-- palforge/test/cases/registry.lua — id resolution and the central object registry.
--
-- This suite pins down the two halves of "what exists": core/object_manager (the id model
-- — resolve / checkOwnership / checkImport / display — plus the typed class registry the
-- api definitions write into) and core/registry.registered(), the kernel's snapshot of
-- that registry. It is entirely PURE: nothing here touches the world, so every test runs
-- and passes at the title screen exactly as it does in a save. The one thing it does
-- assume is that the kernel has already run — the native catalogs are loaded, so the
-- curated ids are registered — which is true by the time any case file runs.
--
-- Every id written here comes from support.id(), and each test un-registers what it
-- registered, so a run leaves the registry exactly as it found it.
local T        = require("palforge.core.unittests")
local support  = require("palforge.test.support")
local om       = require("palforge.core.object_manager")
local registry = require("palforge.core.registry")
local Mesh     = require("palforge.api.mesh")

local s = T.suite("registry")

-- Drop a test class again. register(otype, id, nil) stores nil, which is how the registry
-- spells "forget this" — see the last resolve/register test below, which pins that down.
local function forget(otype, id) om.register(otype, id, nil) end

--=============================================================================
-- resolve — "packid:name" -> the DataTable row FName
--=============================================================================

s:test("a namespaced id becomes the underscore fname the DataTables use", function(t)
    t:eq(om.resolve("example:Bench"), "example_Bench")
    -- support.id() ids are namespaced too, so they survive the same round trip.
    local id = support.id("obj")
    local pack, name = id:match("^([^:]+):(.+)$")
    t:eq(om.resolve(id), pack .. "_" .. name, "a test id resolves like any other")
end)

s:test("a literal game id passes through untouched, and alone", function(t)
    t:eq(om.resolve("Wood"), "Wood")
    t:eq(om.resolve(support.GAME.pal), support.GAME.pal)
    -- Only ONE value on success: a caller writing `local fname, err = resolve(id)` must
    -- not see a stale second return.
    t:eq(select("#", om.resolve("Wood")), 1, "success returns exactly one value")
end)

s:test("an id that is not a non-empty string is rejected with a reason", function(t)
    local fname, err = om.resolve(nil)
    t:eq(fname, nil)
    t:type(err, "string", "the rejection carries a reason")
    t:assert(err:find("non-empty string", 1, true), "the reason says what an id must be")

    t:eq(om.resolve(""), nil, "the empty string is not an id")
    t:eq(om.resolve(42), nil, "a number is not an id")
    t:eq(om.resolve({}), nil, "a table is not an id")
end)

s:test("an illegal pack id or name is rejected and the message names the offender", function(t)
    local fname, err = om.resolve("bad pack:Bench")
    t:eq(fname, nil)
    t:assert(err:find("invalid pack id", 1, true), "the pack half is blamed: " .. tostring(err))
    t:assert(err:find("bad pack", 1, true), "the offending pack id is quoted back")

    fname, err = om.resolve("example:Bad Name")
    t:eq(fname, nil)
    t:assert(err:find("invalid name", 1, true), "the name half is blamed: " .. tostring(err))

    -- Only the FIRST colon splits, so a second one lands in the name and is illegal there.
    fname, err = om.resolve("a:b:c")
    t:eq(fname, nil)
    t:assert(err:find("b:c", 1, true), "the whole remainder is the name: " .. tostring(err))
end)

s:test("an id with an empty half is not namespaced at all, so it survives as a literal", function(t)
    -- Both halves of the pattern need at least one character, so these never match and
    -- fall through the "literal game id" door instead of being rejected. Asserting
    -- today's behaviour: this is the tripwire if the split is ever tightened.
    t:eq(om.resolve(":Bench"), ":Bench", "a missing pack id is not detected")
    t:eq(om.resolve("example:"), "example:", "a missing name is not detected")
end)

--=============================================================================
-- ownership and imports — which ids a pack may key on, and which it may mention
--=============================================================================

s:test("a pack owns its own namespace and every literal id", function(t)
    t:eq(om.checkOwnership("example:Bench", "example"), true, "its own namespace")
    t:eq(om.checkOwnership("Wood", "example"), true, "a literal game id")
    t:eq(om.checkOwnership(support.GAME.building, "example"), true, "a real literal row")
end)

s:test("keying an id in someone else's namespace is refused, naming both packs", function(t)
    local ok, err = om.checkOwnership("other:Bench", "example")
    t:eq(ok, false)
    t:type(err, "string")
    t:assert(err:find("'other'", 1, true), "the namespace it reached into is named")
    t:assert(err:find("'example'", 1, true), "the pack that tried is named")
end)

s:test("a mentioned id is importable when it is literal, own, or a declared dependency", function(t)
    t:eq(om.checkImport("Wood", "example"), true, "a literal id needs no dependency")
    t:eq(om.checkImport("example:Thing", "example"), true, "its own namespace")
    t:eq(om.checkImport("otherpack:Thing", "example", { otherpack = true }), true,
        "a declared dependency")
    -- Anything that is not a string is not an id reference at all, and is waved through
    -- rather than blamed — the schema is what rejects a wrong-typed field.
    t:eq(om.checkImport(nil, "example"), true, "a nil reference is not an import")
    t:eq(om.checkImport(42, "example"), true, "a non-string reference is not an import")
end)

s:test("mentioning an undeclared namespace is refused with the missing dependency named", function(t)
    local ok, err = om.checkImport("otherpack:Thing", "example")
    t:eq(ok, false, "no declared deps at all")
    t:assert(err:find("otherpack", 1, true), "the namespace to declare is named: " .. tostring(err))
    t:assert(err:find("dependency", 1, true), "the message says what is missing")

    t:eq(om.checkImport("otherpack:Thing", "example", { somethingelse = true }), false,
        "declaring a different dependency does not help")
end)

--=============================================================================
-- display — the reverse mapping, for anything a human reads
--=============================================================================

s:test("the id registry's reverse map is the authoritative display form", function(t)
    local idreg = { reverse = { example_Bench = "example:Bench" } }
    t:eq(om.display("example_Bench", idreg), "example:Bench")
    -- A reverse miss with no fallback set is shown as-is rather than guessed at.
    t:eq(om.display("other_Thing", idreg), "other_Thing", "an unknown fname is left alone")
end)

s:test("a reverse miss falls back to the registry's known packs", function(t)
    local idreg = { reverse = { example_Bench = "example:Bench" }, _knownPacks = { other = true } }
    t:eq(om.display("other_Thing", idreg), "other:Thing", "the fallback set still resolves it")
    t:eq(om.display("Wood", idreg), "Wood", "a row belonging to no pack is untouched")
end)

s:test("given only a set of pack ids the longest matching prefix wins", function(t)
    -- "_" is legal inside a name, so "my_pack_Thing" is ambiguous; the longest pack that
    -- prefixes it is the best guess available.
    t:eq(om.display("my_pack_Thing", { my = true, my_pack = true }), "my_pack:Thing")
    t:eq(om.display("my_Thing", { my = true, my_pack = true }), "my:Thing")
    t:eq(om.display("example_Bench"), "example_Bench", "with no source there is nothing to reverse")
end)

--=============================================================================
-- the typed class registry
--=============================================================================

s:test("register and get round-trip the exact class object", function(t)
    local id  = support.id("item")
    local cls = { id = id }
    t:eq(om.register("item", id, cls), cls, "register hands the class back")
    t:eq(om.get("item", id), cls, "get returns the same table, not a copy")
    t:eq(om.get("pal", id), nil, "the id is scoped to its own type")
    forget("item", id)
    t:eq(om.get("item", id), nil, "and it is gone again")
end)

s:test("all() hands out a snapshot that cannot reach the live registry", function(t)
    local id  = support.id("skill")
    local cls = { id = id }
    om.register("skill", id, cls)

    local snap = om.all("skill")
    t:eq(snap[id], cls, "the snapshot contains what was registered")
    snap[id] = nil
    snap["palforge_test:ghost"] = { id = "palforge_test:ghost" }

    t:eq(om.get("skill", id), cls, "deleting from the snapshot left the registry alone")
    t:eq(om.get("skill", "palforge_test:ghost"), nil, "and adding to it registered nothing")
    forget("skill", id)
end)

s:test("an unknown object type fails soft everywhere, and never throws", function(t)
    local cls, err = om.register("bogus", support.id("bogus"), { id = "x" })
    t:eq(cls, nil, "register refuses the type")
    t:type(err, "string", "and says why")
    t:assert(err:find("unknown type", 1, true), "the reason names the problem: " .. tostring(err))
    t:assert(err:find("bogus", 1, true), "the typo is quoted back")

    t:eq(om.get("bogus", "anything"), nil, "get on an unknown type is nil, not an error")
    local all = om.all("bogus")
    t:type(all, "table", "all() on an unknown type is still a table")
    t:eq(next(all), nil, "an empty one")
end)

s:test("an empty or non-string id is refused with a reason", function(t)
    local cls, err = om.register("item", "", {})
    t:eq(cls, nil)
    t:assert(err:find("non-empty string", 1, true), "the reason names the rule: " .. tostring(err))
    t:eq(om.register("item", nil, {}), nil, "nil is not an id")
    t:eq(om.register("item", 7, {}), nil, "a number is not an id")
end)

s:test("registering a nil class forgets the id, and reports no error", function(t)
    local id = support.id("effect")
    om.register("effect", id, { id = id })
    local cls, err = om.register("effect", id, nil)
    t:eq(om.get("effect", id), nil, "the entry is gone")
    t:eq(cls, nil, "there is no class to hand back")
    t:eq(err, nil, "and it is NOT reported as a failure — nil,nil, not nil,reason")
end)

s:test("TYPES lists all eight object domains, sorted, mesh among them", function(t)
    local want = { audio = true, building = true, effect = true, item = true,
                   mesh = true, pal = true, skill = true, ui = true }

    t:eq(#om.TYPES, 8, "one type per api definition module")
    local seen = {}
    for i, otype in ipairs(om.TYPES) do
        t:truthy(want[otype], "'" .. tostring(otype) .. "' is a known domain")
        seen[otype] = true
        if i > 1 then
            t:assert(om.TYPES[i - 1] < otype, "TYPES is sorted so tooling output is stable")
        end
    end
    for otype in pairs(want) do t:truthy(seen[otype], otype .. " is missing from TYPES") end
    t:truthy(seen.mesh, "mesh is a domain of its own, not a field of pal/building")
end)

s:test("every type TYPES advertises is one register() actually accepts", function(t)
    for _, otype in ipairs(om.TYPES) do
        local id  = support.id(otype)
        local cls = { id = id }
        t:eq(om.register(otype, id, cls), cls, "'" .. otype .. "' is registrable")
        t:eq(om.get(otype, id), cls, "'" .. otype .. "' round-trips")
        forget(otype, id)
    end
end)

--=============================================================================
-- core/registry — the kernel's view of the same registry
--=============================================================================

s:test("registered() has a bucket for every object type", function(t)
    local snap = registry.registered()
    t:type(snap, "table")
    for _, otype in ipairs(om.TYPES) do
        t:type(snap[otype], "table", "registered()." .. otype .. " is a table")
    end
    -- Only the object types; nothing invented on the side.
    local n = 0
    for _ in pairs(snap) do n = n + 1 end
    t:eq(n, #om.TYPES, "no bucket beyond the declared types")
end)

s:test("registered() is a snapshot: editing it cannot reach the live registry", function(t)
    local id  = support.id("building")
    local cls = { id = id }
    om.register("building", id, cls)

    local snap = registry.registered()
    t:eq(snap.building[id], cls, "a freshly registered class shows up immediately")
    snap.building[id] = nil
    t:eq(om.get("building", id), cls, "dropping it from the snapshot dropped nothing")
    t:eq(registry.registered().building[id], cls, "a second snapshot still has it")

    forget("building", id)
    t:eq(registry.registered().building[id], nil, "and the snapshot follows the real removal")
end)

s:test("the kernel has already registered the curated native classes", function(t)
    -- initialize() runs at mod load, before any case file does; these are the curated
    -- definitions the native catalogs declare (the bulk CATALOG rows stay lazy data).
    local snap = registry.registered()
    t:truthy(snap.pal[support.GAME.pal], support.GAME.pal .. " is registered")
    t:truthy(snap.pal[support.GAME.pal2], support.GAME.pal2 .. " is registered")
    t:truthy(snap.building[support.GAME.building], support.GAME.building .. " is registered")
    t:truthy(snap.building[support.GAME.palbox], support.GAME.palbox .. " is registered")
    t:truthy(snap.ui["palforge:Button"], "the framework's own ui classes register too")
end)

--=============================================================================
-- the public api writes into the same registry
--=============================================================================

s:test("defining through the api registers the definition under its own type", function(t)
    local id = support.id("mesh")
    local h  = Mesh{ id = id, model = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal" }

    t:eq(h.id, id, "the handle carries the id it was defined with")
    t:truthy(om.get("mesh", id), "defining self-registered it — no separate register step")
    t:eq(registry.registered().mesh[id], om.get("mesh", id),
        "and the kernel's snapshot sees the same class")
    t:eq(om.get("mesh", id), Mesh.get(id)._cls, "Mesh.get finds exactly that class")

    forget("mesh", id)
    t:eq(om.get("mesh", id), nil, "test content is not left behind")
end)

return s
