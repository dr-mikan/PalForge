-- palforge/test/cases/store_api.lua — the PACK-FACING half of persisted world state.
--
-- Three surfaces meet here and this file is where their contract is pinned:
--
--   api.pack(id, opts)            what a pack id may be, now that it is also a FILE NAME
--   PalForge.pack(id).store       the pack's own saved state, isolated to one file
--   core/ledger                   the ids PalForge asked the GAME to write, which is the only
--                                 part of any of this that reaches Palworld's own .sav
--
-- NOTHING HERE NEEDS A WORLD AND NOTHING HERE TOUCHES state/. core/state routes every disk
-- operation through one table (state.__io) and every check that reaches the store substitutes an
-- in-memory implementation of it, exactly as test/cases/store_state.lua does — a suite for the
-- module a player's saved state lives in must not be able to write into a player's saved state.
-- The ledger checks call core/ledger directly rather than pressing :give / :unlock / :teach,
-- because those need a loaded save and a player, and what is under test is the BOOKKEEPING and
-- not the inventory write those three already measure for themselves.
--
-- ⚠️ THE STORE-FACING HALF SKIPS WITHOUT core/state.lua, and says so rather than passing. That
-- module owns the store surface; when it is absent (tooling, a partial deploy, a tree mid-
-- redesign) every check that would exercise it reports skipUnanswerable naming the module. A
-- green line here with skips means "the store was not there to ask", never "the store is fine".
--
-- WHY THE SWEEP MATTERS MORE IN THIS FILE THAN ANYWHERE ELSE: the ids below are registered so
-- that object_manager.owner has something to answer, and owner is the ledger's ONLY gate. An id
-- left registered after a run would keep a later :give writing ledger rows under a test pack.
-- support.sweepAfter(s) takes them all back out.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local api     = require("palforge.api")
local om      = require("palforge.core.object_manager")
local json    = require("palforge.utils.json")
local ledger  = require("palforge.core.ledger")

local s = T.suite("store_api")
support.sweepAfter(s)

-- The pack every check in this file registers under. It is support.NAMESPACE, so every id it
-- owns is swept — and, for a store keyed on pack id, the file it would write is named
-- palforge_test.json, which is recognisable on sight if one ever escapes the fake backend.
local PACK = support.NAMESPACE

-- core/state, or nil. Asked per call rather than memoized, for the reason object_manager's lazy
-- logger states: F9 wipes modules, and a reference captured at file scope closes over a wiped one.
local function state()
    local ok, mod = pcall(require, "palforge.core.state")
    if ok and type(mod) == "table" and type(mod.storeFor) == "function" then return mod end
    return nil
end

-- Skip unless the store module is here. The skip is SESSION-directed: pressing the key again in
-- another game state will not conjure a module, so the text is itself the finding.
local function needStore(t)
    local st = state()
    if not st or type(st.__io) ~= "function" then
        t:skipUnanswerable("palforge.core.state did not load (or exports no storeFor/__io), so "
            .. "the pack store surface does not exist in this tree to be measured")
    end
    return st
end

-- The in-memory backend. Same vocabulary core/state's real IO speaks, and files are TEXT for the
-- same reason store_state.lua keeps them as text: what a store does with bytes it cannot parse is
-- a claim about bytes.
local function fakeIO()
    local files = {}
    local io_ = { files = files, writes = {} }
    function io_.get(key)
        local f = files[key]
        if not f then return nil, "absent" end
        local v, err = json.decode(f.text)
        if type(v) ~= "table" then return nil, err or "not a JSON object" end
        return v
    end
    function io_.put(key, value)
        local text, err = json.encode(value)
        if not text then return false, tostring(err) end
        files[key] = { text = text }
        io_.writes[key] = (io_.writes[key] or 0) + 1
        return true
    end
    function io_.forget() end
    function io_.bytes(key)  return files[key] and #files[key].text or nil end
    function io_.exists(key) return files[key] ~= nil end
    function io_.path(key)   return "<fake>/" .. key .. ".json" end
    function io_.moveAside()  return false, "absent" end
    function io_.writeRaw()   return true end
    function io_.existsRaw()  return true end   -- README.txt already there: never write one
    function io_.remove(key)
        if not files[key] then return false, "absent" end
        files[key] = nil
        return true
    end
    return io_
end

-- Did this suite leave anything of its own in the store's caches? Asked before the loud cleanup
-- below, and asked of all three places a check here can reach: the pack's key/value data, its
-- ledger, and the merged world view the buildings check injects a synthetic record into.
local function leftSomething(st)
    local db = api.pack(PACK).store
    if type(db.keys) == "function" and #db.keys() > 0 then return true end
    local led = ledger.read(PACK)
    if type(led) == "table" and next(led) ~= nil then return true end
    local ok, w = pcall(st.world)
    if ok and type(w) == "table" then
        for _, src in ipairs({ w.entities or {}, w.orphans or {} }) do
            for _, rec in pairs(src) do
                if type(rec) == "table" and rec.pack == PACK then return true end
            end
        end
    end
    return false
end

-- Run fn(store, fake) against a fresh in-memory backend and put the real one back WHATEVER
-- happens — an assertion raises a TABLE sentinel, so it is re-raised unchanged (error(e, 0)) or
-- the runner reports a failure with no message instead of the assertion it was.
--
-- The cleanup is state.uninstall(PACK), not state.__reset(): reset clears the whole merged world
-- view, and in a loaded game that view is the SAME table core/event holds every structure's
-- record in. uninstall is scoped to this one pack — it drops its caches, its dirty flag and its
-- records, and under the fake backend it deletes nothing real.
local function withStore(t, fn)
    local st   = needStore(t)
    local fake = fakeIO()
    local prev = st.__io(fake)
    local ok, e = pcall(fn, api.pack(PACK).store, fake, st)
    -- uninstall is LOUD by design — it is the one destructive call in the store and it says so
    -- every time — so it is asked for only when this suite actually put something in the pack's
    -- slice. A green run must not print four "this deletes the state PalForge kept" lines about
    -- a pack that is empty; a run that leaked something must still be cleaned, including when an
    -- assertion raised half way through.
    if leftSomething(st) then pcall(st.uninstall, PACK) end
    st.__io(prev)
    if not ok then error(e, 0) end
end

--=============================================================================
-- api.pack — a pack id is now a file name
--=============================================================================

s:test("the three ids the store owns are refused, by name", function(t)
    -- Every one of these matches ^[%w_]+$ and was a legal pack id until the store existed. A
    -- pack called "_save" would have written its buildings over the per-save manifest.
    for _, reserved in ipairs({ "_save", "_unowned", "_quarantine" }) do
        local text = t:errors(function() return api.pack(reserved) end, reserved,
            "api.pack(" .. string.format("%q", reserved) .. ") must raise and name the id")
        t:truthy(text:find("RESERVED", 1, true) or text:find("reserved", 1, true),
            "the refusal must say the id is reserved, not just that it is invalid: " .. text)
    end
end)

s:test("an ordinary underscore id is still fine", function(t)
    -- The refusal is three exact names, NOT "anything starting with _". A pack called
    -- "_mypack" is legal and must stay legal — over-tightening here would break packs
    -- silently at their first line.
    local scoped = api.pack("_mypack")
    t:type(scoped, "table", "_mypack is not reserved and must build a scoped api")
    t:type(scoped.Item, "table", "the scoped api still carries its constructors")
end)

s:test("opts.version is accepted, and a non-string is refused at the call site", function(t)
    local scoped = api.pack(PACK, { version = "1.0.0" })
    t:type(scoped, "table", "a declared version must not change what api.pack returns")
    t:errors(function() return api.pack("palforge_test_ver", { version = 7 }) end, "version",
        "a non-string version must raise and name the field")
end)

--=============================================================================
-- the store member
--=============================================================================

s:test("every pack gets a store, and it is the same one every time", function(t)
    local a = api.pack(PACK).store
    local b = api.pack(PACK).store
    t:type(a, "table", "PalForge.pack(id).store must exist whether or not core/state loaded — "
        .. "an absent store answers refusals, never nil")
    t:eq(a, b, "the scoped api is memoized, so the store handle must be too")
    local other = api.pack("palforge_test_other").store
    t:neq(a, other, "two packs must not share one store handle")
end)

s:test("an unavailable store refuses; it never silently accepts", function(t)
    if state() then
        t:skipUnanswerable("core/state loaded, so the no-store degradation path cannot be "
            .. "reached from here — this asserts what a pack sees when the store MODULE is "
            .. "missing, which is a property of the tree and not of the session")
    end
    local db = api.pack(PACK).store
    local ok, why = db.set("k", 1)
    t:falsy(ok, "a store that cannot persist must not report a write as done")
    t:type(why, "string", "and it must say why")
    t:truthy(tostring(why):find(PACK, 1, true), "the reason must name the pack: " .. tostring(why))
end)

s:test("db.set validates the value at the pack's own call site", function(t)
    withStore(t, function(db)
        -- The refusal classes of the store spec. The mixed-key one is not defensive programming:
        -- it is a live encoder bug — encodeTable built its key list with tostring(k) and then
        -- read t[k] with the STRING, so t[1] came back nil and { "wood", count = 3 } lost its
        -- array half on every save. The encoder is fixed; this is the call-site diagnosis.
        local cycle = {}; cycle.a = { b = cycle }
        local deep  = {}; local cur = deep
        for _ = 1, 24 do cur.n = {}; cur = cur.n end
        local wide  = {}; for i = 1, 5000 do wide["f" .. i] = i end

        local CASES = {
            { name = "cycle",    value = cycle },
            { name = "function", value = { onDone = function() end } },
            { name = "nan",      value = { rate = 0 / 0 } },
            { name = "inf",      value = { rate = math.huge } },
            { name = "mixed",    value = { [1] = "wood", count = 3 } },
            { name = "deep",     value = deep },
            { name = "wide",     value = wide },
            { name = "big",      value = { blob = string.rep("x", 70 * 1024) } },
        }
        for _, c in ipairs(CASES) do
            local ok, why = db.set("badval_" .. c.name, c.value)
            t:falsy(ok, "db.set must refuse a value that cannot be saved (" .. c.name .. ")")
            t:type(why, "string", "the refusal must carry a reason (" .. c.name .. ")")
            local text = tostring(why)
            t:truthy(text:find(PACK, 1, true),
                "the reason must name the pack, so a player knows whose bug it is: " .. text)
            t:truthy(text:find("badval_" .. c.name, 1, true),
                "the reason must name the key it refused: " .. text)
        end

        -- And the control: an ordinary value is accepted, so the validator is not simply
        -- refusing everything, and the refused keys really did not land.
        t:truthy(db.set("goodval", { n = 3, list = { 1, 2, 3 }, on = true, name = "ok" }),
            "a plain tree of strings, numbers, booleans and tables must be accepted")
        t:eq(db.get("badval_cycle"), nil, "a refused value must not be stored anyway")
        t:eq(#db.keys(), 1, "exactly one key survived")
    end)
end)

s:test("db.buildings() hands back copies, not the runtime's own records", function(t)
    withStore(t, function(db, _, st)
        -- A world would put core/event's ~500 ms scan on the same table this injects into, and a
        -- synthetic record with no actor behind it is exactly what the miss sweep quarantines.
        -- The claim is about table identity and is fully measurable with no world at all.
        support.needNoWorld(t, "a loaded world runs the building scan over the very table this "
            .. "check injects a synthetic record into")
        if type(db.buildings) ~= "function" or type(st.world) ~= "function" then
            t:skipUnanswerable("the store exposes no buildings()/world() to compare")
        end

        local w   = st.world()
        local key = "palforge_test_Bench@1,2,3"
        w.entities[key] = { buildId = "palforge_test_Bench", def = PACK .. ":Bench", pack = PACK,
                            pos = { x = 100, y = 200, z = 300 }, state = { uses = 1 } }

        local found
        for _, rec in ipairs(db.buildings()) do
            if rec.key == key then found = rec end
        end
        if found then
            found.state.uses = 99
            found.buildId    = "clobbered"
            found.pos.x      = -1
        end
        local live = w.entities[key]
        w.entities[key] = nil          -- put the runtime's view back BEFORE asserting anything

        t:truthy(found, "db.buildings() must return this pack's records")
        t:eq(live.buildId, "palforge_test_Bench",
            "mutating a returned record must not re-write the runtime's buildId")
        t:eq(live.pos.x, 100, "nor its position")
        t:eq(live.state.uses, 1,
            "mutating a returned record's state must not reach core/event's own record — this is "
            .. "the hole PalForge.utils.file.get(key) left open (building_record_orphans.lua:42-47)")
    end)
end)

--=============================================================================
-- the ledger — what PalForge made the GAME write
--=============================================================================

s:test("a literal game id is never ledgered — even one a pack owns", function(t)
    -- ⚠️ THIS IS THE CHECK THAT CAUGHT THE SPEC BEING WRONG ABOUT THIS TREE. The store spec gates
    -- the ledger on object_manager.owner and offers Item.get("Wood"):give(1) as the case that must
    -- write nothing. Measured here, headless: om.owner("item", "Wood") answers "palforge", because
    -- native/_catalog.lua:161 registers the curated vanilla rows under the FRAMEWORK's own pack id
    -- (contract C3). An owner-gated ledger records every vanilla give in the game.
    --
    -- So the gate is the id's NAMESPACE — is the row one that only a pack's PalSchema JSON put
    -- there? — and this check asserts it against exactly the id that falsified the other rule.
    local owner = om.owner("item", support.GAME.item)
    local ok, why = ledger.record("item", support.GAME.item, 1)
    t:falsy(ok, support.GAME.item .. " is a GAME row (registered here by pack '"
        .. tostring(owner) .. "'), and a game row cannot stop existing")
    t:type(why, "string", "and the refusal must say why")
    t:truthy(tostring(why):find("literal game id", 1, true),
        "the reason must be about the ROW, not about who called: " .. tostring(why))

    -- The same claim from the other side: a pack may CLAIM a vanilla id, and that still writes
    -- nothing, because removing the pack does not remove DT_ItemDataTable's own row.
    api.pack(PACK).Item{ id = support.GAME.item }
    t:eq(om.owner("item", support.GAME.item), PACK, "the claim must have landed")
    t:falsy(ledger.record("item", support.GAME.item, 1),
        "a pack claiming a vanilla id does not make the game's row disappear on uninstall")
    -- Put the registry back the way it was, or every later suite's Wood lookup answers ours.
    om.unregister("item", support.GAME.item)
end)

s:test("an unknown kind, a bad id and an unresolvable namespace are all refused", function(t)
    t:falsy(ledger.record("inventory", "mypack:Potion", 1), "there are four kinds and no others")
    t:falsy(ledger.record("item", "", 1), "an empty id is not a name")
    t:falsy(ledger.record("item", nil, 1), "and neither is nil")
    t:falsy(ledger.record("item", ":Potion", 1),
        "an id with an empty namespace is not namespaced at all — object_manager.resolve waves "
        .. "it through as a literal, so nothing in the save can be spelled that way")
    local ok, why = ledger.record("item", "my-pack:Potion", 1)
    t:falsy(ok, "an id that cannot resolve to a row cannot be in the save either — and this is "
        .. "the one id boundary where `resolve(x) or x` is NOT the rule, because there is no "
        .. "engine here to hand the literal to")
    t:truthy(tostring(why):find("cannot resolve", 1, true),
        "and the reason must say so rather than inventing a file name: " .. tostring(why))
end)

s:test("the four kinds each name a registry type and what reached the save", function(t)
    -- The gate's own table, and all it is allowed to know. WHAT CAN BE TAKEN BACK is NOT here:
    -- core/state.lua's RECLAIM table owns that and store.reclaim() reports out of it, so there
    -- is exactly one copy of the rule and it cannot drift from the report a player is shown.
    local EXPECT = { item = "item", tech = "building", passive = "skill", pal = "pal" }
    for kind, otype in pairs(EXPECT) do
        local k = ledger.kind(kind)
        t:type(k, "table", "core/ledger must know the kind '" .. kind .. "'")
        t:eq(k.otype, otype, kind .. " ids are registered under object_manager type " .. otype)
        t:type(k.wrote, "string", "and it must say what that call put into Palworld's save")
    end
    t:eq(ledger.kind("active"), nil,
        "an ACTIVE skill is never ledgered: EPalWazaID is a fixed vanilla enum Lua cannot add "
        .. "to, so nothing written through AddEquipWaza can stop being valid")
    t:eq(ledger.kind("nonsense"), nil, "and there is no fifth kind")
end)

s:test("a pack-owned id IS ledgered, and reclaim names what it cannot undo", function(t)
    withStore(t, function(db)
        if type(db.ledger) ~= "function" then t:skipUnanswerable("the store exposes no ledger()") end

        local scoped = api.pack(PACK)
        local itemId = support.id("Potion")
        local techId = support.id("Bench")
        scoped.Item{ id = itemId }
        scoped.Building{ id = techId }
        t:eq(om.owner("item", itemId), PACK, "the item must be attributed to this pack")
        t:eq(om.owner("building", techId), PACK, "and so must the building")

        local okItem, whyItem = ledger.record("item", itemId, 3)
        -- A hard failure, not a skip. If the store cannot take an append, PalForge is writing
        -- pack-owned names into the player's save and keeping no list of them — which is the one
        -- thing this whole surface exists to prevent. The message names the interface so the fix
        -- is not a search.
        t:truthy(okItem, "a pack-owned item give must land in the ledger. It did not: "
            .. tostring(whyItem) .. ". core/ledger writes through "
            .. "core.state.ledgerAdd(pack, kind, id, n); that is the interface it needs")
        t:truthy(ledger.record("tech", techId), "and so must a pack-owned unlock")

        local resolvedItem = om.resolve(itemId)
        local led = ledger.read(PACK)
        t:type(led, "table", "the pack's ledger must be readable")
        t:type(led.item[resolvedItem], "table",
            "the ROW spelling is what the save holds, so that is what is keyed: " .. resolvedItem)
        t:eq(led.item[resolvedItem].n, 3, "the count is what was given")
        t:type(led.item[resolvedItem].at, "number", "and when")
        t:eq(led.item[itemId], nil, "the source spelling must NOT be a key — nothing holds it")

        -- Twice is accumulated, not overwritten.
        ledger.record("item", itemId, 2)
        t:eq(ledger.read(PACK).item[resolvedItem].n, 5, "a second give adds to the row")

        -- And the removal report, which is the whole reason the rows exist.
        local report = ledger.reclaim(PACK)
        t:type(report, "table", "the store must report on what removal would leave behind")
        t:eq(report.applied, false, "reclaim REPORTS unless asked to act; it must not act alone")
        t:eq(#report.entries, 2, "one item id and one technology id")
        local stuck = {}
        for _, row in ipairs(report.unreclaimable) do stuck[row.kind] = row end
        t:truthy(stuck.tech, "the report must name TECHNOLOGY as unreclaimable — the one thing "
            .. "PalForge can never undo, because UPalCheatManager declares four unlock entries "
            .. "and no lock")
        t:falsy(stuck.item, "and must not claim the item half is stuck")
        t:truthy(tostring(stuck.tech.limit):find("IMPOSSIBLE", 1, true),
            "with the evidence, in that word: " .. tostring(stuck.tech.limit))
        t:truthy(tostring(report.text):find("CANNOT be undone", 1, true),
            "the English half must say it too: " .. tostring(report.text))
    end)
end)

s:test("the ledger reaches ONE pack's file and no other's", function(t)
    withStore(t, function(_, fake, st)
        local scoped = api.pack(PACK)
        local itemId = support.id("Potion")
        scoped.Item{ id = itemId }
        t:truthy(ledger.record("item", itemId, 1), "the append must land")
        t:truthy(st.flushDirty(), "and flush")

        -- ISOLATION, which is the whole point of the redesign: one pack's write touches one
        -- pack's file. `_save` is the manifest and is expected beside it; nothing else may be.
        local wrote = {}
        for key in pairs(fake.writes) do wrote[#wrote + 1] = key end
        table.sort(wrote)
        for _, key in ipairs(wrote) do
            t:truthy(key:find(PACK, 1, true) or key:find("_save", 1, true),
                "an append by one pack must not rewrite another pack's file, but it wrote "
                .. key .. " (all writes: " .. table.concat(wrote, ", ") .. ")")
        end
        local mine = st.keyFor(PACK)
        t:truthy(mine and fake.files[mine], "this pack's own file must be the one that got it")
    end)
end)

return s
