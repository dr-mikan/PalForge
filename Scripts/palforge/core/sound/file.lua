-- PalForge core.sound.file: FileSource — a custom audio file (spec.path). TODO
-- SEAM: the deprecated layer has no custom-file playback, so this extends the base
-- SoundSource and no-ops until a USoundWave/USoundBase loader is observed and wired.
--
--   local FileSource = require("palforge.core.sound.file")
--   FileSource:new{ path = "audio/theme.wav" }:play(actor)
local SoundSource = require("palforge.core.sound.base.source")

local FileSource = SoundSource:extend("FileSource")

-- Play a custom audio file on `actor`. Fail-soft no-op for now.
function FileSource:play(actor)
    -- TODO: custom audio-file playback from self.path. deprecated has no custom-file
    -- mechanism; this needs a USoundWave/USoundBase loader (observe first).
    return false
end

return FileSource
