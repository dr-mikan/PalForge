-- test/hooks/building-record-orphans — THE QUARANTINE ROUND TRIP, AGAINST A REAL SAVE.
--
-- plan/TODO.md Foundations / The id model / F-7, whose "Still owed" is one sentence: *"The round
-- trip has never been run against a real save file."* It has been run headlessly — the attest
-- pass's own `test.run()` printed `world records: 0 restored, 1 quarantined (unattributed), 0
-- unreadable dropped, 0 live` against this working tree's `state/entities_world.json` — and that
-- file is the FALLBACK bucket, written by a session that could not read a save name. A real save
-- has a `w_<directory>` file of its own, and nothing has ever looked at one.
--
-- WHAT F-7 WAS. Records were keyed `<resolvedBuildId>@<cell>` in one file shared by every pack,
-- with no owner and no version, and the miss sweep only ever walked LIVE instances — so a pack's
-- records were never visited again after it was uninstalled, two packs sharing a resolved id
-- shared one state table, and `refreshDefs` picked its winner out of a `pairs()` walk, so which
-- pack owned a placed structure varied between sessions.
--
-- WHAT THE FIX CHOSE, and it is the reason this hook exists rather than a delete-count assertion:
-- **NEVER DELETE ON ABSENCE.** "No definition claims this build id" is not the statement "this
-- pack is gone" — a player disables a mod for one evening, a pack defines its buildings lazily
-- and has not got there yet, an id is mid-rename. So an unclaimed record is MOVED to the file's
-- `orphans` section with an `orphanedAt`, keeps its bytes, and moves back by itself the moment a
-- definition claims its build id again. One pass per world load, after a 60-scan (~30 s) grace
-- period. The ONLY destructive act in the whole file is the `ORPHAN_MAX = 4096` cap.
--
-- THE ASSERTION THAT MATTERS IS THEREFORE A NEGATIVE: a record whose pack is merely NOT LOADED
-- THIS SESSION must still be in the file when the pass has finished. Everything else this hook
-- prints — the counts, the versions, the packs — is context for that one line.
--
-- ⚠️ AND THE F-5 COUPLING IS LOAD-BEARING, which is why the two hooks were written together.
-- The prune's justification used to be "F9 drops a pack's content until the game restarts". That
-- stopped being true when `object_manager` entered core/reload's KEEP — and had it stayed true,
-- this prune would have quarantined EVERY pack's records about thirty seconds after any F9. If
-- object_manager is ever dropped from KEEP again, ORPHAN_GRACE_SCANS is the only thing standing
-- between a reload and a mass quarantine. This hook prints the KEEP flag for that reason.
--
-- HOW TO GET A MEANINGFUL RUN. The pass runs ONCE per loaded world and not before scan 60, so:
--
--     load the save, wait ~30 s, then  pf_hook building-record-orphans
--
-- Running it earlier is not wasted — it prints `gate.pruned = false` and says how many scans are
-- left — and running it twice prints the delta across the pass, which is the round trip itself.
--
-- READ-ONLY, and more carefully than that phrase usually means. `utils.file.get` returns the
-- BACKEND'S CACHED TABLE, which is the very table core/event is holding as `store.cache`
-- (utils/file/json_file.lua's `cache`), so a write here would be a write into the runtime's live
-- record set and would be flushed to disk by the next 10 s batch. Nothing below assigns into any
-- table it reads. `writes = false` is therefore a promise about this file's code, not a property
-- of the API it uses.
local hooks = require("palforge.test.hooks")

local SNAP = "__PalForgeHookOrphanSnapshot"

-- The values core/event.lua declares. Read out of the LIVE closures below and compared against
-- these, because a hook that prints its own copy of a constant is a hook that will one day
-- disagree with the code it is measuring and say nothing about it.
local DOC_GRACE_SCANS = 60      -- core/event.lua:369, ~30 s at SCAN_MS = 500
local DOC_ORPHAN_MAX  = 4096    -- core/event.lua:370
local DOC_REC_VERSION = 2       -- core/event.lua:363
local SCAN_MS         = 500

-- Pull a named upvalue out of a live closure, searching function-valued upvalues to `depth`.
-- (The same helper as test/hooks/building_runtime_reload.lua, and deliberately a copy: a hook
-- file returns nothing, so there is no module for two of them to share, and fifteen lines of
-- pure Lua duplicated is cheaper than a fifth module in a directory whose whole contract is
-- "one file per measurement".)
--
-- ORPHAN_GRACE_SCANS, ORPHAN_MAX and REC_VERSION are all module-locals of core/event.lua and
-- none is exported. They are reachable from `M.__scanPump` at nesting depths 1, 2 and 3
-- (__scanPump -> scanOnce -> pruneOrphans -> loadWorld), which is why the default is 4.
local function upvalue(fn, name, depth, seen)
    if type(fn) ~= "function" then return nil end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
    depth, seen = depth or 4, seen or {}
    if seen[fn] or depth < 0 then return nil end
    seen[fn] = true
    local nested, i = {}, 1
    while true do
        local ok, n, v = pcall(debug.getupvalue, fn, i)
        if not ok or n == nil then break end
        if n == name then return v end
        if type(v) == "function" then nested[#nested + 1] = v end
        i = i + 1
    end
    for _, f in ipairs(nested) do
        local v = upvalue(f, name, depth - 1, seen)
        if v ~= nil then return v end
    end
    return nil
end

local function countPairs(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return out
end

hooks.declare{
    id    = "building-record-orphans",
    item  = "Foundations / The id model / F-7",
    needs = { world = true },
    desc  = "the orphan quarantine round trip against a real save: what loaded, what had no "
         .. "owner, what was quarantined, and that nothing belonging to an absent pack was lost",
    run = function(h)
        local event   = require("palforge.core.event")
        local spatial = require("palforge.core.spatial")
        local file    = require("palforge.utils.file")
        local om      = require("palforge.core.object_manager")
        local reload  = require("palforge.core.reload")

        local RT   = _G.__PalForgeBuildingRegistry
        local prev = _G[SNAP]

        --------------------------------------------------------------------
        h:section("[1] which file, and is it this save's own")
        --------------------------------------------------------------------
        local saveId = spatial.saveId()
        local key    = "entities_" .. saveId
        h:value("spatial.saveId()", saveId)
        h:value("persistence key", key .. ".json  (under <Mods>/PalForge/state/)")
        if saveId == "world" then
            h:warn("THIS IS THE FALLBACK BUCKET, not this save's own file. core/spatial reads "
                .. "GetSelectedWorldSaveDirectoryName / GetSelectedWorldName off PalGameInstance "
                .. "and falls back to the single \"world\" bucket when neither answers — which is "
                .. "the state every save shared before `spatial-saveid` was closed. Everything "
                .. "below is still a real measurement of the quarantine, but it is being made "
                .. "against a file that MORE THAN ONE SAVE may have written to, so a record with "
                .. "no owner here may simply belong to a different save. That is worth its own "
                .. "line in plan/TODO.md if it reproduces: `spatial-saveid` is listed as Closed.")
        else
            h:pass("the save id resolved to a per-save name, so this file belongs to this save "
                .. "alone — which is what `spatial-saveid` closed and what has never been seen "
                .. "from a hook.")
        end

        local w = file.get(key)
        if type(w) ~= "table" then
            h:note("THERE IS NO SUCH FILE YET, and that is a result rather than a failure: "
                .. "nothing has ever been persisted for this save. A record is written only when "
                .. "the scan discovers an actor whose build id a REGISTERED definition claims, "
                .. "and F-8 made the native catalogs declare without registering. TO MAKE THIS "
                .. "MEASURABLE: require('palforge.native.buildings').publish('WorkBench') from "
                .. "the Lua console in a base with a workbench, wait for a scan, and run this "
                .. "hook again. ⚠️ That call is what starts WRITING to this save.")
            return
        end

        --------------------------------------------------------------------
        h:section("[2] what the file says about itself")
        --------------------------------------------------------------------
        local entities = type(w.entities) == "table" and w.entities or {}
        local orphans  = type(w.orphans) == "table" and w.orphans or {}
        local nEnt, nOrph = countPairs(entities), countPairs(orphans)
        h:value("top-level \"version\"", tostring(w.version))
        h:value("entities (live records)", nEnt)
        h:value("orphans (quarantined records)", nOrph)
        if w.orphans == nil then
            h:note("no `orphans` section at all: this file was written before quarantine existed. "
                .. "core/event's loadWorld adds one on read (it does not rewrite the file), so "
                .. "the first flush after this will carry it.")
        end
        local liveRec = upvalue(event.__scanPump, "REC_VERSION")
        h:value("REC_VERSION (read from the live module)",
            tostring(liveRec or ("unreadable — documented as " .. DOC_REC_VERSION)))
        if liveRec and liveRec ~= DOC_REC_VERSION then
            h:fail("core/event declares REC_VERSION = %s and this hook's header says %d. One of "
                .. "the two has drifted.", tostring(liveRec), DOC_REC_VERSION)
        end
        if tonumber(w.version) and liveRec and tonumber(w.version) ~= liveRec then
            h:note("THE KNOWN COSMETIC LIE, and it is worth confirming from a real file: the "
                .. "top-level \"version\" is %s while the records inside are upgraded to v = %s "
                .. "in place. Nothing reads the top-level field, so it costs nothing today and "
                .. "misleads the next reader — plan/TODO.md Owed work §1 carries it.",
                tostring(w.version), tostring(liveRec))
        end

        --------------------------------------------------------------------
        h:section("[3] every live record, by version, owner and claim")
        --------------------------------------------------------------------
        -- "Claimed" is the ONE question the prune asks: is this record's resolved build id in
        -- Registry.byBuildId, which refreshDefs rebuilds from object_manager on every scan.
        local byBuildId = (RT and RT.byBuildId) or {}
        local v1, v2, vOther, junk, withDef, withPack, withAlt, unclaimed = 0, 0, 0, 0, 0, 0, 0, 0
        local unclaimedKeys, unclaimedPacks = {}, {}
        for k, rec in pairs(entities) do
            if type(rec) ~= "table" then
                junk = junk + 1
            else
                local v = tonumber(rec.v)
                if v == nil then v1 = v1 + 1 elseif v == 2 then v2 = v2 + 1 else vOther = vOther + 1 end
                if type(rec.def) == "string" then withDef = withDef + 1 end
                if type(rec.pack) == "string" then withPack = withPack + 1 end
                if rec.altKeys ~= nil then withAlt = withAlt + 1 end
                if not (type(rec.buildId) == "string" and byBuildId[rec.buildId]) then
                    unclaimed = unclaimed + 1
                    if #unclaimedKeys < 12 then unclaimedKeys[#unclaimedKeys + 1] = tostring(k) end
                    unclaimedPacks[tostring(rec.pack or rec.def or "unattributed")] = true
                end
            end
        end
        h:value("records at v = 2 (stamped with owner)", v2)
        h:value("records with no `v` at all (the v1 port shape)", v1)
        h:value("records at some other version", vOther)
        h:value("records carrying a definition id (`def`)", withDef)
        h:value("records carrying a pack id (`pack`)", withPack)
        h:value("records still carrying the dead `altKeys`", withAlt)
        h:value("records whose build id NO definition claims", unclaimed)
        h:value("entries that are not records at all", junk)
        if #unclaimedKeys > 0 then
            h:value("unclaimed keys (first " .. #unclaimedKeys .. ")",
                table.concat(unclaimedKeys, ", "))
            h:value("their packs", table.concat(sortedKeys(unclaimedPacks), ", "))
        end
        if withAlt > 0 then
            h:note("`altKeys` was written by persist() and read by nothing since the port; F-7 "
                .. "deleted it, and stampRecord removes it ON CONTACT rather than rewriting the "
                .. "file. %d record(s) here have not been bound by the scan since the upgrade, "
                .. "which is why they still carry it — stand near them and it clears.", withAlt)
        end

        --------------------------------------------------------------------
        h:section("[4] the quarantine, and the packs it is holding for")
        --------------------------------------------------------------------
        local reclaimable, noStamp, intact, oldest = 0, 0, 0, nil
        local orphanPacks = {}
        for _, rec in pairs(orphans) do
            if type(rec) == "table" then
                orphanPacks[tostring(rec.pack or rec.def or "unattributed")] = true
                local at = tonumber(rec.orphanedAt)
                if at then
                    if oldest == nil or at < oldest then oldest = at end
                else
                    noStamp = noStamp + 1
                end
                if rec.buildId ~= nil and rec.pos ~= nil and rec.state ~= nil then
                    intact = intact + 1
                end
                if type(rec.buildId) == "string" and byBuildId[rec.buildId] then
                    reclaimable = reclaimable + 1
                end
            end
        end
        h:value("quarantined records whose bytes are intact", intact .. " of " .. nOrph)
        h:value("quarantined records with no orphanedAt", noStamp)
        h:value("oldest quarantine", oldest and string.format("%d s ago (%s)",
            os.time() - oldest, os.date("%Y-%m-%d %H:%M:%S", oldest)) or "n/a")
        h:value("packs the quarantine is holding for",
            nOrph > 0 and table.concat(sortedKeys(orphanPacks), ", ") or "none")

        --------------------------------------------------------------------
        h:section("[5] what ORPHAN_GRACE_SCANS and ORPHAN_MAX actually did")
        --------------------------------------------------------------------
        local grace = upvalue(event.__scanPump, "ORPHAN_GRACE_SCANS")
        local max   = upvalue(event.__scanPump, "ORPHAN_MAX")
        local scans = tonumber(RT and RT.world and RT.world.scans) or 0
        local pruned = (RT and RT.world and RT.world.pruned) == true
        h:value("ORPHAN_GRACE_SCANS (live)", tostring(grace or ("unreadable — documented as " .. DOC_GRACE_SCANS)))
        h:value("ORPHAN_MAX (live)", tostring(max or ("unreadable — documented as " .. DOC_ORPHAN_MAX)))
        h:value("scans this world (gate.scans)", scans)
        h:value("the one pass has run (gate.pruned)", tostring(pruned))
        grace = tonumber(grace) or DOC_GRACE_SCANS
        max   = tonumber(max) or DOC_ORPHAN_MAX
        if not pruned then
            local left = math.max(0, grace - scans)
            h:warn("THE PASS HAS NOT RUN YET IN THIS WORLD, so the numbers above describe what a "
                .. "PREVIOUS session left behind, not what this one decided. %d more scan(s) to "
                .. "go — about %.0f s. TO OPEN IT: wait, and run this hook again; the delta "
                .. "between the two runs IS the round trip.", left, left * SCAN_MS / 1000)
        else
            h:pass("the one pass per world load has run: it waited %d scans (~%.0f s) so that a "
                .. "pack defining its buildings lazily, or from its own world.ready handler, had "
                .. "spoken before anything was judged unclaimed.", grace, grace * SCAN_MS / 1000)
        end
        if nOrph > max then
            h:fail("the quarantine holds %d records and the cap is %d, so the cap has DELETED "
                .. "records permanently — the only destructive act in core/event.lua. The "
                .. "[event] log line above says how many and why.", nOrph, max)
        else
            h:pass("the quarantine holds %d of a %d cap, so the ONE destructive path in this "
                .. "file has not been taken and no player record has been deleted.", nOrph, max)
        end

        --------------------------------------------------------------------
        h:section("[6] THE ASSERTION: an absent pack's record was kept, not destroyed")
        --------------------------------------------------------------------
        h:value("core.reload KEEP holds object_manager",
            tostring(reload.KEEP and reload.KEEP["palforge.core.object_manager"] == true))
        if not (reload.KEEP and reload.KEEP["palforge.core.object_manager"]) then
            h:fail("object_manager is NOT in core/reload's KEEP. That is the F-5 half of this "
                .. "coupling, and without it an F9 unclaims every pack's definitions — after "
                .. "which ORPHAN_GRACE_SCANS is all that stands between a reload and a MASS "
                .. "QUARANTINE of the records in this file. Read core/event.lua's header.")
        end
        h:value("building definitions registered right now", countPairs(om.all("building")))
        h:value("build ids claimed right now", countPairs(byBuildId))

        if pruned and unclaimed > 0 then
            h:fail("the pass has run and %d record(s) are STILL in `entities` with a build id "
                .. "nothing claims. They should have been moved to `orphans` (or migrated). "
                .. "Either the pass raised — look for `world records: the orphan pass failed` "
                .. "above — or they were written after it ran, which is harmless and will be "
                .. "swept on the next world load.", unclaimed)
        elseif pruned then
            h:pass("no live record is unclaimed: every record in `entities` names a build id a "
                .. "registered definition claims this session.")
        end
        if pruned and reclaimable > 0 then
            h:fail("%d quarantined record(s) name a build id that IS claimed right now. The pass "
                .. "restores before it quarantines, so these should have been moved back into "
                .. "`entities` and the player's structures should have their state again.",
                reclaimable)
        elseif nOrph > 0 and pruned then
            h:pass("QUARANTINE-NOT-DELETE, CONFIRMED AGAINST A REAL SAVE: %d record(s) belonging "
                .. "to %s are held in this file with their positions and their state tables "
                .. "intact, after a pass that had every opportunity to drop them. Re-install the "
                .. "pack, or re-register the id, and the next pass moves them back by itself.",
                nOrph, table.concat(sortedKeys(orphanPacks), ", "))
        elseif nOrph == 0 then
            h:note("the quarantine is empty, so the KEPT-not-deleted claim is not exercised in "
                .. "this save. TO EXERCISE IT deliberately and reversibly: publish a native "
                .. "building (require('palforge.native.buildings').publish('WorkBench')), let a "
                .. "scan persist a record for a real workbench, then RESTART the game WITHOUT "
                .. "publishing it, and run this hook again ~30 s after the load. The record must "
                .. "be in `orphans` and not gone. Publishing again and reloading restores it, "
                .. "which is the other half of the round trip.")
        end

        --------------------------------------------------------------------
        h:section("[7] the delta since the last run of this hook")
        --------------------------------------------------------------------
        if prev and prev.saveId == saveId then
            local dEnt, dOrph = nEnt - prev.entities, nOrph - prev.orphans
            local dTotal = (nEnt + nOrph) - (prev.entities + prev.orphans)
            h:value("entities", string.format("%d -> %d  (%+d)", prev.entities, nEnt, dEnt))
            h:value("orphans", string.format("%d -> %d  (%+d)", prev.orphans, nOrph, dOrph))
            h:value("total records", string.format("%+d", dTotal))
            if dEnt < 0 and dOrph == -dEnt then
                h:pass("THE ROUND TRIP, WATCHED: %d record(s) moved out of `entities` and the "
                    .. "SAME number arrived in `orphans`. Nothing was destroyed in between; the "
                    .. "pass is a move.", -dEnt)
            elseif dOrph < 0 and dEnt == -dOrph then
                h:pass("THE RESTORE HALF, WATCHED: %d record(s) came BACK out of quarantine into "
                    .. "`entities` — a definition claimed their build id again.", -dOrph)
            elseif dTotal < 0 then
                h:fail("%d record(s) vanished from the file between the two runs, and the only "
                    .. "code path that deletes is the ORPHAN_MAX cap (%d) or an unreadable "
                    .. "entry. Neither should apply here.", -dTotal, max)
            end
        elseif prev then
            h:note("the previous run was against save %q and this one is %q, so there is no delta "
                .. "to take.", tostring(prev.saveId), saveId)
        else
            h:note("no previous run to compare against. Run this hook again after the pass (see "
                .. "[5]) and the delta prints here.")
        end
        _G[SNAP] = { at = os.time(), saveId = saveId, entities = nEnt, orphans = nOrph }
    end,
}
