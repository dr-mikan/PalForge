-- palforge/test/cases/store_disk.lua — the format-3 store END TO END, on a REAL FILESYSTEM,
-- against the REAL legacy files this tree has actually produced.
--
-- ---- why this suite exists beside the other four ----
--
-- store_codec pins the codec and the backend primitives; store_state pins core/state against an
-- IN-MEMORY substitute for its I/O table; store_api pins the pack-facing surface; store_runtime
-- pins the building runtime's half. All four are right and all four share one blind spot: NO
-- BYTE EVER REACHES A DISK IN ANY OF THEM. The store's whole promise — "a mod's state is one
-- file, an absent mod loses nothing, a crash mid-write loses nothing, a corrupt file is
-- diagnosed and never overwritten" — is a promise about files, and a fake that stores decoded
-- text in a Lua table cannot break the way a filesystem breaks. This suite drives core/state
-- through its OWN I/O seam pointed at a scratch directory, so every write goes through
-- json_file's four-step .bak rotation, every read goes through its .json -> .tmp -> .bak
-- recovery order, every quarantine is a real os.rename, and every "byte-identical" assertion
-- below is a comparison of bytes that were really on a disk.
--
-- ⚠️ IT STILL NEVER WRITES INTO state/. Same rule, same reason as store_codec: F-8 ("reading a
-- native catalog started persisting world state") is held in game by the observable "with no
-- pack registering a Building definition there is no state file at all", and store_runtime
-- asserts exactly that a suite later, in game, on a player's install. A suite that planted a
-- file — or merely created the directory — under state/ would falsify it. Everything here lives
-- in a per-run, per-case directory under the OS temp directory, and a run that cannot create one
-- SKIPS rather than falling back.
--
-- ---- what is pinned, and which claim each one is ----
--
--   1  ROUND TRIP        write, drop every cache, read back — the same values, through real
--                        bytes a player could open in Notepad.
--   2  ISOLATION         two mod ids writing the same logical key are two files and never see
--                        each other; loading one brings back one.
--   3  MIGRATION         the four REAL pre-format-3 files this tree has produced (their bytes
--                        are embedded verbatim below) migrate whole, keep every key VERBATIM,
--                        and leave the legacy file byte-identical.
--   4  CRASH MID-WRITE   a torn flush leaves the previous version readable — proved by planting
--                        the exact on-disk shapes each interruption leaves behind.
--   5  CORRUPT INPUT     truncated / not-JSON / literal null are each diagnosed in English, the
--                        session survives, the bytes are preserved and then quarantined VERBATIM.
--   6  FUTURE FORMAT     refused rather than misread, AND the file is byte-identical afterwards
--                        — refusing to read is worthless if the next flush truncates it anyway.
--   7  ABSENT PACK       a mod not loaded this session keeps every byte, and gets every record
--                        back next session. This is the removal contract, measured.
--   8  EFFICIENT READ    what is NOT opened. Asserted as a count of real file opens per moment
--                        of the design's own read-path table, not as a timing.
--
-- ---- one hazard this suite shares with store_state and store_api, stated ----
--
-- state.__io(fake) is the right seam and it is a GLOBAL swap. In a LOADED GAME the 10 s flush
-- pump can fire between the swap and the restore, and a real pack's flush would then land in
-- the scratch directory with its dirty flag cleared — a silently lost write. Every swap window
-- below is one test body long and the restore is in a pcall's tail so an assertion cannot skip
-- it, which is as much as a case file can do about it; closing it properly means a lock inside
-- core/state, in a file this suite does not own.
local T       = require("palforge.core.unittests")
local state   = require("palforge.core.state")
local json    = require("palforge.utils.json")
local backend = require("palforge.utils.file.json_file")
local spatial = require("palforge.core.spatial")
local om      = require("palforge.core.object_manager")
local env     = require("palforge.env")

local s = T.suite("store_disk")

local SEP = package.config:sub(1, 1)

--=============================================================================
-- the scratch directory
--=============================================================================

-- TEMP/TMP are what Windows sets (UE4SS is the real target); TMPDIR and /tmp cover the headless
-- run. The tag carries the process time so two processes cannot collide, and the RUN COUNTER is
-- there for the reason store_codec discovered the hard way: F1 IS PRESSABLE TWICE, the module
-- stays loaded between presses, and json_file's ensureDir memoises SUCCESS — so a directory made
-- once at module load and deleted by the teardown is remembered as present on the second press
-- and every io.open after it fails.
local scratchBase = (os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp")
                        :gsub("[\\/]$", "")
local scratchTag  = string.format("palforge_store_disk_%d_%d",
    os.time(), math.floor((os.clock() * 1000000) % 1000000))

local runNo, caseNo = 0, 0
local MADE = {}                      -- every path this run created, for the teardown

local function rootFor() return scratchBase .. SEP .. scratchTag .. "_" .. runNo end

local function needScratch(t)
    local root = rootFor()
    if not backend.ensureDir(root) then
        t:skipUnanswerable("could not create a scratch directory at " .. root
            .. " (os.execute may be unavailable in this session). This suite will NOT fall back "
            .. "to writing into state/ — see the header.")
    end
    return root
end

--=============================================================================
-- a REAL I/O table for core/state, rooted somewhere that is not state/
--=============================================================================
--
-- Same vocabulary as core/state's own IO (keys, and save-relative raw paths), same return
-- shapes — and every operation really touches a disk, through the same json_file primitives the
-- shipping backend uses. What it adds is a COUNTER PER KEY, because half of what this suite
-- asserts is about files that were NOT opened, and "not opened" is not observable from the
-- outside of a store that answers correctly either way.
--
-- ⚠️ IT DELIBERATELY DOES NOT CACHE. json_file keeps a module-level cache in front of get();
-- dropping it here means every read this suite counts is a real file open, which is the number
-- the design's read-path table is actually making a claim about.
local function diskIO(root)
    local io_ = { root = root, reads = {}, writes = {}, opens = 0, files = {} }

    local function pathFor(key)
        return root .. SEP .. (tostring(key):gsub("[\\/]", SEP)) .. ".json"
    end
    io_.pathFor = pathFor

    local function dirOf(p) return p:match("^(.*)[\\/][^\\/]*$") end

    local function remember(p)
        io_.files[p] = true
        MADE[#MADE + 1] = p
        MADE[#MADE + 1] = p .. ".tmp"
        MADE[#MADE + 1] = p .. ".bak"
    end
    io_.remember = remember

    function io_.get(key)
        io_.reads[key] = (io_.reads[key] or 0) + 1
        io_.opens = io_.opens + 1
        local v, err, kind = backend.readDoc(pathFor(key), key)
        if v ~= nil then return v end
        if kind == "absent" then return nil, "absent" end
        return nil, err or "the file would not parse"
    end

    function io_.put(key, value)
        local text, eerr = json.encode(value)
        if not text then return false, tostring(eerr) end
        local path = pathFor(key)
        if not backend.ensureDir(dirOf(path)) then
            return false, "could not create " .. tostring(dirOf(path))
        end
        remember(path)
        local ok, werr = backend.writeFile(path, text)
        if not ok then return false, tostring(werr) end
        io_.writes[key] = (io_.writes[key] or 0) + 1
        return true
    end

    function io_.forget() end

    function io_.bytes(key)
        local f = io.open(pathFor(key), "rb")
        if not f then return nil end
        local n = f:seek("end"); f:close(); return n
    end

    function io_.exists(key)
        local f = io.open(pathFor(key), "rb")
        if f then f:close(); return true end
        return false
    end

    function io_.path(key) return pathFor(key) end

    function io_.moveAside(key, destKey)
        local from, to = pathFor(key), pathFor(destKey)
        local f = io.open(from, "rb"); if not f then return false, "absent" end; f:close()
        backend.ensureDir(dirOf(to))
        remember(to)
        if os.rename(from, to) then return true end
        local text = backend.readFile(from)
        if not text then return false, "unreadable" end
        local ok, why = backend.writeFile(to, text)
        if not ok then return false, tostring(why) end
        os.remove(from)
        return true
    end

    function io_.writeRaw(rel, text)
        local path = root .. SEP .. (rel:gsub("/", SEP))
        backend.ensureDir(dirOf(path))
        remember(path)
        return backend.writeFile(path, text)
    end

    function io_.existsRaw(rel)
        local f = io.open(root .. SEP .. (rel:gsub("/", SEP)), "rb")
        if f then f:close(); return true end
        return false
    end

    function io_.remove(key)
        local path = pathFor(key)
        local f = io.open(path, "rb"); if not f then return false, "absent" end; f:close()
        local ok, err = os.remove(path)
        if not ok then return false, tostring(err) end
        return true
    end

    return io_
end

-- ⚠️ THE MERGED VIEW IS THE LIVE SESSION'S, AND __reset() CLEARS IT IN PLACE.
--
-- state.__reset() is the only way to get a clean slate between checks, and in a LOADED GAME the
-- table it empties is the same one core/event holds every structure's record in — and each
-- record's `state` is the SAME TABLE REFERENCE as the live instance's self.state
-- (core/event.lua's contract, stated at makeInstance). Leaving it empty between tests means the
-- 10 s pump can fire against a world with no records in it.
--
-- So this suite puts it back. The records are restored BY REFERENCE, not by copy, which is the
-- whole point: a copy would give every live instance a `state` table nothing writes to disk any
-- more. It cannot restore S.data / S.ledger / S.loaded — those are not reachable from outside
-- core/state — but those are re-read from disk on next touch, and a record's identity is not.
--
-- (store_state.lua has the same exposure and does not do this; it is called out here rather
-- than fixed there because that file belongs to another slice.)
local function snapshotWorld()
    local w = state.world()
    local snap = { entities = {}, orphans = {}, n = 0 }
    for k, v in pairs(w.entities) do snap.entities[k] = v; snap.n = snap.n + 1 end
    for k, v in pairs(w.orphans)  do snap.orphans[k]  = v; snap.n = snap.n + 1 end
    return snap
end

local function restoreWorld(snap)
    local w = state.world()
    for k in pairs(w.entities) do w.entities[k] = nil end
    for k in pairs(w.orphans)  do w.orphans[k]  = nil end
    for k, v in pairs(snap.entities) do w.entities[k] = v end
    for k, v in pairs(snap.orphans)  do w.orphans[k]  = v end
end

-- Run fn(io, root) with core/state pointed at a fresh scratch directory, and put the real I/O
-- table and the live session's records back whatever happens — including when an assertion
-- raises, whose sentinel is a TABLE and must be re-raised UNCHANGED (error(e, 0)) or the runner
-- reports "table: 0x…" instead of the assertion it was.
local function withDisk(t, fn)
    local base = needScratch(t)
    caseNo = caseNo + 1
    local root = base .. SEP .. string.format("c%02d", caseNo)
    if not backend.ensureDir(root) then
        t:skipUnanswerable("could not create the per-case scratch directory " .. root)
    end
    local live = snapshotWorld()
    local shim = diskIO(root)
    local prev = state.__io(shim)
    state.__reset()
    local ok, e = pcall(fn, shim, root)
    state.__io(prev)
    state.__reset()
    restoreWorld(live)
    if not ok then error(e, 0) end
end

s:after(function()
    for i = #MADE, 1, -1 do pcall(os.remove, MADE[i]) end
    MADE = {}
    runNo = runNo + 1            -- the NEXT press gets its own directory name
end)

--=============================================================================
-- small helpers
--=============================================================================

local function readBytes(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local text = f:read("*a"); f:close(); return text
end

local function writeBytes(path, text, shim)
    local dir = path:match("^(.*)[\\/][^\\/]*$")
    backend.ensureDir(dir)
    if shim then shim.remember(path) else MADE[#MADE + 1] = path end
    local f = assert(io.open(path, "wb"))
    f:write(text); f:close()
end

-- t:eq on two multi-kilobyte strings prints both of them into the log on a mismatch, which is
-- how a one-byte difference becomes unreadable. Compare the length first and then the content,
-- and say only what differs.
local function sameBytes(t, got, want, what)
    t:eq(type(got), "string", what .. ": there are bytes to compare")
    if got == want then t:assert(true, what); return end
    if #got ~= #want then
        t:fail(string.format("%s: %d bytes on disk, %d expected", what, #got or -1, #want))
    end
    for i = 1, #want do
        if got:sub(i, i) ~= want:sub(i, i) then
            t:fail(string.format("%s: same length but byte %d differs (%q vs %q)",
                what, i, got:sub(i, i), want:sub(i, i)))
        end
    end
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function record(buildId, pack, x, y, z, st)
    return { buildId = buildId, pack = pack, pos = { x = x, y = y, z = z }, state = st or {} }
end

--=============================================================================
-- THE REAL LEGACY FILES
--=============================================================================
--
-- Four of them, and these are the bytes, not a reconstruction. They are embedded rather than
-- read from disk because three of the four live outside the repository (a player's install has
-- no _trash-2026-08-02/) and because a byte-identity assertion is only worth making against
-- bytes that cannot drift.
--
-- WHAT THE FOUR ACTUALLY CONTAIN, measured 2026-08-02 by decoding each one:
--
--   sample          records   version   def   pack   orphans   grids used
--   SAVE                  7         1     0      0         0   100
--   MODS                  4         1     0      0         0   100
--   ORPHAN                1         1     0      0         1   100
--   REPO                 18         1     0      0         0   100 (10) and 50 (8)
--
-- ⚠️ 100% OF THEM ARE v1 — not one record in any of the four carries a `def` or a `pack`. That
-- is not an accident of sampling: core/event stamps those only on the first scan that BINDS a
-- record, so a file written by a session that never rebound is entirely unattributed. It is the
-- whole reason the migration has a third attribution tier (buildId -> the unique definition
-- claiming it) and a _unowned bucket that drains later; a migration keyed on `def` would find it
-- absent on exactly the records that most need migrating.
--
-- ⚠️ AND REPO MIXES TWO GRIDS. Its ten ItemChest keys were quantized at GRID_CM = 100 and its
-- eight logi_* keys at 50 (spatial.lua: "Dense entities (pipes) can override"). Recomputing a
-- key from `pos` at the default grid moves every one of those eight — ItemChest@-3534,2720,71
-- and logi_Pipe@-7069,5449,142 describe the same base. That is what makes "the migration copies
-- the key VERBATIM and never recomputes it" a load-bearing property rather than an optimisation:
-- at migration time the definition that chose grid 50 may not be registered at all.

-- state/entities_w_1DF0E44B4FDDD6196E30819A899C9009.json — the real save this tree measures
-- against (1023 bytes, 7 records, WorkBench x6 + PalBoxV2).
local SAMPLE_SAVE = [[{"entities":{"PalBoxV2@-3537,2715,71":{"altKeys":{},"buildId":"PalBoxV2","pos":{"x":-353692.22236157,"y":271460.67526065,"z":7073.1392145986},"state":{}},"WorkBench@-3432,2651,42":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-343156.90282075,"y":265119.81381945,"z":4209.5734589245},"state":{}},"WorkBench@-3487,2787,32":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-348668.58475688,"y":278693.73712543,"z":3236.1681060562},"state":{}},"WorkBench@-3525,2584,40":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-352534.32389612,"y":258393.68598759,"z":3988.486532417},"state":{}},"WorkBench@-3530,2577,40":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-352988.29760852,"y":257702.15549214,"z":3986.486532417},"state":{}},"WorkBench@-3537,2724,71":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-353665.52492283,"y":272392.37489843,"z":7098.4165515709},"state":{}},"WorkBench@-3539,2719,71":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-353882.20119455,"y":271923.39864647,"z":7073.2210219132},"state":{}}},"version":1}]]

-- The same base as it stood a few days earlier, from the UE4SS Mods tree (596 bytes, 4 records).
-- Kept because it is a strict SUBSET of SAMPLE_SAVE's keys, which is what makes it the honest
-- input for "a restored backup ADDS what is missing and replaces nothing".
local SAMPLE_MODS = [[{"entities":{"PalBoxV2@-3537,2715,71":{"altKeys":{},"buildId":"PalBoxV2","pos":{"x":-353692.22236157,"y":271460.67526065,"z":7073.1392145986},"state":{}},"WorkBench@-3487,2787,32":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-348668.58475688,"y":278693.73712543,"z":3236.1681060562},"state":{}},"WorkBench@-3537,2724,71":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-353665.52492283,"y":272392.37489843,"z":7098.4165515709},"state":{}},"WorkBench@-3539,2719,71":{"altKeys":{},"buildId":"WorkBench","pos":{"x":-353882.20119455,"y":271923.39864647,"z":7073.2210219132},"state":{}}},"version":1}]]

-- The only real file with an `orphans` section (160 bytes, 1 record). It carries `orphanedAt`
-- and NO `why`, because `why` did not exist before format 3 — so it is the one input that proves
-- the migration stamps the reason without inventing the date.
local SAMPLE_ORPHAN = [[{"entities":{},"orphans":{"TestBench@1,2,0":{"altKeys":{},"buildId":"TestBench","orphanedAt":1785646408,"pos":{"x":100,"y":200,"z":30},"state":{}}},"version":1}]]

-- dumps/state/entities_world.json — the largest set this tree has ever produced (2874 bytes,
-- 18 records) and the only one with non-empty `state` tables and a pack's own build ids.
local SAMPLE_REPO = [[{"entities":{"ItemChest@-3456,2644,40":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-345561.53224629,"y":264443.68053891,"z":4006.807593216},"state":{"lastWood":0}},"ItemChest@-3534,2720,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-353355.19752153,"y":272024.00289817,"z":7098.5293299143},"state":{"lastWood":0}},"ItemChest@-3534,2724,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-353416.73940425,"y":272364.38834776,"z":7100.1279377369},"state":{"lastWood":0}},"ItemChest@-3535,2728,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-353545.36243935,"y":272783.10300926,"z":7117.3624636618},"state":{"lastWood":0}},"ItemChest@-3536,2719,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-353609.52883749,"y":271863.46770419,"z":7076.2813950233},"state":{"lastWood":0}},"ItemChest@-3538,2725,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-353812.64690351,"y":272499.61611398,"z":7106.808471283},"state":{"lastWood":0}},"ItemChest@-3540,2711,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-353996.67249924,"y":271112.55298601,"z":7075.2210104374},"state":{"lastWood":0}},"ItemChest@-3543,2711,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-354309.25802449,"y":271135.53023281,"z":7077.5397299972},"state":{"lastWood":0}},"ItemChest@-3543,2714,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-354271.44087874,"y":271437.54402729,"z":7077.3117650897},"state":{"lastWood":0}},"ItemChest@-3545,2724,71":{"altKeys":{},"buildId":"ItemChest","pos":{"x":-354487.33857602,"y":272387.78242962,"z":7108.7014846482},"state":{"lastWood":0}},"logi_Pipe@-7069,5449,142":{"altKeys":{},"buildId":"logi_Pipe","pos":{"x":-353454.1943243,"y":272426.47123697,"z":7102.7207669337},"state":{}},"logi_Pipe@-7070,5439,142":{"altKeys":{},"buildId":"logi_Pipe","pos":{"x":-353485.53761043,"y":271945.97767193,"z":7094.9904416735},"state":{}},"logi_Pipe@-7083,5422,141":{"altKeys":{},"buildId":"logi_Pipe","pos":{"x":-354164.25142882,"y":271119.77906668,"z":7073.6636082187},"state":{}},"logi_Pipe@-7083,5449,142":{"altKeys":{},"buildId":"logi_Pipe","pos":{"x":-354142.76358866,"y":272434.32704763,"z":7100.7206354178},"state":{}},"logi_PipeProvider@-7067,5441,142":{"altKeys":{},"buildId":"logi_PipeProvider","pos":{"x":-353365.98595564,"y":272072.44948149,"z":7098.8185575938},"state":{"role":"provider"}},"logi_PipeProvider@-7079,5449,142":{"altKeys":{},"buildId":"logi_PipeProvider","pos":{"x":-353963.74347859,"y":272453.22932088,"z":7100.2139593365},"state":{"role":"provider"}},"logi_PipeRequester@-7070,5452,142":{"altKeys":{},"buildId":"logi_PipeRequester","pos":{"x":-353504.98074287,"y":272583.08176077,"z":7107.4151236142},"state":{"role":"requester"}},"logi_PipeRequester@-7086,5448,142":{"altKeys":{},"buildId":"logi_PipeRequester","pos":{"x":-354317.90535913,"y":272394.42821468,"z":7107.7484451231},"state":{"_diag":40,"role":"requester"}}},"version":1}]]

-- Plant a legacy file at the key core/state will look for it under: "entities_<saveId>", which
-- lands at <root>/entities_world.json in a headless run and at
-- <root>/entities_w_1DF0E44B….json in a save. Returns the path, so a check can read the bytes
-- back afterwards and prove nothing touched them.
local function plantLegacy(shim, text)
    local path = shim.pathFor(state.legacyKey())
    writeBytes(path, text, shim)
    return path
end

-- Definitions registered by hand so the migration's third attribution tier has something to
-- find. They are outside the "palforge_test:" namespace the suite sweep recognises, so every
-- test that registers them unregisters them itself.
local LOGI_DEFS = {
    { id = "pfd_logi:Pipe",      buildIds = { "logi_Pipe" } },
    { id = "pfd_logi:Provider",  buildIds = { "logi_PipeProvider" } },
    { id = "pfd_logi:Requester", buildIds = { "logi_PipeRequester" } },
}

local function registerLogi()
    for _, d in ipairs(LOGI_DEFS) do
        om.register("building", d.id, { id = d.id, buildIds = d.buildIds }, { pack = "pfd_logi" })
    end
end

local function forgetLogi()
    for _, d in ipairs(LOGI_DEFS) do om.unregister("building", d.id) end
end

-- Does a registered definition already claim this build id? The migration's tier 3 is
-- "exactly ONE registered definition claims it", so a suite that asserts "these records land in
-- _unowned" is only right while nothing else claims them. Headless nothing does (measured: zero
-- registered building definitions after native loads). In a game with a real content pack up,
-- something might — and the honest answer then is a SKIP that names the claimer, not a red test
-- that says the store is broken.
local function claimedBy(buildId)
    local hits = {}
    for id, cls in pairs(om.all("building")) do
        local ids = (type(cls) == "table" and type(cls.buildIds) == "table") and cls.buildIds
                    or { (type(cls) == "table" and cls.id) or id }
        for _, bid in ipairs(ids) do
            if (om.resolve(bid) or bid) == buildId then
                local entry = om.entry("building", id)
                hits[#hits + 1] = (entry and entry.pack) or "?"
            end
        end
    end
    return #hits == 1 and hits[1] or nil, #hits
end

local function needUnclaimed(t, ...)
    for _, bid in ipairs({ ... }) do
        local who, n = claimedBy(bid)
        if who or n > 1 then
            t:skipUnanswerable(string.format("the build id %q is already claimed by %s in this "
                .. "session, so the migration will attribute it there instead of to _unowned. "
                .. "That is the store behaving correctly; this check just cannot see it. Run the "
                .. "suite headless, or without that pack, to measure it.", bid,
                who and ("'" .. who .. "'") or (n .. " definitions")))
        end
    end
end

--=============================================================================
-- 0. THE ONE SEAM THIS SUITE OTHERWISE BYPASSES
--=============================================================================
--
-- Everything below runs against a scratch root, which is exactly what keeps a test suite out
-- of a player's saved state — and it means nothing below ever asks the REAL question "where
-- does <save>/<mod> actually land on this install?". core/state composes the key and refuses
-- to know where state/ is; utils/file/json_file resolves state/ from its own module path and
-- refuses to know what a key means. Each half is pinned by its own suite and the JOIN is
-- pinned by neither.
--
-- It is pure — pathFor builds a string and opens nothing — so it costs nothing to close here,
-- and it is the whole of the removal contract's first clause: everything PalForge persists is
-- inside <Mods>/PalForge/.
s:test("a mod id composes into a path under state/, and cannot compose into one outside it",
function(t)
    local file = require("palforge.utils.file")
    local SAVE = state.saveDir()

    local key = state.keyFor("logi")
    t:eq(key, SAVE .. "/logi", "the key is <save>/<mod>, and nothing else")

    local path = file.pathFor(key)
    t:type(path, "string", "and it resolves to a path")
    local want = "state" .. SEP .. SAVE .. SEP .. "logi.json"
    t:truthy(path:sub(-#want) == want, string.format("ending in %q — got %q", want, path))

    -- MEASURED headless, 2026-08-02, from Scripts/:
    --   ./palforge/utils/file/../../../../state/world/logi.json
    -- and that spelling is the guarantee, not an accident of it. The root is walked from
    -- json_file.lua's OWN directory (debug.getinfo(1,"S").source) up four levels to PalForge/
    -- and then into state/ — so it does not depend on the process's working directory, on a
    -- hardcoded string, or on where UE4SS was launched from. It is what makes "everything
    -- PalForge persists is inside <Mods>/PalForge/" structurally true rather than currently
    -- true, and it is the clause the whole removal contract rests on.
    t:truthy(path:find("utils", 1, true) and path:find("file", 1, true),
        "and it is anchored on utils/file/json_file.lua's own location: " .. path)
    t:truthy(path:find("%.%.[\\/]%.%.[\\/]%.%.[\\/]%.%.[\\/]state"),
        "four levels up from that module, then state/ — never a root of its own choosing")

    -- One root for every key, not one per caller.
    local other = file.pathFor(state.keyFor("mypack"))
    t:eq(path:sub(1, #path - #("logi.json")), other:sub(1, #other - #("mypack.json")),
        "every mod's file lands in the same save folder under the same state/")

    -- Neither component CAN carry a separator: spatial.saveId() gsubs [^%w_] to _, and a mod id
    -- is ^[%w_]+$. Both refusals are asserted where they live (store_state, store_codec); what
    -- is asserted here is that the two locks are on the same door.
    for _, bad in ipairs({ "../../evil", "a/b", "C:/evil", "_save" }) do
        t:eq(state.keyFor(bad), nil, string.format("keyFor refuses %q before it becomes a path", bad))
    end
    t:eq(file.pathFor(SAVE .. "/../../evil"), nil,
        "and pathFor refuses it again at the point the path is actually built")
end)

--=============================================================================
-- 1. ROUND TRIP — real bytes, real disk
--=============================================================================

s:test("a mod's whole file round-trips through a real disk", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local w = state.world()
        w.entities["Smelter@-3432,2651,42"] = record("mypack_Smelter", "mypack",
            -343156.90282075, 265119.81381945, 4209.5734589245,
            { oreBurned = 10, label = "north", lit = true, ratio = 0.5 })
        w.orphans["Ghost@1,2,3"] = { buildId = "mypack_Ghost", pack = "mypack",
            pos = { x = 100, y = 200, z = 300 }, state = { kept = "yes" },
            orphanedAt = 1785646408, why = "missing" }
        local db = state.storeFor("mypack", "1.0.0")
        t:truthy(db.set("tutorialSeen", true))
        t:truthy(db.set("launches", 1))
        t:truthy(db.set("nested", { a = { b = { c = "deep" } } }))
        t:truthy(state.ledgerAdd("mypack", "item", "mypack_Potion", 5))
        t:truthy(db.save(), "the flush reported success")

        local path = shim.pathFor(SAVE .. "/mypack")
        local bytes = readBytes(path)
        t:type(bytes, "string", "and there really is a file on the disk")

        -- DROP EVERYTHING. This is the half a fake cannot make honest: the values below come
        -- back out of those bytes and from nowhere else.
        state.__reset()
        t:truthy(state.loadPack("mypack"), "the file reads back")

        local rec = state.world().entities["Smelter@-3432,2651,42"]
        t:type(rec, "table", "the structure record came back")
        t:eq(rec.buildId, "mypack_Smelter")
        t:eq(rec.pack, "mypack", "attributed by the FILE IT WAS IN, not by a field in the record")
        t:eq(rec.state.oreBurned, 10)
        t:eq(rec.state.label, "north")
        t:eq(rec.state.lit, true)
        t:eq(rec.state.ratio, 0.5)
        t:eq(rec.pos.x, -343157, "the position is integer centimetres, rounded to nearest")
        t:eq(rec.pos.y, 265120)
        t:eq(rec.pos.z, 4210)

        local orph = state.world().orphans["Ghost@1,2,3"]
        t:type(orph, "table", "and so did the quarantined one, as quarantined")
        t:eq(orph.state.kept, "yes")
        t:eq(orph.orphanedAt, 1785646408, "with the date it was quarantined")
        t:eq(orph.why, "missing", "and the reason, which is what makes it self-reversing")

        local db2 = state.storeFor("mypack")
        t:eq(db2.get("tutorialSeen"), true)
        t:eq(db2.get("launches"), 1)
        t:eq(db2.get("nested").a.b.c, "deep", "nested tables survive whole")
        t:eq(db2.ledger().item.mypack_Potion.n, 5, "and so does the ledger")
    end)
end)

s:test("the file a player opens is the file the store reads back", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        state.world().entities["Smelter@-3432,2651,42"] = record("mypack_Smelter", "mypack",
            -343156.90282075, 265119.81381945, 4209.5734589245, { oreBurned = 10 })
        state.storeFor("mypack", "1.0.0")
        state.markDirty("mypack")
        t:truthy(state.flushDirty())

        local text = readBytes(shim.pathFor(SAVE .. "/mypack"))
        local doc  = json.decode(text)
        t:type(doc, "table", "the bytes on disk are JSON anything can read")

        t:eq(doc.palforge.format, state.FORMAT, "the shape statement is in the HEADER, once")
        t:eq(doc.palforge.mod, "mypack", "and the mod id is the file's own name AND its header")
        t:eq(doc.palforge.save, SAVE, "and the save it belongs to, so a copied folder is detectable")
        t:eq(doc.palforge.forge, env.version)
        t:eq(doc.palforge.packVer, "1.0.0", "the pack's declared version reaches the file")
        t:eq(doc.palforge.buildings, 1)

        local rec = doc.buildings["Smelter@-3432,2651,42"]
        t:type(rec, "table")
        t:eq(rec.pack, nil, "`pack` is the FILENAME now, not 15 bytes on every record")
        t:eq(rec.v, nil, "`v` is the header now")
        t:eq(rec.altKeys, nil, "and the dead field is gone")
        t:eq(rec.buildId, "mypack_Smelter", "buildId is kept VERBATIM though the key repeats it: "
            .. "any two of {key, buildId, pos} rebuild the third, so a mangled key is repairable")
        t:eq(#rec.pos, 3, "the position is a three-element array")
        t:eq(rec.pos[1], -343157)
        t:eq(math.type(rec.pos[1]), "integer", "of INTEGERS — %.14g on a double described a "
            .. "structure that jitters by more than a metre between scans")

        t:truthy(text:find("mypack_Smelter", 1, true),
            "and the build id is legible in the raw bytes: this tree greps its own state files")
    end)
end)

--=============================================================================
-- 2. PER-MOD ISOLATION
--=============================================================================

s:test("two mods writing the same key are two files and never see each other", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local a = state.storeFor("pfd_alpha")
        local b = state.storeFor("pfd_beta")
        t:truthy(a.set("progress", "ALPHA_ONLY_VALUE"))
        t:truthy(b.set("progress", "BETA_ONLY_VALUE"))
        t:truthy(a.save()); t:truthy(b.save())

        local ta = readBytes(shim.pathFor(SAVE .. "/pfd_alpha"))
        local tb = readBytes(shim.pathFor(SAVE .. "/pfd_beta"))
        t:type(ta, "string", "alpha has its own file")
        t:type(tb, "string", "beta has its own file")
        t:truthy(ta:find("ALPHA_ONLY_VALUE", 1, true))
        t:falsy(ta:find("BETA_ONLY_VALUE", 1, true),
            "and beta's value is nowhere in alpha's bytes — that is the isolation, physically")
        t:truthy(tb:find("BETA_ONLY_VALUE", 1, true))
        t:falsy(tb:find("ALPHA_ONLY_VALUE", 1, true))

        state.__reset()
        t:eq(state.storeFor("pfd_alpha").get("progress"), "ALPHA_ONLY_VALUE",
            "each reads back its own")
        t:eq(state.storeFor("pfd_beta").get("progress"), "BETA_ONLY_VALUE")
    end)
end)

s:test("loading one mod's file brings back one mod's structures", function(t)
    withDisk(t, function()
        local w = state.world()
        w.entities["A@1,1,1"] = record("A", "pfd_alpha", 100, 100, 100, { n = 1 })
        w.entities["B@2,2,2"] = record("B", "pfd_beta", 200, 200, 200, { n = 2 })
        state.markDirty("pfd_alpha"); state.markDirty("pfd_beta")
        t:truthy(state.flushDirty())

        state.__reset()
        t:truthy(state.loadPack("pfd_alpha"))
        t:type(state.world().entities["A@1,1,1"], "table", "alpha's record is in the merged view")
        t:eq(state.world().entities["B@2,2,2"], nil,
            "and beta's is NOT — an unread file contributes nothing, which is the whole point")
        t:falsy(state.isLoaded("pfd_beta"))

        t:truthy(state.loadPack("pfd_beta"))
        t:type(state.world().entities["B@2,2,2"], "table", "and arrives when it is asked for")
        t:eq(state.world().entities["B@2,2,2"].state.n, 2)
    end)
end)

--=============================================================================
-- 3. MIGRATION — off the REAL legacy files
--=============================================================================
--
-- ⚠️ EVERY CHECK IN THIS SECTION CALLS state.migrate() ITSELF, BECAUSE NOTHING ELSE IN THE TREE
-- DOES. Measured 2026-08-02 by grep over Scripts/ with test/ excluded: M.migrate is DEFINED at
-- core/state.lua:1054 and CALLED from nowhere. Every other `migrate` hit outside test/ is a
-- comment, or core/event's tryMigrate — which is the unrelated definition-rename path.
--
-- So the migration is complete, correct against all four real files (that is what the checks
-- below establish) and UNREACHABLE. A player upgrading to format 3 today gets an empty store
-- while their 7-18 records sit in entities_<save>.json — which is not data LOSS, since the
-- design's central promise is that the legacy file is never touched, but it is the whole
-- migration not running.
--
-- The call belongs at the first world.ready for a save, which is core/event.lua's gate — a file
-- this suite does not own, and a slice that was given "the §8 migration" (core/state) and "the
-- world-ready path" (core/event) as two separate assignments with the join named in neither.
-- These checks are written so that the day the call is added, nothing about them has to change.

s:test("the real 7-record save file migrates whole, and its bytes are untouched", function(t)
    needUnclaimed(t, "WorkBench", "PalBoxV2")
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local path = plantLegacy(shim, SAMPLE_SAVE)

        local rep = state.migrate()
        t:type(rep, "table", "there was something to migrate")
        t:eq(rep.records, 7, "every record in the real file was visited")
        t:eq(rep.added, 7, "and every one of them was kept — nothing is dropped, ever")
        t:eq(rep.unowned, 7, "all seven are unattributable, because 100% of the real samples "
            .. "are v1: no `def` and no `pack` on any record")
        t:eq(rep.fingerprintOf, "bytes", "and the fingerprint was taken off the real bytes")

        local doc = json.decode(readBytes(shim.pathFor(SAVE .. "/_unowned")))
        t:eq(countKeys(doc.buildings), 7)
        local rec = doc.buildings["WorkBench@-3432,2651,42"]
        t:type(rec, "table", "keyed exactly as the legacy file keyed it")
        t:eq(rec.buildId, "WorkBench", "with the build id intact, which is how it is adopted later")
        t:eq(rec.pos[1], -343157, "and the position quantized to integer centimetres")
        t:eq(rec.altKeys, nil, "the dead field is dropped on the way through")

        sameBytes(t, readBytes(path), SAMPLE_SAVE,
            "THE LEGACY FILE IS BYTE-IDENTICAL — not renamed, not deleted, so reverting to an "
            .. "older PalForge means doing nothing")
    end)
end)

s:test("the real 18-record file keeps every key VERBATIM, at two different grids", function(t)
    registerLogi()
    local ok, e = pcall(function()
        needUnclaimed(t, "ItemChest")
        withDisk(t, function(shim)
            local SAVE = state.saveDir()
            plantLegacy(shim, SAMPLE_REPO)

            local rep = state.migrate()
            t:eq(rep.records, 18, "every record in the largest real set")
            t:eq(rep.added, 18)
            t:eq(rep.packs.pfd_logi, 8, "tier 3: the eight logi_* records go to the one pack "
                .. "whose definitions claim those build ids — and NOT because they say so, "
                .. "because nothing in the file says anything")
            t:eq(rep.packs._unowned, 10, "and the ten ItemChest records nobody claims wait in "
                .. "the compatibility bucket, keeping their build id")

            local logi = json.decode(readBytes(shim.pathFor(SAVE .. "/pfd_logi")))
            local un   = json.decode(readBytes(shim.pathFor(SAVE .. "/_unowned")))

            -- THE KEY IS COPIED, NEVER RECOMPUTED. Eight of these were quantized at grid 50 by
            -- a definition that is not necessarily registered when a migration runs; the other
            -- ten at 100. A migration that rebuilt keys from `pos` at the default grid would
            -- move all eight to a key no live actor produces, and the scan would then bind a
            -- SECOND record for each and quarantine the first.
            local moved = 0
            for _, src in ipairs({ json.decode(SAMPLE_REPO).entities }) do
                for key, old in pairs(src) do
                    local now = logi.buildings[key] or un.buildings[key]
                    t:type(now, "table", "the key '" .. key .. "' survived verbatim")
                    t:eq(now.buildId, old.buildId)
                    if spatial.posKey(old.buildId, old.pos) ~= key then moved = moved + 1 end
                end
            end
            t:eq(moved, 8, "and eight of them do NOT reproduce their key at the default grid, "
                .. "which is exactly why the migration must not try")

            t:eq(logi.buildings["logi_PipeRequester@-7086,5448,142"].state._diag, 40,
                "every state table came through, including the diagnostic field")
            t:eq(logi.buildings["logi_PipeProvider@-7067,5441,142"].state.role, "provider")
            t:eq(un.buildings["ItemChest@-3456,2644,40"].state.lastWood, 0)
        end)
    end)
    forgetLogi()
    if not ok then error(e, 0) end
end)

s:test("the real orphan sample migrates as quarantined and gains its reason", function(t)
    needUnclaimed(t, "TestBench")
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        plantLegacy(shim, SAMPLE_ORPHAN)

        local rep = state.migrate()
        t:eq(rep.records, 1)
        t:eq(rep.orphans, 1, "the one real file with an orphans section migrates it as one")

        local doc = json.decode(readBytes(shim.pathFor(SAVE .. "/_unowned")))
        t:eq(countKeys(doc.buildings), 0, "a quarantined record does not come back as a live one")
        local rec = doc.orphans["TestBench@1,2,0"]
        t:type(rec, "table")
        t:eq(rec.orphanedAt, 1785646408, "the date it was quarantined is preserved, not restamped")
        t:eq(rec.why, "unclaimed", "and `why` — which did not exist before format 3 — is stamped")
    end)
end)

s:test("migrating the same real file twice is a no-op, and a restored backup only ADDS",
function(t)
    needUnclaimed(t, "WorkBench", "PalBoxV2")
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local path = plantLegacy(shim, SAMPLE_SAVE)
        t:type(state.migrate(), "table", "the first call migrates")
        local firstWrites = shim.writes[SAVE .. "/_unowned"]
        t:truthy(firstWrites and firstWrites > 0)

        state.__reset()
        t:eq(state.migrate(), nil, "the second call is a no-op: the fingerprint matches the bytes")
        t:eq(shim.writes[SAVE .. "/_unowned"], firstWrites, "and it rewrote nothing")

        -- A session moves a record on, then the player restores an OLDER backup over the legacy
        -- file. SAMPLE_MODS is a strict subset of SAMPLE_SAVE's keys, so the only correct
        -- outcome is: nothing is added, and the live edit is NOT rolled back.
        state.__reset()
        state.loadPack("_unowned")
        state.world().entities["WorkBench@-3432,2651,42"].state.touched = "by the session"
        state.markDirty("_unowned")
        t:truthy(state.flushDirty())

        writeBytes(path, SAMPLE_MODS, shim)
        state.__reset()
        local rep = state.migrate()
        t:type(rep, "table", "a legacy file whose bytes CHANGED is offered again")
        t:eq(rep.records, 4, "the restored file's four records are all visited")
        t:eq(rep.added, 0, "and none is added, because every key is already there")

        local doc = json.decode(readBytes(shim.pathFor(SAVE .. "/_unowned")))
        t:eq(doc.buildings["WorkBench@-3432,2651,42"].state.touched, "by the session",
            "the live record was NOT rolled back to its migration-time state")
        t:eq(countKeys(doc.buildings), 7, "and the three records the backup does not have are "
            .. "still there — a restore adds, it never replaces")
    end)
end)

-- ⚠️ THE ONE-SHOT MARKER IS DERIVED FROM THE FILE'S BYTES, and nothing else in the tree says so.
--
-- MEASURED: replacing fingerprint()'s whole body with a constant leaves all 96 checks in the
-- five store suites green, because every one of them tests the marker's EFFECT ("a second call
-- is a no-op", "a changed file is offered again") and an effect can be produced by a constant
-- plus a second bug. This check tests the VALUE, so the derivation cannot be hollowed out
-- underneath the behaviour.
--
-- It is size + record count + the first 24 bytes, and core/state says in as many words that it
-- is NOT A HASH. That is the right call — a hash of a 26 KB file on every world load buys
-- nothing over three cheap facts — but it means the derivation is the whole guarantee, and a
-- guarantee nobody asserts is a comment.
s:test("the migration's one-shot marker is derived from the legacy file's own bytes", function(t)
    needUnclaimed(t, "WorkBench", "PalBoxV2")
    withDisk(t, function(shim)
        local path = plantLegacy(shim, SAMPLE_SAVE)
        t:type(state.migrate(), "table")

        local mark = state.audit().migrated
        t:type(mark, "table", "the migration left a marker")
        t:eq(mark.records, 7, "recording how many records it took")
        t:eq(mark.bytes, #SAMPLE_SAVE, "and how big the file was — 1023 bytes, measured")
        t:eq(mark.fingerprintOf, "bytes", "taken off the real bytes, not off a re-encoding")
        t:eq(mark.fingerprint, string.format("%d:%d:%s", #SAMPLE_SAVE, 7, SAMPLE_SAVE:sub(1, 24)),
            "and the fingerprint IS size + record count + the first 24 bytes, in that order")

        -- Change one byte of state deep inside the file: the size and the count are identical
        -- and the head is identical, so this is the case the fingerprint is WEAKEST against.
        -- It is still the right trade — see the comment above — but the test should say which
        -- change it can see and which it cannot, rather than implying it sees all of them.
        local twiddled = SAMPLE_SAVE:gsub('"WorkBench@%-3432,2651,42"', '"WorkBench@-3432,2651,43"', 1)
        t:eq(#twiddled, #SAMPLE_SAVE, "the edited file is the same size and has the same count")
        writeBytes(path, twiddled, shim)
        state.__reset()
        t:eq(state.migrate(), nil,
            "so the fingerprint does NOT see it, and the migration correctly declines to run "
            .. "again — the guarantee is 'is this the same file I read before', not 'has any "
            .. "byte changed'")

        -- What it DOES see: a file that grew or shrank, or gained or lost a record.
        writeBytes(path, SAMPLE_MODS, shim)
        state.__reset()
        t:type(state.migrate(), "table", "a file of a different size and count IS seen")
    end)
end)

-- ⚠️ A REAL DEFECT, FOUND BY THIS SUITE AND SINCE FIXED. THIS IS ITS REGRESSION PIN, and the
-- scenario is kept in full because the cost of getting it wrong again is a player's buildings.
--
-- WHAT IT WAS. writeManifest() wrote `migrated = S.migrated`, and S.migrated was populated in
-- exactly two places, both inside migrate(). flush() calls writeManifest() on every successful
-- write, so every session that did not migrate anything wrote `migrated = nil` over a marker
-- that was correct. The live route in was migrate()'s own early return: when the legacy file is
-- absent it returns BEFORE reading the manifest, so S.migrated stayed nil for that whole
-- session — and the legacy file is never deleted, so it is not absent for long.
--
-- MEASURED, three sessions against a real disk, before the fix:
--   1  migrate() runs, _save.json holds  migrated.fingerprint = "200:2:{"entities":{"A@1,1,1":{"
--   2  the player dismantles a structure; core/event drops the record and flushes.
--      _save.json now holds  migrated = nil
--   3  migrate() runs again — the fingerprint is gone, so it re-runs — and the record THE
--      PLAYER REMOVED comes back out of the legacy file as a live record.
--
-- THE FIX is core/state.lua's migratedBlock(): the marker is read back from the manifest once
-- per save when this session did not produce one, so writeManifest can never drop a block it
-- simply never loaded. All three sessions below now behave, and session 3 is the one that
-- matters — a dismantled structure stays dismantled.
s:test("the migration marker survives a flush in a session that never called migrate()",
function(t)
    needUnclaimed(t, "WorkBench", "PalBoxV2")
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        plantLegacy(shim, SAMPLE_SAVE)
        t:type(state.migrate(), "table", "session 1: it migrates")
        local man = json.decode(readBytes(shim.pathFor(SAVE .. "/_save")))
        t:type(man.palforge.migrated, "table", "and the marker is in the manifest")
        local fp0 = man.palforge.migrated.fingerprint

        -- Session 2: the player dismantles a structure and the pack flushes. Nothing in this
        -- session ever calls migrate().
        state.__reset()
        state.loadPack("_unowned")
        t:type(state.world().entities["WorkBench@-3432,2651,42"], "table")
        state.world().entities["WorkBench@-3432,2651,42"] = nil
        state.markDirty("_unowned")
        t:truthy(state.flushDirty())

        man = json.decode(readBytes(shim.pathFor(SAVE .. "/_save")))
        t:type(man.palforge.migrated, "table",
            "THE MARKER IS STILL THERE. writeManifest asked for it rather than assuming this "
            .. "session had loaded it. See the comment above this test.")
        t:eq(man.palforge.migrated.fingerprint, fp0,
            "and it is the same marker, not a fresh one describing a different file")

        -- Session 3: so the migration does NOT run again, and nothing is resurrected.
        state.__reset()
        t:eq(state.migrate(), nil,
            "session 3: the migration does not run a second time on the same file")
        state.__reset()
        state.loadPack("_unowned")
        t:eq(state.world().entities["WorkBench@-3432,2651,42"], nil,
            "a structure the player dismantled stays dismantled — which is what the marker "
            .. "is for, and what its erasure used to cost")
    end)
end)

-- ⚠️ THIS ONE CORRECTS A CLAIM THE DESIGN MAKES, and it is the only place in the five store
-- suites that measures it.
--
-- core/state.lua says, at hydrate: "Integer cm preserves cellOf exactly for any gridCm >= 1."
-- MEASURED over all 30 records in the four real samples, at grids {1, 10, 25, 50, 100, 250,
-- 1000}: it is TRUE at every grid the real data was written with (100, and 50 for the pipes)
-- and FALSE at two others — three records move one cell at grid 10, and one at grid 1000. All
-- four are in the 18-record REPO sample; the other three files are clean at every grid tried.
--
-- The mechanism is not a rounding error, it is an exact boundary: cellOf is floor(v/g + 0.5),
-- so a position whose quantized value lands on x.0 after that shift falls to the other side.
--   ItemChest@-3534,2720,71  x = -353355.19752153
--     grid 10, raw:        floor(-35335.519752153 + 0.5) = floor(-35335.019752153) = -35336
--     grid 10, integer cm: floor(-35335.5         + 0.5) = floor(-35335.0)         = -35335
--
-- WHY IT IS NOT A BUG TODAY, and what would make it one: `rec.pos` has exactly ONE reader in
-- the live tree — core/event's tryMigrate, which recomputes a key when a definition is renamed —
-- and every other consumer takes the LIVE actor's position. So the blast radius is one record,
-- one rename, at a grid nothing currently uses. It becomes real the moment a pack picks a
-- gridCm that is not a divisor-friendly 50 or 100 AND renames a definition. The honest sentence
-- is "integer centimetres preserve the cell at every grid this tree has shipped", and this
-- check is what lets that be said rather than believed.
s:test("integer centimetres keep every real record's cell at the shipped grids", function(t)
    local function cm(v) return math.floor(v + 0.5) end
    local total, movedAt = 0, {}
    for _, text in ipairs({ SAMPLE_SAVE, SAMPLE_MODS, SAMPLE_ORPHAN, SAMPLE_REPO }) do
        local doc = json.decode(text)
        for _, src in ipairs({ doc.entities or {}, doc.orphans or {} }) do
            for _, rec in pairs(src) do
                total = total + 1
                local q = { x = cm(rec.pos.x), y = cm(rec.pos.y), z = cm(rec.pos.z) }
                for _, g in ipairs({ 1, 10, 25, 50, 100, 250, 1000 }) do
                    if spatial.posKey(rec.buildId, rec.pos, g)
                       ~= spatial.posKey(rec.buildId, q, g) then
                        movedAt[g] = (movedAt[g] or 0) + 1
                    end
                end
            end
        end
    end
    t:eq(total, 30, "the four real samples hold thirty records between them")
    t:eq(movedAt[100], nil, "not one moves at GRID_CM = 100, the shipped default")
    t:eq(movedAt[50], nil, "nor at 50, the grid the pipe definitions use")
    t:eq(movedAt[1], nil, "nor at 1, where quantization is the identity")
    t:eq(movedAt[10], 3, "but three DO move at grid 10 — see the comment above this test: the "
        .. "claim 'exactly for any gridCm >= 1' is false at an exact cell boundary")
    t:eq(movedAt[1000], 1, "and one at grid 1000")
end)

s:test("a legacy file that will not parse stops the migration and is left alone", function(t)
    withDisk(t, function(shim)
        local broken = SAMPLE_SAVE:sub(1, 400)          -- a real file, torn in half
        local path = plantLegacy(shim, broken)
        t:eq(state.migrate(), nil, "nothing is migrated out of something that cannot be read")
        sameBytes(t, readBytes(path), broken, "and nothing overwrites it")
        t:eq(countKeys(state.world().entities), 0, "and no half-record leaks into the world view")
    end)
end)

--=============================================================================
-- 4. A CRASH MID-WRITE
--=============================================================================
--
-- The four-step rotation (json_file.writeFile) is: write <f>.tmp; remove <f>.bak;
-- rename <f> -> <f>.bak; rename <f>.tmp -> <f>. The checks below plant the exact on-disk shape
-- each interruption leaves and then ask the STORE — not the backend — what a player gets back.
-- store_codec proves the backend picks the right file; this proves the store's records survive
-- the trip, which is the sentence a player cares about.

s:test("a crash while writing leaves the completed previous version readable", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        state.world().entities["A@1,1,1"] = record("A", "pfd_alpha", 100, 100, 100, { n = 1 })
        state.markDirty("pfd_alpha")
        t:truthy(state.flushDirty(), "flush 1")

        state.world().entities["A@1,1,1"].state.n = 2
        state.markDirty("pfd_alpha")
        t:truthy(state.flushDirty(), "flush 2 — now .json holds n=2 and .bak holds n=1")

        local path = shim.pathFor(SAVE .. "/pfd_alpha")
        t:type(readBytes(path .. ".bak"), "string", "the rotation really left a .bak behind")

        -- The interruption: a partial .tmp beside a good .json. This is by far the common
        -- case — a crash during step 1 — and the good file must win.
        writeBytes(path .. ".tmp", '{"buildings":{"A@1,1,1":{"buildId":"A","pos":[1', shim)
        state.__reset()
        t:truthy(state.loadPack("pfd_alpha"))
        t:eq(state.world().entities["A@1,1,1"].state.n, 2,
            "a partial .tmp beside a good .json is ignored: .tmp is only consulted when the "
            .. ".json is MISSING")

        -- Now the bad one: the .json is gone AND the .tmp is unreadable. The .bak is the last
        -- complete copy and it is the previous flush — one flush lost, nothing else.
        os.remove(path)
        state.__reset()
        t:truthy(state.loadPack("pfd_alpha"))
        t:eq(state.world().entities["A@1,1,1"].state.n, 1,
            "the .bak answers, so the loss is bounded at ONE flush rather than the session")
    end)
end)

s:test("a crash between the rotation's last two steps loses nothing at all", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        state.world().entities["A@1,1,1"] = record("A", "pfd_alpha", 100, 100, 100, { n = 7 })
        state.markDirty("pfd_alpha")
        t:truthy(state.flushDirty())

        -- Step 3 has run (the old file is at .bak), step 4 has not (the new one is still .tmp).
        local path = shim.pathFor(SAVE .. "/pfd_alpha")
        local good = readBytes(path)
        writeBytes(path .. ".tmp", good, shim)
        os.remove(path)
        t:eq(readBytes(path), nil, "there is no .json on disk at this instant")

        state.__reset()
        t:truthy(state.loadPack("pfd_alpha"), "and the store still reads")
        t:eq(state.world().entities["A@1,1,1"].state.n, 7,
            "from the complete .tmp — the write that was interrupted is the one that survives")

        -- And the recovered value is laid back down by the next WRITE, never by the read. A
        -- read path that repairs is a read path that can create, and F-8 is the gate that
        -- closed.
        t:eq(readBytes(path), nil, "the read did NOT re-commit anything")
        state.markDirty("pfd_alpha")
        t:truthy(state.flushDirty())
        t:type(readBytes(path), "string", "the next flush is what puts it back")
    end)
end)

--=============================================================================
-- 5. CORRUPT INPUT — diagnosed in English, and never overwritten
--=============================================================================

s:test("truncated, not-JSON and literal-null files are each diagnosed and none takes the "
    .. "session down", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local shapes = {
            { pack = "pfd_trunc", bytes = '{"palforge":{"format":3,"mod":"pfd_trunc"},"buildi' },
            { pack = "pfd_text",  bytes = "PalForge state file\r\nthis is not JSON at all\r\n" },
            { pack = "pfd_null",  bytes = "null" },
            { pack = "pfd_empty", bytes = "" },
        }
        for _, sh in ipairs(shapes) do
            writeBytes(shim.pathFor(SAVE .. "/" .. sh.pack), sh.bytes, shim)
        end

        for _, sh in ipairs(shapes) do
            local ok, err = state.loadPack(sh.pack)
            t:falsy(ok, sh.pack .. ": a file that cannot be read is a REFUSAL, not a silent zero")
            t:type(err, "string", sh.pack .. ": and it says why, in words")
            t:eq(state.stats(sh.pack).health, "unparseable",
                sh.pack .. ": and the health says so rather than 'ok'")

            local text = state.diagnose(sh.pack)
            t:type(text, "string")
            t:truthy(text:find(sh.pack, 1, true), sh.pack .. ": the paragraph names the pack")
            t:truthy(text:find(SAVE, 1, true), sh.pack .. ": and the save")
            t:truthy(text:find("Palworld save itself is untouched", 1, true),
                sh.pack .. ": and ends with the sentence this whole design exists to be able to "
                .. "say — which is the one a player wants at the moment a file is broken")
        end

        -- THE SESSION SURVIVES. A neighbouring pack loads and flushes normally while all four
        -- broken files sit on the disk beside it.
        state.world().entities["A@1,1,1"] = record("A", "pfd_ok", 100, 100, 100, { n = 1 })
        state.markDirty("pfd_ok")
        t:truthy(state.flushDirty(), "a healthy pack still writes with four broken files beside it")
        t:eq(state.stats("pfd_ok").health, "ok")
    end)
end)

s:test("unreadable bytes are kept until a write, then moved to _quarantine VERBATIM", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local path = shim.pathFor(SAVE .. "/pfd_broken")
        local broken = '{"palforge":{"format":3,"mod":"pfd_broken"},"buildings":{"A@1,1,1":{"bu'
        writeBytes(path, broken, shim)

        t:falsy(state.loadPack("pfd_broken"), "it is refused")
        sameBytes(t, readBytes(path), broken,
            "AND THE BYTES ARE STILL THERE — nothing may write on a read, so the move aside is "
            .. "the next WRITE's job, not this one's")

        state.world().entities["B@2,2,2"] = record("B", "pfd_broken", 200, 200, 200, { n = 2 })
        state.markDirty("pfd_broken")
        t:truthy(state.flushDirty(), "the pack resumes and writes a fresh file")

        t:type(readBytes(path), "string", "there is a file at the name again")
        t:type(json.decode(readBytes(path)), "table", "and this one parses")
        t:eq(json.decode(readBytes(path)).buildings["B@2,2,2"].state.n, 2)

        -- Find what landed in _quarantine/. Lua cannot list a directory, so the check asks the
        -- shim which paths it created — the same question, answered honestly.
        local found, foundPath = nil, nil
        for p in pairs(shim.files) do
            if p:find("_quarantine", 1, true) then foundPath = p; found = readBytes(p) end
        end
        t:type(foundPath, "string", "a quarantine file was created")
        t:truthy(foundPath:find("pfd_broken", 1, true), "named after the pack it came from")
        sameBytes(t, found, broken,
            "and holding the ORIGINAL BYTES, byte for byte — a re-encoding of something that "
            .. "could not be decoded is not a copy of it")
    end)
end)

-- ⚠️ THE SHAPE THE QUARANTINE USED TO MISS, FOUND BY THIS SUITE AND SINCE CLOSED.
--
-- "A file that will not PARSE is never overwritten" was exactly true, and the gap was the word
-- `parse`: a file that parsed to valid JSON of the WRONG SHAPE — an array, an object with no
-- `palforge` header, or a bare scalar — was accepted as an empty document, reported itself
-- healthy, and was REPLACED by the next flush with no quarantine copy. loadPack's only
-- structural test was `type(doc) == "table"`, and for a scalar not even that: `42` decodes
-- cleanly, so IO.get returned it with no error and the "is there a file at all" test — which
-- looked at the error rather than at the value — read it as an absent file.
--
-- How a player reached it: an editor that saved `[]`, a half-merged file, a sync tool that
-- wrote a placeholder, a config dropped into the wrong folder. Real bytes, lost without a copy.
--
-- CLOSED IN loadPack by two conditions: a document must carry the `palforge` header that
-- flush() writes unconditionally, and "there is no file" is now `doc == nil` rather than "no
-- error was reported". Both refusals route into the SAME quarantine the unparseable case uses,
-- so the bytes are moved aside verbatim on the next write and the pack starts empty.
s:test("a file that parses but is not a state document is refused and quarantined, not replaced",
function(t)
    for _, shape in ipairs({ "[1,2,3]", '{"hello":"world"}', '"just a string"', "42" }) do
        withDisk(t, function(shim)
            local SAVE = state.saveDir()
            local path = shim.pathFor(SAVE .. "/pfd_shape")
            writeBytes(path, shape, shim)

            local ok = state.loadPack("pfd_shape")
            t:falsy(ok, shape .. ": it is refused — parsing is not the same as being ours")
            t:neq(state.stats("pfd_shape").health, "ok", shape .. ": and it does not report healthy")

            state.world().entities["A@1,1,1"] = record("A", "pfd_shape", 100, 100, 100, { n = 1 })
            state.markDirty("pfd_shape")
            t:truthy(state.flushDirty())

            local found, foundPath = nil, nil
            for p in pairs(shim.files) do
                if p:find("_quarantine", 1, true) then foundPath = p; found = readBytes(p) end
            end
            t:type(foundPath, "string", shape .. ": a quarantine copy was taken")
            sameBytes(t, found, shape,
                shape .. ": and it holds the ORIGINAL BYTES, byte for byte")
            t:neq(readBytes(path), shape,
                shape .. ": the pack resumed into a fresh file of its own")
        end)
    end
end)

--=============================================================================
-- 6. A FORMAT FROM THE FUTURE
--=============================================================================

s:test("a newer format is refused, and the file is byte-identical afterwards", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local path = shim.pathFor(SAVE .. "/pfd_future")
        local future = json.encode({
            palforge  = { format = state.FORMAT + 1, mod = "pfd_future", save = SAVE,
                          forge = "99.0.0", buildings = 1 },
            buildings = { ["A@1,1,1"] = { buildId = "A", pos = { 100, 100, 100 },
                                          state = { n = 1 }, somethingNew = "kept" } },
        })
        writeBytes(path, future, shim)

        local ok, err = state.loadPack("pfd_future")
        t:falsy(ok, "a format this build does not know is refused, not guessed at")
        t:type(err, "string")
        t:truthy(err:find(tostring(state.FORMAT + 1), 1, true), "the reason names the file's format")
        t:truthy(err:find(tostring(state.FORMAT), 1, true), "and the one this build knows")
        t:eq(state.stats("pfd_future").health, "future-format")
        t:eq(state.world().entities["A@1,1,1"], nil,
            "and NOTHING from it reached the world view — a half-understood record is worse "
            .. "than no record")

        -- The half that matters. Refusing to READ is worthless if the next flush truncates it
        -- with an older writer's idea of the format, and that is the one way a downgrade loses
        -- a player's data permanently.
        state.world().entities["B@2,2,2"] = record("B", "pfd_future", 200, 200, 200, { n = 2 })
        state.markDirty("pfd_future")
        local fok, ferr = state.flush("pfd_future")
        t:falsy(fok, "the flush refuses too")
        t:type(ferr, "string")
        sameBytes(t, readBytes(path), future,
            "AND THE FILE IS BYTE-IDENTICAL after a flush that had records to write")

        -- The 10 s pump takes the same route and must reach the same answer: it REPORTS the
        -- failure and keeps the pack dirty, rather than raising or clearing the flag as though
        -- the write had happened. (flushWorld, which this replaced, discarded its result and
        -- cleared `dirty` anyway — one bad pack silently lost a whole session.)
        local pok, perr = state.flushDirty()
        t:falsy(pok, "the pump reports the failure rather than swallowing it")
        t:type(perr, "string", "and hands back a reason")
        t:truthy(state.stats("pfd_future").dirty, "and the pack STAYS DIRTY, so nothing is "
            .. "recorded as written that was not written")
        sameBytes(t, readBytes(path), future, "and still identical after the pump's own attempt")
    end)
end)

s:test("a file that names another save is neither read nor written", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local path = shim.pathFor(SAVE .. "/pfd_copied")
        local other = json.encode({
            palforge  = { format = state.FORMAT, mod = "pfd_copied",
                          save = "w_9C3A11F2NOTTHISWORLD", forge = env.version },
            buildings = { ["A@1,1,1"] = { buildId = "A", pos = { 1, 1, 1 }, state = { n = 1 } } },
        })
        writeBytes(path, other, shim)

        local ok, err = state.loadPack("pfd_copied")
        t:falsy(ok, "a folder that was renamed or copied is DETECTABLE, not silently adopted")
        t:truthy(err:find("w_9C3A11F2NOTTHISWORLD", 1, true), "and the reason names the id in the file")
        t:truthy(err:find(SAVE, 1, true), "and the id of the folder it is sitting in")
        t:eq(state.world().entities["A@1,1,1"], nil)

        state.world().entities["B@2,2,2"] = record("B", "pfd_copied", 2, 2, 2, { n = 2 })
        state.markDirty("pfd_copied")
        t:falsy(state.flush("pfd_copied"), "and it refuses to write as well as to read")
        sameBytes(t, readBytes(path), other, "so the other world's file is left exactly as it was")

        t:truthy(state.rebind() >= 1, "rebind() is the one-call escape hatch for a real copy")
        t:truthy(state.loadPack("pfd_copied"), "after which it reads")
        t:eq(state.world().entities["A@1,1,1"].state.n, 1)
    end)
end)

--=============================================================================
-- 7. AN ABSENT MOD LOSES NOTHING — the removal contract, measured
--=============================================================================

s:test("a mod that does not load this session keeps every byte, and gets it all back next",
function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()

        -- ---- session 1: two mods, one of them with a quarantined record ----
        local w = state.world()
        w.entities["L@1,1,1"] = record("L", "pfd_logi", 100, 100, 100, { pipes = 4 })
        w.orphans["LQ@2,2,2"] = { buildId = "logi_PipeSatellite", pack = "pfd_logi",
            pos = { x = 200, y = 200, z = 200 }, state = { held = true },
            orphanedAt = 1785646408, why = "unclaimed" }
        w.entities["M@3,3,3"] = record("M", "pfd_mine", 300, 300, 300, { n = 1 })
        state.storeFor("pfd_logi").set("secret", "LOGI_SECRET")
        state.markDirty("pfd_logi"); state.markDirty("pfd_mine")
        t:truthy(state.flushDirty())

        local logiPath  = shim.pathFor(SAVE .. "/pfd_logi")
        local logiBytes = readBytes(logiPath)
        t:type(logiBytes, "string")

        -- ---- session 2: pfd_logi is simply not installed. Nothing asks for it. ----
        state.__reset()
        shim.reads = {}
        state.loadPack("pfd_mine")
        for i = 1, 5 do
            state.world().entities["M@3,3,3"].state.n = i
            state.markDirty("pfd_mine")
            t:truthy(state.flushDirty())
        end

        t:eq(shim.reads[SAVE .. "/pfd_logi"], nil,
            "pfd_logi's file was NEVER OPENED — an absent mod costs zero reads, which is the "
            .. "efficiency claim and the safety claim in one sentence")
        sameBytes(t, readBytes(logiPath), logiBytes,
            "and its bytes are identical after five of the other mod's flushes: an absent mod "
            .. "cannot be evicted, truncated or partially rewritten by a neighbour's growth")

        -- ---- session 3: it is installed again ----
        state.__reset()
        t:truthy(state.loadPack("pfd_logi"))
        t:eq(state.world().entities["L@1,1,1"].state.pipes, 4, "every record came back")
        local q = state.world().orphans["LQ@2,2,2"]
        t:type(q, "table", "including the quarantined one, still quarantined")
        t:eq(q.orphanedAt, 1785646408, "with its date")
        t:eq(q.why, "unclaimed", "and its reason — so it is still self-reversing")
        t:eq(q.state.held, true)
        t:eq(state.storeFor("pfd_logi").get("secret"), "LOGI_SECRET")
    end)
end)

s:test("uninstalling one mod deletes one file and leaves its neighbours alone", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local w = state.world()
        w.entities["L@1,1,1"] = record("L", "pfd_logi", 100, 100, 100, { n = 1 })
        w.entities["M@3,3,3"] = record("M", "pfd_mine", 300, 300, 300, { n = 2 })
        state.markDirty("pfd_logi"); state.markDirty("pfd_mine")
        t:truthy(state.flushDirty())

        local minePath  = shim.pathFor(SAVE .. "/pfd_mine")
        local mineBytes = readBytes(minePath)

        t:truthy(state.uninstall("pfd_logi"), "the one destructive call in the store")
        t:eq(readBytes(shim.pathFor(SAVE .. "/pfd_logi")), nil, "removes exactly one file")
        sameBytes(t, readBytes(minePath), mineBytes, "and does not touch the neighbour's bytes")
        t:eq(state.world().entities["L@1,1,1"], nil, "nor leave its records in the merged view")
        t:type(state.world().entities["M@3,3,3"], "table", "while the neighbour's stay")
        t:falsy(state.uninstall("pfd_logi"), "and a second call has nothing to delete")
    end)
end)

-- The transitional cost the design names rather than sells as free: a migrating player's whole
-- file lands in _unowned, and then DRAINS as core/event attributes each record on first bind.
-- The half that can go wrong is the drain leaving a DUPLICATE — the record in its new pack's
-- file and still in _unowned — which is exactly why attribution marks BOTH documents dirty.
s:test("_unowned drains into the owning mod's file, leaving no duplicate behind", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        state.world().entities["A@1,1,1"] = record("A", nil, 100, 100, 100, { n = 1 })
        state.markDirty("_unowned")
        t:truthy(state.flushDirty())
        t:eq(countKeys(json.decode(readBytes(shim.pathFor(SAVE .. "/_unowned"))).buildings), 1)

        -- What core/event's stampRecord does on the first scan that binds this record.
        local rec = state.world().entities["A@1,1,1"]
        rec.pack, rec.def = "pfd_alpha", "pfd_alpha:Thing"
        state.markDirty("_unowned"); state.markDirty("pfd_alpha")
        t:truthy(state.flushDirty())

        local un = json.decode(readBytes(shim.pathFor(SAVE .. "/_unowned")))
        local al = json.decode(readBytes(shim.pathFor(SAVE .. "/pfd_alpha")))
        t:eq(countKeys(un.buildings), 0, "the bucket gave the record up")
        t:eq(countKeys(al.buildings), 1, "and the owning mod's file has it")
        t:eq(al.buildings["A@1,1,1"].state.n, 1, "with its state")

        state.__reset()
        state.loadPack("_unowned"); state.loadPack("pfd_alpha")
        t:eq(countKeys(state.world().entities), 1,
            "and a session that reads both files sees ONE record, not two")
    end)
end)

--=============================================================================
-- 8. THE EFFICIENT READ — asserted as what is NOT opened
--=============================================================================

s:test("the read path opens what the design says it opens, and nothing else", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()

        -- Four files on the disk, as a player with three mods installed would have.
        local w = state.world()
        w.entities["A@1,1,1"] = record("A", "pfd_alpha", 100, 100, 100, { n = 1 })
        w.entities["B@2,2,2"] = record("B", "pfd_beta", 200, 200, 200, { n = 2 })
        w.entities["G@3,3,3"] = record("G", "pfd_gamma", 300, 300, 300, { n = 3 })
        w.entities["U@4,4,4"] = record("U", nil, 400, 400, 400, { n = 4 })
        for _, p in ipairs({ "pfd_alpha", "pfd_beta", "pfd_gamma", "_unowned" }) do
            state.markDirty(p)
        end
        t:truthy(state.flushDirty())

        -- ---- the accounting starts here ----
        state.__reset()
        shim.reads, shim.opens = {}, 0

        -- game start / world load, before any definition registers
        t:eq(shim.opens, 0, "nothing is opened before anything asks")

        -- a pack installed but registering nothing
        local db = state.storeFor("pfd_gamma")
        t:eq(shim.opens, 0, "building a mod's store handle opens nothing")

        -- the merged view, the health questions, the report — none of them is a read
        state.world()
        state.isLoaded("pfd_alpha")
        state.stats("pfd_alpha")
        state.diagnose("pfd_alpha")
        t:eq(shim.opens, 0, "and neither world(), isLoaded(), stats() nor diagnose() opens a "
            .. "file — which is what lets test/hooks report a pack's state without loading it")

        -- first sight of a definition owned by pack P
        t:truthy(state.loadPack("pfd_alpha"))
        t:eq(shim.opens, 1, "the first sight of a definition opens exactly ONE file")
        t:eq(shim.reads[SAVE .. "/pfd_alpha"], 1)
        t:eq(shim.reads[SAVE .. "/pfd_beta"], nil, "and not the other mods'")
        t:eq(shim.reads[SAVE .. "/pfd_gamma"], nil)
        t:eq(shim.reads[SAVE .. "/_save"], nil, "and not the manifest: it is ADVISORY and "
            .. "nothing on the read path consults it")

        -- idempotent
        t:truthy(state.loadPack("pfd_alpha"))
        t:truthy(state.loadPack("pfd_alpha"))
        t:eq(shim.opens, 1, "asking again reads nothing: one attempt per world, whatever came back")

        -- the compatibility bucket, once any building definition exists
        t:truthy(state.loadPack("_unowned"))
        t:eq(shim.opens, 2)

        -- a mod that is installed but never touches its store still costs nothing...
        t:eq(shim.reads[SAVE .. "/pfd_gamma"], nil, "an installed mod that registers nothing "
            .. "and reads nothing still costs zero")
        -- ...and the first READ is where that stops, which is the real boundary
        t:eq(db.get("anything"), nil)
        t:eq(shim.reads[SAVE .. "/pfd_gamma"], 1, "the first db.get is the read, not storeFor")

        -- writing one mod writes one mod
        state.world().entities["A@1,1,1"].state.n = 99
        state.markDirty("pfd_alpha")
        local before = shim.writes[SAVE .. "/pfd_beta"]
        t:truthy(state.flushDirty())
        t:eq(shim.writes[SAVE .. "/pfd_beta"], before,
            "and the mod nobody touched is not rewritten — 102,332 bytes re-encoded for one "
            .. "changed number was the shape this format replaced")
        t:eq(shim.reads[SAVE .. "/pfd_beta"], nil, "nor even opened")

        -- AN UNINSTALLED MOD: zero, ever.
        t:eq(shim.reads[SAVE .. "/pfd_never_installed"], nil)
    end)
end)

s:test("one mod's world load reads one mod's bytes, not every mod's", function(t)
    withDisk(t, function(shim)
        local SAVE = state.saveDir()
        local PACKS = { "pfd_alpha", "pfd_beta", "pfd_gamma" }

        -- 60 records per mod, with a four-field state on each — the shape the design measured.
        local w = state.world()
        for pi, p in ipairs(PACKS) do
            for i = 1, 60 do
                w.entities[string.format("%s_S@%d,%d,%d", p, pi, i, 0)] =
                    record(p .. "_S", p, pi * 100, i * 100, 0,
                           { uses = i, role = "worker", lit = true, ratio = i / 60 })
            end
            state.markDirty(p)
        end
        t:truthy(state.flushDirty())

        local sizes, total = {}, 0
        for _, p in ipairs(PACKS) do
            sizes[p] = #readBytes(shim.pathFor(SAVE .. "/" .. p))
            total = total + sizes[p]
        end
        t:truthy(total > 0)

        state.__reset()
        shim.reads = {}
        t:truthy(state.loadPack("pfd_alpha"))

        local read = 0
        for key in pairs(shim.reads) do
            local f = readBytes(shim.pathFor(key))
            read = read + (f and #f or 0)
        end
        t:eq(read, sizes.pfd_alpha,
            "a world load with ONE mod installed reads that mod's file and no other byte")
        t:truthy(read * 2 < total, string.format(
            "which is %d bytes instead of %d — the split IS the efficiency, and with none "
            .. "installed it is zero rather than merely faster", read, total))
        t:eq(countKeys(state.world().entities), 60, "and the records it needed are all there")
    end)
end)

--=============================================================================
-- 9. the manifest, and F-8
--=============================================================================

s:test("the manifest is written beside the files and never consulted to read one", function(t)
    withDisk(t, function(shim, root)
        local SAVE = state.saveDir()
        state.world().entities["A@1,1,1"] = record("A", "pfd_alpha", 100, 100, 100, { n = 1 })
        state.markDirty("pfd_alpha")
        t:truthy(state.flushDirty())

        local man = json.decode(readBytes(shim.pathFor(SAVE .. "/_save")))
        t:type(man, "table", "a manifest was written")
        t:eq(man.palforge.save, SAVE, "naming the save")
        t:eq(man.palforge.format, state.FORMAT)
        local found = false
        for _, p in ipairs(man.palforge.packs) do if p == "pfd_alpha" then found = true end end
        t:truthy(found, "and listing the mods this save's store knows about")

        local readme = readBytes(root .. SEP .. "README.txt")
        t:type(readme, "string", "and README.txt sits beside the save folders, not inside one")
        t:truthy(readme:find("NOT part of Palworld's save", 1, true),
            "saying, in English, the thing the player who started this design was afraid of")
        t:truthy(readme:find("copy the whole", 1, true),
            "and how to back a world's state up: copy the w_ folder")

        state.__reset()
        shim.reads = {}
        t:truthy(state.loadPack("pfd_alpha"))
        t:eq(shim.reads[SAVE .. "/_save"], nil,
            "and reading a mod's records did not consult it — an index that can disagree with "
            .. "the truth is the failure class this format removes, so it is allowed to be wrong")
    end)
end)

s:test("F-8: with nothing to record, no file and no directory are created", function(t)
    withDisk(t, function(shim, root)
        local SAVE = state.saveDir()
        -- Everything a pack that registers a definition and never records anything does.
        local db = state.storeFor("pfd_quiet")
        state.world()
        state.isLoaded("pfd_quiet")
        state.markDirty("pfd_quiet")
        t:truthy(state.flush("pfd_quiet"), "the flush reports success")

        t:eq(readBytes(shim.pathFor(SAVE .. "/pfd_quiet")), nil, "and wrote no file")
        t:eq(readBytes(shim.pathFor(SAVE .. "/_save")), nil, "not even a manifest")
        t:eq(readBytes(root .. SEP .. "README.txt"), nil, "and not the README")
        -- io.open on a DIRECTORY succeeds on some platforms and fails on others, so the claim
        -- is carried by the thing that can only be true one way: nothing inside it exists, and
        -- the write path never asked for the directory to be made either.
        t:eq(readBytes(shim.pathFor(SAVE .. "/_unowned")), nil,
            "the save directory holds nothing — which is what 'no pack registering a Building "
            .. "definition, no state file at all' means on a real disk")
        t:eq(next(shim.files), nil, "no path at all was created this whole test")
        t:eq(db.get("nothing"), nil, "and a read of a mod with no file is nil, not an error")
    end)
end)

return s
