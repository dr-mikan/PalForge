-- palforge/test/probes/uievents.lua — COUNT the four UI-rebuild candidates, and count them
-- across a world load.
--
-- Closes plan/TODO.md `ui-update-event` (marked in api/ui.lua at Handle:autoRefresh). Existence
-- is already answered by dumps/cxx and four candidates are named there; what is owed is FIRING
-- COUNTS, because core/event.lua records a shared-dispatch wedge from a hook armed into the
-- world-load storm and a UI hook fires hardest exactly there. A hook that fires 4000 times
-- during a load is unusable as autoRefresh's driver however correct it is, and nothing but a
-- count says which of the four that is.
--
-- THE ONE HONEST PROBLEM, AND HOW IT IS SOLVED. A hook armed at world.ready misses that world's
-- load storm by definition — the storm is over by the time the channel lands (core/event.lua
-- defers world.ready until the first completed scan). So from a SINGLE world load this
-- measurement cannot be taken, and no amount of code changes that.
--
-- What does change it is the sentence core/event.lua:33 and :2161 both already write down:
--
--     "UE4SS has no unregister. On a SECOND world load in the same session the hook is still
--      armed and will fire during that storm."
--
-- That is normally the warning. Here it is the instrument. Arm at world #1's ready (safe: the
-- storm is over), then QUIT TO THE TITLE SCREEN AND LOAD A SAVE AGAIN. world.left brackets the
-- start of the window, world.ready brackets the end, and everything counted between the two IS
-- the load storm — measured, not estimated. Two ordinary menu actions, no keypress, no console.
--
-- WHY THIS IS SAFE TO ARM WHERE THE OTHER ONE WAS NOT. The wedge in dump/docs/further_plan.md
-- came from a handler that READ a half-initialized UPalMapObjectModel during the storm; the
-- fault was in the read, native, where pcall cannot see it. These handler bodies are ONE
-- INTEGER INCREMENT each. They never call :get(), never touch the object, never format a
-- string and never log — so there is no half-initialized memory for them to read. All logging
-- happens later, on core/poll's heartbeat, from plain Lua numbers.
--
-- WHAT IT STILL COSTS, stated plainly: UE4SS cannot unregister a hook. Once armed, these four
-- stay armed for the life of the process. Nothing removes them but quitting the game.
--
-- BOTH BLOCKS THIS FILE EMITS NAME `ui-update-event`, which is still OPEN in plan/TODO.md and
-- still marked in api/ui.lua at Handle:autoRefresh (:1570) — so pasting either one into that item
-- is exactly the right thing to do with it, unlike the closed-item blocks the other probes carry.
--
-- STILL A PROBE, NOT A TEST — it counts, prints and stops, asserting nothing. The game-required
-- MEASUREMENT is moving to a declared hook under Scripts/palforge/test/hooks/, named after this
-- same item id and run by name: `pf_hook ui-update-event`. Note what a hook CANNOT take here,
-- because it is the whole difficulty of this item: the number that matters is only produced by
-- quitting to the title and loading a save again, which is two menu actions across two world
-- loads and nothing a single run of anything can perform. A hook can report what these counters
-- hold; only this probe, armed and left alone, can fill them.
--
-- NO RAW TIMER. The sampler rides core/poll's single heartbeat (poll.every), so this file never
-- creates a LoopAsync of its own and therefore never has to declare one to core/reload's async
-- guard the way probes/watch.lua does. That is the migration core/poll.lua:18-36 exists for.
local probe   = require("palforge.test.probe")
local poll    = require("palforge.core.poll")
local event   = require("palforge.core.event")

local M = {}

-- The four dumps/cxx named, in api/ui.lua's own note at Handle:autoRefresh.
--   PalUserWidget is the base every Palworld screen derives from (Pal.hpp:31902-31903);
--   AddHUD is the HUD adding a widget (Pal.hpp:30714);
--   ActivateWidget is CommonUI's own (CommonUI.hpp:177), the same module as
--   CommonButtonBase:HandleButtonClicked, which native/ui/_widget.lua already hooks — so hooks
--   demonstrably take in that module on this build.
local CANDIDATES = {
    { key = "OnSetup",        path = "/Script/Pal.PalUserWidget:OnSetup" },
    { key = "OnClosed",       path = "/Script/Pal.PalUserWidget:OnClosed" },
    { key = "AddHUD",         path = "/Script/Pal.PalUIHUDLayoutBase:AddHUD" },
    { key = "ActivateWidget", path = "/Script/CommonUI.CommonActivatableWidget:ActivateWidget" },
}

local SAMPLE_S = 1.0    -- never faster than one report line per second, whatever the tick does
local TOTALS_S = 30.0   -- a totals line this often, so a silent probe still proves it is alive
local QUIET_S  = 90.0   -- after this long with nothing at all, say so once

-- A firing count per world load at or above this is not something an unconditional refresh
-- driver can absorb; below the second it is ordinary. Printed with the verdict so the numbers
-- read themselves rather than needing a judgement call afterwards.
local STORM_UNUSABLE = 1000
local STORM_HEAVY    = 100

--=============================================================================
-- state, on _G
--
-- Same reason core/poll keeps its registry there: the heartbeat closure and the hooks were
-- armed on the FIRST load and keep running across every reload, so the state they touch has to
-- survive one. It is also what makes a second pf_uievents a no-op instead of a second arming.
--=============================================================================

local function state()
    local s = _G.__PalForgeUIEventProbe
    if type(s) ~= "table" then
        s = { armed = false, counts = {}, prev = {}, peak = {}, armedOk = {},
              lastAt = 0, lastTotals = 0, lines = 0, quietSaid = false,
              leftCounts = nil, leftAt = nil, storms = 0 }
        for _, c in ipairs(CANDIDATES) do
            s.counts[c.key], s.prev[c.key], s.peak[c.key] = 0, 0, 0
            s.armedOk[c.key] = false
        end
        _G.__PalForgeUIEventProbe = s
    end
    return s
end

local function snapshot()
    local st, out = state(), {}
    for _, c in ipairs(CANDIDATES) do out[c.key] = st.counts[c.key] end
    return out
end

local function totalsLine()
    local st, parts = state(), {}
    for _, c in ipairs(CANDIDATES) do
        parts[#parts + 1] = string.format("%s=%d", c.key, st.counts[c.key])
    end
    local peaks = {}
    for _, c in ipairs(CANDIDATES) do
        peaks[#peaks + 1] = string.format("%.0f", st.peak[c.key])
    end
    return table.concat(parts, "  ") .. "  | peak/s " .. table.concat(peaks, "/")
end

--=============================================================================
-- the verdict block, printed the moment a second world finishes loading
--=============================================================================

local function judge(key, storm, total, peak)
    if not state().armedOk[key] then
        return "NOT MEASURED. RegisterHook refused this path, so the zeros above are the absence "
            .. "of a counter and not the absence of firings. The path itself is the finding: "
            .. "this UFunction is not addressable by name on this build."
    end
    if total == 0 then
        return "ARMED AND NEVER FIRED. The hook took and counted nothing, so nothing calls this "
            .. "UFunction — which is exactly what api/ui.lua:(a) predicted for a "
            .. "BlueprintImplementableEvent: a blueprint that implements one gets its OWN "
            .. "UFunction and a hook on the base never sees the override. Unusable as a driver, "
            .. "and that is a closed answer, not a missing one."
    end
    if storm == 0 then
        return "fires in ordinary play but NOT ONCE during the load storm. This is the best "
            .. "possible outcome: it can drive autoRefresh unconditionally, with no worldReady "
            .. "gate and no wedge risk."
    end
    if storm >= STORM_UNUSABLE then
        return string.format("fires %d times during ONE world load (peak %.0f/s). That is the "
            .. "case api/ui.lua:(b) refused to arm blind for. Not usable as an unconditional "
            .. "driver; if it is wanted at all it must be gated on core/event's worldReady, "
            .. "exactly like tryHookAfterWorldReady, and even then the hook is still CALLED "
            .. "during the storm — the gate only stops the handler doing work.", storm, peak)
    end
    if storm >= STORM_HEAVY then
        return string.format("fires %d times during a world load (peak %.0f/s) — heavy but "
            .. "bounded. Usable behind a worldReady gate, and the handler must stay cheap.",
            storm, peak)
    end
    return string.format("fires only %d time(s) during a whole world load (peak %.0f/s). That "
        .. "is a rate a refresh handler can absorb: usable, with the worldReady gate as "
        .. "belt-and-braces rather than as a necessity.", storm, peak)
end

local function reportStorm(window)
    local st = state()
    st.storms = st.storms + 1
    probe.begin("ui-update-event",
        string.format("firing counts across world load #%d — everything between world.left and "
            .. "world.ready IS the load storm", st.storms + 1))
    probe.line("VALUE the window measured = %.1f s (world.left -> world.ready)", window)

    for _, c in ipairs(CANDIDATES) do
        local total = st.counts[c.key]
        local storm = total - (st.leftCounts[c.key] or 0)
        probe.line("VALUE %-16s storm=%-7d session total=%-7d peak/s=%-6.0f armed=%s",
            c.key, storm, total, st.peak[c.key], tostring(st.armedOk[c.key]))
        probe.note("%s: %s", c.key, judge(c.key, storm, total, st.peak[c.key]))
    end

    probe.note("HOW TO READ THE THRESHOLDS: >= %d firings in one load is 'unusable "
        .. "unconditionally', >= %d is 'heavy but bounded', below that is 'absorbable'. The "
        .. "session totals include the title screen you passed through, so use the UIEV SAMPLE "
        .. "lines above to see WHEN each burst happened — the title menu and the load storm are "
        .. "both inside this window and the per-second lines are what separates them.",
        STORM_UNUSABLE, STORM_HEAVY)
    probe.note("NOTHING WEDGED if you are reading this: these four hooks fired straight through "
        .. "a load storm and core/event's dispatch survived to emit world.ready, which is the "
        .. "channel that printed this block. If PalForge's own item/skill/build channels stop "
        .. "carrying events after this run, THAT is the wedge — say so, and it is still a "
        .. "result: it means no UI hook may be left armed across a load.")
    probe.finish()
end

--=============================================================================
-- arming
--=============================================================================

local function armHooks()
    local st = state()
    probe.begin("ui-update-event",
        "arming four counting hooks; they cannot be unregistered, and only quitting the game "
        .. "removes them")

    if type(RegisterHook) ~= "function" then
        probe.note("RegisterHook is unavailable this session, so nothing was armed and nothing "
            .. "can be counted. This item stays open.")
        probe.finish()
        return false
    end

    local any = false
    for _, c in ipairs(CANDIDATES) do
        local key = c.key
        -- THE ENTIRE HANDLER. One table index and one add. It never calls :get(), so it never
        -- reads an object that the load storm may still be initialising — which is the exact
        -- read that faulted natively once already and is why this arming is defensible where
        -- the pal-init one was not.
        local ok = pcall(RegisterHook, c.path, function() st.counts[key] = st.counts[key] + 1 end)
        st.armedOk[key] = ok == true
        probe.line("VALUE armed %-56s -> %s", c.path, ok and "ok" or "FAILED (not on this build)")
        any = any or ok
    end
    if not any then
        probe.note("not one of the four could be armed, so there is nothing to count. That is "
            .. "itself an answer: none of these paths is hookable on this build.")
        probe.finish()
        return false
    end

    probe.note("WHAT TO DO NOW, and it is two ordinary menu actions:")
    probe.note("  1. play normally for a minute — open and close the INVENTORY, open the BUILD "
        .. "menu, open the PAUSE menu. The UIEV SAMPLE lines show which counter each one moves.")
    probe.note("  2. QUIT TO THE TITLE SCREEN, then LOAD YOUR SAVE AGAIN. The hooks stay armed "
        .. "across that (UE4SS has no unregister), so the second load's storm is counted in "
        .. "full and a '#### BEGIN ui-update-event' block prints the answer by itself.")
    probe.note("Nothing else is required and no key is involved. Every line this probe writes "
        .. "afterwards begins with UIEV.")
    probe.finish()
    return true
end

--=============================================================================
-- sampling + the world markers
--=============================================================================

local function armSampler()
    local st = state()
    -- Rides the ONE heartbeat; this file creates no timer. Bounded on ELAPSED SECONDS and never
    -- on a tick count, because the heartbeat's bodies queue during a load and then drain in a
    -- burst — a tick budget would spend itself in the first second after the world came back.
    poll.every("ui-update-event counters", function(elapsed)
        local dt = elapsed - st.lastAt
        if dt < SAMPLE_S then return false end
        st.lastAt = elapsed

        local moved, parts = false, {}
        for _, c in ipairs(CANDIDATES) do
            local now = st.counts[c.key]
            local d = now - st.prev[c.key]
            st.prev[c.key] = now
            if d > 0 then moved = true end
            local rate = d / dt
            if rate > st.peak[c.key] then st.peak[c.key] = rate end
            parts[#parts + 1] = string.format("%s +%d", c.key, d)
        end

        if moved then
            if st.lines < probe.LIST_LIMIT then
                st.lines = st.lines + 1
                probe.line("UIEV SAMPLE t=%.1f dt=%.1f  %s", elapsed, dt, table.concat(parts, "  "))
            elseif st.lines == probe.LIST_LIMIT then
                st.lines = st.lines + 1
                probe.line("UIEV SAMPLE ... (per-second lines capped at %d; the TOTALS lines and "
                    .. "the verdict block keep going)", probe.LIST_LIMIT)
            end
        end

        if elapsed - st.lastTotals >= TOTALS_S then
            st.lastTotals = elapsed
            probe.line("UIEV TOTALS t=%.0f  %s", elapsed, totalsLine())
        end

        if not st.quietSaid and elapsed >= QUIET_S then
            local sum = 0
            for _, c in ipairs(CANDIDATES) do sum = sum + st.counts[c.key] end
            if sum == 0 then
                st.quietSaid = true
                probe.line("UIEV NOTE %.0f s armed and not one of the four has fired. Open and "
                    .. "close the inventory; if they are still all zero, none of these UFunctions "
                    .. "is reached on this build and the item closes negatively.", elapsed)
            end
        end
        return false   -- runs for the life of the world; there is nothing to stop it for
    end)
end

local function armMarkers()
    local st = state()
    event.on("world.left", function()
        st.leftAt     = os.clock()
        st.leftCounts = snapshot()
        probe.line("UIEV MARK world.left   %s", totalsLine())
        probe.line("UIEV MARK the load-storm window is now OPEN — load a save and the next "
            .. "world.ready closes it and prints the verdict")
    end)
    event.on("world.ready", function()
        probe.line("UIEV MARK world.ready  %s", totalsLine())
        if not st.leftCounts then
            -- The world this probe was armed in. Its storm was over before the hooks existed,
            -- which is the whole reason a second load is asked for.
            return
        end
        local window = os.clock() - (st.leftAt or os.clock())
        local ok, e = pcall(reportStorm, window)
        if not ok then probe.line("UIEV NOTE verdict block raised: %s", tostring(e)) end
        st.leftCounts, st.leftAt = nil, nil
    end)
end

--=============================================================================

---Arm the counters. Idempotent: running it a second time (autorun re-runs on every world.ready)
---reports the state and arms nothing, because a second RegisterHook on the same path would
---double every count and there is no way to take the first one back.
---@return integer sections
function M.run()
    local st = state()
    if st.armed then
        probe.line("UIEV NOTE already armed earlier in this session — nothing re-armed. %s",
            totalsLine())
        if st.leftCounts then
            probe.line("UIEV NOTE a load-storm window is OPEN: this is the world.ready that "
                .. "closes it, and the verdict block has already printed above.")
        end
        return 0
    end

    if not armHooks() then return 0 end
    st.armed = true
    armSampler()
    armMarkers()
    return 1
end

return M
