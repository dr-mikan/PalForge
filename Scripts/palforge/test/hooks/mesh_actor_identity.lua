-- test/hooks/mesh-actor-identity — THE ONE IN-GAME LINE THAT CONFIRMS A-1.
--
-- plan/TODO.md Foundations / Assets / A-1, and A-2 which follows from it. Contract C1.
--
-- A-1 is called "the most consequential finding in this audit": five per-actor tables in the
-- mesh layer, and `instancesByActor` in the building scan, were keyed on a UE4SS actor
-- USERDATA. UE4SS mints a fresh wrapper per lookup, so two references to one UObject are not
-- the same Lua value, and Lua indexes tables by userdata identity — no metamethod can rescue
-- `t[actor]`. Every consequence is silent: a detach that does nothing, an attachOnce that
-- stacks a second component nothing can ever destroy, a skeletal "undo" that restores
-- PalForge's own mesh, and a declared `Building{ mesh = ... }` that sets `_meshPending` once and
-- never renders it.
--
-- ⚠️ NOTHING IN THE TEST SUITE CAN SEE ANY OF THAT. test/cases/mesh.lua uses a plain Lua table
-- as a stub actor, which IS identity-stable, so the tests are green on the one property that
-- does not hold in a world — and pf_mesh captures one pawn value and reuses it for both the
-- attach and the detach, which is the only case that works. This hook is the measurement those
-- two cannot make.
--
-- IT IS ALSO THE PROOF FOR A REFACTOR THAT IS ALREADY WRITTEN. The EVENT and MESH agents have
-- re-keyed those tables on `uo.key(actor)` (GetFullName). The plan says the confirmation is
-- worth taking FIRST, because the change touches five files — so this hook runs BOTH keys side
-- by side on the same sweeps and says which one hits:
--
--   the handle key MISSES on sweep 2 and 3   -> A-1 is real, and the refactor is necessary.
--   the handle key HITS                      -> ⚠️ UE4SS interns handles somewhere this audit
--                                               did not find. That would be a genuinely new
--                                               fact about UE4SS, it would mean only A-2's slow
--                                               path needs looking at, and it is the reason
--                                               this hook prints both rather than the new one.
--
-- "A structure that certainly still exists" is not an assumption here: the target is chosen on
-- sweep 1 by its GetFullName, and each later sweep RE-FINDS it by that same string. A sweep that
-- cannot find the name again says so and the hook stops, because a missing actor would make a
-- miss unattributable — which is exactly the ambiguity the audit is trying to remove.
--
-- MEASURED 2026-08-02 16:39:46/16:39:52/16:39:58, in a loaded save, build 2026-08-02 16:37:13,
-- game v1.0.2.101103: FindAllOf('PalBuildObject') listed 8 actors on all three sweeps, the
-- target was BP_BuildObject_WorkBench_C_2147468373, and sweeps 2 AND 3 both printed
-- byActor[handle] -> MISS, byKey[GetFullName] -> HIT, rawequal = false, uo.same = true.
-- A-1 IS CONFIRMED IN GAME. The re-key is necessary, not tidy, and the second branch above
-- (UE4SS interning handles) is not what this runtime does.
--
-- THE SECOND MEASUREMENT IN EACH SWEEP — the shipped path — and why it now checks whether it
-- APPLIES before it says anything. The same two blocks printed
-- `event.instanceOfActor(fresh handle) -> MISS — the shipped scan does NOT find the record it
-- made for this actor`, and that reading was WRONG: it reported a defect against correct code.
-- M.instanceOfActor (core/event.lua:2767) is `local k = uo.key(actor); return k and
-- instancesByActor[k] or nil` — already keyed on GetFullName, and bindActor fills the same
-- table under the same key (core/event.lua:570). It answered nil because the table was
-- EMPTY: core/event's scan only ever makes a record for an actor whose build id a REGISTERED
-- definition claims (resolveBuildId, core/event.lua:702, returns nil unless Registry.byBuildId
-- holds the id, and refreshDefs builds that index out of object_manager.all("building") and
-- nothing else), and that session had building = 0 registered — the startup line said
-- `17 class(es) registered` and F-8 had made the native catalogs declare with
-- `{ register = false }`. building-record-orphans measured the same emptiness from the other
-- side at 16:39:58: no persistence file for this save at all. There was no record to miss.
-- So the probe now separates the three answers, and only one of them is a defect:
--
--   HIT                       -> the shipped lookup resolves a handle it has never seen to the
--                                instance the scan bound under an older one. C1 in production.
--   MISS, and a record exists -> A REAL DEFECT, named: Registry.instances and instancesByActor
--                                disagree about the same actor.
--   MISS, and no record       -> NOT APPLICABLE. Nothing is measured, and the hook says which
--                                reason it is and what would arm it — including that arming it
--                                WRITES to the player's save.
--
-- Read-only. Three FindAllOf sweeps and some table lookups; it touches no component, attaches
-- nothing and writes nothing. The "what would arm it" sentence names a call that DOES write,
-- and says so before it names it — the hook never makes that call itself.
local hooks = require("palforge.test.hooks")

local CLASS   = "PalBuildObject"   -- what core/event's building scan itself enumerates
local GAP_S   = 6                  -- seconds between sweeps; long enough that nothing is cached
local SWEEPS  = 3

hooks.declare{
    id    = "mesh-actor-identity",
    item  = "Closed 2026-08-02 — A-1 confirmed in three separate sessions",
    needs = { world = true },
    desc  = "does a table keyed on a UE4SS actor handle still hit on a later sweep — the "
         .. "measurement the whole per-actor re-key depends on",
    run = function(h)
        local uo    = require("palforge.core.uobject")
        local event = require("palforge.core.event")
        local poll  = require("palforge.core.poll")

        local function sweep()
            local list
            pcall(function() list = FindAllOf(CLASS) end)
            return (type(list) == "table") and list or {}
        end

        --------------------------------------------------------------------
        h:section("[1] sweep 1 — record every actor under BOTH keys")
        --------------------------------------------------------------------
        local first = sweep()
        h:value("FindAllOf('" .. CLASS .. "')", #first .. " actor(s)")
        if #first == 0 then
            h:fail("no %s in this world, so there is nothing to look up twice. Stand near some "
                .. "buildings — a base, or the palbox — and run it again.", CLASS)
            return
        end

        local byHandle, byKey = {}, {}
        local target, targetName
        for _, actor in ipairs(first) do
            local k = uo.key(actor)
            byHandle[actor] = true          -- THE OLD KEY: the userdata itself
            if k then
                byKey[k] = { actor = actor } -- THE NEW KEY: GetFullName, handle in the VALUE (C1)
                if not target then target, targetName = actor, k end
            end
        end
        if not targetName then
            h:fail("not one of the %d actors would answer GetFullName, so neither key could be "
                .. "built. That is a finding about this world's teardown state rather than "
                .. "about A-1.", #first)
            return
        end
        h:value("target", targetName)
        h:value("recorded under the HANDLE key", #first)
        local nKeys = 0
        for _ in pairs(byKey) do nKeys = nKeys + 1 end
        h:value("recorded under the GetFullName key", nKeys)
        if nKeys < #first then
            h:note("%d actor(s) would not answer GetFullName and have no record at all. `uo.key` "
                .. "returning nil means NO RECORD, never a key — `t[nil]` raises (contract C1).",
                #first - nKeys)
        end

        -- The same-object comparison, on the spot: two lookups of one actor inside ONE sweep.
        -- FindAllOf lists each actor once, so this is normally the empty case — and it is NOT a
        -- dead end, because sweeps 2 and 3 answer exactly this question with a handle from a
        -- LATER FindAllOf, which is the comparison that matters anyway. (MEASURED 2026-08-02
        -- 16:39:46: one entry, deferred; 16:39:52 and 16:39:58 answered rawequal = false.) This
        -- line used to say "not testable", which read as a question nothing would ever answer.
        local again
        for _, actor in ipairs(first) do
            if uo.fullName(actor) == targetName and not rawequal(actor, target) then again = actor end
        end
        h:value("two handles for one actor compare == ", again and tostring(rawequal(again, target))
            or "deferred to sweep 2: FindAllOf listed this actor once, so the second handle "
            .. "comes from the next sweep")

        -- Tier 1 of core/event's own build-id resolution, run here on the target: the class name
        -- pattern BP_BuildObject_<Id>_C (resolveBuildId, core/event.lua:702). It is printed so
        -- the NOT APPLICABLE branch below can name the exact id an operator would have to
        -- register, rather than gesture at "a building". MEASURED 2026-08-02 16:39:46: the
        -- target's class was BP_BuildObject_WorkBench_C, so this answers "WorkBench".
        local candidateId = (uo.className(target) or ""):match("BP_BuildObject_([%w_]+)_C")
        h:value("build id core/event would resolve for it",
            candidateId or "none — this class is not named BP_BuildObject_<Id>_C, so only "
            .. "resolveBuildId's tier 2/3 could claim it")

        -- ---- the shipped path: applicability first, verdict second ----
        -- The header has the account. In short: instanceOfActor is already keyed on
        -- uo.key(actor), so a MISS says nothing about the key until it is known that the scan
        -- ever made a record for this actor — and with no Building registered it never does.
        -- A hook that calls that MISS a defect costs more than a hook that says nothing.
        local function shippedLookup(fresh)
            local inst
            pcall(function() inst = event.instanceOfActor(fresh) end)
            if inst ~= nil then
                h:log("VALUE   event.instanceOfActor(fresh handle) -> HIT (record %s)",
                    tostring(inst.key))
                h:log("PASS the SHIPPED per-actor lookup is correct in game: core/event."
                    .. "instanceOfActor keys on uo.key(actor), so a wrapper it has never seen "
                    .. "before — this sweep's — still resolves to the instance the scan bound "
                    .. "under an older one. That is contract C1 working in production, on the "
                    .. "same handle the two lines above show is a different userdata.")
                return
            end

            -- A MISS. Ask, WITHOUT the index under test, whether core/event tracks this actor
            -- at all: event.instances() walks Registry.instances, a different table from
            -- instancesByActor, so the two disagreeing IS the defect and nothing else here is.
            local tracked, record = {}, nil
            pcall(function() tracked = event.instances() or {} end)
            for _, i in ipairs(tracked) do
                if i.actor and uo.fullName(i.actor) == targetName then record = i; break end
            end
            if record then
                h:log("VALUE   event.instanceOfActor(fresh handle) -> MISS")
                h:log("FAIL A REAL DEFECT IN SHIPPED CODE: core/event tracks an instance for "
                    .. "this actor (record %s, bound under actorKey %s) and its own per-actor "
                    .. "index does not answer for it. Registry.instances and instancesByActor "
                    .. "disagree about one structure — read bindActor/unbindActor "
                    .. "(core/event.lua:570 and 578) and the scan's fast path (scanOnce, "
                    .. "core/event.lua:867), which refreshes bound.actor on a hit and does NOT "
                    .. "re-bind the key, so an actor that was renamed keeps a stale one.",
                    tostring(record.key), tostring(record.actorKey))
                return
            end

            -- No record: NOT APPLICABLE. Which reason, and what would arm it.
            local nDefs, names = 0, {}
            pcall(function()
                for id in pairs(require("palforge.core.object_manager").all("building")) do
                    nDefs = nDefs + 1
                    if #names < 6 then names[#names + 1] = tostring(id) end
                end
            end)
            local ready = false
            pcall(function() ready = event.isWorldReady() end)

            -- native.buildings.publish(id) returns nil for an id its catalog does not hold, so
            -- the fallback is named here rather than left for the operator to discover.
            local arm = candidateId
                and ("require('palforge.native.buildings').publish('" .. candidateId
                     .. "') from the Lua console — or, if that catalog has no such id and it "
                     .. "returns nil, declare Building{ id = '" .. candidateId .. "' } in a pack")
                or  "declare a Building{ buildIds = { ... } } that claims this actor's build id"
            local cost = " ⚠️ THAT IS A SAVE WRITE, and it is why the hook does not do it: a "
                .. "REGISTERED definition makes every matching actor in this world a tracked "
                .. "instance AND a line in this save's entities file, and un-publishing later "
                .. "does not undo the writing (native/buildings.lua header). Do it on a save you "
                .. "do not mind, then run this hook again — the line above becomes HIT or a "
                .. "named FAIL."

            h:log("VALUE   event.instanceOfActor(fresh handle) -> NOT APPLICABLE (%d registered "
                .. "building definition(s), %d live instance(s))", nDefs, #tracked)
            if nDefs == 0 then
                h:log("NOTE not one Building definition is REGISTERED in this session, so "
                    .. "core/event's scan resolves no actor, makes no record and its per-actor "
                    .. "index is empty. instanceOfActor answering nil here is CORRECT and this "
                    .. "probe measured nothing — it is neither a pass nor a defect. F-8 is the "
                    .. "reason: the native catalogs declare with `{ register = false }` "
                    .. "(contract C2), so a stock install registers no building at all. The "
                    .. "first in-game run, 2026-08-02 16:39, was in exactly this state — the "
                    .. "startup line read `17 class(es) registered` with building = 0 — and this "
                    .. "hook called it a defect in shipped code, which it was not.")
                h:log("NOTE TO MAKE IT APPLICABLE: %s. Then wait one 500 ms scan.%s", arm, cost)
            elseif not ready then
                h:log("NOTE %d building definition(s) are registered (%s) but core/event's world "
                    .. "gate is still CLOSED, so scanOnce has not run and nothing is tracked "
                    .. "yet. Not applicable — nothing has had the chance to make a record. Wait "
                    .. "for world.ready and run this hook again.", nDefs, table.concat(names, ", "))
            else
                h:log("NOTE %d building definition(s) are registered (%s) and the scan is "
                    .. "running, but none of them claims THIS actor's build id (%s), so "
                    .. "resolveBuildId answered nil and no record was ever made for it. Not "
                    .. "applicable to this actor. TO MAKE IT APPLICABLE: %s.%s",
                    nDefs, table.concat(names, ", "), candidateId or "unresolved", arm, cost)
            end
        end

        h:note("sweeps 2 and 3 follow at +%d s and +%d s; this hook prints "
            .. "#### BEGIN mesh-actor-identity-sweep-N for each.", GAP_S, GAP_S * 2)

        --------------------------------------------------------------------
        local done = 1
        poll.every("mesh-actor-identity", function(elapsed)
            if elapsed < GAP_S * done then return false end
            done = done + 1
            h:beginBlock("sweep-" .. done)

            local list = sweep()
            h:log("VALUE sweep %d listed %d actor(s)", done, #list)

            -- RE-FIND THE TARGET BY NAME. This is what makes a miss attributable: the structure
            -- is known to still exist because its own full name is in this sweep's list.
            local fresh
            for _, actor in ipairs(list) do
                if uo.fullName(actor) == targetName then fresh = actor; break end
            end
            if not fresh then
                h:log("FAIL the target is not in sweep %d at all (%s). It was demolished, streamed "
                    .. "out, or the world changed — so a lookup miss would say nothing about the "
                    .. "key. Stopping.", done, targetName)
                h:endBlock("sweep-" .. done)
                return true
            end

            local handleHit = byHandle[fresh] == true
            local keyHit    = byKey[uo.key(fresh) or "\0"] ~= nil
            h:log("VALUE sweep %d  same actor, same name, a NEW handle from FindAllOf", done)
            h:log("VALUE   byActor[handle]  -> %s   (the OLD key)", handleHit and "HIT" or "MISS")
            h:log("VALUE   byKey[GetFullName] -> %s (the NEW key, contract C1)", keyHit and "HIT" or "MISS")
            h:log("VALUE   rawequal(sweep1 handle, sweep%d handle) = %s", done,
                tostring(rawequal(target, fresh)))
            h:log("VALUE   uo.same(sweep1 handle, sweep%d handle)  = %s", done,
                tostring(uo.same(target, fresh)))

            if not handleHit and keyHit then
                h:log("PASS A-1 CONFIRMED IN GAME. A table keyed on the handle misses for an "
                    .. "actor that certainly still exists, and the same table keyed on "
                    .. "GetFullName hits. Every silent consequence the audit listed follows from "
                    .. "this one line, and the re-key is necessary rather than tidy.")
            elseif handleHit then
                h:log("FAIL A-1 IS NOT REPRODUCED HERE: the handle key HIT on sweep %d. UE4SS "
                    .. "interns handles somewhere this audit did not find. Do not undo the "
                    .. "re-key on this alone — GetFullName is correct either way — but A-2's "
                    .. "diagnosis needs re-reading, and this is a new fact about UE4SS.", done)
            elseif not keyHit then
                h:log("FAIL BOTH keys missed, which means the target's own name changed between "
                    .. "sweeps. Neither key is being measured; read the two names above.")
            end

            -- AND THE PRODUCTION PATH, asked with a handle from THIS sweep. It runs AFTER the
            -- A-1 verdict deliberately: the two-key measurement above stands on its own and is
            -- what the re-key rests on, while this one may not apply at all, and a block that
            -- led with an inapplicable probe read as though the headline were in doubt.
            shippedLookup(fresh)

            h:endBlock("sweep-" .. done)
            return done >= SWEEPS
        end)
    end,
}
