-- PalForge core.sound.native: NativeSource — a native Palworld sound played through the
-- game's own sound utility (UPalSoundUtility). Extends the base SoundSource.
--
-- Play mechanism: our catalog ids are Wwise AkAudioEvent NAMES with a known asset PATH, so
-- the route is
--   LoadAsset(assetPath) -> PalSoundUtility:PlayAkEventSoundByActor(actor, asset).
-- That is the GAME'S OWN route, and it is measured twice. PlayAkEventSoundByActor is one of the
-- 13 reflected UFunctions on UPalSoundUtility (dumps/reflection/02_reflection.txt), and a
-- recorded session caught the game itself calling it six times on the PalSoundUtility callee
-- with exactly two arguments — a1 an AActor, a2 a UObject (the AkAudioEvent), a3/a4 empty
-- (dumps/reflection/06_events.txt, tag [SOUND.ak]). Same callee, same arity, same order as the
-- call below. The CXX dump then declares it outright:
--   dumps/cxx/Pal.hpp:29170   bool UPalSoundUtility::PlayAkEventSoundByActor(AActor*, UAkAudioEvent*)
-- so the open question "does it hand back a Wwise PlayingID" is answered NO — the return is a
-- bool, and there is no id for a narrow stop to be given. That is why stop() below stays
-- actor-wide, and it is no longer a gap, it is the shape of the call. What is still unrecorded
-- is the AUDIBILITY of OUR call.
-- PlaySoundByActor({Key=FName(id)}) is SILENT for AkAudioEvent names (its Key is a
-- SoundID-table row, a different namespace) — kept as the fallback for a source that carries
-- an id and no loadable asset. The same session logged that one 286 times as
-- (AActor, UScriptStruct, UScriptStruct), so the arity and the two struct arguments used below
-- are right; the struct FIELD names (Key / FadeInTime) are still assumed. api/audio fills the
-- path in from the AkAudioEvent catalog before we get here, so that fallback is now reached
-- only for names the catalog does not know, i.e. names that plausibly ARE SoundID rows.
--
-- The two routes are tried in SEPARATE pcalls on purpose: if the AkAudioEvent call throws
-- (wrong argument count, missing function) the source still falls through to the id route
-- instead of the whole play collapsing to false.
--
-- RETURN CONTRACT: play/stop return true only when a native call was actually ISSUED — a
-- bad actor, a missing CDO, or nothing to post is false. It is NOT a promise that a sound
-- was audible; the engine hands back nothing we can check. A `false` does mean nothing was
-- even attempted, which is what a caller can act on.
--
--   local NativeSource = require("palforge.core.sound.native")
--   NativeSource:new{ id = "AKE_General_Explosion", path = "/Game/.../AKE_General_Explosion.AKE_General_Explosion" }:play(actor)
local SoundSource = require("palforge.core.sound.base.source")
local sig         = require("palforge.core.signature")

local NativeSource = SoundSource:extend("NativeSource")

-- Loaded AkAudioEvent assets cached by path (LoadAsset once, reuse forever).
local assetCache = {}

-- Is `o` a live UObject? Every IsValid call in this file goes through here: a stale handle
-- can throw on the call itself, and none of the callers may let that escape.
local function alive(o)
    local ok, valid = pcall(function() return o ~= nil and o.IsValid ~= nil and o:IsValid() end)
    return ok and valid == true
end

-- Load (and cache) the AkAudioEvent asset at `path`; nil if it cannot be resolved.
-- LoadAsset does not return the object on every UE4SS build, so StaticFindObject is tried
-- afterwards as well — by then the load has already put the asset in memory.
local function loadAsset(path)
    if type(path) ~= "string" or #path == 0 then return nil end
    local cached = assetCache[path]
    if alive(cached) then return cached end
    assetCache[path] = nil

    local a
    pcall(function() if type(LoadAsset) == "function" then a = LoadAsset(path) end end)
    if not alive(a) then a = nil; pcall(function() a = StaticFindObject(path) end) end
    if alive(a) then assetCache[path] = a; return a end
    return nil
end

-- The PalSoundUtility CDO, or nil. Every play/stop call in this file goes through it.
local function soundUtility()
    local u
    pcall(function() u = StaticFindObject("/Script/Pal.Default__PalSoundUtility") end)
    if alive(u) then return u end
    return nil
end

-- The AkGameplayStatics CDO, or nil. Only setActorVolume uses it: volume is the one thing
-- UPalSoundUtility does not expose (its 13 functions are play / stop / switch / RTPC, and the
-- RTPC half was closed with evidence — the build declares three AkRtpc assets and none is a
-- volume). The live run resolved this CDO by this exact path (dumps/f5-partial-run.txt:49).
local function akStatics()
    local o
    pcall(function() o = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics") end)
    if alive(o) then return o end
    return nil
end

-- Play this sound on `actor`. Fail-soft: an invalid actor / missing utility / a source with
-- neither a loadable asset nor an id is a no-op, not an error — and returns FALSE. `played`
-- is set only after a native call has returned, so a throw inside it leaves it false too.
function NativeSource:play(actor)
    if not alive(actor) then return false end

    local u = soundUtility()
    if not u then return false end

    -- Preferred: Wwise AkAudioEvent by loaded asset (the catalog path). This is the branch
    -- that is expected to make noise.
    local asset = loadAsset(self.path)
    if asset then
        local played = false
        -- Argument shape is no longer a guess: the game's own calls to this function are
        -- (AActor, UObject) on the PalSoundUtility callee, two parameters, that order
        -- (06_events.txt [SOUND.ak]) — which is exactly this call. It stays inside a pcall and
        -- `played` still only means ISSUED: the call reports nothing back that we can read.
        pcall(function() u:PlayAkEventSoundByActor(actor, asset); played = true end)
        if played then return true end
    end

    -- Fallback: SoundID-row style id via PlaySoundByActor (no asset loaded, or the AkAudioEvent
    -- call threw). This one DID reach the engine, hence true — but for an AkAudioEvent name it
    -- is the silent namespace (see the header), so true here means "issued", never "audible".
    if type(self.id) == "string" and #self.id > 0 then
        local played = false
        pcall(function()
            u:PlaySoundByActor(actor, { Key = FName(self.id) }, { FadeInTime = 0 })
            played = true
        end)
        return played
    end
    return false
end

-- Stop sounds on `actor`. StopSoundByActor stops ALL sounds on the actor and is not
-- SoundID-specific, so self.id/self.path are unused here. A narrower call does exist —
-- UPalSoundUtility also reflects StopSoundByActorWithSoundId (02_reflection.txt) — but nothing
-- has measured its parameter list, no session log records it firing, and the AkAudioEvent play
-- route hands back no SoundId to pass it, so it is not wired on a guess: a narrow stop that
-- silently misses would be worse than an actor-wide one that works. True only when the
-- actor-wide call was issued.
function NativeSource:stop(actor)
    if not alive(actor) then return false end

    local u = soundUtility()
    if not u then return false end

    local stopped = false
    pcall(function() u:StopSoundByActor(actor); stopped = true end)
    return stopped
end

-- Scale the output bus volume of `actor`'s Wwise game object. `self` is unread: like stop(),
-- this is an ACTOR-scoped call and carries no sound identity.
--
-- WHAT THE DUMP SETTLED, AND IT CORRECTS THE OLD READING. `SetOutputBusVolume` was written off
-- as "a whole output BUS, not one sound". The declaration says otherwise:
--
--   dumps/cxx/AkAudio.hpp:748   UAkGameplayStatics::SetOutputBusVolume(float BusVolume, AActor* Actor)
--
-- There is no bus NAME in it. The second parameter is the actor, i.e. the Wwise game object —
-- this is the Blueprint wrapper for AK::SoundEngine::SetGameObjectOutputBusVolume, which scales
-- what ONE emitter sends to its output bus. That is exactly the scope PlayAkEventSoundByActor
-- posts on and StopSoundByActor clears, so it is the same granularity the rest of this file
-- already works at: per actor, not per sound and not per bus.
--
-- The build declares three other overloads, and none of them is reachable or narrower:
--   AkAudio.hpp:663   UAkComponent::SetOutputBusVolume(float)                  needs a live
--     AkComponent for OUR sound, and there is none: PlayAkEventSoundByActor returns a bool
--     (Pal.hpp:29170), not a component and not a PlayingID, and the 248 live AkComponents
--     belong to level gimmicks (dumps/f5-partial-run.txt:88-89).
--   Pal.hpp:14129     UPalAudioWorldSubsystem::SetOutputBusVolume(float)       world-global.
--   Pal.hpp:29103     UPalSoundPlayer::SetOutputBusVolume(FName, float)        named bus, and
--     the build declares zero AkAuxBus (dumps/f5-partial-run.txt:85), so there is no name.
--
-- LIVE CONFIRMATION of the name only: SetOutputBusVolume is one of AkGameplayStatics' 58
-- reflected functions on this build (dumps/f5-partial-run.txt:58). The PARAMETER LIST above is
-- the dump's, which is why the call goes through core/signature — it walks the live UFunction
-- and refuses rather than calling when the declaration disagrees. Both arguments are the shapes
-- signature is willing to pass: a float and a live UObject.
--
-- NOT OBSERVED: nobody has heard this change a volume. Wwise's own SetGameObjectOutputBusVolume
-- takes a LINEAR multiplier where 1.0 is unity, so that is what `volume` is treated as; the
-- header says only "float", so linear-vs-dB is read off the Wwise API, not off this build.
-- Returns true only when the call was ISSUED, never a promise that anything got quieter.
function NativeSource:setActorVolume(actor, volume)
    -- The VALUE is checked before anything else, including the actor: a FloatProperty is only
    -- safe to marshal when what reaches it is really a finite non-negative number, and refusing
    -- here costs a false while the alternative costs the session.
    -- `volume ~= volume` is the NaN test; math.huge is refused for the same reason a negative is.
    if type(volume) ~= "number" or volume ~= volume or volume < 0 or volume == math.huge then
        return false
    end
    if not alive(actor) then return false end

    local s = akStatics()
    if not s then return false end

    local ok = sig.call(s, "SetOutputBusVolume", { "FloatProperty", "ObjectProperty" },
        volume * 1.0, actor)
    return ok == true
end

return NativeSource
