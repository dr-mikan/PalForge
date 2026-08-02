-- PalForge core.sound: the sound FACADE. Formalizes the native-id vs custom-file
-- branching (which used to be inline in the audio base) into base/impl SoundSource
-- classes and dispatches by spec.kind. Self-contained.
--
-- API:
--   M.resolve(spec)     -- spec = {kind="native", id=?, path=?} | {kind="file", path=}
--                          -> a SoundSource instance, or nil
--                          (a native spec needs EITHER a non-empty id OR a non-empty path:
--                           native.path = the AkAudioEvent asset path, the
--                           PlayAkEventSoundByActor route that actually plays, and it is
--                           valid on its own; id is the fallback SoundID)
--   M.play(spec, actor) -- resolve + play on actor -> true only if a native call was issued
--   M.stop(actor)       -- stop all sounds on actor (native engine stop)
--   M.setActorVolume(actor, v)
--                       -- scale what actor's Wwise game object sends to its output bus
--                       -- (ACTOR-scoped, exactly like stop: it carries no sound identity)
--
-- CONTENT KNOWLEDGE STAYS OUT OF HERE. Turning an AkAudioEvent NAME into its asset path is a
-- catalog lookup, and the catalog lives in native/audio.lua; api/audio.lua does it while
-- lowering, so a spec arriving here already carries whatever path is knowable. The same is true
-- of NAMESPACE resolution: api/audio applies om.resolve to the id before it is lowered, so an
-- id arriving here is already in the "packid_name" form the engine can be handed. This module
-- only ever talks to the engine.
--
-- `kind = "file"` IS STILL DISPATCHED AND NOTHING NORMAL PRODUCES IT. Audio.Spec.soundFile is a
-- hard error at define time now (it silently outranked a working soundId, which made adding it
-- silence a sound that had been playing), so the only specs that arrive here with kind = "file"
-- come from a hand-written `source` override or from a direct call to M.resolve. The branch
-- stays because those two callers are real and are entitled to the same fail-soft `false`
-- FileSource has always given them; see core/sound/file.lua for the evidence that there is
-- nothing else to give.
local NativeSource = require("palforge.core.sound.native")
local FileSource   = require("palforge.core.sound.file")

local M = {}

-- A spec field names something only when it is a non-empty string.
local function named(v) return type(v) == "string" and #v > 0 end

-- Resolve a source spec into the right SoundSource instance, or nil. A native spec is
-- accepted on EITHER field: the path is what makes noise (NativeSource:play prefers it and
-- only falls back to the id), so a path-only definition is a complete one — gating on the
-- id alone made those resolve to nothing.
function M.resolve(spec)
    if type(spec) ~= "table" then return nil end
    if spec.kind == "native" and (named(spec.id) or named(spec.path)) then
        return NativeSource:new{ id = spec.id, path = spec.path }
    elseif spec.kind == "file" and named(spec.path) then
        return FileSource:new{ path = spec.path }
    end
    return nil
end

-- Play a resolved source spec on `actor`. Returns true only when the source issued a native
-- play call. A nil/unresolvable spec is still a fail-soft no-op (it never errors) but it
-- reports FALSE: nothing played, and a caller that cannot tell is a caller that ships a
-- silent definition.
function M.play(spec, actor)
    local src = M.resolve(spec)
    if not src then return false end
    return src:play(actor)
end

-- One source-less NativeSource for the calls that are scoped to an ACTOR rather than to a
-- sound. Neither of them reads `id` or `path` — StopSoundByActor is not SoundID-specific, and
-- SetOutputBusVolume addresses the actor's Wwise game object — so a single shared instance is
-- the whole state either one needs, and the engine call still lives in sound.native.
local engine = NativeSource:new{}

-- Stop all sounds on `actor`.
function M.stop(actor)
    return engine:stop(actor)
end

-- Scale the output bus volume of `actor`'s Wwise game object (linear, 1.0 = unity). ACTOR-wide
-- by construction, not per sound: see the long note at NativeSource:setActorVolume for which of
-- the build's four SetOutputBusVolume declarations this is and why the other three are out.
-- True only when the native call was ISSUED — never a promise that anything got quieter.
function M.setActorVolume(actor, volume)
    return engine:setActorVolume(actor, volume)
end

return M
