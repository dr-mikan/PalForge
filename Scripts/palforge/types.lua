-- PalForge type definitions — GENERATED, do not edit.
--
-- Regenerate with:  lua5.4 tools/gen-types.lua
-- Source of truth:  the schema declarations in Scripts/palforge/api/*.lua
--
-- Annotations only: nothing requires this file at runtime. It exists so an editor
-- (LuaLS / lua-language-server) can complete the fields of every X{ ... } call,
-- show each field's meaning, and jump from a spec name to its field list.
--
-- Every domain has the same shape — the module itself is the constructor:
--   X{ id = ..., name = ..., description = ..., events = { onFoo = fn } } -> X.Handle
--   X.get(id) -> X.Handle        X.get_all() -> X.Handle[]
---@meta

--=============================================================================
-- Mesh
--=============================================================================

---@alias Mesh.Spec.Kind "procedural"|"static"|"skeletal"|"obj"
---@class Mesh.Spec
---@field id? string # mesh id, e.g. "pack:name" (required when defined directly; omit when inline)
---@field kind? Mesh.Spec.Kind # which core.mesh backend renders it (default skeletal)
---@field model string # USkeletalMesh / UStaticMesh asset path
---@field animClass? string # ABP_*_C animation blueprint path (skeletal only)
---@field scale? number # uniform scale applied to the attached mesh
---@field offset? table # { x, y, z } offset from the pawn's origin
---@field texture? string # absolute path to a png applied to the mesh
---@field color? table # tint { r, g, b, a } in 0..1
---@field material? string # base material asset path to instance from
---@field params? table # extra material parameters passed through

--=============================================================================
-- Pal
--=============================================================================

---@class Pal.Spec.Material
---@field color? table # tint { r, g, b, a } in 0..1
---@field texture? string # absolute path to a png applied to the mesh
---@field params? table # extra material parameters passed through
---@field material? string # base material asset path to instance from

---@class Pal.Spec.Events
---@field onSpawned? fun(self: Pal.Handle, ctx: table) # LIVE (UNCONFIRMED candidate, armed only after the world loads) - finished spawning into the world
---@field onDamaged? fun(self: Pal.Handle, ctx: table) # LIVE - took damage
---@field onDeath? fun(self: Pal.Handle, ctx: table) # LIVE - HP reached zero
---@field onCaptured? fun(self: Pal.Handle, ctx: table) # LIVE - caught in a sphere
---@field onTick? fun(self: Pal.Handle, ctx: table) # LIVE - core/event's pal sweep, once per live pawn every core.event.PAL_SCAN_MS (default 3 s)

---@class Pal.Spec
---@field id string # pal id: a game CharacterID ("ChickenPal") or "pack:name"
---@field name? string # shown in UI (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field skills? string[] # skill ids this pal owns (see Skill)
---@field mesh? Mesh.Spec|Mesh.Handle # the mesh attached to a spawned pawn (inline, or a Mesh{ ... } handle)
---@field material? Pal.Spec.Material # material override applied to that mesh
---@field color? table # base tint { r, g, b, a } (shorthand for material.color)
---@field texture? string # png path applied to the mesh (shorthand for material.texture)
---@field icon? any # fallback icon used when the DataTable lookup misses
---@field events? Pal.Spec.Events # lifecycle handlers (grouped)
---@field data? table # free-form payload of your own, carried onto the definition

--=============================================================================
-- Item
--=============================================================================

---@class Item.Spec.Recipe
---@field materials table<string, number> # { <itemId> = <count> } consumed by one craft
---@field count? number # how many of this item one craft yields (default 1)
---@field work? number # work amount the station must put in
---@field station? string # workbench / station id that can craft it

---@class Item.Spec.Events
---@field onObtain? fun(self: Item.Handle, ctx: table) # LIVE - entered the inventory (ctx.count)
---@field onUse? fun(self: Item.Handle, ctx: table) # LIVE - used / consumed (ctx.actor)
---@field onCraft? fun(self: Item.Handle, ctx: table) # declarable; no native source exists yet
---@field onDiscard? fun(self: Item.Handle, ctx: table) # declarable; no native source exists yet

---@alias Item.Spec.Category "material"|"consumable"|"equipment"|"ammo"|"ingredient"|"other"
---@class Item.Spec
---@field id string # item id: a game ItemId ("Wood") or "pack:name"
---@field name? string # shown in UI (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field category? Item.Spec.Category # what kind of inventory content this is (default material)
---@field maxStack? number # inventory stack ceiling (default 1)
---@field icon? any # fallback icon used when the DataTable lookup misses
---@field recipe? Item.Spec.Recipe # the recipe that produces THIS item
---@field events? Item.Spec.Events # lifecycle handlers (grouped)
---@field data? table # free-form payload of your own, carried onto the definition

--=============================================================================
-- Building
--=============================================================================

---@alias Building.Spec.Mesh.Kind "procedural"|"static"|"skeletal"|"obj"
---@class Building.Spec.Mesh
---@field id? string # mesh id, e.g. "pack:name" (required when defined directly; omit when inline)
---@field kind? Building.Spec.Mesh.Kind # which core.mesh backend renders it (default static)
---@field model string # UStaticMesh asset path, or an OBJ path for the procedural backend
---@field animClass? string # ABP_*_C animation blueprint path (skeletal only)
---@field scale? number # uniform scale applied to the attached mesh
---@field offset? table # { x, y, z } offset from the actor's origin
---@field texture? string # absolute path to a png applied to the mesh
---@field color? table # tint { r, g, b, a } in 0..1
---@field material? string # base material asset path to instance from
---@field params? table # extra material parameters passed through

---@class Building.Spec.Material
---@field color? table # tint { r, g, b, a } in 0..1
---@field texture? string # absolute path to a png applied to the mesh
---@field params? table # extra material parameters passed through
---@field material? string # base material asset path to instance from

---@class Building.Spec.Events
---@field onPlace? fun(self: Building.Instance, ctx: table) # LIVE - committed into the world
---@field onLoad? fun(self: Building.Instance, ctx: table) # LIVE - tracked / restored from a save
---@field onRightClick? fun(self: Building.Instance, ctx: table) # LIVE - primary interaction
---@field onRemove? fun(self: Building.Instance, ctx: table) # LIVE - the structure vanished
---@field onTick? fun(self: Building.Instance, ctx: table) # LIVE - heartbeat (see tickInterval)
---@field onWorldReady? fun(self: Building.Instance, ctx: table) # LIVE - world loaded; emitted after the first scan, so only structures already tracked get it
---@field onWorldLeft? fun(self: Building.Instance, ctx: table) # LIVE - the world was unloaded (emitted while instances are still live)
---@field onBuild? fun(self: Building.Definition, ctx: table) # LIVE - build completed; nothing is placed yet, so `self` is the DEFINITION (ctx.buildId, ctx.model)
---@field onLeftClick? fun(self: Building.Instance, ctx: table) # declarable; no native source exists yet
---@field onBreak? fun(self: Building.Instance, ctx: table) # declarable; no native source exists yet

---@class Building.Spec
---@field id string # build id: a game BuildObjectId ("PalBoxV2") or "pack:name"
---@field name? string # shown in UI (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field gridCm? number # placement grid quantum in cm (default core.spatial.GRID_CM)
---@field buildIds? string[] # the game build ids this definition claims; REPLACES the default { id }
---@field tickInterval? number # run onTick every N heartbeats (default 1)
---@field mesh? Building.Spec.Mesh|Mesh.Handle # the mesh attached to the placed actor (inline, or a Mesh{ ... } handle)
---@field material? Building.Spec.Material # material override applied to that mesh
---@field color? table # base tint { r, g, b, a } (shorthand for material.color)
---@field texture? string # png path applied to the mesh (shorthand for material.texture)
---@field icon? any # fallback icon used when the DataTable lookup misses
---@field state? table|fun(): table # default persisted state for a new instance (a table, or a factory returning one)
---@field events? Building.Spec.Events # lifecycle handlers (grouped)
---@field data? table # free-form payload of your own, carried onto the definition

--=============================================================================
-- Skill
--=============================================================================

---@class Skill.Spec.Events
---@field onActivate? fun(self: Skill.Handle, owner: any, ctx: table) # an active skill fired (self, owner, ctx)
---@field onHit? fun(self: Skill.Handle, target: any, ctx: table) # one of its hits landed (self, target, ctx)
---@field onEquip? fun(self: Skill.Handle, owner: any, ctx: table) # a passive was attached (self, owner, ctx)
---@field onUnequip? fun(self: Skill.Handle, owner: any, ctx: table) # a passive was removed (self, owner, ctx)

---@alias Skill.Spec.Kind "active"|"passive"
---@class Skill.Spec
---@field id string # skill id: a game row id or "pack:name"
---@field name? string # shown in skill lists (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field kind? Skill.Spec.Kind # an active skill is fired; a passive one is equipped (default active)
---@field element? string # attribute / element (fire, water, ...)
---@field cooldown? number # seconds between activations (enforced by :activate)
---@field power? number # base power / magnitude
---@field icon? any # fallback icon used when the DataTable lookup misses
---@field events? Skill.Spec.Events # behaviour handlers (grouped)
---@field data? table # free-form payload of your own, carried onto the definition

--=============================================================================
-- Effect
--=============================================================================

---@class Effect.Spec.Events
---@field onApply? fun(self: Effect.Handle, target: any, ctx: table) # LIVE - applied to a target
---@field onTick? fun(self: Effect.Handle, target: any, ctx: table) # LIVE - every `interval` seconds while active
---@field onStack? fun(self: Effect.Handle, target: any, ctx: table) # LIVE - re-applied to a target that already has it
---@field onExpire? fun(self: Effect.Handle, target: any, ctx: table) # LIVE - duration elapsed, removed, or target gone

---@class Effect.Spec
---@field id string # effect id: a name or "pack:name"
---@field name? string # shown on the status bar (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field duration? number # total lifetime in seconds (omit = until :remove())
---@field interval? number # seconds between onTick calls (omit = no periodic tick)
---@field stackable? boolean # may several copies coexist on one target? (default false)
---@field maxStacks? number # stack ceiling when stackable (default 1)
---@field icon? any # status-bar icon
---@field nativeStatus? string # the game's own EPalStatusEffectType this mirrors, when it has one
---@field events? Effect.Spec.Events # lifecycle handlers (grouped)
---@field data? table # free-form payload of your own, carried onto the definition

--=============================================================================
-- Audio
--=============================================================================

---@alias Audio.Spec.Kind "se"|"bgm"
---@class Audio.Spec
---@field id string # audio id: the AkAudioEvent name, or "pack:name"
---@field name? string # human label (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field kind? Audio.Spec.Kind # descriptive only - the native play route is the same for both (default se)
---@field soundId? string # native AkAudioEvent name (the SoundID fallback route)
---@field soundPath? string # native AkAudioEvent asset path (the route that actually plays)
---@field soundFile? string # custom audio file path (seam - not playable yet)
---@field source? fun(self: Audio.Handle): table|nil # override that returns the core.sound spec yourself
---@field data? table # free-form payload of your own, carried onto the definition

--=============================================================================
-- UI
--=============================================================================

---@class UI.Spec
---@field id string # element id, e.g. "pack:Panel"
---@field name? string # human label (defaults to id)
---@field description? string # one-line description, for UI and tooling
---@field render? fun(self: UI.Handle, root: any): boolean? # build the widget tree under `root` (self, root); runs once per mount. Return false if it could not build — the element then stays unmounted
---@field update? fun(self: UI.Handle) # refresh the already-built widgets (self); runs on each :refresh()
---@field destroy? fun(self: UI.Handle) # remove the widgets render() built (self); runs on :unmount()
---@field data? table # default fields shared by every instance of this element

--=============================================================================
-- Common
--=============================================================================

---@class Coord
---@field x number # world X in centimetres
---@field y number # world Y in centimetres
---@field z number # world Z in centimetres
