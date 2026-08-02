-- PalForge core.mesh.assets: turn a PATH a pack wrote into a live UObject, and carry the
-- handful of /Game/... paths that are KNOWN to exist in this build.
--
-- WHY THIS FILE EXISTS. Until now `loadAsset` was a private six-line copy inside both
-- core/mesh/static.lua and core/mesh/skeletal.lua, and it did three things wrong for the
-- one case that matters most — a pack naming an asset the GAME already ships:
--
--   1. It treated the on-disk file as the main case. It is not. A cooked, shipped
--      /Game/... asset needs no importer, no parser and no file the player has to install;
--      it is already in the pak. That is the reusable route, so it is the primary one.
--   2. It accepted any object at all and handed it straight to a typed setter. A
--      USkeletalMesh and a UStaticMesh are SIBLINGS, not relatives —
--      `USkeletalMesh : USkinnedAsset : UStreamableRenderAsset` (dumps/cxx/Engine.hpp:20511,
--      :20802) against `UStaticMesh : UStreamableRenderAsset` (:21631) — so a pack that
--      writes a SM_ path on a Pal (whose mesh kind defaults to "skeletal") used to reach
--      `SetSkinnedAssetAndUpdate(USkinnedAsset*, bool)` with a UStaticMesh in the object
--      slot. A wrong argument TYPE faults inside UE4SS's marshalling where pcall cannot
--      see it; that is the shape that closed the game once. So the class is CHECKED here,
--      before the argument is ever marshalled, and a mismatch is an English error naming
--      the kind the author should have declared.
--   3. It could not resolve an animation blueprint at all — see LOAD vs LOOK UP below,
--      which is very probably why `dumps/reflection/05_assets.txt:803` reports
--      `AnimBlueprint classes : 0 loaded` while dumps/cxx plainly ships ABP_Player.hpp.
--
-- LOAD vs LOOK UP — one route, two steps, and they are not the same step.
--   LoadAsset(path)          brings a PACKAGE into memory. It is I/O. UE4SS does not
--                            return the object on every build (same note as
--                            core/sound/native.lua:53, where this order is already proven
--                            against the AkAudioEvent assets).
--   StaticFindObject(path)   names one object that is ALREADY in memory. It is a lookup and
--                            it never loads anything.
-- For a mesh the two strings coincide: the package `SK_PinkCat` contains an object
-- `SK_PinkCat`, so `/Game/.../SK_PinkCat.SK_PinkCat` is both. For a blueprint they do NOT:
-- the package `ABP_PinkCat` contains the asset `ABP_PinkCat` (a UAnimBlueprint) AND the
-- generated class `ABP_PinkCat_C`, and it is the _C object that SetAnimClass wants
-- (`UAnimBlueprintGeneratedClass : UBlueprintGeneratedClass : UClass`, Engine.hpp:10073).
-- So loadClass() loads the ASSET path and then looks up the _C OBJECT path. That is not a
-- fallback chain — neither step can do the other's job.
--
-- PATH SHAPE. A UE object path is `<package>.<object>`. Every path measured off this build
-- carries the tail, so `normalize` appends it when a caller wrote only the package:
-- `/Game/A/SK_X` -> `/Game/A/SK_X.SK_X`. It is a CONVENIENCE and the full form always wins,
-- because the tail is not always a repeat of the package name — `dumps/reflection/
-- 05_assets.txt:937` records `/Game/Pal/Model/Prop/Mug/Sm_Mug.SM_Mug`, whose package and
-- object differ in case.
--
-- WHERE THE CATALOG BELOW COMES FROM, and why each entry is not a guess:
--   * `dumps/reflection/05_assets.txt` is a sweep of LOADED UObjects taken in a live
--     session. An entry there was in memory when it was printed, so the path resolves by
--     construction — it is the strongest evidence short of loading it again.
--   * `dumps/reflection/04_live_objects.txt` read the mesh and anim-class properties off
--     live actors, which is where the pal <-> ABP pairing comes from.
-- Anything derived from a naming CONVENTION rather than measured is behind palMesh() /
-- palAnim(), which say so in their own docs. Nothing invented sits in the tables.
--
-- WHERE THE IDENTITY AND STRING HELPERS WENT. `live`, `classChain`, `isA`, `describe`,
-- `isObjectPath` and `normalize` were all implemented HERE, and three of them were also
-- implemented, differently, in core/sound/native.lua and core/icons.lua. That divergence had
-- a live consequence in each direction: the sound loader shipped without the class check
-- this file's header argues for, and this file's own `loadClass` parsed a path by a rule
-- `normalize` did not use. So the bodies now live in core/uobject.lua (objects) and
-- core/assetpath.lua (strings) and the six names below are THIN DELEGATIONS kept because
-- public callers spell them `Mesh.assets.<name>` — api/mesh re-exports this whole table, and
-- test/cases/mesh.lua asserts on four of them.

local uo       = require("palforge.core.uobject")
local assetpath = require("palforge.core.assetpath")

local M = {}

--=============================================================================
-- object identity — delegations to core.uobject (see the header)
--=============================================================================

-- Is `o` a live UObject? Every IsValid in this file goes through here: a stale handle can
-- raise on the call itself and no caller may let that escape. core.uobject.live is that
-- implementation now, and it carries the measurement that IsValid on this UE4SS is a real
-- liveness check rather than a null check.
local live = uo.live
M.live = live

---An object's class chain as short class names, leaf first — for a USkeletalMesh:
---{ "SkeletalMesh", "SkinnedAsset", "StreamableRenderAsset", "Object" }.
---@param obj any
---@return string[]
function M.classChain(obj) return uo.classChain(obj) end

---Is `obj` an instance of `className` (or of anything deriving from it)? `className` is the
---SHORT UE name with no U/A prefix: "StaticMesh", "SkinnedAsset", "AnimBlueprintGeneratedClass".
---
---A false here is only ever "the chain we could read does not contain it" — an object whose
---class will not answer returns an empty chain and therefore false, which is why callers
---treat it as a refusal to proceed rather than as proof of the wrong type.
---@param obj any
---@param className string
---@return boolean
function M.isA(obj, className) return uo.isA(obj, className) end

---A one-line description of a live object for a log: "SkeletalMesh /Game/.../SK_PinkCat.SK_PinkCat".
---@param obj any
---@return string
function M.describe(obj) return uo.describe(obj) end

--=============================================================================
-- paths — delegations to core.assetpath (see the header)
--=============================================================================

---Is `path` a UE OBJECT path rather than a file on disk? Object paths are rooted at a mount
---point and always begin with "/" — "/Game/...", "/Engine/...", "/Script/...". A Windows OBJ
---path ("C:/mods/x.obj") never does, which is what lets one `model` field carry both and
---lets a backend say which one it was handed.
---@param path any
---@return boolean
function M.isObjectPath(path) return assetpath.isObjectPath(path) end

---Complete a package-only path to a full `<package>.<object>` object path, and leave an
---already-complete one alone. `/Game/A/SK_X` -> `/Game/A/SK_X.SK_X`.
---
---`suffix` (optional) is appended to the object half — pass "_C" for a blueprint generated
---class, so `/Game/A/ABP_X` -> `/Game/A/ABP_X.ABP_X_C`.
---
---Only the LAST segment is inspected, so a directory containing a dot cannot confuse it, and
---a path that already carries an object half is returned verbatim: the tail is not always a
---repeat of the package name (see the header's Sm_Mug case) and a caller who wrote the full
---form has said something this function must not overrule.
---@param path string
---@param suffix string?
---@return string
function M.normalize(path, suffix) return assetpath.normalize(path, suffix) end

--=============================================================================
-- resolve
--=============================================================================

-- Successfully resolved objects, by the EXACT string that resolved them. Only successes are
-- cached: a miss is usually "the package has not streamed in yet", and caching that would
-- keep a mesh unresolvable for the rest of the session.
--
-- WEAK VALUES, and the reason is NOT the one this comment used to give ("so an asset the
-- engine unloads does not stay pinned by this table alone"). Nothing PalForge holds has ever
-- pinned a UObject: there is no AddToRoot and no FGCObject anywhere in UE4SS's Lua layer, so
-- a strong reference here would not have kept an asset alive and a weak one does not let it
-- die any sooner. What __mode = "v" actually buys is that the ENTRY can evaporate for
-- unrelated reasons, which is harmless precisely because every hit is re-checked with
-- live() below and a vanished entry simply resolves again.
local cache = setmetatable({}, { __mode = "v" })

---Resolve `path` to a live UObject, LOADING it if it is not in memory yet.
---
---`opts.class` — the short class name the caller needs ("StaticMesh", "SkinnedAsset", ...).
---When given and the resolved object is not one, this returns nil plus a message naming what
---it actually got. That check is the whole reason a wrong `kind` on a declaration is now an
---English error instead of a native fault in UE4SS's argument marshalling.
---`opts.suffix` — passed to normalize (see loadClass).
---
---Returns obj, or nil + reason. Never raises.
---@param path string
---@param opts table?
---@return any obj, string? err
function M.load(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or #path == 0 then return nil, "no asset path" end
    if not M.isObjectPath(path) then
        return nil, string.format("%q is not a /Game/... object path (a file on disk is the "
            .. "procedural backend's input, not this one's)", path)
    end
    local full = M.normalize(path, opts.suffix)

    local hit = cache[full]
    if live(hit) then
        if opts.class and not M.isA(hit, opts.class) then
            return nil, string.format("%s is a %s, not a %s", full,
                (M.classChain(hit))[1] or "?", opts.class)
        end
        return hit
    end
    cache[full] = nil

    -- STEP 1 — LOAD. Brings the package in. On builds where UE4SS returns the object this is
    -- also the answer; where it does not, it is still what makes step 2 able to find anything.
    local obj
    pcall(function() if type(LoadAsset) == "function" then obj = LoadAsset(full) end end)
    -- STEP 2 — LOOK UP. Names the object inside the package now in memory. Also the whole of
    -- the resolve when the asset was already loaded (which is the common case for anything
    -- the world is currently rendering).
    if not live(obj) then obj = nil; pcall(function() obj = StaticFindObject(full) end) end
    if not live(obj) then
        -- FOUR SITUATIONS PRODUCE THIS AND ONLY TWO OF THEM CAN BE TOLD APART FROM INSIDE
        -- THE PROCESS. Saying so is the point: the single sentence this used to return
        -- ("check the tail") sent an author looking for a typo when the likeliest cause was
        -- that the package had not streamed in.
        --   1. There is no LoadAsset at all — a headless run, or a UE4SS that does not
        --      expose it. Distinguishable, and it is not the author's mistake.
        --   2. The PACKAGE is in memory but carries no object under the tail we asked for.
        --      Distinguishable, and it IS a tail typo — the case where naming the
        --      <package>.<object> shape is the right advice, because the two halves are not
        --      always the same word (/Game/Pal/Model/Prop/Mug/Sm_Mug.SM_Mug).
        --   3/4. Nothing of that name is in memory and LoadAsset did not bring one in. The
        --      path may be wrong, the asset may not be cooked into this build, or its
        --      package may simply not have streamed in yet — and NOTHING readable from here
        --      separates those three. The message says that rather than picking one.
        if type(LoadAsset) ~= "function" then
            return nil, string.format("%s did not resolve: this environment has no LoadAsset "
                .. "(a headless run, or a UE4SS build that does not expose it), so nothing "
                .. "could be brought into memory to look up", full)
        end
        local pkgPath = assetpath.packageOf(full)
        if pkgPath ~= full then
            local pkg; pcall(function() pkg = StaticFindObject(pkgPath) end)
            if live(pkg) then
                return nil, string.format("%s did not resolve, but its package %s IS in "
                    .. "memory - so the <package>.<object> tail is wrong rather than the "
                    .. "path (the two halves are not always the same word: "
                    .. "/Game/Pal/Model/Prop/Mug/Sm_Mug.SM_Mug)", full, pkgPath)
            end
        end
        return nil, string.format("%s did not resolve: LoadAsset ran and StaticFindObject "
            .. "found nothing under that name, and its package is not in memory either. "
            .. "Three causes are indistinguishable from here - the path is wrong, the asset "
            .. "is not cooked into this build, or it has not streamed in yet. A path that "
            .. "resolved earlier in the session and not now is the streaming case; "
            .. "Mesh.assets carries paths measured off this build to compare against", full)
    end

    if opts.class and not M.isA(obj, opts.class) then
        local chain = M.classChain(obj)
        return nil, string.format("%s is a %s, not a %s", full, chain[1] or "?", opts.class)
    end
    cache[full] = obj
    return obj
end

---Resolve a BLUEPRINT GENERATED CLASS — the `_C` object SetAnimClass wants.
---
---Two steps for the reason in the header: the generated class lives INSIDE the blueprint's
---package but is not the package's own asset object, so the ASSET path is what gets loaded
---and the `_C` OBJECT path is what gets looked up. Both spellings a pack might write are
---accepted, since normalize only completes a path that has no object half at all:
---
---   "/Game/.../ABP_PinkCat"              -> loads ABP_PinkCat.ABP_PinkCat, finds ABP_PinkCat_C
---   "/Game/.../ABP_PinkCat.ABP_PinkCat_C" -> the same two objects, named explicitly
---
---`opts.class` defaults to "AnimBlueprintGeneratedClass", which is the class name
---dumps/reflection/04_live_objects.txt:15 printed when it read AnimClass off a live pawn.
---Returns cls, or nil + reason.
---
---THE PATH SPLIT IS core.assetpath's NOW, AND THAT FIXED TWO REAL DIVERGENCES. This function
---used to parse a path by rules `normalize` did not share, and both were wrong in a way that
---produced a plausible-looking string rather than an error:
---  * it tested `find(".", 1, true)` over the WHOLE path, so a directory containing a dot
---    ("/Game/My.Pack/ABP_X") was read as already carrying an object half and the class path
---    came out package-only ("/Game/My.Pack/ABP_X_C"), which resolves to nothing;
---  * it ran `gsub("_C$", "")` over the whole path, so a PACKAGE whose own name legitimately
---    ends in _C ("/Game/A/Thing_C") had its asset path mangled to "/Game/A/Thing_C.Thing".
---Only the last segment is inspected now, and the _C is stripped from the OBJECT half only.
---@param path string
---@param opts table?
---@return any cls, string? err
function M.loadClass(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or #path == 0 then return nil, "no class path" end
    if not M.isObjectPath(path) then
        return nil, string.format("%q is not a /Game/... object path", path)
    end
    -- Both spellings a pack might write reach the same two strings:
    --   "/Game/.../ABP_X"                -> asset "/Game/.../ABP_X.ABP_X",  class "…ABP_X_C"
    --   "/Game/.../ABP_X.ABP_X_C"        -> the same pair, named explicitly
    local asset, classPath
    local objHalf = assetpath.objectOf(path)
    if objHalf then
        local pkg  = assetpath.packageOf(path)
        local bare = objHalf:gsub("_C$", "")
        asset      = pkg .. "." .. bare
        classPath  = pkg .. "." .. bare .. "_C"
    else
        asset     = assetpath.normalize(path)
        classPath = assetpath.normalize(path, "_C")
    end
    -- The ASSET path is what gets LOADED: loading it is what puts the generated class in
    -- memory, and there is nothing else that will.
    pcall(function() if type(LoadAsset) == "function" then LoadAsset(asset) end end)

    local cls
    pcall(function() cls = StaticFindObject(classPath) end)
    if not live(cls) then
        return nil, string.format("%s did not resolve (LoadAsset(%s) ran, and no _C class "
            .. "object of that name is in memory afterwards)", classPath, asset)
    end
    local want = opts.class or "AnimBlueprintGeneratedClass"
    if want ~= false and not M.isA(cls, want) then
        return nil, string.format("%s is a %s, not a %s", classPath,
            (M.classChain(cls))[1] or "?", want)
    end
    return cls
end

--=============================================================================
-- KNOWN-GOOD PATHS — every one of these was observed in this build
--=============================================================================

-- UStaticMesh — for `kind = "static"`, which is what a Building's mesh defaults to.
-- Provenance: each was printed by the live loaded-object sweep in
-- dumps/reflection/05_assets.txt (`== StaticMesh : 1928 loaded ==`, line 856 onward), so it
-- was resident in memory when the sweep ran. ChestWood has a second, independent
-- confirmation: dumps/reflection/04_live_objects.txt:6 read it off the StaticMeshComponent of
-- a live BP_BuildObject_ItemChest_C, i.e. the game itself was rendering that exact path.
--
-- The three /Engine/ shapes at the end are the useful ones for a first test, because they are
-- geometry with no story attached — and unlike the /Engine/ MATERIAL paths in
-- base/renderer.lua's BASE_MATERIAL_CANDIDATES (which are guesses about what a shipping build
-- keeps), these three were in the same live sweep and are therefore present.
M.SM = {
    ChestWood   = "/Game/Pal/Model/Prop/Architecture/ChestWood/SM_ChestWood.SM_ChestWood",
    WorkBench   = "/Game/Pal/Model/Prop/Architecture/WorkBenchPrimitive/SM_WorkBenchPrimitive.SM_WorkBenchPrimitive",
    Bed         = "/Game/Pal/Model/Prop/Architecture/BedPrimitive/SM_BedPrimitive.SM_BedPrimitive",
    PalBed      = "/Game/Pal/Model/Prop/Architecture/PalBedPrimitive/SM_PalBedPrimitive.SM_PalBedPrimitive",
    TorchStand  = "/Game/Pal/Model/Prop/Architecture/TorchStand/SM_TorchStand.SM_TorchStand",
    PalBox      = "/Game/Pal/Model/Other/PalBox/SM_PalBox.SM_PalBox",
    PalsNest    = "/Game/Pal/Model/Other/PalsNest/SM_PalsNest.SM_PalsNest",
    SupplyPod   = "/Game/Pal/Model/Other/SupplyPod/SM_SupplyPod.SM_SupplyPod",
    Meteor      = "/Game/Pal/Model/Other/Meteor/SM_Meteor.SM_Meteor",
    Bread       = "/Game/Pal/Model/Prop/Bread/SM_Bread.SM_Bread",
    -- package `Sm_Mug`, object `SM_Mug` — the one measured path in the tree whose two halves
    -- differ, and the reason normalize() never overrules a full path.
    Mug         = "/Game/Pal/Model/Prop/Mug/Sm_Mug.SM_Mug",
    RockCoal    = "/Game/Pal/Model/Prop/Resource/Rock/SM_RockCoal.SM_RockCoal",
    Cube        = "/Engine/BasicShapes/Cube.Cube",
    Cylinder    = "/Engine/BasicShapes/Cylinder.Cylinder",
    Sphere      = "/Engine/EngineMeshes/Sphere.Sphere",
}

-- USkeletalMesh — for `kind = "skeletal"`, which is what a Pal's mesh defaults to.
-- Provenance: dumps/reflection/05_assets.txt:805-854, the full `== SkeletalMesh : 49 loaded ==`
-- block. PinkCat has the same second confirmation as ChestWood above — 04_live_objects.txt:24
-- read it off a live BP_PinkCat_C's PalSkeletalMeshComponent — which is what makes PinkCat the
-- one entry here whose mesh AND animation blueprint are both measured on the same actor.
M.SK = {
    PinkCat     = "/Game/Pal/Model/Character/Monster/PinkCat/SK_PinkCat.SK_PinkCat",
    ChickenPal  = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal",
    SheepBall   = "/Game/Pal/Model/Character/Monster/SheepBall/SK_SheepBall.SK_SheepBall",
    LegendDeer  = "/Game/Pal/Model/Character/Monster/LegendDeer/SK_LegendDeer.SK_LegendDeer",
    YakushimaBoss002 = "/Game/Pal/Model/Character/Monster/YakushimaBoss002/SK_YakushimaBoss002.SK_YakushimaBoss002",
    PalEgg      = "/Game/Pal/Model/Other/PalEgg/SK_PalEgg.SK_PalEgg",
    TreasureBoxL = "/Game/Pal/Model/Other/TreasureBoxL/SK_TreasureBoxL.SK_TreasureBoxL",
    Terminal    = "/Game/Pal/Model/Other/Terminal/SK_Terminal.SK_Terminal",
    AttackHelicopter = "/Game/Pal/Model/Other/AttackHelicopter/SK_AttackHelicopter.SK_AttackHelicopter",
    PlayerFemaleHead = "/Game/Pal/Model/Character/Player/Head/Head001/SK_Player_Female_Head001.SK_Player_Female_Head001",
}

-- AnimBlueprintGeneratedClass paths — `animClass`, skeletal only.
--
-- BOTH of these were read as OBJECT PROPERTIES off live pawns, which is as strong as evidence
-- gets short of setting one: dumps/reflection/04_live_objects.txt:15 (the player) and :21
-- (a wild PinkCat) print `animClass = AnimBlueprintGeneratedClass <path>` because dump.lua:169
-- read `Mesh.AnimClass` and asked the object for its own full name. So the path, the class
-- name and the pairing with the mesh above all come from the same read.
--
-- STILL UNOBSERVED: nobody has RESOLVED one from a path. The live asset sweep found zero
-- AnimBlueprint classes loaded (05_assets.txt:803) even in a session where ABP_PinkCat_C was
-- demonstrably driving a pawn — the sweep looks for objects by class and those were there, so
-- the likeliest reading is that the sweep's cap or its class filter missed them rather than
-- that they were absent. Either way loadClass() above is what has to be run to find out, and
-- pf_mesh runs it.
M.ABP = {
    PinkCat = "/Game/Pal/Blueprint/Character/Monster/PalActorBP/PinkCat/ABP_PinkCat.ABP_PinkCat_C",
    Player  = "/Game/Pal/Blueprint/Character/Player/ABP_Player.ABP_Player_C",
}

-- UTexture2D paths — for a spec's `texture`, and for `params.texture` against the MEASURED
-- parameter names in base/renderer.lua ("Base Texture", "Normal Map",
-- "MetallicRoughnessOcclusionSpecularTexture"). base/renderer's resolveTexture takes either
-- one of these or a PNG off disk, dispatching on whether the string is an object path.
--
-- Provenance: dumps/reflection/05_assets.txt:2060-2066. That sweep was FILTERED to names
-- matching "icon" and still printed these, which is why the AttackHelicopter set is what is
-- here and not a pal's body maps — the filter kept 420 of 6414 loaded Texture2Ds and the rest
-- of what survived it is UI artwork. The set is worth having anyway because it is COMPLETE
-- and it PAIRS: base colour, normal, metallic-roughness and emissive for the same model,
-- whose skeletal mesh is assets.SK.AttackHelicopter above. One `Mesh{ ... }` can therefore
-- name a game mesh and the game's own four maps for it, entirely from measured paths.
--
-- The suffix convention this build uses, readable straight off those six lines:
--   _B base colour   _N normal   _M metallic/roughness/occlusion   _E emissive
M.T = {
    HelicopterBase     = "/Game/Pal/Model/Other/AttackHelicopter/Material/T_AttackHelicopter_B.T_AttackHelicopter_B",
    HelicopterNormal   = "/Game/Pal/Model/Other/AttackHelicopter/Material/T_AttackHelicopter_N.T_AttackHelicopter_N",
    HelicopterMRO      = "/Game/Pal/Model/Other/AttackHelicopter/Material/T_AttackHelicopter_M.T_AttackHelicopter_M",
    HelicopterEmissive = "/Game/Pal/Model/Other/AttackHelicopter/Material/T_AttackHelicopter_E.T_AttackHelicopter_E",
}

-- Material instances that a mesh spec's `material` field can be parented to. One entry, and
-- it is the same one base/renderer.lua's BASE_MATERIAL_CANDIDATES leads with: read live off
-- BP_Player_Female_C.CharacterMesh0 on 2026-07-26, and it carries the `BaseColor` vector
-- parameter a tint needs. Kept here as well so a pack has one place to look for paths.
M.MI = {
    PlayerOutfitOldCloth =
        "/Game/Pal/Model/Character/Player/Outfit/SK_Player_Female_Outfit_OldCloth001/v01/"
        .. "MI_Player_Female_Outfit_OldCloth001_v01_M01.MI_Player_Female_Outfit_OldCloth001_v01_M01",
}

--=============================================================================
-- convention builders — a path SHAPE, not a measured path
--=============================================================================

---The conventional USkeletalMesh path for a monster: palMesh("ChickenPal") ->
---"/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal".
---
---The SHAPE is measured five times over — every monster entry in the live SkeletalMesh sweep
---(PinkCat, ChickenPal, SheepBall, LegendDeer, YakushimaBoss002) sits at exactly it. The
---specific path this returns for any OTHER name is not, and the same sweep shows the
---exceptions: a pal can own extra meshes on the same folder (SK_QueenBee_spear,
---SK_YakushimaBoss002_Arm_L) whose names this cannot predict. So treat the result as a
---candidate to resolve, not as a fact — M.load answers honestly either way.
---@param name string   # a monster folder name, e.g. "ChickenPal"
---@return string
function M.palMesh(name)
    return string.format("/Game/Pal/Model/Character/Monster/%s/SK_%s.SK_%s", name, name, name)
end

---The conventional AnimBlueprintGeneratedClass path for a monster: palAnim("ChickenPal") ->
---".../PalActorBP/ChickenPal/ABP_ChickenPal.ABP_ChickenPal_C".
---
---WEAKER EVIDENCE THAN palMesh, and the difference is worth stating: exactly ONE sample of
---this shape has ever been measured (ABP_PinkCat, dumps/reflection/04_live_objects.txt:21).
---dumps/cxx ships ABP_LegendDeer.hpp, ABP_MonsterBase.hpp and ABP_RidingBoss.hpp, so more of
---these classes certainly exist, but nothing in the tree records their PACKAGE directories —
---a header dump carries class declarations, not asset paths. One sample is a convention only
---in the sense that a second one would confirm it.
---@param name string
---@return string
function M.palAnim(name)
    return string.format("/Game/Pal/Blueprint/Character/Monster/PalActorBP/%s/ABP_%s.ABP_%s_C",
                         name, name, name)
end

--=============================================================================
-- discovery
--=============================================================================

---Try to resolve every catalogued path and report what came back. READ-ONLY: it loads
---packages (which is I/O and memory, not a world change) and writes nothing to any actor,
---component or save.
---
---`sink` is called as sink(line) per path; without one the results come back as a list of
---{ group, name, path, ok, detail }. This is the discovery half of pf_mesh and the thing to
---run after a game patch: a path that stops resolving says so in one line.
---@param sink fun(line: string)?
---@return table[] results
function M.probe(sink)
    local out = {}
    local function say(line) if sink then pcall(sink, line) end end

    local groups = {
        { "SM",  M.SM,  "StaticMesh" },
        { "SK",  M.SK,  "SkinnedAsset" },
        { "T",   M.T,   "Texture" },
        { "MI",  M.MI,  "MaterialInterface" },
    }
    for _, g in ipairs(groups) do
        local groupName, tbl, class = g[1], g[2], g[3]
        local names = {}
        for name in pairs(tbl) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local path = tbl[name]
            local obj, err = M.load(path, { class = class })
            local rec = { group = groupName, name = name, path = path,
                          ok = obj ~= nil, detail = obj and M.describe(obj) or tostring(err) }
            out[#out + 1] = rec
            say(string.format("ASSET %s %s.%s -> %s", rec.ok and "OK  " or "MISS",
                groupName, name, rec.detail))
        end
    end

    local abpNames = {}
    for name in pairs(M.ABP) do abpNames[#abpNames + 1] = name end
    table.sort(abpNames)
    for _, name in ipairs(abpNames) do
        local path = M.ABP[name]
        local cls, err = M.loadClass(path)
        local rec = { group = "ABP", name = name, path = path,
                      ok = cls ~= nil, detail = cls and M.describe(cls) or tostring(err) }
        out[#out + 1] = rec
        say(string.format("ASSET %s ABP.%s -> %s", rec.ok and "OK  " or "MISS", name, rec.detail))
    end
    return out
end

return M
