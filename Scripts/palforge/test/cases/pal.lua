-- palforge/test/cases/pal.lua — the pal domain: declaration, strictness, spawn routing.
--
-- What this suite proves: Pal{ ... } validates its declaration and lands every declared
-- field on the handle (and on the CLASS core/event dispatches to); the `events` map is
-- installed behind a forwarder that hands the handler THIS pal's HANDLE as its first
-- argument; an unknown field and an unknown event are hard errors, with a did-you-mean;
-- a nested Mesh{ ... } and an inline mesh table reach the same declaration; and iconOf
-- falls back to the declared icon when the DataTable lookup misses. Handle:spawn picks
-- its engine route from the SHAPE of its argument, and that dispatch is proved WITHOUT a
-- world by swapping core/spawn's three entry points for recorders and putting them back.
--
-- :teachAll is covered the same way: its `taught, asked` partial-result contract is proved
-- with core/character's write recorded, and the write itself — which needs a live pal and
-- changes a real save — is named as the test/hooks/pal-skills-equip hook rather than left
-- as an untested public function or a silent in-body return.
--
-- Only the last five tests need a game: three accepted spawns (ONE harmless chicken each
-- — nothing in-tree can despawn one, so the count stays at one per test) and :renderOn
-- against the player pawn. renderOn is deliberately exercised only on paths that CANNOT
-- change how the player looks — a pal with no mesh, and a model the engine cannot load —
-- because the skeletal backend swaps the pawn's mesh for real.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Pal     = require("palforge.api.pal")
local Mesh    = require("palforge.api.mesh")
local om      = require("palforge.core.object_manager")
local spawn   = require("palforge.core.spawn")
local character = require("palforge.core.character")

local s = T.suite("pal")

-- Every id this file defines is namespaced throwaway content, and defining is permanent:
-- hand it all back the moment this suite finishes rather than letting a run's worth of pals
-- sit in the registry while the remaining suites execute.
support.sweepAfter(s)

-- A model path that is guaranteed not to resolve: renderOn's live test must reach the
-- backend and fail there, never actually dress the player.
local NO_SUCH_MODEL = "/Game/PalForgeTest/DoesNotExist.DoesNotExist"

-- Run `body(rec)` with core/spawn's three engine routes replaced by recorders, so the
-- argument-shape dispatch inside Handle:spawn can be read off without a world. api/pal
-- indexes the module table at CALL time, so replacing the fields is enough. The routes
-- are always put back — including when an assertion raises mid-body, which is why the
-- body runs under pcall and the original error is re-raised unchanged (level 0 keeps the
-- fail/skip sentinel table intact for the runner).
local function withSpawnRecorder(body, verdict)
    if verdict == nil then verdict = true end
    local real = { pal = spawn.pal, palAt = spawn.palAt, palForPlayer = spawn.palForPlayer }
    local rec  = {}
    local function reset() for k in pairs(rec) do rec[k] = nil end end

    spawn.pal = function(id, level)
        reset(); rec.route, rec.id, rec.level = "pal", id, level
        return verdict
    end
    spawn.palAt = function(id, level, x, y, z)
        reset(); rec.route, rec.id, rec.level = "palAt", id, level
        rec.x, rec.y, rec.z = x, y, z
        return verdict
    end
    spawn.palForPlayer = function(id, num, level)
        reset(); rec.route, rec.id, rec.num, rec.level = "palForPlayer", id, num, level
        return verdict
    end

    local ok, err = pcall(body, rec)
    spawn.pal, spawn.palAt, spawn.palForPlayer = real.pal, real.palAt, real.palForPlayer
    if not ok then error(err, 0) end
end

--=============================================================================
-- definition: the module surface
--=============================================================================

s:test("every declared field lands on the handle and on the registered class", function(t)
    local id  = support.id("pal")
    local pal = Pal{
        id          = id,
        name        = "Test Pal",
        description = "a pal that exists only for this run",
        skills      = { "skill_a", "skill_b" },
        mesh        = { model = "/Game/PalForgeTest/SK_Test.SK_Test" },
        icon        = "/Game/PalForgeTest/T_Icon.T_Icon",
        data        = { mine = 42 },
    }

    t:eq(pal.id, id, "the handle carries the id it was defined with")
    t:eq(pal:name(), "Test Pal", "name() is the declared name")
    t:eq(pal:description(), "a pal that exists only for this run", "description() is declared")
    t:eq(#pal:skillsOf(), 2, "skillsOf() lists both declared skill ids")
    t:eq(pal:skillsOf()[1], "skill_a", "skill ids keep their declared order")
    t:eq(pal:mesh().model, "/Game/PalForgeTest/SK_Test.SK_Test", "mesh() is the declared mesh")

    -- `data` has no handle accessor: it is carried onto the definition CLASS, which is
    -- what core/event resolves and dispatches on, so read it the way core/event would.
    local cls = om.get("pal", id)
    t:truthy(cls, "the definition registers under ('pal', id) — how core/event finds it")
    t:eq(cls.data.mine, 42, "the free-form data payload is carried onto the definition")
end)

s:test("a pal with no name is displayed under its own id", function(t)
    local id  = support.id("pal")
    local pal = Pal{ id = id }
    t:eq(pal:name(), id, "name() falls back to the id")
    t:eq(pal:description(), nil, "an undeclared description stays nil")
    t:eq(#pal:skillsOf(), 0, "an undeclared skill list reads as empty, not nil")
    t:eq(pal:mesh(), nil, "an undeclared mesh stays nil")
end)

s:test("Pal.get hands back the registered definition as a fresh handle", function(t)
    local id      = support.id("pal")
    local defined = Pal{ id = id, name = "Fetched" }
    local fetched = Pal.get(id)

    t:neq(fetched, defined, "get() wraps the definition again rather than returning the same handle")
    t:eq(fetched:name(), "Fetched", "both handles stand for the one registered definition")
    t:eq(fetched.id, id, "the id survives the round trip")
end)

s:test("Pal.get on an unknown id returns a usable thin handle, never nil", function(t)
    local id  = support.id("ghost")
    local pal = Pal.get(id)

    t:truthy(pal, "get() never returns nil — any game CharacterID is spawnable")
    t:eq(pal.id, id, "the thin definition is keyed on the id asked for")
    t:eq(pal:name(), id, "with nothing declared, the name is the id")
    t:eq(pal:mesh(), nil, "a thin definition declares no mesh")
    t:eq(om.get("pal", id), nil, "looking a pal up does NOT register it")
end)

s:test("Pal.get demands a non-empty string id", function(t)
    t:errors(function() Pal.get("") end, "id (string) is required")
    t:errors(function() Pal.get(nil) end, "id (string) is required")
end)

s:test("Pal.get_all lists one entry per id, so a redefinition replaces rather than adds", function(t)
    local id     = support.id("pal")
    local before = #Pal.get_all()

    Pal{ id = id, name = "first" }
    Pal{ id = id, name = "second" }

    local all = Pal.get_all()
    t:eq(#all, before + 1, "two definitions under one id occupy one registry slot")
    t:eq(Pal.get(id):name(), "second", "the last definition under an id wins, silently")

    local found
    for _, h in ipairs(all) do if h.id == id then found = h end end
    t:truthy(found, "the new pal is listed by get_all")
    t:eq(found:name(), "second", "get_all hands out handles over the live definitions")
end)

s:test("a native catalog id resolves to its registered definition, mesh and all", function(t)
    pcall(require, "palforge.native.pals")   -- requiring the catalog is what registers it
    local pal = Pal.get(support.GAME.pal)
    t:eq(pal.id, support.GAME.pal, "the handle carries the game CharacterID")

    local m = pal:mesh()
    if not m then
        -- Directed as "this session could not answer": the catalog is a plain require, so a
        -- miss here is not something a world load or a title screen would change — it means
        -- native/pals.lua failed to load, and that is the finding.
        t:skipUnanswerable("native pal catalog not loaded; nothing registered under "
            .. support.GAME.pal .. " (require of palforge.native.pals failed)")
    end
    t:type(m.model, "string", "the curated definition declares a model")
    t:eq(m.kind, "skeletal", "a pal mesh defaults to the skeletal backend")
    t:neq(pal:name(), support.GAME.pal, "a registered definition carries its own display name")
end)

--=============================================================================
-- strictness — the whole point of the spec layer
--=============================================================================

s:test("id is required and its absence names the field", function(t)
    t:errors(function() Pal{} end, 'field "id" is required')
    t:errors(function() Pal{ name = "no id" } end, 'field "id" is required')
end)

s:test("an unknown field is a hard error with a did-you-mean", function(t)
    local msg = t:errors(function()
        Pal{ id = support.id("pal"), meshSpec = { model = "x" } }
    end, 'unknown field "meshSpec"')
    t:assert(msg:find('did you mean "mesh"?', 1, true),
        "the decorated name is matched back to the field it decorates")
    t:assert(msg:find("Valid fields:", 1, true), "and the whole field list is printed")
end)

s:test("an unknown event is rejected inside the events spec, by name", function(t)
    local msg = t:errors(function()
        Pal{ id = support.id("pal"), events = { onSpawn = function() end } }
    end, 'unknown field "onSpawn"')
    t:assert(msg:find("Pal.Spec.Events", 1, true),
        "the context names the nested spec to go and read")
    t:assert(msg:find('did you mean "onSpawned"?', 1, true), "near misses get a suggestion")

    -- An event nobody could have meant is still rejected, just without the hint.
    t:errors(function()
        Pal{ id = support.id("pal"), events = { whenTheMoonIsFull = function() end } }
    end, 'unknown field "whenTheMoonIsFull"')
end)

s:test("a wrongly typed field is rejected with the path to the offending value", function(t)
    t:errors(function()
        Pal{ id = support.id("pal"), skills = { "ok", 2 } }
    end, 'field "skills[2]" expects string, got number')
    t:errors(function()
        Pal{ id = support.id("pal"), events = { onDeath = "boom" } }
    end, 'field "onDeath" expects function, got string')
    t:errors(function() Pal{ id = "" } end, 'field "id" is invalid')
end)

--=============================================================================
-- mesh nesting — one shape, two spellings
--=============================================================================

s:test("a nested Mesh handle and an inline mesh table reach the same declaration", function(t)
    local model = "/Game/PalForgeTest/SK_Body.SK_Body"
    local anim  = "/Game/PalForgeTest/ABP_Body.ABP_Body_C"

    local body   = Mesh{ id = support.id("mesh"), model = model, animClass = anim }
    local nested = Pal{ id = support.id("pal"), mesh = body }
    local inline = Pal{ id = support.id("pal"), mesh = { model = model, animClass = anim } }

    t:eq(nested:mesh().model, inline:mesh().model, "the model survives both spellings")
    t:eq(nested:mesh().animClass, inline:mesh().animClass, "so does the anim class")
    t:eq(nested:mesh().kind, "skeletal", "and Mesh.Spec's default kind is filled in for both")
    t:eq(inline:mesh().kind, "skeletal", "the inline table is validated by the same spec")
    t:eq(nested:mesh().id, body.id, "a nested handle keeps the mesh's own id")
    t:neq(nested:mesh(), body:source(),
        "nesting COPIES: the pal cannot reach into the mesh definition it was handed")
end)

s:test("an inline mesh with no model is rejected by the nested Mesh spec", function(t)
    local msg = t:errors(function()
        Pal{ id = support.id("pal"), mesh = { scale = 2.0 } }
    end, 'field "model" is required')
    t:assert(msg:find("Mesh.Spec", 1, true), "the error says which nested shape complained")
end)

--=============================================================================
-- events — installed on the class core/event dispatches to
--=============================================================================

s:test("a declared handler is installed on the class and receives the HANDLE first", function(t)
    local id   = support.id("pal")
    local ctx  = { actor = { fake = true } }
    local seen = {}

    local pal = Pal{
        id     = id,
        events = {
            onSpawned  = function(self, c) seen.spawned  = { self, c } end,
            onDamaged  = function(self, c) seen.damaged  = { self, c } end,
            onDeath    = function(self, c) seen.death    = { self, c } end,
            onCaptured = function(self, c) seen.captured = { self, c } end,
            -- onTick is declarable but nothing drives it: pals have no instance scan, so
            -- this proves it is INSTALLED, not that the runtime ever fires it.
            onTick     = function(self, c) seen.tick     = { self, c } end,
        },
    }

    -- Exactly what core/event's dispatch does: resolve the class, then inst[hook](inst, ctx).
    local cls = om.get("pal", id)
    t:truthy(cls, "the definition is registered for dispatch")
    cls.onSpawned(cls, ctx)
    t:truthy(seen.spawned, "the declared onSpawned ran")
    t:eq(seen.spawned[1], pal, "the handler's first argument is the pal HANDLE, not the class")
    t:eq(seen.spawned[2], ctx, "the event context is passed through untouched")

    -- The handle forwards the same hooks for manual use, and always with the handle the
    -- define call returned — even when called through a DIFFERENT handle for the same id.
    Pal.get(id):onDamaged(ctx)
    t:eq(seen.damaged[1], pal, "a handler always gets the handle its define call returned")
    pal:onDeath(ctx);    t:truthy(seen.death, "onDeath forwards")
    pal:onCaptured(ctx); t:truthy(seen.captured, "onCaptured forwards")
    pal:onTick(ctx);     t:truthy(seen.tick, "onTick is installed, though no source fires it")
end)

s:test("an undeclared lifecycle hook is an inert no-op, not a nil call", function(t)
    local pal = Pal{ id = support.id("pal") }
    local ctx = { actor = {} }
    t:eq(pal:onSpawned(ctx), nil, "the base hook returns nothing")
    t:eq(pal:onDamaged(ctx), nil, "and never raises for a pal that declared no events")
    t:eq(pal:onDeath(ctx), nil, "same for death")
    t:eq(pal:onCaptured(ctx), nil, "same for capture")
    t:eq(pal:onTick(ctx), nil, "same for tick")
end)

--=============================================================================
-- icons + material
--=============================================================================

s:test("iconOf falls back to the declared icon when the DataTable lookup misses", function(t)
    -- The ids here are namespaced test ids, so the pal icon DataTable can never have a
    -- row for them — with or without a game running, this is the fallback path.
    local icon = "/Game/PalForgeTest/T_Icon.T_Icon"
    t:eq(Pal{ id = support.id("pal"), icon = icon }:iconOf(), icon,
        "the declared icon is what comes back")
    t:eq(Pal{ id = support.id("pal") }:iconOf(), nil,
        "no row and no declared icon is nil, not an error")
end)

s:test("the material block wins over the color/texture shorthands", function(t)
    local shorthandId = support.id("pal")
    Pal{ id = shorthandId, color = { 1, 0, 0, 1 }, texture = "C:/mods/test/skin.png" }
    local shorthand = om.get("pal", shorthandId):material()
    t:type(shorthand, "table", "the shorthands assemble a material descriptor")
    t:eq(shorthand.texture, "C:/mods/test/skin.png", "texture carries through")
    t:eq(shorthand.color[1], 1, "so does the tint")
    t:eq(shorthand.params, nil, "there is no shorthand spelling for params, so it stays nil")

    local fullId = support.id("pal")
    Pal{ id = fullId,
         color    = { 0, 0, 1, 1 },                    -- deliberately contradicts the block
         material = { color = { 0, 1, 0, 1 }, material = "/Game/M_Base.M_Base" } }
    local full = om.get("pal", fullId):material()
    t:eq(full.color[2], 1, "the declared material block is returned as-is")
    t:eq(full.material, "/Game/M_Base.M_Base", "including the base material path")

    local bareId = support.id("pal")
    Pal{ id = bareId }
    t:eq(om.get("pal", bareId):material(), nil,
        "a pal that declares neither has no material descriptor at all")
end)

--=============================================================================
-- :spawn — route selection by argument SHAPE (pure: the engine routes are recorded)
--=============================================================================

s:test("a coordinate — record or array — routes to spawn.palAt", function(t)
    local pal = Pal{ id = support.id("pal") }
    withSpawnRecorder(function(rec)
        pal:spawn({ x = 10, y = 20, z = 30 })
        t:eq(rec.route, "palAt", "{ x=, y=, z= } is a coordinate spawn")
        t:eq(rec.x, 10, "x reaches the engine route")
        t:eq(rec.y, 20, "y reaches the engine route")
        t:eq(rec.z, 30, "z reaches the engine route")
        t:eq(rec.level, nil, "no level was declared, so core/spawn gets to default it")

        pal:spawn({ 11, 22, 33 })
        t:eq(rec.route, "palAt", "the positional { x, y, z } form is a coordinate too")
        t:eq(rec.x, 11, "arg[1] is read as x")
        t:eq(rec.y, 22, "arg[2] is read as y")
        t:eq(rec.z, 33, "arg[3] is read as z")
    end)
end)

s:test("an opts table picks its route from the keys it carries", function(t)
    local pal = Pal{ id = support.id("pal") }
    withSpawnRecorder(function(rec)
        pal:spawn{ at = { x = 1, y = 2, z = 3 }, level = 7 }
        t:eq(rec.route, "palAt", "`at` is the coordinate route")
        t:eq(rec.level, 7, "and `level` rides along with it")
        t:eq(rec.x, 1, "the coordinate under `at` is unpacked the same way")

        pal:spawn{ toPlayer = true, num = 2, level = 5 }
        t:eq(rec.route, "palForPlayer", "`toPlayer` summons into the player's party/box")
        t:eq(rec.num, 2, "num is forwarded")
        t:eq(rec.level, 5, "level is forwarded")

        pal:spawn{ at = { x = 1, y = 2, z = 3 }, toPlayer = true }
        t:eq(rec.route, "palAt", "`at` is tested first, so it wins over `toPlayer`")
    end)
end)

s:test("no argument, or a non-table one, takes the default placement route", function(t)
    local pal = Pal{ id = support.id("pal") }
    withSpawnRecorder(function(rec)
        pal:spawn()
        t:eq(rec.route, "pal", "nothing declared is a wild spawn near the player")
        t:eq(rec.level, nil, "with no level to pass on")

        -- A string/number argument is NOT rejected: it simply never matches the table
        -- shapes and falls through to the default placement.
        pal:spawn("600,0,0")
        t:eq(rec.route, "pal", "a non-table argument is ignored rather than refused")

        pal:spawn{ level = 12 }
        t:eq(rec.route, "pal", "an opts table with no placement key is still a wild spawn")
        t:eq(rec.level, 12, "but its level is honoured")
    end)
end)

s:test(":spawn returns the engine route's verdict unchanged", function(t)
    local pal = Pal{ id = support.id("pal") }
    withSpawnRecorder(function()
        t:eq(pal:spawn(), false, "a route that refused is reported as false")
        t:eq(pal:spawn{ x = 1, y = 2, z = 3 }, false, "on the coordinate route too")
    end, false)
    withSpawnRecorder(function()
        t:eq(pal:spawn(), true, "and an accepted call comes back true")
    end, true)
end)

s:test(":spawn hands core/spawn the definition id verbatim, unresolved", function(t)
    -- A namespaced id is NOT turned into its DataTable row name ("pack:name" ->
    -- "pack_name") on the way to the engine. That is today's behaviour; if the id model
    -- ever reaches into :spawn, this is the test that notices.
    local id  = support.id("pal")
    local pal = Pal{ id = id }
    withSpawnRecorder(function(rec)
        pal:spawn()
        t:eq(rec.id, id, "the colon form is what core/spawn receives")
        t:assert(rec.id:find(":", 1, true) ~= nil, "colon and all")
    end)
end)

--=============================================================================
-- :teachAll — the partial-result contract (pure: core/character's write is recorded)
--
-- Until now this was one of the five public api functions with no coverage at all
-- (api/pal.lua:493). Its WRITE half cannot be measured here — it ends in
-- character.addSkill, which needs a live pal and mutates the tester's save — but the
-- contract that makes it worth calling is pure: `taught, asked` are reported SEPARATELY so
-- a partial result is visible, and a failure does not stop the ids after it. That half is
-- provable by swapping core/character's addSkill for a recorder, the same way the spawn
-- routes are recorded above; api/pal indexes the module at CALL time, so replacing the
-- field is enough. The write itself is named as a hook below rather than left untested.
--=============================================================================

-- Run `body(asked)` with core.character.addSkill replaced by a recorder whose verdict comes
-- from `verdictFor(id)`. The real function is always put back, including when an assertion
-- raises mid-body (level 0 keeps the fail/skip sentinel intact for the runner).
local function withAddSkillRecorder(verdictFor, body)
    local real = character.addSkill
    local asked = {}
    character.addSkill = function(actor, id)
        asked[#asked + 1] = { actor = actor, id = id }
        return verdictFor(id)
    end
    local ok, err = pcall(body, asked)
    character.addSkill = real
    if not ok then error(err, 0) end
end

s:test("teachAll on a pal that declares nothing asks for nothing and reports 0, 0", function(t)
    -- No stub: with an empty skill list the loop body never runs, so nothing engine-facing
    -- is reached even with a world loaded. Both zero is the documented "nothing declared".
    local pal = Pal{ id = support.id("pal") }
    local taught, asked = pal:teachAll({ IsValid = function() return true end })
    t:eq(taught, 0, "nothing was declared, so nothing was taught")
    t:eq(asked, 0, "and nothing was asked for either")
end)

s:test("teachAll reports taught and asked separately, so a partial result is visible", function(t)
    local pal = Pal{ id = support.id("pal"),
                     skills = { "skill_first", "skill_missing", "skill_last" } }
    local actor = { IsValid = function() return true end }

    withAddSkillRecorder(function(id) return id ~= "skill_missing" end, function(asked)
        local taught, count = pal:teachAll(actor)
        t:eq(count, 3, "asked is every id the pal DECLARES, landed or not")
        t:eq(taught, 2, "taught counts only the writes core/character verified")
        t:neq(taught, count, "a partial result stays visible instead of collapsing to a boolean")

        -- One unknown id must not cost a pal its other moves: the id AFTER the failure was
        -- still asked for. That sentence is in api/pal.lua's doc string; this is it measured.
        t:eq(#asked, 3, "the failure did not stop the loop")
        t:eq(asked[1].id, "skill_first", "ids are applied in declared order")
        t:eq(asked[2].id, "skill_missing", "including the one that refuses")
        t:eq(asked[3].id, "skill_last", "and the one after it is still attempted")
        t:eq(asked[1].actor, actor, "the actor is handed to core/character untouched")
    end)
end)

s:test("teachAll counts nothing when every write refuses, and still reports what it asked", function(t)
    -- The shape a title-screen call really has: core/character.addSkill logs and returns
    -- false when the target has no character parameters, so teachAll must answer 0 of N
    -- rather than raising or claiming success.
    local pal = Pal{ id = support.id("pal"), skills = { "a", "b" } }
    withAddSkillRecorder(function() return false end, function(asked)
        local taught, count = pal:teachAll(nil)
        t:eq(taught, 0, "no write landed")
        t:eq(count, 2, "but both declared ids were asked for")
        t:eq(#asked, 2, "and both really reached core/character")
    end)
end)

s:test("teachAll's WRITE half is measured by a hook, not by F1", function(t)
    -- Everything above is the pure contract. What is left — does addSkill really put a
    -- declared move onto a live pal — cannot be asserted from here: it needs a pal standing
    -- in the world and it writes into the tester's save. It is a DECLARED hook so it is
    -- traceable and runnable on demand, instead of a silent in-body return that leaves a
    -- green run looking like coverage.
    t:skipNeedsHook("pal-skills-equip",
        "teachAll's write half needs a live pal and mutates a real save; the same hook "
        .. "measures Skill.Handle:teach / :forget, which is the call underneath it")
end)

--=============================================================================
-- :renderOn — fail-soft everywhere (pure)
--=============================================================================

s:test(":renderOn refuses anything that is not a live actor", function(t)
    local pal = Pal{ id = support.id("pal"), mesh = { model = NO_SUCH_MODEL } }
    t:eq(pal:renderOn(nil), false, "no actor at all is false, not an error")
    t:eq(pal:renderOn({}), false, "a table with no IsValid is false")
    t:eq(pal:renderOn({ IsValid = function() return false end }), false, "a dead actor is false")
end)

s:test(":renderOn is false for a pal that declares no mesh", function(t)
    local pal   = Pal{ id = support.id("pal") }
    local actor = { IsValid = function() return true end }
    t:eq(pal:renderOn(actor), false, "there is nothing to attach, so nothing is claimed")
end)

s:test(":renderOn is false when the actor carries no mesh component", function(t)
    -- The skeletal backend needs actor.Mesh / actor:GetMesh(); a bare table has neither,
    -- so this is the whole attach path exercised down to its fail-soft return.
    local pal   = Pal{ id = support.id("pal"), mesh = { model = NO_SUCH_MODEL } }
    local actor = { IsValid = function() return true end }
    t:eq(pal:renderOn(actor), false, "an attach that could not run reports false")
end)

--=============================================================================
-- LIVE — needs a world. One pal per test, and never a mesh the player would wear.
--=============================================================================

-- THESE THREE USED TO ASSERT FALSE ON PURPOSE, on the belief that the wild route —
-- UPalCheatManager:SpawnMonster — was measured dead on this build. It is not: on 2026-07-26 the
-- coordinate form spawned a pal and placed it on the requested point off by 0 cm, ~5.9 s after
-- the call, twice in one press. The route works and always did; what was broken was a verdict
-- built on a world count taken in the statement after an ASYNCHRONOUS call. Those three false
-- assertions were the notification the old comment promised, and this is them being honoured.
--
-- WHAT THEY ASSERT NOW, and it is everything that is synchronously true: that the call was
-- ISSUED — core.signature matched SpawnMonster's live declaration on this build and the call ran
-- without raising. That is the whole of core/spawn's new contract for the world routes.
--
-- WHERE THE ARRIVAL EVIDENCE LIVES, since none of it can be asserted from here: the
-- [PalForge.spawn] log. A test function cannot block for six seconds — the suite runs on the
-- game thread, off a keypress — so asserting a pal exists would mean either freezing the game or
-- re-introducing the exact too-early measurement that produced the false alarm. core/spawn
-- instead watches for up to 20 looks after each of these calls and writes what it finds:
--   spawn.palAt: placed new pal at (...); it reads back (...), off by N (T s after the call)
--   spawn.pal <id>: N new PalCharacter in the world T s after the call
-- Read those lines after a live run; they arrive AFTER the suite has printed its summary.
--
-- A FALSE HERE IS NOW A REAL FINDING, which is why it fails rather than skips: either the live
-- declaration stopped matching (a game patch), or no PalCheatManager could be reached or
-- constructed in this session. core/spawn logs which of the two it was.
--
-- COST: each of the three really does add ONE ChickenPal to the tester's world, now that we know
-- they arrive. Nothing in-tree can despawn one; that is three chickens per live run, which is
-- the price of testing a spawn at all.
--
-- NOT COVERED, deliberately: the `toPlayer` form. core/spawn.palForPlayer goes to a different
-- object (APalPlayerState:RequestSpawnMonsterForPlayer) and nothing can watch a party/box, so a
-- live test of it would assert a side effect it cannot see while permanently adding a pal to the
-- tester's box. Its verdict is exercised without a world by the recorder tests above.

s:test("a coordinate spawn issues the native call and reports it", function(t)
    support.needWorld(t)
    local coord = support.inFront(600.0, 50.0)
    if not coord then
        t:skipUnanswerable("the player pawn's location could not be read, so there is no point "
            .. "to spawn in front of — a pawn exists (needWorld passed) and K2_GetActorLocation "
            .. "did not answer")
    end

    local pal = Pal.get(support.GAME.pal)   -- one chicken; nothing in-tree can despawn it
    local ok  = pal:spawn(coord)
    t:type(ok, "boolean", ":spawn reports a boolean verdict")
    t:eq(ok, true, "the call was issued: SpawnMonster's live declaration matched and it ran. "
        .. "The pal itself is ~6 s away and the placement line in the [PalForge.spawn] log is "
        .. "what says it arrived — nothing here can wait for it")

    -- The enumeration this test still exists to exercise: FindAllOf("PalCharacter") is how the
    -- deferred placement pass identifies the pal it has to move, and how it measures the
    -- read-back. It is the one piece of that pass reachable from a synchronous test, so prove
    -- it works even though the pal it will find is not here yet.
    support.needGlobal(t, "FindAllOf")   -- no enumeration global, no placement pass to prove
    local near = support.nearestPal(coord)
    if not near then
        t:skipUnanswerable("FindAllOf('PalCharacter') returned nothing enumerable, so the "
            .. "deferred placement pass has nothing to measure against in this session")
    end
    t:type(near.count, "number", "the world is enumerable, which is what the placement pass runs on")
    t:type(near.dist, "number", "and a distance to the requested point is measurable")
    t:type(near.pos.x, "number", "the nearest pal reports a world position")
end)

s:test("the opts form issues the call the same way", function(t)
    support.needWorld(t)
    local coord = support.inFront(700.0, 50.0)
    if not coord then
        t:skipUnanswerable("the player pawn's location could not be read, so there is no point "
            .. "to spawn in front of")
    end

    local ok = Pal.get(support.GAME.pal):spawn{ at = coord, level = 3 }
    t:type(ok, "boolean", "the opts form reports a boolean verdict too")
    t:eq(ok, true, "at + level reaches the same SpawnMonster call, so it is issued the same way")
end)

s:test("a spawn with no argument issues the call as well", function(t)
    support.needWorld(t)
    local ok = Pal.get(support.GAME.pal):spawn()
    t:type(ok, "boolean", "the default form reports a boolean verdict")
    -- The plain wild route is the ONE spawn form whose pal has never actually been seen to
    -- arrive: it makes the identical call, but every run that watched it looked at 1.2 s and
    -- gave up. core/spawn now watches it on the same schedule that caught the coordinate form,
    -- so the "spawn.pal ChickenPal: ..." line in the log of this very run is the answer.
    t:eq(ok, true, "the wild route is the same SpawnMonster call, so it is issued the same way")
end)

s:test(":renderOn leaves the player pawn alone when there is no mesh to attach", function(t)
    local pawn = support.needWorld(t)
    local pal  = Pal{ id = support.id("pal") }   -- no mesh declared
    t:eq(pal:renderOn(pawn), false, "a valid pawn is not enough — there must be a mesh")
end)

s:test(":renderOn will not dress the player with a model the engine cannot load", function(t)
    local pawn = support.needWorld(t)
    -- Deliberately an unloadable path: the backend bails BEFORE it touches the pawn's
    -- mesh component, so the player keeps their own body. Never point this at a real
    -- asset — the skeletal backend would swap the player's mesh for real.
    local pal = Pal{ id = support.id("pal"), mesh = { model = NO_SUCH_MODEL } }
    t:eq(pal:renderOn(pawn), false, "an asset that will not load is a fail-soft false")
end)

return s
