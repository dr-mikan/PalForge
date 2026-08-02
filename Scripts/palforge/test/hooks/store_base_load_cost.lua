-- test/hooks/store-base-load-cost — WHAT DOES A REAL BASE COST TO LOAD?
--
-- The efficiency half of the format-3 pass, measured where it is spent instead of where it was
-- designed. Every number in the design's cost table was taken on WSL2/ext4, in a bare lua5.4,
-- against SYNTHETIC record sets of 100 / 500 / 2000 built by a script:
--
--   records   format 2, one file      format 3, one pack installed
--      100    20,502 B / 5.86 ms      5,351 B / 1.03 ms
--      500   102,332 B / 28.61 ms    26,419 B / 4.97 ms      <- "5.8x", the headline
--     2000  409,061 B / 117.00 ms   105,579 B / 19.90 ms
--
-- Three things about that table are worth saying out loud before anyone quotes it again. It was
-- measured on a filesystem Palworld does not run on. It was measured in a process that is not
-- doing anything else. And THE LARGEST RECORD SET THIS TREE HAS EVER ACTUALLY PRODUCED IS 18
-- (dumps/state/entities_world.json) — the 500-record row is a projection, chosen because
-- Palworld's own build cap (FPalOptionWorldSettings.MaxBuildingLimitNum, Pal.hpp:5497) bounds
-- the count and nobody could read its numeric default off the dumps. So the honest form of the
-- claim is "the split is 5.8x cheaper at a scale nobody has reached", and this hook exists to
-- replace the projection with a base.
--
-- WHAT IT MEASURES, all of it read-only:
--   [1] the base itself — how many PalBuildObject actors are in memory, how many PalForge is
--       tracking, how many building definitions are registered and by which packs
--   [2] the store's files — one per mod id, with the bytes each one costs, straight off disk
--   [3] the decode, timed on the REAL BYTES of each real file, and the encode that a flush pays
--   [4] the counterfactual: what the same records would have cost as ONE format-2 file, which
--       is the number the split is 5.8x better than
--   [5] the 500 ms scan — FindAllOf plus the per-actor key that runs beside it, because that
--       cost is paid twice a second forever while the format-3 read is paid once per world
--
-- ⚠️ THE ANSWER MAY WELL BE "ALMOST NOTHING", AND THAT IS A RESULT. With no registered building
-- definition there are no files at all (F-8), so the store costs a real base exactly zero
-- milliseconds to load — which is the strongest possible form of the efficiency claim and the
-- one a stock session will print. To measure a base that costs something, publish a definition
-- first: require('palforge.native.buildings').publish('WorkBench') in a base with a workbench.
-- ⚠️ THAT CALL STARTS WRITING STATE FOR THIS SAVE. It is the operator's decision, which is why
-- it is an instruction here and not a line of this hook.
--
-- READ-ONLY IN THE STRONG SENSE. It calls FindAllOf, reads file bytes with io.open, and runs
-- json.decode / json.encode over values it decoded itself. It does not call db.set, db.save,
-- state.flush, state.loadPack, state.unload or state.__reset — a hook that measured the load
-- cost by causing a load would change the thing it was measuring, and unload() in particular
-- would drop the merged view core/event holds every live structure's record in.
local hooks = require("palforge.test.hooks")

local ITERS_MAX = 20        -- timing repeats for a small file
local ITERS_MIN = 3         -- ...and for a large one; decode is linear, the repeat is for noise
local BIG_BYTES = 200000    -- past this, use ITERS_MIN

local function countPairs(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function readBytes(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

-- Median of a small sample, not the mean: one scheduler hiccup inside a running game moves a
-- mean by more than the thing being measured. The samples are printed too, because a spread
-- that is wider than the value is itself the finding.
local function timeIt(fn, iters)
    local samples = {}
    for i = 1, iters do
        local t0 = os.clock()
        fn()
        samples[i] = (os.clock() - t0) * 1000
    end
    table.sort(samples)
    local mid = samples[math.ceil(#samples / 2)]
    return mid, samples[1], samples[#samples]
end

hooks.declare{
    id    = "store-base-load-cost",
    item  = "Foundations / F-7 — the format-3 store",
    needs = { world = true },
    desc  = "what a REAL base costs the format-3 store to load: the files, their bytes, the "
         .. "decode timed on those bytes, and what the same records would have cost as one file",
    run = function(h)
        local state = require("palforge.core.state")
        local file  = require("palforge.utils.file")
        local json  = require("palforge.utils.json")
        local om    = require("palforge.core.object_manager")
        local uo    = require("palforge.core.uobject")

        local RT = _G.__PalForgeBuildingRegistry

        --------------------------------------------------------------------
        h:section("[1] the base, and what PalForge has been asked to track")
        --------------------------------------------------------------------
        local actors, nActors = nil, 0
        local tFind, tFindLo, tFindHi = timeIt(function()
            local ok, a = pcall(FindAllOf, "PalBuildObject")
            actors = (ok and type(a) == "table") and a or nil
        end, 5)
        nActors = actors and #actors or 0
        h:value("PalBuildObject actors in memory", nActors)
        h:value("FindAllOf('PalBuildObject') costs", string.format("%.2f ms (%.2f..%.2f)",
            tFind, tFindLo, tFindHi))

        local defs = om.all and om.all("building") or {}
        local nDefs = countPairs(defs)
        h:value("REGISTERED Building definitions", nDefs)
        local byPack = {}
        for id in pairs(defs) do
            local ok, p = pcall(om.owner, "building", id)
            local pack = (ok and type(p) == "string") and p or "(unattributed)"
            byPack[pack] = (byPack[pack] or 0) + 1
        end
        local packNames = {}
        for p in pairs(byPack) do packNames[#packNames + 1] = p end
        table.sort(packNames)
        for _, p in ipairs(packNames) do
            h:log("  pack %-20s declares %d building definition(s)", p, byPack[p])
        end

        h:value("live PalForge building instances", countPairs(RT and RT.instances))
        local w = state.world()
        h:value("records in the merged view (entities)", countPairs(w.entities))
        h:value("records in the merged view (orphans)", countPairs(w.orphans))

        if nDefs == 0 then
            h:pass("ZERO REGISTERED BUILDING DEFINITIONS, SO THE STORE COSTS THIS BASE ZERO "
                .. "MILLISECONDS AND ZERO BYTES TO LOAD. There are %d structures standing "
                .. "here and PalForge opened no file for any of them. That is F-8 and the "
                .. "format-3 lazy load working together, and it is the row of the design's "
                .. "cost table that a stock session actually lands on.", nActors)
            h:note("TO MEASURE A BASE THAT COSTS SOMETHING: from the Lua console run "
                .. "require('palforge.native.buildings').publish('WorkBench') while standing in "
                .. "a base with a workbench, wait one 500 ms scan, and run this hook again. "
                .. "⚠️ That call starts WRITING state for this save and there is no unpublish "
                .. "that un-writes it.")
        end

        --------------------------------------------------------------------
        h:section("[2] the files — one per mod id")
        --------------------------------------------------------------------
        local audit = state.audit()
        h:value("save directory", audit.save)
        h:value("packs the store knows about", #audit.packs)
        if audit.migrated then
            h:value("migrated from", tostring(audit.migrated.from))
            h:value("  records", tostring(audit.migrated.records))
            h:value("  fingerprint taken from", tostring(audit.migrated.fingerprintOf))
        end

        local files, totalBytes, totalRecords = {}, 0, 0
        for _, st in ipairs(audit.packs) do
            local text = readBytes(st.path)
            local n = text and #text or nil
            h:log("  %-18s loaded=%-5s buildings=%-4d orphans=%-4d data=%-3d ledger=%-3d %s",
                st.pack, tostring(st.loaded), st.buildings, st.orphans, st.data, st.ledger,
                n and (n .. " bytes on disk") or "NO FILE ON DISK")
            if st.lastError then h:log("      lastError: %s", tostring(st.lastError)) end
            if text then
                files[#files + 1] = { pack = st.pack, text = text, bytes = n, path = st.path }
                totalBytes = totalBytes + n
                totalRecords = totalRecords + st.buildings + st.orphans
            end
        end
        h:value("total bytes across every pack file", totalBytes)
        h:value("total persisted records", totalRecords)

        -- The one number the whole design turns on, and it is a NEGATIVE for an absent pack.
        local notLoaded = 0
        for _, st in ipairs(audit.packs) do if not st.loaded then notLoaded = notLoaded + 1 end end
        h:value("pack files this session did NOT open", notLoaded)
        if notLoaded > 0 then
            h:pass("%d pack file(s) were never opened this session and cost 0 bytes and 0 ms. "
                .. "Under format 2 those records lived in the SAME file as everyone else's and "
                .. "were decoded on every world load whether or not the pack that wrote them "
                .. "was installed — that is the isolation, expressed as work not done.", notLoaded)
        end

        if #files == 0 then
            h:note("there are no state files for this save, so [3] and [4] have nothing to "
                .. "time. Everything above is still the answer: the cost is zero.")
        end

        --------------------------------------------------------------------
        h:section("[3] the decode, timed on those exact bytes")
        --------------------------------------------------------------------
        local decodeTotal, encodeTotal, biggest = 0, 0, nil
        for _, f in ipairs(files) do
            local iters = (f.bytes > BIG_BYTES) and ITERS_MIN or ITERS_MAX
            local doc
            local dMs, dLo, dHi = timeIt(function() doc = json.decode(f.text) end, iters)
            if type(doc) ~= "table" then
                h:fail("%s's own file (%d bytes) does not decode. The store would quarantine it "
                    .. "verbatim on the next write and start that pack empty — which is the "
                    .. "policy working, but this is the first time it has been seen on a real "
                    .. "file and it belongs in plan/TODO.md.", f.pack, f.bytes)
            else
                local eMs = timeIt(function() json.encode(doc) end, iters)
                decodeTotal = decodeTotal + dMs
                encodeTotal = encodeTotal + eMs
                if not biggest or f.bytes > biggest.bytes then biggest = f end
                h:log("  %-18s %7d B   decode %6.2f ms (%.2f..%.2f)   encode %6.2f ms   [%d runs]",
                    f.pack, f.bytes, dMs, dLo, dHi, eMs, iters)
            end
        end
        if #files > 0 then
            h:value("decode, every pack file", string.format("%.2f ms", decodeTotal))
            h:value("encode, every pack file", string.format("%.2f ms", encodeTotal))
            h:note("the ENCODE number is what one flush costs, and only for the packs that are "
                .. "DIRTY: format 2 re-encoded every pack's records because they shared one "
                .. "file, so one structure changing one field rewrote the lot.")
        end

        --------------------------------------------------------------------
        h:section("[4] what the same records would have cost as ONE file")
        --------------------------------------------------------------------
        -- The counterfactual, built by MERGING the real documents rather than by scaling the
        -- design's table. This is the format-2 shape: every pack's records in one `entities`
        -- map, in one file, decoded in full on every world load.
        if #files < 1 then
            h:note("nothing to merge.")
        else
            local merged = { version = 1, entities = {}, orphans = {} }
            for _, f in ipairs(files) do
                local doc = json.decode(f.text)
                if type(doc) == "table" then
                    for k, rec in pairs(doc.buildings or {}) do
                        -- format 2 carried `pack` and `v` PER RECORD and a position as three
                        -- doubles; that is the 36.2% the split and the integer centimetres
                        -- bought, and a merge that dropped them would understate it.
                        local r = {}
                        for kk, vv in pairs(rec) do r[kk] = vv end
                        r.pack = f.pack
                        r.v    = 2
                        if type(rec.pos) == "table" and rec.pos[1] then
                            r.pos = { x = rec.pos[1] + 0.90282075,
                                      y = rec.pos[2] + 0.81381945,
                                      z = rec.pos[3] + 0.57345892 }
                        end
                        merged.entities[k] = r
                    end
                    for k, rec in pairs(doc.orphans or {}) do merged.orphans[k] = rec end
                end
            end
            local mergedText = json.encode(merged) or ""
            local iters = (#mergedText > BIG_BYTES) and ITERS_MIN or ITERS_MAX
            local mMs = timeIt(function() json.decode(mergedText) end, iters)
            h:value("format-2 equivalent, bytes", #mergedText)
            h:value("format-2 equivalent, decode", string.format("%.2f ms", mMs))
            h:value("format 3, every file", string.format("%d bytes / %.2f ms", totalBytes,
                decodeTotal))
            if #mergedText > 0 and totalBytes > 0 then
                h:value("bytes saved by the split + integer cm",
                    string.format("%.1f%%", 100 * (1 - totalBytes / #mergedText)))
            end
            if decodeTotal > 0 then
                h:value("decode ratio, all packs installed",
                    string.format("%.2fx", mMs / decodeTotal))
            end
            if biggest then
                local bIters = (biggest.bytes > BIG_BYTES) and ITERS_MIN or ITERS_MAX
                local bMs = timeIt(function() json.decode(biggest.text) end, bIters)
                h:value("...and with only '" .. biggest.pack .. "' installed",
                    string.format("%d bytes / %.2f ms", biggest.bytes, bMs))
                if bMs > 0 then
                    h:value("decode ratio, one pack installed",
                        string.format("%.2fx", mMs / bMs))
                end
                h:note("THE SECOND RATIO IS THE ONE THE DESIGN CLAIMED 5.8x FOR, and it is the "
                    .. "realistic one: a player has the packs they have, not all of them. The "
                    .. "first ratio is the worst case — every pack installed — which the design "
                    .. "put at about 2x.")
            end
            h:note("this is a MEASUREMENT AT THIS BASE'S SCALE (%d record(s)), not a refutation "
                .. "or a confirmation of a 500-record projection. At small counts both numbers "
                .. "are dominated by the header and by os.clock's own resolution, and a ratio "
                .. "taken from two sub-millisecond values means very little — which is worth "
                .. "writing down rather than quietly rounding away.", totalRecords)
        end

        --------------------------------------------------------------------
        h:section("[5] the cost that is paid TWICE A SECOND, not once a world")
        --------------------------------------------------------------------
        -- Perspective, and it is the part the design never costed. The store's read happens
        -- once per world load. core/event's scan happens every SCAN_MS = 500 ms for as long as
        -- the world is loaded, and it calls FindAllOf and then uo.key on every actor it got.
        local keyMs = timeIt(function()
            if not actors then return end
            for _, a in ipairs(actors) do pcall(uo.key, a) end
        end, 5)
        h:value(string.format("uo.key over %d actor(s)", nActors),
            string.format("%.2f ms", keyMs))
        h:value("one scan (FindAllOf + keys)", string.format("%.2f ms", tFind + keyMs))
        h:value("...per minute at SCAN_MS=500", string.format("%.0f ms", (tFind + keyMs) * 120))
        h:note("the scan is not this pass's work and nothing here changes it. It is printed "
            .. "because it is the honest denominator: if one world load costs %.2f ms of "
            .. "decoding and every minute of play costs %.0f ms of scanning, then the file "
            .. "format is not where a player's frame time goes, and a future optimisation "
            .. "pass should start with the number above rather than with the one in [3].",
            decodeTotal, (tFind + keyMs) * 120)

        --------------------------------------------------------------------
        h:section("[6] what this run established")
        --------------------------------------------------------------------
        h:log("VALUE structures standing here            = %d", nActors)
        h:log("VALUE registered building definitions     = %d", nDefs)
        h:log("VALUE pack files on disk for this save    = %d", #files)
        h:log("VALUE pack files this session opened      = %d", #audit.packs - notLoaded)
        h:log("VALUE bytes the store read                = %d", totalBytes)
        h:log("VALUE milliseconds the store spent        = %.2f", decodeTotal)
        if totalRecords > 0 then
            h:log("VALUE bytes per record                    = %.0f", totalBytes / totalRecords)
        end
        h:pass("the store's real cost at this base is %d bytes and %.2f ms, across %d file(s). "
            .. "Whatever that number is, it is now a measurement.", totalBytes, decodeTotal,
            #files)
    end,
}
