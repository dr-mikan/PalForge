-- PalForge native: aggregates the per-domain native content catalogs (HYBRID design:
-- one file per data domain) so downstream code can `require("palforge.native")` and
-- reach every catalog + curated class through one table. The kernel
-- (palforge.core.registry) registers only the CURATED classes at game start; the big
-- CATALOG lists are DATA and are not bulk-registered.
--
--   local native = require("palforge.native")
--   native.buildings.WorkBench    native.items.get("Arrow_Fire")    native.audio.MainTheme
local M = {}
M.buildings = require("palforge.native.buildings")
M.items     = require("palforge.native.items")
M.pals      = require("palforge.native.pals")
M.skills    = require("palforge.native.skills")
M.effects   = require("palforge.native.effects")
M.audio     = require("palforge.native.audio")
M.ui        = require("palforge.native.ui")
return M
