-- PalForge core.mesh.procedural: the `kind = "procedural"` (a.k.a. obj) mesh
-- backend — a Wavefront OBJ -> ProceduralMeshComponent attach with an optional
-- material layer (flat color tint / imported PNG texture). Extends the base
-- renderer. Moved VERBATIM from the old core.mesh (self-contained; no PalForge
-- module deps beyond the base renderer + the shared logger).
--
-- Verified chain: AActor:AddComponentByClass -> UProceduralMeshComponent:CreateMeshSection
-- -> SetWorldScale3D. Trap: an empty {} FTransform zero-initializes the relative scale,
-- so the explicit SetWorldScale3D call is mandatory.
--
-- Material layer native APIs:
--   UPrimitiveComponent:CreateAndSetMaterialInstanceDynamic(int32 elem) -> MID
--   UMaterialInstanceDynamic:SetVectorParameterValue(FName, FLinearColor)  -- color
--   UMaterialInstanceDynamic:SetTextureParameterValue(FName, UTexture*)    -- texture
--   UMaterialInstanceDynamic:SetScalarParameterValue(FName, float)
--   UKismetRenderingLibrary:ImportFileAsTexture2D(WorldCtx, FString) -> UTexture2D
-- Because no custom base material ships, element-0 is the engine default (no tint
-- param), so a color/texture may not visibly apply until a base material with those
-- params is supplied. The layer is FULLY fail-soft; the mesh always attaches.

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

-- Candidate parameter names to probe on the (unknown) base material.
local COLOR_PARAMS   = { "Color", "BaseColor", "Tint", "BaseColorTint", "Albedo", "EmissiveColor" }
local TEXTURE_PARAMS = { "BaseColor", "Texture", "Albedo", "Diffuse", "BaseTexture", "MainTexture" }

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

-- clamp a number to [0,1]
local function unit(n) n = tonumber(n) or 0; if n < 0 then return 0 elseif n > 1 then return 1 else return n end end

-- def.color = {r,g,b,a} 0..1  ->  FLinearColor-shaped table
local function linearColor(c)
    if type(c) ~= "table" then return nil end
    return { R = unit(c[1] or c.r), G = unit(c[2] or c.g), B = unit(c[3] or c.b), A = c[4] or c.a or 1.0 }
end

-- def.color -> FColor-shaped table (byte 0..255) for vertex colors
local function byteColor(c)
    local lc = linearColor(c); if not lc then return nil end
    return { R = math.floor(lc.R * 255 + 0.5), G = math.floor(lc.G * 255 + 0.5),
             B = math.floor(lc.B * 255 + 0.5), A = math.floor((lc.A or 1) * 255 + 0.5) }
end

local kismetRendering = nil
local function importTexture(worldCtx, absPath)
    if kismetRendering == nil then
        kismetRendering = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") or false
    end
    if not kismetRendering then return nil, "no KismetRenderingLibrary" end
    local ok, tex = pcall(function() return kismetRendering:ImportFileAsTexture2D(worldCtx, absPath) end)
    if ok and tex and tex:IsValid() then return tex end
    return nil, "ImportFileAsTexture2D failed: " .. tostring(tex)
end

-- Candidate base materials to PARENT the MID to. A freshly created
-- ProceduralMeshComponent section has no material on element 0, so
-- CreateAndSetMaterialInstanceDynamic(0) returns nil. Building the MID *From* a real
-- base material fixes that AND gives it a parent whose Color param / vertex colors the
-- engine will actually render. StaticFindObject only returns ALREADY-LOADED objects,
-- so we try several and take the first present.
local BASE_MATERIAL_CANDIDATES = {
    "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial",       -- has a "Color" vector param
    "/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial",
    "/Engine/EngineDebugMaterials/VertexColorViewMode_ColorOnly.VertexColorViewMode_ColorOnly",
    "/Engine/EngineMaterials/DefaultMaterial.DefaultMaterial",
    "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial",
}
-- Only SUCCESSES are cached; a miss (candidate not loaded yet) retries on the next
-- attach — otherwise early markers placed before the material streams in would be
-- stuck white forever. StaticFindObject is cheap.
local baseMatCache -- {mat,path} of a found base material, or nil
local function resolveBaseMaterial(explicitPath)
    if explicitPath then
        local ok, m = pcall(StaticFindObject, explicitPath)
        if ok and m and m.IsValid and m:IsValid() then return m, explicitPath end
    end
    if baseMatCache then
        local ok = pcall(function() return baseMatCache.mat:IsValid() end)
        if ok and baseMatCache.mat:IsValid() then return baseMatCache.mat, baseMatCache.path end
        baseMatCache = nil
    end
    for _, p in ipairs(BASE_MATERIAL_CANDIDATES) do
        local ok, m = pcall(StaticFindObject, p)
        if ok and m and m.IsValid and m:IsValid() then baseMatCache = { mat = m, path = p }; return m, p end
    end
    return nil  -- not loaded yet; retry next attach
end

-- Discovery helper: log which candidate base materials are currently loaded.
function Procedural.probeMaterials(extra)
    local seen = {}
    local function try(p)
        if seen[p] then return end
        seen[p] = true
        local ok, m = pcall(StaticFindObject, p)
        local found = ok and m and m.IsValid and m:IsValid()
        log.info("MATPROBE " .. (found and "FOUND " or "----- ") .. p)
    end
    for _, p in ipairs(BASE_MATERIAL_CANDIDATES) do try(p) end
    for _, p in ipairs(extra or {}) do try(p) end
end

local function shortName(path)
    if not path then return "?" end
    return (path:gsub("^.*/", ""):gsub("%..*$", ""))
end

-- Keep the created MID per actor so a marker's colour can be RE-SET at runtime.
local midByActor = setmetatable({}, { __mode = "k" })

-- Re-tint an already-attached marker. color = {r,g,b,a} 0..1. Also writes emissive
-- param names so, on a material that supports it, "connected" visibly glows. Safe
-- no-op if the actor has no MID yet (marker not attached / no base material).
function Procedural:setColor(actor, color)
    local mid = midByActor[actor]
    if not mid then return false end
    local lc = linearColor(color)
    if not lc then return false end
    for _, name in ipairs(COLOR_PARAMS) do
        pcall(function() mid:SetVectorParameterValue(FName(name), lc) end)
    end
    for _, name in ipairs({ "EmissiveColor", "Emissive", "EmissiveColour" }) do
        pcall(function() mid:SetVectorParameterValue(FName(name), lc) end)
    end
    return true
end

-- Apply the material layer to a MID on element 0. Fully fail-soft: returns a short
-- status string describing the outcome (for logging). `def` may carry
-- color / texture (abs path) / params / material (base material object path). Never throws.
local function applyMaterial(comp, worldCtx, def)
    if not (def.color or def.texture or def.params or def.material) then return "none" end
    local status = {}
    local mid
    -- prefer a MID parented to a real base material (renders color / vertex color)
    local base, basePath = resolveBaseMaterial(def.material)
    if base then
        local ok, m = pcall(function() return comp:CreateAndSetMaterialInstanceDynamicFromMaterial(0, base) end)
        if ok and m and m:IsValid() then mid = m; status[#status + 1] = "base:" .. shortName(basePath) end
    end
    if not mid then
        local ok, m = pcall(function() return comp:CreateAndSetMaterialInstanceDynamic(0) end)
        if ok and m and m:IsValid() then mid = m end
    end
    if not mid then
        status[#status + 1] = "no-MID(no base material loaded)"
        return table.concat(status, ",")
    end
    -- worldCtx is the owning actor (attach passes it) — remember the MID so its
    -- colour can be updated later. __mode="k" weak table.
    if worldCtx then pcall(function() midByActor[worldCtx] = mid end) end

    -- texture (imported PNG) — try known texture param names
    if def.texture then
        local tex, terr = importTexture(worldCtx, def.texture)
        if tex then
            status[#status + 1] = "tex-imported"
            for _, name in ipairs(TEXTURE_PARAMS) do
                pcall(function() mid:SetTextureParameterValue(FName(name), tex) end)
            end
        else
            status[#status + 1] = "tex-fail(" .. tostring(terr) .. ")"
        end
    end

    -- color (flat tint) — probe candidate vector param names
    if def.color then
        local lc = linearColor(def.color)
        if lc then
            for _, name in ipairs(COLOR_PARAMS) do
                pcall(function() mid:SetVectorParameterValue(FName(name), lc) end)
            end
            status[#status + 1] = "color-set"
        end
    end

    -- explicit params passthrough: { vector={name={r,g,b,a}}, scalar={name=v}, texture={name=path} }
    if type(def.params) == "table" then
        if type(def.params.vector) == "table" then
            for name, val in pairs(def.params.vector) do
                local lc = linearColor(val)
                if lc then pcall(function() mid:SetVectorParameterValue(FName(name), lc) end) end
            end
        end
        if type(def.params.scalar) == "table" then
            for name, val in pairs(def.params.scalar) do
                pcall(function() mid:SetScalarParameterValue(FName(name), tonumber(val) or 0) end)
            end
        end
        if type(def.params.texture) == "table" then
            for name, p in pairs(def.params.texture) do
                local tex = importTexture(worldCtx, p)
                if tex then pcall(function() mid:SetTextureParameterValue(FName(name), tex) end) end
            end
        end
        status[#status + 1] = "params"
    end

    return #status > 0 and table.concat(status, ",") or "mid-only"
end

-- Attach a runtime mesh to an actor. def = { model, scale, offset, color, texture, params, material }.
-- Returns true on success. The mesh always attaches; the material layer is best-effort.
function Procedural:attach(actor, def)
    local mesh, e = Procedural.parseObj(def.model)
    if not mesh then log.err("mesh: " .. tostring(e)); return false end

    local vertexColors = def.color and (function()
        local bc = byteColor(def.color)
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
        -- CreateMeshSection(section, verts, tris, normals, UV0, vertexColors, tangents, collision)
        -- collision=false: decorative meshes must never collide (a collider here both
        -- hitches on cook AND intercepts the build placement raycast).
        comp:CreateMeshSection(0, mesh.verts, mesh.tris, {}, mesh.uvs or {}, vertexColors, {}, false)
        pcall(function() comp:SetCollisionEnabled(0) end)          -- ECollisionEnabled::NoCollision
        pcall(function() comp:SetCollisionProfileName("NoCollision") end)
        local s = def.scale or 1.0
        comp:SetWorldScale3D({ X = s, Y = s, Z = s }) -- mandatory (zero-scale trap)
        local o = def.offset or {}
        comp:K2_SetRelativeLocation({ X = o.x or 0, Y = o.y or 0, Z = o.z or 0 }, false, {}, false)
        -- material layer (fail-soft, logged)
        local st = applyMaterial(comp, actor, def)
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

return Procedural
