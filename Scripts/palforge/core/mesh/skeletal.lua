-- PalForge utils.mesh.skeletal: the `kind = "skeletal"` mesh backend — a UE-authored
-- USkeletalMesh swapped onto a character/pawn via its USkeletalMeshComponent (the real
-- path for creatures, vs the procedural stand-in).
--
-- API confirmed in-game (F1 mesh probe): the pawn's component is `actor.Mesh` (a
-- PalSkeletalMeshComponent); the setters are `SetSkeletalMeshAsset(mesh)` +
-- `SetAnimClass(animClass)` (UE5.1; there is no SetAnimInstanceClass). Pals guard mesh
-- changes with `SetDisableChangeMesh(bool)`, so we clear it first. SetSkeletalMeshAsset
-- re-renders immediately (no MarkRenderStateDirty needed). Works cleanly on a single-mesh
-- creature; a multi-mesh pawn (the player = body+outfit) only swaps the base component.
--
-- spec (from api/*:render): { model = "<USkeletalMesh path>", animClass = "<ABP _C path>" }.
local Renderer = require("palforge.core.mesh.base.renderer")

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
-- Returns true if the mesh was set. Fail-soft: any missing piece is a no-op, not an error.
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
        local set = pcall(function() mc:SetSkinnedAssetAndUpdate(mesh, true) end)
        if not set then pcall(function() mc:SetSkeletalMeshAsset(mesh) end) end
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
        return true
    end)
    return ok and done == true
end

-- The swap is idempotent (re-setting the same mesh is harmless), so once == attach.
function SkeletalMesh:attachOnce(actor, spec)
    return self:attach(actor, spec)
end

return SkeletalMesh
