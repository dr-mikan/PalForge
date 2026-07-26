-- PalForge core.mesh.procedural: the `kind = "procedural"` (a.k.a. obj) mesh
-- backend — a Wavefront OBJ -> ProceduralMeshComponent attach with an optional
-- material layer (flat color tint / imported PNG texture). Extends the base renderer.
--
-- Verified chain (V5 runtime-mesh POC, in-game 2026-07-16, shipped since in PalLogistics):
-- AActor:AddComponentByClass -> UProceduralMeshComponent:CreateMeshSection ->
-- SetWorldScale3D. Trap: an empty {} FTransform zero-initializes the relative scale, so
-- the explicit SetWorldScale3D call is mandatory.
--
-- detach removes again what attach added: K2_DestroyComponent on the component we
-- created, through the shared Renderer.destroyComponent. Its declaration is settled —
-- UActorComponent::K2_DestroyComponent(UObject* Object), dumps/cxx/Engine.hpp:9972, one
-- ObjectProperty argument, which is the component itself — but no run has watched a
-- component actually vanish, so detach still reports only whether that call executed.
--
-- MATERIAL: the MID handling lives in base/renderer (it is UPrimitiveComponent API, the
-- same on every mesh component). This backend only supplies the two things that ARE
-- specific to it: `preferBase = true`, because a freshly created mesh section carries no
-- material at all — CreateAndSetMaterialInstanceDynamic(0) returns nil there, so the MID
-- has to be parented to a real base material to exist — and `always = true`, so a marker
-- declared without a colour can still be tinted later through setColor.
-- Because no custom base material ships, element-0 ends up on whichever engine material
-- happens to be loaded (Renderer.BASE_MATERIAL_CANDIDATES), so a color/texture may not
-- visibly apply until a base material carrying those params is supplied. The one in-game
-- record of this path says exactly that (PalLogistics extensions/pallogistics/init.lua:42
-- — "no-MID -> white"). The layer is FULLY fail-soft; the mesh always attaches.

local Renderer = require("palforge.core.mesh.base.renderer")
local log      = require("palforge.utils.log").scope("mesh")

local Procedural = Renderer:extend("Procedural")

-- ---- inlined file helper (was deprecated/core.readFile) ----
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    return data
end

local objCache = {} -- path -> parsed mesh

-- Parse a (triangulated-or-not) OBJ file: v / vt / f records.
-- Faces with >3 vertices are fan-triangulated. Both windings are emitted so the
-- mesh is visible regardless of face orientation (probe-grade shading).
-- UVs: OBJ addresses position (v) and texcoord (vt) independently per face-vertex.
-- We keep one position array and record, per position index, the FIRST vt seen for
-- it — a best-effort per-vertex UV (correct for meshes that don't share a position
-- across differing UVs; good enough for probe meshes, never crashes).
function Procedural.parseObj(path)
    if objCache[path] then return objCache[path] end
    local text = readFile(path)
    if not text then return nil, "cannot read " .. path end
    local verts, tris, texcoords = {}, {}, {}
    local uvOf = {}     -- position index (0-based) -> {X,Y}
    local hasUV = false
    for line in text:gmatch("[^\r\n]+") do
        local kind, rest = line:match("^(%a+)%s+(.*)$")
        if kind == "v" then
            local x, y, z = rest:match("([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
            if x then table.insert(verts, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }) end
        elseif kind == "vt" then
            local u, v = rest:match("([%-%d%.eE]+)%s+([%-%d%.eE]+)")
            if u then table.insert(texcoords, { X = tonumber(u), Y = 1.0 - (tonumber(v) or 0) }) end
        elseif kind == "f" then
            local idx = {}
            for token in rest:gmatch("%S+") do
                local vi, ti = token:match("^(%-?%d+)/?(%-?%d*)")
                vi = tonumber(vi)
                if vi and vi < 0 then vi = #verts + 1 + vi end
                ti = ti ~= "" and tonumber(ti) or nil
                if ti and ti < 0 then ti = #texcoords + 1 + ti end
                if vi then
                    table.insert(idx, vi - 1) -- OBJ is 1-based
                    if ti and texcoords[ti] and uvOf[vi - 1] == nil then
                        uvOf[vi - 1] = texcoords[ti]; hasUV = true
                    end
                end
            end
            for i = 2, #idx - 1 do
                local a, b, c = idx[1], idx[i], idx[i + 1]
                table.insert(tris, a); table.insert(tris, b); table.insert(tris, c)
                table.insert(tris, c); table.insert(tris, b); table.insert(tris, a)
            end
        end
    end
    if #verts == 0 or #tris == 0 then return nil, "no geometry in " .. path end
    -- Build a per-vertex UV0 array aligned to `verts` (default (0,0) where unknown).
    local uvs = {}
    if hasUV then
        for i = 0, #verts - 1 do uvs[i + 1] = uvOf[i] or { X = 0, Y = 0 } end
    end
    local mesh = { verts = verts, tris = tris, uvs = uvs, hasUV = hasUV }
    objCache[path] = mesh
    return mesh
end

-- Discovery helper: log which candidate base materials are currently loaded. Kept on this
-- backend because core.mesh exposes it from here (M.probeMaterials).
function Procedural.probeMaterials(extra)
    return Renderer.probeMaterials(extra, log.info)
end

-- Keep the component we created per actor, so detach removes exactly what attach added
-- (and nothing that was already on the actor), and so the base setColor knows which
-- component to reach for. __mode="k" weak table.
local compByActor = setmetatable({}, { __mode = "k" })

-- The component this backend dressed `actor` with (base/renderer contract).
function Procedural:componentFor(actor) return actor and compByActor[actor] or nil end

-- Attach a runtime mesh to an actor. def = { model, scale, offset, color, texture, params, material }.
-- Returns true on success. The mesh always attaches; the material layer is best-effort.
function Procedural:attach(actor, def)
    if not (actor and type(def) == "table") then return false end
    local mesh, e = Procedural.parseObj(def.model)
    if not mesh then log.err("mesh: " .. tostring(e)); return false end

    local vertexColors = def.color and (function()
        local bc = Renderer.byteColor(def.color)
        if not bc then return {} end
        local arr = {}
        for i = 1, #mesh.verts do arr[i] = bc end
        return arr
    end)() or {}

    local ok, aerr = pcall(function()
        local pmcClass = StaticFindObject("/Script/ProceduralMeshComponent.ProceduralMeshComponent")
        assert(pmcClass and pmcClass:IsValid(), "ProceduralMeshComponent class not found")
        local comp = actor:AddComponentByClass(pmcClass, false, {}, false)
        assert(comp and comp:IsValid(), "AddComponentByClass failed")
        -- remember it immediately: even a half-built component is ours to destroy again
        pcall(function() compByActor[actor] = comp end)
        -- CreateMeshSection(int32 SectionIndex, TArray<FVector>& Vertices,
        --   TArray<int32>& Triangles, TArray<FVector>& normals, TArray<FVector2D>& UV0,
        --   TArray<FColor>& VertexColors, TArray<FProcMeshTangent>& Tangents,
        --   bool bCreateCollision) — dumps/cxx/ProceduralMeshComponent.hpp:67. Eight
        -- arguments, which is what this passes.
        -- collision=false: decorative meshes must never collide (a collider here both
        -- hitches on cook AND intercepts the build placement raycast).
        comp:CreateMeshSection(0, mesh.verts, mesh.tris, {}, mesh.uvs or {}, vertexColors, {}, false)
        -- ECollisionEnabled::NoCollision = 0 (dumps/cxx/Engine_enums.hpp:777) into
        -- SetCollisionEnabled(TEnumAsByte<ECollisionEnabled::Type>) — one argument,
        -- dumps/cxx/Engine.hpp:19786. The SetCollisionProfileName("NoCollision") that used
        -- to sit beside it is gone: Engine.hpp:19784 declares it
        -- SetCollisionProfileName(FName, bool), so the one-argument call never ran, and
        -- firing it correctly would mean pushing a bare Lua string at an FName parameter —
        -- the marshalling shape that has taken this process down before. Switching
        -- collision off is one capability and SetCollisionEnabled is its one route.
        pcall(function() comp:SetCollisionEnabled(0) end)
        -- SetWorldScale3D(FVector NewScale) — Engine.hpp:20408. Mandatory: the empty {}
        -- FTransform handed to AddComponentByClass zero-initializes the relative scale.
        local s = def.scale or 1.0
        comp:SetWorldScale3D({ X = s, Y = s, Z = s })
        -- K2_SetRelativeLocation(FVector NewLocation, bool bSweep, FHitResult& SweepHitResult,
        -- bool bTeleport) — Engine.hpp:20428. Four arguments; the {} is the out FHitResult.
        local o = def.offset or {}
        comp:K2_SetRelativeLocation({ X = o.x or 0, Y = o.y or 0, Z = o.z or 0 }, false, {}, false)
        -- material layer (fail-soft, logged). always=true so a marker declared with no
        -- colour can still be re-tinted later; preferBase=true because a fresh section has
        -- no material of its own to instance from.
        local st = self:dressMaterial(comp, actor, def, { always = true, preferBase = true })
        if st ~= "none" then
            log.info(string.format("material [%s] uv=%s vcol=%s on %s",
                st, tostring(mesh.hasUV), tostring(#vertexColors > 0), tostring(def.model)))
        end
    end)
    if not ok then log.err("attach failed: " .. tostring(aerr)); return false end
    return true
end

-- Track actors we've already dressed so lazy re-attach doesn't stack meshes.
local dressed = setmetatable({}, { __mode = "k" })

-- Attach once per actor (guards against re-stacking). The global ENABLED kill-switch
-- lives on the facade (core.mesh); this backend only owns the per-actor guard.
function Procedural:attachOnce(actor, def)
    if not (actor and def) then return false end
    if dressed[actor] then return true end
    if self:attach(actor, def) then
        dressed[actor] = true
        return true
    end
    return false
end

-- Destroy the component this backend added to `actor`, so attach can dress it again.
-- Returns false when we added nothing, and when the destroy call did not execute — in
-- that second case the bookkeeping is deliberately LEFT in place, because the component
-- is still on the actor and the once-guard is the only thing stopping a second one.
function Procedural:detach(actor)
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
    if not Renderer.destroyComponent(comp) then
        log.warn("detach failed (K2_DestroyComponent did not fire - core.signature has "
            .. "logged whether it was refused or raised)")
        return false
    end
    -- the whole component goes, so there is no material to put back — just drop the record
    self:forgetMaterial(actor)
    compByActor[actor] = nil
    dressed[actor]     = nil
    return true
end

return Procedural
