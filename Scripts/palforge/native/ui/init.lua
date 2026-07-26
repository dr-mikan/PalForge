-- PalForge native.ui: the concrete UI elements, one per file, each defined through
-- api/ui (which registers it under the "ui" type in object_manager, so tooling and other
-- mods can look it up by id) — plus `widget`, the toolkit they are built with.
--
-- `widget` is re-exported here on purpose. UI.Handle:mount(root) needs a root, and the
-- ONLY things that produce one are widget.screen() (a viewport layer of our own),
-- widget.gameUIRoot() (the game's own in-game UI root canvas) and TitleMenu (which finds
-- the title screen itself). Without this line the sole route to a root was
-- require("palforge.native.ui._widget") — an underscore module that PalForge.native.ui
-- never handed you — so `mount(root)` had no reachable argument.
--
--   local ui     = require("palforge.native.ui")   -- or PalForge.native.ui
--   local screen = ui.widget.screen()              -- a panel of your own to host them
--   ui.Button:new{ label = "OK", onClick = function() end }:mount(screen.root)
--   ui.TitleMenu:new{ entries = { { label = "Mods", onClick = openMods } } }:autoMount(nil, 2000)
--   ui.widget.hide(screen)                         -- take the panel back off the viewport
--
--   -- into the game's OWN UI instead of a layer of ours; nil until a world is up, so the
--   -- same autoMount retry a title-screen element uses is what gets it in.
--   local host = ui.widget.gameUIRoot()
--   if host then ui.Button:new{ label = "Mods", onClick = openMods }:mount(host) end

local M = {}
M.widget    = require("palforge.native.ui._widget")
M.Button    = require("palforge.native.ui.button")
M.TitleMenu = require("palforge.native.ui.title_menu")
return M
