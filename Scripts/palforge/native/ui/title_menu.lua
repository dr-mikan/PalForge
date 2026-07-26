-- PalForge native.ui: TitleMenu — injects entries into the game's title screen, built
-- from Palworld's own native UMG kit. Defined through api/ui, so it fills render() (the
-- "what" to inject), update() (re-assert the injection) and destroy() (take it back
-- out). The lifecycle — WHEN those run — is owned by api/ui; this file writes NO watch
-- loop, it only makes each seam safe to run at any moment.
--
-- Title layout: PalUITitleBase.WidgetTree.RootWidget -> ... -> VerticalBox_0
-- (the button column); each entry is a SizeBox -> WBP_Title_MenuButton.
--
--   local TitleMenu = require("palforge.native.ui.title_menu")
--   local menu = TitleMenu:new{ entries = { { label = "Mods", onClick = openMods } } }
--   menu:mount()            -- false while the title screen is absent; just call it again
--   menu:autoRefresh(2000)  -- re-injects the entries if the title screen rebuilds itself

local UI     = require("palforge.api.ui")
local widget = require("palforge.native.ui._widget")

local alive = widget.alive

-- Locate the title screen's root widget (or use an explicitly supplied root).
local function titleRoot(root)
    if alive(root) then return root end
    local base = widget.findFirst("PalUITitleBase")
    if not base then return nil end
    local r
    pcall(function() r = base.WidgetTree.RootWidget end)
    if alive(r) then return r end
    return nil
end

-- Style a VerticalBox slot to match native entries (left-aligned, small padding).
local function styleSlot(slot)
    pcall(function() slot:SetHorizontalAlignment(widget.HALIGN.LEFT) end)
    pcall(function() slot.HorizontalAlignment = widget.HALIGN.LEFT end)
    pcall(function() slot:SetPadding({ Left = 0, Top = 3, Right = 0, Bottom = 3 }) end)
    pcall(function() slot.Padding = { Left = 0, Top = 3, Right = 0, Bottom = 3 } end)
end

-- The dimensions of a native entry's SizeBox, read off an existing one. Native
-- SizeBoxes have a FIXED width, which is why their left-anchored button content sits
-- left; without it our button stretches and centres. Read as PROPERTIES, not through
-- the getters — those read back nil (recorded in deprecated/titlemenu.lua). Returns
-- nil, nil when there is no sibling to copy, and sizeBox() then leaves the box auto.
local function nativeEntrySize(root)
    local sib = widget.findByName(root, "SizeBox_4")
    if not alive(sib) then return nil, nil end
    local w, h
    pcall(function() w = sib.WidthOverride end)
    pcall(function() h = sib.HeightOverride end)
    if type(w) ~= "number" or w <= 0 then w = nil end
    if type(h) ~= "number" or h <= 0 then h = nil end
    return w, h
end

-- Drop everything we recorded for an entry: its click handler (the router would keep
-- one dead entry per button forever) and its widgets. With `vbox`, the entry is also
-- taken out of the button column.
local function forgetEntry(e, vbox)
    if vbox and alive(e.sizeBox) then pcall(function() vbox:RemoveChild(e.sizeBox) end) end
    if e.clickName then widget.releaseClicks({ e.clickName }) end
    e.invButton, e.sizeBox, e.clickName = nil, nil, nil
end

-- Inject one entry as a native menu button wrapped in a SizeBox sized like the native
-- entries, added to the button column. Records the invisible button, its SizeBox and
-- its click-router key on the entry, so update() can tell whether it is still alive and
-- destroy() can take it back out. Returns true on success.
local function injectEntry(root, vbox, pc, e)
    local btn, inv, clickName = widget.menuButton(vbox, pc, e.label or "", e.onClick)
    if not btn then return false end
    e.invButton, e.clickName = inv, clickName
    local sizeBox = widget.sizeBox(vbox, nativeEntrySize(root))
    pcall(function() sizeBox:SetContent(btn) end)
    e.sizeBox = sizeBox
    local slot
    pcall(function() slot = vbox:AddChildToVerticalBox(sizeBox) end)
    if not slot then
        -- Nothing was placed: drop the handler rather than leave a click wired to a
        -- button nobody can see, and report the failure.
        forgetEntry(e)
        return false
    end
    styleSlot(slot)
    return true
end

-- Keep "Exit Game" last: a VerticalBox has no insert, so move Exit to the end by
-- removing and re-adding it. Runs ONCE after the entries are in, not per entry.
local function moveExitLast(root, vbox)
    pcall(function()
        local exitBtn = widget.findByName(root, "WBP_Title_MenuButton_ExitGame")
        if not (exitBtn and exitBtn:IsValid()) then return end
        local exitBox = exitBtn:GetParent()   -- the SizeBox wrapping the exit button
        if not (exitBox and exitBox:IsValid()) then return end
        vbox:RemoveChild(exitBox)
        styleSlot(vbox:AddChildToVerticalBox(exitBox))
    end)
end

-- Inject every entry that has no live button into the title's VerticalBox_0. Shared by
-- render (first mount: nothing is live yet) and update (re-assert after a rebuild) —
-- entries that are still alive are left alone, so it can never stack duplicates.
-- Returns how many went in, or nil + reason when the title screen is not there.
local function injectMissing(self, root)
    local base = titleRoot(root)
    if not base then return nil, "no title screen" end
    local vbox = widget.findByName(base, "VerticalBox_0")
    if not alive(vbox) then return nil, "no VerticalBox_0" end
    local pc = widget.findFirst("PalPlayerController")
    if not pc then return nil, "no PalPlayerController" end
    local old = alive(self.vbox) and self.vbox or nil   -- the column of a previous pass
    self.vbox = vbox                      -- the column destroy() takes our entries out of
    local n = 0
    for _, e in ipairs(self.entries or {}) do
        if not alive(e.invButton) then
            -- Clear what is left of a button that is gone: its stale click handler, and
            -- its now-empty SizeBox if the column it sat in is still the live one.
            forgetEntry(e, old)
            if injectEntry(base, vbox, pc, e) then n = n + 1 end
        end
    end
    if n > 0 then moveExitLast(base, vbox) end
    return n
end

return UI{
    id          = "palforge:TitleMenu",
    name        = "Title Menu",

    -- Inject every entry from self.entries into the title's VerticalBox_0. Called once
    -- per successful mount by the api/ui lifecycle. Fail-soft: returns true only if an
    -- entry really went in, so a mount attempted before the title screen exists leaves
    -- the element unmounted and can simply be repeated.
    render = function(self, root)
        self.host = root                  -- an explicit root, if the caller gave us one
        return (injectMissing(self, root) or 0) > 0
    end,

    -- Re-assert the injection. The title screen rebuilds its widget tree (returning to
    -- the title, for instance) and silently takes our buttons with it; every entry whose
    -- button is gone is injected again. This is the re-check deprecated/titlemenu.lua
    -- ran from its own LoopAsync — here the loop belongs to api/ui (:autoRefresh(2000)).
    -- True when every entry is present afterwards.
    update = function(self)
        local entries = self.entries or {}
        if #entries == 0 then return false end
        local dead = 0
        for _, e in ipairs(entries) do
            if not alive(e.invButton) then dead = dead + 1 end
        end
        if dead == 0 then return true end
        return (injectMissing(self, self.host) or 0) >= dead
    end,

    -- Take our entries back out of the button column and drop their click handlers, so
    -- a later mount() injects afresh instead of adding a second copy of every entry.
    destroy = function(self)
        local vbox = alive(self.vbox) and self.vbox or nil
        for _, e in ipairs(self.entries or {}) do forgetEntry(e, vbox) end
        self.vbox, self.host = nil, nil
        return true
    end,
}
