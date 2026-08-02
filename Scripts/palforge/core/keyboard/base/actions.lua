-- palforge/core/keyboard/base/actions.lua — THE NAMES. Palworld's own input-action names and
-- Palworld's own FKey spellings, taken out of the game's data rather than invented.
--
-- WHY A WHOLE FILE FOR A LIST OF STRINGS. keymap.lua needs to look INTO a container it may not
-- be able to walk. UE4SS's TMap binding does expose ForEach (ue4ss/Docs/lua-api/classes/tmap.md
-- on this install, and RE-UE4SS's LuaTMap.cpp implements it), but ForEach is not the only way a
-- read can come back empty, and a map you cannot walk you can still LOOK UP — `Find(key)` and
-- `Contains(key)` are the other two thirds of that binding. Both need the key, and the key of
-- Palworld's action maps is an FName action name. So the question "what has the game got" turns
-- into "what are the action names", and that is answerable from shipped data.
--
-- TWO LISTS, TWO DIFFERENT JOBS:
--
--   M.UI_ACTIONS   244 names, the ROW NAMES of DT_UIInputAction
--                  (dumps/catalog/datatables/DT_UIInputAction.json:1, live at
--                   /Game/Pal/DataTable/UI/DT_UIInputAction.DT_UIInputAction —
--                   dumps/reflection/01_datatables.txt:3391 printed it from a real session).
--                  These are the keys of FPalKeyConfigSettings.MouseAndKeyboardUIInputMappings
--                  (Pal.hpp:3978) and of some of MouseAndKeyboardActionMappings (:3974).
--
--   M.KEY_NAMES    117 names, the ROW NAMES of DT_PalRichTextControlKeyIcon
--                  (dumps/catalog/datatables/DT_PalRichTextControlKeyIcon.json:1). These are
--                  UNREAL FKey names — "SpaceBar", "NumPadZero", "BackSpace", "Hyphen" — which
--                  makes them an INDEPENDENT cross-check on keymap.M.FKEY's right-hand column,
--                  written by the game rather than by us. test/cases/ui.lua asserts against it.
--
-- ⚠️ WHAT THE UI LIST DOES NOT COVER, and this is the honest limit. DT_UIInputAction is the UI
-- input table: it has OpenBuildMenu, OpenWorldMap, Interact_1, UICancel. It has NO "Jump", no
-- "Attack", no "Sprint" — the gameplay action and axis names are not in it and are not in any
-- DataTable in the 390-table catalog. Those names come from the OTHER live source keymap.lua
-- reads, UInputSettings.ActionMappings/AxisMappings (Engine.hpp:13683-13684), which is a TArray
-- and therefore genuinely enumerable. The two halves compose: the project arrays supply the
-- gameplay NAMES, this table supplies the UI ones, and the player's config maps are then looked
-- up by every name either half produced. Whatever neither half names cannot be found, and
-- keymap.lua's per-container record says so in numbers (`found` against the map's own `#`)
-- rather than letting it pass as "nothing there".
--
-- LIVE FIRST, SHIPPED SECOND. A live table cannot go stale and picks up anything a patch or a
-- PalSchema pack added; the baked list below is what answers when the table is not loaded. The
-- record M.names() returns says which one answered, because "244 names from the shipped copy"
-- and "244 names read out of the running game" are different evidence.
--
--   local actions = require("palforge.core.keyboard.base.actions")
--   local names, rec = actions.names()      -- names[i] = "OpenWorldMap"; rec.source = "live"
local log = require("palforge.utils.log").scope("keymap")

local M = {}

---The DataTable the UI action names live in, and where to find it.
---The name is what UE4SS's FindObject("DataTable", name) wants; the path is the fallback and is
---MEASURED — dumps/reflection/01_datatables.txt:3391 printed exactly this GetFullName() in a
---live session, so it is not a guessed directory.
M.TABLE = "DT_UIInputAction"
M.PATH  = "/Game/Pal/DataTable/UI/DT_UIInputAction.DT_UIInputAction"

---The 244 row names of DT_UIInputAction, as shipped. Generated from
---dumps/catalog/datatables/DT_UIInputAction.json (count = 244); kept in the source because
---tools/deploy.sh copies Scripts/ and nothing else, so dumps/ does not exist at runtime and a
---"fallback that reads the JSON" would be a fallback that never fires.
M.UI_ACTIONS = {
    "A_ForHelp", "ArenaRule_Default", "ArenaRule_Save", "ArenaSolo_Cancel", "ArenaSpectate_Exit",
    "ArenaSpectate_NextPlayer", "ArenaSpectate_SpectateFreely", "ArenaSpectate_TopDown",
    "Arena_PalDetail_Toggle", "Arena_Rule", "Arena_Spec_Request", "BuildMenuTabNext", "BuildMenuTabPrev",
    "BuildObject", "BuildObjectChangeMode", "BuildObjectChangeReplaceMode", "BuildObjectChangeSnapMode",
    "BuildObjectContinuous", "BuildObjectList_PaintingMode", "BuildRotateLeft", "BuildRotateRight",
    "CancelBuilding_01", "CancelBuilding_02", "CancelBuilding_03", "CancelDismantling_01",
    "CancelDismantling_02", "CancelDismantling_03", "CancelDismantling_FromRadialMenu",
    "CancelDismantling_FromRadialMenu_01", "CancelPainting_01", "CancelPainting_02", "CancelPainting_03",
    "CancelPainting_FromRadialMenu", "CancelPainting_FromRadialMenu_0", "CancelSalvage", "ChangeBuildMode",
    "ChangeProductNum_Down", "ChangeProductNum_Up", "ChangeWeaponBulletNext", "ChangeWeaponBulletPrev",
    "CharacterCreation_Decide", "CharacterCreation_Randomize", "CharacterCreation_ToggleEquip",
    "CharacterCreation_ZoomIn_Mouse", "CharacterCreation_ZoomOut_Mouse", "CharacterMakeSampleVoice",
    "CharacterMakeShortcutConfirm", "ChatCategoryChange", "ChatOpen", "CloseBuildObjectList_General",
    "CloseBuilding", "CommonClick", "Condense_OnePageSelect", "Condense_OnePageUnselect",
    "ConstructionMenuCategoryLeft", "ConstructionMenuCategoryRight", "ConstructionRadialMenuDecide",
    "ConstructionRadialMenuTabNext", "ConstructionRadialMenuTabNext_Mouse",
    "ConstructionRadialMenuTabPrev", "ConstructionRadialMenuTabPrev_Mouse", "ControllerInvokeAction",
    "CraftMenuNextCategory", "CraftMenuPrevCategory", "CutsceneSkip", "D_ForHelp", "DialogShortcutConfirm",
    "DimensionLocker_SendAll", "DirectAttackOrder_ForTIPS", "DismantleObject", "DismantleObjectContinuous",
    "EquipmentCancel", "EquipmentRemove", "EscMenuToPlayerList", "EscMenuToServerInfo",
    "Expedition_ChangeMission", "Expedition_StartMissionShortcut", "FIxedAssignMnage_Sort_GamePad",
    "FavoriteBuildObject", "FishingSuccessCutSceneSkip", "FixedAssignManage_RemoveShortcut",
    "ForceCloseBuilding", "ForceCloseDismantling", "ForceCloseDismantling02", "ForceClosePainting",
    "ForceClosePainting02", "GlobalPalStorage_RemoveData", "GlobalPalStorage_StartRemoveData",
    "ImteStorageFastAllGet", "Interact_1", "Interact_2", "Interact_3", "Interact_4",
    "InventoryCancelStatusEdit", "InventoryConfirmStatusEdit", "InventoryEditStatusPoint",
    "InventoryTabNext", "InventoryTabPrev", "InventoryToggleQuickStack", "Inventory_PadQuickStack",
    "ItemFilter", "ItemList_HalfLift_Pad", "ItemList_UseItem_ForDisplay", "ItemList_UseItem_Hold",
    "ItemList_UseItem_Pad", "ItemShopSelectSellSlot_Pad", "ItemShopSellConfirm", "ItemShopSteal",
    "ItemStorageLeftFocus", "ItemStorageRefill", "ItemStorageRightFocus", "ItemStorageSort",
    "KeyConfigBack", "KeyConfig_PressPadA", "MAP_FILTER", "MAP_MARKER", "MAP_ZOOM", "MainMenuTabNext",
    "MainMenuTabPrev", "ManageStorage", "Map_Dismantal_Camp", "Map_ShowQuest", "ModSettings_Cancel",
    "ModSettings_Cancel_ForKeyGuideIcon", "ModSettings_Confirm", "ModSettings_OpenSteamWorkshop",
    "MoveSelectPaintColorDown", "MoveSelectPaintColorLeft", "MoveSelectPaintColorRight",
    "MoveSelectPaintColorUp", "OneStrokeGame_Reset", "OpenBuildMenu", "OpenCHaracterMenu_Another",
    "OpenCharacterMenu", "OpenChestSetting", "OpenConstructionRadialMenu",
    "OpenDismantling_FromRadialMenu", "OpenEquipSkillList", "OpenPainting_FromRadialMenu", "OpenPalStatus",
    "OpenTechnologyMenu", "OpenWorldMap", "PaintEditColor", "PaintObject", "PaintRemoveColor",
    "PalBoxCursorShortcutNext", "PalBoxCursorShortcutPrev", "PalBoxDetailStatus", "PalBoxNextBox",
    "PalBoxPrevBox", "PalBoxSendSlot", "PalDexRandomCry", "PalLoadoutRightClick_DisplayOnly",
    "PalMenu_Toggle_FavoritePal", "PalShopBoxPageNext", "PalShopBoxPagePrev", "PalShopSelectSellSlot_Pad",
    "PalShopSellConfirm", "PalShopTabNext", "PalShopTabPrev", "PalStatusToParameterDetail",
    "PalStatusToSkillDetail", "PalStatus_RemoveWaza", "PalStorageFavoriteShortcut", "PalboxSortShortcut",
    "PaldeckFiltering_Confirm", "PaldeckFiltering_Reset", "Paldeck_Filtering",
    "PaldexChangeDistributionTimeType", "PaldexDistributionMapZoom", "PaldexToDistribution",
    "PaldexToModel", "Paldex_Sort", "Palpedia_ChangeMap", "PickColor", "QUEST_TRACKING", "Quest_Check",
    "Quest_NextTab", "Quest_PrevTab", "Quest_ShowMap", "QuickChangeWeaponNext_Gamepad",
    "QuickChangeWeaponPrev_GamePad", "REPAIRBENCH_REPAIR", "RadialMenuCancel", "RadialMenuDecide",
    "RadialTab_1", "RadialTab_2", "RadialTab_3", "RadialTab_4", "RadialTab_5", "RadialTab_6",
    "RaidBoss_QuickReturnToBase", "RecipeSelecNumtCancel", "RecipeSelectNum_Decide",
    "RecipeSelectNum_Decrease", "RecipeSelectNum_Decrease10", "RecipeSelectNum_Down",
    "RecipeSelectNum_Increase", "RecipeSelectNum_Increase10", "RecipeSelectNum_MaxNum",
    "RecipeSelectNum_Up", "RecipeStartProduce", "RelicMenu_QuickConfirm", "RepairBench_RepairAll",
    "Research_ShowAllBuff", "ReturnBuildMenuInPainting", "S_ForHelp", "SendChat", "SettingBack",
    "SettingLeft", "SettingRight", "SettingSetToDefault", "SettingTabNext", "SettingTabPrev",
    "SpectateBeginAdminModeShortcut", "SpectateDecreaseMoveSpeed", "SpectateEnd", "SpectateFreely",
    "SpectateHideHud", "SpectateIncreaseMoveSpeed", "SpectateMoveDown", "SpectateMoveUp",
    "SpectateNextPlayer", "SpectateOpenMenu", "SpectatePrevPlayer", "StatusPalDrop",
    "SuitabilitySeting_ToggleDetail", "TalkDecide_01", "TalkDecide_02", "TalkSkip", "TechnologyFilter",
    "TechnologyNextCategory", "TechnologyPrevCategory", "ToggleBoothPrivateLock", "ToggleCanTransportOut",
    "TogglePalDetailSkillInfo", "UICancel", "UICancel_GamepadOnly", "UIEscape", "UITab", "W_ForHelp",
    "WorldMapFocusPlayer", "WorldMap_ChangeMap", "WorldMap_FocusToBaseCamp",
}

---The 117 row names of DT_PalRichTextControlKeyIcon — Palworld's own spelling of every keyboard
---key it can draw an icon for, i.e. UNREAL FKey names. Used as a cross-check on keymap.M.FKEY.
---
---⚠️ IT IS A KEYBOARD table, so it is silent about the mouse (there is no "LeftMouseButton" row)
---and about anything Palworld never draws. An FKey name that is NOT here is therefore NOT wrong;
---the cross-check can only ever assert about the names that ARE here, and it says so.
M.KEY_NAMES = {
    "A", "A_AccentGrave", "Add", "Ampersand", "Apostrophe", "Asterisk", "B", "BackSpace", "Backslash", "C",
    "C_Cedille", "CapsLock", "Caret", "Colon", "Comma", "D", "Decimal", "Delete", "Divide", "Dollar",
    "Down", "E", "E_AccentAigu", "E_AccentGrave", "Eight", "Empty", "End", "Enter", "Equals", "Escape",
    "Exclamation", "F", "F1", "F10", "F11", "F12", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "Five",
    "Four", "G", "H", "Home", "Hyphen", "I", "Insert", "J", "K", "L", "Left", "LeftAlt", "LeftBracket",
    "LeftCommand", "LeftControl", "LeftParantheses", "LeftShift", "M", "Multiply", "N", "Nine", "NumLock",
    "NumPadEight", "NumPadFive", "NumPadFour", "NumPadNine", "NumPadOne", "NumPadSeven", "NumPadSix",
    "NumPadThree", "NumPadTwo", "NumPadZero", "O", "One", "P", "PageDown", "PageUp", "Pause", "Period",
    "Q", "Quote", "R", "Right", "RightAlt", "RightBracket", "RightCommand", "RightControl",
    "RightParantheses", "RightShift", "S", "ScrollLock", "Section", "Semicolon", "Seven", "Six", "Slash",
    "SpaceBar", "Subtract", "T", "Tab", "Three", "Tilde", "Two", "U", "Underscore", "Up", "V", "W", "X",
    "Y", "Z", "Zero",
}

--=============================================================================
-- READING THE LIVE TABLE
--
-- ⚠️ THE ROW ACCESSORS ARE NOT UFUNCTIONS AND THEY ARE NOT ON UDataTable. core/icons.lua:284-299
-- paid for this discovery: dumps/cxx/Engine.hpp declares UDataTable with five properties and ZERO
-- functions, so every reflection sweep misses them and every accessor guessed from the C++ side
-- is called on an object that does not have it. UE4SS binds its own
-- (ue4ss/Docs/lua-api/classes/udatatable.md, shipped in this install):
--
--     dt:GetRowNames()  -> { "UIEscape", ... }     a plain 1-indexed Lua table of strings
--     dt:FindRow(string RowName) / GetRowMap() / GetAllRows() / ForEachRow(fn)
--
-- Only GetRowNames is used here. We want the NAMES and nothing else: not one row struct crosses
-- into Lua, which sidesteps the TSoftObjectPtr wall core/icons.lua:316-341 ran into and makes
-- this the cheapest possible read of the table.
--
-- ⚠️ NO FindAllOf SWEEP. test/tools/catalog.lua:6-10 records the FindAllOf("DataTable") sweep as
-- crash-prone — it touches every loaded table and a stale pointer there raises an access
-- violation Lua's pcall cannot catch — and core/icons.lua:186-195 keeps it out of ordinary
-- helpers for exactly that reason. This is an ordinary helper. Targeted lookup or nothing.
--=============================================================================

-- Flatten whatever GetRowNames handed back into a list of plain strings.
--
-- ⚠️ UNWRAP FIRST. core/icons.lua:362-375 records the failure this prevents: a UE4SS array can
-- deliver its elements wrapped in RemoteUnrealParam, the real value sits behind :get(), and
-- without the unwrap the list comes out the right LENGTH with every entry blank. GetRowNames is
-- documented to return a plain Lua table, but "documented" and "what this build does" have
-- already diverged once in this file's neighbourhood, so both shapes are accepted.
local function toNames(v)
    local out = {}
    if v == nil then return out end
    local function push(x)
        if type(x) == "userdata" or type(x) == "table" then
            local inner
            for _, get in ipairs({ function() return x:get() end,
                                   function() return x:Get() end,
                                   function() return x:ToString() end }) do
                local ok, r = pcall(get)
                if ok and r ~= nil and r ~= x then inner = r; break end
            end
            x = inner
        end
        if type(x) == "string" and #x > 0 and x ~= "None" then out[#out + 1] = x end
    end
    if type(v) == "table" then
        for i = 1, #v do push(v[i]) end
        return out
    end
    -- A userdata container: try the two shapes UE4SS uses, in the order core/icons.lua does.
    if pcall(function() v:ForEach(function(_, e) push(e) end) end) and #out > 0 then return out end
    local n; pcall(function() n = #v end)
    if type(n) == "number" and n > 0 then
        for i = 1, n do local e; pcall(function() e = v[i] end); push(e) end
    end
    return out
end

-- The live UDataTable, or nil. Targeted only: FindObject by class+name first (the route
-- utils/items/init.lua's technologyRows() uses), then the measured package path.
local function liveTable()
    local dt
    if type(FindObject) == "function" then
        pcall(function() dt = FindObject("DataTable", M.TABLE) end)
    end
    local function usable(o)
        if o == nil then return false end
        local ok, v = pcall(function() if o.IsValid then return o:IsValid() end return true end)
        return ok and v ~= false
    end
    if usable(dt) then return dt, "FindObject" end
    dt = nil
    if type(StaticFindObject) == "function" then
        pcall(function() dt = StaticFindObject(M.PATH) end)
    end
    if usable(dt) then return dt, "StaticFindObject" end
    return nil, nil
end

---The record of the last M.names() call. Kept on the module so keymap.lua's report can print
---WHICH source answered without calling again — "244 names, shipped copy" and "251 names, read
---live" are different evidence and a log that merges them is a log that cannot be audited.
M.state = { source = "unread", count = 0, why = "M.names() has not been called yet" }

---Every UI input-action name, live table preferred.
---
---Returns the list and the record. Never raises, never returns nil: with no game at all the
---shipped list answers, which is what makes keymap.lua's Find route testable headlessly.
---@return string[] names, table record
function M.names()
    local dt, how = liveTable()
    if dt then
        local raw
        local ok = pcall(function() raw = dt:GetRowNames() end)
        local live = ok and toNames(raw) or {}
        if #live > 0 then
            M.state = { source = "live", count = #live, how = how,
                why = string.format("read %d row name(s) out of the live %s via %s — a live read "
                    .. "cannot go stale and picks up anything a patch or a PalSchema pack added",
                    #live, M.TABLE, how) }
            return live, M.state
        end
        M.state = { source = "shipped", count = #M.UI_ACTIONS, how = how,
            why = string.format("%s resolved (%s) but GetRowNames answered nothing, so the "
                .. "%d shipped row name(s) are used instead", M.TABLE, how, #M.UI_ACTIONS) }
        return M.UI_ACTIONS, M.state
    end
    M.state = { source = "shipped", count = #M.UI_ACTIONS,
        why = string.format("%s is not loaded (neither FindObject nor %s resolved it), so the "
            .. "%d row name(s) shipped in core/keyboard/base/actions.lua answer — they are the "
            .. "1.x catalog dump and can only be stale if a patch changed the table",
            M.TABLE, M.PATH, #M.UI_ACTIONS) }
    return M.UI_ACTIONS, M.state
end

---Log one line saying where the names came from. Called by keymap once per refresh that
---actually needed them, so a session that never had to look one up stays quiet.
function M.note()
    log.info(string.format("action names: %s (%d) — %s",
        M.state.source, M.state.count or 0, tostring(M.state.why)))
end

return M
