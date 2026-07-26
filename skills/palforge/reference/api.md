<!-- GENERATED FILE — do not edit by hand.
     Regenerate:  cd <PalForge> && lua5.4 tools/gen-skill-reference.lua .
     Generator:   tools/gen-skill-reference.lua
     Truth:       the schema declarations in Scripts/palforge/api/*.lua, read back
                  through the core/schema registry at runtime. -->

# PalForge API reference

Everything a pack can call, generated from the live schema registry. PalForge is a Lua
modding framework for Palworld running under UE4SS.

```lua
local api = require("palforge.api")   -- also installs the globals below, mod-local
```

Every domain has the SAME three-member shape — **the module IS the constructor**:

```lua
local h = Pal{ id = "NewPal", name = "New Pal",     -- define + register -> Handle
               mesh = Mesh{ id = "np:body", model = "/Game/.../SK_X" },   -- nest a definition
               events = { onDamaged = function(self, ctx) end } }
Pal.get("ChickenPal"):spawn(Player.coordinate())    -- act on one, defined here or not
Pal.get_all()                                       -- every registered definition
```

* `X{ ... }` is Lua's call-with-a-table sugar for `X({ ... })` — the braces are the
  argument list. Every domain needs an `id` (`Mesh` enforces it in the constructor
  rather than in the spec, so only an INLINE `mesh = { … }` may omit one).
* **Define once, act many times.** `X{ ... }` registers; `X.get(id)` just hands you a
  handle. Inside an event handler use `get` — re-defining on every event re-registers.
* A nested definition is passed as itself: `mesh = Mesh{ ... }` and the inline
  `mesh = { model = ... }` validate identically.
* Where a domain declares an `X.Spec.Events` shape, its handlers are grouped under
  `events = { … }`. An event name that shape does not declare is a hard error at define
  time, not a silent no-op.
* Every domain module except `Player` also exposes `X.Class`, the base definition
  class (override detection / subclassing).
* A domain's `X.Spec` shapes are PRIVATE — a domain is a thing you call, not a namespace
  to browse. Read them at runtime with `schema.help("X.Spec")` /
  `schema.get("X.Spec").fields`; this page is generated from exactly those.

**Legend — the `fires` column**, read from each hook's own doc string:

| value | means |
|---|---|
| `LIVE` | a confirmed native source emits it; write the handler and it runs |
| `LIVE?` | wired, but never yet observed firing — keep the handler idempotent |
| `no` | *declarable*: the name is accepted, nothing emits it. Your handler never runs |
| `manual` | the doc string carries neither marker — the domain has no native source at all, so the handler runs only when you call it (that domain's own action methods, or the `:onX()` forwarder) |

The `type` column shows the declared LuaLS signature when a field has one, else its
runtime type. In `rules`, `checked` means a predicate runs on the value (on every `id`:
must be a non-empty string). In `notes`, what follows a `→` is what the RETURN VALUE
means — most of this api is fail-soft, so a `false` is information, not an exception.
`—` is "nothing to say", never "unknown".

## Domains

| domain | define | look up | handle | hooks (live/total) | what it is |
|---|---|---|---|---|---|
| [Pal](#pal) | `Pal{ … }` | `.get(id)` `.get_all()` | 8 methods | 5/5 | A pal is a spawnable creature. |
| [Item](#item) | `Item{ … }` | `.get(id)` `.get_all()` | 9 methods | 2/4 | An item is a piece of inventory content: materials, consumables, equipment, ammo. |
| [Building](#building) | `Building{ … }` | `.get(id)` `.get_all()` | 9 methods | 8/10 | A building is a placeable structure: workbenches, storage, machines, decorations —… |
| [Skill](#skill) | `Skill{ … }` | `.get(id)` `.get_all()` | 14 methods | 0/4 | A skill is what a Pal can do: an active attack or a passive trait. |
| [Effect](#effect) | `Effect{ … }` | `.get(id)` `.get_all()` `.activeOn(target)` | 10 methods | 4/4 | An effect is a status applied to a character (a player or a Pal): buffs, debuffs,… |
| [Audio](#audio) | `Audio{ … }` | `.get(id)` `.get_all()` `.bgm(spec)` `.se(spec)` | 7 methods | — | Audio is one playable sound: background music or a one-shot effect. |
| [Mesh](#mesh) | `Mesh{ … }` | `.get(id)` `.get_all()` | 6 methods | — | A mesh is the VISUAL a definition wears: a model asset plus how to paint it. |
| [UI](#ui) | `UI{ … }` | `.get(id)` `.get_all()` | 10 methods | — | A UI element is something drawn on screen out of Palworld's own native UMG kit. |
| [Player](#player) | — | `.character()` `.coordinate()` `.coordinateOffset(dx, dy, dz)` | — | — | PUBLIC player API. Thin facade over utils/player. |

## Validation — exactly what is rejected, and the message you get

Every definition call is validated against its spec before anything is registered: a
problem is a **hard error** (level 0, so the text below is the whole message) and the
call never half-succeeds. Messages are captured from real failing calls.

| rejected | message |
|---|---|
| the argument is not a table | `PalForge: Pal: expected a table, got number. Fields: id, name, description, skills, mesh, material, color, texture, icon, events, data` |
| a required field is missing | `PalForge: Pal: field "id" is required (pal id: a game CharacterID ("ChickenPal") or "pack:name")` |
| an undeclared field (with a did-you-mean) | `PalForge: Pal: unknown field "nam" (did you mean "name"?). Valid fields: id, name, description, skills, mesh, material, color, texture, icon, events, data` |
| a field has the wrong type | `PalForge: Pal: field "id" expects string, got number` |
| a `check` rejects the value | `PalForge: Pal: field "id" is invalid: must be a non-empty string` |
| a value is outside the declared `values` | `PalForge: Item: field "category" must be one of { "material", "consumable", "equipment", "ammo", "ingredient", "other" }, got "junk"` |
| a bad element in an `arrayOf` | `PalForge: Pal: field "skills[2]" expects string, got number` |
| a bad value in a `mapOf` (inside a nested spec) | `PalForge: Item: field "recipe" (Item.Spec.Recipe): field "materials.Wood" expects number, got string` |
| a nested spec rejects one of its own fields | `PalForge: Pal: field "mesh" (Mesh.Spec): field "kind" must be one of { "procedural", "static", "skeletal", "obj" }, got "voxel"` |
| a non-string key | `PalForge: Pal: keys must be strings, got a number key` |
| a lookup with no id | `Pal.get: id (string) is required` |
| `Mesh.get` on an undefined mesh | `PalForge: Mesh.get("nope"): no mesh is defined under that id` |
| a mesh defined without an id | `PalForge: Mesh: field "id" is required (an unnamed mesh cannot be looked up again - write it inline as mesh = { ... } instead)` |
| `Audio.bgm` / `Audio.se` contradicted | `PalForge: Audio.bgm: kind is fixed to "bgm" here, but got "se" - use Audio{ ... } to set it` |

The context prefix is the call you made (`Pal`, `Item`, …), and a nested spec extends
it — `Pal: field "mesh" (Mesh.Spec): …` — so the message always names the shape to go
and read. Array and map elements extend the field name itself (`skills[2]`,
`materials.Wood`). Validation returns a fresh plain COPY with defaults filled; the table
you passed is never mutated.

## Pal

A pal is a spawnable creature.

| call | returns | notes |
|---|---|---|
| `Pal{ … }` | `Pal.Handle` | Define a NEW pal and register it. |
| `Pal.get(id)` | `Pal.Handle` | Get an EXISTING pal by id: a previously-defined one, else a thin definition over any game CharacterID (so a native / other-mod id takes the same… |
| `Pal.get_all()` | `Pal.Handle[]` | Every PalForge-registered pal, as a list of handles. |

### Pal.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | pal id: a game CharacterID ("ChickenPal") or "pack:name" |
| `name` | `string` | — | shown in UI (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `skills` | `table` | each element `string` | skill ids this pal owns (see Skill) |
| `mesh` | `table` | shape [Mesh.Spec](#meshspec) | the mesh attached to a spawned pawn (inline, or a Mesh{ ... } handle) |
| `material` | `table` | shape [Pal.Spec.Material](#palspecmaterial) | material override applied to that mesh |
| `color` | `table` | — | base tint { r, g, b, a } (shorthand for material.color) |
| `texture` | `string` | — | png path applied to the mesh (shorthand for material.texture) |
| `icon` | `any` | — | fallback icon used when the DataTable lookup misses |
| `events` | `table` | shape [Pal.Spec.Events](#palspecevents) | lifecycle handlers (grouped) |
| `data` | `table` | — | free-form payload of your own, carried onto the definition |

### Pal.Spec.Events

Declared as `events = { onX = function(self, …) end }` inside `Pal{ … }`.

| hook | fires | signature | ctx | meaning |
|---|---|---|---|---|
| `onSpawned` | LIVE? | `fun(self: Pal.Handle, ctx: table)` | ctx.actor = the pawn | LIVE (UNCONFIRMED candidate, armed only after the world loads) - finished spawning into the world |
| `onDamaged` | LIVE | `fun(self: Pal.Handle, ctx: table)` | ctx.actor | LIVE - took damage |
| `onDeath` | LIVE | `fun(self: Pal.Handle, ctx: table)` | ctx.actor | LIVE - HP reached zero |
| `onCaptured` | LIVE | `fun(self: Pal.Handle, ctx: table)` | ctx.actor, ctx.comp = the pal's parameter component | LIVE - caught in a sphere |
| `onTick` | LIVE | `fun(self: Pal.Handle, ctx: table)` | ctx.actor, ctx.count = heartbeat number, ctx.now | LIVE - core/event's pal sweep, once per live pawn every core.event.PAL_SCAN_MS (default 3 s) |

### Pal.Spec.Material

| field | type | rules | meaning |
|---|---|---|---|
| `color` | `table` | — | tint { r, g, b, a } in 0..1 |
| `texture` | `string` | — | absolute path to a png applied to the mesh |
| `params` | `table` | — | extra material parameters passed through |
| `material` | `string` | — | base material asset path to instance from |

### Pal.Handle

| method | returns | notes |
|---|---|---|
| `:description()` | `string?` | — |
| `:iconOf()` | `any?` | texture ref from the icon DataTable, else the declared icon |
| `:mesh()` | `table?` | — |
| `:name()` | `string` | — |
| `:renderOn(actor)` | `boolean` | Attach this pal's declared mesh to a live pawn (one-shot; core.mesh guards against re-stacking). |
| `:skillsOf()` | `string[]` | The skill ids this pal owns (resolve them with Skill.get). |
| `:spawn(arg)` | `boolean` | Spawn this pal. → a new pal actor was observed (see above), NOT arrival at `at` |
| `:teachAll(actor)` | `integer` | Put every skill this pal DECLARES onto a live character, so the game itself carries them. `skillsOf()` is what the author wrote; this is how that list reaches a real pal standing in the world. |

Event forwarders (same names as the hooks above; they call the definition's
handler NOW — a test seam, not the real dispatch): `:onCaptured(ctx)` `:onDamaged(ctx)` `:onDeath(ctx)` `:onSpawned(ctx)` `:onTick(ctx)`.

`Pal.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:iconOf()` `:material()` `:mesh()` `:skillsOf()`.

## Item

An item is a piece of inventory content: materials, consumables, equipment, ammo.

| call | returns | notes |
|---|---|---|
| `Item{ … }` | `Item.Handle` | Define an item (give an item id behaviour + metadata) and register it. `spec` is validated against Item.Spec: `id` is required,… |
| `Item.get(id)` | `Item.Handle` | Get an EXISTING item by id: a previously-defined one, else a thin definition over any game ItemId (so vanilla items are actionable too). Never nil. |
| `Item.get_all()` | `Item.Handle[]` | Every PalForge-registered item, as a list of handles. |

### Item.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | item id: a game ItemId ("Wood") or "pack:name" |
| `name` | `string` | — | display name for YOUR ui/tooling; not the in-game name (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `category` | `string` | = `material`, one of `material` `consumable` `equipment` `ammo` `ingredient` `other` | what kind of inventory content this is (PalForge's own classification) |
| `maxStack` | `number` | = `1` | stack ceiling you declare; the GAME's ceiling is a DataTable column |
| `icon` | `any` | — | fallback icon used when the DataTable lookup misses |
| `recipe` | `table` | shape [Item.Spec.Recipe](#itemspecrecipe) | the recipe that produces THIS item (metadata; see Item.Spec.Recipe) |
| `events` | `table` | shape [Item.Spec.Events](#itemspecevents) | lifecycle handlers (grouped) |
| `data` | `table` | — | free-form payload of your own, carried onto the definition |

### Item.Spec.Events

Declared as `events = { onX = function(self, …) end }` inside `Item{ … }`.

| hook | fires | signature | ctx | meaning |
|---|---|---|---|---|
| `onObtain` | LIVE | `fun(self: Item.Handle, ctx: table)` | ctx.count = how many were obtained | LIVE - entered the inventory (ctx.count, ctx.via) |
| `onUse` | LIVE | `fun(self: Item.Handle, ctx: table)` | ctx.actor = who used it | LIVE - used / consumed (ctx.actor = the local player pawn) |
| `onCraft` | no | `fun(self: Item.Handle, ctx: table)` | — | declarable; NO native source exists — fires only on a manual emit |
| `onDiscard` | no | `fun(self: Item.Handle, ctx: table)` | — | declarable; NO native source exists — fires only on a manual emit |

### Item.Spec.Recipe

| field | type | rules | meaning |
|---|---|---|---|
| `materials` | `table` | **required**, values `number` | { <itemId> = <count> } consumed by one craft |
| `count` | `number` | = `1` | how many of this item one craft yields |
| `work` | `number` | — | work amount the station must put in |
| `station` | `string` | — | workbench / station id that can craft it |

### Item.Handle

| method | returns | notes |
|---|---|---|
| `:category()` | `string` | — |
| `:count()` | `integer?` | WORKS, and is measured. How many of this item the local player is holding right now, or nil when the count could not be read (no world / no player — nil is UNKNOWN, never zero). |
| `:description()` | `string?` | — |
| `:give(count)` | `boolean` | Add `count` of this item to the local player's inventory (default 1) through the game's own UPalCheatManager:GetItem(FName… → true only when the inventory count was measured to rise |
| `:iconOf()` | `any?` | texture ref from the icon DataTable, else the declared icon |
| `:maxStack()` | `integer` | — |
| `:name()` | `string` | — |
| `:recipeOf()` | `Item.Spec.Recipe?` | — |
| `:take(count)` | `boolean` | Remove `count` of this item from the local player's inventory (default 1) through the game's own UPalCheatManager:DropItem(const… → true only when the inventory count was measured to fall |

Event forwarders (same names as the hooks above; they call the definition's
handler NOW — a test seam, not the real dispatch): `:onCraft(ctx)` `:onDiscard(ctx)` `:onObtain(ctx)` `:onUse(ctx)`.

`Item.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:iconOf()` `:recipeOf()`.

## Building

A building is a placeable structure: workbenches, storage, machines, decorations — anything picked from the build menu and set into the world.

| call | returns | notes |
|---|---|---|
| `Building{ … }` | `Building.Handle` | Define a building and register it. core/event picks the definition up on its next scan, so a building defined AFTER startup is… |
| `Building.get(id)` | `Building.Handle` | Get an EXISTING building by id: a previously-defined one, else a thin definition over any game BuildObjectId. Never nil. |
| `Building.get_all()` | `Building.Handle[]` | Every PalForge-registered building, as a list of handles. |

### Building.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | build id: a game BuildObjectId ("PalBoxV2") or "pack:name" |
| `name` | `string` | — | shown in UI (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `gridCm` | `number` | — | placement grid quantum in cm (default core.spatial.GRID_CM) |
| `buildIds` | `table` | each element `string` | the game build ids this definition claims; REPLACES the default { id } |
| `tickInterval` | `number` | = `1` | run onTick every N heartbeats |
| `mesh` | `table` | shape [Building.Spec.Mesh](#buildingspecmesh) | the mesh attached to the placed actor (inline, or a Mesh{ ... } handle) |
| `material` | `table` | shape [Building.Spec.Material](#buildingspecmaterial) | material override applied to that mesh |
| `color` | `table` | — | base tint { r, g, b, a } (shorthand for material.color) |
| `texture` | `string` | — | png path applied to the mesh (shorthand for material.texture) |
| `icon` | `any` | — | fallback icon used when the DataTable lookup misses |
| `state` | `table\|fun(): table` | — | default persisted state for a new instance (a table, or a factory returning one) |
| `events` | `table` | shape [Building.Spec.Events](#buildingspecevents) | lifecycle handlers (grouped) |
| `data` | `table` | — | free-form payload of your own, carried onto the definition |

### Building.Spec.Events

Declared as `events = { onX = function(self, …) end }` inside `Building{ … }`.

| hook | fires | signature | ctx | meaning |
|---|---|---|---|---|
| `onPlace` | LIVE | `fun(self: Building.Instance, ctx: table)` | ctx.actor, ctx.pos, ctx.player | LIVE - committed into the world |
| `onLoad` | LIVE | `fun(self: Building.Instance, ctx: table)` | ctx.reconstructed = came from a save | LIVE - tracked / restored from a save |
| `onRightClick` | LIVE | `fun(self: Building.Instance, ctx: table)` | ctx.actor, ctx.player | LIVE - primary interaction |
| `onRemove` | LIVE | `fun(self: Building.Instance, ctx: table)` | ctx.reason | LIVE - the structure vanished |
| `onTick` | LIVE | `fun(self: Building.Instance, ctx: table)` | ctx.count = heartbeat number | LIVE - heartbeat (see tickInterval) |
| `onWorldReady` | LIVE | `fun(self: Building.Instance, ctx: table)` | — | LIVE - world loaded; emitted after the first scan, so only structures already tracked get it |
| `onWorldLeft` | LIVE | `fun(self: Building.Instance, ctx: table)` | — | LIVE - the world was unloaded (emitted while instances are still live) |
| `onBuild` | LIVE | `fun(self: Building.Definition, ctx: table)` | ctx.buildId, ctx.model (the UPalMapObjectModel) | LIVE - build completed; nothing is placed yet, so `self` is the DEFINITION (ctx.buildId, ctx.model) |
| `onLeftClick` | no | `fun(self: Building.Instance, ctx: table)` | — | declarable; no native source exists yet |
| `onBreak` | no | `fun(self: Building.Instance, ctx: table)` | — | declarable; no native source exists yet |

### Building.Spec.Mesh

Same fields as [`Mesh.Spec`](#meshspec), with 3 differences:

| field | changed | here | in `Mesh.Spec` |
|---|---|---|---|
| `kind` | default | `static` | `skeletal` |
| `model` | doc | UStaticMesh asset path, or an OBJ path for the procedural backend | USkeletalMesh / UStaticMesh object path; for procedural / obj, an absolute .obj file path |
| `offset` | doc | { x, y, z } offset from the actor's origin | { x, y, z } offset from the mesh's normal position, in cm |

### Building.Spec.Material

Identical to [`Pal.Spec.Material`](#palspecmaterial) — same fields, same rules.

### Building.Handle

| method | returns | notes |
|---|---|---|
| `:description()` | `string?` | — |
| `:gridCm()` | `number?` | — |
| `:iconOf()` | `any?` | texture ref from the icon DataTable, else the declared icon |
| `:instances()` | `Building.Instance[]` | Every LIVE placed structure of this building in the current world, as instances. Empty until core/event's scan has seen them (world must be loaded). |
| `:mesh()` | `Building.Spec.Mesh?` | — |
| `:name()` | `string` | — |
| `:render()` | `integer` | Attach the mesh to every live structure of this building (normally automatic — the scan does it). |
| `:unlock()` | `boolean` | Unlock this building's technology so it appears in the BUILD menu. Modded buildings get a DT_TechnologyRecipeUnlock row named after their resolved id; this unlocks it. |
| `:update()` | `integer` | Re-tint every live structure of this building from its currentColor(). |

Event forwarders (same names as the hooks above; they call the definition's
handler NOW — a test seam, not the real dispatch): `:onBreak(ctx)` `:onBuild(ctx)` `:onLeftClick(ctx)` `:onLoad(ctx)` `:onPlace(ctx)` `:onRemove(ctx)` `:onRightClick(ctx)` `:onTick(ctx)`.

`Building.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:currentColor()` `:iconOf()` `:material()` `:mesh()` `:neighbors(radiusCm)` `:new(spec)` `:render()` `:update()`.

### Building.Instance

| field | type | meaning |
|---|---|---|
| `id` | `string` | the definition's build id |
| `actor` | `any` | the placed APalBuildObject |
| `pos` | `table` | { x, y, z } world position |
| `state` | `table` | your persisted state (mutate in place, then :save()) |
| `buildId` | `string` | the game build id this instance matched |
| `key` | `string` | the instance's stable registry key |

Plus the per-instance closures core/event installs: `:isValid()` `:save()` `:setDirty()`.

### Building.Definition

| field | type | meaning |
|---|---|---|
| `id` | `string` | the definition's build id |
| `name` | `string` | display name (defaults to id) |
| `description` | `string?` | the declared one-liner, if any |
| `data` | `table?` | your free-form payload from the spec |

## Skill

A skill is what a Pal can do: an active attack or a passive trait.

| call | returns | notes |
|---|---|---|
| `Skill{ … }` | `Skill.Handle` | Define a skill and register it. `spec` is validated against Skill.Spec: `id` is required, unknown fields are an error. |
| `Skill.get(id)` | `Skill.Handle` | Get an EXISTING skill by id: a previously-defined one, else a thin definition over any game skill id. Never nil. |
| `Skill.get_all()` | `Skill.Handle[]` | Every PalForge-registered skill, as a list of handles. |

### Skill.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | skill id: a game row id or "pack:name" |
| `name` | `string` | — | shown in skill lists (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `kind` | `string` | = `active`, one of `active` `passive` | an active skill is fired; a passive one is equipped |
| `element` | `string` | — | attribute / element (fire, water, ...) |
| `cooldown` | `number` | — | seconds between activations (enforced by :activate) |
| `power` | `number` | — | base power / magnitude |
| `icon` | `any` | — | fallback icon used when the DataTable lookup misses |
| `events` | `table` | shape [Skill.Spec.Events](#skillspecevents) | behaviour handlers (grouped) |
| `data` | `table` | — | free-form payload of your own, carried onto the definition |

### Skill.Spec.Events

Declared as `events = { onX = function(self, …) end }` inside `Skill{ … }`.

| hook | fires | signature | ctx | meaning |
|---|---|---|---|---|
| `onActivate` | manual | `fun(self: Skill.Handle, owner: any, ctx: table)` | — | an active skill fired (self, owner, ctx) |
| `onHit` | manual | `fun(self: Skill.Handle, target: any, ctx: table)` | — | one of its hits landed (self, target, ctx) |
| `onEquip` | manual | `fun(self: Skill.Handle, owner: any, ctx: table)` | — | a passive was attached (self, owner, ctx) |
| `onUnequip` | manual | `fun(self: Skill.Handle, owner: any, ctx: table)` | — | a passive was removed (self, owner, ctx) |

### Skill.Handle

| method | returns | notes |
|---|---|---|
| `:activate(owner, ctx)` | `boolean` | Fire this skill for `owner` NOW, unless it is still cooling down. |
| `:cooldownLeft(owner)` | `number` | Seconds until this skill is ready again for `owner` (0 when ready). |
| `:description()` | `string?` | — |
| `:element()` | `string?` | — |
| `:equip(owner, ctx)` | `boolean` | Run this skill's onEquip handler for `owner` — the "a passive was attached" moment. → false only when the handler raised |
| `:forget(actor)` | `boolean` | Take this skill back off a live character. The counterpart of :teach, with the same routing and the same read-back: true only when the skill is gone afterwards. |
| `:hit(target, ctx)` | `boolean` | Report a hit on `target`: runs onHit. Ignores the cooldown and `kind`. → false only when the handler raised |
| `:iconOf()` | `any?` | texture ref from the icon DataTable, else the declared icon |
| `:kind()` | `string` | "active" \| "passive" |
| `:name()` | `string` | — |
| `:power()` | `number?` | — |
| `:skillsOn(actor)` | `table?` | What `actor` actually carries right now, straight from the game: `{ active = { "FireBlast", ... }, passive = { "Legend", ... } }`. |
| `:teach(actor)` | `boolean` | Put this skill on a LIVE character — a pal or the player — so the game itself carries it. → true only when the skill was seen ON the character afterwards |
| `:unequip(owner, ctx)` | `boolean` | Run this skill's onUnequip handler for `owner` — the counterpart of :equip. → false only when the handler raised |

Event forwarders (same names as the hooks above; they call the definition's
handler NOW — a test seam, not the real dispatch): `:onActivate(owner, ctx)` `:onEquip(owner, ctx)` `:onHit(target, ctx)` `:onUnequip(owner, ctx)`.

`Skill.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:iconOf()`.

## Effect

An effect is a status applied to a character (a player or a Pal): buffs, debuffs, damage-over-time, shields.

| call | returns | notes |
|---|---|---|
| `Effect{ … }` | `Effect.Handle` | Define an effect and register it. `spec` is validated against Effect.Spec: `id` is required, unknown fields are an error. |
| `Effect.activeOn(target)` | `string[]` | The ids of every effect currently active on `target`. |
| `Effect.get(id)` | `Effect.Handle` | Get an EXISTING effect by id: a previously-defined one, else a thin definition. Never nil. |
| `Effect.get_all()` | `Effect.Handle[]` | Every PalForge-registered effect, as a list of handles. |

### Effect.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | effect id: a name or "pack:name" |
| `name` | `string` | — | shown on the status bar (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `duration` | `number` | — | total lifetime in seconds (omit = until :remove()) |
| `interval` | `number` | — | seconds between onTick calls (omit = no periodic tick) |
| `stackable` | `boolean` | = `false` | may several copies coexist on one target? |
| `maxStacks` | `number` | = `1` | stack ceiling when stackable |
| `icon` | `any` | — | status-bar icon |
| `nativeStatus` | `string` | checked | the game's own ailment this mirrors, e.g. "Poison" (core.status.names()) |
| `events` | `table` | shape [Effect.Spec.Events](#effectspecevents) | lifecycle handlers (grouped) |
| `data` | `table` | — | free-form payload of your own, carried onto the definition |

### Effect.Spec.Events

Declared as `events = { onX = function(self, …) end }` inside `Effect{ … }`.

| hook | fires | signature | ctx | meaning |
|---|---|---|---|---|
| `onApply` | LIVE | `fun(self: Effect.Handle, target: any, ctx: table)` | — | LIVE - applied to a target |
| `onTick` | LIVE | `fun(self: Effect.Handle, target: any, ctx: table)` | — | LIVE - every `interval` seconds while active |
| `onStack` | LIVE | `fun(self: Effect.Handle, target: any, ctx: table)` | — | LIVE - re-applied to a target that already has it |
| `onExpire` | LIVE | `fun(self: Effect.Handle, target: any, ctx: table)` | — | LIVE - duration elapsed, removed, or target gone |

### Effect.Handle

| method | returns | notes |
|---|---|---|
| `:apply(target, ctx)` | `boolean` | Apply this effect to `target`. Starts the timer: onApply now, onTick every `interval` seconds, onExpire after `duration` (or on :remove()). |
| `:description()` | `string?` | — |
| `:duration()` | `number?` | — |
| `:iconOf()` | `any?` | — |
| `:interval()` | `number?` | — |
| `:isActive(target)` | `boolean` | Is this effect currently active on `target`? |
| `:name()` | `string` | — |
| `:remove(target)` | `boolean` | End this effect on `target` early (fires onExpire with reason "removed"). |
| `:stacksOn(target)` | `integer` | How many stacks of this effect are on `target` (0 when inactive). |
| `:timeLeft(target)` | `number?` | Seconds left before this effect expires on `target`: nil when indefinite, 0 when inactive. |

Event forwarders (same names as the hooks above; they call the definition's
handler NOW — a test seam, not the real dispatch): `:onApply(target, ctx)` `:onExpire(target, ctx)` `:onStack(target, ctx)` `:onTick(target, ctx)`.

`Effect.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:iconOf()`.

## Audio

Audio is one playable sound: background music or a one-shot effect.

| call | returns | notes |
|---|---|---|
| `Audio{ … }` | `Audio.Handle` | Define a playable sound and register it. `spec` is validated against Audio.Spec: `id` is required, unknown fields are an error. |
| `Audio.bgm(spec)` | `Audio.Handle` | Define background music (kind = "bgm"). |
| `Audio.get(id)` | `Audio.Handle` | Get an EXISTING sound by id: a previously-defined one, else a thin native definition keyed on that id. |
| `Audio.get_all()` | `Audio.Handle[]` | Every PalForge-registered sound, as a list of handles. |
| `Audio.se(spec)` | `Audio.Handle` | Define a one-shot sound effect (kind = "se"). |

### Audio.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | audio id: the AkAudioEvent name, or "pack:name" |
| `name` | `string` | — | human label (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `kind` | `string` | = `se`, one of `se` `bgm` | descriptive only - the native play route is the same for both |
| `soundId` | `string` | — | native AkAudioEvent name - its asset path is filled in from the native catalog when you do not pass one |
| `soundPath` | `string` | — | native AkAudioEvent asset path (the route that actually plays); overrides the catalog lookup |
| `soundFile` | `string` | — | custom audio file path (seam - not playable yet) |
| `source` | `fun(self: Audio.Definition): table\|nil` | — | override that returns the core.sound spec yourself; `self` is the DEFINITION, not the handle |
| `data` | `table` | — | free-form payload of your own, carried onto the definition |

### Audio.Handle

| method | returns | notes |
|---|---|---|
| `:description()` | `string?` | — |
| `:kind()` | `string` | "bgm" \| "se" |
| `:name()` | `string` | — |
| `:play(actor)` | `boolean` | Play this sound on `actor` (default: the local player pawn). |
| `:setVolume(volume)` | `boolean` | Set the playback volume, 0.0 .. 1.0. NOT IMPLEMENTED — returns false so a caller can tell it did nothing, and on this build there is no per-sound volume to set AT ALL. |
| `:source()` | `table?` | The lowered source spec core.sound will resolve ({ kind = "native"\|"file", ... } \| nil). |
| `:stop(actor)` | `boolean` | Stop sounds on `actor` (default: the local player pawn). ACTOR-WIDE by design: the native call is StopSoundByActor, so it silences everything playing on that actor and WHICH sound you called it on is ignored. |

`Audio.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:source()`.

## Mesh

A mesh is the VISUAL a definition wears: a model asset plus how to paint it.

| call | returns | notes |
|---|---|---|
| `Mesh{ … }` | `Mesh.Handle` | Define a NAMED mesh and register it. |
| `Mesh.get(id)` | `Mesh.Handle` | Get a previously-defined mesh by id. |
| `Mesh.get_all()` | `Mesh.Handle[]` | Every PalForge-registered mesh, as a list of handles. |

### Mesh.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | checked | mesh id, e.g. "pack:name" (required when defined directly; omit when inline) |
| `kind` | `string` | = `skeletal`, one of `procedural` `static` `skeletal` `obj` | which core.mesh backend renders it |
| `model` | `string` | **required** | USkeletalMesh / UStaticMesh object path; for procedural / obj, an absolute .obj file path |
| `animClass` | `string` | — | ABP_*_C animation blueprint path (skeletal only) |
| `scale` | `number` | — | uniform scale applied to the attached mesh |
| `offset` | `table` | — | { x, y, z } offset from the mesh's normal position, in cm |
| `texture` | `string` | — | absolute path to a png applied to the mesh |
| `color` | `table` | — | tint { r, g, b, a } in 0..1 |
| `material` | `string` | — | base material asset path to instance from |
| `params` | `table` | — | extra material parameters: { vector = { name = {r,g,b,a} }, scalar = { name = n }, texture = { name = "<abs png>" } } |

### Mesh.Handle

| method | returns | notes |
|---|---|---|
| `:attachTo(actor)` | `boolean` | Attach this mesh to a live actor, once (core.mesh guards against re-stacking). Fail-soft false when the actor is not valid. |
| `:detach(actor)` | `boolean` | Undo attachTo, so the actor can be dressed afresh. procedural and static destroy the component they added; skeletal, which swaps the pawn's OWN body, puts back the asset, scale, offset and materials it captured… |
| `:kind()` | `string` | — |
| `:model()` | `string` | — |
| `:setColor(actor, color)` | `boolean` | Re-tint an already-attached mesh on `actor`. |
| `:source()` | `table` | The lowered spec core.mesh will render. |

`Mesh.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:source()`.

## UI

A UI element is something drawn on screen out of Palworld's own native UMG kit.

| call | returns | notes |
|---|---|---|
| `UI{ … }` | `UI.Handle` | Define a UI element and register it. |
| `UI.get(id)` | `UI.Handle` | Get an EXISTING element by id: a previously-defined one, else a thin (inert) element. Never nil. |
| `UI.get_all()` | `UI.Handle[]` | Every PalForge-registered UI element, as a list of handles. |

### UI.Spec

| field | type | rules | meaning |
|---|---|---|---|
| `id` | `string` | **required**, checked | element id, e.g. "pack:Panel" |
| `name` | `string` | — | human label (defaults to id) |
| `description` | `string` | — | one-line description, for UI and tooling |
| `render` | `fun(self: UI.Handle, root: any): boolean?` | — | build the widget tree under `root` (self, root); runs once per mount. Return false if it could not build — the element then stays unmounted |
| `update` | `fun(self: UI.Handle)` | — | refresh the already-built widgets (self); runs on each :refresh() |
| `destroy` | `fun(self: UI.Handle)` | — | remove the widgets render() built (self); runs on :unmount() |
| `data` | `table` | — | default fields shared by every instance of this element |

### UI.Handle

| method | returns | notes |
|---|---|---|
| `:autoMount(root, ms)` | `boolean` | Poll every `ms` milliseconds off the same heartbeat, but drive the WHOLE lifecycle: while the element is down this retries mount(root) — so an element whose host UI does not exist yet (the title screen at load)… |
| `:autoRefresh(ms)` | `boolean` | Poll refresh() every `ms` milliseconds off core/event's heartbeat (opt-in; there is no confirmed native UI-update event to hook). |
| `:description()` | `string?` | — |
| `:isMounted()` | `boolean` | — |
| `:mount(root)` | `boolean` | Mount this element under `root` (render once). |
| `:name()` | `string` | — |
| `:new(spec)` | `UI.Handle` | A fresh, independently-mountable instance of this element. `spec` becomes its state. |
| `:refresh()` | `boolean` | Run update() on the live element. No-op until mounted. |
| `:state()` | `table` | The element's own state instance — what `self` is inside render/update/destroy. |
| `:unmount()` | — | Take the element down: runs destroy() so it removes its own widgets, then forgets the rendered state so a later mount() renders afresh. Also cancels autoRefresh/autoMount. |

`UI.Class` methods (what `self` resolves inside a handler that gets a
definition or an instance): `:destroy()` `:isMounted()` `:mount(root)` `:refresh()` `:render(root)` `:unmount()` `:update()`.

## Player

PUBLIC player API. Thin facade over utils/player.

| call | returns | notes |
|---|---|---|
| `Player.character()` | `any` | The local player character, or nil if not in a world yet. → APalPlayerCharacter \| nil |
| `Player.coordinate()` | `Coord?` | The player's world coordinate { x, y, z }, or nil if unavailable. |
| `Player.coordinateOffset(dx, dy, dz)` | `Coord?` | The player's coordinate offset by (dx, dy, dz) — the common "near me" case. |

## Shared shapes

Declared without a domain prefix: they belong to no single domain.

### Coord

| field | type | rules | meaning |
|---|---|---|---|
| `x` | `number` | **required** | world X in centimetres |
| `y` | `number` | **required** | world Y in centimetres |
| `z` | `number` | **required** | world Z in centimetres |

