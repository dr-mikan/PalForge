# PalForge — what does not work yet

Every entry is a public thing a pack author can call that does not do what it says. None is a
wrong line of code: each is blocked on one fact about Palworld that nobody has measured — a
function's real parameter list, a property's real name, whether a class exists in the shipping
build at all.

Each item names that fact and the key that measures it. The probes are code, in
`Scripts/palforge/test/probes/`, and the same id appears as a `-- TODO(<id>)` marker at the line
a future implementer will open.

## Press F1 first

Four of the items below no longer need a probe at all: the API suite exercises them against a
real world and `core/signature.lua` logs, for every engine call, whether the live build declared
what was called. One keypress in a loaded save answers all four.

| Item | The line to look for |
| --- | --- |
| `item-additem-signature` | `give Wood x3 ... [declared]` and a count that MOVED |
| `effect-native-status` | `status.add AttackUp (EPalStatusID 26) [declared]` |
| `pal-skills-equip` | `addSkill Human_Punch (EPalWazaID 1) [declared] -> equipped` |
| `icons-row-read` | a resolved icon path for `Wood` |

A `refused ...` line is just as good an answer: it names what the live build declared, which is
the fact the item is waiting on.

### What the first F1 run already settled

**Enum arguments are `EnumProperty` here, not `ByteProperty`.** Three correct calls were refused
over the spelling alone — `AddEquipWaza`, `RemoveEquipWaza`, `GetExecutionStatus` all declare
`WazaID:EnumProperty` / `statusID:EnumProperty`. `core/signature.lua` now treats the two as
equivalent, since a legacy `enum` and an `enum class` marshal identically. FString and FName are
NOT equivalent and never will be — that confusion is the one that faults natively.

**Reading a character's skills works.** `skills: the pawn carries 0 active and 0 passive` — the
whole route (actor -> PalUtility -> individual parameters -> two getters) answered on a real
pawn. If a WRITE still fails now that the enum spelling is fixed, the problem is authority, not
reach.

**Two cheat-manager calls ran and did nothing.** `SpawnMonster(ChickenPal, lv 1) ran [evidence
declared] and NOTHING spawned`, and `GetItem executed [evidence declared] and the count did not
rise (135 -> 135)`. Same shape, two different functions: the declaration matched, the call
raised nothing, the world did not change. That is now a measured pattern rather than a
suspicion, and it is what `pal-spawnmonster-signature` is about.

## How to close one

1. Load a save and press the key in the item's **Probe** line.
2. Copy what the probe wrote to `UE4SS.log` — it brackets its output with `#### BEGIN <id>`
   and `#### END <id>`.
3. The missing fact is then known and the implementation follows from it. Delete the marker.
4. Press **F1** to re-run the 304-check API suite, and **F9** to reload without restarting.

## Keys

| Key | What it does | What you need on screen |
| --- | --- | --- |
| F1 | The API test suite — and, in a loaded world, the measurement that closes four items below | Anything. World-gated checks skip |
| F5 | Reflection dump: classes, functions, parameters, DataTable rows | A loaded save |
| F6 | Everything that needs a live pal: mesh, animation, materials | A pal near you |
| F7 | Arms hooks and watches for 60 s while you act | A save, then craft / drop / spawn |
| F8 | Title-screen widgets | The title screen |
| F9 | Reload every palforge module without restarting the game | Anything |

Only F7 changes anything, and it says so before it arms a hook.

## Closed (15)

Six were settled from the reflection dumps in `dumps/`, without touching the game. Two more were
settled inside a loaded save by the first F5 run (`dumps/f5-partial-run.txt`). The last six were settled by
`dumps/cxx/`, UE4SS's own header dump of the installed binary — 1579 headers carrying every
UFunction's real signature, which is the only source in this tree that answers a parameter list
without the game running.

- **`audio-akevent-play-signature`** — Audio.Handle:play. The recorded session caught the GAME ITSELF calling PalSoundUtility:PlayAkEventSoundByActor six times with exactly (AActor, UObject) in that order, which is the call PalForge already makes. Arity, order and callee are settled.
- **`spatial-saveid`** — core.spatial.saveId. PalGameInstance's full 111-property listing contains no WorldGuid, WorldSaveName or SaveName — all three probed names were wrong, which is why every save shared one persistence file. The real accessors are GetSelectedWorldSaveDirectoryName and GetSelectedWorldName, and core/spatial now reads them.
- **`building-leftclick`** — Building onLeftClick. PalBuildObject's complete 22-function list has no click, hit or attack entry. The standing candidate, OnDamage, turned out to be the deterioration timer: 196 firings on a strict 12-13 s cadence per structure, starting half a second after placement, with no player involved. Wiring the hook to it would have run every pack's handler every 12 seconds on every structure in the base.
- **`building-break`** — Building onBreak. None of PalBuildObject, PalMapObjectModel, PalMapObjectConcreteModelBase or PalNetworkPlayerComponent carries a destroy, dismantle or break function. Destruction exists only as delegate FIELDS, which RegisterHook cannot address by path. Disappearance keeps surfacing as onRemove with reason "missing".
- **`building-break-source`** — the building.break and building.leftclick channels. Same evidence, applied to the source side: neither channel is worth adding, and core/event now records why rather than carrying a hopeful TODO.
- **`icons-row-column`** — core.icons ICON_COLUMNS. The DataTable dump printed every table's real column list. Items and pals use `Icon`, buildings use `SoftIcon`, and partner skills use `TextureID_8_2B2F...`. Of the five names the code had been guessing, IconName, IconTexture and Texture are columns of no icon table on this build.
- **`item-inventory-count-readback`** — utils.items.count. Read back from a live save, not inferred: `inv.CountItemNum` is bound (a UFunction userdata), `inv:CountItemNum(FName('Wood'))` answered **135** as a plain Lua number, and the whole resolve chain printed real objects at every step (PalUtility CDO -> BP_Player_Female_C -> BP_PalPlayerState_C -> BP_PalPlayerInventoryData_C). The `CountItemNum64` fallback is gone — a second spelling was only ever there for a return shape that turned out to be a number. Reading an inventory is the one item capability that fully works today.
- **`audio-volume-rtpc`** — Audio.Handle:setVolume. Settled NEGATIVELY, which is still settled. The routes all exist (UPalSoundUtility reflects SetRTPCValueByActor / SetRTPCValueByActorByEnum; AkGameplayStatics reflects SetRTPCValue / GetRTPCValue / ResetRTPCValue), but the build declares exactly **three** AkRtpc assets — Supply_Altitude, OverHeatRifle, ChargeLaserRifle_01 — plus zero AkAuxBus and zero AkAudioBank. None is a volume, so there was never a parameter for those functions to address and no parameter list would have helped. Do not re-probe them. The capability moved to `audio-bus-volume`, which is a different call with a different contract.
- **`spawn-actor-conventions`** — core.spawn.actor. `dumps/cxx/Engine.hpp` declares both halves of deferred spawning outright: `BeginDeferredActorSpawnFromClass` takes FIVE parameters (world context, actor class, transform, collision handling, owner) and `FinishSpawningActor` takes TWO (actor, transform). Neither has the UE 5.3+ scale-method argument this file used to try first. So the four guessed argument conventions were never all callable — three of them could not have worked on any build — and the guess chain is replaced by the one declared shape. Still unobserved end to end, and now honestly gated: both calls take a struct, so `core/signature.lua` only fires them when the live parameter walk succeeds.
- **`mesh-static-setstaticmesh`** — Mesh.Handle:attachTo on kind="static". `dumps/cxx/Engine.hpp:21720` declares `bool SetStaticMesh(UStaticMesh*)` on UStaticMeshComponent — exactly the call being made. The same listing settles the READ-BACK, which was the harder half: there is no reflected `GetStaticMesh` anywhere in the dump, and the asset is reachable only as the UProperty `StaticMesh` (`:21693`). The old two-path check had a first branch that could only ever raise; it is now the property.
- **`mesh-detach-destroycomponent`** — Mesh.Handle:detach. `Engine.hpp:9972` declares `void K2_DestroyComponent(UObject* Object)` on UActorComponent — one object argument, the component itself, which is what both call sites already passed. The two sites are now one shared `Renderer.destroyComponent`.
- **`mesh-skeletal-setter`** — Mesh.Handle:attachTo on kind="skeletal" and Pal.Handle:renderOn. The class ladder is confirmed end to end — `APalCharacter : ACharacter`, whose `Mesh` is a reflected `USkeletalMeshComponent*` (`Engine.hpp:8156`), and `UPalSkeletalMeshComponent` derives from it. Two guesses collapsed: `actor:GetMesh()` is not declared anywhere in the dump, and the two mesh setters are inherited by the SAME component, so the second was never a fallback. One route remains, `SetSkinnedAssetAndUpdate(asset, true)`, chosen because it re-initialises the pose, with the getter that pairs with it for the read-back.
- **`mesh-skeletal-animclass`** — Mesh.Spec.animClass. All three assumptions confirmed: `SetAnimClass(UClass*)`, `SetAnimationMode(TEnumAsByte<EAnimationMode::Type>)`, and `EAnimationMode::AnimationBlueprint = 0`. The calls were already right, and the log line claiming "SetAnimClass is not on this component" was simply wrong. The real weak link turned out to be elsewhere and is recorded in its place: `SetAnimClass` wants an AnimBlueprintGeneratedClass, and the one live asset sweep on disk found zero loaded while the classes plainly exist — so what is unproven is the LoadAsset resolve, not the call.
- **`mesh-texture-import`** — Mesh.Spec.texture. `Engine.hpp:14694` declares `UTexture2D* ImportFileAsTexture2D(UObject* WorldContextObject, FString Filename)` on UKismetRenderingLibrary. Both halves of the unknown are answered: the world context is a plain `UObject*`, so the actor already being passed qualifies, and the path is an FString — an ordinary Lua string, and NOT the FName shape that kills the process.
- **`effect-native-status`** — Effect.Spec.nativeStatus. **Observed working in a loaded save**, 2026-07-26: `status.add AttackUp (EPalStatusID 26) [declared]`, the game reading the ailment back as present, then `status.remove` and the game reading it back as gone. The route is `PalCharacter.StatusComponent` -> `UPalStatusComponent::AddStatus(EPalStatusID)`, and the vocabulary that previously had no source anywhere on disk is `EPalStatusID`'s 38 names. One thing had to change to get there and it generalises: those parameters are declared **EnumProperty**, not ByteProperty — an `enum class`, not a legacy `enum` — and `core/signature.lua` refused three correct calls over the spelling until it learned the two marshal identically. Every `EPal*` argument in this tree is an enum class.

## Open (23)

### Pal

#### `pal-icon-row` — Pal.Handle:iconOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/pal.lua:244

**What a pack author sees**

Always returns the icon the author declared, and nil when none was declared — for a vanilla id
like "ChickenPal" the live lookup contributes nothing, even though the row exists.

**What is still unknown**

```text
The paldeck / capture-UI icon: look the id up in the pal character icon DataTable,
falling back to the declared self.icon on any miss.
TODO(pal-icon-row): the DataTable ROW READ core/icons performs has never been observed to
return anything on this build, so in practice this is the fallback and nothing else.
```

**What the probe prints**

FindAllOf("DataTable"); pick the one whose o:GetFName():ToString() ==
"DT_PalCharacterIconDataTable". (a) Print its columns exactly as the dumper does:
dt.RowStruct:ForEachProperty(function(p) print(p:GetFName():ToString()) end). (b) Then call
dt:GetDataTableRowFromName(FName("ChickenPal")) and dt:FindRow(FName("ChickenPal"), "probe",
false), printing type() and tostring() of each result and the pcall error message when one
raises. "ChickenPal" is a confirmed row of that table (674 rows on disk).

#### `pal-skills-equip` — Skill.Handle:teach / :forget, Pal.Handle:teachAll

- **Probe:** F1
- **Marked at:** Scripts/palforge/core/character.lua:43

**What a pack author sees**

`Skill.get("FireBlast"):teach(pal)` may return false and the pal may not learn the move. When it
works, the pal really does carry it — every write here is verified by reading the character back,
so a true is never "the call ran".

**⚠️ Writing a move to a live pal correlates with a crash**

The first run that did it — `AddEquipWaza` firing with evidence `declared`, the read-back not
showing the move, `RemoveEquipWaza` firing — was followed about 1.4 seconds later by Palworld
closing, part way through the mesh suite. The run before it, with no pal nearby, completed.

That is a correlation and not a proof: several other things happen in that window, and the log
ends with no Lua error, which is what a native fault looks like from here. But the risk is
one-sided — this writes into a character in a real save through a call whose effect has never
been observed — so the write is now **opt-in** and F1 no longer performs it. To run it
deliberately, on a throwaway save:

```lua
_G.PALFORGE_TEST_WRITE_WAZA = true   -- then press F1
```

The read half still runs every time, and it is where the better signal is (see below).

**What is still unknown**

Only whether the writes land. Everything else is settled by `dumps/cxx/Pal.hpp`, and this went
from "the argument shape is unmeasured, so calling one would be a guess with a live pawn on the
other end" to four declared calls with scalar arguments:

```text
class UPalIndividualCharacterParameter                       (Pal.hpp:20822)
    void AddEquipWaza(EPalWazaID WazaID);          RemoveEquipWaza(EPalWazaID);  ClearEquipWaza();
    void AddPassiveSkill(FName AddSkill, FName OverrideSkill);  RemovePassiveSkill(FName SkillId);
    TArray<EPalWazaID> GetEquipWaza();            TArray<FName> GetPassiveSkillList();
class UPalUtility
    UPalIndividualCharacterParameter* GetIndividualCharacterParameterByActor(const AActor*);
                                                                 (Pal.hpp:32340)
```

Every argument is an enum integer or an FName — never a struct — so none is the shape that
faults inside UE4SS marshalling, and every write has a matching read that proves it landed.

Settled alongside it: **the vocabulary**. `EPalWazaID` (`dumps/cxx/Pal_enums.hpp`) names 309
active skills, which is what `Pal{ skills = { ... } }` can contain and what
`core.character.wazaNames()` lists. Active skills are an enum and passives are FNames — a real
distinction a caller cannot paper over, so `:teach` routes on which one the id is rather than on
the skill's declared `kind`.

**The lead worth chasing first: the READ says zero**

`skills: the nearest pal carries 0 active and 0 passive`. A real Palworld pal has equipped
moves, so a pal reporting none means the read is not reaching what it should — and if the read
is landing on the wrong object, so is the write, which would explain the whole item without
server authority coming into it at all. The route resolves and answers, so this is not "no
parameter object"; it is the wrong one, or the right one before its moves are populated.

Read next, in this order: whether `GetIndividualCharacterParameterByActor` returns the same
object as the pal's own `GetCharacterParameterComponent():GetIndividualParameter()`, and what
`GetEquipableWaza()` and `GetMasteredWaza()` say on the same object. If those are non-empty
while `GetEquipWaza()` is empty, the read is fine and the pal genuinely has nothing equipped.

**What the probe prints**

F1 in a loaded world with a pal nearby prints both read-backs, the player's and the pal's. The
enum spelling question is settled — these parameters are `EnumProperty`, and `core/signature.lua`
now accepts it.

#### `pal-spawnmonster-signature` — Pal.Handle:spawn / core.spawn.pal / core.spawn.palAt

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/spawn.lua:279

**What a pack author sees**

`Pal{...}:spawn()` returns false and no pal appears. Nothing has ever spawned through PalForge.

This was measured on 2026-07-26 in a loaded save, with a cheat manager that already existed
(`CheatManagerEnabler` logged "CheatManager already exist") and on the game thread:
`cm:SpawnMonster(FName("ChickenPal"), level)` completed **without raising**, no new
`PalCharacter` existed a statement later, and none existed 1.2 s later either. The call reaches
the engine and does nothing.

**What is still unknown**

The reflected parameter list of `UPalCheatManager::SpawnMonster` and `::SpawnMonsterForPlayer`
on this build. Nothing in either tree has ever reflected it — `dumps/reflection/02_reflection.txt`
covers 21 `/Script/Pal.*` classes and PalCheatManager is not one of them; its only trace anywhere
is PalUtility's `.GetPalCheatManager`. The arity `core/spawn.lua` is written to,
`SpawnMonster(FName CharacterID, int Level)`, comes from a CXXHeaderDump note about *some* build,
not a measurement of this one.

Why that is the suspect: the same run measured `AddItem_ServerInternal` declaring six parameters
where PalForge passes four (`item-additem-signature`), and UE4SS accepts a short argument list
silently — a missing trailing parameter is marshalled as zero. A `SpawnMonster` whose real list
carries, say, a count or an enabling flag after `Level` would behave exactly like this: runs,
raises nothing, spawns nothing.

**What the probe prints**

The cheat manager reached three ways (live object, the controller's `.CheatManager`, its
`.CheatClass`), then its complete UFunction list — which no dump in this tree has — then every
parameter of both spawn functions in declared order, with each one's name and property class. It
calls neither: a guessed argument list faults natively, past `pcall`, and that is what crashed
the first F5 run.

#### `pal-spawn-placement` — Pal.Handle:spawn(coord) / core.spawn.palAt

- **Probe:** F7
- **Marked at:** Scripts/palforge/core/spawn.lua:408

**What a pack author sees**

:spawn(coord) returns true, but nobody has ever seen a pal actually arrive at the coordinate —
the game drops it beside the player and PalForge's relocation runs on a retry chain long after
the call returned, reporting only to the log.

**What is still unknown**

```text
Relocate ONLY our freshly-spawned pal to (x,y,z). The native spawn drops it right at the
player, so among pals absent from `before` we move the SINGLE one nearest the player's spawn
position (px,py,pz) — never a batch, so wild pals that streamed in meanwhile are not dragged
along (that was the "20 -> 40 floating pals" bug). Retries; the actor spawns deferred.
Returns true ONLY when a new pal was found AND the move reported success. Nobody can
receive that today — every call site is a retry timer that ran long after palAt returned —
so the return exists for the log line to be honest and for a future caller to poll on.

TODO(pal-spawn-placement): unobserved end to end — no run of this pass (found / moved /
landed at the coordinate) is recorded anywhere in either tree.
```

**What the probe prints**

In a loaded world, spawn at a distinctive point —
Pal.get("ChickenPal"):spawn(require("palforge.core.player").coordinateOffset(600, 0, 50)) — or
just press F1 (the pal suite's live coordinate test does exactly this). Then paste every
[PalForge.spawn] line from UE4SS.log for the following 5 s: the "accepted; relocation to (x,y,z)
scheduled" line, followed by ONE of "placed new pal at (x,y,z); it reads back (...), off by N" /
"found the new pal but every relocate call failed" / "no new pal actor appeared to place". An
"off by" under ~100 means the coordinate route works.

#### `pal-spawned-hook` — Pal.Spec.Events.onSpawned

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/pal.lua:158

**What a pack author sees**

A declared onSpawned handler may simply never run. Capture, damage and death are confirmed
firing in-game; the spawn hook has never been observed to fire once, so a pack that renders a
mesh from onSpawned can see nothing happen at all.

**What is still unknown**

```text
TODO(pal-spawned-hook): NARROWED by dumps/reflection/. Two halves of the old question
are now answered: (a) BroadcastOnCompleteInitializeParameter IS a real UFunction on
/Script/Pal.PalCharacter (02_reflection.txt), so the hook path is not a guess; (b) the
three sibling hooks this channel sits beside — SetIsCapturedProcessing, OnDamageReaction,
OnDeadCharacter — are all recorded FIRING in a live session (06_events.txt), so the
source machinery around them works. What is left is ONE unknown: does that function run
when a pal spawns AFTER world load, and is `self` then the new pal? 06_events cannot
answer it — the probe mod that produced it had dropped this hook from its arming list,
so there is no line there to be missing. Handlers stay idempotent until a post-load
arming records a firing.
```

**What the probe prints**

In a fully loaded world,
RegisterHook("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter", function(self)
print(os.clock(), self:get():GetClass():GetFullName()) end). Then log the count for three steps
in order: (1) stand idle 30 s (expect 0 lines); (2) run Pal.get("ChickenPal"):spawn() and print
every line for the next 10 s; (3) release one pal from the box. Paste the per-step line counts
and the BP class names printed.

#### `item-craft-source` — Item.Spec.Events.onCraft (channel item.craft)

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/item.lua:110

**What a pack author sees**

A declared onCraft handler never runs. Crafting at a workbench fires nothing on this channel;
the produced item surfaces as onObtain via the get-log instead, which cannot be told apart from
a pickup. Only a manual event.emit('item.craft', ...) reaches the handler. | The channel exists
and DISPATCH is wired, but no source ever emits it: an onCraft handler is registered, validated,
and then never runs for any item, with no warning.

**What is still unknown**

```text
item.craft and item.discard stay SOURCELESS, on purpose rather than by omission.
The one signal that is right there — the get-log — cannot stand in for either: a
crafted item surfaces through that same get-log ("Crafting output surfaces through the
same get-log, so item.craft may be redundant with item.obtain",
dump/docs/further_plan.md:38-39), so emitting item.craft from it would report every
pickup as a craft. Neither channel has a candidate native function recorded anywhere:
dump/dump_targets.md:149-150 lists both as `dump to discover`, and the probe harness
(dump/auto_mod/Scripts/main.lua:33-48) never armed one. Their DISPATCH is wired and
begins working the moment an emit lands here.
TODO(item-craft-source): no craft-complete UFunction is known — which class/function the
game calls when a bench finishes an item, and which param carries the id + count.
Still fully open: the 21 classes in dumps/reflection/02_reflection.txt do not include
PalMapObjectProductItemModel / PalMapObjectWorkeeModel / PalWorkProgress*, and no
craft-shaped hook was ever armed, so nothing in the dumps speaks to it.
```

**What the probe prints**

Two steps. (1) Reflection: for each of /Script/Pal.PalMapObjectProductItemModel,
/Script/Pal.PalMapObjectWorkeeModel, /Script/Pal.PalWorkProgress and
/Script/Pal.PalMapObjectConcreteModelBase, StaticFindObject the class (or CDO) and enumerate
every UFunction, printing the name of any whose name matches
Product|Complete|Work|Output|Craft|Finish, and for each one walk its Children logging property
name, class name and offset. (2) Hook: RegisterHook each candidate path, then craft ONE item at
a workbench in a throwaway world, and for every fire log the function path plus, for each param
i in 1..4, tostring(p:get()) and the value of .Id / .ID / .StaticItemId / .Num when the field
exists. | Two steps, in a throwaway world. (1) REFLECT: add
"/Script/Pal.PalMapObjectProductItemModel", "/Script/Pal.PalMapObjectConcreteModelBase" and
"/Script/Pal.PalWorkProgressModel" to CANDIDATE_CLASSES in dump/dump.lua and run its
dumpReflection (StaticFindObject(path) -> cls:ForEachFunction(fn ->
print(fn:GetFName():ToString()))); paste every function name matching
Craft|Product|Complete|Work|Output. (2) HOOK: for each candidate add {"ITEM.craft",
"/Script/Pal.<Class>:<Fn>"} to HOOKS in dump/auto_mod/Scripts/main.lua and log, per firing: the
path, self:get():GetClass():GetFName():ToString(), and for a1..a4 both p:get() and its
:ToString()/tostring plus the fields .ID, .Id, .StaticItemId, .ItemId, .Num, .Count when
present. Then craft one item at a workbench and paste which line fired with which id and count.

#### `item-datatable-row-read` — Item.Handle:iconOf / Item.Handle:recipeOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/item.lua:169

**What a pack author sees**

iconOf() hands back the icon the author declared (nil when none was declared) for every item,
vanilla ones included — the live table is never actually read. recipeOf() returns nil for every
vanilla item even though DT_ItemRecipeDataTable_Common has 1414 rows keyed by exactly the item
ids the API takes.

**What is still unknown**

```text
The inventory icon. core.icons finds the live DT_ItemIconDataTable for real (the
FindAllOf sweep that dumped the 390-table catalog), but the last step — reading the row —
has never been observed to work from Lua on this build, so this falls back to the declared
self.icon and that is what you get in practice.
TODO(item-datatable-row-read): unknown which row-VALUE accessor a UDataTable exposes to
UE4SS Lua here (GetDataTableRowFromName / FindRow / something else) and what it hands back.
That accessor is now the ONLY missing piece for both :iconOf and :recipeOf. Everything
around it is measured, in dumps/reflection/01_datatables.txt, from a real session:
* the tables are loaded — DT_ItemIconDataTable (1207 rows) and
DT_ItemRecipeDataTable_Common (1414 rows on disk), both under /Game/Pal/DataTable/Item/;
* the row keys are the item ids ("Stone", "Wood", ...);
* the columns are no longer a guess. The icon column is `Icon` — NOT the IconName /
SoftIcon this comment used to claim, neither of which is a column of that table (see
core/icons ICON_COLUMNS_BY_TABLE). The recipe row struct carries Product_Id,
Product_Count, Material1_Id..Material5_Id, Material1_Count..Material5_Count, WorkAmount,
CraftExpRate, EnergyType, EnergyAmount, UnlockItemID, WorkableAttribute, DenyRecipeChain.
What the 2026-07 dumps cannot settle: the accessor itself. 02_reflection.txt covers 21
/Script/Pal.* classes only, so UDataTable / UDataTableFunctionLibrary are absent from it.
```

**What the probe prints**

In a loaded world: local dt = FindObject('DataTable','DT_ItemIconDataTable') (fall back to
FindAllOf('DataTable') matching o:GetFName():ToString()); print dt:GetFullName(). Then for each
of 'GetDataTableRowFromName','FindRow','GetRow','GetRowStruct','GetRowMap' call
dt:GetClass():GetFunctionByName(name) and, when it resolves, walk its Children logging each
property's name, class name and offset. Then CALL each resolved one with FName('Wood') (and with
the plain string 'Wood') and print type() of the result; when non-nil, print the result's
struct/class name and then index it with each of SoftIcon, IconName, IconTexture, Icon, Texture,
printing name -> tostring(value). Repeat the whole sequence verbatim on
FindObject('DataTable','DT_ItemRecipeDataTable_Common') with row FName('Arrow'), indexing
Product_Count, WorkAmount, Material1_Id, Material1_Count.

#### `item-discard-source` — Item.Spec.Events.onDiscard (channel item.discard)

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/item.lua:115

**What a pack author sees**

A declared onDiscard handler never runs. Dropping a stack on the ground, destroying it from the
inventory menu, or consuming a potion all fire nothing on this channel. Only a manual
event.emit('item.discard', ...) reaches the handler. | Same as onCraft: declarable, dispatched,
and never emitted — dropping, trashing or consuming an item produces no event at all.

**What is still unknown**

```text
game calls when a bench finishes an item, and which param carries the id + count.
Still fully open: the 21 classes in dumps/reflection/02_reflection.txt do not include
PalMapObjectProductItemModel / PalMapObjectWorkeeModel / PalWorkProgress*, and no
craft-shaped hook was ever armed, so nothing in the dumps speaks to it.

TODO(item-discard-source): NARROWED by the dumps, not closed. What is now measured:
there is no dedicated drop/discard entry point on the inventory classes at all —
02_reflection.txt lists PalPlayerInventoryData in full (69 fns; the only removal-shaped
name is TryRemoveEquipment) and PalItemContainer in full (13 fns, all reads), so the
"separate discard UFunction" branch of this question is dead. What is still unknown is
the standing hypothesis: whether a drop arrives as AddItem_ServerInternal with a
NEGATIVE Count. The dumps cannot say — that hook WAS armed successfully (14/14, label
ITEM.add, dump/auto_mod/Scripts/main.lua:44) and never fired once across both recorded
sessions, in either direction, while ITEM.getlog and ITEM.use did; so either the
sessions contained no qualifying action or this call does not run client-side at all.
The next probe has to log ITEM.add and ITEM.getlog side by side across a pickup AND a
drop to tell those two apart.
```

**What the probe prints**

Arm RegisterHook on /Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal (already listed in
dump/auto_mod/Scripts/main.lua:44) and log, on every fire, param1 as an FName string and param2
as a NUMBER including its sign. In a throwaway world perform three separate actions with a
marker line printed between them: (a) drop a stack of Wood on the ground, (b) destroy a stack
from the inventory menu, (c) eat one Berries. Report which hooks fired per action and what sign
param2 carried. If AddItem never fires with a negative Count, reflect
/Script/Pal.PalMapObjectDropItemModel, /Script/Pal.PalMapObjectPickableItemModel and
PalPlayerInventoryData, printing every UFunction whose name matches
Drop|Discard|Destroy|Throw|Consume|Lost, with each function's parameter names and classes. | In
a throwaway world with the harness armed on
"/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal" (label ITEM.add already in
dump/auto_mod/Scripts/main.lua:44), log per firing: a1 via p:get():ToString() and a2 via
tostring(p:get()) VERBATIM INCLUDING SIGN. Print a marker line before each action, then: (a)
drop a stack from the inventory to the ground, (b) trash/destroy one, (c) eat one to zero. Paste
the lines and the sign of a2 for each. If nothing fires for (a)/(b), reflect
"/Script/Pal.PalPlayerInventoryData" and "/Script/Pal.PalItemContainer" with
cls:ForEachFunction(fn -> print(fn:GetFName():ToString())) and paste every name matching
Discard|Drop|Remove|Sub|Consume|Trash|Throw.

#### `item-additem-signature` — utils.items, the direct inventory write

- **Probe:** F5
- **Marked at:** Scripts/palforge/utils/items/init.lua:136

**What a pack author sees**

Nothing, if the cheat manager is available — `:give` and `:take` work through it. This matters
when it is NOT: the cheat manager needs `CheatManagerEnabler`, and without it both helpers say
so and return false. A direct write to the inventory object would need no such dependency, and
would report an `EPalItemOperationResult` saying exactly why an add failed (inventory full,
unknown id, container mismatch) instead of PalForge inferring it from a count that did not move.

**What is still unknown**

What the SIX parameters of `/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal` are on
this build. The first in-game run answered `UFunction expected 6 parameters, received 4`, and
note what that does NOT say: UE4SS rejected the call before binding any argument, so it tells us
the declaration has six slots and nothing about whether the four PalForge passed were the right
four in the right order.

**This is the one place the header dump is provably behind the running game.** `dumps/cxx/Pal.hpp:27053`
declares it with four parameters:

```text
EPalItemOperationResult AddItem_ServerInternal(const FName StaticItemId, const int32 Count,
                                              bool IsAssignPassive, const float LogDelay);
```

The live build wants six. That gap — dump generated 2026-07-09, `Palworld-Win64-Shipping.exe`
dated 2026-07-16 — is the concrete reason every dump-derived signature in this tree is checked
against the live object by `core/signature.lua` before it is called, rather than trusted.

**What the probe prints**

Every parameter of `AddItem_ServerInternal` in declared order, asked of both the live inventory
and its class, plus the two sibling add routes this build declares (`RequestAddItem_ForDebug` on
the same class, `RequestAddItem_ToServer` on the network component). It calls none of them.

#### `item-remove-call` — Item.Handle:take

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/item.lua:41

**What a pack author sees**

`:take` works — it removes the items from the inventory and verifies the count fell — but **it
drops them on the ground at the player's feet**. They are gone from the bag and lying in the
world, where the player can simply walk back over them.

The consequence, stated bluntly because it is the common case: **`:take` cannot charge a cost.**
A pack that takes 10 Wood as payment leaves 10 Wood on the floor next to the payer. Use it to
move items out of a bag; do not use it to make something expensive.

**What is still unknown**

Whether any call on this build removes an item *without* putting it in the world. The search has
been narrowed to two candidates, and everything else is eliminated by reading rather than by
guessing:

- The inventory's whole class chain was walked in a live save — `BP_PalPlayerInventoryData_C`
  (0 own functions), `/Script/Pal.PalPlayerInventoryData` (69), `/Script/CoreUObject.Object` (1),
  and `PalItemContainer` (13). One name matches remove/consume/discard/drop/delete across all
  83, and it is `TryRemoveEquipment`, which unequips a slot.
- `UPalItemContainer` and `UPalItemSlot` are now read in full in `dumps/cxx/Pal.hpp`. Every
  function on both is a getter, except `UPalItemSlot::RequestUseToCharacter`, which consumes
  through the use processor for a target character and is not an arbitrary-id removal.
- `UPalCheatManager`'s whole surface is visible too. Its only item removals are `DropItem` /
  `DropItems` (which put the item in the world — the thing being avoided) and
  `ClearPlatformInventoryItem` / `ConsumePlatformInventoryItem`, which are storefront
  entitlements, not inventory.

The two that survive, both unread:

1. `UPalCheatManager::InitInventory(const FName StaticItemId, const int32 Count)` — reads like a
   SET rather than an add, which would make `Count = 0` a true removal. The name says "Init", so
   it may wipe more than the one id. Nothing may be called on that guess; read what it does in a
   throwaway world first.
2. `UPalItemSlot.StackCount` is a plain writable `int32` **property** (offset `0x154`), not a
   function, so a slot walk could decrement it with no marshalling involved at all. The risk is
   not the write but replication — the class carries `OnRep_StackCount`, so a raw poke may leave
   server and client disagreeing. `PalPlayerInventoryData.RequestForceMarkAllDirty` is the
   obvious partner if this is ever tried.

The old candidate — a negative `Count` through `AddItem_ServerInternal` — is retired. It is no
longer the only option and is not worth its risk while those six parameters are unread.

**What the probe prints**

The inventory class chain and the container's function list, unfiltered, so a name nobody has
proposed can be spotted. It writes to no inventory.

#### `skill-activate-source` — Skill.Spec.Events.onActivate

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/skill.lua:59

**What a pack author sees**

A pack that declares events.onActivate gets a handler that never runs by itself. Nothing in
PalForge emits a skill channel (core/event.lua M.CHANNELS is gameStart / world.* / building.* /
pal.* / item.* / tick) and no dispatch would resolve one to a definition, so the handler only
fires when the pack itself calls Handle:activate(owner).

**What is still unknown**

```text
TODO(skill-activate-source): NARROWED — candidates now have names. PlaySkill stays
ruled out (armed in two in-game probes, 0 firings), but dumps/reflection/02_reflection
.txt shows /Script/Pal.PalUtility carries PlayActionByWazaID and PlayAction, and
/Script/Pal.PalPlayerController carries ActionComponent_PlayAction_ToServer_ForPlayer
and OnActionBegin (PalPlayerCharacter has OnBeginAction); PalCharacter exposes
GetActionComponent / :ActionComponent, so the executor is an action component, not the
controller. PlayActionByWazaID is the standout: its name says the waza row id is a
parameter, which is exactly the identity this channel needs.
THE ONE THING LEFT: which of those actually runs when a PAL uses a move (none has ever
been armed), and whether the waza id it carries is an FName or a struct. Until a
RegisterHook run logs one firing, no skill.activate channel gets written.
```

**What the probe prints**

In a loaded world, UE4SS Lua console. STEP 1 (enumerate): for each name in {"PalCharacter","PalP
layerCharacter","PalPlayerController","PalActionComponent","PalCombatComponent","PalWazaBase","P
alSkillBase","PalActionBase"} do `local c = StaticFindObject("/Script/Pal."..n)`; print n and
whether c is non-nil; if non-nil call `c:ForEachFunction(function(f) print("FN", n,
f:GetFName():ToString()) end)` and `c:ForEachProperty(function(p) print("PROP", n,
p:GetFName():ToString(), p:GetClass():GetFName():ToString()) end)`, then walk `c =
c:GetSuperStruct()` until nil and repeat (the walk idiom from PalServerTweaks
.../ConsoleCommandsMod/Scripts/dump_object.lua:183-196). Also do the same starting from
`FindFirstOf("PalPlayerCharacter"):GetClass()` so Blueprint subclasses are covered. Log EVERY
function name; we are looking for ones containing Waza / Skill / Action / Activate / Execute /
Fire / Shot / Attack. STEP 2 (signatures): for each candidate UFunction object f from STEP 1,
print its parameters with `f:ForEachProperty(function(p) print(" PARAM",
p:GetFName():ToString(), p:GetClass():GetFName():ToString(), p:GetOffset_Internal()) end)` — a
NameProperty or a struct here is what would carry the skill id. STEP 3 (confirm live): arm the
top candidates with the count-capped RegisterHook pattern from dump/auto_mod/main.lua:41-53 —
`RegisterHook("/Script/Pal.<Class>:<Fn>", function(self, a1, a2, a3, a4) ... end)` logging
`self:get():GetClass():GetFName():ToString()` and, for each param, `p:get()` normalised through
`v.ToString and v:ToString() or tostring(v)`. Have a Pal use a move and a player use a partner
skill. PASTE BACK: which hook labels fired, how many times, the self class, and every parameter
value string.

#### `skill-hit-source` — Skill.Spec.Events.onHit

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/skill.lua:72

**What a pack author sees**

events.onHit never runs on its own; it only fires when the pack calls Handle:hit(target).
Nothing reports "skill X landed on Y".

**What is still unknown**

```text
TODO(skill-hit-source): NARROWED on both sides. VICTIM side: dumps/reflection/
06_events.txt records PalCharacter:OnDamageReaction firing 9 times on real pals and on
the player, and shows its shape — exactly ONE parameter, a UScriptStruct (a2..a4 are
empty). So the question shrinks from "which hook and how many params" to "what are the
FIELDS of that one struct". The probe never expanded it, so they are still unprinted.
ATTACKER side: /Script/Pal.PalUtility carries MakeDamageInfoByWazaType alongside
MakeDamageInfo, ProcessDamageAndPlayEffectsByDamageInfo and ProcessDamageAndPlayEffects
— a damage-info struct BUILT from a waza type is strong reason to expect the waza
identity to be a field of the very struct OnDamageReaction receives, and those
Process* calls are attacker-side hook candidates that would carry it.
THE ONE THING LEFT: the field list of that struct (walk its UClass with ForEachProperty
inside the hook) and whether any field holds a waza / skill row FName.
Still ruled out: PalPlayerController:SkillDamageReactionComponent_ProcessDamage_ToServer
(armed, 0 firings).
```

**What the probe prints**

Arm `RegisterHook("/Script/Pal.PalCharacter:OnDamageReaction", function(self, a1, a2, a3, a4)
... end)`. Inside, for each param p: `local v = p:get()`; print `type(v)`; when v is userdata
print `v:GetClass():GetFName():ToString()` and then enumerate the whole struct with `local c =
v:GetClass(); while c do c:ForEachProperty(function(pr) print(" FIELD",
pr:GetFName():ToString(), pr:GetClass():GetFName():ToString()) end); c = c:GetSuperStruct()
end`, followed by the VALUE of each field printed as `tostring(v[fieldName])` and, when that is
userdata with ToString, `v[fieldName]:ToString()`. Cap at ~10 firings. Then in game hit a Pal
with a NAMED move (e.g. a fire attack) and, separately, with a plain melee hit, so the log can
be diffed. PASTE BACK: the full field list of every param struct plus their values for both
cases — we need to see whether any field holds a skill/waza row FName and, if so, its exact
name.

#### `skill-icon-key` — Skill.Handle:iconOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/skill.lua:150

**What a pack author sees**

Returns the declared `icon` (usually nil) for essentially every skill. It reaches the engine —
core/icons finds the live UDataTable for real via FindAllOf("DataTable") — but no icon has ever
been observed coming back, and a nil is indistinguishable from "no such row".

**What is still unknown**

```text
palforge/api/skill.lua — PUBLIC skill API + implementation (SELF-CONTAINED).

A skill is what a Pal can do: an active attack or a passive trait. Same shape as every
other api module (call it to define, plus get / get_all + a Handle object with actions
and grouped `events`).

HOW IT INTEGRATES: Skill{ ... } registers the definition class in object_manager under
("skill", id), so it is discoverable (Skill.get / Skill.get_all / core.registry) and a
Pal declares which skills it owns by id (Pal{ skills = { ... } }).

HONEST STATE OF THE 導線: there is NO native skill source WIRED. The two hooks that were
actually armed in game (PalPlayerController:PlaySkill and :SkillDamageReactionComponent_
ProcessDamage_ToServer) fired 0 times, and Lua cannot inject a row into the skill
DataTables (that is PalSchema's job). The reflection dump has since named several
unarmed candidates on classes that are proven loaded — see the per-hook markers below —
so "no candidate exists" is no longer the blocker; "none has been observed firing" is.
So:
* NOTHING fires these handlers automatically — core/event.lua declares no skill
channel (M.CHANNELS is world / building / pal / item / tick) and nothing in the tree
emits one, so a declared `events` table is inert until you call into it yourself.
* What DOES work is MANUAL invocation: :activate(owner) / :hit(target) /
:equip(owner) / :unequip(owner) run the handler now, with the cooldown enforced
here in Lua. That is enough to drive a skill from your own code — e.g. from a Pal's
onTick, a building's onRightClick, or a keybind.
* Nothing here reaches the engine EXCEPT :iconOf, and that one lookup has never been
observed to return a value (see TODO(skill-icon-key) below).
Wiring a native source later means adding the channel AND the dispatch that resolves it
to a definition, in core/event.lua — the handlers below are then reached unchanged, but
that dispatch does not exist yet either. The three unknowns are marked in place, one per
hook, with the probe that would settle each.

local Fireball = Skill{
id = "example:Fireball", kind = "active", element = "fire",
cooldown = 3.0, power = 50,
events = { onActivate = function(skill, owner, ctx) --[[ ... ]] end },
}
Fireball:activate(myPalActor)      -- runs onActivate unless still cooling down
```

**What the probe prints**

In a fully loaded world, UE4SS Lua console. STEP 1 (get the table): `local dt; for _, o in
ipairs(FindAllOf("DataTable") or {}) do if o:IsValid() and o:GetFName():ToString() ==
"DT_partnerSkillIconDataTable" then dt = o end end; print("found", dt ~= nil, dt and
dt:GetFullName())`. STEP 2 (columns — this is the whole of fact (b)): `local rs = dt.RowStruct;
print("rowstruct", rs and rs:GetFName():ToString()); rs:ForEachProperty(function(p) print("COL",
p:GetFName():ToString(), p:GetClass():GetFName():ToString()) end)` (the idiom already written at
dump/dump.lua:59). STEP 3 (what the table can do): `dt:GetClass():ForEachFunction(function(f)
print("FN", f:GetFName():ToString()) end)` walking GetSuperStruct to nil. STEP 4 (fact (a) — try
to read row "Alpaca", which the dump proves is a real row): print the ok flag and the result of
each of `pcall(function() return dt:GetDataTableRowFromName(FName("Alpaca")) end)`,
`pcall(function() return dt:GetDataTableRowFromName("Alpaca") end)`, `pcall(function() return
dt:FindRow(FName("Alpaca"), "probe", false) end)`, and also via the CDO
`StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")` for any GetDataTableRow*
function STEP 3 revealed. STEP 5 (for any non-nil row): print `type(row)`, and when userdata
print `row:GetClass():GetFName():ToString()` plus, for every column name from STEP 2,
`tostring(row[col])` and `row[col].ToString and row[col]:ToString()`. PASTE BACK: the full
column list with class names, which of the four read calls returned non-nil, and the value of
every column for row "Alpaca".

#### `skill-passive-source` — Skill.Spec.Events.onEquip / Skill.Spec.Events.onUnequip

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/skill.lua:88

**What a pack author sees**

Both handlers only run when the pack calls Handle:equip(owner) / Handle:unequip(owner). PalForge
keeps no equipped set and never tells the game anything, so declaring kind = "passive" plus
onEquip attaches nothing.

**What is still unknown**

```text
TODO(skill-passive-source): NARROWED — the shortlist exists now. dumps/reflection/
02_reflection.txt puts AddPassiveSkill and RemovePassiveSkill on /Script/Pal.Pal-
IndividualCharacterParameter, together with GetPassiveSkillList to read the result back
and an OnPassiveSkillUpdateDelegate (+ its __DelegateSignature) that announces the
change; PalCharacter owns a :PassiveSkillComponent and PalGameInstance a
:PassiveSkillManager. So both halves this channel wants — a SOURCE to hook and an
attach call for Handle:equip to make real — have named targets on classes proven
loaded. Covers onUnequip too: same object, RemovePassiveSkill.
THE ONE THING LEFT: the parameter list of Add/RemovePassiveSkill (passive row FName vs
an index into a fixed-size array), and whether hooking them catches the statue-of-power
/ party in-out path. 02_reflection prints names only, and neither was ever armed.
```

**What the probe prints**

STEP 1 (find the holder): `local pal = FindFirstOf("PalCharacter")` in a world with a deployed
Pal; print `pal:GetClass():GetFName():ToString()`, then enumerate the class chain with `local c
= pal:GetClass(); while c do c:ForEachProperty(function(p) print("PROP",
p:GetFName():ToString(), p:GetClass():GetFName():ToString()) end); c:ForEachFunction(function(f)
print("FN", f:GetFName():ToString()) end); c = c:GetSuperStruct() end`. Repeat the same
enumeration for the CDOs `StaticFindObject("/Script/Pal."..n)` with n in {"PalIndividualCharacte
rParameter","PalCharacterParameterComponent","PalIndividualCharacterHandle","PalPassiveSkillComp
onent","PalCharacterContainer"}, printing whether each class EXISTS (non-nil) — the existence
answer alone is load-bearing. STEP 2 (shortlist): print every function or property whose name
contains Passive / Skill / Add / Remove / Set / Array. For each shortlisted UFunction print its
parameters via `f:ForEachProperty(function(p) print(" PARAM", p:GetFName():ToString(),
p:GetClass():GetFName():ToString()) end)`. STEP 3 (confirm live): RegisterHook every
Add*/Remove* found (dump/auto_mod/main.lua pattern), then in game capture a Pal, use the Statue
of Power / passive-skill change bench, and pull a Pal in and out of the party. PASTE BACK: which
classes existed, the shortlisted function names with their parameter lists, and which hooks
fired during those actions with their parameter values.

### Audio

#### `audio-custom-file-loader` — Audio.Spec.soundFile (Audio{ soundFile = ... }:play, via core.sound.file FileSource:play)

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/sound/file.lua:19

**What a pack author sees**

soundFile is an accepted, validated, documented field that takes precedence over
soundId/soundPath — and then plays nothing. The definition lowers to { kind = 'file' },
core.sound resolves it to a FileSource, and :play() returns false. A pack that ships its own
.wav gets silence, and worse, setting soundFile alongside a working soundId silences that too
because the file route wins.

**What is still unknown**

```text
TODO(audio-custom-file-loader): it is unknown whether the shipping build exposes ANY
runtime loader that turns a file on disk into something playable (a USoundWave/USoundBase
factory, or a Wwise external-source / SetMedia entry point); enumerating the audio-related
CDOs' reflected functions would settle whether such a call exists at all.
```

**What the probe prints**

In a fully loaded save, print and paste all of it — a run of nils closes this item permanently:
(1) class existence: for each of '/Script/Engine.Default__SoundWave',
'/Script/Engine.Default__SoundBase', '/Script/Engine.Default__GameplayStatics',
'/Script/AkAudio.Default__AkExternalMediaAsset', '/Script/AkAudio.Default__AkMediaAsset',
'/Script/AkAudio.Default__AkGameplayStatics' do local o = StaticFindObject(path); print(path, o,
o and o:GetFullName()). (2) for '/Script/Engine.Default__GameplayStatics' if it resolved, log
its COMPLETE function list: o:GetClass():ForEachFunction(function(fn) print('FN',
fn:GetFName():ToString()) end) — we are looking for PlaySound2D / CreateSound2D /
SpawnSoundAttached surviving in shipping. (3) for any AkAudio class that resolved, log every
function name containing External, Media, Source, Post or Load, and for each walk
fn:ForEachProperty printing name + property-class + offset. (4) construction:
print(type(NewObject), type(StaticConstructObject), type(StaticConstructObject_Internal)) so we
know whether UE4SS Lua in this build can construct a USoundWave at all. (5)
print(#(FindAllOf('SoundWave') or {})) and #(FindAllOf('AkMediaAsset') or {}) — whether the
shipping game has any instance of either class loaded is itself the answer about whether that
pipeline is alive.

#### `audio-bus-volume` — Audio.Handle:setVolume

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/audio.lua:302

**What a pack author sees**

`setVolume` returns false and changes nothing. **The way to be quieter today is to pick a quieter
AkAudioEvent** — choosing the event is the only volume control a pack has, and on this build
there may be no per-sound volume at all.

The RTPC route this used to wait on is ruled out with evidence (see `audio-volume-rtpc` under
Closed): the build declares three AkRtpc assets and none is a volume. The only candidate left is
`SetOutputBusVolume`, reflected on both AkComponent and AkGameplayStatics — and it moves a whole
output BUS, not one sound, so even when it works it cannot satisfy this method's per-sound
contract. If it is wired it belongs on the module as a bus call.

**What is still unknown**

1. `SetOutputBusVolume`'s parameter list, on either owner — is the bus an FName or an FString, is
   there a leading AkComponent/actor, is the value 0..1 or dB, is there a fade argument. Until a
   real list is printed, do not call it.
2. Whether a per-sound AkComponent is reachable at all. 248 AkComponents are live, but the first
   sampled one is a PalAkComponent owned by a level gimmick, and our play route
   (`PlayAkEventSoundByActor`) hands back nothing — no component, no PlayingID. If there is no
   component to call the overload on, the AkGameplayStatics overload is bus-global and this
   method stays false permanently, which is itself an answer worth having.

**What the probe prints**

`SetOutputBusVolume`'s declared parameters on AkComponent and on AkGameplayStatics, and what a
live AkComponent sample looks like. It calls neither.

#### `mesh-base-material` — Mesh.Spec.color / texture / material on kind="procedural" and kind="obj"; Mesh.Handle:setColor on a procedural mesh

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/mesh/base/renderer.lua:112

**What a pack author sees**

A procedural OBJ mesh attaches and is visible but always white. The log says "no-MID(no material
on the component and no base material loaded)", and every later :setColor on that actor returns
false forever, because there is no material instance to write to. This is the one behaviour with
an in-game record: PalLogistics extensions/pallogistics/init.lua:42 says "no-MID -> white".

**What is still unknown**

```text
Candidate base materials to PARENT a MID to, for a component whose element has NO
material of its own (a fresh ProceduralMeshComponent section is the standing case:
CreateAndSetMaterialInstanceDynamic returns nil there). StaticFindObject only returns
ALREADY-LOADED objects, so we try several and take the first present.
TODO(mesh-base-material): every candidate below is an /Engine/ editor asset that a
cooked shipping build may not contain at all — the one in-game record of this path is
"no-MID -> white" — so a probe must find whether ANY loaded material can serve here.
```

**What the probe prints**

In-world, first the cheap check: `require('palforge.core.mesh').probeMaterials()` and read the
five `MATPROBE FOUND` / `MATPROBE -----` lines it prints. Then enumerate what IS loaded: `local
n=0; for _, m in ipairs(FindAllOf('Material') or {}) do n=n+1; if n<=150 then print('MAT
'..m:GetFullName()) end end; print('total Material', n)` and repeat for
'MaterialInstanceConstant' and 'MaterialInterface'. For the first ~30 of them print whether a
VectorParameterValues array is present and, if so, each `entry.ParameterInfo.Name:ToString()`.
Report one loaded object path that carries a colour parameter — that path goes to the front of
Renderer.BASE_MATERIAL_CANDIDATES.

#### `mesh-material-params` — Mesh.Spec.color / texture / params on every kind, Mesh.Handle:setColor, Building.Instance:update(), Building.Handle:update(), Pal.Class:material()

- **Probe:** F6
- **Marked at:** Scripts/palforge/core/mesh/base/renderer.lua:95

**What a pack author sees**

setColor returns true and the log says "material [color-set]", but the mesh does not change
colour. The call executed on a real dynamic material instance; the parameter name simply was not
one the material carries. Six candidate names are written per slot and all six may miss.

**What is still unknown**

```text
palforge/api/building.lua — PUBLIC building API + implementation (SELF-CONTAINED).

A building is a placeable structure: workbenches, storage, machines, decorations —
anything picked from the build menu and set into the world. Same shape as every other
api module (call it to define, plus get / get_all + a Handle object with actions and
grouped `events`).

HOW IT INTEGRATES: Building{ ... } registers the definition class in object_manager
under ("building", id). core/event owns the FULL building runtime and is the most
complete 導線 in PalForge:
* a RequestBuild_ToServer hook records the placement intent,
* a ~500 ms reconstruction scan over FindAllOf("PalBuildObject") discovers the real
actor, creates a live INSTANCE (def.cls:new{...}), persists it per world, and
attaches the mesh on a later scan (deferred — attaching the frame it is placed
crashes the game),
* an OnBeginInteractBuilding hook drives the interact channel,
* an OnCompleteBuild_ServerInternal hook drives onBuild — armed only once the world
is ready, and dispatched to the DEFINITION rather than to an instance (see below),
* the shared heartbeat drives onTick (per-instance tickInterval + circuit breaker).
This is the one domain where a placed structure really does get its own stateful
instance with save/load, and where onPlace / onLoad / onRightClick / onRemove / onTick /
onWorldReady / onWorldLeft all fire for real.

WIRED (live — see core/event installBuildingSource + installDispatch):
onPlace      <- the scan, matched to a RequestBuild intent  (ctx.actor, ctx.pos, ctx.player)
onLoad       <- the scan, every newly tracked structure     (ctx.reconstructed)
onRightClick <- PalBuildObject:OnBeginInteractBuilding      (ctx.actor, ctx.player)
onRemove     <- the scan's miss sweep                       (ctx.reason)
onTick       <- the shared heartbeat                        (ctx.count; see tickInterval)
onWorldReady / onWorldLeft <- the world-load watch, fired on every live instance
onBuild      <- PalPlayerRecordData:OnCompleteBuild_ServerInternal (ctx.buildId,
ctx.model) — DEFINITION-dispatched and armed late; see the next paragraph
NOT WIRED: onLeftClick / onBreak. No native candidate has ever been found for either
(the only proven click hook in the tree is a UMG widget button, and destruction is
covered by the scan's miss sweep -> onRemove), so nothing emits them. They stay
declarable so a pack's code is future-proof; they never fire.

THE VISUAL LAYER, HONESTLY. A structure's `mesh` really is attached: core/mesh's static
backend adds a UStaticMeshComponent and confirms the asset landed on it before claiming
success. `color` / `texture` / `material` / `params` reach it too — the MID work is
core/mesh/base/renderer's, shared by every backend — and :update() re-tints through the
same MIDs. The one thing nobody has measured is which PARAMETER NAMES a Palworld
material actually carries: the layer writes a candidate list and the names the material
does not have are silent no-ops, so a tint can execute and still not be visible. That
open question is marked TODO(mesh-material-params) in core/mesh/base/renderer.lua.

A live structure can also look around itself: `self:neighbors(radiusCm)` inside any
instance hook returns every other tracked structure within that radius (core.spatial's
hash grid, re-bucketed first so a structure that moved is still found).

The lifecycle receives the live INSTANCE as `self` (not the class): self.actor is the
placed actor, self.pos its world position, self.state your persisted table, and
self:save() writes it. onBuild is the ONE exception, and it has to be: it fires at
build-COMPLETE, up to one scan (~500 ms) before the instance exists, and the game hands
it a UPalMapObjectModel rather than the actor — so core/event dispatches it to the
DEFINITION class instead (self.id and self:iconOf() are there; self.actor / self.pos /
self.state / self:save() are NOT), matched by the game build id the definition claims.
Its native hook also fires for every pre-existing structure during the world-load storm,
where reading that model once produced a native access violation, so core/event arms it
only after world.ready and never at mod load — which means it also stays silent in a
session where the world never finishes loading. onPlace remains the safe placement hook;
onBuild is the extra one, worth trying in a throwaway world first.

onWorldReady fires on the live instances: the ready-watch opens core/event's worldReady
gate, but world.ready is emitted by the FIRST reconstruction scan that completes after
it, so the structures around the player are already tracked when the hook runs. It is a
ONE-SHOT world-load moment, not a per-structure one — anything that streams in on a
later scan misses it, so per-instance startup work belongs in onLoad.

Building{
id = "example:Bench", name = "Modded Bench", gridCm = 100,
mesh  = { kind = "static", model = "/Game/.../SM_Bench.SM_Bench" },
state = { uses = 0 },                       -- default persisted state
events = {
onPlace      = function(self, ctx) self.state.uses = 0; self:save() end,
onRightClick = function(self, ctx) self.state.uses = self.state.uses + 1 end,
onTick       = function(self, ctx) end,
},
}
```

**What the probe prints**

Get hold of a real Palworld material. Either take a placed structure — `local a =
(FindAllOf('PalBuildObject') or {})[1]` — or attach a static WorkBench mesh through PalForge and
keep the component. From the component: `local n = comp:GetNumMaterials(); print('slots', n)`,
then for each slot `local mat = comp:GetMaterial(i); print('SLOT '..i..' '..mat:GetFullName()..'
class='..mat:GetClass():GetFName():ToString())`. Dump the material's parameter arrays: for each
of VectorParameterValues / ScalarParameterValues / TextureParameterValues, `local arr;
pcall(function() arr = mat[name] end)` and if present iterate it printing
`entry.ParameterInfo.Name:ToString()` and the value. Also
`mat:GetClass():ForEachProperty(function(pr) print('PROP '..pr:GetFName():ToString()..'
'..pr:GetClass():GetFName():ToString()) end)`. Then the visual half: `local mid =
comp:CreateAndSetMaterialInstanceDynamic(0)`, and for each candidate name in {Color, BaseColor,
Tint, BaseColorTint, Albedo, EmissiveColor} plus every name harvested from
VectorParameterValues, call `mid:SetVectorParameterValue(FName(name), {R=1,G=0,B=0,A=1})`, print
the name, wait ~2s, and report WHICH name visibly turned the mesh red.

#### `ui-host-paths` — native.ui.widget.cloneGameWidget / UI.Handle:mount(<a panel of the game's own live UI>)

- **Probe:** F5
- **Marked at:** Scripts/palforge/native/ui/_widget.lua:51

**What a pack author sees**

A pack can build a native-looking widget but has nowhere in the game's own UI to put it. M.PATHS
names the title menu only, so every PalForge panel is either a title-menu entry or a separate
full-screen layer of our own (widget.screen). Nothing can be parented into the HUD, the
inventory or the build menu; cloneGameWidget runs but there is no second class path to clone.

**What is still unknown**

```text
Known Palworld UI asset/class paths. TITLE MENU ONLY — every entry below was read off
WBP_Title_MenuButton and the title screen (verified 2026-07-17, poc/V7-title-injection).
Nothing here names the live HUD, the inventory or the build menu, so cloneGameWidget()
and Button:mount(<a panel of the game's own>) have no in-game host to target: a PalForge
panel today is either a title entry or a viewport layer of our own (M.screen).

The HUD's own CLASS is known — deprecated/catalog/ui_widget_classes.txt lists
UPalUIHUDLayoutBase (and UPalUIWorldHUDWidgetCanvas / UPalUIInventoryEquipment); note it
does NOT list the "PalHUD"/"PalHUDWidget" that dump/docs/04_native_ui.md guesses at. What
is missing is one level down, and no dump in either tree has it:
TODO(ui-host-paths): unknown — the widget NAME of a child inside the live
PalUIHUDLayoutBase tree that is a UPanelWidget (i.e. answers AddChild), which is the one
fact needed to parent a PalForge widget into the game's HUD instead of our own layer.
```

**What the probe prints**

With a world loaded and the HUD visible: for each of "PalUIHUDLayoutBase",
"PalUIWorldHUDWidgetCanvas", "PalUIInsideBaseCampCanvas", "PalUIInventoryEquipment" do `local r
= FindFirstOf(name)`, log name .. ' valid=' .. tostring(r and r:IsValid()), then take
`r.WidgetTree.RootWidget` and walk it depth-first exactly the way _widget.findByName walks
(GetChildrenCount()/GetChildAt(i), plus descend a child's own .WidgetTree.RootWidget, plus
GetContent() when childCount==0). For EVERY node print: depth, `w:GetFName():ToString()`,
`w:GetClass():GetFullName()`, and `w:GetChildrenCount()` (print '-' if the call errors — that
identifies non-panels). Then, for each node whose GetChildrenCount() succeeded, construct one
throwaway TextBlock (StaticConstructObject of /Script/UMG.TextBlock into a fresh
/Script/UMG.WidgetTree) and inside a pcall call `w:AddChild(tb)`; print `nodeName .. ' AddChild
-> ' .. tostring(slot) .. ' ' .. (slot and slot:GetClass():GetFullName() or 'nil')`, then
`w:RemoveChild(tb)`. Finally open the Inventory and the Build menu and log every live widget
once: `for _, w in ipairs(FindAllOf("UserWidget") or {}) do print(w:GetFName():ToString(),
w:GetClass():GetFullName(), w:GetFullName()) end`.

#### `ui-menubutton-inner-slot` — native.ui.widget.menuButton (label alignment) — and therefore every TitleMenu entry

- **Probe:** F8
- **Marked at:** Scripts/palforge/native/ui/_widget.lua:356

**What a pack author sees**

A title-menu entry's label may sit centred where the game's own entries sit left.
leftAlignButtonContent calls SetAnchors/SetAlignment on HorizontalBox_0's Slot inside a pcall;
if that slot is not a CanvasPanelSlot both calls raise and are swallowed, and nobody has ever
observed which happens. Cosmetic only — the label is legible either way, and clickableRow does
not depend on it.

**What is still unknown**

```text
Force a freshly created WBP_Title_MenuButton's inner content to the left so labels align
regardless of the button's outer width. Cosmetic and best-effort: SetAnchors/SetAlignment
exist on a CanvasPanelSlot, and nobody has recorded what HorizontalBox_0's Slot actually
is inside that button — on any other slot class both calls raise inside the pcall and the
label simply stays centred. Left as-is rather than guessed at: the label is still legible
either way, and clickableRow does not depend on it (it overlays its own left-aligned text).
TODO(ui-menubutton-inner-slot): unknown — the CLASS of `HorizontalBox_0`.Slot inside a
created WBP_Title_MenuButton, which decides whether these two calls do anything at all.
```

**What the probe prints**

At the title screen: `local lib =
StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"); local pc =
FindFirstOf("PalPlayerController"); local btn = lib:Create(pc, StaticFindObject("/Game/Pal/Bluep
rint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C"), pc)`. Depth-first
find the child named "HorizontalBox_0" (GetChildrenCount/GetChildAt + nested WidgetTree descent)
and print `'created inner slot = ' .. tostring(inner.Slot:GetClass():GetFullName())`. Do the
same for a NATIVE entry's HorizontalBox_0 reached through
FindFirstOf("PalUITitleBase").WidgetTree.RootWidget and print `'native inner slot = ' .. ...` —
if they differ, that is the answer. While that tree is walked, also print every node as `depth,
GetFName():ToString(), GetClass():GetFullName()` so the three literals TitleMenu matches by name
("VerticalBox_0", "SizeBox_4", "WBP_Title_MenuButton_ExitGame") are re-confirmed on the current
game version at the same time.

#### `ui-update-event` — UI.Handle:autoRefresh(ms) — polling is the only refresh driver PalForge has

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/ui.lua:273

**What a pack author sees**

Nothing calls refresh() for a pack. Every element must either call :refresh() by hand or ride
the 500 ms heartbeat, so a panel shows stale content for up to `ms` and there is no way to
refresh exactly when the game rebuilds a screen. TitleMenu's whole re-injection strategy is a
poll for the same reason.

**What is still unknown**

```text
TODO(ui-update-event): unknown whether Palworld raises a catchable UFunction when a
UI is (re)built — until one is dumped, polling is the only driver PalForge has.
```

**What the probe prints**

For each class name in { "PalUIManagerSubsystem", "PalUIHUDLayoutBase", "PalUITitleBase",
"PalUIInventoryEquipment" }: `local cls = StaticFindObject("/Script/Pal." .. name)` and `local
cdo = StaticFindObject("/Script/Pal.Default__" .. name)`; log which resolved. Then enumerate
that class's UFunctions — `cls:ForEachFunction(function(fn) ... end)` if available, else walk
`cls.Children` following `.Next` — and for each print `name .. '::' .. fn:GetFName():ToString()`
followed by each of its own child properties as `' ' .. p:GetFName():ToString() .. ' ' ..
p:GetClass():GetFullName() .. ' @' .. tostring(p:GetOffset_Internal())`. From that list
RegisterHook every function whose name contains Open / Show / Construct / Refresh / Update /
Setup, each logging `'FIRED <path>'` once; then in game open and close the inventory, open the
build menu, and return to the title screen, and paste which paths fired and in what order.

### Events and icons

#### `icons-row-read` — core.icons.resolve -> Item/Pal/Building/Skill Handle:iconOf()

- **Probe:** F1
- **Marked at:** Scripts/palforge/core/icons.lua:377

**What a pack author sees**

`:iconOf()` falls back to the icon you declared yourself and never finds the vanilla one, so a
pack cannot reuse the game's own artwork for an item, pal, building or partner skill.

**What is still unknown**

Whether `GetDataTableColumnAsString` is reflected on this build. That is the whole of it — the
question used to be "does any way to read a DataTable value exist" and is now one yes/no.

What changed: reading a ROW was the wrong question. `dumps/cxx/Engine.hpp` dumps `UDataTable`
in full and it declares five properties and **zero functions**, so every accessor this code used
to try (`dt:GetDataTableRowFromName`, `dt:FindRow`) was called on an object that does not have
it. The real accessors are statics on `UDataTableFunctionLibrary` and take the table as their
first argument:

```text
void GetDataTableRowNames(UDataTable* Table, TArray<FName>& OutRowNames);
bool GetDataTableRowFromName(UDataTable* Table, FName RowName, FTableRowBase& OutRow);
TArray<FString> GetDataTableColumnAsString(const UDataTable* DataTable, FName PropertyName);
bool DoesDataTableRowExist(UDataTable* Table, FName RowName);
```

The row-VALUE one still cannot be used, for the reason this module worked out correctly long
ago: it is CustomThunk with a wildcard out-struct whose real type comes from Blueprint bytecode,
so a reflected call can only offer the declared `FTableRowBase` and the thunk rejects it. So
`core/icons.lua` reads a COLUMN instead — no wildcard, no out-param, an object and an FName in,
an array of plain strings out, one per row in RowMap order. `GetDataTableRowNames` walks the
same RowMap in the same order, so zipping the two gives id -> icon path for a whole table in two
calls and never needs a row struct in Lua.

The sibling is the evidence: `GetDataTableRowNames` on this same library is proven on this build
and runs in production in `utils/items`. The column call has simply never been made.

Settled alongside it, from `dumps/cxx/Pal.hpp`: the column TYPE. All three row structs carry
exactly one field and it is a `TSoftObjectPtr<UTexture2D>` — an asset path, which is what
`LoadAsset` wants, so reading the column as a string loses nothing. It also confirms the column
NAMES (`Icon`, `Icon`, `SoftIcon`) from the shipping binary.

**What the probe prints**

F1 in a loaded world. The suite asks the question a pack author would — can PalForge reuse the
game's own artwork for `Wood`? — and `core.signature` logs whether
`GetDataTableColumnAsString` is declared here. `declared`/`present` plus a row count closes the
item; `refused ... is not declared on this build` means the library is unreflected here and icon
resolution has no route at all, which is equally an answer.

#### `pal-spawned-fresh` — Pal{ events = { onSpawned } } / event.on("pal.spawned")

- **Probe:** F7
- **Marked at:** Scripts/palforge/core/event.lua:928

**What a pack author sees**

The hook is armed (late, after world.ready) and the dispatch resolves, but it has never been
seen to fire: onSpawned may simply never run, and a pack cannot tell that from 'no pal spawned'.

**What is still unknown**

```text
spawned (UNCONFIRMED candidate): fires when a pal finishes parameter init.
ARMED AFTER world.ready, NEVER AT start() — unlike the three confirmed hooks above.
The probe recorded this one firing 0 times when it was armed at load and the pals it
watched pre-existed it (dump/docs/further_plan.md:83-85), and the same note records
WHY that arming is actively harmful: "BroadcastOnCompleteInitializeParameter fires in
the world-load pal-init storm and wedged the shared hook dispatch; must be armed only
AFTER load, or avoided" (:61-64). Wedging the SHARED dispatch takes the three
confirmed hooks down with it, so late arming protects them, not just this one.
Still unproven that it signals a FRESH spawn: that needs a post-load spawn probe, so
keep handlers idempotent and treat the channel as a candidate.
TODO(pal-spawned-fresh): unknown whether BroadcastOnCompleteInitializeParameter fires for a
pal spawned AFTER world load — every probe pal so far pre-existed the hook (0 firings).
```

**What the probe prints**

Enter a world, wait 30 s so the load storm is over, then
RegisterHook("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter", fn) logging
os.clock(), self:get():GetClass():GetFName():ToString() and self:get():GetFullName(). Print a
marker line before each of these, done one at a time: (a) release a pal from the palbox, (b)
hatch an egg / trigger a wild spawn by travelling, (c)
FindFirstOf("PalCheatManager"):SpawnMonster(FName("ChickenPal"), 1). Paste which markers were
followed by a firing and with what class name. If none fires, additionally arm
"/Script/Pal.PalCharacter:BeginPlay" and every function matching Spawn found by reflecting the
PalMonsterSpawner classes, and paste those.

