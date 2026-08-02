-- test/hooks/ui-update-event — DOES PALWORLD RAISE A CATCHABLE UFUNCTION WHEN A UI IS REBUILT?
--
-- plan/TODO.md Open / UI. Marked inside Handle:autoRefresh (api/ui.lua:1658; the marker itself at :1673, where it
-- already names this hook by id).
--
-- What a pack author sees: nothing calls refresh() for them. Every element either calls
-- :refresh() by hand or rides the 500 ms heartbeat, so a panel shows stale content for up to
-- `ms` and there is no way to refresh exactly when the game rebuilds a screen. TitleMenu's whole
-- re-injection strategy is a poll for the same reason.
--
-- The open question, verbatim from the marker: "unknown whether Palworld raises a catchable
-- UFunction when a UI is (re)built — until one is dumped, polling is the only driver PalForge
-- has."
--
-- ⚠️ TWO WARNINGS, BOTH LEARNED THE EXPENSIVE WAY, AND BOTH SHAPE THE CODE BELOW.
--
--   1. UE4SS CANNOT UNREGISTER A HOOK (core/event.lua:33 and :2161 say so in their own words). Everything this hook arms stays
--      armed for the life of the process. That is why the arming list is CAPPED and why the
--      cap is printed: a probe that arms two hundred unremovable hooks to answer one question
--      has made the session worse than it found it.
--   2. A HOOK HANDLER THAT DOES WORK DURING THE WORLD-LOAD STORM WEDGED THE SHARED DISPATCH
--      and took the confirmed hooks down with it. So every handler body here is TWO INTEGER
--      WRITES and nothing else — no :get(), no string, no log call. The FIRED lines the item
--      asks for are printed from core/poll's heartbeat instead, off plain Lua numbers, with the
--      first-fire ORDER preserved. Same information, none of the risk. This is the shape
--      test/probes/uievents.lua established and it is not negotiable.
--
-- WHAT IT NEEDS FROM THE PERSON AT THE KEYBOARD, and it prints these on screen as well as into
-- the log: open the inventory and close it, open the build menu, then return to the title
-- screen. Those three are the item's own list and each one exercises a different rebuild path.
local hooks = require("palforge.test.hooks")

-- The four classes the item names. PalUIManagerSubsystem is the one that would own a global
-- "a screen changed" signal; the other three are individual screens, where a per-screen
-- Construct/Setup would live.
--
-- ⚠️ PalUIManagerSubsystem IS ALREADY ELIMINATED and is kept here anyway, deliberately. The
-- marker at api/ui.lua:1673 records that UPalUIManagerSubsystem (Pal.hpp:30988) declares ZERO
-- functions and says "do not enumerate it again" — so a `0 functions` line against it below is
-- a CONFIRMATION of a known fact and not a discovery, and it costs one reflection walk. Dropping
-- it from the list would make this hook's output stop matching the item's own paragraph, which
-- is the thing a reader will compare it against.
local CLASSES = {
    "PalUIManagerSubsystem",
    "PalUIHUDLayoutBase",
    "PalUITitleBase",
    "PalUIInventoryEquipment",
}

-- The six words a rebuild signal would carry in its name.
local WORDS = { "Open", "Show", "Construct", "Refresh", "Update", "Setup" }

-- How many hooks this run is willing to leave armed for the session. See warning 1.
local ARM_CAP = 40

local function wanted(name)
    for _, w in ipairs(WORDS) do if name:find(w, 1, true) then return true end end
    return false
end

-- Every UFunction on a class, by the two routes the item names: ForEachFunction when this
-- UE4SS build binds it, else the Children/.Next walk. Returns { name, fn } pairs.
local function functionsOf(cls)
    local out, seen = {}, {}
    local function push(fn)
        local name
        pcall(function() name = fn:GetFName():ToString() end)
        if type(name) == "string" and #name > 0 and not seen[name] then
            seen[name] = true
            out[#out + 1] = { name = name, fn = fn }
        end
    end
    local ok = pcall(function() cls:ForEachFunction(function(fn) pcall(push, fn) end) end)
    if ok and #out > 0 then return out, "ForEachFunction" end

    -- The fallback the item asks for: UStruct.Children is a linked list through .Next, and it
    -- carries properties as well as functions, so anything that will not answer GetFName is
    -- simply skipped by push.
    local node
    pcall(function() node = cls.Children end)
    local guard = 0
    while node ~= nil and guard < 4000 do
        guard = guard + 1
        pcall(push, node)
        local nxt
        pcall(function() nxt = node.Next end)
        node = nxt
    end
    return out, (#out > 0) and "Children/.Next walk" or "neither route answered"
end

--=============================================================================
-- state, on _G
--
-- Same reason core/poll keeps its registry there: the hooks and the heartbeat closure survive
-- an F9 reload, so the counters they touch must too. It is also what makes a second run a
-- no-op instead of a second arming of hooks that can never be removed.
--=============================================================================

local function state()
    local s = _G.__PalForgeUIUpdateHook
    if type(s) ~= "table" then
        s = { armed = false, counts = {}, order = {}, firstAt = {}, t0 = os.clock(), armedPaths = {} }
        _G.__PalForgeUIUpdateHook = s
    end
    return s
end

hooks.declare{
    id    = "ui-update-event",
    item  = "Open / UI",
    needs = { world = true },
    desc  = "arms every Open/Show/Construct/Refresh/Update/Setup UFunction on the four UI "
         .. "classes and reports which ones actually fire, and in what order",
    run = function(h)
        local probe = require("palforge.test.probe")
        local poll  = require("palforge.core.poll")
        local st    = state()

        if st.armed then
            h:note("hooks from an earlier run of this hook are STILL ARMED (UE4SS cannot "
                .. "unregister one), so this run re-uses them rather than arming a second set. "
                .. "The counters below have been running since %.0f s ago.", os.clock() - st.t0)
        end

        --------------------------------------------------------------------
        h:section("[1] the four classes, and their UFunctions with parameter offsets")
        --------------------------------------------------------------------
        local candidates = {}
        for _, name in ipairs(CLASSES) do
            local cls, cdo
            pcall(function() cls = StaticFindObject("/Script/Pal." .. name) end)
            pcall(function() cdo = StaticFindObject("/Script/Pal.Default__" .. name) end)
            h:value("/Script/Pal." .. name, probe.valid(cls) and probe.full(cls) or "nil — ABSENT")
            h:value("/Script/Pal.Default__" .. name, probe.valid(cdo) and probe.full(cdo) or "nil — ABSENT")

            -- The class object is what carries the functions; a CDO does not answer
            -- ForEachFunction, its class does (test/probe.lua:189-192 records that).
            local owner = probe.valid(cls) and cls or nil
            if not owner and probe.valid(cdo) then
                pcall(function() owner = cdo:GetClass() end)
                if probe.valid(owner) then
                    h:note("%s resolved only as a CDO; its class %s is what is walked",
                        name, probe.name(owner))
                end
            end
            if not probe.valid(owner) then
                h:value(name .. " functions", "not enumerated — neither the class nor a CDO resolved")
            else
                local fns, how = functionsOf(owner)
                h:value(name .. " functions", string.format("%d, via %s", #fns, how))
                for _, entry in ipairs(fns) do
                    local line = name .. "::" .. entry.name
                    -- Each function's OWN child properties, with class and offset. This is the
                    -- half that says whether a firing would carry anything usable: a rebuild
                    -- signal with a widget parameter is worth far more than a bare notification.
                    local props = {}
                    pcall(function()
                        entry.fn:ForEachProperty(function(p)
                            pcall(function()
                                local pn, pc, off
                                pcall(function() pn = p:GetFName():ToString() end)
                                pcall(function() pc = p:GetClass():GetFullName() end)
                                pcall(function() off = p:GetOffset_Internal() end)
                                props[#props + 1] = string.format(" %s %s @%s",
                                    tostring(pn), tostring(pc), tostring(off))
                            end)
                        end)
                    end)
                    h:log("FN %s%s", line, #props > 0 and ("\n" .. table.concat(props, "\n")) or "  (no parameters)")
                    if wanted(entry.name) then
                        candidates[#candidates + 1] = "/Script/Pal." .. name .. ":" .. entry.name
                    end
                end
            end
        end

        --------------------------------------------------------------------
        h:section("[2] arming")
        --------------------------------------------------------------------
        h:value("candidates matching " .. table.concat(WORDS, "/"), #candidates)
        if #candidates == 0 then
            h:pass("NOT ONE UFunction on those four classes carries any of the six words. That "
                .. "is a complete answer and it closes the item: there is no rebuild signal to "
                .. "hook, and polling stays the only driver PalForge has. Say so in "
                .. "api/ui.lua's autoRefresh doc rather than leaving a TODO.")
            return
        end
        if type(RegisterHook) ~= "function" then
            h:fail("RegisterHook is unavailable this session, so nothing could be armed and the "
                .. "candidate list above is all this run produced.")
            return
        end
        h:warn("about to arm up to %d hook(s). ⚠️ UE4SS CANNOT UNREGISTER ONE: every hook armed "
            .. "here stays for the life of this process, and only quitting the game removes it.",
            math.min(#candidates, ARM_CAP))

        local armed, refused = 0, 0
        for _, path in ipairs(candidates) do
            if armed >= ARM_CAP then
                h:warn("stopping at the cap: %d further candidate(s) were NOT armed, so a zero "
                    .. "against them below would be the absence of a counter rather than the "
                    .. "absence of a firing.", #candidates - armed - refused)
                break
            end
            if st.armedPaths[path] then
                armed = armed + 1   -- already armed by an earlier run; its counter is still live
            else
                st.counts[path] = 0
                -- TWO INTEGER WRITES. No :get(), no string, no log — see warning 2 at the top.
                local ok = pcall(RegisterHook, path, function()
                    local s = _G.__PalForgeUIUpdateHook
                    if not s then return end
                    s.counts[path] = (s.counts[path] or 0) + 1
                    if s.firstAt[path] == nil then
                        s.firstAt[path] = os.clock()
                        s.order[#s.order + 1] = path
                    end
                end)
                if ok then
                    armed = armed + 1
                    st.armedPaths[path] = true
                else
                    refused = refused + 1
                    st.counts[path] = nil
                    h:value("REFUSED " .. path, "not hookable by name on this build")
                end
            end
        end
        st.armed = true
        h:value("armed", string.format("%d of %d candidate(s); %d refused", armed, #candidates, refused))

        --------------------------------------------------------------------
        h:section("[3] what to do in game")
        --------------------------------------------------------------------
        h:ask("open your INVENTORY and close it, then open the BUILD MENU, then RETURN TO THE "
            .. "TITLE SCREEN. Verdicts print at 30 s, 90 s and 180 s.")
        h:note("this hook keeps reporting after this block closes: look for further "
            .. "#### BEGIN ui-update-event-1 / -2 / -3 blocks below.")

        local phase = 0
        poll.every("ui-update-event", function(elapsed)
            local due = (elapsed >= 30 and phase < 1) and 1
                or (elapsed >= 90 and phase < 2) and 2
                or (elapsed >= 180 and phase < 3) and 3 or nil
            if not due then return elapsed >= 185 end
            phase = due
            h:beginBlock(phase)
            local s, fired = state(), 0
            -- FIRST-FIRE ORDER, which is the half of the answer a bare count cannot give: it
            -- says which signal leads a rebuild and which trails it.
            for i, path in ipairs(s.order) do
                fired = fired + 1
                h:log("FIRED %2d. %s  (first at +%.1f s, %d call(s) so far)",
                    i, path, (s.firstAt[path] or 0) - s.t0, s.counts[path] or 0)
            end
            local silent = {}
            for path, count in pairs(s.counts) do
                if count == 0 then silent[#silent + 1] = path end
            end
            table.sort(silent)
            h:value("fired at least once", fired)
            h:value("armed and SILENT", #silent)
            for _, path in ipairs(silent) do h:log("SILENT %s", path) end
            if phase == 3 then
                h:note("HOW TO READ IT. (a) a path that fired when the inventory opened and again "
                    .. "when it closed is a REBUILD SIGNAL and is what autoRefresh should ride — "
                    .. "check its call count against how many times you opened something. "
                    .. "(b) armed and silent means Palworld's own blueprints override that "
                    .. "UFunction: a BlueprintImplementableEvent implemented in a BP gets its OWN "
                    .. "UFunction, and a hook on the base never sees it. That is a closed answer, "
                    .. "not a missing one. (c) a path that fired thousands of times during the "
                    .. "return to title is a load-storm signal and is unusable as an "
                    .. "unconditional driver whatever else it does — core/event's worldReady gate "
                    .. "would have to wrap it, and the hook is still CALLED during the storm.")
                h:endBlock(phase)
                return true
            end
            h:endBlock(phase)
            return false
        end)
    end,
}
