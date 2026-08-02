-- palforge/test/cases/store_codec.lua — the codec and the on-disk backend under the
-- format-3 store.
--
-- This is the layer a player's data physically passes through: utils/json.lua turns a Lua
-- table into the bytes, utils/file/json_file.lua puts those bytes on a disk and gets them back
-- after a crash. Nothing above it can be right if this is wrong, which is why it is the first
-- of the four store suites and why every check below is PURE — it runs identically headless
-- and in a save, and it needs no world, no pawn and no engine.
--
-- ⚠️ IT NEVER WRITES INTO state/. That is not tidiness: F-8 ("reading a native catalog started
-- persisting world state") is held in game by the observable "with no pack registering a
-- Building definition there is no state file at all", and test/cases/store_runtime asserts
-- exactly that a few suites later. A codec test that planted a file — or even created the
-- directory — under state/ would falsify the assertion of a suite that runs after it, in game,
-- on a player's install. So every disk check here runs on a scratch directory in the OS temp
-- directory, through the plain functions json_file exports for the purpose, and removes what
-- it made. If the temp directory cannot be created, those checks SKIP rather than fall back.
--
-- WHAT IS PINNED HERE AND WHY EACH ONE IS PINNED:
--
--   * THE MIXED-KEY ENCODER BUG. `encode({ [1] = "a", x = "b" })` answered {"1":null,"x":"b"}
--     in this tree until this pass — the object branch listed its keys with tostring(k) and
--     then read the value back with the STRING, so t[1] was looked up as t["1"] and came back
--     nil. That is silent loss of a player's data on every save, and the first test below is
--     its regression pin. `state.slots = { "wood", count = 3 }` is that exact shape.
--   * TRAILING INPUT. `decode('{"a":1} garbage')` returned a table and no error, so a torn
--     file with another document's tail on it decoded to something plausible.
--   * THE STRICT-FIRST DECODE. stripComments ran unconditionally over machine-written files
--     that cannot contain a comment; measured here at 8.80 ms of what would otherwise have
--     been a 23.6 ms decode of an 80 KB / 500-record format-3 document — 37%. The pin is that
--     JSONC still decodes, because that is the half a "just make it faster" change breaks.
--   * VALIDATE NAMES THE PATH. A refusal that says "the value cannot be saved" costs a pack
--     author an afternoon; one that says `slots` costs them a line.
--   * THE .bak ROTATION AND THE RECOVERY ORDER. The old write did os.remove(path) and then
--     os.rename(tmp, path), and between those two calls there was NO complete copy of a
--     player's state on disk that anything would ever read — `get` only opened pathFor(key).
--     These checks are the reason the four-step rotation can be claimed rather than believed.
local T       = require("palforge.core.unittests")
local json    = require("palforge.utils.json")
local file    = require("palforge.utils.file")
local backend = require("palforge.utils.file.json_file")

local s = T.suite("store_codec")

local SEP = package.config:sub(1, 1)

-- ---- the scratch directory ----
-- Somewhere that is emphatically NOT state/. TEMP/TMP are what Windows sets (UE4SS is the real
-- target); TMPDIR and /tmp cover the headless run. The name carries a per-process suffix so two
-- processes — or a run beside a still-open editor — cannot collide.
local scratchBase = (os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp")
                        :gsub("[\\/]$", "")
local scratchTag  = string.format("palforge_store_codec_%d_%d",
    os.time(), math.floor((os.clock() * 1000000) % 1000000))

-- ⚠️ THE RUN COUNTER, AND WHY IT IS NOT PARANOIA. F1 IS PRESSABLE TWICE. The directory was
-- originally made ONCE at module load and removed by the teardown, and that combination fails
-- the second press: the module stays loaded, so the name does not change, the teardown has
-- already deleted the directory, and json_file's ensureDir MEMOISES success — so it answers
-- "yes, it is there" without looking and every disk check below dies on io.open. Measured
-- exactly that way (8 failures) the first time this suite was run twice in one process. A fresh
-- name per run is one integer and removes the whole class.
local runNo = 0
local made  = {}   -- every file this run made, so the teardown can take them all back out

local function scratchRoot() return scratchBase .. SEP .. scratchTag .. "_" .. runNo end

-- The scratch directory for this run, created on demand. A check that cannot have one SKIPS
-- rather than falling back to state/ — NEEDS.SESSION is the honest direction, because no
-- session state a tester can get into would change the answer: the finding IS that this process
-- could not make a temp directory.
local function needScratch(t)
    local root = scratchRoot()
    if not backend.ensureDir(root) then
        t:skipUnanswerable("could not create a scratch directory at " .. root
            .. " (os.execute may be unavailable in this session). This suite will NOT fall back "
            .. "to writing into state/ — see the header.")
    end
    return root .. SEP
end

local function scratchPath(t, name)
    local p = needScratch(t) .. name
    made[#made + 1] = p
    made[#made + 1] = p .. ".tmp"
    made[#made + 1] = p .. ".bak"
    return p
end

local function put(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

-- ---- 1. the encoder ----

s:test("an integer key beside a string key keeps its VALUE (the live loss this pass fixed)",
function(t)
    -- The regression pin. Before the fix this encoded to {"1":null,"x":"b"} — the array half
    -- gone, no error, no log line, on every save.
    local text = json.encode({ [1] = "a", x = "b" })
    t:eq(text, '{"1":"a","x":"b"}', "the integer-keyed entry must still carry its value")

    local back = json.decode(text)
    t:type(back, "table")
    t:eq(back["1"], "a", "and it must come back — as the string key \"1\", which is what JSON "
        .. "objects have and why validate refuses the shape at the call site")
    t:eq(back.x, "b")

    -- Same read, same bug: a SPARSE array is not isArray either, so it took the object branch
    -- and lost every element the same way.
    t:eq(json.encode({ [1] = "a", [3] = "b" }), '{"1":"a","3":"b"}',
        "a gapped array must not lose its elements either")
end)

s:test("a real array, an empty table and the scalars are unchanged", function(t)
    t:eq(json.encode({ "a", "b" }), '["a","b"]')
    t:eq(json.encode({}), "{}", "an empty table is an object, which is what a state doc needs")
    t:eq(json.encode({ b = 2, a = 1 }), '{"a":1,"b":2}', "object keys stay sorted, so a diff of "
        .. "two state files is a diff of what changed")
    t:eq(json.encode(1), "1")
    t:eq(json.encode(true), "true")
    t:eq(json.encode("x"), '"x"')
end)

s:test("the encoder stays LENIENT about what it cannot spell", function(t)
    -- Deliberate, and validate is what makes it safe: this runs inside a flush covering a whole
    -- pack's file, and one bad field must not cost the other 499 records. The pack hears about
    -- it from validate, at its own call site, not from a failed flush.
    t:eq(json.encode({ f = print }), '{"f":null}')
    t:eq(json.encode({ n = 0 / 0 }), '{"n":null}')
    t:eq(json.encode({ n = math.huge }), '{"n":null}')
end)

-- ---- 2. the decoder ----

s:test("decode refuses trailing input and says where it is", function(t)
    local v, err = json.decode('{"a":1} garbage')
    t:eq(v, nil, "a document with another document's tail on it is not a value")
    t:type(err, "string")
    t:truthy(err:find("trailing input", 1, true), "the message must name the defect: " .. tostring(err))
    t:truthy(err:find("byte 9", 1, true), "and the byte it starts at: " .. tostring(err))
end)

s:test("decode still reads JSONC through the fallback", function(t)
    local v = json.decode('// a hand-edited file\n{ "a": 1, /* and a block */ "b": [1,2,], }')
    t:type(v, "table", "the strict pass refuses this; the stripComments retry is what reads it")
    t:eq(v.a, 1)
    t:eq(#v.b, 2, "trailing commas survive too")
end)

s:test("the strict path is byte-identical on a machine-written document", function(t)
    -- The optimisation is only allowed to be a speed change. Round-tripping a document with the
    -- SHAPE of a format-3 pack file is how that is stated: same bytes in, same bytes out.
    local doc = {
        palforge = { format = 3, mod = "mypack", save = "w_1DF0E44B4FDDD6196E30819A899C9009",
                     forge = "0.9.0", wrote = 1785646408, buildings = 1 },
        buildings = { ["mypack_Smelter@-3432,2651,42"] = {
            buildId = "mypack_Smelter", def = "mypack:Smelter",
            pos = { -343157, 265120, 4210 }, state = { oreBurned = 10 } } },
        data = { launches = 1, tutorialSeen = true },
        orphans = {},
    }
    local text = json.encode(doc)
    t:truthy(text:find('"pos":[-343157,265120,4210]', 1, true),
        "integer centimetres, as three integers: " .. tostring(text))
    local again = json.encode(json.decode(text))
    t:eq(again, text, "encode(decode(x)) must be x for anything this tree wrote")
end)

s:test("decode refuses a non-string rather than raising", function(t)
    -- It used to call stripComments(text) OUTSIDE the pcall, so json.decode(nil) raised out of
    -- whatever was calling it.
    local v, err = json.decode(nil)
    t:eq(v, nil)
    t:truthy(tostring(err):find("expects a string", 1, true), tostring(err))
end)

-- ---- 3. validate ----

s:test("validate names the PATH of every refusal class", function(t)
    local cases = {
        { name = "cycle",       want = "a.b",
          value = (function() local r = {}; r.a = { b = nil }; r.a.b = r; return r end)(),
          says  = "points back at" },
        { name = "function",    want = "onDone",   value = { onDone = print },
          says  = "is a function" },
        { name = "nan",         want = "rate",     value = { rate = 0 / 0 },
          says  = "not a finite number" },
        { name = "inf",         want = "rate",     value = { rate = -math.huge },
          says  = "not a finite number" },
        { name = "mixed keys",  want = "slots",    value = { slots = { "wood", count = 3 } },
          says  = "mixes array entries with named fields" },
        { name = "array gap",   want = "slots",    value = { slots = { [1] = "a", [3] = "b" } },
          says  = "gap" },
        { name = "key type",    want = "",         value = { [true] = 1 },
          says  = "boolean key" },
    }
    for _, c in ipairs(cases) do
        local ok, path, reason = json.validate(c.value)
        t:falsy(ok, c.name .. " must be refused")
        t:eq(path, c.want, c.name .. ": the path must name the field, got " .. tostring(path))
        t:truthy(tostring(reason):find(c.says, 1, true),
            c.name .. ": the reason must say " .. string.format("%q", c.says)
            .. ", got " .. tostring(reason))
    end
end)

s:test("validate refuses the three limits and reports the number it measured", function(t)
    local L = json.LIMITS

    local deep, cur = {}, nil
    cur = deep
    for _ = 1, L.depth + 4 do cur.n = {}; cur = cur.n end
    local ok, _, reason = json.validate(deep)
    t:falsy(ok, "nesting past the depth limit must be refused")
    t:truthy(tostring(reason):find("nested", 1, true), tostring(reason))

    local wide = {}
    for i = 1, L.fields + 1 do wide["k" .. i] = i end
    local ok2, _, reason2 = json.validate(wide)
    t:falsy(ok2, "more than " .. L.fields .. " fields must be refused")
    t:truthy(tostring(reason2):find("fields", 1, true), tostring(reason2))

    local ok3, _, reason3 = json.validate({ blob = string.rep("x", L.bytes + 4096) })
    t:falsy(ok3, "more than " .. (L.bytes / 1024) .. " KiB encoded must be refused")
    t:truthy(tostring(reason3):find("KiB", 1, true), tostring(reason3))
end)

s:test("validate accepts what a pack really stores, and a DAG is not a cycle", function(t)
    t:truthy(json.validate({ oreBurned = 10, label = "smelter", hot = true, tags = { "a", "b" } }),
        "the shape every state table in this tree has must pass")
    t:truthy(json.validate(nil), "nil is a delete, not a refusal")
    t:truthy(json.validate(42))
    t:truthy(json.validate({}))
    -- The same table referenced twice is NOT a cycle: it encodes twice and decodes into two
    -- tables. Only a table that is its own ancestor is refused, and conflating the two would
    -- refuse a perfectly ordinary shared constant.
    local shared = { x = 1 }
    t:truthy(json.validate({ a = shared, b = shared }), "a DAG must be accepted")
end)

-- ---- 4. the on-disk rotation and the recovery order ----

s:test("two writes leave a .json and a .bak that both parse and differ", function(t)
    local p = scratchPath(t, "rotation.json")

    t:truthy(backend.writeFile(p, '{"n":1}'), "the first write")
    t:eq(backend.readFile(p .. ".bak"), nil, "a first write has nothing to rotate out")
    t:eq(backend.readFile(p .. ".tmp"), nil, "and leaves no .tmp behind")

    t:truthy(backend.writeFile(p, '{"n":2}'), "the second write")
    local cur = json.decode(backend.readFile(p) or "")
    local bak = json.decode(backend.readFile(p .. ".bak") or "")
    t:type(cur, "table", "the .json must parse")
    t:type(bak, "table", "the .bak must parse")
    t:eq(cur.n, 2, "the .json holds the new value")
    t:eq(bak.n, 1, "the .bak holds the PREVIOUS good copy — the whole point of keeping it")
    t:eq(backend.readFile(p .. ".tmp"), nil, "and the .tmp is gone again")
end)

s:test("a partial .tmp beside a good .json is ignored", function(t)
    local p = scratchPath(t, "partial.json")
    put(p, '{"n":7}')
    put(p .. ".tmp", '{"n":8')                     -- truncated: a crash during step 1
    local v, err, kind, from = backend.readDoc(p)
    t:type(v, "table", "the good file must win: " .. tostring(err))
    t:eq(v.n, 7)
    t:eq(kind, nil)
    t:eq(from, "json", ".tmp is only ever consulted when .json is MISSING")
end)

s:test("no .json plus a complete .tmp reads the .tmp (the crash between steps 3 and 4)",
function(t)
    local p = scratchPath(t, "torn.json")
    put(p .. ".tmp", '{"n":9}')
    put(p .. ".bak", '{"n":8}')
    local v, _, _, from = backend.readDoc(p)
    t:type(v, "table")
    t:eq(v.n, 9, "the .tmp is the NEWER copy and is preferred over the .bak")
    t:eq(from, "tmp")
end)

s:test("no .json and an unreadable .tmp falls back to the .bak", function(t)
    local p = scratchPath(t, "fallback.json")
    put(p .. ".tmp", 'not json at all')
    put(p .. ".bak", '{"n":8}')
    local v, _, _, from = backend.readDoc(p)
    t:type(v, "table")
    t:eq(v.n, 8, "only the last flush is lost, not the file")
    t:eq(from, "bak")
end)

s:test("a .json that will not parse is reported CORRUPT and is not called absent", function(t)
    local p = scratchPath(t, "corrupt.json")
    put(p, '{"a": ')
    local v, err, kind = backend.readDoc(p)
    t:eq(v, nil)
    t:eq(kind, "corrupt", "\"absent\" is the one answer that would let the next flush "
        .. "overwrite the only copy, which is failure B")
    t:type(err, "string")

    -- And the literal `null`, which decodes with NO error and is otherwise indistinguishable
    -- from an empty disk.
    put(p, 'null')
    local v2, _, kind2 = backend.readDoc(p)
    t:eq(v2, nil)
    t:eq(kind2, "corrupt")
end)

s:test("nothing on disk at all is ABSENT, and reading it writes nothing", function(t)
    local p = scratchPath(t, "never_written.json")
    local v, err, kind = backend.readDoc(p)
    t:eq(v, nil)
    t:eq(err, nil, "absent is not an error; it is what a pack that never saved anything looks like")
    t:eq(kind, "absent")
    -- The F-8 half, at this layer: a READ may not create anything. If it did, the recovery
    -- path would be a way for a lookup to start persisting world state all over again.
    t:eq(backend.readFile(p), nil, "the read must not have created the .json")
    t:eq(backend.readFile(p .. ".tmp"), nil)
    t:eq(backend.readFile(p .. ".bak"), nil)
end)

s:test("a recovered read does NOT re-commit — the next WRITE does", function(t)
    local p = scratchPath(t, "recommit.json")
    put(p .. ".bak", '{"n":3}')
    local v = backend.readDoc(p)
    t:eq(v and v.n, 3)
    t:eq(backend.readFile(p), nil, "the read repaired nothing on disk, deliberately: 'nothing "
        .. "may write on a READ' is the gate F-8 closed, and a read path that repairs is a "
        .. "read path that can create")
    -- and the write path puts it back where it belongs
    t:truthy(backend.writeFile(p, json.encode(v)))
    local after = json.decode(backend.readFile(p) or "")
    t:eq(after and after.n, 3, "one flush and the next read is normal again")
end)

-- ---- 5. keys are paths now ----

s:test("a key may contain a separator, and may not escape state/", function(t)
    local leaf = file.pathFor("entities_w_ABC")
    t:type(leaf, "string")
    t:truthy(leaf:find("state", 1, true), leaf)

    -- The key carries "/" because core/state composes one string; what lands must carry the
    -- separator THIS OS spells. Asserted on the tail alone — the head is stateDir()'s own
    -- resolved path and whichever separators it happens to contain are not this check's
    -- business.
    local nested = file.pathFor("w_1DF0E44B4FDDD6196E30819A899C9009/logi")
    t:type(nested, "string", "format 3 keys carry one directory level")
    t:truthy(nested:find("w_1DF0E44B4FDDD6196E30819A899C9009" .. SEP .. "logi.json", 1, true),
        "the key's '/' must be spelled " .. string.format("%q", SEP) .. " on disk, got " .. nested)

    for _, bad in ipairs({ "../../evil", "a/../../evil", "/etc/passwd", "C:/windows/x", "..", "" }) do
        local p, why = file.pathFor(bad)
        t:eq(p, nil, string.format("%q must be refused: a key that escapes state/ breaks the "
            .. "removal contract this store exists to keep", bad))
        t:type(why, "string", "and the refusal must say why")
    end
end)

-- ---- 6. the cache leak ----

s:test("forget drops a cached value, and get reads the disk again", function(t)
    -- Entirely in memory: set() stages, it does not write, so this touches no file anywhere.
    -- The leak it pins is real — the backend cache is module-level and had NO eviction, so
    -- core/event's `store.cache = nil` on world-left freed that module's reference while every
    -- record set for every world visited this session stayed here.
    local key = "palforge_store_codec_cache_only"
    file.set(key, { n = 1 })
    local got = file.get(key)
    t:type(got, "table", "a staged value reads back without touching the disk")
    t:eq(got.n, 1)

    t:truthy(file.forget(key), "forget reports that something was cached")
    local after, _, kind = file.get(key)
    t:eq(after, nil, "and afterwards there is nothing but the disk, which has nothing")
    t:eq(kind, "absent")
    t:falsy(file.forget(key), "forgetting twice is a no-op and says so")
end)

-- ---- teardown ----
-- Take the scratch files back out. The directory itself goes too where the platform allows it
-- (POSIX remove() unlinks an empty directory; the Windows CRT's does not, which leaves one
-- empty folder in TEMP and is not worth an os.execute to avoid).
s:after(function()
    for _, p in ipairs(made) do os.remove(p) end
    os.remove(scratchRoot())
    -- A fresh directory name for the next press. See the run-counter note at the top: reusing
    -- the name after this teardown is what made a second F1 report eight failures.
    made, runNo = {}, runNo + 1
end)

return s
