-- PalForge utils.sound.native: NativeSource — a native Palworld sound played through the
-- game's own sound utility (UPalSoundUtility). Extends the base SoundSource.
--
-- Play mechanism (CONFIRMED in-game via the F1 audio self-test): our catalog ids are Wwise
-- AkAudioEvent NAMES with a known asset PATH, so the working path is
--   LoadAsset(assetPath) -> PalSoundUtility:PlayAkEventSoundByActor(actor, asset).
-- PlaySoundByActor({Key=FName(id)}) is SILENT for these (its Key is a SoundID-table row, a
-- different namespace) — kept only as a fallback for a source that carries an id but no path.
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

-- Play this sound on `actor`. Returns true if the native call executed (fail-soft: an
-- invalid actor / missing utility / unresolvable asset is a no-op, not an error).
function NativeSource:play(actor)
    return pcall(function()
        if not (actor and actor:IsValid()) then return end
        local u = StaticFindObject("/Script/Pal.Default__PalSoundUtility")
        if not (u and u:IsValid()) then return end
        -- Preferred: Wwise AkAudioEvent by loaded asset (our catalog path).
        local asset = loadAsset(self.path)
        if asset then
            u:PlayAkEventSoundByActor(actor, asset)
            return
        end
        -- Fallback: SoundID-row style id via PlaySoundByActor (no path available).
        if type(self.id) == "string" and #self.id > 0 then
            u:PlaySoundByActor(actor, { Key = FName(self.id) }, { FadeInTime = 0 })
        end
    end)
end

-- Stop sounds on `actor` (native StopSoundByActor stops all sounds on the actor;
-- it is not SoundID-specific, so self.id/self.path are unused here).
function NativeSource:stop(actor)
    return pcall(function()
        local u = StaticFindObject("/Script/Pal.Default__PalSoundUtility")
        if u and u:IsValid() and actor and actor:IsValid() then u:StopSoundByActor(actor) end
    end)
end

return NativeSource
