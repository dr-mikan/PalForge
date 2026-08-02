-- PalForge tests.audio: example suite over the audio/sound layer. Asserts that a curated
-- BGM handle lowers to the right source spec and that the sound facade resolves it — all
-- pure Lua (no engine calls), so it runs green headless. A template for authoring more
-- suites with palforge.core.unittests.
local T         = require("palforge.core.unittests")
local sound     = require("palforge.core.sound")
local MainTheme = require("palforge.native.audio").MainTheme  -- curated bgm helper (HYBRID audio catalog)

local s = T.suite("audio_unit")   -- distinct from the in-game "audio" suite under palforge/test/cases

s:test("native BGM lowers to a native source spec", function(t)
    local spec = MainTheme:source()
    t:assert(type(spec) == "table", "source() returns a spec table")
    t:eq(spec.kind, "native", "kind is native")
    t:eq(spec.id, MainTheme.id, "id is the definition's AkAudioEvent name")
    t:eq(MainTheme:kind(), "bgm", "the curated helper is background music")
end)

s:test("sound.resolve builds a source for a native spec", function(t)
    local src = sound.resolve({ kind = "native", id = "MainTheme" })
    t:assert(src ~= nil, "native spec resolves to a SoundSource")
    t:assert(type(src.play) == "function", "the source is playable")
end)

s:test("sound.resolve rejects an empty / bad spec", function(t)
    t:assert(sound.resolve({}) == nil, "empty spec -> nil")
    t:assert(sound.resolve({ kind = "native", id = "" }) == nil, "empty id -> nil")
end)

return s
