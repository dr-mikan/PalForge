-- test/hooks/building-record-orphans — THE QUARANTINE ROUND TRIP, AGAINST A REAL SAVE.
--
-- plan/TODO.md Foundations / The id model / F-7, whose "Still owed" is one sentence: *"The round
-- trip has never been run against a real save file."* It has been run headlessly — the attest
-- pass's own `test.run()` printed `world records: 0 restored, 1 quarantined (unattributed), 0
-- unreadable dropped, 0 live` against this working tree's `state/entities_world.json` — and that
-- file is the FALLBACK bucket, written by a session that could not read a save name. A real save
-- has a directory of its own, and nothing has ever looked at one.
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
-- and has not got there yet, an id is mid-rename. So an unclaimed record is MOVED to the
-- `orphans` section with an `orphanedAt`, keeps its bytes, and moves back by itself the moment a
-- definition claims its build id again. One pass per world load, after a 60-scan (~30 s) grace
-- period.
--
-- ⚠️ TWO THINGS CHANGED UNDER THIS HOOK AND IT WAS REWRITTEN FOR BOTH.
--
-- (1) FORMAT 3 — ONE FILE PER MOD ID, PER SAVE. `state/entities_<saveId>.json` became
--     `state/<saveId>/<packId>.json`, plus `_unowned.json` for records no pack can be attributed
--     to. So this hook no longer reads a file: it reads core.state's MERGED view (the same
--     `{ entities, orphans }` the runtime holds) and asks core.state per pack for the file
--     behind it. And it prints something it could not print before — WHICH PACK DOCUMENTS WERE
--     LOADED AT ALL. That is not trivia: not loading a document is now the mechanism that
--     protects an absent pack's records. A pack nothing registers for is never opened, so
--     nothing this session can quarantine it, drop it or overwrite it.
--
-- (2) R-1 — A MISS QUARANTINES TOO. The scan's miss sweep used to DELETE a record whose actor
--     had not been in `FindAllOf("PalBuildObject")` for six consecutive scans (three seconds).
--     It now quarantines it with `why = "missing"`, and the scan's bind path restores it on
--     sight. So `orphans` holds two populations with two very different meanings and this hook
--     counts them apart:
--         why = "unclaimed"   the pack is not loaded today          (the F-7 population)
--         why = "missing"     the ACTOR was not in the last sweeps  (the R-1 population)
--     A large and GROWING "missing" count while the player walks around is the signal that
--     Palworld streams base actors out by proximity — which is what hook
--     `building-actor-streaming` measures directly, and what R-1 was written without.
--
-- THE ASSERTION THAT MATTERS IS STILL A NEGATIVE: a record whose pack is merely NOT LOADED THIS
-- SESSION must still be there when the pass has finished. Everything else this hook prints —
-- the counts, the owners, the reasons — is context for that one line.
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
-- READ-ONLY, and more carefully than that phrase usually means. `state.world()` hands back the
-- runtime's LIVE merged view — the very tables core/event is mutating — so a write here would be
-- a write into the player's records and would be flushed to disk by the next 10 s batch. Nothing
-- below assigns into any table it reads. `writes = false` is therefore a promise about this
-- file's code, not a property of the API it uses.
local hooks = require("palforge.test.hooks")

local SNAP = "__PalForgeHookOrphanSnapshot"

-- The values core/event.lua declares. Read out of the LIVE closures below and compared against
-- these, because a hook that prints its own copy of a constant is a hook that will one day
-- disagree with the code it is measuring and say nothing about it.
local DOC_GRACE_SCANS = 60      -- core/event.lua, ~30 s at SCAN_MS = 500
local DOC_ORPHAN_MAX  = 4096    -- core/event.lua, and PER PACK FILE since format 3
local DOC_FORMAT      = 3       -- core/state.lua's on-disk format
local SCAN_MS         = 500

-- Pull a named upvalue out of a live closure, searching function-valued upvalues to `depth`.
-- (The same helper as test/hooks/building_runtime_reload.lua, and deliberately a copy: a hook
-- file returns nothing, so there is no module for two of them to share, and fifteen lines of
-- pure Lua duplicated is cheaper than a fifth module in a directory whose whole contract is
-- "one file per measurement".)
--
-- ORPHAN_GRACE_SCANS and ORPHAN_MAX are module-locals of core/event.lua and neither is exported.
-- They are reachable from `M.__scanPump` at nesting depths 1 and 2 (__scanPump -> scanOnce ->
-- pruneOrphans), which is why the default is 4. (REC_VERSION used to be read here too. It is
-- gone: the per-record `v` became the document header's `format`, which is core.state's, and a
-- hook reaching into a closure for a constant that has moved modules would have printed
-- "unreadable" forever without saying why.)
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

-- Every pack id this session could have state for, from three independent sources, merged and
-- sorted. THREE, because each answers a different question and the interesting cases are exactly
-- where they disagree: object_manager knows who has DEFINED something, core/event knows whose
-- document it ASKED FOR, and the records themselves name the pack they were attributed to —
-- which is the only one of the three that can name a pack that is no longer installed.
local function packUniverse(om, asked, w)
    local set = {}
    if type(om.packs) == "function" then
        local ok, list = pcall(om.packs)
        if ok and type(list) == "table" then
            for _, p in ipairs(list) do set[tostring(p)] = true end
        end
    end
    for p in pairs(asked or {}) do set[tostring(p)] = true end
    if w then
        for _, section in ipairs({ w.entities, w.orphans }) do
            for _, rec in pairs(section or {}) do
                if type(rec) == "table" and type(rec.pack) == "string" then set[rec.pack] = true end
            end
        end
    end
    return sortedKeys(set)
end

hooks.declare{
    id    = "building-record-orphans",
    item  = "Foundations / The id model / F-7",
    needs = { world = true },
    desc  = "the orphan quarantine round trip against a real save: which pack files loaded, what "
         .. "had no owner, what was quarantined and why, and that nothing belonging to an absent "
         .. "pack was lost",
    run = function(h)
        local event   = require("palforge.core.event")
        local spatial = require("palforge.core.spatial")
        local om      = require("palforge.core.object_manager")
        local reload  = require("palforge.core.reload")

        local RT   = _G.__PalForgeBuildingRegistry
        local prev = _G[SNAP]

        local okS, state = pcall(require, "palforge.core.state")
        if not okS then
            h:fail("core.state would not load (%s), so there is no store to report on. That is a "
                .. "finding about the deploy rather than about the quarantine.", tostring(state))
            return
        end

        --------------------------------------------------------------------
        h:section("[1] which save, and which directory is its own")
        --------------------------------------------------------------------
        local saveId = spatial.saveId()
        h:value("spatial.saveId()", saveId)
        h:value("state directory", (type(state.saveDir) == "function" and state.saveDir() or saveId)
            .. "/   (under <Mods>/PalForge/state/)")
        h:value("format this build writes", tostring(state.FORMAT or DOC_FORMAT))
        if state.FORMAT and state.FORMAT ~= DOC_FORMAT then
            h:note("core.state declares FORMAT = %s and this hook's header says %d. The header "
                .. "needs a line; nothing below depends on the number.",
                tostring(state.FORMAT), DOC_FORMAT)
        end
        if saveId == "world" then
            h:warn("THIS IS THE FALLBACK BUCKET, not this save's own directory. core/spatial reads "
                .. "GetSelectedWorldSaveDirectoryName / GetSelectedWorldName off PalGameInstance "
                .. "and falls back to the single \"world\" bucket when neither answers — which is "
                .. "the state every save shared before `spatial-saveid` was closed. Everything "
                .. "below is still a real measurement of the quarantine, but it is being made "
                .. "against a directory that MORE THAN ONE SAVE may have written to, so a record "
                .. "with no owner here may simply belong to a different save. That is worth its "
                .. "own line in plan/TODO.md if it reproduces: `spatial-saveid` is listed as "
                .. "Closed.")
        else
            h:pass("the save id resolved to a per-save name, so this directory belongs to this "
                .. "save alone — which is what `spatial-saveid` closed and what has never been "
                .. "seen from a hook.")
        end

        local w = state.world()
        if type(w) ~= "table" then
            h:fail("state.world() did not answer with a table. Nothing below can be measured.")
            return
        end
        local entities = type(w.entities) == "table" and w.entities or {}
        local orphans  = type(w.orphans) == "table" and w.orphans or {}
        local nEnt, nOrph = countPairs(entities), countPairs(orphans)

        --------------------------------------------------------------------
        h:section("[2] which pack documents were LOADED — and which were not")
        --------------------------------------------------------------------
        -- THE HEART OF THE FORMAT-3 HALF. A document nothing asked for is not read, not
        -- rewritten and not judged, so an uninstalled pack's records are protected by the
        -- strongest possible mechanism: nothing this session ever opens the file.
        --
        -- ⚠️ AND REPORTING ON IT MUST NOT OPEN IT. `state.stats(p)` and `state.isLoaded(p)`
        -- both answer out of memory and neither calls loadPack, which is what makes this
        -- section readable without falsifying itself — a hook that loaded every document in
        -- order to say which documents were loaded would answer "all of them", every time.
        local asked = (RT and RT.store and RT.store.packsAsked) or {}
        local universe = packUniverse(om, asked, w)
        h:value("pack documents asked for this world", countPairs(asked))
        if #universe == 0 then
            h:note("no pack has defined a building, asked for a document, or left a record. With "
                .. "zero registered building definitions PalForge opens no file and creates no "
                .. "directory at all — that is F-8 working, not a fault.")
        end
        for _, p in ipairs(universe) do
            local loaded = asked[p] == true
            local isLoaded = (type(state.isLoaded) == "function") and state.isLoaded(p) or nil
            local live, quar = 0, 0
            for _, rec in pairs(entities) do
                if type(rec) == "table" and (rec.pack or "_unowned") == p then live = live + 1 end
            end
            for _, rec in pairs(orphans) do
                if type(rec) == "table" and (rec.pack or "_unowned") == p then quar = quar + 1 end
            end
            local path
            if type(state.stats) == "function" then
                local okT, s = pcall(state.stats, p)
                if okT and type(s) == "table" then path = s.path end
            end
            h:value(string.format("pack %-22s", p), string.format(
                "%s | %d live, %d quarantined | %s",
                loaded and "LOADED    " or "not loaded",
                live, quar, tostring(path or "(no path)")))
            if isLoaded ~= nil and isLoaded ~= loaded then
                h:note("core/event thinks pack %q was %s and core.state says %s. They are two "
                    .. "different questions — event records what it ASKED for this world, state "
                    .. "records what it holds — so a disagreement here means a load was refused; "
                    .. "look for the warn line naming the reason.", p,
                    loaded and "asked for" or "never asked for", tostring(isLoaded))
            end
        end
        h:value("records in `entities`", nEnt)
        h:value("records in `orphans`", nOrph)

        --------------------------------------------------------------------
        h:section("[3] every live record, by owner and claim")
        --------------------------------------------------------------------
        -- "Claimed" is the ONE question the prune asks: is this record's resolved build id in
        -- Registry.byBuildId, which refreshDefs rebuilds from object_manager on every scan.
        local byBuildId = (RT and RT.byBuildId) or {}
        local junk, withDef, withPack, withAlt, unclaimed = 0, 0, 0, 0, 0
        local unclaimedKeys, unclaimedPacks = {}, {}
        for k, rec in pairs(entities) do
            if type(rec) ~= "table" then
                junk = junk + 1
            else
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
        if nEnt > 0 and withPack < nEnt then
            h:note("%d of %d live record(s) name no pack, so they are being held in _unowned.json. "
                .. "That is the MIGRATION BUCKET and it drains by itself: `def` and `pack` are "
                .. "stamped on the first scan that BINDS a record, so every record written before "
                .. "this build carries neither, and the next flush after each bind partitions it "
                .. "into its owner's file. Stand near the structures and the number falls.",
                nEnt - withPack, nEnt)
        end
        if withAlt > 0 then
            h:note("%d record(s) still carry `altKeys` — written by persist() and read by nothing "
                .. "since the port. It is removed ON CONTACT by stampRecord rather than by "
                .. "rewriting the file, which is why it survives until its structure is bound by "
                .. "a scan; core.state also drops it on every write. (The per-record `v` is NOT "
                .. "counted here any more and its absence is not a finding: the version became "
                .. "the document header's `format`, so core.state strips `v` on write and puts "
                .. "the current one back on read. Every in-memory record carries one.)", withAlt)
        end

        --------------------------------------------------------------------
        h:section("[4] the quarantine: two populations, two meanings (R-1)")
        --------------------------------------------------------------------
        local reclaimable, noStamp, intact, oldest = 0, 0, 0, nil
        local byWhy, orphanPacks = {}, {}
        for _, rec in pairs(orphans) do
            if type(rec) == "table" then
                orphanPacks[tostring(rec.pack or rec.def or "unattributed")] = true
                local why = tostring(rec.why or "(no reason recorded)")
                byWhy[why] = (byWhy[why] or 0) + 1
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
        for _, why in ipairs(sortedKeys(byWhy)) do
            h:value("quarantined, why = " .. why, byWhy[why])
        end
        h:value("quarantined records whose bytes are intact", intact .. " of " .. nOrph)
        h:value("quarantined records with no orphanedAt", noStamp)
        h:value("oldest quarantine", oldest and string.format("%d s ago (%s)",
            os.time() - oldest, os.date("%Y-%m-%d %H:%M:%S", oldest)) or "n/a")
        h:value("packs the quarantine is holding for",
            nOrph > 0 and table.concat(sortedKeys(orphanPacks), ", ") or "none")
        local nMissing = byWhy["missing"] or 0
        if nMissing > 0 then
            h:note("⚠️ %d record(s) are quarantined as why=\"missing\" — their ACTORS were not in "
                .. "FindAllOf for six consecutive scans (3 s). BEFORE R-1 EVERY ONE OF THESE "
                .. "WOULD HAVE BEEN DELETED OUTRIGHT. Whether that is a demolished structure or "
                .. "a base the player walked away from is exactly what hook "
                .. "`building-actor-streaming` measures; run it next. Either way the record is "
                .. "here, and the scan's bind path puts it back the moment the actor is seen "
                .. "again.", nMissing)
        end
        if noStamp > 0 and nOrph > 0 then
            h:note("%d quarantined record(s) carry no orphanedAt, so they were written by a build "
                .. "older than the stamp. They sort as OLDEST under the cap, which is the "
                .. "conservative direction only if they really are old — they are.", noStamp)
        end

        --------------------------------------------------------------------
        h:section("[5] what ORPHAN_GRACE_SCANS and the PER-PACK cap actually did")
        --------------------------------------------------------------------
        local grace = upvalue(event.__scanPump, "ORPHAN_GRACE_SCANS")
        local max   = upvalue(event.__scanPump, "ORPHAN_MAX")
        local scans = tonumber(RT and RT.world and RT.world.scans) or 0
        local pruned = (RT and RT.world and RT.world.pruned) == true
        h:value("ORPHAN_GRACE_SCANS (live)", tostring(grace or ("unreadable — documented as " .. DOC_GRACE_SCANS)))
        h:value("ORPHAN_MAX (live, PER PACK FILE)", tostring(max or ("unreadable — documented as " .. DOC_ORPHAN_MAX)))
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
        -- THE CAP IS PER PACK NOW, so it has to be checked per pack. Under one shared file a pack
        -- that had been uninstalled for a year could push ANOTHER pack's records over the edge
        -- and delete them; each document has its own budget.
        local overCap = {}
        for _, p in ipairs(universe) do
            local n = 0
            for _, rec in pairs(orphans) do
                if type(rec) == "table" and (rec.pack or "_unowned") == p then n = n + 1 end
            end
            if n > max then overCap[#overCap + 1] = string.format("%s (%d)", p, n) end
        end
        if #overCap > 0 then
            h:fail("these pack documents hold more quarantined records than the per-pack cap of "
                .. "%d — %s — so the cap has DELETED records permanently. That is the only "
                .. "destructive act in core/event.lua; the [event] log line above says how many "
                .. "and for which pack.", max, table.concat(overCap, ", "))
        else
            h:pass("no pack document is over the %d-record cap, so the ONE destructive path in "
                .. "core/event.lua has not been taken and no player record has been deleted. And "
                .. "the cap being per pack is what stops one uninstalled mod's history from "
                .. "evicting another mod's structures.", max)
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
                .. "QUARANTINE of the records in this save. Read core/event.lua's header.")
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
                .. "to %s are held with their positions and their state tables intact, after a "
                .. "pass that had every opportunity to drop them. Re-install the pack, or "
                .. "re-register the id, and the next pass moves them back by itself.",
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
            local dMiss  = nMissing - (prev.missing or 0)
            h:value("entities", string.format("%d -> %d  (%+d)", prev.entities, nEnt, dEnt))
            h:value("orphans", string.format("%d -> %d  (%+d)", prev.orphans, nOrph, dOrph))
            h:value("of those, why=\"missing\"", string.format("%d -> %d  (%+d)",
                prev.missing or 0, nMissing, dMiss))
            h:value("total records", string.format("%+d", dTotal))
            if dEnt < 0 and dOrph == -dEnt then
                h:pass("THE ROUND TRIP, WATCHED: %d record(s) moved out of `entities` and the "
                    .. "SAME number arrived in `orphans`. Nothing was destroyed in between; the "
                    .. "pass is a move.", -dEnt)
            elseif dOrph < 0 and dEnt == -dOrph then
                h:pass("THE RESTORE HALF, WATCHED: %d record(s) came BACK out of quarantine into "
                    .. "`entities` — either a definition claimed their build id again, or their "
                    .. "actor turned up in a scan and the bind path took them back (R-1).", -dOrph)
            elseif dTotal < 0 then
                h:fail("%d record(s) vanished between the two runs. Since R-1 the only code path "
                    .. "that deletes is the PER-PACK ORPHAN_MAX cap (%d) or an unreadable entry; "
                    .. "neither should apply here, and a miss no longer deletes anything.",
                    -dTotal, max)
            end
            if dMiss > 0 then
                h:note("%d MORE record(s) are quarantined as \"missing\" than last run. If you "
                    .. "moved between the two runs, that is very likely the game disposing base "
                    .. "actors behind you — the exact behaviour R-1 was written for, and the "
                    .. "exact thing `building-actor-streaming` measures with a distance "
                    .. "attached.", dMiss)
            end
        elseif prev then
            h:note("the previous run was against save %q and this one is %q, so there is no delta "
                .. "to take.", tostring(prev.saveId), saveId)
        else
            h:note("no previous run to compare against. Run this hook again after the pass (see "
                .. "[5]) and the delta prints here.")
        end
        _G[SNAP] = { at = os.time(), saveId = saveId, entities = nEnt, orphans = nOrph,
                     missing = nMissing }
    end,
}
