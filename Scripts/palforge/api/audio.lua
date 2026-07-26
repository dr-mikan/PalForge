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
--   soundFile           -> { kind = "file"   }  -> core.sound.file    (seam, no-op)
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
-- ONE THING HERE STILL DOES NOTHING, and says so rather than pretending.
--
-- Custom audio FILES are not playable. The in-game F5 harvest (dumps/f5-partial-run.txt) and
-- then dumps/cxx narrowed it to a shape no call in this build can satisfy: the UE-native half is
-- CLOSED — USoundWave declares no importer and USoundWaveProcedural declares nothing at all
-- (Engine.hpp:21335 / :21371), so PlaySound2D survives with nothing to be handed — and the Wwise
-- half exists but takes the wrong input: UWwiseExternalSourceStatics::SetExternalSourceMediaBy*
-- (WwiseFileHandler.hpp:48-50) REBINDS a cooked external-source cookie to media the Wwise cook
-- already staged, which is not a .wav on a pack's disk. So a `soundFile` definition resolves and
-- then no-ops, and core/sound/file.lua carries the marker and the remaining question.
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
--   local Theme = Audio.bgm{ id = "AKE_BGM_Title",
--                            soundId = "AKE_BGM_Title", soundPath = "/Game/.../AKE_BGM_Title" }
--   Theme:play()             -- on the player pawn
--   Theme:stop()
--   Audio.get("AKE_BGM_Title"):play(someActor)

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
local Spec = schema.define("Audio.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "audio id: the AkAudioEvent name, or \"pack:name\"" },
    { "name",        type = "string", doc = "human label (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "kind",        type = "string", values = { "se", "bgm" }, default = "se",
                     doc = "descriptive only - the native play route is the same for both" },
    { "soundId",     type = "string", doc = "native AkAudioEvent name - its asset path is filled in from the native catalog when you do not pass one" },
    { "soundPath",   type = "string", doc = "native AkAudioEvent asset path (the route that actually plays); overrides the catalog lookup" },
    { "soundFile",   type = "string", doc = "custom audio file path (seam - not playable yet)" },
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

-- Lower this declaration into a source spec for core.sound. Prefers a custom file over a
-- native id; returns nil when the definition names no sound. Override for full control.
--
-- A name WITHOUT a path is looked up in the AkAudioEvent catalog and given its real asset
-- path: the path is the branch that produces sound, so a name-only definition that skipped
-- this fell through to PlaySoundByActor and played nothing while still reporting true. A
-- declared soundPath is never overwritten, and an unknown name still lowers to the id alone.
function Class:source()
    if type(self.soundFile) == "string" and #self.soundFile > 0 then
        return { kind = "file", path = self.soundFile }
    end
    local id   = (type(self.soundId)   == "string" and #self.soundId   > 0) and self.soundId   or nil
    local path = (type(self.soundPath) == "string" and #self.soundPath > 0) and self.soundPath or nil
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
---@overload fun(spec: Audio.Spec): Audio.Handle
local Audio = {}

local wrap  -- forward decl; the Audio.Handle wrapper is defined in the BOTTOM section

---Define a playable sound and register it.
---`spec` is validated against Audio.Spec: `id` is required, unknown fields are an error.
---@param spec Audio.Spec
---@return Audio.Handle
local function define(spec)
    spec = Spec:validate(spec, "Audio")
    -- A definition that names no sound falls back to its own id as the AkAudioEvent name
    -- — the same thing Audio.get does for an id it has never seen, so the short form
    -- `Audio.bgm{ id = "AKE_BGM_Title" }` plays rather than resolving to nothing.
    local soundId = spec.soundId
    if soundId == nil and spec.soundPath == nil and spec.soundFile == nil and spec.source == nil then
        soundId = spec.id
    end
    local cls = setmetatable({
        id          = spec.id,
        name        = spec.name or spec.id,
        description = spec.description,
        kind        = spec.kind,
        soundId     = soundId,
        soundPath   = spec.soundPath,
        soundFile   = spec.soundFile,
        data        = spec.data,
    }, Class)
    cls.__index = cls
    if spec.source then cls.source = spec.source end
    pcall(function() om.register("audio", spec.id, cls) end)
    return wrap(cls)
end

-- Calling the module IS defining:  Audio{ id = "AKE_BGM_Title", ... }
setmetatable(Audio, { __call = function(_, spec) return define(spec) end })

-- Same definition with `kind` pinned. The caller's table is never mutated — a stray
-- `kind` in it would be a contradiction, so it is rejected rather than overwritten.
local function defineAs(kind, spec, who)
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
    return define(copy)
end

---Define background music (kind = "bgm").
---@param spec Audio.Spec
---@return Audio.Handle
function Audio.bgm(spec) return defineAs("bgm", spec, "Audio.bgm") end

---Define a one-shot sound effect (kind = "se").
---@param spec Audio.Spec
---@return Audio.Handle
function Audio.se(spec) return defineAs("se", spec, "Audio.se") end

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
---True is not a promise that anything got quieter: nothing here has been heard in game.
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
