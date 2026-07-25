-- PalForge native.ui._widget: reusable native-UMG toolkit. Builds in-game UI from
-- Palworld's OWN widgets + native UMG, in Lua (no cooked WidgetBlueprints). The
-- native UI elements (button, title_menu) use this in their render() to assemble
-- their widget trees. The element LIFECYCLE lives in palforge.api.ui; this module
-- only builds/wires widgets — it holds no lifecycle or watch loop.
--
-- Ported self-contained (no PalForge module deps) so core/native do not depend on
-- the deprecated layer. Includes the shared CLICK ROUTER: one RegisterHook on
-- CommonButtonBase dispatches to whichever callback registered the clicked button;
-- it is installed lazily on the first registerClick().

local M = {}

local function log(msg) pcall(print, "[PalForge.ui] " .. tostring(msg)) end
local function err(msg) pcall(print, "[PalForge.ui] ERR " .. tostring(msg)) end

-- Known Palworld UI asset/class paths (from the title menu).
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
    log(ok and "clicks: hook installed" or "clicks: hook FAILED")
    return ok
end

-- Register a CommonButtonBase widget (the WBP_PalInvisibleButton inside a menu
-- button) so clicking it runs fn. Lazily installs the dispatch hook. Returns true.
function M.registerClick(invButton, fn)
    if not (invButton and invButton:IsValid()) then return false end
    M.installClicks()
    local name = fullName(invButton)
    if not name then return false end
    handlers[name] = fn
    return true
end

-- Drop all handlers whose key isn't in keepSet (a table of fullNames to keep).
function M.retainClicks(keepSet)
    for name in pairs(handlers) do
        if not keepSet[name] then handlers[name] = nil end
    end
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

function M.sizeBox(tree, w, h)
    local s = M.construct("/Script/UMG.SizeBox", tree)
    if w then pcall(function() s:SetWidthOverride(w) end) end
    if h then pcall(function() s:SetHeightOverride(h) end) end
    return s
end

function M.text(tree, str, size, rgba)
    local t = M.construct("/Script/UMG.TextBlock", tree)
    pcall(function() t:SetText(FText(tostring(str))) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color(rgba or { 0.95, 0.93, 0.86, 1 }), ColorUseRule = 0 }) end)
    pcall(function() local f = t.Font; f.Size = size or 16; t.Font = f end)
    return t
end

-- ---- Palworld game widgets ----

-- Force a freshly created WBP_Title_MenuButton's inner content to the left so
-- labels align regardless of the button's outer width.
local function leftAlignButtonContent(btn)
    local inner = M.findByName(btn, M.PATHS.menuButtonInner)
    if not (inner and inner:IsValid()) then return end
    pcall(function()
        local slot = inner.Slot
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.5 }, Maximum = { X = 0.0, Y = 0.5 } })
        slot:SetAlignment({ X = 0.0, Y = 0.5 })
    end)
end

-- Clone the game's title menu button as a clickable row. Returns (button, invBtn).
-- `onClick` is routed through the shared click router.
function M.menuButton(tree, pc, label, onClick)
    local btn, e = M.create(pc, M.PATHS.menuButton)
    if not btn then return nil, e end
    local lbl = M.findByName(btn, M.PATHS.menuButtonLabel)
    if lbl and lbl:IsValid() then pcall(function() lbl:SetText(FText(label)) end) end
    leftAlignButtonContent(btn)
    local inv = M.findByName(btn, M.PATHS.menuButtonClick)
    if inv and onClick then M.registerClick(inv, onClick) end
    return btn, inv
end

-- A clickable, LEFT-ALIGNED row that still looks native. Returns (rowWidget, invBtn).
function M.clickableRow(tree, pc, label, onClick, opts)
    opts = opts or {}
    local overlay = M.overlay(tree)
    local btn, inv = M.menuButton(tree, pc, "", onClick)
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
    return overlay, inv
end

-- Generic: clone any Palworld BP widget, optionally set a label child's text and
-- wire a click. `opts = { label=, labelChild=, clickChild=, onClick= }`.
function M.cloneGameWidget(tree, pc, classPath, opts)
    opts = opts or {}
    local w, e = M.create(pc, classPath)
    if not w then return nil, e end
    if opts.label and opts.labelChild then
        local lbl = M.findByName(w, opts.labelChild)
        if lbl and lbl:IsValid() then pcall(function() lbl:SetText(FText(opts.label)) end) end
    end
    if opts.onClick and opts.clickChild then
        local c = M.findByName(w, opts.clickChild)
        if c then M.registerClick(c, opts.onClick) end
    end
    return w
end

-- ---- slot helpers (return the created slot for further tweaking) ----
local function setVAlign(slot, halign)
    pcall(function() slot:SetHorizontalAlignment(halign) end)
    pcall(function() slot.HorizontalAlignment = halign end)
end

function M.addV(vbox, child, padTop)
    local slot = vbox:AddChildToVerticalBox(child)
    pcall(function() slot:SetPadding({ Left = 0, Top = padTop or 2, Right = 0, Bottom = padTop or 2 }) end)
    pcall(function() slot.Padding = { Left = 0, Top = padTop or 2, Right = 0, Bottom = padTop or 2 } end)
    setVAlign(slot, M.HALIGN.LEFT)
    return slot
end

function M.addH(hbox, child) return hbox:AddChildToHorizontalBox(child) end
function M.addScroll(scroll, child) return scroll:AddChild(child) end

return M
