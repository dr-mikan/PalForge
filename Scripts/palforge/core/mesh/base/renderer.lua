-- PalForge core.mesh.base.renderer: the abstract renderer contract PLUS the material
-- layer every backend shares. Every mesh backend (procedural OBJ, static UStaticMesh,
-- skeletal USkeletalMesh) extends this and overrides what it implements.
-- One PalForge dep: core.signature, for the two native calls here that no run has ever
-- watched succeed (K2_DestroyComponent, ImportFileAsTexture2D).
--
-- Contract:
--   renderer:attach(actor, spec)    -> attach a mesh to `actor` from `spec`
--   renderer:setColor(actor, color) -> re-tint an attached mesh
--   renderer:detach(actor)          -> remove again what attach added
--   renderer:componentFor(actor)    -> the component this backend dressed `actor` with
--   Renderer.destroyComponent(comp) -> destroy a component a backend created
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
-- Native APIs used, every one of them now read off the shipping binary rather than
-- assumed. Line numbers are dumps/cxx/Engine.hpp; the owning classes are
-- UPrimitiveComponent (:19614) and UMaterialInstanceDynamic (:17568), and every mesh
-- component in the game is a UPrimitiveComponent, which is why this layer is shared:
--   :19842  UMaterialInstanceDynamic* CreateAndSetMaterialInstanceDynamic(int32 ElementIndex)
--   :19841  UMaterialInstanceDynamic* CreateAndSetMaterialInstanceDynamicFromMaterial(
--                                       int32 ElementIndex, UMaterialInterface* Parent)
--   :19822  int32 GetNumMaterials()
--   :19824  UMaterialInterface* GetMaterial(int32 ElementIndex)
--   :19759  void SetMaterial(int32 ElementIndex, UMaterialInterface* Material)
--   :17572  void SetVectorParameterValue(FName ParameterName, FLinearColor Value)
--   :17576  void SetScalarParameterValue(FName ParameterName, float Value)
--   :17574  void SetTextureParameterValue(FName ParameterName, UTexture* Value)
--   :14694  UTexture2D* ImportFileAsTexture2D(UObject* WorldContextObject, FString Filename)
--           (on UKismetRenderingLibrary, :14678)
-- Every arity and every argument type this file passes matches those declarations. The
-- FLinearColor argument is a struct passed as a Lua table, which is the same marshalling
-- the proven procedural chain already performs on FVector (SetWorldScale3D).
--
-- The PARAM NAMES remain the open question, and the dump cannot close it: a CXXHeaderDump
-- records CLASS declarations, and a material's parameter names are asset DATA that lives
-- in the .uasset, not in any header. So each candidate below is still written in turn and
-- the ones the material does not carry are no-ops (see the TODO at COLOR_PARAMS). Every
-- call is individually pcall'd; the layer never throws.
local signature = require("palforge.core.signature")

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
--
-- ANSWERED, 2026-07-26. The names were read off the player's own material in a live save and
-- they are recorded above COLOR_PARAMS. The dump genuinely could not have told us — a
-- CXXHeaderDump records classes, and which parameters an asset exposes is data inside a
-- .uasset — so this was closed by reading the running game instead, which is what
-- Renderer.describeMaterials exists to do. Point it at any actor to read its material names.
--
-- WHAT IS STILL OWED: nobody has watched a colour actually CHANGE. The three writes are
-- declared exactly as called, so "the write did not execute" is eliminated, and the names are
-- now real rather than guessed — but a tint landing on screen is a different observation from
-- either of those, and it has not been made.
Renderer.COLOR_PARAMS    = { "BaseColor", "Subsurface Color",
                             "Color", "Tint", "BaseColorTint", "Albedo", "EmissiveColor" }
Renderer.TEXTURE_PARAMS  = { "Base Texture", "Subsurface Texture", "Normal Map",
                             "BaseColor", "Texture", "Albedo", "Diffuse", "MainTexture" }
Renderer.EMISSIVE_PARAMS = { "EmissiveColor", "Emissive", "EmissiveColour" }

-- Candidate base materials to PARENT a MID to, for a component whose element has NO
-- material of its own (a fresh ProceduralMeshComponent section is the standing case:
-- CreateAndSetMaterialInstanceDynamic returns nil there). StaticFindObject only returns
-- ALREADY-LOADED objects, so we try several and take the first present.
-- ANSWERED, 2026-07-26, and by the same read. A material that is currently RENDERING is
-- cooked and loadable by construction, which is what made this closable when an asset path
-- could only ever be a guess: the player's own outfit material instance is now the first
-- BASE_MATERIAL_CANDIDATES entry, and it carries the BaseColor vector parameter a tint needs.
--
-- WHAT IS STILL OWED: the same as above — nobody has watched a procedural mesh come out tinted
-- rather than white. And the honest caveat about the candidate itself is at the list.
Renderer.BASE_MATERIAL_CANDIDATES = {
    -- measured live, 2026-07-26, on BP_Player_Female_C.CharacterMesh0
    "/Game/Pal/Model/Character/Player/Outfit/SK_Player_Female_Outfit_OldCloth001/v01/MI_Player_Female_Outfit_OldCloth001_v01_M01.MI_Player_Female_Outfit_OldCloth001_v01_M01",
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

-- How many material slots `comp` has. Falls back to 1 (element 0 only) when the getter is
-- not there — that is exactly the ProceduralMeshComponent single-section case. It sits up
-- here rather than beside createMids because describeMaterials walks the same slots.
local function slotCount(comp)
    local n
    pcall(function() n = comp:GetNumMaterials() end)
    n = tonumber(n) or 0
    if n < 1 then return 1 end
    if n > 32 then return 32 end   -- sanity clamp; nothing we dress has more slots than this
    return n
end

-- One element out of a UE4SS TArray, unwrapped. Array elements arrive wrapped in
-- RemoteUnrealParam on this build — the trap that made an icon column read the right
-- LENGTH with nothing in it — so anything walking a TArray here goes through this.
local function unwrap(v)
    if type(v) == "userdata" then
        local ok, inner = pcall(function() return v.get and v:get() end)
        if ok and inner ~= nil then return inner end
    end
    return v
end

-- Call `fn(elem)` for each element of a UE4SS TArray. Three access shapes are tried,
-- because UE4SS spells array access differently across builds and this tree has been
-- bitten by each: ForEach, 1-based [i], 0-based Get(i-1). Pure READ; calls nothing.
local function eachElement(arr, fn)
    if arr == nil then return 0 end
    local seen = 0
    pcall(function()
        if arr.ForEach then
            arr:ForEach(function(_, elem) seen = seen + 1; pcall(fn, unwrap(elem)) end)
        end
    end)
    if seen > 0 then return seen end

    local n = 0
    pcall(function() if arr.GetArrayNum then n = arr:GetArrayNum() end end)
    for i = 1, n do
        local e
        pcall(function() e = unwrap(arr[i]) end)
        if e == nil then pcall(function() e = unwrap(arr:Get(i - 1)) end) end
        if e ~= nil then seen = seen + 1; pcall(fn, e) end
    end
    return seen
end

-- The parameter NAMES held in one of a material instance's override arrays, as a list of
-- strings. `field` is "VectorParameterValues" / "ScalarParameterValues" /
-- "TextureParameterValues" — reflected properties on UMaterialInstance
-- (dumps/cxx/Engine.hpp:17548-17551), whose elements each carry an FMaterialParameterInfo
-- with an FName Name (:7652 -> :4038). Empty is a real answer: a material with no
-- overrides in that category, or a plain UMaterial, which keeps its parameters in an
-- expression graph that is not reflected at all.
local function paramNames(mat, field)
    local out = {}
    local arr
    pcall(function() arr = mat[field] end)
    eachElement(arr, function(entry)
        local ok, name = pcall(function()
            return entry.ParameterInfo.Name:ToString()
        end)
        if ok and type(name) == "string" and #name > 0 then out[#out + 1] = name end
    end)
    return out
end

-- READ what materials `comp` is wearing and which parameter names each one carries, and
-- write NOTHING. This is the probe both open mesh items are waiting on, and it is safe to
-- run unattended on a real save precisely because it only reads:
--
--   * mesh-base-material wants ONE loaded UMaterialInterface that can parent a MID. A
--     material that is currently rendering is cooked, loaded and usable, so the full name
--     printed here is an answer rather than a guess (Engine.hpp:19824 GetMaterial).
--   * mesh-material-params wants the NAMES a Palworld material carries, which is asset
--     data no header can hold — but a material INSTANCE lists its own overrides in
--     reflected arrays (Engine.hpp:17548-17551), so they can be read off a live object.
--
-- `sink` is called as sink(line) for each line; without one the results come back as a
-- list of { element, material, vector, scalar, texture } for the caller to report.
-- Every mesh component reachable from `root`, which may be an actor or a component.
--
-- ONE COMPONENT IS NOT ENOUGH, and the first live run is what showed it: asking the player pawn
-- for its .Mesh found a component whose only slot was empty ("MATDESC [0] no material on this
-- slot"). A Palworld player is not one mesh — dumps/cxx/ ships ABP_Player_Hair.hpp,
-- ABP_Player_Head.hpp and ABP_Player.hpp as separate blueprints, and ALI_HumanCloth.hpp beside
-- them — so the materials that are actually on screen hang off CHILD components, and a walk
-- that stops at .Mesh reads the one place they are not.
--
-- GetComponentsByClass is the documented way to enumerate them (Engine.hpp, AActor). Failing
-- that, the two named members are tried directly. Nothing here calls anything that writes.
local function meshComponents(root)
    local out = {}
    local function add(c) if isLive(c) then out[#out + 1] = c end end

    if isLive(root) then
        -- root may already BE a component; a component has no GetComponentsByClass, so a failed
        -- call here is the ordinary case rather than an error.
        add(root)
        for _, name in ipairs({ "Mesh", "SkeletalMesh", "StaticMeshComponent" }) do
            local c; pcall(function() c = root[name] end)
            add(c)
        end
        for _, className in ipairs({ "/Script/Engine.SkeletalMeshComponent",
                                     "/Script/Engine.StaticMeshComponent" }) do
            local cls; pcall(function() cls = StaticFindObject(className) end)
            if isLive(cls) then
                local list; pcall(function() list = root:GetComponentsByClass(cls) end)
                pcall(function()
                    for i = 1, #list do add(list[i]) end
                end)
            end
        end
    end
    return out
end

function Renderer.describeMaterials(root, sink)
    local out = {}
    local function say(line) if sink then pcall(sink, line) end end

    local comps = meshComponents(root)
    if #comps == 0 then
        say("MATDESC no live mesh component to read")
        return out
    end
    say(string.format("MATDESC %d mesh component(s) reachable", #comps))
    for _, comp in ipairs(comps) do
        local cname; pcall(function() cname = comp:GetFName():ToString() end)
        say(string.format("MATDESC component %s (%d slot(s))", tostring(cname or "?"), slotCount(comp)))
        Renderer.describeOneComponent(comp, say, out)
    end
    return out
end

-- One component's slots. Split out so describeMaterials can walk several without nesting.
function Renderer.describeOneComponent(comp, say, out)
    for elem = 0, slotCount(comp) - 1 do
        local mat
        pcall(function() mat = comp:GetMaterial(elem) end)
        if not isLive(mat) then
            say(string.format("MATDESC [%d] no material on this slot", elem))
        else
            local path, cls
            pcall(function() path = mat:GetFullName() end)
            pcall(function() cls = mat:GetClass():GetFName():ToString() end)
            local rec = {
                element = elem,
                material = tostring(path or "?"),
                class    = tostring(cls or "?"),
                vector   = paramNames(mat, "VectorParameterValues"),
                scalar   = paramNames(mat, "ScalarParameterValues"),
                texture  = paramNames(mat, "TextureParameterValues"),
            }
            out[#out + 1] = rec
            say(string.format("MATDESC [%d] %s (%s)", elem, rec.material, rec.class))
            -- FOLLOW .Parent UP. A MaterialInstanceDynamic's arrays hold only what has been
            -- OVERRIDDEN on it, so "vector: (none)" on a MID says nothing about the material —
            -- only that nobody set a vector on that instance. The authored values live on the
            -- MaterialInstanceConstant it derives from (Engine.hpp:17544 declares
            -- `UMaterialInterface* Parent` on UMaterialInstance), so walk up until the arrays
            -- stop being empty or the chain ends. Bounded, because a cycle here would hang F1.
            local parent, depth = mat, 0
            while depth < 6 do
                local up; pcall(function() up = parent.Parent end)
                if not isLive(up) then break end
                parent, depth = up, depth + 1
                local pv = paramNames(parent, "VectorParameterValues")
                local ps = paramNames(parent, "ScalarParameterValues")
                local pt = paramNames(parent, "TextureParameterValues")
                local pname, pcls
                pcall(function() pname = parent:GetFullName() end)
                pcall(function() pcls = parent:GetClass():GetFName():ToString() end)
                say(string.format("MATDESC [%d]   parent[%d] %s (%s)", elem, depth,
                    tostring(pname or "?"), tostring(pcls or "?")))
                if #pv > 0 or #ps > 0 or #pt > 0 then
                    say(string.format("MATDESC [%d]   parent[%d] vector: %s", elem, depth,
                        #pv > 0 and table.concat(pv, ", ") or "(none)"))
                    say(string.format("MATDESC [%d]   parent[%d] scalar: %s", elem, depth,
                        #ps > 0 and table.concat(ps, ", ") or "(none)"))
                    say(string.format("MATDESC [%d]   parent[%d] texture: %s", elem, depth,
                        #pt > 0 and table.concat(pt, ", ") or "(none)"))
                    rec.parentVector, rec.parentScalar, rec.parentTexture = pv, ps, pt
                    break
                end
            end
            say(string.format("MATDESC [%d]   vector: %s", elem,
                #rec.vector > 0 and table.concat(rec.vector, ", ") or "(none)"))
            say(string.format("MATDESC [%d]   scalar: %s", elem,
                #rec.scalar > 0 and table.concat(rec.scalar, ", ") or "(none)"))
            say(string.format("MATDESC [%d]   texture: %s", elem,
                #rec.texture > 0 and table.concat(rec.texture, ", ") or "(none)"))
        end
    end
    return out
end

local kismetRendering = nil

-- The declared shape of UKismetRenderingLibrary::ImportFileAsTexture2D, in the order
-- core.signature checks it. dumps/cxx/Engine.hpp:14694 —
--   UTexture2D* ImportFileAsTexture2D(UObject* WorldContextObject, FString Filename)
-- on UKismetRenderingLibrary (:14678). Both halves of the old unknown are answered by
-- that line: the world context is a plain UObject*, so an ACTOR qualifies (which is what
-- writeMaterial passes), and the path really is an FString — an ordinary Lua string, NOT
-- an FName, so this is not the marshalling shape that kills the process.
local IMPORT_TEXTURE_PARAMS = { "ObjectProperty", "StrProperty" }

-- Import a PNG off disk as a UTexture2D. Returns tex, or nil + reason.
-- STILL UNOBSERVED: the signature is right, but no run in either tree has ever CALLED
-- this, so nothing has watched a texture come back. It goes through core.signature so a
-- build that does not declare it is a refusal that never touches the game, and the reason
-- string says which of the two it was.
function Renderer.importTexture(worldCtx, absPath)
    if type(absPath) ~= "string" or #absPath == 0 then return nil, "no path" end
    if kismetRendering == nil then
        local ok, o = pcall(StaticFindObject, "/Script/Engine.Default__KismetRenderingLibrary")
        kismetRendering = (ok and o) or false
    end
    if not kismetRendering then return nil, "no KismetRenderingLibrary" end
    local ok, tex = signature.call(kismetRendering, "ImportFileAsTexture2D",
                                   IMPORT_TEXTURE_PARAMS, worldCtx, absPath)
    if not ok then return nil, "ImportFileAsTexture2D did not fire (see the signature log)" end
    if isLive(tex) then return tex end
    return nil, "ImportFileAsTexture2D ran and returned nothing importable"
end

-- Destroy a component a backend created. Shared because procedural and static both add a
-- component of their own and both have to be able to take it off again; one copy means
-- one place where the evidence lives.
--
-- UActorComponent::K2_DestroyComponent(UObject* Object) — dumps/cxx/Engine.hpp:9972, on
-- UActorComponent (:9936), which every mesh component is. That settles what the
-- mesh-detach-destroycomponent marker asked: one argument, an ObjectProperty, and the
-- component itself is what the Blueprint node passes — which is exactly the call this
-- makes. The argument-count mismatch that would have made detach a silent no-op reporting
-- true is ruled out.
--
-- STILL UNOBSERVED: no run has watched a component actually disappear. A true here means
-- core.signature found the function on the live class and the call returned without
-- raising, which is the honest ceiling until someone counts ProceduralMeshComponents
-- before and after.
function Renderer.destroyComponent(comp)
    if not isLive(comp) then return false end
    local ok = signature.call(comp, "K2_DestroyComponent", { "ObjectProperty" }, comp)
    return ok
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

-- Create the dynamic material instance(s) for `comp` and remember them against `actor`.
-- `opts.material`   explicit base material object path to parent to (from spec.material)
-- `opts.preferBase` try the base-material parent FIRST (procedural: a fresh section has no
--                   material of its own, so plain CreateAndSetMaterialInstanceDynamic
--                   returns nil). A component carrying real authored materials must NOT
--                   prefer it, or the tint would replace the mesh's own look with a
--                   flat engine material.
-- Returns the list of MIDs (possibly empty) plus the base-material path that was used.
--
-- The two creators below are not two spellings of one capability, and the dump eliminates
-- neither: Engine.hpp:19841 and :19842 declare both, and they need different things —
-- ...FromMaterial needs a base material object to parent to, plain
-- CreateAndSetMaterialInstanceDynamic needs the slot to already carry an authored material.
-- Which of the two can work is a property of the COMPONENT, not of the build, so both stay
-- and the second runs only where the first had nothing to work with.
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
