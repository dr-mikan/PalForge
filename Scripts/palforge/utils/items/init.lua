-- PalForge utils.items: item- and technology-quantity helpers, item-INDEPENDENT.
-- These are the reusable versions of what the old dev unlock/probe code did inline
-- (ported from palforge.deprecated.actions `smith:give_item`, deprecated.container
-- `probeWrite`, and old main.lua `devUnlock`). Purely about moving item counts and
-- unlocking tech — no dependency on any specific item/building class.
--
--   local items = require("palforge.utils.items")
--   items.count("Wood")            -- what the inventory holds right now, or nil (MEASURED)
--   items.count("example:Potion")  -- namespaced ids resolve to their DataTable fname
--   items.give("Wood", 10)         -- the inventory's own add; true only if the count ROSE
--   items.take("Wood", 3)          -- consume 3 Wood out of the bag; true only if it FELL
--   items.describeRemoval()        -- print the removal candidates' live declarations, call none
--   items.unlockAllTech()          -- PalCheatManager: recipe + category + lv-cap
--   items.unlockTech("example:Bench") -- unlock one technology row (ids resolve too;
--                                     -- true only if that row really exists in game)
--
-- GIVE GOES THROUGH THE INVENTORY'S OWN WRITE, not through a cheat:
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
-- TAKE GOES SOMEWHERE ELSE, because that same write will not subtract. A NEGATIVE Count was the
-- standing hypothesis for removal for the whole project; it was finally testable once the
-- parameter list was read, and it is dead: the inventory answered `Success` and the count did not
-- move (161 -> 161, measured in a real save). Accepted and inert. So take routes through the one
-- call on this build that consumes an item id out of the player's bag without putting it in the
-- world — the weapon's own ammo consume, APalWeaponBase:RequestConsumeItem (Pal.hpp:11776). The
-- long version, including what was eliminated and what was NOT chosen, is on M.take.
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
-- CountItemNum (observed answering 135 for Wood), give reports what the count did AND what the
-- inventory itself answered, take reports what the count did (its call returns void, so there is
-- nothing else to report), unlockTech CHECKS that the name really is a row of the live technology
-- table, and unlockAllTech can only report that the native cheats executed without raising.
local log            = require("palforge.utils.log").scope("items")
local object_manager = require("palforge.core.object_manager")
local poll           = require("palforge.core.poll")
local sig            = require("palforge.core.signature")
local uo             = require("palforge.core.uobject")

local M = {}

-- Resolve the local player's UPalItemData inventory. Raises on any missing link so
-- the caller's pcall reports which step failed. (Path from deprecated.actions /
-- deprecated.container: PalUtility CDO -> PlayerState -> InventoryData.)
--
-- OBSERVED, not inferred: dumps/f5-partial-run.txt walked exactly this chain in a loaded save
-- and printed a real object at every step — PalUtility CDO -> BP_Player_Female_C ->
-- BP_PalPlayerState_C -> BP_PalPlayerInventoryData_C. The inventory object is reachable; what
-- is broken further down is one specific write call, not this resolve.
--
-- Liveness at every step is core.uobject.live, not a hand-rolled `x and x:IsValid()`. Same
-- question, one implementation, and it cannot raise from inside the guard itself — a stale handle
-- can throw on the IsValid call, which is exactly the shape an assert message would then blame on
-- the wrong step.
local function playerInventory()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    assert(uo.live(util), "PalUtility CDO not found")
    local player = FindFirstOf("PalPlayerCharacter")
    assert(uo.live(player), "no PalPlayerCharacter")
    local ps = util:GetPlayerStateByPlayer(player)
    assert(uo.live(ps), "no PlayerState")
    local inv = ps:GetInventoryData()
    assert(uo.live(inv), "no InventoryData")
    return inv
end

-- One element out of a UE4SS TArray, unwrapped. Array elements arrive wrapped in
-- RemoteUnrealParam on this build — that is the trap `icons-row-read` cost three wrong turns to
-- find (an array read the right LENGTH with nothing in it, because every element was a wrapper
-- whose value lives behind :get()). Anything that walks a TArray here goes through this.
local function unwrap(v)
    if type(v) == "userdata" then
        local ok, inner = pcall(function() return v.get and v:get() end)
        if ok and inner ~= nil then return inner end
    end
    return v
end

-- The first LIVE object in a UE4SS TArray, or nil. Three access shapes are tried because
-- UE4SS spells array access differently across builds and this tree has been bitten by each:
-- ForEach, 1-based [i], and 0-based Get(i-1). This is a READ; it calls nothing on the game.
local function firstLiveElement(arr)
    if arr == nil then return nil end
    local found
    pcall(function()
        if arr.ForEach then
            arr:ForEach(function(_, elem)
                if found == nil then
                    local e = unwrap(elem)
                    if uo.live(e) then found = e end
                end
            end)
        end
    end)
    if found ~= nil then return found end

    local n = 0
    pcall(function() if arr.GetArrayNum then n = arr:GetArrayNum() end end)
    for i = 1, n do
        local e
        pcall(function() e = unwrap(arr[i]) end)
        if e == nil then pcall(function() e = unwrap(arr:Get(i - 1)) end) end
        if uo.live(e) then return e end
    end
    return nil
end

-- Resolve ONE weapon actor the local player currently has spawned. Raises on any missing link so
-- the caller's pcall reports which step failed, exactly like playerInventory above.
--
-- THE CHAIN, every link read off the shipping binary:
--   APalPlayerCharacter.LoadoutSelectorComponent          dumps/cxx/Pal.hpp:10523 (property)
--   UPalLoadoutSelectorComponent.spawnedWeaponsArray      dumps/cxx/Pal.hpp:21851 (property,
--                                                         TArray<APalWeaponBase*>)
--
-- Both links are PROPERTIES, deliberately. `UPalLoadoutSelectorComponent::GetWeaponList()`
-- (Pal.hpp:21878) hands back the same list through a UFunction, and a call is the one thing in
-- this tree that can kill the process when a declaration has moved — a property read cannot.
-- There is nothing to gain by paying that risk for data that is readable directly.
--
-- WHY THE PLAYER'S OWN LOADOUT AND NOT FindAllOf("PalWeaponBase"): a weapon actor consumes from
-- ITS OWNER's inventory (the class declares GetOwnerCharacter, Pal.hpp:11838, and
-- IsExistBulletInPlayerInventory, :11812). The engine's flat list is full of NPC weapons, and
-- charging the wrong bag would be invisible from here. Coming out of the player's own loadout
-- component, ownership is structural rather than checked.
local function playerWeapon()
    local player = FindFirstOf("PalPlayerCharacter")
    assert(uo.live(player), "no PalPlayerCharacter")
    local loadout
    pcall(function() loadout = player.LoadoutSelectorComponent end)
    assert(uo.live(loadout), "the player pawn carries no LoadoutSelectorComponent")
    local arr
    pcall(function() arr = loadout.spawnedWeaponsArray end)
    local weapon = firstLiveElement(arr)
    assert(weapon ~= nil, "the player has no spawned weapon actor")
    return weapon
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

-- THE REMOVAL, which comes from the other end of the game entirely:
--   APalWeaponBase:RequestConsumeItem(const FName& StaticItemId, int32 ConsumeNum)
--   dumps/cxx/Pal.hpp:11776
-- Two arguments, and they are the SAME shape this file already marshals successfully on this
-- build every time it counts an inventory (CountItemNum takes a `const FName&` too) or unlocks a
-- technology. `const FName&` reaches Lua as a plain NameProperty parameter; the reference is a
-- C++ calling convention, not a different argument type, and there is no struct, out-param,
-- delegate or enum anywhere in the list — the four kinds core.signature refuses to pass on an
-- unread declaration. Nothing here is called before that check runs anyway.
--
-- It returns VOID, which is the one way it is weaker than the add above: it cannot say why. The
-- count is the only witness a caller gets, and M.take says so rather than implying more.
local CONSUME_ITEM_PARAMS = { "NameProperty", "IntProperty" }

-- CLOSED (was item-additem-signature). The declaration was read off the LIVE build and give
-- works: "give Wood x3: 140 -> 143", with the game's own pickup event firing beside it
-- ("Wood onObtain: count=3"). Two independent witnesses, in a real save.
--
-- The fact that blocked it for the whole project was one argument. The live declaration is
--   [StaticItemId:NameProperty, Count:IntProperty, IsAssignPassive:BoolProperty,
--    LogDelay:FloatProperty, bNotifyLog:BoolProperty, ReturnValue:EnumProperty]
-- five arguments and a return, where dumps/cxx/Pal.hpp has four and no bNotifyLog at all. UE4SS
-- counts the return as a slot, which is where "expected 6 parameters, received 4" came from.

-- Which cheat manager we are holding, and what it is outered to. Logged ONCE PER SESSION, from
-- the resolve itself, because "the call ran and nothing happened" cannot distinguish a wrong
-- object from a full inventory and the two need opposite fixes.
--
-- IT USED TO SAY "on the give path" AND HAD NO CALLER AT ALL. give stopped going through the
-- cheat manager the day AddItem_ServerInternal's real declaration was read, and this diagnostic
-- was left behind pointing at a route that no longer existed — so the one line that could have
-- named a wrong-outer cheat manager had quietly stopped printing. It hangs off the resolve now,
-- which is the one thing every remaining cheat route in this file has in common (unlockTech,
-- unlockAllTech, describeRemoval).
local describedCM = false
local function describeCheatManager(cm)
    if describedCM then return end
    describedCM = true
    local outer, ctrlCM
    pcall(function() outer = cm:GetOuter() end)
    pcall(function() ctrlCM = FindFirstOf("PalPlayerController").CheatManager end)
    -- Compare by FULL NAME, not by rawequal: UE4SS hands out a fresh userdata wrapper per
    -- lookup, so two references to the same UObject are not the same Lua value. The first run
    -- of this line printed "is the controller's own: false" for a cheat manager whose own path
    -- was nested under that very controller, which is a diagnostic lying about its subject.
    --
    -- THAT MEASUREMENT IS NOW THE FRAMEWORK'S, not this file's. It is one of the two runs behind
    -- core/uobject.lua, whose whole reason for existing is written at its top — so the comparison
    -- goes through uo.same and the names through uo.fullName rather than through a private copy
    -- that happens to agree with them. The same measurement is why uo.key exists and why no table
    -- in this tree may be keyed on a handle; nothing here keeps a per-object table, so this file
    -- needs the comparison half only.
    log.info(string.format("items: cheat manager %s | outer %s | is the controller's own: %s",
        uo.fullName(cm) or "?", uo.fullName(outer) or "?",
        tostring(uo.same(ctrlCM, cm))))
end

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
--
-- ⚠️ THIS ONE ASKS AND GIVES UP; core/spawn's same-named local ASKS AND THEN BUILDS. The two
-- are deliberately different and the difference is worth stating, because "PalForge needs the
-- CheatManagerEnabler mod" is a framework-wide claim that is FALSE and was believed for a while:
-- core/spawn.lua:190-217 constructs a cheat manager itself with the enabler's own
-- StaticConstructObject(pc.CheatClass, pc) recipe, so a world spawn only needs a player
-- controller. Nothing on THIS path does that yet, so every message below is honest about this
-- helper and must not be read as a statement about the framework.
--
-- Why it has not simply been given the same fallback: this helper asks the CONTROLLER first on
-- purpose (see the note above about the outer), core/spawn's constructor is a file-local, and
-- promoting it is a shared-module change rather than a comment fix. Doing it would make an
-- inventory cheat reachable in the one session shape where it currently is not — a controller
-- that exists with no cheat manager attached and no enabler present.
local function cheatManager()
    local cm
    pcall(function() cm = FindFirstOf("PalPlayerController").CheatManager end)
    if not uo.live(cm) then
        cm = nil
        pcall(function() cm = FindFirstOf("PalCheatManager") end)
        assert(uo.live(cm), "PalCheatManager not available to utils.items — this helper does "
            .. "not construct one (core/spawn does); install CheatManagerEnabler or load a save")
    end
    -- Never allowed to cost the caller its cheat manager: the description is a log line.
    pcall(describeCheatManager, cm)
    return cm
end

-- NO LATE READ-BACK ON THE GIVE PATH, and this is where the note that argued for one used to sit,
-- orphaned above a function that had been deleted out from under it. What it recorded is worth
-- keeping: pal spawning was declared broken on a build where it worked, because the call is
-- asynchronous, the pal arrives about four seconds later, and every check was taken immediately —
-- so a write measured too early looks exactly like a write that never happened. The reason give
-- needs no such pass ANY MORE is that its route changed and was then measured: it goes through
-- AddItem_ServerInternal, which ANSWERS with a named EPalItemOperationResult rather than void,
-- and the count was seen to rise inside the same call on 2026-07-26 ("give Wood x3: 161 -> 164").
-- LogDelay is still a parameter on that write, so if a live save ever shows an add landing late,
-- watchLateFall below is the shape to copy. take keeps its own late pass because its call returns
-- void and the count is its only witness.

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
--   * nothing was called — this module's cheatManager() found none and does not build one
--     (core/spawn does, so this is not a framework-wide requirement — see that local's header),
--     or core.signature refused because this build does not declare GetItem the way the dump
--     does;
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
    -- THE LEDGER IS HOOKED HERE, AT THE ENGINE BOUNDARY, and not on Item.Handle:give — which is
    -- where it started and which covered one of this function's callers. This is the line that
    -- puts a row FName into ItemContainerSaveData, i.e. into PALWORLD'S OWN SAVE, and main.lua
    -- publishes `PalForge.utils.items` as a toolbox a pack calls directly. A ledger that only
    -- hears about the api route makes an uninstall report that is quietly incomplete for every
    -- other route — an effect, a UI action, a native helper, a pack using the toolbox — and an
    -- incomplete removal report is worse than none, because it is believed.
    -- core/character.addSkill records the passive half the same way and for the same reason.
    --
    -- Behind the success test, not behind the call: `true` here is the count read back twice, so
    -- a row is written only for an add the inventory was SEEN to take. The SOURCE id goes in,
    -- not `resolved` — ledger.record resolves it itself, and om.owner is keyed on the source.
    -- The require is lazy for load order only; core.ledger has no dependency back on this file.
    pcall(function() require("palforge.core.ledger").record("item", itemId, count) end)
    return true
end

-- Read the count once more a few ticks later and LOG what it says. This never changes what take
-- returned — the caller already has its answer — and it exists for one reason: this session's own
-- worst diagnosis. Pal spawning was declared broken on a build where it worked, because the pal
-- arrives about four seconds after the call and every check was taken immediately. A consume
-- routed through a "Request" function is exactly the same shape of risk, so if the count falls
-- late, the log says so instead of the miss standing as a property of the build.
--
-- It registers with core.poll and NEVER creates a timer. Asking UE4SS for a LoopAsync per watch
-- removed its engine tick hook three times in one afternoon, each time silently killing every
-- keybind in the mod (core/poll.lua carries the full story).
local function watchLateFall(resolved, before, num)
    if before == nil then return end
    poll.every(string.format("take %s late read-back", resolved), function(elapsed, ticks)
        local now = liveCount(resolved)
        if now ~= nil and now < before then
            log.info(string.format("take %s x%d: the count fell LATE — %d -> %d after %.1f s. "
                .. "The removal worked and the synchronous check was simply too early; take "
                .. "reported false for it", resolved, num, before, now, elapsed))
            return true
        end
        -- Elapsed only. A tick count bounds on how fast the game thread drains its queue, not
        -- on how much time has passed — see the warning on poll.every.
        if elapsed >= 3.0 then
            log.info(string.format("take %s x%d: still %s after %.1f s, so the removal did not "
                .. "land late either", resolved, num, tostring(now), elapsed))
            return true
        end
        return false
    end)
end

-- Remove `count` of `itemId` from the local player's inventory, and measure that the inventory
-- really lost it. `count` is treated as a magnitude. Nothing is left on the ground.
--
-- THE CALL is APalWeaponBase:RequestConsumeItem(const FName& StaticItemId, int32 ConsumeNum) —
-- dumps/cxx/Pal.hpp:11776 — issued through core.signature on a weapon actor the player's own
-- loadout component spawned (playerWeapon, above). It is the game's own "spend an item out of
-- the bag" call: the path a throw weapon takes when it consumes the thing it just threw. The
-- item is consumed, not dropped — nothing appears at the player's feet — which is the whole
-- point, because a pack that charges a cost cannot leave the cost lying on the floor.
--
-- WHY THIS ONE, WHEN THE INVENTORY ITSELF HAS NO REMOVE. Everything below is READ, not guessed,
-- and it is listed so the next reader does not re-walk what is already walked:
--   * The inventory's whole class chain was walked in a live save. BP_PalPlayerInventoryData_C
--     (0 own functions), /Script/Pal.PalPlayerInventoryData (69), /Script/CoreUObject.Object (1)
--     and PalItemContainer (13). ONE name across all 83 matches
--     remove|sub|consume|discard|drop|take|delete|decrease|trash|throw, and it is
--     TryRemoveEquipment, which unequips a slot.
--   * UPalItemContainer (Pal.hpp:21505) and UPalItemSlot (:21633) are read in full. Every
--     function on both is a getter, except UPalItemSlot::RequestUseToCharacter (:21660), which
--     consumes through the USE processor for a target character — an FPalInstanceID struct and
--     an item that HAS a use effect, so not an arbitrary-id removal. Wood cannot be "used".
--   * UPalCheatManager's whole surface (:16085) is visible too: its only item removals are
--     DropItem / DropItems (:16453 / :16451), which put the item in the WORLD, and
--     ClearPlatformInventoryItem / ConsumePlatformInventoryItem (:16495), which are storefront
--     entitlements rather than inventory.
--   * A NEGATIVE Count through AddItem_ServerInternal — the standing hypothesis for years — is
--     dead. It was finally testable once the parameter list was read, and the inventory answered
--     `Success` while the count did not move (161 -> 161, in a real save). Accepted and inert.
-- What that sweep says is not "there is no removal" but "the removal is not reflected on the
-- inventory". APalWeaponBase is where it IS reflected: the same class declares
-- IsExistBulletInPlayerInventory (:11812) and GetOwnerCharacter (:11838), so a weapon plainly
-- both reads and spends the owning PLAYER's bag, by item id and count, in one call.
--
-- THE TWO CANDIDATES THIS DID NOT TAKE, and why neither is called from anywhere in this file:
--   (a) UPalCheatManager:InitInventory(const FName StaticItemId, const int32 Count) —
--       Pal.hpp:16379. "Init" reads like a SET, which would make Count 0 a removal, and it may
--       equally wipe more than the one id. It also sits on the cheat manager, and the cheat
--       manager has a MEASURED pattern on this build: GetItem is declared, executes on the
--       player's own instance with room in the inventory, and reaches nothing (five in-game runs
--       went into establishing that). M.describeRemoval below prints its live declaration
--       without calling it; until someone reads that line in a throwaway world, nothing may act
--       on the guess.
--   (b) UPalItemSlot.StackCount — a plain writable int32 property at offset 0x154
--       (Pal.hpp:21650), so a slot walk could decrement it with no marshalling at all. The risk
--       is not the write but replication: the class carries OnRep_StackCount (:21662), so a raw
--       poke can leave server and client disagreeing about a save's contents, and
--       PalPlayerInventoryData.RequestForceMarkAllDirty (:27012) is a toggle rather than a
--       flush. A route that desyncs a real save is worse than a route that reports false.
--
-- THE VERDICT IS THE MEASUREMENT, exactly as in give and in the other direction: true only when
-- the count was seen to FALL. This call returns VOID — unlike the add, which answers with a named
-- EPalItemOperationResult — so the count is the only witness there is, and the log says as much.
-- Two guards come with it, both about never asking for something the inventory cannot give: the
-- request is CLAMPED to what is actually held when that is readable, and the call is SKIPPED
-- entirely when the inventory holds none. false means one of these, each logged distinctly:
--   * the player has no spawned weapon actor, so there is nothing to route the consume through.
--     That is this route's one real limitation and it is stated rather than hidden;
--   * core.signature refused: this build does not declare RequestConsumeItem the way the dump
--     does, and nothing was called;
--   * it ran and the count could not be read (UNKNOWN, never zero — an unobserved removal is
--     never reported as one);
--   * it ran and the count did not fall. A late fall is still logged by watchLateFall.
--
-- OBSERVED WORKING, 2026-07-26, in a live save:
--     give Wood x3: 161 -> 164 [evidence declared]
--     take Wood x3: 164 -> 161 [evidence declared]
-- Both open questions are answered by that pair. RequestConsumeItem spends the id it is HANDED,
-- not the weapon's own ammunition — Wood is not ammunition for anything — and the weapon does
-- not have to be the equipped one, only spawned. Its live declaration was read before it was
-- called: [StaticItemId:NameProperty, ConsumeNum:IntProperty], two links up the super chain.
--
-- A pack can charge a cost now, and the items are CONSUMED rather than dropped — nothing lands
-- at the player's feet to be picked straight back up, which is what made the DropItem route
-- useless for this.
--
-- ONE LIMITATION, and it is reported as its own message rather than buried in a refusal: a
-- player with nothing equipped has no weapon actor, so there is nothing to ask. That is a real
-- constraint on when :take can be called, not a failure of the call.
function M.take(itemId, count)
    count = math.floor(math.abs(tonumber(count) or 1))
    local resolved = object_manager.resolve(itemId) or itemId
    if count <= 0 then
        log.err(string.format("take %s x%d: count must be a positive number", tostring(resolved), count))
        return false
    end

    local weapon
    if not pcall(function() weapon = playerWeapon() end) or weapon == nil then
        -- The one honest limitation of this route, said plainly rather than reported as a
        -- refusal: the consume is a method ON a weapon actor, so a player whose loadout has
        -- spawned none has nothing to call it on. Equipping anything (a weapon, a tool, a
        -- sphere) puts an APalWeaponBase in spawnedWeaponsArray and the route opens.
        log.err(string.format("take %s x%d: the player has no spawned weapon actor, and "
            .. "RequestConsumeItem is a method on one — equip something and the removal route "
            .. "exists again", resolved, count))
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

    local ok, _, level = sig.call(weapon, "RequestConsumeItem", CONSUME_ITEM_PARAMS,
        FName(resolved), num)
    if not ok then
        -- core.signature has already logged WHY (refused on the declaration, or raised on
        -- binding); this line is the one that names the item and the count.
        log.err(string.format("take %s x%d: RequestConsumeItem did not execute [evidence %s]",
            resolved, num, level))
        return false
    end
    local after = liveCount(resolved)

    if before == nil or after == nil then
        log.warn(string.format("take %s x%d: RequestConsumeItem ran, but the inventory count "
            .. "could not be read (%s -> %s) — the removal is unverified, so this reports false",
            resolved, num, tostring(before), tostring(after)))
        return false
    end
    if after >= before then
        -- The call returns void, so there is no result code to name a reason with. What CAN be
        -- distinguished cheaply is stated: the id is fine (a real number came back for it, so
        -- this build counts it), the call was declared, and the count did not move — which
        -- leaves the two questions on the marker, both about what the weapon consumes.
        log.warn(string.format("take %s x%d: RequestConsumeItem executed [evidence %s] and the "
            .. "count did not fall (%d -> %d). It returns void, so the count is the only witness "
            .. "— the weapon route is proven, so this is a state this run did not have",
            resolved, num, level, before, after))
        watchLateFall(resolved, before, num)
        return false
    end
    log.info(string.format("take %s x%d: %d -> %d [evidence %s]",
        resolved, num, before, after, level))
    return true
end

-- Print the LIVE declarations of the removal candidates this file did NOT call, and call none of
-- them. Nothing here touches an inventory; every line is core.signature walking a UFunction on
-- the running build and saying what it found.
--
-- WHY THIS IS A FUNCTION AND NOT A COMMENT. `sig.describe` is exactly how the five-argument
-- inventory write was finally read — the shape of a function had been the obstacle for the whole
-- project and one printed line ended it. The two candidates left for removal are in the same
-- position now: `InitInventory` may be a SET (in which case Count 0 is the removal this file
-- wants) or may wipe the whole id, and no one can tell from the name. Its declaration is the
-- first fact, it costs one keypress in a loaded world, and it is safe because reading is not
-- calling.
--
-- Returns a table of { name = <evidence level> } so a test can report what it managed to read.
function M.describeRemoval()
    local out = {}

    local cm
    if pcall(function() cm = cheatManager() end) and cm ~= nil then
        -- dumps/cxx/Pal.hpp:16379 — void InitInventory(const FName StaticItemId, const int32
        -- Count). Read the printed parameter list before trusting anything about it: a two-
        -- argument SET and a two-argument wipe-then-set look identical from here.
        out.InitInventory = sig.describe(cm, "InitInventory")
    else
        log.warn("describeRemoval: no cheat manager, so InitInventory's declaration is unread "
            .. "(this module finds one, it does not construct one — core/spawn does)")
    end

    local weapon
    if pcall(function() weapon = playerWeapon() end) and weapon ~= nil then
        -- The route :take actually uses. Printing its declaration next to the candidate's is the
        -- point: one line then shows whether the build still agrees with dumps/cxx/Pal.hpp:11776,
        -- which is the same thing that turned out to be stale for AddItem_ServerInternal.
        out.RequestConsumeItem = sig.describe(weapon, "RequestConsumeItem")
    else
        log.warn("describeRemoval: the player has no spawned weapon actor, so "
            .. "RequestConsumeItem's declaration is unread")
    end

    return out
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
-- THIS IS THE WHOLE REASON Building.Handle:unlock() IS UNVERIFIABLE BY CONSTRUCTION, and the
-- api/building doc quotes this block for it. Nothing that can be written in Lua closes that gap:
-- the missing piece is an accessor the build does not have. What is real evidence, and what this
-- file can still be trusted for, is the PRECONDITION above plus one measured caution — the cheat
-- manager is an object that can execute a call perfectly and reach nothing. UPalCheatManager
-- ::GetItem is the case: declared, called on the player's OWN instance, on an inventory with room
-- for an id that inventory could count, evidence "declared", and the count never moved (five
-- in-game runs). It returns void, so it could never say why. A silent cheat plus no read-back is
-- exactly the pair that produced that, which is why a true from unlockTech is worded as narrowly
-- as it is at M.unlockTech.
-- (The other half of that pattern has been RETIRED and must not be quoted with it any more:
-- SpawnMonster, the cheat that "ran and did nothing", turned out to work — it is asynchronous by
-- about six seconds and every check had been taken immediately. See core/spawn.lua's header.)
--
-- The table is fetched with UE4SS's TARGETED FindObject("DataTable", name) (lua-api
-- global, overload #1: class short name + object short name). Deliberately not the
-- FindAllOf("DataTable") sweep the catalog dumper uses: test/tools/catalog.lua:6-10 documents
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
        v = unwrap(v)                       -- elements arrive wrapped; see unwrap's note
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
            -- Deliberately NOT uo.live here, and it is the one place in this file that is not.
            -- uo.live answers false for an object that does not expose IsValid, which is a
            -- correct answer for an ACTOR and the wrong one for an asset: what FindObject hands
            -- back for a UDataTable on this build need not carry the member at all, and treating
            -- "no IsValid" as "dead" would lose every technology row. So: consult IsValid when it
            -- is there, and otherwise trust the find that just answered.
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
--   * the call itself failed (usually: this module's cheatManager() found no PalCheatManager
--     and, unlike core/spawn's, does not construct one — so CheatManagerEnabler or a loaded
--     save closes it. That is a statement about THIS helper, not about PalForge);
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
    -- Recorded HERE rather than on Building.Handle:unlock, for the reason spelled out at the end
    -- of M.give: this is the call that changes the player's technology state, and this module is
    -- a documented public toolbox. `true` already means "the row exists and the cheat ran", which
    -- is the strongest claim this build allows — there is no is-unlocked accessor, so the ledger
    -- records an INTENT that landed, never a verified state. `name` and not `resolved`, same as
    -- give: ledger.record resolves it and om.owner is keyed on the source id.
    pcall(function() require("palforge.core.ledger").record("tech", name) end)
    return true
end

return M
