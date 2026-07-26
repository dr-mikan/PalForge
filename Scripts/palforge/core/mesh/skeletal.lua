-- PalForge core.mesh.skeletal: the `kind = "skeletal"` mesh backend — a UE-authored
-- USkeletalMesh swapped onto a character/pawn via its USkeletalMeshComponent (the real
-- path for creatures, vs the procedural stand-in).
--
-- NOT CONFIRMED IN-GAME. Nothing in this tree corroborates the chain below — there is no
-- mesh probe, and dump/docs/05_mesh_material.md §5.3 still lists the pawn's component and
-- its setter as things to dump. Written as UE5.1 says they are: the pawn's component is
-- `actor.Mesh` (a PalSkeletalMeshComponent); the setters are `SetSkinnedAssetAndUpdate`
-- / `SetSkeletalMeshAsset` plus `SetAnimClass(animClass)` (there is no
-- SetAnimInstanceClass). Pals guard mesh changes with `SetDisableChangeMesh(bool)`, so we
-- clear it first. Setting the asset re-renders immediately (no MarkRenderStateDirty
-- needed). It would swap a single-mesh creature cleanly; on a multi-mesh pawn (the player
-- = body+outfit) it only reaches the base component.
--
-- Because none of that is proven, attach reports WHICH setter actually executed and
-- returns false when neither did — a UE4SS call into a name the component does not carry
-- raises, so the pcall status separates "ran" from "not there". A true here means a
-- setter ran; confirming it renders is still the open dump task above.
--
-- spec (from api/*:render): { model = "<USkeletalMesh path>", animClass = "<ABP _C path>" }.
local Renderer = require("palforge.core.mesh.base.renderer")
local log      = require("palforge.utils.log").scope("mesh")

local SkeletalMesh = Renderer:extend("SkeletalMeshRenderer")

-- loaded assets cached by path (USkeletalMesh and the ABP UClass alike)
local assetCache = {}
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

-- Resolve the actor's skeletal mesh component (ACharacter.Mesh, with a getter fallback).
local function meshComponentOf(actor)
    local mc; pcall(function() mc = actor.Mesh end)
    if mc and mc:IsValid() then return mc end
    pcall(function() mc = actor:GetMesh() end)
    if mc and mc:IsValid() then return mc end
    return nil
end

-- Swap `actor`'s skeletal mesh (and anim class) to spec.model / spec.animClass.
-- Returns true only if one of the mesh setters actually ran — a component carrying
-- neither is a failure, not a silent success. Fail-soft: any missing piece is a no-op,
-- not an error.
function SkeletalMesh:attach(actor, spec)
    local ok, done = pcall(function()
        if not (actor and actor:IsValid()) then return false end
        local model = spec and (spec.model or spec.asset)
        if type(model) ~= "string" or #model == 0 then return false end
        local mc = meshComponentOf(actor)
        if not mc then return false end
        local mesh = loadAsset(model)
        if not mesh then return false end
        pcall(function() mc:SetDisableChangeMesh(false) end)  -- Pal guard: allow the swap
        -- Set the mesh WITH a render-state update. SetSkinnedAssetAndUpdate(mesh, reinit)
        -- recreates the render state + re-inits the pose, so a cross-skeleton swap renders;
        -- plain SetSkeletalMeshAsset can leave the new mesh INVISIBLE. Fall back if absent.
        -- Keep WHICH setter ran: that is the whole return value, so it cannot be discarded.
        local via
        if pcall(function() mc:SetSkinnedAssetAndUpdate(mesh, true) end) then
            via = "SetSkinnedAssetAndUpdate"
        elseif pcall(function() mc:SetSkeletalMeshAsset(mesh) end) then
            via = "SetSkeletalMeshAsset"
        end
        if not via then
            log.err("skeletal: component carries neither SetSkinnedAssetAndUpdate nor "
                .. "SetSkeletalMeshAsset - mesh NOT set: " .. model)
            return false
        end
        -- optional matching anim class: force AnimationBlueprint mode, then bind the ABP so
        -- the new skeleton is actually driven (an un-driven skinned mesh can cull to nothing).
        local animPath = spec.animClass or spec.anim
        if type(animPath) == "string" and #animPath > 0 then
            local anim = loadAsset(animPath)
            if anim then
                pcall(function() mc:SetAnimationMode(0) end)  -- EAnimationMode::AnimationBlueprint
                pcall(function() mc:SetAnimClass(anim) end)
            end
        end
        log.info("skeletal: set " .. model .. " via " .. via)
        return true
    end)
    return ok and done == true
end

-- The swap is idempotent (re-setting the same mesh is harmless), so once == attach.
function SkeletalMesh:attachOnce(actor, spec)
    return self:attach(actor, spec)
end

return SkeletalMesh
