-- PalForge native.ui: the concrete UI elements, one per file, each defined through
-- api/ui (which registers it under the "ui" type in object_manager, so tooling and other
-- mods can look it up by id). This module just aggregates them.
--
--   local ui     = require("palforge.native.ui")
--   local widget = require("palforge.native.ui._widget")  -- the toolkit they build with
--   local screen = widget.screen()                        -- a panel of your own to host them
--   ui.Button:new{ label = "OK", onClick = function() end }:mount(screen.root)
--   ui.TitleMenu:new{ entries = { { label = "Mods", onClick = openMods } } }:mount()

local M = {}
M.Button    = require("palforge.native.ui.button")
M.TitleMenu = require("palforge.native.ui.title_menu")
return M
