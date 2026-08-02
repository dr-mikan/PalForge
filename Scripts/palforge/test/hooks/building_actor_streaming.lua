-- test/hooks/building-actor-streaming — DOES FindAllOf STOP RETURNING A BASE THE PLAYER LEFT?
--
-- THE HIGHEST-PRIORITY MEASUREMENT IN THE STORE PASS, and the only one that says whether R-1
-- fixed a live data-loss bug or a latent one.
--
-- WHAT R-1 WAS. core/event.lua's miss sweep counts, per live instance, the consecutive scans in
-- which `FindAllOf("PalBuildObject")` did not return that instance's actor. Past
-- MISS_THRESHOLD = 6 — three seconds at SCAN_MS = 500 — it emitted building.remove and then ran
--
--     loadWorld().entities[key] = nil
--
-- which DELETED the structure's persisted record. FindAllOf enumerates in-memory UObjects and
-- nothing else. So the entire question is whether Palworld keeps a base's actors in memory when
-- the player is not near it.
--
-- WHAT THE SHIPPING BINARY SAYS, and it is suggestive rather than decisive — every line below is
-- STRUCTURAL, read out of dumps/, and NOT ONE OF THEM HAS BEEN MEASURED IN GAME. That is the gap
-- this hook exists to close:
--   * Palworld separates a persistent MODEL from a transient CONCRETE MODEL:
--     FPalMapObjectSaveData{ MapObjectId, Model, ConcreteModel }  (dumps/cxx/Pal.hpp:4639).
--   * OnAvailableConcreteModel / OnNotAvailableConcreteModel delegate PAIRS appear on about ten
--     classes (Pal.hpp:14252-14699). A pair of that shape is what an availability window looks
--     like.
--   * TryGetConcreteModel(EPalMapObjectGetModelOutPinType&, ...) has a `Failed = 1` out-pin
--     (Pal_enums.hpp:2853-2857), so the concrete half is expected to be absent sometimes.
--   * UPalMapObjectConcreteModelBase carries :bDisposed and .GetActor (02_reflection.txt).
-- If those describe proximity streaming, then before R-1 PalForge deleted every structure's pack
-- state about three seconds after the player walked away from the base.
--
-- WHY R-1 SHIPPED WITHOUT WAITING FOR THIS ANSWER. A miss now QUARANTINES the record
-- (`orphans`, `why = "missing"`) instead of deleting it, and the scan's bind path takes it back
-- out on sight. That is correct in both worlds: if streaming happens it converts a silent
-- catastrophe into a bounded, logged, self-reversing move; if it does not, a genuinely
-- demolished structure's record sits in quarantine under a per-pack cap instead of vanishing.
-- This hook decides which of the two sentences goes in the release note — not whether to fix it.
--
-- ⚠️ AND THE SWEEP CANNOT SIMPLY BE SWITCHED OFF EITHER. core/event.lua's own survey (its "NO
-- building.break AND NO building.leftclick" note) settles that the miss sweep is the ONLY
-- destruction signal this build offers: PalBuildObject (22 fns), PalMapObjectModel (18),
-- PalMapObjectConcreteModelBase (25) and PalNetworkPlayerComponent (77) declare no Destroy /
-- Dismantle / Demolish entry between them, and destruction appears only as delegate FIELDS that
-- RegisterHook cannot address by path. So the sweep stays; it just stopped deleting.
--
-- HOW TO GET A MEANINGFUL RUN, and it is the one hook here that needs the player to WALK:
--
--     stand in the middle of a base with several structures
--     pf_hook building-actor-streaming
--     then walk away in a straight line — or fast-travel — and keep going for two minutes
--
-- It prints one line a second: how many PalBuildObject actors FindAllOf returns, how many of the
-- ones it saw at t=0 are still in that list, and how far the player has moved from the base. The
-- answer is the DISTANCE AT WHICH THE COUNT FIRST DROPS. Standing still for two minutes is also
-- a result — it says the count is stable while the player is present, which is the control.
--
-- READ-ONLY. It calls FindAllOf and reads actor locations; it registers nothing, defines
-- nothing, and does not touch the store. What it PRINTS about PalForge's own records is read
-- through core.state's merged view, which is the same table the runtime is already holding —
-- nothing below assigns into it.
local hooks = require("palforge.test.hooks")

-- The declared constants of the thing being measured. Read out of the live module where that is
-- possible (see `upvalue`), and compared against these — a hook that prints its own copy of a
-- constant is a hook that will one day disagree with the code it is measuring and say nothing.
local DOC_MISS_THRESHOLD = 6      -- core/event.lua, consecutive unseen scans before a miss
local DOC_SCAN_MS        = 500    -- core/event.lua, SCAN_MS == M.TICK_MS

local WATCH_SEC  = 180            -- how long the watch runs
local REPORT_SEC = 1.0            -- one line a second, per the item's own wording
local DEAD_MAX   = 10             -- consecutive unanswerable samples before the watch gives up

-- Pull a named upvalue out of a live closure, searching function-valued upvalues to `depth`.
-- (The same helper as building_record_orphans.lua and building_runtime_reload.lua, and
-- deliberately a copy: a hook file returns nothing, so there is no module for two of them to
-- share, and fifteen lines of pure Lua duplicated is cheaper than a fourth module in a directory
-- whose whole contract is "one file per measurement".)
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

-- Every PalBuildObject FindAllOf can see right now, as key -> position. THE SAME CALL THE SCAN
-- MAKES, deliberately: a hook that enumerated some other way would be measuring some other
-- question. Keyed on uo.key(actor) (rule 1 in core/event's header) because UE4SS mints a fresh
-- userdata wrapper per lookup, so the actor table from one sweep is never `==` the one from the
-- next even for the identical engine object.
local function sweep(uo)
    local seen, n = {}, 0
    local okFind, actors = pcall(FindAllOf, "PalBuildObject")
    if not (okFind and type(actors) == "table") then return seen, 0, false end
    for _, actor in ipairs(actors) do
        pcall(function()
            if not (actor and actor:IsValid()) then return end
            local k = uo.key(actor)
            if not k then return end
            local pos
            local okL, loc = pcall(function()
                return actor.K2_GetActorLocation and actor:K2_GetActorLocation()
                    or actor:GetActorLocation()
            end)
            if okL and loc then pos = { x = loc.X, y = loc.Y, z = loc.Z } end
            seen[k] = pos or false
            n = n + 1
        end)
    end
    return seen, n, true
end

local function dist(a, b)
    if not (a and b) then return nil end
    local dx, dy, dz = (a.x - b.x), (a.y - b.y), (a.z - b.z)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

hooks.declare{
    id    = "building-actor-streaming",
    item  = "Foundations / The id model / R-1",
    needs = { world = true, player = true },
    desc  = "does FindAllOf('PalBuildObject') stop returning a base the player has walked away "
         .. "from, and at what distance — the measurement R-1 was written without",
    run = function(h)
        local poll    = require("palforge.core.poll")
        local support = require("palforge.test.support")
        local event   = require("palforge.core.event")
        local uo      = require("palforge.core.uobject")
        local spatial = require("palforge.core.spatial")

        local RT = _G.__PalForgeBuildingRegistry

        --------------------------------------------------------------------
        h:section("[1] what the code under test declares")
        --------------------------------------------------------------------
        local miss = tonumber(upvalue(event.__scanPump, "MISS_THRESHOLD")) or DOC_MISS_THRESHOLD
        local scanMs = tonumber(event.TICK_MS) or DOC_SCAN_MS
        h:value("MISS_THRESHOLD (live)", miss)
        h:value("SCAN_MS (live, = event.TICK_MS)", scanMs)
        h:value("a structure is 'missing' after", string.format("%.1f s of not being in FindAllOf",
            miss * scanMs / 1000))
        if miss ~= DOC_MISS_THRESHOLD then
            h:note("core/event declares MISS_THRESHOLD = %d and this hook's header says %d. The "
                .. "measurement below is still valid; the header needs a line.", miss,
                DOC_MISS_THRESHOLD)
        end

        --------------------------------------------------------------------
        h:section("[2] the baseline: every build actor in memory right now")
        --------------------------------------------------------------------
        local base, n0, findable = sweep(uo)
        if not findable then
            h:fail("FindAllOf('PalBuildObject') did not answer at all, so there is nothing to "
                .. "watch. That is a finding about this session rather than about streaming.")
            return
        end
        local pawn  = support.player()
        local start = support.location(pawn)
        h:value("PalBuildObject actors at t=0", n0)
        h:value("player position at t=0", start
            and string.format("%.0f, %.0f, %.0f", start.x, start.y, start.z) or "unreadable")
        if n0 == 0 then
            h:warn("THERE ARE NO BUILD ACTORS HERE, so walking away from them cannot be "
                .. "measured. TO OPEN IT: stand inside a base with structures in it — a "
                .. "workbench, a chest, a foundation — and run this hook again.")
            return
        end
        -- The centroid is what "away from the base" is measured against. A base is not a point
        -- and the player may start at its edge, so distances below are from here, not from the
        -- player's own starting position.
        local cx, cy, cz, np = 0, 0, 0, 0
        for _, p in pairs(base) do
            if type(p) == "table" then cx, cy, cz, np = cx + p.x, cy + p.y, cz + p.z, np + 1 end
        end
        local centre = np > 0 and { x = cx / np, y = cy / np, z = cz / np } or nil
        h:value("actors with a readable position", np .. " of " .. n0)
        h:value("base centroid", centre
            and string.format("%.0f, %.0f, %.0f", centre.x, centre.y, centre.z) or "unreadable")
        h:value("player's distance from it at t=0", (centre and start)
            and string.format("%.0f cm (%.0f m)", dist(start, centre), dist(start, centre) / 100)
            or "unreadable")

        --------------------------------------------------------------------
        h:section("[3] what PalForge itself is holding for this base")
        --------------------------------------------------------------------
        -- Read through core.state's MERGED view — the same `{ entities, orphans }` the runtime
        -- holds. With no registered building definition there are no records at all, and that is
        -- F-8 working rather than a fault; the note says so.
        local okS, st = pcall(require, "palforge.core.state")
        local w = okS and type(st.world) == "function" and st.world() or nil
        local liveInst = countPairs(RT and RT.instances)
        h:value("live PalForge building instances", liveInst)
        h:value("records in `entities`", w and countPairs(w.entities) or "store unreadable")
        local missing0 = 0
        if w then
            for _, rec in pairs(w.orphans) do
                if type(rec) == "table" and rec.why == "missing" then missing0 = missing0 + 1 end
            end
        end
        h:value("records quarantined as why=\"missing\"", missing0)
        if liveInst == 0 then
            h:note("PalForge is tracking none of these structures, because no REGISTERED "
                .. "definition claims their build ids (F-8: the native catalogs declare without "
                .. "registering). The FindAllOf half below is still the measurement that "
                .. "matters — it is the game's behaviour, not ours. TO SEE R-1 ITSELF FIRE: "
                .. "require('palforge.native.buildings').publish('WorkBench') in a base with a "
                .. "workbench, wait for a scan, then run this hook again. ⚠️ That call starts "
                .. "WRITING state for this save.")
        end

        --------------------------------------------------------------------
        h:section("[4] the watch — now walk away")
        --------------------------------------------------------------------
        h:ask("walk away from this base in a straight line, or fast-travel, and keep going. One "
            .. "line a second prints below for %d s.", WATCH_SEC)
        h:note("STANDING STILL IS ALSO A RESULT: a flat count for %d s says the list is stable "
            .. "while the player is present, which is the control this needs.", WATCH_SEC)
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN building-actor-streaming-watch and -verdict below.")

        local nextAt, ticks   = 0, 0
        local dead            = 0     -- consecutive samples where FindAllOf did not answer
        local firstDrop       = nil   -- { at, dist, kept, count }
        local maxDist         = 0
        local minKept         = n0
        h:beginBlock("watch")
        local armed = poll.every("building-actor-streaming", function(elapsed)
            if elapsed < nextAt and elapsed < WATCH_SEC then return false end
            nextAt = elapsed + REPORT_SEC
            ticks  = ticks + 1

            local now, n, ok = sweep(uo)
            if not ok then
                -- FindAllOf itself stopped answering — a quit to the title, a teardown, a
                -- broken UE4SS callback layer. That is NOT "the actors streamed out", and
                -- counting it as a drop would fabricate the very positive this hook exists to
                -- establish. The sample is discarded and the reason is printed.
                dead = dead + 1
                h:log("WATCH t+%5.1f s  FindAllOf did not answer at all — sample DISCARDED "
                    .. "(this is not a drop; it is the enumeration being unavailable). %d in a "
                    .. "row", elapsed, dead)
                if dead < DEAD_MAX then return false end
                h:endBlock("watch")
                h:beginBlock("verdict")
                h:log("FAIL the enumeration has been unavailable for %d consecutive samples, so "
                    .. "the watch is retiring %.0f s early with NO ANSWER. Nothing about "
                    .. "streaming was measured — the most likely cause is that the world was "
                    .. "left while this was running, in which case simply run it again inside "
                    .. "one session.", dead, WATCH_SEC - elapsed)
                h:endBlock("verdict")
                return true
            end
            dead = 0
            local kept = 0
            for k in pairs(base) do if now[k] ~= nil then kept = kept + 1 end end
            local here = support.location(support.player())
            local d    = (here and centre) and dist(here, centre) or nil
            if d then maxDist = math.max(maxDist, d) end
            if kept < minKept then minKept = kept end
            if kept < n0 and not firstDrop then
                firstDrop = { at = elapsed, dist = d, kept = kept, count = n }
            end

            h:log("WATCH t+%5.1f s  d=%8s  FindAllOf=%4d  of the original %d still there: %d%s",
                elapsed,
                d and string.format("%.0fm", d / 100) or "?",
                n, n0, kept,
                (kept < n0) and string.format("   <-- %d GONE", n0 - kept) or "")

            if elapsed < WATCH_SEC then return false end

            ------------------------------------------------------------
            h:endBlock("watch")
            h:beginBlock("verdict")
            h:log("VALUE watch length                        = %.0f s, %d samples", elapsed, ticks)
            h:log("VALUE furthest the player got             = %.0f m", maxDist / 100)
            h:log("VALUE fewest of the original %3d still in = %d", n0, minKept)
            local w2 = okS and type(st.world) == "function" and st.world() or nil
            local missingNow = 0
            if w2 then
                for _, rec in pairs(w2.orphans) do
                    if type(rec) == "table" and rec.why == "missing" then missingNow = missingNow + 1 end
                end
            end
            h:log("VALUE records quarantined why=\"missing\"   = %d (was %d at t=0)",
                missingNow, missing0)

            if firstDrop then
                h:log("PASS ⚠️ STREAMING IS REAL ON THIS BUILD. FindAllOf('PalBuildObject') "
                    .. "stopped returning %d of the %d structures this base had at t=0, "
                    .. "%.0f s in, at %s from the base centroid. THAT MAKES R-1 A LIVE "
                    .. "DATA-LOSS BUG, NOT A LATENT ONE: before it, every one of those records "
                    .. "was DELETED %.1f s after it left the list, and the player only had to "
                    .. "walk away. The release note says 'fixed', not 'hardened'.",
                    n0 - firstDrop.kept, n0, firstDrop.at,
                    firstDrop.dist and string.format("%.0f m", firstDrop.dist / 100)
                        or "an unreadable distance",
                    miss * scanMs / 1000)
                h:log("NOTE the drop distance above is ONE observation on ONE base. It is the "
                    .. "number to put in the header; it is not a constant to code against, and "
                    .. "nothing in this pass does.")
            elseif maxDist < 5000 then
                h:log("NOTE nothing dropped out, but the player never got further than %.0f m "
                    .. "from the base. That is not a negative answer, it is an unfinished "
                    .. "run — the count is simply stable at close range. Run it again and walk "
                    .. "or fast-travel a long way.", maxDist / 100)
            else
                h:log("PASS ALL %d STRUCTURES STAYED IN FindAllOf for the whole watch, out to "
                    .. "%.0f m. On this build, on this base, the map objects the player left "
                    .. "behind are still in memory — so R-1 was LATENT: the delete could only "
                    .. "have fired on a genuinely destroyed structure. R-1 is still right (a "
                    .. "quarantined record for a demolished structure costs bytes; a deleted "
                    .. "record for a streamed-out one costs the player), and this is the line "
                    .. "that says so with a number behind it.", n0, maxDist / 100)
                h:log("NOTE ONE BASE, ONE SESSION, %.0f m. The negative is weaker than the "
                    .. "positive would have been: a bigger world, a server, or a base the "
                    .. "player has never visited this session can all still differ, and the "
                    .. "dumps' Model/ConcreteModel split (see this file's header) is still "
                    .. "there and still unexplained by this run.", maxDist / 100)
            end
            h:log("NOTE what this hook cannot see: whether the structures were ever in memory "
                .. "for a base the player has NOT visited this session. FindAllOf can only "
                .. "report on what is loaded, so the strongest form of the question — does a "
                .. "far-away base's state survive a session in which it is never approached — "
                .. "needs a save/quit/reload and the record counts either side of it. "
                .. "`building-record-orphans` prints those counts.")
            h:endBlock("verdict")
            return true
        end)
        if armed then
            h:pass("the watch is armed. It reports for %d s and then prints its verdict; F9 is "
                .. "refused until it retires (core/poll claims the reload guard), which is the "
                .. "guard working rather than a defect.", WATCH_SEC)
        else
            -- NEVER A SILENT RETURN. core/poll refuses a poller past its own cap, and a hook
            -- whose watch never started would otherwise print a baseline and then nothing at
            -- all — indistinguishable from a base that streamed nothing out.
            h:endBlock("watch")
            h:warn("core/poll REFUSED the watch (too many pollers already running — "
                .. "`require('palforge.core.poll').count()` says how many). Nothing below t=0 "
                .. "was measured. TO OPEN IT: let the outstanding watches retire, or "
                .. "require('palforge.core.poll').clear(), then run this hook again.")
        end
    end,
}
