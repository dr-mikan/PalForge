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
--     onSpawned  <- PalCharacter:BroadcastOnCompleteInitializeParameter (ctx.actor).
--                   The FUNCTION is confirmed to exist — dumps/reflection/02_reflection.txt
--                   lists it on /Script/Pal.PalCharacter next to Bind/UnbindOnComplete-
--                   InitializeParameterDelegate and the OnCompleteInitializeParameter-
--                   DelegateMap property — so the hook path is real and registerable. What
--                   is still UNCONFIRMED is that it FIRES for a fresh post-load spawn:
--                   06_events carries no line for it, but the probe mod that wrote that log
--                   had dropped it from its arming list (dumps/palsmith-dump-mod/Scripts/
--                   main.lua says so in as many words, after a run of it froze the UE4SS
--                   callback layer during the world-load storm) — so the absence proves
--                   nothing. It stays ARMED LATE for that same reason: core/event registers
--                   it on world.ready, never at mod load, so the load-storm firing cannot
--                   wedge the shared hook dispatch and take the three confirmed hooks down
--                   with it. Late arming protects them; it does not make the hook proven.
--                   It is still unshown that it signals a FRESH spawn rather than a re-init,
--                   so keep the handler idempotent.
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
--       -- a real, dump-confirmed skeletal path (dumps/reflection/05_assets.txt):
--       mesh        = Mesh{ id = "newpal:body",
--                           model = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal" },
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
    { "texture",  type = "string", doc = "absolute path to a png applied to the mesh" },
    { "params",   type = "table",  doc = "extra material parameters passed through" },
    { "material", type = "string", doc = "base material asset path to instance from" },
})

---The lifecycle handlers a pal can respond to. All optional. Each receives THIS pal's
---handle as its first argument and an event context `ctx` (ctx.actor = the pawn in the
---world). An event this list does not name is a hard error, not a silent no-op.
local Events = schema.define("Pal.Spec.Events", {
    -- TODO(pal-spawned-hook): NARROWED again, 2026-07-26, this time by dumps/cxx/Pal.hpp —
    -- and the remaining doubt has MOVED, which is the useful part. What is now settled:
    --   (a) the SHAPE. `void BroadcastOnCompleteInitializeParameter()` is declared on
    --       APalCharacter with ZERO parameters (Pal.hpp:9087), so `self` is the character and
    --       there is nothing else the hook could hand a handler. Also reflected in the live
    --       build (02_reflection.txt:874), so the path is not a guess on either source.
    --   (b) that a pal born AFTER world load really does broadcast. The map it broadcasts,
    --       OnCompleteInitializeParameterDelegateMap (:9016), is keyed by
    --       EPalCharacterCompleteDelegatePriority — and the game's own spawn entry point,
    --       UPalCharacterManager::SpawnNewCharacterWithInitializeParameterCallback
    --       (Pal.hpp:15538), takes a priority of that same enum for its
    --       InitializeParameterCallback. "Tell me when this NEW character has initialised" IS
    --       a subscription to this broadcast, so the broadcast happens on a fresh spawn.
    --   (c) the three sibling hooks beside this one — SetIsCapturedProcessing,
    --       OnDamageReaction, OnDeadCharacter — are all recorded FIRING in a live session
    --       (06_events.txt), so the machinery around it works.
    -- WHAT IS LEFT is no longer "does the game run it" but "can RegisterHook SEE it".
    -- BroadcastOnCompleteInitializeParameter is the broadcaster, not a delegate target: a
    -- plain C++ call site never enters ProcessEvent, and a hook armed on it would then sit
    -- there silently forever — which is a complete, boring explanation for the one recorded
    -- arming counting 0. Every hook in this tree that is PROVEN to fire is an RPC, a
    -- BlueprintCallable static, or a dynamic-delegate target; this is none of the three.
    -- Handlers stay idempotent until one post-load arming logs one line.
    -- HOW TO GET THAT LINE (unchanged, and the timing is the whole lesson): press F8, then
    -- release a pal from the box or call Pal.get("ChickenPal"):spawn(coord) — and WATCH FOR AT
    -- LEAST TEN SECONDS, because the pal arrives ~6 s after the call. A hook log that is empty
    -- at 1.2 s says nothing about the hook. If it stays at 0, the replacement is a delegate
    -- TARGET rather than the broadcaster: APalPlayerCharacter::OnCompleteInitializeParameter
    -- (APalCharacter* InCharacter) at Pal.hpp:10637 is one such bound handler, and it takes
    -- the new character as its parameter rather than as self.
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
    -- Registration is what makes the definition reachable: core/event resolves a spawned
    -- pawn to THIS class through it, and Pal.get hands it back. om.register never throws
    -- (it answers nil + reason) and neither argument can be wrong here — "pal" is a declared
    -- type and the spec guarantees a non-empty id — so a refusal means the registry itself
    -- moved under us. Say so: an unregistered definition is a pal whose every event is
    -- silently dead, and that must not be invisible.
    local called, okReg, regErr = pcall(om.register, "pal", spec.id, cls)
    if not called then okReg, regErr = nil, okReg end   -- it raised: the message is arg 2
    if not okReg then
        log.err(string.format("Pal '%s' could NOT be registered (%s) — it will receive no "
            .. "lifecycle events and Pal.get will not find it", tostring(spec.id), tostring(regErr)))
    end
    return handle
end

-- Calling the module IS defining:  Pal{ id = "NewPal", ... }
setmetatable(Pal, { __call = function(_, spec) return define(spec) end })

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
---re-stacking). Pals get no tracked instance, so the caller supplies the actor — typically
---`ctx.actor` inside onSpawned, or inside onTick if the sweep is how you find your pawns.
---Fail-soft false when there is no mesh or no valid actor.
---NOTE: the material fields (color / texture / params / material) are lowered into the
---mesh spec and every backend now runs them through core.mesh's dynamic-material layer,
---the default skeletal one included. That layer writes a list of CANDIDATE parameter
---names, because no dump records what a Palworld material actually calls its tint — so a
---true return means the mesh was swapped and the material write ran, not that the pawn
---visibly changed colour (the mesh-material-params marker in core/mesh/base/renderer.lua).
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
---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end

Pal.Class = Class   -- the base hook table (core/event's pal sweep compares onTick against
                    -- it for override detection; also the base for subclassing)
return Pal
