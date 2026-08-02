-- palforge/api/building.lua — PUBLIC building API + implementation (SELF-CONTAINED).
--
-- A building is a placeable structure: workbenches, storage, machines, decorations —
-- anything picked from the build menu and set into the world. Same shape as every other
-- api module (call it to define, plus get / get_all + a Handle object with actions and
-- grouped `events`).
--
-- HOW IT INTEGRATES: Building{ ... } registers the definition class in object_manager
-- under ("building", id). core/event owns the FULL building runtime and is the most
-- complete 導線 in PalForge:
--   * a RequestBuild_ToServer hook records the placement intent,
--   * a ~500 ms reconstruction scan over FindAllOf("PalBuildObject") discovers the real
--     actor, creates a live INSTANCE (def.cls:new{...}), persists it per world, and
--     attaches the mesh on a later scan (deferred — attaching the frame it is placed
--     crashes the game),
--   * an OnBeginInteractBuilding hook drives the interact channel,
--   * an OnCompleteBuild_ServerInternal hook drives onBuild — armed only once the world
--     is ready, and dispatched to the DEFINITION rather than to an instance (see below),
--   * the shared heartbeat drives onTick (per-instance tickInterval + circuit breaker).
-- This is the one domain where a placed structure really does get its own stateful
-- instance with save/load, and where onPlace / onLoad / onRightClick / onRemove / onTick /
-- onWorldReady / onWorldLeft all fire for real.
--
--   WIRED (live — see core/event installBuildingSource + installDispatch):
--     onPlace      <- the scan, matched to a RequestBuild intent  (ctx.actor, ctx.pos, ctx.player)
--     onLoad       <- the scan, every newly tracked structure     (ctx.reconstructed)
--     onRightClick <- PalBuildObject:OnBeginInteractBuilding      (ctx.actor, ctx.player)
--     onRemove     <- the scan's miss sweep                       (ctx.reason)
--     onTick       <- the shared heartbeat                        (ctx.count; see tickInterval)
--     onWorldReady / onWorldLeft <- the world-load watch, fired on every live instance
--     onBuild      <- PalPlayerRecordData:OnCompleteBuild_ServerInternal (ctx.buildId,
--                     ctx.model) — DEFINITION-dispatched and armed late; see the next paragraph
--   NOT WIRED: onLeftClick / onBreak. Not "not found yet" — SETTLED NEGATIVELY, by reading
--     the complete function lists of every class that could own one (building-leftclick,
--     building-break, building-break-source). There is no click/hit/strike entry on
--     PalBuildObject's 22 functions, the one damage-shaped entry is the deterioration timer
--     firing every 12-13 s per structure with no player involved, and destruction exists only
--     as delegate FIELDS, which RegisterHook cannot address by path. The only proven click
--     hook in the tree is a UMG widget button, and disappearance is covered by the scan's miss
--     sweep -> onRemove(reason = "missing"). They stay declarable so a pack's own emit works
--     and so a future source has somewhere to arrive; nothing emits them today.
--
-- THE VISUAL LAYER, HONESTLY. A structure's `mesh` really is attached: core/mesh's static
-- backend adds a UStaticMeshComponent and confirms the asset landed on it before claiming
-- success. `color` / `texture` / `material` / `params` reach it too — the MID work is
-- core/mesh/base/renderer's, shared by every backend — and :update() re-tints through the
-- same MIDs. The one thing nobody has measured is which PARAMETER NAMES a Palworld
-- material actually carries: the layer writes a candidate list and the names the material
-- does not have are silent no-ops, so a tint can execute and still not be visible. That
-- parameter names are measured and recorded in core/mesh/base/renderer.lua.
--
-- A live structure can also look around itself: `self:neighbors(radiusCm)` inside any
-- instance hook returns every other tracked structure within that radius (core.spatial's
-- hash grid, re-bucketed first so a structure that moved is still found).
--
-- The lifecycle receives the live INSTANCE as `self` (not the class): self.actor is the
-- placed actor, self.pos its world position, self.state your persisted table, and
-- self:save() writes it. onBuild is the ONE exception, and it has to be: it fires at
-- build-COMPLETE, up to one scan (~500 ms) before the instance exists, and the game hands
-- it a UPalMapObjectModel rather than the actor — so core/event dispatches it to the
-- DEFINITION class instead (self.id and self:iconOf() are there; self.actor / self.pos /
-- self.state / self:save() are NOT), matched by the game build id the definition claims.
-- Its native hook also fires for every pre-existing structure during the world-load storm,
-- where reading that model once produced a native access violation, so core/event arms it
-- only after world.ready and never at mod load — which means it also stays silent in a
-- session where the world never finishes loading. onPlace remains the safe placement hook;
-- onBuild is the extra one, worth trying in a throwaway world first.
--
-- onWorldReady fires on the live instances: the ready-watch opens core/event's worldReady
-- gate, but world.ready is emitted by the FIRST reconstruction scan that completes after
-- it, so the structures around the player are already tracked when the hook runs. It is a
-- ONE-SHOT world-load moment, not a per-structure one — anything that streams in on a
-- later scan misses it, so per-instance startup work belongs in onLoad.
--
--   Building{
--       id = "example:Bench", name = "Modded Bench", gridCm = 100,
--       mesh  = { kind = "static", model = "/Game/.../SM_Bench.SM_Bench" },
--       state = { uses = 0 },                       -- default persisted state
--       events = {
--           onPlace      = function(self, ctx) self.state.uses = 0; self:save() end,
--           onRightClick = function(self, ctx) self.state.uses = self.state.uses + 1 end,
--           onTick       = function(self, ctx) end,
--       },
--   }
--
-- The call takes an optional SECOND argument, `opts`, which controls registration and nothing
-- else: `Building(spec, { register = false })` builds and returns the Handle without putting
-- the definition in the registry, and `{ pack = "mypack" }` records who owns the id. Omitting
-- it behaves exactly as it always has. In this domain `register = false` is the difference
-- between a read and a write — see `define` below for why registering a building is not inert.

local om      = require("palforge.core.object_manager")
local icons   = require("palforge.core.icons")
local mesh    = require("palforge.core.mesh")
local items   = require("palforge.utils.items")
local schema  = require("palforge.core.schema")
local spatial = require("palforge.core.spatial")
-- WHAT THIS PACK MADE THE GAME WRITE. :unlock is one of the three calls that appends to
-- PALWORLD'S save rather than to PalForge's own sidecar — and the only one of the three that
-- can never be undone. The record is written by utils.items.unlockTech, at the engine
-- boundary, so this file requires no ledger: hooking the api Handle covered one caller of a
-- toolbox main.lua publishes for packs to call directly. Fail-soft either way — a ledger
-- append never raises and never changes what :unlock returns.
-- core.event is NOT required here: it requires THIS module at load (for the base hook
-- table), so every use of it below is a lazy, pcall'd require inside the function.

require("palforge.api.mesh")   -- declares "Mesh.Spec", the shape this file derives from

--=============================================================================
-- SPEC — the shape of Building{ ... }, declared as data so it is enforced on every call
-- and so the editor type definitions can be generated from it. It stays a LOCAL; read it
-- at runtime through the registry:
--
--   schema.help("Building.Spec")         -- every field, its type, default and meaning
--   schema.get("Building.Spec").fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
--=============================================================================

---The mesh attached to a placed structure: exactly api/mesh's shape, so a named
---`Mesh{ ... }` handle can be worn by a building too, with the one thing that is this
---domain's own policy overridden — a structure is a static mesh where a pal is a
---skeletal one. Deriving rather than re-declaring means a field added to Mesh.Spec
---reaches buildings without anyone remembering to copy it.
local Mesh = schema.derive("Building.Spec.Mesh", schema.get("Mesh.Spec"), {
    kind   = { default = "static" },
    model  = { doc = "UStaticMesh asset path, or an OBJ path for the procedural backend" },
    offset = { doc = "{ x, y, z } offset from the actor's origin" },
})

local Material = schema.define("Building.Spec.Material", {
    { "color",    type = "table",  doc = "tint { r, g, b, a } in 0..1" },
    { "texture",  type = "string", doc = "absolute path to a png applied to the mesh" },
    { "params",   type = "table",  doc = "extra material parameters passed through" },
    { "material", type = "string", doc = "base material asset path to instance from" },
})

---The lifecycle handlers a building can respond to. All optional. Each receives the LIVE
---INSTANCE as `self` (self.actor / self.pos / self.state) and the event context `ctx` —
---except onBuild, which fires before any instance exists and so gets the DEFINITION.
local Events = schema.define("Building.Spec.Events", {
    { "onPlace",      type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - committed into the world" },
    { "onLoad",       type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - tracked / restored from a save" },
    { "onRightClick", type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - primary interaction" },
    { "onRemove",     type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - the structure vanished" },
    { "onTick",       type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - heartbeat (see tickInterval)" },
    { "onWorldReady", type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - world loaded; emitted after the first scan, so only structures already tracked get it" },
    { "onWorldLeft",  type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "LIVE - the world was unloaded (emitted while instances are still live)" },
    { "onBuild",      type = "function", sig = "fun(self: Building.Definition, ctx: table)",
                      doc = "LIVE - build completed; nothing is placed yet, so `self` is the DEFINITION (ctx.buildId, ctx.model)" },
    { "onLeftClick",  type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "declarable, never fires - measured: PalBuildObject has no click/hit function, and its OnDamage is the deterioration timer" },
    { "onBreak",      type = "function", sig = "fun(self: Building.Instance, ctx: table)",
                      doc = "declarable, never fires - measured: destruction exists only as delegate FIELDS; a dismantle arrives as onRemove(reason=\"missing\")" },
})

---What you pass to Building{ ... }. `id` is the only required field.
local Spec = schema.define("Building.Spec", {
    { "id",           type = "string", required = true, check = schema.nonEmpty,
                      doc = "build id: a game BuildObjectId (\"PalBoxV2\") or \"pack:name\"" },
    { "name",         type = "string", doc = "shown in UI (defaults to id)" },
    { "description",  type = "string", doc = "one-line description, for UI and tooling" },
    { "gridCm",       type = "number", doc = "placement grid quantum in cm (default core.spatial.GRID_CM)" },
    { "buildIds",     type = "table", arrayOf = "string",
                      doc = "the game build ids this definition claims; REPLACES the default { id }" },
    { "tickInterval", type = "number", default = 1, doc = "run onTick every N heartbeats" },
    { "mesh",         type = "table", of = Mesh,
                      doc = "the mesh attached to the placed actor (inline, or a Mesh{ ... } handle)" },
    { "material",     type = "table", of = Material, doc = "material override applied to that mesh" },
    { "color",        type = "table",  doc = "base tint { r, g, b, a } (shorthand for material.color)" },
    { "texture",      type = "string", doc = "png path applied to the mesh (shorthand for material.texture)" },
    { "icon",         doc = "fallback icon used when the DataTable lookup misses" },
    { "state",        type = "table|function", sig = "table|fun(): table",
                      doc = "default persisted state for a new instance (a table, or a factory returning one)" },
    { "events",       type = "table", of = Events, doc = "lifecycle handlers (grouped)" },
    { "data",         type = "table", doc = "free-form payload of your own, carried onto the definition" },
})

---A LIVE placed structure — what the lifecycle handlers get as `self`.
---@class Building.Instance
---@field id      string  # the definition's build id
---@field actor   any     # the placed APalBuildObject
---@field pos     table   # { x, y, z } world position
---@field state   table   # your persisted state (mutate in place, then :save())
---@field buildId string  # the game build id this instance matched
---@field key     string  # the instance's stable registry key

---The registered DEFINITION — what a CLASS-dispatched hook gets as `self`. It is the table
---Building{ ... } registered (its declared fields plus the class methods below), not a live
---structure: there is no .actor / .pos / .state / :save() on it, and one definition stands
---for every structure of that id. Only onBuild is dispatched this way, because it fires
---before any instance exists.
---@class Building.Definition
---@field id          string   # the definition's build id
---@field name        string   # display name (defaults to id)
---@field description string?  # the declared one-liner, if any
---@field data        table?   # your free-form payload from the spec

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
-- All of these are called on the live INSTANCE except onBuild, which core/event calls on
-- the definition class itself (nothing is placed yet when it fires).
function Class:onBuild(ctx) end
function Class:onPlace(ctx) end
function Class:onRightClick(ctx) end
-- INERT, AND MEASURED TO BE UNFIXABLE FROM LUA ON THIS BUILD. PalBuildObject's complete
-- function list is now on disk (dumps/reflection/02_reflection.txt, 22 functions) and
-- carries nothing that runs when a player STRIKES a structure: the only input-shaped
-- entries are the interact family (OnBeginInteractBuilding / OnTriggerInteractBuilding /
-- OnStartTriggerInteractBuilding / OnEndTriggerInteractBuilding), which is right-click and
-- is already onRightClick. The one damage-shaped entry, OnDamage, is NOT a strike: in
-- dumps/reflection/06_events.txt it fires 196 times on a strict 12-13 s per-structure
-- cadence — the workbench placed at t=306.412 takes its first at t=306.933 and 180 more
-- over the next 2250 s without dying — i.e. it is the deterioration tick (cf. the
-- :DeteriorationDamage / :DeteriorationTotalDamage fields on PalMapObjectModel), which
-- fires with no player anywhere near it. Wiring onLeftClick to it would call the handler
-- every 12 s on every structure in the base forever.
-- Left declared: the hook, its schema entry and Handle:onLeftClick still work for a pack's
-- own emit, and the dumps cover /Script/Pal.* only — a BP_BuildObject_<Id>_C subclass
-- graph event is the one place not yet enumerated.
function Class:onLeftClick(ctx) end
-- INERT, for the same measured reason. No destroy/dismantle UFunction exists on ANY of the
-- classes that could own one: PalBuildObject (22 fns), PalMapObjectModel (18),
-- PalMapObjectConcreteModelBase (25) and PalNetworkPlayerComponent (77) are all listed in
-- full in dumps/reflection/02_reflection.txt and none has a Destroy/Dismantle/Demolish/
-- Deconstruct/Break entry. Destruction exists there only as DELEGATE FIELDS
-- (PalMapObjectModel:OnDestroyDelegate, :OnDisposeDelegateInServer), which RegisterHook
-- cannot address by path, and PalBuildObject.OnChangeVisualForDismantle is the dismantle
-- PREVIEW visual (cf. :bDismantleTargetInLocal), not a completion. OnDamage is a
-- deterioration tick and never signalled a destruction (see onLeftClick above).
-- So disappearance keeps surfacing through the scan's miss sweep as onRemove with
-- ctx.reason = "missing", which cannot tell a dismantle from a streamed-out structure.
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

-- The material descriptor applied to the mesh: the declared `material = { ... }` block
-- when there is one, else the `color` / `texture` shorthands lifted into that same shape.
-- Consumed by core.mesh:
--   { color = {r,g,b,a}, texture = <abs png path>, params = {...}, material = <base mat path> }
-- Only spec fields are read. Building.Spec is STRICT, so a definition can carry nothing
-- else — the fuller shape (extra params, a base material path) is declared as
-- `material = { params = ..., material = ... }` and returned by the first branch as-is.
-- Override the method for a state-driven material.
function Class:material()
    if self.materialSpec then return self.materialSpec end
    if self.color or self.texture then
        return { color = self.color, texture = self.texture }
    end
    return nil
end

-- Current tint for update(), driven by state. Override to colour by working state.
function Class:currentColor() return self.color end

-- Attach mesh + material to this structure's actor (one-shot; core.mesh guards against
-- re-stacking). Needs a valid self.actor and a self:mesh() carrying a `model` path.
-- Fail-soft. NOTE: core/event calls this from the scan, deliberately one scan AFTER the
-- actor first appears — attaching to an actor still mid-init crashes the game.
--
-- WHAT `true` MEANS: the MESH attached. The colour / texture / params / material half of
-- `def` is lowered with it and core/mesh's shared material layer writes it onto the
-- component's dynamic material instances, but a write to a parameter the material does not
-- carry is a silent no-op, so a declared tint is attempted rather than guaranteed
-- (the names are measured now — see core/mesh/base/renderer.lua). Attachment failure IS
-- reported: false, and no half-dressed component left behind.
function Class:render()
    if not (self.actor and self.actor.IsValid and self.actor:IsValid()) then return false end
    local m = self:mesh()
    if not (type(m) == "table" and m.model) then return false end
    local def = {
        kind = m.kind,  -- Building.Spec.Mesh fills this in; it defaults to "static"
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
--
-- Returns true when the write EXECUTED on a real dynamic material instance — core.mesh
-- routes it to whichever backend dressed the actor, and that backend makes the MID on the
-- spot if the mesh was attached without a colour. false means there was nothing to write
-- to (no mesh of ours on the actor, or no colour). Which parameter name a Palworld
-- material answers to is still unmeasured, so an executed write is not yet proof of a
-- visible change: the names are measured, but no tint has been watched land.
function Class:update()
    if not (self.actor and self.actor.IsValid and self.actor:IsValid()) then return false end
    local color = self:currentColor()
    if not color then return false end
    return mesh.setColor(self.actor, color)
end

-- ---- spatial queries (LIVE INSTANCE only) ----

-- Every OTHER live structure within `radiusCm` of this one — any building definition, not
-- just this one's — as instances. Empty on a definition (no self.pos) and on a bad radius.
--
--   events = { onTick = function(self)
--       for _, n in ipairs(self:neighbors(350)) do ... end   -- everything within 3.5 m
--   end }
--
-- This is the api-level consumer of core.spatial's hash-grid index. The building runtime keeps
-- that index in step: addInstance / removeInstance bucket and un-bucket, and the scan's fast
-- path re-buckets a tracked instance whose position changed (core/event.lua's scanOnce calls
-- spatial.indexUpdate right after `bound.pos = p`). This paragraph used to say the opposite —
-- that the scan refreshed the position IN PLACE and never re-bucketed, so a structure that
-- moved kept a stale bucket — and that was true in effect but not for the reason given: the
-- indexUpdate call was already written, and the actor lookup ABOVE it was keyed on the UE4SS
-- handle, so the whole fast path missed on every sweep and the re-bucket never ran (contract
-- C1, core/spatial.lua's own header carries the account).
--
-- The reindexAll below stays anyway, and not out of caution: instances a pack indexes itself
-- have no driver at all, and the pass is O(tracked structures) of pure Lua with no engine call
-- that touches a bucket only for the entries whose cell really changed — cheaper than reasoning
-- about whether the last scan has run yet.
---@param radiusCm number  # search radius in centimetres
---@return Building.Instance[]
function Class:neighbors(radiusCm)
    if type(radiusCm) ~= "number" or radiusCm <= 0 then return {} end
    if type(self.pos) ~= "table" then return {} end   -- a definition, not a placed structure
    pcall(function()
        spatial.reindexAll(require("palforge.core.event").instances())
    end)
    local ok, list = pcall(function() return spatial.neighbors(self.pos, radiusCm, self) end)
    return (ok and type(list) == "table") and list or {}
end

-- The build-menu icon: look the id up in the build-object icon DataTable, falling back
-- to the declared self.icon on any miss.
--
-- THE ID IS RESOLVED FIRST, and it was not until 2026-08-02. A DataTable row FName is the
-- RESOLVED form — "example:Bench" is the row "example_Bench" — so passing the declared id raw
-- meant every namespaced definition missed the lookup and returned its declared fallback icon.
-- That looks identical to "this build has no icon for that row", which is exactly the shape of
-- a missing call rather than a measured limit: DT_BuildObjectIconDataTable read 567 of 571 rows
-- in a live save (icons-row-read), so the lookup works and it was the argument that was wrong.
-- `resolve(x) or x`, never `resolve(x)` alone — an id that cannot resolve falls back to the
-- LITERAL so a malformed id still asks the game the only question it can.
-- Handle:unlock (below) has always spelled it this way; the two now agree.
function Class:iconOf()
    local id = om.resolve(self.id) or self.id
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.building, id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — the module surface: Building{ ... } / Building.get / Building.get_all
--=============================================================================

---The building domain. CALL it to define one; the two named functions look existing ones up.
---@class palforge.building
---@overload fun(spec: Building.Spec, opts: table?): Building.Handle
local Building = {}

local wrap  -- forward decl; the Building.Handle wrapper is defined in the BOTTOM section

---Define a building and register it. core/event picks the definition up on its next
---scan, so a building defined AFTER startup is still tracked.
---`spec` is validated against Building.Spec: `id` is required, unknown fields are an error.
---
---`opts` is optional and controls REGISTRATION only, never the definition itself:
---
---    Building(spec)                            -- define and register (what everything did)
---    Building(spec, { register = false })      -- build the Handle, register NOTHING
---    Building(spec, { pack = "mypack" })       -- register with that pack as the owner
---
---`register = false` matters more here than in any other domain, because registering a
---building is NOT inert: core/event's ~500 ms reconstruction scan picks the new definition up,
---and every matching actor already standing in the world becomes a tracked instance that is
---PERSISTED to the save's entity file. So `native.buildings.Foundation` — a read, in a tooltip
---— used to make PalForge start writing a record for every foundation in the base, and a pack
---iterating the 498-id CATALOG to fill a picker persisted the whole base. A read asks for
---`{ register = false }`; a definition the author actually wants in the world does not.
---@param spec Building.Spec
---@param opts table?  # { register = boolean, pack = string }
---@return Building.Handle
local function define(spec, opts)
    spec = Spec:validate(spec, "Building")
    -- The id SHAPE is checked here, at define time, and it is not the same check as the
    -- schema's nonEmpty. An id whose halves are not [%w_]+ ("my-pack:Bench") registers
    -- perfectly and is then dead at every engine boundary: om.resolve refuses it, so the
    -- DataTable row name it needs cannot be built, and the definition sits in the registry
    -- looking healthy while its icon lookup, its technology unlock and its build-id match all
    -- miss. Failing at the define call is the only place an author can see it happen.
    local okId, whyId = om.validId(spec.id)
    if not okId then
        error(string.format("PalForge: Building: field %q is invalid: %s", "id",
            whyId or "not a usable id"), 0)
    end
    local cls = setmetatable({
        id           = spec.id,
        name         = spec.name or spec.id,
        description  = spec.description,
        gridCm       = spec.gridCm,
        buildIds     = spec.buildIds,
        tickInterval = spec.tickInterval,
        meshSpec     = spec.mesh,
        materialSpec = spec.material,
        color        = spec.color,
        texture      = spec.texture,
        icon         = spec.icon,
        defaultState = spec.state,
        data         = spec.data,
    }, Class)
    cls.__index = cls  -- so a placed instance (cls:new) resolves the class methods
    if spec.events then
        -- installed as-is: a building's handler receives the LIVE INSTANCE as `self`,
        -- which is the object the event happened to (.actor / .pos / .state / :save()).
        for name, handler in pairs(spec.events) do cls[name] = handler end  -- onPlace, ...
    end
    -- Registration is best-effort (pcall) so a registry hiccup cannot break a definition that
    -- is otherwise fine — the class is built and returned either way. `register = false` skips
    -- it entirely: the Handle works, core/event never sees the definition, and nothing is
    -- persisted for it.
    if not (type(opts) == "table" and opts.register == false) then
        local packOpts = (type(opts) == "table" and opts.pack) and { pack = opts.pack } or nil
        pcall(function() om.register("building", spec.id, cls, packOpts) end)  -- core/event + get() find it
    end
    return wrap(cls)
end

-- Calling the module IS defining:  Building{ id = "example:Bench", ... }
-- The second argument is the optional `opts` above; omitting it behaves exactly as it always
-- has. A scoped surface (PalForge.pack("mypack").Building) is the same call with opts.pack
-- filled in for you.
setmetatable(Building, { __call = function(_, spec, opts) return define(spec, opts) end })

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

---A definable building. Obtain one from Building{ ... } / Building.get / Building.get_all.
---@class Building.Handle
---@field id string   # the building's game BuildObjectId
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Unlock this building's technology so it appears in the BUILD menu. Modded buildings
---get a DT_TechnologyRecipeUnlock row named after their resolved id; this unlocks it.
---
---⚠️ NEVER OBSERVED WORKING, AND UNVERIFIABLE BY CONSTRUCTION — say so before a pack leans on
---it. `true` here does NOT mean the technology is unlocked. It means two things that CAN be
---read: the CheatManager call `UnlockOneTechnology(FName)` was issued without raising, and a
---technology row of that resolved name really exists in the live DT_TechnologyRecipeUnlock
---(only 115 of the 501 vanilla build ids have one, so that check is what stops the cheat
---"succeeding" for a building that has nothing to unlock). What cannot be read is the result:
---UnlockOneTechnology returns nothing, and it rides the same cheat-manager route that
---`pal-spawnmonster-signature` measured as accepting a call and silently doing nothing, which is
---the failure mode this cannot distinguish itself from.
---
---⚠️ CORRECTION, 2026-08-02. This docstring said for months that "no 'is this technology
---unlocked' accessor exists anywhere on this build — not in dumps/cxx". THAT IS FALSE, and it
---sent at least one reader away from a route that is right there: dumps/cxx/Pal.hpp:29999-30001
---declares, on UPalTechnologyData (:29966, reached from APalPlayerState.TechnologyData),
---    bool IsUnlockRecipeTechnology(const FName& technologyName);
---    bool IsUnlockCraftRecipe(const FName& craftRecipeName);
---    bool IsUnlockBuildObject(const FName& BuildObjectId);
---Three read-backs, each taking exactly the FName this call passes. Nothing here calls them yet
---and this return value is unchanged, because a DUMP is not the running build — that lesson cost
---this tree a week when AddItem_ServerInternal turned out to declare five parameters where the
---dump had four. Whether the live build declares them is what `pf_hook building-unlock` walks
---with core.signature's describe, on a live UPalTechnologyData; if they are there, `issued`
---becomes a real verdict and core/ledger's technology half gains the one thing it can report on.
---(This paragraph named `test/hooks/tech-unlock-readback` until 2026-08-02, and no such hook was
---ever declared — the measurement belongs to `building-unlock`, which is right below and already
---owns the same question from the other end.)
---
---Until then the only way to settle it is to press it in a save and LOOK at the build menu. That
---is the declared hook `test/hooks/building-unlock` (needs a world and a player, writes = true —
---it mutates the player's technology state), not a unit check.
---
---⚠️ A SUCCESSFUL UNLOCK REACHES PALWORLD'S OWN SAVE: it appends to the player's unlocked-
---technology list, which the game writes. So a pack-owned id is recorded in core/ledger, and it
---is the ONE kind that can never be undone — UPalCheatManager declares four unlocks and no lock
---(LockTechnology / RemoveTechnology / ResetTechnology / ForgetTechnology are zero hits in
---dumps/cxx/Pal.hpp). The removal report says so in those words rather than implying a reversal.
---@return boolean issued  # the call ran AND a technology row of that name exists; NOT "unlocked"
function Handle:unlock()
    -- `resolve(x) or x`: a DataTable row FName is the resolved form, and an id that cannot
    -- resolve still asks the game about the literal rather than about nothing. Class:iconOf
    -- spells it the same way; the two used to disagree, with iconOf passing the id raw.
    -- The ledger row is written by utils.items.unlockTech itself, at the engine boundary, NOT
    -- here — the same move as Item.Handle:give. That function is published as part of
    -- `PalForge.utils.items`, so hooking its one api caller left every other route unrecorded.
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
---scan does it). Returns how many actually attached: the count is Class:render()'s own
---return value, so a backend that declined (no mesh, unresolved asset, a kind whose
---backend is a stub) is NOT counted. 0 with live instances means nothing attached.
---@return integer
function Handle:render()
    local n = 0
    for _, inst in ipairs(self:instances()) do
        local ok, attached = pcall(function() return inst:render() end)
        if ok and attached then n = n + 1 end
    end
    return n
end

---Re-tint every live structure of this building from its currentColor(). Returns how many
---were actually re-tinted (Class:update()'s return value — an instance with no colour or
---no live material instance is not counted).
---@return integer
function Handle:update()
    local n = 0
    for _, inst in ipairs(self:instances()) do
        local ok, tinted = pcall(function() return inst:update() end)
        if ok and tinted then n = n + 1 end
    end
    return n
end

-- ---- lifecycle events (fired by core.event on the live INSTANCE; forward for manual use).
-- These forwarders call the hook on the definition CLASS, so `self` inside the handler has
-- no .actor / .state / :save(). That is exactly what the real dispatch does for onBuild and
-- ONLY for onBuild; for the other seven it is a test harness, not the real event. ----

---@param ctx table  # ctx.buildId, ctx.model (the UPalMapObjectModel)
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

---@return Building.Spec.Mesh?
function Handle:mesh() return self._cls.meshSpec end
---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end
---@return number?
function Handle:gridCm() return self._cls.gridCm end

Building.Class = Class   -- the base hook table (core/event uses it for override detection)
return Building
