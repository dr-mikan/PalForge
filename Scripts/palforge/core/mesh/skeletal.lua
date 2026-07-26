-- PalForge core.mesh.skeletal: the `kind = "skeletal"` mesh backend — a UE-authored
-- USkeletalMesh swapped onto a character/pawn via its USkeletalMeshComponent (the real
-- path for creatures, vs the procedural stand-in). This is Mesh.Spec's DEFAULT kind, so
-- it is what a plain `Mesh{ model = "…SK_X.SK_X" }` lands on.
--
-- NOT CONFIRMED IN-GAME. Nothing in either tree corroborates the chain below — there is no
-- mesh probe, and dump/docs/05_mesh_material.md §5.3 still lists the pawn's component and
-- its setter as things to dump. Written as UE5.1 says they are: the pawn's component is
-- `actor.Mesh` (a PalSkeletalMeshComponent); the setters are `SetSkinnedAssetAndUpdate`
-- / `SetSkeletalMeshAsset` plus `SetAnimClass(animClass)` (there is no
-- SetAnimInstanceClass). Pals guard mesh changes with `SetDisableChangeMesh(bool)`, so we
-- clear it first. Setting the asset re-renders immediately (no MarkRenderStateDirty
-- needed). It would swap a single-mesh creature cleanly; on a multi-mesh pawn (the player
-- = body+outfit) it only reaches the base component.
--
-- Because none of that is proven, attach never takes a call on trust:
--   * it records WHICH setter executed and returns false when neither did — a UE4SS call
--     into a name the component does not carry raises, so the pcall status separates
--     "ran" from "not there";
--   * where the component also lets us READ the asset back it compares the read-back to
--     what we set, so a setter that runs and is ignored is a false, not a pretended
--     success. When no read-back path exists, "a setter ran" is the honest ceiling.
--
-- UNLIKE the two component-adding backends, this one dresses a component it does NOT own:
-- the pawn's own body. Everything it changes is therefore captured first (the asset, the
-- relative scale and location, the materials) and put back by :detach, so a pack can undo
-- a swap without reloading the world. That is also why the material layer is applied only
-- when the spec asks for it — an attach that declares no colour leaves the pal's own
-- materials exactly as they were.
--
-- spec (from api/pal:renderOn / api/mesh Handle:attachTo):
--   { model = "<USkeletalMesh path>", animClass = "<ABP _C path>", scale = <number>,
--     offset = { x, y, z }, color = { r,g,b,a }, texture = "<abs png>",
--     material = "<base material path>", params = { ... } }
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
    if not actor then return nil end
    local mc; pcall(function() mc = actor.Mesh end)
    if mc and mc.IsValid and mc:IsValid() then return mc end
    mc = nil
    pcall(function() mc = actor:GetMesh() end)
    if mc and mc.IsValid and mc:IsValid() then return mc end
    return nil
end

-- Read the skinned asset back off a component. Four independent paths (UE5 renamed
-- USkinnedMeshComponent's asset from SkeletalMesh to SkinnedAsset), so the confirm does
-- not hinge on a single unverified name. Returns nil when none of them answered — which
-- is a "cannot tell", not a "not set".
local function assetOn(mc)
    local a
    pcall(function() a = mc:GetSkinnedAsset() end)
    if a and a.IsValid and a:IsValid() then return a end
    a = nil; pcall(function() a = mc:GetSkeletalMeshAsset() end)
    if a and a.IsValid and a:IsValid() then return a end
    a = nil; pcall(function() a = mc.SkinnedAsset end)
    if a and a.IsValid and a:IsValid() then return a end
    a = nil; pcall(function() a = mc.SkeletalMesh end)
    if a and a.IsValid and a:IsValid() then return a end
    return nil
end

-- Identity by full name: two UE4SS handles onto one UObject are not necessarily equal,
-- so a name is the only comparison that means anything. nil when it cannot be read.
local function nameOf(o)
    local n
    pcall(function() n = o:GetFullName() end)
    if type(n) == "string" and #n > 0 then return n end
    return nil
end

-- Run the mesh setters in order, returning the name of the one that executed, or nil.
-- SetSkinnedAssetAndUpdate(mesh, reinit) recreates the render state + re-inits the pose,
-- so a cross-skeleton swap renders; plain SetSkeletalMeshAsset can leave the new mesh
-- INVISIBLE. Fall back only if the first is absent.
-- TODO(mesh-skeletal-setter): neither the pawn's mesh-component property nor these setter
-- names are dumped anywhere — a probe must confirm which of them a live pal actually
-- carries before a true here can be read as "the pal changed shape".
local function setMesh(mc, mesh)
    if pcall(function() mc:SetSkinnedAssetAndUpdate(mesh, true) end) then return "SetSkinnedAssetAndUpdate" end
    if pcall(function() mc:SetSkeletalMeshAsset(mesh) end) then return "SetSkeletalMeshAsset" end
    return nil
end

-- What the pawn wore before we touched it, per actor, so detach can put it back:
--   { comp, asset, scale = { X,Y,Z }, loc = { X,Y,Z } }
-- __mode="k" weak table, so a pawn that goes away drops out on its own.
local originalOf = setmetatable({}, { __mode = "k" })

-- The component this backend dressed `actor` with (base/renderer contract). This is what
-- gives skeletal a working setColor: the base makes the MID on demand from it, so a pal
-- swapped in with no colour declared can still be re-tinted afterwards.
function SkeletalMesh:componentFor(actor) return meshComponentOf(actor) end

-- Read a component's relative scale / location, for the restore record. nil when the
-- property is not readable — in which case that axis of the change is simply not applied,
-- since a change we could not undo is worse than one we never made.
local function vecOf(mc, prop)
    local v
    pcall(function() v = mc[prop] end)
    if type(v) ~= "userdata" and type(v) ~= "table" then return nil end
    local out
    pcall(function() out = { X = v.X, Y = v.Y, Z = v.Z } end)
    if out and tonumber(out.X) and tonumber(out.Y) and tonumber(out.Z) then return out end
    return nil
end

-- Swap `actor`'s skeletal mesh (and anim class) to spec.model / spec.animClass, then
-- apply the declared scale / offset / material. Returns true only if one of the mesh
-- setters actually ran AND, where the asset can be read back, the read-back agrees with
-- what we set. Fail-soft: any missing piece is a logged no-op, not an error.
function SkeletalMesh:attach(actor, spec)
    local ok, done = pcall(function()
        if not (actor and actor.IsValid and actor:IsValid()) then return false end
        local model = spec and (spec.model or spec.asset)
        if type(model) ~= "string" or #model == 0 then return false end
        local mc = meshComponentOf(actor)
        if not mc then
            log.err("skeletal: actor carries no readable mesh component (.Mesh / :GetMesh())")
            return false
        end
        local mesh = loadAsset(model)
        if not mesh then log.err("skeletal: cannot resolve mesh " .. model); return false end

        -- capture EVERYTHING we are about to change, before changing it (see header)
        if originalOf[actor] == nil then
            originalOf[actor] = {
                comp  = mc,
                asset = assetOn(mc),
                scale = vecOf(mc, "RelativeScale3D"),
                loc   = vecOf(mc, "RelativeLocation"),
            }
        end

        pcall(function() mc:SetDisableChangeMesh(false) end)  -- Pal guard: allow the swap
        local via = setMesh(mc, mesh)
        if not via then
            log.err("skeletal: component carries neither SetSkinnedAssetAndUpdate nor "
                .. "SetSkeletalMeshAsset - mesh NOT set: " .. model)
            return false
        end
        -- confirm, where the component lets us: a setter that runs and is ignored is a
        -- false. A component with no readable asset is a "cannot tell", so it stands.
        local back, want = nameOf(assetOn(mc)), nameOf(mesh)
        if back and want and back ~= want then
            log.err("skeletal: " .. via .. " ran but the component still wears " .. back)
            return false
        end

        -- optional matching anim class: force AnimationBlueprint mode, then bind the ABP so
        -- the new skeleton is actually driven (an un-driven skinned mesh can cull to nothing).
        local animPath = spec.animClass or spec.anim
        if type(animPath) == "string" and #animPath > 0 then
            local anim = loadAsset(animPath)
            if not anim then
                log.warn("skeletal: cannot resolve animClass " .. animPath .. " - the swapped "
                    .. "mesh keeps the pawn's existing animation blueprint")
            else
                -- TODO(mesh-skeletal-animclass): SetAnimClass / SetAnimationMode are
                -- written as UE5 names them, but nothing dumps them on a Pal component and
                -- the enum value 0 for AnimationBlueprint is likewise assumed — if either
                -- is wrong the swapped mesh stands still or culls to nothing.
                pcall(function() mc:SetAnimationMode(0) end)  -- EAnimationMode::AnimationBlueprint
                if not pcall(function() mc:SetAnimClass(anim) end) then
                    log.warn("skeletal: SetAnimClass is not on this component - animClass dropped")
                end
            end
        end

        -- scale / offset. Only applied when DECLARED and only when we captured the
        -- original, so nothing we cannot undo is written to a pawn we do not own. The
        -- offset is additive: a character's mesh component sits at a deliberate relative
        -- location (the capsule half-height), and overwriting it would sink the model.
        local rec = originalOf[actor]
        if spec.scale and rec.scale then
            local s = tonumber(spec.scale) or 1.0
            pcall(function() mc:SetWorldScale3D({ X = s, Y = s, Z = s }) end)
        end
        local o = spec.offset
        if type(o) == "table" and rec.loc then
            local base = rec.loc
            pcall(function()
                mc:K2_SetRelativeLocation({ X = base.X + (o.x or o[1] or 0),
                                            Y = base.Y + (o.y or o[2] or 0),
                                            Z = base.Z + (o.z or o[3] or 0) }, false, {}, false)
            end)
        end

        -- material layer on the pawn's own component. `always` is off: an attach that
        -- declared nothing leaves the pal's materials untouched (setColor makes the MID
        -- later if it is ever asked to).
        local st = self:dressMaterial(mc, actor, spec, {})
        log.info("skeletal: set " .. model .. " via " .. via
            .. (st ~= "none" and (" material [" .. st .. "]") or ""))
        return true
    end)
    return ok and done == true
end

-- The swap is idempotent (re-setting the same mesh is harmless), so once == attach.
function SkeletalMesh:attachOnce(actor, spec)
    return self:attach(actor, spec)
end

-- Put the pawn back the way attach found it: its own asset, relative scale, relative
-- location and materials. Unlike procedural / static there is no component of ours to
-- destroy — the undo IS the restore — so this returns true only when the asset we
-- captured was actually re-set. Nothing captured (we never dressed this actor, or the
-- component would not tell us what it wore) is an honest false.
function SkeletalMesh:detach(actor)
    if not actor then return false end
    local rec = originalOf[actor]
    if not rec then return false end
    local mc = rec.comp
    local live = false
    pcall(function() live = mc:IsValid() == true end)
    if not live then
        originalOf[actor] = nil
        self:forgetMaterial(actor)
        return false
    end

    self:forgetMaterial(actor)  -- puts the captured material interfaces back on their slots
    if rec.scale then pcall(function() mc:SetRelativeScale3D(rec.scale) end) end
    if rec.loc then pcall(function() mc:K2_SetRelativeLocation(rec.loc, false, {}, false) end) end

    if not rec.asset then
        -- we changed the mesh but the component never told us what it had been, so the
        -- one thing that matters cannot be undone. Keep the record: a later detach with a
        -- readable component would still be able to try.
        log.warn("skeletal: detach cannot restore the original mesh (the component would "
            .. "not read its asset back at attach time)")
        return false
    end
    pcall(function() mc:SetDisableChangeMesh(false) end)
    local via = setMesh(mc, rec.asset)
    if not via then
        log.warn("skeletal: detach failed (neither mesh setter is on this component)")
        return false
    end
    originalOf[actor] = nil
    return true
end

return SkeletalMesh
