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
-- :30712) — and that route is NOT taken here, because its parameter is a UPalUserWidget
-- (Pal.hpp:31888) and M.screen builds a plain /Script/UMG.UserWidget. One route per host.
M.PATHS = {
    menuButton      = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C",
    palTextBlock    = "/Game/Pal/Blueprint/UI/PalTextBlock/BP_PalTextBlock.BP_PalTextBlock_C",
    invisibleButton = "/Game/Pal/Blueprint/UI/System/Style/WBP_PalInvisibleButton.WBP_PalInvisibleButton_C",
    menuButtonLabel = "Test_Content",      -- label widget inside WBP_Title_MenuButton
    menuButtonClick = "WBP_PalInvisibleButton",
    menuButtonInner = "HorizontalBox_0",
    gameUILayout    = "PalPrimaryGameLayoutBase",  -- the live in-game UI root, by native class
    gameUIRoot      = "CanvasPanel_Root",          -- its root UCanvasPanel: the injection host
}

-- Slate alignment enums, named so callers don't memorize integers.
M.HALIGN = { FILL = 0, LEFT = 1, CENTER = 2, RIGHT = 3 }
M.VALIGN = { FILL = 0, TOP = 1, CENTER = 2, BOTTOM = 3 }
M.SIZE   = { AUTO = 0, FILL = 1 }

-- ---- shared click router (ported from the old clicks module) ----
local handlers = {}   -- fullName -> fn
local hooked   = false

local function fullName(w)
    local ok, n = pcall(function() return w:GetFullName() end)
    return ok and n or nil
end

-- Install the single dispatch hook (idempotent). Called lazily by registerClick.
-- The failure is logged ONCE, not once per button: with no UE4SS there is no RegisterHook
-- and every registerClick would otherwise print a line.
local clickHookLogged = false
function M.installClicks()
    if hooked then return true end
    local ok = pcall(function()
        RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(self)
            local name
            local ok2 = pcall(function() name = self:get():GetFullName() end)
            if not ok2 or not name then return end
            local fn = handlers[name]
            if fn then
                local oke, e = pcall(fn)
                if not oke then err("click handler: " .. tostring(e)) end
            end
        end)
    end)
    hooked = ok
    if ok or not clickHookLogged then
        clickHookLogged = true
        log(ok and "clicks: hook installed" or "clicks: hook FAILED")
    end
    return ok
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
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local cls = StaticFindObject(classPath)
    if not (lib and lib:IsValid() and cls and cls:IsValid() and pc and pc:IsValid()) then
        return nil, "create prerequisites missing for " .. tostring(classPath)
    end
    local w = lib:Create(pc, cls, pc)
    if not (w and w:IsValid()) then return nil, "Create failed for " .. tostring(classPath) end
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
    local layout = M.findFirst(M.PATHS.gameUILayout)
    if not layout then
        return nil, "no " .. M.PATHS.gameUILayout .. " live (title screen, or still loading)"
    end
    local panel
    pcall(function() panel = layout[M.PATHS.gameUIRoot] end)
    if not alive(panel) then
        return nil, M.PATHS.gameUILayout .. " has no live " .. M.PATHS.gameUIRoot
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

-- ---- Palworld game widgets ----

-- Force a freshly created WBP_Title_MenuButton's inner content to the left so labels align
-- regardless of the button's outer width. Cosmetic and best-effort: the label is legible either
-- way, and clickableRow does not depend on it (it overlays its own left-aligned text).
--
-- THIS USED TO CALL SetAnchors + SetAlignment, AND THAT WAS THE WRONG CALL TO MAKE. dumps/cxx
-- says so twice over:
--   * Those two exist on UCanvasPanelSlot and on NO other slot class in the whole of UMG
--     (UMG.hpp:364-365). UHorizontalBoxSlot (:734), UVerticalBoxSlot (:1800), UOverlaySlot
--     (:1056) and USizeBoxSlot (:1328) declare SetHorizontalAlignment / SetVerticalAlignment /
--     SetPadding instead, and UPanelSlot itself (:1067) declares no setter at all. So on five of
--     the six slot classes the old pair could never have done anything.
--   * Both take STRUCTS — SetAnchors(FAnchors), SetAlignment(FVector2D). A struct argument on an
--     unread declaration is the category that faults inside UE4SS marshalling, where pcall does
--     NOT catch it and the process dies. The pcall around them was never protection.
--
-- What replaces them is one ENUM call: SetHorizontalAlignment(TEnumAsByte<EHorizontalAlignment>),
-- declared by every box/overlay/size slot, with HAlign_Left = 1 confirmed at
-- SlateCore_enums.hpp:91-97 (which is where M.HALIGN's numbers come from). It goes through
-- core/signature, so if this slot IS a CanvasPanelSlot the live parameter walk finds no such
-- function and the call is REFUSED and logged rather than made — and that log line is itself the
-- answer to the question below, from an ordinary session instead of a probe.
--
-- TODO(ui-menubutton-inner-slot): still unknown — whether a widget named `HorizontalBox_0` is
-- in a created WBP_Title_MenuButton's tree AT ALL, and if so which slot class it occupies.
-- dumps/cxx/WBP_Title_MenuButton.hpp:11-15 lists the button's five declared widget members —
-- Image_161, Image_Icon_Appeal, SizeBox_Icon, Test_Content, WBP_PalInvisibleButton — and
-- HorizontalBox_0 is not among them, while the two names this file DOES match by string are.
-- That is not proof of absence (a widget with "Is Variable" unchecked gets no member and still
-- exists in the WidgetTree), so what is owed is one line off a live button: findByName returning
-- nil means the name is stale and the whole function should go; a slot whose class this now logs
-- means it is real and the alignment is settled.
local function leftAlignButtonContent(btn)
    local inner = M.findByName(btn, M.PATHS.menuButtonInner)
    if not alive(inner) then return false end
    local slot
    pcall(function() slot = inner.Slot end)
    if not alive(slot) then return false end
    -- ByteProperty: UE spells an enum parameter either ByteProperty or EnumProperty and
    -- signature treats the two as equivalent, so naming one covers both.
    local ok = sig.call(slot, "SetHorizontalAlignment", { "ByteProperty" }, M.HALIGN.LEFT)
    return ok == true
end

-- Clone the game's title menu button as a clickable row. Returns (button, invBtn,
-- clickName). `onClick` is routed through the shared click router; clickName is that
-- registration's key — keep it and pass it to releaseClicks when you drop the button.
-- `tree` is UNUSED: WidgetBlueprintLibrary:Create outers the widget itself, so a BP widget
-- needs no WidgetTree. The parameter is kept only so every builder here reads the same way.
function M.menuButton(tree, pc, label, onClick)
    local btn, e = M.create(pc, M.PATHS.menuButton)
    if not btn then return nil, e end
    local lbl = M.findByName(btn, M.PATHS.menuButtonLabel)
    if alive(lbl) then pcall(function() lbl:SetText(FText(label)) end) end
    leftAlignButtonContent(btn)
    local inv = M.findByName(btn, M.PATHS.menuButtonClick)
    local clickName
    if inv and onClick then
        local key = M.registerClick(inv, onClick)
        if key then clickName = key end
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

return M
