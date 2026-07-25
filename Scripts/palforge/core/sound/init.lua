-- PalForge core.sound: the sound FACADE. Formalizes the native-id vs custom-file
-- branching (which used to be inline in the audio base) into base/impl SoundSource
-- classes and dispatches by spec.kind. Self-contained.
--
-- API:
--   M.resolve(spec)     -- spec = {kind="native", id=, path=?} | {kind="file", path=}
--                          -> a SoundSource instance, or nil
--                          (native.path = the AkAudioEvent asset path, the confirmed
--                           PlayAkEventSoundByActor play route; id is the fallback SoundID)
--   M.play(spec, actor) -- resolve + play on actor
--   M.stop(actor)       -- stop all sounds on actor (native engine stop)
local NativeSource = require("palforge.core.sound.native")
local FileSource   = require("palforge.core.sound.file")

local M = {}

-- Resolve a source spec into the right SoundSource instance, or nil.
function M.resolve(spec)
    if type(spec) ~= "table" then return nil end
    if spec.kind == "native" and type(spec.id) == "string" and #spec.id > 0 then
        return NativeSource:new{ id = spec.id, path = spec.path }
    elseif spec.kind == "file" and type(spec.path) == "string" and #spec.path > 0 then
        return FileSource:new{ path = spec.path }
    end
    return nil
end

-- Play a resolved source spec on `actor`. Mirrors the old audio-base playSource: a
-- nil/unresolvable spec is a fail-soft no-op that still reports success (nothing to
-- play is not a failure); a real native call's success/failure is propagated.
function M.play(spec, actor)
    local src = M.resolve(spec)
    if not src then return true end
    return src:play(actor)
end

-- Stop all sounds on `actor`. Routed through NativeSource so the engine call stays
-- in sound.native (StopSoundByActor is not SoundID-specific, so a shared stopper
-- instance suffices).
local stopper = NativeSource:new{}
function M.stop(actor)
    return stopper:stop(actor)
end

return M
