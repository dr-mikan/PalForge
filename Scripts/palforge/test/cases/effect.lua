-- palforge/test/cases/effect.lua — the Effect domain: definition, spec, and the live runtime.
--
-- This suite proves two separate things. The DEFINITION half (Effect{ ... } / Effect.get /
-- Effect.get_all, every spec field, every rejection) is pure Lua and runs anywhere. The
-- RUNTIME half — :apply / :remove / stacking / expiry — is also pure: an application is
-- bookkeeping in a weak-keyed table, and a plain Lua table is a perfectly good target, so
-- none of it needs a world. What it DOES need is the heartbeat, so instead of waiting for
-- real time these tests emit core/event's "tick" channel themselves and count the handler
-- calls; the same trick drives the "world.left" release. Only the last test touches the
-- game (it applies to the real player pawn to exercise the userdata path) and it skips
-- when there is no world.
--
-- The pure half toggles no native ailment, because an Effect only reaches the game's own
-- status system when it DECLARES `nativeStatus`; the last test in this file is the one that
-- does, against a buff chosen so that a leak is harmless. This paragraph used to end by calling
-- that seam an open marker in native/effects.lua. It is not: native/effects.lua is fully
-- implemented and carries no marker at all, so the cross-reference pointed at nothing.
-- It also did a second kind of damage, and avoiding that is why this sentence is worded the way
-- it is: the reference was spelled in the tree's own marker syntax — the word, an open bracket,
-- an item id — so every sweep for open markers matched THIS comment and reported an item that
-- had never existed. A comment ABOUT markers must not be written in the shape of one.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Effect  = require("palforge.api.effect")
local status  = require("palforge.core.status")
local event   = require("palforge.core.event")
local om      = require("palforge.core.object_manager")

local s = T.suite("effect")

-- Every Effect{ } below is namespaced throwaway content and defining is permanent, so the
-- suite gives them back the moment it finishes.
support.sweepAfter(s)

-- Seconds one heartbeat advances an application. Read from event.TICK_MS rather than
-- hard-coded, because that is exactly what the runtime does when it installs its driver.
local BEAT = (tonumber(event.TICK_MS) or 500) / 1000

-- Drive the runtime by hand. The real source is a LoopAsync that emits this channel; a
-- test must never wait for it, so it pushes the beats itself and counts what happened.
local beatNo = 0
local function beats(n)
    for _ = 1, (n or 1) do
        beatNo = beatNo + 1
        event.emit("tick", { count = beatNo, now = 0 })
    end
end

--=============================================================================
-- definition + spec
--=============================================================================

s:test("Effect{ } returns a handle carrying the id and registers the definition", function(t)
    local id = support.id("effect")
    local h  = Effect{ id = id }
    t:eq(h.id, id, "the handle carries the id it was defined with")
    t:type(h.apply, "function", "the handle carries the runtime actions")
    t:truthy(om.get("effect", id), "the definition is registered under (\"effect\", id)")
end)

s:test("every spec field is kept and readable back off the definition", function(t)
    local id = support.id("effect")
    local h  = Effect{
        id           = id,
        name         = "Regeneration",
        description  = "heals over time",
        duration     = 10.0,
        interval     = 1.0,
        stackable    = true,
        maxStacks    = 3,
        icon         = "icon/regen",
        nativeStatus = "Poison",
        data         = { potency = 7 },
        events       = { onApply = function() end },
    }
    t:eq(h:name(), "Regeneration")
    t:eq(h:description(), "heals over time")
    t:eq(h:duration(), 10.0)
    t:eq(h:interval(), 1.0)
    t:eq(h:iconOf(), "icon/regen")

    -- stackable / maxStacks / nativeStatus / data have no handle accessor; they live on
    -- the registered class, which is also where the runtime reads them from.
    local cls = om.get("effect", id)
    t:eq(cls.stackable, true)
    t:eq(cls.maxStacks, 3)
    t:eq(cls.nativeStatus, "Poison")
    t:eq(cls.data.potency, 7)
end)

s:test("the defaults are inert: one stack, not stackable, no duration and no interval", function(t)
    local id  = support.id("effect")
    local h   = Effect{ id = id }
    local cls = om.get("effect", id)
    t:eq(h:name(), id, "name defaults to the id")
    t:eq(h:description(), nil)
    t:eq(h:duration(), nil, "no duration means it lasts until :remove()")
    t:eq(h:interval(), nil, "no interval means onTick never fires")
    t:eq(h:iconOf(), nil)
    t:eq(cls.stackable, false)
    t:eq(cls.maxStacks, 1)
end)

s:test("id is required, and an empty one is rejected by its own check", function(t)
    t:errors(function() Effect{ name = "nameless" } end, 'field "id" is required')
    t:errors(function() Effect{ id = "" } end, "must be a non-empty string")
end)

s:test("an unknown field is a hard error with a did-you-mean", function(t)
    local msg = t:errors(function() Effect{ id = support.id("effect"), duraton = 5 } end,
        'unknown field "duraton"')
    t:truthy(msg:find('did you mean "duration"', 1, true), "the error suggests the real field")
    t:truthy(msg:find("nativeStatus", 1, true), "and lists every valid field")
end)

s:test("an unknown event name is a hard error naming the events shape", function(t)
    local msg = t:errors(function()
        Effect{ id = support.id("effect"), events = { onAply = function() end } }
    end, 'unknown field "onAply"')
    t:truthy(msg:find("Effect.Spec.Events", 1, true), "the error names the nested spec")
    t:truthy(msg:find('did you mean "onApply"', 1, true), "and suggests the handler that exists")
end)

s:test("a field of the wrong type is a hard error naming the field and both types", function(t)
    t:errors(function() Effect{ id = support.id("effect"), duration = "10" } end,
        'field "duration" expects number, got string')
    t:errors(function() Effect{ id = support.id("effect"), events = 5 } end,
        'field "events" expects table, got number')
end)

s:test("Effect.get hands back a thin definition for an id nobody defined, never nil", function(t)
    local id = support.id("effect")
    local h  = Effect.get(id)
    t:truthy(h, "get never returns nil")
    t:eq(h.id, id)
    t:eq(h:name(), id, "an undefined effect names itself")
    t:eq(h:duration(), nil)
    t:eq(h:iconOf(), nil)
    t:eq(om.get("effect", id), nil, "and looking one up does NOT register it")
end)

s:test("Effect.get on a defined id resolves the same definition through a fresh handle", function(t)
    local id = support.id("effect")
    local h  = Effect{ id = id, name = "Shield", duration = 4.0 }
    local g  = Effect.get(id)
    t:neq(g, h, "get builds a new wrapper rather than returning the original handle")
    t:eq(g:name(), "Shield", "but it wraps the same registered class")
    t:eq(g:duration(), 4.0)
end)

s:test("Effect.get demands a non-empty string id", function(t)
    t:errors(function() Effect.get("") end, "Effect.get: id (string) is required")
    t:errors(function() Effect.get(nil) end, "Effect.get: id (string) is required")
end)

s:test("Effect.get_all lists every registered effect, curated ailments included", function(t)
    local id = support.id("effect")
    Effect{ id = id }
    local seen = {}
    for _, h in ipairs(Effect.get_all()) do seen[h.id] = true end
    t:truthy(seen[id], "a just-defined effect is in the list")
    t:truthy(seen["Poison"], "so are native/effects' curated ailments")
end)

s:test("re-defining an id replaces the registered definition", function(t)
    local id = support.id("effect")
    Effect{ id = id, name = "first" }
    Effect{ id = id, name = "second" }
    t:eq(Effect.get(id):name(), "second", "the last definition wins")
end)

s:test("nativeStatus names one of the game's own ailments and is checked when declared", function(t)
    local id = support.id("effect")
    local h  = Effect{ id = id, nativeStatus = "Burn" }
    t:eq(om.get("effect", id).nativeStatus, "Burn", "it is carried on the definition")
    t:eq(h.nativeStatus, nil, "and stays off the handle, like every other declarative field")

    -- The names are the game's own EPalStatusID spellings, and matching is case-insensitive
    -- because "poison" is what somebody will actually type.
    t:truthy(status.known("Poison"), "Poison is an ailment this build has")
    t:truthy(status.known("poison"), "and the lookup does not care about case")
    t:truthy(#status.names() >= 30, "the vocabulary is the whole enum, not a curated handful")

    -- A typo is caught while the definition is being written, with the real list in the
    -- message — not as a quiet log line the first time an effect lands on a player.
    local ok, err = pcall(function() return Effect{ id = support.id("effect"), nativeStatus = "Poizon" } end)
    t:eq(ok, false, "an ailment this build does not have is rejected at definition time")
    t:truthy(tostring(err):find("nativeStatus", 1, true), "and the message names the field")
    t:truthy(tostring(err):find("Burn", 1, true), "and lists the names that would have worked")
end)

s:test("core.status refuses honestly when there is nothing to apply to", function(t)
    -- No world, no PalCharacter, so there is no StatusComponent to reach. Every entry point
    -- must answer without raising, and must distinguish "cannot ask" from "no".
    t:eq(status.add(nil, "Poison"), false, "add reports false rather than raising")
    t:eq(status.remove(nil, "Poison"), false, "and so does remove")
    t:eq(status.isActive(nil, "Poison"), nil, "isActive answers nil — UNKNOWN, never false-as-in-no")
    t:eq(status.add(nil, "Poizon"), false, "an unknown name is refused before any engine call")
end)

s:test("a nativeStatus that cannot fire never fails the effect", function(t)
    -- The contract that matters to a pack: PalForge's own timing, stacking and handlers work
    -- with or without the game's status icon. Failing the whole apply because the native
    -- ailment did not light up would trade a working feature for a cosmetic one.
    --
    -- With no world this exercises exactly that path — status.add cannot reach a component and
    -- returns false — and :apply must still be true and the handler must still have run.
    local id, ran = support.id("effect"), 0
    local h = Effect{ id = id, nativeStatus = "Freeze",
                      events = { onApply = function() ran = ran + 1 end } }
    local target = {}
    t:eq(h:apply(target), true, "the effect applies even though no ailment could be set")
    t:eq(ran, 1, "and the pack's own handler ran")
    t:truthy(h:isActive(target), "and PalForge's bookkeeping is live")
    t:eq(h:remove(target), true, "removal is symmetric")
end)

--=============================================================================
-- runtime — bookkeeping
--=============================================================================

s:test("apply on a plain table target starts a live application and fires onApply", function(t)
    local target, applied = {}, 0
    local h = Effect{ id = support.id("effect"),
        events = { onApply = function() applied = applied + 1 end } }

    t:falsy(h:isActive(target), "nothing is active before apply")
    t:eq(h:apply(target), true, "apply reports success")
    t:eq(applied, 1, "onApply fired exactly once")
    t:truthy(h:isActive(target))
    t:eq(h:stacksOn(target), 1, "an application starts at one stack")

    h:remove(target)
end)

s:test("onApply is handed the handle, the target and a ctx that merges the caller's own", function(t)
    local target = {}
    local gotSelf, gotTarget, gotCtx
    local h = Effect{ id = support.id("effect"), duration = 3.0, events = {
        onApply = function(self, tg, ctx) gotSelf, gotTarget, gotCtx = self, tg, ctx end,
    } }

    h:apply(target, { source = "test" })
    t:eq(gotSelf, h, "the handler's self is the handle the define call returned")
    t:eq(gotTarget, target, "the target is passed through untouched")
    t:eq(gotCtx.effect, h.id, "ctx names the effect")
    t:eq(gotCtx.stacks, 1)
    t:eq(gotCtx.source, "test", "the caller's ctx shows through by __index")

    h:remove(target)
end)

s:test("a target that was never touched reports nothing active", function(t)
    local target = {}
    local h = Effect{ id = support.id("effect"), duration = 1.0 }
    t:falsy(h:isActive(target))
    t:eq(h:stacksOn(target), 0, "no stacks on an untouched target")
    t:eq(h:timeLeft(target), 0, "timeLeft is 0 — not nil — when inactive")
    t:eq(#Effect.activeOn(target), 0)
    t:eq(h:remove(target), false, "removing what was never applied is false, not an error")
end)

s:test("timeLeft is nil while an effect is indefinite and 0 once it is gone", function(t)
    local target = {}
    local h = Effect{ id = support.id("effect") }   -- no duration
    h:apply(target)
    t:eq(h:timeLeft(target), nil, "no duration means no deadline")
    beats(3)
    t:truthy(h:isActive(target), "and it survives any number of heartbeats")
    t:eq(h:remove(target), true)
    t:eq(h:timeLeft(target), 0, "gone reads as 0")
end)

s:test("remove ends the application early with reason 'removed' and is false a second time", function(t)
    local target, reasons = {}, {}
    local h = Effect{ id = support.id("effect"), duration = 10.0, events = {
        onExpire = function(_, _, ctx) reasons[#reasons + 1] = ctx.reason end,
    } }

    h:apply(target)
    t:eq(h:remove(target), true)
    t:eq(#reasons, 1, "onExpire fired once")
    t:eq(reasons[1], "removed", "and said why")
    t:falsy(h:isActive(target))
    t:eq(h:remove(target), false, "the second remove finds nothing to end")
    t:eq(#reasons, 1, "and does not fire onExpire again")
end)

s:test("Effect.activeOn lists a target's effect ids, sorted", function(t)
    local target = {}
    local a = Effect{ id = support.id("effect") }
    local b = Effect{ id = support.id("effect") }
    a:apply(target)
    b:apply(target)

    local want = { a.id, b.id }
    table.sort(want)
    local got = Effect.activeOn(target)
    t:eq(#got, 2)
    t:eq(got[1], want[1], "the list comes back sorted")
    t:eq(got[2], want[2])

    a:remove(target)
    b:remove(target)
    t:eq(#Effect.activeOn(target), 0, "and empties as they are removed")
end)

s:test("apply with no target is a world-global application, separate from any target", function(t)
    local target = {}
    local h = Effect{ id = support.id("effect"), duration = 10.0 }
    h:apply()   -- nil target -> the GLOBAL sentinel bucket

    t:truthy(h:isActive(), "active globally")
    t:falsy(h:isActive(target), "but not on a target that never received it")
    local ids = Effect.activeOn()
    local found = false
    for _, id in ipairs(ids) do if id == h.id then found = true end end
    t:truthy(found, "activeOn() with no target reads the global bucket")
    t:eq(#Effect.activeOn(target), 0)

    t:eq(h:remove(), true, "and remove with no target ends it")
end)

--=============================================================================
-- A-1 / contract C1 — an application is filed under the target's NAME, not its handle
--
-- THE PROPERTY THIS SUITE WAS STRUCTURALLY BLIND TO, and for the same reason the mesh suite
-- was: every target above is a plain Lua table, and a plain Lua table IS identity-stable, so
-- a table keyed on the target looked up correctly here while missing on every second lookup
-- in a world — UE4SS mints a fresh userdata wrapper per lookup, and Lua indexes a table by
-- userdata identity. `apps` was that table. :isActive / :stacksOn / :timeLeft / :remove
-- called with a pawn from a later FindAllOf answered false / 0 / 0 / false, and a second
-- :apply on the SAME pawn started a SECOND independent application: onApply again instead of
-- onStack, stacks back to 1, and core.status.add run twice on a target already carrying the
-- ailment. Nothing raised, so nothing here failed.
--
-- The stand-in is the mesh suite's: two Lua values that answer ONE GetFullName are exactly
-- what two references to one pawn are.
--=============================================================================

local function stubTarget(name)
    return { IsValid = function() return true end, GetFullName = function() return name end }
end

s:test("two handles onto one target reach one application: the runtime keys on the full name", function(t)
    local NAME = "BP_ChickenPal_C /Game/Test/Level:PersistentLevel.BP_ChickenPal_C_11"
    local a1, a2 = stubTarget(NAME), stubTarget(NAME)
    t:neq(a1, a2, "two DIFFERENT Lua values, which is what UE4SS really hands out")

    local applies, stacks = 0, 0
    local h = Effect{ id = support.id("effect"), stackable = true, maxStacks = 3, duration = 10.0,
        events = { onApply = function() applies = applies + 1 end,
                   onStack = function() stacks  = stacks  + 1 end } }

    t:eq(h:apply(a1), true)
    -- THE ASSERTIONS THE OLD KEY COULD NOT PASS: every query below is made through the
    -- SECOND handle, which is what a caller reached by an event ctx actually holds.
    t:eq(h:isActive(a2), true, "the application is visible through a different handle")
    t:eq(h:stacksOn(a2), 1, "and it is the same application, at one stack")
    t:eq(h:timeLeft(a2), 10.0, "carrying the duration the first handle started")

    h:apply(a2)
    t:eq(applies, 1, "the second apply did NOT start a second application")
    t:eq(stacks, 1, "it stacked the first one, which is what onStack means")
    t:eq(h:stacksOn(a1), 2, "and the stack count is shared by both handles")

    local ids = Effect.activeOn(a2)
    t:eq(#ids, 1, "Effect.activeOn reads the same bucket through either handle")
    t:eq(ids[1], h.id)

    t:eq(h:remove(a2), true, "and the removal reaches it through the second handle")
    t:eq(h:isActive(a1), false, "so it is gone for BOTH handles")
end)

s:test("a target that will not answer its own name still gets an application", function(t)
    -- uo.key is nil for it, and `t[nil]` raises — so the fallback is the handle itself, which
    -- is the pre-C1 behaviour for that one object and still lets the caller that holds it
    -- reach its own application. What must never happen is a raise.
    local mute = { IsValid = function() return true end }
    local h = Effect{ id = support.id("effect") }
    t:eq(h:apply(mute), true, "the apply lands")
    t:eq(h:isActive(mute), true, "and the same value reads it back")
    t:eq(h:remove(mute), true)
end)

--=============================================================================
-- runtime — the heartbeat driver (emitted here, never waited for)
--=============================================================================

s:test("one heartbeat advances an application by TICK_MS and fires onTick once per interval", function(t)
    local target, ticks, elapsed = {}, 0, nil
    local h = Effect{ id = support.id("effect"), interval = BEAT, events = {
        onTick = function(_, _, ctx) ticks = ticks + 1; elapsed = ctx.elapsed end,
    } }

    h:apply(target)
    t:eq(ticks, 0, "apply alone does not tick")
    beats(1)
    t:eq(ticks, 1, "one beat, one onTick")
    t:near(elapsed, BEAT, 0.0001, "ctx.elapsed is one heartbeat in")
    beats(3)
    t:eq(ticks, 4, "and one more per beat after that")
    t:near(elapsed, BEAT * 4, 0.0001)

    h:remove(target)
end)

s:test("an interval shorter than the heartbeat catches up inside a single beat", function(t)
    local target, ticks = {}, 0
    local h = Effect{ id = support.id("effect"), interval = BEAT / 2, events = {
        onTick = function() ticks = ticks + 1 end,
    } }

    h:apply(target)
    beats(1)
    t:eq(ticks, 2, "half-beat interval fires twice per beat rather than dropping one")

    h:remove(target)
end)

s:test("an interval longer than the heartbeat waits for enough beats to accumulate", function(t)
    local target, ticks = {}, 0
    local h = Effect{ id = support.id("effect"), interval = BEAT * 2, events = {
        onTick = function() ticks = ticks + 1 end,
    } }

    h:apply(target)
    beats(1)
    t:eq(ticks, 0, "one beat is not enough")
    beats(1)
    t:eq(ticks, 1, "the second beat reaches the interval")
    beats(2)
    t:eq(ticks, 2, "and it keeps to every other beat")

    h:remove(target)
end)

s:test("duration expires the application on the beat it runs out, with reason 'duration'", function(t)
    local target, reason, ticks = {}, nil, 0
    local h = Effect{ id = support.id("effect"), duration = BEAT * 2, interval = BEAT, events = {
        onTick   = function() ticks = ticks + 1 end,
        onExpire = function(_, _, ctx) reason = ctx.reason end,
    } }

    h:apply(target)
    t:near(h:timeLeft(target), BEAT * 2, 0.0001, "the deadline starts at the full duration")
    beats(1)
    t:near(h:timeLeft(target), BEAT, 0.0001, "each beat spends one heartbeat of it")
    t:truthy(h:isActive(target))
    beats(1)
    t:falsy(h:isActive(target), "the beat that runs it out ends it")
    t:eq(reason, "duration")
    t:eq(ticks, 2, "onTick still ran on the expiring beat, before expiry")
    t:eq(h:timeLeft(target), 0)
    t:eq(h:stacksOn(target), 0)
end)

s:test("onExpire is told how long the application lived and how many stacks it held", function(t)
    local target, ctxSeen = {}, nil
    local h = Effect{ id = support.id("effect"), duration = BEAT, stackable = true, maxStacks = 2,
        events = { onExpire = function(_, _, ctx) ctxSeen = ctx end } }

    h:apply(target)
    h:apply(target)          -- second stack
    beats(1)
    t:truthy(ctxSeen, "onExpire fired")
    t:eq(ctxSeen.effect, h.id)
    t:eq(ctxSeen.stacks, 2, "the stack count at expiry")
    t:near(ctxSeen.elapsed, BEAT, 0.0001)
end)

s:test("a handler that raises is swallowed and the application keeps running", function(t)
    local target, ticks = {}, 0
    local h = Effect{ id = support.id("effect"), interval = BEAT, events = {
        onApply = function() error("onApply blew up") end,
        onTick  = function() ticks = ticks + 1; error("onTick blew up") end,
    } }

    t:eq(h:apply(target), true, "a throwing onApply does not fail the apply")
    t:truthy(h:isActive(target), "the application is registered regardless")
    beats(2)
    t:eq(ticks, 2, "and a throwing onTick is called again on the next beat")

    h:remove(target)
end)

s:test("a plain-table target is never treated as gone, even one whose IsValid says false", function(t)
    -- Only userdata is validity-checked; a table (what a test uses as a target) always
    -- counts as alive, so the "target_gone" path cannot be reached from Lua alone.
    local target = { IsValid = function() return false end }
    local reason = nil
    local h = Effect{ id = support.id("effect"), events = {
        onExpire = function(_, _, ctx) reason = ctx.reason end } }

    h:apply(target)
    beats(2)
    t:truthy(h:isActive(target), "still live after two beats")
    t:eq(reason, nil, "nothing expired it")

    h:remove(target)
end)

--=============================================================================
-- runtime — stacking
--=============================================================================

s:test("a stackable effect stacks up to maxStacks and fires onStack instead of onApply", function(t)
    local target, applied, stacked, lastStacks = {}, 0, 0, nil
    local h = Effect{ id = support.id("effect"), stackable = true, maxStacks = 3, duration = 10.0,
        events = {
            onApply = function() applied = applied + 1 end,
            onStack = function(_, _, ctx) stacked = stacked + 1; lastStacks = ctx.stacks end,
        } }

    h:apply(target)
    t:eq(h:stacksOn(target), 1)
    t:eq(applied, 1)
    h:apply(target)
    t:eq(h:stacksOn(target), 2, "a second apply stacks")
    t:eq(applied, 1, "onApply does NOT fire again")
    t:eq(stacked, 1, "onStack does")
    t:eq(lastStacks, 2, "and is told the new count")
    h:apply(target)
    t:eq(h:stacksOn(target), 3)
    h:apply(target)
    t:eq(h:stacksOn(target), 3, "maxStacks is a ceiling")
    t:eq(stacked, 3, "but onStack still fires on the capped re-apply")

    h:remove(target)
end)

s:test("onStack sees the caller's ctx the same way onApply does", function(t)
    local target, seen = {}, nil
    local h = Effect{ id = support.id("effect"), stackable = true, maxStacks = 2, duration = 10.0,
        events = { onStack = function(_, _, ctx) seen = ctx end } }

    h:apply(target, { source = "first" })
    h:apply(target, { source = "second" })
    t:truthy(seen)
    t:eq(seen.effect, h.id)
    t:eq(seen.stacks, 2)
    t:eq(seen.source, "second", "the re-apply's own ctx shows through")

    h:remove(target)
end)

s:test("a non-stackable effect still fires onStack on re-apply but stays at one stack", function(t)
    local target, applied, stacked = {}, 0, 0
    local h = Effect{ id = support.id("effect"), duration = 10.0, events = {
        onApply = function() applied = applied + 1 end,
        onStack = function() stacked = stacked + 1 end,
    } }

    h:apply(target)
    h:apply(target)
    t:eq(h:stacksOn(target), 1, "stackable = false keeps it at one")
    t:eq(applied, 1, "and re-applying is never a fresh onApply")
    t:eq(stacked, 1, "the re-apply is reported as a stack even so")

    h:remove(target)
end)

s:test("re-applying refreshes the remaining duration", function(t)
    local target = {}
    local h = Effect{ id = support.id("effect"), duration = BEAT * 4 }

    h:apply(target)
    beats(2)
    t:near(h:timeLeft(target), BEAT * 2, 0.0001, "two beats spent")
    h:apply(target)
    t:near(h:timeLeft(target), BEAT * 4, 0.0001, "re-apply puts the full duration back")

    h:remove(target)
end)

s:test("re-applying a duration-less effect leaves it indefinite", function(t)
    local target = {}
    local h = Effect{ id = support.id("effect") }
    h:apply(target)
    h:apply(target)
    t:eq(h:timeLeft(target), nil, "no duration to refresh to")
    t:truthy(h:isActive(target))

    h:remove(target)
end)

--=============================================================================
-- runtime — world unload
--=============================================================================

s:test("emitting world.left releases every live application with reason 'world_left'", function(t)
    -- The world going away is the one signal that ends applications wholesale, so this
    -- releases whatever ELSE was live too — acceptable because an effect is not persisted
    -- and a pack re-applies from its own triggers. Emitting the channel is all the
    -- ready-watch does; the live-instance teardown beside it is the watcher's own call,
    -- so no building is dropped out from under a loaded save.
    local targetA, targetB = {}, {}
    local reasons = {}
    local mk = function()
        return Effect{ id = support.id("effect"), duration = 100.0, events = {
            onExpire = function(_, _, ctx) reasons[#reasons + 1] = ctx.reason end } }
    end
    local a, b, g = mk(), mk(), mk()

    a:apply(targetA)
    b:apply(targetB)
    g:apply()                     -- the global bucket goes too

    event.emit("world.left")

    t:eq(#reasons, 3, "every live application expired")
    for _, r in ipairs(reasons) do
        t:eq(r, "world_left", "with its own reason, distinct from a duration expiry")
    end
    t:falsy(a:isActive(targetA))
    t:falsy(b:isActive(targetB))
    t:falsy(g:isActive())
    t:eq(#Effect.activeOn(targetA), 0, "and the bookkeeping is empty afterwards")
end)

s:test("a released application is not resurrected by later heartbeats", function(t)
    local target, ticks = {}, 0
    local h = Effect{ id = support.id("effect"), interval = BEAT, duration = 100.0,
        events = { onTick = function() ticks = ticks + 1 end } }

    h:apply(target)
    beats(1)
    t:eq(ticks, 1)
    event.emit("world.left")
    beats(3)
    t:eq(ticks, 1, "nothing ticks after the world is gone")
    t:falsy(h:isActive(target))
end)

--=============================================================================
-- live — the only test that needs a game
--=============================================================================

s:test("applies to the live player pawn and takes it off again", function(t)
    local pawn = support.needWorld(t)
    local applied, reason = 0, nil
    local h = Effect{ id = support.id("effect"), duration = 60.0, events = {
        onApply  = function() applied = applied + 1 end,
        onExpire = function(_, _, ctx) reason = ctx.reason end,
    } }

    -- Assertions run under pcall so the pawn never keeps an application when one fails.
    -- This effect declares no nativeStatus, so nothing native is toggled and the pawn is
    -- left exactly as it was found; the ailment path is exercised by the test below.
    local ok, err = pcall(function()
        t:eq(h:apply(pawn), true, "a userdata target applies like any other")
        t:eq(applied, 1)
        t:truthy(h:isActive(pawn))
        t:eq(h:stacksOn(pawn), 1)
        -- a live world has a real heartbeat running underneath, so the deadline is only
        -- asserted as "counting down from its duration", never as an exact figure
        local left = h:timeLeft(pawn)
        t:truthy(type(left) == "number" and left > 0 and left <= 60.0,
            "the deadline starts at the duration and counts down")
        local found = false
        for _, id in ipairs(Effect.activeOn(pawn)) do if id == h.id then found = true end end
        t:truthy(found, "activeOn reports it on the pawn")
    end)

    t:eq(h:remove(pawn), true, "and it comes straight back off")
    if not ok then error(err, 0) end
    t:eq(reason, "removed")
    t:falsy(h:isActive(pawn))
end)

s:test("a nativeStatus effect toggles the game's own ailment on the live pawn", function(t)
    local pawn = support.needWorld(t)

    -- AttackUp is chosen deliberately: it is a BUFF, so a run that somehow leaves it behind
    -- has done the tester a small favour rather than poisoning them. Nothing in this suite
    -- may set Poison, Burn or Coma on a real save.
    local STATUS = "AttackUp"
    t:truthy(status.known(STATUS), STATUS .. " must be an ailment this build declares")

    -- Ask the question directly first, before any effect is involved: can this pawn's status
    -- component be reached and read at all? nil is UNKNOWN, so it is a skip and not a failure —
    -- a build that will not answer is not a defect in the effect layer.
    local before = status.isActive(pawn, STATUS)
    if before == nil then
        t:skipUnanswerable("the status component could not be read on this pawn — see the "
            .. "[signature] log line for which lookup failed; that line IS the finding")
    end
    if before then
        t:skipNeedsSetup("the pawn already has " .. STATUS .. "; a clean before/after is not "
            .. "possible — wait for it to run out and press the key again")
    end

    local h = Effect{ id = support.id("effect"), duration = 60.0, nativeStatus = STATUS }

    -- Under pcall so the ailment is always taken back off, including when an assertion raises.
    local ok, err = pcall(function()
        t:eq(h:apply(pawn), true, "the effect applies")
        t:eq(status.isActive(pawn, STATUS), true,
            "and the game itself now reports " .. STATUS .. " on the pawn. A false here means the "
            .. "call fired but the ailment did not stick — check the [signature] evidence level")
    end)

    t:eq(h:remove(pawn), true, "the effect comes off")
    if not ok then error(err, 0) end
    t:eq(status.isActive(pawn, STATUS), false, "and the ailment goes with it")
end)

return s
