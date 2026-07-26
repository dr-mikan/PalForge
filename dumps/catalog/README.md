# PalSmith Catalog

A community reference of Palworld's data, extracted for modders. Two sources:

## Static (checked in) — from the UE4SS CXXHeaderDump

Class names and key API surfaces, extracted offline from `Pal.hpp`:

- `classes.json` — machine-readable index (map-object models, UI widget classes,
  container classes) + `keyFindings` (the exact accessors PalSmith uses).
- `mapobject_models.txt` — every `UPalMapObject*Model` (the "machine" types:
  storage, product, convert, energy, dispenser, chest, …).
- `ui_widget_classes.txt` — every `UPalUI*` widget class (for native UI reuse).
- `container_classes.txt` — inventory/container/storage classes.

These are class NAMES. The concrete content ids (item ids like `Wood`, build ids
like the chest's) are DataTable **row names**, which live in the game data, not
the header — dump those in-game (below).

## Runtime (generated in-game) — DataTable row dump

PalSmith ships a catalog dumper. It runs **automatically ~15s after a world is
ready** (no keypress); you can also re-run it with `PalSmith.dumpCatalog()`. It
enumerates every loaded `UDataTable` (row names via `GetRowNames()`, falling back
to `UDataTableFunctionLibrary:GetDataTableRowNames`) and writes:

- `<Mods>/PalSmith/catalog/datatables/<TableName>.json` — `{ table, count, rows[] }`
  per table (e.g. `DT_ItemDataTable.json` = all item static ids,
  `DT_BuildObjectDataTable.json` = all build-object ids).
- `<Mods>/PalSmith/catalog/index.json` — table→rowcount, plus `friendly`
  shortcuts (item/build/pal/tech tables auto-identified).

Copy the generated `datatables/` here to contribute the id lists to the repo.

## Why PalSmith catalogs

A thriving mod community needs a shared, discoverable map of what exists — item
ids, build ids, pal ids, UI widgets, machine types. PalSmith makes that a
first-class, regenerable artifact so pack authors don't reverse-engineer ids by
hand, and so tooling (editor autocomplete, validators) can build on it.
