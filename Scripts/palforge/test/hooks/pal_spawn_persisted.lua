-- test/hooks/pal-spawn-persisted — DOES A SPAWNED PAL SURVIVE A SAVE, AND CAN THE LEDGER NAME IT?
--
-- WHY THIS FILE EXISTS. `core/ledger.lua` declares four kinds and writes three. The fourth,
-- `pal`, is declared because the on-disk format carries it and is written by NOTHING — its own
-- comment says so, and named `test/hooks/pal-spawn-persisted` as the measurement that would
-- settle it. That hook did not exist. A comment naming an instrument that is not there is the
-- exact defect this directory was built to remove: it reads as "someone is on it" and it is a
-- dead end. So it is declared now, and either it answers or it closes the question negatively.
--
-- THE QUESTION, in one sentence: when `Pal.Handle:spawn` puts a pal in the world, does that pal
-- end up in Palworld's own save — and if it does, is there anything stable enough to record, so
-- that removing the pack could report (or undo) it?
--
-- WHY IT IS NOT OBVIOUS EITHER WAY. Three things are already known and they pull in different
-- directions:
--   * `pal-spawnmonster-signature` (Closed) established that `SpawnMonster` is ISSUED
--     synchronously and the pal ARRIVES about 4-6 seconds later. Anything asked immediately is
--     asking before the answer exists — that is the mistake that closed the item the first time,
--     and this hook waits.
--   * A spawned pal is a wild actor. Palworld persists wild pals per world region rather than
--     per individual, so "it is standing there after a reload" would NOT by itself mean the SAVE
--     carries that individual — a respawn looks identical from outside.
--   * A pal in the PALBOX or in the party is a different matter: those live in
--     `CharacterSaveParameterMap`, keyed by an individual id, which is the only thing a ledger
--     row could be keyed on.
--
-- SO THE HOOK ASKS THE NARROW VERSION and says which one it answered:
--   [1] what a spawned pal's individual parameter object exposes as an ID, if anything
--   [2] whether `CharacterSaveParameterMap` (or the class that owns it) is reachable from Lua
--   [3] whether the id from [1] can be FOUND in [2] — which is the whole question
--   [4] the honest verdict, including the negative: if no per-individual id is readable, or the
--       save map cannot be read, then `pal` can never be a ledger kind on this build and
--       core/ledger's declaration should say so instead of pointing here.
--
-- ⚠️ THIS ONE WRITES. It spawns a pal into the loaded save. A spawn cannot be taken back —
-- `core/state.lua`'s RECLAIM table records `pal` as `can = false` for exactly this reason ("there
-- is no per-individual removal; the cheat manager's deletions are world-scale") — so this runs
-- on a THROWAWAY SAVE and needs its own opt-in on top of env.debug.
local hooks = require("palforge.test.hooks")

-- How long to wait for the arrival. `pal-spawn-placement` measured ~4-6 s from issue to a pal
-- that reads back its own location; 10 s is that with room, and the hook reports how long it
-- actually took rather than assuming.
local ARRIVE_WAIT_S = 10

hooks.declare{
    id     = "pal-spawn-persisted",
    item   = "Implemented, never exercised by a game — the ledger's unwritten `pal` kind",
    writes = true,
    needs  = { world = true, player = true },
    desc   = "spawn one pal, wait for it to arrive, and report whether anything about it is "
          .. "readable from the save map — the measurement core/ledger's unwritten `pal` kind "
          .. "has been waiting on",
    run = function(h)
        local spawn  = require("palforge.core.spawn")
        local player = require("palforge.core.player")
        local uo     = require("palforge.core.uobject")
        local poll   = require("palforge.core.poll")

        h:section("[1] before — what is standing here already")
        local function monsters()
            local out = {}
            local ok = pcall(function()
                for _, a in ipairs(FindAllOf("PalMonsterCharacter") or {}) do
                    local k = uo.key(a)
                    if k then out[k] = a end
                end
            end)
            return ok and out or {}
        end
        local before = monsters()
        local nBefore = 0
        for _ in pairs(before) do nBefore = nBefore + 1 end
        h:value("PalMonsterCharacter actors before", nBefore)

        local at = player.location()
        if not (at and at.x and at.y and at.z) then
            h:fail("no player location, so there is nowhere to put a pal. Load a save and "
                .. "stand somewhere with room around you")
            return
        end
        -- %.0f, not %d. A world location is a FLOAT and Lua 5.4's %d raises
        -- "number has no integer representation" on one — which is exactly how this hook
        -- failed on its first run (2026-08-02 22:06:32), before it had spawned anything.
        -- The one mercy is that it raised BEFORE the write, so nothing was left in the save.
        h:value("player at", string.format("(%.0f,%.0f,%.0f)", at.x, at.y, at.z))

        h:section("[2] the spawn — ISSUED is all the call can report")
        local issued = spawn.palAt("ChickenPal", 1, at.x, at.y, at.z)
        h:value("spawn.palAt issued", tostring(issued))
        h:note("`pal-spawnmonster-signature` closed on exactly this distinction: the call reports "
            .. "whether it was ISSUED, never whether a pal arrived. Arrival is 4-6 s away and no "
            .. "caller can block, so the rest of this hook runs on the heartbeat and prints its "
            .. "own blocks below — look for #### BEGIN pal-spawn-persisted-arrival.")
        if issued == false then
            h:fail("the call was refused before it reached the game (no cheat manager, or bad "
                .. "arguments). Nothing below can be asked.")
            return
        end

        -- Deferred, on the one heartbeat, the way every other hook that waits does it. A hook
        -- body may not block: it runs on the game thread.
        local waited = 0
        poll.every("pal-spawn-persisted", function(elapsed)
            waited = elapsed
            local fresh
            for k, a in pairs(monsters()) do
                if not before[k] then fresh = a; break end
            end
            if not fresh and elapsed < ARRIVE_WAIT_S then return end   -- keep waiting

            h:beginBlock("arrival")
            if not fresh then
                h:fail(string.format("no NEW PalMonsterCharacter appeared within %.0f s. That is "
                    .. "a result about the SPAWN route, not about persistence, and it is the "
                    .. "same shape `pal-spawnmonster-signature` measured: the call was accepted "
                    .. "and the world did not change.", elapsed))
                h:endBlock("arrival")
                return true                                            -- stop the heartbeat
            end
            h:pass(string.format("a new pal arrived after ~%.0f s: %s", elapsed,
                tostring(uo.fullName(fresh))))

            h:section("[3] is there a per-individual ID to record?")
            local param
            pcall(function()
                local u = StaticFindObject("/Script/Pal.Default__PalUtility")
                param = u and u:GetIndividualCharacterParameterByActor(fresh)
            end)
            h:value("IndividualCharacterParameter", param and uo.describe(param) or "nil")

            -- Every plausible spelling, printed raw. A run of nils here is the answer that closes
            -- the ledger's `pal` kind: with no id, there is nothing a row could be keyed on.
            local FIELDS = { "IndividualId", "InstanceId", "PlayerUId", "CharacterID", "NickName" }
            local found = {}
            for _, f in ipairs(FIELDS) do
                local v
                pcall(function() v = param and param[f] end)
                local s
                if v ~= nil then
                    pcall(function() s = (type(v) == "userdata" and v.ToString and v:ToString()) or tostring(v) end)
                end
                h:value("  ." .. f, s or "nil")
                if s and s ~= "" and s ~= "None" then found[#found + 1] = f end
            end

            h:section("[4] is the save map reachable at all?")
            local saveMap
            pcall(function() saveMap = FindFirstOf("PalCharacterSaveParameterStorage") end)
            if not saveMap then
                pcall(function() saveMap = StaticFindObject("/Script/Pal.Default__PalCharacterSaveParameterStorage") end)
            end
            h:value("CharacterSaveParameter storage", saveMap and uo.describe(saveMap) or "nil")

            h:section("[5] the verdict")
            if #found == 0 then
                h:note("NO per-individual id was readable off the spawned pal. If a second run agrees, "
                    .. "`pal` can never be a ledger kind on this build, and core/ledger.lua's KIND "
                    .. "table should say that instead of pointing at this hook. That is a complete "
                    .. "answer — write it into plan/TODO.md and delete the pointer.")
            else
                h:pass("readable id field(s): " .. table.concat(found, ", ")
                    .. " — these are what a `pal` ledger row could be keyed on. The next question is "
                    .. "whether the id survives a save/load, which is a SECOND run of this hook after "
                    .. "quitting to the title and loading again: paste both blocks.")
            end
            h:note("⚠️ THE PAL IS STILL THERE. Nothing here removes it and nothing can: "
                .. "core/state.lua's RECLAIM records `pal` as can = false because the cheat "
                .. "manager's deletions are world-scale. This is why the hook is opt-in and why "
                .. "it says throwaway save.")
            h:endBlock("arrival")
            return true                                                -- one shot, then stop
        end)
    end,
}
