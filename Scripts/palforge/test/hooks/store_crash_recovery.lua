-- test/hooks/store-crash-recovery — WHICH COPY DOES THE STORE READ WHEN A WRITE WAS INTERRUPTED?
--
-- §7.3 of the format-3 design is a four-row table saying exactly what is on disk after a crash
-- at each step of the write, and which copy the next read recovers from:
--
--   crash during step 1   good .json, partial .tmp   -> reads .json          nothing lost
--   between steps 3 and 4 no .json, complete .tmp    -> reads .tmp           nothing lost
--   during step 4         rename is atomic on NTFS   -> one of the above     nothing lost
--   .tmp unreadable       .bak                       -> reads .bak           the last flush
--
-- EVERY ROW OF IT WAS REASONED FROM os.rename's SEMANTICS. Not one was observed, and the two
-- places it could be wrong are exactly the two the reasoning leans on: os.rename on NTFS
-- refuses an existing destination where POSIX silently replaces it (which is why the write is a
-- four-step rotation and not a two-step one), and Lua's io.open("wb") on Windows is buffered by
-- the C runtime in a way the design says nothing about. The headless case file
-- (test/cases/store_codec.lua) pins all four rows — on WSL2/ext4, in a scratch directory, in a
-- process with no game in it. This is the same measurement on the filesystem players have.
--
-- IT ALSO TAKES THE OTHER SAFETY PROPERTY, and that one has never been measured anywhere but a
-- fake I/O table: A FILE THAT WILL NOT PARSE IS NEVER OVERWRITTEN. Under format 2 the loader
-- discarded an unreadable file silently (core/event.lua:379, as it was) and the next flush ten
-- seconds later wrote over the only copy — no log line, no recovery, the player's building
-- state gone for a reason nobody could name afterwards. Format 3 refuses to read it, refuses to
-- write it, and moves the bytes VERBATIM into _quarantine/ on the next write. This hook plants
-- a broken file, watches the refusal, triggers the write, and then compares the quarantined
-- bytes against what it planted — byte for byte, because "moved verbatim" is a claim about
-- bytes and nothing weaker is worth making.
--
-- ⚠️ IT WORKS ON ITS OWN PACK ID, `pf_crash`, AND CANNOT REACH ANOTHER. Every path it touches
-- is derived from state.keyFor("pf_crash"), and no real pack may be called that. The file it
-- corrupts is the file it wrote itself, four lines earlier. store-save-roundtrip uses a
-- different id (`pf_probe`) for exactly this reason: this hook's whole method is destroying the
-- file it is working on, and the round trip's file has to survive a relaunch.
--
-- ⚠️ THE QUARANTINE HALF NEEDS A FRESH SESSION. core/state loads a pack's file at most ONCE per
-- world (loadPack sets S.loaded before it does anything else, so a refusal is not retried every
-- scan). If anything has already loaded `pf_crash` this session — running this hook twice, or
-- an F9 that did not clear the store — the planted file cannot be read for the first time and
-- block [2] says so by name instead of reporting a pass it did not earn. Restart the game, or
-- quit to the title and load the save again, and run this hook first.
--
-- writes = true. It creates, corrupts, quarantines and rewrites files in a real save's state
-- directory. Everything it makes is listed with its absolute path in the last block, together
-- with the one call that removes them.
local hooks = require("palforge.test.hooks")

local PROBE = "pf_crash"

local function readAll(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local t = f:read("a")
    f:close()
    return t
end

local function writeAll(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function exists(path) return path ~= nil and readAll(path) ~= nil end

local function sizeOf(path)
    local t = readAll(path)
    return t and #t or nil
end

-- Everything this hook plants, so the last block can list what it left and the restore can be
-- checked rather than assumed.
local function census(h, path)
    h:value("  <f>.json", sizeOf(path) and (sizeOf(path) .. " bytes") or "absent")
    h:value("  <f>.json.tmp", sizeOf(path .. ".tmp") and (sizeOf(path .. ".tmp") .. " bytes") or "absent")
    h:value("  <f>.json.bak", sizeOf(path .. ".bak") and (sizeOf(path .. ".bak") .. " bytes") or "absent")
end

hooks.declare{
    id     = "store-crash-recovery",
    item   = "Foundations / F-7 — the format-3 store",
    needs  = { world = true },
    writes = true,
    desc   = "plant a torn write and an unreadable file in a real save's store and see which "
          .. "copy the loader recovers from — §7.3's table, on NTFS instead of on paper",
    run = function(h)
        local state   = require("palforge.core.state")
        local file    = require("palforge.utils.file")
        local json    = require("palforge.utils.json")
        local backend = require("palforge.utils.file.json_file")

        --------------------------------------------------------------------
        h:section("[1] where, and whether the quarantine half is reachable")
        --------------------------------------------------------------------
        local key, kerr = state.keyFor(PROBE)
        if not key then
            h:fail("state.keyFor(%q) refused: %s", PROBE, tostring(kerr))
            return
        end
        local path = file.pathFor(key)
        if not path then
            h:fail("utils.file.pathFor(%q) refused — a format-3 key carries a directory "
                .. "separator and the backend would not resolve it.", key)
            return
        end
        h:value("save directory", state.saveDir())
        h:value("key", key)
        h:value("path", path)

        -- ASKED BEFORE ANYTHING TOUCHES THE STORE. state.isLoaded reads a table and opens
        -- nothing, which is the only reason this question can be asked at all.
        local alreadyLoaded = state.isLoaded(PROBE)
        h:value("has anything loaded '" .. PROBE .. "' this session", tostring(alreadyLoaded))
        h:log("BEFORE:")
        census(h, path)

        --------------------------------------------------------------------
        h:section("[2] a file that will not parse is NEVER overwritten")
        --------------------------------------------------------------------
        -- The bytes are deliberately recognisable and deliberately not JSON: a truncation is
        -- what a real interrupted write leaves, and a reader who finds this string in a
        -- quarantine directory a month from now should be able to tell where it came from.
        local BROKEN = '{"palforge":{"format":3,"mod":"' .. PROBE .. '"},"data":{"planted'
        if alreadyLoaded then
            h:warn("SKIPPING THE QUARANTINE HALF, AND NOT SILENTLY: '%s' has already been read "
                .. "this session, and core/state reads a pack's file at most once per world "
                .. "(loadPack sets S.loaded before it does anything else, so a refusal is not "
                .. "retried on every scan). Planting a broken file now would be read by nothing "
                .. "and the pass would be fictional. TO OPEN IT: quit to the title screen, load "
                .. "the save again, and run this hook before anything else touches the store.",
                PROBE)
        else
            backend.ensureDir(path:match("^(.*[\\/])") or "")
            if not writeAll(path, BROKEN) then
                h:fail("could not write the planted file at %s — the directory may not exist "
                    .. "yet. Run store-save-roundtrip once first; its write creates the folder.",
                    path)
            else
                h:value("planted", #BROKEN .. " bytes of deliberately truncated JSON")

                -- The FIRST touch of the store for this pack: a get goes through dataOf ->
                -- loadPack -> IO.get -> the backend's recovery order, which is the whole path
                -- under test.
                local db  = state.storeFor(PROBE, "hook")
                local got = db.get("anything")
                local st  = state.stats(PROBE)
                h:value("db.get answered", tostring(got))
                h:value("stats.health", tostring(st.health))
                h:value("stats.lastError", tostring(st.lastError))
                if st.health ~= "unparseable" then
                    h:fail("the loader did not report the file as unparseable — health is %q. "
                        .. "Either it read it (it is not valid JSON) or it decided it was "
                        .. "absent, and the second would let the next flush overwrite the "
                        .. "bytes.", tostring(st.health))
                else
                    h:pass("the loader REFUSED the broken file, named it in the log, and started "
                        .. "'%s' empty for this session rather than guessing at it.", PROBE)
                end
                if readAll(path) == BROKEN then
                    h:pass("and the bytes are still exactly where they were — a read repaired "
                        .. "nothing, created nothing and destroyed nothing. That is the F-8 "
                        .. "rule ('nothing may write on a read') holding on the recovery path, "
                        .. "which is the one place it was most tempting to break.")
                else
                    h:fail("THE PLANTED BYTES CHANGED DURING A READ. That is the single most "
                        .. "serious thing this hook can find.")
                end

                -- Now the WRITE, which is where the move-aside is specified to happen.
                db.set("afterQuarantine", os.time())
                local okSave, saveErr = db.save()
                h:value("db.save() after the refusal", tostring(okSave) ..
                    (saveErr and (" (" .. tostring(saveErr) .. ")") or ""))

                -- Find the quarantined copy. The name is <ISO8601>_<pack>.json under
                -- <save>/_quarantine/, and Lua cannot list a directory — so the date is
                -- reconstructed from the same clock core/state used, and both the current and
                -- the previous second are tried because a run can straddle one.
                local dir = path:match("^(.*[\\/])") or ""
                local qdir = dir .. "_quarantine" .. (package.config:sub(1, 1))
                local found, foundPath = nil, nil
                for back = 0, 3 do
                    local stamp = os.date("!%Y-%m-%dT%H-%M-%SZ", os.time() - back)
                    local cand = qdir .. stamp .. "_" .. PROBE .. ".json"
                    local text = readAll(cand)
                    if text then found, foundPath = text, cand; break end
                end
                if not found then
                    h:warn("no quarantined copy was found under %s. Either the move-aside did "
                        .. "not run, or it ran more than 3 seconds before this line and the "
                        .. "name (which carries a UTC timestamp) could not be reconstructed — "
                        .. "Lua cannot list a directory, so this search is a guess by "
                        .. "construction. LOOK IN THAT FOLDER BY HAND before concluding "
                        .. "anything; the log line above from core/state names the exact file.",
                        qdir)
                elseif found == BROKEN then
                    h:pass("THE BROKEN FILE WAS MOVED ASIDE BYTE FOR BYTE to %s — %d bytes in, "
                        .. "%d bytes out, identical. Under format 2 those bytes were gone ten "
                        .. "seconds after the world loaded and no log line said so.",
                        foundPath, #BROKEN, #found)
                else
                    h:fail("a quarantined file exists at %s but its bytes differ from what was "
                        .. "planted (%d vs %d). 'Verbatim' is a claim about bytes.",
                        foundPath, #found, #BROKEN)
                end
                local fresh = readAll(path)
                if fresh and json.decode(fresh) then
                    h:pass("and '%s' now has a fresh, parseable file of its own — the pack is "
                        .. "working again in the same session that found its file broken.", PROBE)
                end
            end
        end

        --------------------------------------------------------------------
        h:section("[3] §7.3's recovery order, one row at a time")
        --------------------------------------------------------------------
        -- From here on the measurement is at the BACKEND, through the exported plain function
        -- json_file.readDoc — the same code path utils.file.get runs, minus the cache. That is
        -- deliberate: a cached value would answer every question below without a disk read.
        -- readDoc is documented as never writing, and block [2] just checked that claim on the
        -- corrupt path; each row here checks it again by size.
        local GOOD = json.encode({
            palforge = { format = 3, mod = PROBE, save = state.saveDir(), wrote = os.time() },
            data = { which = "json" },
        })
        local TMP  = json.encode({
            palforge = { format = 3, mod = PROBE, save = state.saveDir(), wrote = os.time() },
            data = { which = "tmp" },
        })
        local BAK  = json.encode({
            palforge = { format = 3, mod = PROBE, save = state.saveDir(), wrote = os.time() },
            data = { which = "bak" },
        })
        local PARTIAL = TMP:sub(1, math.max(8, math.floor(#TMP / 2)))

        local function clear()
            os.remove(path); os.remove(path .. ".tmp"); os.remove(path .. ".bak")
        end
        local function which(v)
            return (type(v) == "table" and type(v.data) == "table") and tostring(v.data.which)
                or "nothing"
        end

        local rows = {
            { name = "a partial .tmp beside a good .json",
              plant = function() writeAll(path, GOOD); writeAll(path .. ".tmp", PARTIAL) end,
              want  = "json", from = "json",
              means = "the ordinary 'crashed while writing' case. The good file wins and the "
                   .. "half-written one is ignored — .tmp is consulted ONLY when .json is "
                   .. "missing, which is the rule the whole table rests on." },
            { name = "no .json, a complete .tmp",
              plant = function() writeAll(path .. ".tmp", TMP); writeAll(path .. ".bak", BAK) end,
              want  = "tmp", from = "tmp",
              means = "a crash between steps 3 and 4 of the rotation. The newest complete copy "
                   .. "is the .tmp and it is what comes back — nothing is lost, and the next "
                   .. "flush lays it back down at .json." },
            { name = "no .json, no .tmp, only a .bak",
              plant = function() writeAll(path .. ".bak", BAK) end,
              want  = "bak", from = "bak",
              means = "the .tmp was unreadable or never made. The previous good copy answers "
                   .. "and the only thing lost is the last flush." },
            { name = "nothing at all",
              plant = function() end,
              want  = "nothing", from = nil,
              means = "the normal case for a pack that has never written — and it must be "
                   .. "distinguishable from every row above, because 'absent' is the only "
                   .. "answer that lets the next flush write." },
        }

        for i, row in ipairs(rows) do
            clear()
            row.plant()
            local before = { sizeOf(path), sizeOf(path .. ".tmp"), sizeOf(path .. ".bak") }
            file.forget(key)
            local v, err, kind, from = backend.readDoc(path, key)
            local after = { sizeOf(path), sizeOf(path .. ".tmp"), sizeOf(path .. ".bak") }
            local got = which(v)
            h:log("ROW %d  %-38s -> read %-8s from=%-6s kind=%s", i, row.name, got,
                tostring(from), tostring(kind or "-"))
            if got == row.want and (row.from == nil or from == row.from) then
                h:pass("§7.3 row %d holds on this filesystem: %s. %s", i, row.name, row.means)
            else
                h:fail("§7.3 row %d does NOT hold here: %s gave back %q from %s, and the design "
                    .. "says %q from %s. %s", i, row.name, got, tostring(from), row.want,
                    tostring(row.from), row.means)
            end
            if err and kind ~= "absent" then h:log("      err: %s", tostring(err)) end
            for j = 1, 3 do
                if before[j] ~= after[j] then
                    h:fail("      readDoc CHANGED a file on disk (slot %d: %s -> %s). It is "
                        .. "documented as never writing, and a read path that repairs is a read "
                        .. "path that can create.", j, tostring(before[j]), tostring(after[j]))
                end
            end
        end

        --------------------------------------------------------------------
        h:section("[4] put it back, and say what is left")
        --------------------------------------------------------------------
        clear()
        file.forget(key)
        local db = state.storeFor(PROBE, "hook")
        db.set("lastCrashRun", os.time())
        local okFinal, finalErr = db.save()
        h:value("final write", tostring(okFinal) ..
            (finalErr and (" (" .. tostring(finalErr) .. ")") or ""))
        h:log("AFTER:")
        census(h, path)
        h:value("the file parses again", tostring(json.decode(readAll(path) or "") ~= nil))
        h:log("DIAGNOSE %s", state.diagnose(PROBE))

        h:note("WHAT THIS RUN LEFT BEHIND, and how to remove all of it:")
        h:log("  require('palforge.core.state').uninstall('%s')     -- this hook's file", PROBE)
        h:log("  require('palforge.core.state').uninstall('pf_probe') -- store-save-roundtrip's")
        h:log("  the quarantined copy, if block [2] made one, is under:")
        h:log("      %s_quarantine%s", path:match("^(.*[\\/])") or "", package.config:sub(1, 1))
        h:log("  ...and it is NOT deleted by uninstall, on purpose: a quarantined file is bytes "
            .. "somebody may still want, and nothing in this tree removes them by itself.")
        h:note("nothing above went anywhere near Palworld's own save. Every path printed in this "
            .. "block is under <Mods>/PalForge/state/.")
    end,
}
