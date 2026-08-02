# PalForge — what is still open

Everything in this file is something a reader must still **do**. Work that is finished *and
verified* — by a headless run, by a real in-game measurement, or by a check in the suite that
exercises it — has been deleted from here; the measurement that shaped it lives in the source
comment the fix is in, which is where someone changing that code will actually meet it.

Four sections:

- **Before publish** — the short list that gates a public release. It is one item.
- **Open (8)** — a public capability a pack author can call that does not do what it says. None is
  a wrong line of code; each is blocked on one fact about Palworld that nobody has measured. Each
  names that fact, the `-- TODO(<id>)` marker at the line a future implementer opens, and the
  **declared hook that takes the measurement**.
- **Owed work** — nothing here waits on a measurement of the game. It is work that is simply not
  finished, plus the capabilities whose only remaining step is running a hook that already exists.
- **Do not re-measure** — the negatives. A one-line index of facts that cost a session to
  establish and would otherwise be probed again. This is a *record*, not a task list: an entry
  earns its line only if a future implementer would look it up. Everything else that used to be
  here (the 2026-08-01 foundations audit, F-1..F-8, A-1..A-6, R-1, and thirty-odd Closed
  narratives) was deleted on 2026-08-02 because it was implemented, verified and written into the
  files it describes.

**Verified headlessly on 2026-08-02, re-run while this file was rewritten.** Full suite
**548 passed / 0 failed / 32 skipped (580 total)**; boot bundle **8 / 0 / 0**; `luac5.4 -p` clean
on all **157** `.lua` files under `Scripts/` and `tools/`; `bash -n tools/deploy.sh` clean.

**Measured in game on 2026-08-02, second run** (`ue4ss/UE4SS.log`, 17:36–17:38 — the first run's
log has since been overwritten, so what run 1 alone established is marked as such below):
`game-build-live` **3 pass / 0 fail**, with `PalGameInstance.DisplayVersion` and
`env.gameBuildLive` both answering `"v1.0.2.101103"`; `mesh-actor-identity` confirming the handle
key misses and the `GetFullName` key hits on a live `BP_BuildObject_ItemChest_C_2147468363` at
17:37:57.5 and 17:38:05.2, `rawequal` false and `uo.same` true both times; the startup line
reading `initialized (dev=true, debug=true, 17 class(es) registered)` with **building = 0**; the
keymap reading Palworld's own config as **107 mapping(s) over 77 key(s)**, twice; and the suite
pressed twice, **444 / 0 / 37** at the title screen and **466 / 0 / 15** in a loaded save. ⚠️ Those
two suite figures are out of **481**, not 580: that deploy (2026-08-02 17:15:18) predates the store
pass, which added 99 checks. What run 2 confirmed is the **skip structure**, and that is what a
future run should compare against — see *Owed work §3*.

---

## Before publish

One thing stands between this tree and a public v0.3.x, and it is the only one that needs the game.

### Settle the waza write

`pal-skills-equip` is the only Open item that is a publish blocker, and it is a blocker for a
reason none of the others share: `Skill.Handle:teach` **writes into a character in a real save**,
and the one run that did it was followed 1.4 seconds later by Palworld closing. The likeliest
explanation is that the write landed on a villager rather than a pal — the search was too wide then
and is fixed now — but "likeliest" is not a thing to publish on.

On a throwaway save, with a pal nearby:

```lua
local env = require("palforge.env")
env.debug = true                             -- Scripts/palforge_dev.lua already does this
env.debugHooks["pal-skills-equip"] = true    -- the per-hook write opt-in
-- then, from the UE4SS console:  pf_hook pal-skills-equip
```

`_G.PALFORGE_TEST_WRITE_WAZA = true` still works and is still honoured — `test/hooks/init.lua`'s
`M.writeAllowed` reads both spellings, and `test/cases/skill.lua`'s own gate asks that function
rather than the global, so arming either one opens both the hook and the F1 check.

Either the write lands and the item closes, or it crashes again with the target now known to be a
`PalMonsterCharacter`, and `:teach` / `:forget` / `:teachAll` ship disabled with the reason stated.
Both outcomes are publishable. The present state is not.

⚠️ An ordinary F1 press does **not** settle it. F1 exercises one gated check
(`test/cases/skill.lua:585`) and neither `Pal.Handle:teachAll` nor `core.character.clearSkills`.
`pf_hook pal-skills-equip` covers all three, and restores the pal it borrowed.

The other seven Open items are all fine to ship: `recipeOf` returns nil, `onHit` never fires,
`autoRefresh` polls, `pal.spawned` may over-report at world load, `soundFile` refuses out loud, and
the two native seams log what they did not do.

**The other five publish gates closed on 2026-08-02** and their reasons now live where a reader
meets them, not here: the repository shape and the declared game build in `env.lua` and `README.md`;
the dev switch defaulting off in `env.lua:39-41` with `tools/deploy.sh` as the half that makes doing
nothing correct; `soundFile`'s define-time refusal in `api/audio.lua`; the SINGLE-PLAYER statement
verbatim at `README.md:27`, in `main.lua`'s startup line and in `env.lua:78-82`; and the three
foundation defects, which are in the *Do not re-measure* index below.

---

## How the tree is laid out

New on 2026-08-02, and a reader needs it before anything else in this file makes sense.

**There is ONE test tree.** `Scripts/palforge/tests/` (plural) no longer exists.

```
Scripts/palforge/test/
  init.lua        THE one entry point. install(report) does everything.
  units/          headless suites, run at BOOT. 2 suites, 8 checks.
  cases/          the in-game API suite — F1. 19 files, 19 suites.
  hooks/          game-required measurements. 25 declared. Never auto-run.
  probes/         discovery dumps. Not tests; they pass and fail nothing.
  tools/          dev instruments — catalog.lua, the body of `ps_catalog`
  support.lua  probe.lua
```

Module paths that changed: `palforge.tests` → `palforge.test.units`; `palforge.tests.catalog` →
`palforge.test.tools.catalog`; `palforge.tests.audio_test` → `palforge.test.units.audio`;
`palforge.tests.object_manager_test` → `palforge.test.units.object_manager`.

**Production reaches into the test tree through ONE name and ONE call**, in `core/registry.lua`'s
dev block (`:164-167`):

```lua
local testState = requireState("palforge.test")
if testState == "loaded" then require("palforge.test").install(record) end
```

`install()` runs the boot bundle, loads the cases, binds F1 and the probe keys, registers every
console command and `ps_catalog`, and hands `core/autorun` its action table through
`autorun.setActions(...)` (`core/autorun.lua:105`). It used to be four reaches across two
directories one character apart, one of them `core/autorun.lua` pulling
`require("palforge.test").ACTIONS` on every world load. `core/autorun.lua` now requires nothing
under `test/`.

**A release deploy has no test tree at all.** Measured against the deployed tree:

| mode | files deployed | `palforge/test/` | `palforge_dev.lua` |
| --- | --- | --- | --- |
| dev (default) | **127** | yes, 57 files | yes (`env.dev = true, env.debug = true`) |
| `--release` | **69** | **no** | no, and a stale one is deleted |

127 = 69 + 57 + 1. So `requireState("palforge.test")` answering `"absent"` is the CORRECT state for
a release rather than an incomplete install. `deprecated/` is dropped from both modes.

---

## Open (8)

### Pal

#### `pal-skills-equip` — Skill.Handle:teach / :forget, Pal.Handle:teachAll

- **Hook:** `pf_hook pal-skills-equip` — needs a world and a pal, **writes**, so it also needs
  `env.debugHooks["pal-skills-equip"] = true`
- **Marked at:** `Scripts/palforge/core/character.lua:79`, and again at `:739` on `clearSkills`
  (the function itself is at `:748`)

**What a pack author sees.** `Skill.get("FireBlast"):teach(pal)` may return false and the pal may
not learn the move. When it works, the pal really does carry it — every write here is verified by
reading the character back, so a true is never "the call ran".

**Reading a pal's skills WORKS** — confirmed 2026-07-26 on a live `BP_SheepBall_C`: the whole route
answers (actor → `PalUtility` → individual parameters → **four** getters) and a real pal's real
loadout comes back. `Skill.Handle:skillsOn(actor)` is usable today and returns four keys, not two.
`equipable` and `mastered` answer **nil for UNKNOWN** rather than an empty list, because
`GetMasteredWaza` is not in the class's declared list (`HasMasteredWaza(EPalWazaID)` is) — so
`#(s.equipable or {})` is the idiom, and a `0` and a `nil` mean different things.

That took several runs for a reason worth keeping: `FindAllOf("PalCharacter")` is too wide.
`APalMonsterCharacter : APalNPC : APalCharacter`, so it matches villagers and merchants too, and an
NPC has no equipped move. Asking one of those reported zeros that looked exactly like a broken
reader. **Ask `PalMonsterCharacter`** — which the hook does, and it refuses to write unless
`uo.isA(target, "PalMonsterCharacter")`.

**⚠️ Writing a move correlates with a crash — but the target may have been wrong.** The first run
that did it — `AddEquipWaza` firing with evidence `declared`, the read-back not showing the move,
`RemoveEquipWaza` firing — was followed about 1.4 seconds later by Palworld closing, part way
through the mesh suite. The run before it, with no pal nearby, completed. It is now known that the
write did not necessarily go to a pal: it used the old search, and the read-back it consulted
afterwards was an NPC's empty list, which is also why it concluded the write had not landed. Putting
an equipped MOVE on a villager is a far more plausible way to destabilise the game than putting one
on a pal. The search is fixed and the experiment has not been re-run; it stays opt-in anyway,
because the correlation is unexplained rather than explained away.

**What is still unknown.** Only whether the ACTIVE writes land. The passive half is proven — closing
`skill-passive-source` required `core.character.addSkill` to put a passive on a live
`BP_ChickenPal_C` and read it back. Everything else is settled by `dumps/cxx/Pal.hpp`:

```text
class UPalIndividualCharacterParameter                       (Pal.hpp:20822)
    void AddEquipWaza(EPalWazaID WazaID);          RemoveEquipWaza(EPalWazaID);  ClearEquipWaza();
    void AddPassiveSkill(FName AddSkill, FName OverrideSkill);  RemovePassiveSkill(FName SkillId);
    TArray<EPalWazaID> GetEquipWaza();            TArray<FName> GetPassiveSkillList();
class UPalUtility
    UPalIndividualCharacterParameter* GetIndividualCharacterParameterByActor(const AActor*);
                                                                 (Pal.hpp:32340)
```

Every argument is an enum integer or an FName — never a struct — so none is the shape that faults
inside UE4SS marshalling, and every write has a matching read that proves it landed. The vocabulary
is settled too: `EPalWazaID` names **309** active skills (measured — `core.character.wazaNames()`
returns 309), which is what `Pal{ skills = { ... } }` can contain. Active skills are an enum and
passives are FNames, a real distinction a caller cannot paper over, so `:teach` routes on which one
the id is rather than on the skill's declared `kind`. Read-backs compare the **canonical**
`EPalWazaID` name, so a lower-cased or integer id no longer reports a landed write as missing.

**What has no coverage in the F1 suite, gated or otherwise.** `test/cases/skill.lua:585` is the only
automated check of the active-move write, and it is gated. `Pal.Handle:teachAll` (`api/pal.lua:553`)
has three pure checks over the `taught, asked` contract (`test/cases/pal.lua:438,447,468`) and a
fourth that always skips naming this hook (`:481`). `core.character.clearSkills`
(`core/character.lua:748`) has no caller and no check outside the hook.

### Item

#### `item-datatable-row-read` — Item.Handle:recipeOf (the :iconOf half is CLOSED)

- **Hook:** `pf_hook item-datatable-row-read` — needs a world, read-only. `item-recipe-of` is
  folded into it and the hook's own `item =` field says so
- **Marked at:** `Scripts/palforge/api/item.lua:229`, and the marker itself says RECIPE half only.
  `Class:recipeOf` is at `:210`

**What a pack author sees.** `recipeOf()` returns nil for every vanilla item even though
`DT_ItemRecipeDataTable_Common` has 1414 rows keyed by exactly the item ids the API takes.
`api/item.lua:210` returns `self.recipe` and never reaches the game.

**What is still unknown — and it is not the accessor any more.** UE4SS binds
`dt:FindRow(<plain Lua string>)`, `dt:GetRowNames()`, `dt:GetRowMap()`, `dt:GetAllRows()` and
`dt:ForEachRow()` onto `UDataTable` itself, which is why every reflection sweep missed them
(`dumps/cxx/Engine.hpp` shows `UDataTable` declaring five properties and ZERO functions); the
measured write-up is at `core/icons.lua:317-339`. What is left is the row VALUE. The only one this
tree has ever read was a single `TSoftObjectPtr` column, read the long way round because that
userdata answers none of the nineteen member names a soft pointer could plausibly expose. So:

```text
Can a scalar / FName column be indexed off the struct dt:FindRow(id) hands back — which was
never tried, and the TSoftObjectPtr failure that forced the detour does not apply to an int32
or an FName — or must the recipe be assembled the way icons are, with one
UDataTableFunctionLibrary::GetDataTableColumnAsString(dt, FName) call per column zipped
against dt:GetRowNames()? Thirteen calls per table, once, cached, is perfectly affordable if
the struct route stays shut.
```

Everything around it is measured (`dumps/reflection/01_datatables.txt`, a real session): the table
is loaded under `/Game/Pal/DataTable/Item/`, the row keys are the item ids, and the row struct
carries Product_Id, Product_Count, Material1_Id..Material5_Id, Material1_Count..Material5_Count,
WorkAmount, CraftExpRate, EnergyType, EnergyAmount, UnlockItemID, WorkableAttribute,
DenyRecipeChain.

The hook prints both routes side by side and unwraps the column elements with `:get()`, because
RemoteUnrealParam is exactly the trap that made the icon array read the right length with nothing
in it. Whichever answers is the implementation; if both do, the struct route is one call instead of
thirteen.

#### `item-satiety-write` — a food or heal item a pack declares itself

- **Hook:** `pf_hook item-satiety-write` — needs a world and a player pawn, **writes**, so it also
  needs `env.debugHooks["item-satiety-write"] = true`
- **Marked at:** `Scripts/palforge/native/items.lua:559`

**What a pack author sees.** `Item.Spec` carries nine fields — id, name, description, category,
maxStack, icon, recipe, events, data — and not one of them is a restore amount, so the only way to
react to a use is `events.onUse`, which is handed a ctx and whose return value is discarded. The
vanilla berry restores satiety because the GAME restores it: `item.use` is dispatched off
`UseItemToCharacter_ServerInternal`, a call PalForge HOOKS rather than makes. So an author's own food
item logs, and the bar moves only when the row it named was already a consumable. There is no way to
write "restores 40 satiety" and have it mean anything.

**What is still unknown — one parameter list.** What argument `SetFullStomach` takes. The live
reflection listing names it on `/Script/Pal.PalIndividualCharacterParameter`
(`dumps/reflection/02_reflection.txt:1298`, inside the class block that opens at `:1107`), and that
is the SAME object `core.character.paramsOf(actor)` already hands back. But the CXX dump's class
body (`Pal.hpp:20822-21161`) declares only the READERS: `GetMaxFullStomach` (`:21095`),
`GetFullStomachRate` (`:21106`), `GetFullStomach` (`:21108`). The setter is reflected and undeclared,
so its parameter list has never been read and `core/signature` has nothing to check a call against.

**HP is a separate and worse case**, kept apart because the two fail for different reasons. The HP
writes ARE declared: `UPalCharacterParameterComponent::SetHP` (`Pal.hpp:15933`), `::AddHP`
(`:16018`), `UPalIndividualCharacterParameter::AddHP` (`:21156`). All three take `FFixedPoint64`, a
STRUCT (`{ int64 Value; }`, `Pal.hpp:120-124`) — the argument shape that faults inside UE4SS
marshalling where pcall cannot see it. The one exception is `::AddHPByRate(float Rate)`
(`Pal.hpp:16016`): a single plain float, callable today, and never once called.

**The hook's order matters and is not negotiable**: pure reads first; then `core/signature`
**describing** `SetFullStomach` on the live object — the parameter walk, not a call, and **that list
is the finding**; then `AddHPByRate(-0.1)` with a read-back, the safe write; and only if the walk
reported a non-struct list, `SetFullStomach`. ⚠️ Nothing taking `FFixedPoint64` may be called there.
Note `GetHP` returns `FFixedPoint64`, so the number is behind its one `Value` field — a struct
RETURN is not the hazard a struct ARGUMENT is, but it is the difference between reading an HP and
reading a wrapper.

**Is the current return honest?** Yes — this is a missing capability, not a defect. No field and no
method on the item surface claims to feed or heal. The honesty risk is entirely future: an
`Item.Spec.restores` field added before the parameter walk answers would be a promise this build has
not been shown to keep.

### Skill

#### `skill-hit-source` — Skill.Spec.Events.onHit

- **Hook:** `pf_hook skill-hit-source` — needs a world, read-only; it confirms a negative
- **Marked at:** `Scripts/palforge/api/skill.lua:118`

**What a pack author sees.** `onHit` never fires. Everything else about a skill works —
`onActivate` fires and the handler gets the move's identity, `onEquip` fires, and `onUnequip` is
wired on the same class.

**Both candidate hooks are measured silent, and they rule out different things.**
`MakeDamageInfoByWazaType` was silent while a pal fought and killed another pal.
`PalAnimNotifyState_AttackCollision:OnHit` was silent in that same session, and silent again in a
session where the player killed a pal by hand — while `pal.damaged` and `pal.death` both carried, so
a blow certainly connected and certainly did damage. A hit does not reach either, from either side.

**What that leaves is not another hook.** `skill.activate` works and carries the waza id.
`pal.damaged` works. And nothing in the damage path carries a waza at all — `FPalDamageInfo` has 40
fields, `FPalDamageRactionInfo` 6, `FPalDamageResult` 12, and not one is an `EPalWazaID`. So the id
can only reach a hit by being remembered from the activation that preceded it and attributed to the
damage that follows. That is **inference, not a source**, and wiring it as one would be wrong: a
move that misses, a second pal attacking in the same window, or damage from anything else would all
be attributed to whatever activated last. If it is ever built it belongs behind a name that says so
— a correlated guess a pack opts into — and never on `onHit`, which promises the game told us.

The hook re-reads the three damage structs out of the *running* build looking for any waza field
(the 40/6/12 counts came from the dump, not the live binary), then counts `skill.hit` against
`pal.damaged` and `skill.activate` for 120 s and **quantifies the ambiguity**: how many damage
events had zero activations in the correlation window, and how many had more than one. Those two
numbers are the argument against ever wiring the inference, expressed as data.

#### `skill-projectile-spawn` — an active skill that puts something in the world

- **Hook:** `pf_hook skill-projectile-spawn` — needs a world and a pal, **writes**, so it also needs
  `env.debugHooks["skill-projectile-spawn"] = true`
- **Marked at:** `Scripts/palforge/native/skills.lua:652`, inside the curated `FlameThrower`'s
  `onActivate`, which is the demonstration

**What a pack author sees.** `Skill{ kind = "active", element = "fire", power = 50 }` defines,
registers and dispatches, and `onActivate` runs at exactly the right moment on a REAL activation —
that half is measured. But `element` and `power` are framework-side metadata that reach nothing
(their `doc =` strings say so), and the handler has no call available to it that puts an object in
the world. A pack's active skill is a well-timed Lua function, and that is all it is.
`native/skills.lua` logs one warn per session saying plainly that nothing was spawned.

**What is still unknown — whether a STRUCT can be marshalled at all.** Everything else on the path
is already read:

- the actor class exists — `APalSkillEffectBase : AActor` (`Pal.hpp:11345`), with
  `Initialize(const AActor*, const FVector&, AActor*, FRandomStream)` at `:11370` and
  `CreateChildSkillEffect(TSubclassOf<APalSkillEffectBase>, FTransform, FRandomStream,
  ESpawnActorCollisionHandlingMethod, AActor*)` at `:11374`;
- the waza row NAMES a class to spawn — `FPalWazaDatabaseRaw` (`Pal.hpp:7534`) carries
  `TSubclassOf<UPalWazaBulletEmiiterOverlapBase> BulletEmiiterOverlapClass` (`:7558`), reachable
  through `UPalWazaDatabase::FindWazaForBP` (`:32646`);
- PalForge ALREADY HAS the generic spawn — `core/spawn.lua`'s `M.actor` is
  `BeginDeferredActorSpawnFromClass` + `FinishSpawningActor`, both read off the dump.

What blocks it is that every one of those calls carries an `FVector`, an `FTransform`, an
`FRandomStream` or an out-struct by reference, and `core/signature` refuses a struct on "present"
evidence, because a struct pushed against an unread declaration is the failure shape that kills the
process. `M.actor` is gated on precisely this and has therefore never run. The bullet route is the
same story: `APalBullet` (`Pal.hpp:8849`), with `ShootOneBullet(TSubclassOf<APalBullet>,
UNiagaraSystem*, FVector, FRotator, float)` on `APalMonsterEquipWeaponBase` (`:10186`) — and one
argument-free sibling, `ShootOneBulletDefault()` (`:10185`), the only entry on this whole surface
that needs no struct at all.

The hook describes (never calls) `ShootOneBulletDefault`, `ShootOneBullet`, `CreateChildSkillEffect`
and `BeginDeferredActorSpawnFromClass` on live objects. **Whether the walk answers "declared" for a
`StructProperty` is the finding, and it settles `core/spawn.lua`'s `M.actor` at the same time.** Then
`ShootOneBulletDefault()` — zero arguments, the one thing safe to try before that answers. ⚠️ Do not
push a hand-built `FVector` or `FTransform` at a call whose declaration the walk could not read.

**Is the current return honest?** The doc carries the meaning and says the right thing:
`api/skill.lua:435` defines `Handle:activate` as false for a passive, false when the cooldown blocked
it, false when the handler raised, and otherwise "the handler ran to completion". It promises nothing
about the world. What a boolean CANNOT express is the case this definition is in — the handler ran,
deliberately, and produced nothing — so that is said in a log line instead. See *Owed work §1*.

### Audio

#### `audio-custom-file-loader` — Audio.Spec.soundFile

- **Hook:** `pf_hook audio-custom-file-loader` — needs a fully loaded save, read-only
- **Marked at:** `Scripts/palforge/core/sound/file.lua:56`

**What a pack author sees.** A hard error at define time, naming this item. `soundFile` used to be
accepted, validated, documented and to take precedence over `soundId`/`soundPath`, so a pack that
shipped its own `.wav` got silence — and worse, setting `soundFile` beside a working `soundId`
silenced that too, because the file route won. Now the definition refuses and says why.
`core/sound/file.lua` is unreachable from any definition; `FileSource:play` is still `return false`
rather than an error, and the header names the two deliberate routes that can still reach it (a
`source` override, and a direct `core.sound.resolve`).

**What is still unknown**

```text
TODO(audio-custom-file-loader): it is unknown whether the shipping build exposes ANY
runtime loader that turns a file on disk into something playable (a USoundWave/USoundBase
factory, or a Wwise external-source / SetMedia entry point); enumerating the audio-related
CDOs' reflected functions would settle whether such a call exists at all.
```

The hook prints all five blocks verbatim and prints nils rather than skipping them — **a run of nils
closes this item permanently.** Class existence for the six candidate CDOs (each as
`path, object, GetFullName`, with a `type(StaticFindObject)` guard so "class absent" cannot be
confused with "no lookup available"); GameplayStatics' complete function list if it resolved (we are
looking for PlaySound2D / CreateSound2D / SpawnSoundAttached surviving in shipping); every AkAudio
function containing External, Media, Source, Post or Load; `type(NewObject)` /
`type(StaticConstructObject)` / `type(StaticConstructObject_Internal)`, so we know whether UE4SS Lua
in this build can construct a `USoundWave` at all; and `#(FindAllOf('SoundWave') or {})` /
`#(FindAllOf('AkMediaAsset') or {})`, because whether the shipping game has any instance of either
loaded is itself an answer about whether that pipeline is alive.

### UI

#### `ui-update-event` — UI.Handle:autoRefresh(ms): polling is the only refresh driver PalForge has

- **Hook:** `pf_hook ui-update-event` — needs a world, read-only, but the operator has to open and
  close screens while it watches
- **Marked at:** `Scripts/palforge/api/ui.lua:1673`, inside `Handle:autoRefresh`

**What a pack author sees.** Nothing calls `refresh()` for a pack. Every element must either call
`:refresh()` by hand or ride the 500 ms heartbeat, so a panel shows stale content for up to `ms` and
there is no way to refresh exactly when the game rebuilds a screen. TitleMenu's whole re-injection
strategy is a poll for the same reason.

**What is still unknown**

```text
TODO(ui-update-event): unknown whether Palworld raises a catchable UFunction when a
UI is (re)built — until one is dumped, polling is the only driver PalForge has.
```

**Already eliminated, and worth not re-discovering:** `UPalUIManagerSubsystem` declares **zero**
functions. The marker says so and says not to enumerate it again; the hook keeps it in the sweep
anyway and explains in its own file why a 0 there is a confirmation rather than a discovery.

The hook resolves `/Script/Pal.<name>` and `/Script/Pal.Default__<name>` for
`PalUIManagerSubsystem`, `PalUIHUDLayoutBase`, `PalUITitleBase` and `PalUIInventoryEquipment`, lists
each class's UFunctions with every child property, then `RegisterHook`s every function whose name
contains Open / Show / Construct / Refresh / Update / Setup (capped at 40, with a warning that UE4SS
cannot unregister a hook) and prints them in first-fire order. Then the operator opens and closes the
inventory, opens the build menu, and returns to the title screen.

### Events

#### `pal-spawned-fresh` — Pal{ events = { onSpawned } } / event.on("pal.spawned")

- **Hook:** `pf_hook pal-spawned-fresh` — needs a world, read-only; give it 30 s after the load storm
- **Marked at:** `Scripts/palforge/api/pal.lua:180`, referenced again at `:39`. It was in
  `core/event.lua` when the item was filed; the channel now fires, so the remaining doubt moved to
  the spec doc a pack author reads

**What a pack author sees.** The channel FIRES — that half is closed. What a pack cannot tell is
whether a firing means a pal that did not exist a moment ago. Every firing observed so far landed in
the same second as `world.ready`, i.e. the load storm, when every pal in range initialises at once.

**What is still unknown**, the marker verbatim:

```text
TODO(pal-spawned-fresh): unknown whether it fires for a pal that is genuinely NEW. Every
firing observed so far landed in the same second as world.ready, i.e. the load storm, when
every pal in range initialises at once. That proves the hook works and says nothing about
the case a pack actually cares about — a pal that did not exist a moment ago. The two look
identical from here because only the FIRST firing per channel is announced.
To settle it: release a pal from the box well after the world has loaded, or let a wild one
stream in while travelling, and watch for a pal.spawned line whose timestamp is nowhere
near world.ready.
```

The arming constraint that produced this item still holds and is recorded in `core/event.lua`: the
broadcaster fires in the world-load pal-init storm and wedged the SHARED hook dispatch, taking the
confirmed hooks down with it, so these sources are armed only after `world.ready` and never at
`start()`. Keep handlers idempotent. There is also a `SPAWN_DEDUPE_SEC = 1.0` window on the emit.

The hook subscribes to the channel `core/event` already feeds and **arms no new hook of its own**,
then timestamps every firing against `world.ready`. It prints a marker line before each of three
operator actions, done one at a time: release a pal from the palbox, hatch an egg or trigger a wild
spawn by travelling, `pf_spawn`.

⚠️ Do NOT re-probe `PalCharacter:BroadcastOnCompleteInitializeParameter`. It is MEASURED SILENT, and
hooking a broadcaster instead of the bound target is the mistake this whole family of items exists
to record.

---

## How to close one

Every Open item has a declared hook. That is what replaced the old "press F1 and read the log"
instructions.

1. **Turn the gates on.** `env.debug = true` loads `test/hooks/` at all; `tools/deploy.sh` (default
   mode) writes a `Scripts/palforge_dev.lua` that sets `dev` and `debug` for you. If the hook
   declares `writes = true` it additionally needs `env.debugHooks["<id>"] = true` — nothing that
   mutates a character, an inventory or the world runs off `debug` alone, because `debug` is a
   session-wide switch and a write is a per-experiment decision taken on a throwaway save.
2. **Run it by name.** `pf_hook <id>` from the UE4SS console; `pf_hooks` first if you want to see
   every hook's gate state and the sentence that would open it; `pf_hook_<id_with_underscores>`
   from `autorun.txt`, because `core/autorun.lua` reads `[delay] name` and cannot carry an argument.
3. **Paste the block.** Output is bracketed `#### BEGIN <id>` / `#### END <id>`, so a block lifts
   out of `UE4SS.log` straight into this file. A hook that keeps watching after its body returns
   prints further blocks of its own, `-1`, `-2`, …
4. **Implement, then re-check.** **F1** re-runs the API suite; **F9** reloads every palforge module
   without restarting. ⚠️ A green F1 is not a green suite — a check belongs to one of THREE
   environments (headless, title screen, loaded save) and one press measures one of them; see
   *Owed work §3*. ⚠️ While a hook's watcher is alive **F9 is refused by name** — every poller
   brackets itself with `core/reload`'s async guard. That is the guard working. It clears when the
   watcher retires, at its own 180 s cap, or from the Lua console with
   `require('palforge.core.reload').asyncReset()`. Deploy, then run the hook; not the reverse.
5. **Move the item out of this file — and fix its `doc =` string in the api file at the same time.**
   Then run `lua5.4 tools/gen-types.lua` from the repo root, because `Scripts/palforge/types.lua` is
   generated from those strings and is also the IDE tooltip. This step exists because four closed
   items were once still described as dead in their own spec docs; a pack author reading a stale
   `doc =` string routes around a channel that works, which costs exactly as much as the channel not
   working.

### The hooks

**25** declared under `Scripts/palforge/test/hooks/`, loaded only when `env.debug` is true, never run
unless asked for by name. `pf_hooks` lists them, `pf_hook <id>` runs one, `pf_hooks_all` runs every
one whose gate is open, read-only ones first. This table is how someone runs a measurement.

| hook | writes | run? | what it owns |
| --- | --- | --- | --- |
| `pal-skills-equip` | ✔ | | **Before publish — the publish blocker** |
| `item-datatable-row-read` | | | Open / Item — the recipe row |
| `item-satiety-write` | ✔ | | Open / Item — the `SetFullStomach` parameter list |
| `skill-hit-source` | | | Open / Skill — confirms the negative |
| `skill-projectile-spawn` | ✔ | | Open / Skill — whether a struct marshals at all |
| `audio-custom-file-loader` | | | Open / Audio |
| `ui-update-event` | | | Open / UI |
| `pal-spawned-fresh` | | | Open / Events |
| `pal-spawn-persisted` | ✔ | | Open / Events — whether a spawned pal carries a per-individual id, and whether it reaches `CharacterSaveParameterMap`. `core/ledger.lua` declares a `pal` kind that nothing writes and pointed at this hook while it did not exist; a run of nils closes the kind. ⚠️ a spawn cannot be taken back (`RECLAIM` records `pal` as `can = false`) — throwaway save |
| `game-build-live` | | **✓×2** | which call carries PALWORLD's build string — `DisplayVersion` does, the three Kismet ones do not |
| `keymap-key-coverage` | | **✓** | the only hook with **no `needs` at all** — 4 pass / 0 fail, run 1 |
| `mesh-actor-identity` | | **✓×2** | the per-actor keying premise, confirmed on two actor classes |
| `building-record-orphans` | | **✓** | the store's quarantine round trip, ~35 s after load — run 1 found a per-save id and no file to round-trip yet |
| `store-base-load-cost` | | | **what a real base costs the store to load**, against a synthetic cost table |
| `store-save-roundtrip` | ✔ | | **does a real save's store survive a real world load** |
| `store-crash-recovery` | ✔ | | the four-row recovery table, on NTFS instead of on paper |
| `save-survives-pack-removal` | ✔ | | **the question the whole store pass was started for** |
| `building-actor-streaming` | | | **does `FindAllOf` stop returning a base the player left**, and at what distance |
| `building-runtime-reload` | | | the one hook whose measurement spans an F9 |
| `mesh-texture-import-live` | | | `ImportFileAsTexture2D`, the call that has never once been made |
| `mesh-color-change` | ✔ | | the colour nobody has watched change |
| `audio-setvolume-audible` | | | deliberately not `writes`: it makes noise, not a save edit |
| `building-unlock` | ✔ | | unverifiable by construction — see *Owed work §2* |
| `ui-host-layer` | | | *Owed work §2* |
| `ui-backhandler` | | | *Owed work §2* |

**Five of the twenty-four have been run**, across two sessions on 2026-08-02, all from `autorun.txt`
rather than a key or the console — which is the third input route working end to end after a key and
a console had each failed a session. What each returned is in this file's header and under its item.

**Eight declare `writes = true`.** Three of the unticked ones change something anyway and say so in
their own headers, because `writes` means "a save is mutated" and nothing weaker:
`audio-setvolume-audible` makes the game loud and then quiet again, `mesh-texture-import-live`
allocates a `UTexture2D` nothing in this process can destroy and writes an 82-byte PNG next to
itself, and `building-runtime-reload` leaves five channel subscriptions and a `__scanPump` wrapper
behind until its next run takes them back.

⚠️ **The three store writers stretch that definition deliberately.** None of them touches Palworld's
save; they create, corrupt and rewrite files under `<Mods>/PalForge/state/`. They declare `writes`
anyway, because the claim being defended is that PalForge is careful with the files under its own
directory, and a hook that made files in a player's `state/` because somebody left `env.debug` on in
a dev overlay would be the first counter-example. Between them they use exactly two pack ids —
`pf_probe` and `pf_crash`, and no real pack may be called either — and each ends by printing the
absolute path of everything it left and the single call that removes it.

A silent skip is the failure mode this tree has been bitten by three times — a probe on Palworld's
own volume key that bound successfully and never fired, a console command registered into a window
UE4SS ships switched off, and a test that skipped for want of a world and reported the same
"0 failed" as a test that ran. So every refusal here names the gate and says the sentence that opens
it, and every "this needs the game" skip in the F1 suite names the hook that measures it. The `item`
column is not prose — it is each hook's own `item =` field, printed by `pf_hooks` and by every
`pf_hook` run, and all of them are spelled `Open / <domain>` with no count, which is the spelling
that cannot go stale the next time an item closes.

### Keys, the console, and autorun.txt

Nine keys, bound only in a dev session (`env.dev`), from `test/init.lua` (F1 and the six probes),
`core/keyboard/functions/f4_unlock.lua` (F4) and `core/registry.lua` (F9).

| Key | What it does | What you need on screen |
| --- | --- | --- |
| F1 | The API test suite — 19 suites | Anything, but see *Owed work §3* |
| F2 | Title-screen widgets | The title screen |
| F3 | The title-menu button's inner slot, read from a world | A loaded save |
| F4 | Unlock all technologies (`utils.items.unlockAllTech`) | A loaded save |
| F5 | Reflection dump: classes, functions, parameters, DataTable rows | A loaded save |
| F6 | Everything that needs a live pal: mesh, animation, materials | A pal near you |
| F8 | Arms hooks and watches for 60 s while you act | A save, then craft / drop / spawn |
| F9 | Reload every palforge module without restarting the game | Anything |
| F10 | Counts the four UI-rebuild hooks, across a whole world load | A save, then quit to title |

F4 and F8 are the two that change anything, and F8 says so before it arms a hook. F8 also holds the
async guard for its whole 60 s window, so F9 is refused until it retires.

F7 is deliberately unbound: **it is Palworld's own volume key**, and the game claims it before UE4SS
sees it, so a probe bound there can never be pressed. `registory.register` now consults the keymap
before binding and prints the verdict on the `bound <KEY>` line itself (`free` / `game` / `unknown`).
⚠️ `free` is not a promise the press arrives — the Steam overlay, the OS and UE's own console keys
are all outside Palworld's key config. **F1 is the only key that has ever been pressed**; everything
else that has run came through `autorun.txt`.

`test/init.lua` registers **18** console actions with `env.debug` off and **42** with it on (one
generated `pf_hook_<id>` per declared hook, so that number moves with the table above). The fifteen
that are not hook plumbing:

```text
pf_tests   pf_keys    pf_spawn    pf_mesh     pf_teach
pf_native  pf_uidecl  pf_uiroute  pf_uiz
pf_reflect pf_pal     pf_watch    pf_title    pf_uislot   pf_uievents
```

**`pf_keys` first when a key does not arrive.** It crosses PalForge's own bindings against the
game's key config and prints, per key, `game` / `free` / `palforge` / `refused` / `unknown`.
**UE4SS ships with its console OFF**, and a command registers perfectly well into a window that does
not exist — the same failure the console was meant to escape, one layer down. Turn it on in
`ue4ss/UE4SS-settings.ini` (`ConsoleEnabled`, `GuiConsoleEnabled`, `GuiConsoleVisible` = 1) and
restart.

When neither works, `Scripts/palforge/autorun.txt` runs named actions on world.ready — no key, no
console, nothing to press:

```text
pf_spawn                        # as soon as the world is ready
20 pf_teach                     # 20 seconds after
30 pf_hook_mesh_actor_identity  # a hook, by its generated name
```

`core/autorun.lua` holds no table of its own: `install()` hands it one through `setActions`, and it
warns when a name has no match. Only names already in that table can run; it reads a list of names,
never code.

---

## Owed work

### 1. Small, and each one has a decision behind it

- **`Skill.Handle:activate` discards the handler's return, and stamps the cooldown first.**
  `api/skill.lua:435` returns `pcall`'s ok, so a raising handler also leaves a cooldown behind. The
  doc string is honest about what `true` means; what a boolean cannot express is "ran and produced
  nothing", which is the case `skill-projectile-spawn` is in. If `activate` is ever made to consult
  the handler's return, that is the distinction it should carry.
- **Three constructors hand-roll their `opts` parsing.** `api/building.lua:459`, `api/mesh.lua:219`
  and `api/ui.lua:1412` read `register`/`pack` inline instead of calling `schema.defineOpts` the way
  the other five domains do (`api/audio.lua:248`, `effect.lua:342`, `item.lua:278`, `pal.lua:322`,
  `skill.lua:363`), so a misspelled option key — `{ regsiter = false }` — is silently ignored where
  the others raise. For Building that means a typo'd read starts persisting a save record for every
  matching actor, which is the exact failure the `register = false` gate exists to prevent. One line
  each; all three already require `schema`.
- **`om.checkImport` has no producer.** `core/object_manager.lua:371` consumes an optional
  `opts.refs`, and grep finds no domain that passes it, so cross-pack references are offered and
  unchecked. Object_manager cannot know which fields of a spec are id references; the api
  constructors are the only layer that does. `om.declareDeps` already gives the dependency set a
  memory, fed by `api.pack(id, { depends = ... })`, so no call site would have to carry a manifest.
- **`core/schema` has no `undefine`.** `test/cases/schema.lua` leaves **8** namespaced specs behind
  on every F1 press — `Inner`, `Spec`, `Dup`, `Derived`, `ReqDefault`, `FnDefault`, `Untyped`,
  `Checked`. Inert (nothing walks the spec list per lookup) and documented at
  `test/cases/schema.lua:29-32`, but `test/support.lua`'s `sweep()` cannot reach it.
- **The five store case files each build their own harness.** `store_api`, `store_codec`,
  `store_disk`, `store_runtime` and `store_state` separately write an in-memory or on-disk I/O
  table (`fakeIO` / `memIO` / `diskIO`), their own scratch-directory naming and teardown, and their
  own `withStore` / `withHarness` / `withDisk` bracket. Four of the five want the same two things: a
  fake backend and a world snapshot restored afterwards. That belongs in `test/support.lua` beside
  `sweepAfter`, and until it does, a change to the store's I/O seam is five edits.
- **The value guard encodes every record's `state` twice per flush.** `utils/json`'s `validate` ends
  by encoding the value to measure it against the 64 KiB limit, and then `partition` encodes it
  again into the document — stated in `core/state.lua:806`, where the cost is argued to be
  acceptable (a handful of fields, at most every 10 s, only while dirty) against the alternative of
  a whole pack's file failing on one bad record. It is still work owed: `validate` returning the
  encoded text it already produced would remove the second pass without changing any behaviour.
- **`schema.derive` does not carry a `validate` override, and two things depend on it.**
  `Building.Spec.Mesh` is derived from `Mesh.Spec`, and `derive` copies field descriptors into a new
  spec object — so an inline `Building{ mesh = {...} }` gets neither `resolvePackPath` on `model` /
  `texture` (a named `Mesh{...}` handle does) nor the `SM_`-meets-`skeletal` warning. Separately,
  `core/mesh/init.lua:265`'s `validateDeclared` walks `om.all("mesh")` only, so the same inline
  meshes are outside the world.ready validation pass and are reported by the scan's render path
  instead. Fix is one of: `derive` rawsets `validate`, or `api/building` delegates. Both halves are
  stated in the two files' comments.
- **`Handle:iconOf` still misses on the blueprint spelling.** The two-spellings-per-creature trap is
  data now, not prose — `native/pals.lua:264` carries `M.ROW_ID = { SheepBall = "Sheepball" }` and
  `M.iconOf` (`:272`) consults it, with the same split on `WorkBench`/`Workbench` in
  `native/buildings.lua` — but that is catalog-level. `pals.SheepBall:iconOf()` still misses because
  the icon table is keyed on the DataTable row spelling. Closing it on the handle needs a
  `Spec.iconId` field read by `Class:iconOf`.
- **`db.reclaim()` reports but does not undo.** `core/state.lua:1527` names every ledgered id, says
  whether each is reclaimable and why, and then marks the reclaimable ones
  `not attempted (no reclaim driver on this build)`. The doing half needs `api/item`'s take and
  `core/character`'s `RemovePassiveSkill`, and `core/state` may require nothing from `api/` — that is
  what keeps the dependency graph acyclic. The store delivers reclaim's *input*.
- ⚠️ **`core.state` is not in `core/reload.lua`'s `KEEP`** (`:82-87` holds four entries: `env`,
  `utils.log`, `core.reload`, `core.object_manager`). It survives F9 only because its state lives on
  `_G.__PalForgeState`. If anyone ever moves that off `_G`, `palforge.core.state` must go into KEEP
  or the runtime will re-persist empty records over a live base.
- **`env.lua:64-74`'s comment is now stale in the reader's favour and should be corrected.** It ends
  "until one run prints it, the value below is checked by a human comparing it with that corner of
  the title screen and by nothing else". A run has printed it: `game-build-live` answered
  `"v1.0.2.101103"` from both `PalGameInstance.DisplayVersion` and `PalUtility.GetDisplayVersion`,
  matching `gameBuild` (`:75`). `env.gameBuild` is a verifiable claim now, and the header should say
  so.

### 2. Declared, shipped, and never once observed working

Each is honestly labelled in the source, each has a hook, and **none is closed until the hook is
run.** A hook that exists is an instrument, not a measurement.

- **The store has never written a byte for a save Palworld loaded.** Four hooks:
  `store-save-roundtrip` (⚠️ it deliberately leaves its file behind, because the round trip that
  matters is the second run — quit to the title, load the same save, run it again, and it reads what
  the first run wrote across a world teardown, which is the trip a pack's own `onLoad` makes);
  `store-crash-recovery` (⚠️ needs a **fresh session** — `core/state` reads a pack's file at most
  once per world, so run it first after a load or it refuses by name); `store-base-load-cost`
  (⚠️ in a stock session the honest answer is **zero bytes and zero milliseconds**, because no
  building definition is registered, and that IS the result); and `save-survives-pack-removal`,
  which is the question the store pass was started for. Everything readable off the binary says a
  save holding a pack-owned FName with no DataTable row behind it is a **missing lookup, not a
  broken file** — the save stores plain `FName`s, rows resolve through accessors built to fail
  (`TryGetStaticItemData` → bool; the whole `BP_FindRow(row, bool&)` family), and
  `EPalSaveError { Success, NotFound, Unknown, Broken, OutOfMemory }` has no "unknown content"
  member — **but nobody has loaded such a save, so that is well-founded and NOT PROVEN.** The load
  path is unreflected C++ (`FPalBinaryMemory`): there is nothing to `signature.describe` and no
  UFunction to hook, so it is empirical or it is nothing.
- **Whether Palworld streams a base's actors out of memory is unmeasured, and it decides whether a
  fix was a catastrophe averted or a latent bug closed.** `core/event.lua`'s miss sweep counts, per
  live instance, the consecutive scans in which `FindAllOf("PalBuildObject")` did not return that
  instance's actor, and past `MISS_THRESHOLD = 6` — three seconds at `SCAN_MS = 500` — it used to
  DELETE the record. It now quarantines instead, and the scan's bind path restores on sight. The
  structural evidence for streaming, all read out of `dumps/` and none of it measured: a persistent
  `Model` separate from a transient `ConcreteModel` (`FPalMapObjectSaveData`, `Pal.hpp:4639`);
  `OnAvailableConcreteModel` / `OnNotAvailableConcreteModel` delegate **pairs** on about ten classes
  (`Pal.hpp:14252-14699`); `TryGetConcreteModel` with a `Failed = 1` out-pin
  (`Pal_enums.hpp:2853-2857`); `UPalMapObjectConcreteModelBase:bDisposed`. `pf_hook
  building-actor-streaming` samples once a second for 180 s and **the answer is the distance at
  which the count first drops**. Standing still for two minutes is also a result — it is the control.
  **This decides whether the release note says "fixed" or "hardened".**
- **The F9 building-runtime fix has never been done in a game** — `pf_hook
  building-runtime-reload`, run once BEFORE the press and once after. It measures three parts
  separately so a partial failure is attributable: that the `object_manager` module table survives
  the wipe still holding the same building ids; that the table the SCAN closes over and the table
  the DISPATCH resolves against are one table, read out of the live closures with
  `debug.getupvalue`; and that `pump()` re-entry happened, via a witness wrapper whose call count
  the NEXT run reads. It arms **no poller**, deliberately: every `core/poll` poller brackets itself
  with the async guard, so a hook with a watcher would refuse the very F9 it is asking for.
  ⚠️ Two halves of the obvious procedure are **not measurable in a stock session** and the hook
  refuses them by name rather than faking them: `Building.Handle:instances()` is empty before *and*
  after the press because no building definition is registered, so the defect and the fix look
  identical; and `onTick` is unreachable even after publishing one, because `Registry.tickList`
  holds only instances whose class *overrides* `onTick` and neither curated building declares one.
- **`ImportFileAsTexture2D` has still never been called** — `pf_hook mesh-texture-import-live`. It
  writes an 82-byte 8×8 PNG next to itself first, so "the import failed" can never mean "there was
  no file"; attempts the import once BEFORE the file exists, so positives-only-with-retry is stated
  as an observation rather than as a code reading; and decides the cache with `rawequal` on the
  return of **`Renderer.resolveTexture`**, not of `importTexture` — the cache lives inside
  `importTexture` while the per-attach call site is `resolveTexture`, and a cache the real call site
  did not reach would be a cache in name only. ⚠️ A successful run allocates **one `UTexture2D` that
  nothing in this process can destroy**: there is no `AddToRoot`, no `FGCObject` and no destroy in
  UE4SS's Lua layer, and a weak-*valued* cache does not shorten a texture's life. One 8×8 is
  nothing; a loop doing this is exactly the leak the cache is about.
- **A colour has never been watched changing** — `pf_hook mesh-color-change` (writes). The parameter
  names are measured; `api/pal.lua`'s `renderOn` is explicit that a `true` means the write ran.
- **`setVolume` has never been heard** — `pf_hook audio-setvolume-audible`. It plays one SE at bus
  volume 1.0 / 0.25 / 0.0 / 1.0, always restoring unity, and proves `:play` first so silence is
  attributable.
- **`Building.Handle:unlock()` is unverifiable by construction** — there is no "is it unlocked"
  accessor. `pf_hook building-unlock` (writes, no undo) records everything establishable —
  cheat-manager existence, `UnlockOneTechnology`'s live declaration, the row precondition (115 of
  501 vanilla ids have one), the call's return — and hands the rest to a human looking at the build
  menu. Its doc string says `true` means "issued, and a technology row of that name exists", not
  "unlocked". ⚠️ **A technology unlock can never be undone on this build**: `UPalCheatManager`
  declares four unlocks and no lock, and `LockTechnology|RemoveTechnology|ResetTechnology|
  ForgetTechnology` have zero hits across all 1579 headers in `dumps/cxx/`.
- **`UI.Spec.host = "layer"` and `backHandler = true`** — `pf_hook ui-host-layer`,
  `pf_hook ui-backhandler`. Both are now refused at define time without a `Frame` root. Both hooks
  declare `input = "clicks"` on the panel they mount and print the applied input grab as a `VALUE`
  line, so running either one measures that on the way past. **`input = "exclusive"` is the one
  declared surface in this file with no hook at all**; nothing in `test/hooks/` mounts it, and
  closing it means declaring one, not running one.
- ⚠️ **`Pal:spawn` issued and delivered nothing, three times in one press, and it is unexplained.**
  `pal-spawnmonster-signature` was closed on one observed arrival (2026-07-26, ~5.9 s). On
  2026-08-02 16:40:13 the in-save suite issued `spawn.pal(world) ChickenPal (lv 1)` with
  `[evidence declared]` and 12 s later logged `the call ran but NO new PalCharacter appeared in
  12.1 s (26 looks)`, then twice more from `spawn.palAt` with `nothing in the world was absent from
  the pre-spawn snapshot`. The 12 s window is not the reason and the signature still matched, so
  what this does NOT overturn is the parameter list. It belongs to whoever next runs a spawn, and it
  is a reason to re-run rather than a reopening.

### 3. Test blind spots that remain

**The three-environment model is confirmed and needs no further argument.** A check belongs to one
of headless / title screen / loaded save; run 2 predicted `444 / 0 / 37` at the title screen and
`466 / 0 / 15` in a save out of 481 and **both landed exactly**, which is the strongest form the
claim could take. What a future run should compare is the **skip structure**, not the totals:
**28 need a world, 1 needs a declared hook, 3 could not be answered by the session** — re-measured
headlessly on 2026-08-02 at `548 passed / 0 failed / 32 skipped (580)`.

- **The minimum full measurement is TWO runs, and neither of them is the pair the summary suggests.**
  A headless `lua5.4` run covers the eight no-engine checks and the four no-world ones (there is no
  world in a bare Lua process either); one F1 in a loaded save covers the world-gated 28 and the two
  the session could not answer. The title-screen press remains useful — it is the only one that
  exercises the game's no-world path with a real engine under it — but it measures nothing the
  headless run does not. Re-run headless with:

  ```sh
  cd Scripts && lua5.4 -e 'package.path="./?.lua;./?/init.lua;"..package.path;
    local e=require("palforge.env") e.dev=true e.debug=true
    local t=require("palforge.test") t.install() t.run()'
  ```

- **One gating axis is outside the environment model entirely, so no number of runs covers it.**
  `core/unittests` declares eight `NEEDS` directions (world, no-world, no-engine, hook, opt-in,
  setup, session, unstated), of which three are ENVIRONMENTS. `test/cases/ui.lua`'s `ownStack`
  (`:1184`, used by four checks) is none of them: it gates on *stack emptiness*, so it skips in any
  session where something is already mounted, and `pf_uiz` leaves three panels up.

### 4. Two design decisions this tree deliberately has not taken

Both were found while fixing something else, both are behaviour changes rather than corrections, and
both are cheaper to decide now than after other people's packs exist.

- **`utils/items` cannot construct a cheat manager; `core/spawn` can.** `core/spawn.lua` builds one
  from the controller's `CheatClass` (falling back to `/Script/Pal.PalCheatManager` then
  `/Script/Engine.CheatManager`), which is why `CheatManagerEnablerMod` is *optional* for a spawn.
  `utils/items`' own `cheatManager()` (`utils/items/init.lua:354`) asserts instead, so `unlockTech`
  refuses in a session shape that `:spawn` handles. The divergence is documented at all four sites
  rather than changed; promoting `core/spawn`'s constructor to a shared helper is the fix, and it
  changes behaviour.
- **F9 is refused while any poller is alive**, because `core/poll` declares every poller to the
  async guard. `native/ui/_widget`'s "ui input dead-man" lives as long as a panel holds input, so F9
  with a panel open is refused and names it. There is a 180 s stale cap and
  `require('palforge.core.reload').asyncReset()`. If that proves too sticky the fix is an opt-out
  flag on `poll.every` plus a caller change — deliberately not taken on a sweep.

---

## Do not re-measure

Negatives and traps that cost a session each. One line apiece, naming where the full measurement
lives. Nothing here is a task; it is here so nobody probes it a second time.

**Things that do not exist on this build.**

- `FApp::GetProjectVersion` — zero hits across all 1579 headers in `dumps/cxx/`.
- The three `UKismetSystemLibrary` build strings carry **Unreal's** identity, never Palworld's:
  `GetBuildVersion` = `"++UE5+Release-5.1-CL-0"`, `GetEngineVersion` = `"5.1.1-0+++UE5+Release-5.1"`,
  `GetGameName` = `"Pal"`. Palworld's own is `UPalGameInstance::DisplayVersion` /
  `UPalUtility::GetDisplayVersion(world)`, both of which need a live `UPalGameInstance` and are
  therefore read at the first `world.ready`, not at startup. See `env.lua` and `main.lua`.
- No lock/relock for a technology: `LockTechnology|RemoveTechnology|ResetTechnology|
  ForgetTechnology`, zero hits in `dumps/cxx/`.
- No click, hit, attack, destroy, dismantle or break entry on `PalBuildObject` (22 functions),
  `PalMapObjectModel` (18), `PalMapObjectConcreteModelBase` (25) or `PalNetworkPlayerComponent`
  (77). Destruction exists only as delegate **fields**, which `RegisterHook` cannot address by path;
  disappearance surfaces as `onRemove` with reason `"missing"`. The standing `onDamage` candidate is
  the deterioration timer — 196 firings on a strict 12–13 s cadence per structure, with no player
  involved. See `core/event.lua`.
- `UPalUIManagerSubsystem` declares **zero** functions. `api/ui.lua`'s marker says not to enumerate
  it again.
- No reflected `GetStaticMesh` anywhere in the dump (the asset is reachable only as the UProperty
  `StaticMesh`), and no `actor:GetMesh()` — the two skeletal mesh setters are inherited by the SAME
  component, so the second was never a fallback. See `core/mesh/static.lua`, `skeletal.lua`.
- `UPalUIHUDLayoutBase` has **no widget members at all** — the child "one level down" everyone was
  looking for never existed; it exposes `AddHUD`. The real host is
  `WBP_PalOverallUILayout.CanvasPanel_Root`, a `UCanvasPanel` and therefore a `UPanelWidget`. See
  `native/ui/`.
- A `CanvasPanelSlot` declares no `SetHorizontalAlignment` (`UMG.hpp:350-374`) where the other five
  slot classes do, so a title-menu button's label can never be aligned that way. A left-aligned
  label routes through `_widget.clickableRow`'s Overlay instead.
- Exactly **three** `AkRtpc` assets exist — `Supply_Altitude`, `OverHeatRifle`,
  `ChargeLaserRifle_01` — plus zero `AkAuxBus` and zero `AkAudioBank`. None is a volume, so the RTPC
  route to `setVolume` had no parameter to address and no parameter list would have helped. The
  capability lives on `UAkGameplayStatics::SetOutputBusVolume(float, AActor*)`, whose second
  argument is the Wwise **game object**, not a bus name.

**Traps that made a working read look broken.**

- **UE4SS mints a fresh userdata per lookup**, so two references to one UObject are not the same Lua
  value and no metamethod can rescue a table keyed on one. **Confirmed in game twice** on two actor
  classes (`BP_BuildObject_WorkBench_C`, run 1; `BP_BuildObject_ItemChest_C_2147468363`, run 2 at
  17:37:57.5 and 17:38:05.2): the handle key MISSES, the `GetFullName` key HITS, `rawequal` is false
  and `uo.same` is true. Every per-object table in the live tree is keyed on `uo.key(o)`, with the
  handle in the record's value and `uo.same` for comparison. `core/uobject.lua` is the only key
  helper and there is deliberately no second one.
- **Row values arrive wrapped.** A `GetDataTableColumnAsString` array delivers its elements as
  `RemoteUnrealParam`, with the real value behind `:get()` — which is what made an icon array read
  the right LENGTH with nothing in it. And a `TSoftObjectPtr` userdata answers none of the nineteen
  member names a soft pointer could plausibly expose, so the struct cannot be opened from Lua. See
  `core/icons.lua:317-339`.
- **`UDataTable`'s row accessors are not UFunctions.** UE4SS binds `FindRow` / `GetRowNames` /
  `GetRowMap` / `GetAllRows` / `ForEachRow` onto the class itself, which is why every reflection
  sweep missed them.
- **`EPal*` parameters are declared `EnumProperty`, not `ByteProperty`** — an `enum class`, not a
  legacy `enum`. `core/signature.lua` refused three correct calls over that spelling until it
  learned the two marshal identically.
- **A struct ARGUMENT faults inside UE4SS's marshalling where `pcall` cannot see it.** That is what
  gates `core/spawn.lua`'s `M.actor`, what killed the button-alignment call, and what
  `skill-projectile-spawn` is about. A struct RETURN is not the same hazard.
- **The header dump can lag the installed binary by a patch.** `AddItem` declared five parameters
  where `dumps/cxx/Pal.hpp` had four; UE4SS also counts the return as a slot, which is where
  "expected 6 parameters, received 4" came from. This is why `env.gameBuild` is declared at all.
- **A write measured too early looks exactly like a write that never happened.** `SpawnMonster`
  works; the "nothing spawned" verdict came from a stopwatch stopped at 1.2 s on a ~5.9 s arrival.
  `:spawn` now returns whether the call was ISSUED and the arrival line follows in the log. (See
  *Owed work §2* for the run-2 anomaly this does not explain.)
- **`RegisterHook` sees what `ProcessEvent` runs, and a broadcaster is not it.** The initialise
  broadcast's bound targets (`PalNPC:OnCompletedInitParam`,
  `PalPlayerCharacter:OnCompleteInitializeParameter`) carry; the broadcaster registered fine and
  never carried anything. Likewise a drop does not go through `AddItem_ServerInternal` — it goes
  through `UPalNetworkItemComponent`, one class over from everywhere the search had looked.
- **An id that names an engine enum is case-INsensitive; an id that names a DataTable row or a
  registry key is case-SENSITIVE.** Written into the headers of `core/character.lua`,
  `core/status.lua` and `core/icons.lua`, and onto the docs site.
- **`UObject:IsValid()` on this UE4SS is a real liveness check**, not a null check
  (`is_object_in_global_unreal_object_map(ptr) && !ptr->IsUnreachable()`), so it genuinely protects
  the world.ready → quit-to-title → load-another-save path. The residual risk is ABA, not plain
  staleness. `uo.live` is the one copy; two more remain in `core/keyboard/base/`, left alone because
  that layer is dependency-minimal by design.
- **Material parameter names are Title Case WITH SPACES** and could never have come from a header
  dump — they are data inside a `.uasset`, read off the running game on 2026-07-26: vector
  `BaseColor`, `Subsurface Color`; texture `Base Texture`,
  `MetallicRoughnessOcclusionSpecularTexture`, `Normal Map`, `Subsurface Texture`; five scalars.
  Only two of the eleven are in `Renderer.TEXTURE_PARAMS`; the rest are reachable through `params`
  only. A material that is currently RENDERING is cooked and shipped by construction, which is why
  the player's own outfit instance leads the base-material candidate list.
- **Icon columns differ per table**: items and pals use `Icon`, buildings `SoftIcon`, partner skills
  `TextureID_8_2B2F...`. `IconName`, `IconTexture` and `Texture` are columns of no icon table on this
  build. The partner-skill table is keyed by **pal** id, not skill id, so only a pal-derived partner
  skill can hit it.
- **`skill.unequip` has never been recorded firing from any source.** `skill.equip` carried from
  `AddPassiveSkill` — including PalForge's own writes, which is a useful property — but "observed"
  belongs only to equip, and `api/skill.lua` and the docs both say exactly that. Which call the GAME
  uses when a player changes a passive at a bench is also unsettled; `SetupSkillFromSelf` stays armed
  beside it and has carried nothing yet.
- **`test/probes/reflect.lua:950` emits a block under `pal-spawn-at-location`, an id this file has
  never carried.** Resolved as keep-and-declare: the block opens with
  `⚠️ PROPOSAL — plan/TODO.md has NEVER carried this id`, because renaming it onto either settled
  spawn id would emit a block for a closed item and invite an accidental reopen. Whoever files it
  owns the name.
