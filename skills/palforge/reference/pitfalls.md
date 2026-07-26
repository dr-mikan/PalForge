# PalForge pitfalls

Every entry is a mistake the code as it stands today actually punishes. Read before writing a
pack; check against this when something "does nothing". Sources: `Scripts/palforge/`,
`plan/TODO.md`.

---

## Definitions

### 1. Defining inside a handler

**Looks like** `onCaptured = function(pal, ctx) Audio.bgm{ id = "AKE_BGM_Title" }:play() end`.
The sound plays, and the log fills with re-registrations; with a `Building` or `Pal` it silently
replaces the definition every event, dropping whatever else was on it.

**Why** `X{ ... }` IS the constructor: it validates, builds a class and writes it into
`object_manager` under `(type, id)`. A handler runs on every event, so it re-registers on every
event. Registration is last-write-wins.

**Instead** define once at file load; inside a handler reach for `X.get(id)`, or close over the
handle the definition returned. `Audio.get("AKE_BGM_Title"):play()`.

### 2. Assuming a field exists

**Looks like** `Building{ id = "Altar", displayName = "X" }` →
`PalForge: Building: unknown field "displayName" (did you mean "name"?). Valid fields: ...`, and
the whole file stops loading.

**Why** every call is validated against a declared spec. Unknown field, missing `id`, wrong
type, value outside `values`, a bad `arrayOf`/`mapOf` element and a failing `check` are all hard
errors at level 0. The call never half-succeeds. Nothing is registered.

**Instead** read the shape rather than guessing:
`print(require("palforge.core.schema").help("Building.Spec"))`, or `reference/api.md`. Note the
field lists differ per domain — `Audio` and `Mesh` have no `events` field at all, `Item` has no
`mesh`, `Pal` has no `state`. Wrap the pack's top-level `require` in `pcall` so one bad field
does not take the rest of the pack down.

### 3. Expecting a brand-new id to show up in game

**Looks like** `Item{ id = "mypack:Potion", category = "consumable" }` registers cleanly,
`Item.get("mypack:Potion"):give(1)` returns something, and no inventory ever shows a potion.

**Why** Lua cannot add a row to Palworld's DataTables. A namespaced id resolves to the row name
`mypack_Potion`; until PalSchema publishes that row, the game has no such item / pal / build
object. The registration, the handlers and the metadata are all real — the row is not.

**Instead** build on ids the game already has, taken verbatim from
`Scripts/palforge/native/{buildings,items,pals,skills,audio}.lua`. Reserve namespaced ids for
things that are pure PalForge concepts: `Skill`, `Effect`, `Mesh`, `UI`.

### 4. Getting an id's spelling wrong

**Looks like** `Building{ id = "Workbench" }` registers, and no placed workbench is ever
tracked. Or `Pal{ id = "Sheepball" }` never receives a single event.

**Why** matching is by the live blueprint id (`BP_BuildObject_<Id>_C`, `BP_<Id>_C`), which is
not always the DataTable row FName. `WorkBench` (BP) vs `Workbench` (DT row); `SheepBall` (BP)
vs `Sheepball` (DT row). PalForge's own curated definitions use the BP spelling.

**Instead** copy the id out of the native catalogs, and verify tracking in game with
`#Building.get("<id>"):instances()`. An empty list after the world is ready means the id is
wrong.

### 5. Redefining an id PalForge already ships

**Looks like** your `Item{ id = "Wood" }` works, and PalForge's own `Wood` onObtain logging is
gone.

**Why** one id holds one definition per type. Shipped: buildings `WorkBench`, `PalBoxV2`; items
`Wood`, `Berries`, `Arrow`; pals `ChickenPal`, `SheepBall`; skill `FlameThrower`; effects
`Poison`, `Burn`, `Freeze`; ui `palforge:Button`, `palforge:TitleMenu`.

**Instead** pick a different id, or accept the replacement deliberately.

---

## Hooks

### 6. Declaring a hook that never fires

**Looks like** a valid definition whose handler simply never runs, with nothing in the log —
indistinguishable from "the thing never happened".

**Why** the name is *declarable* (the spec accepts it, the base class installs it) but no source
emits it. Today: Building `onLeftClick`, `onBreak`; Item `onCraft`, `onDiscard`; all four Skill
hooks (`onActivate`, `onHit`, `onEquip`, `onUnequip`). See `plan/TODO.md` — each is blocked on
an unmeasured native function, not on missing code.

**Instead**

| Wanted | Use |
|---|---|
| Building `onLeftClick` | `onRightClick` |
| Building `onBreak` | `onRemove` (fires ~3 s late, `ctx.reason == "missing"`) |
| Item `onCraft` | `onObtain` — a crafted item lands via the get-log |
| Item `onDiscard` | nothing; there is no signal at all |
| any Skill hook | call `:activate(owner, ctx)` / `:hit` / `:equip` / `:unequip` yourself |

### 7. Building a feature on Pal `onSpawned`

**Looks like** a pal that never gets its mesh, because the hook that was supposed to dress it
did not fire — or gets dressed twice.

**Why** `onSpawned` rides `BroadcastOnCompleteInitializeParameter`, an unconfirmed candidate,
armed only after the world loads. It has never been observed firing, and if it does fire it may
signal a re-initialisation rather than a fresh spawn.

**Instead** keep the handler idempotent, and duplicate the work somewhere that is confirmed:
Pal `onTick` (the ~3 s sweep, `ctx.actor`), or `onDamaged`. `pal:renderOn(actor)` is safe to
call repeatedly — core.mesh guards against re-stacking.

### 8. Expecting Building `onWorldReady` per structure

**Looks like** structures far from the player never run their startup code.

**Why** `world.ready` is a one-shot world-load moment, emitted by the first scan that completes
after the ready gate opens. Only structures that scan had already tracked receive it; anything
that streams in later missed the emit.

**Instead** put per-structure startup work in `onLoad`, which fires for every instance the scan
tracks, whenever it tracks it, with `ctx.reconstructed` telling you it came from a save.

### 9. Touching the mesh inside `onPlace`

**Looks like** `inst:render()` or a material tweak in `onPlace` does nothing — or crashes the
game outright.

**Why** placement is announced (via `RequestBuild_ToServer`) before the actor is finished. The
runtime deliberately defers the mesh attach to a *later* scan; attaching on the placement frame
touches a half-initialised native object and produces an access violation that `pcall` cannot
catch.

**Instead** do visual work in `onRightClick`, `onTick`, or a later `inst:render()`.

### 10. Reading `ctx.actor` on `item.use` as the player

**Looks like** `ctx.actor:GetActorLocation()` in an `onUse` handler raises or returns nonsense.

**Why** the hook is `UseItemToCharacter_ServerInternal`, and under the confirmed signature its
first parameter is the item data object, not the character.

**Instead** use `ctx.itemId`, and reach the player through `Player.character()`.

### 11. Throwing inside a bare `event.on` subscriber

**Looks like** other subscribers on the same channel stop running, with nothing in the log.

**Why** dispatch wraps *definition hooks* in `pcall` and logs failures by channel and hook name.
A plain `event.on` subscriber gets neither. The emit itself is pcall'd at the source, so the
heartbeat survives — but the remaining subscribers on that emit do not.

**Instead** wrap risky work in your subscriber in `pcall` and log the failure yourself.

---

## Return values

### 12. Trusting a `true` that only means "the call was issued"

**Why** most of this API is fail-soft and reports what it can measure, which is often less than
"it worked".

| Call | What `true` really means |
|---|---|
| `Pal.Handle:spawn(coord)` | the native spawn call was ACCEPTED. Not arrival, not the coordinate — relocation runs in a deferred pass whose outcome is only logged (`pal-spawn-placement`). |
| `Item.Handle:give(n)` | the count was seen to rise — **or** `CountItemNum` could not be read at all, in which case the add is unverified (logged as such). |
| `Audio.Handle:play(actor)` | a native play call was issued for this sound. No run has ever confirmed audible output (`audio-akevent-play-signature`). |
| `Mesh.Handle:setColor` / `Building:update()` | a parameter write executed on a real dynamic material instance — under a name the material may not carry (`mesh-material-params`). |
| `Mesh.Handle:detach` | PalForge forgot the actor. The component may still be on screen (`mesh-detach-destroycomponent`). |

And the inverse: `Item.Handle:take(n)` returns `false` on most builds because no removal call
has ever been confirmed; `Audio.Handle:setVolume` returns `false` for every value, always;
`Item.Handle:count()` returns `nil` for UNKNOWN, which is **not** zero.

**Instead** design so a false or an unverified true is survivable. Do not build a cost/toll
mechanic on `:take`. Do not gate anything on `:spawn` having placed a pal at a coordinate. Treat
`:count() == nil` as "cannot tell", never as "none".

---

## Buildings

### 13. `state = { ... }` as a plain table

**Looks like** two placed structures share one counter: interacting with either raises both.

**Why** the definition's `state` is handed to every new instance. A plain table is handed as the
SAME table.

**Instead** `state = function() return { uses = 0 } end`. The factory is called per instance.
(Restored instances take their state from the saved record instead, so the factory runs only for
genuinely new ones.)

### 14. Confusing `tickInterval` with seconds

**Looks like** an `onTick` meant to run every 20 seconds runs 40 times as often.

**Why** `tickInterval` counts 500 ms heartbeats. `tickInterval = 20` is ten seconds. It defaults
to 1 and anything not an integer ≥ 1 is silently forced back to 1.

**Instead** seconds × 2. And note a definition with no `onTick` is never put on the tick list at
all, so adding one later is what turns the cost on.

### 15. Letting `onTick` raise

**Looks like** one structure stops ticking permanently, mid-session, with a single warning.

**Why** five failures without a success in between disable that instance's tick for the rest of
the session (`onTick '<key>' disabled after 5 failures`). Other instances keep running.

**Instead** guard `onTick` bodies, and prefer `inst:setDirty()` over `inst:save()` in a handler
that runs twice a second — `save()` writes the world file every call.

### 16. Expecting per-save persistence

**Looks like** a structure's state from one save turns up in another save at the same
coordinates.

**Why** `core.spatial.saveId()` always returns the literal fallback `"world"`, so every save on
the install shares one file, `state/entities_world.json` (`spatial-saveid`).

**Instead** assume one shared bucket per install. Do not key anything on the assumption that a
world's records are private to it.

### 17. Expecting removal to be prompt or informative

**Looks like** `onRemove` arrives ~3 seconds after a dismantle, with `ctx.reason == "missing"`,
and there is no way to tell a dismantle from a structure that streamed out.

**Why** there is no destroy hook anywhere in the tree. Disappearance is inferred by the scan
after 6 consecutive misses (`building-break`).

**Instead** do not hand out refunds or run "the player destroyed this" logic in `onRemove`.
Note that leaving the world is a different path: `onWorldLeft` runs on every live instance and
the saved records are **kept**, where `onRemove` deletes the record.

---

## Effects and skills

### 18. Expecting an effect to be a game ailment

**Looks like** `nativeStatus = "Burn"` validates and stores, and no status icon appears, no
damage-over-time happens, nothing outside your handlers changes.

**Why** `EPalStatusEffectType` is a native enum and no call to apply one has been confirmed, so
`nativeStatus` is metadata you can read back (`effect-native-status`). What IS real is the
schedule: `:apply` starts a live application that the 500 ms heartbeat advances, and `duration`,
`interval`, stacking and expiry all work.

**Instead** put the whole gameplay in `onApply` / `onTick` / `onExpire`. Also: applications are
not saved — leaving the world expires every one with `reason == "world_left"`, so re-apply from
`onLoad` or a `world.ready` subscriber if it should come back.

### 19. Expecting `Pal.Spec.skills` to equip anything

**Looks like** `skills = { "FlameThrower" }` validates, `:skillsOf()` reads it back, and the
spawned creature has gained nothing.

**Why** no native call that attaches a waza/passive to a live pal has been found — not even a
candidate name (`pal-skills-equip`, `skill-passive-source`).

**Instead** treat `skills` as author metadata, and drive `Skill.Handle:activate/hit/equip` from
code you control.

### 20. Expecting a stack to re-run `onApply`

**Looks like** setup code in `onApply` never runs a second time on a stacked effect.

**Why** re-applying a live effect calls `onStack`, never `onApply`, and always refreshes
`remaining` to the full `duration`. The stack counter only grows when `stackable = true` and
stops at `maxStacks`.

**Instead** put per-application setup in `onApply` and per-refresh work in `onStack`. Note an
`interval` below 0.5 does not tick faster than the heartbeat — the accumulator catches up by
looping, so several `onTick` calls land in one heartbeat.

---

## Audio, meshes and UI

### 21. Shipping your own audio file

**Looks like** `soundFile = "C:/mods/mypack/theme.wav"` validates and plays silence — and
silences a working `soundId` set alongside it.

**Why** no runtime file→playable path has been established in the shipping (Wwise) build, and
the file route takes precedence over `soundId`/`soundPath` (`audio-custom-file-loader`).

**Instead** name a game `AkAudioEvent` from `native/audio.lua`'s catalog. Also: `:stop(actor)`
is actor-wide (it silences that pawn's footsteps and voice lines too), and `:setVolume` does
nothing — pick a quieter event instead.

### 22. Nesting a named `Mesh{ ... }` into a building and expecting `static`

**Looks like** a structure wears nothing, and the log complains about a skeletal attach.

**Why** a named `Mesh{ ... }` is validated against `Mesh.Spec` on its own, whose `kind` defaults
to `"skeletal"`, and that filled-in value travels with the definition. The `"static"` default
belongs to `Building.Spec.Mesh` and therefore applies only to a mesh written INLINE in the
building.

**Instead** pin `kind = "static"` on any named mesh a structure will wear.

### 23. Expecting a tint, a texture or a procedural mesh to be visible

**Looks like** `setColor` returns true and nothing changes colour; a procedural/OBJ mesh
attaches and is white forever; a `texture = "…png"` logs `tex-fail(...)`.

**Why** three separate unmeasured facts: the real material parameter names
(`mesh-material-params`), whether any colour-carrying base material is cooked into the shipping
build (`mesh-base-material`), and whether `ImportFileAsTexture2D` is callable at all
(`mesh-texture-import`). The skeletal and static setters themselves are also unconfirmed
(`mesh-skeletal-setter`, `mesh-static-setstaticmesh`).

**Instead** treat the visual layer as best-effort. Design so the pack is still worth playing if
the model never changes, and verify in game rather than from a `true`.

### 24. Expecting a UI element to refresh itself

**Looks like** a panel showing stale numbers forever, or a title-menu entry that vanishes when
the title screen rebuilds.

**Why** no native "the UI was rebuilt" hook has been found (`ui-update-event`), so nothing calls
`refresh()` for you. And `:autoRefresh` is a no-op while the element is unmounted, so it can
never get an element in that failed its first `mount`.

**Instead** call `:refresh()` when your state changes, `:autoRefresh(ms)` to poll, and
`:autoMount(root, ms)` when the host UI may not exist yet (the title screen at load) — it is the
one call that both retries `mount` and refreshes once up. Only the title screen has a known
injection anchor; everywhere else, build your own layer with `native.ui.widget.screen()`
(`ui-host-paths`).

### 25. Expecting `iconOf()` or `recipeOf()` to read the game's tables

**Looks like** `Item.get("Wood"):iconOf()` is nil, `Item.get("Arrow"):recipeOf()` is nil, even
though both rows exist.

**Why** no row-VALUE accessor on a live `UDataTable` has been confirmed on this build
(`icons-row-read`, `item-datatable-row-read`). Both calls fall back to what you declared.

**Instead** declare `icon` and `recipe` yourself if your pack needs them, and read them back
from your own definition.

---

## Loading

### 26. Loading before PalForge

**Looks like** `attempt to index a nil value (global 'Building')`, or the pack's guard printing
"PalForge is not loaded".

**Why** `_G.PalForge` is published at the very end of PalForge's `main.lua`, and the globals
(`Pal`, `Item`, …) are installed by `require("palforge.api")` inside `registry.initialize()`.
Both exist only afterwards, and only in the same Lua state.

**Instead** in a separate mod folder, guard on `_G.PalForge` and return quietly when it is
missing, then check the order UE4SS loads the two folders in. Inside PalForge itself, require
your file from the bottom of `main.lua`, after `registry.initialize()`, in a `pcall`.

### 27. Expecting anything world-side to run before the world is ready

**Looks like** definitions registered, no errors, and no building/pal/item event ever arrives.

**Why** every native source except the heartbeat returns early until the ready watch has seen a
valid `PalPlayerCharacter` five polls in a row. `Building.Handle:instances()` is empty until the
first scan afterwards.

**Instead** look for `[PalForge.event][info] world ready - building dispatch enabled` in
`UE4SS.log` before debugging anything else. Registering definitions after startup is fine — the
building runtime re-reads its definitions before every scan.

### 28. Not running the suite

**Looks like** a regression noticed three changes later.

**Why** the API test suite is not automatic: it spawns pals and hands out items, so it waits for
a key.

**Instead** press **F1** in game after a change and read
`[PalForge.unittests][info] tests: N passed, M failed, K skipped`. It namespaces and sweeps its
own definitions, so it is safe to press repeatedly. World-gated checks skip at the title screen —
run it once in a loaded save. **F4** unlocks all technology so custom buildings appear in the
build menu; **F5–F8** are discovery probes for `plan/TODO.md`, not tests.
