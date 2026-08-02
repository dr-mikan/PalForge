# PalForge

A content framework for **single-player Palworld**, written in Lua and running on
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). You describe a piece of content in a short file —
a building, an item, a pal, a skill, a status effect, a sound, a model, a menu — and PalForge
registers it, wires it to the game's own events, and gives it somewhere to keep its state.

```lua
require("palforge.api")

Building{
    id = "CampFire",                        -- the game's own build id
    events = {
        onRightClick = function(self, ctx)  -- fires on the real campfire, in a real save
            Item.get("Wood"):give(5)
        end,
    },
}
```

Full documentation: **https://dr-mikan.github.io/PalForge/**

---

## Single-player only

> PalForge targets SINGLE-PLAYER Palworld. Dedicated servers and co-op guests are not
> supported and are not tested: there is no replication layer, and the item, spawn and event
> routes are all client-authoritative. A pack may appear to work for the host and do nothing
> for anyone else.

That is a deliberate scope decision, not an oversight, and the reasons are structural rather
than incidental. `core/spawn.lua` builds a `PalCheatManager` off the **local** player
controller. Spending an item goes through a locally spawned `APalWeaponBase::RequestConsumeItem`.
Every event source in `core/event.lua` is a local `RegisterHook`. None of it has ever been run
against a dedicated server or a co-op guest, and none of it would be expected to behave. If
server support is ever in scope it is a new subsystem — authority checks on every write, an RPC
seam, a decision about who owns pack state — not a fix to any one of the items below.

The same sentence is printed in the log at every startup, so nobody has to find it here first.

## Which Palworld this was measured against

Every capability PalForge reports as working was measured — watched in a real save, or read off
the installed binary's own declarations — against **Palworld v1.0.2.101103**. That number is
in `Scripts/palforge/env.lua` as `gameBuild`, and it is in the startup line, because a framework
that does not say which build it was measured on gives its users no way to tell *"PalForge is
broken"* from *"the game moved"*. This tree has already been bitten by exactly that gap: `AddItem`
turned out to declare five parameters where the header dump had four, because the dump predated
the installed binary by a single patch.

At startup PalForge also asks the running game what build it is (`UKismetSystemLibrary`) and
records the answer in `env.gameBuildLive`. When the two disagree it says so once, in one line. If
the game cannot answer, the line reads `unknown` rather than a guess.

## Requirements

| | |
| --- | --- |
| Palworld | measured against v1.0.2.101103 (Steam, Win64) |
| UE4SS | with the Lua mod loader — if you already run other Palworld Lua mods, you have it |
| `CheatManagerEnablerMod` | **optional.** `core/spawn.lua` builds a cheat manager itself off the local player controller (`StaticConstructObject(pc.CheatClass, pc)`), so `Pal.Handle:spawn` does not need the mod — what it needs is a player controller, i.e. a loaded save. The enabler still helps `utils.items` (`give` / `take` / `unlockTech`), which finds a cheat manager but does not construct one; without one those log `no PalCheatManager` and return false |

## Install

Copy the tree below into `Pal/Binaries/Win64/ue4ss/Mods/`. **`palforge/` has to sit next to
`main.lua`** — `main.lua` puts its own `Scripts/` directory on `package.path` and looks for
everything else there, so a different layout breaks every part of it.

```text
ue4ss/
└── Mods/
    └── PalForge/
        ├── enabled.txt          <- empty file; UE4SS starts a mod only when this exists
        └── Scripts/
            ├── main.lua
            └── palforge/
                ├── env.lua      <- the dev/release switches and the declared game build
                ├── types.lua    <- editor annotations only; nothing loads it at runtime
                ├── autorun.txt  <- the keyless dev queue (core/autorun.lua reads it here)
                ├── api/         <- the public surface a pack writes against
                ├── core/        <- the engine: kernel, event system, Palworld bridges
                ├── native/      <- Palworld's own content as data catalogs
                ├── test/        <- the in-game API suite (SINGULAR — see below)
                ├── tests/       <- the headless unit bundle + ps_catalog (PLURAL — see below)
                └── utils/       <- log, json, file, items
```

Three entries are easy to leave out and each has a consequence that looks like something else:

* **`palforge/test/`, singular.** `core/registry.lua` requires `palforge.test`, and that module
  is what binds **F1**. An install without this directory has no test suite and no F1 key, in
  dev mode, with nothing else in the log to explain it.
* **`palforge/tests/`, plural.** A different thing: the headless unit bundle `core/registry`
  runs at startup under dev, and `palforge.tests.catalog`, which is the body of the `ps_catalog`
  console command. It ships. This paragraph used to say it was gitignored and absent from the
  repository — it *was* listed in `.gitignore`, and that was a defect rather than a design: a
  clone had a boot path and a console command pointing at four files it did not carry. The
  ignore line is gone. If the kernel names it in its "dev tooling NOT loaded" line, the copy is
  incomplete.
* **`palforge/autorun.txt`.** `core/autorun.lua` reads it from beside `palforge/` and runs named
  actions on world load. It is how anything gets run on a machine where no key and no console
  works — three input routes have failed in turn on this project.

`palforge/deprecated/` and `palforge/tmp/` are reference-only and are not needed at runtime.
`palforge/build.lua` is generated by `tools/deploy.sh` and is not in the repository.

Then switch the mod on, with either an empty `enabled.txt` in the mod folder or a line in
`ue4ss/Mods/mods.txt`:

```text title="ue4ss/Mods/mods.txt"
CheatManagerEnablerMod : 1
PalForge : 1
```

### Confirming it loaded

`Pal/Binaries/Win64/ue4ss/UE4SS.log` gets one line per startup, and it carries everything needed
to answer "is this thing even running":

```text
[PalForge.main][info] PalForge v0.3.0 starting | game build: declared v1.0.2.101103, live unknown (UKismetSystemLibrary CDO did not resolve) | dev=false debug=false | dev overlay: absent (release copy)
[PalForge.main][info] PalForge targets SINGLE-PLAYER Palworld. Dedicated servers and co-op guests are not supported and are not tested: ...
[PalForge.registry][info] dev tooling NOT loaded (env.dev = false, the shipped default): no dev keybinds — including F4, unlock all technologies — ...
[PalForge.registry][info] initialized (dev=false, debug=false, <n> class(es) registered)
[PalForge.main][info] ready
```

`live` is whatever the running game answers when asked for its build string. UE4SS starts a Lua
mod early, so `unknown` at that moment is ordinary rather than a failure — the read is retried
once at the first world load and the answer logged there. PalForge would rather print `unknown`
than a guess.

## What actually works

PalForge is at **v0.3.0**, and the honest summary is that the *routes into the game* are mostly
settled and a few *capabilities* are not. 32 capability items have been closed — most of them by
watching the thing happen in a real save, and the rest by reading the installed binary's own
function declarations. Six are open, and every one of them degrades honestly: it returns nil, or
does not fire, or refuses at define time and says why. Nothing in the list below silently does
the wrong thing.

| Domain | Works | Does not |
| --- | --- | --- |
| **Item** | `:give`, `:take`, `:count` — all three observed in a real save, each verified by reading the inventory back. `onObtain` / `onUse` / `onCraft` / `onDiscard` all fire. `:iconOf` reads the game's own artwork | `:recipeOf` returns nil (`item-datatable-row-read`) |
| **Pal** | `:spawn` and placement, both observed end to end. `onCaptured` / `onDamaged` / `onDeath` / `onSpawned` fire. Reading a pal's skills works. `:iconOf` reads 674/674 rows | `onSpawned` may over-report at world load (`pal-spawned-fresh`); `:teachAll` shares the skill-write item below |
| **Building** | the most complete domain: placement, per-structure instances, per-world save/load, `onPlace` / `onLoad` / `onRightClick` / `onRemove` / `onTick` / `onBuild` / `onWorldReady` / `onWorldLeft` | `onLeftClick` and `onBreak` are settled **negatively** — the game exposes no such hook. Disappearance surfaces as `onRemove(reason = "missing")` |
| **Effect** | `nativeStatus` turns the game's real ailments on and off, observed in a save. The duration / interval / stacking runtime is PalForge's own and works without the game | the ailment runs on the game's rules; PalForge does not control its strength |
| **Skill** | `onActivate` and `onEquip` / `onUnequip` observed firing in real combat. `:skillsOn` reads a pal's real loadout. Manual `:activate` / `:hit` with the cooldown enforced in Lua | `onHit` never fires (`skill-hit-source`); `:teach` / `:forget` are **unproven and opt-in** (`pal-skills-equip`) |
| **Audio** | the vanilla route: a 1957-entry AkAudioEvent catalog, `Audio.get(id):play()`, `:stop`, `:setVolume` | custom sound files. `Audio.Spec.soundFile` is **refused at define time** and names the reason (`audio-custom-file-loader`) — it used to outrank `soundId`, so setting it silenced audio that had been playing |
| **Mesh** | vanilla `/Game/...` static and skeletal meshes, class-checked before they are handed to the engine; `.obj` geometry from disk; material colour / texture parameter names read off the running game | nobody has yet watched a colour change or a custom texture import in game. See the asset table below |
| **UI** | building widgets out of Palworld's own UMG kit and mounting them into the game's own UI root — confirmed live | there is no "the UI changed" event to hook, so `:autoRefresh(ms)` polls (`ui-update-event`) |
| **Player** | `Player.character()`, `Player.coordinate()`, `Player.coordinateOffset(dx, dy, dz)` | — |

The six open items in full, with what each measurement needs, are in `plan/TODO.md`. Every one
of them is also marked in the source at the line an implementer would open, as
`-- TODO(<item-id>)`.

## What a pack can ship

This is the part most likely to be assumed rather than read.

| Asset | From your pack | Vanilla `/Game/...` |
| --- | --- | --- |
| Static / skeletal mesh | **No** — the loader refuses a path that does not start with `/` | Yes, working, class-checked |
| Procedural geometry | **Yes** — `.obj` off disk | n/a |
| Texture | Unproven — the import call is wired with the right declared signature and has never once been called | Yes |
| Sound | **No** — refused at define time | Yes, 1957-entry catalog |
| Material | **No** — only "parent a dynamic instance to an already-loaded material" | Yes |

So today **PalForge is a reference-vanilla-assets framework, with an untested custom-PNG side
door and a working OBJ side door.** If your content is built out of Palworld's own assets plus
your own behaviour, you are on the road that is measured. If it needs your own art, expect to
find the edges.

A file your pack ships can be resolved against **your own directory** rather than the game's
working directory, which is what makes a pack portable between machines instead of correct on
exactly one:

```lua
local file = require("palforge.utils.file")
Mesh{ id = "example:marker", kind = "obj", model = file.resolvePackPath("marker.obj") }
```

`file.packDir()` gives the directory of the file that called it, and `resolvePackPath` returns an
absolute path unchanged — so it is safe to run over any path, including a `/Game/...` object
path. When no pack directory can be found the path comes back untouched, which fails later with
the string you actually wrote instead of one PalForge guessed.

## Dev mode

**PalForge ships with every dev tool off**, and this is worth saying plainly because it used to
be the other way round. `env.dev` and `env.debug` both default to `false` in
`Scripts/palforge/env.lua`, and nothing in the framework turns them on.

What `dev` arms: nine keybinds — including **F4, which unlocks every technology in the loaded
save** — the F1 API suite (it spawns pals and hands out items), F9 reload-without-restarting, the
`ps_catalog` DataTable dumper, and the headless unit bundle at boot. What `debug` additionally
arms: the game-required test hooks under `palforge/test/hooks/`, which are declared rather than
run — each has to be asked for by name, and the ones that write into a save need
`env.debugHooks[id] = true` on top of that.

The switch is one optional file, `Scripts/palforge_dev.lua`, which `main.lua` requires
immediately before the kernel starts and ignores when it is absent:

```lua
-- Scripts/palforge_dev.lua
local env = require("palforge.env")
env.dev   = true
env.debug = true
```

It is gitignored, so it cannot reach a player through this repository, and `tools/deploy.sh`
writes it for you:

```bash
tools/deploy.sh                        # dev deploy into the default install; writes the overlay
tools/deploy.sh "/path/to/Palworld"    # dev deploy somewhere else
tools/deploy.sh --release              # no overlay, and any stale copy is deleted by name
```

The script replaces the deployed `Scripts/` wholesale (staging first, then two renames, so the
game never sees a half-populated tree), stamps the copy with a build timestamp so a stale in-game
run is visible in the log, and prints which mode it ran in. **It never edits `env.lua`**: a
release toggle that a tool flips on is a release toggle that eventually ships on, which is how
`dev = true` came to be the shipped default in the first place.

## Repository layout

```text
Scripts/          the mod itself — this is what gets installed
docs/             the documentation site (Next.js + Fumadocs), published to GitHub Pages
dumps/            measured reflection data recovered from real sessions: class listings,
                  DataTable rows. The evidence behind the closed items
plan/TODO.md      what does not work yet, why, and the exact measurement each item needs
skills/           agent skill definitions for working on this repo
tools/            deploy.sh, and the generators for types.lua and the skill reference
e2e/              Playwright checks for the docs site
```

## Licence

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 YUYA556223.
