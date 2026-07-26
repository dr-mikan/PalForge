-- PalForge native.ui: TitleMenu — injects entries into the game's title screen, built
-- from Palworld's own native UMG kit. Defined through api/ui, so it only fills render()
-- (the "what" to inject). The lifecycle (render runs once; refresh driving) is owned by
-- api/ui — this file writes NO watch loop.
--
-- Title layout: PalUITitleBase.WidgetTree.RootWidget -> ... -> VerticalBox_0
-- (the button column); each entry is a SizeBox -> WBP_Title_MenuButton.
--
--   local TitleMenu = require("palforge.native.ui.title_menu")
--   TitleMenu:new{ entries = { { label = "Mods", onClick = openMods } } }:mount()

local UI     = require("palforge.api.ui")
local widget = require("palforge.native.ui._widget")

-- Locate the title screen's root widget (or use an explicitly supplied root).
local function titleRoot(root)
    if root and root.IsValid and root:IsValid() then return root end
    local base = FindFirstOf("PalUITitleBase")
    if not (base and base:IsValid()) then return nil end
    local r
    pcall(function() r = base.WidgetTree.RootWidget end)
    if r and r.IsValid and r:IsValid() then return r end
    return nil
end

-- Style a VerticalBox slot to match native entries (left-aligned, small padding).
local function styleSlot(slot)
    pcall(function() slot:SetHorizontalAlignment(widget.HALIGN.LEFT) end)
    pcall(function() slot.HorizontalAlignment = widget.HALIGN.LEFT end)
    pcall(function() slot:SetPadding({ Left = 0, Top = 3, Right = 0, Bottom = 3 }) end)
    pcall(function() slot.Padding = { Left = 0, Top = 3, Right = 0, Bottom = 3 } end)
end

-- Inject one entry as a native menu button wrapped in a SizeBox, added to the
-- button column. Records the invisible button on the entry so a later refresh can
-- tell whether it is still alive. Returns true on success.
local function injectEntry(root, vbox, pc, e)
    local btn, inv = widget.menuButton(vbox, pc, e.label or "", e.onClick)
    if not btn then return false end
    e.invButton = inv
    local sizeBox = widget.sizeBox(vbox)
    pcall(function() sizeBox:SetContent(btn) end)
    styleSlot(vbox:AddChildToVerticalBox(sizeBox))
    -- Keep "Exit Game" last: VerticalBox has no insert, so move Exit to the end.
    pcall(function()
        local exitBtn = widget.findByName(root, "WBP_Title_MenuButton_ExitGame")
        if exitBtn and exitBtn:IsValid() then
            local exitBox = exitBtn:GetParent()
            if exitBox and exitBox:IsValid() then
                vbox:RemoveChild(exitBox)
                styleSlot(vbox:AddChildToVerticalBox(exitBox))
            end
        end
    end)
    return true
end

return UI{
    id          = "palforge:TitleMenu",
    name        = "Title Menu",

    -- Inject every entry from self.entries into the title's VerticalBox_0. Called once by
    -- the api/ui lifecycle (mount). Fail-soft; returns true if any entry was injected.
    render = function(self, root)
        local base = titleRoot(root)
        if not base then return false end
        local vbox = widget.findByName(base, "VerticalBox_0")
        if not (vbox and vbox:IsValid()) then return false end
        local pc = FindFirstOf("PalPlayerController")
        if not (pc and pc:IsValid()) then return false end
        local n = 0
        for _, e in ipairs(self.entries or {}) do
            if injectEntry(base, vbox, pc, e) then n = n + 1 end
        end
        return n > 0
    end,
}
