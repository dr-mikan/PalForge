-- palforge/core/autorun.lua — run named actions from a FILE, with no key and no console.
--
-- WHY THIS EXISTS. Three ways of asking the game to do something have failed in turn, and each
-- time the work was fine and only the way in was missing:
--
--   F7            Palworld's own volume key. The bind succeeded and the key never arrived, so
--                 from the log it looked exactly like a probe that ran and found nothing.
--   F8, then keys UE4SS binds happily to whatever the game has already claimed. There is no way
--                 to ask whether a key is free.
--   the console   UE4SS ships with ConsoleEnabled, GuiConsoleEnabled and GuiConsoleVisible all
--                 0. A command registers perfectly well into a window that does not exist.
--
-- So this route asks for no input at all. Put a line in a text file, load a save, and it runs.
-- The file is written by whoever is driving the session — a person, or tools/deploy.sh — and
-- read once per world.
--
--   Scripts/palforge/autorun.txt
--     # comments and blank lines are ignored
--     pf_spawn          -- run as soon as the world is ready
--     12 pf_teach       -- run 12 seconds after the world is ready
--
-- The delay matters more than it looks: a pal takes four to eight seconds to arrive, so an
-- action that needs one nearby cannot run in the same breath as the spawn that makes it.
--
-- THIS FILE HOLDS NO TABLE OF ITS OWN. Every name is looked up in require("palforge.test").ACTIONS
-- and a name that is not there is reported and skipped — so a command registered anywhere in the
-- test surface is runnable from here the moment it exists, with NO change in this file. The
-- game-required test hooks (C7) arrive exactly that way: `pf_hooks`, `pf_hooks_all` and one
-- generated `pf_hook_<id_with_underscores>` per declared hook are ordinary ACTIONS entries and
-- resolve through the same lookup `pf_tests` does.
--
-- ⚠️ A LINE IS `[delay] name` AND CARRIES NO ARGUMENT. That is deliberate and it is what the hook
-- runner is built against: the console spelling `pf_hook <id>` takes an id, so test/hooks/init.lua
-- generates a separate ACTIONS name per hook for this file (M.actionName) rather than this parser
-- learning to pass words through. One less thing a text file on disk can say to the game.
--
-- SAFETY. Only names already in palforge.test's ACTIONS table can be run — this reads a list of
-- names, never code, so a stray file cannot execute anything the mod does not already do on a
-- keypress. A hook that WRITES to a save carries its own second gate on top of that
-- (env.debugHooks[id]), which this file neither knows about nor can bypass. Each entry runs at
-- most once per world load. A missing file is the normal case and says nothing.
local log  = require("palforge.utils.log").scope("autorun")
local poll = require("palforge.core.poll")

local M = {}

M.FILE = "autorun.txt"

-- Where this file is on disk, so the queue can sit beside it. UE4SS's working directory is not
-- something to rely on — debug.getinfo gives the path Lua actually loaded us from, which is the
-- deployed Scripts/palforge/core/ whatever the CWD happens to be.
local function scriptsDir()
    local src = debug.getinfo(1, "S").source or ""
    local path = src:match("^@(.*)$")
    if not path then return nil end
    return (path:gsub("[\\/]core[\\/]autorun%.lua$", ""))
end

---Parse the queue file into { delay, name } entries. Returns an empty list when there is none.
local function readQueue()
    local dir = scriptsDir()
    if not dir then return {} end
    local path = dir .. "/" .. M.FILE
    local fh = io.open(path, "r")
    if not fh then
        path = dir .. "\\" .. M.FILE
        fh = io.open(path, "r")
    end
    if not fh then return {} end

    local out = {}
    for line in fh:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") and not line:match("^%-%-") then
            -- A leading integer is a DELAY, not a command name — "12 pf_teach". Anything after
            -- the name is ignored: a line is a name, never a call with arguments (see the header
            -- for why the hook runner generates one name per hook instead).
            local delay, name = line:match("^(%d+)%s+(%S+)$")
            if name then
                out[#out + 1] = { delay = tonumber(delay), name = name }
            else
                out[#out + 1] = { delay = 0, name = line:match("^(%S+)") }
            end
        end
    end
    fh:close()
    log.info(string.format("%s: %d entr%s queued from %s",
        M.FILE, #out, #out == 1 and "y" or "ies", path))
    return out
end

---Run the queue. Called once per world.ready; safe to call again (each world load re-reads the
---file, which is what makes an edit take effect without restarting the game).
function M.run()
    local actions
    local ok = pcall(function() actions = require("palforge.test").ACTIONS end)
    if not (ok and type(actions) == "table") then return end

    for _, entry in ipairs(readQueue()) do
        local run = actions[entry.name]
        if not run then
            log.warn(string.format("%s: no action named %q — the names are the pf_* commands",
                M.FILE, tostring(entry.name)))
        elseif entry.delay <= 0 then
            log.info("running " .. entry.name)
            local okr, err = pcall(run)
            if not okr then log.err(entry.name .. " failed: " .. tostring(err)) end
        else
            -- Rides the shared heartbeat; this file creates no timer of its own. See core/poll.
            local fired = false
            poll.every("autorun " .. entry.name, function(elapsed)
                if fired or elapsed < entry.delay then return fired end
                fired = true
                log.info(string.format("running %s (%.0f s after the world was ready)",
                    entry.name, elapsed))
                local okr, err = pcall(run)
                if not okr then log.err(entry.name .. " failed: " .. tostring(err)) end
                return true
            end)
        end
    end
end

return M
