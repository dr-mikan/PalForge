-- palforge/test/cases/mesh.lua — the Mesh domain: define / get / get_all, the handle's
-- queries, and the fail-soft contract of its three actions.
--
-- Almost everything Mesh does is decidable without a world: a mesh is a DECLARATION, and
-- the interesting behaviour is what the schema fills in and what nesting the same handle
-- into two domains produces. Those tests are pure. Only :attachTo / :detach / :setColor
-- reach core.mesh and want a live actor, so those SKIP without one — and even then they
-- attach a PROCEDURAL mesh whose OBJ file does not exist, so the honest answer is false
-- and nothing is ever put on the player. A skeletal attach would swap the player's own
-- mesh, which is exactly the kind of thing a test must never do to someone's save.
local T        = require("palforge.core.unittests")
local support  = require("palforge.test.support")
local Mesh     = require("palforge.api.mesh")
local Pal      = require("palforge.api.pal")
local Building = require("palforge.api.building")

local s = T.suite("mesh")

-- A UStaticMesh/USkeletalMesh path is never loaded by a pure test, so any well-formed
-- string does; naming a real-looking one keeps the declarations readable.
local MODEL = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal"

-- An OBJ path that is guaranteed NOT to exist, so the procedural backend's parse step
-- fails before it can touch an actor. This is what makes the live attach tests safe.
-- A constant is fine even though the backend caches parsed OBJs: only SUCCESSES are
-- cached, so this one re-fails identically on every run.
local MISSING_OBJ = "C:/palforge_test/no_such_mesh.obj"

-- A minimal stand-in for a live actor: valid enough to get past the handle's guard, so
-- the call reaches core.mesh and we see the BACKEND's answer rather than the guard's.
local function stubActor()
    return { IsValid = function() return true end }
end

--=============================================================================
-- define
--=============================================================================

s:test("a directly defined mesh requires an id, because an unnamed one could never be looked up again", function(t)
    t:errors(function() Mesh{ model = MODEL } end, "field \"id\" is required")
end)

s:test("model is required even when an id is given", function(t)
    t:errors(function() Mesh{ id = support.id("mesh") } end, "field \"model\" is required")
end)

s:test("an unknown field is a hard error with a did-you-mean", function(t)
    local msg = t:errors(function()
        Mesh{ id = support.id("mesh"), model = MODEL, modelPath = MODEL }
    end, "unknown field")
    t:assert(msg:find("did you mean \"model\"?", 1, true),
        "the suggestion should point at \"model\", got: " .. msg)
end)

s:test("a mesh written INLINE inside another definition needs no id", function(t)
    -- The one place `id` is optional: there is nothing to name, so nothing to look up.
    local pal = Pal{ id = support.id("pal"), mesh = { model = MODEL } }
    t:eq(pal:mesh().model, MODEL, "the inline mesh reached the definition")
    t:eq(pal:mesh().id, nil, "and carries no id")
end)

--=============================================================================
-- get / get_all
--=============================================================================

s:test("get returns a handle over the SAME definition the define call registered", function(t)
    local id = support.id("mesh")
    local defined = Mesh{ id = id, model = MODEL }
    local fetched = Mesh.get(id)
    t:eq(fetched.id, id)
    -- Two handles, one definition: identity is on :source(), not on the wrapper.
    t:eq(fetched:source(), defined:source(), "both handles stand for one definition")
end)

s:test("get raises on a miss rather than handing back a thin fallback", function(t)
    -- Unlike Pal/Building there is no sensible thin mesh: one with no model renders
    -- nothing at all, which would fail silently in-world instead of at the call.
    t:errors(function() Mesh.get(support.id("never_defined")) end,
        "no mesh is defined under that id")
end)

s:test("get rejects a non-string id before it reaches the registry", function(t)
    t:errors(function() Mesh.get(nil) end, "id (string) is required")
    t:errors(function() Mesh.get("") end, "id (string) is required")
end)

s:test("get_all lists every registered mesh as a handle", function(t)
    local id = support.id("mesh")
    Mesh{ id = id, model = MODEL }

    local all = Mesh.get_all()
    t:type(all, "table")

    local found
    for _, h in ipairs(all) do
        if h.id == id then found = h end
        t:type(h.source, "function", "every entry is a Mesh.Handle, not a raw class")
    end
    t:truthy(found, "the mesh just defined is in get_all")
    t:eq(found:model(), MODEL)
end)

--=============================================================================
-- the handle's queries
--=============================================================================

s:test("source is the definition itself, with the schema's defaults already filled", function(t)
    local id = support.id("mesh")
    local m = Mesh{ id = id, model = MODEL }

    local src = m:source()
    t:eq(src.id, id)
    t:eq(src.model, MODEL)
    t:eq(src.kind, "skeletal", "kind defaults at define time, not at attach time")
    t:eq(src.scale, nil, "a field with no default and no value stays absent")

    -- :source() is the definition, not a snapshot of it — calling it twice is the same
    -- table, which is what lets core.mesh and the nesting path agree on one declaration.
    t:eq(m:source(), src)
end)

s:test("model and kind read straight off the definition", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MODEL, kind = "static" }
    t:eq(m:model(), MODEL)
    t:eq(m:kind(), "static")
end)

s:test("all four backend kinds are accepted and preserved verbatim", function(t)
    -- "obj" is core.mesh's alias for the procedural backend, but the api stores what was
    -- declared: the alias is resolved at dispatch, not folded away at define time.
    for _, kind in ipairs({ "procedural", "static", "skeletal", "obj" }) do
        local m = Mesh{ id = support.id("mesh_" .. kind), model = MODEL, kind = kind }
        t:eq(m:kind(), kind, kind .. " survives the round trip")
        t:eq(m:source().kind, kind)
    end
end)

s:test("a fifth kind is rejected with the list of the four that exist", function(t)
    local msg = t:errors(function()
        Mesh{ id = support.id("mesh"), model = MODEL, kind = "voxel" }
    end, "must be one of")
    for _, kind in ipairs({ "procedural", "static", "skeletal", "obj" }) do
        t:assert(msg:find(kind, 1, true), "the error should list " .. kind .. ", got: " .. msg)
    end
end)

--=============================================================================
-- nesting — one handle, two domains
--=============================================================================

s:test("one defined handle nests into both Pal and Building, carrying its own kind into each", function(t)
    -- The point of Mesh being its own domain: declare once, wear anywhere. Building
    -- DERIVES its mesh shape from Mesh.Spec, so the handle satisfies both.
    local m   = Mesh{ id = support.id("mesh"), model = MODEL, kind = "procedural" }
    local pal = Pal{ id = support.id("pal"), mesh = m }
    local bld = Building{ id = support.id("building"), mesh = m }

    t:eq(pal:mesh().model, MODEL)
    t:eq(bld:mesh().model, MODEL)
    t:eq(pal:mesh().kind, "procedural")
    t:eq(bld:mesh().kind, "procedural", "the handle's declared kind beats the domain default")
end)

s:test("nesting a handle COPIES it, so neither host can reach the definition through its mesh", function(t)
    local m   = Mesh{ id = support.id("mesh"), model = MODEL }
    local pal = Pal{ id = support.id("pal"), mesh = m }

    t:neq(pal:mesh(), m:source(), "re-validation produced a fresh table")
    t:eq(pal:mesh().model, m:source().model, "with the same content")
end)

s:test("each domain's kind default applies to an INLINE mesh only", function(t)
    -- Inline: nothing filled it in yet, so the host's own policy decides — a pal is a
    -- skeletal creature where a structure is a static prop.
    local inlinePal = Pal{ id = support.id("pal"), mesh = { model = MODEL } }
    local inlineBld = Building{ id = support.id("building"), mesh = { model = MODEL } }
    t:eq(inlinePal:mesh().kind, "skeletal", "Pal.Spec keeps Mesh.Spec's own default")
    t:eq(inlineBld:mesh().kind, "static", "Building.Spec.Mesh overrides it")

    -- A DEFINED handle already had Mesh.Spec's default filled at define time, so the
    -- building's default never gets a say — this is the difference the two spellings make.
    local defined = Mesh{ id = support.id("mesh"), model = MODEL }
    local withHandle = Building{ id = support.id("building"), mesh = defined }
    t:eq(withHandle:mesh().kind, "skeletal",
        "a defined mesh brings its filled kind with it, it is not re-defaulted per host")
end)

--=============================================================================
-- actions — fail-soft, everywhere
--=============================================================================

s:test("attachTo an invalid actor is a fail-soft false, never a raise", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:attachTo(nil), false, "nil actor")
    t:eq(m:attachTo({}), false, "a table with no IsValid at all")
    t:eq(m:attachTo({ IsValid = function() return false end }), false, "a stale actor")
end)

s:test("detach and setColor guard on the actor the same way attachTo does", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MODEL }
    t:eq(m:detach(nil), false)
    t:eq(m:detach({}), false)
    t:eq(m:setColor(nil, { 1, 0, 0, 1 }), false)
    t:eq(m:setColor({}, { 1, 0, 0, 1 }), false)
end)

s:test("a procedural attach whose OBJ file does not exist reports false rather than half-succeeding", function(t)
    -- Past the handle's guard and into the backend: parseObj fails, so the actor is never
    -- touched and no component is created. The honest answer is false.
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:attachTo(stubActor()), false)
end)

s:test("setColor on an actor this session never dressed is false, not a pretended tint", function(t)
    -- core.mesh has no record for the actor, so it falls back to the backend named by the
    -- mesh's own kind — and no backend has a material to write to, so it says so.
    local proc = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    local skel = Mesh{ id = support.id("mesh"), model = MODEL, kind = "skeletal" }
    local actor = stubActor()
    t:eq(proc:setColor(actor, { 1, 0, 0, 1 }), false, "no MID exists for this actor")
    t:eq(skel:setColor(actor, { 1, 0, 0, 1 }), false, "skeletal keeps the inert default")
end)

s:test("detach on an actor this session never dressed is false", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:detach(stubActor()), false, "nothing of PalForge's is on it to remove")
end)

--=============================================================================
-- live — the same claims against the real player pawn
--=============================================================================

s:test("attachTo the live player pawn with an OBJ that is not on disk returns an honest false", function(t)
    local pawn = support.needWorld(t)
    -- Deliberately a PROCEDURAL mesh with an unreadable model: the backend bails at the
    -- parse, so this never adds a component to the player. A skeletal attach here would
    -- swap the player's own mesh, which no test is allowed to do.
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:attachTo(pawn), false, "nothing was attached, and it said so")
    -- Nothing was attached, so there is nothing to take off again.
    t:eq(m:detach(pawn), false, "detach reports it removed nothing")
    t:eq(m:setColor(pawn, { 1, 1, 1, 1 }), false, "and there is no material to re-tint")
end)

return s
