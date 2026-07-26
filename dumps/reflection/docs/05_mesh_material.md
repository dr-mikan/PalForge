# 05 — Mesh / material / model & placement

Fills **`dump_targets.md` §9.5** (mesh backends) and the mesh/render part of **§9.4**
(`base/building.lua : mesh/render`, `base/pal.lua : render`, and the two native `render()`
stubs), using the plan in **§6**.

`utils/mesh/init.lua` is the facade; it dispatches by `spec.kind` to a backend:
`procedural` (OBJ → `ProceduralMeshComponent`, **implemented**), `static` (**TODO stub**),
`skeletal` (**TODO stub**). Buildings currently render via the procedural backend (a
decorative stand-in); pals need a real skeletal mesh. The proven procedural chain
(`AddComponentByClass(ProceduralMeshComponent)` → `CreateMeshSection` → **mandatory**
`SetWorldScale3D`, collision **off**) needs no dump.

**Where to look:** `02_reflection.txt` (mesh-component + material property fields on the
character/build classes) and `04_live_objects.txt` (real placed-actor classes to inspect for
their `StaticMesh`/`SkeletalMesh` asset paths). Material candidates are probed in-game with
`utils/mesh/procedural.lua : Procedural.probeMaterials()`.

---

## 5.1 `utils/mesh/procedural.lua` — base material + param names

1. **Target** — `utils/mesh/procedural.lua`: the `BASE_MATERIAL_CANDIDATES` list (line ~128)
   and the `COLOR_PARAMS` / `TEXTURE_PARAMS` name lists (lines ~37–38). Element-0 of a fresh
   ProceduralMeshComponent has no tint param, so color/texture may not visibly apply until a
   real parent material with the right param names is supplied.
2. **Dump source** — in-game, not a file: call `Procedural.probeMaterials()` (logs which
   candidates are **loaded** — `MATPROBE FOUND …`). Cross-check by enumerating
   `FindAllOf("Material")` / `FindAllOf("MaterialInstance")` for one with a `Color`/`BaseColor`
   vector param. `02_reflection.txt` can show material property names if a material class is in
   the candidate set.
3. **Extract** — (a) a base material object path that is **loaded** and has a usable color/
   texture param; (b) the exact param NAME(s) that visibly tint when set via
   `SetVectorParameterValue(FName, …)` (probe each candidate name and watch).
4. **Implement** — put the confirmed base material at the FRONT of `BASE_MATERIAL_CANDIDATES`,
   and reduce `COLOR_PARAMS` / `TEXTURE_PARAMS` to the confirmed working name(s) (keep the
   others as fallbacks). No structural change — just the data lists.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- loaded base material with a color param (probeMaterials / FindAllOf): ____________
-- working color param name(s): ____________   texture param name(s): ____________
-- final code (utils/mesh/procedural.lua):
--   BASE_MATERIAL_CANDIDATES[1] = "____________"
--   COLOR_PARAMS   = { "____________" }   TEXTURE_PARAMS = { "____________" }
```

---

## 5.2 `utils/mesh/static.lua` — `attach`

1. **Target** — `utils/mesh/static.lua : StaticMesh:attach(actor, spec)` — a TODO stub that
   returns `false`. It should create a `UStaticMeshComponent`, load `spec.asset` (a
   `UStaticMesh` object path), `SetStaticMesh`, then attach + scale.
2. **Dump source** — `04_live_objects.txt`: inspect a placed `PalBuildObject`'s
   `StaticMeshComponent.StaticMesh` object path; enumerate `FindAllOf("StaticMesh")`.
   `02_reflection.txt` → confirm the `SetStaticMesh` signature on `UStaticMeshComponent`.
3. **Extract** — a real `UStaticMesh` object path for a placeable, and the component-add +
   `SetStaticMesh` call shape (mirror the procedural `AddComponentByClass` idiom).
4. **Implement** — in `static.lua`, replace the TODO: find the `UStaticMeshComponent` class,
   `actor:AddComponentByClass(...)`, `LoadObject`/`StaticFindObject(spec.asset)` → `SetStaticMesh`,
   then `SetWorldScale3D` (same mandatory-scale trap as procedural) and relative offset. Keep
   collision off (a collider intercepts the build placement raycast — documented in §6).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- UStaticMesh asset path (04_live_objects.txt / FindAllOf): ____________
-- SetStaticMesh signature (02_reflection.txt): ____________
-- final code (utils/mesh/static.lua : attach):
--
```

---

## 5.3 `utils/mesh/skeletal.lua` — `attach`

1. **Target** — `utils/mesh/skeletal.lua : SkeletalMesh:attach(actor, spec)` — a TODO stub
   returning `false`. It should resolve `spec.asset` (a `USkeletalMesh` object path) and set it
   on the pawn's mesh component (or add a `USkeletalMeshComponent`).
2. **Dump source** — `04_live_objects.txt` + `02_reflection.txt`: inspect a live
   `PalPlayerCharacter` / pal pawn — which mesh component holds `SkeletalMesh`, that component's
   `USkeletalMesh` asset path, and the `SetSkeletalMesh` / `SetSkeletalMeshAsset` signature.
3. **Extract** — the pawn's skeletal-mesh component wiring, a `USkeletalMesh` asset path, and
   the correct swap call.
4. **Implement** — in `skeletal.lua`, replace the TODO: get the pawn's mesh component (or add
   a `USkeletalMeshComponent`), resolve `spec.asset`, call the discovered
   `SetSkeletalMesh(...)`, then scale/offset. This is the real creature-mesh path behind
   `base/pal.lua : render` (§5.5).
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- pawn mesh component + USkeletalMesh asset path: ____________ / ____________
-- SetSkeletalMesh(...) signature: ____________
-- final code (utils/mesh/skeletal.lua : attach):
--
```

---

## 5.4 `base/building.lua : mesh/render` + `native/building/bench.lua : render`

1. **Target** — decide static-vs-procedural for buildings. `base/building.lua : Building:mesh`
   returns `self.meshSpec` and `Building:render` passes `m.kind` through to the mesh facade
   (nil → procedural). `native/building/bench.lua : Bench:render` is an **empty TODO override**
   that currently shadows the working base `render`.
2. **Dump source** — `04_live_objects.txt` (§5.2) for a `UStaticMesh` path if the Bench should
   use a real static mesh; otherwise ship a procedural OBJ (no dump — provide `model`).
3. **Extract** — either a `UStaticMesh` asset path (→ `kind = "static"`, §5.2) or an OBJ path
   (procedural default).
4. **Implement** — choose one:
   - **static:** set `Bench.meshSpec = { kind = "static", asset = "<UStaticMesh path>", scale = 1 }`
     and **delete** the empty `Bench:render` override so the base `render` runs (or have it call
     `self:super("render")`). Requires §5.2 done.
   - **procedural:** set `Bench.meshSpec = { model = "<obj path>", scale = ..., color = {...} }`
     and delete the empty override (base `render` handles it). Note: `core/event.lua`'s deferred
     scan already calls `inst:render()` on a later scan once the placed actor settles
     (`_meshPending`), so building mesh attach timing is handled.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- chosen kind: static|procedural   asset/model: ____________
-- final code (native/building/bench.lua): remove empty render override; set:
--   Bench.meshSpec = { ____________ }
```

---

## 5.5 `native/pal/boss.lua : render` (skeletal)

1. **Target** — `base/pal.lua : Pal:render` builds a **procedural** stand-in from an OBJ; the
   real path is a skeletal swap (§5.3). `native/pal/boss.lua : Boss:render` is an empty TODO
   override shadowing the base.
2. **Dump source** — §5.3 (the pawn's skeletal component + a `USkeletalMesh` asset path).
   `04_live_objects.txt` for the live pal pawn class; observe how `SpawnMonsterForPlayer`
   places a pawn and wires its mesh (§8 behaviors).
3. **Extract** — a `USkeletalMesh` asset path + confirmed swap timing (needs a valid
   `self.actor` pawn).
4. **Implement** — set `Boss.meshSpec = { kind = "skeletal", asset = "<USkeletalMesh path>",
   scale = 1 }` and **delete** the empty `Boss:render` override so the base `render` dispatches
   to the (now-implemented, §5.3) skeletal backend. Requires §5.3.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- USkeletalMesh asset path: ____________
-- final code (native/pal/boss.lua): remove empty render override; set:
--   Boss.meshSpec = { kind = "skeletal", asset = "____________" }
```

---

## 5.6 Placement / grid conventions (confirm, low-risk)

1. **Target** — `utils/spatial.lua : GRID_CM = 100` (1 m) and per-building `gridCm`
   (`base/building.lua : Building.gridCm`, `native/building/bench.lua : Bench.gridCm = 100`);
   plus the settle-timing sentinel in `core/event.lua` (`actorPos` treats `(0,0,0)` as
   not-ready; `_meshPending` defers mesh attach).
2. **Dump source** — observed in-game: real build snap spacing (confirm the 100 cm quantum +
   rotation handling), and how many scans until `pos` stabilizes for the mesh-attach defer.
3. **Extract** — the confirmed grid quantum + the scan count to settle.
4. **Implement** — adjust `spatial.GRID_CM` / per-building `gridCm` only if the observed snap
   differs from 100 cm; the `_meshPending` defer already handles settle timing (no code unless
   the observed settle needs more scans).
5. **FILL**

```text
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed snap quantum (cm): ____________   scans-until-settle: ____________
-- (matches 100cm / current defer -> verified; else adjust GRID_CM / gridCm)
```

---

## Coverage — this doc

| Checklist item | Section |
|---|---|
| §9.5 `utils/mesh/procedural.lua` — base material + param names | §5.1 |
| §9.5 `utils/mesh/static.lua : attach` | §5.2 |
| §9.5 `utils/mesh/skeletal.lua : attach` | §5.3 |
| §9.4 `base/building.lua : Building:mesh/render` (static-vs-procedural) | §5.4 |
| §9.2 `native/building/bench.lua` — `render()` | §5.4 |
| §9.4 `base/pal.lua : Pal:render` (real skeletal) | §5.5 |
| §9.2 `native/pal/boss.lua` — `render()` skeletal | §5.5 |
| §6 placement/grid conventions (supporting) | §5.6 |
