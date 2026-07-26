-- palforge/test/probes/pal.lua — what a LIVE pal's mesh component really is, in its own words.
--
-- Closes three plan/TODO.md items, in this order: `mesh-skeletal-setter` (which mesh setter a
-- pal's component carries and whether the component is reachable at all), `mesh-skeletal-animclass`
-- (SetAnimClass / SetAnimationMode and the EAnimationMode value we merely assume is 0) and
-- `mesh-material-params` (the vector / scalar / texture parameter NAMES a real Palworld material
-- exposes, versus the six names core/mesh/base/renderer.lua guesses). WHAT MUST BE ON SCREEN: a
-- loaded save with a live pal standing near the player — spawn or whistle one out first, then
-- press the probe key. With no pal but a world it falls back to the player pawn and says so.
-- READ-ONLY: nothing here sets a mesh, an anim class or a material parameter; every write the
-- TODO paragraphs describe is named in a NOTE at the end of its section instead.
local probe   = require("palforge.test.probe")
local support = require("palforge.test.support")

local M = {}

--=============================================================================
-- inline reflection the toolkit does not carry
--
-- probe.lua has no chain-walking property map, no TArray reader and no enum dump. These
-- three follow its rules: every engine touch is pcall'd, every answer is printable, and a
-- missing name prints "absent" rather than raising.
--=============================================================================

-- Property names worth calling out by hand, per the TODO grep lists.
local MESH_PROPS = { "SkinnedAsset", "SkeletalMesh", "SkeletalMeshAsset", "RelativeScale3D",
                     "RelativeLocation", "bDisableChangeMesh", "DisableChangeMesh" }
local ANIM_PROPS = { "AnimClass", "AnimationMode", "AnimScriptInstance", "AnimBlueprintGeneratedClass" }

-- Substrings that make a property interesting enough to print from the whole class chain.
local PROP_GREP = { "mesh", "skin", "anim", "relative", "material" }

-- The six colour names core/mesh/base/renderer.lua writes on every tint, plus its emissive
-- and texture lists. Read from the module when it loads, so this probe cannot drift from
-- the code it is judging; the literals are the fallback for a headless run.
local CANDIDATES = {
    color    = { "Color", "BaseColor", "Tint", "BaseColorTint", "Albedo", "EmissiveColor" },
    emissive = { "EmissiveColor", "Emissive", "EmissiveColour" },
    texture  = { "BaseColor", "Texture", "Albedo", "Diffuse", "BaseTexture", "MainTexture" },
}
do
    local ok, R = pcall(require, "palforge.core.mesh.base.renderer")
    if ok and type(R) == "table" then
        if type(R.COLOR_PARAMS) == "table" then CANDIDATES.color = R.COLOR_PARAMS end
        if type(R.EMISSIVE_PARAMS) == "table" then CANDIDATES.emissive = R.EMISSIVE_PARAMS end
        if type(R.TEXTURE_PARAMS) == "table" then CANDIDATES.texture = R.TEXTURE_PARAMS end
    end
end

---An object's class chain as a list of UStructs, leaf first. Empty when nothing is readable.
local function classChain(obj)
    local out = {}
    local k; pcall(function() k = obj:GetClass() end)
    local depth = 0
    while probe.valid(k) and depth < 12 do
        out[#out + 1] = k
        local parent
        pcall(function() parent = k:GetSuperStruct() end)
        if not probe.valid(parent) then pcall(function() parent = k.SuperStruct end) end
        k = parent
        depth = depth + 1
    end
    return out
end

---Every property on a chain as name -> { kind, offset, owner }, plus the total seen.
---Nothing is printed here: the callers choose which names are worth a line.
local function propMap(chain)
    local map, total = {}, 0
    for _, k in ipairs(chain) do
        local owner = probe.name(k)
        pcall(function()
            k:ForEachProperty(function(p)
                pcall(function()
                    local n = probe.name(p)
                    total = total + 1
                    if map[n] == nil then
                        local off
                        pcall(function() off = p:GetOffset_Internal() end)
                        map[n] = { kind = probe.className(p), offset = off, owner = owner }
                    end
                end)
            end)
        end)
    end
    return map, total
end

---Print PROP lines for the named properties, hit or miss. A run of "absent" is the answer.
local function propVerdict(map, names, label)
    local pre = (label and #label > 0) and (label .. " ") or ""
    for _, n in ipairs(names) do
        local r = map[n]
        if r then
            probe.line("PROP %s%s : %s @%s (on %s)", pre, n, r.kind, tostring(r.offset), r.owner)
        else
            probe.line("PROP %s%s -> absent", pre, n)
        end
    end
end

---Print every chain property whose name matches one of PROP_GREP, bounded.
local function propGrep(map, label)
    local hits = {}
    for n, r in pairs(map) do
        local low = n:lower()
        for _, needle in ipairs(PROP_GREP) do
            if low:find(needle, 1, true) then hits[#hits + 1] = { n = n, r = r }; break end
        end
    end
    table.sort(hits, function(a, b) return a.n < b.n end)
    probe.line("PROP %s matched=%d of the chain", label, #hits)
    for i, h in ipairs(hits) do
        if i > probe.LIST_LIMIT then probe.line("PROP ... (%d more)", #hits - probe.LIST_LIMIT); break end
        probe.line("PROP %s : %s @%s (on %s)", h.n, h.r.kind, tostring(h.r.offset), h.r.owner)
    end
end

---Walk a UE array property two ways (Lua indexing first, then UE4SS's ForEach), because
---which one this build answers to is itself unknown. Returns count, visited.
local function eachEntry(arr, limit, fn)
    local n
    pcall(function() n = #arr end)
    if not tonumber(n) then pcall(function() n = arr:GetArrayNum() end) end
    n = tonumber(n)
    local seen = 0
    if not n or n <= 0 then return n, 0 end
    for i = 1, math.min(n, limit) do
        local e; local ok = pcall(function() e = arr[i] end)
        if ok and e ~= nil then seen = seen + 1; pcall(fn, i, e) end
    end
    if seen == 0 then
        pcall(function()
            arr:ForEach(function(i, el)
                if seen >= limit then return end
                local v = el
                pcall(function() if el.get then v = el:get() end end)
                seen = seen + 1
                pcall(fn, i, v)
            end)
        end)
    end
    return n, seen
end

---One line for a parameter value: a colour, a number, or whatever probe.describe makes of it.
local function shortValue(v)
    local t = type(v)
    if t == "number" or t == "string" or t == "boolean" or t == "nil" then return tostring(v) end
    local s
    local ok = pcall(function() s = string.format("(R=%.3f G=%.3f B=%.3f A=%.3f)", v.R, v.G, v.B, v.A) end)
    if ok and s then return s end
    return probe.describe(v)
end

--=============================================================================
-- the subject: a live pal and its mesh component
--
-- Resolved once and cached, so the anim and material sections describe the SAME component
-- the setter section enumerated — which is what the animclass TODO asks for by name.
--=============================================================================

local subject   -- { pal, comp, chain, props, viaProp, viaGetter } once acquired
local resolved  -- true after the first attempt, hit or miss

---Pick a live PalCharacter that is not the player: nearest wins, so the pal you parked in
---front of the camera is the one described. Falls back to the player pawn, loudly.
local function findPal()
    local player = support.player()
    local mine   = player and probe.full(player) or nil
    local here   = player and support.location(player) or nil
    local list   = probe.allOf("PalCharacter")

    local best, bestDist
    for _, a in ipairs(list) do
        if probe.valid(a) and probe.full(a) ~= mine and not probe.className(a):find("Player") then
            local d = 0
            local pos = here and support.location(a)
            if pos and here then
                local dx, dy, dz = pos.x - here.x, pos.y - here.y, pos.z - here.z
                d = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            if not bestDist or d < bestDist then best, bestDist = a, d end
        end
    end
    if best then
        probe.line("VALUE nearest non-player PalCharacter -> %s  (%.0f cm away)", probe.full(best), bestDist or -1)
        return best, false
    end
    probe.line("VALUE no non-player PalCharacter is live -> falling back to the player pawn")
    probe.note("a pal-only member (SetDisableChangeMesh) can read as absent on the player; "
        .. "spawn or whistle out a pal and re-run to be sure")
    return player, true
end

---The pal, its mesh component and the component's class chain — printed once, reused thrice.
local function acquire()
    if resolved then return subject end
    resolved = true

    local pal, isPlayer = findPal()
    if not probe.valid(pal) then probe.line("VALUE no character to describe"); return nil end

    probe.line("VALUE subject class -> %s", probe.className(pal))
    local viaProp   = probe.read(pal, "Mesh")
    local viaGetter = probe.callGet(pal, "GetMesh")
    local comp = (probe.valid(viaProp) and viaProp) or (probe.valid(viaGetter) and viaGetter) or nil
    if not comp then
        probe.line("CLASS mesh component -> absent by BOTH .Mesh and :GetMesh()")
        subject = { pal = pal, isPlayer = isPlayer }
        return subject
    end

    probe.line("CLASS mesh component -> %s  class=%s", probe.full(comp), probe.className(comp))
    local chain = classChain(comp)
    probe.chain(comp, false)
    local props, total = propMap(chain)
    probe.line("PROP chain properties total=%d (distinct=%d)", total, (function()
        local n = 0; for _ in pairs(props) do n = n + 1 end; return n
    end)())

    subject = {
        pal = pal, isPlayer = isPlayer, comp = comp, chain = chain, props = props,
        cls = chain[1],
        viaProp = probe.valid(viaProp), viaGetter = probe.valid(viaGetter),
    }
    return subject
end

--=============================================================================
-- mesh-skeletal-setter
--=============================================================================

local function mesh_skeletal_setter()
    probe.begin("mesh-skeletal-setter",
        "which setter a live pal's mesh component carries, and whether .Mesh reaches it at all")

    local s = acquire()
    if not (s and s.comp) then
        probe.note("core/mesh/skeletal.lua's meshComponentOf() would return nil here, so every "
            .. "attachTo on this actor is the 'no readable mesh component' false")
        probe.finish()
        return
    end

    probe.section("how the component is reachable")
    probe.line("VALUE .Mesh property -> %s", s.viaProp and "VALID" or "absent")
    probe.line("VALUE :GetMesh() -> %s", s.viaGetter and "VALID" or "absent")

    probe.section("the component class, in full")
    probe.functions(s.cls, "leaf class of the mesh component")
    probe.properties(s.cls, "leaf class of the mesh component")

    probe.section("the setters, by name, searched through the whole chain")
    for _, fn in ipairs({ "SetSkinnedAssetAndUpdate", "SetSkeletalMeshAsset", "SetDisableChangeMesh",
                          "GetSkinnedAsset", "GetSkeletalMeshAsset", "SetRelativeScale3D",
                          "K2_SetRelativeLocation" }) do
        probe.params(s.cls, fn)
    end

    probe.section("mesh-ish properties, with offsets")
    propVerdict(s.props, MESH_PROPS, "")
    propGrep(s.props, "chain grep")

    probe.section("what the component wears RIGHT NOW, four ways")
    probe.callGet(s.comp, "GetSkinnedAsset")
    probe.callGet(s.comp, "GetSkeletalMeshAsset")
    probe.read(s.comp, "SkinnedAsset")
    probe.read(s.comp, "SkeletalMesh")

    probe.note("READ THIS AS: whichever of SetSkinnedAssetAndUpdate / SetSkeletalMeshAsset printed "
        .. "a PARAM line is the real setter, and its listed parameters are the real signature — "
        .. "core/mesh/skeletal.lua setMesh() calls them in that order. If BOTH say 'function "
        .. "absent', kind=\"skeletal\" can never work on a pal through this component and the "
        .. "backend must be rewritten around whatever the leaf FN listing above does carry.")
    probe.note("If '.Mesh property -> absent' but ':GetMesh() -> VALID' (or the reverse), "
        .. "meshComponentOf() already tries both, so only the loser is dead code. If the "
        .. "'RIGHT NOW' block is four nils, detach can never restore the original mesh — "
        .. "skeletal.lua's assetOn() is that same list — so attach must be treated as one-way.")
    probe.finish()
end

--=============================================================================
-- mesh-skeletal-animclass
--=============================================================================

local function mesh_skeletal_animclass()
    probe.begin("mesh-skeletal-animclass",
        "SetAnimClass / SetAnimationMode on that same component, plus what EAnimationMode really is")

    local s = acquire()
    if not (s and s.comp) then
        probe.line("VALUE no mesh component from the setter section -> nothing to ask")
        probe.note("resolve mesh-skeletal-setter first; animClass cannot be reached without "
            .. "the component that carries it")
        probe.finish()
        return
    end

    probe.section("the anim functions, searched through the whole chain")
    for _, fn in ipairs({ "SetAnimClass", "SetAnimationMode", "SetAnimInstanceClass",
                          "GetAnimInstance", "LinkAnimClassLayers" }) do
        probe.params(s.cls, fn)
    end

    probe.section("anim properties, with offsets")
    propVerdict(s.props, ANIM_PROPS, "")

    probe.section("what the component is animated by RIGHT NOW")
    probe.read(s.comp, "AnimClass")
    probe.read(s.comp, "AnimationMode")
    probe.callGet(s.comp, "GetAnimInstance")

    probe.section("resolving a real ABP class")
    local abpPath = "/Game/Pal/Blueprint/Character/Monster/PalActorBP/ChickenPal/ABP_ChickenPal.ABP_ChickenPal_C"
    local abp = probe.find(abpPath)
    if not abp then
        local r
        local ok = pcall(function() if type(LoadAsset) == "function" then r = LoadAsset(abpPath) end end)
        probe.line("VALUE LoadAsset(ABP_ChickenPal) -> ok=%s returned=%s", tostring(ok), probe.describe(r))
        if probe.valid(r) then abp = r else abp = probe.find(abpPath) end
    end
    if abp then
        probe.line("VALUE abp class-of -> %s", probe.className(abp))
    else
        probe.note("ABP_ChickenPal is not loaded and LoadAsset did not bring it in; an animClass "
            .. "path in a Mesh spec would hit skeletal.lua's 'cannot resolve animClass' warn")
    end

    probe.section("ABP classes that ARE loaded (a sample of real animClass paths)")
    local abps = probe.allOf("AnimBlueprintGeneratedClass")
    local shown = 0
    for _, a in ipairs(abps) do
        if shown >= 12 then break end
        if probe.valid(a) then shown = shown + 1; probe.line("VALUE ABP %s", probe.full(a)) end
    end
    if shown == 0 then probe.line("VALUE ABP <none loaded>") end

    probe.section("EAnimationMode, so the assumed 0 stops being an assumption")
    local e = probe.find("/Script/Engine.EAnimationMode")
    if e then
        local any = false
        pcall(function()
            e:ForEachName(function(nm, val)
                any = true
                local s2; pcall(function() s2 = nm.ToString and nm:ToString() or tostring(nm) end)
                probe.line("VALUE EAnimationMode %s = %s", tostring(s2), tostring(val))
            end)
        end)
        if not any then
            for i = 0, 4 do
                local nm
                local ok = pcall(function() nm = e:GetNameByValue(i) end)
                if ok and nm ~= nil then
                    local s2; pcall(function() s2 = nm.ToString and nm:ToString() or tostring(nm) end)
                    probe.line("VALUE EAnimationMode[%d] -> %s", i, tostring(s2))
                    any = true
                end
            end
        end
        if not any then probe.line("VALUE EAnimationMode -> found, but neither ForEachName nor GetNameByValue answered") end
    end

    probe.note("READ THIS AS: a PARAM line for SetAnimClass names its ONE parameter — if its "
        .. "class prints as ClassProperty the StaticFindObject/LoadAsset result above can be "
        .. "passed straight in; if it is a SoftClassProperty or an ObjectProperty of a "
        .. "different type, skeletal.lua's mc:SetAnimClass(anim) is passing the wrong thing "
        .. "and animClass silently does nothing. 'function absent' closes the item the other "
        .. "way: drop animClass from Mesh.Spec's skeletal path and let the pawn keep its ABP.")
    probe.note("Whichever EAnimationMode entry reads AnimationBlueprint is the integer "
        .. "SetAnimationMode wants; skeletal.lua hardcodes 0. THIS PROBE DOES NOT CALL "
        .. "SetAnimationMode / SetAnimClass — it is read-only. To finish the item, run the "
        .. "write half by hand on a throwaway pal: Pal.get(\"ChickenPal\"):spawn(...) then "
        .. "Mesh{ model=SK_..., animClass=ABP_... }:attachTo(that actor), and watch whether "
        .. "the swapped model moves or T-poses.")
    probe.finish()
end

--=============================================================================
-- mesh-material-params
--=============================================================================

---Dump one material: its class, its parent, then its three parameter arrays. Names found
---are added to `harvest`. A material already dumped this run prints one line and stops —
---a pal wears the same MI on several slots and printing it eight times helps nobody.
local function dumpMaterial(mat, label, harvest, seen)
    if not probe.valid(mat) then probe.line("SLOT %s -> absent", label); return end
    local key = probe.full(mat)
    if seen and seen[key] then probe.line("SLOT %s -> %s (already dumped)", label, key); return end
    if seen then seen[key] = true end
    probe.line("SLOT %s -> %s class=%s", label, key, probe.className(mat))
    probe.read(mat, "Parent")   -- an instance with empty arrays keeps its names on the parent
    for _, arrName in ipairs({ "VectorParameterValues", "ScalarParameterValues", "TextureParameterValues" }) do
        local arr
        local ok = pcall(function() arr = mat[arrName] end)
        if not ok or arr == nil then
            probe.line("PARAM %s.%s -> absent", label, arrName)
        else
            local n, seen = eachEntry(arr, 32, function(i, entry)
                local nm
                pcall(function() nm = entry.ParameterInfo.Name:ToString() end)
                if nm == nil then pcall(function() nm = tostring(entry.ParameterInfo.Name) end) end
                local val
                pcall(function() val = entry.ParameterValue end)
                probe.line("PARAM %s.%s[%d] %s = %s", label, arrName, i, tostring(nm), shortValue(val))
                if type(nm) == "string" and #nm > 0 then harvest[nm] = arrName end
            end)
            probe.line("PARAM %s.%s -> count=%s read=%d", label, arrName, tostring(n), seen)
        end
    end
end

local function mesh_material_params()
    probe.begin("mesh-material-params",
        "the parameter names a REAL Palworld material carries, versus the six PalForge guesses")

    local s = acquire()
    local harvest, seenMat = {}, {}
    local dumpedClass = false

    ---One component: slot count, each slot's material, and the first material's class props.
    local function fromComponent(comp, label)
        if not probe.valid(comp) then probe.line("CLASS %s component -> absent", label); return end
        probe.section(label .. " : " .. probe.className(comp))
        local n = probe.callGet(comp, "GetNumMaterials")
        n = tonumber(n) or 0
        if n == 0 then
            probe.line("SLOT %s -> GetNumMaterials answered 0 or nothing", label)
        end
        for i = 0, math.min(n, 8) - 1 do
            local mat
            local ok = pcall(function() mat = comp:GetMaterial(i) end)
            if not ok then
                probe.line("SLOT %s[%d] -> GetMaterial raised", label, i)
            else
                dumpMaterial(mat, string.format("%s[%d]", label, i), harvest, seenMat)
                if not dumpedClass and probe.valid(mat) then
                    dumpedClass = true
                    local mcls; pcall(function() mcls = mat:GetClass() end)
                    probe.properties(mcls, "material class " .. probe.className(mat))
                end
            end
        end
    end

    -- the skeletal half: the pal's own body, the component every :setColor on a pal reaches
    if s and s.comp then
        fromComponent(s.comp, "pal mesh")
    else
        probe.line("CLASS pal mesh component -> absent (see the setter section)")
    end

    -- the static half: a placed structure, which is what Building.Instance:update() paints
    probe.section("a placed structure, for the static kind")
    local build = probe.allOf("PalBuildObject")
    local target
    for _, a in ipairs(build) do if probe.valid(a) then target = a; break end end
    if target then
        probe.line("VALUE PalBuildObject -> %s class=%s", probe.full(target), probe.className(target))
        local bc = probe.read(target, "Mesh")
        if not probe.valid(bc) then bc = probe.callGet(target, "GetMesh") end
        if not probe.valid(bc) then
            local sm; pcall(function() sm = FindFirstOf("StaticMeshComponent") end)
            if probe.valid(sm) then
                probe.line("VALUE falling back to the first live StaticMeshComponent -> %s", probe.full(sm))
                bc = sm
            end
        end
        fromComponent(bc, "build mesh")
    else
        probe.line("VALUE PalBuildObject -> none placed; stand near a workbench or a palbox and re-run")
    end

    -- the verdict the item actually turns on
    probe.section("harvested names vs what PalForge writes")
    local names = {}
    for nm in pairs(harvest) do names[#names + 1] = nm end
    table.sort(names)
    probe.line("VALUE harvested=%d parameter name(s)", #names)
    for i, nm in ipairs(names) do
        if i > probe.LIST_LIMIT then probe.line("VALUE ... (%d more)", #names - probe.LIST_LIMIT); break end
        probe.line("VALUE param %s (in %s)", nm, harvest[nm])
    end
    for _, kind in ipairs({ "color", "emissive", "texture" }) do
        for _, guess in ipairs(CANDIDATES[kind] or {}) do
            local where = harvest[guess]
            probe.line("VALUE guess[%s] %s -> %s", kind, guess,
                where and ("HIT (in " .. where .. ")") or "miss")
        end
    end

    probe.note("READ THIS AS: every HIT is a name a real material carries, so a tint written to "
        .. "it can be seen; a wall of 'miss' with a non-empty harvest list means "
        .. "core/mesh/base/renderer.lua's COLOR_PARAMS / TEXTURE_PARAMS should be REPLACED by "
        .. "the harvested names above. An empty harvest with valid materials means the "
        .. "parameter arrays are empty on an instance and the names live on the parent "
        .. "UMaterial — follow the material class PROP listing to Parent and re-run against it.")
    probe.note("THIS PROBE DOES NOT PAINT: CreateAndSetMaterialInstanceDynamic replaces the "
        .. "material on a live actor, which is a state change. Once a name is known, confirm "
        .. "it visibly by hand on a throwaway spawn: Mesh{ model=..., color={r=1,g=0,b=0,a=1} } "
        .. "or handle:setColor{...} on a pal you do not mind recolouring, then reload.")
    probe.finish()
end

--=============================================================================
-- Run every section. Returns the number that ran.
--=============================================================================

function M.run()
    if not support.player() then
        probe.line("NOTE probes/pal needs a loaded world with a live pal near the player: "
            .. "load a save, spawn or whistle out a pal so it stands in front of you, then run "
            .. "this probe again. Nothing ran.")
        return 0
    end
    support.announce("probe: pal mesh / anim / material -> UE4SS.log")

    local sections = {
        mesh_skeletal_setter,
        mesh_skeletal_animclass,
        mesh_material_params,
    }
    local ran = 0
    for _, fn in ipairs(sections) do
        local ok, err = pcall(fn)
        if ok then
            ran = ran + 1
        else
            probe.line("NOTE section raised: %s", tostring(err))
            probe.finish()   -- close the block the section left open
        end
    end
    support.announce("probe: pal done (" .. ran .. " section(s))")
    return ran
end

return M
