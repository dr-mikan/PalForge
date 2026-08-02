-- test/hooks/building-unlock — RECORD WHAT ACTUALLY HAPPENS, BECAUSE NOTHING CAN VERIFY IT.
--
-- plan/TODO.md "Owed work" §4, last bullet: *"`Building.Handle:unlock()` (api/building.lua:439)
-- is unverifiable by construction: there is no 'is it unlocked' accessor
-- (utils/items/init.lua:692), and it rides the cheat-manager surface
-- `pal-spawnmonster-signature` measured as silently doing nothing."*
-- (The bullet is quoted as written, so its first line reference is quoted with it and has since
--  drifted: Handle:unlock is at api/building.lua:520 as this was read. The second reference,
--  utils/items/init.lua:692, is still exact — it is the "UnlockOneTechnology is SILENT" block.)
--
-- TWO SEPARATE PROBLEMS, AND THEY COMPOUND. Either alone would be survivable.
--
--   1. UnlockOneTechnology RETURNS VOID and this build has no "is this technology unlocked"
--      accessor anywhere — not in the CheatManager surface, not in the dumps, not in the C++
--      bridge. So the write cannot be read back. Nothing that can be written in Lua closes that
--      gap; the missing piece is an accessor the binary does not have.
--   2. IT IS A CHEAT-MANAGER CALL, and this tree has MEASURED that surface executing a call
--      perfectly and reaching nothing: UPalCheatManager::GetItem, declared, called on the
--      player's own instance, on an inventory with room, evidence "declared", and the count
--      never moved across five in-game runs. (The other half of that old pair has been RETIRED
--      and must not be quoted beside it any more — SpawnMonster turned out to work and to be
--      asynchronous by about six seconds; see core/spawn.lua's header. Repeating the retired
--      claim is how a fixed thing stays "broken" in a plan file.)
--
-- Together: a silent call on a surface that has been seen to do nothing, with no read-back.
-- `unlockTech` copes by checking the PRECONDITION instead — is `name` a technology row at all —
-- which is real evidence and is not the same thing as evidence of an unlock. Only 115 of the 501
-- vanilla DT_BuildObjectDataTable ids have a matching technology row, so without that check the
-- cheat "succeeds" for buildings that have nothing to unlock.
--
-- SO THIS HOOK DOES THE ONLY HONEST THING AVAILABLE: it records, in order, every fact that can
-- be established — is there a cheat manager, is the id a technology row, what did the call do,
-- did it raise — and then hands the ONE question no code can answer to the person at the
-- keyboard: OPEN THE TECHNOLOGY MENU AND LOOK. That is not a weakness of the hook; it is the
-- item's finding written as a procedure.
--
-- ⚠️ writes = true. UnlockOneTechnology changes the player's technology state in the save, and
-- there is NO UNDO — no "lock this again" call exists either. Whatever this unlocks stays
-- unlocked. Use a throwaway save, and note that this is exactly why it is not run by F1.
local hooks = require("palforge.test.hooks")

-- A vanilla building that certainly has a technology row: the workbench is the first thing any
-- save unlocks, so it is also the one whose row is least likely to be missing. It may ALREADY be
-- unlocked in an established save, which is why block [4] asks about a menu rather than about a
-- change — and why the hook prints a second, more obscure id for anyone running on a fresh save.
local TARGET     = "WorkBench"
local ALT_TARGET = "PalBoxV2"

hooks.declare{
    id     = "building-unlock",
    item   = "Owed work §2 (declared, shipped, never observed working)",
    needs  = { world = true, player = true },
    writes = true,
    desc   = "record every establishable fact about Building.Handle:unlock, then hand the "
          .. "unverifiable half to the operator",
    run = function(h)
        local Building = require("palforge.api.building")
        local items    = require("palforge.utils.items")
        local om       = require("palforge.core.object_manager")
        local sig      = require("palforge.core.signature")
        local probe    = require("palforge.test.probe")

        --------------------------------------------------------------------
        h:section("[1] is there a cheat manager, and what does it declare")
        --------------------------------------------------------------------
        -- The declaration is read and NOTHING is called here. A cheat manager that does not
        -- exist is a completely different finding from one that exists and does nothing, and
        -- the two have been confused before.
        local cm
        pcall(function() cm = FindFirstOf("PalCheatManager") end)
        h:value("FindFirstOf('PalCheatManager')", probe.valid(cm) and probe.full(cm) or "none live")
        if probe.valid(cm) then
            h:value("UnlockOneTechnology declaration", sig.describe(cm, "UnlockOneTechnology"))
            h:note("`declared` above means the live build's parameter list matches what this "
                .. "tree calls with. It says nothing whatever about the call having an effect — "
                .. "GetItem was `declared` too, across five runs in which the item count never "
                .. "moved.")
        else
            h:note("no live PalCheatManager was findable by name. utils/items builds one off the "
                .. "LOCAL player controller when it needs one (CheatManagerEnabler), so this is "
                .. "not necessarily a refusal — block [3] is where it would show up.")
        end

        --------------------------------------------------------------------
        h:section("[2] the precondition: is it a technology row at all")
        --------------------------------------------------------------------
        -- This is the ONLY thing about an unlock that this build lets anyone verify, and it is
        -- verified BEFORE the write so a false below is attributable to the row rather than to
        -- the call.
        for _, id in ipairs({ TARGET, ALT_TARGET }) do
            local resolved = om.resolve(id) or id
            h:value("resolve(" .. id .. ")", resolved)
        end
        local names
        pcall(function() names = items.technologyNames and items.technologyNames() end)
        if type(names) == "table" then
            local n = 0
            for _ in pairs(names) do n = n + 1 end
            h:value("technology rows readable", n)
        else
            h:note("utils/items exposes no public technology-row reader, so the row check "
                .. "below happens inside unlockTech and shows up only in its [items] log line. "
                .. "That is a gap in the SURFACE, not in the check.")
        end

        --------------------------------------------------------------------
        h:section("[3] the write")
        --------------------------------------------------------------------
        h:warn("about to call UnlockOneTechnology(%q) on this save. THERE IS NO UNDO: no 'lock "
            .. "this again' call exists on this build, so whatever this unlocks stays unlocked.",
            TARGET)
        local handle = Building.get(TARGET)
        -- pcall's second value is the RETURN on success and the error on failure; both are
        -- printed, and which one it is is decided by `ok` on the line above it.
        local ok, result = pcall(function() return handle:unlock() end)
        if not ok then
            h:fail("Building.get(%q):unlock() RAISED: %s. That is a hard negative and the most "
                .. "informative outcome available — the call itself is not reachable.",
                TARGET, tostring(result))
            return
        end
        h:value("Building.get('" .. TARGET .. "'):unlock()", tostring(result))
        if result == true then
            h:pass("unlockTech issued the call AND confirmed a technology row of that name "
                .. "exists. That is the STRONGEST claim this build permits, and it is still not "
                .. "a claim that anything was unlocked.")
        else
            h:note("a false here has three distinct causes and the [items] log line above says "
                .. "which: the call raised, the technology table could not be read (unverified), "
                .. "or there is no technology row of that name (nothing to unlock). Only the "
                .. "first is a defect.")
        end

        --------------------------------------------------------------------
        h:section("[4] the half no code can answer")
        --------------------------------------------------------------------
        h:ask("OPEN THE TECHNOLOGY MENU and look for %s. That is the measurement — there is no "
            .. "accessor on this build that can be asked instead.", TARGET)
        h:note("WHAT TO WRITE IN plan/TODO.md, whichever it is:")
        h:note("  (1) it is unlocked and it was not before -> Building.Handle:unlock WORKS, and "
            .. "the cheat-manager surface is not uniformly dead. That is the first positive "
            .. "result that surface has produced since SpawnMonster was cleared.")
        h:note("  (2) it is not unlocked, with a true above -> the third instance of the "
            .. "GetItem pattern: declared, issued, no effect. api/building.lua:520 must then say "
            .. "so outright rather than describing an unlock.")
        h:note("  (3) it was ALREADY unlocked in this save -> nothing was measured. Run it again "
            .. "on a fresh save, or against %s, which an early save has not reached.", ALT_TARGET)
        h:note("Either way this hook has recorded what CAN be recorded: whether the manager "
            .. "exists, what it declares, whether the id is a technology row, and what the call "
            .. "returned. The gap that is left is a missing accessor in the game binary, and it "
            .. "is not closeable from Lua.")
    end,
}
