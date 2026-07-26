-- PalForge utils.sound.native: NativeSource — a native Palworld sound played through the
-- game's own sound utility (UPalSoundUtility). Extends the base SoundSource.
--
-- Play mechanism: our catalog ids are Wwise AkAudioEvent NAMES with a known asset PATH, so
-- the route is
--   LoadAsset(assetPath) -> PalSoundUtility:PlayAkEventSoundByActor(actor, asset).
-- PlayAkEventSoundByActor is a real reflected UFunction on the shipping binary, but no run
-- log in this tree records it making a sound (the F1 audio self-test that once claimed it is
-- gone — core/keyboard/base/registory.lua still lists audio as unconfirmed). Credible route,
-- unproven result.
-- PlaySoundByActor({Key=FName(id)}) is SILENT for these (its Key is a SoundID-table row, a
-- different namespace) — kept only as a fallback for a source that carries an id but no path.
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

-- Load (and cache) the AkAudioEvent asset at `path`; nil if it cannot be resolved.
local function loadAsset(path)
    if type(path) ~= "string" or #path == 0 then return nil end
    local a = assetCache[path]
    if a and a:IsValid() then return a end
    a = nil
    pcall(function() if type(LoadAsset) == "function" then a = LoadAsset(path) end end)
    if not (a and a:IsValid()) then pcall(function() a = StaticFindObject(path) end) end
    if a and a:IsValid() then assetCache[path] = a; return a end
    return nil
end

-- Play this sound on `actor`. Fail-soft: an invalid actor / missing utility / a source with
-- neither a loadable asset nor an id is a no-op, not an error — and returns FALSE. `played`
-- is set only after a native call has returned, so a throw inside it leaves it false too.
function NativeSource:play(actor)
    local played = false
    local ok = pcall(function()
        if not (actor and actor:IsValid()) then return end
        local u = StaticFindObject("/Script/Pal.Default__PalSoundUtility")
        if not (u and u:IsValid()) then return end
        -- Preferred: Wwise AkAudioEvent by loaded asset (our catalog path).
        local asset = loadAsset(self.path)
        if asset then
            u:PlayAkEventSoundByActor(actor, asset)
            played = true
            return
        end
        -- Fallback: SoundID-row style id via PlaySoundByActor (no path available). This one
        -- DID reach the engine, hence true — but for an AkAudioEvent name it is the silent
        -- namespace (see the header), so true here still means "issued", never "audible".
        if type(self.id) == "string" and #self.id > 0 then
            u:PlaySoundByActor(actor, { Key = FName(self.id) }, { FadeInTime = 0 })
            played = true
        end
    end)
    return ok and played
end

-- Stop sounds on `actor`. StopSoundByActor stops ALL sounds on the actor and is not
-- SoundID-specific, so self.id/self.path are unused here (a per-sound stop needs a Wwise
-- PlayingID this source does not capture). True only when that call was issued.
function NativeSource:stop(actor)
    local stopped = false
    local ok = pcall(function()
        local u = StaticFindObject("/Script/Pal.Default__PalSoundUtility")
        if u and u:IsValid() and actor and actor:IsValid() then
            u:StopSoundByActor(actor)
            stopped = true
        end
    end)
    return ok and stopped
end

return NativeSource
