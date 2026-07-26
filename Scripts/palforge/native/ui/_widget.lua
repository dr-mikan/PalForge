-- PalForge native.ui._widget: reusable native-UMG toolkit. Builds in-game UI from
-- Palworld's OWN widgets + native UMG, in Lua (no cooked WidgetBlueprints). The
-- native UI elements (button, title_menu) use this in their render() to assemble
-- their widget trees. The element LIFECYCLE lives in palforge.api.ui; this module
-- only builds/wires widgets — it holds no lifecycle or watch loop.
--
-- Two ways to get a host for those widgets: inject into a panel the game already
-- has (title_menu does that), or make one of your own with M.screen() — the
-- UserWidget + WidgetTree + AddToViewport sequence verified in poc/V6-ui-native.
--
-- Ported self-contained (no PalForge module deps) so core/native do not depend on
-- the deprecated layer. Includes the shared CLICK ROUTER: one RegisterHook on
-- CommonButtonBase dispatches to whichever callback registered the clicked button;
-- it is installed lazily on the first registerClick().

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

-- Known Palworld UI asset/class paths. TITLE MENU ONLY — every entry below was read off
-- WBP_Title_MenuButton and the title screen (verified 2026-07-17, poc/V7-title-injection).
-- Nothing here names the live HUD, the inventory or the build menu, so cloneGameWidget()
-- and Button:mount(<a panel of the game's own>) have no in-game host to target: a PalForge
-- panel today is either a title entry or a viewport layer of our own (M.screen).
--
-- The HUD's own CLASS is known — deprecated/catalog/ui_widget_classes.txt lists
-- UPalUIHUDLayoutBase (and UPalUIWorldHUDWidgetCanvas / UPalUIInventoryEquipment); note it
-- does NOT list the "PalHUD"/"PalHUDWidget" that dump/docs/04_native_ui.md guesses at. What
-- is missing is one level down, and no dump in either tree has it:
-- TODO(ui-host-paths): unknown — the widget NAME of a child inside the live
-- PalUIHUDLayoutBase tree that is a UPanelWidget (i.e. answers AddChild), which is the one
-- fact needed to parent a PalForge widget into the game's HUD instead of our own layer.
M.PATHS = {
    menuButton      = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C",
    palTextBlock    = "/Game/Pal/Blueprint/UI/PalTextBlock/BP_PalTextBlock.BP_PalTextBlock_C",
    invisibleButton = "/Game/Pal/Blueprint/UI/System/Style/WBP_PalInvisibleButton.WBP_PalInvisibleButton_C",
    menuButtonLabel = "Test_Content",      -- label widget inside WBP_Title_MenuButton
    menuButtonClick = "WBP_PalInvisibleButton",
    menuButtonInner = "HorizontalBox_0",
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
-- regardless of the button's outer width. Cosmetic and best-effort: SetAnchors/SetAlignment
-- exist on a CanvasPanelSlot, and nobody has recorded what HorizontalBox_0's Slot actually
-- is inside that button — on any other slot class both calls raise inside the pcall and the
-- label simply stays centred. Left as-is rather than guessed at: the label is still legible
-- either way, and clickableRow does not depend on it (it overlays its own left-aligned text).
-- TODO(ui-menubutton-inner-slot): unknown — the CLASS of `HorizontalBox_0`.Slot inside a
-- created WBP_Title_MenuButton, which decides whether these two calls do anything at all.
local function leftAlignButtonContent(btn)
    local inner = M.findByName(btn, M.PATHS.menuButtonInner)
    if not (inner and inner:IsValid()) then return end
    pcall(function()
        local slot = inner.Slot
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.5 }, Maximum = { X = 0.0, Y = 0.5 } })
        slot:SetAlignment({ X = 0.0, Y = 0.5 })
    end)
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
function M.addChild(panel, child)
    return tryAdd(panel, "AddChild", child)
        or tryAdd(panel, "AddChildToVerticalBox", child)
        or tryAdd(panel, "AddChildToHorizontalBox", child)
        or tryAdd(panel, "AddChildToOverlay", child)
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
