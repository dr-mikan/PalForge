-- palforge/test/cases/registry.lua — id resolution and the central object registry.
--
-- This suite pins down the two halves of "what exists": core/object_manager (the id model
-- — resolve / validId / checkOwnership / checkImport / display, the pack-identity scope,
-- and the typed class registry the api definitions write into) and
-- core/registry.registered(), the kernel's snapshot of that registry. It is entirely PURE:
-- nothing here touches the world, so every test runs and passes at the title screen
-- exactly as it does in a save. The one thing it does assume is that the kernel has
-- already run — the native catalogs are loaded, so the curated ids are registered — which
-- is true by the time any case file runs.
--
-- The registry's diagnostics are LOG LINES (a collision is last-wins by policy, so there
-- is no return value to inspect), which is why this file installs a log sink: a warning
-- that nobody can observe is the F-1 defect all over again, and a test that cannot read
-- the warning cannot prove it happened.
--
-- Every id written here comes from support.id() or the literalId() helper below, and each
-- test un-registers what it registered, so a run leaves the registry exactly as it found it.
local T        = require("palforge.core.unittests")
local support  = require("palforge.test.support")
local om       = require("palforge.core.object_manager")
local registry = require("palforge.core.registry")
local logmod   = require("palforge.utils.log")
local Mesh     = require("palforge.api.mesh")

local s = T.suite("registry")

-- Drop a test class again. om.unregister is the explicit spelling and reports whether
-- anything was there; register(otype, id, nil) is the older one and still works (test
-- support's sweep uses it, and the test further down pins it).
local function forget(otype, id) om.unregister(otype, id) end

-- A LITERAL (colon-free) test id, derived from support.id() so it carries the same
-- per-run counter and can never collide with itself or with real content. A literal id is
-- what an ownership check waves through, so a test about a COLLISION can be about the
-- collision alone, with no ownership warning mixed into the log it reads back. Nothing
-- sweeps these — support.isTestId only recognises the "palforge_test:" namespace — so
-- every test that makes one unregisters it itself.
local function literalId(tag)
    return (support.id(tag):gsub("[^%w_]", "_"))
end

-- ---- reading object_manager's diagnostics ----
--
-- utils.log fans every record out to every sink and has no removeSink, so the capture is
-- installed ONCE here, at file load, and stays inert (`capturing` is false) except inside
-- record(). Only object_manager's own scope is kept: another module warning during the
-- same call is not this suite's business.
local captured, capturing = {}, false
logmod.addSink(function(level, scope, msg)
    if capturing and scope == "objects" then
        captured[#captured + 1] = { level = level, msg = tostring(msg) }
    end
end)

-- Run fn and return every object_manager log record it produced.
local function record(fn)
    captured, capturing = {}, true
    local ok, err = pcall(fn)
    capturing = false
    if not ok then error(err, 0) end
    return captured
end

-- The first record at `level` whose message contains every one of `parts`, or nil.
local function lineWith(records, level, parts)
    for _, rec in ipairs(records) do
        if rec.level == level then
            local hit = true
            for _, part in ipairs(parts) do
                if not rec.msg:find(part, 1, true) then hit = false break end
            end
            if hit then return rec.msg end
        end
    end
    return nil
end

-- Every record at `level`, joined — for the failure message when a line is missing.
local function dump(records, level)
    local out = {}
    for _, rec in ipairs(records) do
        if not level or rec.level == level then out[#out + 1] = rec.level .. ": " .. rec.msg end
    end
    return #out > 0 and table.concat(out, " | ") or "(nothing logged)"
end

local function countAt(records, level)
    local n = 0
    for _, rec in ipairs(records) do if rec.level == level then n = n + 1 end end
    return n
end

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
-- validId — the same shape check, run at DEFINE time instead of at the engine boundary
--
-- resolve() answers "what row is this?" and its failure is a fallback to the literal.
-- validId() answers "could this ever have been an id?" and its failure is a hard error in
-- the domain constructor, before anything is registered. The whole point of F-4 is that
-- Building{ id = "my-pack:Bench" } used to define, register, resolve to nothing, index no
-- build id, and fire no event — with no log line anywhere.
--=============================================================================

s:test("validId accepts every id that can reach a game row, and rejects the rest", function(t)
    -- { id, accepted, what it is }
    local TABLE = {
        { "Wood",              true,  "a literal game id" },
        { "BP_ChickenPal_C",   true,  "a literal blueprint id, underscores and all" },
        { "example:Bench",     true,  "the namespaced form" },
        { "my_pack:Bench_2",   true,  "_ and digits are legal in both halves" },
        { "my-pack:Bench",     false, "a hyphen in the pack half is what VALID rejects" },
        { "example:Bad Name",  false, "a space in the name half" },
        { "a:b:c",             false, "only the first colon splits, so 'b:c' is the name" },
        { ":Bench",            false, "an empty pack half" },
        { "example:",          false, "an empty name half" },
        { "",                  false, "the empty string is not an id" },
    }
    for _, row in ipairs(TABLE) do
        local id, want, why = row[1], row[2], row[3]
        local ok, reason = om.validId(id)
        t:eq(ok, want, string.format("validId(%q) must be %s — %s", id, tostring(want), why))
        if not want then
            t:type(reason, "string", string.format("validId(%q) must say why it refused", id))
        end
    end
    t:eq(om.validId(nil), false, "nil is not an id")
    t:eq(om.validId(42), false, "a number is not an id")
    t:eq(om.validId({}), false, "a table is not an id")
end)

s:test("validId is STRICTER than resolve, and only about the empty halves", function(t)
    -- resolve's split needs at least one character on each side, so ":Bench" and
    -- "example:" never match it and fall through its "literal game id" door (pinned above).
    -- validId refuses them, because at define time an id with an empty half is a typo every
    -- time — and refusing it there means resolve's literal door is never reached for one.
    t:eq(om.resolve(":Bench"), ":Bench", "resolve still treats it as a literal")
    t:eq(om.validId(":Bench"), false, "define time is where it is caught")

    -- Everywhere else the two agree exactly: what validId accepts, resolve resolves.
    for _, id in ipairs({ "Wood", "example:Bench", "my_pack:Bench_2" }) do
        t:truthy(om.validId(id), id .. " is valid")
        t:truthy(om.resolve(id), id .. " therefore resolves")
    end
    for _, id in ipairs({ "my-pack:Bench", "a:b:c", "example:Bad Name" }) do
        t:falsy(om.validId(id), id .. " is refused")
        t:eq(om.resolve(id), nil, id .. " would not have resolved either")
    end
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

s:test("a pack's declared dependencies are remembered, so a caller need not carry them", function(t)
    -- api.pack("mypack", { depends = { "otherpack" } }) records the set once; every later
    -- checkImport for that pack consults it. Without a memory, the only callers that could
    -- ever check an import would be the ones already holding the pack's manifest.
    local packId = "palforge_test_deps"
    t:eq(om.deps(packId), nil, "a pack that declared nothing has no set")
    t:eq(om.checkImport("otherpack:Thing", packId), false, "and so imports nothing")

    om.declareDeps(packId, { "otherpack" })                    -- array form
    t:truthy(om.deps(packId).otherpack, "the array form becomes a set")
    t:eq(om.checkImport("otherpack:Thing", packId), true, "the remembered dep is honoured")
    t:eq(om.checkImport("thirdpack:Thing", packId), false, "and only that one")

    om.declareDeps(packId, { thirdpack = true })               -- set form, replaces
    t:eq(om.checkImport("thirdpack:Thing", packId), true, "the set form works the same")
    t:eq(om.checkImport("otherpack:Thing", packId), false, "declaring again REPLACES the set")

    -- An explicit set still wins, so a caller that has the manifest in hand is unaffected.
    t:eq(om.checkImport("otherpack:Thing", packId, { otherpack = true }), true,
        "an explicit set overrides what was declared")

    om.declareDeps(packId, nil)
    t:eq(om.deps(packId), nil, "declaring nil forgets the set again")
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
    -- The OLD spelling of "forget this", kept working on purpose: it is undocumented but
    -- it is what test/support.lua's sweep calls, and a sweep that stopped working would
    -- leave a run's throwaway definitions in the live registry for core/event to walk.
    -- om.unregister (next test) is the spelling everything new should use.
    local id = support.id("effect")
    om.register("effect", id, { id = id })
    local cls, err = om.register("effect", id, nil)
    t:eq(om.get("effect", id), nil, "the entry is gone")
    t:eq(cls, nil, "there is no class to hand back")
    t:eq(err, nil, "and it is NOT reported as a failure — nil,nil, not nil,reason")
end)

s:test("unregister removes the entry and says whether there was one", function(t)
    local id = support.id("item")
    om.register("item", id, { id = id })

    t:eq(om.unregister("item", id), true, "it removed something and says so")
    t:eq(om.get("item", id), nil, "the class is gone")
    t:eq(om.isRegistered("item", id), false, "and the id is free again")
    t:eq(om.unregister("item", id), false, "a second removal has nothing to remove")
    t:eq(om.unregister("item", "palforge_test:never_registered"), false, "nor has an unknown id")
    t:eq(om.unregister("bogus", id), false, "nor an unknown type — still no throw")
end)

--=============================================================================
-- the detectability surface — "is this id taken, and by whom"
--
-- F-1: registration was a silent overwrite that a pack could not detect. get() cannot
-- answer it (seven of the nine domains fabricate a fallback rather than return nil), so
-- the answer lives here: isRegistered / owner / entry.
--=============================================================================

s:test("isRegistered is the yes/no that X.get cannot give, and is always a boolean", function(t)
    local id = support.id("building")
    t:eq(om.isRegistered("building", id), false, "a fresh id is free")

    om.register("building", id, { id = id })
    t:eq(om.isRegistered("building", id), true, "and taken once registered")
    t:eq(om.isRegistered("pal", id), false, "the answer is per type, like the registry")
    t:eq(om.isRegistered("bogus", id), false, "an unknown type is 'no', not an error")
    t:eq(om.isRegistered("building", 42), false, "a non-string id is 'no', not a throw")

    forget("building", id)
    t:eq(om.isRegistered("building", id), false, "and free again after unregister")
end)

s:test("entry carries the class, its owner and the resolved form — as a copy", function(t)
    local id  = support.id("skill")
    local cls = { id = id }
    om.register("skill", id, cls, { pack = support.NAMESPACE })

    local e = om.entry("skill", id)
    t:type(e, "table", "a registered id has a record")
    t:eq(e.cls, cls, "the record holds the class itself, not a copy of it")
    t:eq(e.pack, support.NAMESPACE, "and who registered it")
    t:eq(e.resolved, om.resolve(id), "and the row name the game will see")

    -- The record is a copy: re-attributing content by writing into someone else's
    -- registration must not be one table assignment away.
    e.pack = "someone_else"
    t:eq(om.owner("skill", id), support.NAMESPACE, "editing the copy changed nothing")
    t:neq(om.entry("skill", id), e, "each call hands out a fresh record")

    t:eq(om.entry("skill", support.id("absent")), nil, "an unregistered id has no record")
    t:eq(om.entry("bogus", id), nil, "nor does an unknown type")
    forget("skill", id)
    t:eq(om.entry("skill", id), nil, "and the record goes with the registration")
end)

s:test("owner is nil for a definition made outside any pack scope", function(t)
    local id = support.id("item")
    om.register("item", id, { id = id })
    t:eq(om.owner("item", id), nil,
        "an unattributed define is attributed to nobody — the whole of the old behaviour")
    t:eq(om.owner("item", support.id("absent")), nil, "an unregistered id has no owner either")
    forget("item", id)
end)

--=============================================================================
-- pack identity (F-6) — withPack is how a definition call says who made it
--=============================================================================

s:test("withPack scopes a registration to a pack and always restores the previous scope", function(t)
    local id = support.id("pal")
    t:eq(om.currentPack(), nil, "the suite runs outside any pack scope")

    local a, b = om.withPack(support.NAMESPACE, function(x)
        t:eq(om.currentPack(), support.NAMESPACE, "inside, the scope is set")
        om.register("pal", id, { id = id })
        return x, "two"
    end, "one")
    t:eq(a, "one", "arguments are forwarded")
    t:eq(b, "two", "and every return value comes back")

    t:eq(om.currentPack(), nil, "the scope is popped again")
    t:eq(om.owner("pal", id), support.NAMESPACE, "the registration kept the attribution")
    forget("pal", id)
end)

s:test("withPack nests, and restores even when the body raises", function(t)
    om.withPack("outerpack", function()
        t:eq(om.currentPack(), "outerpack")
        om.withPack("innerpack", function() t:eq(om.currentPack(), "innerpack") end)
        t:eq(om.currentPack(), "outerpack", "the inner scope is popped back to the outer one")
    end)
    t:eq(om.currentPack(), nil)

    -- The error must arrive unchanged: the unit-test framework raises TABLES (its fail and
    -- skip sentinels), so a withPack that stringified what it caught would turn every
    -- failed assertion inside a scoped define into an unreadable "unexpected Lua error".
    local ok, err = pcall(om.withPack, "boompack", function() error({ marker = true }, 0) end)
    t:eq(ok, false, "the body's error propagates")
    t:type(err, "table", "and arrives as the value that was raised")
    t:truthy(err.marker, "unchanged")
    t:eq(om.currentPack(), nil, "and the scope is restored on the way out")
end)

s:test("an explicit opts.pack wins over the surrounding scope", function(t)
    local id = support.id("audio")
    om.withPack("scopepack", function()
        om.register("audio", id, { id = id }, { pack = support.NAMESPACE })
    end)
    t:eq(om.owner("audio", id), support.NAMESPACE,
        "the argument is the caller being explicit; the scope is only the default")
    forget("audio", id)
end)

--=============================================================================
-- collisions (F-1, F-2) — last-wins stays; being able to SEE it is what was added
--=============================================================================

s:test("two packs claiming one id warns, names both, and the newest still wins", function(t)
    -- A literal id, so this is about the collision alone: an ownership warning would fire
    -- as well if the id sat in one of the two packs' namespaces.
    local id = literalId("collide")
    local first, second = { id = id, tag = "first" }, { id = id, tag = "second" }
    om.register("item", id, first, { pack = "packa" })

    local logged = record(function() om.register("item", id, second, { pack = "packb" }) end)
    local line = lineWith(logged, "warn", { "item", id, "packa", "packb" })
    t:truthy(line, "the collision must name the type, the id and BOTH packs: " .. dump(logged))
    t:assert(line:find("replaces", 1, true), "and say the new definition replaces the old one")

    t:eq(om.get("item", id), second, "last-wins is still the policy, not a refusal")
    t:eq(om.owner("item", id), "packb", "and ownership moved with the definition")
    forget("item", id)
end)

s:test("a pack redefining its own id is not a collision and says nothing", function(t)
    -- F9 reload, a pack re-declaring an id in its own file, the native catalogs
    -- re-materialising a row, and every test in this tree do this constantly. A warning
    -- here would be noise, and noise is what stops warnings being read.
    local id = literalId("redef")
    om.register("skill", id, { id = id, tag = "first" }, { pack = "packa" })

    local logged = record(function()
        om.register("skill", id, { id = id, tag = "second" }, { pack = "packa" })
    end)
    t:eq(countAt(logged, "warn"), 0, "no warning for an owner redefining itself: " .. dump(logged))

    -- The same is true of the unattributed case, which is what a pack that never calls
    -- api.pack looks like: nil owner, nil owner, same owner.
    local plain = literalId("redef_plain")
    om.register("skill", plain, { id = plain, tag = "first" })
    local logged2 = record(function() om.register("skill", plain, { id = plain, tag = "second" }) end)
    t:eq(countAt(logged2, "warn"), 0, "nor for two unattributed defines: " .. dump(logged2))

    forget("skill", id)
    forget("skill", plain)
end)

s:test("re-registering the very same class is not a redefinition at all", function(t)
    local id  = literalId("same")
    local cls = { id = id }
    om.register("item", id, cls, { pack = "packa" })
    local logged = record(function() om.register("item", id, cls, { pack = "packb" }) end)
    t:eq(lineWith(logged, "warn", { "replaces" }), nil,
        "identical class, different pack: nothing was replaced, so nothing is claimed")
    forget("item", id)
end)

s:test("a pack keying an id in another pack's namespace is warned, and registered anyway", function(t)
    local id  = support.id("building")             -- "palforge_test:building_N"
    local cls = { id = id }
    local logged = record(function() om.register("building", id, cls, { pack = "trespasser" }) end)

    local line = lineWith(logged, "warn", { id, support.NAMESPACE, "trespasser" })
    t:truthy(line, "the warning names the id, the namespace and the pack: " .. dump(logged))
    t:eq(om.get("building", id), cls,
        "it is REGISTERED anyway — every domain but pal discards register's result, so a "
        .. "refusal here would be a definition that vanished with no error at the call site")
    forget("building", id)
end)

s:test("two source ids that resolve to one game row warn, naming both", function(t)
    -- This is F-2 exactly: VALID allows "_" in both halves and resolution is plain
    -- concatenation, so "x:a_b" and "x_a:b" are one row with two owners. pairs() order is
    -- unspecified, so before the index the dispatch that walked the whole bucket could pick
    -- either one, differently between sessions.
    local uniq = support.id("form"):match(":(.+)$")     -- unique per run
    local a    = support.NAMESPACE .. ":" .. uniq .. "_row"
    local b    = support.NAMESPACE .. "_" .. uniq .. ":row"
    t:eq(om.resolve(a), om.resolve(b), "the two spellings are one row")

    local clsA, clsB = { id = a }, { id = b }
    om.register("pal", a, clsA)
    local logged = record(function() om.register("pal", b, clsB) end)
    local line = lineWith(logged, "warn", { a, b, om.resolve(a) })
    t:truthy(line, "the warning must name both source ids and the row: " .. dump(logged))

    -- Both definitions stay: they are different ids and get() is keyed on the id as
    -- written. It is the RESOLVED lookup that can only answer with one of them.
    t:eq(om.get("pal", a), clsA, "the first definition is untouched")
    t:eq(om.get("pal", b), clsB, "and so is the second")
    t:eq(om.byResolved("pal", om.resolve(a)), clsB, "last-wins owns the resolved lookup")

    om.unregister("pal", b)
    t:eq(om.byResolved("pal", om.resolve(a)), nil,
        "dropping the winner does not silently hand the row back to the loser — an id that "
        .. "was never in the index must not become live by someone else's removal")
    om.unregister("pal", a)
end)

--=============================================================================
-- byResolved — the O(1) reverse of resolve(), maintained at register time
--=============================================================================

s:test("byResolved finds a class by the row name the game uses, and says which id it was", function(t)
    local id  = support.id("item")
    local cls = { id = id }
    om.register("item", id, cls)

    local found, sourceId = om.byResolved("item", om.resolve(id))
    t:eq(found, cls, "the resolved form finds the class")
    t:eq(sourceId, id, "and hands back the id it was declared with, for display and logs")

    t:eq(om.byResolved("item", id), nil,
        "the index is keyed on the RESOLVED form; the namespaced spelling is get's key")
    t:eq(om.byResolved("pal", om.resolve(id)), nil, "the index is per type, like the registry")
    t:eq(om.byResolved("bogus", "anything"), nil, "an unknown type answers nil, not an error")

    forget("item", id)
    t:eq(om.byResolved("item", om.resolve(id)), nil, "unregistering clears the index too")
end)

s:test("a literal id is reachable through byResolved as itself", function(t)
    -- resolve("Wood") == "Wood", so a literal registers in the index under its own name.
    -- core/event dispatches on what the engine hands it, which for native content IS the
    -- literal — so this is the common case, not the exotic one.
    local id  = literalId("literal")
    local cls = { id = id }
    om.register("effect", id, cls)
    t:eq(om.byResolved("effect", id), cls, "a literal id indexes under itself")
    forget("effect", id)
end)

s:test("byResolved answers for content the kernel registered, without a scan", function(t)
    -- The curated native definitions are literal ids, so this doubles as a check that the
    -- index is populated by the ordinary define path and not only by this suite.
    local cls, sourceId = om.byResolved("pal", support.GAME.pal)
    t:truthy(cls, support.GAME.pal .. " must be reachable by its resolved form")
    t:eq(sourceId, support.GAME.pal, "and its source id is the literal itself")
    t:eq(cls, om.get("pal", support.GAME.pal), "the two routes find the same class")
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
    t:truthy(snap.ui["palforge:Button"], "the framework's own ui classes register too")
end)

-- THE BUILDING PAIR IS THE ONE EXCEPTION, AND IT IS DELIBERATE (F-8 / contract C2). This
-- case used to assert the opposite — that WorkBench and PalBoxV2 were registered at load,
-- alongside the pals above — and that assertion was the publish gate's own release blocker
-- written down as an expectation. Registering a BUILDING is not inert: core/event's ~500 ms
-- reconstruction scan picks the definition up and every matching actor already standing in
-- the world becomes a tracked instance PERSISTED to the save's entity file, so two
-- unconditional Building{...} calls at module load wrote a JSON record for every workbench
-- and every pal box in every install, for content nobody asked for. native/buildings.lua now
-- declares both with `{ register = false }` and hands registration to buildings.publish(id).
-- The two ids stay in support.GAME because they are still the real ids everything else in the
-- suites uses; what changed is who has to ask for them to be live.
s:test("the curated BUILDINGS are declared but not registered until published", function(t)
    -- THE CLAIM IS ABOUT REQUIRING, so it is measured across the require rather than against an
    -- empty registry. `package.loaded` means the module is usually already in memory, and — this
    -- is the case that broke it — something ELSE in the session may legitimately have published
    -- the same id: test/hooks/building-actor-streaming does exactly that so it has records to
    -- watch. On 2026-08-02 23:33 this check failed in a game for that reason while passing
    -- headlessly, and the failure said nothing about F-8. Comparing before with after asks the
    -- question the name promises: does requiring the catalog register anything.
    local before = {
        [support.GAME.building] = om.isRegistered("building", support.GAME.building),
        [support.GAME.palbox]   = om.isRegistered("building", support.GAME.palbox),
    }
    package.loaded["palforge.native.buildings"] = nil
    local nb = require("palforge.native.buildings")
    t:eq(om.isRegistered("building", support.GAME.building), before[support.GAME.building],
        support.GAME.building .. " is NOT registered by requiring the catalog")
    t:eq(om.isRegistered("building", support.GAME.palbox), before[support.GAME.palbox],
        support.GAME.palbox .. " is NOT registered by requiring the catalog")
    if before[support.GAME.building] then
        t:skipUnanswerable("something in this session has already published "
            .. support.GAME.building .. " (the streaming hook does, deliberately), so the "
            .. "publish half below would measure a no-op. The require half above still held.")
    end
    t:truthy(nb.WorkBench, "the curated handle is still declared and readable")
    t:eq(nb.WorkBench.id, support.GAME.building, "and it still carries the real build id")

    -- publish(id) is the opt-in, and it registers the very same handle under "palforge".
    local h = nb.publish(support.GAME.building)
    t:truthy(h, "publish hands the handle back")
    t:truthy(om.isRegistered("building", support.GAME.building), "publishing registers it")
    t:eq(om.owner("building", support.GAME.building), "palforge",
        "and the framework's own definitions are owned by the framework's pack id")

    forget("building", support.GAME.building)
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
