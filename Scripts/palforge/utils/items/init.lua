-- PalForge utils.items: item- and technology-quantity helpers, item-INDEPENDENT.
-- These are the reusable versions of what the old dev unlock/probe code did inline
-- (ported from palforge.deprecated.actions `smith:give_item`, deprecated.container
-- `probeWrite`, and old main.lua `devUnlock`). Purely about moving item counts and
-- unlocking tech — no dependency on any specific item/building class.
--
--   local items = require("palforge.utils.items")
--   items.give("Wood", 10)         -- add 10 Wood to the local player
--   items.give("example:Potion")   -- namespaced ids resolve to their DataTable fname
--   items.take("Wood", 3)          -- TRY to remove 3 Wood (unconfirmed call; verified)
--   items.unlockAllTech()          -- PalCheatManager: recipe + category + lv-cap
--   items.unlockTech("example:Bench") -- unlock one technology row (ids resolve too;
--                                     -- true only if that row really exists in game)
--
-- Fail-soft everywhere: every engine call is pcall-wrapped and reported via
-- utils.log; helpers return true on success, false on failure (never throw). What
-- "success" means differs per helper and each one says so on its own doc comment:
-- take MEASURES the inventory count and reports what actually moved, unlockTech CHECKS
-- that the name really is a row of the live technology table before claiming anything,
-- while give and unlockAllTech can only report that the native call executed without
-- raising — no add-item or cheat call on this build reports back what it did.
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

-- How many of `id` the local inventory holds right now; nil when the count could not be
-- read. CountItemNum is the accessor deprecated.container.probeWrite used to confirm its
-- AddItem writes landed, so it is the one proven way to check an inventory write.
local function countOf(inv, id)
    local ok, n = pcall(function() return inv:CountItemNum(FName(id)) end)
    if ok then return tonumber(n) end
    return nil
end

-- The cheat manager (admin API). Two-step resolve ported from core/spawn: the singleton
-- first, then the local PlayerController's own CheatManager — which is where it lives in
-- the case FindFirstOf misses, because a dedicated server never gets the singleton (the
-- enabler mod arms itself from ClientRestart, and that hook does not fire server-side).
-- core/spawn goes one step further and CONSTRUCTS one when neither exists; this helper
-- only ever USES a cheat manager that already exists (including the one core/spawn
-- attached to the controller) — it builds no engine objects of its own. Raises when there
-- is none, so the caller's pcall reports which step failed.
local function cheatManager()
    local cm; pcall(function() cm = FindFirstOf("PalCheatManager") end)
    if cm and cm:IsValid() then return cm end
    cm = nil
    pcall(function() cm = FindFirstOf("PalPlayerController").CheatManager end)
    assert(cm and cm:IsValid(), "PalCheatManager not available (needs CheatManagerEnabler)")
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

-- TRY to remove `count` of `itemId` from the local player's inventory. `count` is treated
-- as a magnitude.
--
-- ⚠️ REMOVAL IS UNCONFIRMED. No removal call has ever been found on this build — not in
-- the POCs, the deprecated Lua, the C++ module, the probe harness or the knowledge notes;
-- AddItem_ServerInternal is documented for ADDS only. This pushes a NEGATIVE delta through
-- that same add call on the untested hypothesis that the game accepts it. Because that is
-- a hypothesis, the outcome is MEASURED instead of assumed: CountItemNum is read before and
-- after and the return value is whether the count really fell. So false here means "nothing
-- was observed to leave the inventory" — either the negative delta does nothing on this
-- build, or the count could not be read at all (both are logged, distinctly). A caller is
-- never told a removal happened that was not seen.
function M.take(itemId, count)
    count = math.abs(tonumber(count) or 1)
    local resolved = object_manager.resolve(itemId) or itemId
    local before, after
    local ok, e = pcall(function()
        local inv = playerInventory()
        before = countOf(inv, resolved)
        inv:AddItem_ServerInternal(FName(resolved), -count, false, 0.0)
        after  = countOf(inv, resolved)
    end)
    if not ok then
        log.err(string.format("take %s x%d failed: %s", tostring(resolved), count, tostring(e)))
        return false
    end
    if before == nil or after == nil then
        log.warn(string.format("take %s x%d: CountItemNum unreadable, removal unconfirmed",
            tostring(resolved), count))
        return false
    end
    local moved = before - after
    if moved <= 0 then
        log.warn(string.format("take %s x%d: count unchanged at %d (the negative delta removed nothing)",
            tostring(resolved), count, before))
        return false
    end
    if moved < count then
        log.warn(string.format("take %s x%d: only %d removed (%d -> %d)",
            tostring(resolved), count, moved, before, after))
    else
        log.info(string.format("take %s x%d (%d -> %d)", tostring(resolved), count, before, after))
    end
    return true
end

-- ---- the technology row set (what makes unlockTech's return value mean something) ----
--
-- UnlockOneTechnology is SILENT — it returns nothing, and no "is this technology
-- unlocked" accessor exists anywhere on this build (not in the CheatManager surface of
-- __knowledges/palworld-ue4ss-functions.md, not in the dumps, not in the C++ bridge), so
-- the unlock itself CANNOT be read back. What can be checked is the precondition: whether
-- the name is a technology row at all. Most build ids are not — only 115 of the 501
-- vanilla DT_BuildObjectDataTable ids have a matching technology row — so without this
-- check the cheat "succeeds" for buildings that have nothing to unlock.
--
-- The table is fetched with UE4SS's TARGETED FindObject("DataTable", name) (lua-api
-- global, overload #1: class short name + object short name). Deliberately not the
-- FindAllOf("DataTable") sweep the catalog dumper uses: tests/catalog.lua:6-10 documents
-- that sweep as crash-prone (it touches every loaded table, and a stale pointer there
-- raises an access violation Lua pcall cannot catch), which is not acceptable inside an
-- ordinary helper. Row names then come from the extraction the dumper DID prove in game
-- (390 tables written to catalog/datatables/): UDataTable:GetRowNames, with the
-- BlueprintCallable UDataTableFunctionLibrary:GetDataTableRowNames as the fallback for
-- when the direct method is not reflected.
--
-- Reading the LIVE table rather than a checked-in dump is what makes this work for MODDED
-- techs: a PalSchema pack's row is in the loaded table, so "example_Bench" is confirmable
-- exactly like a vanilla row. Both spellings of the table are consulted and unioned —
-- PoC-A confirmed the real name is DT_TechnologyRecipeUnlock_Common, and the dump found
-- a plain DT_TechnologyRecipeUnlock object loaded as well.
local TECH_TABLES = { "DT_TechnologyRecipeUnlock_Common", "DT_TechnologyRecipeUnlock" }

-- Add every FName in a UE4SS TArray to `set` as a string; returns how many were added.
-- Handles the three shapes the catalog dumper had to cope with (ForEach, 1-based [i],
-- 0-based Get(i-1)) and drops empty / "None" entries.
local function addNames(arr, set)
    if arr == nil then return 0 end
    local added = 0
    local function add(v)
        if type(v) == "userdata" then
            local okg, inner = pcall(function() return v.get and v:get() end)
            if okg and inner ~= nil then v = inner end
        end
        local ok, s = pcall(function()
            if type(v) == "userdata" and v.ToString then return v:ToString() end
            return tostring(v)
        end)
        if ok and type(s) == "string" and #s > 0 and s ~= "None" and not set[s] then
            set[s] = true
            added = added + 1
        end
    end
    pcall(function()
        if arr.ForEach then arr:ForEach(function(_, elem) add(elem) end) end
    end)
    if added == 0 then
        pcall(function()
            local n = 0
            if arr.GetArrayNum then n = arr:GetArrayNum()
            elseif type(arr) == "table" then n = #arr end
            for i = 1, n do
                local got = false
                pcall(function() if arr[i] ~= nil then add(arr[i]); got = true end end)
                if not got then pcall(function() add(arr:Get(i - 1)) end) end
            end
        end)
    end
    return added
end

-- Row names of one live UDataTable into `set`; returns how many were added.
local dtLib = nil
local function rowNamesInto(dt, set)
    local added = 0
    do
        local ok, arr = pcall(function() return dt:GetRowNames() end)
        if ok then added = added + addNames(arr, set) end
    end
    if added > 0 then return added end
    if dtLib == nil then
        local ok, lib = pcall(StaticFindObject, "/Script/Engine.Default__DataTableFunctionLibrary")
        dtLib = (ok and lib) or false
    end
    if dtLib then
        -- UE4SS may return the out-array OR fill the passed table in place — try both.
        local out = {}
        local ok, ret = pcall(function() return dtLib:GetDataTableRowNames(dt, out) end)
        if ok then added = added + addNames(ret, set) + addNames(out, set) end
    end
    return added
end

-- The live technology row names as a set, or nil when they could not be read at all
-- (no FindObject global, the tables not loaded yet, no working row-name accessor). nil
-- means UNKNOWN, never "empty": only a non-empty read is ever used to declare a name absent.
-- A successful read is memoized for the session (rows are fixed once the asset is loaded;
-- PalSchema injects its own before play), a miss is NOT — so a call made before the table
-- loaded is simply retried on the next one.
local cachedTechRows = nil
local function technologyRows()
    if cachedTechRows then return cachedTechRows end
    if type(FindObject) ~= "function" then return nil end
    local set, n = {}, 0
    for _, tableName in ipairs(TECH_TABLES) do
        local ok, dt = pcall(FindObject, "DataTable", tableName)
        if ok and dt then
            local okv, valid = pcall(function()
                if dt.IsValid then return dt:IsValid() end
                return true
            end)
            if okv and valid then n = n + rowNamesInto(dt, set) end
        end
    end
    if n == 0 then return nil end
    cachedTechRows = set
    return set
end

-- Unlock all technology via the generic PalCheatManager cheats: every recipe, every
-- category, and the level-cap unlock. (PalSchema-injected rows aren't picked up by
-- these generic cheats — use unlockTech(name) for those.) Each cheat is guarded on its
-- own so one missing function does not cost you the other two, and each result is
-- TRACKED: this returns true only when all three executed, false (naming the ones that
-- did not) otherwise. "Executed" is as far as the game lets us see — no cheat reports
-- what it unlocked, so a call that ran but unlocked nothing still counts as executed.
function M.unlockAllTech()
    local failed = {}
    local ok, e = pcall(function()
        local cm = cheatManager()
        local function cheat(label, fn)
            if not pcall(fn) then failed[#failed + 1] = label end
        end
        cheat("UnlockAllRecipeTechnology",   function() cm:UnlockAllRecipeTechnology() end)
        cheat("UnlockAllCategoryTechnology", function() cm:UnlockAllCategoryTechnology() end)
        cheat("UnlockTechnologyByLvCap(60)", function() cm:UnlockTechnologyByLvCap(60) end)
    end)
    if not ok then
        log.err("unlockAllTech failed: " .. tostring(e))
        return false
    end
    if #failed > 0 then
        log.err("unlockAllTech: " .. table.concat(failed, ", ") .. " did not execute")
        return false
    end
    log.info("unlockAllTech: recipe + category + lv-cap(60)")
    return true
end

-- Unlock ONE technology row by name via UnlockOneTechnology(FName). This is how
-- modded (PalSchema-injected) building techs get unlocked — each modded building's
-- Technology block creates a DT_TechnologyRecipeUnlock row named after its id
-- (e.g. "example_Bench"). The name goes through the same resolve give() uses, so both
-- the namespaced form ("example:Bench") and the already-resolved fname work.
--
-- The cheat is ALWAYS issued (a name the game does not know is a no-op for it), but the
-- return value is the CHECK, not the call. true means: the name was confirmed to be a row
-- of the live technology table AND the cheat executed without raising. false means one of
-- three things, each logged distinctly:
--   * the call itself failed (usually: no PalCheatManager — needs CheatManagerEnabler);
--   * the technology table could not be read, so the unlock is unverifiable;
--   * the name is no technology row, so there was nothing there to unlock — which is the
--     normal answer for most vanilla build ids (Building.get("PalBoxV2"):unlock()).
-- Even a true is only "the row exists and the cheat ran": UnlockOneTechnology reports
-- nothing back and this build exposes no is-unlocked accessor, so no code here can prove
-- the tech tree actually changed. See the technology row set block above.
function M.unlockTech(name)
    local resolved = object_manager.resolve(name) or name
    local rows = technologyRows()
    local ok, e = pcall(function()
        local cm = cheatManager()
        cm:UnlockOneTechnology(FName(resolved))
    end)
    if not ok then
        log.err("unlockTech '" .. tostring(resolved) .. "' failed: " .. tostring(e))
        return false
    end
    if rows == nil then
        log.warn("unlockTech " .. tostring(resolved) ..
            ": issued, but the technology table could not be read — unlock unverified")
        return false
    end
    if not rows[resolved] then
        log.warn("unlockTech " .. tostring(resolved) ..
            ": issued, but no technology row of that name exists — nothing to unlock")
        return false
    end
    log.info("unlockTech " .. tostring(resolved) .. " (technology row confirmed)")
    return true
end

return M
