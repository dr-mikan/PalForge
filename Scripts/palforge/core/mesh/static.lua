-- PalForge core.mesh.static: the `kind = "static"` mesh backend — a UE-authored
-- UStaticMesh asset hung on an actor through a UStaticMeshComponent we create at
-- runtime. Extends the base renderer.
--
-- Ported from the PROVEN procedural chain (core/mesh/procedural.lua — in-game verified
-- 2026-07-16 as the V5 runtime-mesh POC, shipped since in PalLogistics):
--   StaticFindObject(<component class>) -> AActor:AddComponentByClass(cls, false, {}, false)
--   -> fill the component -> MANDATORY SetWorldScale3D -> K2_SetRelativeLocation.
-- The scale call is not optional: the empty {} FTransform handed to AddComponentByClass
-- zero-initializes the relative scale, so a component nobody scales is invisible.
-- Collision stays off for the same reason as procedural — a decorative collider both
-- hitches and intercepts the build placement raycast.
--
-- The setter is no longer a guess. dumps/cxx/Engine.hpp:21720 declares, on
-- UStaticMeshComponent (:21687):
--
--     bool SetStaticMesh(class UStaticMesh* NewMesh);
--
-- One argument, an ObjectProperty, and a bool return — exactly the call below. The same
-- class listing also settles the read-back, in the opposite direction: there is NO
-- reflected `GetStaticMesh` anywhere in the 1579-header dump. The asset is reachable only
-- as the UProperty `UStaticMesh* StaticMesh` at Engine.hpp:21693 (offset 0x0580), which is
-- also what dumps/reflection reads off live actors. So meshOn() reads that one property
-- and nothing else — the getter it used to try first cannot exist.
--
-- attach still does not take the call on trust: it reads the asset back and reports
-- success only when it is really sitting there. On any failure the component we added is
-- destroyed again, so a build where the setter is ignored gets an honest false and no
-- orphaned component, not a mesh nobody rendered.
--
-- STILL UNOBSERVED: a correct signature is not a watched success. No run in either tree
-- has seen a UStaticMesh appear on a component this way, and the dump is one game patch
-- (2026-07-09 vs an exe of 2026-07-16) behind the installed binary, which is why the call
-- goes through core.signature and the read-back is kept.
--
-- MATERIAL: an authored UStaticMesh arrives with real materials on its slots, so unlike
-- the procedural section this component can be instanced directly — base/renderer's MID
-- layer does the work and the spec's color / texture / material / params reach it, which
-- is also what makes a later setColor (api/building's Class:update) able to re-tint a
-- structure. The MID is created lazily: an attach that declares no material leaves the
-- mesh's own look untouched until someone actually asks for a tint.
--
-- spec (from api/building:render / api/pal:renderOn):
--   { model = "<UStaticMesh object path>", scale = <number>, offset = { x, y, z },
--     color = { r,g,b,a }, texture = "<abs png>", material = "<base material path>",
--     params = { vector = {...}, scalar = {...}, texture = {...} } }
-- `asset` is accepted as an alias for `model`: this file's original TODO named the field
-- `asset` while every caller passes `model`.
local Renderer = require("palforge.core.mesh.base.renderer")
local sig      = require("palforge.core.signature")
local log      = require("palforge.utils.log").scope("mesh")

local StaticMesh = Renderer:extend("StaticMeshRenderer")

-- The declared shape of UStaticMeshComponent::SetStaticMesh, in the order core.signature
-- checks it: `class UStaticMesh* NewMesh` is an ObjectProperty (dumps/cxx/Engine.hpp:21720).
-- Handing a live UObject to a UObject* parameter is the one argument kind core.signature
-- will pass on "present" evidence, so this call can still fire on a build whose UE4SS
-- cannot walk a UFunction's properties.
local SET_STATIC_MESH_PARAMS = { "ObjectProperty" }

-- Loaded UStaticMesh assets cached by path (load once, reuse forever). Same resolve
-- order proven for the AkAudioEvent assets in core/sound/native.lua: LoadAsset pulls in
-- an asset that isn't loaded yet, StaticFindObject catches the already-loaded case.
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

-- Read the mesh back off a component. ONE path, because the dump leaves only one: the
-- UProperty `class UStaticMesh* StaticMesh` (dumps/cxx/Engine.hpp:21693). This used to try
-- a `GetStaticMesh()` getter first; no such UFunction is declared on UStaticMeshComponent
-- (:21687) or anywhere else in dumps/cxx, so that branch could only ever raise and be
-- swallowed. Nil here is a "cannot tell", not a "not set".
local function meshOn(comp)
    local m
    pcall(function() m = comp.StaticMesh end)
    if m and m.IsValid and m:IsValid() then return m end
    return nil
end

-- Destroying a component we added is Renderer.destroyComponent — one implementation for
-- both component-adding backends, with the K2_DestroyComponent evidence beside it.
local destroyComponent = Renderer.destroyComponent

-- The component this backend created, per actor, so detach removes exactly what attach
-- added (and nothing that was already on the actor), and so base/renderer's setColor
-- knows which component to instance a material on. __mode="k" weak table.
local compByActor = setmetatable({}, { __mode = "k" })

-- The component this backend dressed `actor` with (base/renderer contract). This is the
-- whole of what setColor needs: the base creates the MID on demand from it.
function StaticMesh:componentFor(actor) return actor and compByActor[actor] or nil end

-- Attach spec's UStaticMesh to `actor` on a component of our own.
-- Returns true only when the asset is confirmed to be sitting on that component.
function StaticMesh:attach(actor, spec)
    if not (actor and spec) then return false end
    local model = spec.model or spec.asset
    if type(model) ~= "string" or #model == 0 then
        log.err("static: spec carries no model path")
        return false
    end
    local asset = loadAsset(model)
    if not asset then log.err("static: cannot resolve mesh " .. model); return false end

    local comp
    local ok, aerr = pcall(function()
        local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        assert(smcClass and smcClass:IsValid(), "StaticMeshComponent class not found")
        -- AddComponentByClass(TSubclassOf<UActorComponent> Class, bool bManualAttachment,
        -- const FTransform& RelativeTransform, bool bDeferredFinish) — Engine.hpp:8056.
        -- Four arguments, which is what the proven procedural chain already passes.
        comp = actor:AddComponentByClass(smcClass, false, {}, false)
        assert(comp and comp:IsValid(), "AddComponentByClass failed")
        -- bool SetStaticMesh(UStaticMesh* NewMesh) — Engine.hpp:21720. Through
        -- core.signature so the live class is asked before the argument is marshalled;
        -- the declared bool return says whether the engine accepted the mesh.
        local set, took = sig.call(comp, "SetStaticMesh", SET_STATIC_MESH_PARAMS, asset)
        assert(set, "SetStaticMesh did not fire (core.signature refused it, or it raised)")
        -- prove the setter took before anything downstream assumes it did: the bool it
        -- returns is the engine's opinion, the property is the fact.
        assert(meshOn(comp), "SetStaticMesh returned " .. tostring(took)
            .. " and the component's StaticMesh property is still empty")
        -- ECollisionEnabled::NoCollision = 0 (dumps/cxx/Engine_enums.hpp:777), passed to
        -- SetCollisionEnabled(TEnumAsByte<ECollisionEnabled::Type>) — one argument,
        -- Engine.hpp:19786. This is the WHOLE of switching collision off; the
        -- SetCollisionProfileName("NoCollision") that used to follow it has been removed,
        -- because Engine.hpp:19784 declares it SetCollisionProfileName(FName, bool) — two
        -- arguments, and an FName rather than a string. The one-argument call could never
        -- have run, and making it run correctly would mean marshalling a bare Lua string
        -- into an FName parameter, which is the shape that has killed this process before.
        pcall(function() comp:SetCollisionEnabled(0) end)
        -- SetWorldScale3D(FVector NewScale) — Engine.hpp:20408, one argument. Mandatory
        -- (the empty {} FTransform above zero-initialized the relative scale).
        local s = spec.scale or 1.0
        comp:SetWorldScale3D({ X = s, Y = s, Z = s })
        -- K2_SetRelativeLocation(FVector NewLocation, bool bSweep, FHitResult& SweepHitResult,
        -- bool bTeleport) — Engine.hpp:20428. Four arguments, which is what is passed here;
        -- the {} stands in for the out FHitResult.
        local o = spec.offset or {}
        comp:K2_SetRelativeLocation({ X = o.x or 0, Y = o.y or 0, Z = o.z or 0 }, false, {}, false)
    end)
    if not ok then
        destroyComponent(comp)   -- never leave a half-dressed component behind
        log.err("static: attach failed: " .. tostring(aerr))
        return false
    end
    pcall(function() compByActor[actor] = comp end)
    -- Material layer, AFTER the mesh is confirmed: fail-soft and never able to undo the
    -- attach, but no longer silently dropped the way it was when only the procedural
    -- backend could paint. `always` is off — the mesh's authored materials stay as they
    -- are unless the spec asked for something.
    local st = self:dressMaterial(comp, actor, spec, {})
    if st ~= "none" then log.info("static: material [" .. st .. "] on " .. model) end
    return true
end

-- Track actors we've already dressed so lazy re-attach doesn't stack meshes.
local dressed = setmetatable({}, { __mode = "k" })

-- Attach once per actor (guards against re-stacking). The global ENABLED kill-switch
-- lives on the facade (core.mesh); this backend only owns the per-actor guard.
function StaticMesh:attachOnce(actor, spec)
    if not (actor and spec) then return false end
    if dressed[actor] then return true end
    if self:attach(actor, spec) then
        dressed[actor] = true
        return true
    end
    return false
end

-- Destroy the component this backend added to `actor`, so attach can dress it again.
-- Returns false when we added nothing, and when the destroy call did not execute — in
-- that second case the bookkeeping is deliberately LEFT in place, because the component
-- is still on the actor and the once-guard is the only thing stopping a second one.
function StaticMesh:detach(actor)
    if not actor then return false end
    local comp = compByActor[actor]
    if not comp then return false end
    local live = false
    pcall(function() live = comp:IsValid() == true end)
    if not live then
        -- already gone (the actor was torn down under us): forget it, but nothing was
        -- removed BY this call, so say so
        compByActor[actor] = nil
        dressed[actor]     = nil
        self:forgetMaterial(actor)
        return false
    end
    if not destroyComponent(comp) then
        log.warn("static: detach failed (K2_DestroyComponent did not fire - core.signature "
            .. "has logged whether it was refused or raised)")
        return false
    end
    -- the whole component goes with it, so there is no material to put back
    self:forgetMaterial(actor)
    compByActor[actor] = nil
    dressed[actor]     = nil
    return true
end

return StaticMesh
