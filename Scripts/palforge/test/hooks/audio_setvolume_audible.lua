-- test/hooks/audio-setvolume-audible — setVolume HAS BEEN HEARD ONCE, HEDGED. THE QUESTION LEFT
-- IS WHETHER 0.00 IS SILENT.
--
-- WHAT "CLOSED ON THE DECLARATION" MEANS, and why that is not the same as working. The native
-- call is `UAkGameplayStatics::SetOutputBusVolume(float BusVolume, AActor* Actor)`
-- (dumps/cxx/AkAudio.hpp:748), the Blueprint wrapper for Wwise's SetGameObjectOutputBusVolume.
-- core/signature checked the live build's declaration against that and let the call through, and
-- the call did not raise. That eliminates "PalForge called the wrong thing" and eliminates
-- nothing else.
--
-- ⚠️ RUN ONCE ALREADY, on 2026-08-02 at 21:39. All four steps below issued, `setVolume` and
-- `play` both true on every one, unity restored. Asked whether steps 2 and 3 were quieter, the
-- operator answered — hedged — that they seemed to be. THE DIRECTION MATCHED THE PREDICTION, and
-- that is why this hook is not simply repeated: what one hedged "seemed quieter" cannot separate
-- is a bus volume that WORKS from one that merely wobbles. The discriminating step is number 3,
-- at 0.00, and the question for the listener is SILENCE — not "was it quieter". A sound that is
-- still faintly audible at 0.00 and a sound that is gone are different findings.
--
-- There is no engine read that can answer this — Wwise's mixer state is not reflected — so the
-- operator IS the instrument, and the verdict this hook prints is a form for them to fill in
-- rather than a judgement it makes for them.
--
-- ⚠️ WHAT IT MOVES, AND WHAT IT PUTS BACK. SetOutputBusVolume scales what ONE emitter — the
-- player actor's Wwise game object — sends to its output bus. It is ACTOR-WIDE: it moves every
-- sound playing on your character, PalForge's and the game's alike, and WHICH sound handle it
-- was called on is ignored (:stop has the same scope, for the same reason). This hook always
-- ends by writing 1.0, which is unity, and it writes 1.0 again from the poll even if a step in
-- between failed. It does not touch your settings, your save, or the game's own volume options.
--
-- It is NOT declared `writes = true`: nothing it changes survives the session or reaches a file.
-- That is a deliberate line — `writes` means "a save is mutated", not "something is audible".
local hooks = require("palforge.test.hooks")

-- The same SE four times, and it is deliberately a SHORT, LOUD, unambiguous one: a BGM would
-- have to be started and stopped and would fight the game's own music, and a quiet sound cannot
-- be told from a muted one. AKE_General_Explosion is curated in native/audio.lua and its play
-- route is CONFIRMED in-game (LoadAsset -> PlayAkEventSoundByActor).
local SOUND = "Explosion"
local STEPS = {
    { at = 0,  volume = 1.00, expect = "NORMAL — this is the reference. Remember how loud it is." },
    { at = 8,  volume = 0.25, expect = "MUCH QUIETER than the first one" },
    { at = 16, volume = 0.00, expect = "SILENT, or as near as makes no difference" },
    { at = 24, volume = 1.00, expect = "NORMAL again — the volume is restored" },
}

hooks.declare{
    id    = "audio-setvolume-audible",
    item  = "Open (1) — the one item nothing has settled",
    needs = { world = true, player = true },
    desc  = "play one sound at four output-bus volumes so a person can say whether setVolume "
         .. "does anything audible",
    run = function(h)
        local audio   = require("palforge.native.audio")
        local support = require("palforge.test.support")
        local poll    = require("palforge.core.poll")

        local pawn = support.player()
        if not pawn then
            h:fail("the player pawn that satisfied the gate is gone; nothing was played.")
            return
        end
        local sound = audio[SOUND]
        if not sound then
            h:fail("native.audio.%s did not resolve, so there is nothing to play. The curated "
                .. "helpers are at the bottom of native/audio.lua.", SOUND)
            return
        end

        h:warn("this moves YOUR CHARACTER'S OUTPUT BUS VOLUME, which affects every sound on that "
            .. "actor including the game's own, and it writes 1.0 back at the end. Turn your "
            .. "speakers up rather than down for this one.")

        --------------------------------------------------------------------
        h:section("[1] does the sound play at all")
        --------------------------------------------------------------------
        -- If :play is false, everything after it is meaningless — you cannot hear a volume
        -- change on a sound that never started, and that failure would look exactly like
        -- setVolume working perfectly.
        local played = sound:play(pawn)
        h:value("native.audio." .. SOUND .. ":play(pawn)", tostring(played))
        if not played then
            h:fail("the sound did not play, so NOTHING about setVolume can be measured in this "
                .. "run. That is a finding about the play route, not about the volume route — "
                .. "read the [sound] line above it.")
            return
        end
        h:pass("a native play call was issued; if you heard nothing at all, the finding is about "
            .. "PlayAkEventSoundByActor rather than about setVolume")

        --------------------------------------------------------------------
        h:section("[2] four volumes, eight seconds apart")
        --------------------------------------------------------------------
        h:ask("LISTEN, AND THE QUESTION IS STEP 3. The same explosion plays four times, 8 s apart, "
            .. "at bus volume 1.0, 0.25, 0.0 and 1.0. A previous run already answered 'quieter, I "
            .. "think'. What is needed this time: was the THIRD one SILENT, or just quiet?")
        for i, s in ipairs(STEPS) do
            h:note("step %d at t+%ds: volume %.2f — %s", i, s.at, s.volume, s.expect)
        end
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN audio-setvolume-audible-step-N and -verdict below.")

        local step, results = 1, {}
        poll.every("audio-setvolume-audible", function(elapsed)
            if step <= #STEPS and elapsed >= STEPS[step].at then
                local s = STEPS[step]
                step = step + 1
                h:beginBlock("step-" .. (step - 1))
                local okVol = sound:setVolume(s.volume, pawn)
                local okPlay = sound:play(pawn)
                results[#results + 1] = { volume = s.volume, vol = okVol, play = okPlay }
                h:log("VALUE setVolume(%.2f) -> %s | play -> %s | you should hear: %s",
                    s.volume, tostring(okVol), tostring(okPlay), s.expect)
                support.announce(string.format("audio-setvolume: volume %.2f — %s",
                    s.volume, s.expect))
                h:endBlock("step-" .. (step - 1))
                return false
            end
            if step <= #STEPS then return false end

            h:beginBlock("verdict")
            -- BELT AND BRACES: unity again, whatever the last step did. A hook that leaves a
            -- player's audio at 0.0 because its own last call failed is a hook that broke the
            -- game for someone who was helping.
            local restored = sound:setVolume(1.0, pawn)
            h:log("VALUE final setVolume(1.0) -> %s (unity; your audio is as it was)",
                tostring(restored))
            for i, r in ipairs(results) do
                h:log("VALUE step %d  volume=%.2f  setVolume=%s  play=%s",
                    i, r.volume, tostring(r.vol), tostring(r.play))
            end
            h:log("NOTE THE ANSWER IS NOT IN THIS LOG. Every `true` above means the native call "
                .. "was ISSUED and core/signature let it through. What is owed is one of these:")
            h:log("NOTE   (1) step 3 was SILENT (not merely quiet) -> audio-setvolume-audible "
                .. "CLOSES, and Handle:setVolume's doc string in api/audio.lua — which currently "
                .. "records one hedged report and says the 0.00 case is unestablished — must be "
                .. "rewritten to say the parameter is confirmed. 'Quieter, I think' is what the "
                .. "run of 2026-08-02 already produced and is NOT this answer.")
            h:log("NOTE   (2) all four sounded identical, with true on every line -> the call "
                .. "runs and does nothing. That is the same shape as the two cheat-manager calls "
                .. "in 'What the first F1 run already settled' (SpawnMonster and GetItem both ran "
                .. "with the declaration matching and changed nothing), and it would make "
                .. "setVolume a THIRD instance of that pattern rather than a one-off.")
            h:log("NOTE   (3) setVolume returned false -> the live declaration disagreed with "
                .. "AkAudio.hpp:748 and the [signature] line above names how.")
            h:endBlock("verdict")
            return true
        end)
    end,
}
