-- test/hooks/pal-spawned-fresh — DOES pal.spawned MEAN "A PAL THAT DID NOT EXIST A MOMENT AGO"?
--
-- ⭐ IT RAN, AND IT ANSWERED YES: 27 firings on 2026-08-02, 17 of them nowhere near a world
-- load. The source marker it used to point at, in api/pal.lua's onSpawned block, is gone —
-- replaced there by the finding. What is left here is the instrument.
--
-- THE QUESTION IT ASKED. The channel FIRES — that half closed as `pal-spawned-hook`. What a pack
-- could not tell was whether a firing means a FRESH pal: every firing observed before this run
-- landed in the same second as world.ready, i.e. the load storm, when every pal in range
-- initialises at once, and the two look identical from here because only the FIRST firing per
-- channel is announced.
--
-- So the measurement is a TIMESTAMP, not a hook: a firing whose timestamp sits nowhere near
-- world.ready is the whole answer, and seventeen of them did.
--
-- ⚠️ DO NOT RE-PROBE PalCharacter:BroadcastOnCompleteInitializeParameter. It is MEASURED SILENT
-- (core/event.lua:1683 records the measurement) — armed after world.ready in a real save, pals caught
-- and released, and pal.spawned carried nothing from it while ten other channels announced.
-- Hooking a broadcaster instead of the bound delegate TARGET is the mistake `pal-spawned-hook`
-- exists to record, and repeating it here would re-open a closed item. The two sources that DO
-- carry are the targets:
--     /Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter   (core/event.lua:1720)
--     /Script/Pal.PalNPC:OnCompletedInitParam                        (core/event.lua:1728)
--
-- ⚠️ AND THIS HOOK ARMS NOTHING OF ITS OWN, WHICH IS A DELIBERATE CHOICE WORTH THE PARAGRAPH.
-- Both sources are ALREADY armed by core/event, and both already carry `ctx.via` naming which
-- of the two fired (core/event.lua:1636). Arming a second RegisterHook on the same two paths to
-- read the same two facts would leave two more hooks that UE4SS can never unregister, for
-- nothing. So this subscribes to the `pal.spawned` channel instead — pure Lua, no engine
-- surface, and it can be dropped again.
--
-- WHAT THAT COSTS, stated rather than hidden: core/event dedupes per actor within
-- SPAWN_DEDUPE_SEC = 1.0 s (core/event.lua:1622), so if BOTH sources fire for one pal inside a
-- second, only the first reaches this subscription. `via` therefore names the source that WON
-- the race, not every source that fired. For the question this hook asks — is the timestamp far
-- from world.ready — that makes no difference at all.
local hooks = require("palforge.test.hooks")

-- The three things to do in game, one at a time, with a marker line printed before each so the
-- log says which action a firing followed. They are the item's own list.
local MARKERS = {
    { at = 5,   what = "(a) RELEASE A PAL FROM THE PALBOX now — the cleanest fresh spawn there "
                    .. "is: the pal did not exist in the world one second before it appears" },
    { at = 70,  what = "(b) HATCH AN EGG, or TRAVEL far enough for a wild pal to stream in. "
                    .. "This is the case a pack cares about most and the one nobody controls" },
    { at = 140, what = "(c) RUN pf_spawn (console, or put `pf_spawn` in autorun.txt). PalForge's "
                    .. "own spawn is the third path and the only one that is scripted" },
}
local FINISH_AT = 210

local function state()
    local s = _G.__PalForgeSpawnFreshHook
    if type(s) ~= "table" then
        s = { subscribed = false, rows = {}, worldReadyAt = nil, armedFallback = false }
        _G.__PalForgeSpawnFreshHook = s
    end
    return s
end

hooks.declare{
    id    = "pal-spawned-fresh",
    item  = "Closed 2026-08-02 — 27 firings, 17 of them clear of a world load",
    needs = { world = true },
    desc  = "timestamp every pal.spawned firing against world.ready, so a fresh spawn can be "
         .. "told from the load storm",
    run = function(h)
        local event = require("palforge.core.event")
        local poll  = require("palforge.core.poll")
        local uo    = require("palforge.core.uobject")
        local st    = state()

        --------------------------------------------------------------------
        h:section("[1] the clock this hook measures against")
        --------------------------------------------------------------------
        -- world.ready for the CURRENT world has already happened — the gate needed it. So the
        -- anchor for this session is honest about being an approximation, and an exact anchor is
        -- recorded for any LATER load in this session.
        local t0 = os.clock()
        if not st.worldReadyAt then
            event.on("world.ready", function()
                local s = state()
                s.worldReadyAt = os.clock()
            end)
            event.on("world.left", function()
                local s = state()
                s.worldReadyAt = nil
            end)
        end
        h:value("world.ready for THIS world", st.worldReadyAt
            and string.format("%.1f s ago (exact — this hook was already running)", t0 - st.worldReadyAt)
            or "already past when this hook started, so distances below are measured from NOW")
        h:note("IF THIS HOOK WAS STARTED FROM autorun.txt AS `30 pf_hook_pal_spawned_fresh`, then "
            .. "world.ready was exactly 30 s before t=0 below and every distance is known "
            .. "precisely. That is the recommended way to run it, and it is the reason the "
            .. "autorun route exists.")
        h:value("pal.spawned sources armed by core/event",
            "PalPlayerCharacter:OnCompleteInitializeParameter + PalNPC:OnCompletedInitParam "
            .. "(BroadcastOnCompleteInitializeParameter is armed too and is MEASURED SILENT)")

        --------------------------------------------------------------------
        h:section("[2] listening")
        --------------------------------------------------------------------
        if st.subscribed then
            h:note("an earlier run of this hook is already subscribed; its rows are kept and this "
                .. "run adds to them rather than double-counting.")
        else
            st.subscribed = true
            event.on("pal.spawned", function(ctx)
                local s = state()
                local now = os.clock()
                -- Read the actor's identity HERE, where we are on the event bus rather than
                -- inside a native hook: core/event has already checked the actor is alive
                -- (emitSpawned refuses a dead one) and has already paid the :get().
                local row = {
                    at    = now,
                    since = s.worldReadyAt and (now - s.worldReadyAt) or nil,
                    via   = tostring(ctx and ctx.via or "?"),
                    class = "?",
                    name  = "?",
                }
                pcall(function()
                    row.class = uo.className(ctx.actor) or "?"
                    row.name  = uo.fullName(ctx.actor) or "?"
                end)
                s.rows[#s.rows + 1] = row
            end)
            h:pass("subscribed to pal.spawned. No new engine hook was armed — see the header for "
                .. "why that is the right answer rather than a shortcut.")
        end
        local baseline = #st.rows
        h:value("firings recorded before this run", baseline)

        --------------------------------------------------------------------
        h:section("[3] what to do in game, one at a time")
        --------------------------------------------------------------------
        h:ask("three things, one at a time, and the log prints a marker before each. Watch for "
            .. "the marker line, THEN do it.")
        for _, m in ipairs(MARKERS) do
            h:note("at t+%d s: %s", m.at, m.what)
        end
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN pal-spawned-fresh-marker-N and -verdict blocks below.")

        local nextMarker, reported = 1, 0
        poll.every("pal-spawned-fresh", function(elapsed)
            local s = state()

            -- print each marker exactly once, when its moment comes
            if nextMarker <= #MARKERS and elapsed >= MARKERS[nextMarker].at then
                local m = MARKERS[nextMarker]
                nextMarker = nextMarker + 1
                h:beginBlock("marker-" .. (nextMarker - 1))
                h:log("MARKER t+%.0f s  %s", elapsed, m.what)
                h:log("MARKER firings so far: %d", #s.rows - baseline)
                h:endBlock("marker-" .. (nextMarker - 1))
                local support = require("palforge.test.support")
                support.announce("pal-spawned-fresh: " .. m.what)
            end

            -- and each new firing as it arrives, with its distance from the anchor
            while reported < (#s.rows - baseline) do
                reported = reported + 1
                local r = s.rows[baseline + reported]
                h:log("FIRED t+%.1f s  via=%-46s %s  %s", r.at - t0, r.via, r.class, r.name)
                if r.since then
                    h:log("FIRED     ...which is %.1f s after the last world.ready%s",
                        r.since, r.since < 3 and "  ⚠️ THAT IS THE LOAD STORM, not a fresh spawn" or "")
                end
            end

            if elapsed < FINISH_AT then return false end

            --------------------------------------------------------------
            h:beginBlock("verdict")
            local total = #s.rows - baseline
            h:log("VALUE firings in this run                = %d", total)
            local late = 0
            for i = baseline + 1, #s.rows do
                if (s.rows[i].at - t0) > 3 then late = late + 1 end
            end
            h:log("VALUE firings more than 3 s after t=0     = %d", late)
            if late > 0 then
                h:log("PASS pal.spawned FIRES FOR A PAL THAT DID NOT EXIST A MOMENT AGO. %d "
                    .. "firing(s) landed nowhere near a world load, each with a marker above it "
                    .. "saying which action produced it. The item closes and api/pal.lua:180's "
                    .. "TODO marker comes out.", late)
            elseif total > 0 then
                h:log("FAIL every firing landed within 3 s of this hook starting, which is the "
                    .. "load storm again. The marked actions produced NOTHING, so the channel "
                    .. "still cannot be said to mean 'fresh'.")
            else
                h:log("FAIL not one firing in %d s, with three spawn actions asked for. That is a "
                    .. "stronger negative than the item expected and it points at the two "
                    .. "delegate targets not being invoked through ProcessEvent on this build "
                    .. "at all.", FINISH_AT)
            end

            -- THE ITEM'S OWN FALLBACK, and only when it is called for: "if none fires,
            -- additionally arm PalCharacter:BeginPlay and every function matching Spawn found by
            -- reflecting the PalMonsterSpawner classes."
            if total == 0 and not s.armedFallback then
                s.armedFallback = true
                h:log("NOTE nothing fired, so the fallback the item asks for runs now: reflect "
                    .. "the spawner classes and arm BeginPlay. ⚠️ these hooks cannot be "
                    .. "unregistered and stay for the session.")
                local probe = require("palforge.test.probe")
                for _, className in ipairs({ "PalMonsterSpawner", "PalMonsterSpawnerBase",
                                             "PalMonsterSpawnerManager" }) do
                    local cls
                    pcall(function() cls = StaticFindObject("/Script/Pal." .. className) end)
                    if not probe.valid(cls) then
                        h:log("VALUE /Script/Pal.%s = absent", className)
                    else
                        local names = probe.functions(cls, className)
                        for _, n in ipairs(names) do
                            if n:find("Spawn", 1, true) then
                                h:log("VALUE spawner candidate = /Script/Pal.%s:%s", className, n)
                            end
                        end
                    end
                end
                if type(RegisterHook) == "function" then
                    local ok = pcall(RegisterHook, "/Script/Pal.PalCharacter:BeginPlay", function()
                        local s2 = state()
                        s2.beginPlay = (s2.beginPlay or 0) + 1
                    end)
                    h:log("VALUE armed PalCharacter:BeginPlay = %s", tostring(ok))
                    h:log("NOTE its counter is read by the NEXT run of this hook; spawn a pal and "
                        .. "run pf_hook_pal_spawned_fresh again.")
                end
            end
            if s.beginPlay then
                h:log("VALUE PalCharacter:BeginPlay firings since it was armed = %d", s.beginPlay)
            end
            h:endBlock("verdict")
            return true
        end)
    end,
}
