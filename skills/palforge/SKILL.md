---
name: palforge
description: Writes and debugs PalForge content packs — Lua mods for Palworld, running under UE4SS, that add or re-skin buildings, items, pals, skills, status effects, sounds, meshes and title-menu entries. Use whenever the request involves PalForge, a Palworld mod, or making any of those things appear in a Palworld save.
---

# PalForge content packs

PalForge is a Lua framework for Palworld under UE4SS. A pack is Lua files that call eight
domain modules. Requiring `palforge.api` installs the bare globals (mod-local, no clash).

## The one call shape

```lua
require("palforge.api")   -- installs Pal, Item, Building, Skill, Effect, Audio, Mesh, UI, Player

local bench = Building{                       -- CALL the module = define + register -> Handle
    id           = "WorkBench",               -- required, everywhere, in every domain
    name         = "Supply Bench",
    tickInterval = 20,                        -- heartbeats (500 ms each), not seconds
    mesh         = Mesh{ id = "mypack:Body",  -- a nested definition, passed as itself
                         kind = "static",
                         model = "/Game/Pal/Model/Other/PalBox/SM_PalBox.SM_PalBox" },
    state        = function() return { uses = 0 } end,   -- FACTORY, not a shared table
    events = {
        onRightClick = function(self, ctx)     -- self = the live instance
            self.state.uses = self.state.uses + 1
            self:save()
            Item.get("Wood"):give(5)           -- get inside a handler; never re-define
        end,
    },
}

Building.get("PalBoxV2"):instances()          -- act on any id, defined here or not
Building.get_all()                            -- every registered definition
```

`X{ ... }` is `X({ ... })`. Three members per domain and no more: `X{...}`, `X.get(id)`,
`X.get_all()`. Every call is validated: an unknown field, a missing `id`, a wrong type or a
value outside the allowed set is a **hard error** at define time with a did-you-mean. Read a
shape at runtime with `require("palforge.core.schema").help("Building.Spec")`.

**Ids.** No colon = a literal game id that already exists (`Wood`, `ChickenPal`, `ItemChest`).
Colon = your own (`"mypack:Flare"` -> row name `mypack_Flare`). Lua cannot add a row to the
game's DataTables, so a namespaced id works from your code and shows in no in-game list until
PalSchema publishes the row. **Build on existing ids.** Real ids live in
`Scripts/palforge/native/{buildings,items,pals,skills,audio}.lua` — take them from there,
verbatim, including case (`WorkBench` and `Workbench` are both real and different).

## Where a pack goes

Preferred — its own UE4SS mod folder, reusing the PalForge already loaded:

```text
ue4ss/Mods/MyPack/
    enabled.txt
    Scripts/
        main.lua          <- entry point UE4SS runs
        mypack/
            init.lua      <- requires every module, in dependency order
            buildings.lua items.lua pals.lua effects.lua skills.lua audio.lua
```

```lua title="ue4ss/Mods/MyPack/Scripts/main.lua"
local thisDir = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
package.path = thisDir .. "?.lua;" .. thisDir .. "?\\init.lua;" .. package.path

local forge = _G.PalForge                     -- published by PalForge's own main.lua
if not forge then
    pcall(print, "[MyPack] PalForge is not loaded - this pack does nothing this session")
    return
end
local log = forge.utils.log.scope("mypack")   -- .info .warn .err -> [PalForge.mypack][info]
local ok, err = pcall(function() require("mypack") end)
if ok then log.info("loaded") else log.err("load failed: " .. tostring(err)) end
```

`_G.PalForge = { env, api, utils = { log, json, file, items }, core = { registry, event,
object_manager, spawn, mesh, sound, player, spatial, icons }, native }`. Inside a module use
`local api = _G.PalForge.api` (or the globals, once `palforge.api` has been required once).

**Requiring a module IS registering its content** — every `X{ ... }` runs as the file loads.
Define at load; never inside a handler. Registration is keyed `(type, id)`, so defining an id
PalForge already ships replaces that definition (`WorkBench`, `PalBoxV2`, `Wood`, `Berries`,
`Arrow`, `ChickenPal`, `SheepBall`, `FlameThrower`, `Poison`/`Burn`/`Freeze`).

Alternative — a single file inside PalForge itself: `ue4ss/Mods/PalForge/Scripts/mypack.lua`,
required from the bottom of PalForge's `main.lua`, **after** `registry.initialize()`, inside a
`pcall`.

## The eight domains

| Domain | Use this when | Handle actions |
|---|---|---|
| `Building` | a placeable structure must do something, remember something, or look different | `:instances()` `:render()` `:update()` `:unlock()` |
| `Item` | inventory content needs behaviour, metadata, a recipe, or you want to hand one out | `:give(n)` `:take(n)` `:count()` `:recipeOf()` |
| `Pal` | a creature must react to being spawned/hurt/killed/caught, or you want to call one | `:spawn(arg)` `:renderOn(actor)` `:skillsOf()` |
| `Skill` | you need a named, cooldown-gated action you fire yourself | `:activate(owner,ctx)` `:hit` `:equip` `:unequip` `:cooldownLeft` |
| `Effect` | something must run for N seconds, tick every M, stack, and end | `:apply(t,ctx)` `:remove(t)` `:isActive` `:stacksOn` `:timeLeft` |
| `Audio` | you want a game sound or music to play | `:play(actor)` `:stop(actor)` |
| `Mesh` | a pal or a structure must wear a different model, tint or texture | `:attachTo(actor)` `:detach(actor)` `:setColor(actor,c)` |
| `UI` | you need a panel, a button, or an entry in the title menu | `:new(spec)` `:mount(root)` `:refresh()` `:autoRefresh(ms)` `:autoMount(root,ms)` `:unmount()` |

`Player` makes nothing: `Player.character()`, `Player.coordinate()`,
`Player.coordinateOffset(dx, dy, dz)`.

## Attaching behaviour

Handlers go in `events = { onX = function(...) end }`. An event name the domain does not
declare is a hard error, not a silent no-op. First argument is the thing it happened to:
`(instance, ctx)` for Building, `(handle, ctx)` for Pal/Item, `(handle, owner, ctx)` for Skill,
`(handle, target, ctx)` for Effect. `Audio` and `Mesh` have no `events` field at all.

**The rule: only write a handler in the LIVE column. Everything else needs you to call it.**

| Domain | LIVE — the game drives it | Never fires — put the work elsewhere |
|---|---|---|
| Building | `onPlace` `onLoad` `onRightClick` `onRemove` `onTick` `onWorldReady` `onWorldLeft` `onBuild` | `onLeftClick` `onBreak` |
| Pal | `onDamaged` `onDeath` `onCaptured` `onTick` (a 3 s sweep), `onSpawned` (wired, never observed firing) | — |
| Item | `onObtain` `onUse` | `onCraft` `onDiscard` |
| Effect | `onApply` `onTick` `onStack` `onExpire` — PalForge's own clock, started by `:apply` | — |
| Skill | none | all four; call `:activate` / `:hit` / `:equip` / `:unequip` |
| Audio, Mesh, UI | none | you play, attach, mount and refresh |

Everything periodic rides one 500 ms heartbeat: Building `onTick` (`tickInterval` counts
heartbeats), Effect timing, `event.every(ms, fn)`. Pal `onTick` rides a separate 3 s sweep
(`require("palforge.core.event").PAL_SCAN_MS`). Nothing fires until the world-ready gate opens.

Cross-cutting listening, when a definition hook is the wrong shape:

```lua
local event = require("palforge.core.event")
local sub = event.on("world.ready", function(ctx) end)  -- also building.*, pal.*, item.*, tick, gameStart
event.every(5000, function(ctx) end)                    -- rounds up to the 500 ms heartbeat
event.emit("mypack:quest.done", { reward = 3 })         -- your own channel names work too
sub:unsubscribe()                                       -- every subscription hands one back
```

## Check the work

1. Start the game with the mod on. `[PalForge.main][info] ready` means PalForge started.
2. **Press F1 in game** — the API test suite runs (~294 checks) and prints
   `tests: N passed, M failed, K skipped`. World-gated checks skip at the title screen. It
   sweeps its own definitions afterwards, so pressing it repeatedly is safe. F5–F8 are
   discovery probes, not tests. F4 unlocks all technology so custom buildings show in the
   build menu.
3. **Read `UE4SS.log`.** Every line is `[PalForge.<scope>][<level>] <msg>`. Use
   `forge.utils.log.scope("mypack")` so yours filter the same way. Order of business:
   - a define error — starts `PalForge: <Domain>: ...` and names the field;
   - `world ready - building dispatch enabled` — nothing world-side runs before it;
   - `#Building.get("<id>"):instances()` — empty means the scan never matched your id;
   - `<channel> -> <hook> handler failed: ...` — your handler raised (dispatch pcalls it).

## Reference

- `reference/api.md` — every call, field, hook, return value and validation message, generated
  from the live schema registry. The authority when this file and the docs disagree.
- `reference/recipes.md` — twelve complete, copy-pasteable content files.
- `reference/pitfalls.md` — what breaks first, and what to do instead. Read before writing.
- `plan/TODO.md` in the repo — the 35 public calls that do not yet do what they say.
- <https://dr-mikan.github.io/PalForge/> — the docs site (guides, concepts, per-domain pages).
