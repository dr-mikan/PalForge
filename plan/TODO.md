# PalForge — what does not work yet

**Open**, in the middle of this file, is capability items: a public thing a pack author can call
that does not do what it says. None is a wrong line of code; each is blocked on one fact about
Palworld that nobody has measured — a function's real parameter list, a property's real name,
whether a class exists in the shipping build at all. Each item names that fact, names the
`-- TODO(<id>)` marker at the line a future implementer will open, and names **the declared hook
that takes the measurement**. There are eight.

**Foundations**, immediately after *Before publish*, is the layer underneath: how an id identifies
a thing, and how an asset is found and kept. The fourteen findings recorded there (F-1..F-8,
A-1..A-6) were audited on 2026-08-01 and implemented on 2026-08-02. The measurements are kept
because they are why the fixes are shaped the way they are, and because two of them can only be
*confirmed* with the game running.

**Owed work**, at the end, is the opposite kind: nothing there is waiting on a measurement. It is
work that is simply not finished.

**Before publish**, immediately below, is the short list that gates a public release. It is short
on purpose: closing the eight Open items is NOT a precondition for publishing. An honest nil is
shippable. A crash is not, and neither is a repository that a pack author cannot legally use.

---

## Before publish

Six things stood between this tree and a public v0.3.x on 2026-08-01. Five are closed. The one
that is left is the only one that needs the game.

### 1. Settle the waza write — the one measurement that gates a release

`pal-skills-equip` is the only Open item that is a publish blocker, and it is a blocker for a
reason none of the others share: `Skill.Handle:teach` **writes into a character in a real save**,
and the one run that did it was followed 1.4 seconds later by Palworld closing. The likeliest
explanation is that the write landed on a villager rather than a pal — the search was too wide
then and is fixed now — but "likeliest" is not a thing to publish on.

The experiment is now a declared hook rather than a bare global. On a throwaway save, with a pal
nearby:

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
`PalMonsterCharacter`, and `:teach` / `:forget` / `:teachAll` ship disabled with the reason
stated. Both outcomes are publishable. The present state is not.

⚠️ An ordinary F1 press does **not** settle it. F1 exercises one gated check
(`test/cases/skill.lua:585`) and neither `Pal.Handle:teachAll` nor `core.character.clearSkills`.
`pf_hook pal-skills-equip` covers all three, and restores the pal it borrowed.

The other seven Open items are all fine to ship: `recipeOf` returns nil, `onHit` never fires,
`autoRefresh` polls, `pal.spawned` may over-report at world load, `soundFile` refuses out loud,
and the two native seams log what they did not do.

### What closed the other five, and why the reasons are worth keeping

**§2 — the repository is now shaped like something that can be distributed.** `LICENSE` (MIT,
"Copyright (c) 2026 YUYA556223") and `README.md` exist; the canonical URL is
`https://github.com/dr-mikan/PalForge` in `Scripts/main.lua:2` and in `package.json`; and the
Palworld build everything was measured against — **v1.0.2.101103** — is in `env.lua` beside
`version = "0.3.0"`, in the README and in the startup line. The reason it is recorded is a fact
this tree was bitten by: `AddItem` declared five parameters where `dumps/cxx/Pal.hpp` had four,
because the header dump predated the installed build by a single patch (see
`item-additem-signature`). `main.lua` also reads the build back at runtime into `env.gameBuildLive`
and warns once on a mismatch — but **that read has never been run**, so which of
`GetBuildVersion` / `GetEngineVersion` / `GetGameName` carries the string is unknown. That is the
`game-build-live` hook, and it is the cheapest one in the directory.

**§3 — `dev` no longer defaults to on.** `env.lua` ships `dev = false`, `debug = false`,
`debugHooks = {}`. A dev session turns them on through an optional `Scripts/palforge_dev.lua`
that `tools/deploy.sh` writes into the *deployed* tree in its default mode and deletes under
`--release`; the file is gitignored (`.gitignore:73`) and can never reach a player through the
repository. `Scripts/main.lua` `pcall(require, "palforge_dev")` immediately before
`registry.initialize()` and reports "absent" and "broken" differently.

The reason is the load-bearing part and is written into `env.lua`'s header: **a release toggle
that defaults to "on" is a release toggle that ships on.** Inverting the default is not enough on
its own — the shipper still has to do nothing, and `deploy.sh --release` is what makes doing
nothing correct. The old plan proposed having the dev loop set `env.dev = true` before
`initialize()`; the overlay file is that idea, made a deployment artifact so it cannot be
forgotten in a commit.

**§4 — `soundFile` refuses rather than silences.** `api/audio.lua`'s `refuseSoundFile` (:219,
called at :254 before anything else) is a hard error at define time, naming the item
`audio-custom-file-loader` and the two fields that do play. It fires on the field being
*present*, so `soundFile = ""` is refused too. This was the one Open item that did not degrade
honestly: the field was accepted, validated, documented, and took precedence over `soundId`, so
setting it next to a working sound silenced a sound that was playing. A field that makes working
audio silent is worse than a field that does not exist.

**§5 — SINGLE-PLAYER ONLY is stated, not implied.** The sentence is verbatim in `README.md:27`,
in `Scripts/main.lua`'s `SINGLE_PLAYER` literal (logged at `:183`) and on the docs index:

```text
PalForge targets SINGLE-PLAYER Palworld. Dedicated servers and co-op guests are not
supported and are not tested: there is no replication layer, and the item, spawn and event
routes are all client-authoritative. A pack may appear to work for the host and do nothing
for anyone else.
```

This was never a TODO to implement. Nothing in `api/` or `core/` replicates, and the routes the
framework is built on are client-side by construction: `core/spawn.lua` builds a
`PalCheatManager` off the local player controller, `item-remove-call` spends items through a
locally spawned `APalWeaponBase::RequestConsumeItem`, and every event source is a local
`RegisterHook`. If server support is ever in scope it is a new subsystem (authority checks on
every write, an RPC seam, a decision about who owns pack state), not a fix to any item in this
file.

**§6 — the three foundation defects landed.** A-1 (per-actor tables keyed on a UE4SS handle),
F-1 (silent id overwrite) and F-8 (reading a native catalog started persisting world state) are
all implemented; see **Foundations** for what each one now does. Two of the three are verified by
reading plus the headless suite, and A-1's in-game confirmation is a declared hook,
`mesh-actor-identity`. That distinction is deliberate and is kept everywhere in this file:
"verified by reading + the headless suite" is honest, and it is a different claim from "observed
live".

---

## Foundations

The rest of this file is about capabilities — whether a given call reaches the game. This section
is about the layers underneath them. Neither is blocked on a measurement; both were audited on
2026-08-01 and implemented on 2026-08-02. Each item below keeps **the measurement** (it is why the
fix is shaped the way it is), then says **what landed** and **what is still owed**.

Two shared modules came out of this work and both load under a bare `lua5.4` with no engine at all:

- `core/uobject.lua` — `live`, `fullName`, **`key`**, `same`, `classChain`, `className`, `isA`,
  `describe`. `uo.key(o)` is `GetFullName()`, and it is the ONLY thing a per-object table may be
  keyed on. There is deliberately no second key helper.
- `core/assetpath.lua` — `isObjectPath`, `normalize(path, suffix)`, `packageOf`, `objectOf`.
  Strings only, no engine calls.

### The id model

**The model was always sound and the enforcement was almost entirely absent.** Ids are per-domain,
not one flat table, so a Pal id and an Item id cannot collide; `packid:name` resolves to
`packid_name`, verified against the dumps to be exactly the spelling PalSchema writes into the
game's tables (the injected rows in `DT_ItemDataTable` are exactly `PalSmith_TestPotion` and
`example_Potion`); and `X.get` fabricating a thin definition never registers it, so a lookup
cannot create content. What was missing was every guard the shape implies. That is what F-1..F-8
added.

#### F-1 — registration was a silent overwrite, and a pack could not detect it

**The measurement.** `object_manager.register` was `registry[otype][id] = cls` with no
existing-key check. Every define path called it inside `pcall` and discarded the result; only
`api/pal.lua` inspected it, and only for a failure a schema-validated id cannot produce. Last-wins
is deliberate and documented — the defect was detectability. Seven of the eight definable domains
never return nil from `X.get` (Mesh raises), so "is this id taken?" had no public answer.

**What landed.** The registry stores an entry record `{ cls, pack, resolved }` per id, and
`core/object_manager.lua` gained `entry`, `owner`, `isRegistered`, `unregister`, `byResolved`,
`validId`, `withPack`, `currentPack`, `declareDeps`. `register(otype, id, cls, opts)` takes
`opts.pack`, defaulting to `currentPack()`. Last-wins is still the policy; three cases now log:
a cross-pack collision `log.warn`s naming both owners, a same-owner redefinition is at most an
`env.debug`-gated info line (this is what makes an F9 reload quiet), and a resolved-form collision
warns naming both source ids. `om.isRegistered` is the public "is this id taken?".
`core/schema.lua`'s duplicate-spec-name raise — the check in the file next door that this one was
modelled on — is untouched.

The framework's own definitions all register under pack `"palforge"`; `native/ui/button.lua` and
`native/ui/title_menu.lua` pass `{ pack = "palforge" }` explicitly, and each carries the paragraph
saying that a pack id buys attributability rather than protection: they still write into the same
bucket a pack writes to, under the same last-wins rule.

**Still owed.** Nothing. The old text's "seven of the nine domains" was one off in two directions:
it is seven of the **eight** definable domains, and the ninth api member, `Player`, defines nothing
and has no `get`.

#### F-2 — `resolve()` was not injective

**The measurement.** `VALID = "^[%w_]+$"` allows `_` in **both** halves, and resolution is plain
concatenation with `_`, so `"my:pack_Thing"` and `"my_pack:Thing"` both become `"my_pack_Thing"` —
one game row, two owners, no diagnostic. The module already knew: `M.display` applies
longest-prefix-wins to mitigate the ambiguity in the *reverse* direction. The forward direction had
nothing. It mattered because event dispatch resolved the whole registry and took the first
`pairs()` match, and `pairs()` order is unspecified — so with a collision **which pack's handler
ran varied between sessions**.

**What landed.** An index of resolved forms, maintained at register time, is the F-2 diagnostic
(the second id to claim a resolved form warns naming both) and it made the dispatch O(1) at the
same time. `core/event.lua`'s `resolvePalClass` / `resolveItemClass` / `resolveSkillClass`
(`:2571`, `:2587`, `:2603`) are now one line each — `object_manager.byResolved(otype, id)` — where
they used to copy the whole bucket with `om.all()` and walk it with `pairs()` **once per event**.
Behaviour for a literal id is identical, because a literal id indexes under itself.

**Still owed.** Nothing.

#### F-3 — `resolve()` was applied at five engine boundaries and skipped at five others

**The measurement.** `Item{ id = "pack:Potion" }:iconOf()` could never hit the live table, because
the row PalSchema wrote is `pack_Potion` and `icons.resolve` was handed `pack:Potion`. The same
gap dropped a namespaced passive skill into `AddPassiveSkill` unresolved, and made a namespaced
audio id miss the AkAudioEvent catalog and play nothing. Every namespaced definition fell back to
its declared icon and looked like an unmeasured capability rather than a missing call.

**What landed.** `om.resolve(x) or x` — never `resolve(x)` alone — at every one of the seven sites
that were skipping it:

| boundary | site |
| --- | --- |
| `Class:iconOf` × 4 | `api/item.lua:241`, `api/pal.lua:290`, `api/skill.lua:257`, `api/building.lua:378` |
| passive skill write | `core/character.lua`'s `passiveName()`, feeding both `AddPassiveSkill` and `RemovePassiveSkill`, and the read-back compares the same resolved row |
| audio catalog lookup | `api/audio.lua`'s `Class:source()` |
| building id | `core/event.lua`'s `buildDef`, with the named literal fallback (F-4) |

**Still owed.** Nothing at the boundaries. The related but separate SheepBall/Sheepball trap is
below, under *Sharp edges*.

#### F-4 — an unresolvable build id made a definition inert, silently

**The measurement.** `core/event.lua` dropped ids that failed resolution instead of falling back
to the literal, which is what every other call site did. An empty `buildIds` meant
`Registry.byBuildId` never learned the id, the scan never matched an actor, and
`onPlace`/`onLoad`/`onTick`/`onRemove` never fired — with no log line. Define-time validation was
`schema.nonEmpty` and nothing else, so `Building{ id = "my-pack:Bench" }` — a hyphen, which `VALID`
rejects — defined, registered, and was dead.

**What landed.** Both halves of the decision, not one:

- **Define time.** `om.validId(id)` (`core/object_manager.lua:129`): an id with no colon is a
  literal game id and is accepted if it is a non-empty string; an id **with** a colon must have
  both halves match `^[%w_]+$`. Every domain constructor calls it and raises a hard English error
  naming the rule. `api/item.lua`, `pal`, `skill`, `effect` and `audio` reach it through
  `check = schema.validId` on the `id` field; `building`, `ui` and `mesh` call `om.validId`
  directly inside `define`. All eight refuse `"my-pack:Bench"`; the message wording differs per
  domain.
- **Engine boundary.** An id that fails to resolve falls back to the LITERAL and warns, rather
  than becoming nothing.

**Still owed.** Nothing.

#### F-5 — F9 split the building runtime from the registry it dispatched against

**The measurement.** `core/reload.lua` kept only `env`, `utils.log` and `reload`, so
`object_manager` was wiped and `registry.initialize()` built a fresh, empty registry. Two
consequences, and the file's own header stated the opposite of the first: **a pack's content was
gone after F9**, not "kept until re-registered" (a pack is a separate UE4SS mod in its own require
namespace, is not in the wipe list, is never re-required, and `package.loaded` is still set — so
it stayed gone until the game restarted); and **the building runtime kept the OLD registry**,
because the reconstruction scan was subscribed inside `installBuildingSource` and survived the
reload still closing over the old module's `Registry`. No building hook fired again, `onTick` was
dead, and `Building.Handle:instances()` returned `{}` forever. The bus had been moved to
`_G.__PalForgeBus` for exactly this reason, with a good comment explaining why; the building and
pal registries were the same kind of state and were not.

**What landed.** Three things, because the prescribed fix was necessary and not sufficient:

1. `palforge.core.object_manager` is in `core/reload.lua`'s `KEEP` (`:86`), so a pack's content
   survives F9.
2. The building runtime lives on `_G.__PalForgeBuildingRegistry` and the spatial index on
   `_G.__PalForgeSpatialIndex`, so the surviving drivers and the new module read one registry.
3. The once-armed drivers **re-enter the current module** through `pump()` /
   `M.__scanPump|__flushPump|__palSweep|__worldPoll|__placeIntent` rather than running their
   captured closures. Without this the surviving scan would keep using the old `buildDef`, the old
   class table and the old dispatch, and fight the new module over one shared registry. It is the
   same technique the tick source already used for `core/poll`.

`core/reload.lua`'s header now names all four survivors and what is still stale after F9.

**Still owed.** This is proven headlessly (two harnesses, 26 + 8 assertions) and by reading. It has
never been done in a game. **The hook is now declared** — `pf_hook building-runtime-reload`
(`test/hooks/building_runtime_reload.lua`), run once BEFORE the press and once after:

```text
pf_hook building-runtime-reload      -- records the baseline and re-arms
press F9
pf_hook building-runtime-reload      -- compares against the record
```

It measures the three parts separately, so a partial failure is attributable: the `object_manager`
module table is the same object across the wipe and still holds the same building ids (KEEP); the
table the SCAN closes over and the table the DISPATCH resolves against are one table, read out of
the live closures with `debug.getupvalue` (this is the `_G` claim, and it is the half already
confirmed headlessly — both upvalues are `_G.__PalForgeBuildingRegistry`); and `pump()` re-entry,
via a transparent witness wrapper on this module's `__scanPump` whose call count the NEXT run reads.
It arms **no poller**, deliberately: every `core/poll` poller brackets itself with the async guard,
so a hook with a watcher would refuse the very F9 it is asking for. If no F9 happened in between it
says so by name rather than reporting a healthy-looking pass for a reload that never occurred.

⚠️ **Two halves of the originally proposed procedure cannot be run as written, and the hook refuses
them by name rather than faking them.** "Confirm `Building.Handle:instances()` is non-empty" is not
measurable in a stock session: instances exist only for **registered** Building definitions
(`refreshDefs` reads `object_manager` and nothing else) and F-8 made both curated native buildings
`{ register = false }`, so a stock session has zero registered buildings and zero instances before
*and* after the press — the defect and the fix look identical. The precondition is
`require("palforge.native.buildings").publish("WorkBench")`, which is itself a save write; that is
what F-8 is about, so it is the operator's decision and not the hook's. And "`onTick` still fires"
is unreachable even after publishing: `Registry.tickList` holds only instances whose class
*overrides* `onTick`, and neither curated building declares one — it needs a pack definition, not a
catalog. Fix #3 is likewise not observable from any export (`gate.scans` climbs identically whether
the pre- or post-reload closure ran, because both write the same `_G` tables), which is why the
hook installs the wrapper instead of reading a counter.

#### F-6 — the ownership model was written, tested, and wired to nothing

**The measurement.** `M.checkOwnership` and `M.checkImport` implemented the policy a multi-pack
framework needs, and grep found zero callers outside `test/cases/registry.lua`. They could not be
wired, either: **there was no pack-identity concept anywhere**, so the framework could not know
which pack made a define call.

**What landed.** The scoped surface the old text proposed:

```lua
local api  = PalForge.pack("mypack", { depends = { "otherpack" } })
local Item = api.Item          -- Item{...} registers with pack = "mypack"
```

`api.pack(packId, opts)` (`api/init.lua:196`) memoizes per pack id, returns the same nine members,
validates the pack id against `^[%w_]+$` with a hard error, is a read-only view, and pops the
scope on the error path. Eight constructors are wrapped in `om.withPack`, **plus `Audio.bgm` and
`Audio.se`** — a hole found at the seam, because those two are define routes reached through
`__index` and the first wrapper only covered `__call`, so a sound worked and only its attribution
was lost. `_G.PalForge.pack` is the same function (`Scripts/main.lua:256`), and `main.lua` warns by
name if it is ever absent. `om.checkOwnership` is consulted by `register`; an ownership violation
is **warn + register**, not refusal, and the module header says why.

**Still owed.** `om.checkImport` has a caller (`register`'s optional `opts.refs`) and **no
producer**: no domain passes `refs`, so an import is offered and unchecked. Object_manager cannot
know which fields of a spec are id references; the wiring point is the api constructors. The
dependency set already has a memory via `om.declareDeps`, fed by `api.pack(id, { depends = ... })`,
so no call site would have to carry a manifest.

#### F-7 — persisted records carried no owner, and orphans accumulated forever

**The measurement.** `core/spatial.lua` keys a record on `buildId@cell`, and `core/event.lua`
wrote one file per save shared by every pack, with no pack attribution and no per-record version
(`altKeys` was written and read by nothing). So renaming an id silently lost the player's state
for every existing structure; uninstalling a pack left its records forever, because the miss sweep
only walks `Registry.instances`; two packs sharing an id shared one key space and one `state`
table; and `refreshDefs` wrote over a `pairs()` walk with no conflict check, so ownership of a
placed structure varied per session.

**What landed.** Records carry `v`, `def` and `pack`, stamped on fresh writes and on the first
bind of a v1 record (`REC_VERSION = 2`). `refreshDefs` is deterministic, conflict-logging and
retiring. `altKeys` is deleted with the rename policy written down.

The prune policy chosen is **never delete on absence**. An unclaimed record is moved to the file's
`orphans` section with `orphanedAt`, logged with a count and the packs it belonged to, and moved
back automatically when a definition claims its build id again. One pass per world load after a
60-scan (~30 s) grace period, `ORPHAN_GRACE_SCANS = 60`. The only destructive act is the
`ORPHAN_MAX = 4096` cap, oldest-first, with its own warn. One unambiguous rename case is migrated.

The F-5/F-7 coupling is now written down in `core/event.lua`, and it is worth repeating here: the
prune's justification used to be "F9 drops a pack's content until the game restarts", which stopped
being true the moment `object_manager` entered `KEEP`. Had that comment stayed true, the new prune
would have quarantined every pack's records ~30 s after any F9. If `object_manager` is ever dropped
from `KEEP` again, `ORPHAN_GRACE_SCANS` is all that stands between a reload and a mass quarantine.

**Still owed.** The round trip has never been run against a real save file. **The hook is now
declared** — `pf_hook building-record-orphans` (`test/hooks/building_record_orphans.lua`). ⚠️ The
delay is part of the measurement: the one orphan pass per world runs only after
`ORPHAN_GRACE_SCANS = 60` (~30 s), so load the save, wait ~35 s, then run it; running it earlier
prints `gate.pruned = false` and how many scans are left, and running it twice prints the delta
across the pass, which is the round trip itself. The assertion that matters is a **negative**: a
record whose pack is merely not loaded this session must still be in the file when the pass has
finished. It is read-only in the strong sense — `utils.file.get` hands back the backend's cached
table, which is the very table `core/event` holds as `store.cache`, so it assigns into nothing it
reads.

⚠️ **One unstated fact makes the working-tree evidence weaker than the paragraph below implies, and
the hook prints it whenever it applies.** `state/entities_world.json` is the **fallback bucket**:
`spatial.saveId()` answers `"world"` when the `PalGameInstance` read fails, so that one file is
shared by *every* such session. A real save has a `w_<directory>` file of its own and nothing has
ever looked at one. In the fallback file, "a record no definition claims" may equally be "a record
from a different save", so the round trip is only really settled against a named save id. A second
softening, for pre-F-7 records specifically: "logged … with the packs it belonged to" is optimistic,
because the log names `rec.pack or rec.def or "unattributed"` and a v1 record carries neither —
which is exactly the `(unattributed)` the attest pass printed.

Two smaller things: the file's top-level
`"version": 1` is never bumped while its records are upgraded to `v = 2` in place (nothing reads
the field, so it is cosmetic and misleading), and the on-disk `state/entities_world.json` in this
working tree holds one v1 record, `TestBench@1,2,0`, that no definition claims. **It has now been
quarantined, by a headless run rather than a game** — the attest pass's `test.run()` on 2026-08-02
printed `world records: 0 restored, 1 quarantined (unattributed), 0 unreadable dropped, 0 live`,
and the record now sits under `orphans` with an `orphanedAt` and its dead `altKeys` still on it,
because quarantine copies a record rather than rewriting it. That is the policy working, not a bug
report, and it is invisible to a clone: `state/` is gitignored and git has never tracked it.

**Correction to the old text:** that file was described here as "the checked-in
`state/entities_world.json`". It is not checked in — `state/` is gitignored (`.gitignore:2`) and
git has never tracked it. It exists because something ran.

#### F-8 — reading a native catalog field started persisting world state

**The measurement.** `native/buildings.lua`'s on-demand accessor built via `X{ id = id }`, which
registers. For buildings, registration is not inert: `refreshDefs` picks the def up on the next
500 ms scan and every matching actor in the world becomes a tracked, **persisted** instance. So a
read in a tooltip made PalForge start writing a record for every matching structure in the base,
and a pack that iterated `native.buildings.CATALOG` to fill a picker registered all 498 and
persisted the whole base. Two ids did it unconditionally: `WorkBench` and `PalBoxV2` were curated
`Building{...}` calls at module load, in every install, for content nobody asked for.

**What landed.** Every domain constructor takes an optional second argument —
`X(spec, { register = false, pack = "id" })` — and all six native catalogs' `M.get` build with
`{ register = false, pack = catalog.PACK }`. `<catalog>.publish(id)` is the opt-in that registers.
`WorkBench` and `PalBoxV2` are still declared in full (mesh, name, recipe) and no longer register:
`buildings.publish("WorkBench")` is how a save opts in.

Measured, not read: loading all six catalogs registers 15 classes and **zero buildings**, all
owned by `"palforge"`; reading `buildings.Stone_Gate` changes the registry by 0; a READ of each of
the six leaves `om.isRegistered` false; and `publish` is idempotent and returns the same handle.
`test/cases/native.lua`'s old "reading one name registers one class" test is inverted into
"reading a name registers NOTHING", and `test/cases/registry.lua` gained the matching
"the curated BUILDINGS are declared but not registered until published".

**Still owed.** Nothing. Note the old text used `buildings.Foundation` twice as the example id;
there is no plain `Foundation` row in `DT_BuildObjectDataTable_Common` — the real ones are
`Wooden_foundation`, `Stone_Foundation`, `Metal_Foundation`, `Glass_foundation`.

#### Sharp edges, and where each is now documented

These were "worth documenting rather than fixing", and they now are documented.

- **Case sensitivity is inconsistent by layer.** An id that names an engine enum is
  case-INsensitive (`core/status.lua` and `core/character.lua` both build lowered maps, so
  `Effect{ nativeStatus = "poison" }` and `Skill.get("fireblast"):teach(pal)` both work); an id
  that names a DataTable row or a registry key is case-SENSITIVE. Written into the headers of
  `core/character.lua`, `core/status.lua` and `core/icons.lua` in the same words, and onto the docs
  site as a table on `api/effect.mdx`.
- **The same creature is spelled two ways, in shipped code.** `native/pals.lua` carries `SheepBall`
  (blueprint id, what dispatch keys on) and `Sheepball` (the DataTable row, what the icon table
  answers to); `native/buildings.lua` has the same `WorkBench`/`Workbench` split. This is now
  *data*, not prose: `M.ROW_ID = { SheepBall = "Sheepball" }` with a catalog-level `M.iconOf(id)`
  that consults it, plus a test asserting two distinct handles for one creature.
  **Still owed:** `Handle:iconOf` on the handle still misses on the blueprint spelling. Closing it
  on the handle needs a `Spec.iconId` field read by `Class:iconOf`.
- **There is now an `unregister`.** `om.unregister(otype, id)` is explicit and headed;
  `register(otype, id, nil)` still forgets, because the tests spelled it that way and
  `test/support.lua`'s sweep keeps it as a fallback.
- **Define-time id validation is no longer `nonEmpty` and nothing else** — see F-4.

#### What is genuinely solid here

Per-domain buckets with an explicit `VALID_TYPES` and a fail-soft unknown type; the `packid:name`
→ `packid_name` model verified against the dumps rather than asserted; catalogs sourced from the
`_Common` sibling so mod rows never leak into "what the game ships"; `native/_catalog.lua`'s naming
rules, which state their collision policy, record rather than swallow it, sort for determinism, and
check the module's own surface for shadowing — the pattern `om.register` was asked to copy and now
has; no id is ever silently coerced between string / FName / number, and `core/icons.lua` refuses
to "also try FName" on purpose; handles capture their class by reference so a stale handle keeps
running its old declaration instead of resolving into a half-built new one; and the building
instance key is the actor first and the position second, with a guard that refuses to steal a live
actor's instance.

### Assets — meshes, textures, materials, sound

The resolver itself is the best-designed code in the tree (see the closing list). The problems were
above and below it: what a record was keyed on, and what a pack can actually ship.

#### A-1 — every per-actor record in the mesh layer was keyed on a UE4SS handle

**This was the most consequential finding in the audit.** UE4SS mints a **fresh userdata per
lookup**, so two references to one UObject are not the same Lua value — and Lua table indexing
compares userdata by identity, so no metamethod could rescue it. This was not inference: **this
tree measured it and wrote it down twice, then keyed on it anyway.**

- `utils/items/init.lua` — *"UE4SS hands out a fresh userdata wrapper per lookup … The first run of
  this line printed 'is the controller's own: false' for a cheat manager whose own path was nested
  under that very controller."*
- `core/mesh/skeletal.lua` — *"two UE4SS handles onto one UObject are not necessarily equal, so a
  name is the only comparison that means anything"* — used correctly for the mesh read-back, and
  ignored for the table key 37 lines earlier.

What a pack author hit, all of it silent: `Mesh.Handle:detach(actor)` returned false and did
nothing unless handed the identical Lua value that `attachTo` got; `attachOnce`'s guard missed the
same way, so a second attach added a *second* component and the first became unreachable and could
never be destroyed (unbounded growth); the skeletal undo inverted, capturing **the mesh PalForge
just installed** as the "original" on a second attach and restoring ours instead of the pal's; and
`setColor` re-created MIDs on a component that already had ours. Nothing in the suite could see it:
the tests stubbed the actor with a plain Lua table, which *is* identity-stable, so they were green
on the one property that does not hold in a world.

**What landed.** Every per-object table in the live tree is keyed on `uo.key(o)` — `GetFullName()`
— with the handle in the record's *value*, re-validated with `uo.live` before use and refreshed
from the caller's fresher handle. Two handles are compared with `uo.same`, never `==`. The audit
listed five tables in the mesh layer; the sweep found **nine sites**, in five more files:

| site | table |
| --- | --- |
| `core/mesh/init.lua` | `dressedBy` (+ `recordFor()`, which re-validates, refreshes and drops dead records) |
| `core/mesh/static.lua` | `compByActor` + `dressed`, collapsed into one `byActor` record |
| `core/mesh/procedural.lua` | the same pair |
| `core/mesh/skeletal.lua` | `originalOf` — this is the capture-once inversion fix |
| `core/mesh/base/renderer.lua` | `midStore`, **and** `createMids`' `prev.comp == comp` comparison |
| `core/event.lua` | `instancesByActor`, **and** the pal onTick sweep's memo `palClassOf` |
| `api/effect.lua` | `apps` — found at the seam, unclaimed by any agent |
| `api/skill.lua` | `lastFire` — found at the seam, unclaimed by any agent |
| `core/icons.lua` | `iconMaps`, keyed on the UDataTable handle |

The two `api/` rows were not documentation defects, they were live bugs the audit had not found:
`api/effect.lua`'s `apps` meant `:isActive` / `:timeLeft` / `Effect.activeOn` answered false/0/{}
through any re-fetched handle, `:remove` removed nothing, and a second `:apply` on the *same* pawn
started a second independent application — `onApply` again instead of `onStack`, and
`core.status.add` run twice on a target already carrying the ailment. `api/skill.lua`'s `lastFire`
meant **`cooldown` did nothing at all for any engine owner**; it only ever worked for the
`NO_OWNER` sentinel and plain-table owners, i.e. exactly what the suite exercised. Both now have
regression tests that drive two distinct handles onto one object, because A-1 is silent by nature
and a pure key fix rots back without one.

Weak keys came out with the handles, deliberately: a string key is not collectable, so `__mode="k"`
would have made those tables immortal. `apps` is bounded by a `target_gone` expiry plus `prune()`;
`lastFire` by a `COOLDOWN_KEEP_SEC = 600` sweep run at most once a minute.

**Still owed — and this is the one in-game line that confirms the whole finding.**
`pf_hook mesh-actor-identity` takes three `FindAllOf("PalBuildObject")` sweeps six seconds apart,
re-finding the target **by `GetFullName`** each time so a miss is attributable, and reports HIT/MISS
under the old handle key and under `uo.key`, `rawequal` vs `uo.same`, and the shipped path
`event.instanceOfActor(fresh)`. A miss under the old key is the bug as diagnosed; a hit means UE4SS
interns handles somewhere this audit did not find. Only `renderer.lua`'s MID store has a
two-handles regression test that can run headlessly — `dressedBy`, `static.byActor`,
`procedural.byActor` and `skeletal.originalOf` need `AddComponentByClass` and cannot be driven
without the engine. That is what the hook is for.

#### A-2 — a declared `Building{ mesh = ... }` probably never attached itself

**The measurement.** `inst._meshPending` was set in `addInstance` and consumed **only** in
`scanOnce`'s fast path, which was inside `if bound then`, where `bound = instancesByActor[actor]`
and `actors` came from a fresh `FindAllOf` every scan. By A-1 that lookup missed on every scan
after the one that created the instance. The slow path then computed `sameActor = inst.actor ==
actor` — false for the same reason — found `heldValid` true, and returned without touching
`_meshPending`. Set once, never cleared, never rendered. It contradicted a claim this file and
`api/pal.lua` both made ("Buildings needed no equivalent — `core/event.lua` already defers
`inst:render()`, so `Building{ mesh = ... }` has always drawn itself").

**What landed.** The fast path is keyed on `uo.key(actor)`, refreshes `bound.actor = actor` before
rendering, then clears `_meshPending` and calls `bound:render()`; it is re-armed on a genuine actor
swap. `api/pal.lua`'s claim is rewritten to state only what is guaranteed. The seam traced the
whole path end to end against the real modules.

**Corrections to the audit's own symptom list**, both found while fixing it: the slow path set
`matched[key] = true` *before* the `if inst then` branch, so for a stationary structure
`missingStreak` neither reset nor grew — it sat at 0, and no spurious `building.remove` was
possible. And `spatial.indexUpdate(bound)` **was already written** in the fast path; both A-2 and
`core/spatial.lua`'s own "KNOWN GAP" read as if the call did not exist. It existed and was dead
code, because of A-1. The real damage was that `bound.pos = p` never ran (a tracked instance's
position was frozen at discovery), `indexUpdate` never ran, and `_meshPending` was never consumed.

**Still owed.** The same hook as A-1: `mesh-actor-identity`. Nobody has ever watched a building
mesh appear.

#### A-3 — the sound loader was the un-hardened twin of the mesh loader

**The measurement.** `core/sound/native.lua` did `LoadAsset` → `StaticFindObject` and handed the
result straight to a typed native parameter (`PlayAkEventSoundByActor(AActor*, UAkAudioEvent*)`,
`dumps/cxx/Pal.hpp:29170`). It had **no class check, no `core/signature`, and no `normalize`** — all
three of which the mesh path has, and `core/mesh/assets.lua` exists *because* handing a wrong-typed
object to a typed setter "faults inside UE4SS's marshalling where pcall cannot see it; that is the
shape that closed the game once." A pack writing `soundPath = Mesh.assets.SM.ChestWood` reached
exactly that. The missing `normalize` had a live consequence: **the module's own documented example
was the broken form** — a package-only path that resolved to nothing and fell through to the silent
branch, which returns **true**.

**What landed.** `loadAsset` normalizes through `core/assetpath` first, then refuses anything that
is not `uo.isA(obj, "AkAudioEvent")` (`core/sound/native.lua:119`) with an English line naming the
class it actually got and the declaration it would have been marshalled into; unresolvable and
wrong-class paths are reported once per path and never cached. The play call goes through
`core/signature` with `{ObjectProperty, ObjectProperty}` instead of a bare pcall. The private
`alive` is gone (`uo.live`). The header's example is the catalog's real path.

`Package.Object` was implemented in three places by hand; it is now one shared helper,
`assetpath.normalize`, used by the mesh loader, `core/icons.lua` and the sound loader alike.

**Still owed.** Nothing in the code. `setVolume` has still never been *heard* — that is
`audio-setvolume-audible`, in Owed work §2.

**Correction:** A-3 said "route the call through `core/signature.lua` the way the mesh path does".
The mesh *loader* does not use signature — it uses the class check; signature is used by the mesh
*setters*. Both are now on the sound path, each in its analogous place.

#### A-4 — state plainly what a pack can ship

| Asset | Pack-supplied | Vanilla `/Game/...` |
| --- | --- | --- |
| Static / skeletal mesh | **No** — `assets.load` refuses anything not starting with `/` | Yes, working, class-checked |
| Procedural geometry | **Yes** — `.obj` off disk | n/a |
| Texture | Unproven — `ImportFileAsTexture2D` is wired with the right signature and **has never once been called** | Yes |
| Sound | **No** — `FileSource:play` is `return false` (`core/sound/file.lua:79`), and `soundFile` now refuses at define time | Yes, 1957-entry catalog |
| Material | **No** — only "parent a MID to an already-loaded material" | Yes |

**The measurement.** The one route that existed was **unshippable anyway**: there was no
pack-relative path resolution. `Mesh.Spec.model` and `texture` went to `io.open` /
`ImportFileAsTexture2D` verbatim, and the docs' own examples hardcoded `C:/mods/example/marker.obj`
— a path that is correct on exactly one machine. PalForge already owned the technique
(`utils/file/json_file.lua` resolves `<Mods>/PalForge/state/` from `debug.getinfo(1,"S").source`)
and exposed no equivalent for a pack.

**What landed.** `utils/file/init.lua:110` `M.packDir(level)` and `:142` `M.resolvePackPath(rel,
level)`, built the same way, with an automatic walk out of `Scripts/palforge/` so they work at any
nesting depth, plus `M.isAbsolute`. `Mesh.Spec:validate` runs `model` and `texture` through
`resolvePackPath`, so a pack ships `art/marker.obj` and the docs' `C:/mods/example/marker.obj`
examples are gone — except where an absolute path is now the *deliberate demonstration* of one of
the three limits below, which is how `api/mesh.mdx` and `api/building.mdx` use it. The README states the shape of the framework in one sentence — a
**reference-vanilla-assets framework, with an untested custom-PNG side door and a working OBJ side
door** — rather than leaving it to be discovered.

**Still owed.** Three places a relative path is still not resolved, all for the same structural
reason and all documented where an author will meet them:

- `Building.Spec.Mesh` is built by `schema.derive` from `Mesh.Spec`, and `derive` copies field
  descriptors into a **new** spec object, so it does not carry the `validate` override. A named
  `Mesh{...}` handle works; an inline `Building{ mesh = {...} }` does not. It also misses the
  `SM_`-meets-`skeletal` warning for the same reason. Fix is one of: `schema.derive` copies a
  rawset `validate`, or `api/building` delegates.
- `Pal.Spec.Material.texture` — `Pal.Spec` has no custom `validate`.
- `params.texture` entries — `out.params` is the pack's own literal table (schema does not copy
  `type = "table"` fields) and rewriting strings inside it would mutate the caller's declaration.
  Deliberate.

#### A-5 — imported textures were re-imported per attach and never released

**The measurement.** `Renderer.importTexture` had no cache. `resolveTexture` dispatched to it on
every call, and `writeMaterial` called it once for `def.texture` plus once per `params.texture`
entry — **on every attach**. So `Pal{ mesh = { texture = "…/body.png" } }` imported a fresh
`UTexture2D` for every pal that spawned, tracked by nothing and destroyed by nothing. The `/Game`
branch of the same function *was* cached, which made the asymmetry easy to miss in review.

**What landed.** `core/mesh/base/renderer.lua:431` — a positives-only, weak-valued cache keyed on
the exact absolute path string. The `kismetRendering` latch went with it: it used to record a
failure permanently, and now retries.

**Still owed.** `ImportFileAsTexture2D` has still never been called, so the new cache is unobserved
along with the capability it caches. **The hook is now declared** — `pf_hook
mesh-texture-import-live` (`test/hooks/mesh_texture_import.lua`), which needs a world and a player
and nothing else. It writes an 82-byte 8×8 PNG next to itself first, so "the import failed" can
never mean "there was no file"; imports once and prints the returned object's class chain and full
name; imports the same path again and decides the cache with `rawequal` on the two returned Lua
values; and attempts the import once BEFORE the file exists, so positives-only-with-retry is stated
as an observation rather than as a code reading. ⚠️ A successful run allocates **one UTexture2D that
nothing in this process can destroy** — there is no `AddToRoot`, no `FGCObject` and no destroy in
UE4SS's Lua layer, and a weak-*valued* cache does not shorten a texture's life. One 8×8 is nothing;
a loop doing this is exactly the leak this item is about.

One thing the paragraphs above leave to be re-derived, and the hook does not: the cache lives
**inside `importTexture`**, while the per-attach call site is **`resolveTexture`** (`writeMaterial`
calls it once for `def.texture` and once per `params.texture` entry). A cache the real call site did
not reach would be a cache in name only, so the hook's last call goes through
`Renderer.resolveTexture` and `rawequal`s *that* return against the first import.

#### A-6 — there was no "validate my declared assets" pass, and attach threw the diagnosis away

**The measurement.** `Mesh.Spec` checks types only — correct at define time, when there is no
world, but nothing replaced it later. `assets.load` produced genuinely good English;
`static.lua` and `skeletal.lua` **logged** it while `core/mesh/init.lua` and `api/mesh.lua`
returned a bare boolean, so the author got `false` and had to go read `UE4SS.log`.
`Mesh.assets.probe` walked PalForge's own catalog, not the registry.

**What landed.** `core/mesh/init.lua:265` `M.validateDeclared(sink)`, re-exported as
`Mesh.validateDeclared`, walks `om.all("mesh")` resolving each declared `model` / `animClass` /
`texture` / `material` and logs one `MESHVALIDATE` block. It is called at `world.ready`, from
`core/event.lua`'s `__scanPump` immediately after the `world.ready` emit, pcall'd and guarded on
the function existing. And `attach` / `attachOnce` / `setColor` / `detach` all return
`false, reason` now, so the diagnosis reaches the caller instead of only the log.
`assets.load`'s single "did not resolve" string is split into the cases that are distinguishable
("no `LoadAsset` at all", "package in memory, tail wrong") plus a plain statement of the three that
are not.

**Still owed.** The pass walks `om.all("mesh")` only, so an inline `Building{ mesh = {...} }` is not
covered — the scan's render path reports those instead. Both halves are stated in the two files'
comments, which used to be stale in opposite directions.

#### Sharp edges, and where each is now documented

- **The stale-pointer fear is smaller than this tree believed, and that is good news.**
  `UObject:IsValid()` on this UE4SS is a real liveness check, not a null check
  (`is_object_in_global_unreal_object_map(ptr) && !ptr->IsUnreachable()`), so it genuinely protects
  the world.ready → quit-to-title → load-another-save path. The residual risk is ABA (a new UObject
  at a freed address), not plain staleness. There used to be four private copies of this check
  (`assets.live`, `renderer.isLive`, `icons.isValid`, `sound.alive`); all four are now `uo.live`.
  Two more remain in `core/keyboard/base/`, left alone deliberately: that layer is
  dependency-minimal by design.
- `assets.lua`'s weak-values comment overstated what the table bought — nothing PalForge holds ever
  pinned a UObject (there is no `AddToRoot`/`FGCObject` anywhere in UE4SS's Lua layer). Corrected in
  place.
- **Two caches used to latch a failure permanently** — `renderer`'s `kismetRendering` and `icons`'s
  `dtLib`. Both are now positives-only with a retry, matching every other cache in the layer.
  `iconMap` additionally bails before `signature.call` when the CDO is missing, so it stops blaming
  the live build for a CDO we have not found yet.
- `core/mesh/procedural.lua`'s OBJ cache was strong and unevicted; it is an 8-entry LRU.
- `core.mesh.attach` had **no once-guard at all**. It now has a **never-stack** guard rather than a
  once-guard, and the reason is written down: `attach` takes a *spec*, so a caller passing a new
  model is asking to change the mesh, and a once-guard would silently ignore that — the same class
  of quiet failure this whole item is about — while also making `attach` and `attachOnce` the same
  function. A previous attach by the same backend has its component destroyed first; by a different
  backend, it is detached first.
- `loadClass`'s path parsing diverged from `normalize` (it tested for a dot over the whole path
  rather than the last segment, so a directory containing a dot yielded a package-only path, and
  `gsub("_C$","")` mangled a package path legitimately ending in `_C`). Rewritten on
  `assetpath.packageOf` / `objectOf` / `normalize`.
- **`iconOf()` returned two different kinds of thing and declared neither.** Settled: it is one
  kind of thing, a `/Game/...` string path. The `icon` field is `type = "string"` in all four
  specs and every `:iconOf` return annotation is `string?`.
- `kind` and the model prefix were not cross-checked at define time, even though
  `skeletal.lua` names it as the mistake ordinary pack code makes. `Mesh.Spec:validate` now warns
  when `SM_` meets `skeletal`, at load, with no world. (Not on `Building.Spec.Mesh` — see A-4.)

#### What is genuinely solid here

The class check before marshalling — it converts the one failure mode `pcall` cannot catch into an
English string, and distinguishes "not in the pak" from "is an asset, wrong class"; `isObjectPath`
as a total, unambiguous dispatch, whose refusal message even names the other backend; read-backs
instead of trusted setters everywhere; failure cleanup that destroys the component on any failed
attach step, so there are no half-dressed leftovers; the skeletal restore discipline, which
captures asset + scale + location before touching a component it does not own and deliberately
keeps the FIRST originals — defeated by A-1 in practice, and now working as designed;
`core/icons.lua` refusing to zip a column against row names when the lengths disagree rather than
handing out confidently wrong icons; and the thread discipline — UE4SS requires `LoadAsset` on the
game thread, every repeated driver rides the one heartbeat, and its body is queued through
`ExecuteInGameThread`. Nothing in the layer throws.

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
   from `autorun.txt`, because `core/autorun.lua` reads `[delay] name` and cannot carry an
   argument.
3. **Paste the block.** Output is bracketed `#### BEGIN <id>` / `#### END <id>`, exactly like the
   probes, so a block lifts out of `UE4SS.log` straight into this file. A hook that keeps watching
   after its body returns prints further blocks of its own, `-1`, `-2`, …
4. **Implement, then re-check.** **F1** re-runs the 481-check API suite; **F9** reloads every
   palforge module without restarting. ⚠️ While a hook's watcher is alive **F9 is refused by name**
   — every poller brackets itself with `core/reload`'s async guard. That is the guard working. It
   clears when the watcher retires, at its own 180 s cap, or from the Lua console with
   `require('palforge.core.reload').asyncReset()`. Deploy, then run the hook; not the reverse.
5. **Move the item to Closed here — and fix its `doc =` string in the api file at the same time.**
   Then run `lua5.4 tools/gen-types.lua` from the repo root, because `Scripts/palforge/types.lua`
   is generated from those strings and is also the IDE tooltip. This step exists because four
   closed items were still described as dead in their own spec docs when this file was last
   synced; a pack author reading a stale `doc =` string routes around a channel that works, which
   costs exactly as much as the channel not working.

### The hooks

19 declared under `Scripts/palforge/test/hooks/`, loaded only when `env.debug` is true, never run
unless asked for by name. `pf_hooks` lists them, `pf_hook <id>` runs one, `pf_hooks_all` runs every
one whose gate is open, read-only ones first.

| hook | writes | what it owns |
| --- | --- | --- |
| `game-build-live` | | Before publish §2 — which function carries the build string |
| `keymap-key-coverage` | | Owed work §3 — the only hook here with **no `needs` at all** |
| `mesh-actor-identity` | | Foundations / A-1 and A-2 — the whole keying finding, in one run |
| `item-datatable-row-read` | | Open / Item (with `item-recipe-of` folded in) |
| `audio-custom-file-loader` | | Open / Audio |
| `building-record-orphans` | | Foundations / F-7 — the quarantine round trip, ~35 s after load |
| `ui-update-event` | | Open / UI |
| `pal-spawned-fresh` | | Open / Events |
| `skill-hit-source` | | Open / Skill — confirms the negative |
| `item-satiety-write` | ✔ | Open / Item — the second one |
| `skill-projectile-spawn` | ✔ | Open / Skill — the second one |
| `ui-host-layer` | | Owed work §2 |
| `ui-backhandler` | | Owed work §2 |
| `building-runtime-reload` | | Foundations / F-5 — the one hook whose measurement spans an F9 |
| `mesh-texture-import-live` | | Foundations / A-5 — the call that has never once been made |
| `mesh-color-change` | ✔ | Owed work §2 — the colour nobody has watched change |
| `audio-setvolume-audible` | | Owed work §2 — deliberately not `writes`: it makes noise, not a save edit |
| `building-unlock` | ✔ | Owed work §2 |
| `pal-skills-equip` | ✔ | Before publish §1 / Open / Pal — **the publish blocker** |

Five declare `writes = true` (the ✔ column) and so need an `env.debugHooks` entry on top of
`env.debug`. Three of the unticked ones change something anyway and say so in their own headers,
because `writes` means "a save is mutated" and nothing weaker: `audio-setvolume-audible` makes the
game loud and then quiet again, `mesh-texture-import-live` allocates a UTexture2D nothing can
destroy and writes an 82-byte PNG next to itself, and `building-runtime-reload` leaves five channel
subscriptions and a `__scanPump` wrapper behind until its next run takes them back.

A silent skip is the failure mode this tree has been bitten by three times — a probe on Palworld's
own volume key that bound successfully and never fired, a console command registered into a window
UE4SS ships switched off, and a test that skipped for want of a world and reported the same
"0 failed" as a test that ran. So every refusal here names the gate and says the sentence that
opens it, and every "this needs the game" skip in the F1 suite names the hook that measures it.

The `item` column above is not prose: it is each hook's own `item =` field, printed by `pf_hooks`
and by every `pf_hook` run, so a hook says where it belongs in this file without anyone looking it
up. That makes it a pointer, and a pointer that has drifted is worse than none. Two drifts were
found and fixed on 2026-08-02: `Open (6)` appeared **13 times across 7 files** (six `item =`
declarations, `init.lua`'s worked example, and prose in the same files) after this file became
Open (8), and five `item =` strings still said "Owed work §4" after that material was renumbered to
§2 here. All 13 now read `Open / <domain>` with no count at all — the spelling the two hooks
written on 2026-08-02 already used, and the one that cannot go stale the next time an item closes.

### Keys

All nine are bound only in a dev session (`env.dev`), from `test/init.lua` (F1 and the six probes),
`core/keyboard/functions/f4_unlock.lua` (F4) and `core/registry.lua` (F9).

| Key | What it does | What you need on screen |
| --- | --- | --- |
| F1 | The API test suite — 481 checks, 14 suites | Anything. World-gated checks skip |
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

F7 is deliberately unbound: **it is Palworld's own volume key**, and the game claims it before
UE4SS sees it, so a probe bound there can never be pressed — which is where `watch` sat,
unreachable and silent about it. `registory.register` now consults the keymap before binding and
prints the verdict on the `bound <KEY>` line itself (`free` / `game` / `unknown`), so a key the game
has taken is named in the log rather than looking like a probe that found nothing. ⚠️ `free` is not
a promise the press arrives: the game's key config is not the only thing that can take a key
(the Steam overlay, the OS, UE's own console keys are all outside it), and F7 may well read `free`
there. The report says so in its own words.

### The console

**Every probe also has a console command**, because a key the game has claimed binds successfully
and then never fires — which from the log is indistinguishable from a probe that ran and found
nothing. `test/init.lua` registers **18** actions with `env.debug` off and **37** with it on (one
generated `pf_hook_<id>` per declared hook, so that number moves with the table above). The fifteen
that are not hook plumbing:

```text
pf_tests   pf_keys    pf_spawn    pf_mesh     pf_teach
pf_native  pf_uidecl  pf_uiroute  pf_uiz
pf_reflect pf_pal     pf_watch    pf_title    pf_uislot   pf_uievents
```

**`pf_keys` first when a key does not arrive.** It crosses PalForge's own bindings against the
game's key config and prints, per key, `game` / `free` / `palforge` / `refused` / `unknown` — so a
key Palworld has taken is named rather than inferred from a probe that stayed silent.

**UE4SS ships with its console OFF**, and a command registers perfectly well into a window that
does not exist — the same failure the console was meant to escape, one layer down. Turn it on in
`ue4ss/UE4SS-settings.ini` and restart:

```ini
ConsoleEnabled = 1
GuiConsoleEnabled = 1
GuiConsoleVisible = 1
```

### When neither a key nor the console works

`Scripts/palforge/autorun.txt` runs named actions on world.ready — no key, no console, nothing to
press. Put a line in it, deploy, load a save:

```text
pf_spawn                        # as soon as the world is ready
20 pf_teach                     # 20 seconds after
30 pf_hook_mesh_actor_identity  # a hook, by its generated name
```

`core/autorun.lua` holds no table of its own: it looks the name up in
`require("palforge.test").ACTIONS` and warns when there is no match. Only names already in that
table can run; it reads a list of names, never code. This exists because three input routes failed
in turn on a real machine — a key Palworld had already claimed, a second key, and a console UE4SS
ships switched off — and each time the work was fine and only the way in was missing.

`pf_spawn` and `pf_teach` exist for the same reason one layer up: two channels are only observable
while something specific is happening, and "go and play until it does" is a poor instruction when
the something is "catch a pal strong enough to fight". PalForge can make the situation, so it does.

---

## Closed (46)

### Settled with the game (32)

Six were settled from the reflection dumps in `dumps/`, without touching the game. Two more were
settled inside a loaded save by the first F5 run (`dumps/f5-partial-run.txt`). Six were settled by
`dumps/cxx/`, UE4SS's own header dump of the installed binary — 1579 headers carrying every
UFunction's real signature, which is the only source in this tree that answers a parameter list
without the game running. The rest were observed live.

- **`audio-akevent-play-signature`** — Audio.Handle:play. The recorded session caught the GAME ITSELF calling PalSoundUtility:PlayAkEventSoundByActor six times with exactly (AActor, UObject) in that order, which is the call PalForge already makes. Arity, order and callee are settled.
- **`spatial-saveid`** — core.spatial.saveId. PalGameInstance's full 111-property listing contains no WorldGuid, WorldSaveName or SaveName — all three probed names were wrong, which is why every save shared one persistence file. The real accessors are GetSelectedWorldSaveDirectoryName and GetSelectedWorldName, and core/spatial now reads them.
- **`building-leftclick`** — Building onLeftClick. PalBuildObject's complete 22-function list has no click, hit or attack entry. The standing candidate, OnDamage, turned out to be the deterioration timer: 196 firings on a strict 12-13 s cadence per structure, starting half a second after placement, with no player involved. Wiring the hook to it would have run every pack's handler every 12 seconds on every structure in the base.
- **`building-break`** — Building onBreak. None of PalBuildObject, PalMapObjectModel, PalMapObjectConcreteModelBase or PalNetworkPlayerComponent carries a destroy, dismantle or break function. Destruction exists only as delegate FIELDS, which RegisterHook cannot address by path. Disappearance keeps surfacing as onRemove with reason "missing".
- **`building-break-source`** — the building.break and building.leftclick channels. Same evidence, applied to the source side: neither channel is worth adding, and core/event now records why rather than carrying a hopeful TODO.
- **`icons-row-column`** — core.icons ICON_COLUMNS. The DataTable dump printed every table's real column list. Items and pals use `Icon`, buildings use `SoftIcon`, and partner skills use `TextureID_8_2B2F...`. Of the five names the code had been guessing, IconName, IconTexture and Texture are columns of no icon table on this build.
- **`item-inventory-count-readback`** — utils.items.count. Read back from a live save, not inferred: `inv.CountItemNum` is bound (a UFunction userdata), `inv:CountItemNum(FName('Wood'))` answered **135** as a plain Lua number, and the whole resolve chain printed real objects at every step (PalUtility CDO -> BP_Player_Female_C -> BP_PalPlayerState_C -> BP_PalPlayerInventoryData_C). The `CountItemNum64` fallback is gone — a second spelling was only ever there for a return shape that turned out to be a number. *(This entry used to end "reading an inventory is the one item capability that fully works today". That was true when it was written and is not now: give and take are both measured, below.)*
- **`audio-volume-rtpc`** — Audio.Handle:setVolume. Settled NEGATIVELY, which is still settled. The routes all exist (UPalSoundUtility reflects SetRTPCValueByActor / SetRTPCValueByActorByEnum; AkGameplayStatics reflects SetRTPCValue / GetRTPCValue / ResetRTPCValue), but the build declares exactly **three** AkRtpc assets — Supply_Altitude, OverHeatRifle, ChargeLaserRifle_01 — plus zero AkAuxBus and zero AkAudioBank. None is a volume, so there was never a parameter for those functions to address and no parameter list would have helped. Do not re-probe them. The capability moved to `audio-bus-volume`, which is a different call with a different contract.
- **`spawn-actor-conventions`** — core.spawn.actor. `dumps/cxx/Engine.hpp` declares both halves of deferred spawning outright: `BeginDeferredActorSpawnFromClass` takes FIVE parameters (world context, actor class, transform, collision handling, owner) and `FinishSpawningActor` takes TWO (actor, transform). Neither has the UE 5.3+ scale-method argument this file used to try first. So the four guessed argument conventions were never all callable — three of them could not have worked on any build — and the guess chain is replaced by the one declared shape. Still unobserved end to end, and now honestly gated: both calls take a struct, so `core/signature.lua` only fires them when the live parameter walk succeeds.
- **`mesh-static-setstaticmesh`** — Mesh.Handle:attachTo on kind="static". `dumps/cxx/Engine.hpp:21720` declares `bool SetStaticMesh(UStaticMesh*)` on UStaticMeshComponent — exactly the call being made. The same listing settles the READ-BACK, which was the harder half: there is no reflected `GetStaticMesh` anywhere in the dump, and the asset is reachable only as the UProperty `StaticMesh`. The old two-path check had a first branch that could only ever raise; it is now the property.
- **`mesh-detach-destroycomponent`** — Mesh.Handle:detach. `Engine.hpp:9972` declares `void K2_DestroyComponent(UObject* Object)` on UActorComponent — one object argument, the component itself, which is what both call sites already passed. The two sites are now one shared `Renderer.destroyComponent`.
- **`mesh-skeletal-setter`** — Mesh.Handle:attachTo on kind="skeletal" and Pal.Handle:renderOn. The class ladder is confirmed end to end — `APalCharacter : ACharacter`, whose `Mesh` is a reflected `USkeletalMeshComponent*`, and `UPalSkeletalMeshComponent` derives from it. Two guesses collapsed: `actor:GetMesh()` is not declared anywhere in the dump, and the two mesh setters are inherited by the SAME component, so the second was never a fallback. One route remains, `SetSkinnedAssetAndUpdate(asset, true)`, chosen because it re-initialises the pose, with the getter that pairs with it for the read-back.
- **`mesh-skeletal-animclass`** — Mesh.Spec.animClass. All three assumptions confirmed: `SetAnimClass(UClass*)`, `SetAnimationMode(TEnumAsByte<EAnimationMode::Type>)`, and `EAnimationMode::AnimationBlueprint = 0`. The calls were already right, and the log line claiming "SetAnimClass is not on this component" was simply wrong. The real weak link turned out to be elsewhere and is recorded in its place: `SetAnimClass` wants an AnimBlueprintGeneratedClass, and the one live asset sweep on disk found zero loaded while the classes plainly exist — so what is unproven is the LoadAsset resolve, not the call.
- **`mesh-texture-import`** — Mesh.Spec.texture. `Engine.hpp:14694` declares `UTexture2D* ImportFileAsTexture2D(UObject* WorldContextObject, FString Filename)` on UKismetRenderingLibrary. Both halves of the unknown are answered: the world context is a plain `UObject*`, so the actor already being passed qualifies, and the path is an FString — an ordinary Lua string, and NOT the FName shape that kills the process.
- **`effect-native-status`** — Effect.Spec.nativeStatus. **Observed working in a loaded save**, 2026-07-26: `status.add AttackUp (EPalStatusID 26) [declared]`, the game reading the ailment back as present, then `status.remove` and the game reading it back as gone. The route is `PalCharacter.StatusComponent` -> `UPalStatusComponent::AddStatus(EPalStatusID)`, and the vocabulary that previously had no source anywhere on disk is `EPalStatusID`'s 38 names. One thing had to change to get there and it generalises: those parameters are declared **EnumProperty**, not ByteProperty — an `enum class`, not a legacy `enum` — and `core/signature.lua` refused three correct calls over the spelling until it learned the two marshal identically. Every `EPal*` argument in this tree is an enum class.
- **`pal-spawnmonster-signature`** — Pal.Handle:spawn. **Observed working**, 2026-07-26. The call was never broken: `cm:SpawnMonster(FName("ChickenPal"), lv)` was issued with `[evidence declared]`, meaning `core/signature.lua` walked the real UFunction on the installed binary and matched it. What was broken was the VERDICT around it — a spawn that arrives after ~5.9 seconds was measured synchronously with a stopwatch stopped at 1.2 s, and the miss was reported as a property of the build. Three hypotheses died with it, including the server-authority one, which had been invented to explain an observation that never happened. `:spawn` now returns whether the call was ISSUED, because arrival is seconds away and no caller can block; the arrival line follows in the log, with elapsed seconds.
- **`pal-spawn-placement`** — core.spawn.palAt. **Observed end to end, twice, in the same press**: `placed new pal at (-345296,263050,4153); it reads back (-345296,263050,4153), off by 0`. Every half that had never been seen is now seen — the pal appears, the nearest-to-player anchor picks the right one, `K2_TeleportTo` accepts it, and the read-back is exact rather than approximate.
- **`icons-row-read`** — core.icons.resolve, and every domain's `:iconOf()`. **Observed working**, 2026-07-26, on every icon table at once: 674/674 pal, 1183/1207 item, 567/571 building, 311/311 partner skill. (The item table's 24 blanks are rows that genuinely carry no icon.) Three wrong turns, each worth remembering: the row accessors are not UFunctions and not on `UDataTable` — UE4SS binds them itself; the value in an icon column is a `TSoftObjectPtr` userdata that answers none of the nineteen member names a soft pointer could plausibly expose, so the struct cannot be opened from Lua; and the string column that replaces it delivers its elements wrapped in **RemoteUnrealParam**, with the real value behind `:get()` — which is what made the array read the right LENGTH with nothing in it.
- **`item-additem-signature`** — Item.Handle:give. **Observed working**, 2026-07-26: `give Wood x3: 140 -> 143`, with the game's own pickup event firing beside it (`Wood onObtain: count=3`) — two independent witnesses in a real save. The whole project was blocked on ONE argument. The live declaration is `(FName StaticItemId, int32 Count, bool IsAssignPassive, float LogDelay, bool bNotifyLog) -> EPalItemOperationResult` — five arguments and a return, where `dumps/cxx/Pal.hpp` has four and no `bNotifyLog` at all, because the dump predates the installed binary by one game patch. UE4SS counts the return as a slot, which is where "expected 6 parameters, received 4" came from. It also ANSWERS, with a named `EPalItemOperationResult`, so a refusal now explains itself instead of being inferred from a count that did not move.
- **`pal-icon-row`** — Pal.Handle:iconOf. Closed with `icons-row-read`: DT_PalCharacterIconDataTable read 674 of 674 rows in a live save, so a vanilla pal id resolves to the game's own artwork and the declared `icon` is the fallback it was always described as.
- **`skill-icon-key`** — Skill.Handle:iconOf. Same read, 311 of 311 rows on DT_partnerSkillIconDataTable. What is left is not a read but a KEYING fact already recorded in core/icons: that table is keyed by PAL id, not skill id, so only a pal-derived partner skill can hit it. A passive skill has no row there and falls back to its declared icon — the correct answer rather than a missing one.
- **`ui-host-paths`** — native.ui.widget / UI.Handle:mount into the game's own UI. `WBP_PalOverallUILayout` declares `UCanvasPanel* CanvasPanel_Root`, and a UCanvasPanel is a UPanelWidget, so it answers `AddChild` with a `UCanvasPanelSlot`. Live-confirmed: an instance is alive under BP_PalGameInstance with its own WidgetTree. Eliminated on the way: `UPalUIHUDLayoutBase` has **no widget members at all**, so the child "one level down" everyone was looking for never existed — it exposes `AddHUD` instead.
- **`audio-bus-volume`** — Audio.Handle:setVolume. The dump overturned the item's own premise. `UAkGameplayStatics::SetOutputBusVolume(float BusVolume, AActor* Actor)` takes **no bus name**: the second parameter is the Wwise game object, so it scales what ONE emitter sends to its bus, at exactly the scope `PlayAkEventSoundByActor` posts on. It was filed as bus-global and is not. Three other overloads were found and rejected with reasons. Wired as `setVolume(volume, actor)`, actor-wide by construction, exactly like `:stop`. Audibility is owed — nobody has heard it; that is `pf_hook audio-setvolume-audible`.
- **`item-remove-call`** — Item.Handle:take. **Observed working**, 2026-07-26, in the same press that proved give: `give Wood x3: 161 -> 164` then `take Wood x3: 164 -> 161`. A pack can charge a cost, and the items are CONSUMED rather than dropped — nothing lands at the player's feet to be picked straight back up, which is what made the DropItem route useless for this. The route is `APalWeaponBase::RequestConsumeItem(const FName&, int32)`, and the reason it went unfound for so long is that nobody thought to look on a WEAPON: the inventory's own class chain has no subtract, and neither does the container, the slot, or the cheat manager. The same weapon class declares `IsExistBulletInPlayerInventory`, so a weapon demonstrably reads and spends the owning PLAYER's bag. Both of the questions left open when it was wired are answered by that one press — it spends the id it is HANDED rather than the weapon's ammunition, and the weapon need only be spawned, not equipped. One real constraint remains and is reported as its own message: a player carrying nothing has no weapon actor to ask.
- **`mesh-material-params`** — Mesh.Spec.color / texture / params, Mesh.Handle:setColor. The names were **read off the running game**, 2026-07-26, because a header dump never could have said them — a CXXHeaderDump records classes, and which parameters an asset exposes is data inside a `.uasset`. Following each MaterialInstanceDynamic on the player's `CharacterMesh0` up to its MaterialInstanceConstant gave: vector `BaseColor`, `Subsurface Color`; texture `Base Texture`, `MetallicRoughnessOcclusionSpecularTexture`, `Normal Map`, `Subsurface Texture`; scalar `Character CameraFade Distance`, `Occlusion Add`, `Roughness Add`, `Light Affect Subsurface Max`, `RefractionDepthBias`. Mostly Title Case WITH SPACES, which no guess had — except `BaseColor`, which was already in the colour list, so tinting had a real chance all along while the texture list had none. Note that only two of those eleven are in `Renderer.TEXTURE_PARAMS`; the rest are reachable through `params` only. Still owed: nobody has watched a colour actually change — `pf_hook mesh-color-change`.
- **`mesh-base-material`** — the material a procedural mesh is parented to. Closed by the same read. `dumps/reflection/05_assets.txt` never swept Material, so not one material in this tree was known to be LOADABLE and five plausible `/Engine/` paths were five guesses. A material that is currently RENDERING is cooked and shipped by construction — the player's own outfit instance now leads the candidate list and carries the `BaseColor` vector a tint needs. It is a character shader hung on a procedural cube, which is odd and is said plainly at the list rather than hidden; a working material that looks wrong can be improved, an unloadable one cannot be used at all.
- **`item-craft-source`** — Item.Spec.Events.onCraft. **Observed live**, 2026-07-26: crafting at a real machine reaches `OnFinishWorkInServer` on one of the two work models that carry an item id, and the channel was seen carrying its first event in a real save. Wired on the header dump alone — neither class is among the 21 in the live reflection dump — and now reproducible by crafting anything. `ctx.count` stays nil: the count lives in the recipe row, and a hook is no place for a DataTable read.
- **`item-discard-source`** — Item.Spec.Events.onDiscard. **Observed live**, 2026-07-26, with the slot resolving to a real item id. Two separate things had to be right. A drop does NOT go through `AddItem_ServerInternal` — that hook was armed and fired zero times across two sessions, because dropping goes through `UPalNetworkItemComponent`, one class over from everywhere the search had looked. And the container holding the dropped slot is not necessarily one the player's inventory helper lists: the first live firing reported "no container of the player's 6 matched", so the set comes from a world sweep now. The GUID match is exact, which is what makes the wider search safe.
- **`skill-activate-source`** — Skill.Spec.Events.onActivate. **Observed live**, 2026-07-26, in real combat: `skill.activate carried its first event from source "PalActionBase:OnBeginAction"`. The source that works is the ACTION OBJECT, not a utility that builds one — a pal's move IS a `UPalActionWazaBase` and carries its own `EPalWazaID`, so hooking it puts the identity a handler needs on `self` rather than in someone else's argument list. `PlayActionByWazaID` stays armed as the control that proved it: it registered successfully and carried nothing while a pal fought and killed another pal, which is what sent the search to the action side. A third source, `PalPlayerCharacter:OnBeginAction`, is armed and player-only; `ctx.via` names whichever carried.
- **`pal-spawned-hook`** — Pal.Spec.Events.onSpawned. **Observed live**, 2026-07-26, from BOTH new sources: `PalNPC:OnCompletedInitParam` and `PalPlayerCharacter:OnCompleteInitializeParameter`. They are the bound TARGETS of the initialise broadcast, not the broadcaster — which was hooked first, registered fine, and never carried anything. That is the general lesson and it is worth keeping: RegisterHook sees what ProcessEvent runs, and a broadcaster is not it.
- **`skill-passive-source`** — Skill.Spec.Events.onEquip. **Observed live**, 2026-07-26: `skill.equip carried its first event from source "AddPassiveSkill"`. The write that triggered it came from PalForge itself — `core/character.addSkill` put a passive on a live `BP_ChickenPal_C` and read it back — which is a useful property in its own right: the source catches a pack's own writes as well as the game's. It also confirms the passive half of `pal-skills-equip` on the way past. What is still unsettled is which call the GAME uses when a player changes a passive at a bench; `SetupSkillFromSelf` stays armed beside it and has carried nothing yet. ⚠️ **The unequip DIRECTION has never been recorded firing from any source.** `skill.unequip` is wired and expected to carry, on the same class and armed the same way — "observed" belongs only to equip, and both `api/skill.lua` and the docs now say exactly that.
- **`ui-menubutton-inner-slot`** — native.ui.widget.menuButton label alignment. **Answered negatively**, 2026-07-27, by reading the button class's own template tree: `HorizontalBox_0` IS in a `WBP_Title_MenuButton` and its slot is a `CanvasPanelSlot`. The name was never stale — the slot is simply the one kind that cannot do this. A CanvasPanelSlot declares no `SetHorizontalAlignment` (`UMG.hpp:350-374`) where the other five slot classes do, so `core/signature` refused the call every time, correctly, and the label has always stayed centred. The alignment it DOES declare takes an `FVector2D`, and a struct argument is the shape that faults inside UE4SS marshalling. The function is deleted rather than left to be refused forever: a refusal logged on every button build reads like a defect and is not one. A left-aligned label is now reachable a different way — `labelAlign = "left"` routes through `_widget.clickableRow`'s Overlay.

### Settled without the game, 2026-08-02 (14)

These are the Foundations findings. Each is **verified by reading plus the headless suite** —
`luac5.4 -p` clean on all 147 files under `Scripts/` and `tools/` (145 + 2), `450 passed / 0 failed /
31 skipped (481 total)`, the 8-check startup bundle green, and in several cases a purpose-built
headless harness. None was observed live, and where a live confirmation is owed it is named. The
measurement that shaped each fix is in **Foundations** above; this list is the index.

- **`F-1` — silent id overwrite.** Closed by the entry record + three logging cases in
  `core/object_manager.lua`, and by `isRegistered`/`owner`/`entry` as the public answer to "is this
  id taken?". Verified by 18 new checks in `test/cases/registry.lua` driving a log sink, plus 8 in
  `test/cases/definitions.lua`.
- **`F-2` — `resolve()` not injective.** Closed by the resolved-form index maintained at register
  time (warns naming both source ids) and by three `byResolved` dispatch sites in `core/event.lua`
  replacing a `pairs()` walk whose winner varied between sessions. Verified by test and by reading
  the three call sites.
- **`F-3` — resolve applied at five boundaries and skipped at five others.** Closed at every
  skipping site. Verified by grep over every boundary plus the audio and iconOf test cases.
- **`F-4` — an unresolvable id defined, registered and was dead.** Closed at define time
  (`om.validId`, all eight domains raise) and at the boundary (literal fallback + warn). Verified by
  running each domain's refusal through `lua5.4` and diffing the message.
- **`F-5` — F9 split the building runtime from its registry.** Closed by `object_manager` in `KEEP`,
  the runtime on `_G`, and the five drivers re-entering the current module. Verified by two headless
  harnesses (26 + 8 assertions), and the `_G` half re-confirmed headlessly on 2026-08-02 with
  `debug.getupvalue`: the scan's `Registry` and the dispatch's `Registry` are one table, and it is
  `_G.__PalForgeBuildingRegistry`. **Live confirmation owed** — `pf_hook building-runtime-reload`,
  run either side of an F9.
- **`F-6` — the ownership model was wired to nothing.** Closed for identity: `PalForge.pack(...)`,
  `withPack`/`currentPack`, owner recorded at register, `checkOwnership` consulted. **Partially
  open:** `checkImport` still has no producer — see Owed work §1.
- **`F-7` — records carried no owner and orphans accumulated forever.** Closed by `v`/`def`/`pack`
  per record, a deterministic `refreshDefs`, and quarantine-not-delete with a 30 s grace and a 4096
  cap. Verified by reading and by the events suite. **Live confirmation owed** —
  `pf_hook building-record-orphans`, ~35 s after a save loads. The working-tree run was against the
  `"world"` FALLBACK bucket, not a named save; see F-7.
- **`F-8` — reading a native catalog started persisting world state.** Closed by
  `X(spec, { register = false })` in all eight domains and the publish gate in all six catalogs.
  Verified by measurement: six catalogs load, 15 classes register, **zero buildings**, a read
  changes the count by 0.
- **`A-1` — per-object tables keyed on a UE4SS handle.** Closed by `uo.key` at nine sites, two of
  which (`api/effect.lua`'s `apps`, `api/skill.lua`'s `lastFire`) were live bugs the audit had not
  found — effect stacking was broken and skill `cooldown` did nothing at all for an engine owner.
  Verified by two new two-handles regression tests plus the mesh suite. **Live confirmation owed** —
  `pf_hook mesh-actor-identity`, which is the whole finding in one run.
- **`A-2` — a declared `Building{ mesh = ... }` never attached itself.** Closed by the re-keyed fast
  path; `_meshPending` is now consumed, and `bound.pos` and `spatial.indexUpdate` run again.
  Verified headlessly end to end. Same hook.
- **`A-3` — the sound loader was the un-hardened twin of the mesh loader.** Closed by `normalize` +
  an `AkAudioEvent` class check + `core/signature` on the play call. Verified by reading and by a
  world-gated test that hands it a wrong-typed asset (a crash there means the check is gone).
- **`A-4` — a pack could not ship a path.** Closed by `utils.file.packDir` / `resolvePackPath` and
  `Mesh.Spec:validate`. Verified by test. Three sites still resolve nothing, for one structural
  reason, all documented — see A-4 above.
- **`A-5` — imported textures were re-imported per attach.** Closed by a positives-only path cache.
  Verified by reading; **unobserved**, because `ImportFileAsTexture2D` has still never been called.
  **Live confirmation owed** — `pf_hook mesh-texture-import-live`, which decides the cache with a
  `rawequal` on the `resolveTexture` return, i.e. at the seam `writeMaterial` actually uses.
- **`A-6` — no "validate my declared assets" pass, and attach threw the diagnosis away.** Closed by
  `Mesh.validateDeclared()` at world.ready plus `false, reason` on every mesh action. Verified by
  test and by tracing the call site.

---

## Open (8)

Six of these are the long-standing items. **Two are new on 2026-08-02** — `item-satiety-write` and
`skill-projectile-spawn`, the second entries under Item and Skill. They were the two bare `TODO:`
comments Owed work used to complain about; giving them ids also made them Open items, because each
is a public capability a pack can already declare and neither does what an author would assume.
**Both markers previously stated something false about the code, and both corrections are the
interesting part:** the facts they said had never been found are in the dumps this tree already
ships, and what is actually missing in each case is one unread parameter list.

### Pal

#### `pal-skills-equip` — Skill.Handle:teach / :forget, Pal.Handle:teachAll

- **Hook:** `pf_hook pal-skills-equip` (`test/hooks/pal_skills_equip.lua`) — needs a world and a
  pal, **writes**, so it needs `env.debugHooks["pal-skills-equip"] = true` as well
- **Marked at:** `Scripts/palforge/core/character.lua:79`, and again at `:726` on `clearSkills`

**What a pack author sees**

`Skill.get("FireBlast"):teach(pal)` may return false and the pal may not learn the move. When it
works, the pal really does carry it — every write here is verified by reading the character back,
so a true is never "the call ran".

**Reading a pal's skills WORKS** — confirmed 2026-07-26 on a live `BP_SheepBall_C`:

```text
skills: the nearest pal carries 3 active, 1 passive, 3 equipable, 0 mastered
```

The whole route answers: actor → `PalUtility` → individual parameters → **four** getters, with a
real pal's real loadout coming back. `Skill.Handle:skillsOn(actor)` is usable today, and it returns
four keys, not two. `equipable` and `mastered` answer **nil for UNKNOWN** rather than an empty list,
because `GetMasteredWaza` is not in the class's declared list (`HasMasteredWaza(EPalWazaID)` is) —
so `#(s.equipable or {})` is the idiom, and a `0` and a `nil` mean different things.

That took several runs for a reason worth keeping: `FindAllOf("PalCharacter")` is too wide.
`APalMonsterCharacter : APalNPC : APalCharacter`, so it matches villagers and merchants too, and an
NPC has no equipped move. Asking one of those reported zeros that looked exactly like a broken
reader. **Ask `PalMonsterCharacter`** — which the hook does, and it refuses to write unless
`uo.isA(target, "PalMonsterCharacter")`.

**⚠️ Writing a move correlates with a crash — but the target may have been wrong**

The first run that did it — `AddEquipWaza` firing with evidence `declared`, the read-back not
showing the move, `RemoveEquipWaza` firing — was followed about 1.4 seconds later by Palworld
closing, part way through the mesh suite. The run before it, with no pal nearby, completed.

It is now known that the write did not necessarily go to a pal: it used the old search, and the
read-back it consulted afterwards was an NPC's empty list — which is also why it concluded the
write had not landed. Putting an equipped MOVE on a villager is a far more plausible way to
destabilise the game than putting one on a pal, so the crash may say nothing about this capability
and everything about that target.

The search is fixed and the experiment has not been re-run. It stays **opt-in** anyway: the
correlation is unexplained rather than explained away, and this writes into a character in a real
save.

**What is still unknown**

Only whether the ACTIVE writes land. The passive half is proven — closing `skill-passive-source`
required `core.character.addSkill` to put a passive on a live `BP_ChickenPal_C` and read it back.
Everything else is settled by `dumps/cxx/Pal.hpp`:

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
inside UE4SS marshalling, and every write has a matching read that proves it landed. The enum
spelling question is settled: these parameters are `EnumProperty`, and `core/signature.lua` accepts
it.

Settled alongside it: **the vocabulary**. `EPalWazaID` (`dumps/cxx/Pal_enums.hpp`) names **309**
active skills — measured, `core.character.wazaNames()` returns 309 — which is what
`Pal{ skills = { ... } }` can contain. Active skills are an enum and passives are FNames, a real
distinction a caller cannot paper over, so `:teach` routes on which one the id is rather than on the
skill's declared `kind`. Read-backs compare the **canonical** `EPalWazaID` name, so a lower-cased or
integer id no longer reports a landed write as missing.

**What the hook prints**

It counts the non-pal `PalCharacter`s in range first, to quantify how wide the old search was; then
states the risk before writing; then covers, each with a read-back, `Skill:teach`/`:forget`,
`teachAll`'s `taught, asked` partial-result contract (including a no-actor control that writes
nothing), and `clearSkills` with capture and restore. It sweeps at the end and re-verifies the pal
ended as it was found. It should also print all four of `skillsOn`'s lists and say which came back
nil, because whether `GetMasteredWaza` exists on this build is unmeasured.

**What has no coverage in the F1 suite, gated or otherwise**

- `test/cases/skill.lua:585` is the ONLY automated check of the active-move write, and it is gated.
- `Pal.Handle:teachAll` (`api/pal.lua:553`) now has three pure checks over the `taught, asked`
  contract (with `core.character.addSkill` swapped for a recorder and always restored) and a fourth
  that always skips, naming this hook. The live half is the hook's.
- `core.character.clearSkills` (`core/character.lua:735`) still has no caller and no check outside
  the hook — same unverified-write class as the rest of this item.

### Item

#### `item-datatable-row-read` — Item.Handle:recipeOf (the :iconOf half is CLOSED)

- **Hook:** `pf_hook item-datatable-row-read` (`test/hooks/item_datatable_row_read.lua`) — needs a
  world, read-only. `item-recipe-of` is folded into it and the hook's own `item =` field says so
- **Marked at:** `Scripts/palforge/api/item.lua:223`, and the marker itself now says RECIPE half only

**Halved 2026-07-31, and the source comment corrected 2026-08-02.** This item used to say "the live
table is never actually read" and to own both halves. That is no longer true of icons:
`icons-row-read` (Closed) read 1183/1207 item rows in a live save, and `Class:iconOf` calls
`icons.resolve` first and falls back to `self.icon` only on a miss. **The accessor question is
answered too** — UE4SS binds `dt:FindRow(<plain Lua string>)`, `dt:GetRowNames()`, `dt:GetRowMap()`,
`dt:GetAllRows()` and `dt:ForEachRow()` onto UDataTable itself, which is why every reflection sweep
missed them (`dumps/cxx/Engine.hpp` shows UDataTable declaring five properties and ZERO functions).
See the measured write-up at `core/icons.lua:317-339`. The stale claim in `api/item.lua` that
reading a row "has never been observed to work from Lua on this build" is gone.

**What a pack author sees**

`recipeOf()` returns nil for every vanilla item even though `DT_ItemRecipeDataTable_Common` has
1414 rows keyed by exactly the item ids the API takes. `api/item.lua:204` returns `self.recipe` and
never reaches the game.

**What is still unknown — and it is not the accessor any more**

A recipe row is a 15-field struct of ints and FNames. The only row VALUE this tree has ever read was
a single `TSoftObjectPtr` column, and it was read the long way round, because that userdata answers
none of the nineteen member names a soft pointer could plausibly expose. So the open question is:

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

**What the hook prints**

Both routes, side by side. `dt:FindRow('Arrow')` (plain Lua string, one argument), the `type()` of
the result, and — when non-nil — Product_Count, WorkAmount, Material1_Id and Material1_Count each as
`name -> tostring(value)` plus `type(value)`. Then, as the control, the same four column names
through `GetDataTableColumnAsString(dt, FName(col))` zipped against `dt:GetRowNames()` — the route
`core/icons.lua` already proves works — printing the `Arrow` element **raw and `:get()`-unwrapped**,
because RemoteUnrealParam is exactly the trap that made the icon array read the right length with
nothing in it. Whichever answers is the implementation; if both do, the struct route is one call
instead of thirteen.

#### `item-satiety-write` — a food or heal item a pack declares itself

- **Hook:** `pf_hook item-satiety-write` (`test/hooks/item_satiety_write.lua`) — needs a world and a
  player pawn, **writes**, so it needs `env.debugHooks["item-satiety-write"] = true` as well
- **Marked at:** `Scripts/palforge/native/items.lua:559`

**What a pack author sees**

`Item.Spec` carries nine fields — id, name, description, category, maxStack, icon, recipe, events,
data — and not one of them is a restore amount, so the only way to react to a use is `events.onUse`,
which is handed a ctx and whose return value is discarded. The vanilla berry restores satiety
because the GAME restores it: `item.use` is dispatched off `UseItemToCharacter_ServerInternal`, a
call PalForge HOOKS rather than makes. So an author's own food item logs, and the bar moves only
when the row it named was already a consumable. There is no way to write "restores 40 satiety" and
have it mean anything.

**What is still unknown — one parameter list**

What argument `SetFullStomach` takes. The live reflection listing names it on
`/Script/Pal.PalIndividualCharacterParameter` (`dumps/reflection/02_reflection.txt:1298`, inside the
class block that opens at `:1107`), and that is the SAME object `core.character.paramsOf(actor)`
already hands back, through `PalUtility::GetIndividualCharacterParameterByActor`
(`dumps/cxx/Pal.hpp:32340`) — a route this tree proved by reading a real pal's four move lists. But
the CXX dump's class body (`Pal.hpp:20822-21161`) declares only the READERS: `GetMaxFullStomach`
(`:21095`), `GetFullStomachRate` (`:21106`), `GetFullStomach` (`:21108`). The setter is reflected
and undeclared, so its parameter list has never been read and `core/signature` has nothing to check
a call against.

**HP is a separate and worse case**, kept apart because the two fail for different reasons. The HP
writes ARE declared: `UPalCharacterParameterComponent::SetHP` (`Pal.hpp:15933`), `::AddHP`
(`:16018`), `UPalIndividualCharacterParameter::AddHP` (`:21156`). All three take `FFixedPoint64`, a
STRUCT (`{ int64 Value; }`, `Pal.hpp:120-124`) — the argument shape that faults inside UE4SS
marshalling where pcall cannot see it, the same refusal that gates `core/spawn.lua`'s `M.actor` and
that ended `ui-menubutton-inner-slot`. The one exception is `::AddHPByRate(float Rate)`
(`Pal.hpp:16016`): a single plain float, callable today, and never once called.

**What the hook prints**, in this order and no other, on a throwaway save:

1. `GetFullStomach` / `GetMaxFullStomach` / `GetMaxHP` / `GetHP` off `core.character.paramsOf(pawn)`
   — pure reads on a proved route; if they do not answer, nothing below is worth attempting. The
   return TYPES differ and the hook must say which it got: the floats and the int32 arrive as
   numbers, but `GetHP` returns `FFixedPoint64`, so the number is behind its one `Value` field. A
   struct RETURN is not the hazard a struct ARGUMENT is — nothing is being pushed — but it is the
   difference between reading an HP and reading a wrapper, the same trap `RemoteUnrealParam` set for
   the icon column.
2. `core/signature` **describing** `SetFullStomach` on that live object — the parameter walk, not a
   call. **That list is the finding**, and it is the one thing the CXX dump cannot supply.
3. `AddHPByRate(-0.1)`, then `GetHP` read back. One float, so it is the safe write, and it settles
   whether this surface writes at all independently of the struct question.
4. ONLY IF step 2 reported a non-struct parameter list: `SetFullStomach`, then read back.
   ⚠️ Nothing taking `FFixedPoint64` may be called here.

**Is the current return honest?** Yes — this is a missing capability, not a defect. No field and no
method on the item surface claims to feed or heal, and the comment above the berry says which half
of its effect is PalForge's. The honesty risk is entirely future: an `Item.Spec.restores` field
added before step 4 answers would be a promise this build has not been shown to keep.

### Skill

#### `skill-hit-source` — Skill.Spec.Events.onHit

- **Hook:** `pf_hook skill-hit-source` (`test/hooks/skill_hit_source.lua`) — needs a world,
  read-only; it confirms a negative
- **Marked at:** `Scripts/palforge/api/skill.lua:118`

**What a pack author sees**

`onHit` never fires. Everything else about a skill works — `onActivate` fires and the handler gets
the move's identity, `onEquip` fires, and `onUnequip` is wired on the same class.

**Both hooks are measured silent, and they rule out different things**

- `MakeDamageInfoByWazaType` — silent while a pal fought and killed another pal.
- `PalAnimNotifyState_AttackCollision:OnHit` — silent in that same session, and silent again in a
  session where the player killed a pal by hand. `pal.damaged` and `pal.death` both carried, so a
  blow certainly connected and certainly did damage.

A hit does not reach either, from either side.

**What that leaves is not another hook**

`skill.activate` works and carries the waza id. `pal.damaged` works. And nothing in the damage path
carries a waza at all — `FPalDamageInfo` has 40 fields, `FPalDamageRactionInfo` 6,
`FPalDamageResult` 12, and not one is an `EPalWazaID`. So the id can only reach a hit by being
remembered from the activation that preceded it and attributed to the damage that follows.

That is **inference, not a source**, and wiring it as one would be wrong: a move that misses, a
second pal attacking in the same window, or damage from anything else would all be attributed to
whatever activated last. If it is ever built it belongs behind a name that says so — a correlated
guess a pack opts into — and never on `onHit`, which promises the game told us.

**What the hook prints**

It re-reads the three damage structs out of the *running* build looking for any waza field (the
40/6/12 counts above came from the dump, not the live binary), then counts `skill.hit` against
`pal.damaged` and `skill.activate` for 120 s and **quantifies the ambiguity**: how many damage
events had zero activations in the correlation window, and how many had more than one. Those two
numbers are the argument against ever wiring the inference, expressed as data.

#### `skill-projectile-spawn` — an active skill that puts something in the world

- **Hook:** `pf_hook skill-projectile-spawn` (`test/hooks/skill_projectile_spawn.lua`) — needs a
  world and a pal, **writes**, so it needs `env.debugHooks["skill-projectile-spawn"] = true` too
- **Marked at:** `Scripts/palforge/native/skills.lua:652` (inside the curated `FlameThrower`'s
  `onActivate`, which is the demonstration)

**What a pack author sees**

`Skill{ kind = "active", element = "fire", power = 50 }` defines, registers and dispatches, and
`onActivate` runs at exactly the right moment on a REAL activation — that half is measured. But
`element` and `power` are framework-side metadata that reach nothing (their `doc =` strings say so
now, in the same words `Item.Spec.Recipe` uses), and the handler has no call available to it that
puts an object in the world. A pack's active skill is a well-timed Lua function, and that is all it
is. `Skill.Handle:activate` returns `true` for the curated FlameThrower and stamps a cooldown;
`native/skills.lua` logs one warn per session saying plainly that nothing was spawned.

**What is still unknown — whether a STRUCT can be marshalled at all**

Everything else on the path is already read:

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

**What the hook prints**

1. `core/signature` **describing**, not calling, each of `ShootOneBulletDefault`, `ShootOneBullet`,
   `CreateChildSkillEffect` and `BeginDeferredActorSpawnFromClass` on live objects, with the
   parameter list the running build reports for each. Whether the walk answers "declared" for a
   `StructProperty` is the finding, and it settles `core/spawn.lua`'s `M.actor` at the same time.
2. `ShootOneBulletDefault()` on a live `APalMonsterEquipWeaponBase`, and whether an `APalBullet`
   comes back. Zero arguments, so this is the safe call and the one thing that can be tried before
   step 1 answers.
3. Only if step 1 reported "declared" for a struct parameter: spawn an `APalSkillEffectBase`
   subclass through `M.actor`, `Initialize` it, and say whether anything appeared.

⚠️ Do not push a hand-built `FVector` or `FTransform` at a call whose declaration the walk could not
read.

**Is the current return honest?** The DOC carries the meaning and it does say the right thing:
`api/skill.lua:427-434` defines `Handle:activate` as false for a passive, false when the cooldown
blocked it, false when the handler raised, and otherwise "the handler ran to completion". It
promises nothing about the world. What a boolean CANNOT express is the case this definition is in —
the handler ran, deliberately, and produced nothing — so that is said in a log line instead. See
Owed work §1.

### Audio

#### `audio-custom-file-loader` — Audio.Spec.soundFile

- **Hook:** `pf_hook audio-custom-file-loader` (`test/hooks/audio_custom_file_loader.lua`) — needs a
  fully loaded save, read-only
- **Marked at:** `Scripts/palforge/core/sound/file.lua:56`

**What a pack author sees**

A hard error at define time, naming this item. That is the change: `soundFile` used to be accepted,
validated, documented and to take precedence over `soundId`/`soundPath`, so a pack that shipped its
own `.wav` got silence — and worse, setting `soundFile` beside a working `soundId` silenced that
too, because the file route won. Now the definition refuses and says why.

`core/sound/file.lua` is therefore unreachable from any definition. `FileSource:play` is still
`return false` rather than an error, and the header names the two deliberate routes that can still
reach it: a `source` override, and a direct `core.sound.resolve`.

**What is still unknown**

```text
TODO(audio-custom-file-loader): it is unknown whether the shipping build exposes ANY
runtime loader that turns a file on disk into something playable (a USoundWave/USoundBase
factory, or a Wwise external-source / SetMedia entry point); enumerating the audio-related
CDOs' reflected functions would settle whether such a call exists at all.
```

**What the hook prints**

All five blocks, verbatim, and it prints nils rather than skipping them — **a run of nils closes
this item permanently.** (1) class existence for `/Script/Engine.Default__SoundWave`,
`…Default__SoundBase`, `…Default__GameplayStatics`, `/Script/AkAudio.Default__AkExternalMediaAsset`,
`…Default__AkMediaAsset`, `…Default__AkGameplayStatics`, each as `path, object, GetFullName`, with a
`type(StaticFindObject)` guard so "class absent" cannot be confused with "no lookup available".
(2) if GameplayStatics resolved, its COMPLETE function list — we are looking for PlaySound2D /
CreateSound2D / SpawnSoundAttached surviving in shipping. (3) for any AkAudio class that resolved,
every function name containing External, Media, Source, Post or Load, each with its properties'
name + class + offset. (4) `type(NewObject)`, `type(StaticConstructObject)`,
`type(StaticConstructObject_Internal)`, so we know whether UE4SS Lua in this build can construct a
USoundWave at all. (5) `#(FindAllOf('SoundWave') or {})` and `#(FindAllOf('AkMediaAsset') or {})` —
whether the shipping game has any instance of either class loaded is itself an answer about whether
that pipeline is alive.

### UI

#### `ui-update-event` — UI.Handle:autoRefresh(ms): polling is the only refresh driver PalForge has

- **Hook:** `pf_hook ui-update-event` (`test/hooks/ui_update_event.lua`) — needs a world, read-only,
  but the operator has to open and close screens while it watches
- **Marked at:** `Scripts/palforge/api/ui.lua:1673` (inside `Handle:autoRefresh`, which starts at
  `:1658`)

**What a pack author sees**

Nothing calls refresh() for a pack. Every element must either call `:refresh()` by hand or ride the
500 ms heartbeat, so a panel shows stale content for up to `ms` and there is no way to refresh
exactly when the game rebuilds a screen. TitleMenu's whole re-injection strategy is a poll for the
same reason.

**What is still unknown**

```text
TODO(ui-update-event): unknown whether Palworld raises a catchable UFunction when a
UI is (re)built — until one is dumped, polling is the only driver PalForge has.
```

**Already eliminated, and worth not re-discovering:** `UPalUIManagerSubsystem` declares **zero**
functions. `api/ui.lua`'s marker says so and says not to enumerate it again; the hook keeps it in
the sweep anyway and explains in its own file why a 0 there is a confirmation rather than a
discovery.

**What the hook prints**

For each of `PalUIManagerSubsystem`, `PalUIHUDLayoutBase`, `PalUITitleBase`,
`PalUIInventoryEquipment`: whether `/Script/Pal.<name>` and `/Script/Pal.Default__<name>` resolved.
Then that class's UFunctions — `ForEachFunction` if available, else the `Children`/`.Next` walk —
each printed as `name::function` followed by every child property as `name class @offset`. From that
list it `RegisterHook`s every function whose name contains Open / Show / Construct / Refresh /
Update / Setup (capped at 40, with a warning that UE4SS cannot unregister a hook), each logging
`FIRED <path>` once, printed from the heartbeat in first-fire order. Then the operator opens and
closes the inventory, opens the build menu, and returns to the title screen, and pastes which paths
fired and in what order.

### Events

#### `pal-spawned-fresh` — Pal{ events = { onSpawned } } / event.on("pal.spawned")

- **Hook:** `pf_hook pal-spawned-fresh` (`test/hooks/pal_spawned_fresh.lua`) — needs a world,
  read-only; give it 30 s after the load storm
- **Marked at:** `Scripts/palforge/api/pal.lua:180` (referenced again at `:39`). It was in
  `core/event.lua` when the item was filed; the channel now fires, so the remaining doubt moved to
  the spec doc a pack author reads

**What a pack author sees**

The channel FIRES — that half is closed as `pal-spawned-hook`. What a pack cannot tell is whether a
firing means a pal that did not exist a moment ago. Every firing observed so far landed in the same
second as `world.ready`, i.e. the load storm, when every pal in range initialises at once.

**What is still unknown**

The marker, verbatim:

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

**What the hook prints**

It subscribes to the channel `core/event` already feeds and **arms no new hook of its own**, then
timestamps every firing against `world.ready` with `via`, the class name and the full name. It
prints a marker line before each of three operator actions, done one at a time: (a) release a pal
from the palbox, (b) hatch an egg or trigger a wild spawn by travelling, (c) `pf_spawn`. Paste which
markers were followed by a firing, with what class, and how far the timestamp sits from
`world.ready`. If none fires it falls back to arming `PalCharacter:BeginPlay` and every function
matching Spawn on the `PalMonsterSpawner` classes.

⚠️ Do NOT re-probe `PalCharacter:BroadcastOnCompleteInitializeParameter`. It is MEASURED SILENT,
which is what closed `pal-spawned-hook`, and hooking a broadcaster instead of the bound target is
the mistake that item exists to record.

---

## Owed work (not blocked on a fact)

Everything below is reachable with the game switched off.

**What the 2026-07-31 audit's seven sections closed**, so nobody goes looking: §1, the four `doc =`
strings that called working channels dead, is done — `api/item.lua`'s onCraft/onDiscard and
`api/skill.lua`'s onActivate/onEquip/onUnequip now read LIVE with their sources, and `types.lua` is
regenerated from them. §2, the docs site, is done: 17 pages × 3 locales rewritten against the tree,
seven new pages added (24 pages, 72 files), and `docs/scripts/lint-content.mjs` is wired to
`npm run lint:docs`, to `docs`' `prebuild`, and to two GitHub workflows — it now also enforces H3/H4
parity, internal-link targets, `meta.json` navigation, an untranslated-English check, and counts
derived from `Scripts/` at lint time. §3, the reload async guard, is done: `core/poll.lua` claims a
token per registered poller and releases it on all three retirement paths, and
`test/probes/watch.lua` brackets both raw `LoopAsync` chains, so `asyncPending()` has real callers
and the refusal branch is reachable. §4 is now five declared hooks and stays below as §2. §5 is
largely done — the summary reports skip direction and says no single run measures everything, the
five uncovered functions are covered or hooked, `tests/spawn.lua` moved to `deprecated/`, and
`Scripts/palforge/tests/` is no longer gitignored (it was, while `core/registry.lua` required it at
boot). §6 and §7 are done except for what is listed below.

### 1. Small, and each one has a decision behind it

- **`Skill.Handle:activate` discards the handler's return, and stamps the cooldown first.**
  `api/skill.lua:435-442` returns `pcall`'s ok, so a raising handler also leaves a cooldown behind.
  The doc string is honest about what `true` means; what a boolean cannot express is "ran and
  produced nothing", which is the case `skill-projectile-spawn` is in. If `activate` is ever made to
  consult the handler's return, that is the distinction it should carry.
- **Three constructors hand-roll their `opts` parsing.** `api/building.lua`, `api/mesh.lua` and
  `api/ui.lua` read `register`/`pack` inline instead of calling `schema.defineOpts`, so a misspelled
  option key — `{ regsiter = false }` — is silently ignored where the other five raise. For Building
  that means a typo'd read starts persisting a save record for every matching actor, which is the
  exact failure F-8 exists to prevent. One line each; all three already require `schema`.
- **`om.checkImport` has no producer.** No domain passes `opts.refs`, so cross-pack references are
  offered and unchecked. The api constructors are the only layer that knows which spec fields are id
  references; `om.declareDeps` already gives the dependency set a memory, fed by
  `api.pack(id, { depends = ... })`. This is the open half of F-6.
- **`core/schema` has no `undefine`.** `test/cases/schema.lua` leaves **8** namespaced specs behind
  on every F1 press — `Inner`, `Spec`, `Dup`, `Derived`, `ReqDefault`, `FnDefault`, `Untyped`,
  `Checked`, and no others in the whole run. Inert — nothing walks the spec list per lookup — and
  documented in the file, but `test/support.lua`'s `sweep()` cannot reach it. (Both this line and
  the file's own comment said **10** until 2026-08-02; the number was counted off the
  `schema.define` call sites, six of which are inside `t:errors` and register nothing. Re-measured
  as the delta across two consecutive `run()`s: 8, then 8 again. Corrected in both places.)
- **`state/entities_world.json`'s top-level `"version": 1` is never bumped** while its records are
  upgraded to `v = 2` in place. Nothing reads the file-level field, so it is cosmetic; a file that
  says 1 and contains v2 records will mislead the next reader. Confirmed on disk on 2026-08-02:
  `version: 1`, `entities: 0`, `orphans: 1`, against a live `REC_VERSION = 2`.
  `pf_hook building-record-orphans` prints both numbers side by side, so the lie is visible in the
  same block that reports the round trip.
- **11 bare `TODO:` survive in `Scripts/palforge/tmp/building_runtime_ref.lua`.** That directory is
  gitignored, required by nothing, and deleted from any deployed tree by `deploy.sh` — so they are
  inert, and they will keep showing up in every future `grep 'TODO'`. It also still contains the old
  handle-keyed pattern, which is correct for a reference copy and wrong to copy from.
- ~~**`Open (6)` is written into `test/hooks/` 13 times** and this file is now Open (8).~~ **Done
  2026-08-02** by the attest pass: all 13 (7 files) now read `Open / <domain>` with no count, which
  is the spelling that cannot go stale, and the five `item =` strings that pointed at the old
  audit's "Owed work §4" now point at §2, where that material actually lives in this file. Nothing
  reads these strings except the two `log.info` lines in `test/hooks/init.lua` that print them.

### 2. Declared, shipped, and never once observed working

Each is honestly labelled in the source, each now has a hook, and **none is closed until the hook is
run.** A hook that exists is an instrument, not a measurement.

- `UI.Spec.host = "layer"` and `backHandler = true` — `pf_hook ui-host-layer`,
  `pf_hook ui-backhandler`. Both are now refused at define time without a `Frame` root. ⚠️ That is a
  **behaviour change** made during this sweep, and the old text was wrong about it: only
  `backHandler` (and `input = "clicks"/"exclusive"`) was refused at define time. `host = "layer"`
  passed define with any root and failed at *mount*, despite `api/ui.lua`'s own doc and
  `native/ui/tree.host`'s comment both claiming it "says so rather than half-working". The claim is
  now true, and `UI{ host = "layer", root = VBox{...} }` is a hard error. **Correction, 2026-08-02:**
  `input = "clicks"` is no longer hookless — both of those hooks declare it on the panel they mount
  (`ui_host_layer.lua:69`, `ui_backhandler.lua:59`) and print the applied input grab as a `VALUE`
  line, so running either one measures it on the way past. `input = "exclusive"` is **the one
  declared surface in this file with no hook at all**; nothing in `test/hooks/` mounts it, and
  closing it means declaring one, not running one.
- **A colour has never been watched changing** — `pf_hook mesh-color-change` (writes). The names are
  measured (`mesh-material-params`); `api/pal.lua`'s `renderOn` is explicit that a `true` means the
  write ran.
- **`setVolume` has never been heard** — `pf_hook audio-setvolume-audible`. It plays one SE at bus
  volume 1.0 / 0.25 / 0.0 / 1.0, always restoring unity, and proves `:play` first so silence is
  attributable. It deliberately does **not** declare `writes`: `writes` means "a save is mutated",
  not "something is audible".
- `Building.Handle:unlock()` is **unverifiable by construction** — there is no "is it unlocked"
  accessor, and it rides the cheat-manager surface. `pf_hook building-unlock` (writes, no undo)
  records everything establishable — cheat-manager existence, `UnlockOneTechnology`'s live
  declaration, the row precondition (115 of 501 vanilla ids have one), the call's return — and hands
  the rest to a human looking at the build menu. Its doc string now says `true` means "issued, and a
  technology row of that name exists", not "unlocked".

  **Correction:** the old text said this rides "the cheat-manager surface `pal-spawnmonster-signature`
  measured as silently doing nothing". `SpawnMonster` **works** — the "nothing spawned" was a
  stopwatch stopped at 1.2 s on a ~5.9 s arrival, and the Closed entry says so. Only `GetItem` is a
  measured do-nothing on that surface.

### 3. Test blind spots that remain

- **No single F1 press can run every check, and the summary now says so** — but the split is not yet
  fully attributable. 28 checks are world-gated and skip at the title screen; **10 are inverse-gated
  and skip when a world IS loaded**, and all ten now route through `t:skipNeedsNoWorld`. Headlessly
  the run is `450 passed, 0 failed, 31 skipped (481 total)` — 28 need a world, 1 needs a declared
  hook, 2 could not be answered by the session at all (the events ready gate needs `LoopAsync`; the
  UI keymap coverage needs UE4SS's own `Key` table). In a save the totals move, which is why the
  docs treat prose counts as warnings rather than errors.
- **`test/cases/ui.lua`'s keymap-coverage case still has an in-game-only half.** The headless half is
  no longer vacuous — it asserts the table is populated, has no blank or duplicate rows, that
  `translate()` agrees with every row, and that the 17 names this tree binds *or refuses by name*
  (F1–F10, ESCAPE, INS, DEL, END and the three mouse buttons) each have a row — but
  the COVERAGE assertion against UE4SS's live `Key` table can only run in a game. That table has
  **165** names, not the 156 two comments in `keymap.lua` claimed; `M.FKEY` matches it exactly in
  both directions (165 rows, re-counted 2026-08-02). **The hook is now declared** —
  `pf_hook keymap-key-coverage`, the only hook in the directory with **no `needs` at all**, because
  `Key` is a UE4SS process global rather than a world subsystem: it answers at the title screen and
  during a load, which also makes it the cheapest thing to put in `autorun.txt`. It crosses the two
  tables one row per name in both directions and names every drift; today's expected result is two
  empty lists, and the day either is not empty is the day it was worth declaring. It measures NAME
  COVERAGE and nothing else — whether Palworld has an action on a key is `pf_keys`, and whether a
  bound key's press ever reaches Lua is the third question F7 cost a session on.
- **A ninth gating axis exists that "run F1 twice" does not cover.** `test/cases/ui.lua`'s
  `ownStack` gates on *stack emptiness*, not on a world: it skips in any session where something is
  already mounted, and `pf_uiz` leaves three panels up.
- `test/probes/reflect.lua` emits `#### BEGIN pal-spawn-at-location` blocks for an id this file has
  never carried. Resolved as **keep + declare**: the two existing spawn ids are both Closed and
  neither asks that question, so renaming onto either would emit a block for a settled item and
  invite an accidental reopen. The probe now opens the block with
  `⚠️ PROPOSAL — plan/TODO.md has NEVER carried this id` (`test/probes/reflect.lua:950`); the word
  `PROPOSED` is the file's header spelling, at `:25` and `:32`. Whoever files it owns the name.

### 4. Two design decisions this sweep deliberately did not take

Both were found while fixing something else, both are behaviour changes rather than corrections, and
both are cheaper to decide now than after other people's packs exist.

- **`utils/items` cannot construct a cheat manager; `core/spawn` can.** `core/spawn.lua` builds one
  from the controller's `CheatClass` (falling back to `/Script/Pal.PalCheatManager` then
  `/Script/Engine.CheatManager`), which is why `CheatManagerEnablerMod` is *optional* for a spawn.
  `utils/items`' own `cheatManager()` asserts instead, so `unlockTech` refuses in a session shape
  that `:spawn` handles. The divergence is now documented at all four sites rather than changed;
  promoting `core/spawn`'s constructor to a shared helper is the fix, and it changes behaviour.
- **F9 is now refused while any poller is alive**, because `core/poll` declares every poller to the
  async guard. `native/ui/_widget`'s "ui input dead-man" lives as long as a panel holds input, so F9
  with a panel open is refused and names it. There is a 180 s stale cap and
  `require('palforge.core.reload').asyncReset()`. If that proves too sticky the fix is an opt-out
  flag on `poll.every` plus a caller change — deliberately not taken on a sweep.
