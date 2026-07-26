-- PalForge native.ui: Button — a single clickable, native-styled button built from
-- Palworld's own native UMG kit. Defined through api/ui, so it fills render() (build the
-- button and place it), update() (write the current self.label / self.onClick into it) and
-- destroy() (take it back out); the lifecycle — WHEN those run — is owned by api/ui.
--
--   local widget = require("palforge.native.ui").widget
--   local screen = widget.screen()          -- a panel of our own to host it
--   local btn = Button:new{ label = "OK", onClick = function() end }
--   btn:mount(screen.root)
--   btn:state().label = "Done"; btn:refresh()   -- update() writes the new label + handler

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
        local btn, inv, clickName = widget.menuButton(root, pc, self.label or "", self.onClick)
        if not btn then return false end
        self.widget, self.invButton, self.clickName = btn, inv, clickName
        self._wiredClick = self.onClick   -- what the router currently holds (see update)
        -- Kept for callers that want the widget itself; the WRITE goes through
        -- widget.setButtonText, which knows that some button classes declare their own SetText
        -- and that the child's NAME differs per class (Text_Main vs Test_Content).
        self.labelWidget = widget.buttonLabel(btn)
        -- Attach into the host panel, whatever kind of panel it is: addChild tries the
        -- typed AddChildTo* first and falls back to UPanelWidget's generic AddChild.
        local slot = widget.addChild(root, btn)
        if not slot then
            -- Placed nowhere: drop it rather than leak an invisible button and a live
            -- click handler, and report the failure so the mount does not latch.
            self:destroy()
            return false
        end
        return true
    end,

    -- Write the current self.label AND the current self.onClick into the live button.
    -- False if the button is gone (the host panel dropped it) or its label widget could
    -- not be reached.
    --
    -- The click is re-wired because self.onClick is a field the caller may change after
    -- mounting, and render() is the only other place that reads it: without this a
    -- refreshed button keeps calling the handler it was built with. registerClick keys on
    -- the invisible button's own name, so re-registering REPLACES the router entry rather
    -- than adding one; clearing onClick drops it instead.
    update = function(self)
        if not alive(self.widget) then return false end
        if self.onClick ~= self._wiredClick then
            if self.onClick and alive(self.invButton) then
                local key = widget.registerClick(self.invButton, self.onClick)
                if key then self.clickName = key end
            elseif self.clickName then
                widget.releaseClicks({ self.clickName })
                self.clickName = nil
            end
            self._wiredClick = self.onClick
        end
        if not alive(self.labelWidget) then self.labelWidget = widget.buttonLabel(self.widget) end
        return widget.setButtonText(self.widget, self.label or "")
    end,

    -- Take the button out of its host panel and drop its click handler, so a later
    -- mount() builds a fresh one instead of leaving an orphan behind. True if a live
    -- button was actually removed.
    destroy = function(self)
        local btn = self.widget
        if self.clickName then widget.releaseClicks({ self.clickName }) end
        self.widget, self.labelWidget, self.invButton = nil, nil, nil
        self.clickName, self._wiredClick = nil, nil
        if not alive(btn) then return false end
        return pcall(function() btn:RemoveFromParent() end)
    end,
}
