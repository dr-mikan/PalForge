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
-- THIS LOADER USED TO BE THE UN-HARDENED TWIN OF THE MESH LOADER, and that is fixed here
-- rather than in a comment. It did LoadAsset -> StaticFindObject and handed whatever came back
-- straight into a typed native parameter, with no path normalization, no class check and no
-- signature walk — all three of which core/mesh/assets.lua has had for as long as it has
-- existed, and it has them BECAUSE handing a wrong-typed object to a typed setter "faults
-- inside UE4SS's marshalling where pcall cannot see it; that is the shape that closed the game
-- once." A pack writing `soundPath = Mesh.assets.SM.ChestWood` reached exactly that shape: a
-- UStaticMesh marshalled into a `UAkAudioEvent*`. All three are now in loadAsset/play below,
-- and each says at its own site what it is for.
--
-- The two routes still fall through in order: if the AkAudioEvent route does not issue — the
-- asset did not resolve, it resolved as the wrong class, or core/signature refused the call
-- because the live declaration disagrees with the dump's — the source still tries the id route
-- instead of the whole play collapsing to false. What changed is that the first route no longer
-- reaches the engine on an unread declaration; it used to be a bare pcall, and a pcall is no
-- defence at all against the failure that matters (a TYPE mismatch faults natively; only an
-- ARITY mismatch raises a catchable Lua error).
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
local uo          = require("palforge.core.uobject")
local assetpath   = require("palforge.core.assetpath")
local log         = require("palforge.utils.log").scope("sound")

local NativeSource = SoundSource:extend("NativeSource")

-- Loaded AkAudioEvent assets cached by NORMALIZED path (LoadAsset once, reuse forever).
-- Successes only, and only after the class check below has passed: a miss is often "the
-- package has not streamed in yet", and caching that would make a sound unplayable for the
-- rest of the session.
local assetCache = {}

-- Paths already reported as unresolvable / wrong-class, so a definition that names a bad path
-- says so ONCE instead of on every :play. The set is the diagnosis, not a cache: the asset is
-- still retried, only the log line is suppressed.
local noted = {}

-- Has the "SetOutputBusVolume ISSUED" line been said this session? See setActorVolume.
local volumeNoted = false

-- Liveness is core.uobject's now (uo.live). The private `alive` this file used to carry was
-- one of three identical copies (mesh assets, sound, icons), and keeping them apart is how
-- this loader ended up without the class check the mesh one has. Same semantics as before:
-- every engine touch inside a pcall, because a stale handle can throw on the IsValid call
-- itself and none of the callers may let that escape.

-- Load (and cache) the AkAudioEvent asset at `path`; nil if it cannot be resolved, or if what
-- resolved is not an AkAudioEvent.
--
-- NORMALIZE FIRST. A UE object path is `<package>.<object>` and LoadAsset wants both halves.
-- Every entry in native/audio.lua's generated catalog carries the tail, which is why the
-- catalog route played and the hand-written route did not: api/audio.lua's own documented
-- example wrote a package-only `soundPath = "/Game/.../AKE_BGM_Title"`, which resolved to
-- nothing and fell through to the SILENT SoundID branch — which returns true. Completing the
-- path through core.assetpath makes the two forms reach the same object. A path that already
-- carries an object half is returned verbatim, because the tail is not always a repeat of the
-- package name (see the Sm_Mug case recorded in core/assetpath.lua).
--
-- THEN CLASS-CHECK, BEFORE THE OBJECT CAN BE MARSHALLED. The asset goes into a parameter the
-- build declares as `UAkAudioEvent*` (dumps/cxx/Pal.hpp:29170), and a wrong-typed object in a
-- typed native parameter faults inside UE4SS's own marshalling, where pcall cannot see it —
-- the process dies. `soundPath = Mesh.assets.SM.ChestWood` is an ordinary mistake to make and
-- it resolves to a perfectly live UStaticMesh, so "it loaded" is not the question. This turns
-- that into an English refusal naming what it actually got, which is exactly what
-- core/mesh/assets.lua's opts.class check does for the mesh setters.
local function loadAsset(path)
    if type(path) ~= "string" or #path == 0 then return nil end
    local full = assetpath.normalize(path)

    local cached = assetCache[full]
    if uo.live(cached) then return cached end
    assetCache[full] = nil

    local a
    pcall(function() if type(LoadAsset) == "function" then a = LoadAsset(full) end end)
    if not uo.live(a) then a = nil; pcall(function() a = StaticFindObject(full) end) end
    if not uo.live(a) then
        if not noted[full] then
            noted[full] = true
            log.warn(string.format("%s did not resolve (LoadAsset ran and StaticFindObject found "
                .. "nothing under that name - check the <package>.<object> tail); this sound can "
                .. "only take the silent SoundID fallback", full))
        end
        return nil
    end

    if not uo.isA(a, "AkAudioEvent") then
        if not noted[full] then
            noted[full] = true
            log.err(string.format("refused to play %s: it is a %s, not an AkAudioEvent. "
                .. "PlayAkEventSoundByActor declares UAkAudioEvent* (dumps/cxx/Pal.hpp:29170), and "
                .. "an object of the wrong class in a typed native parameter faults inside UE4SS's "
                .. "marshalling where pcall cannot see it - so it is not passed", full,
                uo.className(a) or "an object whose class will not answer"))
        end
        return nil
    end

    assetCache[full] = a
    return a
end

-- The PalSoundUtility CDO, or nil. Every play/stop call in this file goes through it.
local function soundUtility()
    local u
    pcall(function() u = StaticFindObject("/Script/Pal.Default__PalSoundUtility") end)
    if uo.live(u) then return u end
    return nil
end

-- The AkGameplayStatics CDO, or nil. Only setActorVolume uses it: volume is the one thing
-- UPalSoundUtility does not expose (its 13 functions are play / stop / switch / RTPC, and the
-- RTPC half was closed with evidence — the build declares three AkRtpc assets and none is a
-- volume). The live run resolved this CDO by this exact path (dumps/f5-partial-run.txt:49).
local function akStatics()
    local o
    pcall(function() o = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics") end)
    if uo.live(o) then return o end
    return nil
end

-- Play this sound on `actor`. Fail-soft: an invalid actor / missing utility / a source with
-- neither a loadable asset nor an id is a no-op, not an error — and returns FALSE. `played`
-- is set only after a native call has returned, so a throw inside it leaves it false too.
function NativeSource:play(actor)
    if not uo.live(actor) then return false end

    local u = soundUtility()
    if not u then return false end

    -- Preferred: Wwise AkAudioEvent by loaded asset (the catalog path). This is the branch
    -- that is expected to make noise.
    local asset = loadAsset(self.path)
    if asset then
        -- Argument shape is not a guess: the game's own calls to this function are
        -- (AActor, UObject) on the PalSoundUtility callee, two parameters, that order
        -- (06_events.txt [SOUND.ak]), and dumps/cxx/Pal.hpp:29170 declares
        -- `bool PlayAkEventSoundByActor(AActor*, UAkAudioEvent*)` — which is exactly this call.
        --
        -- It goes through core/signature rather than a bare pcall, the way the mesh path does.
        -- signature walks the LIVE UFunction's parameter list and refuses when the installed
        -- build disagrees with the dump, which is the only defence there is against a TYPE
        -- mismatch: UE4SS faults inside its own argument marshalling and pcall does not see it.
        -- Both parameters are ObjectProperty, the one kind signature will still pass on
        -- "present" evidence (a userdata IS the pointer — there is no layout to get wrong), so
        -- a build that will not walk a UFunction's properties still plays.
        --
        -- A true return still only means ISSUED. The call hands back a bool we do not read,
        -- and nothing in it reports audibility.
        local ok = sig.call(u, "PlayAkEventSoundByActor", { "ObjectProperty", "ObjectProperty" },
            actor, asset)
        if ok == true then return true end
    end

    -- Fallback: SoundID-row style id via PlaySoundByActor (no asset loaded, the asset was the
    -- wrong class, or the AkAudioEvent call was refused). This one DID reach the engine, hence
    -- true — but for an AkAudioEvent name it is the silent namespace (see the header), so true
    -- here means "issued", never "audible".
    --
    -- It stays a raw pcall on purpose, and the reason is worth stating: its two arguments are
    -- STRUCTS, and core/signature refuses a struct on anything short of a completed parameter
    -- walk (UNVERIFIABLE_KINDS) precisely because a struct is what marshals by layout. Routing
    -- it through signature would therefore refuse it on most builds while changing nothing
    -- about the shape being passed. The struct FIELD names (Key / FadeInTime) are still the
    -- one assumption in this file that no dump has confirmed.
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
    if not uo.live(actor) then return false end

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
-- HEARD ONCE, HEDGED, AND STILL NOT SETTLED. Wwise's own SetGameObjectOutputBusVolume takes a
-- LINEAR multiplier where 1.0 is unity, so that is what `volume` is treated as; the header says
-- only "float", so linear-vs-dB is read off the Wwise API, not off this build.
-- test/hooks/audio-setvolume-audible ran on 2026-08-02 at 21:39 — four plays 8 s apart at
-- 1.0 / 0.25 / 0.0 / 1.0, every call returning true, unity restored — and the operator reported,
-- hedged, that steps 2 and 3 seemed quieter. The direction matched the prediction. What that run
-- did NOT establish is whether 0.00 was SILENT, so the hook stays open and a second run, with the
-- listener told in advance that the question is silence rather than loudness, is what closes it.
-- Returns true only when the call was ISSUED, never a promise that anything got quieter — and
-- the log line below says "ISSUED" in those words for the same reason.
function NativeSource:setActorVolume(actor, volume)
    -- The VALUE is checked before anything else, including the actor: a FloatProperty is only
    -- safe to marshal when what reaches it is really a finite non-negative number, and refusing
    -- here costs a false while the alternative costs the session.
    -- `volume ~= volume` is the NaN test; math.huge is refused for the same reason a negative is.
    if type(volume) ~= "number" or volume ~= volume or volume < 0 or volume == math.huge then
        return false
    end
    if not uo.live(actor) then return false end

    local s = akStatics()
    if not s then return false end

    local ok, _, level = sig.call(s, "SetOutputBusVolume", { "FloatProperty", "ObjectProperty" },
        volume * 1.0, actor)
    if ok == true and not volumeNoted then
        -- ONCE per session, deliberately: a fade calls this every frame, and a per-call line
        -- would bury the log. The word that matters is ISSUED — the engine returns nothing, so
        -- this line is a record that the call was made and NOT a claim that anything got
        -- quieter. One hedged listener report is all there is (see the note above).
        volumeNoted = true
        log.info(string.format("SetOutputBusVolume x%.3f ISSUED on the actor's Wwise game object "
            .. "[%s] - actor-wide, and issued is all it means: one hedged listener report "
            .. "(2026-08-02) matched the direction, and nothing has established that 0.00 is "
            .. "SILENT, which is what test/hooks/audio-setvolume-audible is still for. Said once.",
            volume, tostring(level)))
    end
    return ok == true
end

return NativeSource
