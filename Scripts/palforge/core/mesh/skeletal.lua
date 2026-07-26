-- PalForge core.mesh.skeletal: the `kind = "skeletal"` mesh backend — a UE-authored
-- USkeletalMesh swapped onto a character/pawn via its USkeletalMeshComponent (the real
-- path for creatures, vs the procedural stand-in). This is Mesh.Spec's DEFAULT kind, so
-- it is what a plain `Mesh{ model = "…SK_X.SK_X" }` lands on.
--
-- THE WHOLE CHAIN IS DECLARED, and every link is now cited off the shipping binary
-- rather than written from memory of UE5. dumps/cxx spells the class ladder out:
--
--   APalCharacter : ACharacter                        Pal.hpp:8956
--   ACharacter::Mesh -> USkeletalMeshComponent*       Engine.hpp:8156 (offset 0x0318)
--   UPalSkeletalMeshComponent : USkeletalMeshComponent  Pal.hpp:28853
--   USkeletalMeshComponent : USkinnedMeshComponent    Engine.hpp:20574
--   USkinnedMeshComponent : UMeshComponent            Engine.hpp:20809
--
-- so a pal's mesh component really is reached as `actor.Mesh` — a reflected UProperty, not
-- a getter. No `GetMesh()` UFunction is declared on ACharacter, on APalCharacter, or on
-- anything else in the 1579-header dump (the single hit is an unrelated Houdini plugin
-- class), so the getter this file used to try after `.Mesh` could only ever raise and be
-- swallowed; it is gone. The calls the component carries, all inherited by
-- UPalSkeletalMeshComponent:
--
--   void SetSkinnedAssetAndUpdate(USkinnedAsset* NewMesh, bool bReinitPose)  Engine.hpp:20862
--   USkinnedAsset* GetSkinnedAsset()                                        Engine.hpp:20881
--   void SetAnimationMode(TEnumAsByte<EAnimationMode::Type> InAnimationMode) Engine.hpp:20670
--   void SetAnimClass(UClass* NewClass)                                     Engine.hpp:20669
--   void SetDisableChangeMesh(bool Disable)                       Pal.hpp:28899 (Pal's own)
--
-- Pals guard mesh changes with SetDisableChangeMesh, so we clear it first. Setting the
-- asset re-renders immediately (no MarkRenderStateDirty needed). It swaps a single-mesh
-- creature cleanly; on a multi-mesh pawn (the player = body+outfit) it only reaches the
-- base component.
--
-- STILL UNOBSERVED, and that has not changed: a declaration is not a watched success.
-- Nothing in either tree has seen a pal visibly change shape, the dump is one game patch
-- (2026-07-09) behind the installed binary (2026-07-16), and so attach still never takes a
-- call on trust:
--   * the mesh setter goes through core.signature, which asks the LIVE class before an
--     argument is marshalled and returns false rather than firing if it disagrees;
--   * it reads the asset back and compares it to what we set, so a setter that runs and is
--     ignored is a false, not a pretended success. When the read-back answers nothing,
--     "the setter ran" is the honest ceiling.
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
local assets   = require("palforge.core.mesh.assets")
local sig      = require("palforge.core.signature")
local log      = require("palforge.utils.log").scope("mesh")

local SkeletalMesh = Renderer:extend("SkeletalMeshRenderer")

-- The declared shape of USkinnedMeshComponent::SetSkinnedAssetAndUpdate, in the order
-- core.signature checks it: `USkinnedAsset* NewMesh` is an ObjectProperty and
-- `bool bReinitPose` a BoolProperty (dumps/cxx/Engine.hpp:20862). Both are scalars — a
-- pointer and a bool — so this call can still fire on "present" evidence, i.e. on a build
-- whose UE4SS will not walk a UFunction's properties.
local MESH_SETTER_PARAMS = { "ObjectProperty", "BoolProperty" }

-- WHAT THE SETTER'S PARAMETER ACTUALLY ACCEPTS, and it is not "a mesh". Engine.hpp:20862
-- says `USkinnedAsset* NewMesh`, and the class ladder makes that a real restriction rather
-- than a formality: `USkeletalMesh : USkinnedAsset : UStreamableRenderAsset` (:20511, :20802)
-- but `UStaticMesh : UStreamableRenderAsset` (:21631) — SIBLINGS. A UStaticMesh is not a
-- USkinnedAsset and never was, so handing one to this call is a wrong argument TYPE, which is
-- the failure mode that faults inside UE4SS's marshalling where pcall cannot catch it.
--
-- That was reachable from ordinary pack code until now: Mesh.Spec defaults `kind` to
-- "skeletal", so `Pal{ mesh = { model = "/Game/.../SM_ChestWood.SM_ChestWood" } }` — a
-- perfectly reasonable thing to type — resolved a UStaticMesh and passed it straight in. The
-- resolve is class-checked for exactly that reason and the mismatch is an English error.
local ASSET_CLASS = "SkinnedAsset"

-- The class SetAnimClass wants. `UAnimBlueprintGeneratedClass : UBlueprintGeneratedClass :
-- UClass` (Engine.hpp:10073, :11168), and dumps/reflection/04_live_objects.txt:15 confirms the
-- name from the other end: reading AnimClass off a live pawn printed
-- `AnimBlueprintGeneratedClass /Game/Pal/Blueprint/Character/Player/ABP_Player.ABP_Player_C`.
local ANIM_CLASS = "AnimBlueprintGeneratedClass"

-- Resolve the actor's skeletal mesh component. ONE route: the reflected UProperty
-- `class USkeletalMeshComponent* Mesh` on ACharacter (dumps/cxx/Engine.hpp:8156), which
-- APalCharacter inherits (Pal.hpp:8956). The `actor:GetMesh()` attempt that used to follow
-- it is removed — no UFunction of that name is declared anywhere in dumps/cxx, so it was a
-- second spelling that could never answer.
local function meshComponentOf(actor)
    if not actor then return nil end
    local mc; pcall(function() mc = actor.Mesh end)
    if mc and mc.IsValid and mc:IsValid() then return mc end
    return nil
end

-- Read the skinned asset back off a component. ONE route, the getter that pairs with the
-- setter we use: `USkinnedAsset* GetSkinnedAsset()` on USkinnedMeshComponent
-- (dumps/cxx/Engine.hpp:20881), zero arguments. The three other spellings this used to
-- walk are not gone because they are wrong — GetSkeletalMeshAsset (Engine.hpp:20707) and
-- the UProperties SkeletalMesh (:20811) / SkinnedAsset (:20812) are all really declared —
-- but because a read-back needs one answer, not four attempts at one, and this is the one
-- that reads exactly what SetSkinnedAssetAndUpdate writes. (The `SkeletalMesh` property is
-- the UE4-era name, kept alongside its replacement; the class also carries a
-- GetSkeletalMesh_DEPRECATED, which is how the dump says which of the pair is current.)
-- Returns nil when the component would not answer — a "cannot tell", not a "not set".
local function assetOn(mc)
    local a
    pcall(function() a = mc:GetSkinnedAsset() end)
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

-- Set the component's mesh, returning the name of the setter that executed, or nil.
--
-- ONE route now. Both spellings this used to try in turn are really declared —
-- SetSkinnedAssetAndUpdate(USkinnedAsset*, bool) at dumps/cxx/Engine.hpp:20862 on
-- USkinnedMeshComponent, SetSkeletalMeshAsset(USkeletalMesh*) at :20654 on
-- USkeletalMeshComponent — and a UPalSkeletalMeshComponent inherits both, so the second
-- was never a fallback for anything: it could only ever have run if the first had, too.
-- That makes the choice a straight one on behaviour, and it goes to the first:
-- SetSkinnedAssetAndUpdate recreates the render state and re-inits the pose, so a
-- cross-skeleton swap renders, where plain SetSkeletalMeshAsset can leave the new mesh
-- invisible. `bReinitPose = true` is the second argument the other setter does not have,
-- and it is the whole reason to prefer it.
--
-- A USkeletalMesh is a USkinnedAsset, so the asset a spec names satisfies this parameter.
--
-- Through core.signature: the live class is asked for the declaration before the argument
-- is marshalled, and a build that disagrees gets a refusal that never touches the game
-- rather than a native fault. What the mesh-skeletal-setter marker used to sit here for is
-- now only the observation half — nobody has watched a pal change shape — which no dump
-- can supply.
local function setMesh(mc, mesh)
    local ok = sig.call(mc, "SetSkinnedAssetAndUpdate", MESH_SETTER_PARAMS, mesh, true)
    return ok and "SetSkinnedAssetAndUpdate" or nil
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
-- apply the declared scale / offset / material. Returns true only if the mesh setter
-- actually ran AND, where the asset can be read back, the read-back agrees with what we
-- set. Fail-soft: any missing piece is a logged no-op, not an error.
function SkeletalMesh:attach(actor, spec)
    local ok, done = pcall(function()
        if not (actor and actor.IsValid and actor:IsValid()) then return false end
        local model = spec and (spec.model or spec.asset)
        if type(model) ~= "string" or #model == 0 then return false end
        local mc = meshComponentOf(actor)
        if not mc then
            log.err("skeletal: actor carries no readable .Mesh component (ACharacter::Mesh, "
                .. "dumps/cxx/Engine.hpp:8156) - it is probably not an APalCharacter")
            return false
        end
        -- THE PRIMARY ROUTE: a /Game/... path, loaded and class-checked (see ASSET_CLASS).
        -- core/mesh/assets.lua carries the measured ones — assets.SK.PinkCat is the entry
        -- whose mesh AND animation blueprint were read off the same live pawn.
        local mesh, merr = assets.load(model, { class = ASSET_CLASS })
        if not mesh then log.err("skeletal: " .. tostring(merr)); return false end

        -- capture EVERYTHING we are about to change, before changing it (see header)
        if originalOf[actor] == nil then
            originalOf[actor] = {
                comp  = mc,
                asset = assetOn(mc),
                scale = vecOf(mc, "RelativeScale3D"),
                loc   = vecOf(mc, "RelativeLocation"),
            }
        end

        -- Pal's own guard: SetDisableChangeMesh(bool Disable) on UPalSkeletalMeshComponent
        -- (dumps/cxx/Pal.hpp:28899), one BoolProperty. `false` = stop disabling, i.e. allow
        -- the swap. pcall'd rather than routed through core.signature because a component
        -- that is a plain USkeletalMeshComponent instead of Pal's subclass legitimately
        -- does not have it, and that is not worth a log line on every attach.
        pcall(function() mc:SetDisableChangeMesh(false) end)
        local via = setMesh(mc, mesh)
        if not via then
            log.err("skeletal: SetSkinnedAssetAndUpdate did not fire on this component "
                .. "(core.signature has logged whether it was refused or raised) - mesh "
                .. "NOT set: " .. model)
            return false
        end
        -- confirm, where the component lets us: a setter that runs and is ignored is a
        -- false. A component with no readable asset is a "cannot tell", so it stands.
        local back, want = nameOf(assetOn(mc)), nameOf(mesh)
        if back and want and back ~= want then
            log.err("skeletal: " .. via .. " ran but the component still wears " .. back)
            return false
        end

        -- Optional matching anim class: force AnimationBlueprint mode, then bind the ABP so
        -- the new skeleton is actually driven (an un-driven skinned mesh can cull to nothing).
        --
        -- THE RESOLVE WAS THE WEAK LINK AND IT IS NOW A REAL ROUTE. What SetAnimClass wants is
        -- an AnimBlueprintGeneratedClass — the "…_C" object — and the old code asked plain
        -- LoadAsset for it. That very probably could not work and it explains
        -- dumps/reflection/05_assets.txt:803 (`AnimBlueprint classes : 0 loaded`) recorded in a
        -- session where ABP_PinkCat_C was demonstrably driving a live pawn: the generated class
        -- is not the package's own asset object, so loading `ABP_X.ABP_X_C` as an asset asks for
        -- something that is not there to load. assets.loadClass splits it — LOAD the asset
        -- `ABP_X.ABP_X`, then LOOK UP the object `ABP_X.ABP_X_C` that loading it brought in —
        -- and class-checks the result, so what reaches SetAnimClass is a UClass or nothing.
        -- See core/mesh/assets.lua's header for the full argument.
        --
        -- STILL UNOBSERVED: no run has resolved one. What has been measured is the PATH SHAPE,
        -- read off live pawns (04_live_objects.txt:15 and :21) and recorded as assets.ABP.
        local animPath = spec.animClass or spec.anim
        if type(animPath) == "string" and #animPath > 0 then
            local anim, aerr = assets.loadClass(animPath, { class = ANIM_CLASS })
            if not anim then
                log.warn("skeletal: animClass dropped, the swapped mesh keeps the pawn's "
                    .. "existing animation blueprint - " .. tostring(aerr))
            else
                -- Both calls are declared on USkeletalMeshComponent, which is what
                -- `actor.Mesh` is, and both take exactly one argument:
                --   void SetAnimationMode(TEnumAsByte<EAnimationMode::Type>)  Engine.hpp:20670
                --   void SetAnimClass(UClass* NewClass)                       Engine.hpp:20669
                -- and the enum value that used to be an assumption is confirmed:
                -- EAnimationMode::AnimationBlueprint = 0, dumps/cxx/Engine_enums.hpp:275.
                -- So the mode really is set to AnimationBlueprint and the class really is
                -- bound; neither call is a misspelling and neither is short an argument.
                -- Left as bare pcalls rather than routed through core.signature: both
                -- arguments are scalars a wrong declaration could not fault on (a byte and
                -- an object pointer), the calls are unchanged, and animClass is an optional
                -- extra whose failure must never cost the mesh swap that already succeeded.
                -- What made the object argument safe to pass on a bare pcall is the class
                -- check above; before it, "not a UClass" was the likeliest thing to arrive.
                pcall(function() mc:SetAnimationMode(0) end)
                if not pcall(function() mc:SetAnimClass(anim) end) then
                    log.warn("skeletal: SetAnimClass raised on a declared function with a "
                        .. "verified AnimBlueprintGeneratedClass argument - animClass dropped")
                else
                    -- READ IT BACK. `UClass* GetAnimClass()` — Engine.hpp:20732, zero
                    -- arguments, the getter that pairs with the setter — so "the call ran" and
                    -- "the class is on the component" stop being the same sentence. This is
                    -- the same discipline the mesh setter above already gets from
                    -- GetSkinnedAsset, and it is why the log line below can name a fact.
                    -- A component that will not answer is a "cannot tell", not a failure.
                    local bound; pcall(function() bound = mc:GetAnimClass() end)
                    local boundName = assets.live(bound) and nameOf(bound) or nil
                    local wantName  = nameOf(anim)
                    if boundName and wantName and boundName ~= wantName then
                        log.warn("skeletal: SetAnimClass ran and the component still reports "
                            .. boundName)
                    else
                        log.info("skeletal: animClass " .. assets.describe(anim)
                            .. (boundName and " (read back off the component)"
                                          or " (the component would not read it back)"))
                    end
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
        -- assets.describe rather than the declared string: it prints the CLASS of what
        -- actually landed, so a log line is evidence about the object instead of an echo of
        -- what the pack typed.
        log.info("skeletal: set " .. assets.describe(mesh) .. " via " .. via
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
    -- SetRelativeScale3D(FVector) — Engine.hpp:20411 — restores what vecOf read off the
    -- RelativeScale3D property, so the restore is in the same space as the capture.
    if rec.scale then pcall(function() mc:SetRelativeScale3D(rec.scale) end) end
    -- K2_SetRelativeLocation(FVector, bool, FHitResult&, bool) — Engine.hpp:20428.
    if rec.loc then pcall(function() mc:K2_SetRelativeLocation(rec.loc, false, {}, false) end) end

    if not rec.asset then
        -- we changed the mesh but the component never told us what it had been, so the
        -- one thing that matters cannot be undone. Keep the record: a later detach with a
        -- readable component would still be able to try.
        log.warn("skeletal: detach cannot restore the original mesh (the component would "
            .. "not read its asset back at attach time)")
        return false
    end
    pcall(function() mc:SetDisableChangeMesh(false) end)   -- Pal.hpp:28899, as at attach
    local via = setMesh(mc, rec.asset)
    if not via then
        log.warn("skeletal: detach failed (SetSkinnedAssetAndUpdate did not fire - "
            .. "core.signature has logged why), so the pawn keeps our mesh")
        return false
    end
    originalOf[actor] = nil
    return true
end

return SkeletalMesh
