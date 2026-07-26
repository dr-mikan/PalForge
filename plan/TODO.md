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

## Closed (26)

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
- **`pal-spawnmonster-signature`** — Pal.Handle:spawn. **Observed working**, 2026-07-26. The call was never broken: `cm:SpawnMonster(FName("ChickenPal"), lv)` was issued with `[evidence declared]`, meaning `core/signature.lua` walked the real UFunction on the installed binary and matched it. What was broken was the VERDICT around it — a spawn that arrives after ~4-6 seconds was measured synchronously, and the miss was reported as a property of the build. Three hypotheses died with it, including the server-authority one, which had been invented to explain an observation that never happened. `:spawn` now returns whether the call was ISSUED, because arrival is seconds away and no caller can block; the arrival line follows in the log, with elapsed seconds.
- **`pal-spawn-placement`** — core.spawn.palAt. **Observed end to end, twice, in the same press**: `placed new pal at (-345296,263050,4153); it reads back (-345296,263050,4153), off by 0`. Every half that had never been seen is now seen — the pal appears, the nearest-to-player anchor picks the right one, `K2_TeleportTo` accepts it, and the read-back is exact rather than approximate.
- **`icons-row-read`** — core.icons.resolve, and every domain's `:iconOf()`. **Observed working**, 2026-07-26, on every icon table at once: 674/674 pal, 1183/1207 item, 567/571 building, 311/311 partner skill. (The item table's 24 blanks are rows that genuinely carry no icon; six of the seven tables are at or near 100%.) Three wrong turns, each worth remembering: the row accessors are not UFunctions and not on `UDataTable` — UE4SS binds them itself; the value in an icon column is a `TSoftObjectPtr` userdata that answers none of the nineteen member names a soft pointer could plausibly expose, so the struct cannot be opened from Lua; and the string column that replaces it delivers its elements wrapped in **RemoteUnrealParam**, with the real value behind `:get()` — which is what made the array read the right LENGTH with nothing in it. `utils/items` had been unwrapping correctly all along.
- **`item-additem-signature`** — Item.Handle:give. **Observed working**, 2026-07-26: `give Wood x3: 140 -> 143`, with the game's own pickup event firing beside it (`Wood onObtain: count=3`) — two independent witnesses in a real save. The whole project was blocked on ONE argument. The live declaration is `(FName StaticItemId, int32 Count, bool IsAssignPassive, float LogDelay, bool bNotifyLog) -> EPalItemOperationResult` — five arguments and a return, where `dumps/cxx/Pal.hpp` has four and no `bNotifyLog` at all, because the dump predates the installed binary by one game patch. UE4SS counts the return as a slot, which is where "expected 6 parameters, received 4" came from. It also ANSWERS, with a named `EPalItemOperationResult`, so a refusal now explains itself instead of being inferred from a count that did not move — the thing the cheat-manager route could never do, and the reason establishing that `GetItem` reaches nothing took five in-game runs.
- **`pal-icon-row`** — Pal.Handle:iconOf. Closed with `icons-row-read`: DT_PalCharacterIconDataTable read 674 of 674 rows in a live save, so a vanilla pal id resolves to the game's own artwork and the declared `icon` is the fallback it was always described as.
- **`skill-icon-key`** — Skill.Handle:iconOf. Same read, 311 of 311 rows on DT_partnerSkillIconDataTable. What is left is not a read but a KEYING fact already recorded in core/icons: that table is keyed by PAL id, not skill id, so only a pal-derived partner skill can hit it. A passive skill has no row there and falls back to its declared icon — the correct answer rather than a missing one.
- **`ui-host-paths`** — native.ui.widget / UI.Handle:mount into the game's own UI. `WBP_PalOverallUILayout` declares `UCanvasPanel* CanvasPanel_Root`, and a UCanvasPanel is a UPanelWidget, so it answers `AddChild` with a `UCanvasPanelSlot`. Live-confirmed: an instance is alive under BP_PalGameInstance with its own WidgetTree (`dumps/reflection/03_widgets.txt:54`). Eliminated on the way: `UPalUIHUDLayoutBase` has **no widget members at all**, so the child "one level down" everyone was looking for never existed — it exposes `AddHUD` instead.
- **`audio-bus-volume`** — Audio.Handle:setVolume. The dump overturned the item's own premise. `UAkGameplayStatics::SetOutputBusVolume(float BusVolume, AActor* Actor)` takes **no bus name**: the second parameter is the Wwise game object, so it scales what ONE emitter sends to its bus, at exactly the scope `PlayAkEventSoundByActor` posts on. It was filed as bus-global and is not. Three other overloads were found and rejected with reasons (needs a component our play route never returns / world-global / needs a bus name, and this build has zero AkAuxBus). Wired as `setVolume(volume, actor)`, actor-wide by construction, exactly like `:stop`. Audibility is owed — nobody has heard it.
- **`item-remove-call`** — Item.Handle:take. **Observed working**, 2026-07-26, in the same press that proved give: `give Wood x3: 161 -> 164` then `take Wood x3: 164 -> 161`. A pack can charge a cost, and the items are CONSUMED rather than dropped — nothing lands at the player's feet to be picked straight back up, which is what made the DropItem route useless for this. The route is `APalWeaponBase::RequestConsumeItem(const FName&, int32)`, and the reason it went unfound for so long is that nobody thought to look on a WEAPON: the inventory's own class chain has no subtract, and neither does the container, the slot, or the cheat manager. The same weapon class declares `IsExistBulletInPlayerInventory`, so a weapon demonstrably reads and spends the owning PLAYER's bag. Both of the questions left open when it was wired are answered by that one press — it spends the id it is HANDED rather than the weapon's ammunition, and the weapon need only be spawned, not equipped. One real constraint remains and is reported as its own message: a player carrying nothing has no weapon actor to ask.
- **`mesh-material-params`** — Mesh.Spec.color / texture / params, Mesh.Handle:setColor. The names were **read off the running game**, 2026-07-26, because a header dump never could have said them — a CXXHeaderDump records classes, and which parameters an asset exposes is data inside a `.uasset`. Following each MaterialInstanceDynamic on the player's `CharacterMesh0` up to its MaterialInstanceConstant gave: vector `BaseColor`, `Subsurface Color`; texture `Base Texture`, `MetallicRoughnessOcclusionSpecularTexture`, `Normal Map`, `Subsurface Texture`; scalar `Character CameraFade Distance`, `Occlusion Add`, `Roughness Add`, `Light Affect Subsurface Max`, `RefractionDepthBias`. Mostly Title Case WITH SPACES, which no guess had — except `BaseColor`, which was already in the colour list, so tinting had a real chance all along while the texture list had none. Still owed: nobody has watched a colour actually change.
- **`mesh-base-material`** — the material a procedural mesh is parented to. Closed by the same read. `dumps/reflection/05_assets.txt` never swept Material, so not one material in this tree was known to be LOADABLE and five plausible `/Engine/` paths were five guesses. A material that is currently RENDERING is cooked and shipped by construction — the player's own outfit instance now leads the candidate list and carries the `BaseColor` vector a tint needs. It is a character shader hung on a procedural cube, which is odd and is said plainly at the list rather than hidden; a working material that looks wrong can be improved, an unloadable one cannot be used at all.

## Open (12)

### Pal

#### `pal-skills-equip` — Skill.Handle:teach / :forget, Pal.Handle:teachAll

- **Probe:** F1
- **Marked at:** Scripts/palforge/core/character.lua:53

**What a pack author sees**

`Skill.get("FireBlast"):teach(pal)` may return false and the pal may not learn the move. When it
works, the pal really does carry it — every write here is verified by reading the character back,
so a true is never "the call ran".

**Reading a pal's skills WORKS** — confirmed 2026-07-26 on a live `BP_SheepBall_C`:

```text
skills: the nearest pal carries 3 active, 1 passive, 3 equipable, 0 mastered
```

The whole route answers: actor → `PalUtility` → individual parameters → four getters, with a
real pal's real loadout coming back. `Skill.Handle:skillsOn(actor)` is usable today.

That took several runs for a reason worth keeping: `FindAllOf("PalCharacter")` is too wide.
`APalMonsterCharacter : APalNPC : APalCharacter`, so it matches villagers and merchants too, and
an NPC has no equipped move. Asking one of those reported zeros that looked exactly like a
broken reader. **Ask `PalMonsterCharacter`.**

**⚠️ Writing a move correlates with a crash — but the target may have been wrong**

The first run that did it — `AddEquipWaza` firing with evidence `declared`, the read-back not
showing the move, `RemoveEquipWaza` firing — was followed about 1.4 seconds later by Palworld
closing, part way through the mesh suite. The run before it, with no pal nearby, completed.

It is now known that the write did not necessarily go to a pal: it used the old search, and the
read-back it consulted afterwards was an NPC's empty list — which is also why it concluded the
write had not landed. Putting an equipped MOVE on a villager is a far more plausible way to
destabilise the game than putting one on a pal, so the crash may say nothing about this
capability and everything about that target.

The search is fixed and the experiment has not been re-run. It stays **opt-in** anyway: the
correlation is unexplained rather than explained away, this writes into a character in a real
save, and F1 is a key that gets pressed constantly. To run it deliberately, on a throwaway save:

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

**What the probe prints**

F1 in a loaded world with a pal nearby prints both read-backs, the player's and the pal's. The
enum spelling question is settled — these parameters are `EnumProperty`, and `core/signature.lua`
now accepts it.

#### `pal-spawned-hook` — Pal.Spec.Events.onSpawned

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/pal.lua:159

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
- **Marked at:** Scripts/palforge/api/item.lua:112

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
- **Marked at:** Scripts/palforge/api/item.lua:181

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
- **Marked at:** Scripts/palforge/api/item.lua:121

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

#### `skill-activate-source` — Skill.Spec.Events.onActivate

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/skill.lua:68

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
- **Marked at:** Scripts/palforge/api/skill.lua:85

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

#### `skill-passive-source` — Skill.Spec.Events.onEquip / Skill.Spec.Events.onUnequip

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/skill.lua:100

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
- **Marked at:** Scripts/palforge/core/sound/file.lua:43

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

#### `ui-menubutton-inner-slot` — native.ui.widget.menuButton (label alignment) — and therefore every TitleMenu entry

- **Probe:** F8
- **Marked at:** Scripts/palforge/native/ui/_widget.lua:426

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
- **Marked at:** Scripts/palforge/api/ui.lua:293

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

#### `pal-spawned-fresh` — Pal{ events = { onSpawned } } / event.on("pal.spawned")

- **Probe:** F7
- **Marked at:** Scripts/palforge/core/event.lua:1008

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

