-- PalForge utils.items: item- and technology-quantity helpers, item-INDEPENDENT.
-- These are the reusable versions of what the old dev unlock/probe code did inline
-- (ported from palforge.deprecated.actions `smith:give_item`, deprecated.container
-- `probeWrite`, and old main.lua `devUnlock`). Purely about moving item counts and
-- unlocking tech — no dependency on any specific item/building class.
--
--   local items = require("palforge.utils.items")
--   items.give("Wood", 10)         -- add 10 Wood to the local player (measured)
--   items.give("example:Potion")   -- namespaced ids resolve to their DataTable fname
--   items.take("Wood", 3)          -- TRY to remove 3 Wood (unconfirmed call; measured)
--   items.count("Wood")            -- what the inventory holds right now, or nil
--   items.unlockAllTech()          -- PalCheatManager: recipe + category + lv-cap
--   items.unlockTech("example:Bench") -- unlock one technology row (ids resolve too;
--                                     -- true only if that row really exists in game)
--
-- Fail-soft everywhere: every engine call is pcall-wrapped and reported via
-- utils.log; helpers return true on success, false on failure (never throw). What
-- "success" means differs per helper and each one says so on its own doc comment:
-- give and take both MEASURE the inventory count around the write and report what
-- actually moved, unlockTech CHECKS that the name really is a row of the live technology
-- table before claiming anything, while unlockAllTech can only report that the native
-- cheats executed without raising — no cheat on this build reports back what it did.
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

-- How many of `id` the local inventory holds right now; nil when the count could not be read.
--
-- CountItemNum IS REFLECTED on this build — measured, not assumed. dumps/reflection/
-- 02_reflection.txt enumerated /Script/Pal.PalPlayerInventoryData with ForEachFunction and
-- `.CountItemNum` is in its 69-function list, alongside the `.AddItem_ServerInternal` both
-- write helpers already call and the `.IsExistItem` boolean. The whole resolve chain in
-- playerInventory() is on that same measured footing: PalUtility.GetPlayerStateByPlayer and
-- PalPlayerState.GetInventoryData are both in the dump too. So the call reaches a real
-- UFunction; that is no longer the open question.
--
-- What is still open is the RETURN. ForEachFunction lists function NAMES only — no parameter
-- or return types — so whether this hands Lua a plain integer or a struct/userdata that
-- tonumber() flattens to nil is unmeasured. `.CountItemNum64` sits right beside it in the same
-- list, so when the 32-bit call yields something tonumber() cannot read, the 64-bit sibling is
-- tried before giving up; it costs one call and only on a path that was about to answer nil.
-- Every caller treats nil as UNKNOWN, never as zero, so a build that will not hand back a
-- number degrades to "unverified", not to a lie.
-- TODO(item-inventory-count-readback): unknown what CountItemNum RETURNS to Lua (int vs
-- struct/userdata) — its existence is settled, its shape is not. If both spellings answer
-- nil, the measured escape hatch is the container walk: PalPlayerInventoryData exposes
-- .TryGetContainerFromStaticItemID and .TryGetItemIdBySlot, PalItemContainer exposes
-- .Num / .Get / .GetItemStackCount, and PalItemSlot exposes .GetItemId / .GetStackCount /
-- .IsEmpty — all present in 02_reflection.txt, none of them with a known signature yet.
local function countOf(inv, id)
    local ok, n = pcall(function() return inv:CountItemNum(FName(id)) end)
    if ok then
        local v = tonumber(n)
        if v ~= nil then return v end
    end
    ok, n = pcall(function() return inv:CountItemNum64(FName(id)) end)
    if ok then return tonumber(n) end
    return nil
end

-- Both write helpers do the same three steps around one AddItem_ServerInternal call:
-- resolve the inventory, read the count, write, read again. This is that preamble —
-- the live inventory, or nil plus the reason the caller should log.
local function inventoryFor(what, itemId, count)
    local inv
    local ok, e = pcall(function() inv = playerInventory() end)
    if ok then return inv end
    log.err(string.format("%s %s x%d failed: %s", what, tostring(itemId), count, tostring(e)))
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

-- The live count of `itemId` in the local player's inventory, or nil when it cannot be
-- read (no world, no player, or CountItemNum unbound — see countOf). nil is UNKNOWN, not
-- zero. Namespaced ids resolve like they do everywhere else.
function M.count(itemId)
    local resolved = object_manager.resolve(itemId) or itemId
    local n
    local ok = pcall(function() n = countOf(playerInventory(), resolved) end)
    if not ok then return nil end
    return n
end

-- Add `count` of `itemId` to the local player's inventory. Namespaced ids
-- ("pack:Name") resolve to their DataTable fname ("pack_Name"); literal ids pass
-- through. Uses the game's own server path AddItem_ServerInternal — the best-verified
-- call in the reference library and the one deprecated.container.probeWrite was written
-- to confirm.
--
-- The CALL being proven is not the same as the ADD landing: an id the item table does not
-- know and an inventory with no room both execute happily and move nothing. So the outcome
-- is MEASURED, exactly like take does it — CountItemNum before and after — and true means
-- the count was seen to RISE. The one exception is an unreadable count (countOf nil): the
-- write itself is the proven call, so a build that will not hand back a count gets a true
-- and a log line saying the add is unverified, rather than a false for a call that most
-- likely worked. Both outcomes are logged distinctly.
function M.give(itemId, count)
    count = math.floor(tonumber(count) or 1)
    local resolved = object_manager.resolve(itemId) or itemId
    if count <= 0 then
        log.err(string.format("give %s x%d: count must be a positive number", tostring(resolved), count))
        return false
    end

    local inv = inventoryFor("give", resolved, count)
    if not inv then return false end

    local before = countOf(inv, resolved)
    local ok, e = pcall(function()
        inv:AddItem_ServerInternal(FName(resolved), count, false, 0.0)
    end)
    if not ok then
        log.err(string.format("give %s x%d failed: %s", tostring(resolved), count, tostring(e)))
        return false
    end
    local after = countOf(inv, resolved)

    if before == nil or after == nil then
        log.info(string.format("give %s x%d (issued; CountItemNum unreadable, so the add is unverified)",
            tostring(resolved), count))
        return true
    end
    local moved = after - before
    if moved <= 0 then
        log.err(string.format("give %s x%d: count unchanged at %d — nothing entered the inventory " ..
            "(no such item id, or no room)", tostring(resolved), count, before))
        return false
    end
    if moved < count then
        log.warn(string.format("give %s x%d: only %d landed (%d -> %d)",
            tostring(resolved), count, moved, before, after))
    else
        log.info(string.format("give %s x%d (%d -> %d)", tostring(resolved), count, before, after))
    end
    return true
end

-- TRY to remove `count` of `itemId` from the local player's inventory. `count` is treated
-- as a magnitude.
--
-- ⚠️ REMOVAL IS UNCONFIRMED, and there is now MEASURED reason to think no dedicated remove
-- call is coming. dumps/reflection/02_reflection.txt enumerated the four classes an item
-- removal could plausibly live on and none of them declares one:
--   * PalPlayerInventoryData (69 functions) — has AddItem_ServerInternal, CountItemNum,
--     IsExistItem, RequestAddItem_ForDebug. It has no RemoveItem, RemoveItem_ServerInternal,
--     SubItem, ConsumeItem, DecreaseItem, DeleteItem, DiscardItem, DropItem, TakeItem,
--     LostItem or UseItem. Its only Remove is TryRemoveEquipment, which unequips a slot.
--   * PalItemContainer (13 functions) — Get, Num, GetItemStackCount[64], GetLastNotEmptyIndex,
--     GetPermission, filter/OnRep members. Nothing that subtracts.
--   * PalItemSlot (23 functions) — GetItemId, GetStackCount, IsEmpty, RequestUseToCharacter.
--     Nothing that subtracts; StackCount is a PROPERTY, which is the save-corrupting hand-write
--     deprecated.container._extractImpl is gated off for.
--   * PalItemUseProcessor (2 functions) — CanUseItemToCharacter, UseItemToCharacter_ServerInternal.
-- One caveat keeps this from being absolute: UE4SS ForEachFunction lists a class's OWN
-- functions only (proven in the same dump — PalPlayerCharacter and PalCharacter share zero
-- entries, and no engine APlayerController function appears under PalPlayerController), so a
-- base class of these four could still carry one. The four most likely homes are ruled out,
-- including the very class that declares the ADD.
--
-- The only consumption path ever OBSERVED is UseItemToCharacter_ServerInternal: 06_events.txt
-- caught it firing with `{Id=Berries}` when the player ate one. That is the game invoking its
-- own use processor, not an inventory API a pack can call for an arbitrary id.
--
-- So this still pushes a NEGATIVE delta through the add call, on the untested hypothesis that
-- the game accepts it. Because that is a hypothesis, the outcome is MEASURED instead of
-- assumed: CountItemNum is read before and after and the return value is whether the count
-- really fell. false here means "nothing was observed to leave the inventory" — the negative
-- delta did nothing, there was nothing to take, or the count could not be read at all (all
-- logged, distinctly). A caller is never told a removal happened that was not seen.
--
-- Two guards keep the unproven write as small as it can be: when the count IS readable the
-- delta is clamped to what the inventory actually holds (never ask for an underflow), and
-- when it holds none the write is skipped entirely (nothing to remove, so an untested
-- negative delta buys nothing).
-- TODO(item-remove-call): unknown whether AddItem_ServerInternal honours a negative Count.
-- The other half of this item is answered: no remove/consume UFunction is declared on
-- PalPlayerInventoryData, PalItemContainer, PalItemSlot or PalItemUseProcessor, so there is
-- no better call to switch to on those classes and a probe should stop hunting for one there.
-- Only an observed before/after delta around this write can settle what is left — 02_reflection
-- lists names, never signatures or behaviour, so no dump can answer it.
function M.take(itemId, count)
    count = math.floor(math.abs(tonumber(count) or 1))
    local resolved = object_manager.resolve(itemId) or itemId
    if count <= 0 then
        log.err(string.format("take %s x%d: count must be a positive number", tostring(resolved), count))
        return false
    end

    local inv = inventoryFor("take", resolved, count)
    if not inv then return false end

    local before = countOf(inv, resolved)
    if before ~= nil and before <= 0 then
        log.warn(string.format("take %s x%d: the inventory holds none — nothing to remove",
            tostring(resolved), count))
        return false
    end
    -- ask for no more than is there; an unreadable count leaves the caller's amount alone.
    local asked = (before ~= nil) and math.min(count, before) or count

    local ok, e = pcall(function()
        inv:AddItem_ServerInternal(FName(resolved), -asked, false, 0.0)
    end)
    if not ok then
        log.err(string.format("take %s x%d failed: %s", tostring(resolved), count, tostring(e)))
        return false
    end
    local after = countOf(inv, resolved)

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
