-- PalForge core.registry: the KERNEL. initialize() is the single entry point main.lua
-- calls at GAME START (mod load). It installs the public api, loads the native content
-- catalogs (each definition self-registers into the central object registry as it is
-- defined), starts the unified event system, fires the "gameStart" channel, and — only in
-- dev — loads the dev keybinds, runs the test suites, and exposes the catalog dumper.
--
-- Responsibility split (frame):
--   * object_manager = WHAT exists   (every api definition call records its class there)
--   * registry       = WHEN it loads (this file: load order + the dev gate)
--   * event          = WHAT happens  (core/event.lua: channels, sources, dispatch)
-- Registration is NOT a separate step anymore: a definition call writes into object_manager
-- itself, so loading a catalog module IS registering its content — no walk over an
-- aggregator table, no per-class cls:register(). Going-live (indexing a build id, running
-- the placement/tick runtime) is driven off the event channels; core/event.lua owns the
-- full building runtime.
--
--   local registry = require("palforge.core.registry")
--   registry.initialize()          -- reads palforge.env for the dev gate
--   registry.registered().building -- { id -> class } snapshot, for inspection

local log            = require("palforge.utils.log").scope("registry")
local object_manager = require("palforge.core.object_manager")

local M = {}

-- The native content catalogs, in load order. Requiring one runs its CURATED definition
-- calls, which self-register; the big CATALOG lists stay plain DATA and are materialized
-- lazily by each module's get(id), so startup never registers the thousands of row ids.
local CATALOGS = {
    "palforge.native.buildings",
    "palforge.native.items",
    "palforge.native.pals",
    "palforge.native.skills",
    "palforge.native.effects",
    "palforge.native.audio",
    "palforge.native.ui",
}

-- How many classes are registered across every object type (post-load count).
local function registeredCount()
    local n = 0
    for _, otype in ipairs(object_manager.TYPES) do
        for _ in pairs(object_manager.all(otype)) do n = n + 1 end
    end
    return n
end

-- Dev-only: wire the catalog DataTable dumper to an opt-in console command
-- (`ps_catalog`). NEVER auto-run (the old auto-on-world-enter dump crashed on the
-- load storm). Throwaway world only.
local function installDevCatalogCommand()
    pcall(function()
        if type(RegisterConsoleCommandHandler) ~= "function" then return end
        RegisterConsoleCommandHandler("ps_catalog", function()
            local run = function() pcall(function() require("palforge.tests.catalog").dump() end) end
            if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(run) else run() end
            return true
        end)
        log.info("dev console command registered: ps_catalog (DataTable dumper, opt-in)")
    end)
end

-- Game-start entry (main.lua calls this once).
function M.initialize()
    local env   = require("palforge.env")
    local event = require("palforge.core.event")

    -- ① install the public api (this also publishes the Pal/Item/Building/... globals)
    local okApi, apiErr = pcall(require, "palforge.api")
    if not okApi then log.err("api load error: " .. tostring(apiErr)) end

    -- ② load the native catalogs — each definition self-registers into object_manager
    for _, module in ipairs(CATALOGS) do
        local ok, err = pcall(require, module)
        if not ok then log.err("native catalog '" .. module .. "' load error: " .. tostring(err)) end
    end

    -- ③ start the unified event system (bus + native sources + dispatch)
    event.start()

    -- ④ dev-only tooling, gated on the single env.dev toggle
    if env.dev then
        pcall(function() require("palforge.core.keyboard.base.registory").load() end)
        installDevCatalogCommand()
        -- Editing a file and pressing a key beats restarting the game. F9 drops every
        -- palforge.* module and runs this function again; the engine-facing hooks stay as
        -- they were armed on the first load. See core/reload.lua for what that does and
        -- does not replace.
        pcall(function() require("palforge.core.reload").bind("F9") end)
        -- the headless unit bundle runs NOW (it touches nothing but Lua tables)
        pcall(function()
            local tests = require("palforge.tests")
            if tests and type(tests.run) == "function" then tests.run() end
        end)
        -- the in-game API suite is only LOADED here — requiring it registers every case
        -- and binds F1. It spawns pals and hands out items, so it runs when you press the
        -- key, never at startup. See palforge/test/init.lua for how to bind your own.
        local okTest, testErr = pcall(require, "palforge.test")
        if not okTest then log.err("test suite load error: " .. tostring(testErr)) end
    end

    -- ⑤ fire the gameStart channel — subscribers (runtime wiring, tools) react
    pcall(function() event.emit("gameStart") end)

    log.info(string.format("initialized (dev=%s, %d class(es) registered)",
        tostring(env.dev), registeredCount()))
    return true
end

-- Inspection: a snapshot of every registered class, keyed by object type then id.
function M.registered()
    local out = {}
    for _, otype in ipairs(object_manager.TYPES) do
        out[otype] = object_manager.all(otype)
    end
    return out
end

return M
