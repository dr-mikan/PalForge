-- PalForge core.sound.file: FileSource — a custom audio file (spec.path). TODO SEAM.
--
-- Reached by an Audio definition that sets `soundFile`. Palworld routes ALL of its audio
-- through Wwise (every shipped sound is an AkAudioEvent asset, see native/audio.lua), and
-- Wwise does not consume USoundWave — so playing a .wav off disk needs either an engine
-- USoundWave/USoundBase importer that survives in a shipping build, or a Wwise external-source
-- entry point. Neither is observed anywhere in this tree or the parent tree, and the deprecated
-- layer never had custom-file playback either. Until one is, this no-ops and says so, rather
-- than resolving to a silent success.
--
--   local FileSource = require("palforge.core.sound.file")
--   FileSource:new{ path = "audio/theme.wav" }:play(actor)
local SoundSource = require("palforge.core.sound.base.source")

local FileSource = SoundSource:extend("FileSource")

-- Play a custom audio file on `actor`. Fail-soft no-op: returns false, never throws.
function FileSource:play(actor)
    -- TODO(audio-custom-file-loader): it is unknown whether the shipping build exposes ANY
    -- runtime loader that turns a file on disk into something playable (a USoundWave/USoundBase
    -- factory, or a Wwise external-source / SetMedia entry point); enumerating the audio-related
    -- CDOs' reflected functions would settle whether such a call exists at all.
    return false
end

return FileSource
