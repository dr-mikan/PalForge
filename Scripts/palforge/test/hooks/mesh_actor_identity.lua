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
-- Read-only. Three FindAllOf sweeps and some table lookups; it touches no component, attaches
-- nothing and writes nothing.
local hooks = require("palforge.test.hooks")

local CLASS   = "PalBuildObject"   -- what core/event's building scan itself enumerates
local GAP_S   = 6                  -- seconds between sweeps; long enough that nothing is cached
local SWEEPS  = 3

hooks.declare{
    id    = "mesh-actor-identity",
    item  = "Foundations / Assets / A-1 (and A-2)",
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
        local again
        for _, actor in ipairs(first) do
            if uo.fullName(actor) == targetName and not rawequal(actor, target) then again = actor end
        end
        h:value("two handles for one actor compare == ", again and tostring(rawequal(again, target))
            or "not testable: the sweep listed this actor once")

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

            -- AND THE PRODUCTION PATH, which is the line the refactor is actually judged on:
            -- core/event's own per-actor instance lookup, asked with a handle from THIS sweep.
            local inst
            pcall(function() inst = event.instanceOfActor(fresh) end)
            h:log("VALUE   event.instanceOfActor(fresh handle) -> %s",
                inst ~= nil and "HIT — the shipped building scan finds its own record"
                or "MISS — the shipped scan does NOT find the record it made for this actor")

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
            h:endBlock("sweep-" .. done)
            return done >= SWEEPS
        end)
    end,
}
