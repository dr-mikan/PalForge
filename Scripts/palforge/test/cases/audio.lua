-- palforge/test/cases/audio.lua — the audio api: defining, lowering, and the play chain.
--
-- Almost all of this is pure. It proves that Audio{ ... } validates and registers, that
-- bgm/se PIN `kind` rather than quietly overwriting a caller's, and — the part that decides
-- whether anything can ever make noise — how a declaration is LOWERED into the core.sound
-- spec: the id fallback, a path-only definition (which used to resolve to nothing and now
-- resolves), and an empty sound id, which still resolves to nil. Two tests assert a stub
-- rather than a promise: :setVolume returns false and a soundFile definition plays nothing.
-- Those are tripwires — they go red the day someone implements either, which is the point.
-- Only :play and :stop on a real actor need a world, so those two SKIP at the title screen.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Audio   = require("palforge.api.audio")
local sound   = require("palforge.core.sound")

local s = T.suite("audio")

-- A stand-in for an actor. The routes it is passed to (an unresolvable spec, the file seam)
-- return before anything dereferences it, so those claims hold identically with and without
-- a world — which is what keeps them out of the world-gated tests below.
local STUB_ACTOR = {}

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
    t:eq(src.id, id, "...keyed on the id you asked for")
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
    t:eq(src.id, id, "the definition's own id becomes the AkAudioEvent name")
    t:truthy(sound.resolve(src), "and core.sound resolves it")
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

s:test(":source is the core.sound spec, and a custom file outranks a native id", function(t)
    local both = Audio.se{ id = support.id("audio"),
                           soundId = "AKE_Test_Blip", soundPath = "/Game/x.x" }:source()
    t:type(both, "table", ":source returns a spec table")
    t:eq(both.kind, "native", "soundId/soundPath lower to the native route")
    t:eq(both.id, "AKE_Test_Blip", "the spec carries the event name")
    t:eq(both.path, "/Game/x.x", "...and the asset path")

    local file = Audio.se{ id = support.id("audio"),
                           soundFile = "audio/theme.wav", soundId = "AKE_Test_Blip" }:source()
    t:eq(file.kind, "file", "a soundFile takes precedence over a native id")
    t:eq(file.path, "audio/theme.wav", "the file route carries the file path")
    t:eq(file.id, nil, "the file spec does not carry a native id")
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

s:test("a custom audio FILE does not play yet: :play is a no-op that returns false", function(t)
    -- Palworld exposes no confirmed USoundWave loader, so core.sound.file is a seam. When
    -- someone wires it, this test fails and that is the signal to update it.
    local h = Audio.se{ id = support.id("audio"), soundFile = "audio/theme.wav" }
    t:eq(h:play(STUB_ACTOR), false, "the file route resolves and then plays nothing")
end)

s:test(":setVolume is not implemented and returns false to say so", function(t)
    -- No per-SOUND volume route is known (the RTPC names are not dumped), so this is a
    -- documented stub. Wiring it should break this test, and the signature with it.
    local h = Audio.se{ id = support.id("audio"), soundId = "AKE_Test_Blip" }
    t:eq(h:setVolume(0.5), false, ":setVolume does nothing and reports false")
    t:eq(h:setVolume(0.0), false, "...for every value, including the edges")
    t:eq(h:setVolume(1.0), false, "...including a full-volume request")
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

s:test(":stop is actor-wide: it issues the native stop whatever sound you call it on", function(t)
    local pawn = support.needWorld(t)

    -- StopSoundByActor is not SoundID-specific, so a handle for an id that was never even
    -- defined still stops the actor — and running here, right after :play, silences it.
    local h = Audio.get(support.id("audio"))
    t:eq(h:stop(pawn), true, ":stop returns true once StopSoundByActor has been issued")
    t:eq(h:stop(), true, "the default actor is the local player pawn")
end)

return s
