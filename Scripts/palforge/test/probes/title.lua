-- palforge/test/probes/title.lua — what the title screen's own widgets are actually made of.
--
-- Closes plan/TODO.md `ui-menubutton-inner-slot` (Probe: F2, marked in
-- native/ui/_widget.lua at leftAlignButtonContent). dumps/cxx has since narrowed the item, and
-- this probe now answers what is LEFT of it rather than what it originally asked:
--
--   * SETTLED by the dump, do not re-derive it here. SetAnchors/SetAlignment exist on
--     UCanvasPanelSlot and on no other slot class in UMG (UMG.hpp:364-365), and both take
--     structs — so leftAlignButtonContent no longer calls them. It calls
--     SetHorizontalAlignment(HAlign_Left) through core/signature instead, which every box,
--     overlay and size slot declares.
--   * STILL OPEN, and what the two questions below are for: does a widget named
--     `HorizontalBox_0` exist in a created button AT ALL — the class declares five widget
--     members and it is not one of them (dumps/cxx/WBP_Title_MenuButton.hpp:11-15) — and if it
--     does, which slot class is it in. A `-> MISSING` line under "created button child" means
--     the name is stale and leftAlignButtonContent should be deleted outright.
--
-- While the native tree is walked it also re-confirms the three names TitleMenu matches by
-- string ("VerticalBox_0", "SizeBox_4", "WBP_Title_MenuButton_ExitGame"): if any of them
-- changed, TitleMenu silently injects nothing today. THE GAME MUST BE SITTING ON THE TITLE
-- SCREEN — main menu, no save loaded, which is exactly where support.player() is legitimately
-- nil. Bind it with: test.bind("F2", function() require("palforge.test.probes.title").run() end).
--
-- Read-only: nothing is added to the viewport, no native widget is reparented, no property
-- is written. The single object this probe brings into being is one orphan WBP_Title_MenuButton
-- that the TODO's own recipe requires — never shown, never parented, dropped on the way out.
local probe   = require("palforge.test.probe")
local support = require("palforge.test.support")

local M = {}

-- Copied from native/ui/_widget.lua M.PATHS and native/ui/title_menu.lua rather than required
-- from them, so a rename over there shows up here as a MISSING line instead of being inherited.
local MENU_BUTTON_CLASS = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C"
local WIDGET_BP_LIB     = "/Script/UMG.Default__WidgetBlueprintLibrary"
local INNER             = "HorizontalBox_0"          -- PATHS.menuButtonInner  (the slot question)
local LABEL             = "Test_Content"             -- PATHS.menuButtonLabel
local CLICK             = "WBP_PalInvisibleButton"   -- PATHS.menuButtonClick
local TITLE_LITERALS    = { "VerticalBox_0", "SizeBox_4", "WBP_Title_MenuButton_ExitGame" }

local MAX_DEPTH = 14   -- the depth cap _widget.findByName itself uses

--=============================================================================
-- inline widget-tree access
--
-- probe.lua has no widget walker, so this is written here with the same pcall discipline:
-- every call answers with a value or nil, never a raise. The walk is the one from
-- dump/dump.lua and _widget.findByName — GetChildrenCount/GetChildAt, plus a nested
-- UserWidget's own .WidgetTree.RootWidget, plus GetContent() when there are no children.
--=============================================================================

local function wname(w)
    local n = probe.name(w)
    if n and n ~= "?" and n ~= "" then return n end
    local f = probe.full(w)
    return f:match("[%.:]([%w_]+)$") or f
end

local function clsFull(w)
    local s; local ok = pcall(function() s = w:GetClass():GetFullName() end)
    return ok and tostring(s) or "?"
end

---GetChildrenCount, or nil when the call raises — that is what identifies a non-panel.
local function childCount(w)
    local n; local ok = pcall(function() n = w:GetChildrenCount() end)
    if ok and type(n) == "number" then return n end
    return nil
end

local function childAt(w, i)
    local c; pcall(function() c = w:GetChildAt(i) end)
    return probe.valid(c) and c or nil
end

---A widget's own WidgetTree root (how a nested UserWidget hides its children).
local function treeRoot(w)
    local r; pcall(function() r = w.WidgetTree.RootWidget end)
    return probe.valid(r) and r or nil
end

local function contentOf(w)
    local c; pcall(function() c = w:GetContent() end)
    return probe.valid(c) and c or nil
end

---The Slot object a widget currently occupies, or nil.
local function slotOf(w)
    local s; pcall(function() s = w.Slot end)
    return probe.valid(s) and s or nil
end

---Depth-first walk. Prints every node as "NODE [depth] name class children=n" (children='-'
---when GetChildrenCount raises), bounded by probe.LIST_LIMIT lines; the total is always
---printed, so nothing is hidden. Returns (hits, total) where hits maps a wanted name to the
---FIRST widget seen with it.
local function walk(root, label, wanted)
    probe.section("tree walk: " .. tostring(label))
    local hits, seen, printed, total = {}, {}, 0, 0
    if not probe.valid(root) then
        probe.line("NODE <no root for %s>", tostring(label))
        return hits, 0
    end

    local function visit(w, depth)
        if not probe.valid(w) or depth > MAX_DEPTH then return end
        local key = probe.full(w)
        -- A tree that loops back would otherwise never end. "?" means GetFullName raised,
        -- and two unrelated widgets must not collide on it, so those are never deduped.
        if key ~= "?" then
            if seen[key] then return end
            seen[key] = true
        end
        total = total + 1

        local n  = childCount(w)
        local nm = wname(w)
        if printed < probe.LIST_LIMIT then
            printed = printed + 1
            probe.line("NODE [%d] %s  %s  children=%s", depth, nm, clsFull(w), n and tostring(n) or "-")
        elseif printed == probe.LIST_LIMIT then
            printed = printed + 1
            probe.line("NODE ... (listing capped at %d; the walk itself continues)", probe.LIST_LIMIT)
        end
        if wanted and wanted[nm] and not hits[nm] then hits[nm] = w end

        local sub = treeRoot(w)
        if sub then visit(sub, depth + 1) end
        for i = 0, (n or 0) - 1 do
            local c = childAt(w, i)
            if c then visit(c, depth + 1) end
        end
        if (n or 0) == 0 then
            local ct = contentOf(w)
            if ct then visit(ct, depth + 1) end
        end
    end

    visit(root, 0)
    probe.line("NODE count=%d in %s", total, tostring(label))
    return hits, total
end

---Print one widget's Slot class the way the TODO asks for it. Returns the class fullname
---string, or nil when there is no slot to read.
local function reportSlot(w, tag)
    if not probe.valid(w) then
        probe.line("VALUE %s inner slot = <no %s widget>", tag, INNER)
        return nil
    end
    local slot = slotOf(w)
    if not slot then
        probe.line("VALUE %s inner slot = absent (%s.Slot is nil or invalid)", tag, INNER)
        return nil
    end
    local cf = clsFull(slot)
    probe.line("VALUE %s inner slot = %s", tag, cf)
    probe.line("VALUE %s inner slot object = %s", tag, probe.full(slot))
    return cf, slot
end

---Ask a slot's own class which alignment setters it declares. SetHorizontalAlignment is the one
---leftAlignButtonContent now calls; SetAnchors/SetAlignment are printed only to confirm on the
---live build what UMG.hpp:364-365 says — that they belong to UCanvasPanelSlot and nothing else.
local function reportSlotSetters(slot, tag)
    if not probe.valid(slot) then return end
    local cls; pcall(function() cls = slot:GetClass() end)
    if not probe.valid(cls) then
        probe.line("PARAM <no class off the %s slot>", tag)
        return
    end
    probe.params(cls, "SetAnchors")
    probe.params(cls, "SetAlignment")
    probe.params(cls, "SetHorizontalAlignment")
    probe.params(cls, "SetPadding")
end

--=============================================================================
-- ui-menubutton-inner-slot
--=============================================================================

local function ui_menubutton_inner_slot()
    probe.begin("ui-menubutton-inner-slot",
        "title screen required; created vs native WBP_Title_MenuButton HorizontalBox_0.Slot")

    --------------------------------------------------------------------------
    -- 1. a FRESHLY CREATED button, exactly the way _widget.create builds one
    --------------------------------------------------------------------------
    probe.section("created WBP_Title_MenuButton")
    local lib = probe.find(WIDGET_BP_LIB)
    local pc  = probe.firstOf("PalPlayerController")
    local cls = probe.find(MENU_BUTTON_CLASS)

    local createdSlotClass, createdSlot
    local btn
    if lib and pc and cls then
        local ok, e = pcall(function() btn = lib:Create(pc, cls, pc) end)
        probe.line("VALUE lib:Create(pc, WBP_Title_MenuButton_C, pc) -> %s",
            ok and probe.describe(btn) or ("call raised: " .. tostring(e)))
    else
        probe.note("create skipped, a prerequisite is absent: lib=%s pc=%s class=%s",
            tostring(lib ~= nil), tostring(pc ~= nil), tostring(cls ~= nil))
    end

    if probe.valid(btn) then
        local hits = walk(btn, "created WBP_Title_MenuButton",
            { [INNER] = true, [LABEL] = true, [CLICK] = true })
        for _, nm in ipairs({ INNER, LABEL, CLICK }) do
            probe.line("VALUE created button child %-24s -> %s", nm,
                hits[nm] and clsFull(hits[nm]) or "MISSING")
        end
        createdSlotClass, createdSlot = reportSlot(hits[INNER], "created")
        reportSlotSetters(createdSlot, "created")
        -- Cleanup: it was never added to anything, so this is belt-and-braces only.
        pcall(function() btn:RemoveFromParent() end)
        btn = nil
    else
        probe.line("VALUE created inner slot = <no button was created>")
        probe.note("a missing WBP_Title_MenuButton_C usually means the title screen is not "
            .. "up: that class is only loaded while the title map is.")
    end

    --------------------------------------------------------------------------
    -- 2. a NATIVE entry, reached through the live title screen
    --------------------------------------------------------------------------
    probe.section("native title screen")
    local base = probe.firstOf("PalUITitleBase")
    local root = base and treeRoot(base) or nil
    probe.line("VALUE PalUITitleBase.WidgetTree.RootWidget -> %s",
        root and probe.describe(root) or "absent")

    local nativeSlotClass, nativeSlot
    local hits = {}
    if root then
        local wanted = { [INNER] = true, [LABEL] = true, [CLICK] = true }
        for _, nm in ipairs(TITLE_LITERALS) do wanted[nm] = true end
        hits = walk(root, "PalUITitleBase", wanted)

        probe.section("literals TitleMenu matches by name")
        for _, nm in ipairs(TITLE_LITERALS) do
            probe.line("VALUE literal %-32s -> %s", nm,
                hits[nm] and (clsFull(hits[nm]) .. "  " .. probe.full(hits[nm])) or "MISSING")
        end
        -- SizeBox_4 is read for its dimensions by title_menu.nativeEntrySize; both come back
        -- as properties there because the getters were recorded as answering nil.
        if hits["SizeBox_4"] then
            probe.read(hits["SizeBox_4"], "WidthOverride")
            probe.read(hits["SizeBox_4"], "HeightOverride")
            probe.callGet(hits["SizeBox_4"], "GetWidthOverride")
            probe.callGet(hits["SizeBox_4"], "GetHeightOverride")
        end
        if hits["VerticalBox_0"] then
            probe.line("VALUE VerticalBox_0 children=%s",
                tostring(childCount(hits["VerticalBox_0"]) or "-"))
        end

        nativeSlotClass, nativeSlot = reportSlot(hits[INNER], "native")
        reportSlotSetters(nativeSlot, "native")
    else
        probe.line("VALUE native inner slot = <no PalUITitleBase on screen>")
        for _, nm in ipairs(TITLE_LITERALS) do
            probe.line("VALUE literal %-32s -> not checked (no title screen)", nm)
        end
    end

    --------------------------------------------------------------------------
    -- 3. the answer
    --------------------------------------------------------------------------
    probe.section("verdict")
    probe.line("VALUE created inner slot class = %s", createdSlotClass or "unknown")
    probe.line("VALUE native  inner slot class = %s", nativeSlotClass or "unknown")
    if createdSlotClass and nativeSlotClass then
        probe.line("VALUE created vs native = %s",
            createdSlotClass == nativeSlotClass and "SAME" or "DIFFERENT")
    end

    if createdSlotClass then
        local isCanvas = createdSlotClass:find("CanvasPanelSlot") ~= nil
        probe.note("HIT: HorizontalBox_0 IS in a created button and its slot is %s. "
            .. "leftAlignButtonContent calls SetHorizontalAlignment(HAlign_Left) through "
            .. "core/signature, so %s Either way the item is settled — record this class in "
            .. "native/ui/_widget.lua and drop the TODO.",
            createdSlotClass,
            isCanvas and ("a CanvasPanelSlot declares no such setter (UMG.hpp:350-374) and "
                    .. "signature REFUSES the call and logs it: the label stays centred, and the "
                    .. "only struct-free way to move it would be SetAutoSize + an offset write, "
                    .. "which is not worth it for a cosmetic. Delete leftAlignButtonContent.")
                or ("this slot class declares it (see the PARAM lines above) and the call lands: "
                    .. "the label really is left-aligned."))
    else
        probe.note("MISS: no created-button slot was read, and WHICH miss it is matters. If the "
            .. "'created button child HorizontalBox_0' line above says MISSING while Test_Content "
            .. "and WBP_PalInvisibleButton resolved, the answer is that the name is STALE — the "
            .. "class declares five widget members and HorizontalBox_0 is not one of them "
            .. "(dumps/cxx/WBP_Title_MenuButton.hpp:11-15) — so delete leftAlignButtonContent and "
            .. "PATHS.menuButtonInner with it. If lib/pc/class all resolved but Create returned "
            .. "nil, WidgetBlueprintLibrary:Create is the blocker and the item stays open. If "
            .. "WBP_Title_MenuButton_C printed 'absent', you are not on the title screen — quit "
            .. "to the main menu and run this again before concluding anything.")
    end

    if root then
        local missing = {}
        for _, nm in ipairs(TITLE_LITERALS) do
            if not hits[nm] then missing[#missing + 1] = nm end
        end
        if #missing == 0 then
            probe.note("HIT: all three TitleMenu literals are present on this game version, so "
                .. "native/ui/title_menu.lua's injection path is intact — no change needed.")
        else
            probe.note("MISS: %s not found in the live title tree. TitleMenu matches those names "
                .. "as string literals (title_menu.lua:50/131/147), so it injects NOTHING today. "
                .. "Pick the replacement out of the NODE lines above and update the literals.",
                table.concat(missing, ", "))
        end
    else
        probe.note("MISS: no PalUITitleBase, so the native half of this item is unanswered. "
            .. "Only the title screen has one — run this from the main menu, not from a save.")
    end

    probe.finish()
end

-- Run every section. Returns the number that ran.
function M.run()
    -- This probe wants the TITLE SCREEN, which is the one screen where support.player() is
    -- SUPPOSED to be nil — so the world guard here asks for the title instead: no title
    -- widget and no PlayerController means there is no UI to read at all, and the honest
    -- answer is one line telling you where to be, not a block full of nils.
    local pawn = support.player()
    local title, pc
    pcall(function() title = FindFirstOf("PalUITitleBase") end)
    pcall(function() pc = FindFirstOf("PalPlayerController") end)

    if not (probe.valid(title) or probe.valid(pc)) then
        probe.line("NOTE probes/title.lua needs the game sitting at the TITLE SCREEN: no "
            .. "PalUITitleBase and no PalPlayerController are live%s. Quit to the main menu "
            .. "(no save loaded) and press the probe key again.",
            pawn and " (a world IS loaded — you are in-game, not at the title)" or "")
        return 0
    end

    if pawn then
        probe.note("a world is loaded (support.player() is not nil), so this is NOT the title "
            .. "screen: expect the native half to report absent. Re-run from the main menu.")
    end

    ui_menubutton_inner_slot()
    return 1
end

return M
