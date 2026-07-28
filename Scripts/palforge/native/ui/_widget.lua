-- PalForge native.ui._widget: reusable native-UMG toolkit. Builds in-game UI from
-- Palworld's OWN widgets + native UMG, in Lua (no cooked WidgetBlueprints). The
-- native UI elements (button, title_menu) use this in their render() to assemble
-- their widget trees. The element LIFECYCLE lives in palforge.api.ui; this module
-- only builds/wires widgets — it holds no lifecycle or watch loop.
--
-- Three ways to get a host for those widgets: inject into a panel the game already
-- has (title_menu does that on the title screen), hang one off the game's own live
-- in-game UI root with M.gameUIRoot(), or make one of your own with M.screen() — the
-- UserWidget + WidgetTree + AddToViewport sequence verified in poc/V6-ui-native.
--
-- Ported self-contained apart from core/signature, which is not optional: two calls
-- here take arguments whose declared types decide whether the call is safe at all, and
-- a wrong TYPE faults inside UE4SS's marshalling where pcall cannot see it. signature
-- walks the live UFunction and refuses instead. Includes the shared CLICK ROUTER: one
-- RegisterHook on CommonButtonBase dispatches to whichever callback registered the
-- clicked button; it is installed lazily on the first registerClick().

local sig = require("palforge.core.signature")

local M = {}

local function log(msg) pcall(print, "[PalForge.ui] " .. tostring(msg)) end
local function err(msg) pcall(print, "[PalForge.ui] ERR " .. tostring(msg)) end

-- Is this a widget we can still talk to? Everything here goes through pcall: the
-- engine globals may be absent (no game) and a widget the game already destroyed
-- can throw on IsValid itself.
function M.alive(w)
    local ok, v = pcall(function() return w and w:IsValid() end)
    return ok and v == true
end
local alive = M.alive

-- FindFirstOf that cannot throw, not even when UE4SS is not there at all.
-- Returns the object only if it is alive; nil otherwise.
function M.findFirst(class)
    local ok, o = pcall(function()
        local x = FindFirstOf(class)
        if x and x:IsValid() then return x end
        return nil
    end)
    return (ok and o) or nil
end

-- Known Palworld UI asset/class paths. The title-screen entries were read off
-- WBP_Title_MenuButton and the title screen (verified 2026-07-17, poc/V7-title-injection);
-- dumps/cxx re-confirms both names PalForge matches by string, `Test_Content` and
-- `WBP_PalInvisibleButton`, as declared members of the button class
-- (dumps/cxx/WBP_Title_MenuButton.hpp:14-15).
--
-- The IN-GAME host is the last two entries, and it is the one thing this table used to be
-- missing. What is wanted is a child inside the game's own live UI that is a UPanelWidget,
-- i.e. answers AddChild; the dump names one outright:
--
--   dumps/cxx/WBP_PalOverallUILayout.hpp:4   class UWBP_PalOverallUILayout_C : UPalPrimaryGameLayoutBase
--                                       :9     class UCanvasPanel* CanvasPanel_Root;
--
-- UPalPrimaryGameLayoutBase is Pal.hpp:27311, a UPrimaryGameLayout (CommonGame.hpp:156) — the
-- CommonUI root the whole in-game UI stacks onto. A UCanvasPanel is a UPanelWidget
-- (UMG.hpp:344), so it answers UPanelWidget::AddChild (UMG.hpp:1087) and hands back a
-- UCanvasPanelSlot (UMG.hpp:347, :350). LIVE CONFIRMATION: an instance of that class is alive
-- under the game instance with its own WidgetTree —
-- `BP_PalGameInstance_C_2147482476.WBP_PalOverallUILayout_C_2147481885.WidgetTree_2147481884`
-- (dumps/reflection/03_widgets.txt:54). Not observed: nobody has watched a widget appear there.
--
-- WHAT THE DUMP ELIMINATED, so nobody re-walks it. UPalUIHUDLayoutBase (Pal.hpp:30707) has no
-- panel child to find: it is a native UCommonActivatableWidget and declares no widget members
-- at all. It offers an API instead — AddHUD(UPalUserWidget*, int32) / RemoveHUD (Pal.hpp:30714,
-- :30712) — which M.screen cannot use, because its parameter is a UPalUserWidget (Pal.hpp:31888)
-- and M.screen builds a plain /Script/UMG.UserWidget.
--
-- ⚠️ THAT IS A FACT ABOUT M.screen, NOT ABOUT THE ROUTE. UI.Frame builds WBP_PalCommonWindow_C,
-- which IS a UPalUserWidget, and the whole family of game-owned entry points is therefore open
-- to it: AddHUD with a z, BP_AddWidget onto a CommonUI layer, and the activatable's own
-- InputConfig. Read "THE GAME'S OWN UI ROUTE" further down this file before adding a host — it
-- is where the two live runs that broke Esc were finally explained.
M.PATHS = {
    menuButton      = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C",
    palTextBlock    = "/Game/Pal/Blueprint/UI/PalTextBlock/BP_PalTextBlock.BP_PalTextBlock_C",
    invisibleButton = "/Game/Pal/Blueprint/UI/System/Style/WBP_PalInvisibleButton.WBP_PalInvisibleButton_C",
    menuButtonLabel = "Test_Content",      -- label widget inside WBP_Title_MenuButton
    menuButtonClick = "WBP_PalInvisibleButton",
    -- Kept as a NAME even though nothing calls it any more: the probe proved this really is
    -- the button's inner box, and the next reader deserves that fact rather than an absence.
    -- Its slot is a CanvasPanelSlot, which cannot be aligned without a struct call.
    menuButtonInner = "HorizontalBox_0",
    gameUILayout    = "PalPrimaryGameLayoutBase",  -- the live in-game UI root, by native class
    gameUIRoot      = "CanvasPanel_Root",          -- its root UCanvasPanel: the injection host
    -- ---- looking NATIVE: the game's own frame and label, by the child names they declare ----
    -- WBP_PalCommonWindow_C is a pure content frame — ONE member, a UNamedSlot, and no functions
    -- at all (dumps/cxx/WBP_PalCommonWindow.hpp:4-6). A UNamedSlot is a UContentWidget
    -- (UMG.hpp:1042 -> :505), so it takes our tree through SetContent, exactly as UBorder does.
    -- It is the window every Palworld dialog is built out of: seven distinct classes declare one
    -- (dumps/reflection/03_widgets.txt:6, 165, 166, 172, 221, 280, 340), including the game's own
    -- mod-disclaimer dialog.
    windowSlot      = "NamedSlot_91",
    -- WBP_CommonButton_C's own label child and clickable child (WBP_CommonButton.hpp:12-13).
    commonButtonLabel = "Text_Main",
}

-- Slate alignment enums, named so callers don't memorize integers.
M.HALIGN = { FILL = 0, LEFT = 1, CENTER = 2, RIGHT = 3 }
M.VALIGN = { FILL = 0, TOP = 1, CENTER = 2, BOTTOM = 3 }
M.SIZE   = { AUTO = 0, FILL = 1 }

-- ---- shared click router (ported from the old clicks module) ----
--
-- WHAT ACTUALLY FIRES ON A CLICK, settled from the dump rather than from hope.
--
-- The premise this router was rewritten under — "HandleButtonClicked is not a member of
-- UCommonButtonBase" — is FALSE. It is declared, on the class, in this build:
--
--   dumps/cxx/CommonUI.hpp:258   class UCommonButtonBase : public UCommonUserWidget
--   dumps/cxx/CommonUI.hpp:346       void HandleButtonClicked();
--
-- and it is the right SHAPE as well as the right name. The rule this tree keeps re-learning is
-- that RegisterHook sees what ProcessEvent runs — a delegate TARGET, an RPC or a
-- BlueprintCallable, never a broadcaster — and HandleButtonClicked is a delegate target: the
-- inner UCommonButtonInternalBase (CommonUI.hpp:411, a UButton) broadcasts OnClicked and the
-- bound target is this UFunction, invoked through ProcessEvent like every AddDynamic target.
--
-- THE BROADCASTER, so nobody hooks it by mistake. `OnButtonBaseClicked` (CommonUI.hpp:287) is a
-- multicast delegate PROPERTY. Its targets are generated per blueprint, and the title button
-- shows exactly that — three of them, one per binding:
--   dumps/cxx/WBP_Title_MenuButton.hpp:23-25
--     BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_
--       CommonButtonBaseClicked__DelegateSignature(UCommonButtonBase* Button)
-- A hook on the delegate's signature function catches none of those, because none of them IS
-- that function; they merely share its parameter list.
--
-- SO WHY DID NOTHING HAPPEN. Because this code could not tell you. The old installClicks
-- wrapped RegisterHook in a bare pcall, threw the error text away, discarded the (pre, post)
-- ids it returns on success, and printed "hook installed" / "hook FAILED" with no reason
-- attached. "There is no CommonUI line in the log" is not evidence either way: UE4SS logs its
-- own `[RegisterHook] Registered native hook` at LogLevel::Verbose (LuaMod.cpp:4151) and a
-- refusal is thrown into Lua, where that pcall ate it. A silent failure is the bug — so this
-- router now records, per route, whether it armed, with which ids, and with what refusal.
--
-- TWO ROUTES, NOT ONE, because there are two independent places a Palworld button's click
-- passes through and only a live run can say which one this build actually delivers:
--
--   [native] /Script/CommonUI.CommonButtonBase:HandleButtonClicked      CommonUI.hpp:346
--            One hook for every CommonUI button in the game. FUNC_Native, so UE4SS takes the
--            native branch (LuaMod.cpp:4141-4152) and hooks the UFunction's Func pointer.
--   [bp]     <WBP_PalCommonButtonBase_C>:BP_OnClicked                   WBP_PalCommonButtonBase.hpp:20
--            UCommonButtonBase::BP_OnClicked is a BlueprintImplementableEvent, and Palworld's
--            button base OVERRIDES it — which means the derived class carries its OWN UFunction
--            of that name and a hook on the CommonUI one would never see it (the same trap
--            recorded against OnSetup/OnClosed in api/ui.lua). Every button this file can build
--            is one of these: WBP_PalCommonButton_C (WBP_PalCommonButton.hpp:4) and
--            WBP_PalInvisibleButton_C (WBP_PalInvisibleButton.hpp:4) both derive from
--            WBP_PalCommonButtonBase_C (WBP_PalCommonButtonBase.hpp:4).
--            Its path is NOT written down here. It is read off a LIVE button's own class at arm
--            time — the same "ask the world what is loaded" move buttonClass() makes — so a
--            blueprint that moves cannot turn this into a lookup by a name that does not exist.
--
-- Both fire for the same click on the same widget, so a dispatch is de-duplicated per widget on
-- a short ELAPSED window (never a tick count). Which route delivered the first click of the
-- session is logged, once, because that is the fact neither the dump nor this comment can settle.
local handlers = {}   -- fullName -> fn
local lastFire = {}   -- fullName -> os.clock() of its last dispatch, for the cross-route dedupe

-- Both hooks fire microseconds apart inside one ProcessEvent chain, and the fastest human
-- double-click is an order of magnitude slower than this, so the window separates the two
-- routes without ever merging two real clicks. os.clock is the same clock core/poll bounds
-- its pollers on.
M.CLICK_DEDUPE = 0.05

-- The classes the blueprint route reads its path off. NOT M.BUTTON_CLASSES: that list now leads
-- with WBP_CommonButton_C, which is a plain UUserWidget (WBP_CommonButton.hpp:4) and has no
-- BP_OnClicked of its own. These two are the ones that ARE WBP_PalCommonButtonBase_C.
M.BP_CLICK_CLASSES = { "WBP_PalInvisibleButton_C", "WBP_PalCommonButton_C" }

-- One record per route: what it is, whether it armed, and what it has SEEN. `seen` counts
-- every click on every button of that kind in the whole game, which is the diagnostic that
-- separates "the hook never fires" from "the hook fires and our widget never gets the click".
M.clickRoutes = {
    { id = "native", state = "pending", seen = 0, dispatched = 0,
      path = "/Script/CommonUI.CommonButtonBase:HandleButtonClicked",
      what = "UCommonButtonBase::HandleButtonClicked (CommonUI.hpp:346)" },
    { id = "bp",     state = "pending", seen = 0, dispatched = 0,
      path = nil,   -- read off a live button at arm time; see blueprintClickPath below
      what = "WBP_PalCommonButtonBase_C::BP_OnClicked (WBP_PalCommonButtonBase.hpp:20)" },
}

local function fullName(w)
    local ok, n = pcall(function() return w:GetFullName() end)
    return ok and n or nil
end

-- One click, arriving through one route. `ctx` is UE4SS's RemoteUnrealParam for the hook's
-- context object (LuaMod.cpp:144 constructs it as an ObjectProperty), so `:get()` is how
-- the button itself is reached — and it is the ONE call here that is allowed to fail quietly,
-- because it fails identically for every button in the game and would otherwise print per click.
local function dispatch(route, ctx)
    route.seen = route.seen + 1
    local name
    local ok = pcall(function() name = ctx:get():GetFullName() end)
    if not ok or type(name) ~= "string" then
        route.unnamed = (route.unnamed or 0) + 1
        return
    end
    local fn = handlers[name]
    if not fn then return end

    local now, prev = os.clock(), lastFire[name]
    if prev and (now - prev) < M.CLICK_DEDUPE then
        route.deduped = (route.deduped or 0) + 1
        return
    end
    lastFire[name] = now
    route.dispatched = route.dispatched + 1
    if not route.delivered then
        route.delivered = true
        log(string.format("clicks: FIRST delivery came through the %s route (%s)",
            route.id, route.what))
    end
    local oke, e = pcall(fn)
    if not oke then err("click handler: " .. tostring(e)) end
end

-- Arm one route. Everything RegisterHook can tell us is kept: the two callback ids it returns
-- on success (LuaMod.cpp:4185-4186) and the message it throws on refusal — which names whether
-- the UFunction was not found, or was found and is neither a native nor a script function
-- (LuaMod.cpp:4134, :4176-4183). Each outcome is logged once per route, never once per button.
local function arm(route)
    if route.state == "armed" then return true end
    if type(RegisterHook) ~= "function" then
        route.state, route.why = "refused", "RegisterHook is not available in this session"
    elseif type(route.path) ~= "string" or #route.path == 0 then
        route.state, route.why = "pending", route.why or "no path resolved yet"
    else
        local ok, a, b = pcall(RegisterHook, route.path, function(ctx) dispatch(route, ctx) end)
        if ok then
            route.state, route.why, route.ids = "armed", nil, { a, b }
        else
            route.state, route.why = "refused", tostring(a)
        end
    end
    -- Log a state CHANGE, not a state. A retry that fails the same way every time says nothing
    -- new, and this is reached from registerClick — i.e. once per button built.
    if route.state ~= route.logged then
        route.logged = route.state
        if route.state == "armed" then
            log(string.format("clicks: %s route armed (%s) ids=%s,%s", route.id, route.path,
                tostring(route.ids and route.ids[1]), tostring(route.ids and route.ids[2])))
        else
            log(string.format("clicks: %s route %s — %s", route.id, route.state,
                tostring(route.why)))
        end
    end
    return route.state == "armed"
end

-- The blueprint route's path, read off whatever button class this world has loaded. Not a
-- constant, on purpose: `/Game/Pal/Blueprint/UI/System/Style/WBP_PalCommonButtonBase...` is a
-- path nobody in this tree has verified, and a lookup by a name that does not exist is the
-- exact failure mode that produced this rewrite. sig.find walks the live super chain, so a
-- WBP_PalCommonButton_C instance answers with the UFunction its BASE declares; GetFullName then
-- spells it in the "Function <outer>:<name>" form RegisterHook parses (LuaMod.cpp:85-96).
---@return string? path, string? why
local function blueprintClickPath()
    local inst
    for _, name in ipairs(M.BP_CLICK_CLASSES) do
        local o = M.findFirst(name)
        if alive(o) then inst = o; break end
    end
    if not inst then
        return nil, "no live WBP_PalCommonButtonBase_C to read BP_OnClicked off (needs a world "
            .. "with UI up)"
    end
    local fn = sig.find(inst, "BP_OnClicked")
    if not fn then
        return nil, "BP_OnClicked is not reachable from a live " .. M.widgetName(inst)
    end
    local full
    pcall(function() full = fn:GetFullName() end)
    if type(full) ~= "string" or #full == 0 then
        return nil, "BP_OnClicked was found but has no readable full name"
    end
    -- THE CHECK THAT MAKES THIS ROUTE WORTH ARMING. UCommonButtonBase declares BP_OnClicked
    -- itself, as a BlueprintImplementableEvent (CommonUI.hpp:375) — so a super-chain walk that
    -- runs past the blueprint lands on the BASE's stub, whose full name lives under /Script/.
    -- Hooking that one catches exactly the classes that do NOT override it, i.e. none of
    -- Palworld's buttons, while reporting itself as armed. Refuse instead of arming a lie.
    if full:find("/Script/", 1, true) then
        return nil, "BP_OnClicked resolved to the CommonUI base (" .. full .. "), not to a "
            .. "blueprint override — a hook there can never see the override"
    end
    return full
end

-- Install the dispatch hooks (idempotent). Called at load AND from registerClick.
--
-- ⚠️ ARM THIS EAGERLY, not on first registration. It used to be reached only from
-- registerClick, so a button class with no bindable child meant registerClick was never called,
-- which meant the hook was never registered, which meant NO button in the mod could ever be
-- clicked — and the only symptom was silence. A hook that costs one lookup per click is not
-- worth making conditional on anything.
--
-- The blueprint route CANNOT arm at load: its path is read off a live button and there is no
-- world at load. That is why this stays callable — registerClick calls it again from inside a
-- world, and the route arms then. Retrying is free; `arm` returns immediately once armed.
function M.installClicks()
    local armed = 0
    for _, route in ipairs(M.clickRoutes) do
        if route.id == "bp" and route.state ~= "armed" and not route.path then
            local path, why = blueprintClickPath()
            route.path, route.why = path, why
        end
        if arm(route) then armed = armed + 1 end
    end
    return armed > 0
end

---What the click router is doing, as printable lines. This is the whole point of the rewrite:
---a run can now say "the native route is armed, it has seen 14 clicks, none of them ours" —
---which names the step that refused instead of leaving silence to mean four different things.
---@return string[]
function M.clickReport()
    local out, n = {}, 0
    for _ in pairs(handlers) do n = n + 1 end
    out[#out + 1] = string.format("clicks: %d handler(s) registered", n)
    for _, r in ipairs(M.clickRoutes) do
        out[#out + 1] = string.format(
            "clicks: %-6s %-8s seen=%d dispatched=%d%s%s | %s%s",
            r.id, r.state, r.seen, r.dispatched,
            r.deduped and (" deduped=" .. r.deduped) or "",
            r.unnamed and (" unnamed=" .. r.unnamed) or "",
            r.what, r.why and ("  [" .. tostring(r.why) .. "]") or "")
    end
    if M.clickRoutes[1].seen == 0 and M.clickRoutes[2].seen == 0 then
        out[#out + 1] = "clicks: NEITHER route has seen a single click — including the game's "
            .. "own buttons. Either no hook is armed (read the states above) or no mouse click "
            .. "is reaching any widget at all (see M.grabInput)."
    end
    return out
end

-- Register a CommonButtonBase widget (the WBP_PalInvisibleButton inside a menu
-- button) so clicking it runs fn. Lazily installs the dispatch hook. Returns the
-- router key for this button (its fullName, a truthy string) so the caller can
-- hand it back to releaseClicks when the widget goes away — a destroyed widget can
-- no longer be asked for its own name. Returns false if it could not register.
function M.registerClick(invButton, fn)
    if not alive(invButton) then return false end
    M.installClicks()
    local name = fullName(invButton)
    if not name then return false end
    handlers[name] = fn
    return name
end

-- Drop all handlers whose key isn't in keepSet (a table of fullNames to keep).
function M.retainClicks(keepSet)
    for name in pairs(handlers) do
        if not keepSet[name] then handlers[name] = nil end
    end
end

-- Drop the handlers for `names` (router keys from registerClick) and leave every
-- other element's alone — what an element calls from its destroy() so the router
-- does not keep one dead entry per button forever. Returns how many were dropped.
function M.releaseClicks(names)
    local keep, dropped = {}, 0
    for name in pairs(handlers) do keep[name] = true end
    for _, name in ipairs(names or {}) do
        if name and handlers[name] then keep[name] = nil; dropped = dropped + 1 end
    end
    M.retainClicks(keep)
    return dropped
end

-- ---- low-level construction ----
local function classOf(path)
    local c = StaticFindObject(path)
    if not (c and c:IsValid()) then error("class not found: " .. path) end
    return c
end

-- Construct a native/engine object (e.g. "/Script/UMG.VerticalBox").
function M.construct(path, outer)
    local o = StaticConstructObject(classOf(path), outer)
    if not (o and o:IsValid()) then error("construct failed: " .. path) end
    return o
end

-- Instantiate a Blueprint widget by class path via WidgetBlueprintLibrary (this
-- initializes the widget's own WidgetTree, unlike StaticConstructObject). Use for
-- any WBP_/BP_ widget from the game.
function M.create(pc, classPath)
    local cls = StaticFindObject(classPath)
    if not (cls and cls:IsValid()) then
        return nil, "class not loaded: " .. tostring(classPath)
    end
    return M.createFromClass(pc, cls, classPath)
end

---Build a widget from a class OBJECT rather than a path. Split out because the useful button
---class has no path worth citing — it is whichever one this world has loaded — and a live
---Is `w` an instance of a class whose name CONTAINS `needle`? Walks the super chain, because a
---Blueprint button is several links below CommonButtonBase and its own class name says nothing.
function M.isA(w, needle)
    if not alive(w) then return false end
    local k; pcall(function() k = w:GetClass() end)
    local depth = 0
    while alive(k) and depth < 12 do
        local n; pcall(function() n = k:GetFName():ToString() end)
        if type(n) == "string" and n:find(needle, 1, true) then return true end
        local parent; pcall(function() parent = k:GetSuperStruct() end)
        k, depth = parent, depth + 1
    end
    return false
end

---The first descendant whose class chain contains `needle`. The counterpart to findByName for
---the case where the child's NAME is whatever its author chose but its KIND is known.
function M.findByClass(w, needle, depth)
    if not alive(w) or (depth or 0) > 14 then return nil end
    if (depth or 0) > 0 and M.isA(w, needle) then return w end
    local found
    pcall(function()
        local tree = w.WidgetTree
        if alive(tree) then
            local root = tree.RootWidget
            if alive(root) then found = M.findByClass(root, needle, (depth or 0) + 2) end
        end
    end)
    if found then return found end
    local n = 0
    pcall(function() n = w:GetChildrenCount() end)
    for i = 0, (n or 0) - 1 do
        local child
        pcall(function() child = w:GetChildAt(i) end)
        if child then
            local r = M.findByClass(child, needle, (depth or 0) + 1)
            if r then return r end
        end
    end
    return nil
end


---instance hands over its class directly. `label` is only for the error message.
function M.createFromClass(pc, cls, label)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not (lib and lib:IsValid() and cls and cls:IsValid() and pc and pc:IsValid()) then
        return nil, "create prerequisites missing for " .. tostring(label or "<class>")
    end
    local w = lib:Create(pc, cls, pc)
    if not (w and w:IsValid()) then return nil, "Create failed for " .. tostring(label or "<class>") end
    return w
end

function M.widgetName(w)
    local ok, n = pcall(function() return w:GetFName():ToString() end)
    if ok and n and #n > 0 then return tostring(n) end
    local full = ""
    pcall(function() full = w:GetFullName() end)
    return full:match("[%.:]([%w_]+)$") or full or "?"
end

-- Depth-first search for a descendant widget by name (descends nested UserWidgets,
-- panel children, and single-content widgets). Returns the widget or nil.
function M.findByName(w, name, depth)
    if not (w and w:IsValid()) or (depth or 0) > 14 then return nil end
    if M.widgetName(w) == name then return w end
    local found
    pcall(function()
        local tree = w.WidgetTree
        if tree and tree:IsValid() then
            local root = tree.RootWidget
            if root and root:IsValid() then found = M.findByName(root, name, (depth or 0) + 2) end
        end
    end)
    if found then return found end
    local n = 0
    pcall(function() n = w:GetChildrenCount() end)
    for i = 0, (n or 0) - 1 do
        local child
        pcall(function() child = w:GetChildAt(i) end)
        if child then
            local r = M.findByName(child, name, (depth or 0) + 1)
            if r then return r end
        end
    end
    if (n or 0) == 0 then
        local content
        pcall(function() content = w:GetContent() end)
        if content and content:IsValid() then return M.findByName(content, name, (depth or 0) + 1) end
    end
    return nil
end

local function color(c) return { R = c[1], G = c[2], B = c[3], A = c[4] or 1.0 } end
M.color = color

-- ---- native UMG primitives (outer = the WidgetTree that owns the panel) ----
function M.vbox(tree) return M.construct("/Script/UMG.VerticalBox", tree) end
function M.hbox(tree) return M.construct("/Script/UMG.HorizontalBox", tree) end
function M.scrollBox(tree) return M.construct("/Script/UMG.ScrollBox", tree) end
function M.overlay(tree) return M.construct("/Script/UMG.Overlay", tree) end

function M.border(tree, rgba)
    local b = M.construct("/Script/UMG.Border", tree)
    pcall(function() b:SetBrushColor(color(rgba or { 0.13, 0.11, 0.09, 0.97 })) end)
    return b
end

-- A SizeBox with optional fixed dimensions. Each override is written TWICE, as the
-- slot helpers below are: the property (with its bOverride_ flag, which the engine
-- ignores the value without) and the setter, because UE4SS setters sometimes no-op.
function M.sizeBox(tree, w, h)
    local s = M.construct("/Script/UMG.SizeBox", tree)
    if w then
        pcall(function() s.WidthOverride = w; s.bOverride_WidthOverride = true end)
        pcall(function() s:SetWidthOverride(w) end)
    end
    if h then
        pcall(function() s.HeightOverride = h; s.bOverride_HeightOverride = true end)
        pcall(function() s:SetHeightOverride(h) end)
    end
    return s
end

function M.text(tree, str, size, rgba)
    local t = M.construct("/Script/UMG.TextBlock", tree)
    pcall(function() t:SetText(FText(tostring(str))) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color(rgba or { 0.95, 0.93, 0.86, 1 }), ColorUseRule = 0 }) end)
    pcall(function() local f = t.Font; f.Size = size or 16; t.Font = f end)
    return t
end

-- A UImage with a texture in it. The ONE brush call this makes is the one that needs no struct:
--
--   dumps/cxx/UMG.hpp:747   class UImage : public UWidget
--                     :765     void SetBrushFromTexture(class UTexture2D* Texture, bool bMatchSize);
--
-- Every other way in takes an FSlateBrush, an FSlateColor, an FLinearColor or an FVector2D
-- (:760, :761, :762, :771), and UWidgetBlueprintLibrary's MakeBrushFromTexture (:2016) RETURNS
-- one — so SetBrushFromTexture is not merely the shortest route, it is the only one whose
-- arguments this tree is allowed to marshal. It goes through core/signature for that reason:
-- ObjectProperty + BoolProperty is exactly what the check can verify.
--
-- NO SIZE FIELD, and that is a finding rather than an omission. This build's UImage has no
-- SetBrushSize (grep dumps/cxx: zero hits — that is UE5.1+), the size lives on FSlateBrush's
-- ImageSize (SlateCore.hpp:337) which is a struct write, and SetDesiredSizeOverride takes an
-- FVector2D. So an image is sized either by `bMatchSize` (it adopts the texture's own pixel
-- size) or by putting it in a SizeBox, which is a node this tree already has.
--
-- `opacity` is SetOpacity(float) (:759) — a plain float, so it is called directly. `rgba` is a
-- TINT through SetColorAndOpacity(FLinearColor) (:761), written the way M.text writes its own
-- colour: every field of the struct named in full, inside a pcall, and skipped entirely when
-- the caller did not ask for one.
function M.image(tree, texture, opts)
    opts = opts or {}
    local img = M.construct("/Script/UMG.Image", tree)
    if texture ~= nil then
        local match = opts.matchSize
        if match == nil then match = true end
        sig.call(img, "SetBrushFromTexture", { "ObjectProperty", "BoolProperty" }, texture, match == true)
        -- The property write as well as the setter, the way every override in this file is
        -- written: UE4SS setters sometimes no-op where the property write lands.
        pcall(function() img.Brush.ResourceObject = texture end)
    end
    if opts.opacity then pcall(function() img:SetOpacity(opts.opacity) end) end
    if opts.rgba then pcall(function() img:SetColorAndOpacity(color(opts.rgba)) end) end
    return img
end

-- ---- screen root: a widget of OUR OWN to build those primitives in ----
--
-- Every primitive above takes a WidgetTree as its construct outer, and a bare
-- UUserWidget has NONE — the engine normally builds one from the widget's generated
-- Blueprint class. Constructing a WidgetTree by hand and assigning it is the step
-- that makes cook-free, Lua-only UMG work; poc/V6-ui-native recorded it as verified
-- in-game on 2026-07-17 (all five stages OK, the panel really drew), and every
-- PalForge panel that shipped afterwards used the same sequence:
--
--   pc -> UserWidget(outer = pc) -> WidgetTree(outer = w) -> w.WidgetTree = tree
--      -> root panel -> tree.RootWidget -> AddToViewport(z)

-- Something that can own our widgets: the player controller when there is one
-- (WidgetBlueprintLibrary needs a controller), else the GameInstance. nil with no game.
function M.owner()
    return M.findFirst("PalPlayerController") or M.findFirst("PlayerController")
        or M.findFirst("GameInstance")
end

-- The game's OWN in-game UI root: the UCanvasPanel a PalForge widget can be parented into
-- instead of a viewport layer of our own. Returns the panel, or nil + a reason.
--
--   local host = widget.gameUIRoot()
--   if host then Button:new{ label = "Mods", onClick = f }:mount(host) end
--
-- Read the M.PATHS note above for the declarations this rests on. Two things about the WAY it
-- is reached are deliberate:
--
--   * FindFirstOf takes the NATIVE base class (PalPrimaryGameLayoutBase), not the blueprint
--     class name. FindFirstOf matches subclasses — the same call answers FindFirstOf
--     ("PalPlayerCharacter") with a BP_Player_Female_C every run (dumps/f5-partial-run.txt:160)
--     — so asking for the base survives a blueprint rename, and WBP_PalOverallUILayout_C is
--     the only subclass this build has.
--   * The panel is read as a PROPERTY (`layout.CanvasPanel_Root`), not searched for by name
--     through findByName. It is a declared member at a known offset (WBP_PalOverallUILayout.hpp:9);
--     a tree walk would find the same object more slowly and could find a different one.
--
-- nil at the title screen and during load, which is correct rather than a failure: the layout
-- belongs to the in-game UI. An element that wants it should ride :autoMount, exactly as a
-- title-screen element does.
function M.gameUIRoot()
    return M.hostPanel(M.PATHS.gameUILayout, M.PATHS.gameUIRoot)
end

-- The same two steps for ANY panel the game already draws: find a live widget by CLASS, then
-- reach the panel inside it that will take our children. gameUIRoot is this call with the one
-- pair of names PalForge had measured; a pack that wants to extend a different screen names its
-- own pair and gets the same fail-soft contract (panel, or nil + a sentence).
--
--   widget.hostPanel("PalPrimaryGameLayoutBase", "CanvasPanel_Root")   -- the in-game UI root
--   widget.hostPanel("PalUITitleBase", "VerticalBox_0")                -- the title button column
--
-- THE PANEL IS READ AS A PROPERTY FIRST, then searched for by name. Both halves are deliberate
-- and each covers the other's blind spot:
--   * a declared member is at a known offset and answers immediately — that is the route
--     WBP_PalOverallUILayout's CanvasPanel_Root takes (dumps/cxx/WBP_PalOverallUILayout.hpp:9),
--     and a tree walk would find the same object more slowly and could find a different one;
--   * a widget whose designer "Is Variable" box is unchecked gets NO member and still exists in
--     the WidgetTree — the same fact recorded against HorizontalBox_0 at the TODO further down
--     this file — so the name search is what reaches those, and TitleMenu already finds
--     VerticalBox_0 that way (title_menu.lua:147).
-- `panelName` omitted means the found widget IS the panel; it is returned as-is and whether it
-- takes children is answered by the first AddChild, not guessed at here.
---@return userdata? panel, string? reason
function M.hostPanel(className, panelName)
    if type(className) ~= "string" or #className == 0 then
        return nil, "hostPanel: a host widget CLASS name is required"
    end
    local host = M.findFirst(className)
    if not host then
        return nil, "no " .. className .. " live (title screen, or still loading)"
    end
    if panelName == nil then return host end

    local panel
    pcall(function() panel = host[panelName] end)
    if not alive(panel) then panel = M.findByName(host, panelName) end
    if not alive(panel) then
        return nil, className .. " has no live " .. panelName
    end
    return panel
end

-- Put a screen (or a bare UserWidget) on the viewport. Returns true only when the
-- widget reports itself in the viewport afterwards — or, on a build without
-- IsInViewport, when the AddToViewport call itself did not error.
function M.show(screen, zOrder)
    local w = screen and (screen.widget or screen)
    if not w then return false end
    if not pcall(function() w:AddToViewport(zOrder or 1000) end) then return false end
    local shown
    if pcall(function() shown = w:IsInViewport() end) and shown ~= nil then
        return shown == true
    end
    return true
end

-- Take a screen back off the viewport. Returns true if it is no longer shown.
function M.hide(screen)
    local w = screen and (screen.widget or screen)
    if not w then return false end
    if not pcall(function() w:RemoveFromParent() end) then return false end
    local shown
    if pcall(function() shown = w:IsInViewport() end) and shown ~= nil then
        return shown ~= true
    end
    return true
end

-- Build a screen: our own UUserWidget with a live WidgetTree and a root panel, ready
-- for the primitives above — pass `screen.tree` to vbox/text/clickableRow, `screen.pc`
-- to the clickable ones, and add your widgets under `screen.root`. Shown on the
-- viewport immediately unless opts.show == false (then call M.show yourself).
--
--   opts = { zOrder = 1000, show = true,
--            dim     = {r,g,b,a} | false,  -- false: bare VerticalBox root, no frame
--            panel   = {r,g,b,a},          -- the inset panel behind your widgets
--            padding = { Left =, Top =, Right =, Bottom = } }
--
-- Fail-soft: never throws. Returns the screen table, or nil + a reason when there is
-- no game to own it, a UMG class is missing, or it could not be shown.
function M.screen(pc, opts)
    opts = opts or {}
    pc = pc or M.owner()
    if not pc then return nil, "no owner (no PlayerController / GameInstance)" end

    local w, tree, root
    local ok, e = pcall(function()
        w = M.construct("/Script/UMG.UserWidget", pc)
        pcall(function() w:SetPlayerContext(pc) end)
        -- THE CRUX: a bare UUserWidget's WidgetTree is null, so construct one.
        tree = w.WidgetTree
        if not alive(tree) then
            tree = M.construct("/Script/UMG.WidgetTree", w)
            w.WidgetTree = tree
        end
        if not alive(tree) then error("WidgetTree still invalid after construct") end
        pcall(function() w:SetVisibility(0) end)   -- ESlateVisibility Visible

        -- Fullscreen dim + inset panel + vertical stack: the frame every shipped
        -- PalForge panel used. `dim = false` gives a bare VerticalBox root instead.
        local content = M.vbox(tree)
        if opts.dim == false then
            tree.RootWidget = content
        else
            local dim = M.border(tree, opts.dim or { 0.02, 0.02, 0.03, 0.86 })
            tree.RootWidget = dim
            local pnl = M.border(tree, opts.panel or { 0.10, 0.09, 0.08, 0.98 })
            pcall(function()
                pnl:SetPadding(opts.padding or { Left = 90, Top = 54, Right = 90, Bottom = 54 })
            end)
            pcall(function() dim:SetContent(pnl) end)
            pcall(function() pnl:SetContent(content) end)
        end
        root = content
    end)
    if not (ok and alive(w) and alive(tree) and root) then
        return nil, "screen build failed: " .. tostring(e)
    end

    local screen = { widget = w, tree = tree, root = root, pc = pc }
    if opts.show ~= false and not M.show(screen, opts.zOrder) then
        pcall(function() w:RemoveFromParent() end)
        return nil, "AddToViewport failed"
    end
    return screen
end
-- ANSWERED, 2026-07-27, and negatively — which is still an answer. The probe read the button's
-- own template tree and reported:
--
--   HorizontalBox_0 IS in a WBP_Title_MenuButton and its slot is a CanvasPanelSlot.
--
-- So the name was never stale; the slot is simply the one kind that cannot do this. A
-- CanvasPanelSlot declares no SetHorizontalAlignment (UMG.hpp:350-374) — the other five slot
-- classes do — so core/signature refused the call every time and logged it, correctly, and the
-- label has always stayed centred.
--
-- The alignment it DOES declare, SetAlignment, takes an FVector2D, and a struct argument is the
-- shape that faults inside UE4SS marshalling where pcall cannot see it. The struct-free
-- alternative is SetAutoSize plus an offset write, which is a lot of machinery and a new failure
-- mode for a cosmetic nobody asked for.
--
-- So the function is gone rather than left to be refused forever. A refusal logged on every
-- button build reads like a defect and is not one.

-- Clone the game's title menu button as a clickable row. Returns (button, invBtn,
-- clickName). `onClick` is routed through the shared click router; clickName is that
-- registration's key — keep it and pass it to releaseClicks when you drop the button.
-- `tree` is UNUSED: WidgetBlueprintLibrary:Create outers the widget itself, so a BP widget
-- A button class that exists HERE. Not a path, because the useful one has no path anyone can
-- cite: the title-menu button is only resident at the title screen, and a declared UI mounting
-- into the game's own HUD asked for it and got "create prerequisites missing" — the class is
-- simply not loaded in a world.
--
-- What IS in a world: 240 live CommonButtonBase instances, and the probe named their classes —
-- WBP_PalCommonButton_C and WBP_PalInvisibleButton_C. A live instance carries its own class, so
-- asking the world for one is both cheaper than a path and correct by construction: if the
-- lookup answers, the class is loaded, because something is standing there made of it.
--
-- This is one route, not a fallback chain. The title screen has live buttons too, so the same
-- question — "what button class is loaded right now" — is the right question everywhere.
--
-- ORDER CHANGED, 2026-07-27, and the reason is what the game does with its OWN mod menu.
-- WBP_CommonButton_C leads because it is the button Palworld's built-in Mod Menu is built from
-- (dumps/cxx/WBP_Option_ModMenu.hpp:15-17) and it is the only candidate that carries a LABEL and
-- a click target it declares by name rather than by luck:
--
--   dumps/cxx/WBP_CommonButton.hpp:12   class UBP_PalTextBlock_C* Text_Main;
--                               :13     class UWBP_PalInvisibleButton_C* WBP_PalInvisibleButton;
--                               :30     void SetText(FText Text);
--
-- so the text goes in through the button's own one-argument setter instead of through a search
-- for whatever TextBlock happens to be inside it, and the clickable child is found by the exact
-- name the class declares. It is resident in a world — eleven rows in
-- dumps/reflection/03_widgets.txt (:7, :338-339, :589) — which is the property the whole
-- buttonClass idea rests on.
--
-- WBP_PalCommonButton_C and WBP_PalInvisibleButton_C stay behind it: both are
-- UWBP_PalCommonButtonBase_C and therefore CommonButtonBase themselves (WBP_PalCommonButton.hpp:4,
-- WBP_PalInvisibleButton.hpp:4, WBP_PalCommonButtonBase.hpp:4), which is the shape the click
-- router's `inv = btn` fallback below was written for.
M.BUTTON_CLASSES = { "WBP_CommonButton_C", "WBP_PalCommonButton_C", "WBP_PalInvisibleButton_C" }

---The CLASS behind the first of `names` this world has an instance of, plus the name that hit.
---
---The whole idea in one function: a live instance carries its own class, so asking the world is
---both cheaper than a path and correct by construction — if the lookup answers, the class is
---loaded, because something is standing there made of it. FindFirstOf also answers with
---ARCHETYPES, the template widgets inside a loaded blueprint's WidgetTree, which is why this
---works for classes that are resident but not currently on screen (that is how
---dumps/reflection/03_widgets.txt lists WBP_PalCommonWindow_C seven times with no live window).
---@return userdata? cls, string? name
function M.liveClass(names)
    for _, name in ipairs(names or {}) do
        local inst = M.findFirst(name)
        if alive(inst) then
            local cls; pcall(function() cls = inst:GetClass() end)
            if alive(cls) then return cls, name end
        end
    end
    return nil, nil
end

---Construct a native/engine object from a CLASS OBJECT rather than a path — the counterpart to
---M.construct for the classes that have no path anyone can cite. Raises like M.construct does.
function M.constructFromClass(cls, outer)
    if not alive(cls) then error("constructFromClass: no class", 0) end
    local o = StaticConstructObject(cls, outer)
    if not alive(o) then error("construct failed from a live class", 0) end
    return o
end

function M.buttonClass()
    do
        local cls, name = M.liveClass(M.BUTTON_CLASSES)
        if cls then return cls, name end
    end
    -- The title-menu class by path, for the title screen, where the in-world ones may not be up
    -- yet. Same question, different moment; it is the only path form kept.
    local cls; pcall(function() cls = StaticFindObject(M.PATHS.menuButton) end)
    if alive(cls) then return cls, "WBP_Title_MenuButton_C" end
    return nil, nil
end

---The widget inside a button that carries its text, whatever class of button it is. Three names
---for one question, in order of how exact each one is: WBP_CommonButton_C declares Text_Main
---(WBP_CommonButton.hpp:12), WBP_Title_MenuButton_C declares Test_Content
---(WBP_Title_MenuButton.hpp:14), and anything else is asked by SHAPE — the first TextBlock in
---its tree — because a class nobody wrote this code against has neither name.
---@return userdata? label
function M.buttonLabel(btn)
    local lbl = M.findByName(btn, M.PATHS.commonButtonLabel)
        or M.findByName(btn, M.PATHS.menuButtonLabel)
        or M.findByClass(btn, "TextBlock")
    return alive(lbl) and lbl or nil
end

---Write `label` into `btn`, through the button's OWN setter when it declares one.
---
---WBP_CommonButton_C declares `void SetText(FText Text)` on itself
---(dumps/cxx/WBP_CommonButton.hpp:30) and that is the call the game's own Mod Menu makes
---(WBP_Option_ModMenu.hpp:15-17). Going through it lets the button do whatever it does around
---the write — its Text_Main is a UBP_PalTextBlock_C, which carries Palworld's font scaling and
---its localisation binding (Pal.hpp:30039-30050) — instead of us reaching past it into a child.
---
---core/signature gates it because FText is a TextProperty, i.e. one of the kinds signature
---refuses on an unread declaration: if this build will not walk the parameter list we do not
---guess, we write the child instead, which is exactly what shipped before.
---@return boolean wrote
function M.setButtonText(btn, label)
    if not alive(btn) then return false end
    local s = tostring(label or "")
    if sig.check(btn, "SetText", { "TextProperty" }) == "declared" then
        if pcall(function() btn:SetText(FText(s)) end) then return true end
    end
    local lbl = M.buttonLabel(btn)
    if not lbl then return false end
    return pcall(function() lbl:SetText(FText(s)) end) == true
end

-- needs no WidgetTree. The parameter is kept only so every builder here reads the same way.
function M.menuButton(tree, pc, label, onClick)
    local cls, clsName = M.buttonClass()
    if not cls then
        return nil, "no button class is loaded — no live CommonButtonBase and no title-menu class"
    end
    local btn, e = M.createFromClass(pc, cls)
    if not btn then return nil, (tostring(e) .. " [" .. tostring(clsName) .. "]") end
    -- THE LABEL AND THE CLICK TARGET ARE FOUND BY SHAPE WHEN A NAME WILL NOT DO, and that was a
    -- correction. Both used to be looked up by the child names the TITLE menu button happens to
    -- use (Test_Content, WBP_PalInvisibleButton). Once the class came from whatever the world had
    -- loaded, those names were not always there, and the failure was silent in the worst way: no
    -- inner button found meant registerClick was never called, which meant installClicks was
    -- never called, which meant the click hook was never registered at all. The panel mounted,
    -- the button drew, and nothing could ever happen.
    --
    -- The names are back — but as DECLARED members of the class in the lead, not as a guess:
    -- WBP_CommonButton_C declares Text_Main and WBP_PalInvisibleButton by those exact names
    -- (dumps/cxx/WBP_CommonButton.hpp:12-13). The shape search stays behind them, for the class
    -- nobody wrote this code against.
    M.setButtonText(btn, label)

    -- The clickable thing is an inner CommonButtonBase when the class wraps one, and otherwise
    -- the button ITSELF — WBP_PalCommonButton_C derives from CommonButtonBase, so it is the
    -- widget the hook will report. One question, "which CommonButtonBase fires", asked of the
    -- three places it can be: the child the class declares, any CommonButtonBase in its tree,
    -- and the button itself.
    local inv = M.findByName(btn, M.PATHS.menuButtonClick)
    if not alive(inv) then inv = M.findByClass(btn, "CommonButtonBase") end
    if not alive(inv) and M.isA(btn, "CommonButtonBase") then inv = btn end

    local clickName
    if alive(inv) and onClick then
        local key = M.registerClick(inv, onClick)
        if key then clickName = key end
    end
    if onClick and not clickName then
        err("menuButton: no CommonButtonBase to bind the click to on " .. tostring(clsName))
    end
    return btn, inv, clickName
end

-- A clickable, LEFT-ALIGNED row that still looks native.
-- Returns (rowWidget, invBtn, clickName).
function M.clickableRow(tree, pc, label, onClick, opts)
    opts = opts or {}
    local overlay = M.overlay(tree)
    local btn, inv, clickName = M.menuButton(tree, pc, "", onClick)
    if btn then
        local bs = overlay:AddChildToOverlay(btn)
        pcall(function() bs:SetHorizontalAlignment(M.HALIGN.FILL) end)
        pcall(function() bs:SetVerticalAlignment(M.VALIGN.FILL) end)
    end
    -- ESlateVisibility HitTestInvisible=3 so text shows but clicks pass through.
    local t = M.text(tree, label, opts.size or 18, opts.color)
    pcall(function() t:SetVisibility(3) end)
    local ts = overlay:AddChildToOverlay(t)
    pcall(function() ts:SetHorizontalAlignment(M.HALIGN.LEFT) end)
    pcall(function() ts:SetVerticalAlignment(M.VALIGN.CENTER) end)
    pcall(function() ts:SetPadding({ Left = opts.indent or 28, Top = 0, Right = 12, Bottom = 0 }) end)
    return overlay, inv, clickName
end

-- Generic: clone any Palworld BP widget, optionally set a label child's text and
-- wire a click. `opts = { label=, labelChild=, clickChild=, onClick= }`. Like menuButton,
-- `tree` is unused (Create outers the widget itself). Returns (widget, clickName) — the
-- router key, so the caller can releaseClicks it when the widget goes away; without it a
-- cloned widget's handler would sit in the router forever with no way to name it again.
function M.cloneGameWidget(tree, pc, classPath, opts)
    opts = opts or {}
    local w, e = M.create(pc, classPath)
    if not w then return nil, e end
    if opts.label and opts.labelChild then
        local lbl = M.findByName(w, opts.labelChild)
        if lbl and lbl:IsValid() then pcall(function() lbl:SetText(FText(opts.label)) end) end
    end
    local clickName
    if opts.onClick and opts.clickChild then
        local c = M.findByName(w, opts.clickChild)
        if c then
            local key = M.registerClick(c, opts.onClick)
            if key then clickName = key end
        end
    end
    return w, clickName
end

--=============================================================================
-- LOOKING NATIVE — the game's own frame and the game's own label
--
-- WHAT CAN LOOK NATIVE, and what cannot. Three of the five things a panel is made of can be the
-- game's own widget, and two cannot:
--
--   button  YES — and already was. M.BUTTON_CLASSES now leads with the button Palworld's own
--                 Mod Menu is built from (WBP_Option_ModMenu.hpp:15-17).
--   frame   YES — M.gameFrame below. WBP_PalCommonWindow_C is a pure content frame: one member,
--                 a UNamedSlot, no functions at all (WBP_PalCommonWindow.hpp:4-6). It is the
--                 window seven different Palworld dialogs are built out of
--                 (03_widgets.txt:6, 165, 166, 172, 221, 280, 340).
--   label   YES — M.palText below. BP_PalTextBlock_C (BP_PalTextBlock.hpp:4) is the label 57
--                 loaded classes use, and it is a UPalTextBlockBase (Pal.hpp:30039) — Palworld's
--                 font scaling, UI-settings binding and localisation binding, which is most of
--                 what makes text look native.
--   layout  NO  — a VerticalBox is a VerticalBox. There is no Palworld "row" or "column" widget
--                 to adopt; the game lays its own panels out with canvases and offsets, which
--                 needs the struct calls this tree cannot make (UMG.hpp:350-374).
--   colour / spacing / font  NO, not as a THEME. Every style hook in this build is a struct or a
--                 style-CLASS argument with no path to a Palworld instance:
--                 UCommonBorder::SetStyle takes a TSubclassOf<UCommonBorderStyle>
--                 (CommonUI.hpp:232) and the dump names no Palworld subclass to pass;
--                 UCommonTextBlock::SetStyle is the same (CommonUI.hpp:749); UBorder's
--                 SetBrushColor / SetPadding take FLinearColor / FMargin (UMG.hpp:282, :275).
--                 So a PalForge Border is a Border with a colour you chose, and it will not
--                 match the game's chrome. Use a Frame if you want the game's chrome.
--=============================================================================

-- One member, and it is a UNamedSlot (WBP_PalCommonWindow.hpp:6). A UNamedSlot is a
-- UContentWidget (UMG.hpp:1042 -> :505), so it takes our content through SetContent.
M.PANEL_CLASSES = { "WBP_PalCommonWindow_C" }

-- The game's own window chrome, with the slot our content goes into — and, because it is the
-- only widget in this tree that is a UPalUserWidget, the ONE node that unlocks the game's own
-- input-mode route and its own layer route. Read the ⚠️⚠️ block further down before changing it.
--
-- Returns (frame, contentHost, className) or nil + a reason. `contentHost` is the frame's
-- NamedSlot, NOT the frame: a caller adds its tree to that and the chrome draws around it.
--
-- WHY IT IS SEPARATE FROM THE FRAME. Every other widget in this file is its own parent. This one
-- is not, and pretending otherwise is how a panel ends up drawn behind the frame instead of
-- inside it — so the two are returned as two things and the caller cannot conflate them.
--
-- opts = { input       = an M.INPUT_MODES key; its `pal` byte is written onto the widget BEFORE
--                        it is activated, which is the only moment the router reads it,
--          layer       = a layer-tag substring (or true for the first layer) to push onto
--                        through the game's own BP_AddWidget instead of parenting by hand,
--          backHandler = claim the CommonUI BACK action (that is Esc) — see below }
---@return userdata? frame, userdata? contentHost, string? whyOrName
function M.gameFrame(pc, opts)
    opts = opts or {}
    local cls, name = M.liveClass(M.PANEL_CLASSES)
    if not cls then
        return nil, nil, "no Palworld window class is loaded (tried " ..
            table.concat(M.PANEL_CLASSES, ", ") .. ")"
    end

    -- ROUTE A: THE GAME'S OWN. BP_AddWidget on a registered CommonUI layer creates the widget,
    -- pushes it on that layer's activatable stack, activates it and registers it with the action
    -- router — all the things we otherwise do by hand and one (the router) that we cannot.
    -- Unmeasured; it refuses with a sentence, and the caller falls through to route B.
    local frame, container, layerTag
    if opts.layer ~= nil and opts.layer ~= false then
        local w, c, tagOrWhy = M.pushToLayer(opts.layer ~= true and opts.layer or nil, cls)
        if w then
            frame, container, layerTag = w, c, tagOrWhy
            log(string.format("frame: %s pushed onto CommonUI layer %s through BP_AddWidget — the "
                .. "game's own route, so the action router owns its activation and its input mode",
                name, tostring(layerTag)))
        else
            log("frame: the layer route was not available (" .. tostring(tagOrWhy)
                .. "); building the window directly instead")
        end
    end

    -- ROUTE B: build it ourselves. A UUserWidget, so it goes through WidgetBlueprintLibrary::
    -- Create like every other blueprint widget here — StaticConstructObject would leave its
    -- WidgetTree null. This is the route two live runs have watched draw (tree.lua:1-9).
    if not alive(frame) then
        local e
        frame, e = M.createFromClass(pc, cls, name)
        if not frame then return nil, nil, tostring(e) end
    end

    local slot = M.findByName(frame, M.PATHS.windowSlot) or M.findByClass(frame, "NamedSlot")
    if not alive(slot) then
        pcall(function() frame:RemoveFromParent() end)
        return nil, nil, name .. " has no " .. M.PATHS.windowSlot .. " to put content in"
    end

    -- ⚠️ IT IS AN ACTIVATABLE WIDGET, NOT A PLAIN ONE. WBP_PalCommonWindow_C is a UPalUserWidget
    -- (WBP_PalCommonWindow.hpp:4 -> Pal.hpp:31888 -> :13367 -> UCommonActivatableWidget,
    -- CommonUI.hpp:147), and a CommonUI activatable is DEACTIVATED when it is created: it carries
    -- bSetVisibilityOnActivated / ActivatedVisibility (CommonUI.hpp:163-164) and normally gets its
    -- visibility from being pushed onto a layer. On route B ours is not pushed onto anything, so
    -- it has to be activated by hand or it can sit there collapsed, which would read as "the
    -- Frame node does nothing" with nothing in the log. ActivateWidget takes no arguments
    -- (CommonUI.hpp:177), so it goes through signature cleanly.
    --
    -- ⚠️ THE THREE ACTIVATION FLAGS ARE NO LONGER FORCED, AND THAT IS A CORRECTION.
    --
    --   bIsBackHandler            CommonUI.hpp:149  this widget claims the BACK action — Esc.
    --   bIsModal                  CommonUI.hpp:153  input does not reach anything underneath.
    --   bSupportsActivationFocus  CommonUI.hpp:152  activating it moves focus onto it.
    --
    -- The previous version forced all three to false as one of two candidate causes of "Esc
    -- stopped closing the game's menu". The run MEASURED them first and printed
    -- `bIsBackHandler=false bIsModal=false bSupportsActivationFocus=true` — i.e. two of the three
    -- were already false before anything of ours ran, so this window was never the router's back
    -- handler and was never modal, and the suspect is dead. Forcing a flag we now know was
    -- already correct is not caution, it is noise that hides the next reading. So they are READ
    -- and LOGGED, and written only where the CALLER declared one.
    --
    -- ⚠️ AND bIsBackHandler IS NOW OFFERED RATHER THAN SUPPRESSED. It is how a CommonUI screen
    -- says "Esc closes ME" — the mechanism the game itself uses (BP_OnHandleBackAction,
    -- CommonUI.hpp:172) and the only way a mod can be IN Esc's path rather than beside it. It is
    -- opt-in because a widget that claims Back and cannot handle it swallows the key, and
    -- because whether the router registers a widget of ours at all is exactly what is unmeasured.
    local were = {}
    for _, flag in ipairs({ "bIsBackHandler", "bIsModal", "bSupportsActivationFocus" }) do
        local was
        pcall(function() was = frame[flag] end)
        were[#were + 1] = flag .. "=" .. tostring(was)
    end
    if opts.backHandler ~= nil then
        pcall(function() frame.bIsBackHandler = opts.backHandler == true end)
        were[#were + 1] = "-> bIsBackHandler=" .. tostring(opts.backHandler == true) .. " (declared)"
    end

    -- ⚠️ THE INPUT MODE GOES ON HERE, BEFORE ActivateWidget, AND NOWHERE ELSE. Palworld keeps the
    -- mode on the widget (Pal.hpp:13369-13370) and the router reads it at activation; the two
    -- live runs that broke Esc wrote it into the player controller instead, behind the router's
    -- back. On route A the widget was already activated by BP_AddWidget, so the write may be one
    -- activation late — that is stated on the log line rather than hidden.
    local inputSpec = opts.input and M.INPUT_MODES[opts.input] or nil
    if inputSpec and inputSpec.pal ~= nil then
        local wrote, detail = M.setWidgetInputConfig(frame, inputSpec)
        log(string.format("frame: input = %q -> %s  [%s%s]", tostring(opts.input), detail,
            wrote and "written" or "NOT written",
            container and ", AFTER BP_AddWidget activated it — the router may not re-read it"
                or ", before ActivateWidget, which is when the router reads it"))
    end

    log("frame: " .. name .. " CommonUI activation flags " .. table.concat(were, " ")
        .. " — read, not forced; see the ⚠️ note in M.gameFrame for why that changed")
    if not container then sig.call(frame, "ActivateWidget", {}) end
    -- SelfHitTestInvisible (ESlateVisibility 4, UMG_enums.hpp:48-55): the chrome must not eat the
    -- clicks meant for the button inside it, and Visible on a container is exactly how that
    -- happens. Children stay hit-testable.
    pcall(function() frame:SetVisibility(4) end)
    return frame, slot, name, container
end

---Deactivate a widget that IS a CommonUI activatable, and say nothing at all about one that is
---not. The counterpart to the ActivateWidget above: an activated widget is registered with the
---action router, and RemoveFromParent is not documented to unregister it — so a frame that is
---taken down without this could keep a stale node in the router for the rest of the session.
---
---Gated on the class rather than tried blind: DeactivateWidget (CommonUI.hpp:170) is absent from
---every plain UMG primitive this tree builds, and core/signature would correctly log a refusal
---for each of them, which reads like a defect and is not one.
---@return boolean deactivated
function M.deactivate(w)
    if not alive(w) then return false end
    if not M.isA(w, "CommonActivatableWidget") then return false end
    local ok = sig.call(w, "DeactivateWidget", {})
    return ok == true
end

-- The game's own text block. A UWidget (UTextBlock -> UCommonTextBlock -> UPalTextBlockBase ->
-- BP_PalTextBlock_C: UMG.hpp:1518, CommonUI.hpp:736, Pal.hpp:30039, BP_PalTextBlock.hpp:4), NOT
-- a UUserWidget — so it is CONSTRUCTED into a widget tree like every primitive above and NOT
-- created through WidgetBlueprintLibrary, which only takes UUserWidget subclasses.
--
-- BP_PalTextBlock_C is resident in any world — 57 loaded classes declare one as a child — and it
-- also has a path, which is the rarest combination here, so both routes are used (live class
-- first, path second) exactly as buttonClass does.
--
-- Returns nil + a reason rather than raising, because "the class is not resident" is a normal
-- answer at the title screen and the caller falls back to a plain TextBlock.
M.LABEL_CLASSES = { "BP_PalTextBlock_C" }

---@return userdata? label, string? why
function M.palText(tree, str, size)
    local cls, name = M.liveClass(M.LABEL_CLASSES)
    if not cls then
        pcall(function() cls = StaticFindObject(M.PATHS.palTextBlock) end)
        name = alive(cls) and "BP_PalTextBlock_C (by path)" or nil
    end
    if not alive(cls) then
        return nil, "no BP_PalTextBlock_C is loaded and " .. M.PATHS.palTextBlock
            .. " did not resolve"
    end
    local ok, t = pcall(M.constructFromClass, cls, tree)
    if not ok or not alive(t) then return nil, "construct " .. tostring(name) .. ": " .. tostring(t) end

    -- ⚠️ TURN THE REBUILD BINDING OFF BEFORE WRITING THE TEXT. UPalTextBlockBase carries
    -- `IsAutoTextSetWhenWidgetRebuilt` (Pal.hpp:30044) and a BindTextDatatableHandle (:30041):
    -- with the flag on, the widget re-reads its bound localisation row whenever Slate rebuilds
    -- it, which silently throws away anything we wrote. Ours is bound to no row, so the re-read
    -- would blank it.
    pcall(function() t.IsAutoTextSetWhenWidgetRebuilt = false end)
    pcall(function() t:SetText(FText(tostring(str))) end)
    if size then
        -- UpdateFontSize(int32) is Palworld's own, and it is a plain int (Pal.hpp:30050) — the
        -- one font call in this whole tree that is not a struct. SetFont takes an FSlateFontInfo
        -- (UMG.hpp:1548) and is unreachable.
        sig.call(t, "UpdateFontSize", { "IntProperty" }, math.floor(size))
    end
    return t
end

--=============================================================================
-- ⚠️⚠️ THE GAME'S OWN UI ROUTE — how Palworld puts a screen up, decides the input mode,
-- and delivers Esc. Read this before touching input or hosting.
--
-- EVERYTHING BELOW IS FROM THIS INSTALL'S OWN DUMP unless a line says otherwise, and the
-- lines that are inference say so. It was written after TWO live runs in which a mounted
-- PalForge panel broke Esc, and it is the answer to "what were we doing wrong": we were
-- writing, by hand, state that this game derives from its widget stack.
--
-- 1. A SCREEN IS AN ACTIVATABLE WIDGET, AND IT DECLARES ITS OWN INPUT MODE.
--
--      class UPalActivatableWidget : public UCommonActivatableWidget   Pal.hpp:13367
--          EPalWidgetInputMode InputConfig;                            Pal.hpp:13369
--          EMouseCaptureMode   GameMouseCaptureMode;                   Pal.hpp:13370
--      enum class EPalWidgetInputMode { Default, GameAndMenu, Game, Menu }  Pal_enums.hpp:5367
--      enum class EMouseCaptureMode  { NoCapture, CapturePermanently,
--                                      CapturePermanently_IncludingInitialMouseDown,
--                                      CaptureDuringMouseDown, ... }        Engine_enums.hpp:2237
--
--    EVERY Palworld screen is a UPalUserWidget (Pal.hpp:31888), which IS a UPalActivatableWidget,
--    and it carries those two BYTES as data. The game does not call SetInputMode when a menu
--    opens: it ACTIVATES a widget, and CommonUI's action router reads the topmost activatable's
--    declared config and applies it — then restores the previous one when that widget
--    deactivates. Opening the inventory and closing it again is one activate and one deactivate.
--
--    THE GAME WATCHES THAT HAPPEN, which is the proof it is the router's decision and not the
--    caller's: APalHUDInGame::OnActiveInputModeChanged(ECommonInputMode) — Pal.hpp:9742 — is a
--    callback the HUD gets when the ROUTER's active mode changes. ECommonInputMode is
--    { Menu, Game, All } (CommonInput_enums.hpp:8). Nothing broadcasts that when we call
--    UWidgetBlueprintLibrary::SetInputMode_* ourselves, because that call never reaches the
--    router. That is the whole of the desync.
--
-- 2. ESC IS NOT A KEY ON THIS BUILD. IT IS A NAMED UI ACTION.
--
--      DT_UIInputAction  /Game/Pal/DataTable/UI/DT_UIInputAction.DT_UIInputAction
--                        244 rows, INCLUDING "UIEscape" and "UICancel"
--                        (core/keyboard/base/actions.lua:60-121 carries the shipped list)
--      FPalKeyConfigSettings.MouseAndKeyboardUIInputMappings : TMap<FName, FKey>  Pal.hpp:3978
--                        the player's action-name -> key map for exactly those rows
--      UPalUserWidget::RegisterActionBinding(FName ActionName, bool IsDisplayActionBar,
--                        TEnumAsByte<EInputEvent> InputType, <delegate> Callback)
--                        -> FPalUIActionBindData                            Pal.hpp:31898
--      UPalUserWidget::RegisterActionBinding_NotConcume(... same ...)       Pal.hpp:31897
--      UPalUserWidget::UnregisterActionBinding(FPalUIActionBindData&)       Pal.hpp:31895
--      UPalUserWidget.BindedActionHandles : TArray<FPalUIActionBindData>    Pal.hpp:31892
--      UPalUIActionWidgetBase::SetActionBinding_ForBP(FPalUIActionBindData) Pal.hpp:30203
--                        the on-screen prompt glyph, a UCommonActionWidget
--      UPalUIUtility::SetEnableCommonUIInput(WorldContext, FName flag, bool) Pal.hpp:31667
--      UPalUIUtility::ResetEnableCommonUIInput(WorldContext)                Pal.hpp:31670
--      UPalUIUtility::GetUIInputActionRowHandle(WorldContext, FName, out)   Pal.hpp:31694
--
--    So a Palworld screen that wants Esc does not bind a KEY. It asks its own widget for the
--    ACTION named "UIEscape" (or "UICancel"), the router resolves that action against the
--    activatable tree that owns the focused widget, and the binding is CONSUMING or not by which
--    of the two functions was called — `_NotConcume` is the game's own spelling of "observe".
--    Underneath, the router is UCommonUIActionRouterBase (CommonUI.hpp:794), specialised as
--    UPalCommonUIActionRouter (Pal.hpp:16698); the action table is
--    UCommonUIInputSettings.InputActions : TArray<FUIInputAction> (CommonUI.hpp:810), and the
--    generic BACK path is bIsBackHandler (CommonUI.hpp:149) + BP_OnHandleBackAction (:172).
--
--    ⚠️ WHAT THIS MEANS FOR RegisterKeyBind. A UE4SS keybind on Escape would OBSERVE the key and
--    could never PARTICIPATE: it cannot consume, it cannot order itself against the router, and
--    it would fire whether or not a screen of ours is up. That is why ESCAPE stays refused as a
--    bindable key in core/keyboard — not as a safety rule, but because it is the wrong tool. The
--    right tool is the action binding above, and native/ui/keys.lua's header says so now.
--
--    ⚠️ AND WHAT IS NOT REACHABLE YET. RegisterActionBinding's fourth parameter is a DELEGATE.
--    core/signature refuses DelegateProperty outright (signature.lua:60-63) and UE4SS has no
--    documented way to push a Lua function into a delegate ARGUMENT (binding a delegate
--    PROPERTY is a different thing and is supported). So PalForge cannot make that call today.
--    Two routes remain and both are measurable rather than guessed:
--      (a) bIsBackHandler = true on our own activatable + a hook on
--          /Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction. The click router in
--          this file already proves hooks take in the CommonUI module.
--      (b) a hook on /Script/Pal.PalUserWidget:RegisterActionBinding, which OBSERVES every
--          action the game's own screens bind, with the name and the widget. That is what
--          test/init.lua's pf_uiroute arms; it is a reading instrument, not a binding.
--
-- 3. A SCREEN IS PUT UP THROUGH A LAYER, NOT BY PARENTING INTO A CANVAS.
--
--      class UPrimaryGameLayout : public UCommonUserWidget                CommonGame.hpp:156
--          TMap<FGameplayTag, UCommonActivatableWidgetContainerBase*> Layers;  :158
--          void RegisterLayer(FGameplayTag, UCommonActivatableWidgetContainerBase*);  :160
--      class UPalPrimaryGameLayoutBase : public UPrimaryGameLayout        Pal.hpp
--      class UCommonActivatableWidgetContainerBase : public UWidget       CommonUI.hpp:180
--          UCommonActivatableWidget* BP_AddWidget(TSubclassOf<UCommonActivatableWidget>);  :194
--          void RemoveWidget(UCommonActivatableWidget*);                       :190
--          UCommonActivatableWidget* GetActiveWidget();                        :192
--          TArray<UCommonActivatableWidget*> WidgetList;                       :185
--      class UPalActivatableWidgetContainer : public UCommonActivatableWidgetStack  Pal.hpp
--
--    PalForge ALREADY FINDS THE RIGHT OBJECT and then goes round the front door: M.gameUIRoot
--    does FindFirstOf("PalPrimaryGameLayoutBase") and reaches past it into CanvasPanel_Root.
--    That draws — it is confirmed drawing, tree.lua:1-9 — and it is not how the game does it.
--    BP_AddWidget on one of that layout's LAYERS creates the widget, pushes it on the stack,
--    activates it, gives it the transition, hands it to the router, and hands the instance back.
--    RemoveWidget takes it off and the router restores whatever was underneath.
--
--    The alternatives the game also uses, for completeness — all instance-or-class calls that
--    exist on this build and none of which need a struct:
--      APalHUDInGame::AddHUD(TSubclassOf<UPalUserWidget>, EPalHUDWidgetPriority,
--                            UPalHUDDispatchParameterBase*) -> FGuid          Pal.hpp:9755
--      APalHUDInGame::CloseHUDWidget(UPalUserWidget*) / RemoveHUD(FGuid)      Pal.hpp:9751, :9739
--      APalHUDInGame::PushWidgetStackableUI(TSubclassOf<...>, Param) -> FGuid Pal.hpp:9740
--      UPalUIHUDLayoutBase::AddHUD(UPalUserWidget* Widget, int32 ZOrder)      Pal.hpp:30714
--      UPalUIHUDLayoutBase::RemoveHUD(UPalUserWidget* Widget)                 Pal.hpp:30712
--      UPalUserWidget::Push(TSubclassOf<UPalUserWidgetOverlayUI>, Param)      Pal.hpp:31894
--    EPalHUDWidgetPriority is Pal_enums.hpp:2007. Note AddHUD takes an INSTANCE and a ZORDER —
--    it is the game's own answer to the z question this tree solves with SetZOrder — but its
--    parameter is a UPalUserWidget, so only a widget built from a Palworld class may be handed
--    to it. WBP_PalCommonWindow_C is one (WBP_PalCommonWindow.hpp:4), which is exactly why
--    UI.Frame is the node that unlocks the game's own route.
--
-- 4. ⚠️ WHY ESC DIED, AND HOW THAT IS KNOWN. Two live runs, one variable between them.
--
--      RUN 1  input = "clicks" -> SetInputMode_GameAndUIEx, no focus hand-back.
--             Esc OPENED the game's menu and would not CLOSE it.
--      RUN 2  the same, plus SetFocusToGameViewport immediately and again a heartbeat later,
--             plus the frame's three CommonUI activation flags read and forced false.
--             Esc did NOTHING AT ALL — it did not even open the menu.
--
--    The flags were measured `bIsBackHandler=false bIsModal=false bSupportsActivationFocus=true`
--    BEFORE being written, so the frame was never claiming Back and was never modal: that
--    suspect is dead, in both runs. The only behavioural change between the two runs was the
--    focus hand-back, and it made things STRICTLY WORSE — which rules the focus argument out as
--    the cause of run 1 and rules the hand-back in as a second, independent harm. What is left,
--    present in both runs and in no run where Esc worked, is SetInputMode_GameAndUIEx itself.
--
--    That is consistent with §1 and §2 and with nothing else: the mode is the router's, derived
--    from the activatable stack and broadcast to the game (Pal.hpp:9742); Esc is an action the
--    router resolves against that stack. Writing the mode behind the router leaves it holding a
--    description of the input state that is no longer true, and forcing focus onto the bare
--    SViewport takes the focused widget OUT of every activatable tree the router owns, so the
--    action has nothing to resolve against at all. Worse, then, is exactly what one would
--    predict.
--
--    ⚠️ WHAT IS INFERENCE AND WHAT IS NOT. The dump gives §1, §2 and §3 outright — the
--    properties, the functions, the enums and the HUD callback are all this install's. The
--    step "and therefore the router's cached config goes stale" is UE/CommonUI behaviour this
--    repo cannot read, and it is the one link in the chain that is reasoning rather than
--    evidence. It is testable, cheaply, and pf_uiroute tests it: hook
--    APalHUDInGame:OnActiveInputModeChanged and watch whether it fires when the GAME opens a
--    menu (it must) and whether it fires when WE mount a panel (today it must not).
--
-- 5. SO THE RULE IN THIS FILE IS NOW: THE MODE IS NEVER WRITTEN DIRECTLY.
--    An element that wants the mouse declares it, the declaration is written onto the
--    ACTIVATABLE WIDGET as InputConfig / GameMouseCaptureMode before it is activated, and the
--    router does the rest — including putting it back. UWidgetBlueprintLibrary's three
--    input-mode entries (UMG.hpp:2003-2005) and SetFocusToGameViewport (:2007) are deliberately
--    NOT CALLED anywhere in this module any more. They are named here so nobody has to find
--    them again, and so the next person knows the calls were tried and what they cost.
--=============================================================================

---EPalWidgetInputMode (Pal_enums.hpp:5367) — what a Palworld screen declares it needs.
M.PAL_INPUT_MODE = { DEFAULT = 0, GAME_AND_MENU = 1, GAME = 2, MENU = 3 }

---EMouseCaptureMode (Engine_enums.hpp:2237) — the other byte on the same widget.
M.MOUSE_CAPTURE = { NO_CAPTURE = 0, PERMANENT = 1, PERMANENT_INCLUDING_INITIAL_DOWN = 2,
                    DURING_MOUSE_DOWN = 3, DURING_RIGHT_MOUSE_DOWN = 4 }

---api/ui's `input` names, translated into what a Palworld screen would declare for the same
---thing. `pal` nil means the element asks for no mode at all and the router is never involved.
---
---This table is the single place the two vocabularies meet. api/ui declares the same NAMES (it
---makes no engine call, so it cannot read this) and the two are kept in step by test/cases/ui.
M.INPUT_MODES = {
    none      = { pal = nil, cursor = false,
                  doc = "takes nothing at all" },
    cursor    = { pal = nil, cursor = true,
                  doc = "shows the cursor (a plain restorable property) and nothing else" },
    clicks    = { pal = M.PAL_INPUT_MODE.GAME_AND_MENU, capture = M.MOUSE_CAPTURE.DURING_MOUSE_DOWN,
                  cursor = true, needsActivatable = true,
                  doc = "the game's GameAndMenu: clicks reach widgets, the player still moves" },
    exclusive = { pal = M.PAL_INPUT_MODE.MENU, capture = M.MOUSE_CAPTURE.NO_CAPTURE,
                  cursor = true, needsActivatable = true,
                  doc = "the game's Menu: a modal, exactly what an inventory screen declares" },
}

--=============================================================================
-- reading the declaration before calling — the literal version
--
-- core/signature refuses a call whose declared parameter kinds do not match what the caller
-- said it would pass. That is the right default and it costs one thing: a caller who does not
-- KNOW the kind (is TSubclassOf a ClassProperty or an ObjectProperty on this build?) has to
-- guess, and a wrong guess logs a refusal that reads like a defect. So ask the declaration for
-- its kinds and pass those. Nothing is loosened by this — signature still walks the live
-- UFunction, still refuses the unverifiable kinds, and still checks the arguments; the only
-- change is that the EXPECTED list comes from the build instead of from a header.
--=============================================================================

---The first `n` declared parameter kinds of `owner:fnName`, or nil when the build will not walk
---the UFunction (in which case the caller must fall back to a written-down shape).
---@return string[]? kinds
function M.declaredKinds(owner, fnName, n)
    local fn = sig.find(owner, fnName)
    if not fn then return nil end
    local params = sig.paramsOf(fn)
    if type(params) ~= "table" then return nil end
    local out = {}
    for i = 1, n do
        local p = params[i]
        if not p or type(p.kind) ~= "string" then return nil end
        out[i] = p.kind
    end
    return out
end

--=============================================================================
-- the game's UI layers
--=============================================================================

---The live UPalPrimaryGameLayoutBase, or nil + why. The same object M.gameUIRoot reaches past.
---@return userdata? layout, string? why
function M.gameLayout()
    local layout = M.findFirst(M.PATHS.gameUILayout)
    if not layout then
        return nil, "no " .. M.PATHS.gameUILayout .. " live (title screen, or still loading)"
    end
    return layout
end

---Every registered CommonUI layer of the in-game layout: { tag, container, class, count }.
---
---`Layers` is a TMap<FGameplayTag, UCommonActivatableWidgetContainerBase*> (CommonGame.hpp:158)
---and this WALKS it — ForEach only. It never calls Find/Contains, because those push the key
---through UE4SS's pusher and an FGameplayTag key has no measured push shape here; the crash that
---rule exists for is written out in core/keyboard/base/keymap.lua:118-127.
---@return table[] layers, string how
function M.uiLayers()
    local out = {}
    local layout = M.gameLayout()
    if not layout then return out, "no layout" end
    local map
    pcall(function() map = layout.Layers end)
    if map == nil then return out, "the layout has no readable Layers map" end
    local n = 0
    local ok = pcall(function()
        map:ForEach(function(k, v)
            n = n + 1
            local tag, container
            pcall(function() tag = k:get() end); tag = tag or k
            pcall(function() container = v:get() end); container = container or v
            local name
            pcall(function() name = tag.TagName:ToString() end)
            if name == nil then pcall(function() name = tostring(tag) end) end
            local cls, count
            pcall(function() cls = container:GetClass():GetFName():ToString() end)
            pcall(function() count = #container.WidgetList end)
            out[#out + 1] = { tag = name or "?", container = alive(container) and container or nil,
                              class = cls or "?", count = count }
        end)
    end)
    if not ok then return out, "the Layers map refused to iterate" end
    if n == 0 then return out, "the Layers map iterated nothing (it may genuinely be empty)" end
    return out, string.format("%d layer(s) by ForEach", n)
end

---The layers as printable lines. A report rather than a return, because "which layer" is a
---question nobody can answer from a header and the first run that prints this settles it.
---@return string[]
function M.layerReport()
    local layers, how = M.uiLayers()
    local out = { string.format("layers: %s", how) }
    for i, l in ipairs(layers) do
        out[#out + 1] = string.format("layers:   %d. %-44s %-34s widgets=%s",
            i, tostring(l.tag), tostring(l.class), tostring(l.count))
    end
    if #layers == 0 then
        out[#out + 1] = "layers: nothing to push onto — host = \"layer\" cannot resolve, and an "
            .. "element declaring it stays unmounted and says so (which is what autoMount retries)"
    end
    return out
end

---Push a widget CLASS onto one of the game's own CommonUI layers, the way the game does.
---
---`tag` is a layer tag substring (case-insensitive) or nil for the first layer found. Returns the
---created widget, the container it went onto, and the tag that matched — or nil + why.
---
---⚠️ UNMEASURED. Every fact this rests on is from the dump (CommonUI.hpp:180-195, CommonGame.hpp:
---156-160) and no run has yet watched BP_AddWidget answer here. It refuses rather than raises at
---every step, so an element that declares this host simply stays unmounted with a sentence.
---@return userdata? widget, userdata? container, string? tagOrWhy
function M.pushToLayer(tag, cls)
    if not alive(cls) then return nil, nil, "no widget class to push" end
    local layers, how = M.uiLayers()
    if #layers == 0 then return nil, nil, "no CommonUI layer is readable: " .. tostring(how) end
    local want = tag and tostring(tag):lower() or nil
    local chosen
    for _, l in ipairs(layers) do
        if l.container and (want == nil or tostring(l.tag):lower():find(want, 1, true)) then
            chosen = l; break
        end
    end
    if not chosen then
        local names = {}
        for _, l in ipairs(layers) do names[#names + 1] = tostring(l.tag) end
        return nil, nil, string.format("no layer matching %q — this layout registers %s",
            tostring(tag), table.concat(names, ", "))
    end

    -- TSubclassOf<UCommonActivatableWidget> — ClassProperty on paper, asked for in fact.
    local kinds = M.declaredKinds(chosen.container, "BP_AddWidget", 1) or { "ClassProperty" }
    local ok, w = sig.call(chosen.container, "BP_AddWidget", kinds, cls)
    if not ok or not alive(w) then
        return nil, nil, string.format("BP_AddWidget on layer %s did not answer with a widget "
            .. "(core/signature logged the declaration it read)", tostring(chosen.tag))
    end
    return w, chosen.container, tostring(chosen.tag)
end

---Take a widget back off the layer it was pushed onto. The router restores whatever was
---underneath — which is the half SetInputMode could never do.
---@return boolean removed
function M.removeFromLayer(container, w)
    if not (alive(container) and alive(w)) then return false end
    local kinds = M.declaredKinds(container, "RemoveWidget", 1) or { "ObjectProperty" }
    return sig.call(container, "RemoveWidget", kinds, w) == true
end

---Write an element's declared input mode onto the ACTIVATABLE WIDGET, which is where Palworld
---keeps it (Pal.hpp:13369-13370). Two plain byte properties: a read, a write and a read-back, no
---UFunction and no struct — the same class of operation core/keyboard/base/keymap.lua argues is
---safe, and the reason this route is takeable at all.
---
---⚠️ IT MUST HAPPEN BEFORE ActivateWidget. The router reads the config when the widget activates;
---writing it afterwards changes a byte nobody re-reads.
---@param w userdata     # a UPalActivatableWidget (or subclass)
---@param spec table     # one row of M.INPUT_MODES
---@return boolean wrote, string detail
function M.setWidgetInputConfig(w, spec)
    if not alive(w) then return false, "no widget" end
    if type(spec) ~= "table" or spec.pal == nil then
        return false, "this input mode asks the router for nothing"
    end
    if not M.isA(w, "PalActivatableWidget") then
        return false, "the widget is not a UPalActivatableWidget, so it has no InputConfig for "
            .. "the router to read (Pal.hpp:13367-13370)"
    end
    local wasMode, wasCapture
    pcall(function() wasMode = w.InputConfig end)
    pcall(function() wasCapture = w.GameMouseCaptureMode end)
    local wroteMode = pcall(function() w.InputConfig = spec.pal end)
    local wroteCapture = (spec.capture == nil)
        or pcall(function() w.GameMouseCaptureMode = spec.capture end)
    local nowMode
    pcall(function() nowMode = w.InputConfig end)
    -- The read-back is the measurement. A byte that will not take the write is a fact worth one
    -- line; a byte that took it and changed nothing on screen is a DIFFERENT fact, and only the
    -- router's own callback (Pal.hpp:9742) can tell them apart — see pf_uiroute.
    local detail = string.format("InputConfig %s -> %s (read back %s), GameMouseCaptureMode %s -> %s",
        tostring(wasMode), tostring(spec.pal), tostring(nowMode),
        tostring(wasCapture), tostring(spec.capture))
    return (wroteMode and wroteCapture and nowMode == spec.pal), detail
end

--=============================================================================
-- INPUT — what an element takes from the player, and the dead-man that gives it back
--
-- WHAT IS LEFT HERE AFTER §5 ABOVE. Exactly one engine write: bShowMouseCursor
-- (Engine.hpp:9035), a plain bool property that is READ before it is written and restored
-- exactly. Everything about the input MODE now happens on the activatable widget, before it is
-- activated, in M.setWidgetInputConfig — so grabInput's whole job is the cursor, the bookkeeping
-- and the dead-man.
--
-- THE DEAD-MAN, AND WHY IT IS A REGISTRY RATHER THAN A TIMER PER GRAB. Every grab goes into a
-- list on _G — the same trick core/poll.lua:28-30 uses and for the same reason: _G survives a
-- hot reload and the module tables do not. One poller sweeps that list on the heartbeat, on
-- ELAPSED SECONDS (core/poll.lua:51-56), and releases anything that can no longer be answered
-- for. It retires itself when the list is empty and is re-armed by the next grab, so an idle
-- session pays nothing.
--
-- THREE WAYS A GRAB BECOMES ORPHANED, and the sweep catches all three:
--   * the Lua state that took it is gone (F9 hot reload). Each grab is stamped with the LOAD
--     table of the module instance that created it, and the registry holds the current one; a
--     mismatch means nothing will ever call release, because the code that would have is gone.
--   * the element that took it is no longer mounted or no longer points at this grab. api/ui
--     supplies that answer as a closure, so the engine seam never has to know what an element is.
--   * nobody supplied an answer at all (a direct caller of this module). Then, and only then, a
--     wall-clock cap applies, because there is nothing else to go on.
-- The previous version armed a dead-man ONLY inside the "exclusive" branch and only after the
-- mode call succeeded, so a "cursor" grab, a degraded grab and every "clicks" grab had none.
--=============================================================================

---How long a grab NOBODY can answer for may be held. Elapsed seconds, never ticks.
M.GRAB_MAX_SECONDS = 120

-- A fresh table per LOAD of this module: the identity of the Lua state that is running now.
local LOAD = {}

local function grabRegistry()
    local g = _G.__PalForgeInputGrabs
    if type(g) ~= "table" then g = { list = {}, sweeping = false }; _G.__PalForgeInputGrabs = g end
    return g
end
grabRegistry().load = LOAD

---Release every outstanding grab that can no longer be answered for. Returns how many are still
---outstanding afterwards. Published so a probe can force a sweep and so the poller body is one
---named function rather than an anonymous closure nobody can call by hand.
---@return integer outstanding
function M.sweepGrabs()
    local g = grabRegistry()
    local keep = {}
    for _, grab in ipairs(g.list) do
        if not grab.released then
            local why
            if grab.load ~= g.load then
                why = "the Lua state that took it has been reloaded since (F9), so nothing will "
                    .. "ever call release for it"
            elseif type(grab.alive) == "function" then
                local ok, still = pcall(grab.alive)
                if not ok then
                    why = "the owner's liveness check raised: " .. tostring(still)
                elseif not still then
                    why = "the element that took it is no longer mounted and holding it"
                end
            elseif (os.clock() - (grab.t0 or 0)) > M.GRAB_MAX_SECONDS then
                why = string.format("it has been held for more than %d s and nobody is answering "
                    .. "for it", M.GRAB_MAX_SECONDS)
            end
            if why then
                err(string.format("input grab held by %s is being released without being asked: %s",
                    tostring(grab.id or "an unnamed caller"), why))
                M.releaseInput(grab)
            else
                keep[#keep + 1] = grab
            end
        end
    end
    g.list = keep
    return #keep
end

-- Arm the sweeper, lazily and at most once at a time. It rides core/poll's one heartbeat and
-- retires itself when there is nothing outstanding, so the next grab re-arms it — which also
-- means a poll.clear() cannot leave the list unwatched forever.
local function armSweeper()
    local g = grabRegistry()
    if g.sweeping then return end
    g.sweeping = true
    local ok = pcall(function()
        local poll = require("palforge.core.poll")
        g.sweeping = poll.every("ui input dead-man", function()
            if M.sweepGrabs() == 0 then grabRegistry().sweeping = false; return true end
            return false
        end) == true
    end)
    if not ok then g.sweeping = false end
end

---Take what `mode` asks for. Returns a grab token to hand back to M.releaseInput, or nil plus a
---reason — and "none" is a reason rather than a failure.
---
---⚠️ THE MODE HALF IS NOT DONE HERE ANY MORE. `clicks` and `exclusive` are carried on the
---activatable widget's own InputConfig (M.setWidgetInputConfig, called by M.gameFrame before it
---activates), because that is how Palworld does it and because writing the mode by hand is what
---broke Esc twice — see §4 and §5 of the block above. What arrives here for those two modes is
---the cursor plus a note saying whether the widget-side write actually happened, so a run can
---tell "the game's route was taken" from "the panel is not an activatable and got nothing".
---
---@param mode string    # a key of M.INPUT_MODES
---@param focus userdata # the element's own root widget; only inspected, never focused
---@param owner table?   # { id = string, alive = fun():boolean } — the dead-man's answer
---@return table? grab, string? reason
function M.grabInput(mode, focus, owner)
    if mode == nil or mode == "none" then
        return nil, "input = \"none\": the player's input was not touched"
    end
    local spec = M.INPUT_MODES[mode]
    if not spec then return nil, "unknown input mode " .. tostring(mode) end

    local pc = M.findFirst("PalPlayerController") or M.findFirst("PlayerController")
    if not pc then return nil, "no PlayerController to read the cursor flag off" end

    local cursorWas
    pcall(function() cursorWas = pc.bShowMouseCursor end)
    local grab = { pc = pc, mode = mode, cursorWas = cursorWas, applied = {}, t0 = os.clock(),
                   load = LOAD, id = owner and owner.id, alive = owner and owner.alive }

    -- IN THE REGISTRY BEFORE ANYTHING IS WRITTEN. The dead-man must cover a grab that fails
    -- half-way as surely as one that succeeds; the previous version registered nothing until
    -- after the mode call, which is why three of its five paths had no cover at all.
    local g = grabRegistry()
    g.list[#g.list + 1] = grab
    armSweeper()

    if spec.cursor and pcall(function() pc.bShowMouseCursor = true end) then
        grab.applied[#grab.applied + 1] = "bShowMouseCursor = true"
    end

    if spec.needsActivatable then
        -- Say, on the token, whether the game's own route was available at all. api/ui logs it.
        if M.isA(focus, "PalActivatableWidget") then
            grab.applied[#grab.applied + 1] = "the mode is carried on the widget's own InputConfig"
        else
            grab.note = string.format("input = %q asks for the game's %s mode, which Palworld "
                .. "carries on the ACTIVATABLE WIDGET (Pal.hpp:13369) — and this element's root "
                .. "is not one, so only the cursor was shown. Wrap the tree in UI.Frame{ }, which "
                .. "builds WBP_PalCommonWindow_C (a UPalUserWidget), and the mode is declared "
                .. "where the router reads it. PalForge no longer calls SetInputMode itself: "
                .. "doing that stopped Esc reaching the game's own menu, twice",
                mode, mode == "exclusive" and "Menu" or "GameAndMenu")
        end
    end
    return grab
end

---Hand a grab back: the cursor flag exactly as it was found, and nothing else to undo, because
---nothing else was written. The MODE goes back when the activatable deactivates and the router
---restores what was underneath — which is the half this file could never do by hand.
---@return boolean released
function M.releaseInput(grab)
    if type(grab) ~= "table" then return false end
    if grab.released then return false end
    grab.released = true
    local pc = grab.pc
    if alive(pc) and grab.cursorWas ~= nil then
        pcall(function() pc.bShowMouseCursor = grab.cursorWas end)
    end
    return true
end

---How many grabs are outstanding, and what they are — for UI.report and for a probe.
---@return string[]
function M.grabReport()
    local g = grabRegistry()
    if #g.list == 0 then return { "input: no element is holding any part of the player's input" } end
    local out = { string.format("input: %d grab(s) outstanding", #g.list) }
    for i, grab in ipairs(g.list) do
        out[#out + 1] = string.format("input:   %d. %-34s mode=%-10s held=%.0fs  %s%s", i,
            tostring(grab.id or "?"), tostring(grab.mode), os.clock() - (grab.t0 or 0),
            table.concat(grab.applied or {}, " + "),
            grab.note and ("  [" .. grab.note .. "]") or "")
    end
    return out
end

-- ---- slot helpers (return the created slot for further tweaking) ----
local function setVAlign(slot, halign)
    pcall(function() slot:SetHorizontalAlignment(halign) end)
    pcall(function() slot.HorizontalAlignment = halign end)
end

-- Call one AddChildTo* on `panel`; nil unless a slot really came back. Fail-soft on
-- purpose: `panel` may be nil, a plain table, or a widget of the wrong kind, and none of
-- those is worth raising over — the caller reads the nil and reports that nothing was placed.
local function tryAdd(panel, method, child)
    if not (panel and child) then return nil end
    local ok, slot = pcall(function() return panel[method](panel, child) end)
    if ok and slot then return slot end
    return nil
end

-- Put `child` into whatever kind of panel `panel` is, and return its slot (nil if it would
-- not take it). AddChild FIRST, deliberately: it is UPanelWidget's generic entry, every
-- panel overrides it to build its own slot type (a VerticalBox answers with a
-- VerticalBoxSlot), and it is the call the verified two-pane Mod Manager used through
-- addScroll. The typed names are only a fallback, and they go last because UE4SS does not
-- always answer an unknown method with nil — V7a recorded it handing back a TrivialObject —
-- so asking a ScrollBox for AddChildToVerticalBox is a question worth not asking first.
local function slotClassName(slot)
    local ok, n = pcall(function() return slot:GetClass():GetFName():ToString() end)
    return (ok and type(n) == "string") and n or nil
end

function M.addChild(panel, child)
    local slot = tryAdd(panel, "AddChild", child)
        or tryAdd(panel, "AddChildToVerticalBox", child)
        or tryAdd(panel, "AddChildToHorizontalBox", child)
        or tryAdd(panel, "AddChildToOverlay", child)
    if not slot then return nil end

    -- A CanvasPanelSlot is the one slot class that lays its child out by OFFSETS, and a fresh
    -- one's are all zero — so a widget added to a canvas (which is what M.gameUIRoot hands back:
    -- UMG.hpp:347 says a UCanvasPanel answers with a UCanvasPanelSlot) occupies a 0x0 box and
    -- never draws. bAutoSize is what makes it take its own desired size instead, and it is the
    -- ONE way to fix that without a struct argument: SetAutoSize(bool) at UMG.hpp:363, against
    -- SetSize/SetPosition/SetOffsets/SetAnchors/SetAlignment which all take FVector2D, FMargin
    -- or FAnchors and are therefore not callable on evidence we have.
    -- Gated on the class name rather than tried blind: every box slot would otherwise log a
    -- refusal per child, and a title-menu entry is a box slot.
    if slotClassName(slot) == "CanvasPanelSlot" then
        sig.call(slot, "SetAutoSize", { "BoolProperty" }, true)
    end
    return slot
end

function M.addV(vbox, child, padTop)
    local slot = tryAdd(vbox, "AddChildToVerticalBox", child)
    if not slot then return nil end
    pcall(function() slot:SetPadding({ Left = 0, Top = padTop or 2, Right = 0, Bottom = padTop or 2 }) end)
    pcall(function() slot.Padding = { Left = 0, Top = padTop or 2, Right = 0, Bottom = padTop or 2 } end)
    setVAlign(slot, M.HALIGN.LEFT)
    return slot
end

function M.addH(hbox, child) return tryAdd(hbox, "AddChildToHorizontalBox", child) end
function M.addScroll(scroll, child) return tryAdd(scroll, "AddChild", child) end

-- Armed at load. See the note on installClicks for what conditional arming cost.
M.installClicks()

return M
