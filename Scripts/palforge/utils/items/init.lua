-- PalForge utils.items: item- and technology-quantity helpers, item-INDEPENDENT.
-- These are the reusable versions of what the old dev unlock/probe code did inline
-- (ported from palforge.deprecated.actions `smith:give_item`, deprecated.container
-- `probeWrite`, and old main.lua `devUnlock`). Purely about moving item counts and
-- unlocking tech — no dependency on any specific item/building class.
--
--   local items = require("palforge.utils.items")
--   items.give("Wood", 10)         -- add 10 Wood to the local player
--   items.give("example:Potion")   -- namespaced ids resolve to their DataTable fname
--   items.take("Wood", 3)          -- remove 3 Wood (give with a negative count)
--   items.unlockAllTech()          -- PalCheatManager: recipe + category + lv-cap
--   items.unlockTech("example_Bench") -- unlock one technology row by name
--
-- Fail-soft everywhere: every engine call is pcall-wrapped and reported via
-- utils.log; helpers return true on success, false on failure (never throw).
local log            = require("palforge.utils.log").scope("items")
local object_manager = require("palforge.core.object_manager")

local M = {}

-- Resolve the local player's UPalItemData inventory. Raises on any missing link so
-- the caller's pcall reports which step failed. (Path from deprecated.actions /
-- deprecated.container: PalUtility CDO -> PlayerState -> InventoryData.)
local function playerInventory()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    assert(util and util:IsValid(), "PalUtility CDO not found")
    local player = FindFirstOf("PalPlayerCharacter")
    assert(player and player:IsValid(), "no PalPlayerCharacter")
    local ps = util:GetPlayerStateByPlayer(player)
    assert(ps and ps:IsValid(), "no PlayerState")
    local inv = ps:GetInventoryData()
    assert(inv and inv:IsValid(), "no InventoryData")
    return inv
end

local function cheatManager()
    local cm = FindFirstOf("PalCheatManager")
    assert(cm and cm:IsValid(), "PalCheatManager not available (server: needs CheatManagerEnabler)")
    return cm
end

-- Add `count` of `itemId` to the local player's inventory. Namespaced ids
-- ("pack:Name") resolve to their DataTable fname ("pack_Name"); literal ids pass
-- through. Uses the game's own server path AddItem_ServerInternal (the same call
-- deprecated.container.probeWrite verified as safe). Returns true on success.
function M.give(itemId, count)
    count = count or 1
    local resolved = object_manager.resolve(itemId) or itemId
    local ok, e = pcall(function()
        local inv = playerInventory()
        inv:AddItem_ServerInternal(FName(resolved), count, false, 0.0)
    end)
    if ok then log.info(string.format("give %s x%d", tostring(resolved), count))
    else log.err(string.format("give %s x%d failed: %s", tostring(resolved), count, tostring(e))) end
    return ok
end

-- Remove `count` of `itemId` from the local player's inventory. Implemented as a
-- give with a negative count (AddItem_ServerInternal accepts negative deltas on the
-- observed build). `count` is treated as a magnitude. Returns true on success.
function M.take(itemId, count)
    count = math.abs(count or 1)
    return M.give(itemId, -count)
end

-- Unlock all technology via the generic PalCheatManager cheats: every recipe, every
-- category, and the level-cap unlock. (PalSchema-injected rows aren't picked up by
-- these generic cheats — use unlockTech(name) for those.) Returns true on success.
function M.unlockAllTech()
    local ok, e = pcall(function()
        local cm = cheatManager()
        pcall(function() cm:UnlockAllRecipeTechnology() end)
        pcall(function() cm:UnlockAllCategoryTechnology() end)
        pcall(function() cm:UnlockTechnologyByLvCap(60) end)
    end)
    if ok then log.info("unlockAllTech: recipe + category + lv-cap(60)")
    else log.err("unlockAllTech failed: " .. tostring(e)) end
    return ok
end

-- Unlock ONE technology row by name via UnlockOneTechnology(FName). This is how
-- modded (PalSchema-injected) building techs get unlocked — each modded building's
-- Technology block creates a DT_TechnologyRecipeUnlock row named after its id
-- (e.g. "example_Bench"). Returns true on success.
function M.unlockTech(name)
    local ok, e = pcall(function()
        local cm = cheatManager()
        cm:UnlockOneTechnology(FName(name))
    end)
    if ok then log.info("unlockTech " .. tostring(name))
    else log.err("unlockTech '" .. tostring(name) .. "' failed: " .. tostring(e)) end
    return ok
end

return M
