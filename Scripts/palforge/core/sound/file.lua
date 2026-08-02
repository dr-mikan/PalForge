-- PalForge core.sound.file: FileSource — a custom audio file (spec.path). TODO SEAM.
--
-- NO DEFINITION REACHES THIS ANY MORE, BY CONSTRUCTION. `Audio.Spec.soundFile` is a HARD ERROR
-- at define time (api/audio.lua): the field is still declared, so the error can name it and say
-- what to use instead, but no Audio{ ... } call can carry one. The reason is the one thing in
-- this seam that was not honest — soundFile took PRECEDENCE over soundId/soundPath, so adding
-- it beside a working soundId SILENCED a sound that had been playing, and :play then returned
-- the false that came from here. A field that makes working audio silent is worse than a field
-- that does not exist, so it refuses at the point where the author can still see it.
--
-- The two ways left in are both deliberate: a definition's own `source` override returning
-- `{ kind = "file", path = ... }`, and a direct `core.sound.resolve{ kind = "file", ... }`. Both
-- are code someone wrote on purpose, and both still land on the `return false` below.
--
-- Everything from here down is the evidence for WHY it is false, and it is what will have to be
-- overturned before soundFile can be accepted again. Palworld routes ALL of its audio through
-- Wwise (every shipped sound is an AkAudioEvent asset, see native/audio.lua), so playing a .wav
-- off disk needs either an engine USoundWave/USoundBase importer that survives in a shipping
-- build, or a Wwise external-source entry point. dumps/cxx answered BOTH halves, and only one of
-- them is still open.
--
-- THE UE-NATIVE HALF IS CLOSED, and it is closed on declarations, not on absence of evidence:
--   * USoundWave (Engine.hpp:21335) declares exactly two functions, SetSoundAssetCompressionType
--     and GetSoundAssetCompressionType (:21366-:21367). No importer, no InitAudioResource, no
--     way in for bytes.
--   * USoundWaveProcedural (Engine.hpp:21371) — the class whose whole purpose is queued PCM —
--     declares ZERO functions and ZERO properties. QueueAudio is C++-only and is not reachable
--     from Lua on this build.
--   * The consumers survived shipping and are useless without a producer: PlaySound2D
--     (Engine.hpp:13354) and CreateSound2D (:13425) both take a `USoundBase* Sound` we have no
--     way to make. The 6 live SoundWave / 8 live SoundBase are the SkyCreatorPlugin's own assets
--     (dumps/f5-partial-run.txt:150-151, dumps/reflection/05_assets.txt), not a factory.
-- So there is no USoundWave route, and no further probe of Engine.hpp will find one.
--
-- THE WWISE HALF EXISTS — and the harvest missed it, because it only ever enumerated /Script/AkAudio.
-- The entry point lives in a different module:
--   dumps/cxx/WwiseFileHandler.hpp:45  class UWwiseExternalSourceStatics : UBlueprintFunctionLibrary
--     :48  SetExternalSourceMediaWithIds(const FAkUniqueID Cookie, const int32 MediaId)
--     :49  SetExternalSourceMediaByName(FString ExternalSourceName, FString MediaName)
--     :50  SetExternalSourceMediaById(FString ExternalSourceName, const int32 MediaId)
-- Three all-scalar signatures (FString / int32), i.e. shapes core/signature would pass. That
-- retires the old question — "is there ANY Wwise external-source / SetMedia entry point" — as a
-- YES.
--
-- IT IS STILL THE WRONG INPUT, and that is the honest reading of what those three do. They do not
-- ingest a file; they REBIND an external-source cookie that the Wwise cook already declared to a
-- media entry the cook already staged. The surrounding declarations say so plainly:
-- FWwiseExternalSourceCookieDefaultMedia and FWwiseExternalSourceMediaInfo are FTableRowBase, i.e.
-- DataTable rows built at cook time (WwiseSimpleExternalSource.hpp:4, :13), and
-- UWwiseExternalSourceSettings points at them plus an ExternalSourceStagingDirectory (:25-:29).
-- A pack ships a .wav; that pipeline consumes Wwise-encoded media by name. And nothing can post
-- an event WITH external sources anyway: UAkGameplayStatics' 58 functions (AkAudio.hpp:725-786)
-- contain no *WithExternalSources overload, which the live build confirms — the same 58 with no
-- such name (dumps/f5-partial-run.txt:127-135).
--
-- TODO(audio-custom-file-loader): the ONLY route left is Wwise external sources, and what is
-- unknown is now whether this game's cook declares ANY. Two facts settle it, both read-only:
-- whether /Script/WwiseFileHandler.Default__WwiseExternalSourceStatics resolves live, and
-- whether the DataTables named by UWwiseExternalSourceSettings (MediaInfoTable /
-- ExternalSourceDefaultMedia) exist with rows. Zero external sources means SetExternalSourceMedia*
-- has nothing to rebind and this seam is dead for good; even a non-zero answer only makes a
-- .wem in the cook's staging directory playable, never a pack's .wav — so a working `soundFile`
-- would still need an offline Wwise conversion step that PalForge cannot perform at runtime.
--
--   local FileSource = require("palforge.core.sound.file")
--   FileSource:new{ path = "audio/theme.wav" }:play(actor)
local SoundSource = require("palforge.core.sound.base.source")

local FileSource = SoundSource:extend("FileSource")

-- Play a custom audio file on `actor`. Fail-soft no-op: returns false, never throws.
--
-- It stays `return false` rather than becoming an error, because the two callers that can still
-- reach it (see the header) are code that opted in, and the SoundSource contract this class
-- implements is that a source which could not reach the engine reports false. There is nothing
-- to call: dumps/cxx closed the UE-native half outright and the Wwise half takes cooked media
-- rather than a file, so a `true` here would be a lie in the one place a caller checks.
function FileSource:play(actor)
    return false
end

return FileSource
