-- palforge/api/pal.lua — PUBLIC pal API + implementation (SELF-CONTAINED).
--
-- A pal is a spawnable creature. This module is the TEMPLATE every other api module
-- follows: define / get / get_all + a Handle object carrying actions and grouped `events`.
-- Its only internal deps are core/object_manager (the registry core/event resolves pals
-- through), core/spawn (the spawn engine), core/mesh and core/icons.
--
-- HOW IT INTEGRATES: Pal.define registers the definition class in object_manager under
-- ("pal", id). core/event resolves a spawned pal's class by its BP class name
-- (BP_<Id>_C -> id -> object_manager.get) and calls cls:onXxx(ctx) with the class as
-- self — so a definition's lifecycle handlers just work.
--
--   WIRED (live, confirmed native hooks — see core/event installPalSource):
--     onCaptured <- PalCharacterParameterComponent:SetIsCapturedProcessing(true)
--     onDamaged  <- PalCharacter:OnDamageReaction
--     onDeath    <- PalCharacter:OnDeadCharacter
--     onSpawned  <- PalCharacter:BroadcastOnCompleteInitializeParameter (UNCONFIRMED candidate)
--   NOT WIRED: onTick — no per-pal instance tracking exists (pals have no scan the way
--     buildings do), so nothing drives a periodic pal hook. Declarable, never fires.
--
-- ACTIONS are real: :spawn goes through UPalCheatManager (server-verified), coordinate
-- placement included. Note that define() gives an EXISTING CharacterID behaviour — Lua
-- cannot add a brand-new creature row (that is PalSchema's job).
--
-- LAYOUT
--   SPEC    — the shape of define(), declared as data (core/schema). It is enforced on
--             every call AND readable at runtime as Pal.Spec, and it is what
--             Scripts/palforge/types.lua is generated from for editor completion.
--   TOP     — module functions:   Pal.define / Pal.get / Pal.get_all
--   BOTTOM  — the pal OBJECT (Pal.Handle): actions (:spawn) + lifecycle events.
--
-- Events are GROUPED under `events`; each handler is `function(self, ctx)`:
--
--   Pal.define{
--       id = "NewPal",
--       events = {
--           onCaptured = function(self, ctx)
--               log.info("NewPal onCaptured: " .. tostring(ctx and ctx.actor))
--           end,
--       },
--   }:spawn(Player.coordinate())

local om     = require("palforge.core.object_manager")
local spawn  = require("palforge.core.spawn")
local mesh   = require("palforge.core.mesh")
local icons  = require("palforge.core.icons")
local schema = require("palforge.core.schema")

--=============================================================================
-- SPEC — the shape of Pal.define, declared as data so it is REFERENCEABLE at
-- runtime and enforced on every call. Reach it as Pal.Spec:
--
--   Pal.Spec:help()        -- print every field, its type, default and meaning
--   Pal.Spec.fields        -- the same, as a table, for tooling
--   Pal.Spec.Mesh{ ... }   -- build (and validate) a nested value on its own
--
-- Nested constructors are OPTIONAL sugar — `mesh = Pal.Spec.Mesh{ model = "..." }` and
-- `mesh = { model = "..." }` are validated identically, so use whichever reads better.
-- Anything not declared here is a hard error at define time, with a did-you-mean: a
-- silently ignored typo is exactly what this layer exists to prevent.
--=============================================================================

---A world coordinate. Accepts { x=, y=, z= } or the array form { x, y, z }.
local Coord = schema.define("Pal.Spec.Coord", {
    { "x", type = "number", required = true, doc = "world X in centimetres" },
    { "y", type = "number", required = true, doc = "world Y in centimetres" },
    { "z", type = "number", required = true, doc = "world Z in centimetres" },
})

local Mesh = schema.define("Pal.Spec.Mesh", {
    { "kind",      type = "string", values = { "procedural", "static", "skeletal", "obj" },
                   default = "skeletal", doc = "which core.mesh backend renders it" },
    { "model",     type = "string", required = true, doc = "USkeletalMesh / UStaticMesh asset path" },
    { "animClass", type = "string", doc = "ABP_*_C animation blueprint path (skeletal only)" },
    { "scale",     type = "number", doc = "uniform scale applied to the attached mesh" },
    { "offset",    type = "table",  doc = "{ x, y, z } offset from the pawn's origin" },
})

local Material = schema.define("Pal.Spec.Material", {
    { "color",    type = "table",  doc = "tint { r, g, b, a } in 0..1" },
    { "texture",  type = "string", doc = "absolute path to a png applied to the mesh" },
    { "params",   type = "table",  doc = "extra material parameters passed through" },
    { "material", type = "string", doc = "base material asset path to instance from" },
})

---The lifecycle handlers a pal can respond to. All optional. Each receives the pal
---definition as `self` and an event context `ctx` (ctx.actor = the pawn in the world).
local Events = schema.define("Pal.Spec.Events", {
    { "onSpawned",  type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE (candidate hook) - finished spawning into the world" },
    { "onDamaged",  type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - took damage" },
    { "onDeath",    type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - HP reached zero" },
    { "onCaptured", type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - caught in a sphere" },
    { "onTick",     type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "declarable; no per-pal tick source exists yet" },
})

---What you pass to Pal.define. `id` is the only required field.
local Spec = schema.define("Pal.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "pal id: a game CharacterID (\"ChickenPal\") or \"pack:name\"" },
    { "displayName", type = "string", doc = "shown in UI (defaults to id)" },
    { "skills",      type = "table", arrayOf = "string", doc = "skill ids this pal owns (see Skill.define)" },
    { "mesh",        type = "table", of = Mesh,     doc = "the mesh attached to a spawned pawn" },
    { "material",    type = "table", of = Material, doc = "material override applied to that mesh" },
    { "color",       type = "table",  doc = "base tint { r, g, b, a } (shorthand for material.color)" },
    { "texture",     type = "string", doc = "png path applied to the mesh (shorthand for material.texture)" },
    { "icon",        doc = "fallback icon used when the DataTable lookup misses" },
    { "events",      type = "table", of = Events, doc = "lifecycle handlers (grouped)" },
    { "data",        type = "table",  doc = "free-form payload of your own, carried onto the definition" },
})

--=============================================================================
-- the registered pal DEFINITION class (what core/event dispatches to)
-- A definition is a table with `.id` + lifecycle methods. Defaults are inert;
-- define{ events = {...} } overrides them per pal. core/event calls cls:onXxx(ctx).
--=============================================================================

local Class = {}
Class.__index = Class
Class.icon = nil

function Class:onSpawned(ctx) end
function Class:onDamaged(ctx) end
function Class:onDeath(ctx) end
function Class:onCaptured(ctx) end
function Class:onTick(ctx) end

function Class:skillsOf() return self.skills or {} end
function Class:mesh() return self.meshSpec end

-- The material descriptor applied to the mesh, from the declared data fields. Consumed by
-- core.mesh: { color = {r,g,b,a}, texture = <abs png path>, params = {...}, material = ... }
function Class:material()
    if self.materialSpec then return self.materialSpec end
    if self.color or self.texture or self.materialParams or self.baseMaterial then
        return { color = self.color, texture = self.texture,
                 params = self.materialParams, material = self.baseMaterial }
    end
    return nil
end

-- The paldeck / capture-UI icon: look the id up in the pal character icon DataTable,
-- falling back to the declared self.icon on any miss.
function Class:iconOf()
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.pal, self.id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — module functions
--=============================================================================

---@class palforge.pal
local Pal = {}

-- The spec, exposed so it can be read, printed and used as a constructor.
Pal.Spec          = Spec
Pal.Spec.Coord    = Coord
Pal.Spec.Mesh     = Mesh
Pal.Spec.Material = Material
Pal.Spec.Events   = Events

local wrap  -- forward decl; the Pal.Handle wrapper is defined in the BOTTOM section

---Define a NEW pal and register it. Returns a handle you can chain :spawn on.
---`spec` is validated against Pal.Spec: `id` is required, unknown fields are an error.
---@param spec Pal.Spec
---@return Pal.Handle
function Pal.define(spec)
    spec = Spec:validate(spec, "Pal.define")
    local cls = setmetatable({
        id           = spec.id,
        displayName  = spec.displayName or spec.id,
        skills       = spec.skills,
        meshSpec     = spec.mesh,
        materialSpec = spec.material,
        color        = spec.color,
        texture      = spec.texture,
        icon         = spec.icon,
        data         = spec.data,
    }, Class)
    cls.__index = cls  -- so a spawned instance (if ever made) resolves the class methods
    if spec.events then
        for name, handler in pairs(spec.events) do cls[name] = handler end  -- onSpawned, ...
    end
    pcall(function() om.register("pal", spec.id, cls) end)  -- so core/event + get() find it
    return wrap(cls)
end

---Get an EXISTING pal by id: a previously-defined one, else a thin definition over any
---game CharacterID (so native / other-mod pals are spawnable too). Never nil.
---@param id string
---@return Pal.Handle
function Pal.get(id)
    assert(type(id) == "string" and #id > 0, "Pal.get: id (string) is required")
    local cls = om.get("pal", id) or setmetatable({ id = id }, Class)
    return wrap(cls)
end

---Every PalForge-registered pal, as a list of handles.
---@return Pal.Handle[]
function Pal.get_all()
    local out = {}
    for _, cls in pairs(om.all("pal")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the pal OBJECT (Pal.Handle): actions + lifecycle events
-- The handle wraps a definition class and gives a uniform :spawn(coord) (works for
-- ANY id, incl. pals registered elsewhere). core/event fires the lifecycle on the
-- underlying class; the :onXxx below forward for manual use.
--=============================================================================

---A definable/live pal. Obtain one from Pal.define / Pal.get / Pal.get_all.
---@class Pal.Handle
---@field id string   # the pal's game CharacterID
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Spawn this pal. Accepts a coordinate, a full opts table, or nothing:
---  :spawn(coord)                          -- { x, y, z } or { x=, y=, z= }
---  :spawn{ at = coord, level =, toPlayer =, num = }
---  :spawn()                               -- default placement (wild, near player)
---@param arg Coord|table|nil
---@return boolean ok
function Handle:spawn(arg)
    local opts = {}
    if type(arg) == "table" then
        if arg.x or arg[1] then opts.at = arg else opts = arg end
    end
    local id = self.id
    if opts.at then
        local a = opts.at
        return spawn.palAt(id, opts.level, a.x or a[1], a.y or a[2], a.z or a[3])
    end
    if opts.toPlayer then return spawn.palForPlayer(id, opts.num, opts.level) end
    return spawn.pal(id, opts.level)
end

---Attach this pal's declared mesh to a live pawn (one-shot; core.mesh guards against
---re-stacking). Pals have no instance scan, so the caller supplies the actor — typically
---`ctx.actor` inside onSpawned. Fail-soft false when there is no mesh or no valid actor.
---@param actor any   # the pawn to decorate (e.g. ctx.actor)
---@return boolean ok
function Handle:renderOn(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then return false end
    local m = self._cls:mesh()
    if not (type(m) == "table" and m.model) then return false end
    local def = {
        kind = m.kind,  -- nil -> procedural, the default backend
        model = m.model, scale = m.scale, offset = m.offset,
        color = m.color, texture = m.texture, params = m.params, material = m.material,
    }
    local mat = self._cls:material()
    if type(mat) == "table" then
        def.color    = mat.color    or def.color
        def.texture  = mat.texture  or def.texture
        def.params   = mat.params   or def.params
        def.material = mat.material or def.material
    end
    return mesh.attachOnce(actor, def)
end

-- ---- lifecycle events (fired by core.event on the definition; forward for manual use) ----

---@param ctx table  # ctx.actor = the pawn
function Handle:onSpawned(ctx) if self._cls.onSpawned then return self._cls:onSpawned(ctx) end end
---@param ctx table
function Handle:onDamaged(ctx) if self._cls.onDamaged then return self._cls:onDamaged(ctx) end end
---@param ctx table
function Handle:onDeath(ctx) if self._cls.onDeath then return self._cls:onDeath(ctx) end end
---@param ctx table
function Handle:onCaptured(ctx) if self._cls.onCaptured then return self._cls:onCaptured(ctx) end end
---@param ctx table
function Handle:onTick(ctx) if self._cls.onTick then return self._cls:onTick(ctx) end end

-- ---- queries ----

---The skill ids this pal owns (resolve them with Skill.get).
---@return string[]
function Handle:skillsOf() return self._cls.skills or {} end
---@return table?
function Handle:mesh() return self._cls.meshSpec end
---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:displayName() return self._cls.displayName or self.id end

Pal.Class = Class   -- the base hook table (used for override detection / subclassing)
return Pal
