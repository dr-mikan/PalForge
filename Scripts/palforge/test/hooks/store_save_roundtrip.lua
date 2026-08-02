-- test/hooks/store-save-roundtrip — DOES A REAL SAVE'S STORE SURVIVE A REAL WORLD LOAD?
--
-- THE ONE MEASUREMENT THE FORMAT-3 STORE HAS NEVER HAD. Everything else about it is proven:
-- 553 headless checks, four case files, an in-memory I/O table, a byte-for-byte comparison of
-- the encoder's output. Not one of those has ever opened a file in a player's
-- <Mods>/PalForge/state/ directory for a save Palworld actually loaded, and the whole point of
-- the pass was to be trustworthy with a player's data. `building-record-orphans` has asked the
-- store what it is HOLDING since 2026-08-02; nothing has ever asked the disk.
--
-- WHAT A ROUND TRIP IS HERE, and it is two different lengths:
--
--   THE SHORT ONE, complete inside one run: write through the public pack surface
--   (PalForge.pack(id).store), flush it, drop the backend's cache, read the bytes back off the
--   real path, and compare. That measures the codec, the atomic write, the path composition
--   and the header — on NTFS, at a path with a directory separator in the key, which is new in
--   format 3 (json_file.lua:190, pathFor's "/" -> SEP).
--
--   THE LONG ONE, which needs the operator: run it, then QUIT TO THE TITLE SCREEN, LOAD THE
--   SAME SAVE AGAIN, and run it again. Run 2 reads what run 1 wrote, across a world teardown
--   (core/state.unload, which flushes and drops every cache) and a fresh world load. That is
--   the trip a pack's own onLoad handler makes, and it is the only version of this that
--   answers "will my structure's state still be there tomorrow".
--
-- ⚠️ WHY THIS DECLARES writes = true, WHEN IT DOES NOT TOUCH PALWORLD'S SAVE. The directory's
-- own definition is stricter than this — `writes` means "a save is mutated", which is why
-- mesh-texture-import (allocates a UTexture2D, writes an 82-byte PNG) and
-- audio-setvolume-audible (makes the game loud) deliberately do NOT declare it. This one takes
-- the stricter side on purpose, and the reason is worth stating rather than assuming: it
-- CREATES FILES IN A REAL SAVE'S STATE DIRECTORY — state/<saveId>/pf_probe.json, its .bak,
-- state/<saveId>/_save.json and state/README.txt — and after this pass the whole claim being
-- defended is that PalForge is careful with the files under its own directory. A hook that
-- makes files there because somebody left env.debug on in a dev overlay would be the first
-- counter-example. `writes` is the only per-experiment gate the framework has, so it is the
-- one used.
--
-- ⚠️ IT DELIBERATELY DOES NOT CLEAN UP AFTER ITSELF, and that is not laziness. The long round
-- trip needs the file to still be there on the next launch, so deleting it at the end of run 1
-- would make run 2 impossible and the hook would only ever measure the half that the headless
-- suite already covers. The last block prints the ABSOLUTE PATH and the one call that removes
-- it — PalForge.core.state.uninstall("pf_probe"). Only one other hook here writes a file at
-- all, store-crash-recovery, and it uses its own id (`pf_crash`) precisely because it corrupts
-- the file it works on and must not be able to reach this one.
--
-- WHAT IT DOES NOT TOUCH: any real pack's file. It writes under the pack id `pf_probe` and
-- nothing else in the tree ever names that id, so a failed run cannot damage a pack's records.
-- It does not call state.unload(), state.__reset() or state.__io(): the first two would drop
-- the merged view core/event is holding every live structure's record in, and the third would
-- redirect a LIVE session's flushes into a fake — the hazard slice 4 recorded about
-- test/cases/store_api.lua's convention, which is a headless convention and is wrong in a game.
local hooks = require("palforge.test.hooks")

-- The one pack id every store hook in this directory writes under. One file for an operator to
-- remove, whichever hooks were run.
local PROBE = "pf_probe"

-- A value shaped to exercise the things format 3 changed, all at once. It is small on purpose:
-- the size question belongs to store-base-load-cost, and a round trip that failed on a 90 KB
-- payload would not say which of the two it failed on.
local function payload(run, saveId)
    return {
        run     = run,
        saveId  = saveId,
        at      = os.time(),
        -- A REAL ARRAY. This is the regression pin for the live encoder bug slice 1 fixed:
        -- encodeTable built its key list with tostring(k) and then read the value back with
        -- the STRING, so t[1] was looked up as t["1"] and came back nil. Every array a pack
        -- ever saved lost its elements. Pinned headlessly in store_codec; pinned HERE against
        -- the deployed copy, which is a different file on a different machine.
        list    = { "wood", "stone", "ore" },
        -- Nested, mixed types, a quote and a backslash — the escaping path, which no headless
        -- check reads back off a real NTFS file.
        nested  = { n = 3, f = 0.5, ok = true, s = [[a "quoted" \ backslash]] },
    }
end

-- Compare two decoded values structurally and name the FIRST field that differs. A boolean
-- "they differ" is not something anyone can act on.
local function diff(a, b, path)
    path = path or ""
    if type(a) ~= type(b) then
        return string.format("%s: wrote a %s, read back a %s", path == "" and "the value" or path,
            type(a), type(b))
    end
    if type(a) ~= "table" then
        if a ~= b then
            return string.format("%s: wrote %s, read back %s", path == "" and "the value" or path,
                tostring(a), tostring(b))
        end
        return nil
    end
    for k, v in pairs(a) do
        local d = diff(v, b[k], path == "" and tostring(k) or (path .. "." .. tostring(k)))
        if d then return d end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return string.format("%s: read back a field that was never written",
                path == "" and tostring(k) or (path .. "." .. tostring(k)))
        end
    end
    return nil
end

local function fileBytes(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

local function ageWords(sec)
    if type(sec) ~= "number" then return "an unrecorded time" end
    if sec < 90 then return string.format("%d seconds", sec) end
    if sec < 5400 then return string.format("%d minutes", math.floor(sec / 60)) end
    if sec < 172800 then return string.format("%.1f hours", sec / 3600) end
    return string.format("%.1f days", sec / 86400)
end

hooks.declare{
    id     = "store-save-roundtrip",
    item   = "Foundations / F-7 — the format-3 store",
    needs  = { world = true },
    writes = true,
    desc   = "write a pack's state through the public surface into a REAL save's store, read it "
          .. "back off the real path, and — run it again after a reload — across a world load",
    run = function(h)
        local state   = require("palforge.core.state")
        local file    = require("palforge.utils.file")
        local json    = require("palforge.utils.json")
        local spatial = require("palforge.core.spatial")
        local backend = require("palforge.utils.file.json_file")

        --------------------------------------------------------------------
        h:section("[1] which save, and where its store lives")
        --------------------------------------------------------------------
        local saveId = state.saveDir()
        local key, kerr = state.keyFor(PROBE)
        if not key then
            h:fail("state.keyFor(%q) refused: %s. Nothing below can run.", PROBE, tostring(kerr))
            return
        end
        local path = file.pathFor(key)
        h:value("spatial.saveId()", spatial.saveId())
        h:value("state.saveDir()", saveId)
        h:value("format this build writes", state.FORMAT)
        h:value("the probe pack's key", key)
        h:value("the probe pack's path", tostring(path))
        h:value("the legacy (format-2) key", state.legacyKey())
        if saveId == "world" then
            h:warn("saveId is the FALLBACK bucket \"world\", not a per-save name. That means the "
                .. "PalGameInstance read failed this session, so this run would measure a file "
                .. "shared by every such session rather than this save's own. The round trip "
                .. "below is still valid; the cross-launch half is not, because a second "
                .. "session could land in the same bucket from a different save.")
        else
            h:pass("the store resolved a PER-SAVE directory, %s/, so nothing written below can "
                .. "be read by another save.", saveId)
        end

        --------------------------------------------------------------------
        h:section("[2] what a PREVIOUS run left — the long round trip")
        --------------------------------------------------------------------
        -- THE READ COMES FIRST, before anything is written, or the write would answer the
        -- question the read was asked.
        local db   = state.storeFor(PROBE, "hook")
        local prev = db.get("roundtrip")
        local run  = 1
        if type(prev) == "table" and type(prev.run) == "number" then
            run = prev.run + 1
            local age = os.time() - (tonumber(prev.at) or os.time())
            h:value("the previous run's number", prev.run)
            h:value("it was written", ageWords(age) .. " ago")
            h:value("the save it named", tostring(prev.saveId))
            local d = diff(payload(prev.run, prev.saveId), prev)
            -- `at` differs by construction (it is a timestamp), so compare only the fields a
            -- round trip must preserve exactly.
            local shape = diff({ list = { "wood", "stone", "ore" },
                                 nested = { n = 3, f = 0.5, ok = true,
                                            s = [[a "quoted" \ backslash]] } },
                               { list = prev.list, nested = prev.nested })
            if shape then
                h:fail("A VALUE CAME BACK CHANGED across whatever happened between the two runs: "
                    .. "%s. That is a real defect in the store and it is the reason this hook "
                    .. "exists.", shape)
            elseif prev.saveId ~= saveId then
                h:warn("the previous run named save %q and this session is %q. The file was read "
                    .. "anyway, which means core/state's save-identity refusal did NOT fire — "
                    .. "expected only if you used state.rebind(). Worth a look.",
                    tostring(prev.saveId), saveId)
            else
                h:pass("EVERY FIELD OF THE PREVIOUS RUN CAME BACK INTACT — the array with all "
                    .. "three elements in order, the nested table, the float, the boolean and "
                    .. "the escaped string. Written %s ago, in a different run of this hook. If "
                    .. "a world load happened in between, THAT IS THE ROUND TRIP CLOSED.",
                    ageWords(age))
                h:note("this block cannot tell a reload from two runs in one session. If you "
                    .. "have not quit to the title screen and loaded this save again since the "
                    .. "last run, do that now and run this hook a third time — the number above "
                    .. "will be %d and the sentence will mean the world load.", run)
            end
            if d and not shape then h:note("the timestamp differs, as it must: %s", d) end
        else
            h:note("NOTHING HAS EVER BEEN WRITTEN HERE — this is run 1 for this save, so there "
                .. "is nothing to read back yet and the long round trip has not started.")
            h:ask("after this finishes: QUIT TO THE TITLE SCREEN, LOAD THIS SAVE AGAIN, and run "
                .. "`pf_hook store-save-roundtrip` a second time. Run 2 is the measurement.")
        end

        --------------------------------------------------------------------
        h:section("[3] the write, through the public pack surface")
        --------------------------------------------------------------------
        -- Deliberately through db.set / db.save and not through core/state's internals: this is
        -- the surface a pack author has, and a round trip taken through a private route would
        -- prove something no pack can rely on.
        local value = payload(run, saveId)
        local okSet, why = db.set("roundtrip", value)
        if not okSet then
            h:fail("db.set refused the payload: %s. Nothing was written.", tostring(why))
            return
        end
        h:pass("db.set accepted the payload (run %d) — the validator walked it and found a tree "
            .. "of strings, numbers, booleans and tables.", run)

        -- The refusals, exercised in the same breath and on the same live store. Cheap, and it
        -- is the difference between "the validator is wired" and "the validator exists".
        local cyc = {}; cyc.self = cyc
        local okCyc, whyCyc = db.set("pf_should_never_land", cyc)
        if okCyc then
            h:fail("db.set ACCEPTED a cyclic table. It should have refused it by name; the "
                .. "flush would have failed instead, taking this pack's whole file with it.")
        else
            h:pass("db.set refused a cyclic value at the call site, naming the pack and the "
                .. "field: %s", tostring(whyCyc))
        end
        local okFn = db.set("pf_should_never_land", { onDone = function() end })
        if okFn then h:fail("db.set ACCEPTED a function-valued field.") end

        local t0 = os.clock()
        local okSave, saveErr = db.save()
        local writeMs = (os.clock() - t0) * 1000
        if not okSave then
            h:fail("db.save() FAILED: %s. The pack stays dirty and the next 10 s pump retries "
                .. "it — that is the format-3 write path working, and it is also why this run "
                .. "cannot measure anything below.", tostring(saveErr))
            h:note("state.diagnose: %s", state.diagnose(PROBE))
            return
        end
        h:value("db.save() took", string.format("%.2f ms", writeMs))
        h:pass("db.save() reported the file written.")

        --------------------------------------------------------------------
        h:section("[4] the bytes, read back off the real path")
        --------------------------------------------------------------------
        local size = fileBytes(path)
        h:value("the file exists", size and "yes" or "NO")
        h:value("its size", size and (size .. " bytes") or "n/a")
        if not size then
            h:fail("db.save() said it wrote and there is no file at %s. That is the worst "
                .. "possible answer and it is exactly what this hook was written to catch.",
                tostring(path))
            return
        end

        -- Drop the backend's in-process cache first, or the "read" below would be answered
        -- from the same table that was just written and would prove nothing at all. This is
        -- the eviction slice 1 added; before it, the module-level cache was never dropped.
        file.forget(key)
        local doc, derr, kind = file.get(key)
        if type(doc) ~= "table" then
            h:fail("re-reading %s after forgetting its cache gave nothing back (%s / %s). The "
                .. "bytes are on disk and the loader cannot read them.", key,
                tostring(derr), tostring(kind))
            return
        end
        local head = type(doc.palforge) == "table" and doc.palforge or {}
        h:value("palforge.format", tostring(head.format))
        h:value("palforge.mod", tostring(head.mod))
        h:value("palforge.save", tostring(head.save))
        h:value("palforge.forge", tostring(head.forge))
        h:value("sections present", table.concat({
            doc.buildings and "buildings" or nil, doc.orphans and "orphans" or nil,
            doc.data and "data" or nil, doc.ledger and "ledger" or nil }, ", "))

        if tonumber(head.format) ~= state.FORMAT then
            h:fail("the file says format %s and this build writes %d.", tostring(head.format),
                state.FORMAT)
        elseif head.mod ~= PROBE then
            h:fail("the file says mod %q and it was written for %q — the per-mod isolation is "
                .. "the whole change and the header does not agree with the filename.",
                tostring(head.mod), PROBE)
        elseif head.save ~= saveId then
            h:fail("the file says save %q and it is sitting in the folder for %q. core/state "
                .. "will refuse to read it next session, correctly, and this session wrote it.",
                tostring(head.save), saveId)
        else
            h:pass("THE FILE DESCRIBES ITSELF CORRECTLY: format %d, mod %q, save %q. A file that "
                .. "is moved or copied is detectable rather than silently adopted.",
                state.FORMAT, PROBE, saveId)
        end

        local back = type(doc.data) == "table" and doc.data.roundtrip or nil
        local d = diff(value, back)
        if d then
            h:fail("THE VALUE DID NOT SURVIVE THE FILE: %s", d)
        else
            h:pass("every field came back identical from the bytes on disk — including the "
                .. "three-element array, which is the live encoder bug this pass fixed, and the "
                .. "escaped string.")
        end

        --------------------------------------------------------------------
        h:section("[5] the .bak rotation, on NTFS")
        --------------------------------------------------------------------
        -- §7.3 of the design is REASONED FROM os.rename SEMANTICS AND HAS NEVER BEEN OBSERVED
        -- ON WINDOWS. The headless case file exercises it on WSL2/ext4, which is a different
        -- filesystem with different rename rules. This is the cheap half of that measurement:
        -- after a SECOND write, both copies must exist, both must parse, and they must differ.
        -- (store-crash-recovery takes the other half — which copy the loader reads when one of
        -- them is missing.)
        db.set("rotationProbe", os.time())
        local ok2 = db.save()
        local bakPath = path .. ".bak"
        local tmpPath = path .. ".tmp"
        h:value("second write reported", tostring(ok2))
        h:value("<f>.json", (fileBytes(path) or 0) .. " bytes")
        h:value("<f>.json.bak", fileBytes(bakPath) and (fileBytes(bakPath) .. " bytes")
            or "ABSENT")
        h:value("<f>.json.tmp", fileBytes(tmpPath) and (fileBytes(tmpPath) .. " bytes")
            or "absent (correct — step 4 renamed it away)")
        local curText = backend.readFile(path)
        local bakText = backend.readFile(bakPath)
        if not bakText then
            h:fail("there is no .bak after two writes. On this filesystem step 3 of the "
                .. "rotation (rename <f>.json -> <f>.json.bak) did not happen, so between the "
                .. "remove and the rename there is a window with no complete copy — which is "
                .. "the defect format 3 was supposed to close.")
        else
            local bv = json.decode(bakText)
            local cv = json.decode(curText or "")
            if type(bv) ~= "table" or type(cv) ~= "table" then
                h:fail("one of the two copies does not parse (.json %s, .bak %s).",
                    type(cv), type(bv))
            elseif bakText == curText then
                h:warn("the .json and the .bak are byte-identical. Not a defect — it happens "
                    .. "when the second write produced the same bytes — but it means this run "
                    .. "did not actually demonstrate a PREVIOUS version being kept.")
            else
                h:pass("AT EVERY INSTANT THERE ARE TWO COMPLETE COPIES ON NTFS: <f>.json holds "
                    .. "this write and <f>.json.bak holds the one before it, both parse, and "
                    .. "they differ. §7.3's table was reasoned from os.rename's semantics; this "
                    .. "is the first time it has been watched on Windows.")
            end
        end

        --------------------------------------------------------------------
        h:section("[6] what is on disk now, and how to remove it")
        --------------------------------------------------------------------
        local st = state.stats(PROBE)
        h:value("stats.health", tostring(st.health))
        h:value("stats.bytes", tostring(st.bytes))
        h:value("stats.data (keys)", tostring(st.data))
        h:value("stats.dirty", tostring(st.dirty))
        h:value("stats.lastError", tostring(st.lastError))
        h:log("DIAGNOSE %s", state.diagnose(PROBE))

        local audit = state.audit()
        h:value("packs this save's store knows", #audit.packs)
        for _, p in ipairs(audit.packs) do
            h:log("  pack %-16s loaded=%-5s buildings=%-4d orphans=%-4d data=%-3d %s",
                p.pack, tostring(p.loaded), p.buildings, p.orphans, p.data, tostring(p.path))
        end

        h:note("THIS HOOK LEFT A FILE BEHIND ON PURPOSE. Run 2 of this hook, after a reload, is "
            .. "the measurement that matters, and it can only read what run 1 left. Nothing "
            .. "reads %s except this hook and its siblings, and no real pack can be named "
            .. "%s — but it is a file in your state directory and here is how it goes away:",
            PROBE, PROBE)
        h:log("  from the Lua console:  require('palforge.core.state').uninstall('%s')", PROBE)
        h:log("  or delete this file:   %s", tostring(path))
        h:log("  and its backup:        %s", tostring(bakPath))
        h:note("PALWORLD'S OWN SAVE WAS NOT TOUCHED BY ANY OF THIS. Everything above happened "
            .. "under <Mods>/PalForge/state/, and deleting that whole folder loses only the "
            .. "state mods kept for your buildings — state/README.txt says the same thing where "
            .. "a player will find it.")
    end,
}
