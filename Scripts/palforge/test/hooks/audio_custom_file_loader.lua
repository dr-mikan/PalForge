-- test/hooks/audio-custom-file-loader — A TRIPWIRE, NOT A SEARCH.
--
-- ⚠️ THIS ITEM IS CLOSED. It closed NEGATIVELY on 2026-08-02: a pack cannot ship a `.wav` on this
-- build, `Audio.Spec.soundFile` is a hard error at define time, and core/sound/file.lua carries
-- the full reading of both halves. This hook no longer asks whether a loader exists. It exists to
-- notice if the answer ever CHANGES — which, on a game that updates, is a different job with a
-- different shape.
--
-- WHAT THE OLD HOOK WAS AND WHY IT IS GONE. It was written expecting "a run of nils closes this
-- permanently", so it printed six class lookups, GameplayStatics' complete function list, every
-- AkAudio function matching five words with its parameter list, three constructor names and four
-- instance counts. That was the right instrument for an open question and it did its job on
-- 2026-08-02. It was NOT nils:
--
--   AkExternalMediaAsset  = 0 function(s)   FindAllOf -> nothing      <- the Wwise half, dead
--   AkMediaAsset          = 0 function(s)   FindAllOf -> nothing      <- the Wwise half, dead
--   GameplayStatics       = 137 functions, PlaySound2D and friends all present
--   FindAllOf('SoundWave') = 6   FindAllOf('SoundBase') = 8           (SkyCreatorPlugin's rain)
--   type(StaticConstructObject) = function                            (NewObject = nil)
--
-- so the item narrowed rather than closing, to exactly one question: can a USoundWave be
-- constructed here and its PCM buffer filled from a file? That question was then answered WITHOUT
-- the game, off dumps/cxx, and the answer is no — see core/sound/file.lua. Re-running the old
-- block would print those 137 names again and settle nothing, which is the specific failure this
-- rewrite is against: a probe that keeps measuring a question that has an answer.
--
-- WHAT IS LEFT, AND IT IS THREE LINES. The refusal in api/audio.lua rests on three facts about
-- this build. Each is cheap to re-check and each, if it ever flipped, would reopen the item and
-- point straight at the implementation:
--
--   [1] USoundWave exposes no writable audio buffer. Its whole reflected chain is 51 metadata
--       properties (Engine.hpp:21336-21366 plus USoundBase :21003-:21027) and the samples live in
--       members that are not UPROPERTYs. If a byte-array property ever appears on that class,
--       THAT IS THE ROUTE and the item reopens.
--   [2] This build ships a runtime file importer for TEXTURES and none for sound —
--       ImportFileAsTexture2D / ImportBufferAsTexture2D (Engine.hpp:14694-14695) are the only
--       Import*As* in the entire dump. An ImportFileAsSoundWave appearing anywhere is the route.
--   [3] The Wwise media classes are absent. If AkExternalMediaAsset or AkMediaAsset ever resolves
--       with functions on it, the SetMedia route is back.
--
-- A PASS HERE MEANS "the closure still holds". A FAIL means the build changed under us and
-- core/sound/file.lua plus api/audio.lua's refuseSoundFile are what to rewrite. It prints one
-- line per fact and nothing else.
--
-- NEEDS NOTHING, deliberately. The old hook declared `needs = { world = true }` because it
-- counted live instances; a tripwire reads CDOs and reflection, which are process-global, so this
-- one answers at the title screen, during a load, and in a session where nothing else in this
-- directory can run. A tripwire you have to load a save to trip is a tripwire nobody trips.
local hooks = require("palforge.test.hooks")

-- Property names that would mean "somewhere to put samples". Deliberately broad — this is not a
-- lookup of a name we expect, it is a watch for one we do not.
local BUFFER_WORDS = { "Raw", "PCM", "Compressed", "Buffer", "Bulk", "Chunk", "Sample" }

-- ⚠️ THE FOUR PROPERTIES THAT ALREADY MATCH THOSE WORDS AND ARE NOT BUFFERS. Every one is an
-- ordinary cooked-metadata field measured on the 2026-08-02 build — `Sample` catches SampleRate
-- (int32, Engine.hpp:21360), SampleRateQuality (an enum, :21339) and USoundBase's TotalSamples
-- (a float, :21017); `Chunk` catches InitialChunkSize (int32, :21353). Without this list the
-- broad word set fires on EVERY run, and a tripwire that is always tripped is strictly worse than
-- no tripwire: the one time it means something, nobody looks. So the words stay broad and the
-- four known names are subtracted by name, which also means adding a fifth is a deliberate act
-- someone has to justify rather than a threshold quietly raised.
local KNOWN_METADATA = {
    SampleRate = true, SampleRateQuality = true, TotalSamples = true, InitialChunkSize = true,
}

-- The classes worth asking for an importer. The first is where the TEXTURE importer actually
-- lives on this build, so it is the one that proves the walk works at all.
local IMPORT_HOSTS = {
    "/Script/Engine.Default__KismetRenderingLibrary",
    "/Script/Engine.Default__GameplayStatics",
    "/Script/AudioMixer.Default__AudioMixerBlueprintLibrary",
}

local function find(path)
    local o; pcall(function() o = StaticFindObject(path) end)
    return o
end

-- A class's reflected member names, collected SILENTLY. probe.functions/probe.properties print
-- every name they see, which is exactly the 137-line noise this rewrite removes. A name that
-- will not read back is still COUNTED (as probe.name's "?"), because a member that exists and
-- cannot be named is not a member that is absent.
local function members(probe, cls, each)
    local out = {}
    if not probe.valid(cls) then return out end
    pcall(function()
        cls[each](cls, function(m) out[#out + 1] = probe.name(m) end)
    end)
    return out
end

-- Walk `cls` and its supers, collecting property names. USoundWave's buffer would be on
-- USoundWave itself, but ForEachProperty does not climb, and the claim being defended is about
-- the whole chain a constructed object would expose.
local function chainProperties(probe, cls)
    local names, k, depth = {}, cls, 0
    while probe.valid(k) and depth < 6 do
        for _, n in ipairs(members(probe, k, "ForEachProperty")) do names[#names + 1] = n end
        local parent; pcall(function() parent = k:GetSuperStruct() end)
        if not probe.valid(parent) then pcall(function() parent = k.SuperStruct end) end
        k, depth = parent, depth + 1
    end
    return names
end

local function looksLikeBuffer(name)
    if KNOWN_METADATA[name] then return false end
    for _, w in ipairs(BUFFER_WORDS) do if name:find(w, 1, true) then return true end end
    return false
end

hooks.declare{
    id    = "audio-custom-file-loader",
    item  = "Closed 2026-08-02 (negative) — kept as a regression tripwire",
    desc  = "the item is CLOSED: a .wav cannot be played on this build. This re-checks the three "
         .. "facts the refusal rests on, in three lines, and fails only if one of them changed",
    run = function(h)
        local probe = require("palforge.test.probe")

        h:note("audio-custom-file-loader CLOSED NEGATIVELY on 2026-08-02 (see core/sound/file.lua). "
            .. "Nothing below is an open question; each line is a fact the closure rests on. "
            .. "PASS = the closure still holds.")

        -- WHETHER THE QUESTION CAN BE ASKED AT ALL. "The class has no buffer" and "this session
        -- cannot look a class up" produce identical answers and mean opposite things, so the one
        -- case where a negative is not a result has to be named before any negative is printed.
        if type(StaticFindObject) ~= "function" then
            h:warn("StaticFindObject is unavailable in this session, so nothing below could be "
                .. "asked. This run measured NOTHING — it neither confirms nor disturbs the "
                .. "closure.")
            return
        end

        --------------------------------------------------------------------
        h:section("[1] does USoundWave expose anywhere to put samples")
        --------------------------------------------------------------------
        local wave = find("/Script/Engine.Default__SoundWave")
        if not probe.valid(wave) then
            -- Not a reopening and not a confirmation: on 2026-08-02 this CDO resolved and 6 live
            -- SoundWaves were in the process, so its absence now is a fact about the session
            -- (module not loaded yet), not about the class.
            h:warn("the SoundWave CDO did not resolve this session, so the property walk was not "
                .. "done. It resolved on 2026-08-02; this is a session state, not a change.")
        else
            local cls; pcall(function() cls = wave:GetClass() end)
            local props = chainProperties(probe, cls)
            local hits = {}
            for _, n in ipairs(props) do if looksLikeBuffer(n) then hits[#hits + 1] = n end end
            h:value("USoundWave chain properties", #props)
            if #props == 0 then
                h:warn("ForEachProperty answered nothing on this build's USoundWave, so the walk "
                    .. "itself failed. Zero properties is not the same as zero buffers, and it is "
                    .. "not read as a confirmation.")
            elseif #hits == 0 then
                h:pass("no property on the USoundWave chain is named like a sample buffer, once "
                    .. "the four known metadata names are subtracted. The dump says the same (29 "
                    .. "own + 22 inherited, all cooked metadata), so a USoundWave constructed "
                    .. "from Lua would be one that can never be filled.")
            else
                -- THE TRIPWIRE. A name alone is not the route — it has to be an array of bytes
                -- that Lua can write — but it would be the first thing that has ever looked like
                -- one, and it is worth a human reading the property's type.
                h:value("...named like a buffer, and NOT known metadata", table.concat(hits, ", "))
                h:fail("a USoundWave property is named like a sample buffer and is not one of the "
                    .. "four this build already had, which is the ONE thing that reopens "
                    .. "audio-custom-file-loader. Read its type: if it is a writable byte array, "
                    .. "core/sound/file.lua and api/audio.lua's refuseSoundFile are what to "
                    .. "rewrite.")
            end
        end

        --------------------------------------------------------------------
        h:section("[2] is there a runtime importer for sound, as there is for textures")
        --------------------------------------------------------------------
        -- The texture importer is the control. If this block finds ImportFileAsTexture2D it has
        -- proved the walk works, which is what makes "and no sound equivalent" a measurement
        -- rather than a walk that quietly found nothing anywhere.
        local sawTexture, soundImporters = false, {}
        for _, path in ipairs(IMPORT_HOSTS) do
            local cdo = find(path)
            local cls; if probe.valid(cdo) then pcall(function() cls = cdo:GetClass() end) end
            for _, n in ipairs(members(probe, cls, "ForEachFunction")) do
                if n:find("Import", 1, true) then
                    if n:find("Texture", 1, true) then sawTexture = true end
                    if n:find("Sound", 1, true) or n:find("Wave", 1, true)
                        or n:find("Audio", 1, true) then
                        soundImporters[#soundImporters + 1] = path .. ":" .. n
                    end
                end
            end
        end
        h:value("Import*AsTexture* found (the control)", tostring(sawTexture))
        h:value("Import* naming Sound / Wave / Audio",
            #soundImporters > 0 and table.concat(soundImporters, ", ") or "NONE")
        if #soundImporters > 0 then
            h:fail("an audio importer exists on this build. That is the second thing that reopens "
                .. "this item: read its parameter list and, if it takes an FString filename or a "
                .. "byte array, FileSource:play can finally be written.")
        elseif sawTexture then
            h:pass("the walk works — it found the texture importer — and there is no audio "
                .. "counterpart. The build ships runtime file import for images and not for "
                .. "sound, which is the finding, not a failed search.")
        else
            h:warn("neither a texture nor an audio importer was seen, so this block proved "
                .. "nothing: without the control there is no way to tell an absent function from "
                .. "an absent walk. Not read as a confirmation.")
        end

        --------------------------------------------------------------------
        h:section("[3] have the Wwise media classes come back")
        --------------------------------------------------------------------
        -- Measured 0 functions each, and FindAllOf answering nothing, on 2026-08-02.
        local backFromTheDead = {}
        for _, name in ipairs({ "AkExternalMediaAsset", "AkMediaAsset" }) do
            local cdo = find("/Script/AkAudio.Default__" .. name)
            local cls; if probe.valid(cdo) then pcall(function() cls = cdo:GetClass() end) end
            local n = #members(probe, cls, "ForEachFunction")
            h:value(name, probe.valid(cdo) and (n .. " function(s)") or "absent, as measured")
            if n > 0 then backFromTheDead[#backFromTheDead + 1] = name end
        end
        if #backFromTheDead == 0 then
            h:pass("the Wwise external-media route is still absent — the same answer as "
                .. "2026-08-02, when both CDOs declared 0 functions and FindAllOf found no "
                .. "instance of either.")
        else
            h:fail("%s now declares functions. The Wwise SetMedia route was measured dead on "
                .. "2026-08-02 and is not any more; walk its parameter list.",
                table.concat(backFromTheDead, " and "))
        end

        --------------------------------------------------------------------
        h:section("verdict")
        --------------------------------------------------------------------
        h:note("ALL PASS -> nothing changed and there is nothing to do; soundFile stays refused. "
            .. "ANY FAIL -> the build moved and this item REOPENS: the failing line names which "
            .. "of the three facts stopped being true, and core/sound/file.lua's header is the "
            .. "argument that has to be rewritten around it. A WARN is neither: it means this "
            .. "session could not ask, and the closure is untouched.")
    end,
}
