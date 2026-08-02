-- palforge/api/audio.lua — PUBLIC audio API + implementation (SELF-CONTAINED).
--
-- Audio is one playable sound: background music or a one-shot effect. Same shape as every
-- other api module (call it to define, plus get / get_all + a Handle object with actions),
-- except that audio has no lifecycle events to subscribe to — you PLAY it, so the Handle's
-- surface is actions. `bgm` and `se` are named constructors that pin `kind`.
--
-- HOW IT INTEGRATES: Audio{ ... } registers the definition class in object_manager under
-- ("audio", id) and lowers the declaration into a source spec that core.sound resolves:
--   soundId / soundPath -> { kind = "native" }  -> core.sound.native  (WORKING)
--   soundFile           -> REFUSED at define time (see below)
--
-- Audio{ spec, opts } takes an optional second argument, like every other domain constructor:
-- `opts.register == false` builds and returns the Handle WITHOUT registering it (a definition
-- a pack wants to hold on to rather than publish), and `opts.pack = "mypackid"` records the
-- owner. Omitting opts behaves exactly as it always did.
--
-- The native route is the game's own route: a catalog entry is a Wwise AkAudioEvent NAME with
-- an asset PATH, played via LoadAsset(path) -> PalSoundUtility:PlayAkEventSoundByActor —
-- a reflected UFunction (dumps/reflection/02_reflection.txt) that a recorded session caught the
-- GAME ITSELF calling, with exactly (AActor, UObject) in that order (06_events.txt, [SOUND.ak]),
-- which is the shape used here. The path is what actually plays;
-- PlaySoundByActor({Key=FName(id)}) is a DIFFERENT namespace (SoundID rows) and is
-- silent for AkAudioEvent names.
--
-- SO A NAME ALONE IS ENOUGH: when a definition carries a soundId and no soundPath, lowering
-- looks the name up in native/audio.lua's generated AkAudioEvent catalog and attaches the
-- real asset path. `Audio.get("AKE_General_Explosion"):play()` and the one-line form
-- `Audio.bgm{ id = "AKE_BGM_Title" }` therefore take the route that plays, instead of
-- resolving onto the silent fallback and still reporting true. A name the catalog does not
-- know keeps the old behaviour (the SoundID fallback), and passing soundPath yourself always
-- wins — nothing is ever overwritten.
--
-- :play returns true only when a native play call was ISSUED for the sound — a definition
-- that names nothing, or a world that has no player pawn, returns false rather than a
-- reassuring true. It is still not a promise of audibility (the engine returns nothing).
--
-- ONE THING HERE IS REFUSED OUTRIGHT, and refusing is the whole point.
--
-- Custom audio FILES are not playable. The in-game F5 harvest (dumps/f5-partial-run.txt) and
-- then dumps/cxx narrowed it to a shape no call in this build can satisfy: the UE-native half is
-- CLOSED — USoundWave declares no importer and USoundWaveProcedural declares nothing at all
-- (Engine.hpp:21335 / :21371), so PlaySound2D survives with nothing to be handed — and the Wwise
-- half exists but takes the wrong input: UWwiseExternalSourceStatics::SetExternalSourceMediaBy*
-- (WwiseFileHandler.hpp:48-50) REBINDS a cooked external-source cookie to media the Wwise cook
-- already staged, which is not a .wav on a pack's disk. core/sound/file.lua carries the full
-- evidence and the one question left open (audio-custom-file-loader in plan/TODO.md).
--
-- `soundFile` USED TO BE ACCEPTED AND THAT WAS THE WORST OF BOTH. It was validated, documented,
-- and it took PRECEDENCE over soundId/soundPath in the lowering below — so a pack that added a
-- soundFile beside a working soundId silenced a sound that had been playing, and :play handed
-- back the false that came out of the file seam. Every other unfinished thing in this framework
-- degrades honestly; that one made working audio silent. So it is now a HARD ERROR at define
-- time, naming the open item and saying what to use instead. The field stays DECLARED in the
-- spec so the error can name it and so tooling still lists it — a field that errors where you
-- typed it costs you a minute; a field that silences your sound costs you an afternoon.
--
-- VOLUME IS NOW WIRED, and it is ACTOR-WIDE, not per sound. Handle:setVolume calls
-- UAkGameplayStatics::SetOutputBusVolume(float, AActor*) (AkAudio.hpp:748) — Wwise's
-- SetGameObjectOutputBusVolume, which scales what one emitter sends to its output bus. The old
-- reading of that function ("a whole output BUS") was wrong: it has no bus name in it, it has
-- the actor. So it lands at exactly the scope :play posts at and :stop clears. It is still not
-- per sound, and the RTPC route that would have been is closed with evidence rather than
-- silence: the build declares three AkRtpc assets — Supply_Altitude, OverHeatRifle,
-- ChargeLaserRifle_01 — and no AkAuxBus and no AkAudioBank, so none of them is a volume and no
-- parameter list would have helped. TO MAKE ONE SOUND QUIETER THAN ANOTHER, PICK A QUIETER
-- EVENT from the catalog — that is still the only per-sound control a pack has.
--
--   local Theme = Audio.bgm{ id = "AKE_BGM_Title", soundId = "AKE_BGM_Title",
--       soundPath = "/Game/Pal/Sound/Events/SE/UI/BGM_Title/AKE_BGM_Title.AKE_BGM_Title" }
--   Theme:play()             -- on the player pawn
--   Theme:stop()
--   Audio.get("AKE_BGM_Title"):play(someActor)
--
-- THAT PATH IS THE CATALOG'S OWN (native/audio.lua:186), AND IT CARRIES ITS `.Object` TAIL.
-- Neither was true of the example this header used to show. It wrote an abbreviated,
-- package-only "/Game/.../AKE_BGM_Title" — which resolves to nothing and falls through to the
-- silent SoundID branch, which returns true. So the module's documented example was the one
-- form that does not play, while every generated catalog entry was the form that does.
-- core/sound/native.lua completes a package-only path through core.assetpath now, so both forms
-- reach the same asset; the example is written in full anyway, because that is the form to copy
-- — and it is copied from the catalog, so it is a path this build actually has (the title BGM
-- lives under Events/SE/UI/BGM_Title/, not under an Events/BGM/ directory, which is exactly the
-- kind of thing an abbreviated example lets you assume).

local om     = require("palforge.core.object_manager")
local sound  = require("palforge.core.sound")
local schema = require("palforge.core.schema")

--=============================================================================
-- SPEC — the shape of Audio{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("Audio.Spec")         -- every field, its type, default and meaning
--   schema.get("Audio.Spec").fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
--=============================================================================

---What you pass to Audio{ ... } / Audio.bgm / Audio.se. `id` is required; a definition
---that names no sound falls back to its own id as the AkAudioEvent name.
-- `id` carries schema.validId, not schema.nonEmpty: a namespaced id has to survive
-- object_manager.resolve to reach the game at all ("pack:Theme" -> "pack_Theme"), and here it
-- has a second reason — a definition that names no sound uses its own id AS the AkAudioEvent
-- name, so an id that cannot resolve becomes a sound name that cannot resolve either. Refused
-- HERE rather than registering and playing nothing. The rule is written once, in core/schema.lua.
local Spec = schema.define("Audio.Spec", {
    { "id",          type = "string", required = true, check = schema.validId,
                     doc = "audio id: the AkAudioEvent name, or \"pack:name\"" },
    { "name",        type = "string", doc = "human label (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "kind",        type = "string", values = { "se", "bgm" }, default = "se",
                     doc = "descriptive only - the native play route is the same for both" },
    { "soundId",     type = "string", doc = "native AkAudioEvent name - its asset path is filled in from the native catalog when you do not pass one" },
    { "soundPath",   type = "string", doc = "native AkAudioEvent asset path (the route that actually plays); overrides the catalog lookup" },
    -- DECLARED SO THE ERROR CAN NAME IT. Setting this is a hard error at define time (see
    -- define() below and the header): it is not playable on this build AND it outranked
    -- soundId/soundPath, so accepting it silenced sounds that worked. It stays in the spec
    -- rather than being deleted so that `schema.help("Audio.Spec")`, the generated types and
    -- the did-you-mean list all still know the name a pack author is about to type.
    { "soundFile",   type = "string", doc = "REFUSED at define time: custom audio files do not play on this build (open item audio-custom-file-loader) - use soundId or soundPath" },
    { "source",      type = "function", sig = "fun(self: Audio.Definition): table|nil",
                     doc = "override that returns the core.sound spec yourself; `self` is the DEFINITION, not the handle" },
    { "data",        type = "table",  doc = "free-form payload of your own, carried onto the definition" },
})

--=============================================================================
-- the registered audio DEFINITION class
--=============================================================================

local Class = {}
Class.__index = Class
Class.kind = "se"

-- The generated AkAudioEvent catalog (event name -> asset path) that native/audio.lua carries,
-- reached LAZILY and through pcall. It has to be lazy: native/audio.lua requires THIS module to
-- build its definitions, so a top-level require here would be a cycle. The kernel loads
-- palforge.native.audio at startup (core/registry), so by the time anything plays this is a
-- table lookup; a session without the catalog simply has no path to add.
local catalog         -- name -> asset path, once native.audio has been seen
local catalogLoading  -- re-entrancy guard: never require the catalog from inside its own load
local function catalogPath(name)
    if type(name) ~= "string" or #name == 0 then return nil end
    if not catalog and not catalogLoading then
        catalogLoading = true
        local mod = package.loaded["palforge.native.audio"]
        if mod == nil then
            local ok, m = pcall(require, "palforge.native.audio")
            mod = ok and m or nil
        end
        if type(mod) == "table" and type(mod.CATALOG) == "table" then catalog = mod.CATALOG end
        catalogLoading = false
    end
    return catalog and catalog[name] or nil
end

-- Lower this declaration into a source spec for core.sound. Returns nil when the definition
-- names no sound. Override for full control.
--
-- A name WITHOUT a path is looked up in the AkAudioEvent catalog and given its real asset
-- path: the path is the branch that produces sound, so a name-only definition that skipped
-- this fell through to PlaySoundByActor and played nothing while still reporting true. A
-- declared soundPath is never overwritten, and an unknown name still lowers to the id alone.
--
-- THE ID IS RESOLVED FIRST, and this is the engine boundary that needed it. A definition's id
-- may be namespaced ("mypack:Theme"), and a namespaced id is not what anything downstream can
-- use: the AkAudioEvent catalog is keyed on event names, and the SoundID fallback puts the id
-- straight into FName(). The colon form matched neither, so a namespaced sound missed the
-- catalog and then posted an FName nothing answers to — it played nothing, silently. `resolve`
-- turns "mypack:Theme" into "mypack_Theme", which is the same transformation the DataTable rows
-- get, and `or id` keeps the LITERAL when resolve refuses the shape, so an id is never dropped
-- on the floor at a boundary (that fallback is the rule, not a local choice — see F-4).
--
-- The soundFile branch stays for the two callers that can still produce a file spec — a `source`
-- override and a direct core.sound call — because Audio{ soundFile = ... } is now refused at
-- define time and can no longer reach here. It is kept, rather than deleted, because a subclass
-- of Audio.Class that sets soundFile itself is entitled to the documented lowering; what it is
-- not entitled to is silence, and core/sound/file.lua returns false rather than pretending.
function Class:source()
    if type(self.soundFile) == "string" and #self.soundFile > 0 then
        return { kind = "file", path = self.soundFile }
    end
    local id   = (type(self.soundId)   == "string" and #self.soundId   > 0) and self.soundId   or nil
    local path = (type(self.soundPath) == "string" and #self.soundPath > 0) and self.soundPath or nil
    if id then id = om.resolve(id) or id end
    if id and not path then path = catalogPath(id) end
    if id or path then
        return { kind = "native", id = id, path = path }
    end
    return nil
end

-- The actor a sound plays on. Defaults to the local player pawn (the confirmed route
-- needs an actor); nil when there is no world yet.
local function defaultActor()
    local a; pcall(function() a = FindFirstOf("PalPlayerCharacter") end)
    if a and a.IsValid and a:IsValid() then return a end
    return nil
end

--=============================================================================
-- TOP — the module surface: Audio{ ... } / Audio.bgm / Audio.se / Audio.get / Audio.get_all
--=============================================================================

---The audio domain. CALL it to define a sound; bgm / se pin `kind`, get looks one up.
---@class palforge.audio
---@overload fun(spec: Audio.Spec, opts: table?): Audio.Handle
local Audio = {}

local wrap  -- forward decl; the Audio.Handle wrapper is defined in the BOTTOM section

-- THE soundFile PUBLISH GATE. Declared, validated, documented — and refused, loudly, here.
-- See the header for why this is an error rather than a warning: soundFile outranked
-- soundId/soundPath in the lowering, so accepting it silenced sounds that were working, and it
-- has never been playable on any build this tree has measured. The message names the open item
-- (audio-custom-file-loader) so nobody has to guess whether it is a bug or a boundary, and it
-- names the two fields that DO play so the fix is one line.
local function refuseSoundFile(spec, who)
    if spec.soundFile == nil then return end
    error(string.format(
        "PalForge: %s: soundFile is not accepted (id %q, soundFile %q). Custom audio files do "
        .. "not play on this build: the UE-native route has no importer that survives shipping "
        .. "(USoundWave declares none, USoundWaveProcedural declares nothing at all) and the "
        .. "Wwise route rebinds media the cook already staged rather than reading a file. This "
        .. "is the open item audio-custom-file-loader. It is an ERROR rather than a no-op "
        .. "because soundFile used to OUTRANK soundId/soundPath, so setting it beside a working "
        .. "soundId silenced a sound that was playing. Name a game sound instead: "
        .. "soundId = \"AKE_UI_Common_Menu_Close\", or soundPath = the asset path from "
        .. "PalForge.native.audio.CATALOG.",
        who, tostring(spec.id), tostring(spec.soundFile)), 0)
end

---Define a playable sound and register it.
---`spec` is validated against Audio.Spec: `id` is required, unknown fields are an error.
---`opts` is the optional second argument every domain constructor takes:
---
---  { register = false }   build and return the handle, register NOTHING — a definition the
---                         caller wants to hold rather than publish (registering is permanent;
---                         object_manager has no expiry).
---  { pack = "mypack" }    register attributed to that pack, which is what gives a collision
---                         a "who". PalForge.pack("mypack").Audio fills it in for you.
---@param spec Audio.Spec
---@param opts table?
---@return Audio.Handle
local function define(spec, opts, who)
    who = who or "Audio"
    local register, pack = schema.defineOpts(opts, who)
    -- The SCHEMA errors stay labelled "Audio" whichever constructor was called: they name the
    -- spec being validated, they are quoted verbatim in the docs, and Audio.bgm/Audio.se
    -- validate against exactly the same one. The refusal below names the constructor instead,
    -- because it is about the call the author made.
    spec = Spec:validate(spec, "Audio")
    refuseSoundFile(spec, who)
    -- A definition that names no sound falls back to its own id as the AkAudioEvent name
    -- — the same thing Audio.get does for an id it has never seen, so the short form
    -- `Audio.bgm{ id = "AKE_BGM_Title" }` plays rather than resolving to nothing.
    -- (soundFile is refused above, so it can no longer take part in this test.)
    local soundId = spec.soundId
    if soundId == nil and spec.soundPath == nil and spec.source == nil then
        soundId = spec.id
    end
    local cls = setmetatable({
        id          = spec.id,
        name        = spec.name or spec.id,
        description = spec.description,
        kind        = spec.kind,
        soundId     = soundId,
        soundPath   = spec.soundPath,
        data        = spec.data,
    }, Class)
    cls.__index = cls
    if spec.source then cls.source = spec.source end
    -- so get() finds it — unless the caller asked for a definition that stays out of the
    -- registry (opts.register == false), which is a build, not a define.
    if register then
        pcall(function() om.register("audio", spec.id, cls, { pack = pack }) end)
    end
    return wrap(cls)
end

-- Calling the module IS defining:  Audio{ id = "AKE_BGM_Title", ... }
setmetatable(Audio, { __call = function(_, spec, opts) return define(spec, opts) end })

-- Same definition with `kind` pinned. The caller's table is never mutated — a stray
-- `kind` in it would be a contradiction, so it is rejected rather than overwritten.
local function defineAs(kind, spec, who, opts)
    if spec ~= nil and type(spec) ~= "table" then
        spec = Spec:validate(spec, who)   -- let the schema produce the type error
    end
    local copy = {}
    for k, v in pairs(spec or {}) do copy[k] = v end
    if copy.kind ~= nil and copy.kind ~= kind then
        error(string.format("PalForge: %s: kind is fixed to %q here, but got %q - use Audio{ ... } to set it",
            who, kind, tostring(copy.kind)), 0)
    end
    copy.kind = kind
    return define(copy, opts, who)
end

---Define background music (kind = "bgm").
---@param spec Audio.Spec
---@param opts table?
---@return Audio.Handle
function Audio.bgm(spec, opts) return defineAs("bgm", spec, "Audio.bgm", opts) end

---Define a one-shot sound effect (kind = "se").
---@param spec Audio.Spec
---@param opts table?
---@return Audio.Handle
function Audio.se(spec, opts) return defineAs("se", spec, "Audio.se", opts) end

---Get an EXISTING sound by id: a previously-defined one, else a thin native definition keyed
---on that id. Lowering resolves the name against the AkAudioEvent catalog, so any catalogued
---event name plays without ever having been defined. Never nil, and never registers.
---@param id string
---@return Audio.Handle
function Audio.get(id)
    assert(type(id) == "string" and #id > 0, "Audio.get: id (string) is required")
    local cls = om.get("audio", id) or setmetatable({ id = id, soundId = id }, Class)
    return wrap(cls)
end

---Every PalForge-registered sound, as a list of handles.
---@return Audio.Handle[]
function Audio.get_all()
    local out = {}
    for _, cls in pairs(om.all("audio")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the audio OBJECT (Audio.Handle): actions
--=============================================================================

---A playable sound. Obtain one from Audio{ ... } / Audio.bgm / Audio.se / Audio.get.
---@class Audio.Handle
---@field id string   # the sound's id
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Play this sound on `actor` (default: the local player pawn). Returns true only when a
---native play call was issued for this sound; a missing world, a definition that names no
---sound and an unresolvable spec are all a fail-soft false.
---@param actor any?
---@return boolean ok
function Handle:play(actor)
    local a = actor or defaultActor()
    if not a then return false end
    return sound.play(self._cls:source(), a)
end

---Stop sounds on `actor` (default: the local player pawn). ACTOR-WIDE by design: the native
---call is StopSoundByActor, so it silences everything playing on that actor and WHICH sound
---you called it on is ignored. The narrower StopSoundByActorWithSoundId is reflected on
---UPalSoundUtility and the dump now declares it —
---`StopSoundByActorWithSoundId(AActor*, const FPalDataTableRowName_SoundID&)` (Pal.hpp:29161) —
---which rules it out twice over: its second parameter is a STRUCT, and it wants a SoundID table
---row, while the AkAudioEvent play route hands back only a bool (Pal.hpp:29170). There is no id
---to give it, so it is not wired.
---Returns true only when that native call was issued.
---@param actor any?
---@return boolean ok
function Handle:stop(actor)
    local a = actor or defaultActor()
    if not a then return false end
    return sound.stop(a)
end

---Set the playback volume on `actor` (default: the local player pawn), as a LINEAR multiplier
---where 1.0 is unity. ACTOR-WIDE by design, exactly like :stop — read that first if you expected
---this to be per sound.
---
---WHAT THIS ACTUALLY MOVES. The native call is
---`UAkGameplayStatics::SetOutputBusVolume(float BusVolume, AActor* Actor)`
---(dumps/cxx/AkAudio.hpp:748), the Blueprint wrapper for Wwise's
---SetGameObjectOutputBusVolume: it scales what ONE emitter — the actor's Wwise game object —
---sends to its output bus. So it moves every sound playing on that actor, ours and the game's
---alike, and WHICH sound handle you called it on is ignored. That is the same scope :play posts
---at and :stop clears, so the actor argument means the same thing in all three.
---
---There is no narrower control on this build, and that is settled rather than untried. The RTPC
---route is closed with evidence: the routes exist (UPalSoundUtility reflects SetRTPCValueByActor
---and SetRTPCValueByActorByEnum, AkGameplayStatics reflects SetRTPCValue / GetRTPCValue /
---ResetRTPCValue) but the whole build declares THREE AkRtpc assets — Supply_Altitude,
---OverHeatRifle, ChargeLaserRifle_01 — and none is a volume, so there was never a parameter for
---them to address. The per-sound AkComponent overload (AkAudio.hpp:663) has no object to be
---called on: PlayAkEventSoundByActor returns a bool (Pal.hpp:29170), not a component and not a
---PlayingID. To make ONE sound quieter than another, still pick a quieter AkAudioEvent.
---
---Returns true only when the native call was ISSUED — there is no world, or no actor, or the
---live declaration disagreed with the dump's and core/signature refused, and you get false.
---True is not a promise that anything got quieter: nothing here has been heard in game. That is
---not a shrug, it is the one thing left owed on this call, and it is owed as a named hook —
---`test/hooks/audio-setvolume-audible`, which needs a loaded world and a person listening:
---play a catalog event, set 0.2, play it again, say whether the second one was quieter. The log
---line the call writes says ISSUED in those words so a reader never mistakes it for a
---measurement (audio-bus-volume in plan/TODO.md closed on the DECLARATION, not on audibility).
---@param volume number   # linear multiplier, 1.0 = unchanged; negative is refused
---@param actor any?
---@return boolean ok
function Handle:setVolume(volume, actor)
    local a = actor or defaultActor()
    if not a then return false end
    return sound.setActorVolume(a, volume)
end

-- ---- queries ----

---The lowered source spec core.sound will resolve ({ kind = "native"|"file", ... } | nil).
---@return table?
function Handle:source() return self._cls:source() end
---@return string  # "bgm" | "se"
function Handle:kind() return self._cls.kind or "se" end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end

Audio.Class = Class   -- the base class (used for subclassing / override detection)
return Audio
