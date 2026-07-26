# 07 — Register seams & gameplay behaviors

Fills the **`register()`** part of **`dump_targets.md` §9.4** (item/pal/skill/effect) and the
**behaviors** of **§9.6**, using the plan in **§7** (data locations / injection) and **§8**
(behaviors to observe). Also carries the gameplay hooks on the native classes whose *ids* were
filled in [02](02_content_ids.md): `Potion:onUse`, `Fireball:onActivate`, the effects'
`onApply/onExpire`.

Two halves to keep straight (§7):
- **register()** publishes a class to the game's data layer so the content **exists** — done by
  authoring **PalSchema jsonc** rows (global rows; the `packid_name` FName convention in
  `object_manager.resolve` prevents collisions). `register()` is the Lua seam that hands the
  class's fields to that injection.
- **behaviors** are the runtime gameplay calls a hook makes (heal, apply status, spawn
  projectile) — discovered by observing what the native path does (§8).

> **Prerequisite:** the exact DataTable names + row structure must be confirmed first — see
> [02 §2.6](02_content_ids.md#26-confirm-exact-datatable-names--96). The proven runtime write
> paths (`utils/items.give/take`, `utils/items.unlockTech`, container I/O) are the reference
> for how these calls reach the game.

`base/building.lua : Building:register` is **DONE** — going-live is event-driven via
`core/event.lua` (the scan + `object_manager.all("building")`), no per-class call. Do **not**
add a building register seam.

---

## 7.1 Item / building / pal / skill register seams

Each domain base has a `register()` that is a `-- TODO:` (item/pal/skill/effect); the native
subclass (`potion`/`boss`/`fireball`/effects) also has an empty `register()` override.

1. **Target** —
   - `base/item.lua : Item:register` (publish item + recipe) — the TODO already sketches
     `data.defineItem{ id, displayName, category, maxStack, icon = self:iconOf() }` +
     `if self:recipeOf() then data.defineRecipe(self.id, self:recipeOf()) end`.
   - `base/pal.lua : Pal:register` (hand class to the spawn pipeline: id, mesh, skills, hooks).
   - `base/skill.lua : Skill:register` (id, kind, element, cooldown, power, icon, hooks).
   - plus each native override (`native/item/potion.lua : Potion:register`, etc.) which should
     either be removed (so the base runs) or call `self:super("register")`.
2. **Dump source** — `01_datatables.txt` via [02 §2.6](02_content_ids.md#26-confirm-exact-datatable-names--96):
   the confirmed table name + the exact **column set** each row needs (id/display/category/
   maxStack/icon for items; stats/skills/mesh for pals; element/power/cooldown for skills).
   For tech unlock of a modded buildable, the `TechnologyRecipeUnlock` row shape.
3. **Extract** — the row columns each domain requires (so the jsonc / `data.defineX` payload is
   complete) and the FName each row is keyed on (`object_manager.resolve(self.id)`).
4. **Implement** — replace the `register()` TODO with a call into the chosen data layer:
   build the row payload from the class fields + `self:iconOf()` and hand it to the PalSchema
   injection (or a `data.defineX` shim). Keep it fail-soft (`pcall`), matching `define()`'s
   fail-soft registry call. Remove the empty native overrides so the base `register` runs.
   For a modded building, also emit the `DT_TechnologyRecipeUnlock` row and unlock at runtime
   with `utils/items.unlockTech("<packid>_<name>")`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- confirmed row columns per domain (from 01_datatables.txt / §2.6):
--   item : ____________   pal : ____________   skill : ____________
-- injection layer chosen (PalSchema jsonc / data.defineX shim): ____________
-- final code (base/item.lua : Item:register  [+ pal, skill]):
--
```

---

## 7.2 Effect register + status apply/remove — `base/effect.lua`, `native/effect/*`

1. **Target** — `base/effect.lua : Effect:register` (TODO: id, duration, interval, stacking,
   icon, hooks) and the native `onApply`/`onExpire` in `native/effect/{burn,freeze,poison}.lua`
   (TODO: apply/remove `<Cls>.nativeStatus` on `target`). The `nativeStatus` FNames come from
   [02 §2.5](02_content_ids.md#25-effectburnfreezepoisonlua--nativestatus).
2. **Dump source** — `02_reflection.txt`: grep the character/parameter classes and the status
   component for the native call that **adds/removes a status by FName** (e.g.
   `AddPassiveEffect`/`AddStatus`/`ApplyState`-style). Observe whether the game drives the
   status duration/interval natively or we drive it with the framework timer (§8).
3. **Extract** — the `/Script/Pal.<Class>:<AddStatus>(FName, …)` and the matching remove call;
   whether duration/interval is native (then `Effect.duration`/`interval` just mirror it) or
   framework-driven.
4. **Implement** —
   - `native/effect/*.lua : onApply` → call the discovered add-status CDO/method with
     `FName(self.nativeStatus)` on `target`; `onExpire` → the remove call. Fail-soft (`pcall`),
     mirroring `utils/items.give`'s CDO idiom.
   - `base/effect.lua : Effect:register` → publish the status row (if modded) + register the
     timing policy discovered above; remove the empty native overrides if the base suffices.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- add-status / remove-status native calls (02_reflection.txt):
--   add: /Script/Pal. ____________ : ____________ (FName, ...)
--   rem: /Script/Pal. ____________ : ____________
-- duration/interval driven by: game | framework
-- final code (native/effect/*.lua onApply/onExpire; base/effect.lua register):
--
```

---

## 7.3 Item use behavior — `native/item/potion.lua : onUse`

1. **Target** — `native/item/potion.lua : Potion:onUse(ctx)` (TODO: heal the user). Fires via
   the `item.use` SOURCE ([01 §1.5](01_life_events.md#15-itemuse--installitemsource-candidate-proven))
   once item instance tracking ([01 §1.9](01_life_events.md#19-item-instance-runtime-unblocks-1518-dispatch))
   resolves the class.
2. **Dump source** — `02_reflection.txt` (§8): observe what
   `PalItemUseProcessor:UseItemToCharacter_ServerInternal` does to the target — the native
   heal/stat call it invokes (grep the character/parameter component for `Heal`/`Recover`/`HP`).
3. **Extract** — the native heal call signature + which actor is the target (the `ctx.player`
   the source emits, or the `targetId` param).
4. **Implement** — in `Potion:onUse`, call the discovered heal method on the target (fail-soft
   CDO idiom, like `utils/items`). Amount can come from a `Potion.healAmount` field.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- native heal call (02_reflection.txt): /Script/Pal. ____________ : ____________
-- target actor source: ctx.player | targetId
-- final code (native/item/potion.lua : onUse):
--
```

---

## 7.4 Skill activation behavior — `native/skill/fireball.lua : onActivate`

1. **Target** — `native/skill/fireball.lua : Fireball:onActivate(owner, ctx)` (TODO: spawn the
   projectile). Skill id/element from [02 §2.4](02_content_ids.md#24-skillfireballlua--id--element).
2. **Dump source** — `02_reflection.txt` (§8): the projectile/skill-activation native call
   (grep the skill/character classes for `Skill`/`Projectile`/`Activate`/`Fire`); observe how a
   native active skill spawns its effect.
3. **Extract** — the activation/projectile-spawn call signature + how `owner` supplies origin/
   direction.
4. **Implement** — in `Fireball:onActivate`, call the discovered spawn/activate path with
   `owner` as source (fail-soft). If PalSchema drives skills off the DataTable row, `register()`
   (§7.1) may suffice and `onActivate` only adds framework-side effects.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- projectile/activation native call (02_reflection.txt): ____________
-- final code (native/skill/fireball.lua : onActivate):
--
```

---

## 7.5 Pal spawn/register behavior — `base/pal.lua`, `native/pal/boss.lua`

1. **Target** — `base/pal.lua : Pal:register` + `native/pal/boss.lua : Boss:register` (spawn
   pipeline). Ties to the spawn SOURCE ([01 §1.1](01_life_events.md#11-palspawned--installpalsource))
   and skeletal mesh ([05 §5.5](05_mesh_material.md#55-nativepalbosslua--render-skeletal)).
2. **Dump source** — `02_reflection.txt` + `04_live_objects.txt` (§8): how
   `SpawnMonsterForPlayer` places a pawn, its initial state, mesh-component wiring, HP/damage
   flow, and the capture-success path.
3. **Extract** — the spawn entry the pipeline should call + the pawn's initial-state wiring
   needed to drive `onSpawned`/`onDamaged`/`onDeath`/`onCaptured`.
4. **Implement** — `Pal:register` hands (id, mesh, skills, hooks) to the spawn layer; the
   `MonsterParameter` row is authored via PalSchema (§7.1). Remove the empty `Boss:register`
   override or call `self:super("register")`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- spawn entry + initial-state wiring (02_reflection.txt / 04_live_objects.txt): ____________
-- final code (base/pal.lua : Pal:register):
--
```

---

## 7.6 Behaviors to observe — §8 / §9.6

A reference checklist the recipes above draw on. Observe enough runtime behavior (in the
throwaway world, via probes) that each hook can be implemented non-trivially. No single code
file — each row feeds the sections noted.

1. **Target** — make the lifecycle hooks mean something.
2. **Dump source** — `02_reflection.txt` (the native calls) + live probing (§8).
3. **Extract** —
   - **Building work/production** — how a vanilla bench advances work, consumes inputs, yields
     outputs; the driving component + tick cadence → `Building:onTick/onPlace/onRightClick`,
     `item.craft` payload ([01 §1.7](01_life_events.md#17-itemcraft--installitemsource)).
   - **Container behavior** — slot count, `GetItemId().StaticId`/`GetStackCount`, valid-vs-empty
     slot rules (empty-fill can crash on load) → building storage hooks, `item.obtain/discard`.
   - **Pal AI / spawn** — §7.5.
   - **Item use effects** — §7.3.
   - **Status apply/remove** — §7.2 (and whether we drive timing or the game does).
   - **Sound lifecycle / volume / custom-file** — [03](03_audio.md).
4. **Implement** — feed each observation into the section noted; this doc's other sections are
   where the code lands.
5. **FILL**

```text
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- building work component + tick cadence: ____________
-- container slot rules (count / StaticId / empty-slot): ____________
-- status timing (native vs framework): ____________
```

---

## Coverage — this doc

| Checklist item | Section |
|---|---|
| §9.4 `base/item.lua : Item:register` | §7.1 |
| §9.4 `base/pal.lua : Pal:register` | §7.1, §7.5 |
| §9.4 `base/skill.lua : Skill:register` | §7.1 |
| §9.4 `base/effect.lua : Effect:register` | §7.2 |
| §9.2 `native/item/potion.lua` — `onUse` heal + `register()` | §7.3, §7.1 |
| §9.2 `native/skill/fireball.lua` — `onActivate` + `register()` | §7.4, §7.1 |
| §9.2 `native/pal/boss.lua` — `register()` | §7.5, §7.1 |
| §9.2 `native/effect/{burn,freeze,poison}.lua` — `onApply/onExpire` | §7.2 |
| §9.6 behaviors: building work / pal AI-spawn / item-use / status apply | §7.6 |
| §9.4 `base/building.lua : Building:register` | **DONE** (event-driven) |
