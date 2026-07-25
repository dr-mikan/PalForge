-- palforge/api/audio.lua — PUBLIC audio API + implementation (SELF-CONTAINED).
--
-- Audio is one playable sound: background music or a one-shot effect. Same shape as every
-- other api module (define / get / get_all + a Handle object with actions), except that
-- audio has no lifecycle events to subscribe to — you PLAY it, so the Handle's surface is
-- actions.
--
-- HOW IT INTEGRATES: Audio.define registers the definition class in object_manager under
-- ("audio", id) and lowers the declaration into a source spec that core.sound resolves:
--   soundId / soundPath -> { kind = "native" }  -> core.sound.native  (WORKING)
--   soundFile           -> { kind = "file"   }  -> core.sound.file    (seam, no-op)
--
-- The native route is CONFIRMED in-game: a catalog entry is a Wwise AkAudioEvent NAME with
-- an asset PATH, played via LoadAsset(path) -> PalSoundUtility:PlayAkEventSoundByActor.
-- Prefer passing BOTH soundId and soundPath (native/audio.lua's catalog does); the path is
-- what actually plays, the id is the SoundID-table fallback.
--
-- Custom audio FILES are not playable yet — Palworld exposes no USoundWave loader we have
-- confirmed, so a `soundFile` definition resolves and no-ops instead of pretending. Volume
-- is likewise unwired (no AkAudio RTPC / component-gain path observed).
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
-- SPEC — the shape of Audio.define, declared as data so it is REFERENCEABLE at
-- runtime and enforced on every call. Reach it as Audio.Spec:
--
--   Audio.Spec:help()   -- print every field, its type, default and meaning
--   Audio.Spec.fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
--=============================================================================

---What you pass to Audio.define / Audio.bgm / Audio.se. `id` is required, plus ONE of
---soundId / soundPath / soundFile (or an own `source` override).
local Spec = schema.define("Audio.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "audio id: the AkAudioEvent name, or \"pack:name\"" },
    { "displayName", type = "string", doc = "human label (defaults to id)" },
    { "kind",        type = "string", values = { "se", "bgm" }, default = "se",
                     doc = "descriptive only - the native play route is the same for both" },
    { "soundId",     type = "string", doc = "native AkAudioEvent name (the SoundID fallback route)" },
    { "soundPath",   type = "string", doc = "native AkAudioEvent asset path (the route that actually plays)" },
    { "soundFile",   type = "string", doc = "custom audio file path (seam - not playable yet)" },
    { "source",      type = "function", sig = "fun(self: Audio.Handle): table|nil",
                     doc = "override that returns the core.sound spec yourself" },
    { "data",        type = "table",  doc = "free-form payload of your own, carried onto the definition" },
})

--=============================================================================
-- the registered audio DEFINITION class
--=============================================================================

local Class = {}
Class.__index = Class
Class.kind = "se"

-- Lower this declaration into a source spec for core.sound. Prefers a custom file over a
-- native id; returns nil when the definition names no sound. Override for full control.
function Class:source()
    if type(self.soundFile) == "string" and #self.soundFile > 0 then
        return { kind = "file", path = self.soundFile }
    end
    if (type(self.soundId) == "string" and #self.soundId > 0)
        or (type(self.soundPath) == "string" and #self.soundPath > 0) then
        return { kind = "native", id = self.soundId, path = self.soundPath }
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
-- TOP — module functions
--=============================================================================

---@class palforge.audio
local Audio = {}

-- The spec, exposed so it can be read, printed and used as a constructor.
Audio.Spec = Spec

local wrap  -- forward decl; the Audio.Handle wrapper is defined in the BOTTOM section

---Define a playable sound and register it.
---`spec` is validated against Audio.Spec: `id` is required, unknown fields are an error.
---@param spec Audio.Spec
---@return Audio.Handle
function Audio.define(spec)
    spec = Spec:validate(spec, "Audio.define")
    local cls = setmetatable({
        id          = spec.id,
        displayName = spec.displayName or spec.id,
        kind        = spec.kind,
        soundId     = spec.soundId,
        soundPath   = spec.soundPath,
        soundFile   = spec.soundFile,
        data        = spec.data,
    }, Class)
    cls.__index = cls
    if spec.source then cls.source = spec.source end
    pcall(function() om.register("audio", spec.id, cls) end)
    return wrap(cls)
end

-- Sugar over define that pins `kind`. The caller's table is never mutated — a stray
-- `kind` in it would be a contradiction, so it is rejected rather than overwritten.
local function defineAs(kind, spec, who)
    if spec ~= nil and type(spec) ~= "table" then
        spec = Spec:validate(spec, who)   -- let the schema produce the type error
    end
    local copy = {}
    for k, v in pairs(spec or {}) do copy[k] = v end
    if copy.kind ~= nil and copy.kind ~= kind then
        error(string.format("PalForge: %s: kind is fixed to %q here, but got %q - use Audio.define to set it",
            who, kind, tostring(copy.kind)), 0)
    end
    copy.kind = kind
    return Audio.define(copy)
end

---Define background music (kind = "bgm"). Sugar over define.
---@param spec Audio.Spec
---@return Audio.Handle
function Audio.bgm(spec) return defineAs("bgm", spec, "Audio.bgm") end

---Define a one-shot sound effect (kind = "se"). Sugar over define.
---@param spec Audio.Spec
---@return Audio.Handle
function Audio.se(spec) return defineAs("se", spec, "Audio.se") end

---Get an EXISTING sound by id: a previously-defined one, else a thin native definition
---keyed on that id (so any AkAudioEvent name is playable if it resolves). Never nil.
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

---A playable sound. Obtain one from Audio.define / Audio.bgm / Audio.se / Audio.get.
---@class Audio.Handle
---@field id string   # the sound's id
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Play this sound on `actor` (default: the local player pawn). Returns true if the native
---call executed; a missing world / unresolvable sound is a fail-soft false.
---@param actor any?
---@return boolean ok
function Handle:play(actor)
    local a = actor or defaultActor()
    if not a then return false end
    return sound.play(self._cls:source(), a)
end

---Stop sounds on `actor` (default: the local player pawn). The native stop is not
---per-sound — it stops everything playing on that actor.
---@param actor any?
---@return boolean ok
function Handle:stop(actor)
    local a = actor or defaultActor()
    if not a then return false end
    return sound.stop(a)
end

---Set the playback volume, 0.0 .. 1.0. NOT IMPLEMENTED — no native volume/gain control
---has been confirmed (needs an AkAudio RTPC or component-gain path). Returns false so a
---caller can tell it did nothing.
---@param volume number
---@return boolean ok
function Handle:setVolume(volume)
    -- TODO: apply volume once an AkAudio RTPC / component-gain route is observed.
    return false
end

-- ---- queries ----

---The lowered source spec core.sound will resolve ({ kind = "native"|"file", ... } | nil).
---@return table?
function Handle:source() return self._cls:source() end
---@return string  # "bgm" | "se"
function Handle:kind() return self._cls.kind or "se" end
---@return string
function Handle:displayName() return self._cls.displayName or self.id end

Audio.Class = Class   -- the base class (used for subclassing / override detection)
return Audio
