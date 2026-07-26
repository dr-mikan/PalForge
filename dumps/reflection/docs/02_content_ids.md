# 02 — Content IDs & data structure

Fills **`dump_targets.md` §9.2** (the id/data half of each `native/*` placeholder) and
**§9.6** (confirm exact DataTable names + tech/build-tree structure), using the plan in
**§4** and **§7**.

Every concrete `native/*` class ships a **placeholder** id/soundId/nativeStatus that literally
says *"confirm by dump"*. The recipe for each is the same: dump the DataTable rows
(mechanism 2a), grep for the row, write the real FName into the file. Mesh/render, register,
and behavior for these same files live in [05](05_mesh_material.md) and [07](07_registers.md).

**Where to look for all of §9.2 ids:** `01_datatables.txt` (every loaded `UDataTable` → its
row FNames). The dumper tags friendly substrings — grep the file for `ItemDataTable`,
`BuildObjectDataTable`, `MonsterParameter`, `TechnologyRecipeUnlock`. For build ids also use
`04_live_objects.txt` (real placed-actor classes → `BP_BuildObject_<Id>_C`).

> **Id model** (`utils/object_manager.resolve`): a namespaced id `"pack:Name"` maps to the
> DataTable row FName `"pack_Name"`; a literal id (no colon, e.g. `Wood`) passes through. The
> placeholders like `Bench`/`Explosion`/`Burn`/`MainTheme` are literal strings to be confirmed
> or replaced with the real row FName.

---

## 2.1 `native/building/bench.lua` — `buildIds`

1. **Target** — the build-object id(s) the Bench class resolves to. `native/building/bench.lua`
   currently sets only `Bench.displayName` / `Bench.gridCm` and has **no `buildIds`**;
   `core/event.lua : buildDef` falls back to `buildIds = { id }` (`"example:Bench"` →
   `"example_Bench"`). To bind the class to a **vanilla** build object, add `Bench.buildIds`.
2. **Dump source** — `04_live_objects.txt` (place the target building first): its class prints
   as `BP_BuildObject_<Id>_C   -> id: <Id>`. Cross-check `01_datatables.txt` →
   `BuildObjectDataTable` rows.
3. **Extract** — the `<Id>` from `BP_BuildObject_<Id>_C` (this is exactly what
   `core/event.lua : resolveBuildId` matches on), and/or the `BuildObjectDataTable` row FName.
4. **Implement** — add to `native/building/bench.lua` (after the `gridCm` line):
   ```lua
   Bench.buildIds = { "<Id>" }   -- literal vanilla id, OR "example:Bench" for a PalSchema row
   ```
   For a **modded** buildable, keep `example:Bench` and inject a `BuildObjectDataTable` +
   `DT_TechnologyRecipeUnlock` row named `example_Bench` via PalSchema (see §2.6/§7), then
   unlock it with `utils/items.unlockTech("example_Bench")`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed from 04_live_objects.txt: BP_BuildObject_______________ _C  -> id: ____________
-- BuildObjectDataTable row (01_datatables.txt): ____________
-- final code (native/building/bench.lua):
--   Bench.buildIds = { "____________" }
```

---

## 2.2 `native/item/potion.lua` — id + `recipe.materials`

1. **Target** — the Potion item id (currently the class id `example:Potion` → `example_Potion`)
   and its recipe material ids. `native/item/potion.lua` sets
   `recipe = { materials = { example_Herb = 3 }, count = 1 }` — `example_Herb` is a
   **placeholder material FName**.
2. **Dump source** — `01_datatables.txt` → `ItemDataTable` rows (grep for the herb/material
   FName; and for the potion row itself if binding to a vanilla consumable).
3. **Extract** — the real material row FName(s) for the recipe, and the item row FName if
   `example:Potion` should map onto an existing item instead of a PalSchema-injected one.
4. **Implement** — in `native/item/potion.lua`, replace the material key:
   ```lua
   Potion.recipe = { materials = { <RealMaterialFName> = 3 }, count = 1 }
   ```
   Keys are DataTable FNames (literal) or namespaced ids (`otherpack:Herb`). Publishing the
   recipe to the data layer is the `register()` seam in [07](07_registers.md).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- ItemDataTable material row(s): ____________
-- (optional) item row this class binds to: ____________
-- final code (native/item/potion.lua):
--   Potion.recipe = { materials = { ____________ = 3 }, count = 1 }
```

---

## 2.3 `native/pal/boss.lua` — monster id

1. **Target** — the monster/pal id the Boss class represents. `native/pal/boss.lua` ships only
   the class id `example:Boss` + `skills = { "example:Fireball" }`; add an explicit `Boss.id`
   binding (or keep `example:Boss` for a PalSchema-injected pal).
2. **Dump source** — `01_datatables.txt` → `MonsterParameter` (friendly-tag) rows;
   `04_live_objects.txt` → live `PalCharacter` classes for a spawned pal.
3. **Extract** — the pal/monster row FName (BlueSkyDragon-style literal), or confirm the
   PalSchema row name.
4. **Implement** — in `native/pal/boss.lua`:
   ```lua
   Boss.id = "<MonsterParameterRowFName>"   -- only if binding to a vanilla/known pal
   ```
   (mesh/render → [05](05_mesh_material.md#55-nativepalbosslua--render-skeletal); spawn
   register → [07](07_registers.md)).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- MonsterParameter row FName: ____________
-- final code (native/pal/boss.lua):  Boss.id = "____________"
```

---

## 2.4 `native/skill/fireball.lua` — id + element

1. **Target** — the skill row id + element. `native/skill/fireball.lua` sets
   `element = "fire"`, `cooldown = 3.0`, `power = 50` and class id `example:Fireball`.
2. **Dump source** — `01_datatables.txt`. **`dump to discover`** the Pal skill table — grep
   for `Skill` / `WazaData` / `ActiveSkill`.
3. **Extract** — the skill row FName; confirm the element enum/value the game uses if binding
   to a native skill.
4. **Implement** — in `native/skill/fireball.lua`, add `Fireball.id = "<SkillRowFName>"` (only
   to bind to an existing skill) and, if the game names elements differently, correct
   `Fireball.element`. Activation behavior + register → [07](07_registers.md).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- skill table name + row FName (01_datatables.txt): ____________ / ____________
-- native element value: ____________
-- final code (native/skill/fireball.lua):  Fireball.id = "____________"
```

---

## 2.5 `native/effect/{burn,freeze,poison}.lua` — `nativeStatus`

1. **Target** — the `nativeStatus` FName each effect resolves/applies. Current placeholders:
   `native/effect/burn.lua` → `Burn.nativeStatus = "Burn"`,
   `native/effect/freeze.lua` → `Freeze.nativeStatus = "Freeze"`,
   `native/effect/poison.lua` → `Poison.nativeStatus = "Poison"`.
2. **Dump source** — `01_datatables.txt`. **`dump to discover`** the status/state table — grep
   for `Status` / `PassiveSkill` / `State` / `Buff`.
3. **Extract** — the exact status row FName that each `.nativeStatus` must equal.
4. **Implement** — set `<Cls>.nativeStatus = "<StatusRowFName>"` in each file. Apply/remove
   (`onApply`/`onExpire`) → [07](07_registers.md).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- status table name (01_datatables.txt): ____________
-- rows:  Burn -> ____________   Freeze -> ____________   Poison -> ____________
-- final code:  <Cls>.nativeStatus = "____________"   (in each of the 3 files)
```

---

## 2.6 Confirm exact DataTable names + tech/build tree — §9.6

1. **Target** — pin the **real** table names behind the friendly substrings, and learn the
   tech-tree row structure so modded content can be authored/injected (PalSchema jsonc; §7).
   This underpins the `register()` seams in [07](07_registers.md).
2. **Dump source** — `01_datatables.txt`. Each block header is the table's full object name
   (`== <FullName> ==`) followed by its rows.
3. **Extract** — for each domain, the exact full table name + a representative row:
   - **item** — `ItemDataTable` (id, display, category, maxStack, icon path)
   - **build** — `BuildObjectDataTable` (+ `BP_BuildObject_<Id>_C`)
   - **pal** — `MonsterParameter`
   - **skill** — the `Skill`/`WazaData` table (discover)
   - **status** — the `Status`/`State` table (discover)
   - **tech** — `TechnologyRecipeUnlock` → node → unlocked recipe/build id, level/cost,
     category ordering. Each modded building tech = a `DT_TechnologyRecipeUnlock` row named
     after its id (e.g. `example_Bench`), unlocked by `utils/items.unlockTech(FName)`.
4. **Implement** — record the confirmed names in this doc (they are referenced by the
   `register()` recipes and the PalSchema authoring path). No code file changes here — this is
   the reference table the other docs cite.
5. **FILL**

```text
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- Confirmed full DataTable object names (from 01_datatables.txt "== ... ==" headers):
--   item   : ____________
--   build  : ____________
--   pal    : ____________
--   skill  : ____________
--   status : ____________
--   tech   : ____________
-- Tech row structure (columns observed for a TechnologyRecipeUnlock row):
--   ____________
```

---

## Coverage — this doc

| Checklist item | Section |
|---|---|
| §9.2 `native/building/bench.lua` — build id / `buildIds` | §2.1 |
| §9.2 `native/item/potion.lua` — item row id + `recipe.materials` | §2.2 |
| §9.2 `native/pal/boss.lua` — monster row id | §2.3 |
| §9.2 `native/skill/fireball.lua` — skill row id / element | §2.4 |
| §9.2 `native/effect/{burn,freeze,poison}.lua` — `nativeStatus` | §2.5 |
| §9.6 confirm exact table names (item/build/pal/skill/status/tech) | §2.6 |
| §9.6 tech/build tree node structure + placement | §2.6 |

(SoundIDs are in [03](03_audio.md); `render()`/mesh, `register()`, and gameplay behaviors for
the same native files are in [05](05_mesh_material.md) and [07](07_registers.md). §9.6
"behaviors to observe" → [07](07_registers.md#76-behaviors-to-observe--8--96).)
