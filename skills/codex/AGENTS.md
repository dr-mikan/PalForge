# PalForge

PalForge is a Lua content framework for Palworld running under UE4SS. A *pack* is a Lua file
that calls PalForge's API to add items, buildings, pals, skills, effects, sounds, meshes and
UI. Write packs against the shape below; do not invent fields.

## Reaching the API

```lua
local api = require("palforge.api")   -- from inside PalForge's own Scripts/ folder
local PF  = _G.PalForge               -- from a separate UE4SS mod; then api = PF.api
```

`require("palforge.api")` also installs the bare globals `Pal Item Building Skill Effect
Audio Mesh UI Player`, so `Item.get("Wood"):give(10)` works without the `api.` prefix. UE4SS
gives each Lua mod its own Lua state, so those globals belong to that mod alone.

`_G.PalForge` also carries `utils` (`log`, `json`, `file`, `items`), `core` (`registry`,
`event`, `object_manager`, `spawn`, `mesh`, `sound`, `player`, `spatial`, `icons`), `native`
and `env`.

## The call shape — every domain is identical

```lua
local h = Item{ id = "Stone", name = "Stone", category = "material",
                events = { onObtain = function(self, ctx) end } }  -- define + register
Item.get("Wood"):give(10)     -- act on one, defined here or not
Item.get_all()                -- every registered definition, as handles
```

- The module **is** the constructor: `X{ ... }` is Lua sugar for `X({ ... })`.
- Every domain requires `id` and returns an `X.Handle`.
- **Define once, act many times.** Inside a handler use `X.get(id)` — calling `X{ ... }`
  on every event re-registers the definition.
- Nested definitions pass as themselves: `mesh = Mesh{ id = "p:body", model = "..." }` and
  inline `mesh = { model = "..." }` validate identically. Only an inline mesh may omit `id`.
- Handlers are grouped: `events = { onX = function(self, ...) end }`.
- An id with no colon is one of the game's own row ids (`Wood`, `PalBoxV2`, `ChickenPal`).
  `"pack:name"` is your own namespaced id and matches the row name `pack_name`.
- `X.Spec` shapes are private. Read them at runtime with `schema.help("Pal.Spec")` or
  `schema.get("Pal.Spec").fields`, from `require("palforge.core.schema")`.

## Domains

| domain | define | also on the module | what it is |
| --- | --- | --- | --- |
| `Pal` | `Pal{ … }` | `.get(id)` `.get_all()` | a spawnable creature |
| `Item` | `Item{ … }` | `.get(id)` `.get_all()` | inventory content: materials, consumables, equipment, ammo |
| `Building` | `Building{ … }` | `.get(id)` `.get_all()` | a placeable structure: workbenches, storage, machines, decorations |
| `Skill` | `Skill{ … }` | `.get(id)` `.get_all()` | what a Pal can do: an active attack or a passive trait |
| `Effect` | `Effect{ … }` | `.get(id)` `.get_all()` `.activeOn(target)` | a status on a character: buffs, debuffs, damage-over-time, shields |
| `Audio` | `Audio{ … }` | `.get(id)` `.get_all()` `.bgm(spec)` `.se(spec)` | one playable sound |
| `Mesh` | `Mesh{ … }` | `.get(id)` `.get_all()` | the visual a definition wears: a model asset plus how to paint it |
| `UI` | `UI{ … }` | `.get(id)` `.get_all()` | something drawn on screen from Palworld's own UMG kit |
| `Player` | — | `.character()` `.coordinate()` `.coordinateOffset(dx, dy, dz)` | the local player |

`Building` is the only domain with per-placement instances: inside its handlers `self` is a
`Building.Instance` carrying `self.actor`, `self.pos`, `self.state`, `self:save()` and
`self:isValid()`. `onBuild` is the exception — nothing is placed yet, so `self` is the
definition.

## The hook rule

Only write handlers for hooks that something actually fires. A hook that is merely
*declarable* is accepted at define time and never runs.

| domain | hooks that fire | declarable, but dead |
| --- | --- | --- |
| `Pal` | `onDamaged` `onDeath` `onCaptured` `onTick`; `onSpawned` is wired but never yet observed | — |
| `Item` | `onObtain` `onUse` | `onCraft` `onDiscard` |
| `Building` | `onPlace` `onLoad` `onRightClick` `onRemove` `onTick` `onWorldReady` `onWorldLeft` `onBuild` | `onLeftClick` `onBreak` |
| `Effect` | `onApply` `onTick` `onStack` `onExpire` | — |
| `Skill` | none natively — `onActivate` `onHit` `onEquip` `onUnequip` run only when you call `:activate` `:hit` `:equip` `:unequip` | — |
| `Audio` `Mesh` `UI` `Player` | no events at all | — |

If a design needs `onCraft`, `onDiscard`, `onLeftClick` or `onBreak`, say so and use the
live neighbour instead (`onObtain` / `onUse`, `onRightClick` / `onRemove`).

Nothing world-facing runs before the world gate opens; the log says
`world ready - building dispatch enabled`. Handlers run inside a `pcall`, so a mistake logs
rather than crashes, and a `Building` `onTick` that raises 5 times is switched off.
Everything periodic rides one 500 ms heartbeat, so `Building.tickInterval` counts heartbeats,
not seconds; `Pal` `onTick` rides a separate 3 s sweep.

## Validation is a hard error

Every definition call is validated before anything registers, and never half-succeeds. An
unknown field, a missing `id`, a wrong type, a value outside a declared set, or a bad nested
field raises with the full message, e.g.

```text
PalForge: Pal: unknown field "nam" (did you mean "name"?). Valid fields: id, name, description, skills, mesh, material, color, texture, icon, events, data
PalForge: Item: field "category" must be one of { "material", "consumable", "equipment", "ammo", "ingredient", "other" }, got "junk"
```

Read the message rather than guessing: it names the shape and lists the valid fields.

## What Lua cannot do

Lua cannot add a new row to the game's item, pal or building DataTables — that is PalSchema's
job. Build behaviour and metadata on an id the game already has, or accept that a `"pack:name"`
id needs a matching PalSchema row. `Pal.Handle:spawn` goes through `UPalCheatManager`, so it
returns `false` without `CheatManagerEnablerMod` enabled.

## Loading a pack

Preferred: ship the pack as its own UE4SS mod (`ue4ss/Mods/MyPack/` with `enabled.txt` and
`Scripts/main.lua`) that reuses the PalForge already running. List it below `PalForge` in
`ue4ss/Mods/mods.txt`, and guard on the published table:

```lua
local PF = _G.PalForge
if not PF then print("[mypack] PalForge is not loaded - check the mod load order\n") return end
local api, log = PF.api, PF.utils.log.scope("mypack")
```

Fallback, and the route that always works: put the file next to `main.lua` in
`ue4ss/Mods/PalForge/Scripts/` and require it at the **bottom** of that `main.lua`, after
`registry.initialize()`, inside a `pcall`:

```lua
local ok, err = pcall(require, "mypack")
if not ok then print("[mypack] load failed: " .. tostring(err) .. "\n") end
```

Before `initialize()` the globals are not installed and the native catalogs have not loaded.
Requiring a module **is** registering its content — every `X{ ... }` runs as the file loads,
so define at load time and never inside a handler.

## How to verify

1. **Syntax, offline:** `luac5.4 -p mypack.lua` (or `lua5.4 -e "assert(loadfile('mypack.lua'))"`).
   Do this on every pack file you write.
2. **Fields, offline:** check each field against `reference/api.md` in this repo, or at
   runtime with `print(require("palforge.core.schema").help("Item.Spec"))`.
3. **It loaded:** `[PalForge.main][info] ready` in `UE4SS.log`, then
   `[PalForge.event][info] world ready - building dispatch enabled` once a save is open.
4. **It works:** with `env.dev = true`, **F1** runs the shipped in-game suite and prints
   `[PalForge] tests: N passed, N failed, N skipped`; **F4** unlocks all technology so a
   modded building shows up in the build menu.
5. **Your handler ran:** log from it — `require("palforge.utils.log").scope("mypack").info(...)`
   prints `[PalForge.mypack][info] ...`. Failures show as
   `[PalForge.event][err] item.use -> onUse handler failed: ...`.

Never claim a pack works in game unless a log line or a test result says so. Syntax-checked
and schema-checked is the most an offline edit can honestly claim.
