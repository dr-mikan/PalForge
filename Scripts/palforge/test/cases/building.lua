-- palforge/test/cases/building.lua — the building domain: definition, spec, handle.
--
-- Proves the DEFINITION side of api/building end to end without a world: what
-- Building{ ... } accepts and rejects, what it puts on the registered class, that the mesh
-- field really is the derived Building.Spec.Mesh (static by default, every other field
-- inherited from Mesh.Spec), that every declared event installs over the inert base hook,
-- and what the Handle queries answer. Only the last two tests need a world, and only to
-- read: they look at the structures the player has ALREADY placed, because there is no api
-- to place or destroy one and a test must never ask the player to build something. Nothing
-- here writes a save, attaches a mesh to a real actor, or unlocks anything.
local T        = require("palforge.core.unittests")
local support  = require("palforge.test.support")
local Building = require("palforge.api.building")
local Mesh     = require("palforge.api.mesh")
local schema   = require("palforge.core.schema")
local om       = require("palforge.core.object_manager")
local event    = require("palforge.core.event")
local spatial  = require("palforge.core.spatial")

local s = T.suite("building")

-- The registered class behind a handle. Reading it through object_manager rather than
-- through handle._cls asserts the registration itself — that is the seam core/event uses
-- to find a definition on its next scan.
local function classOf(id)
    return om.get("building", id)
end

-- Every event name Building.Spec.Events declares, in declaration order.
local function eventNames()
    local out = {}
    for _, f in ipairs(schema.get("Building.Spec.Events").fields) do out[#out + 1] = f.name end
    return out
end

--=============================================================================
-- definition + lookup
--=============================================================================

s:test("defining a building registers the class and returns a handle carrying its id", function(t)
    local id = support.id("building")
    local h  = Building{ id = id, name = "Test Bench", description = "one line" }

    t:type(h, "table", "Building{ ... } returns a handle")
    t:eq(h.id, id, "the handle carries the id it was defined with")
    t:eq(h:name(), "Test Bench")
    t:eq(h:description(), "one line")
    t:truthy(classOf(id), "the definition class is registered under (\"building\", id)")
    t:eq(classOf(id).id, id)
end)

s:test("name defaults to the id and description stays nil when neither is declared", function(t)
    local id = support.id("building")
    local h  = Building{ id = id }
    t:eq(h:name(), id, "an undeclared name reads back as the id")
    t:eq(h:description(), nil)
end)

s:test("get returns the registered definition, and a thin handle for an id nobody defined", function(t)
    local id = support.id("building")
    Building{ id = id, name = "Registered" }
    t:eq(Building.get(id):name(), "Registered", "get finds the definition that was registered")

    -- Never nil: an undefined id yields a thin definition over the game build id, so a
    -- pack can act on a vanilla structure it never declared.
    local thin = Building.get(support.id("unregistered"))
    t:truthy(thin, "get is never nil")
    t:eq(thin:name(), thin.id, "a thin handle names itself after its id")
    t:eq(thin:mesh(), nil, "a thin handle declares no mesh")
end)

s:test("get rejects a missing or empty id rather than handing back a nameless handle", function(t)
    t:errors(function() Building.get(nil) end, "id (string) is required")
    t:errors(function() Building.get("") end, "id (string) is required")
end)

s:test("get_all lists every registered definition, including one defined just now", function(t)
    local id = support.id("building")
    Building{ id = id }

    local found = false
    local all = Building.get_all()
    t:type(all, "table")
    for _, h in ipairs(all) do
        if h.id == id then found = true; break end
    end
    t:truthy(found, "the definition just made is in get_all()")
end)

--=============================================================================
-- spec fields
--=============================================================================

s:test("gridCm is only what the author declared - the handle never substitutes the default", function(t)
    local declared = support.id("building")
    Building{ id = declared, gridCm = 250 }
    t:eq(Building.get(declared):gridCm(), 250)

    -- The fallback lives in core/event's buildDef (cls.gridCm or spatial.GRID_CM), not on
    -- the handle: an undeclared gridCm reads back as nil, and the runtime quantizes at
    -- spatial.GRID_CM. Asserting nil here is the tripwire if the default ever moves up.
    local bare = support.id("building")
    Building{ id = bare }
    t:eq(Building.get(bare):gridCm(), nil, "an undeclared gridCm stays nil on the definition")
    t:eq(classOf(bare).gridCm, nil)
    t:eq(spatial.GRID_CM, 100, "the runtime fallback the scan applies instead")
end)

s:test("buildIds replaces the default { id } and must be an array of strings", function(t)
    local id = support.id("building")
    Building{ id = id, buildIds = { "Workbench", "WorkBench_SkillUnlock" } }

    local ids = classOf(id).buildIds
    t:type(ids, "table")
    t:eq(#ids, 2, "both claimed game ids are carried onto the class")
    t:eq(ids[1], "Workbench")
    t:eq(ids[2], "WorkBench_SkillUnlock")

    -- Undeclared it stays nil; core/event substitutes { id } when it builds the def.
    local bare = support.id("building")
    Building{ id = bare }
    t:eq(classOf(bare).buildIds, nil)

    t:errors(function() Building{ id = support.id("building"), buildIds = { "ok", 3 } } end,
        "field \"buildIds[2]\" expects string, got number")
end)

s:test("tickInterval defaults to 1 and is carried onto the registered class", function(t)
    local bare = support.id("building")
    Building{ id = bare }
    t:eq(classOf(bare).tickInterval, 1, "the schema fills the default at define time")
    t:eq(schema.get("Building.Spec"):field("tickInterval").default, 1)

    local slow = support.id("building")
    Building{ id = slow, tickInterval = 20, events = { onTick = function() end } }
    t:eq(classOf(slow).tickInterval, 20, "a declared interval survives onto the class")
end)

s:test("a state table is shared by every instance while a state factory gives each its own", function(t)
    -- A plain table is carried by REFERENCE onto the class, so every instance the scan
    -- creates would hand the very same table to its handlers.
    local shared  = { uses = 0 }
    local tableId = support.id("building")
    Building{ id = tableId, state = shared }
    t:eq(classOf(tableId).defaultState, shared, "the declared table is the class's defaultState")

    -- A factory is what makes per-instance state possible. core/event's scan resolves it
    -- exactly like this — `ds(def.cls)` once per newly tracked structure — so calling it
    -- twice here is the same thing two placements would do, minus the world.
    local facId = support.id("building")
    Building{ id = facId, state = function() return { uses = 0 } end }
    local cls = classOf(facId)
    t:type(cls.defaultState, "function", "a factory is stored as-is, not called at define time")

    local a = cls.defaultState(cls)
    local b = cls.defaultState(cls)
    t:type(a, "table")
    t:type(b, "table")
    t:neq(a, b, "each call builds a fresh table, so two structures cannot share state")
    a.uses = 7
    t:eq(b.uses, 0, "mutating one instance's state leaves the other alone")
end)

s:test("state accepts only a table or a factory", function(t)
    t:errors(function() Building{ id = support.id("building"), state = "nope" } end,
        "field \"state\" expects table|function, got string")
end)

s:test("data is carried through untouched for the pack's own payload", function(t)
    local id      = support.id("building")
    local payload = { recipe = "wood", tier = 2 }
    Building{ id = id, data = payload }
    t:eq(classOf(id).data, payload, "the free-form payload reaches the class by reference")
end)

--=============================================================================
-- mesh: the derived Building.Spec.Mesh
--=============================================================================

s:test("the mesh field is validated as Building.Spec.Mesh, derived from Mesh.Spec", function(t)
    local base    = schema.get("Mesh.Spec")
    local derived = schema.get("Building.Spec.Mesh")
    t:truthy(derived, "Building.Spec.Mesh is declared in the schema registry")
    t:eq(schema.get("Building.Spec"):field("mesh").of, derived,
        "the mesh field points at the derived spec, not at a re-declared copy")

    -- Derivation, not duplication: same fields, same order, so a field added to Mesh.Spec
    -- reaches buildings with nobody remembering to copy it.
    t:eq(#derived.fields, #base.fields, "every Mesh.Spec field is inherited")
    for i, f in ipairs(base.fields) do
        t:eq(derived.fields[i].name, f.name, "field " .. i .. " keeps its name and position")
    end
    t:eq(derived:field("model").required, true, "model stays required through the derivation")
end)

s:test("an inline mesh gets kind \"static\" - a structure is not a skeletal pal", function(t)
    t:eq(schema.get("Building.Spec.Mesh"):field("kind").default, "static")
    t:eq(schema.get("Mesh.Spec"):field("kind").default, "skeletal",
        "the base default the building overrides")

    local id = support.id("building")
    local h  = Building{ id = id, mesh = { model = "/Game/Test/SM_X.SM_X" } }
    local m  = h:mesh()
    t:type(m, "table")
    t:eq(m.kind, "static", "the derived default is filled in at define time")
    t:eq(m.model, "/Game/Test/SM_X.SM_X")
end)

s:test("a mesh without a model, or with a kind no backend has, is a hard error", function(t)
    t:errors(function() Building{ id = support.id("building"), mesh = { kind = "static" } } end,
        "field \"model\" is required")
    -- the `values` list is inherited from Mesh.Spec along with everything else
    local text = t:errors(function()
        Building{ id = support.id("building"), mesh = { model = "/X.X", kind = "bogus" } }
    end, "must be one of")
    t:truthy(text:find("procedural", 1, true), "the error lists the kinds a backend exists for")
end)

s:test("a named Mesh handle nests into a building and keeps the kind it was defined with", function(t)
    -- The handle's __spec metafield is what lets it pass validation as a plain table; the
    -- kind it already carries is present, so the building's "static" default never applies.
    local meshId = support.id("mesh")
    local m = Mesh{ id = meshId, model = "/Game/Test/SK_Y.SK_Y" }

    local id = support.id("building")
    local h  = Building{ id = id, mesh = m }
    t:eq(h:mesh().model, "/Game/Test/SK_Y.SK_Y", "the nested declaration reaches the definition")
    t:eq(h:mesh().kind, "skeletal", "a defined mesh keeps its own kind, defaults and all")
    t:eq(h:mesh().id, meshId, "and its name, so the source is still identifiable")
end)

--=============================================================================
-- events
--=============================================================================

s:test("every event Building.Spec.Events declares installs over the inert base handler", function(t)
    local names, handlers, spec = eventNames(), {}, {}
    t:eq(#names, 10, "the declared lifecycle is ten hooks")
    for _, name in ipairs(names) do
        local fn = function() return name end
        handlers[name] = fn
        spec[name] = fn
    end

    local id = support.id("building")
    Building{ id = id, events = spec }
    local cls = classOf(id)

    for _, name in ipairs(names) do
        t:type(Building.Class[name], "function", name .. " has an inert default on the base class")
        t:eq(cls[name], handlers[name], name .. " is installed as-is on the definition")
        t:neq(cls[name], Building.Class[name],
            name .. " overrides the base, which is how core/event detects the hook")
    end
end)

s:test("a definition that declares no events inherits the base class's inert hooks", function(t)
    local id = support.id("building")
    Building{ id = id }
    local cls = classOf(id)
    for _, name in ipairs(eventNames()) do
        t:eq(cls[name], Building.Class[name], name .. " resolves to the inert base default")
    end
end)

s:test("an unknown event is a hard error with a did-you-mean", function(t)
    t:errors(function()
        Building{ id = support.id("building"), events = { onPlaced = function() end } }
    end, "unknown field \"onPlaced\" (did you mean \"onPlace\"?)")
end)

s:test("an event handler must be callable", function(t)
    t:errors(function()
        Building{ id = support.id("building"), events = { onTick = "soon" } }
    end, "field \"onTick\" expects function, got string")
end)

s:test("the handle forwards the eight per-structure events but not the two world hooks", function(t)
    local seen = nil
    local id = support.id("building")
    local h  = Building{ id = id, events = {
        onPlace = function(self, ctx) seen = { self = self, ctx = ctx }; return "ran" end,
    } }

    -- The forwarder is for MANUAL use: it calls the hook on the CLASS, not on a live
    -- instance (there is none until core/event's scan creates one).
    t:eq(h:onPlace({ tag = 1 }), "ran", "the forwarder returns what the handler returned")
    t:truthy(seen, "the declared handler ran")
    t:eq(seen.self.id, id, "`self` is the definition class, not the handle")
    t:eq(seen.ctx.tag, 1, "the ctx is passed straight through")

    for _, name in ipairs({ "onBuild", "onPlace", "onLoad", "onRightClick",
                            "onLeftClick", "onBreak", "onRemove", "onTick" }) do
        t:type(h[name], "function", name .. " has a handle-level forwarder")
    end
    -- onWorldReady / onWorldLeft are fired by core/event across every live instance at
    -- once, so there is nothing sensible for a single definition handle to forward.
    t:eq(h.onWorldReady, nil, "onWorldReady has no forwarder on the handle")
    t:eq(h.onWorldLeft, nil, "onWorldLeft has no forwarder on the handle")
end)

--=============================================================================
-- validation of the top-level spec
--=============================================================================

s:test("id is required and an unknown field is a hard error with a suggestion", function(t)
    t:errors(function() Building{ name = "no id" } end, "field \"id\" is required")
    t:errors(function() Building{ id = "" } end, "must be a non-empty string")
    t:errors(function() Building{ id = support.id("building"), meshSpec = {} } end,
        "unknown field \"meshSpec\" (did you mean \"mesh\"?)")
end)

--=============================================================================
-- handle queries + the empty-registry answers
--=============================================================================

s:test("iconOf falls back to the declared icon when the DataTable lookup misses", function(t)
    -- No DT_BuildObjectIconDataTable row exists for a namespaced test id, in game or out,
    -- so this exercises the fallback rather than the lookup.
    local id = support.id("building")
    local h  = Building{ id = id, icon = "palforge-test-icon" }
    t:eq(h:iconOf(), "palforge-test-icon")

    local bare = support.id("building")
    t:eq(Building{ id = bare }:iconOf(), nil, "no icon declared and no row -> nil, never a throw")
end)

s:test("instances, render and update are empty and zero for a definition nothing has placed", function(t)
    -- True with or without a world: a test-namespaced building has never been built, so the
    -- instance registry can have nothing for it, and render/update count real attachments.
    local id = support.id("building")
    local h  = Building{ id = id, mesh = { model = "/Game/Test/SM_Z.SM_Z" } }

    local list = h:instances()
    t:type(list, "table", "instances() is always a list, never nil")
    t:eq(#list, 0)
    t:eq(h:render(), 0, "render() counts attachments, and there is nothing to attach to")
    t:eq(h:update(), 0, "update() counts re-tints, likewise")
end)

s:test("the instance registry answers for an unplaced definition and for a nil actor", function(t)
    local id = support.id("building")
    Building{ id = id }
    t:type(event.instances(id), "table")
    t:eq(#event.instances(id), 0, "nothing is tracked for a definition nothing placed")
    t:eq(event.instanceOfActor(nil), nil, "a nil actor resolves to no instance, fail-soft")
    t:type(event.isWorldReady(), "boolean", "the world gate always answers")
end)

--=============================================================================
-- LIVE — read-only, over whatever the player has already built
--=============================================================================

s:test("a curated building's live instances are well-shaped", function(t)
    support.needWorld(t)

    -- WorkBench is a CURATED native definition, so core/event has a def for it and its
    -- scan tracks any that exist. An empty list is a legitimate answer (the player may
    -- have none nearby) - what must hold is the SHAPE of whatever is there.
    local h = Building.get(support.GAME.building)
    local list = h:instances()
    t:type(list, "table")

    for _, inst in ipairs(list) do
        t:type(inst.key, "string", "every instance has a stable registry key")
        t:type(inst.buildId, "string", "and the game build id it matched")
        t:type(inst.pos, "table")
        t:type(inst.pos.x, "number")
        t:type(inst.pos.z, "number")
        t:type(inst.state, "table", "state is always a table, even when none was declared")
        t:type(inst.def, "table")
        t:type(inst.def.id, "string")
        -- the per-instance persistence closures exist; NOT called - save() writes the
        -- player's world file.
        t:type(inst.save, "function")
        t:type(inst.isValid, "function")
        t:type(inst.mesh, "function", "the class methods resolve on the instance")
    end
end)

s:test("event.instances holds every tracked structure and instanceOfActor round-trips", function(t)
    support.needWorld(t)

    local all = event.instances()
    t:type(all, "table")

    local one = event.instances(support.GAME.building)
    t:type(one, "table")
    t:truthy(#all >= #one, "the unfiltered list contains the filtered one")

    for _, inst in ipairs(one) do
        t:truthy(#event.instances(inst.buildId) > 0, "the build-id filter finds it back")
        if inst.actor then
            t:eq(event.instanceOfActor(inst.actor), inst,
                "an actor resolves back to exactly the instance bound to it")
        end
    end
end)

return s
