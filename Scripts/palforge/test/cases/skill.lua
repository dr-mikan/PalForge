-- palforge/test/cases/skill.lua — the skill domain: define, lookup, manual invocation.
--
-- Every claim here is pure Lua, because that is the honest state of the domain: no native
-- source fires a skill, so nothing in api/skill.lua reaches the engine except iconOf's
-- DataTable probe. The suite proves the shape (strict spec, kind default, carried fields),
-- the four handlers getting the DEFINING handle, and the cooldown — that it blocks the
-- second immediate :activate, that :cooldownLeft reports a sane remainder, that it is
-- per-owner, and that :hit / :equip / :unequip step around it. Only the last test needs a
-- world, and only to prove the live icon lookup fails soft; it skips at the title screen.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Skill   = require("palforge.api.skill")
local character = require("palforge.core.character")

local s = T.suite("skill")

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

    -- :activate is pcall's ok flag, not the handler's value — a caller that wants the
    -- return has to go through :onActivate.
    t:eq(sk:activate({}), true, "activate reports that the handler ran, not what it returned")
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
-- LIVE — needs a world. These are what turn pal-skills-equip from a hypothesis
-- into an answer, so they are written to be informative even when they fail.
--=============================================================================

s:test("the live pawn's own skill lists are readable -- TODO(pal-skills-equip)", function(t)
    local pawn = support.needWorld(t)

    -- The read half on its own is worth a test: it walks the whole route — an actor, through
    -- PalUtility, to the character's individual parameters, and back out through two different
    -- getters. If this works and a write below does not, the problem is authority, not reach.
    local skills = character.skillsOn(pawn)
    if skills == nil then
        t:skip("the character parameters could not be read on this pawn — the [signature] log line "
            .. "names which lookup failed, and that line IS the finding")
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
            -- what it should. That distinction is the whole of TODO(pal-skills-equip) now.
            support.log(string.format("skills: the nearest pal carries %d active, %d passive, "
                .. "%d equipable, %d mastered", #theirs.active, #theirs.passive,
                #(theirs.equipable or {}), #(theirs.mastered or {})))
        end
    end
end)

-- OFF BY DEFAULT, AND THE REASON IS A CRASH — with a detail that has since changed its meaning.
-- The one run that performed this write was followed by Palworld closing about 1.4 seconds
-- later; the run before it, which wrote nothing, completed.
--
-- What is now known: that write did NOT necessarily go to a pal. It used the old nearbyPal,
-- which searched PalCharacter and so matched villagers and merchants as readily as pals — and
-- the read-back it consulted afterwards was an NPC's empty list, which is why it concluded the
-- write had not landed. Writing an equipped MOVE onto a villager is a far more plausible way to
-- destabilise the game than writing one onto a pal, so the crash may say nothing about this
-- capability and everything about that target. The search is fixed; the experiment has not been
-- re-run.
--
-- It stays opt-in anyway. The correlation is unexplained rather than explained away, this writes
-- into a character in the player's real save, and F1 is a key they press constantly. A test that
-- MIGHT take the game down is not worth running unattended for a question that can wait.
--
-- To run it deliberately, set the flag from the UE4SS console and press F1:
--     _G.PALFORGE_TEST_WRITE_WAZA = true
-- Do that on a throwaway save, with a pal you do not mind losing.
--
-- The read half above still runs every time and is where the useful signal now is: if a real
-- pal reports zero equipped moves, the read is not reaching what it should, and that is a
-- better lead than any write result.
s:test("an active skill can be taught to a live PAL and taken back off -- TODO(pal-skills-equip)", function(t)
    support.needWorld(t)
    if not _G.PALFORGE_TEST_WRITE_WAZA then
        t:skip("writing a move to a live pal is opt-in: it correlates with a crash and has never "
            .. "been seen to land. Set _G.PALFORGE_TEST_WRITE_WAZA = true on a throwaway save to run it")
    end

    -- ON A PAL, NOT ON THE PLAYER, and that distinction is a finding rather than a preference.
    -- The first live run taught Human_Punch to the player pawn: the call fired with evidence
    -- "declared" and the read-back did not show it. The same run also printed "the pawn carries
    -- 0 active and 0 passive" — a player has no equipped moves at all, because moves belong to
    -- pals and a player fights with weapons. So the write may well have been correct and simply
    -- meaningless on that target, and testing it there could never tell the two apart.
    local pal, palClass = support.nearbyPal()
    if not pal then
        t:skip("no pal near the player — whistle one out and run this again; the player pawn is "
            .. "the wrong target for equipped moves and would not answer the question")
    end
    support.log("skills: teaching against a " .. tostring(palClass))
    if character.skillsOn(pal) == nil then t:skip("character parameters unreadable on that pal") end

    -- Human_Punch is chosen deliberately: it is the plainest move in the game, so a run that
    -- somehow leaves it behind changes nothing anyone would notice. Nothing in this suite may
    -- teach a real save a legendary move.
    local SKILL = "Human_Punch"
    local sk = Skill.get(SKILL)
    local pawn = pal
    local had = false
    for _, n in ipairs(character.skillsOn(pal).active) do if n == SKILL then had = true end end
    if had then t:skip("that pal already has " .. SKILL .. "; a clean before/after is not possible") end

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
