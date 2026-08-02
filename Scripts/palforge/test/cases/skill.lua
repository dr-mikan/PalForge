-- palforge/test/cases/skill.lua — the skill domain: define, lookup, manual invocation.
--
-- Every claim here is pure Lua, and that is still the honest place to test this domain: the
-- four native skill sources core/event.lua arms on 2026-07-26 cannot be driven from a test
-- (only the game can call PlayActionByWazaID), so what IS tested is everything between the
-- channel and the handler — emit a skill channel by hand and prove the dispatch resolves the
-- definition and calls it with the right subject. The suite proves the shape (strict spec,
-- kind default, carried fields), the four handlers getting the DEFINING handle, the BUS route
-- into them, and the cooldown — that it blocks the second immediate :activate, that
-- :cooldownLeft reports a sane remainder, that it is per-owner, and that :hit / :equip /
-- :unequip step around it. Only two tests need a world; they skip at the title screen.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Skill   = require("palforge.api.skill")
local event   = require("palforge.core.event")
local character = require("palforge.core.character")
local logmod  = require("palforge.utils.log")

local s = T.suite("skill")

-- Hand every namespaced definition this file registers back to the registry as soon as the
-- suite finishes; object_manager has no expiry, so nothing else would.
support.sweepAfter(s)

-- Long enough that a second :activate in the same test can never fall outside it, so no
-- test ever waits on a clock. Nothing here sleeps.
local LONG_CD = 60.0

s:test("a skill needs only an id, and everything else has an inert default", function(t)
    local id = support.id("skill")
    local sk = Skill{ id = id }

    t:eq(sk.id, id, "the handle carries the id it was defined with")
    t:eq(sk:kind(), "active", "kind defaults to active")
    t:eq(sk:name(), id, "name falls back to the id")
    t:eq(sk:description(), nil, "no description was declared")
    t:eq(sk:element(), nil, "no element was declared")
    t:eq(sk:power(), nil, "no power was declared")
    t:eq(sk:cooldownLeft(), 0, "a skill with no cooldown is never cooling down")
    t:eq(sk:activate(), true, "the base onActivate is a no-op that still reports fired")
end)

s:test("an unknown field is a hard error with a did-you-mean", function(t)
    local id = support.id("skill")
    local msg = t:errors(function() Skill{ id = id, cooldownSeconds = 1 } end,
        "unknown field")
    t:assert(msg:find('did you mean "cooldown"', 1, true) ~= nil,
        "the suggestion points at the field that was meant, got: " .. msg)
end)

s:test("id is required and kind is checked against its value list", function(t)
    t:errors(function() Skill{} end, 'field "id" is required')
    t:errors(function() Skill{ id = "" } end, "is invalid")
    t:errors(function() Skill{ id = support.id("skill"), kind = "ultimate" } end,
        'must be one of { "active", "passive" }')
    t:errors(function() Skill{ id = support.id("skill"), cooldown = "3" } end,
        "expects number, got string")
end)

s:test("a handler the spec does not name is a hard error listing the four it does", function(t)
    local msg = t:errors(function()
        Skill{ id = support.id("skill"), events = { onFire = function() end } }
    end, 'unknown field "onFire"')
    t:assert(msg:find("onActivate, onHit, onEquip, onUnequip", 1, true) ~= nil,
        "the error names the accepted handlers, got: " .. msg)

    t:errors(function()
        Skill{ id = support.id("skill"), events = { onActivate = 5 } }
    end, "expects function, got number")
end)

s:test("name, description, element and power are carried onto the definition", function(t)
    local id = support.id("skill")
    local sk = Skill{
        id = id, name = "Test Bolt", description = "a bolt, for testing",
        kind = "active", element = "fire", power = 12.5,
    }
    t:eq(sk:name(), "Test Bolt", "the declared name wins over the id")
    t:eq(sk:description(), "a bolt, for testing", "the description is readable back")
    t:eq(sk:element(), "fire", "the element is readable back")
    t:eq(sk:power(), 12.5, "the power is readable back")
    t:eq(sk:kind(), "active", "an explicit kind is kept")
end)

s:test("the declared cooldown is what :cooldownLeft counts down from", function(t)
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD }
    local owner = {}

    t:eq(sk:cooldownLeft(owner), 0, "nothing has fired yet")
    t:eq(sk:activate(owner), true, "the first activate fires")

    local left = sk:cooldownLeft(owner)
    -- The suite runs in milliseconds, so the remainder must still be essentially the
    -- whole cooldown; the window is there for os.clock's granularity, not for waiting.
    t:assert(left > LONG_CD - 1.0 and left <= LONG_CD,
        "cooldownLeft is just under the declared cooldown, got " .. tostring(left))
end)

s:test("Skill.get returns the defined class for a known id and a thin one for an unknown", function(t)
    local id = support.id("skill")
    local defined = Skill{ id = id, kind = "passive", element = "ice", power = 7 }

    local got = Skill.get(id)
    t:neq(got, defined, "get() wraps the registered class in a NEW handle")
    t:eq(got.id, id, "the handle is for the id asked for")
    t:eq(got:kind(), "passive", "it sees the registered definition, not a blank one")
    t:eq(got:element(), "ice", "carried fields come back through get()")
    t:eq(got:power(), 7, "carried fields come back through get()")

    -- No registration, no game row: still a usable handle rather than nil.
    local unknown = Skill.get("palforge_test_no_such_skill_row")
    t:assert(unknown ~= nil, "get() of an unregistered id is never nil")
    t:eq(unknown:kind(), "active", "a thin definition takes the class defaults")
    t:eq(unknown:name(), "palforge_test_no_such_skill_row", "its name falls back to its id")
    t:eq(unknown:power(), nil, "a thin definition declares nothing")

    t:errors(function() Skill.get("") end, "id (string) is required")
    t:errors(function() Skill.get(nil) end, "id (string) is required")
end)

s:test("Skill.get_all lists every PalForge-defined skill as a handle", function(t)
    local id = support.id("skill")
    Skill{ id = id }

    local all = Skill.get_all()
    t:type(all, "table", "get_all returns a list")

    local mine
    for _, h in ipairs(all) do
        t:type(h.activate, "function", "every entry is a handle, not a raw class")
        if h.id == id then mine = h end
    end
    t:assert(mine ~= nil, "the skill just defined is in the list")
end)

s:test("the four handlers receive the handle the definition returned", function(t)
    local seen = {}
    local sk
    sk = Skill{
        id = support.id("skill"),
        events = {
            onActivate = function(self, owner, ctx) seen.activate = { self, owner, ctx } end,
            onHit      = function(self, target, ctx) seen.hit     = { self, target, ctx } end,
            onEquip    = function(self, owner, ctx) seen.equip    = { self, owner, ctx } end,
            onUnequip  = function(self, owner, ctx) seen.unequip  = { self, owner, ctx } end,
        },
    }

    local owner, target = {}, {}
    sk:activate(owner)
    sk:hit(target)
    sk:equip(owner)
    sk:unequip(owner)

    for _, name in ipairs({ "activate", "hit", "equip", "unequip" }) do
        local call = seen[name]
        t:assert(call ~= nil, "on" .. name .. " ran")
        t:eq(call[1], sk, "on" .. name .. " got the skill handle as self")
        t:type(call[3], "table", "on" .. name .. " got a ctx table even though none was passed")
    end
    t:eq(seen.activate[2], owner, "onActivate got the owner")
    t:eq(seen.hit[2], target, "onHit got the target")
    t:eq(seen.equip[2], owner, "onEquip got the owner")
    t:eq(seen.unequip[2], owner, "onUnequip got the owner")
end)

s:test("declaring onHit WARNS at define time, because nothing will ever call it", function(t)
    -- skill-hit-source, closed as a negative: the game does not report which move did a hit on
    -- this build — both candidate sources are measured silent AND nothing in the damage path
    -- carries a waza id, so there is no third source to find. An author who writes onHit and is
    -- told nothing learns it from a silence, weeks later, which is the failure shape this whole
    -- tree exists to abolish. It WARNS rather than raising (unlike Audio.Spec.soundFile, which
    -- was actively harmful): :hit(target) really does run the handler, so a pack that drives its
    -- own combat bookkeeping is entitled to declare one.
    -- utils.log has addSink and no removeSink, so the sink installed here is made harmless
    -- rather than removed — the mesh suite's pattern, for the same reason.
    local seen, recording = {}, true
    logmod.addSink(function(level, scope, msg)
        if recording and level == "warn" and scope == "skill" and #seen < 32 then
            seen[#seen + 1] = msg
        end
    end)

    local id = support.id("skill")
    local sk = Skill{ id = id, events = { onHit = function() end } }
    t:truthy(sk, "it is still DEFINED — the warning is advice, not a refusal")
    t:eq(sk:hit({}), true, "and :hit(target) still runs the handler, which is the point")

    local hit
    for _, msg in ipairs(seen) do
        if msg:find(id, 1, true) and msg:find("onHit", 1, true) then hit = msg end
    end
    t:truthy(hit, "a warning naming the id and the handler was logged")
    t:truthy(hit and hit:find("skill-hit-source", 1, true),
        "and it names the measurement behind it: " .. tostring(hit))
    t:truthy(hit and hit:find("onActivate", 1, true),
        "and points at the channel that DOES fire: " .. tostring(hit))

    -- The other three handlers are all live, so declaring them says nothing.
    local before = #seen
    Skill{ id = support.id("skill"), events = {
        onActivate = function() end, onEquip = function() end, onUnequip = function() end } }
    Skill{ id = support.id("skill") }
    local after = #seen
    recording = false
    t:eq(after, before, "a definition without onHit warns about nothing")
end)

s:test("core.event declares a channel for every one of the four handlers", function(t)
    local want = { ["skill.activate"] = "onActivate", ["skill.hit"] = "onHit",
                   ["skill.equip"] = "onEquip", ["skill.unequip"] = "onUnequip" }
    for _, name in ipairs(event.CHANNELS) do want[name] = nil end
    local missing = {}
    for name in pairs(want) do missing[#missing + 1] = name end
    table.sort(missing)
    t:eq(#missing, 0, "a handler with no channel can never fire: " .. table.concat(missing, ", "))
end)

s:test("emitting a skill channel reaches the DEFINED skill with the right subject", function(t)
    -- This is the half of the 導線 a test can own. The other half — whether the game calls
    -- PlayActionByWazaID / MakeDamageInfoByWazaType / Add|RemovePassiveSkill — is what F8's
    -- watch probe is for, and no assertion here can stand in for it.
    --
    -- The four skill.* channels only reach a definition once core/event's DISPATCH is
    -- installed. In game the kernel has already done it — registry.initialize() calls
    -- event.start() long before F1 loads this file — so this line is a no-op there; start() is
    -- idempotent. It is here because a HEADLESS run has no kernel, and the suites are loaded in
    -- registration order: skill comes before item, which is the one file that was ensuring
    -- this (test/cases/item.lua's dispatchReady, for the identical reason on the item.*
    -- channels), so every assertion below failed for want of a subscriber rather than for
    -- anything about skills. Same fact, same fix, stated in both places.
    pcall(function() event.start() end)

    local id = support.id("skill")
    local seen = {}
    local sk = Skill{ id = id, events = {
        onActivate = function(self, owner, ctx) seen.activate = { self, owner, ctx } end,
        onHit      = function(self, target, ctx) seen.hit     = { self, target, ctx } end,
        onEquip    = function(self, owner, ctx) seen.equip    = { self, owner, ctx } end,
        onUnequip  = function(self, owner, ctx) seen.unequip  = { self, owner, ctx } end,
    } }

    local owner, target = {}, {}
    event.emit("skill.activate", { skillId = id, owner = owner })
    event.emit("skill.hit",      { skillId = id, target = target })
    event.emit("skill.equip",    { skillId = id, owner = owner })
    event.emit("skill.unequip",  { skillId = id, owner = owner })

    for _, name in ipairs({ "activate", "hit", "equip", "unequip" }) do
        t:assert(seen[name] ~= nil, "skill." .. name .. " dispatched to on" .. name)
        t:eq(seen[name][1], sk, "the handler got the DEFINING handle as self, not the class")
    end
    -- The subject is what separates these four from every other channel in the bus: onHit is
    -- handed the TARGET and the other three the owner, so a shared two-argument dispatcher
    -- would silently shift every handler's arguments by one.
    t:eq(seen.activate[2], owner, "onActivate got ctx.owner")
    t:eq(seen.hit[2], target, "onHit got ctx.target, NOT the owner")
    t:eq(seen.equip[2], owner, "onEquip got ctx.owner")
    t:eq(seen.unequip[2], owner, "onUnequip got ctx.owner")
    t:eq(seen.activate[3].skillId, id, "the whole ctx is handed through as the third argument")
end)

s:test("a skill channel for an id nobody DEFINED dispatches to nothing", function(t)
    -- Skill.get materialises a thin handle that is never registered, so the game firing a
    -- vanilla move reaches no handler at all. That is the rule pals and items follow too, and
    -- it is why a pack has to Skill{ ... } an id rather than Skill.get it.
    local id = support.id("skill")
    local sk = Skill.get(id)
    local ran = false
    sk._cls.onActivate = function() ran = true end

    local ok = pcall(event.emit, "skill.activate", { skillId = id, owner = {} })
    t:truthy(ok, "an unresolvable skill ctx is a no-op, not an error")
    t:falsy(ran, "an unregistered id resolves to nothing, so nothing runs")

    -- And a ctx with no skillId at all cannot key anything either.
    t:truthy(pcall(event.emit, "skill.hit", { target = {} }), "a ctx with no skillId is inert")
end)

s:test("an explicit ctx is handed through to the handler untouched", function(t)
    local got
    local ctx = { reason = "test" }
    local sk = Skill{ id = support.id("skill"),
        events = { onActivate = function(_, _, c) got = c end } }

    sk:activate({}, ctx)
    t:eq(got, ctx, "the very table passed in reaches the handler")
end)

s:test(":activate reports a boolean and discards whatever the handler returned", function(t)
    local sk = Skill{ id = support.id("skill"),
        events = { onActivate = function() return 42, "extra" end } }

    -- :activate is "the handler ran", not the handler's value — a caller that wants the
    -- return has to go through :onActivate. The ONE exception is a literal false, which is
    -- how a handler reports that it could not do the thing (the next test).
    t:eq(sk:activate({}), true, "activate reports that the handler ran, not what it returned")

    local nils = Skill{ id = support.id("skill"), events = { onActivate = function() end } }
    t:eq(nils:activate({}), true, "a handler that returns nothing at all still means it ran")

    local truthy = Skill{ id = support.id("skill"),
        events = { onActivate = function() return "done" end } }
    t:eq(truthy:activate({}), true, "and so does any other truthy value")
end)

s:test("a handler that returns false makes :activate answer false WITH THE REASON", function(t)
    -- THE HONESTY RULE, and the reason the item skill-projectile-spawn could close: nothing
    -- returns true for a thing that did not happen. A boolean alone cannot express "ran, and
    -- deliberately produced nothing", so a handler opts in by returning false — and the reason
    -- it names travels out to the caller instead of being swallowed.
    local sk = Skill{ id = support.id("skill"), events = {
        onActivate = function() return false, "the door was already open" end } }

    local ran, why = sk:activate({})
    t:eq(ran, false, "the handler's own refusal is the answer, not pcall's ok flag")
    t:eq(why, "the door was already open", "and its reason is handed to the caller verbatim")

    -- A handler that refuses without saying why still gets a reason, because a bare false
    -- would be exactly the silent no this whole change is against.
    local mute = Skill{ id = support.id("skill"),
        events = { onActivate = function() return false end } }
    local ran2, why2 = mute:activate({})
    t:eq(ran2, false, "a bare false is still a refusal")
    t:type(why2, "string", "and it is never reasonless")
    t:assert(why2:find("named no reason", 1, true) ~= nil,
        "the stand-in says the handler gave none, got: " .. tostring(why2))
end)

s:test("every false from :activate carries an English reason", function(t)
    -- The three refusals the framework itself issues. A caller must be able to tell a passive
    -- from a cooldown from a raiser without reading the source.
    local passive = Skill{ id = support.id("skill"), kind = "passive" }
    local ran, why = passive:activate({})
    t:eq(ran, false, "a passive is not fired")
    t:assert(why:find("passive", 1, true) ~= nil, "and says so: " .. tostring(why))

    local cd = Skill{ id = support.id("skill"), cooldown = LONG_CD }
    local owner = {}
    t:eq(cd:activate(owner), true, "the first activate fires")
    local ran2, why2 = cd:activate(owner)
    t:eq(ran2, false, "the second is blocked")
    t:assert(why2:find("cooling down", 1, true) ~= nil,
        "and names the cooldown and the remainder: " .. tostring(why2))

    local boom = Skill{ id = support.id("skill"), events = {
        onActivate = function() error("deliberate: an author's handler blew up") end } }
    local ran3, why3 = boom:activate({})
    t:eq(ran3, false, "a raising handler is not a fired skill")
    t:assert(why3:find("raised", 1, true) ~= nil, "and the error text comes with it: "
        .. tostring(why3))
    t:assert(why3:find("deliberate", 1, true) ~= nil,
        "including the author's own message: " .. tostring(why3))
end)

s:test("spawnProjectile REFUSES, names the measurement, and never claims a spawn", function(t)
    -- skill-projectile-spawn, closed as a negative on 2026-08-02: the running build declared
    -- the parameter list of all six candidate routes and every one takes a struct, which is the
    -- argument shape that faults inside UE4SS's marshalling where pcall cannot see it. The item
    -- is closed by this refusal EXISTING and being callable — a missing function reads as "not
    -- found yet", and this reads as "measured, and here is by what".
    local sk = Skill{ id = support.id("skill") }
    local spawned, why = sk:spawnProjectile({})
    t:eq(spawned, false, "nothing is ever spawned on this build")
    t:type(why, "string", "and the refusal is never a bare false")
    for _, phrase in ipairs({ "skill-projectile-spawn", "2026-08-02", "struct" }) do
        t:assert(why:find(phrase, 1, true) ~= nil,
            "the reason names " .. phrase .. ", got: " .. why)
    end
    t:eq(Skill.projectileRefusal(), why, "and the module-level string is the same one sentence")

    -- The shape a pack author is told to copy: ask, and hand the refusal back out. What must
    -- NOT happen is the old behaviour — a handler that produced no projectile and an :activate
    -- that answered true for it anyway.
    local demo = Skill{ id = support.id("skill"), events = {
        onActivate = function(self, owner) return self:spawnProjectile(owner) end } }
    local ran, reason = demo:activate({})
    t:eq(ran, false, "a skill that could not produce its effect does not report that it did")
    t:eq(reason, why, "and the caller is handed the same measured reason")
end)

s:test("the SHIPPED demo skill does not claim a fireball it never produced", function(t)
    -- native.skills' curated "FlameThrower" is the definition the open item was marked inside,
    -- and it is what a pack author copies. It used to log that it had spawned nothing and hand
    -- back TRUE with a cooldown stamped for it — the one place in this tree where a return value
    -- said yes to something that did not happen. This pins the fix on the real definition and
    -- not just on a locally-built stand-in.
    local skills = require("palforge.native.skills")
    local ran, why = skills.Fireball:activate({ })
    t:eq(ran, false, "the demo reports that it produced nothing")
    t:type(why, "string", "with a reason")
    t:eq(why, Skill.projectileRefusal(), "and the reason is the measured refusal, verbatim")

    -- It is the same handle Skill.get and the named field answer with, so nobody reaches a
    -- different, more optimistic FlameThrower by another route.
    t:eq(skills.get("FlameThrower"), skills.Fireball, "get() hands back the curated handle")
    t:eq(skills.FlameThrower, skills.Fireball, "and so does the named field")
end)

s:test(":onActivate called directly returns the handler's value and skips the cooldown", function(t)
    local calls = 0
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD,
        events = { onActivate = function() calls = calls + 1; return 42 end } }
    local owner = {}

    t:eq(sk:onActivate(owner, {}), 42, "the raw event forwards the handler's return value")
    t:eq(sk:onActivate(owner, {}), 42, "and it is not gated by the cooldown")
    t:eq(calls, 2, "both direct calls reached the handler")
    t:eq(sk:cooldownLeft(owner), 0, "the raw event does not stamp the clock either")
end)

s:test("a cooldown blocks the second immediate :activate", function(t)
    local calls = 0
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD,
        events = { onActivate = function() calls = calls + 1 end } }
    local owner = {}

    t:eq(sk:activate(owner), true, "the first activate fires")
    t:eq(sk:activate(owner), false, "the second is refused while cooling down")
    t:eq(sk:activate(owner), false, "and stays refused")
    t:eq(calls, 1, "the handler ran exactly once")
end)

s:test("a cooldown of zero or none never blocks", function(t)
    local zero = Skill{ id = support.id("skill"), cooldown = 0 }
    t:eq(zero:activate({}), true, "first")
    t:eq(zero:activate({}), true, "a zero cooldown is no cooldown")

    local none = Skill{ id = support.id("skill") }
    local owner = {}
    t:eq(none:activate(owner), true, "first")
    t:eq(none:activate(owner), true, "an undeclared cooldown is no cooldown")
    t:eq(none:cooldownLeft(owner), 0, "and nothing is ever left to wait for")
end)

s:test("the cooldown is per owner, so two pals fire the same skill independently", function(t)
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD }
    local a, b, c = {}, {}, {}

    t:eq(sk:activate(a), true, "a fires")
    t:eq(sk:activate(b), true, "b is not blocked by a's cooldown")
    t:eq(sk:activate(a), false, "a is still cooling down")
    t:eq(sk:activate(b), false, "and so is b, on its own clock")

    t:assert(sk:cooldownLeft(a) > 0, "a has time left")
    t:assert(sk:cooldownLeft(b) > 0, "b has time left")
    t:eq(sk:cooldownLeft(c), 0, "an owner that never fired it is ready")
    t:eq(sk:activate(c), true, "and can fire")

    -- No owner at all is its own bucket, not a shared one.
    t:eq(sk:cooldownLeft(), 0, "the ownerless bucket is untouched by any owner")
    t:eq(sk:activate(), true, "the ownerless activate fires")
    t:eq(sk:activate(), false, "and then cools down like any other")
end)

-- A-1 / contract C1. Every owner above is a plain Lua table, and a plain Lua table IS
-- identity-stable — so the cooldown table looked up correctly here while doing NOTHING in a
-- world: UE4SS mints a fresh userdata wrapper per lookup, Lua indexes a table by userdata
-- identity, and `lastFire` was keyed on the owner handle. :activate(pawn) stamped the clock
-- under whichever wrapper the caller held, and the next :activate — reached through a pawn
-- from a later FindAllOf, or from an event's ctx.owner — found an empty bucket and fired
-- immediately. A declared cooldown was simply ignored, silently, for every engine owner.
-- The stand-in is the mesh suite's: two Lua values answering ONE GetFullName are exactly
-- what two references to one pawn are.
local function stubOwner(name)
    return { IsValid = function() return true end, GetFullName = function() return name end }
end

s:test("two handles onto one owner share one cooldown: the clock is stamped under the full name", function(t)
    local NAME = "BP_ChickenPal_C /Game/Test/Level:PersistentLevel.BP_ChickenPal_C_4"
    local a1, a2 = stubOwner(NAME), stubOwner(NAME)
    t:neq(a1, a2, "two DIFFERENT Lua values, which is what UE4SS really hands out")

    local calls = 0
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD,
        events = { onActivate = function() calls = calls + 1 end } }

    t:eq(sk:activate(a1), true, "the first activate fires")
    -- THE ASSERTIONS THE OLD KEY COULD NOT PASS.
    t:eq(sk:activate(a2), false, "the second is refused through a DIFFERENT handle onto the "
        .. "same pal, which is the only shape a live caller ever has")
    t:eq(calls, 1, "so the handler really ran once, not twice")
    t:assert(sk:cooldownLeft(a2) > 0, "and cooldownLeft reports the remainder through it too")

    -- A different pal is still a different bucket: the fix must not collapse every owner
    -- into one clock, which a naive "just use one key" would.
    local other = stubOwner("BP_ChickenPal_C /Game/Test/Level:PersistentLevel.BP_ChickenPal_C_5")
    t:eq(sk:activate(other), true, "another pal is not blocked by this one's cooldown")
end)

s:test("an owner that will not answer its own name still gets a cooldown bucket", function(t)
    -- uo.key is nil for it and `t[nil]` raises, so the fallback is the handle itself — the
    -- pre-C1 behaviour for that one object, which still works for the caller holding it.
    local mute = { IsValid = function() return true end }
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD }
    t:eq(sk:activate(mute), true, "the first activate fires")
    t:eq(sk:activate(mute), false, "and the same value is refused the second time")
end)

s:test("two handles over the same definition share one cooldown", function(t)
    local id = support.id("skill")
    local sk = Skill{ id = id, cooldown = LONG_CD }
    local again = Skill.get(id)
    local owner = {}

    t:eq(sk:activate(owner), true, "fired through the defining handle")
    t:eq(again:activate(owner), false, "the second handle sees the same (class, owner) clock")
    t:assert(again:cooldownLeft(owner) > 0, "and reports the same remainder")
end)

s:test("a handler reached through Skill.get still gets the DEFINING handle as self", function(t)
    local id = support.id("skill")
    local seen
    local sk = Skill{ id = id, events = { onActivate = function(self) seen = self end } }

    local got = Skill.get(id)
    got:activate({})
    -- The forwarder closes over the handle define() built, so `self` is that one — NOT
    -- the handle you happened to call through. Only the id is guaranteed to match.
    t:eq(seen, sk, "self is the handle the define call returned")
    t:neq(seen, got, "not the handle the call was made on")
    t:eq(seen.id, got.id, "both stand for the same skill")
end)

s:test("a passive skill never activates and never spends its cooldown", function(t)
    local calls = 0
    local sk = Skill{ id = support.id("skill"), kind = "passive", cooldown = LONG_CD,
        events = { onActivate = function() calls = calls + 1 end } }
    local owner = {}

    t:eq(sk:activate(owner), false, "a passive skill is not something you fire")
    t:eq(calls, 0, "onActivate never ran")
    t:eq(sk:cooldownLeft(owner), 0, "and the clock was not touched, so nothing is blocked later")
end)

s:test(":hit, :equip and :unequip ignore both the cooldown and the kind", function(t)
    local hits, equips, unequips = 0, 0, 0
    local sk = Skill{ id = support.id("skill"), kind = "passive", cooldown = LONG_CD,
        events = {
            onHit     = function() hits     = hits     + 1 end,
            onEquip   = function() equips   = equips   + 1 end,
            onUnequip = function() unequips = unequips + 1 end,
        } }
    local owner = {}

    t:eq(sk:equip(owner), true, "equip runs on a passive")
    t:eq(sk:equip(owner), true, "and again immediately")
    t:eq(sk:hit(owner), true, "hit runs on a passive")
    t:eq(sk:hit(owner), true, "and again immediately")
    t:eq(sk:unequip(owner), true, "unequip runs on a passive")
    t:eq(sk:unequip(owner), true, "and again immediately")

    t:eq(hits, 2, "every hit reached the handler")
    t:eq(equips, 2, "every equip reached the handler")
    t:eq(unequips, 2, "every unequip reached the handler")
    t:eq(sk:cooldownLeft(owner), 0, "none of them stamped the cooldown")
end)

s:test("a skill with no handlers at all is a no-op that still reports success", function(t)
    local sk = Skill{ id = support.id("skill") }
    t:eq(sk:activate({}), true, "the base onActivate is inert")
    t:eq(sk:hit({}), true, "the base onHit is inert")
    t:eq(sk:equip({}), true, "the base onEquip is inert")
    t:eq(sk:unequip({}), true, "the base onUnequip is inert")
end)

s:test("a handler that raises is swallowed: false back, cooldown already spent", function(t)
    local sk = Skill{ id = support.id("skill"), cooldown = LONG_CD,
        events = {
            onActivate = function() error("deliberate: an author's handler blew up") end,
            onHit      = function() error("deliberate: an author's handler blew up") end,
            onEquip    = function() error("deliberate: an author's handler blew up") end,
            onUnequip  = function() error("deliberate: an author's handler blew up") end,
        } }
    local owner = {}

    t:eq(sk:activate(owner), false, "a raising handler is reported as not fired")
    t:assert(sk:cooldownLeft(owner) > 0,
        "the clock is stamped BEFORE the handler runs, so a raiser still consumed it")
    t:eq(sk:hit(owner), false, "a raising onHit is caught, not propagated")
    t:eq(sk:equip(owner), false, "a raising onEquip is caught, not propagated")
    t:eq(sk:unequip(owner), false, "a raising onUnequip is caught, not propagated")
end)

s:test("iconOf falls back to the declared icon when the DataTable lookup misses", function(t)
    -- The id is namespaced, so no skill icon row can ever exist for it: this exercises
    -- the miss path both headless (no engine) and in a save (a real table, no row).
    local withIcon = Skill{ id = support.id("skill"), icon = "/Game/PalForge/Test/T_Icon.T_Icon" }
    t:eq(withIcon:iconOf(), "/Game/PalForge/Test/T_Icon.T_Icon",
        "the declared icon is returned when nothing resolves")

    local without = Skill{ id = support.id("skill") }
    t:eq(without:iconOf(), nil, "no declared icon and no row means nil, not an error")

    t:eq(Skill.get("palforge_test_no_such_skill_row"):iconOf(), nil,
        "a thin definition has no icon to fall back to either")
end)

s:test("with a world loaded, iconOf still fails soft against the real icon DataTable", function(t)
    support.needWorld(t)

    -- Same claim as above, but now StaticFindObject really can return the partner-skill
    -- icon table: the row lookup must miss quietly rather than throw into the caller.
    local sk = Skill{ id = support.id("skill"), icon = "/Game/PalForge/Test/T_Icon.T_Icon" }
    t:eq(sk:iconOf(), "/Game/PalForge/Test/T_Icon.T_Icon",
        "a live DataTable probe that misses still yields the declared fallback")
end)

--=============================================================================
-- teaching a live character — the game's own skill lists
--=============================================================================

s:test("an id is routed by what the GAME knows it as, not by the skill's declared kind", function(t)
    -- Palworld stores active and passive skills separately, so :teach has to pick one. It picks
    -- on the id: a name in the game's active-skill enum is an active skill, anything else is
    -- treated as a passive name. `kind` describes YOUR skill's behaviour and deliberately has
    -- no say here — this asks the game for one of its own.
    t:truthy(character.isActiveSkill("FireBlast"), "a real game move is recognised as active")
    t:truthy(character.isActiveSkill("fireblast"), "and the lookup does not care about case")
    t:truthy(character.isActiveSkill(1), "an integer is taken as the enum value it is")
    t:falsy(character.isActiveSkill("Legend"), "a passive name is not an active skill")
    t:falsy(character.isActiveSkill("example:MyOwnSkill"), "and neither is a pack's own id")

    -- Declaring kind="passive" must not turn a real active move into a passive one.
    local active = Skill{ id = support.id("skill"), kind = "passive" }
    t:falsy(character.isActiveSkill(active.id), "a pack id stays a passive whatever it declares")
end)

s:test("the active-skill vocabulary is the whole enum, not a curated handful", function(t)
    local names = character.wazaNames()
    t:truthy(#names > 300, "every skill the build declares is addressable, got " .. #names)
    local seen = {}
    for _, n in ipairs(names) do
        t:type(n, "string", "every entry is a name a pack can write")
        t:falsy(seen[n], "and no name is listed twice: " .. n)
        seen[n] = true
    end
    t:falsy(seen["None"], "the None sentinel is not offered as a skill")
end)

s:test("teach and forget refuse honestly when there is no character to write to", function(t)
    -- No world, so nothing resolves to a character parameter object. Every entry point must
    -- answer without raising, and must distinguish "could not ask" from "no".
    local sk = Skill.get("FireBlast")
    t:eq(sk:teach({}), false, "teach reports false rather than raising")
    t:eq(sk:forget({}), false, "and so does forget")
    t:eq(sk:skillsOn({}), nil, "skillsOn answers nil — UNKNOWN, never an empty character")
    t:eq(sk:teach(nil), false, "a nil target is refused the same way")
end)

s:test("equip is still your own bookkeeping and never touches the game", function(t)
    -- :equip and :teach mean different things on purpose. :equip runs YOUR handler on ANY
    -- value; :teach writes to a real character. This pins that separation, because quietly
    -- making :equip write to the game would change what every existing pack's handler means.
    local ran = 0
    local sk  = Skill{ id = support.id("skill"), kind = "passive",
                       events = { onEquip = function() ran = ran + 1 end } }
    t:eq(sk:equip("not an actor at all"), true, "equip works on a value that is not a character")
    t:eq(ran, 1, "and it ran the pack's handler")
    t:eq(sk.teach ~= nil, true, "the game-facing pair exists alongside it")
end)

--=============================================================================
-- LIVE — needs a world. These are what turned pal-skills-equip from a hypothesis
-- into an answer (8 pass / 0 fail, 2026-08-02, test/hooks/pal_skills_equip.lua),
-- and they stay here as the regression: they are written to be informative even
-- when they fail, because a failure now is news.
--=============================================================================

s:test("the live pawn's own skill lists are readable", function(t)
    local pawn = support.needWorld(t)

    -- The read half on its own is worth a test: it walks the whole route — an actor, through
    -- PalUtility, to the character's individual parameters, and back out through two different
    -- getters. If this works and a write below does not, the problem is authority, not reach.
    local skills = character.skillsOn(pawn)
    if skills == nil then
        t:skipUnanswerable("the character parameters could not be read on this pawn — the "
            .. "[signature] log line names which lookup failed, and that line IS the finding")
    end
    t:type(skills.active, "table", "the active-skill list comes back as a list")
    t:type(skills.passive, "table", "and so does the passive one")
    support.log(string.format("skills: the player pawn carries %d active and %d passive",
        #skills.active, #skills.passive))

    -- And a real pal, when one is nearby, because that is the character equipped moves belong
    -- to. A player carrying zero is normal; a PAL carrying zero would say the read is not
    -- reaching what it should.
    local pal, palClass = support.nearbyPal()
    if pal then
        local theirs = character.skillsOn(pal)
        if theirs then
            support.log("skills: the nearest pal is a " .. tostring(palClass))
            -- All four lists, because the useful question is which of them are empty. A wild pal
            -- with nothing EQUIPPED but a non-empty mastered/equipable list is a correct read of
            -- a pal that simply has no loadout; all four empty means the read is not reaching
            -- what it should. That distinction is what the pal-skills-equip run turned on, and
            -- it is why all four are printed rather than just `active`.
            support.log(string.format("skills: the nearest pal carries %d active, %d passive, "
                .. "%d equipable, %d mastered", #theirs.active, #theirs.passive,
                #(theirs.equipable or {}), #(theirs.mastered or {})))
        end
    end
end)

-- ⭐ THE WRITE LANDS, AND THE GAME STAYS UP. Measured 2026-08-02 in a real save by
-- test/hooks/pal_skills_equip.lua on a live PalMonsterCharacter — 8 pass / 0 fail. AddEquipWaza
-- put Human_Punch on the pal and the read-back saw it, :forget took it off, teachAll answered
-- `2, 2`, and ClearEquipWaza cleared the loadout and every move was restored and verified.
--
-- THE OLD CRASH BELONGED TO THE TARGET, NOT TO THE WRITE. The one earlier run that wrote was
-- followed by Palworld closing about 1.4 seconds later; it used the old nearbyPal, which
-- searched PalCharacter and so matched villagers and merchants as readily as pals — and the
-- read-back it consulted afterwards was an NPC's empty list, which is why it also concluded the
-- write had not landed. Writing an equipped MOVE onto a villager is a far more plausible way to
-- destabilise the game than writing one onto a pal. The search is fixed (support.nearbyPal asks
-- PalMonsterCharacter), and the fixed search is what the 8-pass run used.
--
-- IT STAYS OFF BY DEFAULT ANYWAY, and the reason is no longer doubt about the answer: this
-- writes into a character in the player's real save, and F1 is a key they press constantly.
-- Mutating someone's save unattended is not something a passing suite should do.
--
-- To run it deliberately, arm the opt-in and press F1. EITHER SPELLING WORKS:
--     env.debugHooks["pal-skills-equip"] = true   -- in Scripts/palforge_dev.lua (the canonical
--                                                 -- one; tools/deploy.sh writes that file and
--                                                 -- the same switch arms the declared hook)
--     _G.PALFORGE_TEST_WRITE_WAZA = true          -- from the UE4SS console (the older one)
-- Do that on a throwaway save, with a pal you do not mind losing.
--
-- The read half above still runs every time and is where the useful signal now is: if a real
-- pal reports zero equipped moves, the read is not reaching what it should, and that is a
-- better lead than any write result.
s:test("an active skill can be taught to a live PAL and taken back off", function(t)
    support.needWorld(t)
    -- THE OPT-IN HAS TWO SPELLINGS AND THE QUESTION IS ASKED WHERE BOTH ARE KNOWN.
    -- `env.debugHooks["pal-skills-equip"]` is the canonical switch (env.lua, and what
    -- tools/deploy.sh writes into Scripts/palforge_dev.lua); `_G.PALFORGE_TEST_WRITE_WAZA` is
    -- the older one that core/character.lua's skills section and the comment above both name.
    -- test/hooks/init.lua's writeAllowed() is the single place that honours both, so it is
    -- asked rather than re-implemented here: a tester who armed the canonical switch and then
    -- watched F1 skip anyway would have no way to tell that from the write being refused for a
    -- real reason, and "the switch was on and nothing happened" is precisely the failure shape
    -- this whole explicit-skip regime exists to abolish. Requiring that module is safe with
    -- env.debug off — writeAllowed reads a table and a global and declares nothing.
    local armed = false
    pcall(function() armed = require("palforge.test.hooks").writeAllowed("pal-skills-equip") end)
    if not armed then
        -- Named as a HOOK rather than a bare skip, because "off by default" has to stay
        -- traceable to something that can actually be run. test/hooks/pal-skills-equip is the
        -- declared, gated route for exactly this write (C7: needs a world and a pal, writes,
        -- so it also wants env.debugHooks["pal-skills-equip"]).
        t:skipNeedsHook("pal-skills-equip",
            "writing a move to a live pal is opt-in: the write is measured landing (8 pass / 0 "
            .. "fail, 2026-08-02) but it mutates the loaded save. Set "
            .. "env.debugHooks[\"pal-skills-equip\"] = true (or the older "
            .. "_G.PALFORGE_TEST_WRITE_WAZA = true) on a throwaway save to run it from F1 instead")
    end

    -- ON A PAL, NOT ON THE PLAYER, and that distinction is a finding rather than a preference.
    -- The first live run taught Human_Punch to the player pawn: the call fired with evidence
    -- "declared" and the read-back did not show it. The same run also printed "the pawn carries
    -- 0 active and 0 passive" — a player has no equipped moves at all, because moves belong to
    -- pals and a player fights with weapons. So the write may well have been correct and simply
    -- meaningless on that target, and testing it there could never tell the two apart.
    local pal, palClass = support.nearbyPal()
    if not pal then
        t:skipNeedsSetup("no pal near the player — whistle one out and run this again; the "
            .. "player pawn is the wrong target for equipped moves and would not answer the "
            .. "question")
    end
    support.log("skills: teaching against a " .. tostring(palClass))
    if character.skillsOn(pal) == nil then
        t:skipUnanswerable("character parameters unreadable on that pal — the [signature] line "
            .. "names the lookup that failed")
    end

    -- Human_Punch is chosen deliberately: it is the plainest move in the game, so a run that
    -- somehow leaves it behind changes nothing anyone would notice. Nothing in this suite may
    -- teach a real save a legendary move.
    local SKILL = "Human_Punch"
    local sk = Skill.get(SKILL)
    local pawn = pal
    local had = false
    for _, n in ipairs(character.skillsOn(pal).active) do if n == SKILL then had = true end end
    if had then
        t:skipNeedsSetup("that pal already has " .. SKILL
            .. "; a clean before/after is not possible — run it against a different pal")
    end

    -- Under pcall so the skill is always taken back off, including when an assertion raises.
    local ok, err = pcall(function()
        t:eq(sk:teach(pawn), true, "teach reports true only when the read-back SAW the skill on "
            .. "the character. A false means the write did not land — check the [signature] "
            .. "evidence level: 'declared' plus a false points at server authority")
    end)

    local gone = sk:forget(pawn)
    if not ok then error(err, 0) end
    t:eq(gone, true, "and forget takes it off again, verified the same way")
end)

return s
