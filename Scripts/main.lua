-- PalForge — content framework for Palworld (UE4SS Lua mod). THIN entry point.
-- https://github.com/YUYA556223/PalForge
--
-- Runs as a UE4SS Lua mod. All logic lives under palforge.* (api/ core/ utils/ native/);
-- this file only:
--   1. bootstraps package.path so palforge.* resolves relative to this Scripts dir,
--   2. initializes the kernel (api + native catalogs + event system + dev tools),
--   3. publishes the downstream API on _G.PalForge for companion mods to reuse.
--
-- LAYERS
--   api/    the PUBLIC surface a content pack writes against. One module per domain
--           (Pal, Item, Building, Skill, Effect, Audio, UI, Player), all the same shape:
--           define{ id, ..., events = {...} } / get(id) / get_all(), returning a Handle
--           that carries that domain's actions. Requiring palforge.api also installs the
--           bare globals (Pal, Item, Building, ...) for terse pack code.
--   core/   the ENGINE. The kernel (registry), the one event system (event: channels +
--           native sources + dispatch + the full building runtime), and the Palworld
--           bridges api/ is built on (object_manager, spawn, mesh, sound, player, icons,
--           spatial, keyboard, unittests, vendor/rx). Not something a pack calls directly.
--   utils/  the generic TOOLBOX a pack does call directly: log, json, file, items.
--   native/ Palworld's own content as data catalogs + a few curated definitions.
--
-- Install layout:
--   ue4ss/Mods/PalForge/Scripts/main.lua        <- this file
--   ue4ss/Mods/PalForge/Scripts/palforge/*.lua  <- modules

-- Make require() resolve palforge.* relative to this Scripts dir.
local thisDir = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
package.path = thisDir .. "?.lua;" .. thisDir .. "?\\init.lua;" .. package.path

local env      = require("palforge.env")
local registry = require("palforge.core.registry")
local log      = require("palforge.utils.log").scope("main")

log.info("PalForge v" .. tostring(env.version) .. " starting (dev=" .. tostring(env.dev) .. ")")

-- Load + register everything (api, native catalogs, event system, dev tools if env.dev).
local ok, err = pcall(function() registry.initialize() end)
if not ok then
    log.err("initialize failed: " .. tostring(err))
else
    log.info("ready")
end

-- Public surface for downstream Lua mods (companion mods loaded into this VM reuse these).
-- `api` is what a content pack writes against; `utils` is the toolbox; `core` and `native`
-- are exposed for advanced use (custom event channels, catalog lookups).
_G.PalForge = {
    env = env,
    api = require("palforge.api"),
    utils = {
        log   = require("palforge.utils.log"),
        json  = require("palforge.utils.json"),
        file  = require("palforge.utils.file"),
        items = require("palforge.utils.items"),
    },
    core = {
        registry       = registry,
        event          = require("palforge.core.event"),
        object_manager = require("palforge.core.object_manager"),
        spawn          = require("palforge.core.spawn"),
        mesh           = require("palforge.core.mesh"),
        sound          = require("palforge.core.sound"),
        player         = require("palforge.core.player"),
        spatial        = require("palforge.core.spatial"),
        icons          = require("palforge.core.icons"),
    },
    native = require("palforge.native"),
}

return _G.PalForge
