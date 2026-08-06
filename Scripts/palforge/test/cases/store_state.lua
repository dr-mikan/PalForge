-- palforge/test/cases/store_state.lua — the per-mod persistence store (core/state.lua).
--
-- This suite is ENTIRELY PURE and, more importantly, it NEVER TOUCHES state/. core/state
-- routes every disk operation through one table (state.__io) whose vocabulary is keys and
-- save-relative paths, and every check below substitutes an in-memory implementation of it.
-- A test suite for the module a player's saved state lives in must not be able to write into
-- a player's saved state — and it must not need a game, a world or a disk to say whether the
-- isolation, the refusals and the migration are right.
--
-- WHAT IS PINNED HERE, and each one is a claim the design rests on:
--   * the mod id becomes a FILENAME, so keyFor refuses the three reserved names and anything
--     that is not ^[%w_]+$;
--   * hydrate ∘ dehydrate is IDENTITY except for the three fields the file deliberately does
--     not carry the same way (pos, pack, v) — including a field this build has never heard
--     of, which must survive a rewrite;
--   * a record is never DROPPED for being malformed: a missing buildId is repaired from the
--     key, and a key that does not split keeps whatever buildId the record has;
--   * ISOLATION: one pack's flush writes one pack's file and reads no other pack's;
--   * every refusal — a save id that disagrees, a format from the future, a file that will
--     not parse — refuses to WRITE as well as to read, and never destroys the bytes;
--   * the migration attributes by pack, then by def, then by the UNIQUE definition claiming
--     a build id, leaves the legacy file byte-identical, and does not run twice.
--
-- The two things it deliberately does NOT pin, because they belong to another slice: the
-- .bak rotation and the .json -> .tmp -> .bak recovery order (utils/file/json_file.lua,
-- test/cases/store_codec.lua) and the runtime's own quarantine policy (core/event.lua,
-- test/cases/store_runtime.lua).
local T       = require("palforge.core.unittests")
local state   = require("palforge.core.state")
local json    = require("palforge.utils.json")
local om      = require("palforge.core.object_manager")
local spatial = require("palforge.core.spatial")
local support = require("palforge.test.support")

local s = T.suite("store_state")

-- The save id these checks run against, PINNED rather than probed — see withStore below for
-- what probing it cost. It is deliberately not "world": that is the real fallback bucket, and a
-- fixture that shares a name with a production value hides the day they stop agreeing.
local SAVE = "pf_testsave"

--=============================================================================
-- the in-memory store backend
--=============================================================================

-- A file is TEXT here, not a decoded value, which is the whole point: "this file will not
-- parse" and "these bytes were preserved verbatim" are both statements about text, and a
-- fake that held decoded tables could express neither.
-- The store's I/O seam is faked once, in test/support: JSON round trip, read/write counters,
-- a `failWrite` hook and a moveAside that carries the SAME bytes across. This suite used to
-- carry its own copy of all four.

-- Run fn(fake) with the store pointed at a fresh in-memory backend, and put the real one
-- back whatever happens — including when an assertion raises, whose sentinel is a TABLE and
-- must be re-raised unchanged (error(e, 0)) or the runner reports it as a failure with no
-- message instead of the assertion it was.
-- THE SAVE ID IS PINNED FOR THE DURATION OF EACH CHECK, and that is a fix rather than
-- convenience. `SAVE` used to be `spatial.saveId()` captured at MODULE LOAD — which is startup,
-- before any world exists, so it read the "world" fallback and every key below matched. In a
-- GAME that snapshot is a lie the moment a save is selected: on 2026-08-02 22:08 this suite
-- failed 21 checks in a loaded save with `expected world, got w_1DF0E44B4FDDD6196E30819A899C9009`,
-- and not one of them was about the store — they were about a constant that had gone stale
-- between require and run.
--
-- (It was HIDDEN before that day by a second defect: saveId cached its own fallback, so the
-- whole session stayed on "world" and the snapshot happened to keep matching. Fixing that one —
-- a miss is no longer cached — is what made this one visible. Two wrongs had been making a
-- right.)
--
-- These checks are about the store's LOGIC, not about which save is loaded, so pinning is also
-- the more honest fixture: the keys are deterministic in every environment instead of depending
-- on what the operator happened to load.
-- The same pin, for the two checks that ask core.state a pure question and need no fake IO at
-- all. They still have to run against a KNOWN save id: `keyFor` and `legacyKey` compose one,
-- and in a loaded game the real one is whatever the operator opened.
-- ⚠️ THE __reset() CALLS ARE LOAD-BEARING, and leaving them out is how this still failed in a
-- game after the pin was added. `state.saveDir()` answers `S.save or spatial.saveId()` — the
-- store CACHES the id it synced to — so in a session where a world had already been loaded,
-- S.save held the real save and the pin on spatial.saveId was never consulted. Headless S.save
-- is nil, so the pin worked there and the suite went green while the same two checks failed in
-- game (2026-08-02 22:21:54). Resetting drops that cache so the pinned probe is what answers.
local function withSaveId(fn)
    local prev = spatial.saveId
    spatial.saveId = function() return SAVE end
    state.__reset()
    local ok, e = pcall(fn)
    spatial.saveId = prev
    state.__reset()
    if not ok then error(e, 0) end
end

local function withStore(fn)
    local fake = support.storeIO{ json = true }
    local prevSaveId = spatial.saveId
    spatial.saveId = function() return SAVE end
    local prev = state.__io(fake)
    state.__reset()
    local ok, e = pcall(fn, fake)
    state.__io(prev)
    spatial.saveId = prevSaveId
    state.__reset()
    if not ok then error(e, 0) end
end

-- A record in the shape core/event.lua puts into the merged view.
local function record(buildId, pack, x, y, z, st)
    return { buildId = buildId, pack = pack, v = 2,
             pos = { x = x, y = y, z = z }, state = st or {} }
end

local function decodeFile(fake, key)
    local f = fake.files[key]
    if not f then return nil end
    return json.decode(f.text)
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--=============================================================================
-- key composition
--=============================================================================

s:test("a mod id becomes a file name, so the three reserved names are refused", function(t)
    withSaveId(function()
        t:eq(state.keyFor("logi"), SAVE .. "/logi", "a normal mod id keys one file per save")
    end)
    for _, bad in ipairs({ "_save", "_unowned", "_quarantine" }) do
        local key, why = state.keyFor(bad)
        t:eq(key, nil, "'" .. bad .. "' is one of the store's own files and cannot be a mod id")
        t:truthy(why and why:find(bad, 1, true), "the refusal names the id it refused")
    end
end)

s:test("a mod id that could escape state/ is refused before it becomes a path", function(t)
    -- The reason this is asked HERE and not only in api.pack: the backend key used to be a
    -- leaf name and is now a PATH. Everything that could add a second path component, walk
    -- upwards, or name a drive is refused by the same ^[%w_]+$ that resolve() already needs.
    for _, bad in ipairs({ "../evil", "a/b", "a\\b", "..", "C:", "my-pack", "my pack", "" }) do
        local key = state.keyFor(bad)
        t:eq(key, nil, string.format("%q must not become a file name", bad))
    end
    t:eq(state.keyFor(nil), nil, "a missing mod id is not a mod id")
    t:eq(state.keyFor(7), nil, "a number is not a mod id")
end)

s:test("the legacy key is the single pre-format-3 file and nothing else", function(t)
    withSaveId(function()
        t:eq(state.legacyKey(), "entities_" .. SAVE,
            "migrate() reads exactly the file the old runtime wrote")
        t:eq(state.saveDir(), SAVE, "the save directory is core.spatial's save id, unchanged")
    end)
end)

--=============================================================================
-- hydrate / dehydrate
--=============================================================================

s:test("dehydrate drops exactly pack, v and altKeys, and quantizes pos to integer cm", function(t)
    local rec = { buildId = "WorkBench", def = "mypack:Bench", pack = "mypack", v = 2,
                  altKeys = {}, pos = { x = -343156.90282075, y = 265119.81381945,
                  z = 4209.5734589245 }, state = { oreBurned = 10 } }
    local d = state.__dehydrate(rec)
    t:eq(d.pack, nil, "the pack is the FILENAME now, not a field in every record")
    t:eq(d.v, nil, "the record version is the file's header now, not 5 bytes per record")
    t:eq(d.altKeys, nil, "altKeys was written by nothing and read by nothing")
    t:eq(d.buildId, "WorkBench", "buildId is kept verbatim: it makes a mangled key repairable")
    t:eq(d.def, "mypack:Bench", "def is identity")
    t:eq(d.state, rec.state, "the state table is the SAME table, not a copy")
    t:type(d.pos, "table")
    t:eq(d.pos[1], -343157, "x rounds to the nearest centimetre")
    t:eq(d.pos[2], 265120, "y rounds to the nearest centimetre")
    t:eq(d.pos[3], 4210, "z rounds to the nearest centimetre")
end)

s:test("a field this build has never heard of survives a rewrite", function(t)
    -- This is what makes `g` (the stable structure id, if building-instanceid-stable settles
    -- in its favour) addable with NO format bump: an unknown field is carried through
    -- dehydrate untouched instead of being silently dropped by a whitelist.
    local d = state.__dehydrate({ buildId = "X", pos = { x = 0, y = 0, z = 0 }, state = {},
                                  g = "A1B2C3D4", somethingLater = { 1, 2 } })
    t:eq(d.g, "A1B2C3D4", "an unknown scalar survives")
    t:type(d.somethingLater, "table", "an unknown table survives")
end)

s:test("hydrate is the exact inverse except pos, pack and v", function(t)
    local rec = { buildId = "X", def = "p:X", pack = "p", v = 2, pos = { x = 1.4, y = -2.6, z = 3.5 },
                  state = { a = 1 }, orphanedAt = 99, why = "missing" }
    local h = state.__hydrate(state.__dehydrate(rec), "p", "X@0,0,0")
    t:eq(h.buildId, rec.buildId)
    t:eq(h.def, rec.def)
    t:eq(h.orphanedAt, 99, "when a record was quarantined survives the round trip")
    t:eq(h.why, "missing", "WHY it was quarantined survives the round trip")
    t:eq(h.state.a, 1)
    t:eq(h.pack, "p", "the pack comes back from the FILE NAME")
    t:eq(h.v, nil, "and the record version does NOT come back: core/event's stampRecord no "
        .. "longer writes or compares one, so a loaded record would carry a field a freshly "
        .. "bound one does not. The shape statement is the document header, and it is "
        .. "dispatched on there")
    t:eq(h.pos.x, 1, "1.4 cm and 1 cm are the same cell at any grid >= 1 cm")
    t:eq(h.pos.y, -3, "rounding is to nearest and correct for negatives")
    t:eq(h.pos.z, 4)
end)

s:test("a record with no buildId is repaired from the key, and a bad key is not fatal", function(t)
    local h = state.__hydrate({ pos = { 1, 2, 3 }, state = {} }, "p", "WorkBench@-3432,2651,42")
    t:eq(h.buildId, "WorkBench", "any two of {key, buildId, pos} reconstruct the third")

    local h2 = state.__hydrate({ buildId = "Keep", state = {} }, "p", "not a key at all")
    t:type(h2, "table", "a key that does not split is NOT a reason to drop a player's record")
    t:eq(h2.buildId, "Keep", "the record's own buildId is left alone")

    local h3 = state.__hydrate({ state = {} }, "p", "also not a key")
    t:type(h3, "table", "neither is a record with nothing to repair FROM")
    t:eq(h3.buildId, nil)
end)

--=============================================================================
-- isolation: one file per mod, and no other file is opened
--=============================================================================

s:test("each mod's records land in that mod's file and nowhere else", function(t)
    withStore(function(fake)
        local w = state.world()
        w.entities["A@1,1,1"] = record("A", "alpha", 100, 100, 100, { n = 1 })
        w.entities["B@2,2,2"] = record("B", "beta", 200, 200, 200, { n = 2 })
        w.entities["C@3,3,3"] = record("C", nil, 300, 300, 300, { n = 3 })
        state.markDirty("alpha"); state.markDirty("beta"); state.markDirty(nil)
        t:truthy(state.flushDirty(), "every dirty pack writes")

        local a = decodeFile(fake, SAVE .. "/alpha")
        local b = decodeFile(fake, SAVE .. "/beta")
        local u = decodeFile(fake, SAVE .. "/_unowned")
        t:eq(countKeys(a.buildings), 1, "alpha's file holds alpha's one record")
        t:truthy(a.buildings["A@1,1,1"], "and it is the right one")
        t:eq(countKeys(b.buildings), 1, "beta's file holds beta's one record")
        t:eq(countKeys(u.buildings), 1, "a record nothing can be attributed to goes to _unowned")
        t:eq(a.palforge.mod, "alpha", "the file says which mod it is, inside the file")
        t:eq(a.palforge.save, SAVE, "and which save, so a copied folder is detectable")
        t:eq(a.palforge.format, state.FORMAT)
        t:eq(a.buildings["A@1,1,1"].pack, nil, "the pack is not repeated inside every record")
    end)
end)

s:test("writing one mod's file reads no other mod's file — an uninstalled pack costs zero",
function(t)
    withStore(function(fake)
        fake.files[SAVE .. "/beta"] = { text = '{"palforge":{"format":3,"mod":"beta","save":"'
            .. SAVE .. '"},"buildings":{}}' }
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1)
        state.markDirty("alpha")
        t:truthy(state.flush("alpha"))
        t:eq(fake.reads[SAVE .. "/beta"], nil,
            "beta's file was never opened: a pack you do not use costs no read, ever")
        t:eq(fake.writes[SAVE .. "/beta"], nil, "and no write")
        t:eq(fake.reads[SAVE .. "/alpha"], 1,
            "alpha's file is read ONCE, before it is replaced — the file is the whole truth "
            .. "for that pack, so its data and ledger sections must not be written as empty")
    end)
end)

s:test("a save that changes under the store writes the OLD world into the OLD folder",
function(t)
    withStore(function(fake)
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1, { n = 1 })
        state.markDirty("alpha")

        -- The world changed without a teardown — a missed world-left, or a save loaded from
        -- inside another. Two things must hold and neither is free: the pending records go to
        -- the directory they BELONG to, and the teardown (which re-enters through flushDirty)
        -- must not recurse.
        local realSaveId = spatial.saveId
        spatial.saveId = function() return "w_SECOND" end
        local ok = pcall(function() return state.world() end)
        spatial.saveId = realSaveId

        t:truthy(ok, "the teardown does not recurse into itself")
        t:truthy(fake.files[SAVE .. "/alpha"],
            "alpha's records were written to the save they describe")
        t:eq(fake.files["w_SECOND/alpha"], nil, "and NOT into the world that was just loaded")
        t:eq(countKeys(state.world().entities), 0, "the new world starts from its own files")
    end)
end)

s:test("a pack's declared version reaches the file header", function(t)
    withStore(function(fake)
        state.storeFor("alpha", "1.2.3")           -- api.pack("alpha", { version = "1.2.3" })
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1)
        state.markDirty("alpha")
        state.flushDirty()
        t:eq(decodeFile(fake, SAVE .. "/alpha").palforge.packVer, "1.2.3",
            "so a state file can say which build of a pack wrote it")
        t:eq(decodeFile(fake, SAVE .. "/alpha").palforge.forge,
            require("palforge.env").version, "beside which build of PalForge did")
    end)
end)

s:test("with nothing to record, no file and no directory are created (F-8)", function(t)
    withStore(function(fake)
        local db = state.storeFor("quiet")
        t:type(db, "table", "building the handle a pack gets opens nothing")
        t:eq(countKeys(fake.files), 0, "storeFor touched no disk")
        state.markDirty("quiet")
        t:truthy(state.flushDirty(), "a dirty pack with nothing in it is not an error")
        t:eq(countKeys(fake.files), 0,
            "and it writes NOTHING: no state file, no save folder, no README")
        t:eq(db.get("anything"), nil, "reading a pack that has no file answers nil")
        t:eq(countKeys(fake.files), 0, "and reading still writes nothing")
    end)
end)

s:test("the first write, and only the first write, leaves the README next to the files",
function(t)
    withStore(function(fake)
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1)
        state.markDirty("alpha")
        state.flushDirty()
        -- support.storeIO keeps writeRaw's output in its own `raw` table, as the STRING that was
        -- written — this suite used to key it into `files` under a "raw:" prefix, which meant
        -- reading a { text = ... } wrapper back out of the same table the JSON documents live in.
        -- Same assertion, one fewer indirection.
        local readme = fake.raw["README.txt"]
        t:type(readme, "string", "a player who opens state/ finds the answer next to the files")
        t:truthy(readme:find("NOT part of Palworld's save", 1, true),
            "and the first thing it says is the thing they are worried about")
        t:truthy(fake.files[SAVE .. "/_save"], "the manifest names the save's packs")
        local man = decodeFile(fake, SAVE .. "/_save")
        t:eq(man.palforge.packs[1], "alpha")
    end)
end)

--=============================================================================
-- refusals — every one of them refuses to WRITE as well as to read
--=============================================================================

s:test("a file that says it belongs to another save is neither read nor written", function(t)
    withStore(function(fake)
        local foreign = '{"palforge":{"format":3,"mod":"logi","save":"w_SOMEONE_ELSE"},'
            .. '"buildings":{"A@1,1,1":{"buildId":"A","pos":[1,1,1],"state":{"keep":true}}}}'
        fake.files[SAVE .. "/logi"] = { text = foreign }

        local ok, why = state.loadPack("logi")
        t:falsy(ok, "a folder that was renamed or copied is detectable, not silently adopted")
        t:truthy(why:find("w_SOMEONE_ELSE", 1, true), "the reason names the id in the file")
        t:truthy(why:find(SAVE, 1, true), "and the id of the folder it is sitting in")
        t:eq(countKeys(state.world().entities), 0, "none of its records were adopted")

        state.world().entities["B@2,2,2"] = record("B", "logi", 2, 2, 2)
        state.markDirty("logi")
        t:falsy(state.flush("logi"), "and it refuses to WRITE, which is the half that matters")
        t:eq(fake.files[SAVE .. "/logi"].text, foreign, "the bytes are exactly as they were")
        t:truthy(state.stats("logi").dirty, "the records stay dirty rather than being dropped")
        t:eq(state.stats("logi").health, "save-mismatch")
    end)
end)

s:test("rebind() is the one-call escape hatch for a world that really was copied", function(t)
    withStore(function(fake)
        fake.files[SAVE .. "/logi"] = { text = '{"palforge":{"format":3,"mod":"logi",'
            .. '"save":"w_SOMEONE_ELSE"},"buildings":{"A@1,1,1":{"buildId":"A","pos":[1,1,1],'
            .. '"state":{"keep":true}}}}' }
        t:falsy(state.loadPack("logi"))
        t:eq(state.rebind(), 1, "one file was adopted")
        local rec = state.world().entities["A@1,1,1"]
        t:type(rec, "table", "its records are in the world now")
        t:eq(rec.state.keep, true, "with their state intact")
        t:truthy(state.flush("logi"), "and it writes again")
        t:eq(decodeFile(fake, SAVE .. "/logi").palforge.save, SAVE,
            "rewritten with THIS save's id, so the mismatch does not come back")
    end)
end)

s:test("a format from the future is left alone rather than truncated by an older writer",
function(t)
    withStore(function(fake)
        local future = '{"palforge":{"format":4,"mod":"logi","save":"' .. SAVE .. '"},'
            .. '"buildings":{"A@1,1,1":{"buildId":"A","pos":[1,1,1],"state":{}}}}'
        fake.files[SAVE .. "/logi"] = { text = future }

        local ok, why = state.loadPack("logi")
        t:falsy(ok, "a shape this build does not know is refused, not guessed at")
        t:truthy(why:find("4", 1, true), "the reason names the format it found")
        t:eq(countKeys(state.world().entities), 0, "the pack has no records this session")

        state.markDirty("logi")
        state.world().entities["B@2,2,2"] = record("B", "logi", 2, 2, 2)
        t:falsy(state.flush("logi"))
        t:eq(fake.files[SAVE .. "/logi"].text, future,
            "and the newer file is untouched — a downgrade must never lose data permanently")
    end)
end)

s:test("a file that will not parse is quarantined verbatim, and only on the next WRITE",
function(t)
    withStore(function(fake)
        local broken = '{"buildings":{"A@1,1,1":{"buildId":"A",'      -- truncated mid-write
        fake.files[SAVE .. "/logi"] = { text = broken }

        local ok = state.loadPack("logi")
        t:falsy(ok, "it cannot be read")
        t:eq(fake.files[SAVE .. "/logi"].text, broken,
            "and NOTHING was written by the read that found it — reads do not write")
        t:eq(state.stats("logi").health, "unparseable")

        state.world().entities["B@2,2,2"] = record("B", "logi", 2, 2, 2)
        state.markDirty("logi")
        t:truthy(state.flush("logi"), "the pack resumes, writing a fresh file")

        local moved, movedText = nil, nil
        for key, f in pairs(fake.files) do
            if key:find(SAVE .. "/_quarantine/", 1, true) then moved, movedText = key, f.text end
        end
        t:truthy(moved, "the unreadable file was moved into _quarantine/")
        t:eq(movedText, broken, "with its bytes unchanged — a re-encoding is not a copy")
        t:truthy(moved:find("_logi", 1, true), "named after the pack it belonged to")
        t:eq(countKeys(decodeFile(fake, SAVE .. "/logi").buildings), 1,
            "and the new file holds this session's record")
    end)
end)

s:test("a write that fails keeps the dirty set and says which pack and why", function(t)
    withStore(function(fake)
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1)
        state.markDirty("alpha")
        fake.failWrite = "the disk is full"

        local ok, err = state.flush("alpha")
        t:falsy(ok, "a flush that could not write must never look like one that did")
        t:truthy(tostring(err):find("disk is full", 1, true), "the reason survives to the caller")
        local st = state.stats("alpha")
        t:truthy(st.dirty, "the pack stays dirty, so the next pump RETRIES it")
        t:truthy(st.lastError, "and the reason is readable afterwards")
        t:eq(st.health, "write-failing")

        fake.failWrite = nil
        t:truthy(state.flushDirty(), "and the retry writes it")
        t:falsy(state.stats("alpha").dirty)
        t:eq(countKeys(decodeFile(fake, SAVE .. "/alpha").buildings), 1,
            "nothing was lost by the failure")
    end)
end)

s:test("a record whose state cannot be saved is skipped, and takes nothing else with it",
function(t)
    withStore(function(fake)
        local w = state.world()
        w.entities["Good@1,1,1"] = record("Good", "alpha", 1, 1, 1, { n = 1 })
        local cyclic = {}
        cyclic.self = cyclic
        w.entities["Bad@2,2,2"] = record("Bad", "alpha", 2, 2, 2, cyclic)
        state.markDirty("alpha")

        t:truthy(state.flush("alpha"), "the pack's flush still succeeds")
        local doc = decodeFile(fake, SAVE .. "/alpha")
        t:truthy(doc.buildings["Good@1,1,1"], "the record that CAN be saved was saved")
        t:eq(doc.buildings["Bad@2,2,2"], nil, "the one that cannot was skipped")
        t:truthy(state.stats("alpha").lastError:find("Bad@2,2,2", 1, true),
            "and the skip names the record, so it is not silent")
    end)
end)

--=============================================================================
-- the value guard
--=============================================================================

s:test("check() refuses the four classes that are SILENTLY lossy", function(t)
    t:truthy(state.check({ a = 1, b = "two", c = { true, false } }), "a plain tree is fine")
    t:truthy(state.check(nil))
    t:truthy(state.check("a string"))

    local cyclic = { a = {} }
    cyclic.a.back = cyclic
    t:falsy(state.check(cyclic), "a cycle would recurse until the stack overflowed")
    t:falsy(state.check({ onDone = function() end }), "a function encodes as null — the field "
        .. "would be GONE with no error at all")
    t:falsy(state.check({ rate = 0 / 0 }), "a NaN encodes as null")
    t:falsy(state.check({ rate = math.huge }), "so does an infinity")
    t:falsy(state.check({ "wood", count = 3 }),
        "an array mixed with named fields LOSES the array half in this tree's encoder")

    local _, path = state.check({ inner = { bad = print } })
    t:truthy(path and path:find("bad", 1, true), "the refusal names the offending field's path")
end)

--=============================================================================
-- the pack handle
--=============================================================================

s:test("the handle a pack gets is memoized, and cannot name another pack's store", function(t)
    withStore(function()
        local db = state.storeFor("alpha")
        t:eq(db, state.storeFor("alpha"), "the same table every time, like api.pack itself")
        t:neq(db, state.storeFor("beta"), "and one per pack")
        t:eq(db.saveId(), SAVE)
        t:truthy(db.path():find("alpha", 1, true), "it can say where its own file is")
    end)
end)

s:test("a pack's own key/value data round-trips through its file", function(t)
    withStore(function(fake)
        local db = state.storeFor("alpha")
        t:truthy(db.set("tutorialSeen", true))
        db.data().launches = (db.data().launches or 0) + 1
        t:truthy(db.save())

        local doc = decodeFile(fake, SAVE .. "/alpha")
        t:eq(doc.data.tutorialSeen, true)
        t:eq(doc.data.launches, 1)
        t:eq(doc.buildings and countKeys(doc.buildings), 0, "and no records were invented")

        state.__reset()
        t:eq(state.storeFor("alpha").get("launches"), 1, "the next session reads it back")
    end)
end)

s:test("set() refuses a value that cannot be saved, at the pack's own call site", function(t)
    withStore(function()
        local db = state.storeFor("alpha")
        local ok, why = db.set("slots", { "wood", count = 3 })
        t:falsy(ok, "the refusal happens NOW, not inside a flush ten minutes later")
        t:truthy(why:find("alpha", 1, true), "and it names the pack")
        t:truthy(why:find("slots", 1, true), "and the key")
        t:eq(db.get("slots"), nil, "nothing was stored")
        t:falsy(db.set("", 1), "an empty key is not a key")
    end)
end)

s:test("building() answers only for records this pack owns", function(t)
    withStore(function()
        local w = state.world()
        w.entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1, { mine = true })
        w.entities["B@2,2,2"] = record("B", "beta", 2, 2, 2, { theirs = true })
        local db = state.storeFor("alpha")
        local st = db.building("A@1,1,1")
        t:type(st, "table")
        t:eq(st, w.entities["A@1,1,1"].state,
            "it is the SAME table as the record's state, so a mutation is written on flush")
        t:eq(db.building("B@2,2,2"), nil, "another pack's structure is not reachable")
        t:eq(db.building({ key = "A@1,1,1" }), st, "an instance is accepted as well as a key")
    end)
end)

s:test("buildings() hands out COPIES, so a pack cannot rewrite the runtime's records",
function(t)
    withStore(function()
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1, { n = 1 })
        local list = state.storeFor("alpha").buildings()
        t:eq(#list, 1)
        list[1].state.n = 999
        list[1].buildId = "hijacked"
        t:eq(state.world().entities["A@1,1,1"].state.n, 1, "the live record is untouched")
        t:eq(state.world().entities["A@1,1,1"].buildId, "A")
    end)
end)

--=============================================================================
-- the ledger and what it can say about an uninstall
--=============================================================================

s:test("the ledger records what the pack made the GAME write, and survives a round trip",
function(t)
    withStore(function(fake)
        t:truthy(state.ledgerAdd("alpha", "item", "alpha_Potion", 5))
        t:truthy(state.ledgerAdd("alpha", "item", "alpha_Potion", 2))
        t:truthy(state.ledgerAdd("alpha", "tech", "alpha_Smelter"))
        t:falsy(state.ledgerAdd("alpha", "waza", "whatever"),
            "an ACTIVE skill is never ledgered: EPalWazaID is a fixed vanilla enum and Lua "
            .. "cannot mint a value, so nothing written there can stop being valid")
        t:truthy(state.flushDirty())

        local doc = decodeFile(fake, SAVE .. "/alpha")
        t:eq(doc.ledger.item.alpha_Potion.n, 7, "the same id aggregates rather than repeating")
        t:truthy(doc.ledger.item.alpha_Potion.at, "with when it last happened")
        t:eq(doc.ledger.tech.alpha_Smelter.n, 1)
    end)
end)

s:test("reclaim() names what it could NOT undo", function(t)
    withStore(function()
        state.ledgerAdd("alpha", "item", "alpha_Potion", 3)
        state.ledgerAdd("alpha", "tech", "alpha_Smelter")
        local rep = state.storeFor("alpha").reclaim()
        t:eq(#rep.entries, 2)
        t:eq(#rep.unreclaimable, 1, "exactly one of the two can never be taken back")
        t:eq(rep.unreclaimable[1].kind, "tech")
        t:truthy(rep.unreclaimable[1].limit:find("no lock", 1, true),
            "and it says why: the cheat manager declares four unlocks and no lock")
        t:truthy(rep.text:find("CANNOT be undone", 1, true),
            "the paragraph a player reads says so too")
        t:falsy(rep.applied, "and nothing was undone by asking")
    end)
end)

--=============================================================================
-- the quarantine, per pack
--=============================================================================

-- ⚠️ THE CAP ITSELF (ORPHAN_MAX) IS core/event.lua's, and test/cases/store_runtime.lua pins
-- it. What belongs here is the property the cap is applied ON TOP OF: a quarantined record
-- is counted, held and written per PACK FILE. Under one shared file the cap counted every
-- pack's quarantine together, so a pack uninstalled for a year could push a neighbour's
-- records over the edge; that is a scope change, and this is the store side of it.
s:test("quarantined records are counted and written per pack, never pooled", function(t)
    withStore(function(fake)
        local w = state.world()
        for i = 1, 5 do
            w.orphans[string.format("A%d@%d,0,0", i, i)] =
                { buildId = "A", pack = "alpha", pos = { x = i, y = 0, z = 0 }, state = {},
                  orphanedAt = 100 - i, why = "unclaimed" }
        end
        w.orphans["B1@9,0,0"] = { buildId = "B", pack = "beta", pos = { x = 9, y = 0, z = 0 },
                                  state = {}, orphanedAt = 1, why = "unclaimed" }
        state.markDirty("alpha"); state.markDirty("beta")
        t:truthy(state.flushDirty())

        t:eq(state.stats("alpha").orphans, 5, "alpha's quarantine holds only alpha's records")
        t:eq(state.stats("beta").orphans, 1, "and beta's only beta's")
        t:eq(countKeys(decodeFile(fake, SAVE .. "/alpha").orphans), 5,
            "each pack's file carries its own quarantine, so each has its own budget")
        t:eq(countKeys(decodeFile(fake, SAVE .. "/beta").orphans), 1)
    end)
end)

s:test("a quarantined record keeps its bytes through a flush and a reload", function(t)
    withStore(function()
        state.world().orphans["A@1,1,1"] = { buildId = "A", pack = "alpha",
            pos = { x = 1, y = 1, z = 1 }, state = { keep = "this" },
            orphanedAt = 1700000000, why = "missing" }
        state.markDirty("alpha")
        t:truthy(state.flushDirty())

        state.__reset()
        t:truthy(state.loadPack("alpha"))
        local rec = state.world().orphans["A@1,1,1"]
        t:type(rec, "table", "a quarantined record comes back as quarantined")
        t:eq(rec.state.keep, "this", "with its state")
        t:eq(rec.orphanedAt, 1700000000, "and when it was quarantined")
        t:eq(rec.why, "missing", "and why")
        t:eq(state.world().entities["A@1,1,1"], nil, "and not as a live record")
    end)
end)

--=============================================================================
-- migration off the single legacy file
--=============================================================================

-- Three throwaway definitions, registered so the migration's tier-2 (def -> owner) and
-- tier-3 (buildId -> the unique definition claiming it) attribution have something to find.
-- Registered and unregistered by hand: these are literal-ish ids outside the
-- "palforge_test:" namespace the suite sweep recognises, so this file gives back what it took.
local MIG_DEFS = {
    { id = "pfs_b:Thing", pack = "pfs_b" },
    { id = "pfs_c:Thing", pack = "pfs_c" },
}

local function registerMigDefs()
    for _, d in ipairs(MIG_DEFS) do
        om.register("building", d.id, { id = d.id }, { pack = d.pack })
    end
end

local function forgetMigDefs()
    for _, d in ipairs(MIG_DEFS) do om.unregister("building", d.id) end
end

local function legacyText()
    -- Written as TEXT, not as a table, for two reasons: the check below asserts the legacy
    -- file is byte-identical afterwards, and the v1 records in every real sample this tree
    -- has (`altKeys`, no `def`, no `pack`) are what a migration actually meets.
    return json.encode({
        version  = 2,
        entities = {
            ["A@1,1,1"] = { buildId = "A", pack = "pfs_a", v = 2,
                            pos = { x = 100.4, y = -200.6, z = 0 }, state = { n = 1 } },
            ["B@2,2,2"] = { buildId = "B", def = "pfs_b:Thing",
                            pos = { x = 1, y = 2, z = 3 }, state = { n = 2 } },
            ["pfs_c_Thing@3,3,3"] = { buildId = "pfs_c_Thing", altKeys = {},
                            pos = { x = 4, y = 5, z = 6 }, state = { n = 3 } },
            ["D@4,4,4"] = { buildId = "nobody_Thing",
                            pos = { x = 7, y = 8, z = 9 }, state = { n = 4 } },
        },
        orphans  = {
            ["E@5,5,5"] = { buildId = "E", pack = "pfs_a", orphanedAt = 1234,
                            pos = { x = 0, y = 0, z = 0 }, state = { n = 5 } },
        },
    })
end

s:test("migration partitions by pack, then def, then the UNIQUE definition claiming a build id",
function(t)
    registerMigDefs()
    withStore(function(fake)
        local original = legacyText()
        fake.files["entities_" .. SAVE] = { text = original }

        local rep = state.migrate()
        t:type(rep, "table", "there was something to migrate")
        t:eq(rep.records, 5, "every record was visited")
        t:eq(rep.added, 5, "and every one of them was kept — nothing is dropped, ever")
        t:eq(rep.packs.pfs_a, 2, "tier 1: the record says which pack it belongs to")
        t:eq(rep.packs.pfs_b, 1, "tier 2: its def is registered and object_manager names the owner")
        t:eq(rep.packs.pfs_c, 1, "tier 3: exactly one registered definition claims that build id")
        t:eq(rep.packs._unowned, 1, "and a build id nobody claims goes to the compatibility bucket")

        local a = decodeFile(fake, SAVE .. "/pfs_a")
        t:eq(countKeys(a.buildings), 1)
        t:eq(countKeys(a.orphans), 1, "a quarantined record migrates as quarantined")
        t:eq(a.orphans["E@5,5,5"].orphanedAt, 1234, "keeping when it was quarantined")
        t:eq(a.orphans["E@5,5,5"].why, "unclaimed", "and gaining WHY, which format 3 records")
        t:eq(a.buildings["A@1,1,1"].state.n, 1, "every state table survives byte for byte")
        t:eq(a.buildings["A@1,1,1"].pos[1], 100, "positions become integer centimetres")
        t:eq(a.buildings["A@1,1,1"].pos[2], -201)
        t:eq(a.buildings["A@1,1,1"].altKeys, nil, "and the dead field goes")

        t:eq(decodeFile(fake, SAVE .. "/pfs_b").buildings["B@2,2,2"].state.n, 2)
        t:eq(decodeFile(fake, SAVE .. "/pfs_c").buildings["pfs_c_Thing@3,3,3"].state.n, 3)
        t:eq(decodeFile(fake, SAVE .. "/_unowned").buildings["D@4,4,4"].buildId, "nobody_Thing",
            "an unattributable record keeps its build id, which is how it is adopted later")

        t:eq(fake.files["entities_" .. SAVE].text, original,
            "AND THE LEGACY FILE IS BYTE-IDENTICAL: not renamed, not deleted, so reverting to "
            .. "an older PalForge means doing nothing")
    end)
    forgetMigDefs()
end)

s:test("migration does not run twice, and a restored backup ADDS rather than replaces",
function(t)
    registerMigDefs()
    withStore(function(fake)
        fake.files["entities_" .. SAVE] = { text = legacyText() }
        t:type(state.migrate(), "table", "the first call migrates")

        local writesAfterFirst = fake.writes[SAVE .. "/pfs_a"]
        state.__reset()
        t:eq(state.migrate(), nil, "the second call is a no-op: the fingerprint matches")
        t:eq(fake.writes[SAVE .. "/pfs_a"], writesAfterFirst, "and it rewrote nothing")

        -- A player restores a backup over the legacy file: it now holds a record the shards
        -- do not. The fingerprint no longer matches, so the MISSING record is added — and the
        -- one that is already there is left exactly as the session left it.
        state.__reset()
        state.loadPack("pfs_a")
        state.world().entities["A@1,1,1"].state.n = 99
        state.markDirty("pfs_a")
        state.flushDirty()

        local restored = json.decode(legacyText())
        restored.entities["F@6,6,6"] = { buildId = "F", pack = "pfs_a",
            pos = { x = 0, y = 0, z = 0 }, state = { n = 6 } }
        fake.files["entities_" .. SAVE] = { text = json.encode(restored) }

        state.__reset()
        local rep = state.migrate()
        t:type(rep, "table", "a legacy file that CHANGED is offered again")
        t:eq(rep.added, 1, "and only the record that was missing is added")
        local a = decodeFile(fake, SAVE .. "/pfs_a")
        t:eq(a.buildings["F@6,6,6"].state.n, 6, "the new record arrived")
        t:eq(a.buildings["A@1,1,1"].state.n, 99,
            "and the live one was NOT rolled back to its migration-time state")
    end)
    forgetMigDefs()
end)

s:test("a legacy file that will not parse stops the migration and is left alone", function(t)
    withStore(function(fake)
        local broken = '{"entities":{"A@1,1,1":'
        fake.files["entities_" .. SAVE] = { text = broken }
        t:eq(state.migrate(), nil, "nothing is migrated out of something that cannot be read")
        t:eq(fake.files["entities_" .. SAVE].text, broken, "and nothing overwrites it")
        t:eq(countKeys(state.world().entities), 0)
    end)
end)

--=============================================================================
-- reporting
--=============================================================================

s:test("diagnose() answers in one paragraph a human can act on", function(t)
    withStore(function()
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1, { n = 1 })
        state.world().orphans["Z@9,9,9"] = { buildId = "logi_PipeSatellite", pack = "alpha",
            pos = { x = 9, y = 9, z = 9 }, state = {}, orphanedAt = 1700000000,
            why = "unclaimed" }
        state.markDirty("alpha")
        state.flushDirty()

        local text = state.diagnose("alpha")
        t:truthy(text:find("alpha", 1, true), "it names the pack")
        t:truthy(text:find(SAVE, 1, true), "and the save")
        t:truthy(text:find("1 structure", 1, true), "and how many structures it holds")
        t:truthy(text:find("Z@9,9,9", 1, true), "and NAMES the quarantined record")
        t:truthy(text:find("logi_PipeSatellite", 1, true), "and the build id nothing claims")
        t:truthy(text:find("Nothing has failed", 1, true))
        t:truthy(text:find("Palworld save itself is untouched", 1, true),
            "and it ends with the sentence this whole design exists to be able to say")
    end)
end)

s:test("audit() enumerates the save's packs without opening their files", function(t)
    withStore(function(fake)
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1)
        state.markDirty("alpha")
        state.flushDirty()
        fake.files[SAVE .. "/ghost"] = { text = '{"palforge":{"format":3,"mod":"ghost","save":"'
            .. SAVE .. '"},"buildings":{}}' }
        -- The manifest is the only way Lua can name a file it has not opened. It is ADVISORY:
        -- nothing on the read path consults it, so it is allowed to be out of date, and here
        -- it is — 'ghost' appeared after it was written and audit() does not invent it.
        local rep = state.audit()
        t:eq(rep.save, SAVE)
        t:truthy(#rep.packs >= 1)
        t:eq(rep.packs[1].pack, "alpha")
        t:eq(fake.reads[SAVE .. "/ghost"], nil, "and no pack's file was opened to answer")
    end)
end)

s:test("uninstall() is the only destructive call, and it says so", function(t)
    withStore(function(fake)
        state.world().entities["A@1,1,1"] = record("A", "alpha", 1, 1, 1)
        state.markDirty("alpha")
        state.flushDirty()
        t:truthy(fake.files[SAVE .. "/alpha"])

        t:truthy(state.uninstall("alpha"))
        t:eq(fake.files[SAVE .. "/alpha"], nil, "the pack's file is gone")
        t:eq(state.world().entities["A@1,1,1"], nil, "and so are its records in memory")
        t:falsy(state.uninstall("alpha"), "a second call has nothing to delete")
    end)
end)

s:test("object_manager.packs() names every pack this session has seen", function(t)
    -- ⚠️ F1 IS PRESSABLE TWICE, and the registry deliberately survives between presses (it is
    -- in core/reload.lua's KEEP). So "the count went up" is decidable on the FIRST press only;
    -- asserting it unconditionally made this suite report one failure on every press after the
    -- first, in a tree whose whole claim is 0 failed. Both directions are pinned instead, and
    -- the second is the stronger statement: a pack already seen is counted once, not twice.
    local before = om.packs()
    local had = false
    for _, p in ipairs(before) do if p == "pfs_seen_here" then had = true end end

    om.withPack("pfs_seen_here", function() end)
    local after = om.packs()

    if had then
        t:eq(#after, #before, "a pack seen again is counted once, not twice")
    else
        t:truthy(#after > #before, "opening a scoped surface is enough to be counted")
    end
    local found = false
    for _, p in ipairs(after) do if p == "pfs_seen_here" then found = true end end
    t:truthy(found, "and the id is in the list")
    for i = 2, #after do
        t:truthy(after[i - 1] < after[i], "the list is sorted, so a store enumerates the same "
            .. "way every session")
    end
end)

return s
