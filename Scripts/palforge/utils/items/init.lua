-- PalForge utils.items: item- and technology-quantity helpers, item-INDEPENDENT.
-- These are the reusable versions of what the old dev unlock/probe code did inline
-- (ported from palforge.deprecated.actions `smith:give_item`, deprecated.container
-- `probeWrite`, and old main.lua `devUnlock`). Purely about moving item counts and
-- unlocking tech — no dependency on any specific item/building class.
--
--   local items = require("palforge.utils.items")
--   items.count("Wood")            -- what the inventory holds right now, or nil (MEASURED)
--   items.count("example:Potion")  -- namespaced ids resolve to their DataTable fname
--   items.give("Wood", 10)         -- cheat-manager GetItem; true only if the count ROSE
--   items.take("Wood", 3)          -- remove 3 Wood from the inventory (MEASURED)
--   items.unlockAllTech()          -- PalCheatManager: recipe + category + lv-cap
--   items.unlockTech("example:Bench") -- unlock one technology row (ids resolve too;
--                                     -- true only if that row really exists in game)
--
-- GIVE AND TAKE GO THROUGH THE INVENTORY'S OWN WRITE, not through a cheat:
--
--     PalPlayerInventoryData:AddItem_ServerInternal(
--         FName StaticItemId, int32 Count, bool IsAssignPassive,
--         float LogDelay, bool bNotifyLog) -> EPalItemOperationResult
--
-- read off the LIVE build, which matters: dumps/cxx/Pal.hpp declares four parameters and the
-- installed binary has five. That fifth, `bNotifyLog`, is the whole of the "UFunction expected 6
-- parameters, received 4" that blocked this file for so long — UE4SS counts the return as a
-- slot, so six slots is five arguments. The dump was one game patch stale and the patch added
-- the parameter. Nothing here is called until core.signature has matched the declaration against
-- the live object, and this is why.
--
-- take is the same call with a NEGATIVE Count. That was the standing hypothesis for removal from
-- the beginning and was set aside for one reason: a call whose parameter list is unread must not
-- be made with any Count at all.
--
-- WHAT THE CHEAT ROUTE COST, since the comments here spent a long time defending it.
-- UPalCheatManager::GetItem(FName, int32) is declared on this build, executes with evidence
-- "declared", is called on the player controller's OWN cheat manager, on an inventory with room
-- (0.0 of 300.0) for an id that inventory can count (137 Wood) — and moves nothing, still
-- nothing 2.8 s later. It returns void, so it can never say why. Five in-game runs went into
-- establishing that, and every one of them would have been unnecessary had the inventory's own
-- write been read first. It answers with a named EPalItemOperationResult.
--
-- Fail-soft everywhere: every engine call is pcall-wrapped and reported via utils.log; helpers
-- return true on success, false on failure, never throw. What "success" means differs per helper
-- and each says so on its own doc comment. count MEASURES the live inventory through
-- CountItemNum (observed answering 135 for Wood), give and take report what the count did AND
-- what the inventory itself answered, unlockTech CHECKS that the name really is a row of the
-- live technology table, and unlockAllTech can only report that the native cheats executed
-- without raising.
local log            = require("palforge.utils.log").scope("items")
local object_manager = require("palforge.core.object_manager")
local sig            = require("palforge.core.signature")

local M = {}

-- Resolve the local player's UPalItemData inventory. Raises on any missing link so
-- the caller's pcall reports which step failed. (Path from deprecated.actions /
-- deprecated.container: PalUtility CDO -> PlayerState -> InventoryData.)
--
-- OBSERVED, not inferred: dumps/f5-partial-run.txt walked exactly this chain in a loaded save
-- and printed a real object at every step — PalUtility CDO -> BP_Player_Female_C ->
-- BP_PalPlayerState_C -> BP_PalPlayerInventoryData_C. The inventory object is reachable; what
-- is broken further down is one specific write call, not this resolve.
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
-- THIS ONE IS SETTLED — read back from a live save, not inferred from a name list.
-- dumps/f5-partial-run.txt, block item-inventory-count-readback, resolved the inventory
-- through the chain above and then asked it directly:
--     VALUE inv.CountItemNum -> UFunction: 00000205DCB46D38 (lua type userdata)
--     VALUE inv:CountItemNum(FName('Wood')) -> ok=true value=135 luatype=number tonumber=135
-- So the function is bound, it takes the id as an FName, and it hands Lua a plain number.
-- tonumber() stays only as the cheap guard it always was; it is no longer load-bearing.
--
-- ONE ARGUMENT RULE, learned the expensive way in that same run: the FName wrapper is
-- MANDATORY. The probe's very next line was inv:CountItemNum("Wood") with a bare Lua string,
-- and it faulted inside UE4SS's argument marshalling and took Palworld down — a native fault
-- pcall never sees. For the same reason the 64-bit sibling `.CountItemNum64` (in the class's
-- function list, its declaration never read) is NOT called here as a fallback: the add call
-- below is the standing proof of what guessing at a declaration costs. Should the 32-bit read
-- ever answer nil, that sibling — and then the container walk, PalPlayerInventoryData
-- .TryGetContainerFromStaticItemID / PalItemContainer .GetItemStackCount / PalItemSlot
-- .GetStackCount — is where to look next, AFTER its parameter list has been printed.
--
-- nil means UNKNOWN to every caller here, never zero.
local function countOf(inv, id)
    local ok, n = pcall(function() return inv:CountItemNum(FName(id)) end)
    if not ok then return nil end
    return tonumber(n)
end

-- The same read as M.count, on an ALREADY-RESOLVED id, and never raising: this is where give
-- and take get their before/after readings. Resolving the inventory chain once per READING
-- rather than once per call is deliberate — a reading has to be of the inventory as it is at
-- that moment, and the chain resolve is cheap next to the cheat it brackets.
--
-- nil is UNKNOWN to every caller here, never zero.
local function liveCount(resolved)
    local n
    local ok = pcall(function() n = countOf(playerInventory(), resolved) end)
    if not ok then return nil end
    return n
end

-- The declared parameter shape the two item cheats share, in the order core.signature checks
-- it: an FName item id, then a plain int32 count. GetItem(FName StaticItemId, int32 Count) and
-- DropItem(const FName StaticItemId, const int32 Num) really are the same shape, so this is
-- named once rather than repeated.
--
-- That shape is also the reason "present" evidence is acceptable for these two at all:
-- core.signature refuses to pass a struct, an out-param, a delegate or an enum on an unread
-- declaration, because those are where marshalling actually breaks. An FName plus an integer is
-- the marshalling this file already performs successfully on this build every time it unlocks a
-- technology.
local ITEM_CHEAT_PARAMS = { "NameProperty", "IntProperty" }

-- THE INVENTORY'S OWN WRITE, read from the live build rather than from the dump:
--   AddItem_ServerInternal — [StaticItemId:NameProperty, Count:IntProperty,
--                             IsAssignPassive:BoolProperty, LogDelay:FloatProperty,
--                             bNotifyLog:BoolProperty, ReturnValue:EnumProperty]
--
-- FIVE arguments and a return. That is the whole of "UFunction expected 6 parameters, received
-- 4" — UE4SS counts the return value as a slot, PalForge passed four, and the fifth argument is
-- `bNotifyLog`, which dumps/cxx/Pal.hpp does not have at all. The dump was generated one game
-- patch before the installed binary and the patch added that parameter; this is the clearest
-- illustration in the tree of why every dump-derived signature is checked against the live
-- object before it is called.
local ADD_ITEM_PARAMS = { "NameProperty", "IntProperty", "BoolProperty", "FloatProperty", "BoolProperty" }

-- And it ANSWERS. EPalItemOperationResult, verbatim from dumps/cxx/Pal_enums.hpp — thirty-five
-- named outcomes, so a refusal explains itself instead of being inferred from a count that did
-- not move. This is what the cheat-manager route could never give: GetItem returns nothing at
-- all, which is why "it ran and reached nothing" took five in-game runs to establish.
local ITEM_RESULT = {
    [0] = "Success",
    [1] = "SuccessNoOperation",
    [2] = "FailedTerminatedManager",
    [3] = "FailedNotExistsInventoryData",
    [4] = "FailedContainerOverflowSlotNum",
    [5] = "FailedContainerItemInfoOverSlotNum",
    [6] = "FailedContainerOverflowItemsInSlot",
    [7] = "FailedContainerNotFoundContainer",
    [8] = "FailedContainerNotFoundSlot",
    [9] = "FailedContainerIsLocalOnly",
    [10] = "FailedContainerNotEqualsId",
    [11] = "FailedCreateDynamicItemData",
    [12] = "FailedNoDynamicItemIds",
    [13] = "FailedNotFoundContainer",
    [14] = "FailedNotFoundSlot",
    [15] = "FailedNotFoundStaticItemData",
    [16] = "FailedNotEnoughSlotSpace",
    [17] = "FailedSameSlotUseProduceAndConsume",
    [18] = "FailedNotEnoughConsumes",
    [19] = "FailedInValidItemInSlot",
    [20] = "FailedNotEnoughNumInSlot",
    [21] = "FailedNotEqualRequiredItemInSlot",
    [22] = "FailedGetLocalSlotInServer",
    [23] = "FailedEmptyConsumeItemInfo",
    [24] = "FailedSlotCountIsZero",
    [25] = "FailedCannotAggregateSlotItem",
    [26] = "FailedInvalidPermission",
    [27] = "FailedNotAllowedByFilter",
    [28] = "FailedNotControllable",
    [29] = "FailedRestrictedOperation",
    [30] = "FailedRecievedItemNotEqual",
    [31] = "FailedTransactionLockedOperation",
    [32] = "FailedNotFoundRowNameOrHash",
    [33] = "FailedUnknown",
    [34] = "FailedUnknownLogOutput",
}

-- The result as a name, for a log line. Unknown values print their number rather than a guess.
local function resultName(v)
    local n = tonumber(v)
    if n == nil then return tostring(v) end
    return ITEM_RESULT[n] or ("EPalItemOperationResult(" .. n .. ")")
end

-- Did the write report success? Success and SuccessNoOperation are the only two that are not a
-- failure; the latter means the call was legal and moved nothing (asking for zero, say), which
-- the count check below then reports honestly rather than celebrating.
local function resultOk(v)
    local n = tonumber(v)
    return n == 0 or n == 1
end

-- CLOSED (was item-additem-signature). The declaration was read off the LIVE build and give
-- works: "give Wood x3: 140 -> 143", with the game's own pickup event firing beside it
-- ("Wood onObtain: count=3"). Two independent witnesses, in a real save.
--
-- The fact that blocked it for the whole project was one argument. The live declaration is
--   [StaticItemId:NameProperty, Count:IntProperty, IsAssignPassive:BoolProperty,
--    LogDelay:FloatProperty, bNotifyLog:BoolProperty, ReturnValue:EnumProperty]
-- five arguments and a return, where dumps/cxx/Pal.hpp has four and no bNotifyLog at all. UE4SS
-- counts the return as a slot, which is where "expected 6 parameters, received 4" came from.

-- The cheat manager (admin API). Two-step resolve ported from core/spawn: the singleton
-- first, then the local PlayerController's own CheatManager — which is where it lives in
-- the case FindFirstOf misses, because a dedicated server never gets the singleton (the
-- enabler mod arms itself from ClientRestart, and that hook does not fire server-side).
-- core/spawn goes one step further and CONSTRUCTS one when neither exists; this helper
-- only ever USES a cheat manager that already exists (including the one core/spawn
-- attached to the controller) — it builds no engine objects of its own. Raises when there
-- is none, so the caller's pcall reports which step failed.
-- The cheat manager, PREFERRING THE PLAYER'S OWN. The order matters and the old one was
-- backwards: it took FindFirstOf("PalCheatManager") first, which is whichever instance the
-- engine happens to list, and only fell back to the controller's. A UCheatManager reaches the
-- player through its OUTER — UE's own cheats are written against GetOuterAPlayerController() —
-- so an instance that is not this controller's can execute a world cheat perfectly (SpawnMonster
-- puts a pal in the world and demonstrably works) while an inventory cheat quietly reaches
-- nobody. That is the exact shape of the open give() failure, so ask the controller first.
local function cheatManager()
    local cm
    pcall(function() cm = FindFirstOf("PalPlayerController").CheatManager end)
    if cm and cm:IsValid() then return cm end
    cm = nil
    pcall(function() cm = FindFirstOf("PalCheatManager") end)
    assert(cm and cm:IsValid(), "PalCheatManager not available (needs CheatManagerEnabler)")
    return cm
end

-- Read the count again a second later, and log what it says. This does NOT change what give()
-- returns; it exists to answer one question the synchronous check cannot.
--
-- THE PRECEDENT IS THIS SESSION'S OWN. Pal spawning was declared broken on a build where it
-- worked perfectly: the call is asynchronous, the pal arrives about four seconds later, and
-- every check was taken immediately and reported the miss as a property of the game. The header
-- of this file has flagged the same possibility for give all along — AddItem_ServerInternal
-- declares a LogDelay, so the inventory-data path has a delay concept in it — and it has never
-- been tested. An add that lands after the second reading looks exactly like an add that never
-- happened.
-- Which cheat manager we are holding, and what it is outered to. Logged once per session on the
-- give path, because "the call ran and nothing happened" cannot distinguish a wrong object from
-- a full inventory, and the two need opposite fixes.
local describedCM = false
local function describeCheatManager(cm)
    if describedCM then return end
    describedCM = true
    local function nameOf(o)
        local ok, n = pcall(function() return o:GetFullName() end)
        return ok and tostring(n) or "?"
    end
    local outer, ctrlCM
    pcall(function() outer = cm:GetOuter() end)
    pcall(function() ctrlCM = FindFirstOf("PalPlayerController").CheatManager end)
    -- Compare by FULL NAME, not by rawequal: UE4SS hands out a fresh userdata wrapper per
    -- lookup, so two references to the same UObject are not the same Lua value. The first run
    -- of this line printed "is the controller's own: false" for a cheat manager whose own path
    -- was nested under that very controller, which is a diagnostic lying about its subject.
    log.info(string.format("items: cheat manager %s | outer %s | is the controller's own: %s",
        nameOf(cm), outer and nameOf(outer) or "?",
        tostring(ctrlCM ~= nil and nameOf(ctrlCM) == nameOf(cm))))
end

-- The live count of `itemId` in the local player's inventory, or nil when it cannot be read
-- (no world, no player — see countOf). nil is UNKNOWN, not zero. Namespaced ids resolve like
-- they do everywhere else.
--
-- This is the one item helper here that is MEASURED END TO END on this build: both the
-- resolve chain and the CountItemNum read were exercised in a loaded save and answered with
-- real objects and a real number (135 Wood). That is why give and take are allowed to state a
-- verdict at all — this read is the evidence both of them rest on, and a pack that only wants
-- to know what the player is carrying gets the answer straight from the game.
function M.count(itemId)
    return liveCount(object_manager.resolve(itemId) or itemId)
end

-- Add `count` of `itemId` to the local player's inventory, and MEASURE that it landed.
-- Namespaced ids ("pack:Name") resolve to their DataTable fname ("pack_Name"); literal ids
-- pass through.
--
-- THE CALL is UPalCheatManager:GetItem(FName StaticItemId, int32 Count) — dumps/cxx/Pal.hpp
-- :16398 — issued through core.signature, so the live declaration is checked before an argument
-- is marshalled. The cheat manager is the same object this file unlocks technologies through on
-- this build, and an FName-plus-int cheat is the same marshalling that already works there,
-- which is the strongest evidence available for a call nobody has watched yet.
--
-- THE VERDICT IS THE MEASUREMENT, NOT THE CALL. Issuing a cheat is never the same as an add
-- landing: an item id the game does not know and a full inventory both execute happily and move
-- nothing. So CountItemNum is read before and after (the one inventory read PROVEN on this
-- build — 135 Wood out of a live save), and true means the count was seen to RISE. false means
-- one of these, each logged distinctly:
--   * nothing was called — no PalCheatManager (needs CheatManagerEnabler), or core.signature
--     refused because this build does not declare GetItem the way the dump does;
--   * the cheat ran and the count could not be read (no world, no player). An unreadable count
--     is UNKNOWN, never zero, and deliberately NOT a success: a helper that claims a write it
--     could not see is exactly what hid the AddItem_ServerInternal outage for so long;
--   * the cheat ran and the count did not rise — an unknown item id, or a full inventory.
--
-- ⚠️ NOT YET OBSERVED IN GAME (file header). One failure mode to look for FIRST if this reports
-- false in a live save while logging evidence "declared": the cheat is server-authoritative and
-- its inventory-data sibling carries a LogDelay, so the add may land AFTER the second reading is
-- taken. That would be a false negative, and the fix is to re-read on a later frame — not to
-- start trusting the call, which is the thing this function refuses to do.
function M.give(itemId, count)
    count = math.floor(tonumber(count) or 1)
    local resolved = object_manager.resolve(itemId) or itemId
    if count <= 0 then
        log.err(string.format("give %s x%d: count must be a positive number", tostring(resolved), count))
        return false
    end

    local inv
    if not pcall(function() inv = playerInventory() end) then
        log.err(string.format("give %s x%d failed: the player's inventory could not be reached",
            resolved, count))
        return false
    end

    local before = liveCount(resolved)
    -- IsAssignPassive false (this is a plain item, not a rolled piece of gear), LogDelay 0.0 and
    -- bNotifyLog false (no pickup banner for something a mod handed over silently).
    local ok, result, level = sig.call(inv, "AddItem_ServerInternal", ADD_ITEM_PARAMS,
        FName(resolved), count, false, 0.0, false)
    if not ok then
        -- core.signature has already logged WHY (refused on the declaration, or raised on
        -- binding); this line is the one that names the item and the count.
        log.err(string.format("give %s x%d: AddItem_ServerInternal did not execute [evidence %s]",
            resolved, count, level))
        return false
    end
    if not resultOk(result) then
        -- The one thing the cheat route could never do: say why. This is a real answer from the
        -- inventory, not an inference from a count.
        log.err(string.format("give %s x%d refused by the inventory: %s [evidence %s]",
            resolved, count, resultName(result), level))
        return false
    end
    local after = liveCount(resolved)

    if before == nil or after == nil then
        log.warn(string.format("give %s x%d: AddItem_ServerInternal answered %s, but the "
            .. "inventory count could not be read (%s -> %s) — the add is unverified, so this "
            .. "reports false", resolved, count, resultName(result), tostring(before), tostring(after)))
        return false
    end
    if after <= before then
        -- "Unknown item id, or no room" is two very different answers and the log was giving
        -- neither. Both are cheap to distinguish and neither guess is worth another run:
        --   * the id is fine if the inventory can COUNT it — `before` is a real number here, so
        --     "Wood" is a StaticItemId this build knows;
        --   * room is readable directly. PalPlayerInventoryData declares GetNowItemWeight and
        --     GetMaxItemWeight, and a player at the cap is exactly the case where a cheat runs,
        --     raises nothing and moves nothing.
        local now, max
        pcall(function()
            local inv = playerInventory()
            now = tonumber(inv:GetNowItemWeight())
            max = tonumber(inv:GetMaxItemWeight())
        end)
        log.warn(string.format("give %s x%d: AddItem_ServerInternal answered %s but the count "
            .. "did not rise (%d -> %d). Weight is now %s of %s. A success that moves nothing is "
            .. "worth reporting as a failure — the count is what a caller can see",
            resolved, count, resultName(result), before, after, tostring(now), tostring(max)))
        return false
    end
    log.info(string.format("give %s x%d: %d -> %d [evidence %s]",
        resolved, count, before, after, level))
    return true
end

-- Remove `count` of `itemId` from the local player's inventory by DROPPING IT ON THE GROUND,
-- and measure that the inventory really lost it. `count` is treated as a magnitude.
--
-- ⚠️ WHAT PHYSICALLY HAPPENS, said plainly: the call is UPalCheatManager:DropItem(const FName
-- StaticItemId, const int32 Num) — dumps/cxx/Pal.hpp:16453 — and a drop is not a delete. The
-- items leave the inventory, which is what :take promises and what the count below verifies,
-- and then they exist in the world at the player's feet, where anyone can walk over them and
-- pick them back up. A pack that takes a payment this way leaves the payment lying there. If a
-- pack needs the item GONE, this is not that call — and no call on this build is (below).
--
-- WHY THIS CALL AND NOT A REMOVE: there is no remove. dumps/f5-partial-run.txt walked the
-- inventory's WHOLE class chain in a live save, which is what the earlier reflection dump could
-- not do (UE4SS ForEachFunction lists a class's own functions only, so a base class was still a
-- live possibility). The walk:
--   * [0] BP_PalPlayerInventoryData_C — 0 functions, 0 properties of its own.
--   * [1] /Script/Pal.PalPlayerInventoryData — 69 functions, 25 properties. Exactly ONE
--         function matches remove|sub|consume|discard|drop|take|lost|delete|decrease|trash|
--         throw, and it is TryRemoveEquipment, which unequips a slot. No property matches.
--   * [2] /Script/CoreUObject.Object — 1 function, no match.
--   * PalItemContainer, the container behind it — 13 functions, no match.
-- 69 + 13 + 1 functions, one hit, and the hit is about equipment. Nothing on the chain
-- subtracts an item, base classes included. The only consumption path ever OBSERVED is
-- UseItemToCharacter_ServerInternal (dumps/reflection/06_events.txt caught it firing with
-- `{Id=Berries}` when the player ate one), and that is the game invoking its own use processor,
-- not an inventory API a pack can call for an arbitrary id. Against that, a cheat that takes the
-- item out of the inventory in one FName-plus-int call — the shape this file already marshals
-- successfully — is the best-evidenced removal on this build. It is simply honest about where
-- the item goes.
-- (The F5 block also printed "function absent" for a dozen proposed removal names — ignore
-- those lines as evidence. The same helper printed it for AddItem_ServerInternal, which
-- demonstrably exists, so what is being reported there is a probe bug, not an absence. The
-- FN/PROP chain counts above are the part that was really measured.)
--
-- THE VERDICT IS THE MEASUREMENT, exactly as in give and in the other direction: true only when
-- the count was seen to FALL. Two guards come with that, and both are about never asking for
-- something the inventory cannot give: the request is CLAMPED to what is actually held when
-- that is readable, so a drop never asks for an underflow, and the call is SKIPPED entirely
-- when the inventory holds none. false means nothing was called (no cheat manager,
-- core.signature refused, or nothing was held), or the cheat ran and the count could not be
-- read (UNKNOWN, never zero — an unobserved removal is not reported as one), or it ran and the
-- count did not fall.
--
-- ⚠️ NOT YET OBSERVED IN GAME, exactly like give — same dump, same untested route, and the same
-- server-authority delay to suspect first if a live run reports false with evidence "declared".
-- TODO(item-remove-call): unknown whether ANY call on this build removes an item without
-- putting it in the world. DropItem is a real removal from the inventory and it is what :take
-- uses, but a consume/destroy that leaves nothing behind is still unfound — and the two places
-- this note used to send a reader are now READ, both negative:
--   * UPalItemContainer (dumps/cxx/Pal.hpp) declares eleven functions and every one is a
--     getter: Num, Get, GetItemStackCount, GetPermission, GetFilterPreference,
--     GetFilterOffList, and the OnRep/delegate plumbing. UPalItemSlot is the same story —
--     TryGetStaticItemData, GetStackCount, GetItemId, IsEmpty, IsMaxStack and friends, plus
--     RequestUseToCharacter, which consumes through the USE processor for a target character
--     and is not an arbitrary-id removal. Neither class can subtract.
--   * UPalCheatManager's whole surface is now visible too, and its only item removals are
--     DropItem / DropItems (both put the item in the world, which is the thing being avoided)
--     and ClearPlatformInventoryItem / ConsumePlatformInventoryItem, which are storefront
--     entitlements, not inventory.
-- TWO CANDIDATES SURVIVE, both unread and both listed so the next reader does not re-walk what
-- is already walked:
--   (a) UPalCheatManager:InitInventory(const FName StaticItemId, const int32 Count) — reads
--       like a SET rather than an add, which would make Count 0 a true removal. The name says
--       "Init", so it may also wipe more than the one id; nothing may be called on that guess.
--       Read what it does before trusting it, in a throwaway world.
--   (b) UPalItemSlot.StackCount is a plain writable int32 PROPERTY (offset 0x154), not a
--       function, so a slot walk could decrement it with no marshalling involved at all. The
--       risk there is not the write but replication: the class carries OnRep_StackCount, so a
--       raw poke may leave server and client disagreeing. PalPlayerInventoryData
--       .RequestForceMarkAllDirty exists and is the obvious partner if this is ever tried. The old candidate, a NEGATIVE
-- Count through AddItem_ServerInternal, is no longer the only one and is no longer worth the
-- risk it carries while its six parameters are unread (item-additem-signature).
function M.take(itemId, count)
    count = math.floor(math.abs(tonumber(count) or 1))
    local resolved = object_manager.resolve(itemId) or itemId
    if count <= 0 then
        log.err(string.format("take %s x%d: count must be a positive number", tostring(resolved), count))
        return false
    end

    local inv
    if not pcall(function() inv = playerInventory() end) then
        log.err(string.format("take %s x%d failed: the player's inventory could not be reached",
            resolved, count))
        return false
    end

    local before = liveCount(resolved)
    if before == 0 then
        log.warn(string.format("take %s x%d: the inventory holds none, so nothing is removed",
            resolved, count))
        return false
    end
    local num = count
    if before ~= nil and count > before then
        num = before
        log.warn(string.format("take %s x%d: the inventory holds only %d, removing that many",
            resolved, count, before))
    end

    -- A NEGATIVE Count through the same write. That was the standing hypothesis for removal long
    -- before the signature was known, and it was set aside for one reason only: a call whose
    -- parameter list is unread must not be made with any Count at all. The list is read now, and
    -- the return value settles the rest — an inventory that will not subtract this way says so
    -- with a named EPalItemOperationResult instead of leaving it to be guessed from a count.
    --
    -- This also removes the pile at the player's feet. The DropItem route this replaces did take
    -- the items out of the bag, but it put them in the world, where the player walks straight
    -- back over them — so it could never charge a cost, which is most of what :take is for.
    local ok, result, level = sig.call(inv, "AddItem_ServerInternal", ADD_ITEM_PARAMS,
        FName(resolved), -num, false, 0.0, false)
    if not ok then
        log.err(string.format("take %s x%d: AddItem_ServerInternal did not execute [evidence %s]",
            resolved, num, level))
        return false
    end
    if not resultOk(result) then
        log.err(string.format("take %s x%d refused by the inventory: %s [evidence %s]",
            resolved, num, resultName(result), level))
        return false
    end
    local after = liveCount(resolved)

    if before == nil or after == nil then
        log.warn(string.format("take %s x%d: AddItem_ServerInternal answered %s, but the inventory "
            .. "count could not be read (%s -> %s) — the removal is unverified, so this reports "
            .. "false", resolved, num, resultName(result), tostring(before), tostring(after)))
        return false
    end
    if after >= before then
        -- Reaching here means the inventory answered Success or SuccessNoOperation and the count
        -- did not move: a call that is legal and inert. The result code is what says which, and
        -- it is the fact this line exists to carry — it printed `level` until now, which is the
        -- same word on every path and told nobody anything.
        log.warn(string.format("take %s x%d: AddItem_ServerInternal(Count=-%d) answered %s and "
            .. "the count did not fall (%d -> %d). A negative Count is accepted and does nothing, "
            .. "so it is not how this build subtracts — see TODO(item-remove-call)",
            resolved, num, num, resultName(result), before, after))
        return false
    end
    log.info(string.format("take %s x%d: %d -> %d [evidence %s, result %s]",
        resolved, num, before, after, level, resultName(result)))
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
