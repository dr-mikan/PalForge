# PalSmith — In-Game Dump / Observation Plan (`dump_targets.md`)

The single source of truth for **what we must observe in a running Palworld client** to
fill every remaining `-- TODO(dump)` / `-- TODO:` seam in PalSmith and finish the 導線
(the end-to-end wiring). It does **not** contain values — it says *what* to observe,
*where* it lives, *how* to dump it with UE4SS, and *which* Lua frame / native file each
observation fills.

> **Rule (do not violate):** never invent a Palworld id / asset path / native-event name.
> Real names appear below **only** where the codebase already proves them (grepped from
> `palsmith/*` + `deprecated/`). Everything else is written as **`dump to discover`**.

---

## 1. Purpose & how to use

- **This is the dump plan, not the data.** Each row in the tables below maps to exactly one
  fill-in point in the code; Section 9 is the self-audit that every point is covered.
- **Run in a throwaway world.** `FindAllOf` / object enumeration touches native memory; a
  stale pointer raises `EXCEPTION_ACCESS_VIOLATION` which Lua `pcall` **cannot** catch and
  crashes the game (documented in `tests/catalog.lua` and `core/event.lua`). Never auto-run
  a dump on world-enter (the load-storm was the historical crash). Dump deliberately, by
  hand, after the world is fully loaded.
- **Entry points that already exist:**
  - Console command **`ps_catalog`** → `tests/catalog.lua : M.dump()` — enumerates every
    loaded `UDataTable` and writes row names to `<Scripts>/catalog/datatables/*.json` +
    `index.json`. Wired dev-only in `core/registry.lua : installDevCatalogCommand()`
    (gated on `env.dev`).
  - `tests/catalog.lua : M.logBuildIds()` — prints the resolved build table summary.
  - Dev keybinds (dev-only, `utils/keyboard/functions/`): **F1** announce probe, **F4**
    `items.unlockAllTech()`, **F8** `items.give("Wood",1)`.
- **We can add more probes.** New discovery is a new `RegisterConsoleCommandHandler` in the
  dev block, or a new `tests/<name>_probe.lua`. Section 2 is the toolbox those probes reuse.
- **How to read a row:** `WHAT to observe → WHERE it lives (DataTable / UE class / asset
  path) → HOW to dump (concrete UE4SS call) → FILLS (frame/file)`.

---

## 2. Dump mechanisms (the toolbox)

Reuse these exact techniques. All are already present in the codebase (mostly in
`deprecated/` and `tests/catalog.lua`); the probes we add just re-point them.

### (a) DataTable row dump — content ids
The backbone. Discover ids by enumerating every loaded `UDataTable` and reading its row
FNames.

```lua
local all = FindAllOf("DataTable")                        -- every loaded UDataTable
for _, dt in ipairs(all) do
  local names = dt:GetRowNames()                          -- path 1 (not always reflected)
  -- path 2 (reliable, BlueprintCallable):
  local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
  lib:GetDataTableRowNames(dt, outTbl)                    -- fills outTbl in place OR returns
  local tname = dt:GetFName():ToString()                  -- GetName() is NOT always bound
end
```
Verbatim in `tests/catalog.lua` and `deprecated/catalog.lua`. Output lands in
`catalog/datatables/<TableName>.json`. **Friendly substrings the dumper already tags**
(confirm the exact live table name from the dump): `ItemDataTable`, `BuildObjectDataTable`,
`MonsterParameter`, `TechnologyRecipeUnlock`.

### (b) Reflection enumeration — find the event/function to hook
For pal/item life events where **no** native function name is known yet: enumerate a
candidate UObject's functions/properties to spot the call to hook.

- UE4SS console: `dumpallobjects`, or the **Live View / "Dump all objects & properties"**
  in the UE4SS GUI — writes `UE4SS_ObjectDump.txt` with every `UFunction` signature.
- In Lua, walk a live instance's class: `obj:GetClass():GetFullName()`, then read the
  CXX header dump (`Pal.hpp` from `Dumper-7`/`CXXHeaderDump`) for the matching
  `UFunction` on e.g. `PalCharacter` / `PalIndividualCharacterHandle` /
  `PalCharacterParameterComponent`.
- Grep the header for verbs: `Spawn`, `Dead`/`Death`/`Die`, `Damage`, `Capture`/`Catch`,
  `AddItem`, `ConsumeItem`, `Craft`.

### (c) Hook probe — confirm a candidate function actually fires
Once (b) yields a candidate, prove it fires and inspect its params before wiring a SOURCE.

```lua
RegisterHook("/Script/Pal.<Class>:<Function>", function(self, p1, p2)
  local s  = self:get()
  local a1 = p1 and p1:get()                              -- unwrap RemoteUnrealParam
  print("[probe] fired", s:GetFullName(), tostring(a1))
end)
```
Pattern proven in `core/event.lua : tryHook()` and `deprecated/events.lua`. Always
`pcall(RegisterHook, ...)` (a bad path must not abort load). Log the payload so we learn
which field carries the id / amount / target.

### (d) Widget-tree traversal — map a live UI
Depth-first search the live UMG tree to learn widget names/paths for injection.

```lua
local base = FindFirstOf("PalUITitleBase")                -- or the HUD/build-menu root
local root = base.WidgetTree.RootWidget
-- descend: WidgetTree.RootWidget, GetChildrenCount()/GetChildAt(i), GetContent()
```
The full `findByName(w, name, depth)` DFS is in `native/ui/_widget.lua` (and
`deprecated/nativeui.lua` / `deprecated/titlemenu.lua`). To **map** an unknown tree, log
`widgetName(child)` at every node instead of matching one name.

### (e) SoundID discovery — Wwise event rows
Palworld SEs/BGM are **Wwise events named by an FName SoundID row** (not `USoundBase`), so
`PlaySound2D` does not apply. Discover valid ids via the DataTable dump (a), then confirm
each by *playing* it:

```lua
local u = StaticFindObject("/Script/Pal.Default__PalSoundUtility")
u:PlaySoundByActor(actor, { Key = FName(soundId) }, { FadeInTime = 0 })   -- audible => valid
u:StopSoundByActor(actor)
u:IsSoundPlayingByActor(actor)
```
Verbatim in `utils/sound/native.lua` and `deprecated/audio.lua : playSE/dumpSounds`.
Grep the dump for tables containing `Sound` / `SE` / `BGM` / `Wwise` / `Ak`.

### (f) CDO call idiom (supporting)
Static gameplay calls go through a Class-Default-Object found by
`StaticFindObject("/Script/Pal.Default__<Class>")` then a method call — e.g.
`Default__PalUtility`, `Default__PalSoundUtility`. Used everywhere in `utils/items`,
`utils/sound/native`, `deprecated/actions`.

---

## 3. Life events — fills `core/event.lua` SOURCEs

`core/event.lua` is the whole 導線: `native event → SOURCE emit → channel → DISPATCH →
inst:onX(ctx)`. **DISPATCH is already wired for every channel.** The gap is the SOURCE for
pal + item. World + building SOURCEs are live (poll + hooks); an optional lighter native
event is noted for each.

Legend: **LIVE** = source implemented; **TODO(dump)** = honest stub, no native impl exists.

| Channel | Status | Native function / hook to use or discover | How to confirm it fires | Payload to extract | Fills |
|---|---|---|---|---|---|
| `world.ready` | LIVE (poll) | `LoopAsync(1000)` polling `FindFirstOf("PalPlayerCharacter")`, N stable polls | already firing; log on emit | `{}` | `installWorldSource` |
| `world.left` | LIVE (poll) | same poll going invalid | leave world, watch log | `{}` | `installWorldSource` |
| *(optional)* world native event | dump to discover | reflection (b) on `PalGameInstance`/`PalWorld`/level-streaming for a real "world loaded" delegate | hook probe (c) | — | lighter `world.*` upgrade |
| `building.place` | LIVE (hook+scan) | `RegisterHook("/Script/Pal.PalNetworkPlayerComponent:RequestBuild_ToServer", fn(self,buildObjectId,location))` reconciled by `FindAllOf("PalBuildObject")` scan | place a building, watch `onPlace` | `{key,actor,pos,buildId,player}` | `installBuildingSource` |
| `building.load` | LIVE (scan) | `FindAllOf("PalBuildObject")` reconstruction scan on the heartbeat | reload a saved base | `{key,actor,pos,buildId,reconstructed}` | `scanOnce` |
| `building.interact` | LIVE (hook) | `RegisterHook("/Script/Pal.PalBuildObject:OnBeginInteractBuilding", fn(self,other))`; id via `BP_BuildObject_<Id>_C` class-name match | right-click a placed building | `{actor,player,buildId}` | `installBuildingSource` |
| `building.remove` | LIVE (scan) | scan miss-sweep (`MISS_THRESHOLD` consecutive misses) | destroy a building | `{key,buildId,actor,reason}` | `scanOnce` |
| *(optional)* build-complete native | dump to discover | `PalBuildObject:OnCompleteBuild_ServerInternal` **exists but is unsafe** (fires for every actor in the load storm → access violation). Only reconsider after observing a safe post-storm variant | hook probe (c) in throwaway world | — | replace deferred scan (only if proven safe) |
| `pal.spawned` | **TODO(dump)** | `dump to discover` — reflection (b) on `PalCharacter` / spawn path (`PalCheatManager:SpawnMonsterForPlayer` is a *cheat* spawn, useful only as a probe trigger, not the SOURCE) | hook probe (c); spawn via F-key/cheat and watch | `{actor, palId}` | `installPalSource` |
| `pal.damaged` | **TODO(dump)** | `dump to discover` — damage-apply UFunction on the character/parameter component (grep header for `Damage`/`ReceiveDamage`) | hook probe (c); hit a pal | `{actor, amount, palId}` | `installPalSource` |
| `pal.death` | **TODO(dump)** | `dump to discover` — death/`Dead` UFunction (grep `Dead`/`Die`/`OnDead`) | hook probe (c); kill a pal | `{actor, palId}` | `installPalSource` |
| `pal.captured` | **TODO(dump)** | `dump to discover` — capture/catch-success UFunction (grep `Capture`/`Catch`/`PalSphere`) | hook probe (c); catch a pal | `{actor, palId}` | `installPalSource` |
| `item.obtain` | **TODO(dump)** | `dump to discover` — inventory add path. **Candidate known:** `UPalItemContainer` / inventory `AddItem_ServerInternal(FName,count,...)` (proven in `utils/items.give`) — hook it to observe obtains | hook probe (c) on the add path; pick up an item | `{itemId, count, player}` | `installItemSource` |
| `item.use` | **TODO(dump)** — **candidate proven** | `RegisterHook("/Script/Pal.PalItemUseProcessor:UseItemToCharacter_ServerInternal", fn(self,itemData,targetId))`; `itemData.ID:ToString()` is the item FName (verbatim in `deprecated/events.lua`) | use/consume an item | `{itemId, player}` | `installItemSource` |
| `item.craft` | **TODO(dump)** | `dump to discover` — craft-complete UFunction on the crafting/work component (grep `Craft`/`Product`/`Complete`) | hook probe (c); craft at a bench | `{itemId, count}` | `installItemSource` |
| `item.discard` | **TODO(dump)** | `dump to discover` — drop/consume-to-zero path (may be the negative-delta branch of the same add call, per `utils/items.take`) | hook probe (c); drop an item | `{itemId, count}` | `installItemSource` |

> Item runtime note (from `installItemSource`): even once these hooks fire, items have **no
> per-instance tracking**, so `resolve("item", …)` returns nil and DISPATCH no-ops until an
> item runtime (analogous to the building registry in `core/event.lua`) is added. Observe
> whether `itemData` carries a stable handle we can key on.

---

## 4. Content IDs — fills `native/*` + audio

Every concrete `native/*` class ships a **placeholder** id/soundId that says
"confirm by dump". Dump the DataTable (mechanism 2a), grep for the row, write the real
value into the file. PalSchema is how new content rows get *injected* (jsonc split, see
Section 7); this section is how we learn the **existing** row names.

| Domain | DataTable / asset source (dump to confirm exact name) | Row-name shape | Native file(s) filled |
|---|---|---|---|
| **Building** | `BuildObjectDataTable` (friendly-tag); also class `BP_BuildObject_<Id>_C` | build-object FName, e.g. the vanilla chest id; modded → `example_Bench` | `native/building/bench.lua` (`Bench.buildIds`) |
| **Item** | `ItemDataTable` (friendly-tag) | item FName; recipe material ids (e.g. `example_Herb`) | `native/item/potion.lua` (`recipe.materials`, id) |
| **Pal** | `MonsterParameter` (friendly-tag) | pal/monster FName (BlueSkyDragon-style) | `native/pal/boss.lua` (id) |
| **Skill** | `dump to discover` — the Pal skill / active-skill DataTable (grep dump for `Skill`/`WazaData`/`ActiveSkill`) | skill FName | `native/skill/fireball.lua` (id, element) |
| **Effect (nativeStatus)** | `dump to discover` — the status/state DataTable (grep for `Status`/`PassiveSkill`/`State`/`Buff`) | status FName that `.nativeStatus` must equal | `native/effect/{burn,freeze,poison}.lua` (`nativeStatus = "Burn"/"Freeze"/"Poison"` — placeholders) |
| **Audio — BGM SoundID** | `dump to discover` — Sound/Wwise/Ak DataTable(s) (mechanism 2a+2e) | Wwise event FName row | `native/audio/bgm/{main_theme,battle_theme,victory_theme}.lua` (`soundId` placeholders `MainTheme`/`BattleTheme`/`VictoryTheme`) |
| **Audio — SE SoundID** | same Sound tables; confirm by `PlaySoundByActor` (2e) | Wwise event FName row | `native/audio/se/{explosion,laser,footstep}.lua` (`soundId` placeholders `Explosion`/`Laser`/`Footstep`) |

**Icons (texture asset paths) — for `iconOf`.** Each domain's `iconOf` returns
`self.icon` (a path/handle) but the resolve step is TODO. Dump the **icon column** of the
same DataTable row (item/pal/skill/effect rows carry an icon soft-object path), or
enumerate loaded `Texture2D` objects via `FindAllOf("Texture2D")` and match by name.

| Icon for | Where the path lives | Dump how | Fills |
|---|---|---|---|
| Item icon | icon field of the `ItemDataTable` row (soft `Texture2D` path) | read the row struct / grep dump; `FindAllOf("Texture2D")` cross-check | `base/item.lua : Item:iconOf` |
| Pal icon | icon/paldeck field of `MonsterParameter`-family row | same | `base/pal.lua : Pal:iconOf` |
| Skill icon | icon field of the skill table row | same | `base/skill.lua : Skill:iconOf` |
| Effect icon | icon field of the status table row | same | `base/effect.lua : Effect:iconOf` |

---

## 5. Native UI data — fills `native/ui`

The UI kit builds live UMG from Palworld's **own** widgets (no cooked WidgetBlueprints).
Lifecycle is owned by `base/ui.lua`; the concrete elements only fill `render()`.

**Known-good widget paths (verified 2026-07-17 from the title menu; in `native/ui/_widget.lua : M.PATHS`):**

| Key | Path / name |
|---|---|
| `menuButton` | `/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C` |
| `palTextBlock` | `/Game/Pal/Blueprint/UI/PalTextBlock/BP_PalTextBlock.BP_PalTextBlock_C` |
| `invisibleButton` | `/Game/Pal/Blueprint/UI/System/Style/WBP_PalInvisibleButton.WBP_PalInvisibleButton_C` |
| `menuButtonLabel` | `Test_Content` (label widget inside `WBP_Title_MenuButton`) |
| `menuButtonClick` | `WBP_PalInvisibleButton` (the CommonUI click target) |
| `menuButtonInner` | `HorizontalBox_0` |
| title button column | `PalUITitleBase.WidgetTree.RootWidget → … → VerticalBox_0` |
| exit anchor | `WBP_Title_MenuButton_ExitGame` (kept last by `title_menu.lua`) |
| click event | `RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", fn(self))` (shared click router) |

**Still to dump (mechanism 2d — traverse the live tree, logging every `widgetName`):**

| Target UI | Root to grab (dump to confirm) | What to map | Fills |
|---|---|---|---|
| Title menu tree | `FindFirstOf("PalUITitleBase")` | confirm `VerticalBox_0` + entry/slot shape across game versions | `native/ui/title_menu.lua` |
| Button host panel | the panel a `Button` mounts into | which `AddChildTo*` the host accepts (context-dependent per `native/ui/button.lua`) | `native/ui/button.lua : render` |
| Build menu | `dump to discover` — the build/HUD widget (grep loaded widgets for `Build`/`WBP_Build`) | container to inject modded buildables + row widget path | build-menu injection (new element) |
| Inventory UI | `dump to discover` — inventory widget (`WBP_Inventory*`/`Container`) | slot widget + list container | inventory element |
| HUD | `dump to discover` — main HUD root (`PalHUD`/`WBP_MainHUD*`) | anchor for status-bar / overlays | HUD element + effect status bar |
| UI update signal | `dump to discover` — a native/PalSchema UMG update event to bind `refresh()` to; else `LoopAsync` fallback | which event to hook vs. async fallback | `base/ui.lua : UIRenderer:_installUpdateDriver` |

Construction primitives already proven (no dump needed): `StaticConstructObject` on
`/Script/UMG.{VerticalBox,HorizontalBox,ScrollBox,Overlay,Border,SizeBox,TextBlock}`, and
`WidgetBlueprintLibrary:Create(pc, cls, pc)` via
`/Script/UMG.Default__WidgetBlueprintLibrary` for WBP_/BP_ widgets.

---

## 6. Mesh / material / model & placement — fills render + mesh util

`utils/mesh/` dispatches by `spec.kind`: `procedural` (OBJ→ProceduralMesh, **implemented**),
`static` (**TODO stub**), `skeletal` (**TODO stub**). Buildings currently render via the
procedural backend; pals need real skeletal.

| What to observe | Where / native API | How to dump | Fills |
|---|---|---|---|
| **Base material with a usable color/texture param** | procedural MID needs a real parent material; candidates in `procedural.lua : BASE_MATERIAL_CANDIDATES` (e.g. `/Engine/BasicShapes/BasicShapeMaterial`) | `Procedural.probeMaterials()` logs which candidates are **loaded**; also `FindAllOf("Material")`/`MaterialInstance` and check for a `Color`/`BaseColor` vector param | `utils/mesh/procedural.lua` (base material + `COLOR_PARAMS`/`TEXTURE_PARAMS` names) |
| **Correct color/texture param NAMES** on that material | UE material params via reflection | probe `SetVectorParameterValue(FName, ...)` against `COLOR_PARAMS`/`TEXTURE_PARAMS`, watch which visibly tints | same param-name lists in `procedural.lua` |
| **Building mesh — static vs procedural** | a real `UStaticMesh` asset for a placeable | dump the vanilla build actor's `StaticMeshComponent.StaticMesh` object path (inspect a placed `PalBuildObject`); enumerate `FindAllOf("StaticMesh")` | `utils/mesh/static.lua : attach` (`spec.asset` = UStaticMesh path); `base/building.lua : mesh` (choose `kind="static"`) |
| **Pal mesh — skeletal** | the pawn's `USkeletalMeshComponent` + its `USkeletalMesh` | inspect a live `PalPlayerCharacter`/pal pawn: which mesh component holds `SkeletalMesh`; dump asset path; observe `SetSkeletalMesh`/`SetSkeletalMeshAsset` signature | `utils/mesh/skeletal.lua : attach`; `base/pal.lua : render` (real creature mesh) |
| **Placed-actor location / settle timing** | `K2_GetActorLocation()` (0,0,0 = not-ready sentinel) | already handled by the deferred scan; observe how many scans until `pos` stabilizes for the mesh-attach defer | `core/event.lua` deferred `_meshPending` |
| **Grid / placement convention** | `spatial.GRID_CM = 100` (1 m); per-building `gridCm` | observe real build snap spacing to confirm 100 cm quantum and rotation handling | `utils/spatial.lua`, `base/building.lua : gridCm` |

Proven procedural chain (no dump): `AddComponentByClass(ProceduralMeshComponent)` →
`CreateMeshSection(0,verts,tris,{},uvs,vcolors,{},false)` → **mandatory** `SetWorldScale3D`
(empty `{}` FTransform zero-inits scale) → material via
`CreateAndSetMaterialInstanceDynamicFromMaterial(0, base)` and
`KismetRenderingLibrary:ImportFileAsTexture2D`. Collision **must** stay off (a collider
intercepts the build placement raycast).

---

## 7. Data locations & structure ("tree") — where Palworld stores content + how we inject

So content can be *authored* and *injected*. Two halves: **read** existing structure by
dumping (mechanism 2a); **write** new content via **PalSchema jsonc** (rows are global; the
`packid_name` FName convention in `object_manager.resolve` prevents collisions).

| Data domain | Where it lives (dump to confirm exact table) | Structure to learn | Author/inject via |
|---|---|---|---|
| Items | `ItemDataTable` | columns: id, display, category, maxStack, icon path, stack rules | PalSchema item jsonc → `base/item.lua : register` publishes; recipe = `data.defineRecipe` |
| Recipes | recipe/product table (dump; near item/craft tables) | materials map, output count, work amount, station id | PalSchema recipe jsonc |
| Buildings | `BuildObjectDataTable` + `BP_BuildObject_<Id>_C` blueprints | id, mesh, placement category, work type | PalSchema build jsonc → `base/building.lua` (event-driven going-live) |
| Pals | `MonsterParameter` (+ related param tables) | stats, skills list, mesh/AI refs, paldeck icon | PalSchema pal jsonc → `base/pal.lua : register` |
| Skills | skill/`WazaData`-family table (dump to discover) | element, power, cooldown, projectile/anim refs | PalSchema skill jsonc → `base/skill.lua : register` |
| Effects/status | status/state table (dump to discover) | duration, interval, stacking, icon | PalSchema status jsonc → `base/effect.lua : register` |
| **Tech / build tree** | `TechnologyRecipeUnlock` (friendly-tag) | node → unlocked recipe/build id, level/cost, category ordering, tree placement | PalSchema tech jsonc; each modded building tech creates a `DT_TechnologyRecipeUnlock` row named after its id (e.g. `example_Bench`), unlocked at runtime by `items.unlockTech(FName)` / `PalCheatManager:UnlockOneTechnology` |

**Runtime write paths already proven** (for dev/probe, not the ship path):
- Give/take items: `PalUtility CDO → GetPlayerStateByPlayer → GetInventoryData →
  AddItem_ServerInternal(FName, count, false, 0.0)` (`utils/items`).
- Unlock tech: `PalCheatManager:{UnlockAllRecipeTechnology, UnlockAllCategoryTechnology,
  UnlockTechnologyByLvCap(60), UnlockOneTechnology(FName)}` (`utils/items`).
- Container (chest) I/O: `actor:GetModel() → GetConcreteModel(true) →
  GetItemContainerModule() → GetContainer()` = `UPalItemContainer` (`deprecated/container.lua`;
  **writes are save-risky**, throwaway-world only).

---

## 8. Behaviors to observe — so the lifecycle hooks mean something

Enough runtime behavior to implement each hook non-trivially.

| Object | Observe | Why (which hook it makes real) |
|---|---|---|
| **Building work/production** | how a vanilla bench/production building advances work, consumes inputs, yields outputs; which component drives it and its tick cadence | `Building:onTick`, `onPlace`, `onRightClick` (open its panel); `item.craft` payload |
| **Container behavior** | slot count, `GetItemId().StaticId` / `GetStackCount`, valid-vs-empty slot rules (empty-fill can crash on load) | building storage hooks; `item.obtain`/`discard` semantics |
| **Pal AI / spawn** | how `SpawnMonsterForPlayer` places a pawn, initial state, mesh component wiring, damage/HP flow, capture success path | `Pal:onSpawned/onDamaged/onDeath/onCaptured`, `Pal:render` (skeletal) |
| **Item use effects** | what `UseItemToCharacter_ServerInternal` does to the target (heal/stat), the native heal/status call | `Item:onUse` (e.g. Potion heal), effect application |
| **Status apply/remove** | the native call that adds/removes a status by FName, and how duration/interval are driven natively vs. our framework timer | `Effect:onApply/onExpire`; whether we drive timing or the game does |
| **Sound lifecycle** | fade in/out, whether SE vs BGM stop independently, positional vs 2D | `base/audio` play/stop; `setVolume` path |
| **Volume/gain control** | there is **no** volume control on `PalSoundUtility`; look for an AkAudio RTPC or a component-gain path | `base/audio.lua : setVolume` (BGM + SE) |
| **Custom-file audio** | whether a `USoundWave`/`USoundBase` can be loaded from a file at runtime and played (Palworld uses Wwise, so this may be impossible → confirm) | `utils/sound/file.lua : FileSource:play` |

---

## 9. Coverage checklist (self-audit — every fill-in point)

Every `-- TODO(dump)` SOURCE, every `native/*` placeholder, and every base/util seam found
in the code. Checkbox = dumped & filled. "Covered by §" points to the section with the plan.

### 9.1 Event SOURCEs — `core/event.lua`
- [ ] `pal.spawned` SOURCE (`installPalSource`) — §3
- [ ] `pal.damaged` SOURCE (`installPalSource`) — §3
- [ ] `pal.death` SOURCE (`installPalSource`) — §3
- [ ] `pal.captured` SOURCE (`installPalSource`) — §3
- [ ] `item.obtain` SOURCE (`installItemSource`) — §3
- [ ] `item.use` SOURCE (candidate: `PalItemUseProcessor:UseItemToCharacter_ServerInternal`) — §3
- [ ] `item.craft` SOURCE (`installItemSource`) — §3
- [ ] `item.discard` SOURCE (`installItemSource`) — §3
- [x] `world.ready` / `world.left` — LIVE (poll); optional native-event upgrade — §3
- [x] `building.place/load/interact/remove` — LIVE (hook+scan); optional native complete — §3
- [x] `tick` — LIVE (`LoopAsync`)

### 9.2 Native content placeholders — `native/*`
- [ ] `native/building/bench.lua` — real build id / `buildIds`; `render()`; `register()` — §4, §6
- [ ] `native/item/potion.lua` — item row id, `recipe.materials` (`example_Herb`), `onUse` heal, `register()` — §4, §8
- [ ] `native/pal/boss.lua` — monster row id, `render()` skeletal, `register()` — §4, §6
- [ ] `native/skill/fireball.lua` — skill row id/element, `onActivate` projectile, `register()` — §4, §8
- [ ] `native/effect/burn.lua` — `nativeStatus="Burn"` confirm; `onApply/onExpire` — §4, §8
- [ ] `native/effect/freeze.lua` — `nativeStatus="Freeze"` confirm; `onApply/onExpire` — §4, §8
- [ ] `native/effect/poison.lua` — `nativeStatus="Poison"` confirm; `onApply/onExpire` — §4, §8
- [ ] `native/audio/bgm/main_theme.lua` — `soundId="MainTheme"` confirm — §4 (2e)
- [ ] `native/audio/bgm/battle_theme.lua` — `soundId="BattleTheme"` confirm — §4 (2e)
- [ ] `native/audio/bgm/victory_theme.lua` — `soundId="VictoryTheme"` confirm — §4 (2e)
- [ ] `native/audio/se/explosion.lua` — `soundId="Explosion"` confirm — §4 (2e)
- [ ] `native/audio/se/laser.lua` — `soundId="Laser"` confirm — §4 (2e)
- [ ] `native/audio/se/footstep.lua` — `soundId="Footstep"` confirm — §4 (2e)

### 9.3 Native UI — `native/ui/*`
- [x] `native/ui/_widget.lua : M.PATHS` — title paths verified (2026-07-17) — §5
- [ ] `native/ui/_widget.lua` — build-menu / inventory / HUD widget paths (dump) — §5
- [ ] `native/ui/title_menu.lua` — re-confirm `VerticalBox_0`/entry shape per version — §5
- [ ] `native/ui/button.lua` — host-panel `AddChildTo*` (context-dependent) — §5

### 9.4 Base seams — `base/*`
- [ ] `base/item.lua : Item:iconOf` — icon path resolve — §4 (icons)
- [ ] `base/pal.lua : Pal:iconOf` — icon path resolve — §4 (icons)
- [ ] `base/skill.lua : Skill:iconOf` — icon path resolve — §4 (icons)
- [ ] `base/effect.lua : Effect:iconOf` — icon path resolve — §4 (icons)
- [ ] `base/item.lua : Item:register` — publish item + recipe to data layer — §7
- [ ] `base/pal.lua : Pal:register` — hand to spawn pipeline — §7, §8
- [ ] `base/skill.lua : Skill:register` — register with skill system — §7
- [ ] `base/effect.lua : Effect:register` — register with status system — §7, §8
- [x] `base/building.lua : Building:register` — going-live is event-driven (`core/event`), no per-class call — §3
- [ ] `base/building.lua : Building:mesh/render` — static-vs-procedural choice — §6
- [ ] `base/pal.lua : Pal:render` — real skeletal mesh — §6
- [ ] `base/audio.lua : BackgroundMusic:setVolume` — no native gain; find AkAudio RTPC — §8
- [ ] `base/audio.lua : SoundEffect:setVolume` — same volume path — §8
- [ ] `base/ui.lua : UIRenderer:_installUpdateDriver` — bind `refresh()` to a UI update signal — §5

### 9.5 Util seams — `utils/*`
- [ ] `utils/sound/file.lua : FileSource:play` — custom-file playback (USoundWave/USoundBase; may be impossible under Wwise) — §8
- [ ] `utils/mesh/procedural.lua` — base material + color/texture param names — §6
- [ ] `utils/mesh/static.lua : attach` — `UStaticMesh` asset load/attach — §6
- [ ] `utils/mesh/skeletal.lua : attach` — `USkeletalMesh` swap on pawn — §6

### 9.6 Data & tech tree (authoring/injection)
- [ ] Confirm exact table names: item / build / pal / skill / status / tech — §4, §7
- [ ] Tech/build tree node structure + placement (`TechnologyRecipeUnlock`) — §7
- [ ] Behaviors: building work, pal AI/spawn, item-use, status apply — §8

---

### Appendix — proven native names already in the codebase (do **not** re-dump)

`FindAllOf("DataTable")`, `UDataTable:GetRowNames()`,
`/Script/Engine.Default__DataTableFunctionLibrary:GetDataTableRowNames`,
`/Script/Pal.Default__PalSoundUtility:{PlaySoundByActor,StopSoundByActor,IsSoundPlayingByActor}`,
`/Script/Pal.PalNetworkPlayerComponent:RequestBuild_ToServer`,
`/Script/Pal.PalBuildObject:OnBeginInteractBuilding`,
`/Script/Pal.PalItemUseProcessor:UseItemToCharacter_ServerInternal` (`itemData.ID`=FName),
`/Script/CommonUI.CommonButtonBase:HandleButtonClicked`,
`FindAllOf("PalBuildObject")`, `FindFirstOf("PalPlayerCharacter"|"PalPlayerController"|"PalUITitleBase"|"PalGameInstance"|"PalCheatManager")`,
`/Script/Pal.Default__PalUtility:{GetPlayerStateByPlayer,SendSystemAnnounce}` → `GetInventoryData:AddItem_ServerInternal`,
`PalCheatManager:{SpawnMonsterForPlayer,UnlockAllRecipeTechnology,UnlockAllCategoryTechnology,UnlockTechnologyByLvCap,UnlockOneTechnology}`,
container chain `GetModel→GetConcreteModel(true)→GetItemContainerModule→GetContainer`,
mesh chain `AddComponentByClass(ProceduralMeshComponent)→CreateMeshSection→SetWorldScale3D`,
`/Script/Engine.Default__KismetRenderingLibrary:ImportFileAsTexture2D`,
build-id class pattern `BP_BuildObject_<Id>_C`.
