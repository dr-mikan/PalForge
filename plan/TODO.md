# PalForge — what does not work yet

Every entry is a public thing a pack author can call that does not do what it says. None is a
wrong line of code: each is blocked on one fact about Palworld that nobody has measured — a
function's real parameter list, a property's real name, whether a class exists in the shipping
build at all.

Each item names that fact and the key that measures it. The probes are code, in
`Scripts/palforge/test/probes/`, and the same id appears as a `-- TODO(<id>)` marker at the line
a future implementer will open.

## How to close one

1. Load a save and press the key in the item's **Probe** line.
2. Copy what the probe wrote to `UE4SS.log` — it brackets its output with `#### BEGIN <id>`
   and `#### END <id>`.
3. The missing fact is then known and the implementation follows from it. Delete the marker.
4. Press **F1** to re-run the 294-check API suite, and **F9** to reload without restarting.

## Keys

| Key | What it does | What you need on screen |
| --- | --- | --- |
| F1 | The API test suite, the regression net | Anything. World-gated checks skip |
| F5 | Reflection dump: classes, functions, parameters, DataTable rows | A loaded save |
| F6 | Everything that needs a live pal: mesh, animation, materials | A pal near you |
| F7 | Arms hooks and watches for 60 s while you act | A save, then craft / drop / spawn |
| F8 | Title-screen widgets | The title screen |
| F9 | Reload every palforge module without restarting the game | Anything |

Only F7 changes anything, and it says so before it arms a hook.

## Closed (6)

Settled from the reflection dumps in `dumps/`, without touching the game.

- **`audio-akevent-play-signature`** — Audio.Handle:play. The recorded session caught the GAME ITSELF calling PalSoundUtility:PlayAkEventSoundByActor six times with exactly (AActor, UObject) in that order, which is the call PalForge already makes. Arity, order and callee are settled.
- **`spatial-saveid`** — core.spatial.saveId. PalGameInstance's full 111-property listing contains no WorldGuid, WorldSaveName or SaveName — all three probed names were wrong, which is why every save shared one persistence file. The real accessors are GetSelectedWorldSaveDirectoryName and GetSelectedWorldName, and core/spatial now reads them.
- **`building-leftclick`** — Building onLeftClick. PalBuildObject's complete 22-function list has no click, hit or attack entry. The standing candidate, OnDamage, turned out to be the deterioration timer: 196 firings on a strict 12-13 s cadence per structure, starting half a second after placement, with no player involved. Wiring the hook to it would have run every pack's handler every 12 seconds on every structure in the base.
- **`building-break`** — Building onBreak. None of PalBuildObject, PalMapObjectModel, PalMapObjectConcreteModelBase or PalNetworkPlayerComponent carries a destroy, dismantle or break function. Destruction exists only as delegate FIELDS, which RegisterHook cannot address by path. Disappearance keeps surfacing as onRemove with reason "missing".
- **`building-break-source`** — the building.break and building.leftclick channels. Same evidence, applied to the source side: neither channel is worth adding, and core/event now records why rather than carrying a hopeful TODO.
- **`icons-row-column`** — core.icons ICON_COLUMNS. The DataTable dump printed every table's real column list. Items and pals use `Icon`, buildings use `SoftIcon`, and partner skills use `TextureID_8_2B2F...`. Of the five names the code had been guessing, IconName, IconTexture and Texture are columns of no icon table on this build.

## Open (29)

### Pal

#### `pal-icon-row` — Pal.Handle:iconOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/pal.lua:238

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

#### `pal-skills-equip` — Pal.Spec.skills / Pal.Handle:skillsOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/pal.lua:203

**What a pack author sees**

skills = { "FlameThrower" } is validated, stored and read back by :skillsOf(), but the spawned
creature never gains the skill — the field is author metadata only.

**What is still unknown**

```text
The declared skill ids, verbatim. DECLARATIVE ONLY: nothing here teaches the pawn
anything — a pack reads the list back and drives each skill itself through api/skill.
TODO(pal-skills-equip): NARROWED — the attach calls EXIST, only their argument shape is
still unmeasured. dumps/reflection/02_reflection.txt lists, on /Script/Pal.PalIndividual-
CharacterParameter: AddEquipWaza / RemoveEquipWaza / ClearEquipWaza / ReplaceEquipWaza
(via the controller RPCs) for actives, AddPassiveSkill / RemovePassiveSkill for passives,
and the readbacks that would VERIFY a write — GetEquipWaza, GetEquipableWaza,
GetMasteredWaza, HasMasteredWaza, GetPassiveSkillList. The route from a pawn to that
object is named too: /Script/Pal.PalUtility:GetIndividualCharacterParameterByActor, or
PalCharacter:GetCharacterParameterComponent -> PalCharacterParameterComponent:
GetIndividualParameter. /Script/Pal.PalPlayerController additionally carries the
server-authoritative forms AddEquipWaza_ToServer / RemoveEquipWaza_ToServer /
ReplaceEquipWaza_ToServer.
THE ONE THING LEFT: the parameter list of AddEquipWaza / AddPassiveSkill — an FName, a
struct or an index — and whether the direct call replicates or the _ToServer RPC is
required. 02_reflection prints function NAMES only, never parameters, so calling one now
would be a guess with a live pawn on the other end. Nothing is pushed onto the pawn until
a probe prints those parameters (f:ForEachProperty on the UFunction) — this stays a
read-back of what the author declared.
```

**What the probe prints**

Use the dumper's own reflection pattern (dump/dump.lua:104). For each of
"/Script/Pal.PalCharacter", "/Script/Pal.PalCharacterParameterComponent",
"/Script/Pal.PalIndividualCharacterParameter", "/Script/Pal.PalMonsterParameterComponent": local
cls = StaticFindObject(path); cls:ForEachFunction(function(fn) print(fn:GetFName():ToString())
end); cls:ForEachProperty(function(p) print(p:GetFName():ToString()) end). Paste every name
containing Waza, Skill, Passive, Learn, Equip or Add. Then repeat ForEachFunction on a live pal:
actor:GetClass() for the first entry of FindAllOf("PalCharacter").

#### `pal-spawn-placement` — Pal.Handle:spawn(coord) / core.spawn.palAt

- **Probe:** F7
- **Marked at:** Scripts/palforge/core/spawn.lua:246

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
- **Marked at:** Scripts/palforge/api/pal.lua:143

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

#### `spawn-actor-conventions` — core.spawn.actor

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/spawn.lua:46

**What a pack author sees**

Public through _G.PalForge.core.spawn.actor and has never spawned anything for anyone: it tries
four argument conventions, logs that all of them failed, and returns nil.

**What is still unknown**

```text
collision 2 = AdjustIfPossibleButAlwaysSpawn; scale method 0 = OverrideRootScale.
Arg count/owner varies across UE builds — try conventions in order until one spawns.
TODO(spawn-actor-conventions): which of these four (if any) UE4SS can actually call on
this build is unknown — no run of BeginDeferredActorSpawnFromClass is recorded anywhere.
```

**What the probe prints**

A UFunction is a UStruct, so its parameters enumerate like properties. Run: local f =
StaticFindObject("/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass");
f:ForEachProperty(function(p) print(p:GetFName():ToString(), p:GetClass():GetFName():ToString())
end) — paste the names and classes in printed order; repeat for
"/Script/Engine.GameplayStatics:FinishSpawningActor". If StaticFindObject returns nothing for a
function path, fall back to
StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetClass():ForEachFunction(fn ->
print name) to confirm the names exist. Then call core.spawn.actor(playerPawn,
StaticFindObject("/Script/Engine.StaticMeshActor"), { Translation = <player pos>, Rotation = {},
Scale3D = { X = 1, Y = 1, Z = 1 } }) and paste the "convention N worked" / "all conventions
failed" / "FinishSpawningActor never ran" line.

### Item

#### `item-craft-source` — Item.Spec.Events.onCraft (channel item.craft)

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/item.lua:89

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
- **Marked at:** Scripts/palforge/api/item.lua:146

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
- **Marked at:** Scripts/palforge/api/item.lua:94

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

#### `item-inventory-count-readback` — utils.items.count / Item.Handle:count (and the verification inside :give and :take)

- **Probe:** F5
- **Marked at:** Scripts/palforge/utils/items/init.lua:60

**What a pack author sees**

count() may answer nil for every call, and take() may log 'CountItemNum unreadable, removal
unconfirmed' and answer false forever. In that state give() also loses its verification and
falls back to 'the call was issued'. Nothing in the tree has ever recorded this accessor
actually returning a number — the one caller (deprecated/container.lua:320) wrapped it in its
own pcall and its log was never captured.

**What is still unknown**

```text
How many of `id` the local inventory holds right now; nil when the count could not be read.

CountItemNum IS REFLECTED on this build — measured, not assumed. dumps/reflection/
02_reflection.txt enumerated /Script/Pal.PalPlayerInventoryData with ForEachFunction and
`.CountItemNum` is in its 69-function list, alongside the `.AddItem_ServerInternal` both
write helpers already call and the `.IsExistItem` boolean. The whole resolve chain in
playerInventory() is on that same measured footing: PalUtility.GetPlayerStateByPlayer and
PalPlayerState.GetInventoryData are both in the dump too. So the call reaches a real
UFunction; that is no longer the open question.

What is still open is the RETURN. ForEachFunction lists function NAMES only — no parameter
or return types — so whether this hands Lua a plain integer or a struct/userdata that
tonumber() flattens to nil is unmeasured. `.CountItemNum64` sits right beside it in the same
list, so when the 32-bit call yields something tonumber() cannot read, the 64-bit sibling is
tried before giving up; it costs one call and only on a path that was about to answer nil.
Every caller treats nil as UNKNOWN, never as zero, so a build that will not hand back a
number degrades to "unverified", not to a lie.
TODO(item-inventory-count-readback): unknown what CountItemNum RETURNS to Lua (int vs
struct/userdata) — its existence is settled, its shape is not. If both spellings answer
nil, the measured escape hatch is the container walk: PalPlayerInventoryData exposes
.TryGetContainerFromStaticItemID and .TryGetItemIdBySlot, PalItemContainer exposes
.Num / .Get / .GetItemStackCount, and PalItemSlot exposes .GetItemId / .GetStackCount /
.IsEmpty — all present in 02_reflection.txt, none of them with a known signature yet.
```

**What the probe prints**

Same inv as item-remove-call. Print, on separate lines: type(inv.CountItemNum); the result of
inv:CountItemNum(FName('Wood')) as both tostring(v) and type(v) and tonumber(v); then
inv:GetClass():GetFunctionByName('CountItemNum') and, if non-nil, walk its Children logging
every property's name, class name, offset and whether it is a return-param. Also try the sibling
names GetItemNum, GetItemCount, HasItem, GetItemStackCount the same way and print which ones
resolve.

#### `item-remove-call` — Item.Handle:take

- **Probe:** F5
- **Marked at:** Scripts/palforge/utils/items/init.lua:207

**What a pack author sees**

take() issues AddItem_ServerInternal with a negative Count and then reports what it measured.
Nothing has ever been observed to leave an inventory on this build, so a pack charging a cost
most likely gets false back and has to reverse its own give(). The call is made, the removal is
a hypothesis.

**What is still unknown**

```text
TRY to remove `count` of `itemId` from the local player's inventory. `count` is treated
as a magnitude.

⚠️ REMOVAL IS UNCONFIRMED, and there is now MEASURED reason to think no dedicated remove
call is coming. dumps/reflection/02_reflection.txt enumerated the four classes an item
removal could plausibly live on and none of them declares one:
* PalPlayerInventoryData (69 functions) — has AddItem_ServerInternal, CountItemNum,
IsExistItem, RequestAddItem_ForDebug. It has no RemoveItem, RemoveItem_ServerInternal,
SubItem, ConsumeItem, DecreaseItem, DeleteItem, DiscardItem, DropItem, TakeItem,
LostItem or UseItem. Its only Remove is TryRemoveEquipment, which unequips a slot.
* PalItemContainer (13 functions) — Get, Num, GetItemStackCount[64], GetLastNotEmptyIndex,
GetPermission, filter/OnRep members. Nothing that subtracts.
* PalItemSlot (23 functions) — GetItemId, GetStackCount, IsEmpty, RequestUseToCharacter.
Nothing that subtracts; StackCount is a PROPERTY, which is the save-corrupting hand-write
deprecated.container._extractImpl is gated off for.
* PalItemUseProcessor (2 functions) — CanUseItemToCharacter, UseItemToCharacter_ServerInternal.
One caveat keeps this from being absolute: UE4SS ForEachFunction lists a class's OWN
functions only (proven in the same dump — PalPlayerCharacter and PalCharacter share zero
entries, and no engine APlayerController function appears under PalPlayerController), so a
base class of these four could still carry one. The four most likely homes are ruled out,
including the very class that declares the ADD.

The only consumption path ever OBSERVED is UseItemToCharacter_ServerInternal: 06_events.txt
caught it firing with `{Id=Berries}` when the player ate one. That is the game invoking its
own use processor, not an inventory API a pack can call for an arbitrary id.

So this still pushes a NEGATIVE delta through the add call, on the untested hypothesis that
the game accepts it. Because that is a hypothesis, the outcome is MEASURED instead of
assumed: CountItemNum is read before and after and the return value is whether the count
really fell. false here means "nothing was observed to leave the inventory" — the negative
delta did nothing, there was nothing to take, or the count could not be read at all (all
logged, distinctly). A caller is never told a removal happened that was not seen.

Two guards keep the unproven write as small as it can be: when the count IS readable the
delta is clamped to what the inventory actually holds (never ask for an underflow), and
when it holds none the write is skipped entirely (nothing to remove, so an untested
negative delta buys nothing).
TODO(item-remove-call): unknown whether AddItem_ServerInternal honours a negative Count.
The other half of this item is answered: no remove/consume UFunction is declared on
PalPlayerInventoryData, PalItemContainer, PalItemSlot or PalItemUseProcessor, so there is
no better call to switch to on those classes and a probe should stop hunting for one there.
Only an observed before/after delta around this write can settle what is left — 02_reflection
lists names, never signatures or behaviour, so no dump can answer it.
```

**What the probe prints**

In a loaded throwaway world: (1) local inv = StaticFindObject('/Script/Pal.Default__PalUtility')
:GetPlayerStateByPlayer(FindFirstOf('PalPlayerCharacter')):GetInventoryData(); print
inv:GetClass():GetFullName(). (2) Enumerate that UClass's functions (ForEachFunction, or
GetFunctionByName over each of: RemoveItem, RemoveItem_ServerInternal, SubItem, ConsumeItem,
DecreaseItem, DeleteItem, DiscardItem, DropItem, TakeItem, LostItem, UseItem) and for every one
that resolves, walk its Children printing each property's name, class name and offset. (3) print
inv:CountItemNum(FName('Wood')), then call inv:AddItem_ServerInternal(FName('Wood'), -1, false,
0.0), then print CountItemNum again — both numbers on ONE log line so the delta is unambiguous.
Repeat step 3 with -3. Log everything with a distinct prefix.

### Skill and Effect

#### `effect-native-status` — Effect.Spec.nativeStatus (and the native half of Effect.Handle:apply / :remove)

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/effect.lua:20

**What a pack author sees**

A pack sets nativeStatus = "Burn"; the field is validated and stored on the definition and then
read by nothing. :apply starts a real, correctly-timed application and fires the pack's
handlers, but no game ailment is toggled and no status icon appears. native/effects.lua's
curated Poison / Burn / Freeze are empty handler bodies for the same reason.

**What is still unknown**

```text
palforge/api/effect.lua — PUBLIC effect API + implementation (SELF-CONTAINED).

An effect is a status applied to a character (a player or a Pal): buffs, debuffs,
damage-over-time, shields. Same shape as every other api module (call it to define,
plus get / get_all + a Handle object with actions and grouped `events`).

HOW IT INTEGRATES: Effect{ ... } registers the definition class in object_manager under
("effect", id). The TIMING — duration, periodic interval, stacking, expiry — is owned
HERE, driven off core/event's "tick" channel (the shared ~500 ms heartbeat). That makes
this a REAL runtime, not a seam: :apply(target) starts a live application and the
handlers fire on schedule until it expires or is removed. The runtime also listens on
"world.left" and releases everything it is holding when the world unloads, so no
application survives a world reload (reason "world_left"); it is not persisted, so
nothing is re-applied on the next world.

What is NOT wired: the game's own ailments (EPalStatusEffectType — Poison / Burn /
Freeze) are a native enum, and no native call to apply one has been found on any class
yet reflected, so a PalForge effect does not toggle the game's status icon.
`nativeStatus` is therefore an ANNOTATION today: it is validated, stored on the
definition and readable off it, and nothing acts on it — see TODO(effect-native-status)
in Handle:apply for where the search now stands. The gameplay lives in YOUR handlers —
onTick is where you deal the damage / heal / buff through whatever call you have (e.g.
utils.items, an actor method).

local Regen = Effect{
id = "example:Regen", name = "Regeneration",
duration = 10.0,   -- seconds; nil = until :remove()
interval = 1.0,    -- seconds between onTick calls
events = {
onApply  = function(effect, target, ctx) end,
onTick   = function(effect, target, ctx) --[[ heal target; ctx.elapsed ]] end,
onExpire = function(effect, target, ctx) end,
},
}
Regen:apply(Player.character())
```

**What the probe prints**

In a loaded world. STEP 1 (do these classes exist?): for n in {"PalStatusEffectComponent","PalBa
dStatusComponent","PalCharacterParameterComponent","PalIndividualCharacterParameter","PalCharact
er","PalPlayerCharacter","PalStatusUtility","PalDamageUtility"} do `local c =
StaticFindObject("/Script/Pal."..n); print(n, c ~= nil)` — the existence answers alone are load-
bearing. STEP 2 (enumerate): for each existing c, walk `while c do c:ForEachFunction(function(f)
print("FN", f:GetFName():ToString()) end); c:ForEachProperty(function(p) print("PROP",
p:GetFName():ToString(), p:GetClass():GetFName():ToString()) end); c = c:GetSuperStruct() end`.
Also do this from a live instance: `local pc = FindFirstOf("PalPlayerCharacter");
print(pc:GetClass():GetFName():ToString())` then the same walk on pc:GetClass(). Log everything
containing Status / BadStatus / Ailment / Effect / Add / Remove / Apply / Set. STEP 3
(signatures): for every shortlisted UFunction f, `f:ForEachProperty(function(p) print(" PARAM",
p:GetFName():ToString(), p:GetClass():GetFName():ToString(), p:GetOffset_Internal()) end)` — a
ByteProperty/EnumProperty here means the enum form, a NameProperty means the FName form. STEP 4
(get the enum values): arm the shortlisted add/remove functions with the count-capped
RegisterHook pattern from dump/auto_mod/main.lua:41-53, logging self class and every parameter
as `p:get()` normalised through `v.ToString and v:ToString() or tostring(v)`. Then in game
deliberately catch each ailment: stand in fire (Burn), take a poison attack (Poison), stand in a
snow biome / take an ice attack (Freeze), get wet, get electrified. PASTE BACK: which class
existed, which function fired for each ailment, and the exact parameter value printed for each —
those printed values ARE the nativeStatus values the field must hold.

#### `skill-activate-source` — Skill.Spec.Events.onActivate

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/skill.lua:58

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
- **Marked at:** Scripts/palforge/api/skill.lua:71

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
- **Marked at:** Scripts/palforge/api/skill.lua:26

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
- **Marked at:** Scripts/palforge/api/skill.lua:87

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

#### `audio-volume-rtpc` — Audio.Handle:setVolume

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/audio.lua:277

**What a pack author sees**

Returns false for every value, including 0.0 and 1.0, and nothing changes. There is no way to
make one sound quieter than another; a pack can only pick a quieter event.

**What is still unknown**

```text
TODO(audio-volume-rtpc): existence is settled — UPalSoundUtility::SetRTPCValueByActor and
::SetRTPCValueByActorByEnum are reflected in this build, and the route is per-actor. Still
unknown, and all a probe needs now: their parameter lists (is the RTPC an FName or an
FString, is there an InterpolationTimeMs), which RTPC controls volume, and the entries of
the enum the ByEnum overload takes — enumerating that UEnum is the cheapest way to get a
real RTPC name, since no dump in the tree carries one.
```

**What the probe prints**

In a fully loaded save, print all four blocks and paste the whole log — an empty result is
itself a useful answer: (1) existence: for each of '/Script/Pal.Default__PalSoundUtility',
'/Script/AkAudio.Default__AkGameplayStatics', '/Script/AkAudio.Default__AkComponent',
'/Script/AkAudio.Default__AkAudioEvent' do local o = StaticFindObject(path); print(path, o, o
and o:GetFullName()). (2) for every one that resolved, log its COMPLETE function list
unfiltered: o:GetClass():ForEachFunction(function(fn) print('FN', o:GetFullName(),
fn:GetFName():ToString()) end). (3) for any function whose name contains RTPC, Volume, Bus,
Gain, Fade, Mute or Set, walk its parameters in order: fn:ForEachProperty(function(p) print('
PARM', p:GetFName():ToString(), p:GetClass():GetFName():ToString(), p:GetOffset_Internal(),
p:GetSize()) end). (4) the RTPC names themselves — this is the part nothing in the repo can
supply: print(#(FindAllOf('AkRtpc') or {})) and then for each, print its GetFName():ToString()
and GetFullName(); do the same for FindAllOf('AkAuxBus') and FindAllOf('AkAudioBank'). Also
print how many AkComponent instances exist and one's full name plus its Outer: local cs =
FindAllOf('AkComponent'); print('#AkComponent', cs and #cs); if cs and cs[1] then
print(cs[1]:GetFullName(), cs[1]:GetOuter() and cs[1]:GetOuter():GetFullName()) end.

### Mesh

#### `mesh-base-material` — Mesh.Spec.color / texture / material on kind="procedural" and kind="obj"; Mesh.Handle:setColor on a procedural mesh

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/mesh/base/renderer.lua:89

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

#### `mesh-detach-destroycomponent` — Mesh.Handle:detach on kind="procedural" / "obj" / "static" (and core.mesh.detach)

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/mesh/static.lua:72

**What a pack author sees**

detach returns true and PalForge forgets the actor, but the mesh is still on screen. A later
attachTo then stacks a SECOND component on the same actor, because the once-guard was cleared by
the detach that did not actually remove anything.

**What is still unknown**

```text
Destroy a component we added. K2_DestroyComponent is the BlueprintCallable
counterpart of the proven AddComponentByClass, but has no in-game record of its own,
so the pcall status (i.e. "the component carried the function and it ran") is the
strongest thing we can honestly report.
TODO(mesh-detach-destroycomponent): K2_DestroyComponent's reflected argument list is
undumped — we pass the component as the Object argument, which is what the Blueprint
node does, but a mismatch would make BOTH this and procedural:detach silent no-ops that
still report true. Same call site in core/mesh/procedural.lua : Procedural:detach.
```

**What the probe prints**

On the player pawn: `local before = #(FindAllOf('ProceduralMeshComponent') or {});
print('before', before)`. `local cls =
StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'); local comp =
pawn:AddComponentByClass(cls, false, {}, false); print('after add',
#(FindAllOf('ProceduralMeshComponent') or {}))`. Enumerate the function:
`comp:GetClass():ForEachFunction(function(f) if f:GetFullName():find('DestroyComponent') then
print('FN '..f:GetFullName()); f:ForEachProperty(function(pr) print(' PARAM
'..pr:GetFName():ToString()..' '..pr:GetClass():GetFName():ToString()..'
@'..tostring(pr:GetOffset_Internal())) end) end end)`. Then try both call shapes on two separate
freshly-added components, printing for each the pcall status, `comp:IsValid()` afterwards, and
the FindAllOf count: (a) `comp:K2_DestroyComponent(comp)`, (b) `comp:K2_DestroyComponent()`.
Report which one drops the count back to `before`.

#### `mesh-material-params` — Mesh.Spec.color / texture / params on every kind, Mesh.Handle:setColor, Building.Instance:update(), Building.Handle:update(), Pal.Class:material()

- **Probe:** F6
- **Marked at:** Scripts/palforge/api/building.lua:45

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

#### `mesh-skeletal-animclass` — Mesh.Spec.animClass (skeletal only) — reached from Mesh.Handle:attachTo and Pal.Handle:renderOn

- **Probe:** F6
- **Marked at:** Scripts/palforge/core/mesh/skeletal.lua:177

**What a pack author sees**

The pal's model swaps but stands frozen in a T-pose, or vanishes because an undriven skinned
mesh culls to nothing. The log line is "skeletal: SetAnimClass is not on this component -
animClass dropped", or nothing at all when SetAnimationMode silently took the wrong enum value.

**What is still unknown**

```text
TODO(mesh-skeletal-animclass): SetAnimClass / SetAnimationMode are
written as UE5 names them, but nothing dumps them on a Pal component and
the enum value 0 for AnimationBlueprint is likewise assumed — if either
is wrong the swapped mesh stands still or culls to nothing.
```

**What the probe prints**

Reuse the component from the mesh-skeletal-setter probe. From its class listing, print the full
names of the `SetAnimClass` and `SetAnimationMode` UFunctions and each of their params via
`f:ForEachProperty(function(pr) print(' PARAM '..pr:GetFName():ToString()..'
'..pr:GetClass():GetFName():ToString()..' @'..tostring(pr:GetOffset_Internal())) end)`. Then
resolve a real ABP class: `local abp = StaticFindObject('/Game/Pal/Blueprint/Character/Monster/P
alActorBP/ChickenPal/ABP_ChickenPal.ABP_ChickenPal_C') or LoadAsset('/Game/Pal/Blueprint/Charact
er/Monster/PalActorBP/ChickenPal/ABP_ChickenPal.ABP_ChickenPal_C'); print('abp', tostring(abp),
abp and abp:GetFullName(), abp and abp:GetClass():GetFName():ToString())`. Call `print('mode
ok', pcall(function() mc:SetAnimationMode(0) end))` and `print('animclass ok', pcall(function()
mc:SetAnimClass(abp) end))`, then print `tostring(mc.AnimClass)` and `pcall(function() return
mc:GetAnimInstance() end)` with :GetFullName() on any valid result. Also dump the enum if
reachable: `local e = StaticFindObject('/Script/Engine.EAnimationMode')` and print its names and
values.

#### `mesh-skeletal-setter` — Mesh.Handle:attachTo / Mesh.Handle:detach on kind="skeletal" (the DEFAULT kind), and Pal.Handle:renderOn

- **Probe:** F6
- **Marked at:** Scripts/palforge/core/mesh/skeletal.lua:94

**What a pack author sees**

A pack author writes Mesh{ id="x", model="/Game/.../SK_ChickenPal.SK_ChickenPal" } — kind
defaults to skeletal — and calls :attachTo(ctx.actor). It returns false and UE4SS.log shows
either "skeletal: actor carries no readable mesh component (.Mesh / :GetMesh())" or "skeletal:
component carries neither SetSkinnedAssetAndUpdate nor SetSkeletalMeshAsset". No pal ever
changes shape. If it returns true instead, nobody has ever confirmed the pal visibly changed.

**What is still unknown**

```text
Run the mesh setters in order, returning the name of the one that executed, or nil.
SetSkinnedAssetAndUpdate(mesh, reinit) recreates the render state + re-inits the pose,
so a cross-skeleton swap renders; plain SetSkeletalMeshAsset can leave the new mesh
INVISIBLE. Fall back only if the first is absent.
TODO(mesh-skeletal-setter): neither the pawn's mesh-component property nor these setter
names are dumped anywhere — a probe must confirm which of them a live pal actually
carries before a true here can be read as "the pal changed shape".
```

**What the probe prints**

With a pal in the world: `local p = FindFirstOf('PalCharacter')` (or FindAllOf and pick a valid
one); print `p:GetFullName()`. Then `local mc; pcall(function() mc = p.Mesh end); print('Mesh
prop ->', tostring(mc))` and `pcall(function() mc = p:GetMesh() end); print('GetMesh() ->',
tostring(mc))`. For whichever is valid print `mc:GetClass():GetFullName()`. Then enumerate the
component class: `mc:GetClass():ForEachFunction(function(f) print('FN '..f:GetFullName()) end)`
and `mc:GetClass():ForEachProperty(function(pr) print('PROP '..pr:GetFName():ToString()..'
'..pr:GetClass():GetFName():ToString()..' @'..tostring(pr:GetOffset_Internal())) end)`. Grep
that output for SetSkinnedAssetAndUpdate, SetSkeletalMeshAsset, SetDisableChangeMesh,
GetSkinnedAsset, GetSkeletalMeshAsset, SkinnedAsset, SkeletalMesh, RelativeScale3D,
RelativeLocation. For each mesh setter found, walk its own params:
`f:ForEachProperty(function(pr) print(' PARAM '..pr:GetFName():ToString()..'
'..pr:GetClass():GetFName():ToString()..' @'..tostring(pr:GetOffset_Internal())) end)`. Finally
print the CURRENT asset four ways, each in a pcall, printing ok and (when valid) :GetFullName():
mc:GetSkinnedAsset(), mc:GetSkeletalMeshAsset(), mc.SkinnedAsset, mc.SkeletalMesh.

#### `mesh-static-setstaticmesh` — Mesh.Handle:attachTo on kind="static", Building.Instance:render(), Building.Handle:render()

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/mesh/static.lua:109

**What a pack author sees**

Placing the shipped WorkBench or PalBoxV2 attaches nothing. UE4SS.log shows "static: attach
failed: SetStaticMesh did not take", render() returns false, and because the component is
destroyed again there is nothing half-attached to see.

**What is still unknown**

```text
TODO(mesh-static-setstaticmesh): SetStaticMesh's reflected signature is undumped
and so are both read-back paths in meshOn(); if none of the three names exist,
every static building attach is an honest-but-permanent false.
```

**What the probe prints**

In-world: `local cls = StaticFindObject('/Script/Engine.StaticMeshComponent'); print('cls',
tostring(cls))`. Enumerate it: `cls:ForEachFunction(function(f) print('FN '..f:GetFullName())
end)`; find SetStaticMesh and GetStaticMesh and for each print their params with
`f:ForEachProperty(function(pr) print(' PARAM '..pr:GetFName():ToString()..'
'..pr:GetClass():GetFName():ToString()..' @'..tostring(pr:GetOffset_Internal())) end)`. Also
`cls:ForEachProperty(...)` and grep for a property literally named StaticMesh. Then do a LIVE
round trip on the player pawn: `local comp = pawn:AddComponentByClass(cls, false, {}, false)`;
`local asset = StaticFindObject('/Game/Pal/Model/Prop/Architecture/WorkBenchPrimitive/SM_WorkBen
chPrimitive.SM_WorkBenchPrimitive') or LoadAsset(...)`; print `tostring(asset)`; then
`print('set ok', pcall(function() comp:SetStaticMesh(asset) end))`; then print all of
`pcall(function() return comp:GetStaticMesh() end)` and `pcall(function() return comp.StaticMesh
end)` with :GetFullName() on any valid result, plus `pcall(function() return
comp:GetNumMaterials() end)`.

#### `mesh-texture-import` — Mesh.Spec.texture and Mesh.Spec.params.texture on every kind

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/mesh/base/renderer.lua:162

**What a pack author sees**

Declaring texture = "C:/mods/example/body.png" logs "tex-fail(no KismetRenderingLibrary)" or
"tex-fail(ImportFileAsTexture2D failed: ...)" and the mesh keeps its original surface. The
attach still returns true, because the material layer is deliberately best-effort.

**What is still unknown**

```text
Import a PNG off disk as a UTexture2D. Returns tex, or nil + reason.
TODO(mesh-texture-import): ImportFileAsTexture2D is listed as BlueprintCallable in the
V5 POC notes but has never been CALLED in either tree — its argument list (whether the
world-context object may be an actor, and whether the path is FString) is unconfirmed.
```

**What the probe prints**

In-world: `local krl = StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary');
print('krl', tostring(krl), krl and krl:GetFullName())`. Enumerate:
`krl:GetClass():ForEachFunction(function(f) print('FN '..f:GetFullName()) end)`; find
ImportFileAsTexture2D and print each param with `f:ForEachProperty(function(pr) print(' PARAM
'..pr:GetFName():ToString()..' '..pr:GetClass():GetFName():ToString()..'
@'..tostring(pr:GetOffset_Internal())) end)`. Then put a real PNG on disk and call it three
ways, printing the pcall status, tostring(result) and result:GetFullName() when valid: with the
player pawn as world context, with FindFirstOf('World'), and with krl itself. Report which
context argument (if any) returns a valid UTexture2D.

### UI

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

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/icons.lua:311

**What a pack author sees**

iconOf() always returns the declared `icon` (nil unless the author set one). The table is now
genuinely found, but no row is ever read, so Item.get("Wood"):iconOf() is nil even though the
row exists.

**What is still unknown**

```text
Fetch the row struct for `id`, across the row-access APIs a UDataTable may expose. NEITHER
of these has been observed to work on this build — reading a row value from Lua is a
capability nobody in this tree has demonstrated — so a nil here means "the unproven route
did not fire", not "there is no such row".

Be pessimistic about both, and about anything shaped like them. In UE, GetDataTableRowFromName
is not a member of UDataTable at all: it is a static on UDataTableFunctionLibrary declared
CustomThunk with a wildcard output struct, and the wildcard's real type comes from Blueprint
bytecode — a reflected call can only offer the declared FTableRowBase, which the thunk
rejects as incompatible with the table's row type. FindRow is a C++ template and is not
reflected at all. The library's SIBLING function is the shape that does work here
(dtfl:GetDataTableRowNames(dt) — dump/dump.lua:64, tests/catalog.lua:105-119, and
utils/items/init.lua's rowNamesInto), and it returns row NAMES, not values. So the missing
capability is probably not a call spelling but a whole accessor; whatever probe closes this
has to go LOOKING for one rather than assume one, which is why no third guess is bolted on
here.

The 2026-07 reflection dumps do not touch this. They re-confirm both halves that already
worked — 01_datatables.txt read `dt.RowStruct` and a row-NAME accessor for all 391 loaded
tables, 0 of them reporting "<no row-name accessor>" — and they add nothing about values,
because 02_reflection.txt covers 21 /Script/Pal.* classes ONLY: no /Script/Engine.UDataTable
and no UDataTableFunctionLibrary appear anywhere in the tree. This stays a /Script/Engine
question and cannot be answered from those files.
TODO(icons-row-read): unknown whether ANY reflected row-VALUE accessor exists on this build
(on UDataTable, on UDataTableFunctionLibrary, or as a Pal-specific icon getter). This is now
the ONLY missing step: the table is found, its package path is measured, and the column to
index once a row is in hand is measured too (ICON_COLUMNS_BY_TABLE).
```

**What the probe prints**

In a loaded world, print three lists. (1) local dt = FindObject("DataTable",
"DT_ItemIconDataTable"); print(dt:GetFullName()); dt:GetClass():ForEachFunction(function(fn)
print("UDataTable." .. fn:GetFName():ToString()) end). (2) local lib =
StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary");
lib:GetClass():ForEachFunction(function(fn) print("DTFL." .. fn:GetFName():ToString()) end). (3)
local u = StaticFindObject("/Script/Pal.Default__PalUtility");
u:GetClass():ForEachFunction(function(fn) local n = fn:GetFName():ToString(); if n:find("Icon")
or n:find("Row") or n:find("Texture") then print("PalUtility." .. n) end end). Paste all three
lists verbatim.

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

