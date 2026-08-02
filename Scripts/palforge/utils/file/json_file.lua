-- PalForge utils.file.json_file: the default persistence backend — simple JSON
-- key/value files under the PalForge Mods dir. Extends the base backend. Moved
-- VERBATIM from the old core.util.store (depends only on utils.json + the shared
-- logger; the file/dir helpers it used to pull from deprecated/core stay inlined).
--
-- Each key is its own file: <Mods>/PalForge/state/<key>.json
--
-- ⚠️ A KEY IS NOW A PATH, NOT A LEAF NAME. Format 3 gives every Palworld save its own
-- directory and every mod id its own file inside it, so the keys this backend is handed look
-- like "w_1DF0E44B4FDDD6196E30819A899C9009/logi" and land at
--   <Mods>/PalForge/state/w_1DF0E44B4FDDD6196E30819A899C9009/logi.json
-- Three things follow from that and each is implemented below:
--   * pathFor NORMALISES the separator. A key is written with "/" by core/state (it composes
--     one string), and Windows is the real target; a literal "/" inside a "\"-rooted path
--     happens to work through the CRT, but the paths this module hands back are also printed
--     in logs and put in front of players, so they are spelled the way the OS spells them.
--   * pathFor REFUSES a key that could escape state/. Neither component can contain a
--     separator by construction — spatial.saveId() gsubs [^%w_] to "_" and a pack id is
--     ^[%w_]+$ — but this is the one place a path is actually built out of a caller's string,
--     and the removal contract ("everything PalForge persists is inside <Mods>/PalForge/")
--     is worth a second lock at the point where it could be broken.
--   * ensureDir is called with the FILE's directory, not with state/, and is MEMOISED. It
--     used to run on every flush, and on Windows its body is
--     `os.execute('if not exist "…" mkdir "…"')` — a cmd.exe process spawn, every 10 s while
--     anything was dirty. Per-pack files would have multiplied that by the number of packs.
--
-- ⚠️ AND THE WRITE IS A FOUR-STEP ROTATION NOW, because the old one had an instant with no
-- complete copy on disk. It was: write <f>.tmp, os.remove(<f>), os.rename(tmp, <f>) — and
-- between the remove and the rename the only complete copy of a player's state was a .tmp
-- file that `get` never looked at (it only ever opened pathFor(key)). The sequence and what
-- survives a crash at each step is written out at writeFile below.
local json    = require("palforge.utils.json")
local Backend = require("palforge.utils.file.base.backend")
local log     = require("palforge.utils.log").scope("file")

local JsonFile = Backend:extend("JsonFile")

-- ---- inlined file/dir helpers (were deprecated/core.readFile / .ensureDir /
-- ---- .writeFile) ----
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Does a FILE exist and open for reading?
local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

---Does this path exist, FILE OR DIRECTORY? `os.rename(p, p)` is the portable probe: it
---succeeds for anything the filesystem has and fails for anything it does not, and renaming a
---path onto itself changes nothing on either platform.
---
---⚠️ IT IS NOT `io.open`, AND THE DIFFERENCE COST THIS TREE ITS FIRST REAL WRITE. `ensureDir`
---used `exists()` above, which opens the path as a FILE — that succeeds for a directory on
---Linux and FAILS for one on Windows. So on Windows `ensureDir` ran mkdir, asked "is it there
---now?", was told no by a probe that cannot see directories, and reported
---`could not create <dir>` for a directory it had just created. Every per-save write the store
---attempted in game failed that way, with the log blaming the filesystem.
---
---The headless suite could not catch it: it runs under Linux Lua, where `io.open` on a
---directory succeeds, so `ensureDir` answered correctly there and 553 checks passed while the
---game wrote nothing. MEASURED 2026-08-02 22:05-22:06 (hook `store-save-roundtrip`, and every
---`[file][warn] write failed` line in that session).
---@param path string
---@return boolean
local function pathExists(path)
    if type(path) ~= "string" or path == "" then return false end
    return os.rename(path, path) == true
end

local SEP = package.config:sub(1, 1)   -- "\\" on Windows, "/" elsewhere

-- Directories this session has already created (or found). The VALUE is what makes the memo
-- safe rather than merely fast: a write failure clears its own directory's entry (see
-- writeFile's callers), so a directory that is deleted underneath a running game is retried
-- on the next flush instead of being remembered as present forever.
local dirsMade = {}

-- Ensure a directory exists (mkdir -p equivalent). Returns true on success. Windows is
-- the real target (UE4SS), but the POSIX branch keeps headless runs working too.
-- Both branches create intermediate directories, which is what format 3's
-- state/<save>/ layer needs.
-- BOTH PROBES ARE pathExists, NOT exists. See pathExists for what using the file probe here
-- cost: on Windows it cannot see a directory, so this function reported "could not create" for
-- a directory mkdir had just made, and every per-save store write in the game failed.
--
-- A MISS IS NOT MEMOISED (`made or nil`), which is the same positives-only rule the asset and
-- icon caches use and which `mesh-texture-import-live` confirmed in game: a directory that was
-- not creatable a moment ago — a drive still mounting, a folder the player was renaming — must
-- not be unwriteable for the rest of the session.
local function ensureDir(dir)
    if dir == nil or dir == "" then return false end
    if dirsMade[dir] then return true end
    if pathExists(dir) then dirsMade[dir] = true; return true end
    local ok = pcall(function()
        if SEP == "\\" then
            os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
        end
    end)
    local made = ok and pathExists(dir)
    dirsMade[dir] = made or nil
    return made
end

-- The directory part of a path, with no trailing separator, or nil for a bare name.
local function dirOf(path)
    return path:match("^(.*)[\\/][^\\/]*$")
end

-- Atomic-ish write, in four steps, so at EVERY INSTANT at least one complete copy exists and
-- the recovery rule below can name which one it is:
--
--   1. write   <f>.json.tmp
--   2. remove  <f>.json.bak            (ignored if absent — Windows os.rename won't overwrite)
--   3. rename  <f>.json -> <f>.json.bak    (harmless failure on a first write)
--   4. rename  <f>.json.tmp -> <f>.json
--
--   crash during 1        good .json, partial .tmp   -> get reads .json (.tmp is only ever
--                                                       consulted when .json is MISSING)
--   crash between 3 and 4 no .json, complete .tmp,    -> get reads .tmp
--                         previous .bak
--   crash during 4        rename is atomic within an NTFS volume -> one of the two above
--   .tmp unreadable       .bak                        -> get reads .bak; the last flush is
--                                                       the only thing lost
--
-- ⚠️ The .bak is NEVER deleted afterwards. It doubles the file count in a directory whose
-- largest measured member is 26 KB, and it is the cheapest possible answer to the fear that
-- started the whole format-3 pass: "what happens to my world if this goes wrong".
--
-- Returns ok, err.
local function writeFile(path, text)
    local tmp = path .. ".tmp"
    local bak = path .. ".bak"

    local f, oerr = io.open(tmp, "wb")
    if not f then return false, "open failed: " .. tostring(oerr) end
    local ok, werr = pcall(function()
        f:write(text)
        f:close()
    end)
    if not ok then pcall(function() f:close() end); return false, "write failed: " .. tostring(werr) end

    -- 2 + 3. Both are allowed to fail: on a FIRST write there is no .json to rotate and no
    -- .bak to clear, and that is the normal case rather than an error. What is not allowed is
    -- for step 4 to find <path> still occupied, which is why step 4 has its own fallback.
    os.remove(bak)
    os.rename(path, bak)

    -- 4.
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        -- Windows os.rename refuses an existing destination. If step 3 did not move the old
        -- file out of the way (antivirus holding the handle, a read-only attribute), clear it
        -- and try once more before falling back to a direct write.
        os.remove(path)
        rok, rerr = os.rename(tmp, path)
    end
    if not rok then
        -- Last resort: write the bytes straight to <path>. The .bak from step 3 is still on
        -- disk at this point, so even a crash inside THIS write leaves a complete copy.
        local f2 = io.open(path, "wb")
        if not f2 then return false, "rename failed: " .. tostring(rerr) end
        local ok2, werr2 = pcall(function() f2:write(text); f2:close() end)
        if not ok2 then
            pcall(function() f2:close() end)
            return false, "rename failed (" .. tostring(rerr) .. ") and the direct write failed: "
                .. tostring(werr2)
        end
        os.remove(tmp)
    end
    return true
end

-- Base dir resolved from THIS module's path. The on-disk target must stay
-- <Mods>/PalForge/state/. This file lives at
--   .../PalForge/Scripts/palforge/utils/file/json_file.lua
-- so reaching PalForge/ means going FOUR dirs up from here:
--   file -> utils -> palforge -> Scripts -> PalForge, then /state/.
-- (Keep this count in step with the module's depth — it was one too deep while this file
--  lived under core/util/, which silently put state/ outside the mod dir.)
--
-- THIS IS THE TECHNIQUE utils/file/init.lua's packDir / resolvePackPath generalise: resolve
-- a directory from a SOURCE FILE's own path rather than from a hardcoded string. The
-- difference is only which frame is asked — level 1 here (this module), the calling pack's
-- frame there — and it is what lets a pack ship `model = "art/marker.obj"` instead of the
-- `C:/mods/example/marker.obj` that was the only documented shape. The count above stays
-- hand-written because THIS path is fixed by the module's own location, not by a caller's.
local function stateDir()
    local here = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
    local up   = table.concat({ "..", "..", "..", "..", "state" }, SEP)
    return here .. up .. SEP
end

local cache = {}

-- A key must stay UNDER state/. Two shapes are refused, and both would put PalForge's writes
-- somewhere the "delete the folder and it is all gone" contract does not cover:
--   * a ".." segment, which walks out
--   * an absolute prefix ("/x", "C:/x"), which ignores state/ entirely
-- Everything else is accepted, including the "/" that format-3 keys carry.
local function badKey(key)
    if type(key) ~= "string" or key == "" then return "a key must be a non-empty string" end
    if key:find("^%a:[\\/]") or key:sub(1, 1) == "/" or key:sub(1, 1) == "\\" then
        return "a key must be relative to state/, and '" .. key .. "' is absolute"
    end
    if key == ".." or key:find("^%.%.[\\/]") or key:find("[\\/]%.%.[\\/]") or key:find("[\\/]%.%.$") then
        return "a key must stay under state/, and '" .. key .. "' has a '..' segment"
    end
    return nil
end

-- The absolute on-disk path a key resolves to, or nil + why it was refused.
local function pathFor(key)
    local why = badKey(key)
    if why then return nil, why end
    return stateDir() .. (key:gsub("[\\/]", SEP)) .. ".json"
end

---The absolute path a key lands at. PUBLIC because two things in the format-3 store need it
---and neither can be given the resolution technique instead: `db.path()` puts it in front of a
---player who is about to uninstall a pack, and the quarantine move (a file that will not parse
---is moved aside VERBATIM, never overwritten) needs the source path to copy from. Keeping this
---the only exported route preserves the invariant the header above states — json_file is the
---one module that knows where state/ is on disk.
---@param key string
---@return string? path
---@return string? err
function JsonFile.pathFor(key) return pathFor(key) end

---Read and decode ONE document at an absolute path, applying the recovery order.
---
---THE ORDER IS <p> -> <p>.tmp -> <p>.bak, and the last two are only consulted when <p> is
---MISSING — a partial .tmp beside a good .json is the ordinary "crashed while writing" case
---and the good file wins. That is the whole of the table at writeFile above, in code.
---
---⚠️ IT DOES NOT WRITE. The format-3 spec has the recovered copy re-committed here so the next
---read is normal; it is not, deliberately, because "nothing may write on a READ" is a gate
---this tree closed in game (F-8: reading a native catalog started persisting world state) and
---a read path that repairs is a read path that can create. Nothing is lost by that: the value
---comes back and the session runs on it, and the NEXT flush — a write path, asked for by a
---writer — lays it down at <p> through the rotation above. A session that only ever reads
---leaves the .tmp/.bak exactly where it found them, and the next session recovers identically.
---
---PLAIN FUNCTION, not a method: call it with a dot. Exported so core/state can read a
---candidate file before deciding what to do with it, and so test/cases/store_codec can
---exercise the recovery order on a scratch path in the OS temp directory rather than by
---planting files in a player's state/ — which would falsify F-8's "no registered building
---definition, no file at all" for the case files that run after it.
---@param path string    # absolute, ending in .json
---@param label string?  # what to call it in a log line (a key); defaults to the path
---@return any|nil value
---@return string? err
---@return string? kind  # "absent" | "corrupt" | nil when a value came back
---@return string? from  # "json" | "tmp" | "bak" — which copy answered
local function readDoc(path, label)
    label = label or path
    local text = readFile(path)
    if text then
        local v, derr = json.decode(text)
        if derr then return nil, path .. ": " .. tostring(derr), "corrupt", "json" end
        if v == nil then
            -- The one value that decodes WITHOUT an error and is still indistinguishable from
            -- "there is no file": the literal `null`. Reported as corrupt rather than absent,
            -- because absent is the answer that lets the next flush overwrite the bytes. Any
            -- other decoded type is handed straight back — this backend is a generic
            -- key/value store, and it is core/state, not this file, that knows a state
            -- document is an object.
            return nil, path .. ": the file decoded to null", "corrupt", "json"
        end
        return v, nil, nil, "json"
    end

    -- <p> is missing. Either the key was never written — by far the common case, and the one
    -- F-8 depends on staying silent — or a flush was interrupted between steps 3 and 4 of the
    -- rotation. Whether anything else is on disk is what tells the two apart.
    for _, cand in ipairs({ { path .. ".tmp", "tmp" }, { path .. ".bak", "bak" } }) do
        local ctext = readFile(cand[1])
        if ctext then
            local v, derr = json.decode(ctext)
            if not derr and v ~= nil then
                log.warn(string.format("'%s' is missing and was recovered from its .%s — a flush "
                    .. "was interrupted. The value is live for this session; the next flush "
                    .. "writes it back to the .json.", label, cand[2]))
                return v, nil, nil, cand[2]
            end
            log.warn(string.format("'%s' is missing and its .%s would not parse either: %s",
                label, cand[2], tostring(derr or "it decoded to null")))
        end
    end

    return nil, nil, "absent", nil
end

-- The raw primitives, exported as PLAIN FUNCTIONS (call them with a dot, never with a colon).
-- core/state needs readFile + writeFile to move an unparseable file into _quarantine/ byte for
-- byte, and store_codec needs readDoc + writeFile + ensureDir to exercise the rotation and the
-- recovery order somewhere that is not a player's state/.
JsonFile.readFile  = readFile
JsonFile.writeFile = writeFile
JsonFile.ensureDir = ensureDir
JsonFile.readDoc   = readDoc

---Read a key -> value (decoded), or nil. See readDoc for the recovery order and for why
---nothing here writes.
---
---The three answers are deliberately distinguishable, because core/state does something
---different with each:
---   value                 it read
---   nil, nil, "absent"    nothing on disk at all — the normal answer for a key never written,
---                         and it must not be confused with the next one
---   nil, err, "corrupt"   a file IS there and would not parse. core/state quarantines those
---                         bytes and only then reads again; with <f>.json moved aside, this
---                         same call falls through to the .bak on its own.
---@param key string
---@return any|nil value
---@return string? err
---@return string? kind   # "absent" | "corrupt" | nil when a value came back
function JsonFile:get(key)
    if cache[key] ~= nil then return cache[key] end

    local path, why = pathFor(key)
    if not path then return nil, why, "corrupt" end

    local v, err, kind = readDoc(path, key)
    if v ~= nil then cache[key] = v end
    return v, err, kind
end

-- Set a key in memory (call flush() or use setAndFlush to persist).
function JsonFile:set(key, value)
    cache[key] = value
end

---Drop a key's cached value. The cache is module-level and was NEVER evicted: `store.cache =
---nil` in core/event dropped that module's reference while this table still held every record
---set for every world visited in the session, so leaving a world freed nothing. core/state
---calls this per loaded key on world-left.
---@param key string
---@return boolean had   # was anything cached
function JsonFile:forget(key)
    local had = cache[key] ~= nil
    cache[key] = nil
    return had
end

function JsonFile:flush(key)
    local keys = key and { key } or {}
    if not key then for k in pairs(cache) do table.insert(keys, k) end end
    local okAll = true
    for _, k in ipairs(keys) do
        local path, why = pathFor(k)
        if not path then
            log.warn("refusing to write '" .. tostring(k) .. "': " .. tostring(why)); okAll = false
        else
            local text, eerr = json.encode(cache[k])
            if not text then
                log.warn("encode failed for '" .. k .. "': " .. tostring(eerr)); okAll = false
            else
                -- The FILE's directory, not state/. Memoised, so the cmd.exe spawn this used
                -- to cost on every flush is paid once per directory per session.
                local dir = dirOf(path)
                if not ensureDir(dir) then
                    log.warn("write failed for '" .. k .. "': could not create " .. tostring(dir))
                    okAll = false
                else
                    local ok, werr = writeFile(path, text)
                    if not ok then
                        log.warn("write failed for '" .. k .. "': " .. tostring(werr))
                        -- The directory may be the reason. Forget it so the next flush asks
                        -- the filesystem again rather than trusting a memo taken before
                        -- somebody deleted the folder underneath us.
                        if dir then dirsMade[dir] = nil end
                        okAll = false
                    end
                end
            end
        end
    end
    return okAll
end

function JsonFile:setAndFlush(key, value)
    self:set(key, value)
    return self:flush(key)
end

return JsonFile
