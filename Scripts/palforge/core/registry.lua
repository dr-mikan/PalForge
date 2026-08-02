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
--
-- THE DEV GATE (step ④ below) is the difference between a framework and a cheat menu: env.dev
-- arms the nine dev keybinds, and one of them — F4 — unlocks every technology in the loaded
-- save. It defaults to FALSE in env.lua and only Scripts/palforge_dev.lua turns it on. Whatever
-- the gate decides, initialize() logs the pieces it loaded and the pieces it did not, by name.

local log            = require("palforge.utils.log").scope("registry")
local object_manager = require("palforge.core.object_manager")

local M = {}

-- require() a module that may legitimately be ABSENT from the tree, and say which of the three
-- things happened. A bare pcall(require, ...) reports a module that is not there and a module
-- with a syntax error identically, and those need different answers: one is an INCOMPLETE
-- INSTALL, the other is a defect that must be named in the log. The match is on the exact quoted
-- form Lua produces — "module 'x' not found" — so a MISSING DEPENDENCY of the module being
-- loaded is reported as the error it is, rather than as the module being absent.
--
-- This comment used to say "palforge.tests is gitignored and only tools/deploy.sh puts it in a
-- deployed tree". That was the defect, not the design: `Scripts/palforge/tests/` was listed in
-- .gitignore while this file requires it at boot and registers ps_catalog out of it, so a clone
-- had a boot path and a console command pointing at four files the repository did not carry.
-- The .gitignore line is gone and both directories ship. "absent" is now what a HAND-COPIED or
-- half-deployed tree looks like — the reason tools/deploy.sh stages and swaps rather than
-- deleting in place — and it is still worth telling apart from a syntax error.
local function requireState(module)
    local ok, err = pcall(require, module)
    if ok then return "loaded" end
    local msg = tostring(err)
    if msg:find("module '" .. module .. "' not found", 1, true) then return "absent" end
    return "error: " .. msg
end

-- The native content catalogs, in load order. Requiring one runs its CURATED definition
-- calls; the big CATALOG lists stay plain DATA and are materialized lazily by each module's
-- get(id), so startup never registers the thousands of row ids — and, since the publish gate
-- landed (F-8 / contract C2), a lazy get(id) does not register the ONE row it materialises
-- either. It builds with `{ register = false }` and stops there; <catalog>.publish(id) is the
-- opt-in that registers.
--
-- "which self-register" is true of the curated definitions in five of these six content
-- catalogs and NOT of native.buildings: its curated WorkBench / PalBoxV2 are declared with
-- `{ register = false }` too, because registering a building is not inert (core/event's scan
-- tracks and PERSISTS every matching actor already standing in the world, which is what made
-- an unconditional definition here a release blocker). Requiring native.buildings therefore
-- registers nothing at all; buildings.publish("WorkBench") is how a save opts in.
-- Everything that does register here registers under the pack id "palforge" (contract C3).
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
--
-- Returns whether the handler was installed, and the reason when it was not, so initialize()
-- can list it among the tooling that did and did not load. REGISTERING IS NOT REACHING: UE4SS
-- ships ConsoleEnabled, GuiConsoleEnabled and GuiConsoleVisible all at 0, so a command registers
-- perfectly well into a window that does not exist (core/autorun.lua's header records that as
-- one of the three input routes that failed in turn). autorun.txt is the route that needs no
-- console at all.
---@return boolean installed
---@return string? why  -- why not, when installed is false
local function installDevCatalogCommand()
    if type(RegisterConsoleCommandHandler) ~= "function" then
        return false, "RegisterConsoleCommandHandler unavailable in this UE4SS"
    end
    local ok, err = pcall(function()
        RegisterConsoleCommandHandler("ps_catalog", function()
            local run = function() pcall(function() require("palforge.tests.catalog").dump() end) end
            if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(run) else run() end
            return true
        end)
    end)
    if not ok then return false, tostring(err) end
    log.info("dev console command registered: ps_catalog (DataTable dumper, opt-in)")
    return true
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

    -- ④ dev-only tooling, gated on the single env.dev toggle.
    --
    -- WHY THIS GATE IS THE ONE THAT MATTERS, in one name: F4 UNLOCKS EVERY TECHNOLOGY
    -- (core/keyboard/functions/f4_unlock.lua) in the save that is loaded, in one keypress, with
    -- no confirmation. Until 2026-08-02 `dev = true` was the shipped default in env.lua, so a
    -- copy deployed as-is armed F4 for every player who installed it — along with F1, which
    -- spawns pals and hands out items, F9, which drops and re-requires every module, and the
    -- headless bundle, which ran at boot. env.lua now defaults dev OFF and nothing in the
    -- framework turns it on: only Scripts/palforge_dev.lua, which tools/deploy.sh writes in its
    -- default mode, which `--release` deletes, and which is gitignored so it cannot travel
    -- through the repository.
    --
    -- The lines below name WHAT LOADED AND WHAT DID NOT, one entry per piece. "The key does
    -- nothing" has been diagnosed from the wrong end repeatedly in this tree — a key that was
    -- never bound and a key that was bound and never arrived look identical from outside — and
    -- a log that lists neither leaves no way to tell them apart.
    if env.dev then
        local loaded, missing = {}, {}
        local function record(okay, what, why)
            if okay then loaded[#loaded + 1] = what else missing[#missing + 1] = what .. " (" .. why .. ")" end
        end

        local okKeys, keysErr = pcall(function()
            require("palforge.core.keyboard.base.registory").load()
        end)
        record(okKeys, "dev keybinds incl. F4 unlock-all-technologies", tostring(keysErr))

        local okCat, catWhy = installDevCatalogCommand()
        record(okCat, "ps_catalog console command", tostring(catWhy))

        -- Editing a file and pressing a key beats restarting the game. F9 drops every
        -- palforge.* module and runs this function again; the engine-facing hooks stay as
        -- they were armed on the first load. See core/reload.lua for what that does and
        -- does not replace.
        local okReload, reloadErr = pcall(function() require("palforge.core.reload").bind("F9") end)
        record(okReload, "F9 reload", tostring(reloadErr))

        -- The headless unit bundle runs NOW (it touches nothing but Lua tables). It lives in
        -- palforge/tests/, which SHIPS — this comment used to say the directory was gitignored
        -- and that a clone was expected not to have it, which was true of .gitignore and wrong
        -- of the code: the require below and the ps_catalog registration above are both boot
        -- paths into that directory, so a clone without it was an install with two dangling
        -- references and no way to tell. The .gitignore line was removed; "absent" now means an
        -- incomplete copy and is reported as such rather than swallowed. The same directory
        -- holds palforge.tests.catalog, which is what the ps_catalog console command dumps.
        local unitState = requireState("palforge.tests")
        if unitState == "loaded" then
            local ranOk = pcall(function()
                local tests = require("palforge.tests")
                if tests and type(tests.run) == "function" then tests.run() end
            end)
            record(ranOk, "headless unit bundle (palforge.tests)", "run failed")
        else
            record(false, "headless unit bundle (palforge.tests)", unitState)
        end

        -- The in-game API suite is only LOADED here — requiring it registers every case
        -- and binds F1. It spawns pals and hands out items, so it runs when you press the
        -- key, never at startup. See palforge/test/init.lua for how to bind your own.
        -- palforge/test/ is the module that binds F1: an install that omits
        -- Scripts/palforge/test/ has no test suite and no F1, with nothing else in the log to
        -- say why. (This line used to add "unlike palforge/tests/" — both directories are in
        -- the repository now; see the note on the bundle above.)
        local testState = requireState("palforge.test")
        record(testState == "loaded", "in-game API suite on F1 (palforge.test)", testState)

        -- env.debug is the SECOND switch and it is narrower: the measurements that cannot run
        -- without a running game live in palforge/test/hooks (contract C7), are declared rather
        -- than run, and each one still has to be asked for by name (pf_hooks / pf_hook <id>).
        -- The ones that WRITE into a save need env.debugHooks[id] = true on top of that.
        if env.debug then
            local hookState = requireState("palforge.test.hooks")
            record(hookState == "loaded", "game-required test hooks (palforge.test.hooks)", hookState)
        else
            missing[#missing + 1] = "game-required test hooks (env.debug = false)"
        end

        log.info("dev tooling loaded: " .. (#loaded > 0 and table.concat(loaded, ", ") or "nothing"))
        if #missing > 0 then
            log.info("dev tooling NOT loaded: " .. table.concat(missing, ", "))
        end
    else
        log.info("dev tooling NOT loaded (env.dev = false, the shipped default): no dev keybinds "
            .. "— including F4, unlock all technologies — no F1 API suite, no F9 reload, no "
            .. "ps_catalog dumper, no headless unit bundle and no test hooks. A dev session turns "
            .. "them on with Scripts/palforge_dev.lua (env.dev = true), which tools/deploy.sh "
            .. "writes in its default mode and deletes with --release.")
    end

    -- ⑤ fire the gameStart channel — subscribers (runtime wiring, tools) react
    pcall(function() event.emit("gameStart") end)

    log.info(string.format("initialized (dev=%s, debug=%s, %d class(es) registered)",
        tostring(env.dev), tostring(env.debug), registeredCount()))
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
