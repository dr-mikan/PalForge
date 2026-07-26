-- PalForge core.mesh.base.renderer: the abstract renderer contract PLUS the material
-- layer every backend shares. Every mesh backend (procedural OBJ, static UStaticMesh,
-- skeletal USkeletalMesh) extends this and overrides what it implements.
-- Self-contained (no PalForge deps).
--
-- Contract:
--   renderer:attach(actor, spec)    -> attach a mesh to `actor` from `spec`
--   renderer:setColor(actor, color) -> re-tint an attached mesh
--   renderer:detach(actor)          -> remove again what attach added
--   renderer:componentFor(actor)    -> the component this backend dressed `actor` with
-- attach and detach default to inert (return false) so an unfinished backend is a safe
-- no-op, and so a backend that legitimately CANNOT do one of them keeps the inert default
-- rather than faking a success.
--
-- WHY THE MATERIAL LAYER LIVES HERE. Painting a mesh is not a per-backend problem: the
-- calls are all UPrimitiveComponent / UMaterialInstanceDynamic methods, which every mesh
-- component is. It used to sit in the procedural backend alone, which is why a spec's
-- `color` / `texture` / `material` / `params` fields were silently inert on the static and
-- skeletal kinds even though every caller (api/building:render, api/pal:renderOn) passes
-- them through. So the MID handling is a base capability and `setColor` has a REAL default:
--
--   renderer:dressMaterial(comp, actor, def)  -- attach-time: MID(s) + write the declared
--                                                fields; remembers them for later
--   renderer:setColor(actor, color)           -- later: write to the remembered MIDs, or
--                                                make them on the spot from componentFor()
--
-- The lazy path is what makes a re-tint work for a mesh declared with no colour at all: a
-- backend only has to say WHICH component it dressed and it gets setColor for free.
--
-- Native APIs used (all BlueprintCallable, so reachable from UE4SS Lua):
--   UPrimitiveComponent:CreateAndSetMaterialInstanceDynamic(int32 elem) -> MID
--   UPrimitiveComponent:CreateAndSetMaterialInstanceDynamicFromMaterial(int32, UMaterialInterface*)
--   UPrimitiveComponent:GetNumMaterials() -> int32 / :GetMaterial(int32) / :SetMaterial(int32, ...)
--   UMaterialInstanceDynamic:SetVectorParameterValue(FName, FLinearColor)
--   UMaterialInstanceDynamic:SetScalarParameterValue(FName, float)
--   UMaterialInstanceDynamic:SetTextureParameterValue(FName, UTexture*)
--   UKismetRenderingLibrary:ImportFileAsTexture2D(WorldCtx, FString) -> UTexture2D
-- The PARAM NAMES are the open question, not the calls: nothing in either tree records a
-- Palworld material's vector/texture parameter names, so each candidate below is written
-- in turn and the ones the material does not carry are no-ops (see the TODO at
-- COLOR_PARAMS). Every call is individually pcall'd; the layer never throws.
local Renderer = {}
Renderer.__index = Renderer
Renderer.__name  = "Renderer"
Renderer.__super = nil

-- Create a subclass. Call with `:` — e.g. Renderer:extend("Procedural").
function Renderer.extend(parent, name)
    local cls = setmetatable({}, { __index = parent })
    cls.__index = cls
    cls.__name  = name or "AnonRenderer"
    cls.__super = parent
    return cls
end

-- Instantiate (backends are used as singletons, but new() is here for symmetry with
-- the other core base classes).
function Renderer.new(cls, spec)
    return setmetatable(spec or {}, cls)
end

-- Call the parent class's implementation of `method` from within an override. Works for
-- both shapes this file supports: an INSTANCE (getmetatable(self) is its class) and a
-- CLASS used as a singleton, which is how core.mesh actually holds the backends — for the
-- latter getmetatable(self) is the plain `{ __index = parent }` link table and carries no
-- __super, so reading it off `self` is what makes the singleton case resolve at all.
function Renderer.super(self, method, ...)
    local cls    = getmetatable(self)
    local parent = rawget(self, "__super") or (cls and cls.__super)
    if parent and parent[method] then return parent[method](self, ...) end
end

--=============================================================================
-- material layer — colour / texture helpers
--=============================================================================

-- Candidate parameter names to probe on the (unknown) base material. Each is written in
-- turn; the ones the material does not carry are silent no-ops.
-- TODO(mesh-material-params): no dump records the vector/texture parameter names of any
-- Palworld material, so a tint may write six names none of which the material carries.
Renderer.COLOR_PARAMS    = { "Color", "BaseColor", "Tint", "BaseColorTint", "Albedo", "EmissiveColor" }
Renderer.TEXTURE_PARAMS  = { "BaseColor", "Texture", "Albedo", "Diffuse", "BaseTexture", "MainTexture" }
Renderer.EMISSIVE_PARAMS = { "EmissiveColor", "Emissive", "EmissiveColour" }

-- Candidate base materials to PARENT a MID to, for a component whose element has NO
-- material of its own (a fresh ProceduralMeshComponent section is the standing case:
-- CreateAndSetMaterialInstanceDynamic returns nil there). StaticFindObject only returns
-- ALREADY-LOADED objects, so we try several and take the first present.
-- TODO(mesh-base-material): every candidate below is an /Engine/ editor asset that a
-- cooked shipping build may not contain at all — the one in-game record of this path is
-- "no-MID -> white" — so a probe must find whether ANY loaded material can serve here.
Renderer.BASE_MATERIAL_CANDIDATES = {
    "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial",       -- has a "Color" vector param
    "/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial",
    "/Engine/EngineDebugMaterials/VertexColorViewMode_ColorOnly.VertexColorViewMode_ColorOnly",
    "/Engine/EngineMaterials/DefaultMaterial.DefaultMaterial",
    "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial",
}

-- clamp a number to [0,1]
local function unit(n) n = tonumber(n) or 0; if n < 0 then return 0 elseif n > 1 then return 1 else return n end end

-- { r, g, b, a } (named or positional, 0..1) -> FLinearColor-shaped table
function Renderer.linearColor(c)
    if type(c) ~= "table" then return nil end
    return { R = unit(c[1] or c.r), G = unit(c[2] or c.g), B = unit(c[3] or c.b), A = c[4] or c.a or 1.0 }
end

-- the same colour as an FColor-shaped table (byte 0..255), for vertex colours
function Renderer.byteColor(c)
    local lc = Renderer.linearColor(c); if not lc then return nil end
    return { R = math.floor(lc.R * 255 + 0.5), G = math.floor(lc.G * 255 + 0.5),
             B = math.floor(lc.B * 255 + 0.5), A = math.floor((lc.A or 1) * 255 + 0.5) }
end

local function isLive(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- Only SUCCESSES are cached; a miss (candidate not loaded yet) retries on the next
-- attach — otherwise a mesh dressed before the material streams in would be stuck white
-- forever. StaticFindObject is cheap.
local baseMatCache -- { mat = <UMaterial>, path = <string> } or nil
function Renderer.resolveBaseMaterial(explicitPath)
    if explicitPath then
        local ok, m = pcall(StaticFindObject, explicitPath)
        if ok and isLive(m) then return m, explicitPath end
    end
    if baseMatCache then
        if isLive(baseMatCache.mat) then return baseMatCache.mat, baseMatCache.path end
        baseMatCache = nil
    end
    for _, p in ipairs(Renderer.BASE_MATERIAL_CANDIDATES) do
        local ok, m = pcall(StaticFindObject, p)
        if ok and isLive(m) then baseMatCache = { mat = m, path = p }; return m, p end
    end
    return nil  -- not loaded yet; retry next attach
end

-- Discovery helper: report which candidate base materials are currently loaded. `sink` is
-- called as sink(line) for each; without one the results come back as a list of
-- { path = ..., found = ... } so a caller can log them in its own scope.
function Renderer.probeMaterials(extra, sink)
    local seen, out = {}, {}
    local function try(p)
        if seen[p] then return end
        seen[p] = true
        local ok, m = pcall(StaticFindObject, p)
        local found = (ok and isLive(m)) and true or false
        out[#out + 1] = { path = p, found = found }
        if sink then pcall(sink, "MATPROBE " .. (found and "FOUND " or "----- ") .. p) end
    end
    for _, p in ipairs(Renderer.BASE_MATERIAL_CANDIDATES) do try(p) end
    for _, p in ipairs(extra or {}) do try(p) end
    return out
end

local kismetRendering = nil
-- Import a PNG off disk as a UTexture2D. Returns tex, or nil + reason.
-- TODO(mesh-texture-import): ImportFileAsTexture2D is listed as BlueprintCallable in the
-- V5 POC notes but has never been CALLED in either tree — its argument list (whether the
-- world-context object may be an actor, and whether the path is FString) is unconfirmed.
function Renderer.importTexture(worldCtx, absPath)
    if type(absPath) ~= "string" or #absPath == 0 then return nil, "no path" end
    if kismetRendering == nil then
        local ok, o = pcall(StaticFindObject, "/Script/Engine.Default__KismetRenderingLibrary")
        kismetRendering = (ok and o) or false
    end
    if not kismetRendering then return nil, "no KismetRenderingLibrary" end
    local ok, tex = pcall(function() return kismetRendering:ImportFileAsTexture2D(worldCtx, absPath) end)
    if ok and isLive(tex) then return tex end
    return nil, "ImportFileAsTexture2D failed: " .. tostring(tex)
end

--=============================================================================
-- material layer — the per-actor MID record
--=============================================================================

-- backend class -> (actor -> record). Keyed by the backend as well as the actor because
-- two backends can legitimately have dressed the same actor (a procedural marker hung on
-- a pawn whose own skeletal mesh was also swapped), and each must re-tint ITS OWN
-- component. Inner tables are weak-keyed, so an actor that goes away drops out on its own.
local midStore = {}
local function storeFor(self)
    local t = midStore[self]
    if not t then t = setmetatable({}, { __mode = "k" }); midStore[self] = t end
    return t
end

-- The MIDs this backend created on `actor`, as a list, or nil.
function Renderer:midsFor(actor)
    if not actor then return nil end
    local rec = storeFor(self)[actor]
    if not (rec and rec.mids and #rec.mids > 0) then return nil end
    return rec.mids, rec
end

-- Forget (and, where we can, undo) the material work this backend did on `actor`. The
-- restore puts the component's original material interfaces back on their slots, so a
-- backend that swapped a material on a component it does NOT own — skeletal, on the pawn's
-- own body — leaves the pawn as it found it. Returns true when a restore executed.
function Renderer:forgetMaterial(actor)
    if not actor then return false end
    local store = storeFor(self)
    local rec   = store[actor]
    store[actor] = nil
    if not (rec and rec.comp and rec.originals) then return false end
    if not isLive(rec.comp) then return false end
    local restored = false
    for elem, mat in pairs(rec.originals) do
        if pcall(function() rec.comp:SetMaterial(elem, mat) end) then restored = true end
    end
    return restored
end

-- How many material slots `comp` has. Falls back to 1 (element 0 only) when the getter is
-- not there — that is exactly the ProceduralMeshComponent single-section case.
local function slotCount(comp)
    local n
    pcall(function() n = comp:GetNumMaterials() end)
    n = tonumber(n) or 0
    if n < 1 then return 1 end
    if n > 32 then return 32 end   -- sanity clamp; nothing we dress has more slots than this
    return n
end

-- Create the dynamic material instance(s) for `comp` and remember them against `actor`.
-- `opts.material`   explicit base material object path to parent to (from spec.material)
-- `opts.preferBase` try the base-material parent FIRST (procedural: a fresh section has no
--                   material of its own, so plain CreateAndSetMaterialInstanceDynamic
--                   returns nil). A component carrying real authored materials must NOT
--                   prefer it, or the tint would replace the mesh's own look with a
--                   flat engine material.
-- Returns the list of MIDs (possibly empty) plus the base-material path that was used.
function Renderer:createMids(comp, actor, opts)
    opts = opts or {}
    if not isLive(comp) then return {}, nil end

    local base, basePath
    if opts.preferBase or opts.material then base, basePath = Renderer.resolveBaseMaterial(opts.material) end
    if not base then basePath = nil end

    -- Keep the FIRST originals we ever captured for this actor. A second attach reads
    -- back the MID the first one installed, so overwriting here would make :detach
    -- "restore" our own dynamic material instead of the mesh's authored one.
    local prev      = storeFor(self)[actor or comp]
    local originals = (prev and prev.comp == comp and prev.originals) or {}

    local mids = {}
    for elem = 0, slotCount(comp) - 1 do
        local orig
        if originals[elem] == nil then pcall(function() orig = comp:GetMaterial(elem) end) end
        local mid
        if base then
            local ok, m = pcall(function()
                return comp:CreateAndSetMaterialInstanceDynamicFromMaterial(elem, base)
            end)
            if ok and isLive(m) then mid = m end
        end
        if not mid then
            local ok, m = pcall(function() return comp:CreateAndSetMaterialInstanceDynamic(elem) end)
            if ok and isLive(m) then mid = m end
        end
        if mid then
            mids[#mids + 1] = mid
            if orig ~= nil then originals[elem] = orig end
        end
    end
    if #mids > 0 then
        storeFor(self)[actor or comp] = { mids = mids, comp = comp, originals = originals }
    end
    return mids, basePath
end

-- Write the declared material fields of `def` onto every MID in `mids`. Returns a list of
-- short status words describing what was attempted, for the caller to log.
function Renderer:writeMaterial(mids, def, worldCtx)
    local status = {}
    if not (mids and #mids > 0 and type(def) == "table") then return status end

    local function eachMid(fn) for _, mid in ipairs(mids) do pcall(fn, mid) end end

    -- texture (imported PNG) — try the known texture param names
    if def.texture then
        local tex, terr = Renderer.importTexture(worldCtx, def.texture)
        if tex then
            status[#status + 1] = "tex-imported"
            for _, name in ipairs(self.TEXTURE_PARAMS) do
                eachMid(function(mid) mid:SetTextureParameterValue(FName(name), tex) end)
            end
        else
            status[#status + 1] = "tex-fail(" .. tostring(terr) .. ")"
        end
    end

    -- color (flat tint) — probe the candidate vector param names. The emissive names go
    -- with them so a declared colour and a later :setColor produce the SAME look; when
    -- they diverged, painting at attach time and re-painting afterwards did not match.
    if def.color then
        local lc = Renderer.linearColor(def.color)
        if lc then
            for _, name in ipairs(self.COLOR_PARAMS) do
                eachMid(function(mid) mid:SetVectorParameterValue(FName(name), lc) end)
            end
            for _, name in ipairs(self.EMISSIVE_PARAMS) do
                eachMid(function(mid) mid:SetVectorParameterValue(FName(name), lc) end)
            end
            status[#status + 1] = "color-set"
        end
    end

    -- explicit passthrough: { vector = { name = {r,g,b,a} }, scalar = { name = v },
    --                         texture = { name = <abs png path> } }
    if type(def.params) == "table" then
        if type(def.params.vector) == "table" then
            for name, val in pairs(def.params.vector) do
                local lc = Renderer.linearColor(val)
                if lc then eachMid(function(mid) mid:SetVectorParameterValue(FName(name), lc) end) end
            end
        end
        if type(def.params.scalar) == "table" then
            for name, val in pairs(def.params.scalar) do
                local v = tonumber(val) or 0
                eachMid(function(mid) mid:SetScalarParameterValue(FName(name), v) end)
            end
        end
        if type(def.params.texture) == "table" then
            for name, p in pairs(def.params.texture) do
                local tex = Renderer.importTexture(worldCtx, p)
                if tex then eachMid(function(mid) mid:SetTextureParameterValue(FName(name), tex) end) end
            end
        end
        status[#status + 1] = "params"
    end
    return status
end

-- Attach-time entry point: build the MID(s) on `comp` for `actor` and write whatever
-- `def` declared. Fully fail-soft; never throws. Returns a short status STRING for the
-- caller's log — "none" when the spec declared no material fields at all, so a plain
-- attach stays silent.
--
-- `opts.always` creates the MID even when nothing was declared (the procedural backend
-- does this so a later setColor has something to write to; a backend dressing a component
-- it does not own leaves it alone until asked).
function Renderer:dressMaterial(comp, actor, def, opts)
    def  = type(def) == "table" and def or {}
    opts = opts or {}
    local declared = (def.color or def.texture or def.params or def.material) and true or false
    if not (declared or opts.always) then return "none" end

    local mids, basePath = self:createMids(comp, actor,
        { material = def.material, preferBase = opts.preferBase })
    local status = {}
    if basePath then status[#status + 1] = "base:" .. (basePath:gsub("^.*/", ""):gsub("%..*$", "")) end
    if #mids == 0 then
        status[#status + 1] = "no-MID(no material on the component and no base material loaded)"
        return declared and table.concat(status, ",") or "none"
    end
    if not declared then return "none" end
    for _, w in ipairs(self:writeMaterial(mids, def, actor)) do status[#status + 1] = w end
    return #status > 0 and table.concat(status, ",") or "mid-only"
end

--=============================================================================
-- contract (override in a backend; attach / detach default inert)
--=============================================================================

-- Attach a mesh described by `spec` to `actor`. Returns true on success.
function Renderer:attach(actor, spec) return false end

-- The component this backend put the mesh on, for `actor`. Overriding this is all a
-- backend has to do to get a working setColor: it lets the default below create the MID
-- on demand for a mesh that was attached without any colour declared.
function Renderer:componentFor(actor) return nil end

-- Re-tint an already-attached mesh. `color` = { r, g, b, a } 0..1. Writes both the colour
-- and the emissive param names, so on a material that supports it a tint visibly glows.
-- Returns true only when a write actually EXECUTED — a MID we cannot reach, or one that
-- does not carry SetVectorParameterValue, is an honest false rather than a pretended tint.
function Renderer:setColor(actor, color)
    if not actor then return false end
    local lc = Renderer.linearColor(color)
    if not lc then return false end

    local mids = self:midsFor(actor)
    if not mids then
        -- never painted, but we know which component we dressed: make the MID(s) now.
        local comp = self:componentFor(actor)
        if not isLive(comp) then return false end
        mids = self:createMids(comp, actor, {})
        if #mids == 0 then return false end
    end

    local wrote = false
    for _, mid in ipairs(mids) do
        for _, name in ipairs(self.COLOR_PARAMS) do
            if pcall(function() mid:SetVectorParameterValue(FName(name), lc) end) then wrote = true end
        end
        for _, name in ipairs(self.EMISSIVE_PARAMS) do
            pcall(function() mid:SetVectorParameterValue(FName(name), lc) end)
        end
    end
    return wrote
end

-- Remove from `actor` what this backend's attach added, so the actor can be dressed
-- again. Returns true only when the removal actually executed; a backend that added
-- nothing of its own returns false.
function Renderer:detach(actor) return false end

return Renderer
