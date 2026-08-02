-- palforge/test/cases/audio.lua — the audio api: defining, lowering, and the play chain.
--
-- Almost all of this is pure. It proves that Audio{ ... } validates and registers, that
-- bgm/se PIN `kind` rather than quietly overwriting a caller's, and — the part that decides
-- whether anything can ever make noise — how a declaration is LOWERED into the core.sound
-- spec: the id fallback, a path-only definition (which used to resolve to nothing and now
-- resolves), and an empty sound id, which still resolves to nil. :setVolume is asserted the way
-- :play and :stop are: false with no actor, true once the native call has been issued — and
-- "issued" is the whole claim, because nobody has heard it (test/hooks/audio-setvolume-audible).
--
-- TWO THINGS THIS FILE USED TO ASSERT ARE GONE, and they were both about soundFile. It used to
-- prove that a soundFile OUTRANKS a soundId in the lowering, and that the resulting source plays
-- nothing — an accurate description of a field that silenced working audio. soundFile is a hard
-- error at define time now, so the tests are the refusal itself: the error fires, it names the
-- open item, and neither of the two working fields is reachable past it.
--
-- Only :play, :stop, :setVolume on a real actor and the wrong-class refusal need a world, so
-- those SKIP at the title screen. ONE test here skips the other way round — ":setVolume reports
-- false ... when there is no actor" skips when a world IS loaded, because a loaded world is
-- exactly what makes its premise false. That inversion is easy to add by accident and hard to
-- read later, so it is spelled out in the case name; nothing new here does it.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Audio   = require("palforge.api.audio")
local sound   = require("palforge.core.sound")
local om      = require("palforge.core.object_manager")

local s = T.suite("audio")

-- A stand-in for an actor. The routes it is passed to (an unresolvable spec, a refused value)
-- return before anything dereferences it, so those claims hold identically with and without
-- a world — which is what keeps them out of the world-gated tests below.
local STUB_ACTOR = {}

-- A real /Game asset that is NOT an AkAudioEvent: the static mesh the live sweep read off a
-- rendering BP_BuildObject_ItemChest_C (core/mesh/assets.lua M.SM.ChestWood). It is here because
-- `soundPath = Mesh.assets.SM.ChestWood` is the mistake the sound loader had no defence against
-- — it resolves to a perfectly live UStaticMesh, and marshalling one into a UAkAudioEvent*
-- parameter is the shape that closed the game once.
local WRONG_CLASS_PATH = "/Game/Pal/Model/Prop/Architecture/ChestWood/SM_ChestWood.SM_ChestWood"

-- The AkAudioEvent this suite plays live: a short one-shot UI blip rather than the title
-- BGM, because someone will press F1 inside their actual save.
local LIVE_EVENT = "AKE_UI_Common_Menu_Close"

-- The real asset path for a catalog event, or nil when the native catalog is not loaded.
-- The live test points a TEST-namespaced id at a real path: the path is the route that
-- actually plays, and borrowing it this way never defines over a game id.
local function catalogPath(name)
    local ok, native = pcall(require, "palforge.native.audio")
    if ok and type(native) == "table" and type(native.CATALOG) == "table" then
        return native.CATALOG[name]
    end
    return nil
end

--=============================================================================
-- defining, and getting back what you defined
--=============================================================================

s:test("a defined sound is registered and Audio.get hands the same definition back", function(t)
    local id = support.id("audio")
    local h  = Audio{ id = id, name = "Test Blip", description = "a defined sound",
                      soundId = "AKE_Test_Blip" }

    t:eq(h.id, id, "the handle carries the id it was defined with")
    t:eq(h:name(), "Test Blip", "name is the declared label")
    t:eq(h:description(), "a defined sound", "description is carried onto the definition")

    local got = Audio.get(id)
    t:eq(got.id, id, "Audio.get returns a handle for the registered definition")
    t:eq(got:name(), "Test Blip", "...and it is the SAME definition, not a fresh native stub")
    t:eq(got:source().id, "AKE_Test_Blip", "...carrying the declared AkAudioEvent name")
end)

s:test("name defaults to the id when no label is given", function(t)
    local id = support.id("audio")
    t:eq(Audio{ id = id, soundId = "AKE_Test_Blip" }:name(), id, "name falls back to the id")
end)

s:test("Audio.get_all lists every registered sound, including one just defined", function(t)
    local id = support.id("audio")
    Audio{ id = id, soundId = "AKE_Test_Blip" }

    local all, mine = Audio.get_all(), nil
    t:type(all, "table", "get_all returns a list")
    for _, h in ipairs(all) do
        if h.id == id then mine = h end
    end
    t:truthy(mine, "the sound just defined appears in get_all")
    t:truthy(#all >= 1, "get_all is a list of handles")
end)

s:test("Audio.get on an id nobody defined returns a native handle without registering it", function(t)
    local id  = support.id("audio")
    local h   = Audio.get(id)
    local src = h:source()

    t:truthy(src, "an unknown id is still playable: it keys a thin native definition")
    t:eq(src.kind, "native", "the fallback definition is a native source")
    -- support.id() is NAMESPACED ("palforge_test:audio_7"), and lowering resolves an id on its
    -- way to the engine — so the spec carries the resolved form, not the colon form. That is the
    -- point of the resolution test below, and it is asserted here too because this is the route
    -- an undefined id takes.
    t:eq(src.id, om.resolve(id), "...keyed on the RESOLVED form of the id you asked for")
    t:eq(h:kind(), "se", "an undeclared kind reads as the class default, se")

    -- get must not have REGISTERED anything, or looking a sound up would create content.
    for _, other in ipairs(Audio.get_all()) do
        t:neq(other.id, id, "Audio.get does not register the id it was asked about")
    end
end)

s:test("id is required and an unknown field is a hard error with a suggestion", function(t)
    t:errors(function() Audio{ soundId = "AKE_Test_Blip" } end, "field \"id\" is required")
    t:errors(function() Audio{ id = support.id("audio"), soundpath = "/Game/x" } end,
        "did you mean \"soundPath\"?")
end)

--=============================================================================
-- kind: what bgm and se pin, and what they refuse
--=============================================================================

s:test("bgm and se pin kind, and a bare Audio{ ... } defaults to se", function(t)
    t:eq(Audio.bgm{ id = support.id("audio"), soundId = "AKE_Test_Blip" }:kind(), "bgm",
        "Audio.bgm pins kind to bgm")
    t:eq(Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip" }:kind(), "se",
        "Audio.se pins kind to se")
    t:eq(Audio{ id = support.id("audio"), soundId = "AKE_Test_Blip" }:kind(), "se",
        "the spec default is se")
    t:eq(Audio{ id = support.id("audio"), kind = "bgm", soundId = "AKE_Test_Blip" }:kind(), "bgm",
        "Audio{ ... } is the way to set kind explicitly")
end)

s:test("passing a contradicting kind to bgm or se is an error, not a silent overwrite", function(t)
    t:errors(function() Audio.bgm{ id = support.id("audio"), kind = "se" } end,
        "kind is fixed to \"bgm\" here, but got \"se\"")
    t:errors(function() Audio.se{ id = support.id("audio"), kind = "bgm" } end,
        "kind is fixed to \"se\" here, but got \"bgm\"")
end)

s:test("a kind that merely agrees is accepted, and the caller's table is never mutated", function(t)
    local spec = { id = support.id("audio"), kind = "bgm", soundId = "AKE_Test_Blip" }
    t:eq(Audio.bgm(spec):kind(), "bgm", "a redundant kind = bgm is not a contradiction")

    local plain = { id = support.id("audio"), soundId = "AKE_Test_Blip" }
    Audio.bgm(plain)
    t:eq(plain.kind, nil, "bgm copies the spec rather than writing kind into the caller's table")
end)

--=============================================================================
-- lowering: what :source() hands to core.sound, and what core.sound does with it
--=============================================================================

s:test("a definition that names no sound falls back to its own id as the event name", function(t)
    local id  = support.id("audio")
    local src = Audio.bgm{ id = id }:source()

    t:truthy(src, "the short form Audio.bgm{ id = ... } still lowers to a source")
    t:eq(src.kind, "native", "the fallback route is native")
    t:eq(src.id, om.resolve(id), "the definition's own id becomes the AkAudioEvent name")
    t:truthy(sound.resolve(src), "and core.sound resolves it")
end)

s:test("a NAMESPACED sound id is resolved before it is handed to the engine", function(t)
    -- F-3/C5. An id may be namespaced, and a namespaced id is useless at both engine boundaries
    -- this spec feeds: the AkAudioEvent catalog is keyed on event names, and the SoundID fallback
    -- puts the id straight into FName(). "mypack:Theme" matched neither, so a namespaced sound
    -- missed the catalog and then posted a name nothing answers to — silence, reported as true.
    local src = Audio.se{ id = support.id("audio"), soundId = "mypack:Theme" }:source()
    t:eq(src.id, "mypack_Theme", "the colon form is resolved to the underscore form")
    t:eq(src.path, nil, "an id the catalog does not know still lowers to the id alone")

    -- The literal fallback (C4): resolve REFUSES a shape it cannot turn into a row name, and the
    -- boundary keeps the literal rather than dropping it. A hyphen is a perfectly natural thing
    -- to type, and "nothing at all" is the one answer that helps nobody.
    local bad = Audio.se{ id = support.id("audio"), soundId = "my-pack:Theme" }:source()
    t:eq(bad.id, "my-pack:Theme", "an unresolvable id falls back to the LITERAL, never to nil")

    -- A literal game id is untouched: this is what every catalog entry is.
    local plain = Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip" }:source()
    t:eq(plain.id, "AKE_Test_Blip", "an id with no colon is passed through unchanged")
end)

s:test("an id that could never resolve is refused at DEFINE time, not at play time", function(t)
    -- C4. "my-pack:Blip" would register fine and then be dead at every boundary it reaches,
    -- because om.resolve requires letters/digits/underscore in both halves — and for AUDIO it is
    -- worse than for other domains, since a definition that names no sound uses its own id as
    -- the event name. Audio.Spec's `id` carries schema.validId, so it is refused where it was
    -- typed. The wording belongs to core/schema.lua; what this asserts is that audio enforces it.
    t:errors(function() Audio{ id = "my-pack:Blip", soundId = "AKE_Test_Blip" } end,
        "letters/digits/_ only")
    t:errors(function() Audio.bgm{ id = "pack:has space", soundId = "AKE_Test_Blip" } end,
        "letters/digits/_ only")
end)

s:test("opts.register = false builds the handle and publishes nothing", function(t)
    -- C2. Registering is what makes an id public and permanent (object_manager has no expiry),
    -- so a caller that only wants the handle has to be able to say so.
    local id = support.id("audio")
    local h  = Audio.se({ id = id, soundId = "AKE_Test_Blip" }, { register = false })

    t:eq(h.id, id, "the handle is built and returned exactly as usual")
    t:eq(h:source().id, "AKE_Test_Blip", "...and lowers exactly as usual")
    t:eq(om.get("audio", id), nil, "but nothing was registered under that id")

    -- and the default is unchanged: no opts still registers.
    local id2 = support.id("audio")
    Audio.se{ id = id2, soundId = "AKE_Test_Blip" }
    t:truthy(om.get("audio", id2), "omitting opts registers, exactly as before")

    t:errors(function() Audio.se({ id = support.id("audio"), soundId = "x" }, "mypack") end,
        "the second argument is the options table")
end)

s:test("a soundPath-only definition resolves: the path alone is a complete definition", function(t)
    local path = "/Game/Pal/Sound/Events/SE/UI/Common/AKE_Test_Only_Path.AKE_Test_Only_Path"
    local src  = Audio.se{ id = support.id("audio"), soundPath = path }:source()

    t:eq(src.kind, "native", "a path lowers to a native source")
    t:eq(src.path, path, "the declared path is carried through")
    t:eq(src.id, nil, "declaring a path does NOT invent a sound id")
    -- The path is the PlayAkEventSoundByActor route, so gating resolution on the id alone
    -- silently dropped these; core.sound accepts either field now.
    t:truthy(sound.resolve(src), "core.sound resolves a native source that has only a path")
end)

s:test("an empty sound id lowers to no source at all", function(t)
    local h = Audio.se{ id = support.id("audio"), soundId = "" }
    t:eq(h:source(), nil, "an empty soundId names nothing, so nothing is lowered")
    t:eq(sound.resolve({ kind = "native", id = "", path = "" }), nil,
        "core.sound needs a NON-empty id or path")
    t:eq(sound.resolve(nil), nil, "and a nil spec resolves to nil rather than throwing")
end)

s:test(":source is the core.sound spec: soundId and soundPath both land on it", function(t)
    local both = Audio.se{ id = support.id("audio"),
                           soundId = "AKE_Test_Blip", soundPath = "/Game/x.x" }:source()
    t:type(both, "table", ":source returns a spec table")
    t:eq(both.kind, "native", "soundId/soundPath lower to the native route")
    t:eq(both.id, "AKE_Test_Blip", "the spec carries the event name")
    t:eq(both.path, "/Game/x.x", "...and the asset path")
end)

s:test("soundFile is a HARD ERROR at define time, on every constructor", function(t)
    -- THE PUBLISH GATE. soundFile was accepted, validated, documented — and it took precedence
    -- over soundId/soundPath, so adding one beside a working soundId silenced a sound that had
    -- been playing, and :play handed back the false that came out of the file seam. Nothing else
    -- in this framework degrades that way. It refuses at the point the author can still see it.
    --
    -- This test is the tripwire for audio-custom-file-loader: the day a runtime loader is found,
    -- this is what says "and now unrefuse the field".
    local msg = t:errors(function()
        Audio{ id = support.id("audio"), soundFile = "audio/theme.wav" }
    end, "soundFile is not accepted")
    t:truthy(msg:find("audio-custom-file-loader", 1, true),
        "the refusal names the open item, so it reads as a boundary rather than a bug")
    t:truthy(msg:find("soundId", 1, true),
        "...and names what to use instead, so the fix is one line")

    t:errors(function() Audio.bgm{ id = support.id("audio"), soundFile = "a.wav" } end,
        "soundFile is not accepted")
    t:errors(function() Audio.se{ id = support.id("audio"), soundFile = "a.wav" } end,
        "soundFile is not accepted")

    -- The dangerous shape specifically: soundFile NEXT TO a working sound. It must not be
    -- accepted-and-ignored either, because "it plays" and "it errors" are both fine answers
    -- while "it silently stopped playing" is not.
    t:errors(function()
        Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip", soundFile = "a.wav" }
    end, "soundFile is not accepted")

    -- An empty string is still a soundFile: the old code tested `#self.soundFile > 0` when
    -- lowering, so "" fell through to the native route and looked harmless. The gate is on the
    -- FIELD BEING PRESENT, not on it being non-empty.
    t:errors(function() Audio.se{ id = support.id("audio"), soundFile = "" } end,
        "soundFile is not accepted")

    -- The field stays DECLARED so the error can name it and so tooling still lists it — which is
    -- also what keeps the did-you-mean suggestion working for someone typing "soundfile".
    local schema = require("palforge.core.schema")
    local spec   = schema.get("Audio.Spec")
    local found  = false
    for _, f in ipairs((spec and spec.fields) or {}) do
        if f.name == "soundFile" then found = true end
    end
    t:truthy(found, "soundFile is still a declared field, so the refusal can name it")
end)

--=============================================================================
-- the play chain — the parts that are honest about doing nothing
--=============================================================================

s:test("a definition that names no sound never claims to have played", function(t)
    -- False with or without a world: the spec is unresolvable, so the actor is never reached.
    local h = Audio.se{ id = support.id("audio"), soundId = "" }
    t:eq(h:play(STUB_ACTOR), false, ":play reports false rather than a reassuring true")
    t:eq(sound.play(nil, STUB_ACTOR), false, "core.sound.play agrees")
end)

s:test("the file route still exists below the api, and still plays nothing", function(t)
    -- Audio{ soundFile = ... } cannot reach this any more (it is refused at define time), but
    -- core.sound still DISPATCHES kind = "file", because two callers can still produce one: a
    -- definition's own `source` override, and a direct core.sound call. Both are code someone
    -- wrote on purpose, and both must get the same honest false rather than a silent true.
    -- Palworld exposes no confirmed loader for a file on disk; when one is found, this test
    -- fails and that is the signal that audio-custom-file-loader can close.
    t:truthy(sound.resolve({ kind = "file", path = "audio/theme.wav" }),
        "core.sound still resolves a file spec to a FileSource")
    t:eq(sound.play({ kind = "file", path = "audio/theme.wav" }, STUB_ACTOR), false,
        "...and that source plays nothing, without throwing")

    -- The same thing through the only api route left to it: a source override.
    local h = Audio.se{ id = support.id("audio"),
                        source = function() return { kind = "file", path = "audio/theme.wav" } end }
    t:eq(h:source().kind, "file", "a source override may still return a file spec")
    t:eq(h:play(STUB_ACTOR), false, "and :play reports false rather than a reassuring true")
end)

s:test(":setVolume reports false with no actor (SKIPS when a world IS loaded)", function(t)
    -- setVolume is wired now (UAkGameplayStatics::SetOutputBusVolume, AkAudio.hpp:748) but it
    -- is ACTOR-scoped, so with no world there is no default actor and nothing is issued. This
    -- is the same fail-soft claim :play and :stop make, asserted on the same terms.
    local h = Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip" }
    -- INVERSE-GATED, and typed as such: skipNeedsNoWorld rather than the bare t:skip, so this
    -- lands in the summary's "need no world" bucket with the other nine instead of in the
    -- "did not say which" one. The audible half is test/hooks/audio-setvolume-audible.
    if support.player() then
        t:skipNeedsNoWorld("a world is loaded — there IS an actor to scale, so the no-actor "
            .. "refusal this asserts cannot happen")
    end
    t:eq(h:setVolume(0.5), false, "no actor, so no native call was issued")
    t:eq(h:setVolume(0.0), false, "...for every value, including the edges")
    t:eq(h:setVolume(1.0), false, "...including a full-volume request")
end)

s:test(":setVolume refuses a value that is not a non-negative number, and never raises", function(t)
    -- The value guard runs before the engine is reached at all, which is why this claim holds
    -- identically with and without a world: a FloatProperty is only safe to marshal when what
    -- reaches it really is a number, and a fail-soft false is the whole contract here.
    local h = Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip" }
    t:eq(h:setVolume(-1.0, STUB_ACTOR), false, "a negative multiplier is refused")
    t:eq(h:setVolume("loud", STUB_ACTOR), false, "a string is refused")
    t:eq(h:setVolume(nil, STUB_ACTOR), false, "and so is nothing at all")
end)

--=============================================================================
-- live: the native route needs a real actor
--=============================================================================

s:test(":play issues a native call for a resolvable sound on the player pawn", function(t)
    local pawn = support.needWorld(t)
    local path = catalogPath(LIVE_EVENT)
    if not path then t:skip("native audio catalog unavailable this session") end

    -- A test-namespaced id pointed at a real asset path: nothing real is redefined, and the
    -- path is the route that actually reaches PlayAkEventSoundByActor.
    local h = Audio.se{ id = support.id("audio"), soundPath = path }
    t:eq(h:play(pawn), true, ":play returns true once the native call has been ISSUED")
    t:eq(h:play(), true, "the default actor is the local player pawn")
end)

s:test("a soundPath that names the WRONG CLASS is refused before it is marshalled", function(t)
    local pawn = support.needWorld(t)

    -- A-3. This is the test that has to run in a world, because the whole claim is about what
    -- happens to an object that RESOLVES: SM_ChestWood is a real, live UStaticMesh (the live
    -- sweep read it off a rendering item chest), and the parameter it would be handed is
    -- declared UAkAudioEvent* (dumps/cxx/Pal.hpp:29170). Handing a wrong-typed object to a typed
    -- native parameter faults inside UE4SS's marshalling where pcall cannot see it — that is the
    -- shape that closed the game once, and it is why the mesh loader has had a class check for
    -- as long as it has existed while this one had none.
    --
    -- If this test ever CRASHES the session rather than failing, the check is gone.
    local h = Audio.se{ id = support.id("audio"), soundPath = WRONG_CLASS_PATH }
    t:eq(h:play(pawn), false,
        "a static mesh in soundPath is refused, and :play says false instead of dying")

    -- The refusal is per PATH, not per definition: a second sound naming the same asset is
    -- refused just as firmly (and the log line is said once, not once per play).
    local h2 = Audio.se{ id = support.id("audio"), soundPath = WRONG_CLASS_PATH }
    t:eq(h2:play(pawn), false, "...and again for any other definition naming the same asset")

    -- With an id ALSO declared, the refusal falls through to the SoundID route exactly as an
    -- unresolvable path does — issued, and silent, which is the documented behaviour of that
    -- branch. What matters is that the AkAudioEvent parameter never saw the mesh.
    local h3 = Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip",
                         soundPath = WRONG_CLASS_PATH }
    t:type(h3:play(pawn), "boolean", "the fallback route decides the return, and it never throws")
end)

s:test(":setVolume issues the actor-scoped output-bus call on the player pawn", function(t)
    local pawn = support.needWorld(t)

    -- 1.0 ON PURPOSE. This is the one live audio claim that leaves state behind — an output bus
    -- volume is a property of the actor's Wwise game object, not of a playing sound, so a test
    -- that set 0.2 would leave the player's own audio scaled down after it passed. 1.0 is unity:
    -- the call is fully exercised, core/signature's live parameter walk either agrees with
    -- AkAudio.hpp:748 or refuses, and nothing about the session sounds different afterwards.
    local h = Audio.get(support.id("audio"))
    t:eq(h:setVolume(1.0, pawn), true, ":setVolume returns true once the native call was ISSUED")
    t:eq(h:setVolume(1.0), true, "the default actor is the local player pawn, as with play/stop")
end)

s:test(":stop is actor-wide: it issues the native stop whatever sound you call it on", function(t)
    local pawn = support.needWorld(t)

    -- StopSoundByActor is not SoundID-specific, so a handle for an id that was never even
    -- defined still stops the actor — and running here, right after :play, silences it.
    local h = Audio.get(support.id("audio"))
    t:eq(h:stop(pawn), true, ":stop returns true once StopSoundByActor has been issued")
    t:eq(h:stop(), true, "the default actor is the local player pawn")
end)

return s
