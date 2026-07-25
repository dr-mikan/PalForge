-- palforge/api/building.lua — PUBLIC building API + implementation (SELF-CONTAINED).
--
-- A building is a placeable structure: workbenches, storage, machines, decorations —
-- anything picked from the build menu and set into the world. Same shape as every other
-- api module (define / get / get_all + a Handle object with actions and grouped `events`).
--
-- HOW IT INTEGRATES: Building.define registers the definition class in object_manager
-- under ("building", id). core/event owns the FULL building runtime and is the most
-- complete 導線 in PalForge:
--   * a RequestBuild_ToServer hook records the placement intent,
--   * a ~500 ms reconstruction scan over FindAllOf("PalBuildObject") discovers the real
--     actor, creates a live INSTANCE (def.cls:new{...}), persists it per world, and
--     attaches the mesh on a later scan (deferred — attaching the frame it is placed
--     crashes the game),
--   * an OnBeginInteractBuilding hook drives the interact channel,
--   * the shared heartbeat drives onTick (per-instance tickInterval + circuit breaker).
-- Every hook below is LIVE — this is the one domain where a placed structure really does
-- get its own stateful instance with save/load.
--
-- The lifecycle receives the live INSTANCE as `self` (not the class): self.actor is the
-- placed actor, self.pos its world position, self.state your persisted table, and
-- self:save() writes it. onBuild / onLeftClick / onBreak are declarable but have no
-- native source yet (no channel emits them); onPlace + onRemove cover place/destroy.
--
--   Building.define{
--       id = "example:Bench", displayName = "Modded Bench", gridCm = 100,
--       mesh  = { kind = "static", model = "/Game/.../SM_Bench.SM_Bench" },
--       state = { uses = 0 },                       -- default persisted state
--       events = {
--           onPlace      = function(self, ctx) self.state.uses = 0; self:save() end,
--           onRightClick = function(self, ctx) self.state.uses = self.state.uses + 1 end,
--           onTick       = function(self, ctx) end,
--       },
--   }

local om    = require("palforge.core.object_manager")
local icons = require("palforge.core.icons")
local mesh  = require("palforge.core.mesh")
local items = require("palforge.utils.items")

--=============================================================================
-- TYPES (LuaLS annotations — editor intellisense only; zero runtime cost)
--=============================================================================

---A mesh descriptor. `kind` picks the backend in core.mesh (procedural | static | skeletal).
---@class Building.Mesh
---@field kind   string?  # "static" | "procedural" | "skeletal" (default procedural)
---@field model  string   # asset path (static/skeletal) or OBJ path (procedural)
---@field scale  number?
---@field offset table?
---@field color  table?   # { r, g, b, a } 0..1

---The lifecycle handlers a building can respond to. All optional. Each receives the LIVE
---INSTANCE as `self` (self.actor / self.pos / self.state) and the event context `ctx`.
---@class Building.Events
---@field onPlace       fun(self: Building.Instance, ctx: table)  # LIVE — committed into the world
---@field onLoad        fun(self: Building.Instance, ctx: table)  # LIVE — tracked / restored from save
---@field onRightClick  fun(self: Building.Instance, ctx: table)  # LIVE — primary interaction
---@field onRemove      fun(self: Building.Instance, ctx: table)  # LIVE — the structure vanished
---@field onTick        fun(self: Building.Instance, ctx: table)  # LIVE — heartbeat (see tickInterval)
---@field onWorldReady  fun(self: Building.Instance, ctx: table)  # LIVE — world finished loading
---@field onWorldLeft   fun(self: Building.Instance, ctx: table)  # LIVE — world unloaded
---@field onBuild       fun(self: Building.Instance, ctx: table)  # declarable; no native source yet
---@field onLeftClick   fun(self: Building.Instance, ctx: table)  # declarable; no native source yet
---@field onBreak       fun(self: Building.Instance, ctx: table)  # declarable; no native source yet

---What you pass to Building.define. `id` is required; everything else is optional.
---@class Building.Spec
---@field id           string          # build id: a game BuildObjectId ("PalBoxV2") or "pack:name"
---@field displayName  string?         # shown in UI (defaults to id)
---@field gridCm       number?         # placement grid quantum in cm (default core.spatial.GRID_CM)
---@field buildIds     string[]?       # extra game build ids this definition claims (default { id })
---@field tickInterval integer?        # run onTick every N heartbeats (default 1)
---@field mesh         Building.Mesh?  # the mesh attached to the placed actor
---@field material     table?          # { color, texture, params, material } override
---@field color        table?          # base tint { r, g, b, a } (shorthand for material.color)
---@field icon         any?            # fallback icon when the DataTable lookup misses
---@field state        table|fun():table|nil  # default persisted state for a new instance
---@field events       Building.Events?       # lifecycle handlers (grouped)

---A LIVE placed structure — what the lifecycle handlers get as `self`.
---@class Building.Instance
---@field id      string  # the definition's build id
---@field actor   any     # the placed APalBuildObject
---@field pos     table   # { x, y, z } world position
---@field state   table   # your persisted state (mutate in place, then :save())
---@field buildId string  # the game build id this instance matched
---@field key     string  # the instance's stable registry key

--=============================================================================
-- the registered building DEFINITION class (what core/event instantiates + dispatches to)
-- A placed structure IS an instance of this class: core/event calls cls:new(spec), so
-- the lifecycle AND the visual methods below resolve on the instance.
--=============================================================================

local Class = {}
Class.__index = Class
Class.gridCm       = nil   -- nil -> core.spatial.GRID_CM
Class.tickInterval = 1
Class.icon         = nil

-- Instantiate for a placed structure. `spec` becomes the instance's own state (its
-- actor, position, persisted fields, ...). core/event.makeInstance calls this.
function Class.new(cls, spec)
    return setmetatable(spec or {}, cls)
end

-- ---- placement & interaction lifecycle (defaults inert; override via events) ----
function Class:onBuild(ctx) end
function Class:onPlace(ctx) end
function Class:onRightClick(ctx) end
function Class:onLeftClick(ctx) end
function Class:onBreak(ctx) end
function Class:onLoad(ctx) end
function Class:onTick(ctx) end
function Class:onRemove(ctx) end

-- ---- shared world-lifecycle hooks (fired by core.event on every live instance) ----
function Class:onWorldReady(ctx) end
function Class:onWorldLeft(ctx) end

-- ---- 3D representation ----

-- The mesh descriptor to show in-world. Override for a state-driven mesh.
function Class:mesh() return self.meshSpec end

-- The material descriptor applied to the mesh. Override, or supply data fields on the
-- definition (color / texture / materialParams / baseMaterial). Consumed by core.mesh:
--   { color = {r,g,b,a}, texture = <abs png path>, params = {...}, material = <base mat path> }
function Class:material()
    if self.materialSpec then return self.materialSpec end
    if self.color or self.texture or self.materialParams or self.baseMaterial then
        return { color = self.color, texture = self.texture,
                 params = self.materialParams, material = self.baseMaterial }
    end
    return nil
end

-- Current tint for update(), driven by state. Override to colour by working state.
function Class:currentColor() return self.color end

-- Attach mesh + material to this structure's actor (one-shot; core.mesh guards against
-- re-stacking). Needs a valid self.actor and a self:mesh() carrying a `model` path.
-- Fail-soft. NOTE: core/event calls this from the scan, deliberately one scan AFTER the
-- actor first appears — attaching to an actor still mid-init crashes the game.
function Class:render()
    if not (self.actor and self.actor.IsValid and self.actor:IsValid()) then return false end
    local m = self:mesh()
    if not (type(m) == "table" and m.model) then return false end
    local def = {
        kind = m.kind,  -- nil -> procedural, the default backend
        model = m.model, scale = m.scale, offset = m.offset,
        color = m.color, texture = m.texture, params = m.params, material = m.material,
    }
    local mat = self:material()
    if type(mat) == "table" then
        def.color    = mat.color    or def.color
        def.texture  = mat.texture  or def.texture
        def.params   = mat.params   or def.params
        def.material = mat.material or def.material
    end
    return mesh.attachOnce(self.actor, def)
end

-- Push state-driven visual changes: re-tint the live material from self:currentColor().
-- Call from onTick when the structure's look depends on its state.
function Class:update()
    if not (self.actor and self.actor.IsValid and self.actor:IsValid()) then return false end
    local color = self:currentColor()
    if not color then return false end
    return mesh.setColor(self.actor, color)
end

-- The build-menu icon: look the id up in the build-object icon DataTable, falling back
-- to the declared self.icon on any miss.
function Class:iconOf()
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.building, self.id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — module functions
--=============================================================================

---@class palforge.building
local Building = {}

local wrap  -- forward decl; the Building.Handle wrapper is defined in the BOTTOM section

---Define a building and register it. core/event picks the definition up on its next
---scan, so a building defined AFTER startup is still tracked.
---@param spec Building.Spec
---@return Building.Handle
function Building.define(spec)
    assert(type(spec) == "table",
        "Building.define: pass a table, e.g. Building.define{ id = 'X', events = {...} }")
    assert(type(spec.id) == "string" and #spec.id > 0, "Building.define: spec.id (string) is required")
    local cls = setmetatable({
        id           = spec.id,
        displayName  = spec.displayName or spec.id,
        gridCm       = spec.gridCm,
        buildIds     = spec.buildIds,
        tickInterval = spec.tickInterval,
        meshSpec     = spec.mesh,
        materialSpec = spec.material,
        color        = spec.color,
        texture      = spec.texture,
        icon         = spec.icon,
        defaultState = spec.state,
    }, Class)
    cls.__index = cls  -- so a placed instance (cls:new) resolves the class methods
    if type(spec.events) == "table" then
        for name, handler in pairs(spec.events) do cls[name] = handler end  -- onPlace, ...
    end
    pcall(function() om.register("building", spec.id, cls) end)  -- so core/event + get() find it
    return wrap(cls)
end

---Get an EXISTING building by id: a previously-defined one, else a thin definition over
---any game BuildObjectId. Never nil.
---@param id string
---@return Building.Handle
function Building.get(id)
    assert(type(id) == "string" and #id > 0, "Building.get: id (string) is required")
    local cls = om.get("building", id) or setmetatable({ id = id }, Class)
    return wrap(cls)
end

---Every PalForge-registered building, as a list of handles.
---@return Building.Handle[]
function Building.get_all()
    local out = {}
    for _, cls in pairs(om.all("building")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the building OBJECT (Building.Handle): actions + lifecycle events
-- The handle is the DEFINITION-level view. The per-structure view is the live
-- INSTANCE that core/event creates and hands to the lifecycle handlers as `self`;
-- reach those with :instances().
--=============================================================================

---A definable building. Obtain one from Building.define / Building.get / Building.get_all.
---@class Building.Handle
---@field id string   # the building's game BuildObjectId
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Unlock this building's technology so it appears in the BUILD menu. Modded buildings
---get a DT_TechnologyRecipeUnlock row named after their resolved id; this unlocks it.
---@return boolean ok
function Handle:unlock()
    return items.unlockTech(om.resolve(self.id) or self.id)
end

---Every LIVE placed structure of this building in the current world, as instances.
---Empty until core/event's scan has seen them (world must be loaded).
---@return Building.Instance[]
function Handle:instances()
    local ok, list = pcall(function()
        return require("palforge.core.event").instances(self.id)
    end)
    return (ok and type(list) == "table") and list or {}
end

---Attach the mesh to every live structure of this building (normally automatic — the
---scan does it). Returns how many attached.
---@return integer
function Handle:render()
    local n = 0
    for _, inst in ipairs(self:instances()) do
        if pcall(function() return inst:render() end) then n = n + 1 end
    end
    return n
end

---Re-tint every live structure of this building from its currentColor().
---@return integer
function Handle:update()
    local n = 0
    for _, inst in ipairs(self:instances()) do
        if pcall(function() return inst:update() end) then n = n + 1 end
    end
    return n
end

-- ---- lifecycle events (fired by core.event on the live INSTANCE; forward for manual use) ----

---@param ctx table
function Handle:onBuild(ctx) if self._cls.onBuild then return self._cls:onBuild(ctx) end end
---@param ctx table  # ctx.actor, ctx.pos, ctx.player
function Handle:onPlace(ctx) if self._cls.onPlace then return self._cls:onPlace(ctx) end end
---@param ctx table  # ctx.reconstructed = came from a save
function Handle:onLoad(ctx) if self._cls.onLoad then return self._cls:onLoad(ctx) end end
---@param ctx table  # ctx.actor, ctx.player
function Handle:onRightClick(ctx) if self._cls.onRightClick then return self._cls:onRightClick(ctx) end end
---@param ctx table
function Handle:onLeftClick(ctx) if self._cls.onLeftClick then return self._cls:onLeftClick(ctx) end end
---@param ctx table
function Handle:onBreak(ctx) if self._cls.onBreak then return self._cls:onBreak(ctx) end end
---@param ctx table  # ctx.reason
function Handle:onRemove(ctx) if self._cls.onRemove then return self._cls:onRemove(ctx) end end
---@param ctx table  # ctx.count = heartbeat number
function Handle:onTick(ctx) if self._cls.onTick then return self._cls:onTick(ctx) end end

-- ---- queries ----

---@return Building.Mesh?
function Handle:mesh() return self._cls.meshSpec end
---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:displayName() return self._cls.displayName or self.id end
---@return number?
function Handle:gridCm() return self._cls.gridCm end

Building.Class = Class   -- the base hook table (core/event uses it for override detection)
return Building
