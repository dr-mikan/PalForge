-- PalForge core.mesh.static: the `kind = "static"` mesh backend — a UE-authored
-- UStaticMesh asset hung on an actor through a UStaticMeshComponent we create at
-- runtime. Extends the base renderer. Self-contained (no PalForge module deps beyond
-- the base renderer + the shared logger).
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
-- The one link with NO record in either tree is the setter itself,
-- `UStaticMeshComponent:SetStaticMesh(UStaticMesh*)`: dump/docs/05_mesh_material.md §5.2
-- still lists its reflected signature as a to-confirm. So attach does not take the call
-- on trust — it READS THE ASSET BACK off the component (GetStaticMesh(), then the
-- `StaticMesh` property dump/dump.lua reads off live actors) and reports success only
-- when the read-back asset is really there. On any failure the component we added is
-- destroyed again, so a build where the setter is missing or ignored gets an honest
-- false and no orphaned component, not a mesh nobody rendered.
--
-- spec (from api/building:render / api/pal:renderOn):
--   { model = "<UStaticMesh object path>", scale = <number>, offset = { x, y, z } }
-- `asset` is accepted as an alias for `model`: this file's original TODO named the field
-- `asset` while every caller passes `model`.
local Renderer = require("palforge.core.mesh.base.renderer")
local log      = require("palforge.utils.log").scope("mesh")

local StaticMesh = Renderer:extend("StaticMeshRenderer")

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

-- Read the mesh back off a component. Two independent paths, so the confirm does not
-- hinge on a single unverified name: the BlueprintPure getter, then the property.
local function meshOn(comp)
    local m
    pcall(function() m = comp:GetStaticMesh() end)
    if m and m.IsValid and m:IsValid() then return m end
    m = nil
    pcall(function() m = comp.StaticMesh end)
    if m and m.IsValid and m:IsValid() then return m end
    return nil
end

-- Destroy a component we added. K2_DestroyComponent is the BlueprintCallable
-- counterpart of the proven AddComponentByClass, but has no in-game record of its own,
-- so the pcall status (i.e. "the component carried the function and it ran") is the
-- strongest thing we can honestly report.
local function destroyComponent(comp)
    if not (comp and comp.IsValid and comp:IsValid()) then return false end
    local ok = pcall(function() comp:K2_DestroyComponent(comp) end)
    return ok
end

-- The component this backend created, per actor, so detach removes exactly what attach
-- added (and nothing that was already on the actor). __mode="k" weak table.
local compByActor = setmetatable({}, { __mode = "k" })

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
        comp = actor:AddComponentByClass(smcClass, false, {}, false)
        assert(comp and comp:IsValid(), "AddComponentByClass failed")
        comp:SetStaticMesh(asset)
        -- prove the (unconfirmed) setter took before anything downstream assumes it did
        assert(meshOn(comp), "SetStaticMesh did not take")
        pcall(function() comp:SetCollisionEnabled(0) end)          -- ECollisionEnabled::NoCollision
        pcall(function() comp:SetCollisionProfileName("NoCollision") end)
        local s = spec.scale or 1.0
        comp:SetWorldScale3D({ X = s, Y = s, Z = s }) -- mandatory (zero-scale trap)
        local o = spec.offset or {}
        comp:K2_SetRelativeLocation({ X = o.x or 0, Y = o.y or 0, Z = o.z or 0 }, false, {}, false)
    end)
    if not ok then
        destroyComponent(comp)   -- never leave a half-dressed component behind
        log.err("static: attach failed: " .. tostring(aerr))
        return false
    end
    pcall(function() compByActor[actor] = comp end)
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
        return false
    end
    if not destroyComponent(comp) then
        log.warn("static: detach failed (K2_DestroyComponent unavailable)")
        return false
    end
    compByActor[actor] = nil
    dressed[actor]     = nil
    return true
end

return StaticMesh
