-- test/hooks/ui-update-event — DOES PALWORLD RAISE A CATCHABLE UFUNCTION WHEN A UI IS REBUILT?
--
-- ⚠️ YES. THREE OF THEM. ANSWERED 2026-08-02 23:04, AND THE ANSWER IS SHIPPED.
--
--     armed = 21 of 21 candidate(s); 0 refused
--     fired at least once = 3        armed and SILENT = 18
--
--     FIRSTFIRE /Script/CommonUI.CommonActivatableWidget:ActivateWidget   at +22.4 s
--     FIRSTFIRE /Script/Pal.PalHUDService:Push                            at +25.6 s
--     FIRSTFIRE /Script/Pal.PalHUDService:Close                           at +27.8 s
--
-- (UE4SS.log, build stamp 2026-08-02 23:02:07, v1.0.2.101103, while the operator opened and
-- closed the inventory and the build menu. The +30 s verdict block recorded 1 call each.)
--
-- Those three are armed at runtime by native/ui/refresh.lua and ridden by api/ui.lua's
-- Handle:autoRefresh, with the 500 ms heartbeat kept underneath as the FLOOR. UI.refreshDriver(ms)
-- returns kind = "event+poll" once they are armed. Block [4] below asks the shipped driver what it
-- thinks, in the same session that measures the hooks, so the instrument and the implementation
-- can never disagree quietly.
--
-- ⚠️ AND THE HOOK STAYS DECLARED, because three answers out of twenty-one is not a closed item:
--
--   * THE 18 SILENT ONES ARE NOT PROVEN DEAD. The operator opened TWO screens, not eighteen.
--     ShowCommonUI (popups), RemoveHUD (return to title), the world-HUD pair and the CommonUI
--     container's BP_AddWidget / RemoveWidget were never given an action that would exercise them.
--     Their zero is an absence of input. Run this again and do the OTHER things.
--   * THE LOAD STORM IS STILL UNMEASURED HERE. This hook needs a world, so it arms after one is
--     up; ActivateWidget's one call in thirty seconds says nothing about how hard it fires during
--     a load. test/probes/uievents.lua is the instrument that brackets a storm (arm at world #1's
--     ready, then load a save again), and it is the run that would justify — or refuse — arming
--     the signal any earlier than world.ready.
--   * WHICH REBUILDS THE THREE DO NOT COVER is unknown, and is the reason the poll stays.
--
-- Paired with api/ui.lua's Handle:autoRefresh, which is where the answer ships and which names
-- this hook id by hand — one grep finds both the question and the instrument.
--
--=============================================================================
-- ⚠️ WHAT THE EARLIER 2026-08-02 RUN MEASURED, AND WHY THIS FILE WAS REWRITTEN ONCE ALREADY
--
-- Kept in full. It is the reason every claim in this tree carries a time as well as a date: the
-- 21:57 run below was read as "there is no rebuild event" and that conclusion shipped for a few
-- hours, into api/ui.lua's doc strings and into UI.refreshDriver's return value, before the 23:04
-- run above contradicted it with the same hook and a better candidate list.
--=============================================================================
--
-- The run reported, on Palworld v1.0.2.101103:
--
--     PalUIManagerSubsystem   = 0 functions        PalUIHUDLayoutBase      = 5
--     PalUITitleBase          = 1 function         PalUIInventoryEquipment = 8
--     candidates matching Open/Show/Construct/Refresh/Update/Setup = 2
--     armed = 2 of 2, refused 0     fired at least once = 0     armed and SILENT = 2
--
-- and the honest reading of it is NOT "there is no rebuild event". It is THE SEARCH WAS AIMED
-- WRONG, in two separate ways, and both are fixed below.
--
-- (1) THE FILTER SELECTED FALSE POSITIVES. dumps/cxx names the fourteen functions the run
--     counted, so the two it armed can be identified exactly:
--         PalUITitleBase::ShouldShowGlobalPalStorageNewMark   (Pal.hpp:31655)  matched "Show"
--         PalUIInventoryEquipment::RequestUpdatePlayerStatusPoint (Pal.hpp:30807) matched "Update"
--     One asks whether to draw a NEW badge on a storage button; the other posts stat points.
--     Neither is a UI rebuild under any reading, so "armed 2, silent 2" is not evidence about
--     rebuilds — it is evidence that nobody opened global storage or spent a stat point. A
--     substring filter over six English words is therefore DEMOTED here: it no longer selects
--     what gets armed, it only cross-checks the named list for something missed.
--
-- (2) THE ENUMERATION ONLY SAW LEAF CLASSES. 5 + 1 + 8 = 14 is each class's OWN declarations;
--     ForEachFunction and the Children/.Next walk both stop at the class, and inheritance is not
--     followed. Every one of those screens is a UPalUserWidget -> UPalActivatableWidget ->
--     UCommonActivatableWidget, and the lifecycle lives on the BASES — none of which was in the
--     list. That is why fourteen functions contained no rebuild signal: the rebuild signals are
--     not declared there and never were. The class list below therefore names the bases too,
--     and the arming list is by PATH and does not depend on the walk finding anything.
--
-- WHAT THE FOURTEEN DO SETTLE, and it is worth keeping: PalUIHUDLayoutBase's own five are
-- AddHUD / RemoveHUD / AddWorldHUD / RemoveWorldHUD / VisibilityOverride, which is a real
-- add-and-remove path and IS armed below. PalUIManagerSubsystem answering 0 by class AND by CDO
-- confirms dumps/cxx (Pal.hpp:30988 declares nothing): there is no global "a screen changed"
-- subsystem signal, and that half of the item is closed.
--
-- ⚠️ TWO WARNINGS, BOTH LEARNED THE EXPENSIVE WAY, AND BOTH SHAPE THE CODE BELOW.
--
--   1. UE4SS CANNOT UNREGISTER A HOOK (core/event.lua:33 and :2161 say so in their own words).
--      Everything this hook arms stays armed for the life of the process. That is why the arming
--      list is CAPPED, why the cap is printed, and why the candidate list below is ORDERED by
--      how much each one would tell us — the cap truncates the tail, so the tail is the cheap
--      half on purpose.
--   2. A HOOK HANDLER THAT DOES WORK DURING THE WORLD-LOAD STORM WEDGED THE SHARED DISPATCH
--      and took the confirmed hooks down with it. So every handler body here is TWO INTEGER
--      WRITES and nothing else — no :get(), no string, no log call. The FIRED lines the item
--      asks for are printed from core/poll's heartbeat instead, off plain Lua numbers, with the
--      first-fire ORDER preserved. Same information, none of the risk. This is the shape
--      test/probes/uievents.lua established and it is not negotiable.
--
-- ⚠️ IT IS NOT THE ONLY THING ARMING THESE PATHS ANY MORE. native/ui/refresh.lua arms three of
-- them at runtime — the three that fired — the first time a pack calls :autoRefresh or
-- :autoMount, deferred to world.ready. Two callbacks on one UFunction is exactly what UE4SS
-- supports and neither can see the other, so the counters below stay honest; what it means is
-- that a session which has already mounted a PalForge panel is measuring paths that were armed
-- twice, and that the SHIPPED driver is live while this hook watches it. Block [4] prints what
-- that driver says.
--
-- WHAT IT NEEDS FROM THE PERSON AT THE KEYBOARD, and it prints these on screen as well as into
-- the log: open the inventory and close it, open the build menu, then return to the title
-- screen. Those three are the item's own list and each one exercises a different rebuild path.
-- ⚠️ THE 23:04 RUN DID THE FIRST TWO AND NOT THE THIRD, which is why the return to title — the
-- action that would exercise RemoveHUD, RemoveWidget and the teardown half — is the one to make
-- sure of this time.
-- The verdicts moved EARLIER (20 / 60 / 150 s, was 30 / 90 / 180) because the 2026-08-02 session
-- ended before the second one printed, and a verdict nobody reads measures nothing. A firing is
-- also announced the moment it first happens, so a session that ends after forty seconds still
-- carries the finding.
local hooks = require("palforge.test.hooks")

--=============================================================================
-- [A] the classes to WALK. Enumeration only — nothing is armed from this list.
--
-- Widened from the item's four to include every base the four inherit from, because the walk
-- does not follow inheritance and the lifecycle is declared on the bases. `pkg` is separate
-- because two of them are CommonUI's, not Pal's.
--=============================================================================

local CLASSES = {
    -- The item's four, kept so this hook's output still lines up with the paragraph a reader
    -- will compare it against.
    { pkg = "Pal", name = "PalUIManagerSubsystem",
      why = "the one that WOULD own a global 'a screen changed' signal. ALREADY ELIMINATED — "
         .. "Pal.hpp:30988 declares nothing and the 2026-08-02 run confirmed 0 by class and by "
         .. "CDO. Re-walked because it costs one reflection call and it is the line that proves "
         .. "this run is looking at the same build the last one did" },
    { pkg = "Pal", name = "PalUIHUDLayoutBase",
      why = "the in-game HUD layout. Its own five ARE an add/remove path (Pal.hpp:30710-30714) "
         .. "and four of them are armed below" },
    { pkg = "Pal", name = "PalUITitleBase",
      why = "the title screen — the one TitleMenu re-injects into on a poll" },
    { pkg = "Pal", name = "PalUIInventoryEquipment",
      why = "the inventory screen, the item's own example of a thing that opens and closes" },

    -- The bases. THIS IS THE WIDENING.
    { pkg = "Pal", name = "PalUserWidget",
      why = "Pal.hpp:31888 — the base EVERY Palworld screen derives from, and where OnSetup "
         .. "(:31902) and OnClosed (:31903) are declared. Not one of the fourteen functions the "
         .. "last run counted was from here, because the walk stops at the leaf" },
    { pkg = "Pal", name = "PalUserWidgetStackableUI",
      why = "Pal.hpp — what a PUSHED screen is (inventory, build menu, map are all one). "
         .. "PalUITitleBase is one of these" },
    { pkg = "Pal", name = "PalActivatableWidget",
      why = "Pal.hpp:13367 — Palworld's own CommonUI activatable, where InputConfig lives. The "
         .. "join between the Pal classes and the CommonUI ones" },
    { pkg = "CommonUI", name = "CommonActivatableWidget",
      why = "CommonUI.hpp:147 — THE activatable lifecycle: ActivateWidget / DeactivateWidget / "
         .. "BP_OnActivated / BP_OnDeactivated. CommonUI's activatable stack is the thing that "
         .. "actually changes when a screen opens" },
    { pkg = "CommonUI", name = "CommonActivatableWidgetContainerBase",
      why = "CommonUI.hpp:180 — the STACK itself: BP_AddWidget pushes, RemoveWidget pops. "
         .. "api/ui.lua's host = \"layer\" already pushes through this exact function" },
    { pkg = "Pal", name = "PalHUDService",
      why = "Pal.hpp:20447 — Palworld's own screen service. Push / Close / ShowCommonUI / AddHUD "
         .. "all live here, which makes it the closest thing this build has to the subsystem "
         .. "signal PalUIManagerSubsystem turned out not to carry" },
    { pkg = "Pal", name = "PalHUDInGame",
      why = "Pal.hpp:9709 — the AHUD actor that owns the layout and the widget lists "
         .. "(HUDWidgets, StackableUIWidgets). The service's other end" },
}

--=============================================================================
-- [B] the candidates to ARM, in priority order, each with the dump line and the reason.
--
-- NAMED, not filtered. Every entry says what a firing would MEAN and what is expected, so a
-- zero is readable as a result rather than as an absence. `expect` is a prediction on record:
-- getting one wrong is a finding.
--
--   native  a C++ BlueprintCallable/native UFunction on the base. A hook takes for every
--           subclass instance in the game — this is the shape CommonButtonBase's
--           HandleButtonClicked has, and that one is armed at every PalForge startup, so hooks
--           demonstrably take in these modules on this build.
--   bpevent a BlueprintImplementableEvent. A blueprint that implements one gets its OWN
--           UFunction of that name and a hook on the base never sees the override. Expected
--           silent — armed anyway, because "expected silent" is a prediction and this hook's
--           job is to measure predictions rather than repeat them.
--=============================================================================

local CANDIDATES = {
    -- ---- CommonUI's activatable lifecycle: the highest-value four ----
    { path = "/Script/CommonUI.CommonActivatableWidget:ActivateWidget", kind = "native",
      from = "CommonUI.hpp:177",
      why  = "'this screen just became active'. Every Palworld screen is one of these "
          .. "(PalUserWidget -> PalActivatableWidget -> CommonActivatableWidget), so one hook "
          .. "covers every menu in the game. If anything here is autoRefresh's driver, it is "
          .. "this",
      fired = "CONFIRMED 2026-08-02 23:04, first fire at +22.4 s — SHIPPED as a driver in "
           .. "native/ui/refresh.lua",
      expect = "FIRES on every menu open, and hard during a load" },
    { path = "/Script/CommonUI.CommonActivatableWidget:DeactivateWidget", kind = "native",
      from = "CommonUI.hpp:171",
      why  = "the CLOSE half, and it is not optional: a HUD panel of ours has to re-check when a "
          .. "screen goes AWAY as much as when one arrives",
      expect = "FIRES whenever a menu closes" },
    { path = "/Script/CommonUI.CommonActivatableWidgetContainerBase:BP_AddWidget", kind = "native",
      from = "CommonUI.hpp:194",
      why  = "the stack PUSH — creates, stacks, activates and transitions a widget on a CommonUI "
          .. "layer. api/ui.lua's host = \"layer\" goes through this same call, so a firing here "
          .. "is the game doing exactly what PalForge asks it to do, and would settle "
          .. "ui-host-layer's question from the other side",
      expect = "FIRES on a full-screen menu; may be silent if Palworld pushes natively" },
    { path = "/Script/CommonUI.CommonActivatableWidgetContainerBase:RemoveWidget", kind = "native",
      from = "CommonUI.hpp:190",
      why  = "the stack POP, the counterpart to BP_AddWidget",
      expect = "FIRES when a pushed screen is dismissed" },

    -- ---- Palworld's own screen service ----
    { path = "/Script/Pal.PalHUDService:Push", kind = "native",
      from = "Pal.hpp:20487",
      why  = "'push a stackable UI'. Inventory, build menu, map and pause are all "
          .. "UPalUserWidgetStackableUI, so this is the single Palworld-side call every one of "
          .. "the operator's three actions passes through",
      fired = "CONFIRMED 2026-08-02 23:04, first fire at +25.6 s — SHIPPED as a driver. This is "
           .. "the object UPalUIManagerSubsystem (0 declared functions) turned out not to be",
      expect = "FIRES once per screen the operator opens" },
    { path = "/Script/Pal.PalHUDService:Close", kind = "native",
      from = "Pal.hpp:20518",
      why  = "the close half of Push, by widget id",
      fired = "CONFIRMED 2026-08-02 23:04, first fire at +27.8 s — SHIPPED as a driver",
      expect = "FIRES once per screen closed" },
    { path = "/Script/Pal.PalHUDService:ShowCommonUI", kind = "native",
      from = "Pal.hpp:20480",
      why  = "the enum-keyed open (EPalWidgetBlueprintType) — the route a dialog, a warning or a "
          .. "reward popup takes rather than Push",
      expect = "FIRES on popups; may be silent across the three asked-for actions" },
    { path = "/Script/Pal.PalHUDService:AddHUD", kind = "native",
      from = "Pal.hpp:20521",
      why  = "the service side of adding a HUD widget — the thing that changes what is on screen "
          .. "without any menu being opened at all",
      expect = "FIRES during world load, then rarely" },
    { path = "/Script/Pal.PalHUDService:RemoveHUD", kind = "native",
      from = "Pal.hpp:20486",
      why  = "its counterpart, and the one that would fire during a teardown to title",
      expect = "FIRES on return to title" },

    -- ---- the HUD layout's own add/remove path: four of the fourteen the last run walked ----
    { path = "/Script/Pal.PalUIHUDLayoutBase:AddHUD", kind = "native",
      from = "Pal.hpp:30714",
      why  = "the layout ACCEPTING a widget — the last leg of the service call above and the one "
          .. "closest to 'the screen now contains something new'. It was in the fourteen the "
          .. "2026-08-02 run enumerated and the word filter skipped it",
      expect = "FIRES with the service's AddHUD, roughly one for one" },
    { path = "/Script/Pal.PalUIHUDLayoutBase:RemoveHUD", kind = "native",
      from = "Pal.hpp:30712",
      why  = "the layout dropping a widget. Same fourteen, same skip",
      expect = "FIRES on teardown" },
    { path = "/Script/Pal.PalUIHUDLayoutBase:AddWorldHUD", kind = "native",
      from = "Pal.hpp:30713",
      why  = "world-space HUD (nameplates, markers). Worth counting because it is the candidate "
          .. "most likely to fire CONSTANTLY, which is a disqualification and therefore a result",
      expect = "FIRES a lot in ordinary play — probably too much to drive a refresh" },
    { path = "/Script/Pal.PalUIHUDLayoutBase:RemoveWorldHUD", kind = "native",
      from = "Pal.hpp:30711",
      why  = "its counterpart; the pair's RATIO says whether world HUD churn is steady or bursty",
      expect = "FIRES a lot, tracking AddWorldHUD" },

    -- ---- the HUD actor: the other end of the service ----
    { path = "/Script/Pal.PalHUDInGame:PushWidgetStackableUI", kind = "native",
      from = "Pal.hpp:9740",
      why  = "the actor-side push. Armed ALONGSIDE the service's Push on purpose: if one fires "
          .. "and the other does not, that names which of the two objects a pack should be "
          .. "watching, and no dump can answer that",
      expect = "FIRES with PalHUDService:Push" },
    { path = "/Script/Pal.PalHUDInGame:CreateHUDWidget", kind = "native",
      from = "Pal.hpp:9748",
      why  = "the actual widget CONSTRUCTION — earliest point at which a new screen exists",
      expect = "FIRES once per widget built" },
    { path = "/Script/Pal.PalHUDInGame:CloseHUDWidget", kind = "native",
      from = "Pal.hpp:9751",
      why  = "construction's counterpart",
      expect = "FIRES once per widget closed" },
    { path = "/Script/Pal.PalHUDInGame:BP_SetupPlayerUI", kind = "native",
      from = "Pal.hpp:9752",
      why  = "the whole player UI being built. Not a per-screen driver — it is the WORLD-LOAD "
          .. "marker, and having it counted is what lets every other number be read as 'during "
          .. "the storm' or 'after it'",
      expect = "FIRES once per world load" },

    -- ---- the BlueprintImplementableEvents: expected silent, armed to prove it ----
    { path = "/Script/Pal.PalUserWidget:OnSetup", kind = "bpevent",
      from = "Pal.hpp:31902",
      why  = "the per-screen 'I am being set up' on the base every Palworld screen derives from. "
          .. "The one every previous pass named first and the one this file expects least from",
      expect = "SILENT — a BP override carries its own UFunction" },
    { path = "/Script/Pal.PalUserWidget:OnClosed", kind = "bpevent",
      from = "Pal.hpp:31903",
      why  = "its counterpart, same class, same expectation",
      expect = "SILENT — same reason" },
    { path = "/Script/CommonUI.CommonActivatableWidget:BP_OnActivated", kind = "bpevent",
      from = "CommonUI.hpp:174",
      why  = "CommonUI's blueprint-facing activation event. Armed as the CONTROL for the pair "
          .. "above: if ActivateWidget fires and this does not, the BP-override rule is measured "
          .. "on this build rather than quoted from UE documentation",
      expect = "SILENT while ActivateWidget fires" },
    { path = "/Script/CommonUI.CommonActivatableWidget:BP_OnDeactivated", kind = "bpevent",
      from = "CommonUI.hpp:173",
      why  = "the same control on the closing side",
      expect = "SILENT while DeactivateWidget fires" },
}

-- How many hooks this run is willing to leave armed for the session. See warning 1. The list
-- above is 21 long and ordered, so a lower cap costs the bpevent controls first.
local ARM_CAP = 24

-- DEMOTED, not deleted. This filter used to decide what got armed and produced two false
-- positives out of two (see the header). It now only reports names the walk found that nobody
-- named in CANDIDATES — a nudge for the NEXT edit of this file, never something that arms.
local WORDS = { "Open", "Show", "Construct", "Refresh", "Update", "Setup", "Activate", "Push",
                "Add", "Remove", "Create", "Close" }

local function wanted(name)
    for _, w in ipairs(WORDS) do if name:find(w, 1, true) then return true end end
    return false
end

-- Every UFunction on a class, by the two routes the item names: ForEachFunction when this
-- UE4SS build binds it, else the Children/.Next walk. Returns { name, fn } pairs.
--
-- ⚠️ NEITHER ROUTE FOLLOWS INHERITANCE. UStruct.Children is a class's own list and
-- ForEachFunction measured out at exactly the own-declaration counts on 2026-08-02 (5 / 1 / 8,
-- which is what dumps/cxx declares for those three). That is finding (2) in the header, and it
-- is why CLASSES names the bases and why ARMING does not depend on this walk at all.
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
        s = { armed = false, counts = {}, order = {}, firstAt = {}, t0 = os.clock(),
              armedPaths = {}, announced = {} }
        _G.__PalForgeUIUpdateHook = s
    end
    -- An older run of this file left a state table without `announced`; adding it here rather
    -- than only in the constructor is what makes an F9 reload onto the new code survivable.
    if type(s.announced) ~= "table" then s.announced = {} end
    return s
end

-- The candidate record for a path, so a report line can say WHY a path was armed without
-- carrying the reason through the hook body (which is two integer writes and stays that way).
local function candidateOf(path)
    for _, c in ipairs(CANDIDATES) do if c.path == path then return c end end
    return nil
end

hooks.declare{
    id    = "ui-update-event",
    item  = "Closed 2026-08-02 — three native update entry points fire",
    needs = { world = true },
    desc  = "arms 21 NAMED UI-rebuild candidates from dumps/cxx — CommonUI's activatable "
         .. "lifecycle, the CommonUI stack, PalHUDService, the HUD actor and the HUD layout's "
         .. "own add/remove path — and reports which ones actually fire, and in what order. "
         .. "3 of the 21 are ANSWERED (2026-08-02 23:04) and shipped as :autoRefresh's driver; "
         .. "this run is for the other 18 and for what a return to title does",
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
        h:section("[1] the classes, and their OWN UFunctions with parameter offsets")
        --------------------------------------------------------------------
        h:note("WHAT THIS BLOCK IS AND IS NOT. It is a walk of each class's OWN declarations — "
            .. "inheritance is NOT followed by either route, which is why the four screen "
            .. "classes on their own turned up 14 functions and no rebuild signal on 2026-08-02. "
            .. "Nothing in block [2] is armed from what this block finds; the arming list is "
            .. "written by hand from dumps/cxx and is checked against these declarations here.")
        local declared, missed = {}, {}
        for _, entry in ipairs(CLASSES) do
            local full = "/Script/" .. entry.pkg .. "." .. entry.name
            local cls, cdo
            pcall(function() cls = StaticFindObject(full) end)
            pcall(function() cdo = StaticFindObject("/Script/" .. entry.pkg .. ".Default__" .. entry.name) end)
            h:log("CLASS %s\n  WHY %s", full, entry.why)
            h:value(full, probe.valid(cls) and probe.full(cls) or "nil — ABSENT")

            -- The class object is what carries the functions; a CDO does not answer
            -- ForEachFunction, its class does (test/probe.lua:189-192 records that).
            local owner = probe.valid(cls) and cls or nil
            if not owner and probe.valid(cdo) then
                pcall(function() owner = cdo:GetClass() end)
                if probe.valid(owner) then
                    h:note("%s resolved only as a CDO; its class %s is what is walked",
                        entry.name, probe.name(owner))
                end
            end
            if not probe.valid(owner) then
                h:value(entry.name .. " functions", "not enumerated — neither the class nor a CDO resolved")
            else
                local fns, how = functionsOf(owner)
                h:value(entry.name .. " functions", string.format("%d, via %s", #fns, how))
                for _, fn in ipairs(fns) do
                    local path = full .. ":" .. fn.name
                    declared[path] = true
                    -- Each function's OWN child properties, with class and offset. This is the
                    -- half that says whether a firing would carry anything usable: a rebuild
                    -- signal with a widget parameter is worth far more than a bare notification.
                    local props = {}
                    pcall(function()
                        fn.fn:ForEachProperty(function(p)
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
                    h:log("FN %s::%s%s", entry.name, fn.name,
                        #props > 0 and ("\n" .. table.concat(props, "\n")) or "  (no parameters)")
                    if wanted(fn.name) and not candidateOf(path) then
                        missed[#missed + 1] = path
                    end
                end
            end
        end

        --------------------------------------------------------------------
        h:section("[2] the named candidates, checked against the walk, then armed")
        --------------------------------------------------------------------
        -- A candidate the walk did NOT see is not necessarily wrong — a class may fail to
        -- resolve, or ForEachFunction may return nothing on this UE4SS build — but it is the
        -- first thing to look at if RegisterHook then refuses it, so the two facts are printed
        -- side by side rather than in two different blocks.
        local seenCount = 0
        for _, c in ipairs(CANDIDATES) do
            if declared[c.path] then seenCount = seenCount + 1 end
            h:log("CAND %-8s %-72s %s\n  WHY    %s\n  EXPECT %s\n  WALK   %s%s",
                c.kind, c.path, c.from, c.why, c.expect,
                declared[c.path] and "declared on the class the walk read"
                                 or "NOT seen by the walk (see the class's line in [1])",
                c.fired and ("\n  PRIOR  " .. c.fired) or "")
        end
        h:value("candidates NAMED from dumps/cxx", #CANDIDATES)
        h:value("of those, confirmed by the live walk", seenCount)

        if #missed > 0 then
            table.sort(missed)
            h:note("the demoted word filter also matched %d function(s) that NOBODY NAMED. This "
                .. "is a nudge for the next edit of this file, not something that gets armed — "
                .. "the last run armed two such matches and both were false positives:", #missed)
            for _, p in ipairs(missed) do h:log("UNNAMED %s", p) end
        else
            h:note("the demoted word filter found nothing the named list had missed.")
        end

        if type(RegisterHook) ~= "function" then
            h:fail("RegisterHook is unavailable this session, so nothing could be armed and the "
                .. "candidate list above is all this run produced.")
            return
        end
        h:warn("about to arm up to %d hook(s). ⚠️ UE4SS CANNOT UNREGISTER ONE: every hook armed "
            .. "here stays for the life of this process, and only quitting the game removes it.",
            math.min(#CANDIDATES, ARM_CAP))

        local armed, refused = 0, 0
        for _, c in ipairs(CANDIDATES) do
            local path = c.path
            if armed + refused >= ARM_CAP then
                h:warn("stopping at the cap: %d further candidate(s) were NOT armed, so a zero "
                    .. "against them below would be the absence of a counter rather than the "
                    .. "absence of a firing.", #CANDIDATES - armed - refused)
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
        h:value("armed", string.format("%d of %d candidate(s); %d refused", armed, #CANDIDATES, refused))
        if armed == 0 then
            h:fail("not one candidate could be armed. That is a finding about this build's "
                .. "hookability, not about UI rebuilds, and it contradicts the click router — "
                .. "which arms /Script/CommonUI.CommonButtonBase:HandleButtonClicked at every "
                .. "startup. Check the log for 'clicks: native route armed' before believing it.")
            return
        end

        --------------------------------------------------------------------
        h:section("[3] what the SHIPPED driver says, in this same session")
        --------------------------------------------------------------------
        -- THE INSTRUMENT AND THE IMPLEMENTATION, SIDE BY SIDE. Three of the candidates above are
        -- now a shipped refresh driver (native/ui/refresh.lua, ridden by api/ui.lua's
        -- Handle:autoRefresh). The failure this block exists to catch is the one that produced
        -- this hook's own rewrite: a report that runs ahead of the fact. If UI.refreshDriver()
        -- says "event+poll" while the paths below are silent, or says "poll" while they fire, the
        -- two halves have drifted and this is where it shows.
        local okD, driver = pcall(function() return require("palforge.api.ui").refreshDriver(500) end)
        if not okD or type(driver) ~= "table" then
            h:value("UI.refreshDriver()", "unavailable: " .. tostring(driver))
        else
            h:value("UI.refreshDriver().kind", tostring(driver.kind))
            h:value("UI.refreshDriver().state", tostring(driver.state))
            h:value("UI.refreshDriver().event", tostring(driver.event))
            h:value("UI.refreshDriver().staleMs / eventStaleMs",
                string.format("%s / %s", tostring(driver.staleMs), tostring(driver.eventStaleMs)))
            h:log("WHY %s", tostring(driver.why))
            h:note("state = \"waiting\" here is CORRECT and not a defect: the runtime signal is "
                .. "armed at world.ready and only once a pack has actually asked for a refresh "
                .. "driver (:autoRefresh / :autoMount). A session with no PalForge panel mounted "
                .. "arms nothing, which is the point — UE4SS cannot unregister a hook.")
        end
        local okS, rsrc = pcall(require, "palforge.native.ui.refresh")
        if okS and type(rsrc) == "table" then
            local okL, lines = pcall(rsrc.report)
            if okL and type(lines) == "table" then
                for _, line in ipairs(lines) do h:log("%s", line) end
            end
            h:value("refresh.generation()", tostring(rsrc.generation()))
        end

        --------------------------------------------------------------------
        h:section("[4] what to do in game")
        --------------------------------------------------------------------
        h:ask("open your INVENTORY and close it, then open the BUILD MENU, then RETURN TO THE "
            .. "TITLE SCREEN — and this time DO THE THIRD ONE: the 23:04 run stopped after two "
            .. "screens and that is exactly why 18 candidates are silent rather than dead. If you "
            .. "can also open a popup (a reward, a warning, a confirmation dialog), that is what "
            .. "would exercise PalHUDService:ShowCommonUI. A FIRST FIRE is announced the moment "
            .. "it happens; full reports print at 30 s, 120 s, 300 s and 600 s.")
        h:note("this hook keeps reporting after this block closes: look for further "
            .. "#### BEGIN ui-update-event-1 / -2 / -3 / -4 blocks below, and for FIRSTFIRE lines "
            .. "in between them.")

        local phase = 0
        poll.every("ui-update-event", function(elapsed)
            local s = state()

            -- FIRST FIRE, announced immediately. The 2026-08-02 session ended before the second
            -- verdict printed, so the single most valuable line — "this path fires at all" — is
            -- no longer held back until one. Costs one integer compare per beat.
            for _, path in ipairs(s.order) do
                if not s.announced[path] then
                    s.announced[path] = true
                    local c = candidateOf(path)
                    h:log("FIRSTFIRE %s  at +%.1f s  (%s; expected: %s)", path,
                        (s.firstAt[path] or 0) - s.t0,
                        c and c.kind or "?", c and c.expect or "?")
                end
            end

            -- FOUR REPORTS OVER TEN MINUTES, and the early ones are PROGRESS rather than a
            -- verdict. The old schedule was 20/60/150 s and stopped at 155, which handed the
            -- operator a deadline: open the inventory inside two and a half minutes or the hook
            -- has already decided. On 2026-08-02 that produced "armed 2, silent 2" from a
            -- session where the menus were opened — and the two armed names turned out to be
            -- substring false positives anyway. A hook that needs a person should wait for one.
            local due = (elapsed >= 30  and phase < 1) and 1
                or (elapsed >= 120 and phase < 2) and 2
                or (elapsed >= 300 and phase < 3) and 3
                or (elapsed >= 600 and phase < 4) and 4 or nil
            if not due then return elapsed >= 605 end
            phase = due
            h:beginBlock(phase)
            local fired = 0
            -- FIRST-FIRE ORDER, which is the half of the answer a bare count cannot give: it
            -- says which signal leads a rebuild and which trails it.
            for i, path in ipairs(s.order) do
                fired = fired + 1
                local c = candidateOf(path)
                h:log("FIRED %2d. %s  (first at +%.1f s, %d call(s) so far)  expected: %s",
                    i, path, (s.firstAt[path] or 0) - s.t0, s.counts[path] or 0,
                    c and c.expect or "?")
            end
            local silent = {}
            for path, count in pairs(s.counts) do
                if count == 0 then silent[#silent + 1] = path end
            end
            table.sort(silent)
            h:value("fired at least once", fired)
            h:value("armed and SILENT", #silent)
            for _, path in ipairs(silent) do
                local c = candidateOf(path)
                h:log("SILENT %s  (%s; expected: %s)", path,
                    c and c.kind or "?", c and c.expect or "?")
            end
            -- ⚠️ phase >= 3, NOT phase == 3. The schedule has four steps (30 / 120 / 300 / 600 s)
            -- and this used to stop the poller at the third, so the fourth arm of `due` was dead
            -- code and the 600 s report never existed. A hook that asks the operator to return to
            -- the title screen must still be counting when they get back.
            if phase >= 3 then
                h:note("HOW TO READ IT. (a) a path that fired when the inventory opened and again "
                    .. "when it closed is a REBUILD SIGNAL and is what autoRefresh should ride — "
                    .. "check its call count against how many times you opened something. "
                    .. "(b) a `bpevent` that is silent while its `native` neighbour fires is the "
                    .. "BP-override rule MEASURED on this build: a BlueprintImplementableEvent "
                    .. "implemented in a BP gets its OWN UFunction and a hook on the base never "
                    .. "sees it. That is a closed answer, not a missing one. (c) a path that "
                    .. "fired thousands of times during the return to title is a load-storm "
                    .. "signal and is unusable as an unconditional driver whatever else it does "
                    .. "— core/event's worldReady gate would have to wrap it, and the hook is "
                    .. "still CALLED during the storm. (d) a `native` path that is silent through "
                    .. "all three actions is a genuine negative and belongs in api/ui.lua's "
                    .. "autoRefresh doc by name and date.")
                h:note("WHAT WAS DONE WITH THE FIRST THREE WINNERS, so a fourth is wired the same "
                    .. "way: native/ui/refresh.lua arms the path with a handler of THREE INTEGER "
                    .. "WRITES and nothing else, api/ui.lua's poll() reads its generation() once "
                    .. "per 500 ms heartbeat and refreshes at most once per beat — so a storm "
                    .. "costs increments, not renders — and only then does UI.refreshDriver() "
                    .. "report it, from what is actually armed rather than from a constant. The "
                    .. "poll stays as the FLOOR either way. Add a fourth by adding it to "
                    .. "native/ui/refresh.lua's SIGNALS with the dump line and the run that "
                    .. "measured it, and nothing else changes.")
                h:note("⚠️ AND WHAT A SILENT CANDIDATE IS STILL NOT: proof that it cannot fire. "
                    .. "The 2026-08-02 23:04 run left 18 silent because the operator opened two "
                    .. "screens. If this run's silent list is shorter, that is what a different "
                    .. "set of actions bought — record the actions with the numbers.")
            end
            h:endBlock(phase)
            return phase >= 4
        end)
    end,
}
