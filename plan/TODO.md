# PalForge — what does not work yet

Every entry here is a public thing a pack author can call that does not do what it says.
They are not bugs in the sense of a wrong line of code: each one is blocked on a fact about
Palworld that nobody has measured yet — a function's real parameter list, a property's real
name, whether a class exists in the shipping build at all.

Each item names that ONE missing fact and the probe that settles it. The probes are code, not
instructions: they live in `Scripts/palforge/test/probes/` and run from a key in game.

## How to close an item

1. Load a save and press the key in the item's **Probe** column.
2. Copy everything the probe wrote to `UE4SS.log` (it brackets its output with `#### BEGIN`
   and `#### END` markers).
3. Paste it back. The missing fact is then known, the implementation follows from it, and the
   `-- TODO(<id>)` marker in the code comes out.
4. Press **F1** to re-run the API suite and confirm nothing regressed.

## Probe keys

| Key | What it does | What you need on screen |
| --- | --- | --- |
| F1 | The API test suite — 294 checks, the regression net | Anything. World-gated checks skip |
| F5 | Reflection dump: classes, functions, parameters, DataTable rows | A loaded save |
| F6 | Everything that needs a live pal: mesh components, materials | A pal standing near you |
| F7 | Arms hooks and watches for 60 s while YOU act | A loaded save, then craft / drop / spawn |
| F8 | Title-screen widgets | The title screen |

Nothing here writes to your save. F7 asks you to perform normal actions; everything else only
reads.

## Open items (35)

### Pal

#### `pal-icon-row` — Pal.Handle:iconOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/pal.lua:201

**What a pack author sees**

Always returns the icon the author declared, and nil when none was declared — for a vanilla id
like "ChickenPal" the live lookup contributes nothing, even though the row exists.

**The one thing nobody has measured**

Two facts, both settled by the same probe: which row accessor a UDataTable exposes to UE4SS Lua
on this build (GetDataTableRowFromName / FindRow / neither), and what the icon column on
DT_PalCharacterIconDataTable's RowStruct is really called — the on-disk catalog captured row
NAMES only, never columns, so core/icons' ICON_COLUMNS list is a guess.

**What the probe prints**

FindAllOf("DataTable"); pick the one whose o:GetFName():ToString() ==
"DT_PalCharacterIconDataTable". (a) Print its columns exactly as the dumper does:
dt.RowStruct:ForEachProperty(function(p) print(p:GetFName():ToString()) end). (b) Then call
dt:GetDataTableRowFromName(FName("ChickenPal")) and dt:FindRow(FName("ChickenPal"), "probe",
false), printing type() and tostring() of each result and the pcall error message when one
raises. "ChickenPal" is a confirmed row of that table (674 rows on disk).

**Once it is known**

A real iconOf for pals — and, through the shared core/icons.resolve, for item, skill and
building at the same time.

#### `pal-skills-equip` — Pal.Spec.skills / Pal.Handle:skillsOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/pal.lua:181

**What a pack author sees**

skills = { "FlameThrower" } is validated, stored and read back by :skillsOf(), but the spawned
creature never gains the skill — the field is author metadata only.

**The one thing nobody has measured**

Whether ANY native call attaches a waza / active / passive skill to a live pal, and its
signature. No such function is named in the reflection dumps, the POCs, the deprecated Lua or
the C++ bridge, so even the candidate name is missing.

**What the probe prints**

Use the dumper's own reflection pattern (dump/dump.lua:104). For each of
"/Script/Pal.PalCharacter", "/Script/Pal.PalCharacterParameterComponent",
"/Script/Pal.PalIndividualCharacterParameter", "/Script/Pal.PalMonsterParameterComponent": local
cls = StaticFindObject(path); cls:ForEachFunction(function(fn) print(fn:GetFName():ToString())
end); cls:ForEachProperty(function(p) print(p:GetFName():ToString()) end). Paste every name
containing Waza, Skill, Passive, Learn, Equip or Add. Then repeat ForEachFunction on a live pal:
actor:GetClass() for the first entry of FindAllOf("PalCharacter").

**Once it is known**

Making Pal.Spec.skills real (equip the declared list onto a spawned pal), and any pal-driven
skill use.

#### `pal-spawn-placement` — Pal.Handle:spawn(coord) / core.spawn.palAt

- **Probe:** F7
- **Marked at:** Scripts/palforge/core/spawn.lua:246

**What a pack author sees**

:spawn(coord) returns true, but nobody has ever seen a pal actually arrive at the coordinate —
the game drops it beside the player and PalForge's relocation runs on a retry chain long after
the call returned, reporting only to the log.

**The one thing nobody has measured**

Whether the deferred pass finds the freshly spawned actor at all, and which of the three
relocate calls (K2_TeleportTo, K2_SetActorLocation, SetActorLocation) actually moves a
PalCharacter on this build. No run of this pass is recorded anywhere in either tree.

**What the probe prints**

In a loaded world, spawn at a distinctive point —
Pal.get("ChickenPal"):spawn(require("palforge.core.player").coordinateOffset(600, 0, 50)) — or
just press F1 (the pal suite's live coordinate test does exactly this). Then paste every
[PalForge.spawn] line from UE4SS.log for the following 5 s: the "accepted; relocation to (x,y,z)
scheduled" line, followed by ONE of "placed new pal at (x,y,z); it reads back (...), off by N" /
"found the new pal but every relocate call failed" / "no new pal actor appeared to place". An
"off by" under ~100 means the coordinate route works.

**Once it is known**

Whether :spawn(coord) may be documented as placing a creature, or must switch strategy (the C++
SpawnPalAt bridge is the only alternative and last produced a static, invincible pal).

#### `pal-spawned-hook` — Pal.Spec.Events.onSpawned

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/pal.lua:128

**What a pack author sees**

A declared onSpawned handler may simply never run. Capture, damage and death are confirmed
firing in-game; the spawn hook has never been observed to fire once, so a pack that renders a
mesh from onSpawned can see nothing happen at all.

**The one thing nobody has measured**

Whether /Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter fires when a pal spawns
AFTER the world has finished loading — and if it does, whether it signals a FRESH spawn or also
a re-init of pals that already exist. The single recorded probe armed it at mod load and counted
0 calls.

**What the probe prints**

In a fully loaded world,
RegisterHook("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter", function(self)
print(os.clock(), self:get():GetClass():GetFullName()) end). Then log the count for three steps
in order: (1) stand idle 30 s (expect 0 lines); (2) run Pal.get("ChickenPal"):spawn() and print
every line for the next 10 s; (3) release one pal from the box. Paste the per-step line counts
and the BP class names printed.

**Once it is known**

Whether onSpawned can be documented as confirmed-LIVE, or must be re-sourced from another hook
(untried candidates: PalMonsterSpawner*:Spawn*, PalCharacter:BeginPlay, SpawnMonsterForPlayer).

#### `spawn-actor-conventions` — core.spawn.actor

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/spawn.lua:46

**What a pack author sees**

Public through _G.PalForge.core.spawn.actor and has never spawned anything for anyone: it tries
four argument conventions, logs that all of them failed, and returns nil.

**The one thing nobody has measured**

The exact parameter list UE4SS sees for UGameplayStatics::BeginDeferredActorSpawnFromClass and
for FinishSpawningActor on this build — how many arguments each declares, in what order, and
whether the trailing scale-method enum exists (it is 5.3+ in stock UE).

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

**Once it is known**

Spawning an arbitrary actor at an exact location from Lua — the only route to a genuinely
location-controlled spawn, and the prerequisite for placing props/buildings from a pack.

### Item

#### `item-craft-source` — Item.Spec.Events.onCraft (channel item.craft)

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/item.lua:89 | Scripts/palforge/core/event.lua:1077

**What a pack author sees**

A declared onCraft handler never runs. Crafting at a workbench fires nothing on this channel;
the produced item surfaces as onObtain via the get-log instead, which cannot be told apart from
a pickup. Only a manual event.emit('item.craft', ...) reaches the handler. | The channel exists
and DISPATCH is wired, but no source ever emits it: an onCraft handler is registered, validated,
and then never runs for any item, with no warning.

**The one thing nobody has measured**

Which UFunction fires when a craft / production COMPLETES, and which of its parameters carries
the produced item id and count. The only lead anywhere in the tree is a class NAME with no
function list: UPalMapObjectProductItemModel (deprecated/catalog/mapobject_models.txt:58). |
Which UFunction the game calls when a production/work building finishes an item, and which of
its params carries the produced item FName and the count. No candidate name exists anywhere in
the tree (dump/dump_targets.md:149 lists it as 'dump to discover'; the probe harness never armed
one).

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

**Once it is known**

onCraft, and any pack that needs to react to production rather than to pickup (bonus output, XP
on craft, craft-gated unlocks). | emitting item.craft { itemId, count } from installItemSource,
which makes Item onCraft live for every definition (the DISPATCH is already wired)

#### `item-datatable-row-read` — Item.Handle:iconOf / Item.Handle:recipeOf

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/item.lua:146

**What a pack author sees**

iconOf() hands back the icon the author declared (nil when none was declared) for every item,
vanilla ones included — the live table is never actually read. recipeOf() returns nil for every
vanilla item even though DT_ItemRecipeDataTable_Common has 1414 rows keyed by exactly the item
ids the API takes.

**The one thing nobody has measured**

Which row-VALUE accessor a live UDataTable exposes to UE4SS Lua on this build —
GetDataTableRowFromName, FindRow, or something else — and what it hands back (an indexable
struct userdata, or nothing). Only row NAMES have ever been extracted in this tree; no row value
has been read once.

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

**Once it is known**

Live icons for every domain (item/pal/skill/building all route through core.icons), and
recipeOf() reading the real recipe — the table, the row keys and the column names are all
already known, only the accessor is missing.

#### `item-discard-source` — Item.Spec.Events.onDiscard (channel item.discard)

- **Probe:** F7
- **Marked at:** Scripts/palforge/api/item.lua:94 | Scripts/palforge/core/event.lua:1079

**What a pack author sees**

A declared onDiscard handler never runs. Dropping a stack on the ground, destroying it from the
inventory menu, or consuming a potion all fire nothing on this channel. Only a manual
event.emit('item.discard', ...) reaches the handler. | Same as onCraft: declarable, dispatched,
and never emitted — dropping, trashing or consuming an item produces no event at all.

**The one thing nobody has measured**

Which UFunction fires when the player drops / discards / destroys an item — or whether there is
no dedicated one and it is simply AddItem_ServerInternal arriving with a NEGATIVE Count (the
same fact as item-remove-call, observed from the game's side instead of ours). | Whether a
player DROPPING or destroying an item routes through
/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal with a NEGATIVE Count (the standing
hypothesis in dump/docs/01_life_events.md §1.8, never observed), or through a separate
drop/discard UFunction — and that function's name.

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

**Once it is known**

onDiscard and the item.discard channel; the same observation is the cheapest confirmation of
whether a negative Count means anything to this build, which is what Item.Handle:take rests on.
| emitting item.discard { itemId, count } from installItemSource; the same fact also tells
utils.items.take whether its negative-delta call removes anything

#### `item-inventory-count-readback` — utils.items.count / Item.Handle:count (and the verification inside :give and :take)

- **Probe:** F5
- **Marked at:** Scripts/palforge/utils/items/init.lua:49

**What a pack author sees**

count() may answer nil for every call, and take() may log 'CountItemNum unreadable, removal
unconfirmed' and answer false forever. In that state give() also loses its verification and
falls back to 'the call was issued'. Nothing in the tree has ever recorded this accessor
actually returning a number — the one caller (deprecated/container.lua:320) wrapped it in its
own pcall and its log was never captured.

**The one thing nobody has measured**

Whether UPalPlayerInventoryData:CountItemNum(FName) is reflected to UE4SS Lua on this build, and
what it returns — a plain integer, or a struct/userdata that tonumber() turns into nil.

**What the probe prints**

Same inv as item-remove-call. Print, on separate lines: type(inv.CountItemNum); the result of
inv:CountItemNum(FName('Wood')) as both tostring(v) and type(v) and tonumber(v); then
inv:GetClass():GetFunctionByName('CountItemNum') and, if non-nil, walk its Children logging
every property's name, class name, offset and whether it is a return-param. Also try the sibling
names GetItemNum, GetItemCount, HasItem, GetItemStackCount the same way and print which ones
resolve.

**Once it is known**

Whether give() and take() can report measured truth at all. If CountItemNum is unbound, both
degrade to 'the call was issued' and a different read (walking the inventory container's slots)
has to replace it.

#### `item-remove-call` — Item.Handle:take

- **Probe:** F5
- **Marked at:** Scripts/palforge/utils/items/init.lua:170

**What a pack author sees**

take() issues AddItem_ServerInternal with a negative Count and then reports what it measured.
Nothing has ever been observed to leave an inventory on this build, so a pack charging a cost
most likely gets false back and has to reverse its own give(). The call is made, the removal is
a hypothesis.

**The one thing nobody has measured**

Whether UPalPlayerInventoryData (or the UPalItemContainer behind it) exposes ANY remove/consume
UFunction — its exact name and parameter list — and, if it does not, whether
AddItem_ServerInternal(FName StaticItemId, int Count, bool IsAssignPassive, float LogDelay)
honours a NEGATIVE Count.

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

**Once it is known**

A real Item.Handle:take, and with it every cost/consume mechanic a pack wants (recipes, tolls,
fuel). It is also the prime candidate for the item.discard source, so one probe settles two
TODOs.

### Building

#### `building-break` — Building.Instance:onBreak (Building{ events = { onBreak = ... } })

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/building.lua:216

**What a pack author sees**

Same as onLeftClick: declarable, installed on the class, never emitted. Destruction is only ever
observed indirectly, by the reconstruction scan's miss sweep (core/event.lua:469-476) firing
onRemove with ctx.reason = "missing" up to MISS_THRESHOLD scans late — so a pack cannot tell a
deliberate dismantle from a streamed-out structure, and cannot see who did it or get anything
back before the actor is gone.

**The one thing nobody has measured**

The name and parameter list of the UFunction the game runs when a structure is
dismantled/destroyed. Grepping every .lua/.md/.json/.txt/.cpp in /mnt/e/steam_hosts/pal/mods for
dismantl/deconstruct/RequestDestroy/DestroyBuild/BreakBuild/OnDestroyed/Demolish returns only
content ids (a "DismantlingConveyor" build id plus its three sound events) — no UFunction
candidate anywhere, and dump/dump_targets.md:141 explicitly assigns destruction to the scan miss
sweep instead.

**What the probe prints**

With a world loaded. (1) ForEachFunction over the four classes that plausibly own it, printing
EVERY name: `for _, p in ipairs({"/Script/Pal.PalBuildObject",
"/Script/Pal.PalNetworkPlayerComponent", "/Script/Pal.PalPlayerRecordData",
"/Script/Pal.PalMapObjectConcreteModelBase"}) do local c = StaticFindObject(p); print("==
"..p..(c and c:IsValid() and "" or " <NOT LOADED>")); if c and c:IsValid() then
c:ForEachFunction(function(f) print(" FN "..f:GetFName():ToString()) end) end end`.
PalNetworkPlayerComponent and PalPlayerRecordData are the two proven owners of the build
lifecycle (RequestBuild_ToServer and OnCompleteBuild_ServerInternal), so a destroy counterpart
is most likely to sit beside them. (2) For each hit on
Destroy/Dismantle/Deconstruct/Demolish/Remove/Break/Repair, dump the parameter list with
`f:ForEachProperty(function(pr) print(" PARAM "..pr:GetFName():ToString().." :
"..pr:GetClass():GetFName():ToString()) end)` — the key question is whether param 1 is the build
ACTOR, a UPalMapObjectModel (like OnCompleteBuild_ServerInternal), or an FName build id, since
that decides instance- vs class-dispatch. (3) In a THROWAWAY world (this class of hook has a
recorded native access violation during the world-load storm), RegisterHook the best candidate,
dismantle one Workbench, and paste the log.

**Once it is known**

onBreak gets a real source, and onRemove gets an honest reason: the destroy hook can emit
building.remove with reason = "dismantled" plus the player, immediately instead of up to
MISS_THRESHOLD scans late, while genuine streaming-out keeps reason = "missing". It is also the
missing half of the deferred-mesh/persistence story — the persisted record could be dropped at
the moment of dismantle rather than on a scan miss.

#### `building-leftclick` — Building.Instance:onLeftClick (Building{ events = { onLeftClick = ... } })

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/building.lua:213

**What a pack author sees**

Declaring events.onLeftClick validates, installs over the inert base hook, and shows up in
editor completion — and then never runs. There is no "building.leftclick" entry in
core/event.lua's M.CHANNELS (lines 56-64), no source emits one, and installDispatch (1147-1161)
has no subscription, so the only thing that can ever call the handler is the manual test
forwarder Handle:onLeftClick(ctx). A pack author sees a hook that silently does nothing forever.

**The one thing nobody has measured**

Whether /Script/Pal.PalBuildObject — or the BP_BuildObject_<Id>_C subclass a placed structure
actually is — carries ANY UFunction that runs when the player strikes or attacks a placed
structure, and if so its exact function NAME and parameter list. Exhaustive grep of both trees
found only /Script/CommonUI.CommonButtonBase:HandleButtonClicked (a UMG widget button, already
used elsewhere) and PalBuildObject:OnBeginInteractBuilding (already onRightClick).

**What the probe prints**

With a world loaded, in the UE4SS Lua console. (1) `local c =
StaticFindObject("/Script/Pal.PalBuildObject"); c:ForEachFunction(function(f) print("FN
"..f:GetFName():ToString()) end)` — print EVERY name, do not filter in the probe. (2) Same for
the concrete class of a real placed structure and its whole super chain: `local a =
FindAllOf("PalBuildObject")[1]; local k = a:GetClass(); while k and k:IsValid() do print("==
"..k:GetFullName()); k:ForEachFunction(function(f) print(" FN "..f:GetFName():ToString()) end);
k = k:GetSuperStruct() end`. (3) For every printed name containing
Damage/Hit/Attack/Take/Receive/Click/Press/Shot, dump its parameters:
`f:ForEachProperty(function(p) print(" PARAM "..p:GetFName():ToString().." :
"..p:GetClass():GetFName():ToString()) end)`. (4) In a throwaway world, RegisterHook each
candidate as "/Script/Pal.PalBuildObject:<Name>" (or the BP path), log a line on entry, then
melee a placed Workbench and paste which ones fired. Paste the whole function list even if
nothing fires — the absence is the finding.

**Once it is known**

onLeftClick becomes wireable: one channel name in core/event.lua M.CHANNELS, one tryHook in
installBuildingSource that emits it with ctx.actor/ctx.player, and one M.on(...) line in
installDispatch reusing the existing actor->instance resolve. Nothing in api/building has to
change — the hook, the schema entry, the base default and the handle forwarder are already in
place.

#### `spatial-saveid` — core.spatial.saveId() (public as PalForge.core.spatial.saveId; drives the building persistence file name via core/event.lua:161)

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/spatial.lua:196

**What a pack author sees**

It always returns the literal fallback "world", so every save file on the install shares ONE
persisted-building file, state/entities_world.json — which is exactly the artifact a real
session produced (PalSmith commit dc206a6). A structure's saved state from world A is therefore
visible to, and position-matchable in, world B. Nothing errors; the caller just never gets
isolation.

**The one thing nobody has measured**

Which property on the live PalGameInstance (or anywhere up its super chain) holds a per-SAVE
identifier — the exact property NAME and its type. The three currently probed names, WorldGuid /
WorldSaveName / SaveName, are guesses: nothing in the dumps, the POCs,
deprecated/catalog/classes.json or __knowledges/palworld-ue4ss-functions.md names a world or
save identifier on any class.

**What the probe prints**

With a world loaded. (1) Walk the whole class chain and print everything: `local gi =
FindFirstOf("PalGameInstance"); print("GI "..tostring(gi and gi:IsValid())); local k =
gi:GetClass(); while k and k:IsValid() do print("== "..k:GetFullName());
k:ForEachProperty(function(p) print(" PROP "..p:GetFName():ToString().." :
"..p:GetClass():GetFName():ToString()) end); k:ForEachFunction(function(f) print(" FN
"..f:GetFName():ToString()) end); k = k:GetSuperStruct() end`. (2) For every printed name
containing Save/World/Guid/Slot/Id/Name, READ it and print the value: `local v; if
pcall(function() v = gi[NAME] end) then local ok, s = pcall(function() return v.ToString and
v:ToString() or tostring(v) end); print("VAL "..NAME.." = "..tostring(ok and s)) end`. (3)
CRITICAL: run the whole thing in TWO DIFFERENT save files and paste both logs. A name only
settles this if its value DIFFERS between the two saves — a constant is as useless as the
current fallback.

**Once it is known**

Per-save persistence namespacing: saveId() can return a real w_<id> and each world gets its own
state/entities_<id>.json, so onLoad/onRemove stop reconstructing another save's structures and
Building.Instance.state stops leaking across worlds. Until it is known, the honest documentation
is one shared bucket per install.

### Skill and Effect

#### `effect-native-status` — Effect.Spec.nativeStatus (and the native half of Effect.Handle:apply / :remove)

- **Probe:** F5

**What a pack author sees**

A pack sets nativeStatus = "Burn"; the field is validated and stored on the definition and then
read by nothing. :apply starts a real, correctly-timed application and fires the pack's
handlers, but no game ailment is toggled and no status icon appears. native/effects.lua's
curated Poison / Burn / Freeze are empty handler bodies for the same reason.

**The one thing nobody has measured**

The native add-status and remove-status calls: owning class, function name, and the TYPE of the
status argument — an EPalStatusEffectType enum value or an FName — plus the member names of
EPalStatusEffectType itself, which was never captured in any reflection dump (confirmed: no row
named Burn/Poison/Freeze exists in any of the 390 checked-in DataTables; DT_StatusEffectFood
holds 54 food ids only; the C++ bridge cpp/PalForgeNative exposes only Ping and SpawnPalAt;
mods/__knowledges/palworld-ue4ss-functions.md records no status function).

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

**Once it is known**

Wiring nativeStatus for real: Effect.Handle:apply would toggle the game's own ailment (status
icon, native damage-over-time) and :remove / the expiry path would clear it, turning
native/effects.lua's Poison / Burn / Freeze from empty handler bodies into working ailments and
making PalForge effects visible to the rest of the game rather than only to the pack's own
handlers.

#### `skill-activate-source` — Skill.Spec.Events.onActivate

- **Probe:** F5

**What a pack author sees**

A pack that declares events.onActivate gets a handler that never runs by itself. Nothing in
PalForge emits a skill channel (core/event.lua M.CHANNELS is gameStart / world.* / building.* /
pal.* / item.* / tick) and no dispatch would resolve one to a definition, so the handler only
fires when the pack itself calls Handle:activate(owner).

**The one thing nobody has measured**

The owning class and exact name of the native UFunction that runs when a character executes an
active skill, and whether its parameter list carries the skill's row FName.
/Script/Pal.PalPlayerController:PlaySkill is ruled out: it was armed in two separate in-game
probes (v4 and v6, dump/auto_mod/main.lua HOOKS entry "SKILL.play") and fired 0 times.

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

**Once it is known**

A skill.activate channel in core/event.lua plus the dispatch that resolves it to the registered
definition — which turns every pack's declared onActivate from manual-only into a real game-
driven hook, and unblocks native/skills.lua's Fireball onActivate body.

#### `skill-hit-source` — Skill.Spec.Events.onHit

- **Probe:** F7

**What a pack author sees**

events.onHit never runs on its own; it only fires when the pack calls Handle:hit(target).
Nothing reports "skill X landed on Y".

**The one thing nobody has measured**

Whether the skill's identity is reachable from the one damage hook that IS confirmed to fire —
/Script/Pal.PalCharacter:OnDamageReaction, already wired as the pal.damaged channel in
core/event.lua — i.e. whether any of its parameters is a struct carrying a waza/skill FName, and
what that field is called. (The candidate that would name the skill directly,
/Script/Pal.PalPlayerController:SkillDamageReactionComponent_ProcessDamage_ToServer, was armed
as "SKILL.dmg" in dump/auto_mod/main.lua and fired 0 times.)

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

**Once it is known**

A skill.hit channel keyed by the skill id, so onHit becomes game-driven; also tells core/event
whether pal.damaged's existing ctx can simply be extended instead of adding a new source.

#### `skill-icon-key` — Skill.Handle:iconOf

- **Probe:** F5

**What a pack author sees**

Returns the declared `icon` (usually nil) for essentially every skill. It reaches the engine —
core/icons finds the live UDataTable for real via FindAllOf("DataTable") — but no icon has ever
been observed coming back, and a nil is indistinguishable from "no such row".

**The one thing nobody has measured**

Two facts, both needed, neither on disk (the checked-in catalog under
deprecated/catalog/datatables/ is {table,count,rows} only — row NAMES, no columns): (a) whether
a live UDataTable exposes a row-VALUE read to UE4SS Lua on this build at all, i.e. whether
dt:GetDataTableRowFromName(...) or dt:FindRow(...) returns anything, and whether the key must be
FName(id) or a plain string; (b) which column of DT_partnerSkillIconDataTable holds the texture
reference (core/icons currently guesses SoftIcon, IconName, IconTexture, Icon, Texture in that
order).

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

**Once it is known**

iconOf for the 303 pal-named partner skills (and, the same answer, iconOf for item / pal /
building, which all run through the identical core/icons chain). It also settles whether
Skill.get("<vanilla id>") could ever carry real element / power / cooldown read from
DT_PartnerSkillParameter, which today are always nil.

#### `skill-passive-source` — Skill.Spec.Events.onEquip / Skill.Spec.Events.onUnequip

- **Probe:** F5

**What a pack author sees**

Both handlers only run when the pack calls Handle:equip(owner) / Handle:unequip(owner). PalForge
keeps no equipped set and never tells the game anything, so declaring kind = "passive" plus
onEquip attaches nothing.

**The one thing nobody has measured**

Whether a native function for attaching/detaching a passive skill to a Pal exists at all, and if
so its owning class, its name and its argument type (passive row FName vs an index into a fixed-
size array). No candidate has ever been named — passive attach/detach appears in no HOOKS list
and in no dump target table.

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

**Once it is known**

A skill.equip / skill.unequip source, and the ability for Handle:equip to actually attach the
passive rather than just running the pack's handler.

### Audio

#### `audio-akevent-play-signature` — Audio.Handle:play (via core.sound.native NativeSource:play)

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/sound/native.lua:79

**What a pack author sees**

It returns true and a native call is issued, but no run in either tree has ever recorded a sound
actually being heard. A pack author gets true and possibly silence, with no way to tell which.
Because there is no PlayingID, Handle:stop is also forced to be actor-wide (StopSoundByActor
silences the pawn's footsteps and voice lines along with your BGM).

**The one thing nobody has measured**

Whether UPalSoundUtility actually has a UFunction named PlayAkEventSoundByActor, and if so its
exact reflected parameter list: how many parameters, in what order, each one's property class
(is the first an AActor* or a WorldContextObject; is the second a UAkAudioEvent* object or an
FName), and whether it has a return parm — specifically whether it hands back an int32 Wwise
PlayingID.

**What the probe prints**

In a fully loaded save (not the title screen), print all of this and paste the whole log: (1)
local u = StaticFindObject('/Script/Pal.Default__PalSoundUtility'); print('CDO', u, u and
u:GetFullName()) (2) log EVERY function on the class, unfiltered —
u:GetClass():ForEachFunction(function(fn) print('FN', fn:GetFName():ToString()) end). We need
the full list to know what actually exists (PlayAkEventSoundByActor, PlaySoundByActor,
StopSoundByActor, IsSoundPlayingByActor, and anything else). (3) for each of
PlayAkEventSoundByActor / PlaySoundByActor / StopSoundByActor, walk its parameters IN ORDER:
local fn = u:GetClass():FindFunctionByName? -- or capture it from the ForEachFunction loop --
then fn:ForEachProperty(function(p) print(' PARM', p:GetFName():ToString(),
p:GetClass():GetFName():ToString(), p:GetOffset_Internal(), p:GetSize()) end). Print the
property NAME, its property-class name (ObjectProperty / NameProperty / StructProperty /
IntProperty...), offset and size, and say which one is the return parm. (4) then actually call
it and report audibility: local ev =
LoadAsset('/Game/Pal/Sound/Events/SE/UI/Item/AKE_GrabItem.AKE_GrabItem'); if not ev then ev =
StaticFindObject('/Game/Pal/Sound/Events/SE/UI/Item/AKE_GrabItem.AKE_GrabItem') end;
print('asset', ev, ev and ev:GetFullName(), ev and ev:GetClass():GetFName():ToString()); local
pawn = FindFirstOf('PalPlayerCharacter'); local ok, r = pcall(function() return
u:PlayAkEventSoundByActor(pawn, ev) end); print('call ok=', ok, 'ret=', tostring(r)). Report
BOTH the printed return value AND whether a sound was audible.

**Once it is known**

A confirmed-audible play route for the entire Audio api (everything else in the domain rests on
this one call), the correct argument order if it is wrong today, and — if a PlayingID comes back
— a real per-sound Handle:stop instead of the actor-wide StopSoundByActor.

#### `audio-custom-file-loader` — Audio.Spec.soundFile (Audio{ soundFile = ... }:play, via core.sound.file FileSource:play)

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/sound/file.lua:19

**What a pack author sees**

soundFile is an accepted, validated, documented field that takes precedence over
soundId/soundPath — and then plays nothing. The definition lowers to { kind = 'file' },
core.sound resolves it to a FileSource, and :play() returns false. A pack that ships its own
.wav gets silence, and worse, setting soundFile alongside a working soundId silences that too
because the file route wins.

**The one thing nobody has measured**

Whether the shipping (non-editor) build exposes ANY runtime path from a file on disk to
something playable: does a USoundWave / USoundBase / USoundFactory / GameplayStatics-PlaySound2D
chain survive in shipping, or does the Wwise integration expose an external-source entry point
(UAkExternalMediaAsset, UAkMediaAsset, a PostEventWithExternalSources-style function)? Nobody
has established that even one of these classes exists in this build.

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

**Once it is known**

Custom pack-supplied audio files. If the answer is that no such path exists (which is the likely
outcome under Wwise), the follow-up is not an implementation but a decision: remove
Audio.Spec.soundFile and core/sound/file.lua rather than keep a live field that can only ever
return false, or demote it to a documented permanently-unsupported field and stop letting it
outrank soundPath.

#### `audio-volume-rtpc` — Audio.Handle:setVolume

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/audio.lua:268

**What a pack author sees**

Returns false for every value, including 0.0 and 1.0, and nothing changes. There is no way to
make one sound quieter than another; a pack can only pick a quieter event.

**The one thing nobody has measured**

Whether ANY volume entry point is reflected in this build at all — concretely: (a) does
UPalSoundUtility have a SetRTPCValueByActor function, (b) does a UAkGameplayStatics class exist
here (StaticFindObject on its CDO), (c) does the player pawn own a UAkComponent with
SetOutputBusVolume — and for whichever exists, its parameter list (is the RTPC named by FName or
FString, is there an InterpolationTimeMs parameter, is the actor a parameter or the callee) —
plus the NAME of an RTPC that controls volume. The only RTPC-ish names anyone has ever written
down for Palworld are Field_Time and Sliding_Speed, neither of which is a volume.

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

**Once it is known**

Audio.Handle:setVolume, and the final shape of it — whether it stays setVolume(volume), becomes
setVolume(volume, actor) because the route is per-actor, or moves to a bus/mixer-level call on
the module rather than the handle. Also unblocks any future fade-in/fade-out.

### Mesh

#### `mesh-base-material` — Mesh.Spec.color / texture / material on kind="procedural" and kind="obj"; Mesh.Handle:setColor on a procedural mesh

- **Probe:** F5

**What a pack author sees**

A procedural OBJ mesh attaches and is visible but always white. The log says "no-MID(no material
on the component and no base material loaded)", and every later :setColor on that actor returns
false forever, because there is no material instance to write to. This is the one behaviour with
an in-game record: PalLogistics extensions/pallogistics/init.lua:42 says "no-MID -> white".

**The one thing nobody has measured**

Whether ANY UMaterial carrying a colour vector parameter is loaded in a cooked shipping build,
to parent a procedural section's MID to. A fresh ProceduralMeshComponent section owns no
material, so CreateAndSetMaterialInstanceDynamic returns nil; the five /Engine/ candidates in
BASE_MATERIAL_CANDIDATES are editor assets that may not be cooked in, and StaticFindObject only
returns already-LOADED objects.

**What the probe prints**

In-world, first the cheap check: `require('palforge.core.mesh').probeMaterials()` and read the
five `MATPROBE FOUND` / `MATPROBE -----` lines it prints. Then enumerate what IS loaded: `local
n=0; for _, m in ipairs(FindAllOf('Material') or {}) do n=n+1; if n<=150 then print('MAT
'..m:GetFullName()) end end; print('total Material', n)` and repeat for
'MaterialInstanceConstant' and 'MaterialInterface'. For the first ~30 of them print whether a
VectorParameterValues array is present and, if so, each `entry.ParameterInfo.Name:ToString()`.
Report one loaded object path that carries a colour parameter — that path goes to the front of
Renderer.BASE_MATERIAL_CANDIDATES.

**Once it is known**

The entire material layer on the one mesh backend that IS proven to render. Without it,
procedural meshes can only ever be white and their setColor is structurally false.

#### `mesh-detach-destroycomponent` — Mesh.Handle:detach on kind="procedural" / "obj" / "static" (and core.mesh.detach)

- **Probe:** F5

**What a pack author sees**

detach returns true and PalForge forgets the actor, but the mesh is still on screen. A later
attachTo then stacks a SECOND component on the same actor, because the once-guard was cleared by
the detach that did not actually remove anything.

**The one thing nobody has measured**

Whether `K2_DestroyComponent` takes the component as its single Object argument (the shape the
Blueprint node uses, which is what we pass) or takes none, and whether it really removes a
component that was added by AddComponentByClass. It is the symmetric counterpart of the proven
AddComponentByClass but has no in-game record of its own.

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

**Once it is known**

Honest detach for the two component-adding backends, and therefore safe re-dressing of an actor.
Today detach can report true while the component is still attached.

#### `mesh-material-params` — Mesh.Spec.color / texture / params on every kind, Mesh.Handle:setColor, Building.Instance:update(), Building.Handle:update(), Pal.Class:material()

- **Probe:** F6

**What a pack author sees**

setColor returns true and the log says "material [color-set]", but the mesh does not change
colour. The call executed on a real dynamic material instance; the parameter name simply was not
one the material carries. Six candidate names are written per slot and all six may miss.

**The one thing nobody has measured**

The vector and texture parameter NAMES a real Palworld material exposes — e.g. what the tint
parameter on SM_PalBox's or SK_ChickenPal's material is actually called. Nothing in either tree
records a single material parameter name; dump/docs/05_mesh_material.md 5.1 is an empty FILL
block.

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

**Once it is known**

Any tint or texture ever being VISIBLE, on all four kinds. Every paint endpoint currently
reports honest success for a write that lands on a parameter nobody has.

#### `mesh-skeletal-animclass` — Mesh.Spec.animClass (skeletal only) — reached from Mesh.Handle:attachTo and Pal.Handle:renderOn

- **Probe:** F6

**What a pack author sees**

The pal's model swaps but stands frozen in a T-pose, or vanishes because an undriven skinned
mesh culls to nothing. The log line is "skeletal: SetAnimClass is not on this component -
animClass dropped", or nothing at all when SetAnimationMode silently took the wrong enum value.

**The one thing nobody has measured**

Whether a Pal's skeletal mesh component carries `SetAnimClass` (and whether its parameter is a
raw UClass* or a TSubclassOf that will not accept a StaticFindObject result), plus what integer
EAnimationMode::AnimationBlueprint really is — we assume 0.

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

**Once it is known**

Mesh.Spec.animClass doing anything, and therefore a swapped skeletal mesh being animated at all
— which is what makes the swap usable rather than a frozen prop.

#### `mesh-skeletal-setter` — Mesh.Handle:attachTo / Mesh.Handle:detach on kind="skeletal" (the DEFAULT kind), and Pal.Handle:renderOn

- **Probe:** F6

**What a pack author sees**

A pack author writes Mesh{ id="x", model="/Game/.../SK_ChickenPal.SK_ChickenPal" } — kind
defaults to skeletal — and calls :attachTo(ctx.actor). It returns false and UE4SS.log shows
either "skeletal: actor carries no readable mesh component (.Mesh / :GetMesh())" or "skeletal:
component carries neither SetSkinnedAssetAndUpdate nor SetSkeletalMeshAsset". No pal ever
changes shape. If it returns true instead, nobody has ever confirmed the pal visibly changed.

**The one thing nobody has measured**

Which of `SetSkinnedAssetAndUpdate` / `SetSkeletalMeshAsset` a live Pal pawn's mesh component
actually carries, with what parameter list, and whether that component is reachable as the
`.Mesh` property at all. Nothing in either tree names it; dump/docs/05_mesh_material.md 5.3 is
still an empty FILL block.

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

**Once it is known**

The default mesh kind working at all: Mesh{...}:attachTo, Pal.Handle:renderOn,
Mesh.Handle:detach's restore, and Mesh.Handle:setColor on a pal. It also settles the
RelativeScale3D / RelativeLocation property names that skeletal scale and offset are gated on.

#### `mesh-static-setstaticmesh` — Mesh.Handle:attachTo on kind="static", Building.Instance:render(), Building.Handle:render()

- **Probe:** F5

**What a pack author sees**

Placing the shipped WorkBench or PalBoxV2 attaches nothing. UE4SS.log shows "static: attach
failed: SetStaticMesh did not take", render() returns false, and because the component is
destroyed again there is nothing half-attached to see.

**The one thing nobody has measured**

The reflected signature of `UStaticMeshComponent::SetStaticMesh` (parameter count and type) and
whether either read-back path — the `GetStaticMesh()` UFunction or the `StaticMesh` property —
exists on a component added at runtime. dump/docs/05_mesh_material.md 5.2 still lists all of
this as a to-confirm with an empty FILL block.

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

**Once it is known**

kind="static" entirely — both curated buildings and every inline building mesh, since
Building.Spec.Mesh defaults kind to "static". It also settles whether the per-slot material work
in base/renderer has any slots to work with.

#### `mesh-texture-import` — Mesh.Spec.texture and Mesh.Spec.params.texture on every kind

- **Probe:** F5

**What a pack author sees**

Declaring texture = "C:/mods/example/body.png" logs "tex-fail(no KismetRenderingLibrary)" or
"tex-fail(ImportFileAsTexture2D failed: ...)" and the mesh keeps its original surface. The
attach still returns true, because the material layer is deliberately best-effort.

**The one thing nobody has measured**

Whether `UKismetRenderingLibrary::ImportFileAsTexture2D` is callable at all from UE4SS Lua and
what it wants as its WorldContextObject argument — we currently pass the owning actor. The V5
POC README lists it as expected-BlueprintCallable but it has never been called in either tree.

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

**Once it is known**

The `texture` field on all four kinds — the headline example in api/mesh.lua's own header uses
it.

### UI

#### `ui-host-paths` — native.ui.widget.cloneGameWidget / UI.Handle:mount(<a panel of the game's own live UI>)

- **Probe:** F5
- **Marked at:** Scripts/palforge/native/ui/_widget.lua:51

**What a pack author sees**

A pack can build a native-looking widget but has nowhere in the game's own UI to put it. M.PATHS
names the title menu only, so every PalForge panel is either a title-menu entry or a separate
full-screen layer of our own (widget.screen). Nothing can be parented into the HUD, the
inventory or the build menu; cloneGameWidget runs but there is no second class path to clone.

**The one thing nobody has measured**

The widget NAME of a child inside the live PalUIHUDLayoutBase tree that is a UPanelWidget (i.e.
answers AddChild). The HUD/inventory ROOT CLASSES are already known from
deprecated/catalog/ui_widget_classes.txt (UPalUIHUDLayoutBase, UPalUIWorldHUDWidgetCanvas,
UPalUIInventoryEquipment, UPalUIInsideBaseCampCanvas — note the file does NOT contain the
'PalHUD'/'PalHUDWidget' that dump/docs/04_native_ui.md guesses at); the injectable child one
level down is what nothing in either tree records.

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

**Once it is known**

Filling M.PATHS with a real HUD/inventory anchor, and a native/ui element that injects into the
game's OWN screens (a status bar, extra inventory rows, build-menu entries) instead of only a
separate viewport layer. It is also dump/docs/04_native_ui.md §4.1-4.3, whose FILL blocks are
still blank.

#### `ui-menubutton-inner-slot` — native.ui.widget.menuButton (label alignment) — and therefore every TitleMenu entry

- **Probe:** F8
- **Marked at:** Scripts/palforge/native/ui/_widget.lua:356

**What a pack author sees**

A title-menu entry's label may sit centred where the game's own entries sit left.
leftAlignButtonContent calls SetAnchors/SetAlignment on HorizontalBox_0's Slot inside a pcall;
if that slot is not a CanvasPanelSlot both calls raise and are swallowed, and nobody has ever
observed which happens. Cosmetic only — the label is legible either way, and clickableRow does
not depend on it.

**The one thing nobody has measured**

The CLASS of `HorizontalBox_0`.Slot inside a freshly created WBP_Title_MenuButton
(deprecated/nativeui.lua logged it once as 'BTNDIAG inner slot = ...' but no log line was ever
kept in either tree).

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

**Once it is known**

Making title-entry label alignment deterministic instead of best-effort, and re-confirming
dump/docs/04_native_ui.md §4.5 — if any of those three names changed, TitleMenu silently injects
nothing today.

#### `ui-update-event` — UI.Handle:autoRefresh(ms) — polling is the only refresh driver PalForge has

- **Probe:** F5
- **Marked at:** Scripts/palforge/api/ui.lua:273

**What a pack author sees**

Nothing calls refresh() for a pack. Every element must either call :refresh() by hand or ride
the 500 ms heartbeat, so a panel shows stale content for up to `ms` and there is no way to
refresh exactly when the game rebuilds a screen. TitleMenu's whole re-injection strategy is a
poll for the same reason.

**The one thing nobody has measured**

Whether Palworld raises any UFunction that UE4SS can RegisterHook when a UI screen is opened,
closed or rebuilt — specifically the NAME and parameter list of an Open/Show/Construct-style
UFunction on UPalUIManagerSubsystem, UPalUIHUDLayoutBase or UPalUITitleBase.
dump/docs/04_native_ui.md §4.4's FILL block is still empty and no reflection dump exists in
either tree.

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

**Once it is known**

An event-driven refresh: a ui.* channel in core/event fed by a real native hook, so elements
update the moment a screen rebuilds instead of polling — and TitleMenu could re-inject on the
rebuild signal rather than on a 2 s timer.

### Events and icons

#### `building-break-source` — Building{ events = { onBreak, onLeftClick } }

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/event.lua:744

**What a pack author sees**

Both hooks are declarable and permanently inert — there is no channel for either in core/event,
so nothing emits them. A destroyed structure surfaces only as onRemove, up to MISS_THRESHOLD
scans later, and a left click surfaces not at all.

**The one thing nobody has measured**

Whether /Script/Pal.PalBuildObject:OnDamage — the one destruction-adjacent hook the event probe
ever saw fire (dump/docs/further_plan.md:157-166, harness label BUILD.damage) — also fires when
the structure is DESTROYED, and what its params carry (damage amount? remaining HP?
instigator?); plus whether PalBuildObject exposes any separate destroy or click UFunction at
all.

**What the probe prints**

(1) REFLECT: local cls = StaticFindObject("/Script/Pal.PalBuildObject");
cls:ForEachFunction(function(fn) print(fn:GetFName():ToString()) end);
cls:ForEachProperty(function(p) print(p:GetFName():ToString(),
p:GetClass():GetFName():ToString()) end) — paste BOTH lists in full (the function list settles
onLeftClick too, and the property list shows whether HP is readable). (2) HOOK:
RegisterHook("/Script/Pal.PalBuildObject:OnDamage", fn) logging self:get():GetFullName(), the id
matched out of the class name (BP_BuildObject_<Id>_C), and a1..a4 via p:get() plus tostring. In
a throwaway world, with a marker line before each: (a) hit a placed wooden wall ONCE, (b) keep
hitting until it is destroyed, (c) dismantle another from the build menu. Paste every firing
under its marker.

**Once it is known**

a building.break channel + onBreak dispatch (and onLeftClick, if the reflected function list
names a click path)

#### `icons-row-column` — core.icons.resolve -> Item/Pal/Building/Skill Handle:iconOf() (the ICON_COLUMNS probe list)

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/icons.lua:86

**What a pack author sees**

Even once a row can be read, the texture is looked for under five inferred column names; if none
of them is the real one, resolve() still returns nil and iconOf() still falls back silently.

**The one thing nobody has measured**

The property names of each icon table's ROW STRUCT — which one holds the texture ref and of what
type (FName? soft object path? object?). SoftIcon/IconName/IconTexture/Icon/Texture are name-
table inference, never measured.

**What the probe prints**

No readable row needed — walk the row struct, exactly as dump/dump.lua:55-59 does. For each of
DT_ItemIconDataTable, DT_PalCharacterIconDataTable, DT_BuildObjectIconDataTable,
DT_partnerSkillIconDataTable (and the _Common siblings): local dt = FindObject("DataTable",
name); print(name, dt and dt:GetFullName()); local rs = dt.RowStruct; print(" rowstruct=",
rs:GetFName():ToString()); rs:ForEachProperty(function(p) print(" ", p:GetFName():ToString(),
p:GetClass():GetFName():ToString()) end). Paste the per-table property name + class list (the
GetFullName lines also settle this file's unverified PACKAGE_DIRS).

**Once it is known**

replacing the ICON_COLUMNS guess list with measured column names, so readIcon looks in the right
place the first time

#### `icons-row-read` — core.icons.resolve -> Item/Pal/Building/Skill Handle:iconOf()

- **Probe:** F5
- **Marked at:** Scripts/palforge/core/icons.lua:269

**What a pack author sees**

iconOf() always returns the declared `icon` (nil unless the author set one). The table is now
genuinely found, but no row is ever read, so Item.get("Wood"):iconOf() is nil even though the
row exists.

**The one thing nobody has measured**

Whether ANY reflected row-VALUE accessor exists on this build — the two members findRow tries
are near-certainly wrong (in UE, GetDataTableRowFromName is a CustomThunk static on
UDataTableFunctionLibrary whose wildcard output type comes from Blueprint bytecode, and FindRow
is a C++ template that is not reflected), so the question is what UDataTable /
UDataTableFunctionLibrary / a Pal-specific utility ACTUALLY expose.

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

**Once it is known**

real icons for all four domains — findTable and readIcon are already in place, only the row
fetch in the middle is missing

#### `pal-spawned-fresh` — Pal{ events = { onSpawned } } / event.on("pal.spawned")

- **Probe:** F7
- **Marked at:** Scripts/palforge/core/event.lua:900

**What a pack author sees**

The hook is armed (late, after world.ready) and the dispatch resolves, but it has never been
seen to fire: onSpawned may simply never run, and a pack cannot tell that from 'no pal spawned'.

**The one thing nobody has measured**

Whether /Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter is called for a pal
spawned AFTER the world has finished loading (it fired 0 times in the v4/v6 probes, where every
pal pre-existed the hook — dump/docs/further_plan.md:83-85), and whether `self` is then the new
pal's actor.

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

**Once it is known**

either confirming pal.spawned as a real spawn signal, or replacing its source with whatever does
fire — the channel, dispatch and Pal onSpawned are already wired either way

