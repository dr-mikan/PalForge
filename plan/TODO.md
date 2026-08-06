# PalForge — what is still open

Everything in this file is something a reader must still **do**. Work that is finished *and
verified* has been deleted from here; the measurement that shaped it lives in the source comment
the fix is in, which is where someone changing that code will actually meet it.

**The standard, stated once, because it is the reason eight items moved on 2026-08-02.** An item
does not close because the fact behind it became known. It closes when the capability is
**implemented, reproducible, and usable from another library** — a pack author can call it, the
call does what its `doc =` string says, and a second run gets the same answer. A settled negative
closes the same way: implemented as a refusal that names its measurement, not as a note.

Sections:

- **Before publish** — empty. Nothing gates a public release any more; the paragraph there says
  what closed the last one and keeps the reason the item existed.
- **Open (1)** — `audio-setvolume-audible`, and it is hedged on purpose.
- **Implemented, never exercised by a game (7)** — shipped code no Palworld session has ever run.
  Each names the ONE action that settles it and says whether a release should wait. This is the
  list to read when deciding what the next session does.
- **What the running game found that reading never would** — two defects the hook regime caught
  that 553 headless checks could not, and one conclusion a later measurement overturned.
- **Owed work** — work that is simply not finished. Nothing in it waits on Palworld.
- **Do not re-measure** — the index of facts that cost a session each, including everything the
  eight closed items established. A *record*, not a task list.

⚠️ **`ue4ss/UE4SS.log` has rotated.** The in-game figures below were read out of it live, session by
session, and most of those lines no longer exist on disk. Nothing here is weakened by that and
nothing here should be re-derived from a log that no longer holds it.

---

## Where the tree stands

Re-measured on 2026-08-03 while this file was rewritten, with `lua5.4`, `luac5.4` and `grep`:

- **Headless suite: 577 passed / 0 failed / 35 skipped (612 total)**; boot bundle **8 / 0 / 0**.
  The skips are directed: **31 need a world, 1 needs a declared hook, 3 could not be answered by
  the session**. That is the figure with `test.install()` run first, which is the F1 route and
  what CI's `npm run check` does NOT do: `npm test` alone prints **576 / 0 / 36**, because the
  boot bundle answers the one check that otherwise reports "needs a declared hook". Both are
  correct; quote whichever matches the command being shown.
- The same suite under **simulated in-game conditions** (the UI rebuild signal armed, three
  buildings published): **558 / 0 / 54** out of the same 612, recorded 2026-08-02 after the four
  in-game failures of 23:33 were fixed.
- `luac5.4 -p` clean on all **161** `.lua` files under `Scripts/` and `tools/` — 31 of them under
  `palforge/deprecated/`, which no deploy ships. `bash -n tools/deploy.sh` clean.
- **26 declared hooks**, **12** of which declare `writes = true`. `test/init.lua` registers **18**
  console actions with `env.debug` off and **44** with it on — the difference is one generated
  `pf_hook_<id>` per hook (`test/init.lua:207` for the static table, `:1132` for the six probes,
  `:1154` for the hooks).
- **No `-- TODO(<id>)` marker in `Scripts/` names an item this file carries.** The five that still
  did on 2026-08-02 — `item-datatable-row-read`, `item-satiety-write`, `pal-skills-equip`,
  `pal-spawned-fresh`, `skill-projectile-spawn` — went out with their items. The one Open item never
  had one, because nothing in the code is waiting on it: the call is written, issued and documented,
  and the doubt is about what a human heard.

---

## Before publish

**Nothing.** The list is empty, and it emptied on 2026-08-02 at 22:07.

`pal-skills-equip` was the last blocker, and it was a blocker for a reason none of the others
shared: `Skill.Handle:teach` **writes into a character in a real save**, and the first run that did
it was followed 1.4 seconds later by Palworld closing. **The target was the suspect, never the
write** — `FindAllOf("PalCharacter")` is too wide (`APalMonsterCharacter : APalNPC : APalCharacter`,
so it matches villagers and merchants), an NPC has no equipped move, and putting an equipped MOVE on
a villager is a far more plausible way to destabilise the game than putting one on a pal. That is
worth keeping written down, because a future reader who meets the crash in the git history will
otherwise re-fear the write itself.

The hook now asks `PalMonsterCharacter` and refuses to write unless `uo.isA(target,
"PalMonsterCharacter")`. On a real save it returned **8 pass / 0 fail**: `addSkill Human_Punch
(EPalWazaID 1) [declared] -> equipped`, read back on a live `PalMonsterCharacter`; `:forget` took it
off; `teachAll(pal)` answered `2, 2`; `ClearEquipWaza` ran and every move it removed was restored
and verified. **The game stayed up.**

The write stays opt-in anyway — `env.debugHooks["pal-skills-equip"] = true` on top of `env.debug` —
because a per-experiment decision on a throwaway save is the right shape for anything that mutates a
character, not because the outcome is in doubt.

### Cutting one

Push a tag and `.github/workflows/release.yml` does the rest:

```
git tag v0.3.0 && git push origin v0.3.0
```

It runs `npm run check` (syntax sweep → headless suite → `types.lua` freshness → docs content lint),
refuses a tag that disagrees with `package.json`'s version, builds the archive with
`tools/deploy.sh --package` — **the same script that deploys to a real install**, so what people
download is not a second definition of "what ships" — and publishes `PalForge-v0.3.0.zip` as a
GitHub Release. `workflow_dispatch` builds and uploads an artifact without publishing, which is how
to look at a build before committing to a tag.

Three assertions stand between the gate and the upload, and all three exist because the blast radius
is somebody else's save file: `palforge/test/` must not be in the archive, `palforge_dev.lua` must
not be in the archive, and the shipped `env.lua` must still read `dev = false` / `debug = false`.
`tools/deploy.sh --release` already removes all three; the workflow asserts it rather than trusting
it, because `dev = true` was once the shipped default here.

**Nexus Mods has no upload API** — the acceptable-use policy makes the public API read-only, so that
step is a human dragging the zip from the GitHub Release into the Nexus form. Nothing automates it
and nothing should pretend to.

---

## Open (1)

### `audio-setvolume-audible` — nobody has confirmed that anything got quieter

- **Hook:** `pf_hook audio-setvolume-audible` — needs a loaded save. Deliberately NOT `writes`: it
  makes noise, not a save edit.
- **Where the measurement lives:** `api/audio.lua:426-435`, in `Handle:setVolume`'s own doc string.

**What ran.** 2026-08-02 at 21:39: the same explosion four times, 8 s apart, at bus volume
**1.0 / 0.25 / 0.00 / 1.0**, with `setVolume` and `play` both returning true on all four and unity
restored at the end. Asked afterwards whether steps 2 and 3 were quieter, the operator answered —
twice, and hedged both times — that they seemed to be.

**⚠️ Volume 0.00 was not silent.** That is the fact, and it is the whole item.

**What that does NOT establish, in either direction.** A bus volume of zero that is still audible
has the same shape as `SpawnMonster` and `GetItem` once did — declared, issued, no effect — but
nothing has separated *the parameter never reaches the mixer* from *something else interfered*:
another emitter, the wrong actor's Wwise game object, or the explosion being posted somewhere other
than the object whose output bus was scaled. One hedged human observation is more than this call had
before (nobody had heard the parameter do anything at all) and it is not a verdict. **Do not upgrade
this item on the strength of the direction matching.**

**What it is not blocked on.** The native declaration is read and matched:
`UAkGameplayStatics::SetOutputBusVolume(float BusVolume, AActor* Actor)`
(`dumps/cxx/AkAudio.hpp:748`), actor-wide by construction, which is why *which* sound handle it was
called on is ignored. The narrower RTPC route is closed with evidence — see *Do not re-measure*.
`setVolume` returns true for **ISSUED** and its doc string says so in those words, so the shipped
surface is already honest about this.

**THE ONE ACTION THAT SETTLES IT.** Re-run the hook with the listener told **in advance** that the
question is *silence at step 3*, not loudness anywhere — with the game's own sliders at a known
position and nothing else audible. If 0.00 is silent, the item closes positive and the doc string
loses its hedge. If 0.00 is audible, the item becomes a different and answerable question — which
Wwise game object the sound was posted on — and that is a new hook, not this one.

---

## Implemented, never exercised by a game (7)

Everything here is shipped code with a hook pointing at it that **no Palworld session has ever
run to a result**. A hook that exists is an instrument, not a measurement. The table is the whole
decision; the notes under it are only what the action needs to be done correctly.

| what has never run | the ONE action that settles it | wait for it before publishing? |
| --- | --- | --- |
| `audio-setvolume-audible` | re-run the hook, listener briefed that the question is SILENCE at step 3 | **no** — `setVolume` already documents itself as ISSUED-only |
| `building-actor-streaming` | walk or fast-travel **well past 287 m** from a base while the hook samples, then come back | **no** — but it decides whether the release note says "fixed" or "hardened" |
| `building-runtime-reload` | run the hook, press **F9**, run it again in the same session | **no** — F9 is a dev-only path |
| `save-survives-pack-removal` | give a pack item in a save, quit, **remove the pack**, reload, run the hook | **recommended** — it is the question the whole store pass was started for |
| `pal-spawn-persisted` | on a throwaway save, run the hook once through (it now gets past its own first line) | **no** — ⚠️ a spawn cannot be taken back |
| `store-save-roundtrip`, run 2 | quit to title, load the **same** save, run the hook again | **cheap, and worth doing** — it is the trip a pack's `onLoad` makes |
| the UI load storm | arm `test/probes/uievents.lua` at world #1's `world.ready`, then load a save again | **no** — the consumer is bounded by construction |

- **`building-actor-streaming` has never produced a result, and both reasons are fixed in the
  hook.** It had nothing to watch (F-8: the catalogs declare without registering), so it now
  publishes the ids standing around it and retracts them when its window retires; and the operator
  walked to **287 m while all 7 structures stayed in `FindAllOf` for all 90 samples**, which is
  inside Palworld's streaming radius. The answer being looked for is **the distance at which the
  count first drops**. Standing still for two minutes is also a result — it is the control. The
  structural evidence for streaming (all read out of `dumps/`, none of it measured) is in
  *Do not re-measure*. ⚠️ This hook publishes definitions and therefore writes into
  `<Mods>/PalForge/state/`, so it declares `writes = true` and needs
  `env.debugHooks["building-actor-streaming"] = true` on top of `env.debug`. That flag went on
  2026-08-03; for a while the declaration and the hook's own ⚠️ comment disagreed about it, and the
  comment was the one telling the truth.
- **`store-save-roundtrip` run 1 passed 7/0 after a real defect was fixed** (below), wrote 370
  bytes, read them back field-for-field, and left `<f>.json` 397 B beside `<f>.json.bak` 370 B with
  no `.tmp`. It **deliberately leaves its file behind**, because run 2 is the measurement: reading
  across a world teardown what a previous session wrote.
- ⚠️ **Ordering constraint for a store session**, because two of the rows above are store hooks:
  `store-crash-recovery` (which has run, and whose four §7.3 rows already hold on real NTFS) needs a
  **fresh session** — `core/state` reads a pack's file at most once per world, so it goes first after
  a load or it refuses by name.
- **`pal-spawn-persisted` raised on its own first line** on 2026-08-02 at 22:06:32 — `%d` fed a
  float, which Lua 5.4 rejects — before it had spawned anything. Fixed at
  `test/hooks/pal_spawn_persisted.lua:82-85`; the one mercy was that it raised BEFORE the write, so
  nothing was left in the save. ⚠️ It also carries the unexplained anomaly of 2026-08-02 16:40:13:
  `spawn.pal(world) ChickenPal (lv 1)` issued with `[evidence declared]`, and 12 s later
  `the call ran but NO new PalCharacter appeared in 12.1 s (26 looks)`, twice more from
  `spawn.palAt`. The 12 s window is not the reason (the one observed arrival was ~5.9 s) and the
  signature still matched, so this does not overturn the parameter list. Whoever next runs a spawn
  owns it.
- **The load storm is the one item with no hook**, because a hook needs a world and therefore arms
  after the storm it wants to watch. `ActivateWidget` fired once in 30 s in a session that armed
  late; how hard it fires during a load is unmeasured. `test/probes/uievents.lua` is the instrument
  that can bracket one. Until it reports, `native/ui/refresh.lua` assumes the storm is violent and
  is built so that a violent one costs nothing.

**Not one of the seven, and it will never be one:** `Building.Handle:unlock()` is **unverifiable by
construction** — this build has no "is it unlocked" accessor. `pf_hook building-unlock` (writes, no
undo, never run) records everything establishable — cheat-manager existence, `UnlockOneTechnology`'s
live declaration, the row precondition (**115 of 501** vanilla ids have one), the call's return — and
hands the rest to a human looking at the build menu. Its doc string says `true` means "issued, and a
technology row of that name exists", not "unlocked". ⚠️ **A technology unlock can never be undone on
this build** — see *Do not re-measure*.

---

## What the running game found that reading never would

Three items in one section because they make the same argument: this tree's confidence comes from
running, and reading is not a substitute for it.

### 1. `ensureDir` asked `io.open` whether a directory exists

`store-save-roundtrip` FAILED at 22:05 with `db.save() FAILED: the backend refused the write`.
`ensureDir` ran mkdir, then asked its own `exists()` — which opens the path as a FILE — whether the
directory was there. **That succeeds for a directory on Linux and fails for one on Windows.** So
every per-save store write in the game reported `could not create <dir>` for a directory it had just
created, and blamed the filesystem.

The headless suite could not catch it: it runs under Linux Lua, where the probe answers yes. **553
checks passed while the game wrote nothing.** Fixed with `os.rename(p, p)`, the portable probe that
sees directories on both platforms — `utils/file/json_file.lua:55-75`, with `ensureDir` at `:97-111`
and both probes now going through it. Run 1 then passed 7/0.

### 2. `spatial.saveId()` cached its own fallback

At 21:38:27, four minutes into a loaded save, on a session that had answered `w_1DF0E44B…` earlier
the same evening, `spatial.saveId()` answered `world` — the SHARED bucket — and the store wrote
`world/logi.json` for a save that has a real id. One line did it:

```lua
cachedSaveId = probed and ("w_" .. …) or "world"      -- ← the defect
```

**A miss was cached.** One probe taken before the `PalGameInstance` exists locked the whole session
into the shared bucket, silently, and no later call ever asked again. The store's per-save isolation
rests on that string. Fixed **positives-only** at `core/spatial.lua:318-323`, with the measurement
above it at `:294-316`; a miss now costs one failed probe per call until the game will answer.
`"world"` remains a legitimate ANSWER for a build that never exposes the name — it is just no longer
a permanent one.

**Read those two as one rule, not two fixes:** *the answer that means "not yet" must never be the
answer that is kept.* Three caches now say so in their own comments — `core/mesh/assets.lua:135`
("Only successes are" cached), `core/icons.lua:506` ("A FAILED build is not cached") and
`core/spatial.lua:309` — and `mesh-texture-import-live` confirmed the same discipline from the other
side, importing a path successfully on the call after that path had missed.

### 3. ⚠️ `ui-update-event` was concluded closed, and a measurement hours later overturned it

Earlier on 2026-08-02 the item was closed with "polling is the only driver": `autoRefresh` said no
rebuild UFunction had ever been observed, `UI.refreshDriver` returned `kind = "poll"`, and a
once-per-session log line said so. That rested on a 21:57 run in which **2 of 14** candidates were
armed and both stayed silent — and both of those two (`ShouldShowGlobalPalStorageNewMark`,
`RequestUpdatePlayerStatusPoint`) were substring false positives with nothing to do with rebuilding
a screen. The conclusion was not wrong about its evidence; it was drawn from evidence that could not
support it, and it was written into the shipping doc strings. **A stale "this does not work" is the
expensive kind of wrong: a pack author who believes it routes around a channel that works, and
nothing ever tells them.** The correction is written where the claim was
(`native/ui/refresh.lua:10-33`) rather than only here, for the same reason.

At 23:04, with the candidate set widened to **21 named out of the dumps**, three fired while the
operator opened and closed two screens. What they were and what shipped is in *Do not re-measure*.

---

## Owed work

### 1. Small, and each one has a decision behind it

- ~~**Three constructors hand-roll their `opts` parsing.**~~ **DONE 2026-08-06.** All three call
  `schema.defineOpts`; a misspelled option raises in every domain, verified for Building, Mesh and
  UI. Original text: `api/building.lua:459-460`,
  `api/mesh.lua:244-246` and `api/ui.lua:1426-1427` read `register`/`pack` inline instead of calling
  `schema.defineOpts` the way the other five domains do (`api/audio.lua:275`, `effect.lua:342`,
  `item.lua:533`, `pal.lua:322`, `skill.lua:419`), so a misspelled option key — `{ regsiter = false }`
  — is silently ignored where the others raise. For Building that means a typo'd read starts
  persisting a save record for every matching actor, which is the exact failure the `register = false`
  gate exists to prevent. One line each; all three already require `schema`.
- ~~**`om.checkImport` has no producer.**~~ **DONE 2026-08-06.** `api/pal` produces refs from
  `spec.skills`, `api/item` from a recipe's materials / product / station, and an undeclared
  cross-pack reference now warns by name. Original text: `core/object_manager.lua:191` is consumed at `:371-373` via
  an optional `opts.refs`, and no `api/` module passes one, so cross-pack references are offered and
  unchecked. Object_manager cannot know which fields of a spec are id references; the api
  constructors are the only layer that does. `M.declareDeps` (`:162`) already gives the dependency
  set a memory, fed by `api.pack(id, { depends = ... })`, so no call site would have to carry a
  manifest.
- ~~**`core/schema` has no `undefine`.**~~ **DONE 2026-08-06.** `schema.undefine` exists and
  `test/support`'s sweep uses it; the leak measured across two consecutive runs is 0, and
  `schema.all()` stays at 31. Original text: `test/cases/schema.lua` leaves **8** namespaced specs behind
  on every F1 press — `Inner`, `Spec`, `Dup`, `Derived`, `ReqDefault`, `FnDefault`, `Untyped`,
  `Checked`, measured across two consecutive `run()`s rather than counted off the call sites
  (`test/cases/schema.lua:25-32`). Inert — nothing walks the spec list per lookup — but
  `test/support.lua`'s `sweep()` cannot reach it.
- ~~**The five store case files each build their own harness.**~~ **DONE 2026-08-06.**
  `support.storeIO{ json = ? }` is the one fake; the three in-memory suites use it. The two DISK
  suites keep their own on purpose — their subject is real files. Original text: `store_api`, `store_codec`,
  `store_disk`, `store_runtime` and `store_state` separately write an in-memory or on-disk I/O table
  (`fakeIO` / `memIO` / `diskIO`), their own scratch-directory naming and teardown, and their own
  bracket. Four of the five want the same two things: a fake backend and a world snapshot restored
  afterwards. That belongs in `test/support.lua` beside `sweepAfter` (`:346`), and until it does, a
  change to the store's I/O seam is five edits.
- ~~**The value guard encodes every record's `state` twice per flush.**~~ **DECIDED, NOT DONE,
  2026-08-06.** `json.validate` now returns the text it produced, but core/state deliberately does
  not take it: the second pass is the WHOLE-DOCUMENT encode, so reusing the first would mean
  splicing a pre-encoded fragment into a serialiser whose byte-identical output the store's own
  tests assert. The reasoning is written at the cost paragraph in core/state.lua. Original text: `utils/json`'s `validate` ends
  by encoding the value to measure it against the 64 KiB limit, and `partition` then encodes it again
  into the document — stated at `core/state.lua:804-810`, where the cost is argued acceptable (a
  handful of fields, at most every 10 s, only while dirty) against the alternative of a whole pack's
  file failing on one bad record. `validate` returning the text it already produced would remove the
  second pass without changing any behaviour.
- ~~**`schema.derive` does not carry a `validate` override**~~ **HALF DONE 2026-08-06.** `derive`
  rawgets the base's own `validate` and carries it, so an inline `Building{ mesh = {...} }` now
  gets `resolvePackPath` and the `SM_`-meets-`skeletal` warning. STILL OPEN: `validateDeclared`
  walks `om.all("mesh")` only, and an inline mesh is unregistered by construction, so it remains
  outside the world.ready pass. Original text:
  `core/schema.lua:372-382` copies field descriptors into a new spec object, so an inline
  `Building{ mesh = {...} }` gets neither `resolvePackPath` on `model` / `texture` (a named
  `Mesh{...}` handle does) nor the `SM_`-meets-`skeletal` warning. Separately,
  `core/mesh/init.lua`'s `validateDeclared` walks `om.all("mesh")` only, so the same inline meshes
  are outside the world.ready validation pass. Fix is one of: `derive` rawsets `validate`, or
  `api/building` delegates.
- ~~**`Handle:iconOf` still misses on the blueprint spelling.**~~ **DONE 2026-08-06.** `iconId` is
  a declared field on all four specs, `Class:iconOf` tries it before `id`, and the two curated
  definitions plus the lazy catalog path carry it from `M.ROW_ID`. Original text: The two-spellings-per-creature trap is
  data now, not prose — `native/pals.lua:264` carries `M.ROW_ID = { SheepBall = "Sheepball" }` and
  `M.iconOf` (`:272`) consults it, with the same split on `WorkBench`/`Workbench` in
  `native/buildings.lua` — but that is catalog-level. `pals.SheepBall:iconOf()` (`api/pal.lua:291`,
  reached through `Handle:iconOf` at `:568`) still misses, because the icon table is keyed on the
  DataTable row spelling. Closing it on the handle needs a `Spec.iconId` field read by `Class:iconOf`.
- ~~**`db.reclaim()` reports but does not undo.**~~ **DONE 2026-08-06.** `core/state` exposes
  `setReclaimDriver` and `api/init` installs drivers for `item` and `passive`; `tech` and `pal`
  stay driverless because they are impossible to undo on this build. Rows report reclaimed /
  partly reclaimed / not reclaimed with the reason. Original text: `core/state.lua:1554` marks every reclaimable id
  `not attempted (no reclaim driver on this build)`. The doing half needs `api/item`'s take and
  `core/character`'s `RemovePassiveSkill`, and `core/state` may require nothing from `api/` — that is
  what keeps the dependency graph acyclic. The store delivers reclaim's *input*.
- ⚠️ **`core.state` is not in `core/reload.lua`'s `KEEP`** (`:82-87` holds four entries: `env`,
  `utils.log`, `core.reload`, `core.object_manager`). It survives F9 only because its state lives on
  `_G.__PalForgeState`. If anyone ever moves that off `_G`, `palforge.core.state` must go into KEEP
  or the runtime will re-persist empty records over a live base.
- ~~**`UI.Spec.input = "exclusive"` is the one declared surface with no hook at all.**~~
  **DONE 2026-08-06.** `test/hooks/ui_input_exclusive.lua` declares it; 26 hooks now. It comes
  down on the clock rather than on a keypress, because a modal that fails to retract is a session
  where the player cannot move. Original text:
  Nothing under `test/hooks/` mounts it. Closing it means declaring a hook, not running one.
  (`host = "layer"` and `backHandler = true` both ran on 2026-08-02 — see *Do not re-measure*.)

### 2. Test blind spots that remain

**The three-environment model is confirmed and needs no further argument.** A check belongs to one
of headless / title screen / loaded save; an earlier run predicted `444 / 0 / 37` at the title screen
and `466 / 0 / 15` in a save out of 481 and **both landed exactly**, which is the strongest form the
claim could take. What a future run should compare is the **skip structure**, not the totals.

- ~~**The gap is still the wrong way round, and it is still unexplained.**~~ **READ SIDE BY SIDE,
  2026-08-03, and there is nothing wrong with it.** The two runs were compared per check rather
  than by total: headless skips **36**, the same suite with the engine simulated skips **48**, and
  **every one of the 12 extra is a `no-engine` check** — the `[mesh]` texture-shape dispatch, six
  `[ui]` cases that assert what happens with no controller and no owner, `[ui] keymap.refresh with
  no game`, and four `[store_runtime]` cases. A check whose claim is *"with no engine under it, X"*
  is UNMEASURABLE the moment an engine exists, so a richer session necessarily skips more, not
  fewer. The direction was never a defect; it is what the third environment MEANS.
  One check goes the other way and is equally correct: `[events] the ready gate is shut while
  there is no player pawn` skips headlessly (no `LoopAsync`) and runs once the engine is stubbed.
  Reproduce with `comm` over the two runs' `SKIP [suite] name (direction)` lines — the totals never
  could have said this, and that was the real finding.
- **The minimum full measurement is TWO runs, and neither is the pair the summary suggests.** A
  headless `lua5.4` run covers the no-engine and no-world checks (there is no world in a bare Lua
  process either); one F1 in a loaded save covers the 31 world-gated ones and the 3 the session
  could not answer. The title-screen press remains useful — it is the only one that exercises the
  game's no-world path with a real engine under it — but it measures nothing the headless run does
  not. Re-run headless with:

  ```sh
  cd Scripts && lua5.4 -e 'package.path="./?.lua;./?/init.lua;"..package.path;
    local e=require("palforge.env") e.dev=true e.debug=true
    local t=require("palforge.test") t.install() t.run()'
  ```

- **One gating axis is outside the environment model entirely, so no number of runs covers it.**
  `core/unittests/init.lua:74-97` declares eight `NEEDS` directions (world, no-world, no-engine,
  hook, opt-in, setup, session, unstated), of which three are ENVIRONMENTS (`:109`).
  `test/cases/ui.lua`'s `ownStack` (`:1452`, used at `:1515`, `:1533`, `:1555`, `:1575`, `:1599`) is
  none of them: it gates on *stack emptiness*, so it skips in any session where something is already
  mounted, and `pf_uiz` leaves three panels up.

### 3. Two design decisions this tree deliberately has not taken

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

## How to run a measurement

### The tree

**There is ONE test tree.** `Scripts/palforge/tests/` (plural) no longer exists.

```
Scripts/palforge/test/          58 files
  init.lua        THE one entry point. install(report) does everything.
  units/          headless suites, run at BOOT. 2 suites, 8 checks.
  cases/          the in-game API suite — F1. 19 files.
  hooks/          game-required measurements. 25 declared. Never auto-run.
  probes/         discovery dumps. Not tests; they pass and fail nothing.
  tools/          dev instruments — catalog.lua, the body of `ps_catalog`
  support.lua  probe.lua
```

Production reaches into it through **ONE name and ONE call**, in `core/registry.lua`'s dev block
(`:164-167`): `requireState("palforge.test")`, then `require("palforge.test").install(record)`.
`install()` runs the boot bundle, loads the cases, binds F1 and the probe keys, registers every
console command and `ps_catalog`, and hands `core/autorun` its action table through
`autorun.setActions(...)` (`core/autorun.lua:105`). `core/autorun.lua` requires nothing under
`test/`.

**A release deploy has no test tree at all.** `tools/deploy.sh:88-103` stages `main.lua` plus
`palforge/`, drops `deprecated/` and `tmp/` from both modes, and drops `palforge/test/` for
`--release` only — 58 files of the 127 under `palforge/`, leaving **69**. So
`requireState("palforge.test")` answering `"absent"` is the CORRECT state for a release rather than
an incomplete install. Dev additionally gets the generated `palforge_dev.lua`, which is the whole
dev/release switch: `env.lua` ships `dev = false` and nothing in the framework ever turns it on.

### Running a hook

1. **Turn the gates on.** `env.debug = true` loads `test/hooks/` at all; `tools/deploy.sh` (default
   mode) writes the `palforge_dev.lua` that sets `dev` and `debug` for you. A hook declaring
   `writes = true` additionally needs `env.debugHooks["<id>"] = true` — nothing that mutates a
   character, an inventory or the world runs off `debug` alone, because `debug` is a session-wide
   switch and a write is a per-experiment decision taken on a throwaway save.
2. **Run it by name.** `pf_hook <id>` from the UE4SS console; `pf_hooks` first if you want every
   hook's gate state and the sentence that opens it; `pf_hook_<id_with_underscores>` from
   `autorun.txt`, because `core/autorun.lua` reads `[delay] name` and cannot carry an argument.
3. **Paste the block.** Output is bracketed `#### BEGIN <id>` / `#### END <id>`, so a block lifts out
   of `UE4SS.log` straight into this file. A hook that keeps watching prints further blocks, `-1`,
   `-2`, …
4. **Implement, then re-check.** **F1** re-runs the API suite; **F9** reloads every palforge module
   without restarting. ⚠️ A green F1 is not a green suite — one press measures one environment; see
   *Owed work §2*. ⚠️ While a hook's watcher is alive **F9 is refused by name**; that is the async
   guard working. Deploy, then run the hook; not the reverse.
5. **Move the item out of this file — and fix its `doc =` string in the api file at the same time.**
   Then run `lua5.4 tools/gen-types.lua` from the repo root, because `Scripts/palforge/types.lua` is
   generated from those strings and is also the IDE tooltip. This step exists because four closed
   items were once still described as dead in their own spec docs, and `ui-update-event` was
   described as dead in its own doc strings for two hours after a hook disproved it.

### The hooks

**25** declared under `Scripts/palforge/test/hooks/`, loaded only when `env.debug` is true, never run
unless asked for by name. **Twenty have now been run to a result.** The five that have not are the
four listed in *Implemented, never exercised by a game* above, plus `building-unlock`, which is
unverifiable by construction and will never produce one.

| hook | writes | run? | what it owns now |
| --- | --- | --- | --- |
| `audio-setvolume-audible` | | **✓** | **the only Open item** — one hedged human report, and 0.00 was not silent |
| `building-actor-streaming` | (see §1) | | **at what distance `FindAllOf` stops returning a base** — never produced a result |
| `building-runtime-reload` | | | the one hook whose measurement spans an F9 |
| `save-survives-pack-removal` | ✔ | | the question the store pass was started for |
| `pal-spawn-persisted` | ✔ | | whether a spawned pal carries a per-individual id that reaches `CharacterSaveParameterMap`. ⚠️ a spawn cannot be taken back |
| `store-save-roundtrip` | ✔ | **✓** | run 1: 7 pass, 370 B written and read back. Run 2 — across a world load — is owed |
| `store-crash-recovery` | ✔ | **✓** | the four-row recovery table, on NTFS instead of on paper. ⚠️ needs a fresh session |
| `building-unlock` | ✔ | | unverifiable by construction — 115 of 501 vanilla ids have a technology row |
| `pal-skills-equip` | ✔ | **✓** | **8/0 — closed the last publish blocker** |
| `item-satiety-write` | ✔ | **✓** | `SetFullStomach` takes ONE argument; satiety moved and was put back |
| `item-datatable-row-read` | | **✓** | the struct route: one `FindRow` call instead of thirteen |
| `skill-hit-source` | | **✓** | settled negative, structurally: no waza field in any damage struct |
| `skill-projectile-spawn` | ✔ | **✓** | settled negative: six routes, every one takes a struct |
| `audio-custom-file-loader` | | **✓** | settled negative: no writable audio buffer, no Wwise media route |
| `ui-update-event` | | **✓** | 21 armed, **3 fired** — the rebuild signal `autoRefresh` now rides |
| `pal-spawned-fresh` | | **✓** | 27 firings, 17 nowhere near a world load |
| `ui-host-layer` | | **✓** | mounted through the game's own CommonUI layer, and came down again |
| `ui-backhandler` | | **✓** | the healthy negative: input is not swallowed |
| `mesh-color-change` | ✔ | **✓** | a chest in the air went red → green → blue → gone |
| `mesh-texture-import-live` | | **✓** | `ImportFileAsTexture2D` called for the first time, and the cache answered |
| `mesh-actor-identity` | | **✓×3** | A-1, three independent sessions, three actor sets |
| `game-build-live` | | **✓×3** | `DisplayVersion` carries Palworld's build; the Kismet strings do not |
| `keymap-key-coverage` | | **✓×2** | 165 names against 165 rows, identical in both directions |
| `building-record-orphans` | | **✓×2** | 3 pass; 0 records, 0 orphans — still owed a base that HAS records |
| `store-base-load-cost` | | **✓** | 0 bytes, 0.00 ms, 0 files at a 7-structure base |

**Nine declare `writes = true`.** Three hooks that do not declare it change something anyway and say
so in their own headers, because `writes` means "a save is mutated" and nothing weaker:
`audio-setvolume-audible` makes the game loud and then quiet again, `mesh-texture-import-live`
allocates a `UTexture2D` nothing in this process can destroy and writes an 82-byte PNG next to
itself, and `building-runtime-reload` leaves subscriptions behind until its next run takes them back.
The first two have run, and both costs were paid exactly as written down. (`building-actor-streaming`
is the one that stretches this past the point of honesty — *Owed work §1*.)

⚠️ **The three store writers stretch the definition deliberately.** None touches Palworld's save;
they create, corrupt and rewrite files under `<Mods>/PalForge/state/`. They declare `writes` anyway,
because the claim being defended is that PalForge is careful with the files under its own directory.
Between them they use exactly two pack ids — `pf_probe` and `pf_crash`, and no real pack may be
called either — and each ends by printing the absolute path of everything it left and the single call
that removes it.

A silent skip is the failure mode this tree has been bitten by three times — a probe on Palworld's
own volume key that bound successfully and never fired, a console command registered into a window
UE4SS ships switched off, and a test that skipped for want of a world and reported the same "0
failed" as a test that ran. So every refusal names the gate and says the sentence that opens it, and
every "this needs the game" skip in the F1 suite names the hook that measures it.

### Keys, the console, and autorun.txt

Nine keys, bound only in a dev session (`env.dev`), from `test/init.lua` (F1 and the six probes),
`core/keyboard/functions/f4_unlock.lua` (F4) and `core/registry.lua` (F9).

| Key | What it does | What you need on screen |
| --- | --- | --- |
| F1 | The API test suite | Anything, but see *Owed work §2* |
| F2 | Title-screen widgets | The title screen |
| F3 | The title-menu button's inner slot, read from a world | A loaded save |
| F4 | Unlock all technologies (`utils.items.unlockAllTech`) | A loaded save |
| F5 | Reflection dump: classes, functions, parameters, DataTable rows | A loaded save |
| F6 | Everything that needs a live pal: mesh, animation, materials | A pal near you |
| F8 | Arms hooks and watches for 60 s while you act | A save, then craft / drop / spawn |
| F9 | Reload every palforge module without restarting the game | Anything |
| F10 | Counts the four UI-rebuild hooks, across a whole world load | A save, then quit to title |

F4 and F8 are the two that change anything, and F8 says so before it arms a hook. F7 is deliberately
unbound: **it is Palworld's own volume key**, and the game claims it before UE4SS sees it.
`registory.register` consults the keymap before binding and prints the verdict on the `bound <KEY>`
line (`free` / `game` / `unknown`). ⚠️ `free` is not a promise the press arrives — the Steam overlay,
the OS and UE's own console keys are all outside Palworld's key config. **F1 is the only key that has
ever been pressed**; everything else that has run came through `autorun.txt`.

The eighteen console actions registered with `env.debug` off — the other 25 are the generated
`pf_hook_<id>` names:

```text
pf_hook     pf_hooks    pf_hooks_all              # the hook plumbing
pf_tests    pf_keys     pf_spawn    pf_mesh       pf_teach
pf_native   pf_uidecl   pf_uiroute  pf_uiz
pf_reflect  pf_pal      pf_watch    pf_title      pf_uislot   pf_uievents   # the six probes
```

**`pf_keys` first when a key does not arrive.** It crosses PalForge's own bindings against the game's
key config and prints, per key, `game` / `free` / `palforge` / `refused` / `unknown`. **UE4SS ships
with its console OFF**, and a command registers perfectly well into a window that does not exist —
the same failure the console was meant to escape, one layer down. Turn it on in
`ue4ss/UE4SS-settings.ini` (`ConsoleEnabled`, `GuiConsoleEnabled`, `GuiConsoleVisible` = 1) and
restart.

When neither works, `Scripts/palforge/autorun.txt` runs named actions on `world.ready` — no key, no
console, nothing to press. **Every measurement on 2026-08-02 came in through it**, which is the third
input route working end to end after a key and a console had each failed a session.

```text
pf_spawn                        # as soon as the world is ready
20 pf_teach                     # 20 seconds after
30 pf_hook_mesh_actor_identity  # a hook, by its generated name
```

`install()` hands `core/autorun` its table through `setActions`, and it warns when a name has no
match. Only names already in that table can run; it reads a list of names, never code.

---

## Do not re-measure

Negatives, traps and hard-won positives, one entry apiece, naming where the full measurement lives.
Nothing here is a task. An entry earns its line only if a future implementer would otherwise look it
up — or probe it a second time.

### What the eight items closed on 2026-08-02 established

- **`pal-skills-equip`** — active-move writes LAND and the game survives them. Every write is
  verified by reading the character back, so a `true` is never "the call ran". The vocabulary is
  settled: `EPalWazaID` names **309** active skills (`core.character.wazaNames()` returns 309,
  re-measured 2026-08-03), which is what `Pal{ skills = { ... } }` can contain. Active skills are an
  enum and passives are FNames, so `:teach` routes on which one the id IS rather than on the skill's
  declared `kind`, and read-backs compare the **canonical** `EPalWazaID` name. `skillsOn(actor)`
  returns four keys, not two; `equipable` and `mastered` answer **nil for UNKNOWN** rather than an
  empty list, because `GetMasteredWaza` is not declared on this build (`HasMasteredWaza(EPalWazaID)`
  is — `core/character.lua:560-564`). `#(s.equipable or {})` is the idiom, and a `0` and a `nil` mean
  different things.
- **`item-satiety-write`** — **`SetFullStomach` takes ONE argument on this build**, and that had to
  be measured: the CXX dump has no body for the setter (its class body, `Pal.hpp:20822-21161`,
  declares only the readers) and only the reflection listing carries the name
  (`dumps/reflection/02_reflection.txt:1298`). The argument's property class is read off the running
  build at call time and never assumed. Satiety moved **31.648 → 21.648** on a live character and was
  put back exactly; `AddHPByRate(float)` lands too. **Two objects, and asking the wrong one is how a
  present function reads as absent**: satiety on `UPalIndividualCharacterParameter`, HP rate on
  `UPalCharacterParameterComponent`. Every absolute HP write takes `FFixedPoint64` — a struct — so
  `Item.Spec.restores = { hp = 50 }` is refused at define time and HP is expressed as a rate. The
  whole account is at `core/character.lua:766-805`; the shipped field is `api/item.lua:320-321`,
  wired on `item.use`.
- **`item-datatable-row-read`** — the struct route works and is one call: `dt:FindRow('Arrow')`
  hands back a `ScriptStruct /Script/Pal.PalItemRecipe` that can be indexed by column name.
  `core/recipes.lua:115-147` parses it into the same `Item.Spec.Recipe` shape a pack declares, and
  `api/item.lua:392` lets a DECLARED recipe win over the game's. Confirmed in a game at 23:33:
  `recipes: Arrow -> Arrow x10, work=1000.0, from { Stone x2, Wood x2 }`. The row's 20 properties are
  below.
- **`pal-spawned-fresh`** — **it fires for a genuinely new pal**: 27 firings, **17 of them nowhere
  near a world load**. Before that run every firing had landed in the same second as `world.ready`,
  so a new pal could not be told from a re-init. `api/pal.lua:182-188`. The arming constraint still
  holds and is recorded in `core/event.lua`: the broadcaster fires in the world-load pal-init storm
  and wedged the SHARED hook dispatch, so these sources are armed only after `world.ready` and never
  at `start()`. Keep handlers idempotent; there is a `SPAWN_DEDUPE_SEC = 1.0` window on the emit, and
  only the FIRST firing per channel is announced.
- **`skill-projectile-spawn`** — settled NEGATIVE and implemented as a refusal. **Seven parameter
  lists were walked in a live save and the running build DECLARED all of them; six routes carry a
  struct** — an `FVector`, an `FTransform`, an `FRandomStream` or an out-struct by reference:
  `ShootOneBullet`, `CreateChildSkillEffect`, `APalSkillEffectBase::Initialize`,
  `BeginDeferredActorSpawnFromClass`, `FinishSpawningActor`, `FindWazaForBP`. All six were refused by
  name and the process survived because the hook refused rather than called. The one argument-free
  entry on the whole surface, `ShootOneBulletDefault()`, needs a live `APalMonsterEquipWeaponBase`,
  which a skill handler is never handed. Shipped as `Skill.Handle:spawnProjectile`, a callable
  refusal carrying the date and all six routes (`api/skill.lua:537-575`), and `Handle:activate` now
  answers `ran, reason` and honours a handler's literal `false` (`:486-535`). **This also settles
  `core/spawn.lua`'s `M.actor`**: the declaration reads fine and the struct is still the barrier.
- **`skill-hit-source`** — settled NEGATIVE **structurally**. Not one field in the three damage
  structs this build declares names a waza: `FPalDamageInfo` **40** fields, `FPalDamageRactionInfo`
  **6**, `FPalDamageResult` **12**, and the closest of the 58 are `EPalWazaCategory` (a Melee/Shot
  bucket, not an identity) and `FName AttackStaticItemID` (the weapon). Both candidate hooks are
  measured silent from both sides. **No amount of fighting can change that**, which is why declaring
  `onHit` now WARNS at define time (`api/skill.lua:384-396`) and `:hit(target)` is the only thing that
  runs it. A correlated guess — remembering the activation and attributing the damage that follows —
  is explicitly declined, because the one number that would justify it (how often the guess is wrong)
  has never been measured; `test/hooks/skill_hit_source.lua` block [3] exists to count it, and if it
  is ever built it belongs behind a name that says it is a guess. Never on `onHit`, which promises
  the game told us. Full account at `api/skill.lua:118-149`.
- **`audio-custom-file-loader`** — settled NEGATIVE from the dumps and confirmed live. **`USoundWave`
  plus `USoundBase` declare 51 reflected properties and not one byte buffer** — the sample data is
  `FByteBulkData RawData` / `FFormatContainer CompressedFormatData`, which are never UPROPERTYs in
  any UE build (`Engine.hpp:21336-21366`, indexed at `core/sound/file.lua:35`). The only two
  `Import*As*` functions in all 1579 headers are both TEXTURE ones. `USoundWaveProcedural` — the
  class whose entire purpose is queued PCM — is not reachable either. The Wwise half is dead
  separately (below). `Audio.Spec.soundFile` now raises at define time with the finding and its date
  (`api/audio.lua:232-258`; the field's own doc at `:141`). What would reopen it, and nothing less:
  a byte-buffer member appearing on `USoundWave`'s reflected property list, or an
  `ImportFileAsSoundWave` turning up after a game update (`core/sound/file.lua:120`).
- **`ui-update-event`** — **three catchable UFunctions fire when Palworld builds or tears down a
  screen**, measured 2026-08-02 23:04 with 21 named candidates armed, 0 refused:

  ```text
  FIRSTFIRE /Script/CommonUI.CommonActivatableWidget:ActivateWidget   at +22.4 s
  FIRSTFIRE /Script/Pal.PalHUDService:Push                            at +25.6 s
  FIRSTFIRE /Script/Pal.PalHUDService:Close                           at +27.8 s
  ```

  `native/ui/refresh.lua` arms exactly those three, lazily, once per session, after `world.ready` —
  arming is forever on this UE4SS, and the handler body is three writes and nothing else so a load
  storm costs increments. `autoRefresh` now refreshes on a rebuild AND at least every `ms`, and
  `UI.refreshDriver(ms)` (`api/ui.lua:1675`) reports `kind = "event+poll"` (`:1712`) read from what
  is actually armed rather than from what this file believes. ⚠️ **The 18 silent candidates are NOT
  proven dead** — the operator opened two screens, not eighteen; their zero is an absence of input.
  They stay named in the hook. The poll stays as the FLOOR: a title-screen element, a session where
  arming was refused, and any rebuild these three do not cover all run on it.

### Things that do not exist on this build

- `FApp::GetProjectVersion` — zero hits across all 1579 headers in `dumps/cxx/`.
- The three `UKismetSystemLibrary` build strings carry **Unreal's** identity, never Palworld's:
  `GetBuildVersion` = `"++UE5+Release-5.1-CL-0"`, `GetEngineVersion` = `"5.1.1-0+++UE5+Release-5.1"`,
  `GetGameName` = `"Pal"`. Palworld's own is `UPalGameInstance::DisplayVersion` /
  `UPalUtility::GetDisplayVersion(world)` — **both answered `v1.0.2.101103` in three separate
  sessions**, matching `env.gameBuild` (`env.lua:80`). Both need a live `UPalGameInstance` and are
  therefore read at the first `world.ready`, not at startup, which is why the old startup MISMATCH
  warning was a defect in the reader.
- No lock/relock for a technology: `LockTechnology|RemoveTechnology|ResetTechnology|
  ForgetTechnology`, zero hits in `dumps/cxx/`. `UPalCheatManager` declares four unlocks and no lock.
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
  `WBP_PalOverallUILayout.CanvasPanel_Root`, a `UCanvasPanel` and therefore a `UPanelWidget`.
- A `CanvasPanelSlot` declares no `SetHorizontalAlignment` (`UMG.hpp:350-374`) where the other five
  slot classes do, so a title-menu button's label can never be aligned that way. A left-aligned label
  routes through `_widget.clickableRow`'s Overlay instead.
- Exactly **three** `AkRtpc` assets exist — `Supply_Altitude`, `OverHeatRifle`,
  `ChargeLaserRifle_01` — plus zero `AkAuxBus` and zero `AkAudioBank`. None is a volume, so the RTPC
  route to `setVolume` had no parameter to address and no parameter list would have helped. The
  capability lives on `UAkGameplayStatics::SetOutputBusVolume(float, AActor*)`, whose second argument
  is the Wwise **game object**, not a bus name.
- **The Wwise external-media route does not exist on this build.** Measured 2026-08-02 21:38:12:
  `AkExternalMediaAsset` and `AkMediaAsset` both resolve as CDOs and both declare **0 functions**,
  and `FindAllOf` answers nothing for either class. `AkGameplayStatics` has 58 functions, of which
  the 7 matching External/Media/Source/Post/Load are all event/bank calls and none reads a file
  (their parameter lists could not be walked — `NumParms=nil` on all seven — a loose end, not a
  route). Do not sweep `AkAudio` for a file loader again.
- **The UE audio pipeline is alive but has no door.** `UGameplayStatics` declares **137** functions
  and the audio ones survive in shipping (`PlaySound2D`, `CreateSound2D`, `SpawnSound2D`,
  `PlaySoundAtLocation`, `SpawnSoundAtLocation`, `SpawnSoundAttached`, `PlayDialogue2D`,
  `PrimeSound`); `FindAllOf('SoundWave')` = **6** and `FindAllOf('SoundBase')` = **8**
  (SkyCreatorPlugin's rain and lightning); `type(StaticConstructObject)` = `function` while
  `NewObject` and `StaticConstructObject_Internal` are both nil. Everything downstream of a filled
  buffer is present — which is exactly why the missing buffer is the whole answer.

### Structural evidence for base streaming, none of it measured

Read out of `dumps/`, and the reason `building-actor-streaming` exists: a persistent `Model` separate
from a transient `ConcreteModel` (`FPalMapObjectSaveData`, `Pal.hpp:4639`);
`OnAvailableConcreteModel` / `OnNotAvailableConcreteModel` delegate **pairs** on about ten classes
(`Pal.hpp:14252-14699`); `TryGetConcreteModel` with a `Failed = 1` out-pin
(`Pal_enums.hpp:2853-2857`); `UPalMapObjectConcreteModelBase:bDisposed`. `core/event.lua`'s miss
sweep counts, per live instance, the consecutive scans in which `FindAllOf("PalBuildObject")` did not
return that instance's actor, and past `MISS_THRESHOLD = 6` — three seconds at `SCAN_MS = 500` — it
used to DELETE the record. **It now quarantines instead, and the scan's bind path restores on
sight.** Whether that was a catastrophe averted or a latent bug closed is the unmeasured part.

Everything readable off the binary says a save holding a pack-owned FName with no DataTable row
behind it is a **missing lookup, not a broken file** — the save stores plain `FName`s, rows resolve
through accessors built to fail (`TryGetStaticItemData` → bool; the whole `BP_FindRow(row, bool&)`
family), and `EPalSaveError { Success, NotFound, Unknown, Broken, OutOfMemory }` has no "unknown
content" member — **but nobody has loaded such a save, so that is well-founded and NOT PROVEN.** The
load path is unreflected C++ (`FPalBinaryMemory`): there is nothing to `signature.describe` and no
UFunction to hook, so it is empirical or it is nothing. That is `save-survives-pack-removal`.

### Traps that made a working read look broken

- **UE4SS mints a fresh userdata per lookup**, so two references to one UObject are not the same Lua
  value and no metamethod can rescue a table keyed on one. **Confirmed in game three times, in three
  independent sessions** (`BP_BuildObject_WorkBench_C`; `BP_BuildObject_ItemChest_C_2147468363` at
  17:37:57.5 and 17:38:05.2; a WorkBench again over a 7-actor sweep at 21:37:50.7 and 21:37:56.7):
  every time, the handle key MISSES, the `GetFullName` key HITS, `rawequal` is false and `uo.same` is
  true. Every per-object table in the live tree is keyed on `uo.key(o)`, with the handle in the
  record's value. `core/uobject.lua` is the only key helper and there is deliberately no second one.
- **Row values arrive wrapped.** A `GetDataTableColumnAsString` array delivers its elements as
  `RemoteUnrealParam`, with the real value behind `:get()` — which is what made an icon array read
  the right LENGTH with nothing in it. And a `TSoftObjectPtr` userdata answers none of the nineteen
  member names a soft pointer could plausibly expose, so that struct cannot be opened from Lua. See
  `core/icons.lua:317-339`.
- **`UDataTable`'s row accessors are not UFunctions.** UE4SS binds `FindRow` / `GetRowNames` /
  `GetRowMap` / `GetAllRows` / `ForEachRow` onto the class itself, which is why every reflection
  sweep missed them. `FindRow` takes a **plain Lua string**, never an `FName`.
- **A row STRUCT can be indexed by column name from Lua**, and the `TSoftObjectPtr` that could not be
  opened is a property of one column TYPE, not of row structs — the two must not be confused again.
  `Product_Count` (`number(10)`), `WorkAmount` (`number(1000.0)`), `Material1_Id` (`userdata(Wood)`)
  and `Material1_Count` (`number(2)`) all read straight off `dt:FindRow('Arrow')`; the control route
  (`GetDataTableColumnAsString` zipped against `dt:GetRowNames()`, 1414 names, `"Arrow"` at index 12)
  agreed. **The row's 20 real properties, read off the live build:**

  ```text
  Product_Id:Name       Product_Count:Int      WorkAmount:Float    WorkableAttribute:Int
  UnlockItemID:Name     Material1_Id:Name      Material1_Count:Int Material2_Id:Name
  Material2_Count:Int   Material3_Id:Name      Material3_Count:Int Material4_Id:Name
  Material4_Count:Int   Material5_Id:Name      Material5_Count:Int EnergyType:Enum
  EnergyAmount:Int      CraftExpRate:Float     DenyRecipeChain:Array
  Editor_RowNameHash:Int
  ```

  `WorkableAttribute` is an enum of what KIND of station can run the recipe and is NOT a station id,
  which is why `core/recipes.lua` leaves `station` nil rather than filling a documented field with a
  confidently wrong number.
- **`EPal*` parameters are declared `EnumProperty`, not `ByteProperty`** — an `enum class`, not a
  legacy `enum`. `core/signature.lua` refused three correct calls over that spelling until it learned
  the two marshal identically.
- **A struct ARGUMENT faults inside UE4SS's marshalling where `pcall` cannot see it.** That is what
  gates `core/spawn.lua`'s `M.actor`, what killed the button-alignment call, what refuses
  `restores = { hp = ... }`, and what `skill-projectile-spawn` measured six times over. A struct
  RETURN is not the same hazard — `GetHP` answers `FFixedPoint64` and the number is behind its one
  `Value` field.
- **The header dump can lag the installed binary by a patch.** `AddItem` declared five parameters
  where `dumps/cxx/Pal.hpp` had four; UE4SS also counts the return as a slot, which is where
  "expected 6 parameters, received 4" came from. This is why `env.gameBuild` is declared at all.
- **A write measured too early looks exactly like a write that never happened.** `SpawnMonster`
  works; the "nothing spawned" verdict came from a stopwatch stopped at 1.2 s on a ~5.9 s arrival.
  `:spawn` now returns whether the call was ISSUED and the arrival line follows in the log. (The
  16:40:13 anomaly this does not explain is under *Implemented, never exercised by a game*.)
- **`RegisterHook` sees what `ProcessEvent` runs, and a broadcaster is not it.** The initialise
  broadcast's bound targets (`PalNPC:OnCompletedInitParam`,
  `PalPlayerCharacter:OnCompleteInitializeParameter`) carry; the broadcaster registered fine and
  never carried anything. ⚠️ Do NOT re-probe
  `PalCharacter:BroadcastOnCompleteInitializeParameter`. Likewise a drop does not go through
  `AddItem_ServerInternal` — it goes through `UPalNetworkItemComponent`, one class over from
  everywhere the search had looked.
- **An id that names an engine enum is case-INsensitive; an id that names a DataTable row or a
  registry key is case-SENSITIVE.** Written into the headers of `core/character.lua`,
  `core/status.lua` and `core/icons.lua`, and onto the docs site.
- **`UObject:IsValid()` on this UE4SS is a real liveness check**, not a null check
  (`is_object_in_global_unreal_object_map(ptr) && !ptr->IsUnreachable()`), so it genuinely protects
  the world.ready → quit-to-title → load-another-save path. The residual risk is ABA, not plain
  staleness. `uo.live` is the one copy; two more remain in `core/keyboard/base/`, left alone because
  that layer is dependency-minimal by design.
- **Material parameter names are Title Case WITH SPACES** and could never have come from a header
  dump — they are data inside a `.uasset`, read off the running game: vector `BaseColor`,
  `Subsurface Color`; texture `Base Texture`, `MetallicRoughnessOcclusionSpecularTexture`,
  `Normal Map`, `Subsurface Texture`; five scalars. Only two of the eleven are in
  `Renderer.TEXTURE_PARAMS`; the rest are reachable through `params` only. A material that is
  currently RENDERING is cooked and shipped by construction, which is why the player's own outfit
  instance leads the base-material candidate list.
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

### Positives, measured once and not to be re-probed

A doubt costs a session to remove as surely as a negative does.

- **A pack-supplied PNG imports, and A-5 is settled.** `ImportFileAsTexture2D` was called for the
  first time in this tree's history on 2026-08-02 at 21:38:53 and answered
  `Texture2D /Engine/Transient.Texture2D_2147458906`, class chain
  `Texture2D : Texture : StreamableRenderAsset : Object`, with `uo.isA(tex, "Texture2D")` true — so
  it satisfies the `UTexture*` that `SetTextureParameterValue` declares. The second call came back
  `rawequal` to the first, which only the cache can do, and `Renderer.resolveTexture` — the seam
  `writeMaterial` actually runs — returned that same cached instance. ⚠️ **The cost is real and
  unchanged**: one `UTexture2D` per distinct path per session that nothing in this process can
  destroy, because UE4SS's Lua layer has no destroy, no `AddToRoot` and no `FGCObject`, and a
  weak-*valued* cache does not shorten a texture's life. One 8×8 is nothing; the cache is what stops
  an attach-per-pal loop from being a leak. **Anything in this tree still calling texture import
  "unproven" is stale.**
- **A colour was watched changing.** A chest in the air went red → green → blue → gone. That is the
  one thing nobody had ever watched, and `api/pal.lua`'s `renderOn` is explicit that a `true` means
  the write ran.
- **`UI.Spec.host = "layer"` works and comes back down.** Mounted through the game's own CommonUI
  layer (`z = 30`, `rootClass = WBP_PalCommonWindow_C`), and `RemoveWidget` took it down.
- **`backHandler = true` produces the healthy negative.** The game's pause menu opened normally: the
  claim is ignored, input is NOT swallowed. `live activatables = 1397, of which claim the back
  action = 0`.
- **UE4SS `Key` = 165 names and `keymap.FKEY` = 165 rows, identical in BOTH directions**, in three
  sessions. `keymap.FKEY` re-counted headlessly on 2026-08-03: still 165.
- **The store's crash table holds on NTFS.** All four §7.3 recovery rows, which had been REASONED
  from `os.rename` semantics, hold on the real filesystem — `<f>.json` 397 B beside `<f>.json.bak`
  370 B with no `.tmp` left behind.
- **A real base costs the store nothing to load.** `store-base-load-cost`: **0 bytes, 0.00 ms, 0
  files** at a base with 7 structures standing and 0 registered building definitions. That is F-8
  observed rather than argued, and it is the FLOOR — it says nothing yet about a base that has
  records.
- **`building-record-orphans`: 3 pass, twice.** 0 records, 0 orphans, no pack document over the
  4096-record cap, and the one destructive path not taken. Still owed a base that HAS records.
- **git history: 101 commits, no secret of any shape**, and no credential-shaped filename ever
  committed.
