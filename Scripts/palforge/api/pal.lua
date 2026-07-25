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
--   TYPES   — LuaLS (---@) annotations so editors give real intellisense.
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

local om    = require("palforge.core.object_manager")
local spawn = require("palforge.core.spawn")
local mesh  = require("palforge.core.mesh")
local icons = require("palforge.core.icons")

--=============================================================================
-- TYPES (LuaLS annotations — editor intellisense only; zero runtime cost)
--=============================================================================

---A world coordinate. Accepts { x=, y=, z= } or the array form { x, y, z }.
---@class Coord
---@field x number
---@field y number
---@field z number

---The lifecycle handlers a pal can respond to. All optional. Each receives the pal
---as `self` and an event context `ctx` (ctx.actor = the pawn in the world).
---@class Pal.Events
---@field onSpawned  fun(self: Pal.Handle, ctx: table)  # LIVE (candidate hook) — finished spawning
---@field onDamaged  fun(self: Pal.Handle, ctx: table)  # LIVE — took damage
---@field onDeath    fun(self: Pal.Handle, ctx: table)  # LIVE — HP reached zero
---@field onCaptured fun(self: Pal.Handle, ctx: table)  # LIVE — caught in a sphere
---@field onTick     fun(self: Pal.Handle, ctx: table)  # declarable; no per-pal tick source yet

---What you pass to Pal.define. `id` is required; everything else is optional.
---@class Pal.Spec
---@field id          string       # pal id: a game CharacterID ("ChickenPal") or "pack:name"
---@field displayName string?      # shown in UI (defaults to id)
---@field skills      string[]?    # skill ids this pal owns (see Skill.define)
---@field events      Pal.Events?  # lifecycle handlers (grouped)
---@field mesh        table?       # mesh descriptor { kind=, model=, animClass=, scale=, ... }
---@field material    table?       # { color, texture, params, material } override
---@field color       table?       # base tint { r, g, b, a }
---@field texture     string?      # absolute png path applied to the mesh
---@field icon        any?         # fallback icon when the DataTable lookup misses

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

local wrap  -- forward decl; the Pal.Handle wrapper is defined in the BOTTOM section

---Define a NEW pal and register it. Returns a handle you can chain :spawn on.
---@param spec Pal.Spec
---@return Pal.Handle
function Pal.define(spec)
    assert(type(spec) == "table",
        "Pal.define: pass a table, e.g. Pal.define{ id = 'X', events = {...} }")
    assert(type(spec.id) == "string" and #spec.id > 0, "Pal.define: spec.id (string) is required")
    local cls = setmetatable({
        id           = spec.id,
        displayName  = spec.displayName or spec.id,
        skills       = spec.skills,
        meshSpec     = spec.mesh,
        materialSpec = spec.material,
        color        = spec.color,
        texture      = spec.texture,
        icon         = spec.icon,
    }, Class)
    cls.__index = cls  -- so a spawned instance (if ever made) resolves the class methods
    if type(spec.events) == "table" then
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
