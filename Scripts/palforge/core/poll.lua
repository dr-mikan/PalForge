-- palforge/core/poll.lua — repeated work that rides the ONE heartbeat, instead of asking UE4SS
-- for a new timer every time something needs watching.
--
-- WHY THIS EXISTS, and it is not tidiness. Every LoopAsync creates a Lua registry reference that
-- UE4SS holds and releases, and every ExecuteInGameThread queues a body that carries another.
-- A watch that starts a loop, queues bodies from inside it, and then stops the loop while bodies
-- are still queued is a teardown race — and UE4SS's response to a reference it can no longer
-- resolve is not to skip it:
--
--   [UE4SS.EngineTick.LuaModImpl] Hook threw exception:
--     "[Lua::Registry::get_function_ref] Ref was not function", removing hook!
--
-- It removes the ENGINE TICK HOOK. Every keybind in this mod runs its body through
-- ExecuteInGameThread and that queue is drained by the tick, so the keys go dead while the game
-- carries on perfectly — which does not look like a keybind problem and costs a restart. That
-- happened three times in one afternoon, and twice it was diagnosed as something else first.
--
-- So: no watch creates a timer. core/event.lua arms exactly one LoopAsync for the whole session
-- and never stops it, and everything that needs to look at the world repeatedly registers a
-- function here for that tick to call. One reference exists, for the life of the process.
--
--   local poll = require("palforge.core.poll")
--   poll.every("spawn arrival", function(elapsed, ticks)
--       if found() then return true end        -- true means DONE: drop me
--       return elapsed >= 12                   -- give up on the CLOCK, never on a tick count
--   end)
--
-- The registry lives on _G so it survives a reload, exactly like the event bus does: the tick
-- closure that drains it was armed on the FIRST load and keeps running across every reload
-- after, so it has to find the current list rather than the one it captured.
local log = require("palforge.utils.log").scope("poll")

local M = {}

-- How many pollers may run at once. Each is a table entry and a function call per tick, so the
-- cost is nothing like a timer's — but a leak here would be invisible, and a bounded list that
-- refuses loudly is easier to trust than an unbounded one that never complains.
M.MAX = 16

local function state()
    local s = _G.__PalForgePollers
    if type(s) ~= "table" then s = { list = {}, n = 0 }; _G.__PalForgePollers = s end
    return s
end

---Register `fn` to be called on every heartbeat until it returns true.
---
---`fn(elapsed, ticks)` receives the seconds since registration and how many times it has been
---called. Returning true — or raising — removes it.
---
---⚠️ BOUND ON `elapsed`, NOT ON `ticks`. The heartbeat's body is queued through
---ExecuteInGameThread, so when the game thread is busy the bodies pile up and then drain in a
---burst: `ticks` advances as fast as the queue empties, not as fast as time passes. A live run
---spent a twenty-tick budget in ONE SECOND and reported a spawn missing that had not had time to
---arrive. `ticks` is honest about how many times you ran and is worth printing; it is not a
---clock. A poller that never returns true runs until the world does.
---@param name string   # shown in the log when it is dropped or refused
---@param fn fun(elapsed: number, ticks: integer): boolean
---@return boolean registered
function M.every(name, fn)
    if type(fn) ~= "function" then return false end
    local s = state()
    if s.n >= M.MAX then
        log.warn(string.format("%s: %d pollers already running, so this one is not started",
            name, s.n))
        return false
    end
    s.list[#s.list + 1] = { name = name, fn = fn, t0 = os.clock(), ticks = 0 }
    s.n = s.n + 1
    return true
end

---How many pollers are running.
---@return integer
function M.count() return state().n end

---Call every registered poller once, dropping the ones that finish. Called by the heartbeat in
---core/event.lua and by nothing else.
---
---A poller that RAISES is dropped and reported rather than left to raise once per tick forever:
---a broken watch should cost one log line, not a flooded log.
function M.drain()
    local s = state()
    if #s.list == 0 then return end
    local keep = {}
    for _, p in ipairs(s.list) do
        p.ticks = p.ticks + 1
        local ok, done = pcall(p.fn, os.clock() - p.t0, p.ticks)
        if not ok then
            log.err(string.format("%s raised and was dropped: %s", p.name, tostring(done)))
        elseif not done then
            keep[#keep + 1] = p
        end
    end
    s.list, s.n = keep, #keep
end

---Drop every poller. For a reload that wants to start clean; nothing else should need it.
---@return integer dropped
function M.clear()
    local s = state()
    local n = s.n
    s.list, s.n = {}, 0
    return n
end

return M
