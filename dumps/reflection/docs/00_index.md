# PalSmith — Dump → Implementation "Solution" Docs (`dump/docs/`)

These docs are the **bridge** from a completed in-game dump to the concrete code change.
For every `-- TODO(dump)` / `-- TODO:` seam catalogued in
[`../dump_targets.md`](../dump_targets.md) **§9**, there is a recipe here that says: which
dump output file to read, exactly what to extract from it, which Lua file/line-area to
change, and the code to write — with a labelled **FILL** block a human pastes the observed
value + resulting code into once the dump has run.

> **These recipes describe HOW.** They contain **no** invented Palworld ids / asset paths /
> native-event names — only names already proven in the codebase (see the `dump_targets.md`
> Appendix). Every discovered value stays a blank FILL block until `ps_dump` has actually run.

## How to use

1. **Run the dump** in a throwaway world, *after* it has fully loaded (open the Build menu /
   Inventory / Paldeck first so their widget trees are captured):
   - UE4SS Lua console: `dofile("<...>/mods/PalSmith/dump/dump.lua")`
   - or the console command it registers: **`ps_dump`**
   - (dev catalog alternative for DataTables only: **`ps_catalog`** → `tests/catalog.lua`)
2. **Read the output files** it writes into `dump/` (mapping repeated in each doc):

   | Output file | Contents | Feeds |
   |---|---|---|
   | `01_datatables.txt` | every loaded `UDataTable` → its row FNames | content ids (item/build/pal/skill/status/tech), SoundIDs |
   | `02_reflection.txt` | candidate classes → their `UFunction`s + properties | event hooks (pal/item life events), icon/mesh fields |
   | `03_widgets.txt` | live widget trees + all live `UserWidget`s | native UI paths (title/HUD/build/inventory) |
   | `04_live_objects.txt` | real classes of placed objects | build ids (`BP_BuildObject_<Id>_C`), live pals |

3. **Open the matching doc** below, find the item, and **fill** it.

## The docs

| Doc | Covers | `dump_targets.md` §9 range |
|---|---|---|
| [`01_life_events.md`](01_life_events.md) | pal + item event SOURCEs in `core/event.lua` | §9.1 |
| [`02_content_ids.md`](02_content_ids.md) | building/item/pal/skill/effect ids + data-table & tech-tree structure | §9.2 (ids), §9.6 |
| [`03_audio.md`](03_audio.md) | BGM/SE SoundIDs, `setVolume`, custom-file playback | §9.2 (audio), §9.4 (setVolume), §9.5 (file) |
| [`04_native_ui.md`](04_native_ui.md) | build-menu/inventory/HUD widget paths, title/button, UI update driver | §9.3, §9.4 (`_installUpdateDriver`) |
| [`05_mesh_material.md`](05_mesh_material.md) | procedural/static/skeletal mesh + building/pal `render()` | §9.5 (mesh), §9.4 (mesh/render) |
| [`06_icons.md`](06_icons.md) | `iconOf` resolve for item/pal/skill/effect | §9.4 (icons) |
| [`07_registers.md`](07_registers.md) | `register()` seams + gameplay behaviors (heal/status/skill/spawn) | §9.4 (register), §9.6 (behaviors) |

## FILL block convention

Every item ends with a fenced block like this — **empty now** (the dump has not run):

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- observed:
--   <the exact value(s) read from the dump output file>
-- final code (paste into the target lua file):
--   <the line(s) after substituting the value>
```

## Coverage

Every open `dump_targets.md` §9 checkbox maps to at least one recipe. See the **Coverage
map** at the bottom of each doc; the master audit is in
[`01_life_events.md`](01_life_events.md#coverage-master-audit). Items already marked `[x]` in
§9 (world/building/tick SOURCEs, verified title `M.PATHS`, event-driven `Building:register`)
are noted as **DONE** where they appear and need no dump.
