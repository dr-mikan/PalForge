-- test/hooks/skill-hit-source — CONFIRM THE NEGATIVE, SO THE ITEM CAN CLOSE.
--
-- plan/TODO.md Open / Skill. Marked at api/skill.lua's TODO(skill-hit-source) (:118 as this was written).
--
-- THIS HOOK IS NOT LOOKING FOR A SOURCE. It exists to make an item that has been open forever
-- CLOSABLE, by turning "we never found one" into "there is not one, and here is the evidence".
-- The two candidates are already ruled out and are not re-litigated:
--
--   MakeDamageInfoByWazaType                     armed, measured SILENT while a pal fought and
--                                                killed another pal (core/event.lua's skill
--                                                source block records the session).
--   PalAnimNotifyState_AttackCollision:OnHit     armed, measured SILENT in that same session,
--                                                and silent again in a session where the player
--                                                killed a pal by hand.
--
-- pal.damaged and pal.death both carried in those sessions, so a blow certainly connected and
-- certainly did damage. A hit does not reach either hook, from either side.
--
-- AND WHAT IS LEFT IS NOT ANOTHER HOOK. Nothing in the damage path carries a waza at all:
-- FPalDamageInfo has 40 fields, FPalDamageRactionInfo 6, FPalDamageResult 12, and not one is an
-- EPalWazaID — the closest are `EPalWazaCategory Category`, a Melee/Shot bucket rather than an
-- identity, and `FName AttackStaticItemID`, which is the weapon. Block [1] below reads those
-- three structs OUT OF THE RUNNING BUILD rather than out of a header, because that is the
-- difference between "the dump we have says no" and "this build says no".
--
-- ⚠️ AND THE ONE THING THIS HOOK MUST NOT DO. The id could reach a hit by being REMEMBERED from
-- the activation that preceded it and attributed to the damage that follows. That is inference,
-- not a source, and wiring it would be wrong: a move that misses, a second pal attacking in the
-- same window, or damage from anything else would all be attributed to whatever activated last.
-- Block [3] MEASURES exactly how often that ambiguity occurs in real combat — how many
-- activations sit in the window before each damage event — so the refusal is quantified instead
-- of asserted. Nothing here writes a correlation into onHit, and if such a thing is ever built
-- it belongs behind a name that says so, never on `onHit`, which promises the game told us.
--
-- Read-only, and it arms nothing: the two candidate hooks and the two channels it listens to are
-- already installed by core/event, so this subscribes to the bus and reflects structs.
local hooks = require("palforge.test.hooks")

-- The three damage structs the item names, plus the projectile class, which is the one path the
-- collision hook could never have covered anyway (APalBullet carries OwnerStaticItemId and no
-- waza). Spelled as /Script paths: a UScriptStruct drops the F prefix.
local STRUCTS = {
    "/Script/Pal.PalDamageInfo",
    "/Script/Pal.PalDamageRactionInfo",   -- the game's own spelling; not a typo here
    "/Script/Pal.PalDamageResult",
}
local WATCH_S = 120

local function state()
    local s = _G.__PalForgeSkillHitHook
    if type(s) ~= "table" then
        s = { subscribed = false, hits = 0, damages = 0, activates = 0, recent = {}, gaps = {} }
        _G.__PalForgeSkillHitHook = s
    end
    return s
end

hooks.declare{
    id    = "skill-hit-source",
    item  = "Open / Skill",
    needs = { world = true },
    desc  = "confirm that nothing in the damage path carries a waza id, and quantify why "
         .. "correlating activation with damage would be wrong",
    run = function(h)
        local probe = require("palforge.test.probe")
        local event = require("palforge.core.event")
        local poll  = require("palforge.core.poll")
        local st    = state()

        --------------------------------------------------------------------
        h:section("[1] what the damage path carries, read off THIS build")
        --------------------------------------------------------------------
        -- Whether the question can be asked at all, before any of its answers are read: an
        -- absent struct and an absent StaticFindObject look identical and mean opposite things.
        local canAsk = type(StaticFindObject) == "function"
        h:value("type(StaticFindObject)", type(StaticFindObject))
        local found = 0

        local wazaFields = 0
        for _, path in ipairs(STRUCTS) do
            local s
            pcall(function() s = StaticFindObject(path) end)
            if not probe.valid(s) then
                h:value(path, "absent — this build does not expose the struct by that name")
            else
                found = found + 1
                h:value(path, probe.full(s))
                local rows = probe.properties(s, path)
                for _, r in ipairs(rows) do
                    -- An EnumProperty called Waza-anything is the only thing that would reopen
                    -- this item. Name it loudly if it is there.
                    if tostring(r.name):find("Waza", 1, true) then
                        wazaFields = wazaFields + 1
                        h:value("⚠️ WAZA-ISH FIELD on " .. path,
                            string.format("%s : %s", tostring(r.name), tostring(r.kind)))
                    end
                end
                h:value(path .. " field count", #rows)
            end
        end
        if not canAsk or found == 0 then
            h:fail("none of the three structs could be read (%s), so block [1] measured NOTHING. "
                .. "A zero waza-field count below would be the absence of a read rather than the "
                .. "absence of a field.",
                canAsk and "they are absent by those names" or "StaticFindObject is unavailable")
        elseif wazaFields == 0 then
            h:pass("NOT ONE FIELD in the %d damage struct(s) this build declares names a waza. "
                .. "The victim side cannot answer 'which skill' at any depth of struct walking. "
                .. "That is the negative confirmed against the running binary rather than "
                .. "against a header dump.", found)
        else
            h:fail("%d waza-ish field(s) were found above. THAT REOPENS THE ITEM: read the kind "
                .. "printed beside each — an EnumProperty is an identity and a ByteProperty "
                .. "called WazaCategory is still only a Melee/Shot bucket.", wazaFields)
        end
        -- The projectile path, for completeness: a ranged pal move lands through APalBullet and
        -- never through the collision notify, so a hit source that only covered melee would have
        -- been incomplete even if it had fired.
        local bullet
        pcall(function() bullet = StaticFindObject("/Script/Pal.PalBullet") end)
        h:value("/Script/Pal.PalBullet", probe.valid(bullet) and probe.full(bullet) or "absent")
        if probe.valid(bullet) then
            local cls; pcall(function() cls = bullet:GetClass() end)
            probe.properties(probe.valid(cls) and cls or bullet, "PalBullet")
        end

        --------------------------------------------------------------------
        h:section("[2] listening to the three channels while you fight")
        --------------------------------------------------------------------
        if st.subscribed then
            h:note("an earlier run is already subscribed; its counters keep running.")
        else
            st.subscribed = true
            event.on("skill.activate", function(ctx)
                local s = state()
                s.activates = s.activates + 1
                s.recent[#s.recent + 1] = { at = os.clock(), id = tostring(ctx and ctx.id or "?") }
                if #s.recent > 64 then table.remove(s.recent, 1) end
            end)
            event.on("skill.hit", function(ctx)
                local s = state()
                s.hits = s.hits + 1
                h:log("FIRED skill.hit via=%s id=%s — ⚠️ THIS FALSIFIES THE ITEM'S PREMISE and is "
                    .. "the single most valuable line this hook can print",
                    tostring(ctx and ctx.via or "?"), tostring(ctx and ctx.id or "?"))
            end)
            event.on("pal.damaged", function()
                local s = state()
                s.damages = s.damages + 1
                -- HOW AMBIGUOUS WOULD A GUESS HAVE BEEN? Count the activations inside the
                -- window a correlator would have looked back over. Two or more means the guess
                -- had to pick, and picking is what makes it a guess.
                local now, inWindow = os.clock(), 0
                for _, a in ipairs(s.recent) do
                    if (now - a.at) <= 1.0 then inWindow = inWindow + 1 end
                end
                s.gaps[#s.gaps + 1] = inWindow
            end)
            h:pass("subscribed to skill.activate, skill.hit and pal.damaged. Nothing new was "
                .. "armed — core/event already holds both skill.hit candidates, and adding a "
                .. "third unremovable hook to re-observe a measured silence would cost the "
                .. "session something for nothing.")
        end

        h:ask("FIGHT SOMETHING for the next %d s — hit a pal with a melee weapon, and let a pal "
            .. "of yours attack one too. Both sides matter: the two silent hooks fail on "
            .. "different sides.", WATCH_S)
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN skill-hit-source-verdict below.")

        local base = { hits = st.hits, damages = st.damages, activates = st.activates, gaps = #st.gaps }
        poll.every("skill-hit-source", function(elapsed)
            if elapsed < WATCH_S then return false end
            local s = state()
            h:beginBlock("verdict")
            local hits = s.hits - base.hits
            local dmg  = s.damages - base.damages
            local act  = s.activates - base.activates
            h:log("VALUE skill.hit firings      = %d", hits)
            h:log("VALUE pal.damaged firings    = %d", dmg)
            h:log("VALUE skill.activate firings = %d", act)

            --------------------------------------------------------------
            -- [3] the ambiguity, quantified
            --------------------------------------------------------------
            local ambiguous, none = 0, 0
            for i = base.gaps + 1, #s.gaps do
                if s.gaps[i] == 0 then none = none + 1 elseif s.gaps[i] > 1 then ambiguous = ambiguous + 1 end
            end
            h:log("VALUE damage events with NO activation in the preceding second   = %d", none)
            h:log("VALUE damage events with MORE THAN ONE activation in that second = %d", ambiguous)
            h:log("NOTE those two numbers are the case against correlating. The first is damage a "
                .. "correlator would have attributed to a move that had already finished; the "
                .. "second is damage it would have had to guess between. Neither is rare in real "
                .. "combat, and neither is visible to a pack author who was told the game said so.")

            if hits > 0 then
                h:log("FAIL — in the good sense: skill.hit DID fire %d time(s). The item is NOT a "
                    .. "closed negative and one of the two armed candidates reaches this build "
                    .. "after all. The FIRED lines above name the source.", hits)
            elseif dmg == 0 then
                h:log("NOTE nothing was damaged in %d s, so nothing was measured. This is not a "
                    .. "result: fight something and run it again.", WATCH_S)
            else
                h:log("PASS CONFIRMED NEGATIVE. %d damage event(s) and %d activation(s) landed and "
                    .. "skill.hit carried nothing, on a build whose damage structs declare no "
                    .. "waza field (block [1]). `skill-hit-source` closes as NO SOURCE EXISTS: "
                    .. "api/skill.lua's onHit doc must say the game does not report which move "
                    .. "did the damage, and the TODO marker comes out. It does not become a "
                    .. "correlated guess.", dmg, act)
            end
            h:endBlock("verdict")
            return true
        end)
    end,
}
