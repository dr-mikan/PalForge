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
--   native.buildings.publish("WorkBench")   -- opt in to a LIVE definition; see below
--
-- WHAT THAT IS WORTH. The framework's constructors are now exercised by the framework itself
-- against 8299 real ids, and a pack author gets a discoverable, typed handle for everything
-- vanilla instead of having to know an id string. The named fields are completable in an editor:
-- tools/gen-types.lua walks these catalogs and writes them into Scripts/palforge/types.lua.
--
-- WHAT IT COSTS: nothing at load, and — since 2026-08-02 — nothing per read either. A named
-- field is a metatable __index over the module's own lazy get(id), so requiring a catalog builds
-- only its handful of CURATED definitions and the 8299 rows stay plain DATA until one is asked
-- for. On top of that, a catalog READ no longer REGISTERS anything: every accessor builds its
-- handle with `{ register = false }`, because registration is not inert for buildings — a
-- registered building definition makes core/event track and PERSIST every matching actor in the
-- world, so `native.buildings.Stone_Foundation` in a tooltip used to start writing a record for
-- every stone foundation in the player's base, and nothing prunes those records.
-- native/_catalog.lua states the gate in full and native/buildings.lua carries the measurement.
--
-- SO PUBLISHING IS A CALL YOU MAKE: `<catalog>.publish(id)` registers the very handle the
-- catalog already cached, which is what turns building tracking, :instances(), the persisted
-- record and X.get/X.get_all visibility back on — per id, attributably, and only when a pack
-- asks. native/_catalog.lua holds that machinery and the naming rule — including what happens
-- when two ids want the same field name — and test/cases/native.lua re-derives the whole
-- mapping on every run, and measures the registry across a read, to keep both honest.
local M = {}
M.buildings = require("palforge.native.buildings")
M.items     = require("palforge.native.items")
M.pals      = require("palforge.native.pals")
M.skills    = require("palforge.native.skills")
M.effects   = require("palforge.native.effects")
M.audio     = require("palforge.native.audio")
M.ui        = require("palforge.native.ui")
return M
