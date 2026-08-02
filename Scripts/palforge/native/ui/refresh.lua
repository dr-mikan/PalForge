-- PalForge native.ui.refresh — THE UI-REBUILD SIGNAL. Where "the game just built or tore down a
-- screen" comes from, and the engine seam behind UI.Handle:autoRefresh's event half.
--
-- THE SPLIT IS THE SAME ONE AS EVERYWHERE ELSE UNDER native/ui. api/ui.lua decides WHEN an
-- element refreshes — pure Lua, provable headlessly; this file decides WHETHER A REBUILD CAN BE
-- HEARD AT ALL, which is entirely a question about UE4SS and about what Palworld actually calls.
-- It is the exact counterpart of native/ui/keys.lua, one channel over.
--
--=============================================================================
-- ⚠️ THIS FILE EXISTS BECAUSE A CONCLUSION OUTRAN ITS EVIDENCE, AND THE MEASUREMENT OVERTURNED IT
--=============================================================================
--
-- Earlier on 2026-08-02, `ui-update-event` was closed with "POLLING IS THE ANSWER": api/ui.lua's
-- autoRefresh said no rebuild UFunction had ever been observed, UI.refreshDriver returned
-- kind = "poll", event = nil, and a once-per-session log line said so. That rested on a 21:57 run
-- where 2 of 14 candidates were armed and both stayed silent — and both of those two
-- (`ShouldShowGlobalPalStorageNewMark`, `RequestUpdatePlayerStatusPoint`) were substring false
-- positives that have nothing to do with rebuilding a screen.
--
-- The 23:04 run of test/hooks/ui-update-event, with 21 NAMED candidates armed by path, measured
-- this while the operator opened and closed the inventory and the build menu:
--
--     armed = 21 of 21 candidate(s); 0 refused
--     fired at least once = 3        armed and SILENT = 18
--
--     FIRSTFIRE /Script/CommonUI.CommonActivatableWidget:ActivateWidget   at +22.4 s
--     FIRSTFIRE /Script/Pal.PalHUDService:Push                            at +25.6 s
--     FIRSTFIRE /Script/Pal.PalHUDService:Close                           at +27.8 s
--
-- (UE4SS.log, build stamp 2026-08-02 23:02:07; the +30 s verdict block recorded 1 call each.)
--
-- So there ARE catchable UFunctions that fire when Palworld builds and tears down a screen, and
-- the earlier text was false. These three are what this file arms.
--
-- ⚠️ AND THE SAME MISTAKE IS NOT MADE IN THE OTHER DIRECTION. Three functions firing is not proof
-- that riding them is sufficient:
--
--   * THE 18 SILENT ONES ARE NOT PROVEN DEAD. The operator opened TWO screens, not eighteen.
--     `PalHUDService:ShowCommonUI` (popups), `RemoveHUD` (return to title), the world-HUD pair and
--     the CommonUI container's BP_AddWidget/RemoveWidget were never given an action that would
--     exercise them. Their zero is an absence of input, not an absence of firing, and they stay
--     named in test/hooks/ui-update-event rather than being written off.
--   * WHAT THE THREE COVER IS UNMEASURED. Nobody has watched what happens to a HUD-only change,
--     a popup, or a screen that is rebuilt in place. A rebuild this file does not hear is
--     invisible to an event-only design — which is the first reason the poll stays as the FLOOR
--     in api/ui.lua rather than being replaced.
--   * THE LOAD STORM IS UNMEASURED HERE TOO. The hook needs a world, so it armed AFTER the world
--     was up: ActivateWidget's 1 call in 30 s says nothing about how hard it fires during a load.
--     test/probes/uievents.lua is the instrument that brackets a storm (arm at world #1's ready,
--     then load a save again); until it reports, this file assumes the storm is violent and is
--     built so that a violent one costs nothing (see both rules below).
--
--=============================================================================
-- TWO RULES, BOTH LEARNED EXPENSIVELY, AND THEY SHAPE EVERY LINE BELOW
--=============================================================================
--
-- 1. ⚠️ ARMING IS FOREVER. UE4SS cannot unregister a hook (core/event.lua:33-35 and the same
--    sentence at :1636). Everything armed here stays armed for the life of the process. So:
--    arming is at most ONCE PER SESSION, the guard is on _G (a hot reload builds a fresh module
--    underneath a hook that keeps running — core/event.lua's rule 2), and it is LAZY: nothing is
--    armed unless a pack actually asked for a refresh driver by calling :autoRefresh / :autoMount.
--    That is the same shape native/ui/_widget.lua's click router uses, which is what proves
--    CommonUI functions are hookable on this build — it arms
--    /Script/CommonUI.CommonButtonBase:HandleButtonClicked and has done for every session.
--
-- 2. ⚠️ NOT DURING THE WORLD-LOAD STORM. core/event.lua:46-53 records what a hook armed at the
--    wrong moment cost: a native access violation from reading half-initialized memory, and a
--    storm-firing hook that WEDGED the shared UE4SS dispatch and took the confirmed hooks down
--    with it. ActivateWidget fires for every activatable going up, which is exactly where a load
--    is loudest. Two defences, and both are needed:
--
--      (a) arming is deferred to core/event's `world.ready` — the same one-shot, gate-checked
--          pattern core/event.lua's tryHookAfterWorldReady uses, re-implemented here rather than
--          borrowed because this file must not require core/event at load time. That misses the
--          FIRST world's storm entirely. It does not help on a second load in the same session,
--          and nothing can: there is no unregister.
--      (b) THE HANDLER BODY IS THREE WRITES AND NOTHING ELSE — an integer, a counter, and a
--          one-time os.clock(). No :get(), no string, no log, no engine call. There is no
--          half-initialized object for it to read, so (b) is what actually holds when (a) cannot.
--          This is the body test/probes/uievents.lua established and it is not negotiable.
--
--    And the CONSUMER is bounded by construction: api/ui.lua reads `generation()` once per 500 ms
--    heartbeat and refreshes at most once per beat, so a storm that fires this four thousand times
--    costs four thousand integer increments and exactly one refresh.
--
--=============================================================================
-- WHAT IT IS NOT
--=============================================================================
--
-- Not a channel on core/event. This is a UI-local signal with a UI-local consumer, and putting it
-- on the shared bus would mean a source that fires hardest during a load storm pushing through the
-- one dispatch every confirmed hook in the tree shares. If a second consumer ever wants it, the
-- patch core/event.lua would need is a `ui.rebuilt` channel emitting from the same three paths on
-- the same world.ready gate — a `generation()` reader costs nothing by comparison and is what
-- ships today.
--
--   local refresh = require("palforge.native.ui.refresh")
--   refresh.arm()            -- idempotent; defers itself to world.ready when a world is loading
--   refresh.generation()     -- an integer that CHANGES when Palworld built or tore down a screen
--   refresh.status()         -- what is armed, what has fired, how often, and when it first did
--   for _, line in ipairs(refresh.report()) do print(line) end

local log = require("palforge.utils.log").scope("ui")

local M = {}

---The run that named these three, quoted by every message this file and api/ui.lua produce, so
---the two can never drift apart.
M.MEASURED = "measured 2026-08-02 23:04 on Palworld v1.0.2.101103 by test/hooks/ui-update-event "
    .. "(21 armed, 3 fired, 18 silent)"

---The three UFunctions that FIRED. Named by path, with the dump line each was read from and what
---a firing means — nothing here is armed by a substring filter ever again.
M.SIGNALS = {
    { path = "/Script/CommonUI.CommonActivatableWidget:ActivateWidget",
      from = "CommonUI.hpp:177",
      what = "a screen became ACTIVE. Every Palworld screen is a CommonActivatableWidget "
          .. "(PalUserWidget -> PalActivatableWidget -> CommonActivatableWidget), so this one "
          .. "hook covers every menu in the game — and fires hardest during a world load",
      measuredAt = "+22.4 s" },
    { path = "/Script/Pal.PalHUDService:Push",
      from = "Pal.hpp:20487",
      what = "Palworld PUSHED a stackable screen (inventory, build menu, map, pause are all "
          .. "UPalUserWidgetStackableUI). This is the game's own screen service — the object "
          .. "UPalUIManagerSubsystem, which declares zero functions, turned out not to be",
      measuredAt = "+25.6 s" },
    { path = "/Script/Pal.PalHUDService:Close",
      from = "Pal.hpp:20518",
      what = "the CLOSE half of Push, by widget id. A HUD panel of ours has to re-check when a "
          .. "screen goes away as much as when one arrives",
      measuredAt = "+27.8 s" },
}

--=============================================================================
-- STATE, ON _G — rule 1. The hook closures and the world.ready subscriber are armed once per
-- SESSION and survive an F9 reload; anything they write that a fresh module then read would be
-- written by the old closures and read by nobody. One table, and a second run of this file finds
-- it already armed rather than arming a second set that can never be taken back.
--=============================================================================

local function st()
    local s = _G.__PalForgeUIRefresh
    if type(s) ~= "table" then
        s = { gen = 0, state = "pending", why = nil, t0 = os.clock(),
              counts = {}, firstAt = {}, armedPaths = {}, refusals = {}, watching = false }
        _G.__PalForgeUIRefresh = s
    end
    -- A session that armed under an older copy of this file may be missing a field this one
    -- reads. Fill in rather than replace: the live hook closures hold THIS table.
    s.counts     = s.counts     or {}
    s.firstAt    = s.firstAt    or {}
    s.armedPaths = s.armedPaths or {}
    s.refusals   = s.refusals   or {}
    s.gen        = s.gen        or 0
    return s
end

---The number that says "a screen was built or torn down". It only ever goes UP, and a consumer
---compares it against the value it last saw rather than resetting it — two consumers must be able
---to ride the same signal without stealing each other's edges.
---@return integer
function M.generation()
    local s = _G.__PalForgeUIRefresh
    return (type(s) == "table" and tonumber(s.gen)) or 0
end

-- THE HANDLER. Rule 2(b): three writes, no engine call, no allocation past the first firing of
-- each path. Read the header before adding anything to this function.
local function bump(path)
    return function()
        local s = _G.__PalForgeUIRefresh
        if not s then return end
        s.gen = s.gen + 1
        s.counts[path] = (s.counts[path] or 0) + 1
        if s.firstAt[path] == nil then s.firstAt[path] = os.clock() end
    end
end

-- Arm the three, right now. Only ever called from a moment that has been decided to be safe (see
-- M.arm) — this function does not check, it registers.
local function armNow()
    local s = st()
    if s.state == "armed" then return s.state, s.why end
    if type(RegisterHook) ~= "function" then
        s.state, s.why = "unavailable", "RegisterHook is not available in this session"
        return s.state, s.why
    end
    local armed = 0
    for _, sig in ipairs(M.SIGNALS) do
        if s.armedPaths[sig.path] then
            armed = armed + 1
        else
            s.counts[sig.path] = s.counts[sig.path] or 0
            local ok, err = pcall(RegisterHook, sig.path, bump(sig.path))
            if ok then
                armed = armed + 1
                s.armedPaths[sig.path] = true
            else
                -- Kept, not swallowed. UE4SS's refusal names whether the UFunction was not found
                -- or was found and is neither native nor script (LuaMod.cpp:4134, :4176-4183),
                -- and "the driver is a poll today" is only readable with that sentence next to it.
                s.refusals[sig.path] = tostring(err)
            end
        end
    end
    if armed > 0 then
        s.state, s.why = "armed", nil
        log.info(string.format("ui rebuild signal ARMED on %d of %d path(s): %s. %s. A refresh now "
            .. "lands within one heartbeat of the game building or tearing down a screen; the poll "
            .. "stays as the floor. ⚠️ UE4SS cannot unregister these — they are armed for the life "
            .. "of this process.", armed, #M.SIGNALS, table.concat(M.armed(), " + "), M.MEASURED))
    else
        s.state = "refused"
        s.why = "no candidate path could be armed on this build"
        log.warn(string.format("ui rebuild signal could NOT be armed (%s) — refresh falls back to "
            .. "the poll alone, which is what shipped before this signal existed. Refusals: %s",
            s.why, table.concat(M.refusalLines(), "; ")))
    end
    return s.state, s.why
end

-- Re-entered by the world.ready subscriber rather than captured, for core/event.lua's rule 3: that
-- subscription is armed once per session and survives every hot reload, so it must reach the
-- CURRENT module and not the copy that existed when it was made.
function M.__armNow() return armNow() end

---Ask for the rebuild signal. Idempotent, cheap to call on every :autoRefresh, and it is the ONLY
---thing in this file that ever registers a hook — so a session where no pack asked for a refresh
---driver arms nothing at all.
---
---⚠️ IT MAY NOT ARM IMMEDIATELY, AND THAT IS THE POINT (rule 2a). While no world is ready — the
---title screen, and a world that is LOADING, which are indistinguishable from here — arming is
---deferred to core/event's `world.ready` and this returns "waiting". The gate is checked again
---inside that subscriber, so a synthetic emit (the test suite emits every channel by hand) cannot
---arm us into a load storm.
---
---A title-screen-only session therefore runs on the poll alone. That is the deliberate trade: the
---alternative is arming before the player's first world load, i.e. guaranteeing that the very
---first storm is caught by a hook nobody can remove.
---@return string state   # "armed" | "waiting" | "refused" | "unavailable"
---@return string? why
function M.arm()
    local s = st()
    if s.state == "armed" or s.state == "unavailable" or s.state == "refused" then
        return s.state, s.why
    end
    if type(RegisterHook) ~= "function" then
        s.state, s.why = "unavailable", "RegisterHook is not available in this session"
        return s.state, s.why
    end
    local event
    local okE = pcall(function() event = require("palforge.core.event") end)
    if not (okE and type(event) == "table") then
        s.state, s.why = "waiting", "core.event is not loadable yet, so there is no world.ready "
            .. "to arm behind"
        return s.state, s.why
    end
    -- A world is up and its load storm is over (core/event defers world.ready until the first
    -- completed scan, so the gate being open IS the storm being finished). Arm here and now.
    local ready = false
    pcall(function() ready = event.isWorldReady() == true end)
    if ready then return armNow() end

    if not s.watching then
        s.watching = true
        local okS = pcall(function()
            event.on("world.ready", function()
                local live = _G.__PalForgeUIRefresh
                if live and live.state == "armed" then return end   -- one-shot: world.ready
                                                                    -- re-fires per world load
                local ev = require("palforge.core.event")
                if ev.isWorldReady() ~= true then return end        -- arm on the GATE, never on a
                                                                    -- synthetic emit
                require("palforge.native.ui.refresh").__armNow()
            end)
        end)
        if not okS then s.watching = false end
    end
    s.state = "waiting"
    s.why = "no world is ready yet — arming is deferred to core/event's world.ready, because "
        .. "ActivateWidget fires for every activatable during a world-load storm and UE4SS cannot "
        .. "unregister a hook"
    return s.state, s.why
end

---The paths that are armed RIGHT NOW, in declaration order. Empty until arm() has succeeded.
---@return string[]
function M.armed()
    local s, out = st(), {}
    for _, sig in ipairs(M.SIGNALS) do
        if s.armedPaths[sig.path] then out[#out + 1] = sig.path end
    end
    return out
end

---Every refusal, as "path: reason" lines. Empty when nothing was refused.
---@return string[]
function M.refusalLines()
    local s, out = st(), {}
    for _, sig in ipairs(M.SIGNALS) do
        local why = s.refusals[sig.path]
        if why then out[#out + 1] = sig.path .. ": " .. why end
    end
    return out
end

---Everything this file knows, as data. What a report prints and what UI.refreshDriver reads.
---@return table
function M.status()
    local s = st()
    local signals = {}
    for i, sig in ipairs(M.SIGNALS) do
        signals[i] = { path = sig.path, from = sig.from, what = sig.what,
                       armed = s.armedPaths[sig.path] == true,
                       fired = s.counts[sig.path] or 0,
                       firstAt = s.firstAt[sig.path] and (s.firstAt[sig.path] - s.t0) or nil,
                       refused = s.refusals[sig.path] }
    end
    return { state = s.state, why = s.why, generation = s.gen,
             armed = M.armed(), signals = signals, measured = M.MEASURED,
             uptime = os.clock() - s.t0 }
end

---What the rebuild signal is doing, as printable lines — the third question UI.report() asks,
---beside "who would get a press" and "can a press arrive at all". A zero here is readable: it
---separates "nothing is armed" from "armed and the game has not rebuilt a screen since".
---@return string[]
function M.report()
    local d, out = M.status(), {}
    if d.state ~= "armed" then
        out[#out + 1] = string.format("ui: the rebuild signal is %s%s — refresh is running on the "
            .. "POLL alone", d.state, d.why and (" (" .. d.why .. ")") or "")
        return out
    end
    out[#out + 1] = string.format("ui: the rebuild signal is ARMED on %d path(s); generation = %d "
        .. "(a refresh rides every change of it, with the poll as the floor)", #d.armed, d.generation)
    for _, sig in ipairs(d.signals) do
        out[#out + 1] = string.format("ui:   %-58s %-8s %s", sig.path,
            sig.armed and "armed" or (sig.refused and "REFUSED" or "-"),
            (sig.fired > 0)
                and string.format("%d firing(s), first at +%.1f s", sig.fired, sig.firstAt or 0)
                or "silent so far — which is an absence of screens opening, not proof it cannot fire")
    end
    return out
end

return M
