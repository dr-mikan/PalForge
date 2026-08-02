-- test/hooks/building-runtime-reload — DOES THE BUILDING RUNTIME REALLY SURVIVE F9.
--
-- plan/TODO.md Foundations / The id model / F-5, whose "Still owed" says it in one sentence:
-- *"This is proven headlessly (two harnesses, 26 + 8 assertions) and by reading. It has never
-- been done in a game."* The EVENT agent proposed this hook by this name and it was never
-- declared. This is that hook.
--
-- WHAT F-5 WAS. `core/reload.lua` kept only `env`, `utils.log` and `reload`, so
-- `object_manager` was wiped and `registry.initialize()` built a fresh, EMPTY registry — and
-- the reconstruction scan, subscribed once per session inside `installBuildingSource`, survived
-- the wipe still closing over the OLD module's `Registry`. After one press: no building hook
-- fired again, `onTick` was dead, and `Building.Handle:instances()` answered `{}` for the rest
-- of the session, silently.
--
-- WHAT THE FIX CLAIMS, in three parts, because the prescribed fix was necessary and not
-- sufficient — and this hook measures each part separately, so a partial failure is
-- attributable rather than "F9 broke buildings again":
--
--   1. `palforge.core.object_manager` is in core/reload.lua's KEEP (:86), so a pack's
--      definitions outlive the wipe.  MEASURED AS: the module TABLE is the same object
--      before and after, and `om.all("building")` still holds the same ids.
--   2. The runtime registry lives on `_G.__PalForgeBuildingRegistry` and the spatial index on
--      `_G.__PalForgeSpatialIndex`, so the surviving drivers and the new module read ONE
--      table.  MEASURED AS: `rawequal` on the table itself, AND — the part the plan actually
--      words as the question — the identity of the table the SCAN closes over against the one
--      the DISPATCH resolves against, read out of the live closures with `debug.getupvalue`.
--   3. The once-armed drivers RE-ENTER the current module through `pump()` rather than running
--      their captured closures (core/event.lua's `pump`, `M.__scanPump` and friends).
--      MEASURED AS: a transparent witness wrapper installed on this module's `__scanPump`,
--      whose call count and last-call age are read by the NEXT run of this hook. A wrapper on
--      the PRE-reload module going quiet while the scan keeps running is the visible half of
--      pump(); a wrapper on the POST-reload module being called is the other half.
--
-- ⚠️ IT NEEDS THE OPERATOR TO PRESS F9 BETWEEN TWO RUNS, and each half runs on its own:
--
--     pf_hook building-runtime-reload      <- the BEFORE run: records and re-arms
--     press F9                             <- the reload this whole item is about
--     pf_hook building-runtime-reload      <- the AFTER run: compares against the record
--
-- Run it a third time and it compares against the second; there is no "phase" to keep track
-- of. If no F9 happened in between it SAYS SO by name (the core.event module table is
-- unchanged) rather than reporting a healthy-looking pass for a reload that never occurred —
-- which is the exact shape of false green this directory exists to refuse.
--
-- ⚠️ AND IT DELIBERATELY ARMS NO POLLER. Every core/poll poller brackets itself with
-- core/reload's async guard, so a hook with a watcher REFUSES the very F9 this measurement
-- needs (test/hooks/init.lua's header, core/poll.lua:123,134). Everything here is one-shot and
-- synchronous, and the two things that need time to pass — the scan witness and the channel
-- counters — are read by the next run instead of waited on.
--
-- WHAT IT LEAVES BEHIND, stated because `writes = false` only means "no save is mutated":
--   * `_G.__PalForgeHookReloadSnapshot`, a plain Lua table with the previous run's counts and
--     three module/table references. Cleared and rebuilt on every run.
--   * five subscriptions on the building.* channels, counting into that table. The NEXT run
--     unsubscribes them; until then they add one increment per event.
--   * one wrapper around `core.event.__scanPump` that calls straight through. The next run
--     restores the original, and an F9 replaces the whole module anyway.
-- Nothing here touches an actor, a component, an inventory or the persistence file.
local hooks = require("palforge.test.hooks")

local SNAP = "__PalForgeHookReloadSnapshot"

-- The five channels a placed structure can carry. onTick is NOT a channel — it is dispatched
-- per instance out of `Registry.tickList` — so it is reported as a list LENGTH below rather
-- than counted here, and the block says what a zero there does and does not mean.
local CHANNELS = { "building.place", "building.load", "building.interact",
                   "building.remove", "building.build" }

-- Pull a named upvalue out of a live closure, searching function-valued upvalues to `depth`.
--
-- THIS IS THE ONLY WAY TO ANSWER THE QUESTION AS THE PLAN WORDS IT. "The registry table the
-- scan closes over" is a module-local upvalue: no export returns it, and comparing counts
-- through the public surface can only ever say the two AGREE, never that they are one table.
-- `debug` is present in this tree's Lua by construction — utils/file/json_file.lua resolves
-- the state directory with `debug.getinfo` on every session — but every call is pcall'd and a
-- nil answer degrades to the behavioural probes below rather than failing the run.
--
-- Closures compiled from one chunk SHARE an upvalue when they reference the same local, so
-- whichever path finds `Registry` first finds the same object every other closure sees.
local function upvalue(fn, name, depth, seen)
    if type(fn) ~= "function" then return nil end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
    depth, seen = depth or 3, seen or {}
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

-- tostring on a table is its ADDRESS, which is the only printable form of identity Lua has.
-- Printed beside every rawequal verdict so a pasted block can be re-read later: two blocks
-- whose addresses differ where the verdict said "same" would mean the verdict was computed
-- against something else.
local function addr(t)
    if t == nil then return "nil" end
    local ok, s = pcall(tostring, t)
    return ok and s or "?"
end

hooks.declare{
    id    = "building-runtime-reload",
    item  = "Implemented, never exercised by a game",
    needs = { world = true },
    desc  = "press F9 between two runs: does the building registry the scan writes into stay "
         .. "the one the dispatch reads, and does a building hook fire afterwards",
    run = function(h)
        local event   = require("palforge.core.event")
        local om      = require("palforge.core.object_manager")
        local reload  = require("palforge.core.reload")
        local prev    = _G[SNAP]

        local RT   = _G.__PalForgeBuildingRegistry
        local IDX  = _G.__PalForgeSpatialIndex
        local BUS  = _G.__PalForgeBus

        --------------------------------------------------------------------
        h:section("[1] which run is this, and did an F9 actually happen")
        --------------------------------------------------------------------
        -- `reloaded` decides the WORDING of every comparison below. A block that says "the same
        -- table across the reload" when no reload happened is a block that reads as a pass for a
        -- measurement nobody took, which is the shape of false green this directory refuses.
        local reloaded = prev ~= nil and not rawequal(prev.eventMod, event)
        local span     = reloaded and "across the reload" or "since the previous run (NO RELOAD)"
        local sinceRun = prev and (os.clock() - (prev.clock or os.clock())) or 0
        if not prev then
            h:note("NO PREVIOUS RUN IS RECORDED, so this is the BEFORE half. Everything below is "
                .. "a baseline. WHAT TO DO NEXT, in this order: (1) place or stand near a "
                .. "structure a registered definition claims, (2) PRESS F9, (3) run "
                .. "`pf_hook building-runtime-reload` again. The second run is the measurement; "
                .. "this one is what it is measured against.")
        else
            h:value("previous run", string.format("%d s ago", os.time() - (prev.at or os.time())))
            h:value("core.event module table", string.format("%s -> %s", addr(prev.eventMod), addr(event)))
            if not reloaded then
                h:warn("THE core.event MODULE TABLE IS UNCHANGED, so NO RELOAD HAPPENED between "
                    .. "the two runs. F9 drops every palforge.* module from package.loaded, so a "
                    .. "reload cannot leave this table identical. Everything below is therefore a "
                    .. "second baseline and NOT a measurement of F-5. TO OPEN IT: press F9 (or "
                    .. "run `require('palforge.core.reload').reload()` from the Lua console) and "
                    .. "run this hook again. ⚠️ If the press was REFUSED, the [reload] line above "
                    .. "names the async chain that is still outstanding — a hook watcher or an "
                    .. "open PalForge panel — and that refusal is the guard working.")
            else
                h:pass("A RELOAD DID HAPPEN: core.event is a different module table than the one "
                    .. "the previous run held. Every comparison below is therefore about what "
                    .. "survived it.")
            end
        end

        --------------------------------------------------------------------
        h:section("[2] the three things F-5 claims survive, by IDENTITY")
        --------------------------------------------------------------------
        h:value("_G.__PalForgeBuildingRegistry", addr(RT))
        h:value("_G.__PalForgeSpatialIndex", addr(IDX))
        h:value("_G.__PalForgeBus", addr(BUS))
        h:value("core.object_manager module", addr(om))
        h:value("core.reload KEEP has object_manager",
            tostring(reload.KEEP and reload.KEEP["palforge.core.object_manager"] == true))
        if RT == nil then
            h:fail("there is no _G.__PalForgeBuildingRegistry at all. core/event.lua creates it at "
                .. "module load, so either core.event has never been required in this session or "
                .. "something cleared the global. Nothing below can be measured.")
            return
        end
        if prev then
            local checks = {
                { "the building runtime registry", prev.rt, RT,
                  "the surviving scan and the new dispatch would be reading two different "
                  .. "instance tables — F-5 exactly as it was originally diagnosed" },
                { "the spatial hash grid", prev.idx, IDX,
                  "every live instance's `_bucket` stamp would name a bucket that no longer "
                  .. "exists and neighbors() would answer {} for a base full of structures" },
                { "the event bus", prev.bus, BUS,
                  "native hooks armed on the first load would push into a table nobody listens to" },
                { "the object_manager MODULE", prev.omMod, om,
                  "every pack's definitions would be gone until the game restarts, and — with "
                  .. "the F-7 prune in place — every one of their records would be quarantined "
                  .. "about 30 s later" },
            }
            for _, c in ipairs(checks) do
                if c[2] == nil then
                    h:note("%s: the previous run recorded nothing to compare against", c[1])
                elseif not rawequal(c[2], c[3]) then
                    h:fail("%s was REPLACED %s (%s -> %s). Consequence: %s",
                        c[1], span, addr(c[2]), addr(c[3]), c[4])
                elseif reloaded then
                    h:pass("%s is the SAME table across the reload (%s)", c[1], addr(c[3]))
                else
                    h:note("%s is unchanged, but no reload happened, so this is not evidence "
                        .. "about F-5 (%s)", c[1], addr(c[3]))
                end
            end
        end

        --------------------------------------------------------------------
        h:section("[3] the scan's registry vs the dispatch's registry — the plan's question")
        --------------------------------------------------------------------
        -- Read straight out of the live closures. `M.instances` and `M.instanceOfActor` are the
        -- DISPATCH side (they are what api/building's Handle:instances() and the interact route
        -- resolve through); `M.__scanPump` reaches scanOnce, which is the SCAN side.
        local scanRegistry = upvalue(event.__scanPump, "Registry")
        local scanGate     = upvalue(event.__scanPump, "gate")
        local dispRegistry = upvalue(event.instances, "Registry")
        local dispByActor  = upvalue(event.instanceOfActor, "instancesByActor")
        if scanRegistry == nil and dispRegistry == nil then
            h:note("debug.getupvalue answered nothing on this build, so the two tables cannot be "
                .. "compared by identity here. That is a limitation of the SESSION, not a "
                .. "finding: block [4]'s behavioural probes are what is left, and they can say "
                .. "the two AGREE without proving they are one table.")
        else
            h:value("SCAN     closes over Registry", addr(scanRegistry))
            h:value("DISPATCH closes over Registry", addr(dispRegistry))
            h:value("DISPATCH closes over byActor", addr(dispByActor))
            h:value("SCAN     closes over the world gate", addr(scanGate))
            if scanRegistry ~= nil and dispRegistry ~= nil and rawequal(scanRegistry, dispRegistry)
               and rawequal(scanRegistry, RT) then
                h:pass("THE SCAN AND THE DISPATCH HOLD ONE TABLE, and it is the one on _G. This "
                    .. "is the line F-5 is about: the scan writes an instance into the table the "
                    .. "dispatch resolves a building.place / load / interact / remove against.")
            else
                h:fail("THE SCAN AND THE DISPATCH ARE NOT ON ONE TABLE (scan %s, dispatch %s, "
                    .. "_G %s). Whatever the scan discovers, the dispatch cannot find, and no "
                    .. "building hook will fire again in this session.",
                    addr(scanRegistry), addr(dispRegistry), addr(RT))
            end
            if dispByActor ~= nil and not rawequal(dispByActor, RT.byActor) then
                h:fail("the dispatch's actor index is NOT _G.__PalForgeBuildingRegistry.byActor "
                    .. "(%s vs %s): an interact would resolve to nothing for an actor the scan "
                    .. "has bound.", addr(dispByActor), addr(RT.byActor))
            end
            if scanGate ~= nil and not rawequal(scanGate, RT.world) then
                h:fail("the scan's world gate is not the shared one (%s vs %s), so gate.ready, "
                    .. "gate.scans and gate.pruned mean different things to the two halves.",
                    addr(scanGate), addr(RT.world))
            end
        end

        --------------------------------------------------------------------
        h:section("[4] what the registry actually holds, through the public surface")
        --------------------------------------------------------------------
        local registered = om.all("building")
        local nRegistered = countPairs(registered)
        local instances   = event.instances()
        local now = {
            registered = nRegistered,
            instances  = #instances,
            rtInstances = countPairs(RT.instances),
            byActor    = countPairs(RT.byActor),
            tickList   = #(RT.tickList or {}),
            defs       = countPairs(RT.defs),
            byBuildId  = countPairs(RT.byBuildId),
            scans      = tonumber(RT.world and RT.world.scans) or 0,
            pruned     = (RT.world and RT.world.pruned) == true,
            ready      = event.isWorldReady(),
        }
        local function line(label, key, note)
            local was = prev and prev.now and prev.now[key]
            h:value(label, string.format("%s%s%s", tostring(now[key]),
                was ~= nil and ("   (was " .. tostring(was) .. ")") or "",
                note and ("   " .. note) or ""))
        end
        line("registered building definitions", "registered")
        line("event.instances() — the DISPATCH view", "instances")
        line("_G registry .instances — the raw table", "rtInstances")
        line("_G registry .byActor", "byActor")
        line("_G registry .tickList (onTick candidates)", "tickList")
        line("_G registry .defs", "defs")
        line("_G registry .byBuildId", "byBuildId")
        line("scanOnce passes this world (gate.scans)", "scans")
        line("the F-7 orphan pass has run (gate.pruned)", "pruned")
        line("event.isWorldReady()", "ready")

        if now.instances ~= now.rtInstances then
            h:fail("event.instances() reports %d and the table on _G holds %d. The public view "
                .. "and the shared state disagree, which is F-5's symptom read from the other "
                .. "side.", now.instances, now.rtInstances)
        end
        if prev and prev.now and now.scans <= (prev.now.scans or 0) then
            if sinceRun < 2 then
                h:note("gate.scans has not moved, and only %.1f s separates the two runs — the "
                    .. "scan runs every 500 ms, so that is not long enough to conclude anything. "
                    .. "Leave a few seconds between the halves.", sinceRun)
            else
                h:fail("gate.scans has NOT moved in %.0f s (%d -> %d). The 500 ms reconstruction "
                    .. "scan is not running at all, so nothing below is a statement about the "
                    .. "reload — check for a [reload]/[event] error above, and note that the scan "
                    .. "is driven by a subscription armed ONCE per session.",
                    sinceRun, prev.now.scans or 0, now.scans)
            end
        elseif prev then
            h:pass("the scan is still running %s: gate.scans %d -> %d, and it is incrementing the "
                .. "world gate held on _G.", span, prev.now.scans or 0, now.scans)
        end

        -- THE PRECONDITION NOBODY CAN INFER FROM A ZERO. Instances exist only for REGISTERED
        -- definitions (core/event's refreshDefs reads object_manager and nothing else), and
        -- F-8 made the curated native buildings declare-without-registering. So a stock dev
        -- session has zero registered buildings, zero instances, and "instances() is non-empty
        -- after F9" is unmeasurable — which would look exactly like the defect.
        if nRegistered == 0 then
            h:warn("NOT MEASURABLE, AND THIS IS THE GATE: no Building definition is registered, "
                .. "so there are no instances for the reload to lose and no building.* event "
                .. "can ever be dispatched. This is not a defect — F-8 made the native catalogs "
                .. "declare without registering on purpose. TO OPEN IT, from the UE4SS Lua "
                .. "console, BEFORE the before-run: "
                .. "require('palforge.native.buildings').publish('WorkBench')  — then stand in a "
                .. "base with a workbench in it. ⚠️ Publishing is what starts PERSISTING a record "
                .. "for every matching structure in that save (that is exactly what F-8 is "
                .. "about), so do it on a save you do not mind writing to.")
        elseif now.instances == 0 then
            h:warn("%d definition(s) are registered and NOTHING is tracked. Either no structure "
                .. "of a claimed build id is standing near you, or the scan is not matching. The "
                .. "claimed build ids this session are the %d key(s) of byBuildId above; stand "
                .. "next to one of those structures and run the before-run again.", nRegistered,
                now.byBuildId)
        elseif prev and prev.now and prev.now.instances > 0 and now.instances == 0 then
            h:fail("INSTANCES WENT TO ZERO %s (%d -> 0). That is F-5's headline symptom: "
                .. "Building.Handle:instances() answers {} and no building hook fires again for "
                .. "the rest of the session.", span, prev.now.instances)
        elseif prev and prev.now and prev.now.instances > 0 and reloaded then
            h:pass("%d tracked instance(s) before the reload, %d after. Building.Handle:"
                .. "instances() is NOT empty on the other side of an F9.",
                prev.now.instances, now.instances)
        end
        if now.tickList == 0 and nRegistered > 0 then
            h:note("tickList is empty, so onTick is vacuous this session: it holds only instances "
                .. "whose CLASS overrides onTick (core/event's `overrides`), and neither curated "
                .. "native building declares one. To measure onTick across a reload, define "
                .. "Building{ id = 'WorkBench', events = { onTick = function(self) ... end } } in "
                .. "a pack and place one.")
        end

        --------------------------------------------------------------------
        h:section("[5] did a building hook FIRE, on the other side of the press")
        --------------------------------------------------------------------
        if prev and prev.counts then
            local total = 0
            for _, ch in ipairs(CHANNELS) do
                local n = tonumber(prev.counts[ch]) or 0
                total = total + n
                h:value(ch, n)
            end
            if total > 0 then
                h:pass("%d building event(s) were dispatched between the two runs. A channel "
                    .. "carrying anything at all means the surviving source resolved a live "
                    .. "instance out of the registry and the dispatch found the definition — "
                    .. "which is the whole of F-5 in one observation.", total)
            else
                h:note("no building.* event was carried between the two runs. That is NOT a "
                    .. "failure on its own: place / load fire when the scan first sees a "
                    .. "structure, interact when you use one. To make this line mean something, "
                    .. "run the before-run, press F9, then WALK UP TO A TRACKED STRUCTURE AND "
                    .. "USE IT (a workbench, a chest), then run the after-run.")
            end
        end

        --------------------------------------------------------------------
        h:section("[6] the pump witness — do the once-armed drivers re-enter THIS module")
        --------------------------------------------------------------------
        -- Fix #3 of F-5. The scan subscription is created once per SESSION inside
        -- installBuildingSource; after a reload it is still the pre-reload closure, and the only
        -- reason it runs current code at all is that its body is `pump("__scanPump")`, which
        -- re-requires core.event on every call. A wrapper on THIS module's __scanPump therefore
        -- answers "is the surviving driver reaching this module?" — and it answers it half a
        -- second at a time, which is why it is read by the NEXT run rather than waited on here.
        if prev and prev.witness then
            local w = prev.witness
            local age = w.lastAt and (os.clock() - w.lastAt) or nil
            h:value("witness calls on the PREVIOUS module", w.calls or 0)
            h:value("last call", age and string.format("%.1f s ago", age) or "never")
            h:value("that module is still the current one", tostring(rawequal(w.module, event)))
            if (w.calls or 0) == 0 then
                h:note("the driver never called the module this witness was installed on, in the "
                    .. "%.1f s the two runs are apart. Under about a second that is expected (the "
                    .. "scan runs every 500 ms), and so is an F9 taken immediately after the "
                    .. "install; otherwise the scan subscription is not running at all — see "
                    .. "gate.scans in [4].", sinceRun)
            elseif rawequal(w.module, event) then
                h:pass("the tick-driven scan is calling this module's __scanPump (%d time(s)). "
                    .. "pump() is live.", w.calls)
            elseif age and age > 3 then
                h:pass("the PRE-reload module stopped being called %.1f s ago while the scan kept "
                    .. "running (gate.scans is still climbing). That is pump() doing its job: the "
                    .. "surviving driver re-resolved core.event and moved to the new module "
                    .. "instead of running its captured closure.", age)
            else
                h:note("the pre-reload module was called %d time(s) and last %.1f s ago. Wait a "
                    .. "few seconds after the F9 before the after-run: the point of this line is "
                    .. "that the OLD module goes quiet while the scan keeps going.", w.calls, age or -1)
            end
            -- Put the original back if it is still ours to put back.
            if type(w.orig) == "function" and rawequal(w.module, event) then
                pcall(function() event.__scanPump = w.orig end)
            end
        end

        --------------------------------------------------------------------
        -- Tear the previous run down and arm a fresh one. Doing it LAST means everything above
        -- reported the old counters before they were dropped.
        --------------------------------------------------------------------
        if prev and prev.subs then
            for _, sub in ipairs(prev.subs) do pcall(function() sub:unsubscribe() end) end
        end

        local snap = {
            at = os.time(), clock = os.clock(),
            eventMod = event, omMod = om, rt = RT, idx = IDX, bus = BUS,
            now = now, counts = {}, subs = {},
        }
        for _, ch in ipairs(CHANNELS) do
            snap.counts[ch] = 0
            local ok, sub = pcall(function()
                return event.on(ch, function() snap.counts[ch] = (snap.counts[ch] or 0) + 1 end)
            end)
            if ok and sub then snap.subs[#snap.subs + 1] = sub end
        end
        local orig = event.__scanPump
        if type(orig) == "function" then
            snap.witness = { module = event, orig = orig, calls = 0, lastAt = nil }
            event.__scanPump = function(...)
                snap.witness.calls  = snap.witness.calls + 1
                snap.witness.lastAt = os.clock()
                return orig(...)
            end
        end
        _G[SNAP] = snap

        h:section("[7] armed — what to do now")
        h:value("channel counters armed", #snap.subs .. " of " .. #CHANNELS)
        h:value("scan witness installed", tostring(snap.witness ~= nil))
        h:ask("PRESS F9 NOW, then use a tracked structure, then run "
            .. "`pf_hook building-runtime-reload` again.")
        h:note("this hook holds NO poller, so F9 will not be refused on its account. If the press "
            .. "is refused anyway, the message names the chain that is outstanding.")
    end,
}
