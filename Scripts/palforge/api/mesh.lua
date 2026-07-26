-- palforge/api/mesh.lua — PUBLIC mesh API + implementation (SELF-CONTAINED).
--
-- A mesh is the VISUAL a definition wears: a model asset plus how to paint it. It follows
-- the same shape as every other api module (call it to define, plus get / get_all + a
-- Handle carrying actions), and it exists as its own domain so a mesh can be declared
-- ONCE, named, and reused by name across pals, buildings and anything else that renders:
--
--   local body = Mesh{ id = "example:body",
--                      model = "/Game/Pal/Model/Character/Monster/X/SK_X",
--                      texture = "C:/mods/example/body.png" }
--   Pal{ id = "example:Boss", mesh = body }         -- nest the defined mesh
--   Pal{ id = "example:Add",  mesh = Mesh.get("example:body") }
--   body:attachTo(ctx.actor)                        -- or attach it yourself
--
-- Nesting works because the Handle's metatable carries `__spec` (see core/schema): the
-- validator unwraps it to the plain declaration, so `mesh = Mesh{ ... }` and the inline
-- `mesh = { model = "..." }` are validated identically and reach core.mesh the same way.
-- That is why api/pal reuses THIS shape rather than declaring a copy of it — one shape,
-- so the two spellings can never drift.
--
-- HOW IT INTEGRATES: defining registers the definition in object_manager under
-- ("mesh", id); attaching lowers the declaration to core.mesh, which dispatches on
-- `kind` (procedural / static / skeletal / obj) and guards against re-stacking.

local om     = require("palforge.core.object_manager")
local mesh   = require("palforge.core.mesh")
local schema = require("palforge.core.schema")

--=============================================================================
-- SPEC — the shape of Mesh{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("Mesh.Spec")         -- every field, its type, default and meaning
--   schema.get("Mesh.Spec").fields   -- the same, as a table, for tooling
--
-- `id` is optional here and only here: a mesh written INLINE inside another definition
-- (`mesh = { model = "..." }`) has nothing to name. Defining one directly requires an id,
-- since an unnamed definition could never be looked up again.
--=============================================================================

local Spec = schema.define("Mesh.Spec", {
    { "id",        type = "string", check = schema.nonEmpty,
                   doc = "mesh id, e.g. \"pack:name\" (required when defined directly; omit when inline)" },
    { "kind",      type = "string", values = { "procedural", "static", "skeletal", "obj" },
                   default = "skeletal", doc = "which core.mesh backend renders it" },
    { "model",     type = "string", required = true, doc = "USkeletalMesh / UStaticMesh asset path" },
    { "animClass", type = "string", doc = "ABP_*_C animation blueprint path (skeletal only)" },
    { "scale",     type = "number", doc = "uniform scale applied to the attached mesh" },
    { "offset",    type = "table",  doc = "{ x, y, z } offset from the pawn's origin" },
    { "texture",   type = "string", doc = "absolute path to a png applied to the mesh" },
    { "color",     type = "table",  doc = "tint { r, g, b, a } in 0..1" },
    { "material",  type = "string", doc = "base material asset path to instance from" },
    { "params",    type = "table",  doc = "extra material parameters passed through" },
}, { handle = "Mesh.Handle" })   -- a Mesh.Handle satisfies this shape too (see __spec below)

--=============================================================================
-- the registered mesh DEFINITION class
--=============================================================================

local Class = {}
Class.__index = Class

-- The spec core.mesh consumes. A definition IS that spec — the declaration validated,
-- with defaults filled — so there is nothing to lower and one field list to maintain.
-- Kept as a method so a definition can override it for a fully computed mesh.
function Class:source() return self end

--=============================================================================
-- TOP — the module surface: Mesh{ ... } / Mesh.get / Mesh.get_all
--=============================================================================

---The mesh domain. CALL it to define a mesh; the two named functions look existing ones up.
---@class palforge.mesh
---@overload fun(spec: Mesh.Spec): Mesh.Handle
local Mesh = {}

local wrap  -- forward decl; the Mesh.Handle wrapper is defined in the BOTTOM section

---Define a NAMED mesh and register it. Returns a handle you can attach, or nest
---directly in another definition (`Pal{ mesh = Mesh{ ... } }`).
---`spec` is validated against Mesh.Spec: `model` is required, unknown fields are an error.
---@param spec Mesh.Spec
---@return Mesh.Handle
local function define(spec)
    spec = Spec:validate(spec, "Mesh")
    if spec.id == nil then
        error("PalForge: Mesh: field \"id\" is required (an unnamed mesh cannot be "
            .. "looked up again - write it inline as mesh = { ... } instead)", 0)
    end
    -- `spec` is already a fresh, validated, defaults-filled copy that nothing else holds
    -- a reference to, so the definition can BE it rather than another transcription.
    local cls = setmetatable(spec, Class)
    pcall(function() om.register("mesh", spec.id, cls) end)
    return wrap(cls)
end

-- Calling the module IS defining:  Mesh{ id = "example:body", model = "..." }
setmetatable(Mesh, { __call = function(_, spec) return define(spec) end })

---Get a previously-defined mesh by id. Errors when nothing is registered under it —
---unlike a pal or an item there is no sensible thin fallback, since a mesh with no
---model would silently render nothing.
---@param id string
---@return Mesh.Handle
function Mesh.get(id)
    assert(type(id) == "string" and #id > 0, "Mesh.get: id (string) is required")
    local cls = om.get("mesh", id)
    if not cls then
        error(string.format("PalForge: Mesh.get(%q): no mesh is defined under that id", id), 0)
    end
    return wrap(cls)
end

---Every PalForge-registered mesh, as a list of handles.
---@return Mesh.Handle[]
function Mesh.get_all()
    local out = {}
    for _, cls in pairs(om.all("mesh")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the mesh OBJECT (Mesh.Handle): actions
-- Meshes have no lifecycle of their own — they are worn by something else — so the
-- handle's surface is actions plus the declaration it stands for.
--=============================================================================

---A defined mesh. Obtain one from Mesh{ ... } / Mesh.get / Mesh.get_all.
---@class Mesh.Handle
---@field id string   # the mesh's id
local Handle = {}
Handle.__index = Handle

-- `__spec` is what lets a handle be passed straight into another definition: core/schema
-- unwraps it to the declaration it stands for before validating that against the nested
-- spec. Re-validation copies, so the caller can never reach the definition through it.
Handle.__spec = function(self) return self._cls:source() end

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Attach this mesh to a live actor, once (core.mesh guards against re-stacking).
---Fail-soft false when the actor is not valid.
---@param actor any   # the pawn to decorate (e.g. ctx.actor)
---@return boolean ok
function Handle:attachTo(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then return false end
    return mesh.attachOnce(actor, self._cls:source())
end

---Re-tint an already-attached mesh on `actor`.
---@param actor any
---@param color table  # { r, g, b, a } in 0..1
---@return boolean ok
function Handle:setColor(actor, color)
    if not (actor and actor.IsValid and actor:IsValid()) then return false end
    return mesh.setColor(actor, color)
end

-- ---- queries ----

---The lowered spec core.mesh will render.
---@return table
function Handle:source() return self._cls:source() end
---@return string
function Handle:model() return self._cls.model end
---@return string
function Handle:kind() return self._cls.kind or "skeletal" end

Mesh.Class = Class   -- the base class (used for subclassing / override detection)
return Mesh
