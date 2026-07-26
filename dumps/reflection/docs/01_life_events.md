# 01 — Life-event SOURCEs (`core/event.lua`)

Fills **`dump_targets.md` §9.1** (event SOURCEs) using the plan in **§3**.

`core/event.lua` holds the whole 導線: `native event → SOURCE emit → channel → DISPATCH →
inst:onX(ctx)`. **DISPATCH is already wired for every channel** (see `installDispatch()`, the
`M.on("pal.spawned", …)` etc. block). The gap is the **SOURCE**: the two stub functions

- `installPalSource()`  — currently only `-- TODO(dump):` comments (around **lines 596–600**)
- `installItemSource()` — currently only `-- TODO(dump):` comments (around **lines 602–608**)

Both run inside `M.start()` and may use the module-local helpers already defined above them:
`tryHook(path, fn)` (pcall-guarded `RegisterHook`, logs+disables on failure) and
`get(param)` (`param:get()`, unwraps a `RemoteUnrealParam`). The `worldReady` gate is also in
scope — mirror the building source and early-return `if not worldReady then return end`.

**Shared recipe shape** (what you write into the stub once the dump names the UFunction):

```lua
tryHook("/Script/Pal.<Class>:<Function>", function(self, p1, p2)
    if not worldReady then return end
    local ok, e = pcall(function()
        local s   = get(self)
        -- read the id/amount/target off the unwrapped params (learn the field from the probe)
        M.emit("<channel>", { --[[ payload fields per §3 ]] })
    end)
    if not ok then log.err("<channel> source: " .. tostring(e)) end
end)
```

**Before wiring a SOURCE, confirm the hook fires** with a throwaway hook probe (mechanism 2c)
and log the payload so you learn *which param field* carries the id / amount / target.

---

## 1.1 `pal.spawned` — `installPalSource`

1. **Target** — `core/event.lua : installPalSource` → add a `tryHook` that emits `pal.spawned`.
2. **Dump source** — `02_reflection.txt`. Grep the `PalCharacter` / spawn-path classes
   (`/Script/Pal.PalCharacter`, `PalPlayerCharacter`, `PalIndividualCharacterParameter`) for a
   function matching `Spawn|BeginPlay|Setup|Init`. `PalCheatManager:SpawnMonsterForPlayer` is a
   *cheat trigger only*, not the SOURCE — use it to make a pal appear while probing.
3. **Extract** — the `/Script/Pal.<Class>:<Function>` path of the real spawn/init call, and
   which unwrapped param (or `self`) is the spawned actor; derive `palId` from the actor
   (class name / paldeck param). Confirm with a hook probe (2c) before wiring.
4. **Implement** — payload `{ actor = <spawned pawn>, palId = <resolved id> }`; then
   `M.emit("pal.spawned", { actor = actor, palId = palId })`. DISPATCH (`M.on("pal.spawned",
   … call("pal","onSpawned",ctx))`) already routes it to `Pal:onSpawned`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed UFunction (from 02_reflection.txt):
--   /Script/Pal. ______________ : ______________
-- param carrying the actor / how palId is read:
--   ______________
-- final code (into installPalSource):
--
```

---

## 1.2 `pal.damaged` — `installPalSource`

1. **Target** — `core/event.lua : installPalSource` → `tryHook` emitting `pal.damaged`.
2. **Dump source** — `02_reflection.txt`. Grep `PalCharacter` /
   `PalCharacterParameterComponent` / `PalIndividualCharacterParameter` for `Damage|ReceiveDamage|ApplyDamage|Hit`.
3. **Extract** — the damage-apply `/Script/Pal.<Class>:<Function>` path; which param is the
   damage amount and which is/holds the target actor. Probe (2c) hitting a pal to confirm.
4. **Implement** — payload `{ actor = <target>, amount = <dmg>, palId = <id> }`;
   `M.emit("pal.damaged", …)`. Routed to `Pal:onDamaged(damageValue, ctx)` — note the base
   signature takes the amount **first**, so DISPATCH's `call("pal","onDamaged",ctx)` passes
   `ctx` only; if you need `damageValue` positionally, carry it in `ctx.amount`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed UFunction:
--   /Script/Pal. ______________ : ______________
-- amount param / target param:
--   ______________
-- final code (into installPalSource):
--
```

---

## 1.3 `pal.death` — `installPalSource`

1. **Target** — `core/event.lua : installPalSource` → `tryHook` emitting `pal.death`.
2. **Dump source** — `02_reflection.txt`. Grep the character/parameter classes for
   `Dead|Death|Die|OnDead|Kill`.
3. **Extract** — death `/Script/Pal.<Class>:<Function>` path; the dying actor + how to read
   its `palId`. Probe (2c) killing a pal.
4. **Implement** — payload `{ actor = <dying pawn>, palId = <id> }`;
   `M.emit("pal.death", …)` → `Pal:onDeath`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed UFunction:
--   /Script/Pal. ______________ : ______________
-- final code (into installPalSource):
--
```

---

## 1.4 `pal.captured` — `installPalSource`

1. **Target** — `core/event.lua : installPalSource` → `tryHook` emitting `pal.captured`.
2. **Dump source** — `02_reflection.txt`. Grep `PalCaptureManager` / `PalCharacter` for
   `Capture|Catch|PalSphere|Success`.
3. **Extract** — capture-success `/Script/Pal.<Class>:<Function>` path; the captured actor +
   `palId`. Probe (2c) catching a pal.
4. **Implement** — payload `{ actor = <captured pawn>, palId = <id> }`;
   `M.emit("pal.captured", …)` → `Pal:onCaptured`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed UFunction:
--   /Script/Pal. ______________ : ______________
-- final code (into installPalSource):
--
```

---

## 1.5 `item.use` — `installItemSource`  (candidate PROVEN)

1. **Target** — `core/event.lua : installItemSource` → `tryHook` emitting `item.use`.
2. **Dump source** — none needed to find the hook: the path is already proven in
   `deprecated/events.lua` (`M.install`). **Still confirm** the item FName shape by using an
   item and reading the log. In `02_reflection.txt` you can cross-check
   `/Script/Pal.PalItemUseProcessor` carries `UseItemToCharacter_ServerInternal`.
3. **Extract** — the item FName from the first param: `get(itemData).ID:ToString()` (verbatim
   from `deprecated/events.lua : onUse`).
4. **Implement** — write the proven hook into the stub:

   ```lua
   tryHook("/Script/Pal.PalItemUseProcessor:UseItemToCharacter_ServerInternal",
     function(self, itemData, targetId)
       if not worldReady then return end
       local ok, e = pcall(function()
           local id = get(itemData).ID:ToString()
           M.emit("item.use", { itemId = id, player = FindFirstOf("PalPlayerCharacter") })
       end)
       if not ok then log.err("item.use source: " .. tostring(e)) end
     end)
   ```

   DISPATCH (`M.on("item.use", … call("item","onUse",ctx))`) already routes it. **Runtime
   caveat (§3 note):** items have **no per-instance tracking**, so `resolve("item", …)` returns
   nil and `Item:onUse` won't fire until an item runtime keyed on `itemId` is added — see
   §1.9 below.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed item FName from get(itemData).ID:ToString():
--   ______________
-- final code (into installItemSource): [proven shape above]
--
```

---

## 1.6 `item.obtain` — `installItemSource`

1. **Target** — `core/event.lua : installItemSource` → `tryHook` emitting `item.obtain`.
2. **Dump source** — `02_reflection.txt`. **Candidate known:** the inventory add path
   `AddItem_ServerInternal(FName, count, …)` on `PalPlayerInventoryData` / `PalItemContainer`
   (the same call `utils/items.give` uses). Grep those classes for `AddItem|Add`.
3. **Extract** — the `/Script/Pal.<Class>:AddItem_ServerInternal` path; params: item FName +
   count (+ player). Probe (2c) picking up an item; watch whether the same call fires for
   both add and remove (negative delta) — that branch feeds `item.discard` (§1.8).
4. **Implement** — payload `{ itemId = <FName>, count = <n>, player = FindFirstOf("PalPlayerCharacter") }`;
   `M.emit("item.obtain", …)` → `Item:onObtain`. Same runtime caveat as §1.5.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed add-path UFunction + params:
--   /Script/Pal. ______________ : AddItem_ServerInternal(______________)
-- final code (into installItemSource):
--
```

---

## 1.7 `item.craft` — `installItemSource`

1. **Target** — `core/event.lua : installItemSource` → `tryHook` emitting `item.craft`.
2. **Dump source** — `02_reflection.txt`. Grep the crafting/work component classes for
   `Craft|Product|Complete|Work|Output`.
3. **Extract** — the craft-complete `/Script/Pal.<Class>:<Function>` path; the produced item
   FName + count. Probe (2c) crafting at a bench.
4. **Implement** — payload `{ itemId = <FName>, count = <n> }`;
   `M.emit("item.craft", …)` → `Item:onCraft`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed craft-complete UFunction:
--   /Script/Pal. ______________ : ______________
-- final code (into installItemSource):
--
```

---

## 1.8 `item.discard` — `installItemSource`

1. **Target** — `core/event.lua : installItemSource` → `tryHook` emitting `item.discard`.
2. **Dump source** — `02_reflection.txt`. Likely the **negative-delta branch** of the same
   add call (`utils/items.take` = `give` with a negative count) or a dedicated drop/consume
   path. Grep for `Discard|Drop|Consume|Remove|Sub`.
3. **Extract** — the drop/consume-to-zero `/Script/Pal.<Class>:<Function>` path (or the sign
   of `count` on the add call); item FName + count. Probe (2c) dropping an item.
4. **Implement** — payload `{ itemId = <FName>, count = <n> }`;
   `M.emit("item.discard", …)` → `Item:onDiscard`. If it's the add call's negative branch,
   branch on `count < 0` inside the §1.6 hook instead of a second `tryHook`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed discard path (or "negative branch of AddItem_ServerInternal"):
--   ______________
-- final code (into installItemSource):
--
```

---

## 1.9 Item instance runtime (unblocks §1.5–1.8 DISPATCH)

1. **Target** — `core/event.lua : resolve()` currently returns `nil` for `otype ~= "building"`,
   so **every item DISPATCH no-ops** even after the sources fire. To make `Item:onObtain/onUse/
   onCraft/onDiscard` actually run, add an item registry analogous to the building `Registry`.
2. **Dump source** — `02_reflection.txt` + the §1.5/§1.6 probes: observe whether `itemData`
   (or the inventory slot) carries a **stable handle** we can key an instance on
   (`GetItemId().StaticId`, a slot index, a container id).
3. **Extract** — the stable key field, and how to map an emitted `ctx.itemId` back to a
   registered `Item` class (via `object_manager.all("item")` keyed by resolved FName).
4. **Implement** — extend `resolve(otype, ctx)`: for `otype == "item"`, look the class up by
   `ctx.itemId` (resolve namespaced ids through `object_manager.resolve`) and return a
   per-use instance (or a cached one keyed on the stable handle). No code until the handle is
   observed — **do not invent** a tracking key.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- stable item handle observed (field on itemData / slot):
--   ______________
-- resolve() item branch:
--
```

---

## Already LIVE (no dump) — noted for completeness

- `world.ready` / `world.left` — **DONE** (poll in `installWorldSource`). Optional native-event
  upgrade is a *nice-to-have*: grep `02_reflection.txt` on `PalGameInstance`/`PalWorld` for a
  real "world loaded" delegate; only replace the poll if one is found.
- `building.place` / `building.load` / `building.interact` / `building.remove` — **DONE**
  (`installBuildingSource` hooks `RequestBuild_ToServer` + `OnBeginInteractBuilding`, plus the
  `FindAllOf("PalBuildObject")` scan). Do **not** hook `OnCompleteBuild_ServerInternal`
  (documented load-storm access violation).
- `tick` — **DONE** (`installTickSource`, `LoopAsync(M.TICK_MS)`).

---

## Coverage — this doc (§9.1)

| §9.1 checklist item | Recipe | Status |
|---|---|---|
| `pal.spawned` SOURCE | §1.1 | recipe (dump) |
| `pal.damaged` SOURCE | §1.2 | recipe (dump) |
| `pal.death` SOURCE | §1.3 | recipe (dump) |
| `pal.captured` SOURCE | §1.4 | recipe (dump) |
| `item.use` SOURCE (candidate proven) | §1.5 | recipe (confirm) |
| `item.obtain` SOURCE | §1.6 | recipe (dump) |
| `item.craft` SOURCE | §1.7 | recipe (dump) |
| `item.discard` SOURCE | §1.8 | recipe (dump) |
| *(enabler)* item instance tracking | §1.9 | recipe (dump) |
| `world.ready`/`world.left` | — | **DONE** (§9 `[x]`) |
| `building.place/load/interact/remove` | — | **DONE** (§9 `[x]`) |
| `tick` | — | **DONE** (§9 `[x]`) |

---

## Coverage — master audit

Every `dump_targets.md` §9 checkbox → the doc + section that carries its recipe. `[x]` items
in §9 are **DONE** and need no dump.

### §9.1 Event SOURCEs → this doc

See the table above.

### §9.2 Native content placeholders

| Item | id/data | render() | register() / behavior |
|---|---|---|---|
| `native/building/bench.lua` | [02](02_content_ids.md#21-buildingbenchlua--buildids) | [05](05_mesh_material.md#54-nativebuildingbenchlua--render) | [07](07_registers.md#71-item--building--pal--skill-register-seams) |
| `native/item/potion.lua` | [02](02_content_ids.md#22-itempotionlua--id--recipematerials) | — | [07](07_registers.md) (register + `onUse` heal) |
| `native/pal/boss.lua` | [02](02_content_ids.md#23-palbosslua--monster-id) | [05](05_mesh_material.md#55-nativepalbosslua--render-skeletal) | [07](07_registers.md) |
| `native/skill/fireball.lua` | [02](02_content_ids.md#24-skillfireballlua--id--element) | — | [07](07_registers.md) (register + `onActivate`) |
| `native/effect/{burn,freeze,poison}.lua` | [02](02_content_ids.md#25-effectburnfreezepoisonlua--nativestatus) | — | [07](07_registers.md) (`onApply/onExpire`) |
| `native/audio/bgm/{main,battle,victory}_theme.lua` | [03](03_audio.md#31-bgm-soundids--nativeaudiobgm) | — | — |
| `native/audio/se/{explosion,laser,footstep}.lua` | [03](03_audio.md#32-se-soundids--nativeaudiose) | — | — |

### §9.3 Native UI → [04](04_native_ui.md)
`_widget.lua` build/inventory/HUD paths, `title_menu.lua`, `button.lua`. (`M.PATHS` title = **DONE**.)

### §9.4 Base seams
- iconOf (item/pal/skill/effect) → [06](06_icons.md)
- register (item/pal/skill/effect) → [07](07_registers.md)  · `Building:register` = **DONE**
- building `mesh`/`render`, pal `render` → [05](05_mesh_material.md)
- `BackgroundMusic:setVolume` / `SoundEffect:setVolume` → [03](03_audio.md#33-setvolume--baseaudiolua)
- `UIRenderer:_installUpdateDriver` → [04](04_native_ui.md#44-baseuilua--_installupdatedriver)

### §9.5 Util seams
- `utils/sound/file.lua : FileSource:play` → [03](03_audio.md#34-custom-file-playback--utilssoundfilelua)
- `utils/mesh/procedural.lua` → [05](05_mesh_material.md#51-utilsmeshprocedurallua--base-material--param-names)
- `utils/mesh/static.lua : attach` → [05](05_mesh_material.md#52-utilsmeshstaticlua--attach)
- `utils/mesh/skeletal.lua : attach` → [05](05_mesh_material.md#53-utilsmeshskeletallua--attach)

### §9.6 Data & tech tree → [02](02_content_ids.md#26-confirm-exact-datatable-names--96) and behaviors → [07](07_registers.md#76-behaviors-to-observe--8--96)
