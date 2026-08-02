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
--
-- EVERY POLLER IS DECLARED TO THE RELOAD GUARD, and that is what makes F9 able to refuse
-- honestly. core/reload.lua has always documented asyncBegin/asyncDone as the reason a reload
-- waits for outstanding repeating work — and NOTHING called either, so asyncPending() answered 0
-- for the whole session and the refusal branch was unreachable. The two call sites were lost when
-- core/spawn.lua stopped arming its own LoopAsync chains and moved onto this heartbeat; the work
-- did not go away, it moved HERE, so this is where it is declared again. One begin per registered
-- poller, one done per poller that retires. The other caller is test/probes/watch.lua, which still
-- arms two RAW LoopAsync chains of its own (a 12 s readback and a 60 s window summary) and
-- declares each of them the same way — so between here and there, asyncPending() is exactly "how
-- much repeated work is outstanding", the question the F9 refusal asks.
--
-- WHAT THAT COSTS, said plainly, because a guard that surprises someone is worse than no guard:
-- while ANY poller is running, F9 refuses and names it. Most are seconds long (a spawn arrival
-- watch, an item read-back). One is not — native/ui/_widget's "ui input dead-man" runs for as
-- long as a panel holds the player's input — so an F9 pressed with a PalForge panel open is
-- refused, and the refusal names that poller. The escape hatch is already printed in the same
-- message: require('palforge.core.reload').asyncReset().
local log = require("palforge.utils.log").scope("poll")

local M = {}

-- The reload guard, required LAZILY, and the laziness is the point. This module is a primitive:
-- core/event, core/autorun and utils/items all load it early, while core/reload pulls the whole
-- kernel in through core/registry when it actually runs. A load-time require here would put that
-- edge into the require graph at startup and give the graph a cycle to find. Asked for at the
-- moment of use, it costs one table lookup and cannot participate in load order at all.
--
-- Fail-soft on purpose: if core/reload cannot be reached, the pollers still run. The guard is a
-- courtesy to F9, never a precondition for the work it is counting.
--
-- The call's first return value is handed back, because asyncBegin answers a TOKEN and asyncDone
-- takes it: token-less release drops the OLDEST outstanding chain, which is only correct while
-- everything finishes in the order it was armed, and this file's callers do not. A poller
-- registered while test/probes/watch's 60 s window summary is outstanding would otherwise release
-- WATCH's chain when it retired, leaving its own entry standing until the 180 s stale cap dropped
-- it — F9 refused for three minutes, naming a poller that finished long ago.
local function guard(fnName, ...)
    local ok, reload = pcall(require, "palforge.core.reload")
    if not (ok and type(reload) == "table" and type(reload[fnName]) == "function") then
        return nil
    end
    local called, res = pcall(reload[fnName], ...)
    if called then return res end
    return nil
end

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
---Registering also CLAIMS THE RELOAD GUARD in `name`'s name, and the claim is released the moment
---the poller retires. So a poller that never returns true keeps F9 refusing, and the refusal says
---which one — which is the intended behaviour, not a side effect: a reload landing on outstanding
---repeated work is what removes UE4SS's engine tick hook.
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
    -- Declared to the reload guard BEFORE the entry exists, so there is no window in which the
    -- poller is drainable and uncounted. `guarded` is what pairs the done with this begin exactly
    -- once, whichever way the poller leaves (returned true, raised, or was cleared), and
    -- `guardToken` is what makes that release name THIS poller rather than the oldest chain
    -- outstanding at the time (see guard() above). A nil token — an older core/reload, or one
    -- that could not be reached at all — falls back to the oldest-first form, which is what
    -- happened before and is still balanced.
    local token = guard("asyncBegin", name)
    s.list[#s.list + 1] = { name = name, fn = fn, t0 = os.clock(), ticks = 0,
                            guarded = true, guardToken = token }
    s.n = s.n + 1
    return true
end

-- Release one poller's claim on the reload guard. Called on every exit path there is.
local function release(p)
    if p and p.guarded then
        p.guarded = false
        guard("asyncDone", p.guardToken)
    end
end

---How many pollers are running.
---@return integer
function M.count() return state().n end

---Call every registered poller once, dropping the ones that finish. Called by the heartbeat in
---core/event.lua and by nothing else.
---
---A poller that RAISES is dropped and reported rather than left to raise once per tick forever:
---a broken watch should cost one log line, not a flooded log.
---
---Both drop paths release the reload guard, and a raise is exactly why that release lives here
---rather than in the poller: a watch that dies half way through is the case core/reload's
---asyncReset was written for, and a guard that leaks a count on every raise would refuse F9 for
---the rest of the session over a watch that is long gone.
function M.drain()
    local s = state()
    if #s.list == 0 then return end
    local keep = {}
    for _, p in ipairs(s.list) do
        p.ticks = p.ticks + 1
        local ok, done = pcall(p.fn, os.clock() - p.t0, p.ticks)
        if not ok then
            log.err(string.format("%s raised and was dropped: %s", p.name, tostring(done)))
            release(p)
        elseif not done then
            keep[#keep + 1] = p
        else
            release(p)
        end
    end
    s.list, s.n = keep, #keep
end

---Drop every poller. For a reload that wants to start clean; nothing else should need it.
---
---Every dropped poller releases its claim on the reload guard, so clearing the list also clears
---what F9 would have refused over. That is the honest pairing: the work really is gone.
---@return integer dropped
function M.clear()
    local s = state()
    local n = s.n
    for _, p in ipairs(s.list) do release(p) end
    s.list, s.n = {}, 0
    return n
end

return M
