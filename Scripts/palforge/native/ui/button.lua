-- PalForge native.ui: Button — a single clickable, native-styled button built from
-- Palworld's own native UMG kit. Defined through api/ui, so it fills render() (build the
-- button and place it), update() (write the current self.label into it) and destroy()
-- (take it back out); the lifecycle — WHEN those run — is owned by api/ui.
--
--   local widget = require("palforge.native.ui._widget")
--   local screen = widget.screen()          -- a panel of our own to host it
--   Button:new{ label = "OK", onClick = function() end }:mount(screen.root)

local UI     = require("palforge.api.ui")
local widget = require("palforge.native.ui._widget")

local alive = widget.alive

return UI{
    id          = "palforge:Button",
    name        = "Button",

    -- Build one native menu button from self.label / self.onClick and place it under
    -- `root` (any panel that takes children — a widget.screen() vbox, or a panel of the
    -- game's own). Fail-soft: returns false, having built nothing that survives, when
    -- there is no player controller or `root` did not accept the button.
    render = function(self, root)
        local pc = widget.findFirst("PalPlayerController")
        if not pc then return false end
        local btn, _, clickName = widget.menuButton(root, pc, self.label or "", self.onClick)
        if not btn then return false end
        self.widget, self.clickName = btn, clickName
        self.labelWidget = widget.findByName(btn, widget.PATHS.menuButtonLabel)
        -- Attach into the host panel if it accepts children (context-dependent).
        local slot
        pcall(function()
            if root and root.AddChildToVerticalBox then slot = root:AddChildToVerticalBox(btn)
            elseif root and root.AddChild then slot = root:AddChild(btn) end
        end)
        if not slot then
            -- Placed nowhere: drop it rather than leak an invisible button and a live
            -- click handler, and report the failure so the mount does not latch.
            self:destroy()
            return false
        end
        return true
    end,

    -- Write the current self.label into the live button. False if the button is gone
    -- (the host panel dropped it) or its label widget could not be reached.
    update = function(self)
        if not alive(self.widget) then return false end
        if not alive(self.labelWidget) then
            self.labelWidget = widget.findByName(self.widget, widget.PATHS.menuButtonLabel)
            if not alive(self.labelWidget) then return false end
        end
        local lbl = self.labelWidget
        return pcall(function() lbl:SetText(FText(tostring(self.label or ""))) end)
    end,

    -- Take the button out of its host panel and drop its click handler, so a later
    -- mount() builds a fresh one instead of leaving an orphan behind. True if a live
    -- button was actually removed.
    destroy = function(self)
        local btn = self.widget
        if self.clickName then widget.releaseClicks({ self.clickName }) end
        self.widget, self.labelWidget, self.clickName = nil, nil, nil
        if not alive(btn) then return false end
        return pcall(function() btn:RemoveFromParent() end)
    end,
}
