-- test/hooks/audio-custom-file-loader — IS THERE ANY RUNTIME LOADER FOR A FILE ON DISK?
--
-- plan/TODO.md Open / Audio. Marked at core/sound/file.lua's TODO(audio-custom-file-loader) (:56 as this was written).
--
-- What a pack author sees today: `soundFile` is an accepted, validated, documented field that
-- takes PRECEDENCE over soundId/soundPath — and then plays nothing. Worse, setting it beside a
-- working soundId silences that too, because the file route wins.
--
-- The open question, verbatim from the marker:
--
--     it is unknown whether the shipping build exposes ANY runtime loader that turns a file on
--     disk into something playable (a USoundWave/USoundBase factory, or a Wwise external-source
--     / SetMedia entry point); enumerating the audio-related CDOs' reflected functions would
--     settle whether such a call exists at all.
--
-- ⚠️ A RUN OF NILS CLOSES THIS ITEM PERMANENTLY, AND THAT IS WHY EVERY NIL IS PRINTED. The
-- instinct in a probe is to skip what did not resolve and print what did; here the absences ARE
-- the measurement. "Six classes, all absent, no constructor, zero instances" is a complete,
-- final answer — `soundFile` then refuses at define time with this log block as the reason
-- (that refusal is "Before publish" §4) — whereas a block that quietly printed only the two
-- classes that resolved would look like a probe that had not finished.
--
-- The five numbered blocks below are the item's own "What the probe prints" paragraph,
-- implemented as written. Nothing here calls a UFunction: it resolves CDOs, walks reflection,
-- and counts instances. Read-only, one shot, nothing to do in game.
local hooks = require("palforge.test.hooks")

-- (1) The six classes, in the item's own order. Engine's sound classes first — if a USoundWave
-- can be constructed and played, the file route is an Engine problem. Then AkAudio's, because
-- Palworld's audio is Wwise: an external-source / media-asset entry point would be the route
-- that actually fits this game.
local CLASSES = {
    "/Script/Engine.Default__SoundWave",
    "/Script/Engine.Default__SoundBase",
    "/Script/Engine.Default__GameplayStatics",
    "/Script/AkAudio.Default__AkExternalMediaAsset",
    "/Script/AkAudio.Default__AkMediaAsset",
    "/Script/AkAudio.Default__AkGameplayStatics",
}

-- (3) The words a loader would have in its name. Deliberately broad: this is a search for
-- whether such a call EXISTS, not a lookup of one that is already known.
local WANTED = { "External", "Media", "Source", "Post", "Load" }

local function matches(name)
    for _, w in ipairs(WANTED) do if name:find(w, 1, true) then return true end end
    return false
end

hooks.declare{
    id    = "audio-custom-file-loader",
    item  = "Open / Audio",
    needs = { world = true },
    desc  = "does the shipping build expose ANY way to turn a .wav on disk into something "
         .. "playable — a run of nils closes the item for good",
    run = function(h)
        local probe = require("palforge.test.probe")

        --------------------------------------------------------------------
        h:section("[1] class existence — every one printed, resolved or not")
        --------------------------------------------------------------------
        -- ⚠️ FIRST, WHETHER THE QUESTION CAN BE ASKED AT ALL. "Six classes absent" and "this
        -- session has no StaticFindObject" produce identical nils and mean opposite things —
        -- one closes the item, the other says nothing was measured. This hook's whole value is
        -- that a run of nils is a VERDICT, so the one case where it is not has to be named.
        local canAsk = type(StaticFindObject) == "function"
        h:value("type(StaticFindObject)", type(StaticFindObject))
        if not canAsk then
            h:fail("StaticFindObject is unavailable in this session, so every nil below is the "
                .. "absence of a LOOKUP and not the absence of a class. NOTHING is closed by "
                .. "this run.")
        end

        local resolved = {}
        for _, path in ipairs(CLASSES) do
            local o
            pcall(function() o = StaticFindObject(path) end)
            local live = probe.valid(o)
            h:value(path, live and probe.full(o) or "nil — ABSENT on this build")
            if live then resolved[path] = o end
        end
        local n = 0
        for _ in pairs(resolved) do n = n + 1 end
        if n == 0 and canAsk then
            h:pass("NONE of the six resolved, and the lookup itself works. That is a complete "
                .. "answer and it closes this item: there is no sound-loading surface of any "
                .. "kind to call, so Audio.Spec.soundFile must refuse at define time rather than "
                .. "accept and silence.")
        end

        --------------------------------------------------------------------
        h:section("[2] GameplayStatics' COMPLETE function list")
        --------------------------------------------------------------------
        -- Looking for PlaySound2D / CreateSound2D / SpawnSoundAttached surviving into shipping.
        -- The complete list is printed rather than a filtered one: a name nobody thought to
        -- grep for is exactly what this block exists to find.
        local gs = resolved["/Script/Engine.Default__GameplayStatics"]
        if not gs then
            h:value("GameplayStatics functions", "not enumerated — the CDO is absent (block [1])")
        else
            local cls; pcall(function() cls = gs:GetClass() end)
            local names = probe.functions(cls, "GameplayStatics")
            local interesting = {}
            for _, name in ipairs(names) do
                if name:find("Sound", 1, true) or name:find("Audio", 1, true) then
                    interesting[#interesting + 1] = name
                end
            end
            h:value("GameplayStatics functions", #names)
            h:value("...with Sound or Audio in the name",
                #interesting > 0 and table.concat(interesting, ", ") or "NONE")
            if #interesting == 0 and #names > 0 then
                h:note("the CDO enumerates %d functions and not one of them mentions sound. "
                    .. "Engine's Blueprint audio surface is stripped from this build.", #names)
            end
        end

        --------------------------------------------------------------------
        h:section("[3] the AkAudio walk — every External / Media / Source / Post / Load function")
        --------------------------------------------------------------------
        local akSeen = 0
        for _, path in ipairs(CLASSES) do
            if path:find("AkAudio", 1, true) then
                local o = resolved[path]
                if not o then
                    h:value(path .. " walk", "skipped — the CDO is absent (block [1])")
                else
                    local cls; pcall(function() cls = o:GetClass() end)
                    local names = probe.functions(cls, path)
                    local hits = {}
                    for _, name in ipairs(names) do if matches(name) then hits[#hits + 1] = name end end
                    h:value(path, string.format("%d function(s), %d matching %s",
                        #names, #hits, table.concat(WANTED, "/")))
                    for _, name in ipairs(hits) do
                        akSeen = akSeen + 1
                        -- The PARAMETER LIST is the point. "A function called SetMedia exists" is
                        -- not usable; "SetMedia(AkExternalMediaAsset*, FName)" is, and a wrong
                        -- guess at an argument type is what faults natively.
                        probe.params(cls, name)
                    end
                end
            end
        end
        if akSeen == 0 then
            h:note("no AkAudio function on any resolved class carries any of the five words. If "
                .. "block [1] resolved an AkAudio class at all, that is a stronger negative than "
                .. "an absent class: the module is present and has no such entry point.")
        else
            h:note("%d candidate(s) printed above WITH THEIR PARAMETER LISTS. A route only counts "
                .. "if its arguments are things this tree can marshal — an object pointer, an "
                .. "FName, a scalar. A STRUCT parameter is not callable from here "
                .. "(core/signature refuses one on an unread declaration) and rules the "
                .. "candidate out however promising its name is.", akSeen)
        end

        --------------------------------------------------------------------
        h:section("[4] construction: can UE4SS Lua make a UObject at all on this build")
        --------------------------------------------------------------------
        -- Even a perfect factory function is unreachable if nothing here can construct the
        -- object to hand it. Three names, printed whatever they are.
        for _, name in ipairs({ "NewObject", "StaticConstructObject", "StaticConstructObject_Internal" }) do
            h:value("type(_G." .. name .. ")", type(_G[name]))
        end
        if type(NewObject) ~= "function" and type(StaticConstructObject) ~= "function"
            and type(StaticConstructObject_Internal) ~= "function" then
            h:pass("UE4SS Lua cannot construct a UObject in this session, so a USoundWave cannot "
                .. "be made here even if a loader existed. Half the item closes on this line "
                .. "alone — and unlike block [1] this one needs no engine at all to be true, "
                .. "because it is a question about the Lua environment UE4SS provides.")
        end

        --------------------------------------------------------------------
        h:section("[5] is the pipeline alive at all — instance counts")
        --------------------------------------------------------------------
        -- Whether the shipping game has any instance of either class LOADED is itself the
        -- answer about whether that pipeline is alive. A build that plays all its audio through
        -- Wwise banks has no USoundWave anywhere.
        for _, className in ipairs({ "SoundWave", "SoundBase", "AkMediaAsset", "AkExternalMediaAsset" }) do
            local list
            pcall(function() list = FindAllOf(className) end)
            local count = 0
            if type(list) == "table" then pcall(function() count = #list end) end
            h:value("#FindAllOf('" .. className .. "')",
                type(list) == "table" and count or "nil — FindAllOf answered nothing for this class")
            if type(list) == "table" and count > 0 then
                local first = list[1]
                h:value("  first instance", probe.valid(first) and probe.full(first) or "unreadable")
            end
        end

        --------------------------------------------------------------------
        h:section("verdict")
        --------------------------------------------------------------------
        h:note("HOW TO READ THIS BLOCK. (a) every line nil / ABSENT / 0 -> the item CLOSES: no "
            .. "runtime file loader exists on this build, and Audio.Spec.soundFile must refuse "
            .. "at define time naming this measurement, which is what 'Before publish' §4 asks "
            .. "for. (b) a function survived with a marshallable parameter list -> the item stays "
            .. "open and that signature is the implementation. (c) classes present but no "
            .. "constructor -> also a close, for the different reason printed in block [4].")
    end,
}
