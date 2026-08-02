-- palforge/test/probes/uislot.lua — the SAME question probes/title.lua asks, asked from a
-- LOADED WORLD instead of the title screen.
--
-- IT CLOSED plan/TODO.md `ui-menubutton-inner-slot`, on 2026-07-27, and the answer was negative.
-- One line off a real WBP_Title_MenuButton settled it:
--
--   HorizontalBox_0 IS in a WBP_Title_MenuButton and its slot is a CanvasPanelSlot.
--
-- The name was never stale — it is in the designer tree with its "Is Variable" box unchecked, so
-- it has no class member (dumps/cxx/WBP_Title_MenuButton.hpp:11-15 lists five and this is not one
-- of them) and only a tree walk reaches it. What settled the item is the SLOT: a CanvasPanelSlot
-- is the one slot class in UMG that declares no SetHorizontalAlignment (UMG.hpp:350-374, where
-- the other five do), so core/signature refused the call every time — correctly — and the label
-- has always stayed centred. The alignment a CanvasPanelSlot does declare, SetAlignment, takes an
-- FVector2D, and a struct argument is the shape that faults inside UE4SS marshalling where pcall
-- cannot see it; the struct-free alternative is SetAutoSize plus an offset write, which is a lot
-- of machinery and a new failure mode for a cosmetic nobody asked for.
--
-- So `leftAlignButtonContent` was DELETED from native/ui/_widget.lua rather than left to be
-- refused on every button build, and there is no marker anywhere to go and remove: the evidence
-- lives at native/ui/_widget.lua:755-771 and in plan/TODO.md's Closed list. This probe is now a
-- REGRESSION check — a build that puts HorizontalBox_0 in a box or overlay slot would make the
-- setter available and REOPEN the item, and the verdict below says so in those words.
--
-- WHY A SECOND PROBE INSTEAD OF PRESSING F2. probes/title.lua needs the game sitting on the
-- title screen and there is no way to make that happen from core/autorun, which runs on
-- world.ready and only there. So this one is written for the only place autorun can reach.
--
-- THE ROUTE THAT MAKES THAT POSSIBLE, and it is the whole idea here: a created button was never
-- the only place the answer lives. A UWidgetBlueprintGeneratedClass carries the DESIGNER
-- hierarchy on the class itself —
--
--     dumps/cxx/UMG.hpp:1975  class UWidgetBlueprintGeneratedClass : public UBlueprintGeneratedClass
--                       :1977      class UWidgetTree* WidgetTree;
--
-- — and every widget in that template tree already has its Slot assigned, because that is what
-- the designer laid out. So the answer is a PROPERTY READ on the class, with no widget created,
-- no PlayerController needed and nothing added to anyone's screen. The one thing in-world does
-- not give us for free is the class being loaded: dumps/reflection/03_widgets.txt was taken
-- in-game with menus open and lists WBP_Title_MenuBG_C, WBP_Title_WorldSelectButton_C and
-- WBP_Title_WorldSettings_ListButton_C, but NOT WBP_Title_MenuButton_C. Hence LoadAsset, in the
-- "Package.Object" form core/sound/native.lua:53-65 proved for /Game assets, before the read.
--
-- READ-ONLY, with one deliberate exception. Sections 1, 2 and 4 call nothing: StaticFindObject /
-- LoadAsset / GetClass / GetFName / GetFullName / GetChildrenCount / GetChildAt / GetContent and
-- property reads, which is the same set probes/title.lua walks with. Section 3 creates ONE orphan
-- WBP_Title_MenuButton exactly as _widget.menuButton would, never shows it and never parents it —
-- and it runs LAST, deliberately, so the class-tree answer is already in the log before anything
-- is constructed.
--
-- No UFunction is called with an argument. The one declaration that matters is read through
-- core/signature's describe(), which walks the live parameter list and logs it WITHOUT calling.
--
-- STILL A PROBE, NOT A TEST. It prints what the button's tree IS and stops; it asserts nothing.
-- The game-required MEASUREMENTS are moving to declared hooks under Scripts/palforge/test/hooks/,
-- named after their plan/TODO.md item id and run by name (`pf_hook <id>`); nothing here duplicates
-- one today, because this file's remaining question is a closed item's regression rather than an
-- open item's measurement.
local probe   = require("palforge.test.probe")
local support = require("palforge.test.support")
local sig     = require("palforge.core.signature")

local M = {}

-- Copied from native/ui/_widget.lua M.PATHS rather than required from it, exactly as
-- probes/title.lua does: a rename over there must show up here as a MISSING line instead of
-- being silently inherited.
local MENU_BUTTON_CLASS = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C"
local MENU_BUTTON_ASSET = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton"
local WIDGET_BP_LIB     = "/Script/UMG.Default__WidgetBlueprintLibrary"
local INNER             = "HorizontalBox_0"          -- PATHS.menuButtonInner  (the slot question)
local LABEL             = "Test_Content"             -- PATHS.menuButtonLabel
local CLICK             = "WBP_PalInvisibleButton"   -- PATHS.menuButtonClick

local MAX_DEPTH   = 14    -- the depth cap _widget.findByName itself uses
local MAX_BUTTONS = 12    -- live CommonButtonBase instances sampled in section 4
local MAX_BOXES   = 4000  -- live HorizontalBox instances scanned for the histogram

--=============================================================================
-- inline widget-tree access (the same pcall discipline probes/title.lua uses:
-- every call answers with a value or nil, never a raise)
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

local function clsName(w)
    local s; local ok = pcall(function() s = w:GetClass():GetFName():ToString() end)
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

---The slot CLASS NAME a widget sits in ("HorizontalBoxSlot", "CanvasPanelSlot", ...), or nil.
local function slotClassOf(w)
    local s = slotOf(w)
    if not s then return nil end
    return clsName(s)
end

---The template WidgetTree root a UWidgetBlueprintGeneratedClass carries (UMG.hpp:1977). This is
---the DESIGNER hierarchy — every widget the blueprint lays out, variable or not, with its Slot
---already assigned. Reads the property; nothing is constructed and nothing is called.
local function classTreeRoot(cls)
    if not probe.valid(cls) then return nil end
    local tree; pcall(function() tree = cls.WidgetTree end)
    if not probe.valid(tree) then return nil end
    local root; pcall(function() root = tree.RootWidget end)
    return probe.valid(root) and root or nil
end

---Depth-first walk, printing each node with the slot class it occupies — which is the line this
---whole probe exists for. Returns (hits, total); hits maps a wanted name to the first match.
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
        -- A tree that loops back would otherwise never end. "?" means GetFullName raised, and
        -- two unrelated widgets must not collide on it, so those are never deduped.
        if key ~= "?" then
            if seen[key] then return end
            seen[key] = true
        end
        total = total + 1

        local n  = childCount(w)
        local nm = wname(w)
        if printed < probe.LIST_LIMIT then
            printed = printed + 1
            probe.line("NODE [%d] %s  %s  children=%s  slot=%s", depth, nm, clsFull(w),
                n and tostring(n) or "-", slotClassOf(w) or "none")
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

---Print one widget's Slot class, and then ask that slot's class whether it declares the call the
---deleted leftAlignButtonContent used to make. An "absent" answer here is the POSITIVE evidence
---this item closed on, not a gap. sig.describe walks the LIVE parameter list and logs it; it
---calls nothing, which is the only way to ask this question safely (a struct argument on an
---unread declaration faults where pcall cannot see it).
---Returns the slot class name, or nil when there is no slot to read.
local function reportSlot(w, tag)
    if not probe.valid(w) then
        probe.line("VALUE %s %s slot = <no %s widget>", tag, INNER, INNER)
        return nil
    end
    local slot = slotOf(w)
    if not slot then
        probe.line("VALUE %s %s slot = absent (.Slot is nil or invalid)", tag, INNER)
        return nil
    end
    probe.line("VALUE %s %s slot = %s", tag, INNER, clsFull(slot))
    probe.line("VALUE %s %s slot object = %s", tag, INNER, probe.full(slot))

    -- All three go through sig.describe and NOT probe.params, deliberately. Both read a
    -- declaration without calling, but they find the function differently: probe.params leads
    -- with GetFunctionByName, which is not in UE4SS's documented Lua surface and answers
    -- "function absent" on a build that simply does not have it — a false negative on exactly
    -- the question being asked. sig.find leads with ForEachFunction on the class and walks the
    -- super chain, which is the route core/signature is built on and the one that has answered
    -- on this build every run. SetAnchors and SetAlignment are asked only to confirm live what
    -- UMG.hpp:364-365 says — they belong to UCanvasPanelSlot and to no other slot class — and
    -- neither is called by anything in this tree any more.
    for _, fnName in ipairs({ "SetHorizontalAlignment", "SetAnchors", "SetAlignment" }) do
        probe.line("VALUE %s slot %s -> %s", tag, fnName, tostring(sig.describe(slot, fnName)))
    end
    return clsName(slot)
end

--=============================================================================
-- 1. get the class loaded, in a world where the title map is not
--=============================================================================

local function resolveClass()
    probe.section("WBP_Title_MenuButton_C, from a loaded world")

    local cls
    pcall(function() cls = StaticFindObject(MENU_BUTTON_CLASS) end)
    probe.line("CLASS StaticFindObject(%s) -> %s", MENU_BUTTON_CLASS,
        probe.valid(cls) and probe.full(cls) or "absent")
    if probe.valid(cls) then
        probe.note("the class was ALREADY loaded in this world — no LoadAsset was needed.")
        return cls
    end

    if type(LoadAsset) ~= "function" then
        probe.note("LoadAsset is not available this session, so an unloaded title class cannot "
            .. "be brought in. This item stays open; run probes/title.lua from the main menu.")
        return nil
    end

    -- Both spellings, cheapest first. "Package.Object" is the form proven for /Game assets in
    -- core/sound/native.lua; for a widget blueprint the OBJECT is the asset (…_MenuButton) and
    -- the CLASS is the generated one (…_MenuButton_C), and which one LoadAsset accepts on this
    -- build has never been measured — so both are tried and both results are printed.
    for _, path in ipairs({ MENU_BUTTON_ASSET, MENU_BUTTON_CLASS }) do
        local a
        local ok = pcall(function() a = LoadAsset(path) end)
        probe.line("VALUE LoadAsset(%s) -> ok=%s returned=%s", path, tostring(ok), probe.describe(a))
        cls = nil
        pcall(function() cls = StaticFindObject(MENU_BUTTON_CLASS) end)
        if probe.valid(cls) then
            probe.line("CLASS after LoadAsset, StaticFindObject(%s) -> %s",
                MENU_BUTTON_CLASS, probe.full(cls))
            return cls
        end
    end

    probe.line("CLASS WBP_Title_MenuButton_C -> still absent after both LoadAsset forms")
    return nil
end

--=============================================================================
-- 4. what Palworld's OWN in-world UI does with a HorizontalBox
--
-- Corroboration, not the answer. Even if the title class cannot be loaded, the in-game menus
-- are full of CommonButtonBase-derived buttons and of HorizontalBoxes, and the histogram of
-- which slot class those boxes actually occupy is what decides whether
-- SetHorizontalAlignment(HAlign_Left) is a call that lands on this game's UI at all.
--=============================================================================

-- Two in-game widget classes that DECLARE a member called HorizontalBox_0, which is the exact
-- name and the exact shape the title button is being asked about
-- (dumps/cxx/WBP_MainMenu_Pal_WorkIconText.hpp:9, dumps/cxx/WBP_MainMenu_Pal_FoodAmount.hpp:7).
local INNER_OWNERS = { "WBP_MainMenu_Pal_WorkIconText_C", "WBP_MainMenu_Pal_FoodAmount_C" }

local function inWorldCorroboration()
    probe.section("in-world corroboration: live HorizontalBox slots")

    local boxes
    pcall(function() boxes = FindAllOf("HorizontalBox") end)
    if type(boxes) ~= "table" then
        probe.line("LIVE HorizontalBox -> none (FindAllOf answered nothing)")
    else
        local hist, order, scanned, examples = {}, {}, 0, 0
        for _, b in ipairs(boxes) do
            if scanned >= MAX_BOXES then break end
            scanned = scanned + 1
            local sc = slotClassOf(b) or "none"
            if hist[sc] == nil then hist[sc] = 0; order[#order + 1] = sc end
            hist[sc] = hist[sc] + 1
            -- A handful of named examples from BUTTON widgets, which is the population the
            -- title button belongs to.
            local full = probe.full(b)
            if examples < 20 and full:find("Button") then
                examples = examples + 1
                probe.line("VALUE button-owned HorizontalBox %s  slot=%s  %s", wname(b), sc, full)
            end
        end
        probe.line("LIVE HorizontalBox -> %d live, %d scanned", #boxes, scanned)
        table.sort(order)
        for _, sc in ipairs(order) do
            probe.line("VALUE slot histogram  %-24s %d", sc, hist[sc])
        end
    end

    probe.section("in-world corroboration: classes that DECLARE HorizontalBox_0")
    for _, className in ipairs(INNER_OWNERS) do
        local o = probe.firstOf(className)
        if o then
            local box; pcall(function() box = o[INNER] end)
            probe.line("VALUE %s.%s -> %s  slot=%s", className, INNER, probe.describe(box),
                (probe.valid(box) and (slotClassOf(box) or "none")) or "-")
        end
    end

    probe.section("in-world corroboration: live CommonButtonBase buttons")
    local btns
    pcall(function() btns = FindAllOf("CommonButtonBase") end)
    if type(btns) ~= "table" then
        probe.line("LIVE CommonButtonBase -> none")
        return
    end
    probe.line("LIVE CommonButtonBase -> %d live, showing up to %d", #btns, MAX_BUTTONS)
    local shown = 0
    for _, b in ipairs(btns) do
        if shown >= MAX_BUTTONS then break end
        shown = shown + 1
        probe.line("VALUE button %-40s own slot=%s", clsName(b), slotClassOf(b) or "none")
        -- The button's OWN class template tree, three levels deep: does a Palworld button
        -- blueprint put a HorizontalBox inside itself, and in what slot when it does. This is
        -- the same read section 2 makes of the title button, on a class that is definitely
        -- resident — so if the title class will not load, these lines are what is left.
        local bcls; pcall(function() bcls = b:GetClass() end)
        local root = classTreeRoot(bcls)
        if root then
            local found
            local function scan(w, d)
                if found or not probe.valid(w) or d > 3 then return end
                if clsName(w) == "HorizontalBox" then found = w; return end
                for i = 0, (childCount(w) or 0) - 1 do scan(childAt(w, i), d + 1) end
            end
            scan(root, 0)
            probe.line("VALUE   its class tree root=%s  first HorizontalBox=%s slot=%s",
                wname(root), found and wname(found) or "none",
                found and (slotClassOf(found) or "none") or "-")
        end
    end
end

--=============================================================================
-- the item
--=============================================================================

local function ui_menubutton_inner_slot()
    probe.begin("ui-menubutton-inner-slot",
        "CLOSED 2026-07-27, negatively — this block is now a REGRESSION check, not a question. "
        .. "The expected answer is 'CanvasPanelSlot' with SetHorizontalAlignment absent; anything "
        .. "else REOPENS the item. Asked from a LOADED WORLD: WBP_Title_MenuButton_C's template "
        .. "WidgetTree, then a created instance, then what the in-game UI does with a "
        .. "HorizontalBox.")

    local cls = resolveClass()

    --------------------------------------------------------------------------
    -- 2. the class's OWN template tree: the answer, with nothing constructed
    --------------------------------------------------------------------------
    probe.section("template WidgetTree on the generated class (UMG.hpp:1977)")
    local templateSlot
    local templateHits = {}
    local root = classTreeRoot(cls)
    probe.line("VALUE WBP_Title_MenuButton_C.WidgetTree.RootWidget -> %s",
        root and probe.describe(root) or "absent")
    if root then
        templateHits = walk(root, "WBP_Title_MenuButton_C template",
            { [INNER] = true, [LABEL] = true, [CLICK] = true })
        for _, nm in ipairs({ INNER, LABEL, CLICK }) do
            probe.line("VALUE template child %-24s -> %s", nm,
                templateHits[nm] and clsFull(templateHits[nm]) or "MISSING")
        end
        templateSlot = reportSlot(templateHits[INNER], "template")
    elseif cls then
        probe.note("the class resolved but its WidgetTree property did not read. That is the "
            .. "one thing this route depends on, so fall back to section 3 (the created "
            .. "instance) for the answer.")
    end

    --------------------------------------------------------------------------
    -- 3. a CREATED instance, exactly what _widget.menuButton builds
    --
    -- Last, on purpose: constructing a title-screen widget in a loaded world is the only step
    -- here that is not a pure read, so everything above is already written when it runs.
    --------------------------------------------------------------------------
    probe.section("created WBP_Title_MenuButton (orphan, never shown)")
    local createdSlot
    local createdHits = {}
    local lib = probe.find(WIDGET_BP_LIB)
    local pc  = probe.firstOf("PalPlayerController")
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
        createdHits = walk(btn, "created WBP_Title_MenuButton",
            { [INNER] = true, [LABEL] = true, [CLICK] = true })
        for _, nm in ipairs({ INNER, LABEL, CLICK }) do
            probe.line("VALUE created button child %-24s -> %s", nm,
                createdHits[nm] and clsFull(createdHits[nm]) or "MISSING")
        end
        createdSlot = reportSlot(createdHits[INNER], "created")
        -- It was never added to anything, so this is belt-and-braces only.
        pcall(function() btn:RemoveFromParent() end)
        btn = nil
    end

    --------------------------------------------------------------------------
    -- 4. corroboration from the UI that IS on screen
    --------------------------------------------------------------------------
    inWorldCorroboration()

    --------------------------------------------------------------------------
    -- the answer
    --------------------------------------------------------------------------
    probe.section("verdict")
    local sawInner = (templateHits[INNER] ~= nil) or (createdHits[INNER] ~= nil)
    local slotClass = templateSlot or createdSlot
    probe.line("VALUE template %s slot class = %s", INNER, templateSlot or "unknown")
    probe.line("VALUE created  %s slot class = %s", INNER, createdSlot or "unknown")

    if slotClass then
        local isCanvas = slotClass:find("CanvasPanelSlot") ~= nil
        if isCanvas then
            probe.note("AS RECORDED: %s IS in a WBP_Title_MenuButton and its slot is a %s — the "
                .. "same answer this probe produced on 2026-07-27, which is what closed the item. "
                .. "A CanvasPanelSlot declares no SetHorizontalAlignment (UMG.hpp:350-374, where "
                .. "the other five slot classes do), so the sig.describe line above reading absent "
                .. "IS the evidence, not a gap: the label is centred and always was. Nothing to "
                .. "do, and nothing to delete — leftAlignButtonContent is already gone from "
                .. "native/ui/_widget.lua, and the reasoning is written out at :739. The two "
                .. "setters this slot does declare both take an FVector2D, and a struct argument "
                .. "is the shape that faults inside UE4SS marshalling.", INNER, slotClass)
        else
            probe.note("REOPEN ui-menubutton-inner-slot: %s sits in a %s, NOT the CanvasPanelSlot "
                .. "this item closed on. If the sig.describe line above shows that class declaring "
                .. "SetHorizontalAlignment, a left-aligned label became possible on this build and "
                .. "the deleted leftAlignButtonContent (native/ui/_widget.lua:755) is worth "
                .. "reinstating. Paste this whole block into plan/TODO.md — it contradicts a "
                .. "measurement.", INNER, slotClass)
        end
    elseif sawInner then
        probe.note("REOPEN, differently: a widget named %s was found but it occupies NO slot, "
            .. "which happens when it is the TREE ROOT — a root widget has no parent to slot into. "
            .. "That is not what was measured on 2026-07-27 (a CanvasPanelSlot was read, twice, "
            .. "from the template tree and from a created instance), so either the button's tree "
            .. "changed or this walk reached a different widget. Either way there is no slot to "
            .. "align and nothing to reinstate; paste the NODE lines back.", INNER)
    elseif cls then
        probe.note("REOPEN: WBP_Title_MenuButton_C resolved and %s is NOT in it. It was there on "
            .. "2026-07-27 — in the designer tree, with no class member behind it, which is why "
            .. "the class declaring only five widget members "
            .. "(dumps/cxx/WBP_Title_MenuButton.hpp:11-15) never contradicted it. A tree walk that "
            .. "now agrees with the member list means the name went stale in a patch, and "
            .. "PATHS.menuButtonInner (native/ui/_widget.lua:92) is then dead and worth dropping. "
            .. "Check the 'template child' lines first: if %s and %s resolved while %s did not, "
            .. "that is the finding; if all three are MISSING the walk itself failed and this "
            .. "concludes nothing.", INNER, LABEL, CLICK, INNER)
    else
        probe.note("NO ANSWER: WBP_Title_MenuButton_C could not be loaded from a world, so neither "
            .. "the template tree nor a created instance could be read — this run measured "
            .. "nothing, and it neither confirms nor contradicts the close. The fallback is "
            .. "probes/title.lua from the main menu (pf_title), which needs the title screen. Read "
            .. "the histogram in section 4 meanwhile: it says what slot class Palworld's own UI "
            .. "puts a HorizontalBox in, which is the same population the title button belongs to.")
    end

    probe.finish()
end

---Run the probe. Returns 1 when it ran, 0 when it said what it needed and stopped.
function M.run()
    -- The opposite guard to probes/title.lua: THIS one wants a loaded world, because that is
    -- the only place core/autorun can reach. With no world there is no PlayerController to
    -- create with and no in-game UI to corroborate against, and every line below would be nil.
    if not support.player() then
        probe.line("NOTE probes/uislot.lua needs a LOADED SAVE: no PalPlayerCharacter is live. "
            .. "At the title screen run pf_title instead — probes/title.lua asks the same "
            .. "question of the real title menu.")
        return 0
    end
    ui_menubutton_inner_slot()
    return 1
end

return M
