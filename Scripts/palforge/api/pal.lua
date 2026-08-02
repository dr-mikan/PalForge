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
--                   (ctx.actor = the pal, ctx.comp = its parameter component). OBSERVED
--                   FIRING: dumps/reflection/06_events.txt logs it as [PAL.capture.set]
--                   with self = the pal's CharacterParameterComponent, and with BOTH a1=true
--                   and a1=false in one session — which is why the source filters on true.
--     onDamaged  <- PalCharacter:OnDamageReaction        (ctx.actor). OBSERVED FIRING
--                   ([PAL.damage], 9 times, on both BP_ChickenPal_C and BP_Player_Female_C).
--     onDeath    <- PalCharacter:OnDeadCharacter         (ctx.actor). OBSERVED FIRING
--                   ([PAL.dead], on BP_ChickenPal_C).
--     onSpawned  <- PalNPC:OnCompletedInitParam and PalPlayerCharacter:OnCompleteInitialize-
--                   Parameter (ctx.actor) — the bound TARGETS of the initialise broadcast.
--                   OBSERVED FIRING, 2026-07-26, which is what closed pal-spawned-hook.
--                   NOT the broadcaster: PalCharacter:BroadcastOnCompleteInitializeParameter
--                   is what this file used to name here, it registered fine, and it is
--                   MEASURED SILENT (core/event.lua:1683-1688). That is the general lesson —
--                   RegisterHook sees what ProcessEvent runs, and a broadcaster is not it.
--                   The sources stay ARMED LATE, on world.ready and never at mod load: the
--                   broadcast fires in the world-load pal-init storm, and a firing there
--                   wedged the SHARED UE4SS hook dispatch once and took the confirmed hooks
--                   down with it (core/event.lua:46-53).
--                   WHAT IS STILL UNKNOWN is narrower than "does it fire": every firing seen
--                   so far landed in the same second as world.ready, so it is unshown that
--                   one means a pal that did not exist a moment ago rather than a re-init.
--                   Keep the handler idempotent — TODO(pal-spawned-fresh) on Pal.Spec.Events.
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
-- ACTIONS. :spawn has TWO routes, because there are two capabilities. A WILD spawn into the
-- world (the plain and coordinate forms) goes through UPalCheatManager:SpawnMonster — core/spawn
-- constructs a cheat manager itself on a dedicated server, where nothing else does. A summon TO
-- THE PLAYER (`toPlayer`) goes through APalPlayerState:RequestSpawnMonsterForPlayer and touches
-- no cheat manager at all.
-- ✅ THE WILD ROUTE WORKS, AND IT IS SLOW. Observed 2026-07-26 in a loaded save: the coordinate
-- form spawned a pal and teleported it onto the requested point off by 0 cm, twice — but ~5.9 s
-- after the call. SpawnMonster is ASYNCHRONOUS, so nothing a :spawn call can return says a pal
-- exists: the boolean means THE NATIVE CALL WAS ISSUED, and the arrival is reported afterwards
-- in the [PalForge.spawn] log by core/spawn's deferred passes. (This module used to say the
-- opposite in bold — "measured DEAD" — because core/spawn checked for the pal in the statement
-- after the call and once more at 1.2 s, and then wrote the miss down as a property of the
-- build. The evidence and the corrected windows are at the top of core/spawn.lua.)
-- STILL UNOBSERVED, and not to be assumed from the above: the PLAIN wild form (no coordinate).
-- It makes the identical call, so it very probably works, but no run has yet watched it long
-- enough to see the pal. The toPlayer route is unwatched for a different reason: its function
-- is the one spawn name this tree has confirmed on the installed binary, but a party/box summon
-- puts nothing in the world to count, so there is nothing to watch with. The id reaches
-- core/spawn exactly as it was declared and is resolved there ("pack:Boss" -> the row spelling
-- "pack_Boss"), so a namespaced pal takes the same route as a literal one. Note that defining
-- gives an EXISTING CharacterID behaviour — Lua cannot add a brand-new creature row (that is
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
--       -- A DECLARED MESH RENDERS ITSELF: nothing below calls renderOn, and the pawn still
--       -- wears this the moment it spawns. See the note in define().
--       mesh        = Mesh{ id = "newpal:body",
--                           model     = Mesh.assets.SK.PinkCat,
--                           animClass = Mesh.assets.ABP.PinkCat },
--       events      = {
--           onSpawned = function(pal, ctx)
--               Audio.get("AKE_BGM_Title"):play()   -- get, not define: a handler runs often
--           end,
--       },
--   }
--   pal:spawn(Player.coordinate())
--
-- Mesh.assets is the catalog of /Game/... paths measured off this build (core/mesh/assets.lua);
-- an inline `mesh = { model = "/Game/..." }` is the same thing without naming it.

local om      = require("palforge.core.object_manager")
local spawn   = require("palforge.core.spawn")
local mesh    = require("palforge.core.mesh")
local icons   = require("palforge.core.icons")
local schema  = require("palforge.core.schema")
local character = require("palforge.core.character")
local log     = require("palforge.utils.log").scope("pal")

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
    -- TWO ACCEPTED SHAPES, not one. Renderer.resolveTexture (core/mesh/base/renderer.lua:488)
    -- branches on assets.isObjectPath: a "/Game/..." reference is LOADED as an existing
    -- UTexture2D, anything else is handed to ImportFileAsTexture2D as a file on disk. The asset
    -- route is the stronger of the two by evidence — StaticFindObject and LoadAsset run every
    -- session; the import route has a correct signature and no observation behind it.
    -- ⚠️ ABSOLUTE, on this field. Mesh.Spec runs `model` and `texture` through
    -- file.resolvePackPath inside its own Spec:validate (api/mesh.lua:175-176); Pal.Spec has no
    -- custom validate, so a relative path declared HERE reaches the renderer verbatim and is
    -- looked for relative to the game's working directory. Name a "/Game/..." asset, or give an
    -- absolute file path, or declare the mesh as a named Mesh{ ... } and reference that.
    { "texture",  type = "string",
      doc = "a \"/Game/...\" UTexture2D to load, or an ABSOLUTE path to a png to import; "
          .. "not pack-relative — only Mesh.Spec resolves those" },
    { "params",   type = "table",  doc = "extra material parameters passed through" },
    { "material", type = "string", doc = "base material asset path to instance from" },
})

---The lifecycle handlers a pal can respond to. All optional. Each receives THIS pal's
---handle as its first argument and an event context `ctx` (ctx.actor = the pawn in the
---world). An event this list does not name is a hard error, not a silent no-op.
local Events = schema.define("Pal.Spec.Events", {
    -- onSpawned FIRES, observed 2026-07-26. The working sources are the bound TARGETS of the
    -- initialise broadcast — PalNPC:OnCompletedInitParam for a pal, and
    -- PalPlayerCharacter:OnCompleteInitializeParameter — not the broadcaster itself, which was
    -- hooked first, registered fine and never carried anything. That is the general lesson:
    -- RegisterHook sees what ProcessEvent runs, and a broadcaster is not it.
    --
    -- TODO(pal-spawned-fresh): unknown whether it fires for a pal that is genuinely NEW. Every
    -- firing observed so far landed in the same second as world.ready, i.e. the load storm, when
    -- every pal in range initialises at once. That proves the hook works and says nothing about
    -- the case a pack actually cares about — a pal that did not exist a moment ago. The two look
    -- identical from here because only the FIRST firing per channel is announced.
    -- To settle it: release a pal from the box well after the world has loaded, or let a wild one
    -- stream in while travelling, and watch for a pal.spawned line whose timestamp is nowhere
    -- near world.ready.
    --
    -- WHAT A PACK CAN RELY ON TODAY, since the marker above is about the one thing it cannot:
    -- the channel FIRES, with ctx.actor being a live pawn of this pal's id, at least once per
    -- pawn, and it is the earliest moment that pawn's .Mesh component is real — which is why a
    -- declared `mesh` is attached on exactly this channel (see define()). Write the handler so
    -- that being called twice for one pawn is harmless, and it is correct under either answer
    -- to the question above. What it must NOT be used for is counting how many pals appeared.
    { "onSpawned",  type = "function", sig = "fun(self: Pal.Handle, ctx: table)",
                    doc = "LIVE - a pal finished initialising (ctx.actor); may repeat per pawn, keep it idempotent" },
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
-- `id` carries schema.validId, not schema.nonEmpty: the spawn route and the icon table both
-- want the resolved row spelling ("pack:Boss" -> "pack_Boss"), so an id that cannot resolve —
-- "my-pack:Boss", a hyphen — is refused at define time instead of registering and being
-- silently inert. The rule is written once, in core/schema.lua.
local Spec = schema.define("Pal.Spec", {
    { "id",          type = "string", required = true, check = schema.validId,
                     doc = "pal id: a game CharacterID (\"ChickenPal\") or \"pack:name\"" },
    { "name",        type = "string", doc = "shown in UI (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "skills",      type = "table", arrayOf = "string", doc = "skill ids this pal owns (see Skill)" },
    { "mesh",        type = "table", of = Mesh,
                     doc = "the mesh worn by a spawned pawn (inline, or a Mesh{ ... } handle); attached automatically on pal.spawned" },
    { "material",    type = "table", of = Material, doc = "material override applied to that mesh" },
    { "color",       type = "table",  doc = "base tint { r, g, b, a } (shorthand for material.color)" },
    { "texture",     type = "string", doc = "png path applied to the mesh (shorthand for material.texture)" },
    -- ONE KIND OF THING, declared — the same decision as Item.Spec.icon and Skill.Spec.icon.
    -- core/icons answers a /Game/... asset PATH as a plain string (the icon column is read as
    -- text; the TSoftObjectPtr in the row answers none of the nineteen member names a soft
    -- pointer could expose, so it cannot be unwrapped from Lua at all), so the declared
    -- fallback is a string path too and :iconOf answers string|nil, always. Before this, the
    -- field carried no `type =` and the accessor could hand back a string path or whatever the
    -- author declared, which is a union every caller had to branch on.
    { "icon",        type = "string",
                     doc = "/Game/... texture path used when the icon DataTable has no row for this id" },
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

-- The declared skill ids, verbatim — what the AUTHOR wrote, not what any live pal carries.
-- The two are different questions and both are answerable now: Pal.Handle:teachAll(actor)
-- writes this list onto a live character, and Skill.Handle:skillsOn(actor) reads back what
-- that character actually has. See core/character.lua for the route and its evidence.
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
-- The icon table read WORKS as of 2026-07-26: core/icons read DT_PalCharacterIconDataTable in a
-- live save and 674 of 674 rows carry an icon. So a vanilla pal id resolves to the game's own
-- artwork here, and the declared `icon` really is the fallback it was always described as.
-- THE ID IS RESOLVED FIRST (F-3/C5). The row PalSchema writes for "pack:Boss" is spelled
-- "pack_Boss", so handing icons.resolve the raw namespaced id could never hit the live table —
-- every namespaced pal fell back to its declared icon and looked like an unmeasured capability
-- rather than a call that was never made. `or self.id` is the boundary rule: an id that will
-- not resolve falls back to the LITERAL, never to nothing.
-- Note the case trap this does NOT fix, because it is a different one and the catalogs record
-- it honestly: the same creature is spelled two ways on this build — SheepBall is the blueprint
-- id dispatch keys on, Sheepball is the DataTable row this lookup answers to — and the match
-- here is case-SENSITIVE (core/icons.lua:40-42).
function Class:iconOf()
    local id = om.resolve(self.id) or self.id
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.pal, id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — the module surface: Pal{ ... } / Pal.get / Pal.get_all
--=============================================================================

---The pal domain. CALL it to define a pal; the two named functions look existing ones up.
---@class palforge.pal
---@overload fun(spec: Pal.Spec, opts: table?): Pal.Handle
local Pal = {}

local wrap  -- forward decl; the Pal.Handle wrapper is defined in the BOTTOM section

---Define a NEW pal and register it. Returns a handle you can chain :spawn on.
---`spec` is validated against Pal.Spec: `id` is required, unknown fields are an error.
---
---`opts` is optional and omitting it behaves exactly as it always has:
---  { register = false }   build and return the handle, register NOTHING — what a native
---                         catalog uses so that READING native.pals.ChickenPal stops writing
---                         to the registry. A definition that is not registered receives no
---                         lifecycle events, which is the point: it is a value, not content.
---  { pack = "mypack" }    register attributed to that pack, which is what gives a collision
---                         a "who". PalForge.pack("mypack").Pal is the same thing without
---                         passing it per call.
---@param spec Pal.Spec
---@param opts table?
---@return Pal.Handle
local function define(spec, opts)
    local register, pack = schema.defineOpts(opts, "Pal")
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
    -- A DECLARED MESH RENDERS ITSELF. Until now `mesh = { model = ... }` stored a string and
    -- nothing else: renderOn existed, and every pal that wanted to be seen had to write
    -- `events = { onSpawned = function(pal, ctx) pal:renderOn(ctx.actor) end }` by hand. That
    -- is boilerplate for the one thing declaring a mesh can possibly have meant, so declaring
    -- it is now the whole of it — which is what makes `Pal{ id = "pack:Boss", mesh = { model =
    -- Mesh.assets.SK.PinkCat } }` a complete, working definition.
    --
    -- ON SPAWN, not on the tick sweep. pal.spawned is the moment a pawn has finished its
    -- parameter init (core/event.lua's three-source dedupe), which is the earliest point at
    -- which its .Mesh component is real. The tick sweep would also reach the pawn, once every
    -- PAL_SCAN_MS forever, and paying that for a mesh that only ever needs setting once is the
    -- wrong trade — so this is on the one channel that fires once per pawn and nowhere else.
    --
    -- THE BUILDING SIDE, stated carefully because this comment used to overclaim it. It said
    -- buildings "needed no equivalent — core/event.lua already defers inst:render(), so
    -- Building{ mesh = ... } has always drawn itself". The deferred render call is real and is
    -- still there; what was never true is the "has always drawn itself" that was inferred from
    -- it. The 2026-08-01 asset audit (A-1/A-2) found the mesh layer keying its per-actor
    -- records on a UE4SS handle, and a handle is minted fresh per lookup — so the attach could
    -- not find, guard or undo anything it had stored, and a declared building mesh probably
    -- never reached the structure at all. What is guaranteed once that keying is fixed (uobject.key,
    -- owned by the mesh/event work) is this and no more: a placed structure gets ONE deferred
    -- inst:render() call, at the moment its actor is tracked. Whether the pack SEES a mesh
    -- after that is a fact about core.mesh, not about this module, and nobody has watched one
    -- appear on a building yet. The pal side above is the same shape and carries the same
    -- caveat: the attach is issued on the one channel that fires per pawn.
    --
    -- The author's own onSpawned still runs, and runs AFTER: a handler that wants to move,
    -- rename or re-tint the pawn should find the mesh already on it. mesh.attachOnce guards
    -- against re-stacking, so a second spawn event for one pawn costs nothing, and the whole
    -- thing is pcall'd — a mesh that will not resolve must never cost a pal its lifecycle.
    if type(spec.mesh) == "table" and spec.mesh.model then
        local declared = cls.onSpawned   -- the author's forwarder, or Class's inert default
        cls.onSpawned = function(self, ctx, ...)
            pcall(function() handle:renderOn(ctx and ctx.actor) end)
            return declared(self, ctx, ...)
        end
    end
    -- Registration is what makes the definition reachable: core/event resolves a spawned
    -- pawn to THIS class through it, and Pal.get hands it back. om.register never throws
    -- (it answers nil + reason) and neither argument can be wrong here — "pal" is a declared
    -- type and the spec guarantees a non-empty id — so a refusal means the registry itself
    -- moved under us. Say so: an unregistered definition is a pal whose every event is
    -- silently dead, and that must not be invisible.
    -- opts.register == false skips the whole paragraph deliberately and silently: the caller
    -- asked for a definition that is not content, so "it will receive no lifecycle events" is
    -- the requested outcome rather than the failure the log line describes.
    if register then
        local called, okReg, regErr = pcall(om.register, "pal", spec.id, cls, { pack = pack })
        if not called then okReg, regErr = nil, okReg end   -- it raised: the message is arg 2
        if not okReg then
            log.err(string.format("Pal '%s' could NOT be registered (%s) — it will receive no "
                .. "lifecycle events and Pal.get will not find it", tostring(spec.id), tostring(regErr)))
        end
    end
    return handle
end

-- Calling the module IS defining:  Pal{ id = "NewPal", ... }
setmetatable(Pal, { __call = function(_, spec, opts) return define(spec, opts) end })

---Get an EXISTING pal by id: a previously-defined one, else a thin definition over any
---game CharacterID (so a native / other-mod id takes the same routes as a defined one).
---Never nil.
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
---`true` MEANS THE NATIVE CALL WAS ISSUED — core.signature matched the live declaration and the
---call ran without raising — and nothing more. It is not a promise that a pal exists yet, and
---on the coordinate form it is not a promise that one is at `at`. `false` means the call was
---refused or raised, or that nothing was attempted at all (no cheat manager, no player state,
---bad args).
---
---⚠️ SPAWNING IS ASYNCHRONOUS: THE PAL ARRIVES SECONDS LATER (~5.9 s when it was measured, on
---2026-07-26). No synchronous return can describe that, which is why this one does not try.
---Where the truth is: the [PalForge.spawn] log. The coordinate form's deferred pass prints
---"placed new pal at (...); it reads back (...), off by N" — that same run recorded off by 0,
---twice, so the coordinate route is measured EXACT. The plain wild form prints an arrival line
---of its own, and the `toPlayer` form prints none at all because nothing here can enumerate a
---party/box.
---
---If your pack has to REACT to the pal, do not gate on this boolean and do not poll for one
---frame: use the onSpawned handler, or look for the pawn yourself over a window of ten seconds
---or more.
---@param arg Coord|table|nil
---@return boolean issued   # the native call was issued (see above), NOT arrival, NOT `at`
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
---re-stacking).
---
---YOU DO NOT NORMALLY CALL THIS. A definition that declares a `mesh` attaches it itself on
---pal.spawned (see define()), so this is the manual route for a pawn PalForge did not spawn,
---for a pawn found through the onTick sweep, and for re-applying after a detach.
---Fail-soft false when there is no mesh or no valid actor.
---NOTE: the material fields (color / texture / params / material) are lowered into the
---mesh spec and every backend now runs them through core.mesh's dynamic-material layer,
---the default skeletal one included. That layer writes a list of CANDIDATE parameter
---names, because no dump records what a Palworld material actually calls its tint — so a
---true return means the mesh was swapped and the material write ran, not that the pawn
---visibly changed colour (the mesh-material-params marker in core/mesh/base/renderer.lua).
---A COLOUR HAS NEVER BEEN WATCHED CHANGING. mesh-material-params closed on the measured
---parameter NAMES, which is a different claim, and nothing in this tree has ever reported
---seeing a pawn's tint move. That is a measurement only the running game can make, so it
---belongs in a named hook — test/hooks/mesh-color-change: find or spawn one pawn, renderOn it
---with an unmistakable colour, and record in the log whether a human saw it change. Until that
---hook exists and has been run, read every `true` from this function as "the write ran".
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
    -- The pal-level material block / shorthands override whatever the mesh declared, so a
    -- shared Mesh{ ... } can be re-tinted per pal. core.mesh's renderer base applies these
    -- on every backend (skeletal included).
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

---Put every skill this pal DECLARES onto a live character, so the game itself carries them.
---
---`skillsOf()` is what the author wrote; this is how that list reaches a real pal standing in
---the world. Each id routes on what the game knows it as — one of its 309 active skills, or a
---passive skill by name — and each write is verified by reading the character back.
---
---Returns how many landed and how many were asked for, so a partial result is visible instead
---of being flattened into a boolean: `taught, asked = pal:teachAll(actor)`. Both zero means
---nothing was declared. Skills are applied in declared order and a failure does not stop the
---rest — one unknown id should not cost a pal its other four moves.
---@param actor any        # a live pal or player character
---@return integer taught, integer asked
function Handle:teachAll(actor)
    local ids, taught = self._cls.skills or {}, 0
    for _, id in ipairs(ids) do
        if character.addSkill(actor, id) then taught = taught + 1 end
    end
    return taught, #ids
end
---@return table?
function Handle:mesh() return self._cls.meshSpec end
---The paldeck icon as a /Game/... asset path: the live DataTable's row for this id (674 of
---674 rows carry one), else the declared `icon`, else nil. One kind of value, never an engine
---object — see the Pal.Spec `icon` note.
---@return string?
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end

Pal.Class = Class   -- the base hook table (core/event's pal sweep compares onTick against
                    -- it for override detection; also the base for subclassing)
return Pal
