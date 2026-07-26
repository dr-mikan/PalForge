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
| F8 | Arms hooks and watches for 60 s while you act | A save, then craft / drop / spawn |
| F2 | Title-screen widgets | The title screen |
| F9 | Reload every palforge module without restarting the game | Anything |

Only F8 changes anything, and it says so before it arms a hook.

**Every probe also has a console command**, because a key the game has claimed binds
successfully and then never fires — which from the log is indistinguishable from a probe that
ran and found nothing. Open the UE4SS console window and type one:

```text
pf_tests   pf_watch   pf_reflect   pf_pal   pf_title
pf_spawn   pf_teach
```

### When neither a key nor the console works

`Scripts/palforge/autorun.txt` runs named actions on world.ready — no key, no console, nothing
to press. Put a line in it, deploy, load a save:

```text
pf_spawn        # as soon as the world is ready
20 pf_teach     # 20 seconds after
```

Only names already in the `pf_*` action table can run; it reads a list of names, never code.
This exists because three input routes failed in turn on a real machine — a key Palworld had
already claimed, a second key, and a console UE4SS ships switched off — and each time the work
was fine and only the way in was missing.

**UE4SS ships with its console OFF**, and a command registers perfectly well into a window that
does not exist — which is the same failure the console was meant to escape, one layer down. Turn
it on in `ue4ss/UE4SS-settings.ini` and restart:

```ini
ConsoleEnabled = 1
GuiConsoleEnabled = 1
GuiConsoleVisible = 1
```

The last two exist because two channels are only observable while something specific is
happening, and "go and play until it does" is a poor instruction when the something is
"catch a pal strong enough to fight". `pf_spawn` puts one in front of you; `pf_teach` gives the
nearest pal a passive skill through the same call the `skill.equip` source hooks. PalForge can
make the situation, so it should.

**F7 is Palworld's own volume key** and the game claims it before UE4SS sees it, so a probe
bound there can never be pressed — which is where `watch` sat, unreachable and silent about
it. The bindings are printed at startup now, so a key the game has taken is visible in the
log rather than looking like a probe that found nothing.

## Closed (31)

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
- **`item-craft-source`** — Item.Spec.Events.onCraft. **Observed live**, 2026-07-26: crafting at a real machine reaches `OnFinishWorkInServer` on one of the two work models that carry an item id, and the channel was seen carrying its first event in a real save. Wired on the header dump alone — neither class is among the 21 in the live reflection dump — and now reproducible by crafting anything. `ctx.count` stays nil: the count lives in the recipe row, and a hook is no place for a DataTable read.
- **`item-discard-source`** — Item.Spec.Events.onDiscard. **Observed live**, 2026-07-26, with the slot resolving to a real item id. Two separate things had to be right. A drop does NOT go through `AddItem_ServerInternal` — that hook was armed and fired zero times across two sessions, because dropping goes through `UPalNetworkItemComponent`, one class over from everywhere the search had looked. And the container holding the dropped slot is not necessarily one the player's inventory helper lists: the first live firing reported "no container of the player's 6 matched", so the set comes from a world sweep now. The GUID match is exact, which is what makes the wider search safe.
- **`skill-activate-source`** — Skill.Spec.Events.onActivate. **Observed live**, 2026-07-26, in real combat: `skill.activate carried its first event from source "PalActionBase:OnBeginAction"`. The source that works is the ACTION OBJECT, not a utility that builds one — a pal's move IS a `UPalActionWazaBase` and carries its own `EPalWazaID`, so hooking it puts the identity a handler needs on `self` rather than in someone else's argument list. `PlayActionByWazaID` stays armed as the control that proved it: it registered successfully and carried nothing while a pal fought and killed another pal, which is what sent the search to the action side.
- **`pal-spawned-hook`** — Pal.Spec.Events.onSpawned. **Observed live**, 2026-07-26, from BOTH new sources: `PalNPC:OnCompletedInitParam` and `PalPlayerCharacter:OnCompleteInitializeParameter`. They are the bound TARGETS of the initialise broadcast, not the broadcaster — which was hooked first, registered fine, and never carried anything. That is the general lesson and it is worth keeping: RegisterHook sees what ProcessEvent runs, and a broadcaster is not it.
- **`skill-passive-source`** — Skill.Spec.Events.onEquip. **Observed live**, 2026-07-26: `skill.equip carried its first event from source "AddPassiveSkill"`. The write that triggered it came from PalForge itself — `core/character.addSkill` put a passive on a live `BP_ChickenPal_C` and read it back — which is a useful property in its own right: the source catches a pack's own writes as well as the game's. It also confirms the passive half of `pal-skills-equip` on the way past. `SetupSkillFromSelf` stays armed beside it and has carried nothing yet, so which call the GAME uses when a player changes a passive at a bench is still open — the log names the source, so one bench visit settles it.

## Open (7)

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

#### `item-datatable-row-read` — Item.Handle:iconOf / Item.Handle:recipeOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/item.lua:175

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

#### `skill-hit-source` — Skill.Spec.Events.onHit

- **Probe:** ordinary play
- **Marked at:** Scripts/palforge/api/skill.lua:105

**What a pack author sees**

`onHit` never fires. Everything else about a skill works — `onActivate` fires, and the handler
gets the move's identity.

**Both hooks are measured silent, and they rule out different things**

- `MakeDamageInfoByWazaType` — silent while a pal fought and killed another pal.
- `PalAnimNotifyState_AttackCollision:OnHit` — silent in that same session, and silent again in a
  session where the player killed a pal by hand. `pal.damaged` and `pal.death` both carried, so a
  blow certainly connected and certainly did damage.

A hit does not reach either, from either side.

**What that leaves is not another hook**

`skill.activate` works and carries the waza id. `pal.damaged` works. And nothing in the damage
path carries a waza at all — `FPalDamageInfo` has 40 fields, `FPalDamageRactionInfo` 6,
`FPalDamageResult` 12, and not one is an `EPalWazaID`. So the id can only reach a hit by being
remembered from the activation that preceded it and attributed to the damage that follows.

That is **inference, not a source**, and wiring it as one would be wrong: a move that misses, a
second pal attacking in the same window, or damage from anything else would all be attributed to
whatever activated last. If it is ever built it belongs behind a name that says so — a correlated
guess a pack opts into — and never on `onHit`, which promises the game told us.

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

- **Probe:** F8
- **Marked at:** Scripts/palforge/core/event.lua:1043

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

