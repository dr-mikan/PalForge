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
local uo       = require("palforge.core.uobject")
local log      = require("palforge.utils.log").scope("mesh")

local Procedural = Renderer:extend("Procedural")

-- ---- inlined file helper (was deprecated/core.readFile) ----
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    return data
end

-- Parsed OBJs, by path. BOUNDED, which it was not: this held the full verts / tris / uvs
-- arrays for every OBJ path ever parsed, strongly and unevicted, for the life of the
-- process. That is a real amount of memory per entry — three Lua tables sized by the model,
-- one FVector table per vertex — and the count grew with the number of distinct paths a
-- session touched, which for a pack that generates paths is not bounded at all.
--
-- Least-recently-USED eviction rather than least-recently-added: the attach loop re-parses
-- the same handful of models over and over, so recency of use is exactly the right thing to
-- keep. The cap is a judgement, not a measurement — 8 distinct procedural models live at
-- once is already more than anything in this tree does — and evicting is cheap, because a
-- miss costs one io.open and a linear parse, not an engine call.
local OBJ_CACHE_MAX = 8
local objCache = {}      -- path -> parsed mesh
local objOrder = {}      -- paths, least-recently-used first

local function objTouch(path)
    for i = 1, #objOrder do
        if objOrder[i] == path then table.remove(objOrder, i); break end
    end
    objOrder[#objOrder + 1] = path
end

local function objCacheGet(path)
    local mesh = objCache[path]
    if mesh then objTouch(path) end
    return mesh
end

local function objCachePut(path, mesh)
    objCache[path] = mesh
    objTouch(path)
    while #objOrder > OBJ_CACHE_MAX do
        local oldest = table.remove(objOrder, 1)
        objCache[oldest] = nil
    end
end

-- Parse a (triangulated-or-not) OBJ file: v / vt / f records.
-- Faces with >3 vertices are fan-triangulated. Both windings are emitted so the
-- mesh is visible regardless of face orientation (probe-grade shading).
-- UVs: OBJ addresses position (v) and texcoord (vt) independently per face-vertex.
-- We keep one position array and record, per position index, the FIRST vt seen for
-- it — a best-effort per-vertex UV (correct for meshes that don't share a position
-- across differing UVs; good enough for probe meshes, never crashes).
function Procedural.parseObj(path)
    local cached = objCacheGet(path)
    if cached then return cached end
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
    objCachePut(path, mesh)
    return mesh
end

-- Discovery helper: log which candidate base materials are currently loaded. Kept on this
-- backend because core.mesh exposes it from here (M.probeMaterials).
function Procedural.probeMaterials(extra)
    return Renderer.probeMaterials(extra, log.info)
end

-- Keep the component we created per actor, so detach removes exactly what attach added
-- (and nothing that was already on the actor), and so the base setColor knows which
-- component to reach for.
--
-- KEYED ON core.uobject.key (the actor's full name), NOT on the actor handle — contract C1,
-- and the identical defect static.lua carried: UE4SS mints a fresh userdata wrapper per
-- lookup, so a `__mode="k"` table keyed on a handle could only ever be read back with the
-- one Lua value that wrote it. The record holds the handle:
--   { actor = <freshest handle we were given>, comp = <the ProceduralMeshComponent> }
-- and the separate `dressed` boolean table is gone, because the once-guard now rests on
-- whether a component of ours is still live rather than on a flag that survived a detach
-- that never ran.
local byActor = {}

-- The record for `actor`, re-validated, handle refreshed from the caller's fresher one. A
-- record whose component is already gone is dropped: nothing left to detach, nothing left
-- to guard.
local function recordFor(actor)
    local k = uo.key(actor)
    if not k then return nil, nil end
    local rec = byActor[k]
    if rec == nil then return nil, k end
    if not uo.live(rec.comp) then byActor[k] = nil; return nil, k end
    rec.actor = actor
    return rec, k
end

-- The component this backend dressed `actor` with (base/renderer contract).
function Procedural:componentFor(actor)
    local rec = recordFor(actor)
    return rec and rec.comp or nil
end

-- Attach a runtime mesh to an actor. def = { model, scale, offset, color, texture, params, material }.
-- Returns true on success, or false PLUS the English reason (the same string this logs) —
-- a pack author who gets a bare false back has to go and read UE4SS.log to find out which
-- step refused. The mesh always attaches; the material layer is best-effort.
function Procedural:attach(actor, def)
    if not (actor and type(def) == "table") then return false, "procedural: no actor or no spec" end
    local mesh, e = Procedural.parseObj(def.model)
    if not mesh then
        local why = "mesh: " .. tostring(e)
        log.err(why)
        return false, why
    end

    -- NEVER STACK: a component a previous attach put on this actor is destroyed first, so a
    -- second attach cannot orphan the first. Keyed on a handle, the store used to be
    -- overwritten on every re-attach and the earlier component became unreachable.
    local prev = recordFor(actor)
    if prev then
        local gone = Renderer.destroyComponent(prev.comp)
        log.info("procedural: replacing the component a previous attach put on this actor"
            .. (gone and "" or " (K2_DestroyComponent did not fire, so the old one may still "
                .. "be on the actor - core.signature has logged why)"))
    end

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
        -- remember it immediately: even a half-built component is ours to destroy again.
        -- A nil key (an actor that will not answer GetFullName) means no record — which
        -- costs the ability to detach it later, not the attach itself, and the log line at
        -- the end of this function says so.
        local k = uo.key(actor)
        if k then byActor[k] = { actor = actor, comp = comp } end
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
    if not ok then
        local why = "attach failed: " .. tostring(aerr)
        log.err(why)
        return false, why
    end
    if not uo.key(actor) then
        log.warn("procedural: the mesh is attached but this actor would not answer "
            .. "GetFullName, so nothing was recorded - detach and setColor will find no "
            .. "record for it")
    end
    return true
end

-- Attach once per actor (guards against re-stacking). The global ENABLED kill-switch
-- lives on the facade (core.mesh); this backend only owns the per-actor guard.
--
-- The guard reads the record, whose liveness recordFor has just re-checked, so "already
-- dressed" means "a component this backend created is still on this actor". The separate
-- `dressed` flag table it used to consult was keyed on the actor handle, so it missed on
-- every call after the first and the stacking it existed to prevent happened anyway.
function Procedural:attachOnce(actor, def)
    if not (actor and def) then return false, "procedural: no actor or no spec" end
    if recordFor(actor) then return true end
    return self:attach(actor, def)
end

-- Destroy the component this backend added to `actor`, so attach can dress it again.
-- Returns false when we added nothing, and when the destroy call did not execute — in
-- that second case the bookkeeping is deliberately LEFT in place, because the component
-- is still on the actor and the once-guard is the only thing stopping a second one.
function Procedural:detach(actor)
    if not actor then return false, "procedural: no actor" end
    -- recordFor already dropped a record whose component the engine tore down under us, so
    -- "no record" and "the component is gone" arrive here as one case, and both mean this
    -- call removed nothing. The material bookkeeping is cleared either way.
    local rec, k = recordFor(actor)
    if not rec then
        if k then self:forgetMaterial(actor) end
        return false, "procedural: nothing of PalForge's is recorded on this actor to remove"
    end
    if not Renderer.destroyComponent(rec.comp) then
        local why = "detach failed (K2_DestroyComponent did not fire - core.signature has "
            .. "logged whether it was refused or raised)"
        log.warn(why)
        -- bookkeeping deliberately LEFT in place: the component is still on the actor and
        -- the once-guard is the only thing stopping a second one
        return false, why
    end
    -- the whole component goes, so there is no material to put back — just drop the record
    self:forgetMaterial(actor)
    byActor[k] = nil
    return true
end

return Procedural
