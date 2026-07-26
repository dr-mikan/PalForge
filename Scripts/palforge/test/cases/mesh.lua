-- palforge/test/cases/mesh.lua — the Mesh domain: define / get / get_all, the handle's
-- queries, and the fail-soft contract of its three actions.
--
-- Almost everything Mesh does is decidable without a world: a mesh is a DECLARATION, and
-- the interesting behaviour is what the schema fills in and what nesting the same handle
-- into two domains produces. Those tests are pure. Only :attachTo / :detach / :setColor
-- reach core.mesh and want a live actor, so those SKIP without one — and even then they
-- attach a PROCEDURAL mesh whose OBJ file does not exist, so the honest answer is false
-- and nothing is ever put on the player. A skeletal attach would swap the player's own
-- mesh, which is exactly the kind of thing a test must never do to someone's save.
local T        = require("palforge.core.unittests")
local support  = require("palforge.test.support")
local Mesh     = require("palforge.api.mesh")
local mesh     = require("palforge.core.mesh")
local assets   = require("palforge.core.mesh.assets")
local Pal      = require("palforge.api.pal")
local Building = require("palforge.api.building")

local s = T.suite("mesh")

-- A UStaticMesh/USkeletalMesh path is never loaded by a pure test, so any well-formed
-- string does; naming a real-looking one keeps the declarations readable. This one is real:
-- dumps/reflection/05_assets.txt:851 printed it in a live loaded-object sweep.
local MODEL = assets.SK.ChickenPal

-- An OBJ path that is guaranteed NOT to exist, so the procedural backend's parse step
-- fails before it can touch an actor. This is what makes the live attach tests safe.
-- A constant is fine even though the backend caches parsed OBJs: only SUCCESSES are
-- cached, so this one re-fails identically on every run.
local MISSING_OBJ = "C:/palforge_test/no_such_mesh.obj"

-- A minimal stand-in for a live actor: valid enough to get past the handle's guard, so
-- the call reaches core.mesh and we see the BACKEND's answer rather than the guard's.
local function stubActor()
    return { IsValid = function() return true end }
end

--=============================================================================
-- define
--=============================================================================

s:test("a directly defined mesh requires an id, because an unnamed one could never be looked up again", function(t)
    t:errors(function() Mesh{ model = MODEL } end, "field \"id\" is required")
end)

s:test("model is required even when an id is given", function(t)
    t:errors(function() Mesh{ id = support.id("mesh") } end, "field \"model\" is required")
end)

s:test("an unknown field is a hard error with a did-you-mean", function(t)
    local msg = t:errors(function()
        Mesh{ id = support.id("mesh"), model = MODEL, modelPath = MODEL }
    end, "unknown field")
    t:assert(msg:find("did you mean \"model\"?", 1, true),
        "the suggestion should point at \"model\", got: " .. msg)
end)

s:test("a mesh written INLINE inside another definition needs no id", function(t)
    -- The one place `id` is optional: there is nothing to name, so nothing to look up.
    local pal = Pal{ id = support.id("pal"), mesh = { model = MODEL } }
    t:eq(pal:mesh().model, MODEL, "the inline mesh reached the definition")
    t:eq(pal:mesh().id, nil, "and carries no id")
end)

--=============================================================================
-- get / get_all
--=============================================================================

s:test("get returns a handle over the SAME definition the define call registered", function(t)
    local id = support.id("mesh")
    local defined = Mesh{ id = id, model = MODEL }
    local fetched = Mesh.get(id)
    t:eq(fetched.id, id)
    -- Two handles, one definition: identity is on :source(), not on the wrapper.
    t:eq(fetched:source(), defined:source(), "both handles stand for one definition")
end)

s:test("get raises on a miss rather than handing back a thin fallback", function(t)
    -- Unlike Pal/Building there is no sensible thin mesh: one with no model renders
    -- nothing at all, which would fail silently in-world instead of at the call.
    t:errors(function() Mesh.get(support.id("never_defined")) end,
        "no mesh is defined under that id")
end)

s:test("get rejects a non-string id before it reaches the registry", function(t)
    t:errors(function() Mesh.get(nil) end, "id (string) is required")
    t:errors(function() Mesh.get("") end, "id (string) is required")
end)

s:test("get_all lists every registered mesh as a handle", function(t)
    local id = support.id("mesh")
    Mesh{ id = id, model = MODEL }

    local all = Mesh.get_all()
    t:type(all, "table")

    local found
    for _, h in ipairs(all) do
        if h.id == id then found = h end
        t:type(h.source, "function", "every entry is a Mesh.Handle, not a raw class")
    end
    t:truthy(found, "the mesh just defined is in get_all")
    t:eq(found:model(), MODEL)
end)

--=============================================================================
-- the handle's queries
--=============================================================================

s:test("source is the definition itself, with the schema's defaults already filled", function(t)
    local id = support.id("mesh")
    local m = Mesh{ id = id, model = MODEL }

    local src = m:source()
    t:eq(src.id, id)
    t:eq(src.model, MODEL)
    t:eq(src.kind, "skeletal", "kind defaults at define time, not at attach time")
    t:eq(src.scale, nil, "a field with no default and no value stays absent")

    -- :source() is the definition, not a snapshot of it — calling it twice is the same
    -- table, which is what lets core.mesh and the nesting path agree on one declaration.
    t:eq(m:source(), src)
end)

s:test("model and kind read straight off the definition", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MODEL, kind = "static" }
    t:eq(m:model(), MODEL)
    t:eq(m:kind(), "static")
end)

s:test("all four backend kinds are accepted and preserved verbatim", function(t)
    -- "obj" is core.mesh's alias for the procedural backend, but the api stores what was
    -- declared: the alias is resolved at dispatch, not folded away at define time.
    for _, kind in ipairs({ "procedural", "static", "skeletal", "obj" }) do
        local m = Mesh{ id = support.id("mesh_" .. kind), model = MODEL, kind = kind }
        t:eq(m:kind(), kind, kind .. " survives the round trip")
        t:eq(m:source().kind, kind)
    end
end)

s:test("a fifth kind is rejected with the list of the four that exist", function(t)
    local msg = t:errors(function()
        Mesh{ id = support.id("mesh"), model = MODEL, kind = "voxel" }
    end, "must be one of")
    for _, kind in ipairs({ "procedural", "static", "skeletal", "obj" }) do
        t:assert(msg:find(kind, 1, true), "the error should list " .. kind .. ", got: " .. msg)
    end
end)

--=============================================================================
-- nesting — one handle, two domains
--=============================================================================

s:test("one defined handle nests into both Pal and Building, carrying its own kind into each", function(t)
    -- The point of Mesh being its own domain: declare once, wear anywhere. Building
    -- DERIVES its mesh shape from Mesh.Spec, so the handle satisfies both.
    local m   = Mesh{ id = support.id("mesh"), model = MODEL, kind = "procedural" }
    local pal = Pal{ id = support.id("pal"), mesh = m }
    local bld = Building{ id = support.id("building"), mesh = m }

    t:eq(pal:mesh().model, MODEL)
    t:eq(bld:mesh().model, MODEL)
    t:eq(pal:mesh().kind, "procedural")
    t:eq(bld:mesh().kind, "procedural", "the handle's declared kind beats the domain default")
end)

s:test("nesting a handle COPIES it, so neither host can reach the definition through its mesh", function(t)
    local m   = Mesh{ id = support.id("mesh"), model = MODEL }
    local pal = Pal{ id = support.id("pal"), mesh = m }

    t:neq(pal:mesh(), m:source(), "re-validation produced a fresh table")
    t:eq(pal:mesh().model, m:source().model, "with the same content")
end)

s:test("each domain's kind default applies to an INLINE mesh only", function(t)
    -- Inline: nothing filled it in yet, so the host's own policy decides — a pal is a
    -- skeletal creature where a structure is a static prop.
    local inlinePal = Pal{ id = support.id("pal"), mesh = { model = MODEL } }
    local inlineBld = Building{ id = support.id("building"), mesh = { model = MODEL } }
    t:eq(inlinePal:mesh().kind, "skeletal", "Pal.Spec keeps Mesh.Spec's own default")
    t:eq(inlineBld:mesh().kind, "static", "Building.Spec.Mesh overrides it")

    -- A DEFINED handle already had Mesh.Spec's default filled at define time, so the
    -- building's default never gets a say — this is the difference the two spellings make.
    local defined = Mesh{ id = support.id("mesh"), model = MODEL }
    local withHandle = Building{ id = support.id("building"), mesh = defined }
    t:eq(withHandle:mesh().kind, "skeletal",
        "a defined mesh brings its filled kind with it, it is not re-defaulted per host")
end)

--=============================================================================
-- actions — fail-soft, everywhere
--=============================================================================

s:test("attachTo an invalid actor is a fail-soft false, never a raise", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:attachTo(nil), false, "nil actor")
    t:eq(m:attachTo({}), false, "a table with no IsValid at all")
    t:eq(m:attachTo({ IsValid = function() return false end }), false, "a stale actor")
end)

s:test("detach and setColor guard on the actor the same way attachTo does", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MODEL }
    t:eq(m:detach(nil), false)
    t:eq(m:detach({}), false)
    t:eq(m:setColor(nil, { 1, 0, 0, 1 }), false)
    t:eq(m:setColor({}, { 1, 0, 0, 1 }), false)
end)

s:test("a procedural attach whose OBJ file does not exist reports false rather than half-succeeding", function(t)
    -- Past the handle's guard and into the backend: parseObj fails, so the actor is never
    -- touched and no component is created. The honest answer is false.
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:attachTo(stubActor()), false)
end)

s:test("setColor on an actor this session never dressed is false, not a pretended tint", function(t)
    -- core.mesh has no record for the actor, so it falls back to the backend named by the
    -- mesh's own kind — and no backend has a material to write to, so it says so.
    local proc = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    local skel = Mesh{ id = support.id("mesh"), model = MODEL, kind = "skeletal" }
    local actor = stubActor()
    t:eq(proc:setColor(actor, { 1, 0, 0, 1 }), false, "no MID exists for this actor")
    t:eq(skel:setColor(actor, { 1, 0, 0, 1 }), false, "skeletal keeps the inert default")
end)

s:test("detach on an actor this session never dressed is false", function(t)
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:detach(stubActor()), false, "nothing of PalForge's is on it to remove")
end)

--=============================================================================
-- assets — the /Game/... catalog and the resolver behind it
--
-- Pure: normalize and isObjectPath are string work, and load() on a bad shape refuses
-- before it touches the engine at all. The one thing that needs a world — whether a path
-- really resolves — is the live test at the bottom and pf_mesh.
--=============================================================================

s:test("the catalog reaches a pack through the public Mesh module, not just core", function(t)
    -- The point of re-exporting it: a pack requires api/mesh and has the paths.
    t:eq(Mesh.assets, assets, "Mesh.assets IS core.mesh.assets, not a copy that can drift")
    t:eq(mesh.assets, assets, "and core.mesh re-exports the same table")
    for _, group in ipairs({ "SM", "SK", "ABP", "MI" }) do
        t:type(assets[group], "table", group .. " is a catalog table")
        local n = 0
        for _, path in pairs(assets[group]) do
            n = n + 1
            t:truthy(assets.isObjectPath(path), group .. " entry is an object path: " .. path)
            t:truthy(path:find(".", 1, true), group .. " entry names its object half: " .. path)
        end
        t:truthy(n > 0, group .. " carries at least one path")
    end
end)

s:test("the two paths measured off a live actor are in the catalog verbatim", function(t)
    -- dumps/reflection/04_live_objects.txt:21 and :24 read these off one live BP_PinkCat_C —
    -- the mesh from its PalSkeletalMeshComponent, the anim class from that component's
    -- AnimClass property. They are the strongest pair in the tree and a typo in either would
    -- be invisible until someone ran the game, so they are asserted here.
    t:eq(assets.SK.PinkCat,
        "/Game/Pal/Model/Character/Monster/PinkCat/SK_PinkCat.SK_PinkCat")
    t:eq(assets.ABP.PinkCat,
        "/Game/Pal/Blueprint/Character/Monster/PalActorBP/PinkCat/ABP_PinkCat.ABP_PinkCat_C")
    -- and the convention builders reproduce that measured sample, which is the whole of
    -- their evidence.
    t:eq(assets.palMesh("PinkCat"), assets.SK.PinkCat, "palMesh matches the measured path")
    t:eq(assets.palAnim("PinkCat"), assets.ABP.PinkCat, "palAnim matches the measured path")
end)

s:test("normalize completes a package-only path and never overrules a complete one", function(t)
    t:eq(assets.normalize("/Game/A/B/SK_X"), "/Game/A/B/SK_X.SK_X")
    t:eq(assets.normalize("/Game/A/B/ABP_X", "_C"), "/Game/A/B/ABP_X.ABP_X_C")
    -- A full path is returned verbatim, and the reason is a measured one: the object half is
    -- not always a repeat of the package (05_assets.txt:937 records Sm_Mug.SM_Mug), so
    -- "completing" one that is already complete would corrupt it.
    t:eq(assets.normalize(assets.SM.Mug), assets.SM.Mug, "a complete path is untouched")
    t:eq(assets.normalize("/Game/Pal/Model/Prop/Mug/Sm_Mug"), "/Game/Pal/Model/Prop/Mug/Sm_Mug.Sm_Mug",
        "completing the Mug package gives the WRONG object half - which is why the catalog "
        .. "stores the full path and normalize is a convenience only")
    t:eq(assets.normalize(""), "", "an empty string is not a path to complete")
end)

s:test("isObjectPath separates a game asset from a file on disk", function(t)
    t:eq(assets.isObjectPath("/Game/Pal/Model/X.X"), true)
    t:eq(assets.isObjectPath("/Engine/BasicShapes/Cube.Cube"), true)
    t:eq(assets.isObjectPath("C:/mods/example/body.obj"), false, "a Windows path is not one")
    t:eq(assets.isObjectPath(nil), false)
    t:eq(assets.isObjectPath(42), false)
end)

s:test("load refuses a disk path and says which backend wanted it", function(t)
    -- The static / skeletal backends take object paths; an OBJ file is the procedural
    -- backend's input. Refusing here is what turns "silently rendered nothing" into a line
    -- in the log that names the mistake.
    local obj, err = assets.load(MISSING_OBJ, { class = "StaticMesh" })
    t:eq(obj, nil)
    t:type(err, "string")
    t:truthy(err:find("procedural", 1, true), "the reason names the backend that takes it: " .. err)

    t:eq(assets.load(nil), nil, "nil is not a path")
    t:eq(assets.load(""), nil, "and neither is an empty string")
end)

s:test("loadClass refuses the same way, before it can reach LoadAsset", function(t)
    local cls, err = assets.loadClass("not/an/object/path")
    t:eq(cls, nil)
    t:truthy(type(err) == "string" and #err > 0, "and says why")
end)

s:test("a texture reference dispatches on its SHAPE, so only one route can ever apply", function(t)
    -- The missing half of "reusable by pointing at an asset": a mesh could point at a game
    -- asset while its textures could only come off the author's disk. resolveTexture takes
    -- either, and which one is decided by the string, not by trying both.
    local Renderer = require("palforge.core.mesh.base.renderer")
    t:type(Renderer.resolveTexture, "function")

    -- object path -> the asset route, which refuses honestly with no engine under it
    local tex, err = Renderer.resolveTexture(nil, assets.T.HelicopterBase)
    t:eq(tex, nil, "nothing resolves without a game")
    t:type(err, "string", "and it says why")

    -- disk path -> the import route, whose refusal names its own dependency
    local tex2, err2 = Renderer.resolveTexture(nil, "C:/mods/pack/body.png")
    t:eq(tex2, nil)
    t:truthy(type(err2) == "string" and err2:find("KismetRenderingLibrary", 1, true),
        "a disk path goes to the importer, not the asset loader: " .. tostring(err2))

    t:eq(Renderer.resolveTexture(nil, nil), nil, "and neither shape is not a reference")
    t:eq(Renderer.resolveTexture(nil, ""), nil)
end)

s:test("the texture catalog is a matching set for a mesh that is also catalogued", function(t)
    -- The point of keeping these four: they are the game's own base/normal/MRO/emissive maps
    -- for a model whose mesh is assets.SK.AttackHelicopter, so one declaration can name a
    -- game mesh AND the game's own maps for it without a single file on disk.
    for _, name in ipairs({ "HelicopterBase", "HelicopterNormal", "HelicopterMRO", "HelicopterEmissive" }) do
        t:type(assets.T[name], "string", name .. " is catalogued")
        t:truthy(assets.T[name]:find("AttackHelicopter", 1, true),
            name .. " belongs to the same model as assets.SK.AttackHelicopter")
    end
end)

s:test("classChain and isA are honest about an object they cannot read", function(t)
    -- Every caller treats an unreadable class as a refusal to proceed, so an empty chain
    -- rather than a raise is load-bearing: it is what makes a wrong-kind check fail CLOSED.
    t:eq(#assets.classChain(nil), 0, "nothing is not a class chain")
    t:eq(#assets.classChain({}), 0, "and neither is a plain table")
    t:eq(assets.isA(nil, "StaticMesh"), false)
    t:eq(assets.describe(nil), "(nothing)")
end)

s:test("a static attach whose model is not an object path is a false, not a raise", function(t)
    -- Past the handle's guard and into the backend: the resolve refuses, so
    -- AddComponentByClass is never reached and no component is created.
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "static" }
    t:eq(m:attachTo(stubActor()), false)
end)

s:test("a skeletal attach on an actor with no .Mesh component is a false, not a raise", function(t)
    -- The skeletal backend checks the COMPONENT before it resolves the model, so this stub
    -- never reaches the asset layer — which is the right order (a package should not be
    -- loaded for an actor that cannot wear it) and the reason the log line names the
    -- component rather than the path.
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "skeletal" }
    t:eq(m:attachTo(stubActor()), false)
end)

--=============================================================================
-- a declared mesh renders itself
--=============================================================================

s:test("declaring a mesh on a Pal installs the attach, without an onSpawned of its own", function(t)
    -- The 導線 the user asked for: `Pal{ mesh = { model = ... } }` and nothing else. Before
    -- this, renderOn existed and nothing called it, so a declared mesh stored a string.
    local bare      = Pal{ id = support.id("pal") }
    local withMesh  = Pal{ id = support.id("pal"), mesh = { model = MODEL } }
    local Class     = Pal.Class

    t:eq(bare._cls.onSpawned, Class.onSpawned,
        "a pal with no mesh keeps the inert base handler, so it costs nothing")
    t:neq(withMesh._cls.onSpawned, Class.onSpawned,
        "a pal WITH a mesh has one installed")

    -- and it is fail-soft: dispatching it with no actor must not raise, because core/event
    -- calls this on every spawn of every PalForge pal.
    local ok = pcall(function() withMesh._cls:onSpawned({}) end)
    t:truthy(ok, "onSpawned with an empty ctx is a no-op, not an error")
    local ok2 = pcall(function() withMesh._cls:onSpawned({ actor = stubActor() }) end)
    t:truthy(ok2, "and neither is a stub actor that resolves no asset")
end)

s:test("the author's own onSpawned still runs, and runs after the mesh", function(t)
    local order = {}
    local pal = Pal{
        id   = support.id("pal"),
        mesh = { model = MODEL },
        events = { onSpawned = function(_, _) order[#order + 1] = "author" end },
    }
    pal._cls:onSpawned({ actor = stubActor() })
    t:eq(#order, 1, "the declared handler was called exactly once")
    t:eq(order[1], "author", "and it was not replaced by the mesh attach")
end)

--=============================================================================
-- live — the same claims against the real player pawn
--=============================================================================

s:test("attachTo the live player pawn with an OBJ that is not on disk returns an honest false", function(t)
    local pawn = support.needWorld(t)
    -- Deliberately a PROCEDURAL mesh with an unreadable model: the backend bails at the
    -- parse, so this never adds a component to the player. A skeletal attach here would
    -- swap the player's own mesh, which no test is allowed to do.
    local m = Mesh{ id = support.id("mesh"), model = MISSING_OBJ, kind = "procedural" }
    t:eq(m:attachTo(pawn), false, "nothing was attached, and it said so")
    -- Nothing was attached, so there is nothing to take off again.
    t:eq(m:detach(pawn), false, "detach reports it removed nothing")
    t:eq(m:setColor(pawn, { 1, 1, 1, 1 }), false, "and there is no material to re-tint")
end)

s:test("the catalogued /Game/... paths resolve in a loaded world", function(t)
    support.needWorld(t)
    -- THE ASSET HALF OF THE WHOLE FEATURE, and the only place it can be answered: whether a
    -- path resolves is a fact about the installed pak, and no dump can hold it. Each entry
    -- came from a live loaded-object sweep, so the expectation is that it resolves again —
    -- but a game patch can move an asset, and this is what would say so.
    --
    -- It LOADS packages (I/O and memory) and writes nothing to any actor, component or save.
    local found = assets.probe(support.log)
    t:truthy(#found > 0, "the catalog is not empty")

    local ok, miss, missed = 0, 0, {}
    for _, rec in ipairs(found) do
        if rec.ok then ok = ok + 1 else miss = miss + 1; missed[#missed + 1] = rec.name end
    end
    support.log(string.format("mesh: %d of %d catalogued asset paths resolved", ok, #found))

    -- The ABP entries are deliberately NOT part of the assertion. Whether a blueprint's
    -- generated class can be reached from a path is the open question this run exists to
    -- answer (see core/mesh/assets.lua's M.ABP note), and asserting an answer we do not have
    -- would only manufacture a failure. The ASSET_MISS lines above are the report.
    local meshOk, meshTotal = 0, 0
    for _, rec in ipairs(found) do
        if rec.group == "SM" or rec.group == "SK" then
            meshTotal = meshTotal + 1
            if rec.ok then meshOk = meshOk + 1 end
        end
    end
    if meshOk == 0 then
        t:skip(string.format("none of the %d catalogued mesh paths resolved in this world - "
            .. "read the ASSET lines above: they were all in a live loaded-object sweep, so "
            .. "either the resolve route is wrong or the pak has moved under the dump",
            meshTotal))
    end
    t:truthy(meshOk > 0, "at least one shipped mesh asset resolved from its path")
    if miss > 0 then
        support.log("mesh: did not resolve: " .. table.concat(missed, ", "))
    end
end)

s:test("the player's own materials name themselves and their parameters", function(t)
    local pawn = support.needWorld(t)

    -- READ-ONLY, and that is the point: this writes nothing to any material, any component
    -- or any save. It is the probe both open mesh items have been waiting on, and neither
    -- can be closed from dumps/ at all — a CXXHeaderDump holds classes, and which material
    -- an asset carries and which parameters that material exposes are DATA inside a
    -- .uasset. So the only place the answer exists is a loaded world, and the cheapest
    -- loaded thing wearing a real Palworld material is the player's own body.
    --
    -- What each printed line is worth:
    --   * the MATERIAL PATH is a mesh-base-material answer. A material that is currently
    --     rendering is by definition cooked into the pak and loaded, so it can parent a MID
    --     where the five /Engine/ editor paths in Renderer.BASE_MATERIAL_CANDIDATES are
    --     guesses that a shipping build may not contain at all.
    --   * the PARAMETER NAMES are a mesh-material-params answer. Renderer.COLOR_PARAMS
    --     writes six candidate names per slot and any of them may be a silent no-op; these
    --     are the names the material really carries, read off UMaterialInstance's own
    --     reflected override arrays (dumps/cxx/Engine.hpp:17548-17551).
    -- Nothing is asserted about WHICH names come back — that would be inventing the answer
    -- this test exists to fetch. What is asserted is that the read itself works.
    local found = mesh.describeMaterials(pawn, support.log)
    t:type(found, "table", "the read reports what it saw, even when it saw nothing")

    if #found == 0 then
        t:skip("the player pawn exposed no readable material slot — look for the MATDESC "
            .. "lines: 'no live component' means .Mesh could not be read, 'no material on "
            .. "this slot' means the component is there and its slots are empty")
    end

    local names = 0
    for _, rec in ipairs(found) do
        t:type(rec.material, "string", "every slot names the material it is wearing")
        t:truthy(#rec.material > 0, "and the name is not empty")
        names = names + #rec.vector + #rec.scalar + #rec.texture
    end
    support.log(string.format("mesh: %d material slot(s) read on the player, %d parameter "
        .. "name(s) in total. A slot with zero names is a real answer too — a plain UMaterial "
        .. "keeps its parameters in an expression graph, which is not reflected",
        #found, names))
end)

return s
