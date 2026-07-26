-- palforge/test/cases/definitions.lua — the one shape every api domain shares.
--
-- Eight domains (Pal, Item, Building, Skill, Effect, Audio, Mesh, UI) are meant to be the
-- SAME object with different actions: call the module to define, get / get_all to look one
-- up, a handle back either way. This suite makes every claim about all eight AT ONCE, by
-- looping over them, so a domain that quietly grows a `define` function, publishes its
-- private Spec, forgets to register, or starts handing back definition classes instead of
-- handles is caught here rather than in its own case file. It also pins the two documented
-- exceptions to that uniformity — Mesh.get RAISES where the other seven fall back, and a
-- mesh has no name/description at all — plus the nesting rule that makes
-- `Pal{ mesh = Mesh{ ... } }` work: the handle is unwrapped, validated like the inline
-- table, and stored as a COPY.
--
-- NOTHING HERE NEEDS A WORLD. Defining is registry bookkeeping and no test below spawns,
-- gives, plays or mounts anything, so this suite passes in full at the title screen — no
-- support.needWorld call appears in it. Every id comes from support.id(), so a run only
-- ever registers under "palforge_test:", never over real content.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local api     = require("palforge.api")
local om      = require("palforge.core.object_manager")
local schema  = require("palforge.core.schema")

local s = T.suite("definitions")

-- Every domain, plus the little that a generic test cannot infer: the object_manager type
-- it registers under, a MINIMAL valid declaration, and the handle query that reads that
-- declaration's distinguishing value back. Mesh needs its own pair because it is the only
-- domain with no `name` field — its equivalent is `model`, the one thing it must be given.
local DOMAINS = {
    { name = "Pal",      module = api.Pal,      otype = "pal",      query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "Item",     module = api.Item,     otype = "item",     query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "Building", module = api.Building, otype = "building", query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "Skill",    module = api.Skill,    otype = "skill",    query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "Effect",   module = api.Effect,   otype = "effect",   query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "Audio",    module = api.Audio,    otype = "audio",    query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "UI",       module = api.UI,       otype = "ui",       query = "name",
      decl = function(id, tag) return { id = id, name = tag } end },
    { name = "Mesh",     module = api.Mesh,     otype = "mesh",     query = "model",
      decl = function(id, tag) return { id = id, model = tag } end },
}

-- The seven that promise `get` is never nil. Mesh is deliberately not one of them: a mesh
-- with no model would render nothing, so there is no honest fallback to invent.
local NEVER_NIL = {}
for _, d in ipairs(DOMAINS) do
    if d.name ~= "Mesh" then NEVER_NIL[#NEVER_NIL + 1] = d end
end

-- Read a declaration's distinguishing value back off a handle. This doubles as the test
-- for handle-ness: the definition CLASS carries the same key as plain data, only a handle
-- answers it as a method.
local function readBack(d, handle) return handle[d.query](handle) end

-- A real skeletal asset path, so a mesh declaration is the shape the game would get.
local MODEL = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal"

--=============================================================================
-- the uniform module surface
--=============================================================================

s:test("every domain module is callable, because calling it IS defining", function(t)
    for _, d in ipairs(DOMAINS) do
        local mt = getmetatable(d.module)
        t:truthy(mt, d.name .. " needs a metatable to carry __call")
        t:type(mt.__call, "function", d.name .. "{ ... } must be the way to define")
    end
end)

s:test("every domain exposes get and get_all and nothing named define, Spec or Events", function(t)
    for _, d in ipairs(DOMAINS) do
        t:type(d.module.get, "function", d.name .. ".get must exist")
        t:type(d.module.get_all, "function", d.name .. ".get_all must exist")
        -- the module IS the constructor; a second spelling would be a second way in
        t:eq(d.module.define, nil, d.name .. " must not publish define")
        -- shapes stay private to their module — a domain is a thing you call, not a
        -- namespace to browse
        t:eq(d.module.Spec, nil, d.name .. " must not publish its Spec")
        t:eq(d.module.Events, nil, d.name .. " must not publish its Events")
    end
end)

s:test("a domain's private spec is still readable through the schema registry", function(t)
    for _, d in ipairs(DOMAINS) do
        local spec = schema.get(d.name .. ".Spec")
        t:truthy(spec, d.name .. ".Spec must be declared where tooling can reach it")
        t:eq(spec.name, d.name .. ".Spec")
        t:type(spec.fields, "table", d.name .. ".Spec must expose its ordered fields")
    end
end)

s:test("the bare globals installed by requiring palforge.api ARE the namespaced modules", function(t)
    for _, d in ipairs(DOMAINS) do
        t:eq(_G[d.name], d.module, "_G." .. d.name .. " must be the same table as api." .. d.name)
    end
    t:eq(_G.Player, api.Player, "_G.Player must be the same table as api.Player")
end)

--=============================================================================
-- defining: registration
--=============================================================================

s:test("calling a domain registers the definition in object_manager under that domain's type", function(t)
    for _, d in ipairs(DOMAINS) do
        local id = support.id(d.otype)
        t:eq(om.get(d.otype, id), nil, "a fresh test id must start unregistered")

        d.module(d.decl(id, "registered"))

        local cls = om.get(d.otype, id)
        t:truthy(cls, d.name .. "{ ... } must register under (\"" .. d.otype .. "\", id)")
        t:eq(cls.id, id, "the registered definition must carry the id it was declared with")

        -- and under that type ONLY: the registry is keyed by type for a reason
        for _, other in ipairs(DOMAINS) do
            if other.otype ~= d.otype then
                t:eq(om.get(other.otype, id), nil,
                    d.name .. " must not also register under \"" .. other.otype .. "\"")
            end
        end
    end
end)

s:test("re-defining an id replaces the registration instead of adding a second one", function(t)
    for _, d in ipairs(DOMAINS) do
        local id = support.id("redef")
        d.module(d.decl(id, "first"))
        local before = #d.module.get_all()

        d.module(d.decl(id, "second"))

        t:eq(#d.module.get_all(), before, d.name .. " must not grow when an id is re-declared")
        t:eq(readBack(d, d.module.get(id)), "second",
            d.name .. ".get must see the newest declaration")

        local seen = 0
        for _, h in ipairs(d.module.get_all()) do
            if h.id == id then seen = seen + 1 end
        end
        t:eq(seen, 1, d.name .. " must hold exactly one definition per id")
    end
end)

--=============================================================================
-- looking up
--=============================================================================

s:test("get returns a thin fallback for an unknown id in seven domains, and Mesh.get raises", function(t)
    for _, d in ipairs(NEVER_NIL) do
        local id = support.id("missing")
        local h = d.module.get(id)
        t:truthy(h, d.name .. ".get must never return nil")
        t:eq(h.id, id, "the fallback stands for the id it was asked about")
        t:eq(h:name(), id, "an undeclared id names itself")
        t:eq(h:description(), nil, "a fallback describes nothing")
    end

    t:errors(function() return api.Mesh.get(support.id("missing")) end,
        "no mesh is defined under that id",
        "Mesh.get must raise rather than invent a mesh with no model")
end)

s:test("a fallback from get is not registered, so looking something up never creates content", function(t)
    for _, d in ipairs(NEVER_NIL) do
        local id = support.id("lookup")
        d.module.get(id)
        t:eq(om.get(d.otype, id), nil, d.name .. ".get must not register its fallback")
    end
end)

s:test("get_all returns handles, and a just-defined id is among them", function(t)
    for _, d in ipairs(DOMAINS) do
        local id = support.id("all")
        d.module(d.decl(id, "listed"))

        local found = false
        for _, h in ipairs(d.module.get_all()) do
            t:type(h.id, "string", d.name .. ".get_all must yield things with an id")
            -- the definition class carries this key as DATA; only a handle answers it as
            -- a method, so this is what proves get_all wrapped rather than leaked
            t:type(h[d.query], "function",
                d.name .. ".get_all must yield handles, not definition classes")
            if h.id == id then
                found = true
                t:eq(readBack(d, h), "listed", "the listed handle must carry the declaration")
            end
        end
        t:truthy(found, d.name .. ".get_all must include a definition made moments ago")
    end
end)

--=============================================================================
-- what a handle carries
--=============================================================================

s:test("a handle carries the id, name and description it was declared with", function(t)
    for _, d in ipairs(NEVER_NIL) do
        local id = support.id("meta")
        local h = d.module{ id = id, name = "Declared Name", description = "one line" }
        t:eq(h.id, id, d.name .. " handle must expose its id as a field")
        t:eq(h:name(), "Declared Name", d.name .. " handle must expose its name")
        t:eq(h:description(), "one line", d.name .. " handle must expose its description")

        -- and a handle fetched later says the same, so the registration kept all three
        local again = d.module.get(id)
        t:eq(again.id, id)
        t:eq(again:name(), "Declared Name", d.name .. ".get must return the declared name")
        t:eq(again:description(), "one line", d.name .. ".get must return the declared description")
    end
end)

s:test("name falls back to the id when the declaration omits it", function(t)
    for _, d in ipairs(NEVER_NIL) do
        local id = support.id("unnamed")
        t:eq(d.module{ id = id }:name(), id, d.name .. " must default its name to its id")
    end
end)

s:test("a mesh carries only an id: name and description are not a mesh's fields at all", function(t)
    local id = support.id("mesh")
    local h  = api.Mesh{ id = id, model = MODEL }
    t:eq(h.id, id, "a mesh handle exposes its id")
    t:eq(h.name, nil, "a mesh has no name to query")
    t:eq(h.description, nil, "a mesh has no description to query")

    -- and declaring one is a hard error, not a silently carried extra
    t:errors(function() return api.Mesh{ id = support.id("mesh"), model = MODEL, name = "Body" } end,
        "unknown field \"name\"", "a name on a mesh must be rejected at define time")
end)

--=============================================================================
-- nesting: Pal{ mesh = Mesh{ ... } }
--=============================================================================

s:test("a Mesh handle nested as another definition's mesh validates exactly like the inline table", function(t)
    local meshId = support.id("mesh")
    local defined = api.Mesh{ id = meshId, model = MODEL }

    local viaHandle = api.Pal{ id = support.id("pal"), mesh = defined }
    local viaInline = api.Pal{ id = support.id("pal"), mesh = { id = meshId, model = MODEL } }

    local a, b = viaHandle:mesh(), viaInline:mesh()
    t:type(a, "table", "a nested Mesh handle must reach the definition as a plain table")
    t:type(b, "table", "an inline mesh must reach the definition as a plain table")
    for _, field in ipairs({ "id", "kind", "model", "animClass", "scale", "offset",
                             "texture", "color", "material", "params" }) do
        t:eq(a[field], b[field], "mesh." .. field .. " must be identical either way")
    end
    -- the shared spec's default arrives through both spellings, which is the point of
    -- api/pal reusing Mesh.Spec rather than declaring a copy of it
    t:eq(a.kind, "skeletal", "Mesh.Spec's default kind must reach the pal both ways")
end)

s:test("the nested mesh is a copy, so nothing can reach the Mesh definition through it", function(t)
    local meshId  = support.id("mesh")
    local defined = api.Mesh{ id = meshId, model = MODEL }
    local pal     = api.Pal{ id = support.id("pal"), mesh = defined }

    t:neq(pal:mesh(), defined:source(), "the nested value must not BE the mesh definition")

    pal:mesh().model = "/Game/scribbled/over"
    t:eq(defined:model(), MODEL, "writing through the pal must not reach the Mesh handle")
    t:eq(api.Mesh.get(meshId):model(), MODEL, "...nor the registered mesh definition")
end)

return s
