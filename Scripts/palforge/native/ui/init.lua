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

--   -- OR, declared rather than built: the tree is the element, and it finds its own host.
--   local VBox, Label, Button = UI.VBox, UI.Label, UI.Button
--   UI{ id = "pack:Panel", host = "game",
--       root = VBox{ Label{ text = "Supplies" }, Button{ text = "Take one", onClick = f } } }
--       :new{}:autoMount(nil, 2000)
--
-- `tree` is what turns that declaration into widgets. It is re-exported for the same reason
-- `widget` is — so it is reachable without an underscore module — but a pack should not need
-- it: api/ui calls it, and what a pack writes is the declaration.

local M = {}
M.widget    = require("palforge.native.ui._widget")
M.tree      = require("palforge.native.ui.tree")
-- WHERE "THE GAME JUST REBUILT A SCREEN" COMES FROM — the seam behind :autoRefresh's event half.
-- Re-exported for the same reason `keys` is: `refresh.report()` and `refresh.status()` answer
-- "is my panel riding the rebuild signal or only the poll", and a probe should be able to ask
-- without requiring an underscore module. A pack should not need it — what a pack writes is
-- :autoRefresh(ms), and UI.refreshDriver(ms) is the same answer as data.
--
-- ⚠️ REQUIRING IT ARMS NOTHING. The three hooks go in on the first refresh.arm(), which api/ui
-- calls from :autoRefresh / :autoMount and which defers itself to world.ready.
M.refresh   = require("palforge.native.ui.refresh")
-- The keyboard seam behind UI.Spec's `keys` / `buttons`. Re-exported for the same reason `tree`
-- is — so `keys.report()` is reachable from a probe or an autorun action without requiring an
-- underscore module — and for the same caveat: a pack should not need it. What a pack writes is
-- `keys = { "INS" }, onKeyPressed = function(self, ctx) ... end` on its own declaration.
M.keys      = require("palforge.native.ui.keys")
M.Button    = require("palforge.native.ui.button")
M.TitleMenu = require("palforge.native.ui.title_menu")
return M
