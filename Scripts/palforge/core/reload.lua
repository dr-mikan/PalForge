-- PalForge core.reload: swap the framework's Lua out from under a running game.
--
-- Editing a file and pressing a key beats restarting Palworld every time, so this exists.
-- It drops every palforge.* module from package.loaded and re-runs the kernel, which means a
-- change to an api module, a content pack, a test case or a probe is live in about a second.
--
--   PRESS F9 IN GAME  ->  reload every palforge.* module and re-register the content
--
-- WHAT CANNOT BE RELOADED, and why that is fine
--
-- UE4SS gives no way to take back three things once they exist, so a naive reload would
-- stack a second copy of each on every press:
--
--   RegisterHook      a native hook stays armed for the process. Re-arming it would run
--                     every handler twice, then three times.
--   LoopAsync         a loop keeps running. A second heartbeat would double every tick.
--   RegisterKeyBind   a bound key keeps its engine binding.
--
-- So the ENGINE-FACING layer is armed exactly once per session and the reload leaves it
-- alone: `_G.__PalForgeArmed` records that it happened and survives the module wipe, because
-- it lives on the global table rather than inside a module. core/event checks it before
-- arming anything, and the keybind registry already swaps a bound key's function in place
-- rather than binding again — which is what makes the keys keep working across a reload while
-- pointing at the NEW code.
--
-- Everything above that line — definitions, specs, handlers, the api surface, the test suite,
-- the probes, your own content — is plain Lua and is genuinely replaced.
--
-- WHAT A RELOAD DOES NOT UNDO. Definitions already registered in object_manager stay until
-- the reload re-registers over them, and live building instances keep the handler tables they
-- were created with. A structure placed before the reload runs the OLD onTick until it is
-- rediscovered. That is worth knowing when a hook seems not to have changed.
local log = require("palforge.utils.log").scope("reload")

local M = {}

-- Modules to keep across a reload. `env` holds the dev toggle a reload must not flip, and
-- utils/log is what reports the reload itself — dropping it mid-flight would lose the report.
M.KEEP = {
    ["palforge.env"] = true,
    ["palforge.utils.log"] = true,
    ["palforge.core.reload"] = true,
}

-- Has the engine-facing layer been armed this session? Lives on _G so it outlives the wipe.
---@return boolean
function M.armed()
    return _G.__PalForgeArmed == true
end

---Record that the engine-facing layer is armed. core/event calls this once.
function M.markArmed()
    _G.__PalForgeArmed = true
end

-- Every currently-loaded palforge.* module, except the ones we keep.
local function loadedModules()
    local names = {}
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:sub(1, 9) == "palforge." and not M.KEEP[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

---Drop every palforge.* module and load the framework again.
---
--=============================================================================
-- pending async work
--
-- WHY RELOADING MID-FLIGHT IS NOT SAFE. UE4SS holds a Lua registry reference to every
-- LoopAsync callback, and the engine-tick hook is what runs them. Clearing package.loaded out
-- from under a callback that is still scheduled can leave that reference pointing at something
-- that is no longer a function, and UE4SS's response is not to skip it:
--
--   [UE4SS.EngineTick.LuaModImpl] Hook threw exception:
--     "[Lua::Registry::get_function_ref] Ref was not function", removing hook!
--
-- It removes the TICK HOOK. Every keybind handler in this tree runs its body inside
-- ExecuteInGameThread, and that queue is drained by the tick — so the keys stop responding
-- while the game carries on perfectly well, which is a confusing thing to debug and costs a
-- restart. That happened once, from an F9 pressed a few seconds after an F1 that had left three
-- spawn watches running for up to twenty seconds each.
--
-- So: anything that schedules a repeating callback registers itself here, and reload REFUSES
-- while any are outstanding rather than risking the hook. The counter lives on _G so it
-- survives the reload it is guarding.
local function pending()
    local n = _G.__PalForgeAsync
    if type(n) ~= "number" then n = 0; _G.__PalForgeAsync = 0 end
    return n
end

---Call before scheduling a repeating async callback, and pair it with M.asyncDone.
function M.asyncBegin(what)
    _G.__PalForgeAsync = pending() + 1
    _G.__PalForgeAsyncWhat = what or _G.__PalForgeAsyncWhat
end

---Call when that callback's chain has finished, on every exit path including the give-up one.
function M.asyncDone()
    local n = pending() - 1
    _G.__PalForgeAsync = (n > 0) and n or 0
end

---How many repeating callbacks are outstanding right now.
---@return integer
function M.asyncPending() return pending() end

---Force the counter back to zero. The guard is a courtesy, not a lock: a chain that dies
---between begin and done would otherwise refuse every reload for the rest of the session, which
---is a far worse failure than the one being prevented. Bound to F9 with a modifier by the
---kernel, and printed in the refusal message so it is discoverable at the moment it is wanted.
function M.asyncReset()
    local n = pending()
    _G.__PalForgeAsync, _G.__PalForgeAsyncWhat = 0, nil
    log.warn(string.format("async counter reset from %d to 0 — reload is unblocked", n))
    return n
end

---Returns ok, plus how many modules were dropped. A failure leaves the OLD modules unloaded
---and the new ones partially loaded, so it says loudly what broke — fix the file and press
---the key again, which is the whole point of having it on a key.
---@return boolean ok, integer dropped
function M.reload()
    -- Refuse rather than break the tick hook. See the block above asyncBegin: a reload that
    -- lands while a LoopAsync chain is outstanding can cost the session its keybinds entirely.
    local waiting = M.asyncPending()
    if waiting > 0 then
        log.warn(string.format("reload REFUSED: %d async watch(es) still running%s. They are "
            .. "short — wait a few seconds and press the key again. Reloading now can leave "
            .. "UE4SS holding a dead callback reference, and its answer to that is to remove the "
            .. "engine tick hook, which is what runs every keybind in this mod.",
            waiting, _G.__PalForgeAsyncWhat and (" (" .. _G.__PalForgeAsyncWhat .. ")") or ""))
        log.warn("if it never clears, the counter is stuck: "
            .. "require('palforge.core.reload').asyncReset() unblocks it")
        return false, 0
    end

    local names = loadedModules()
    log.info(string.format("reloading %d module(s)", #names))

    for _, name in ipairs(names) do package.loaded[name] = nil end

    -- The api installs the bare globals (Pal, Item, ...); clear them so a module that
    -- disappeared from the api does not linger as a stale global.
    for _, g in ipairs({ "Pal", "Item", "Building", "Skill", "Effect", "Audio", "Mesh", "UI", "Player" }) do
        _G[g] = nil
    end

    local ok, err = pcall(function()
        local registry = require("palforge.core.registry")
        registry.initialize()
    end)

    if not ok then
        log.err("reload FAILED: " .. tostring(err))
        log.err("the framework is half-loaded - fix the file and press the key again")
        return false, #names
    end

    log.info(string.format("reloaded %d module(s) - engine hooks kept from the first load", #names))
    return true, #names
end

---Bind the reload to a key. Called by the kernel; `key` defaults to F9.
---@param key string?
---@return boolean bound
function M.bind(key)
    key = key or "F9"
    local reg = require("palforge.core.keyboard.base.registory")
    return reg.register(key, function()
        local ok, n = M.reload()
        pcall(function()
            local util   = StaticFindObject("/Script/Pal.Default__PalUtility")
            local player = FindFirstOf("PalPlayerCharacter")
            if util and util:IsValid() and player and player:IsValid() then
                util:SendSystemAnnounce(player, string.format(
                    "[PalForge] reload %s (%d modules)", ok and "ok" or "FAILED", n))
            end
        end)
    end, { desc = "reload every palforge.* module" })
end

return M
