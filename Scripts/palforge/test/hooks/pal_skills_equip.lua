-- test/hooks/pal-skills-equip — THE MEASUREMENT THAT GATED A RELEASE, AND IT PASSED.
--
-- ⭐ 8 pass / 0 fail, 2026-08-02, in a real save on a live PalMonsterCharacter. AddEquipWaza
-- landed and read back, :forget took it off, teachAll answered `2, 2`, ClearEquipWaza worked and
-- every move was restored and verified. THE GAME STAYED UP. The source marker it used to point
-- at, in core/character.lua's skills section, is gone — replaced there by the finding. What is
-- left here is the instrument, and the paragraphs below are the reasoning it was built on.
--
-- This one WRITES INTO A CHARACTER IN A REAL SAVE, which is why it is gated and why it stays
-- gated: the earlier run that ever did it was followed 1.4 seconds later by Palworld closing.
--
-- ⚠️ THE CRASH, AND WHY IT MAY SAY NOTHING ABOUT THIS CAPABILITY. That run used the old search,
-- `FindAllOf("PalCharacter")`. The hierarchy is APalMonsterCharacter : APalNPC : APalCharacter
-- (dumps/cxx/Pal.hpp:10167, 10195, 8956), so "PalCharacter" also matches villagers, merchants
-- and every other NPC — none of which has an equipped move. The read-back that run consulted was
-- therefore an NPC's empty list, which is also why it concluded the write had not landed.
-- Putting an equipped MOVE on a villager is a far more plausible way to destabilise the game
-- than putting one on a pal. So the likeliest reading is "the write went to the wrong target",
-- and "likeliest" is not a thing to publish on — which is what this hook is for.
--
-- The search is fixed (support.nearbyPal asks PalMonsterCharacter) and this hook MEASURES THE
-- FIX rather than assuming it: block [1] counts how many PalCharacters in this world are NOT
-- PalMonsterCharacters, i.e. exactly how wide the old net was and how likely it was to catch a
-- villager. That number is the first thing to read in the output.
--
-- WHAT IT COVERS, and all three are things plan/TODO.md records as having NO coverage at all:
--   [2] the ACTIVE-MOVE WRITE through the public api — Skill.Handle:teach / :forget. The only
--       automated check is test/cases/skill.lua's "an active skill can be taught to a live
--       PAL" case (:585) and it is gated off.
--   [3] Pal.Handle:teachAll's `taught, asked` partial-result contract (api/pal.lua:553), which
--       has no check anywhere.
--   [4] core.character.clearSkills (core/character.lua:735), which wraps ClearEquipWaza and has
--       no caller and no check — its own marker says "NO CALLER, NO CHECK, NEVER RUN".
--
-- EVERY WRITE IS READ BACK. Not once at the end — after each individual call, because "the call
-- ran" is precisely the evidence that let :give and :spawn claim success for months while doing
-- nothing. A true from character.addSkill already means the read-back saw it; this hook prints
-- the lists either way so a false can be told apart from an unreadable pal.
--
-- ⚠️ RUN IT ON A THROWAWAY SAVE. It teaches Human_Punch and Human_Rolling — the two plainest
-- moves in the game, chosen so that a run which somehow leaves one behind changes nothing anyone
-- would notice — and it removes every one it added. Block [4] additionally CLEARS the pal's
-- equipped moves and puts them back; if the game closes between those two steps, that pal has
-- lost its moves permanently. That is the honest cost of measuring ClearEquipWaza at all.
local hooks = require("palforge.test.hooks")

-- The two plainest moves in the game. Human_Punch is EPalWazaID 1 and Human_Rolling is 298
-- (core/character.lua's WAZA map). Nothing in this hook may teach a real save a legendary move.
local MOVE_A, MOVE_B = "Human_Punch", "Human_Rolling"

-- Print all four lists every time. `active` alone cannot distinguish "nothing equipped" from
-- "nothing reachable" — a wild pal legitimately carries equipable moves it has not equipped —
-- and that ambiguity is what made the first run's zeros unreadable.
local function readBack(h, character, pal, when)
    local s = character.skillsOn(pal)
    if not s then
        h:fail("read-back %s: skillsOn returned nil — the individual parameter object could not "
            .. "be reached at all. Nothing below this line means anything.", when)
        return nil
    end
    h:value("skills " .. when, string.format("%d active {%s} | %d passive {%s} | %d equipable | %d mastered",
        #s.active, table.concat(s.active, ", "), #s.passive, table.concat(s.passive, ", "),
        #(s.equipable or {}), #(s.mastered or {})))
    return s
end

local function has(list, want)
    for _, v in ipairs(list or {}) do if v == want then return true end end
    return false
end

hooks.declare{
    id     = "pal-skills-equip",
    item   = "Closed 2026-08-02 — 8 pass / 0 fail on a live PalMonsterCharacter",
    needs  = { world = true, pal = true },
    writes = true,
    desc   = "the publish blocker: does an active-move write land on a real pal, and does the "
          .. "game survive it",
    run = function(h)
        local support   = require("palforge.test.support")
        local character = require("palforge.core.character")
        local uo        = require("palforge.core.uobject")
        local Skill     = require("palforge.api.skill")
        local Pal       = require("palforge.api.pal")

        --------------------------------------------------------------------
        h:section("[1] the target, and how wide the OLD search was")
        --------------------------------------------------------------------
        -- READ-ONLY, and it is the block that either supports or kills the crash hypothesis.
        local wide, narrow = {}, {}
        pcall(function() wide = FindAllOf("PalCharacter") or {} end)
        pcall(function() narrow = FindAllOf("PalMonsterCharacter") or {} end)
        h:value("FindAllOf('PalCharacter')", #wide .. " actor(s) — THE OLD SEARCH")
        h:value("FindAllOf('PalMonsterCharacter')", #narrow .. " actor(s) — what is asked now")
        h:value("non-pal PalCharacters in range", (#wide - #narrow) .. " (villagers, merchants, "
            .. "the player, every other NPC — each one a target the old search could have hit)")
        if #wide > #narrow then
            h:note("the old net WAS wider than the pals in this world, so 'the write landed on a "
                .. "villager' remains the leading explanation of the 1.4 s crash.")
        else
            h:note("the two searches answer the same count HERE, which does not clear the old "
                .. "search — it only says this particular spot has no NPCs in it.")
        end

        local pal, palClass = support.nearbyPal()
        if not pal then
            -- Unreachable: needs.pal gated it. Kept because the world moves between the gate
            -- check and this line, and a nil here must not read as a measurement.
            h:fail("the pal that satisfied the gate is gone. Nothing was written.")
            return
        end
        h:value("target class", tostring(palClass))
        h:value("target full name", tostring(uo.fullName(pal)))
        h:value("target class chain", table.concat(uo.classChain(pal), " : "))
        if not uo.isA(pal, "PalMonsterCharacter") then
            h:fail("the target is NOT a PalMonsterCharacter. REFUSING TO WRITE: this is the exact "
                .. "shape that correlated with the crash, and no measurement is worth repeating it.")
            return
        end
        h:pass("the target is a PalMonsterCharacter, which is the one class an equipped move "
            .. "belongs on")

        --------------------------------------------------------------------
        h:section("[2] Skill.Handle:teach / :forget — the active-move write")
        --------------------------------------------------------------------
        local before = readBack(h, character, pal, "before anything")
        if not before then return end

        h:warn("ABOUT TO WRITE. The next call is AddEquipWaza(EPalWazaID 1) on the pal above. "
            .. "If Palworld closes in the next few seconds, THAT is the finding: the write "
            .. "itself destabilises the game even with the target now known to be a pal, and "
            .. ":teach / :forget / :teachAll ship disabled with this log as the reason.")

        if has(before.active, MOVE_A) then
            h:note("that pal already has %s, so a clean before/after on it is impossible; "
                .. "block [2] uses %s instead", MOVE_A, MOVE_B)
        end
        local move = has(before.active, MOVE_A) and MOVE_B or MOVE_A
        if has(before.active, move) then
            h:warn("the pal already carries both %s and %s, so the ADD half cannot be measured "
                .. "on it. Run this against a different pal.", MOVE_A, MOVE_B)
        else
            local taught = Skill.get(move):teach(pal)
            local after  = readBack(h, character, pal, "after teach " .. move)
            h:value("Skill.get('" .. move .. "'):teach(pal)", tostring(taught))
            if taught and after and has(after.active, move) then
                h:pass("THE ACTIVE-MOVE WRITE LANDS. AddEquipWaza fired, the read-back sees %s on "
                    .. "a live PalMonsterCharacter, and the game is still running. That is the "
                    .. "fact plan/TODO.md 'Before publish' §1 has been waiting for.", move)
            elseif after then
                h:fail("the write did NOT land: %s is not in the read-back. The game did not "
                    .. "close, so this is authority or marshalling rather than the crash — read "
                    .. "the [signature] evidence level on the AddEquipWaza line above. "
                    .. "'declared' plus a false points at server authority "
                    .. "(core/character.lua's SERVER AUTHORITY note).", move)
            end

            local forgot = Skill.get(move):forget(pal)
            local cleaned = readBack(h, character, pal, "after forget " .. move)
            h:value("Skill.get('" .. move .. "'):forget(pal)", tostring(forgot))
            if cleaned and not has(cleaned.active, move) then
                h:pass(":forget took it back off — the pal is as it was found")
            else
                h:fail("⚠️ %s IS STILL ON THAT PAL. This hook could not undo its own write; the "
                    .. "save now differs from how it was found.", move)
            end
        end

        --------------------------------------------------------------------
        h:section("[3] Pal.Handle:teachAll — the `taught, asked` partial-result contract")
        --------------------------------------------------------------------
        -- Handle:teachAll (api/pal.lua:553) promises `taught, asked = pal:teachAll(actor)` so a partial result is
        -- visible instead of being flattened into a boolean. Nothing has ever exercised it.
        -- The definition is built with { register = false } (contract C2). If this build of
        -- api/pal.lua does not honour that yet the second argument is simply ignored, the id is
        -- namespaced palforge_test:* either way, and support.sweep() takes it back out below.
        local def = Pal({ id = support.id("teachall"), name = "teachAll probe",
                          skills = { MOVE_A, MOVE_B } }, { register = false })

        -- THE CONTROL FIRST, and it costs nothing: teachAll against no actor at all. addSkill
        -- finds no character parameters, writes nothing, and returns false for each id — so
        -- `asked` must still be 2. That proves the two return values are independent without
        -- touching the save.
        local t0, a0 = def:teachAll(nil)
        h:value("teachAll(nil) -> taught, asked", string.format("%s, %s", tostring(t0), tostring(a0)))
        if t0 == 0 and a0 == 2 then
            h:pass("the partial-result contract holds on the zero end: nothing landed, and "
                .. "`asked` still reports the 2 ids that were declared")
        else
            h:fail("teachAll(nil) answered %s, %s — expected 0, 2. `asked` is meant to be "
                .. "#skills whatever happens to the writes.", tostring(t0), tostring(a0))
        end

        local t1, a1 = def:teachAll(pal)
        h:value("teachAll(pal) -> taught, asked", string.format("%s, %s", tostring(t1), tostring(a1)))
        local afterAll = readBack(h, character, pal, "after teachAll")
        if t1 == a1 and a1 == 2 then
            h:pass("both declared moves landed on a live pal through the public api — a Pal "
                .. "definition's `skills` list really does reach a pal standing in the world")
        else
            h:note("%d of %d landed. That IS the partial result the contract exists to make "
                .. "visible; the read-back above says which one is missing.", t1 or -1, a1 or -1)
        end
        -- A GENUINE PARTIAL — 0 < taught < asked — is NOT produced here, and that is a refusal
        -- rather than an omission. The only way to force one is to declare an id the game does
        -- not have, which routes to AddPassiveSkill and writes a junk FName onto a character in
        -- the player's real save. This hook will not do that for the sake of a nicer number.
        h:note("no forced FAILURE case is included: making one write fail means asking for an id "
            .. "the game does not have, which core.character routes to AddPassiveSkill and writes "
            .. "as an FName into a real character. Refused deliberately.")

        -- take back exactly what [3] added
        for _, id in ipairs({ MOVE_A, MOVE_B }) do
            if afterAll and has(afterAll.active, id) and not has(before.active, id) then
                Skill.get(id):forget(pal)
            end
        end
        readBack(h, character, pal, "after undoing teachAll")

        --------------------------------------------------------------------
        h:section("[4] core.character.clearSkills — ClearEquipWaza, no caller, no check")
        --------------------------------------------------------------------
        local now = character.skillsOn(pal)
        local held = {}
        for _, id in ipairs((now and now.active) or {}) do held[#held + 1] = id end
        if #held == 0 then
            -- The safe case, and still a real measurement: the call is reachable and its
            -- read-back contract (#active == 0 afterwards) is exercised with nothing to lose.
            local ok = character.clearSkills(pal)
            h:value("clearSkills(pal) on a pal with no equipped moves", tostring(ok))
            if ok then
                h:pass("ClearEquipWaza is reachable and its read-back agrees. Nothing was lost — "
                    .. "the pal had no equipped move to begin with.")
            else
                h:fail("clearSkills returned false on a pal that already had zero active moves, "
                    .. "so either the call was refused (read the [signature] line) or the "
                    .. "read-back could not be taken.")
            end
        else
            h:warn("ABOUT TO REMOVE THIS PAL'S OWN MOVES: %s. They are re-added immediately "
                .. "afterwards and verified. If the game closes in between, they are gone for "
                .. "good — this is the step that needs a throwaway save.", table.concat(held, ", "))
            local ok = character.clearSkills(pal)
            local cleared = readBack(h, character, pal, "after clearSkills")
            h:value("clearSkills(pal)", tostring(ok))
            if ok and cleared and #cleared.active == 0 then
                h:pass("ClearEquipWaza WORKS: %d equipped move(s) went, and the read-back confirms "
                    .. "an empty active list", #held)
            else
                h:fail("clearSkills reported %s and the read-back shows %d active move(s) — the "
                    .. "call and its verification disagree", tostring(ok),
                    cleared and #cleared.active or -1)
            end

            local restored = 0
            for _, id in ipairs(held) do
                if character.addSkill(pal, id) then restored = restored + 1 end
            end
            local back = readBack(h, character, pal, "after restoring")
            if restored == #held then
                h:pass("all %d move(s) put back, each one verified by its own read-back", #held)
            else
                h:fail("⚠️ ONLY %d OF %d MOVES WERE RESTORED. That pal has permanently lost: %s. "
                    .. "This is the cost this block warned about, and it is a finding about "
                    .. "AddEquipWaza rather than about ClearEquipWaza.", restored, #held,
                    table.concat(held, ", "))
            end
            if back then
                h:value("moves the pal ended with", table.concat(back.active, ", "))
            end
        end

        --------------------------------------------------------------------
        h:section("[5] the state this hook leaves behind")
        --------------------------------------------------------------------
        local swept = support.sweep()
        h:value("throwaway definitions swept", swept)
        local final = readBack(h, character, pal, "FINAL")
        if final and before then
            local same = #final.active == #before.active
            for _, id in ipairs(before.active) do same = same and has(final.active, id) end
            if same then
                h:pass("the pal's equipped moves are exactly what they were before this hook ran")
            else
                h:fail("⚠️ the pal's equipped moves DIFFER from how they were found. Before: {%s}. "
                    .. "After: {%s}.", table.concat(before.active, ", "),
                    table.concat(final.active, ", "))
            end
        end
        h:note("IF PALWORLD IS STILL RUNNING AND BLOCK [2] PASSED, plan/TODO.md 'Before publish' "
            .. "§1 is settled and pal-skills-equip closes. If it is not running, the last line "
            .. "in this block before the log ends is the finding, and :teach / :forget / "
            .. ":teachAll ship disabled with that line quoted as the reason. Both outcomes are "
            .. "publishable; the present state is not.")
    end,
}
