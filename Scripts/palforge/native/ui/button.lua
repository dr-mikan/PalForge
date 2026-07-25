-- PalForge native.ui: Button — a single clickable, native-styled button built from
-- Palworld's own native UMG kit. Defined through api/ui, so it only fills render() (the
-- "what"); the lifecycle (render-once / refresh / unmount) is owned by api/ui.
--
--   local Button = require("palforge.native.ui.button")
--   Button:new{ label = "OK", onClick = function() end }:mount(root)

local UI     = require("palforge.api.ui")
local widget = require("palforge.native.ui._widget")

return UI.define{
    id          = "palforge:Button",
    displayName = "Button",

    -- Build one native menu button from self.label / self.onClick and place it under
    -- `root` (best-effort; placement is host-panel dependent). Fail-soft.
    render = function(self, root)
        local pc = FindFirstOf("PalPlayerController")
        if not (pc and pc:IsValid()) then return false end
        local btn = widget.menuButton(root, pc, self.label or "", self.onClick)
        if not btn then return false end
        self.widget = btn
        -- Attach into the host panel if it accepts children (context-dependent).
        pcall(function()
            if root and root.AddChildToVerticalBox then root:AddChildToVerticalBox(btn)
            elseif root and root.AddChild then root:AddChild(btn) end
        end)
        return true
    end,
}
