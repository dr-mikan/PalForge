-- palforge/api/pal.lua — PUBLIC pal API + implementation (SELF-CONTAINED).
--
-- A pal is a spawnable creature. This module is the TEMPLATE every other api module
-- follows: the module itself is CALLED to define, plus get / get_all, and it returns a
-- Handle object carrying actions and grouped `events`. Its only internal deps are
-- core/object_manager (the registry core/event resolves pals through), core/spawn (the
-- spawn engine), core/mesh and core/icons.
--
-- HOW IT INTEGRATES: Pal{ ... } registers the definition class in object_manager under
-- ("pal", id). core/event resolves a spawned pal's class by its BP class name
-- (BP_<Id>_C -> id -> object_manager.get) and calls cls:onXxx(ctx) with the class as
-- self — so a definition's lifecycle handlers just work. The same one resolver serves both
-- halves of the 導線: the four native hooks below and the onTick sweep.
--
--   WIRED (live — see core/event installPalSource):
--     onCaptured <- PalCharacterParameterComponent:SetIsCapturedProcessing(true)
--                   (ctx.actor = the pal, ctx.comp = its parameter component)
--     onDamaged  <- PalCharacter:OnDamageReaction        (ctx.actor)
--     onDeath    <- PalCharacter:OnDeadCharacter         (ctx.actor)
--     onSpawned  <- PalCharacter:BroadcastOnCompleteInitializeParameter (ctx.actor).
--                   Still an UNCONFIRMED candidate, and now ARMED LATE: core/event
--                   registers it on world.ready, never at mod load, because it fires for
--                   every pal in the world-load init storm and doing that once wedged the
--                   shared UE4SS hook dispatch — which would take the three confirmed hooks
--                   down with it. Late arming protects them; it does not make the hook
--                   proven. It is still unshown that it signals a FRESH spawn rather than a
--                   re-init, so keep the handler idempotent.
--     onTick     <- core/event's pal sweep. There is NO native hook behind this one; the
--                   sweep is the source, and it is described in full below.
--   NOT WIRED: nothing. All five declared events have a source.
--
-- THE onTick SWEEP — what it is and what it costs, because it is the one hook driven by
-- polling rather than by the game. Pals have no per-instance tracking (dispatch resolves a
-- CLASS, not an object), so nothing but a sweep can drive a periodic pal hook. core/event
-- walks FindAllOf("PalCharacter") on its own cadence and calls onTick once per matching
-- live pawn, with ctx.actor = that pawn, ctx.count = the heartbeat number and ctx.now =
-- os.clock(). It is gated on the same worldReady flag as everything else, each call is
-- pcall'd, and a handler that raises five times in a row is logged and then switched off
-- for the rest of the session — for every pawn of that id, since the breaker sits on the
-- definition, not on the pawn. The building tick's discipline, reused.
--   INTERVAL: core.event.PAL_SCAN_MS, 3000 ms by default. Deliberately not the 500 ms
--   heartbeat, and re-read on every heartbeat so a pack can retune it live —
--   `require("palforge.core.event").PAL_SCAN_MS = 5000`; 0 or nil turns the sweep off.
--   COST, which is why that number is what it is: FindAllOf walks every UObject and is the
--   known periodic-hitch source (the old scheduler backed off to 4 s settled / ~15 s idle
--   for exactly that reason), and the building scan already runs one such sweep every
--   500 ms. So this one is throttled to ~1 sweep / 3 s, does no FindAllOf AT ALL while no
--   pal is registered, and resolves each actor's class exactly ONCE: the result — the class, or a
--   miss — is memoized in a weak actor-keyed table that is dropped only when the registered
--   pal count changes. A world of ~20-40 vanilla pals therefore costs one failed lookup
--   each and a table read per sweep thereafter, and a definition that never overrides
--   onTick is never called at all.
--   NO PER-PAL STATE: `self` is this definition's handle, one handle for every pawn of that
--   id, so anything per-pawn has to be keyed by ctx.actor yourself.
--
-- ACTIONS are real: :spawn goes through UPalCheatManager (server-verified; core/spawn
-- constructs one itself on a dedicated server, where nothing else does). A coordinate
-- spawn is a spawn-then-relocate, so it reports that the spawn was ACCEPTED, not that
-- the pal reached the coordinate — see :spawn below. Note that defining gives an
-- EXISTING CharacterID behaviour — Lua cannot add a brand-new creature row (that is
-- PalSchema's job).
--
-- LAYOUT
--   SPEC    — the shape of Pal{ ... }, declared as data (core/schema). It is PRIVATE to
--             this file: it is enforced on every call, and Scripts/palforge/types.lua is
--             generated from it for editor completion, but it is not part of the surface.
--             Read it at runtime with schema.help("Pal.Spec").
--   TOP     — the module surface:   Pal{ ... } / Pal.get / Pal.get_all
--   BOTTOM  — the pal OBJECT (Pal.Handle): actions (:spawn) + lifecycle events.
--
-- A DEFINITION IS ONE PIECE OF DATA. Everything is named, a nested definition is passed
-- as itself, and events are grouped under `events` as `function(pal, ctx)` — `pal` is
-- THIS definition's handle (so :spawn / :renderOn are right there) and ctx.actor is the
-- pawn the event happened to:
--
--   local pal = Pal{
--       id          = "NewPal",
--       name        = "New Pal",
--       description = "the one that greets you",
--       mesh        = Mesh{ id = "newpal:body", model = "/Game/.../SK_X" },
--       events      = {
--           onSpawned = function(pal, ctx)
--               pal:renderOn(ctx.actor)
--               Audio.get("AKE_BGM_Title"):play()   -- get, not define: a handler runs often
--           end,
--       },
--   }
--   pal:spawn(Player.coordinate())

local om      = require("palforge.core.object_manager")
local spawn   = require("palforge.core.spawn")
local mesh    = require("palforge.core.mesh")
local icons   = require("palforge.core.icons")
local schema  = require("palforge.core.schema")

-- The mesh a spawned pawn wears is api/mesh's shape, not a copy of it, so `mesh = { ... }`
-- written inline and `mesh = Mesh{ ... }` passed as a defined object are the same shape
-- and can never drift apart. Requiring the module is what puts that shape in the registry.
require("palforge.api.mesh")
local Mesh = schema.get("Mesh.Spec")

--=============================================================================
-- SPEC — the shape of Pal{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL: the module
-- is a thing you call, not a namespace to browse. When you need to see the fields at
-- runtime, ask the registry:
--
--   schema.help("Pal.Spec")             -- every field, its type, default and meaning
--   schema.get("Pal.Spec").fields       -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean: a
-- silently ignored typo is exactly what this layer exists to prevent.
--=============================================================================

local Material = schema.define("Pal.Spec.Material", {
    { "color",    type = "table",  doc = "tint { r, g, b, a } in 0..1" },
    { "texture",  type = "string", doc = "absolute path to a png applied to the mesh" },
    { "params",   type = "table",  doc = "extra material parameters passed through" },
    { "material", type = "string", doc = "base material asset path to instance from" },
})

---The lifecycle handlers a pal can respond to. All optional. Each receives THIS pal's
---handle as its first argument and an event context `ctx` (ctx.actor = the pawn in the
---world). An event this list does not name is a hard error, not a silent no-op.
local Events = schema.define("Pal.Spec.Events", {
    { "onSpawned",  type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE (UNCONFIRMED candidate, armed only after the world loads) - finished spawning into the world" },
    { "onDamaged",  type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - took damage" },
    { "onDeath",    type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - HP reached zero" },
    { "onCaptured", type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - caught in a sphere" },
    { "onTick",     type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - core/event's pal sweep, once per live pawn every core.event.PAL_SCAN_MS (default 3 s)" },
})

---What you pass to Pal{ ... }. `id` is the only required field.
local Spec = schema.define("Pal.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "pal id: a game CharacterID (\"ChickenPal\") or \"pack:name\"" },
    { "name",        type = "string", doc = "shown in UI (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "skills",      type = "table", arrayOf = "string", doc = "skill ids this pal owns (see Skill)" },
    { "mesh",        type = "table", of = Mesh,
                     doc = "the mesh attached to a spawned pawn (inline, or a Mesh{ ... } handle)" },
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
-- Inert like the rest, and load-bearing as a BASELINE: core/event's pal sweep compares a
-- definition's onTick against this very function to decide whether the definition really
-- implements it, so a pal that declares no onTick costs nothing per sweep.
function Class:onTick(ctx) end

function Class:skillsOf() return self.skills or {} end
function Class:mesh() return self.meshSpec end

-- The material descriptor applied to the mesh, from the declared data fields. Consumed by
-- core.mesh: { color = {r,g,b,a}, texture = <abs png path>, params = {...}, material = ... }
-- `material = { ... }` (Pal.Spec.Material) carries all four; the top-level `color` /
-- `texture` shorthands carry those two and nothing else — there is no shorthand spelling
-- for params / material, so nothing else can be assembled here.
function Class:material()
    if self.materialSpec then return self.materialSpec end
    if self.color or self.texture then
        return { color = self.color, texture = self.texture }
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
-- TOP — the module surface: Pal{ ... } / Pal.get / Pal.get_all
--=============================================================================

---The pal domain. CALL it to define a pal; the two named functions look existing ones up.
---@class palforge.pal
---@overload fun(spec: Pal.Spec): Pal.Handle
local Pal = {}

local wrap  -- forward decl; the Pal.Handle wrapper is defined in the BOTTOM section

---Define a NEW pal and register it. Returns a handle you can chain :spawn on.
---`spec` is validated against Pal.Spec: `id` is required, unknown fields are an error.
---@param spec Pal.Spec
---@return Pal.Handle
local function define(spec)
    spec = Spec:validate(spec, "Pal")
    local cls = setmetatable({
        id           = spec.id,
        name         = spec.name or spec.id,
        description  = spec.description,
        skills       = spec.skills,
        meshSpec     = spec.mesh,
        materialSpec = spec.material,
        color        = spec.color,
        texture      = spec.texture,
        icon         = spec.icon,
        data         = spec.data,
    }, Class)
    cls.__index = cls  -- so a spawned instance (if ever made) resolves the class methods
    local handle = wrap(cls)
    -- dispatch calls cls:onXxx(...) with the CLASS as self; a handler wants the HANDLE
    -- (what the call returned, and what carries :spawn / :renderOn), so each declared
    -- handler goes in behind a forwarder that swaps it in.
    for name, handler in pairs(spec.events or {}) do           -- onSpawned, ...
        cls[name] = function(_, ...) return handler(handle, ...) end
    end
    pcall(function() om.register("pal", spec.id, cls) end)  -- so core/event + get() find it
    return handle
end

-- Calling the module IS defining:  Pal{ id = "NewPal", ... }
setmetatable(Pal, { __call = function(_, spec) return define(spec) end })

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

---A definable/live pal. Obtain one from Pal{ ... } / Pal.get / Pal.get_all.
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
---
---`true` means the native spawn call was ACCEPTED, not that a pal is standing there:
---the game spawns the actor a few frames later, and the coordinate form additionally
---relocates it in a deferred pass that finishes long after this returns (its outcome is
---logged, not returned). `false` is definite — nothing was even attempted.
---@param arg Coord|table|nil
---@return boolean accepted   # the spawn call was accepted (see above), NOT arrival
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
---re-stacking). Pals get no tracked instance, so the caller supplies the actor — typically
---`ctx.actor` inside onSpawned, or inside onTick if the sweep is how you find your pawns.
---Fail-soft false when there is no mesh or no valid actor.
---NOTE: the material fields (color / texture / params / material) are applied by the
---procedural / obj backends only; on the default skeletal backend they are carried but
---inert, so a true return there means the MESH was swapped, not that it was painted.
---@param actor any   # the pawn to decorate (e.g. ctx.actor)
---@return boolean ok
function Handle:renderOn(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then return false end
    local m = self._cls:mesh()
    if not (type(m) == "table" and m.model) then return false end
    local def = {
        kind = m.kind,  -- filled by Mesh.Spec's default ("skeletal") when declared inline
        model = m.model, animClass = m.animClass, scale = m.scale, offset = m.offset,
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
---@param ctx table  # ctx.actor
function Handle:onDamaged(ctx) if self._cls.onDamaged then return self._cls:onDamaged(ctx) end end
---@param ctx table  # ctx.actor
function Handle:onDeath(ctx) if self._cls.onDeath then return self._cls:onDeath(ctx) end end
---@param ctx table  # ctx.actor, ctx.comp = the pal's parameter component
function Handle:onCaptured(ctx) if self._cls.onCaptured then return self._cls:onCaptured(ctx) end end
---@param ctx table  # ctx.actor, ctx.count = heartbeat number, ctx.now
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
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end

Pal.Class = Class   -- the base hook table (core/event's pal sweep compares onTick against
                    -- it for override detection; also the base for subclassing)
return Pal
