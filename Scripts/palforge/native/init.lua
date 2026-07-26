-- PalForge native: the game's OWN content, declared through PalForge's own constructors and
-- reachable BY NAME. One file per data domain; this aggregates them so downstream code can
-- `require("palforge.native")` and reach every catalog through one table.
--
--   local native = require("palforge.native")
--   native.buildings.PalBoxV2:instances()   -- one NAMED field per row the game declares
--   native.items.Arrow_Fire:give(20)
--   native.pals.BlueSkyDragon:spawn()
--   native.skills.Legend:kind()             --> "passive"
--   native.effects.Sleep:apply(target)
--   native.audio.AKE_BGM_Title:play()
--   native.items.get("Arrow_Fire")          -- the same handle, by id string
--
-- WHAT THAT IS WORTH. The framework's constructors are now exercised by the framework itself
-- against 8261 real ids, and a pack author gets a discoverable, typed handle for everything
-- vanilla instead of having to know an id string. The named fields are completable in an editor:
-- tools/gen-types.lua walks these catalogs and writes them into Scripts/palforge/types.lua.
--
-- WHAT IT COSTS: nothing at load. A named field is a metatable __index over the module's own
-- lazy get(id), so requiring a catalog registers only its handful of CURATED definitions and
-- the 8261 rows stay plain DATA until one is asked for. native/_catalog.lua holds that machinery
-- and the naming rule — including what happens when two ids want the same field name — and
-- test/cases/native.lua re-derives the whole mapping on every run to keep it honest.
local M = {}
M.buildings = require("palforge.native.buildings")
M.items     = require("palforge.native.items")
M.pals      = require("palforge.native.pals")
M.skills    = require("palforge.native.skills")
M.effects   = require("palforge.native.effects")
M.audio     = require("palforge.native.audio")
M.ui        = require("palforge.native.ui")
return M
