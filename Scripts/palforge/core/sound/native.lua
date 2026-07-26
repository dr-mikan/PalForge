-- PalForge core.sound.native: NativeSource — a native Palworld sound played through the
-- game's own sound utility (UPalSoundUtility). Extends the base SoundSource.
--
-- Play mechanism: our catalog ids are Wwise AkAudioEvent NAMES with a known asset PATH, so
-- the route is
--   LoadAsset(assetPath) -> PalSoundUtility:PlayAkEventSoundByActor(actor, asset).
-- PlayAkEventSoundByActor is believed to be a reflected UFunction on the shipping binary, but
-- no run log in this tree records it making a sound and no dump in the parent tree records
-- its parameter list. Credible route, unproven result — see the TODO at the call.
-- PlaySoundByActor({Key=FName(id)}) is SILENT for AkAudioEvent names (its Key is a
-- SoundID-table row, a different namespace) — kept as the fallback for a source that carries
-- an id and no loadable asset. api/audio fills the path in from the AkAudioEvent catalog
-- before we get here, so that fallback is now reached only for names the catalog does not
-- know, i.e. names that plausibly ARE SoundID rows.
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

-- The PalSoundUtility CDO, or nil. Every native call in this file goes through it.
local function soundUtility()
    local u
    pcall(function() u = StaticFindObject("/Script/Pal.Default__PalSoundUtility") end)
    if alive(u) then return u end
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
        -- TODO(audio-akevent-play-signature): UPalSoundUtility::PlayAkEventSoundByActor is
        -- assumed to exist and to take (Actor, AkAudioEvent) in that order, and no run has
        -- ever confirmed it is audible; its reflected parameter list would settle both.
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
-- SoundID-specific, so self.id/self.path are unused here (a per-sound stop needs a Wwise
-- PlayingID this source does not capture). True only when that call was issued.
function NativeSource:stop(actor)
    if not alive(actor) then return false end

    local u = soundUtility()
    if not u then return false end

    local stopped = false
    pcall(function() u:StopSoundByActor(actor); stopped = true end)
    return stopped
end

return NativeSource
