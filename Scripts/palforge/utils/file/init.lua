-- PalForge utils.file: the persistence FACADE, backed by the default json_file
-- backend (JSON key/value files under <Mods>/PalForge/state/), PLUS the pack-relative
-- path resolver every pack that ships an asset needs. Self-contained.
--
-- PUBLIC API — the same method names the old core.util.store exposed, so callers
-- (core.building) only change their `require` (...util.store -> ...util.file) and
-- their local var name (store -> file):
--   M.get(key)              -> value | nil, err, kind
--   M.set(key, val)         -- stage in memory
--   M.setAndFlush(key, val) -- stage + persist immediately
--   M.flush(key)            -- persist (key, or everything staged)
--   M.forget(key)           -- drop a key's CACHED value (the cache was never evicted)
--   M.pathFor(key)          -- the absolute file a key lands at
--   M.packDir(level)        -- the directory of the .lua file that called you
--   M.resolvePackPath(rel)  -- that directory + a relative path
--   M.isAbsolute(path)      -- the test the two above dispatch on
--
-- ⚠️ A KEY MAY NOW CONTAIN "/" — format 3 puts one directory per Palworld save under state/
-- and one file per mod id inside it, so a key reads "w_1DF0E44B…/logi". The separator
-- handling, the refusal of anything that could escape state/, and the .bak rotation are all
-- in json_file.lua; this facade only forwards. Everything else about the contract is
-- unchanged, and PalForge.utils.file stays a public surface a pack can use for its own
-- arbitrary keys.
--
-- WHY THE PATH HALF IS HERE AND WHY IT WAS MISSING. The one asset route a pack can
-- genuinely ship on today is a file off disk (a .obj for the procedural mesh backend, a
-- .png for ImportFileAsTexture2D), and both of those went to io.open / the importer
-- VERBATIM. So the documented example was `C:/mods/example/marker.obj` — a path that is
-- correct on exactly one machine, which makes the one shippable route unshippable. The
-- technique was already in the tree and used once: utils/file/json_file.lua resolves
-- <Mods>/PalForge/state/ from `debug.getinfo(1, "S").source`, i.e. from where its OWN
-- module file sits. The only new idea here is doing it for a frame that is NOT ours.
local backend = require("palforge.utils.file.json_file")

local M = {}

-- Read a key -> value (decoded), or nil. On failure the second return says WHY and the third
-- is "absent" (nothing on disk — the normal answer for a key never written) or "corrupt" (a
-- file is there and would not parse, and must not be overwritten).
function M.get(key) return backend:get(key) end

-- Stage a key in memory (persist later via flush / setAndFlush).
function M.set(key, value) return backend:set(key, value) end

-- Stage a key and persist it immediately.
function M.setAndFlush(key, value) return backend:setAndFlush(key, value) end

-- Persist a key (nil = everything staged).
function M.flush(key) return backend:flush(key) end

---Drop a key's CACHED value, so the next get() reads the file again.
---
---This closes a leak rather than adding a convenience. The backend's cache is module-level
---and had no eviction at all: core/event's `store.cache = nil` on world-left dropped that
---module's reference while the backend still held every record set for every world visited
---this session, so leaving a world freed nothing and re-entering it read a stale table.
---core/state calls this per loaded key in state.unload().
---@param key string
---@return boolean had   # was anything cached
function M.forget(key) return backend:forget(key) end

---The absolute path a key lands at — <Mods>/PalForge/state/<key>.json — or nil + why the key
---was refused. Exported because a player who is uninstalling a pack is entitled to be told
---which file to delete (`db.path()`), and because moving an unparseable file into
---_quarantine/ VERBATIM needs the path of the bytes to move.
---@param key string
---@return string? path
---@return string? err
function M.pathFor(key) return backend.pathFor(key) end

--=============================================================================
-- pack-relative paths
--=============================================================================

local SEP = package.config:sub(1, 1)   -- "\\" on Windows, "/" elsewhere

-- Compare paths with one separator and one case. Windows is the real target and its
-- filesystem is case-insensitive, so a prefix test that is not would report "outside
-- PalForge" for a path that differs only in the drive letter's case.
local function canon(p)
    return (tostring(p):gsub("\\", "/"):lower())
end

-- The directory of the source file at an ABSOLUTE debug stack level, with its trailing
-- separator, or nil. `source` is "@<path>" for a file chunk and something else entirely for
-- a string chunk (`load("...")`) or a C function — both of which return nil here rather
-- than a guess, which is why every caller has a "no pack directory" branch.
local function frameDir(level)
    local info = debug.getinfo(level, "S")
    if not info or type(info.source) ~= "string" or info.source:sub(1, 1) ~= "@" then
        return nil
    end
    return info.source:match("@(.*[\\/])")
end

-- PalForge's OWN module root, resolved the way json_file.lua resolves the state dir: this
-- file is .../PalForge/Scripts/palforge/utils/file/init.lua, so two dirs up is
-- .../Scripts/palforge/. It is what the automatic frame walk skips over — a frame inside it
-- is the framework calling itself, never the pack that asked.
local SELF_ROOT = (function()
    local here = frameDir(1)
    if not here then return nil end
    return canon(here .. ".." .. SEP .. ".." .. SEP):gsub("/[^/]+/%.%./", "/"):gsub("/[^/]+/%.%./", "/")
end)()

---Is `path` already absolute? Two shapes count, and both matter here:
---a POSIX/UE root ("/Game/...", "/home/...") and a Windows drive ("C:/mods/..."). Everything
---else is relative to something, and for a pack that something is its own directory.
---
---A UE OBJECT path is absolute by this test, which is deliberate: `/Game/A/SK_X.SK_X` must
---never be joined to a pack directory. That is the same first-character rule
---core.assetpath.isObjectPath uses, arrived at from the other side.
---@param path any
---@return boolean
function M.isAbsolute(path)
    if type(path) ~= "string" or #path == 0 then return false end
    local c = path:sub(1, 1)
    if c == "/" or c == "\\" then return true end
    return path:match("^%a:[\\/]") ~= nil
end

---The directory of the .lua file that called you, with a trailing separator — the "pack
---directory" a pack should resolve its own shipped files against.
---
---`level` is a stack level counted from the CALLER: 1 (the default meaning of an explicit
---value) is the file that called packDir, 2 is that file's caller, and so on — the same
---counting `debug.getinfo` uses, shifted so a caller never has to know that packDir has a
---frame of its own.
---
---With NO argument the level is found by WALKING OUT of PalForge: the first frame whose
---source is not under Scripts/palforge/ is the pack. That is what makes this usable from
---inside the framework, where the number of frames between a pack's `Mesh{ ... }` and the
---code doing the resolving depends on whether the mesh was declared directly or nested
---inside a Pal{ } — a fixed number would be wrong for one of the two.
---
---Returns nil when there is no such frame: a definition made from a string chunk, from C,
---or from PalForge's own test suite has no pack directory, and inventing one would turn a
---relative path into a confidently wrong absolute path.
---@param level integer?
---@return string?
function M.packDir(level)
    if level ~= nil then
        local n = tonumber(level)
        if not n then return nil end
        return frameDir(n + 1)          -- +1 skips packDir's own frame
    end
    -- 2 = our caller. 24 is a ceiling, not a measurement: nothing in this tree nests
    -- definitions anywhere near that deep, and an unbounded walk on a recursive call site
    -- would be the one way this could hang.
    for l = 2, 24 do
        local d = frameDir(l)
        if d then
            if not (SELF_ROOT and canon(d):sub(1, #SELF_ROOT) == SELF_ROOT) then return d end
        end
    end
    return nil
end

---Resolve `rel` against the calling pack's directory. An ABSOLUTE path (including any
---/Game/... object path) is returned unchanged, so this is safe to run over every path a
---spec carries without first knowing which kind it is.
---
---   local file = require("palforge.utils.file")
---   Mesh{ id = "example:marker", kind = "obj", model = file.resolvePackPath("marker.obj") }
---
---`level` has the same meaning as in packDir and is normally omitted. When no pack
---directory can be found the path comes back UNCHANGED — a relative path that stays
---relative fails at io.open with the string the author wrote, which is a readable failure;
---a path joined to a guessed directory is not.
---@param rel string
---@param level integer?
---@return string
function M.resolvePackPath(rel, level)
    if type(rel) ~= "string" or #rel == 0 then return rel end
    if M.isAbsolute(rel) then return rel end
    local dir = (level ~= nil) and frameDir((tonumber(level) or 1) + 1) or M.packDir()
    if not dir then return rel end
    -- "./x" and ".\x" are the same statement as "x"; anything further (".." segments) is
    -- left to the OS, which resolves them correctly on both platforms.
    local cleaned = rel:gsub("^%.[\\/]", "")
    return dir .. cleaned
end

return M
