-- PalForge core.state — WHERE A PLAYER'S MOD STATE LIVES, and the only module that decides it.
--
-- ONE FILE PER MOD, UNDER ONE DIRECTORY PER SAVE, READ ONLY WHEN SOMETHING ASKS FOR IT:
--
--   <UE4SS Mods>/PalForge/state/
--   ├── README.txt                    written once, on the first WRITE (never on a read)
--   ├── entities_w_1DF0….json         LEGACY — read once by migrate(), then NEVER touched
--   └── w_1DF0E44B4FDDD6196E30819A899C9009/      one directory per SAVE (core.spatial.saveId)
--       ├── _save.json                manifest — ADVISORY, nothing on the read path consults it
--       ├── _unowned.json             records no pack can be attributed to (yet)
--       ├── logi.json                 one file per MOD ID
--       ├── mypack.json
--       └── _quarantine/
--           └── 2026-08-02T14-03-11Z_logi.json   a file that would not parse, moved aside
--
-- THE MOD ID IS core.object_manager's PACK IDENTITY. No second identity was invented:
-- `owner("building", defId)` already answers "whose record is this?", `api.pack(id)` already
-- scopes a define, `^[%w_]+$` (api/init.lua's PACK_ID) already makes it a legal FILENAME, and
-- every record already carries it as `rec.pack`. The whole change is promoting it from a
-- FIELD to a FILENAME.
--
-- NEITHER PATH COMPONENT CAN ESCAPE state/. core.spatial.saveId() gsubs [^%w_] -> _ and
-- prefixes "w_"; a pack id is ^[%w_]+$. Neither can contain / \ . or : — stated because the
-- backend key used to be a leaf name and is now a PATH.
--
-- ⚠️ THIS IS A SIDECAR. It is NOT part of Palworld's save. Nothing in this tree calls
-- SaveGame / RequestSave / WriteSave and nothing here opens a .sav; delete <Mods>/PalForge/
-- and the world still loads. What DOES reach the game's own save is what PalForge asks the
-- GAME to do — Item:give puts a StaticItemId into an inventory container, Building:unlock
-- appends to the player's technology list — and THAT is what the `ledger` section below
-- records, id by id, so an uninstall can be described rather than guessed at.
--
-- ---- what this module owns, and what it deliberately does not ----
--
-- OWNS   the per-pack documents, the per-pack dirty set, the merged view core/event reads,
--        the format-3 dispatch, the quarantine, the migration off the single legacy file.
-- DOES NOT OWN  where state/ is on disk (utils/file/json_file.lua's debug.getinfo walk is
--        the authority and is not duplicated), the atomic write and its .bak rotation (same
--        module), the JSON codec, or the record LIFECYCLE (core/event.lua binds, stamps,
--        migrates and quarantines records; this module only decides which file each lands in).
--
-- ---- the merged view, and why there is no per-pack index ----
--
-- core/event.lua keeps ONE table — `{ entities = {...}, orphans = {...} }` — so scanOnce's
-- per-actor lookup stays a single hash hit and never walks N files. This module hands that
-- table out (M.world()) and PARTITIONS IT BY rec.pack AT FLUSH TIME.
--
-- The partition is a walk over every record, once per flushed pack, and that is on purpose.
-- core/event.lua writes `w.entities[key] = rec` DIRECTLY — an index of "which key belongs to
-- which pack" maintained here would be a second copy of the truth, able to disagree with the
-- first, which is the exact failure class this store exists to remove. The walk is also not
-- the expensive half: at 500 records the ENCODE is 1.78 ms per pack and the walk is a hash
-- iteration over a table the encoder is about to visit anyway.
--
-- ---- the read path (the efficiency the user asked for), measured ----
--
--   game start                                        no file opened, 0 bytes
--   world load, before any definition registers       no file opened, 0 bytes
--   first sight of a definition owned by pack P       P.json only
--   first sight of ANY building definition            _unowned.json (the compatibility bucket)
--   a pack installed but registering nothing          0
--   A PACK UNINSTALLED                                0, EVER
--
-- MEASURED (WSL2/ext4, lua5.4, this tree's own utils/json.lua, 20 iterations, a 4-field state
-- on every record): at 500 records the world-load read with ONE pack installed goes 28.61 ms
-- (today's single shared file) -> 4.97 ms. 5.8x. With three packs installed ~14 ms. With none,
-- 0 ms. The write amplification moves the same way: one structure changing one number
-- re-encodes and rewrites 102,332 bytes today (7.48 ms) and 26,419 bytes here (1.78 ms).
--
-- _unowned.json loads whenever ANY building definition exists, and the asymmetry is a
-- measurement rather than a preference: all four real sample files in this tree are 100%
-- v1 records — no `def`, no `pack` — because those are stamped only on the first scan that
-- BINDS a record. A migrating player's whole file therefore lands in _unowned. It then
-- DRAINS: core/event's stampRecord attributes each record on first bind and the next flush
-- partitions it into the owning pack's file. After a session or two it is empty. That is a
-- transitional cost, named rather than sold as free.
--
-- ---- failure semantics, in one place ----
--
--   a file that will NOT PARSE      is never overwritten. It is moved aside verbatim to
--                                   _quarantine/<ISO8601>_<pack>.json — and the move happens
--                                   on the next WRITE, not on the read that found it, because
--                                   nothing may write on a read. The pack resumes from
--                                   whatever the backend's .bak recovery could give it.
--   a `format` THIS BUILD DOES NOT KNOW   is refused, not guessed at: logged once, left alone,
--                                   that pack's records absent for the session rather than
--                                   truncated by an older writer.
--   `palforge.save` DISAGREES with the folder   refuses to read AND refuses to write, naming
--                                   both ids. A renamed or copied folder becomes detectable
--                                   instead of silently adopted. M.rebind() is the one-call
--                                   escape hatch for the legitimate copy-a-world case.
--   a WRITE THAT FAILS              KEEPS the dirty set, records lastError and warns once per
--                                   distinct reason WITH THE PACK NAMED. It is never cleared
--                                   as though it had succeeded — which is what the code this
--                                   replaces did (flushWorld discarded setAndFlush's result
--                                   and cleared `dirty` anyway, so one cyclic state table in
--                                   any pack silently lost a whole session's building state).
--   a RECORD whose state will not encode   is SKIPPED and the rest of the pack's flush
--                                   proceeds, with the reason in lastError. Nothing silently
--                                   succeeds; nothing takes another record down with it.
--
-- ---- the caches live on _G, for the reason core/spatial's index does ----
--
-- An F9 hot reload drops every palforge.* module except four (core/reload.lua's KEEP), so a
-- fresh core.state would hold an EMPTY world while every live building instance keeps the
-- `state` table it was created with — the record and the instance would stop describing one
-- thing, and the next flush would write a file with the records missing. The tables are
-- shared through _G and cleared IN PLACE, never replaced, for the same reason.
local file    = require("palforge.utils.file")
local json    = require("palforge.utils.json")
local spatial = require("palforge.core.spatial")
local om      = require("palforge.core.object_manager")
local env     = require("palforge.env")
local log     = require("palforge.utils.log").scope("store")

local M = {}

-- The on-disk format. Written ONCE per file (palforge.format) instead of once per record,
-- and DISPATCHED ON — the `version` field the old single file carried was written and never
-- read, which is the same as not having one.
--   1  { buildId, pos = {x,y,z}, state, altKeys = {} }      the port; altKeys was dead
--   2  { v, buildId, def, pack, pos = {x,y,z}, state }      carries its owner (F-7)
--   3  one file per pack; `pack` is the FILENAME, `v` is the HEADER, `pos` is integer cm
M.FORMAT = 3

-- Three ids that are files in the save directory rather than packs. All three are legal pack
-- ids today (^[%w_]+$ admits a leading underscore), so they are refused by name — one
-- validation line beats a `pack.<id>.json` convention that costs legibility forever.
M.UNOWNED    = "_unowned"
M.MANIFEST   = "_save"
M.QUARANTINE = "_quarantine"
M.RESERVED   = { [M.UNOWNED] = true, [M.MANIFEST] = true, [M.QUARANTINE] = true }

local PACK_ID = "^[%w_]+$"
local SEP     = package.config:sub(1, 1)

---The ledger's four kinds, IN REPORT ORDER, and the only list of them in the tree.
---
---An active SKILL is deliberately absent: EPalWazaID is a fixed vanilla enum, Lua cannot mint
---a value, so nothing written there can ever stop being valid and recording it would be noise
---in the one report that has to be trustworthy.
---
---THIS IS THE ROSTER. It was five lists across two files — a set here, an ordered `M.KINDS` in
---core/ledger that nothing read, the `RECLAIM` keys below, an inline literal inside db.reclaim
---and a sixth copy in a hook — and two of them had already drifted into different orders, so
---the one guarantee the ordered copy existed to give was not true. A fifth kind is a one-line
---edit here plus its `RECLAIM` rule; nothing else enumerates them.
M.LEDGER_KINDS = { "item", "passive", "tech", "pal" }

local LEDGER_KIND = {}
for _, k in ipairs(M.LEDGER_KINDS) do LEDGER_KIND[k] = true end

--=============================================================================
-- the session tables (shared through _G — see the header)
--=============================================================================

local S = _G.__PalForgeState
if not S then
    S = {
        save     = nil,                             -- the saveId every table below describes
        world    = { entities = {}, orphans = {} }, -- THE merged view core/event reads
        loaded   = {},                              -- packId -> true once a read was ATTEMPTED
        dirty    = {},                              -- packId -> true
        data     = {},                              -- packId -> the pack's own key/value table
        ledger   = {},                              -- packId -> { item = {...}, tech = {...} }
        meta     = {},                              -- packId -> { health, lastError, ... }
        stores   = {},                              -- packId -> the handle handed to the pack
        seen     = {},                              -- packId -> true: has a file, or wrote one
        warned   = {},                              -- dedup for "once per distinct reason"
        migrated = nil,                             -- the _save.json `migrated` block, once read
        migratedRead = nil,                         -- ...and whether we have looked for it yet
        readme   = false,
    }
    _G.__PalForgeState = S
end

--=============================================================================
-- I/O — one seam, and the raw route it needs
--=============================================================================

-- WHY THERE IS A RAW ROUTE AT ALL. Three things this module must do cannot be said in the
-- key/value facade's vocabulary, and each of them is load-bearing:
--   * move a file that will NOT PARSE aside VERBATIM. A re-encoding of something we could
--     not read is not a copy of it;
--   * write state/README.txt — text, not a JSON value under a key;
--   * report a file's SIZE for stats()/diagnose() without reading it back.
--
-- All three ask for a PATH, AND THIS MODULE DELIBERATELY DOES NOT KNOW WHERE state/ IS.
-- utils/file/json_file.lua resolves it from its own module path and that invariant is not
-- spent here: the path is ASKED FOR (file.pathFor, and the readFile / writeFile / ensureDir
-- primitives that file exports for exactly this) and never reconstructed. The directory
-- itself is the directory of a key's path — one question to the one authority, rather than
-- a second copy of a "…/…/…/state" walk that could drift out of step with it.
local backend = require("palforge.utils.file.json_file")

local function pathOf(key)
    local p = file.pathFor(key)
    return p
end

local function stateDir()
    local p = file.pathFor("_")
    return (p and p:match("^(.*[\\/])")) or ""
end

local function fileExists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function fileSize(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")          -- O(1): the size WITHOUT reading the file
    f:close()
    return n
end

-- THE ONE TEST SEAM. Everything this module does to a disk goes through this table, in the
-- vocabulary of KEYS ("w_1DF0…/logi", "w_1DF0…/_quarantine/2026-…_logi") — never absolute
-- paths — so a headless test can substitute an in-memory implementation and never touch a
-- player's state/ directory. M.__io(replacement) returns the previous table.
local IO = {}

-- Decoded value for a key, or nil. Returns `nil, "absent"` when there is no file and
-- `nil, "<reason>"` when there is one and it would not parse — the distinction the whole
-- quarantine policy turns on. The backend is the authority: its get answers value, err, kind
-- where kind is "absent" or "corrupt", and it has already applied the .json -> .tmp -> .bak
-- recovery order by the time it says either.
function IO.get(key)
    local ok, v, err, kind = pcall(file.get, key)
    if not ok then return nil, tostring(v) end
    if v ~= nil then return v end
    if kind == "absent" then return nil, "absent" end
    if type(err) == "string" and #err > 0 then return nil, err end
    if kind == "corrupt" then return nil, "the file would not parse" end
    if fileExists(pathOf(key)) then return nil, "the file exists and would not parse" end
    return nil, "absent"
end

function IO.put(key, value)
    local ok, res = pcall(file.setAndFlush, key, value)
    if not ok then return false, tostring(res) end
    if res == false then
        -- The backend logs its own reason and answers a bare false. Re-encode HERE, on the
        -- failure path only, so the reason reaches lastError and diagnose() instead of only
        -- the log.
        local _, eerr = json.encode(value)
        return false, tostring(eerr or "the backend refused the write")
    end
    -- DROP THE WRITTEN DOCUMENT, because nothing ever reads it back. `file.setAndFlush` stores
    -- the doc in json_file's module-level cache on the way past, so without this the store held
    -- a SECOND copy of every record for the life of the world — the live record plus its
    -- dehydrated twin (states are shared by reference; the record and pos tables are not).
    -- Measured at 500 records: 137 KB per pack, never read. Every reader that could want it
    -- loads first (loadPack is guarded by S.loaded, flush loads before writing, rebind already
    -- forgot explicitly), so the cached copy is pure retention.
    IO.forget(key)
    return true
end

function IO.forget(key)
    file.forget(key)
end

function IO.bytes(key)
    return fileSize(pathOf(key))
end

function IO.exists(key)
    return fileExists(pathOf(key))
end

-- Move a key's file aside, VERBATIM, to another KEY. os.rename first: it preserves the bytes
-- exactly, costs nothing, and cannot half-succeed. The read-and-write fallback is for the one
-- case rename cannot do (a destination on another volume), and it goes through the backend's
-- own readFile/writeFile — exported by json_file for exactly this — so the bytes take the
-- same route in as they took out.
function IO.moveAside(key, destKey)
    local from = pathOf(key)
    local to   = pathOf(destKey)
    if not (from and to) then return false, "the destination is not a legal key" end
    if not fileExists(from) then return false, "absent" end
    backend.ensureDir(to:match("^(.*[\\/])") or stateDir())
    if os.rename(from, to) then return true end
    local text = backend.readFile(from)
    if not text then return false, "unreadable" end
    local ok, why = backend.writeFile(to, text)
    if not ok then return false, tostring(why) end
    os.remove(from)
    return true
end

-- Write TEXT (not a JSON value under a key) at a path relative to state/. README.txt is the
-- only user and the only reason this exists.
function IO.writeRaw(rel, text)
    local dir = stateDir()
    if dir == "" then return false, "state/ could not be resolved" end
    backend.ensureDir(dir)
    return backend.writeFile(dir .. (rel:gsub("/", SEP)), text)
end

function IO.existsRaw(rel)
    local dir = stateDir()
    return dir ~= "" and fileExists(dir .. (rel:gsub("/", SEP)))
end

function IO.remove(key)
    local path = pathOf(key)
    if not fileExists(path) then return false, "absent" end
    local ok, err = os.remove(path)
    if not ok then return false, tostring(err) end
    IO.forget(key)
    return true
end

function IO.path(key)
    return pathOf(key)
end

---Swap the I/O table (tests only). Returns the previous one so a test can restore it.
---@param replacement table
---@return table previous
function M.__io(replacement)
    local prev = IO
    if type(replacement) == "table" then IO = replacement end
    return prev
end

--=============================================================================
-- key composition — PURE. No filesystem access, no directory is created here.
--=============================================================================

---The save's directory name. core.spatial owns the identity; what this adds is that the
---answer is the id the CACHES describe, not a fresh probe — during the teardown that runs
---when a save changes under us, the two differ, and every key built in between has to name
---the world whose records are being written.
---@return string
function M.saveDir()
    return S.save or spatial.saveId()
end

---The backend key for a pack's file: "<saveDir>/<packId>". Refuses the three reserved ids
---and anything that is not ^[%w_]+$ — the same rule api.pack applies, asked again here
---because this is the point where the id becomes a FILENAME.
---@param packId string
---@return string? key, string? err
function M.keyFor(packId)
    if type(packId) ~= "string" or not packId:match(PACK_ID) then
        return nil, string.format("a mod id must be letters, digits or _ (it becomes a file "
            .. "name under state/<save>/); got %s",
            type(packId) == "string" and string.format("%q", packId) or type(packId))
    end
    if M.RESERVED[packId] then
        return nil, string.format("'%s' is reserved by PalForge's own store (%s are the "
            .. "save manifest, the unattributed bucket and the quarantine folder); pick "
            .. "another mod id", packId, "_save / _unowned / _quarantine")
    end
    return M.saveDir() .. "/" .. packId
end

---The key of the single pre-format-3 file, "entities_<saveId>". Read once by migrate() and
---never touched again — not renamed, not deleted. Rolling back to an older PalForge means
---doing nothing.
---@return string
function M.legacyKey()
    return "entities_" .. M.saveDir()
end

-- The internal spelling: reserved ids are legal HERE (they are how the store names its own
-- files), and only here.
local function internalKey(packId)
    return M.saveDir() .. "/" .. packId
end

local function normPack(packId)
    if type(packId) ~= "string" or #packId == 0 then return M.UNOWNED end
    if M.RESERVED[packId] and packId ~= M.UNOWNED then return M.UNOWNED end
    return packId
end

---Which file does this record belong to? `rec.pack` when it has one, `_unowned` otherwise.
---
---EXPORTED, AND IT HAS TO BE. This is the rule that decides which document a record lands in,
---so it is the one rule the whole per-mod design rests on. core/event.lua used to open-code a
---looser copy — `(type(rec.pack) == "string" and rec.pack) or "_unowned"` — which omitted the
---reserved-name check, so a record carrying `pack = "_save"` was partitioned into `_unowned`
---by the flush and counted against `_save` by the orphan cap. One rule, one caller-visible
---name, no second spelling to drift.
---@param rec table?
---@return string packId
function M.packOf(rec)
    local p = rec and rec.pack
    if type(p) == "string" and #p > 0 and not M.RESERVED[p] then return p end
    return M.UNOWNED
end

local packOfRec = M.packOf

local function metaFor(packId)
    local m = S.meta[packId]
    if not m then m = { health = "unread" }; S.meta[packId] = m end
    return m
end

local function warnOnce(tag, msg)
    if S.warned[tag] then return end
    S.warned[tag] = true
    log.warn(msg)
end

--=============================================================================
-- the value guard (§ "db.set validates at the call site")
--=============================================================================

-- THE GUARD IS THE CODEC'S. utils/json.M.validate implements all seven refusal classes
-- (cycle, function/userdata/thread, non-finite number, integer key beside a string key,
-- depth > 16, > 4096 fields, > 64 KiB encoded) and is preferred whenever the codec has one.
--
-- WHY FOUR OF THE SEVEN MATTER MORE THAN THE OTHER THREE, because it is the reason the guard
-- is at the CALL SITE rather than at the write: four are SILENTLY LOSSY, not merely unbounded.
-- Measured against this tree's own encoder:
--   * a function/userdata/thread encodes as `null` — the field is gone with no error at all;
--   * a NaN or an infinity encodes as `null` — same;
--   * `{ "wood", count = 3 }` loses the ARRAY HALF, because encodeTable builds its key list
--     with tostring(k) and then reads t["1"] where the value is at t[1] (measured: the tree's
--     own encoder turns {[1]="a",x="b"} into {"1":null,"x":"b"});
--   * a cycle recurses until the stack overflows — caught by json.encode's pcall, so the whole
--     FILE fails to write rather than the one value.
-- A pack that hits one of those and is told at `db.set` can fix it. A pack that is told at the
-- next flush has already lost the value and cannot tell which field did it. The other three
-- (depth, field count, encoded size) are bounds: a refusal there is annoying, never lossy.
--
-- THERE IS NO FALLBACK, DELIBERATELY. This file once carried a second, weaker validator behind
-- `if type(json.validate) == "function"`, on the theory that the store should not depend on a
-- codec it does not own. It owns it: utils/json ships in this tree, in the same commit, and
-- nothing rebinds package.loaded — so the probe was constant-true and 43 lines were unreachable.
-- Two copies of a refusal rule is how a store starts refusing different things in different
-- builds; there is one, and this function is a forward to it.

---Would this value survive a round-trip through the store? Returns true, or
---false + the PATH of the offending field + why. Pure; touches no disk.
---@param value any
---@return boolean ok, string? path, string? reason
function M.check(value)
    return json.validate(value)
end

--=============================================================================
-- hydrate / dehydrate
--=============================================================================
--
-- ON-DISK FIELD NAMES ARE IDENTICAL TO IN-MEMORY FIELD NAMES, and that is the largest
-- simplification in this design: hydrate/dehydrate shrink to "expand pos, restore the two
-- fields the file does not need to carry" and "drop those two, quantize pos". Everything
-- else is IDENTITY, so core/event.lua's nine record readers need no edit at all, and a
-- field this build has never heard of (`g`, the stable structure id, when the
-- building-instanceid-stable hook says it survives a save/load) SURVIVES A REWRITE instead
-- of being silently dropped — which is what makes it addable with no format bump.
--
--   pack     the FILENAME       15 B/record saved, and the isolation change itself
--   v        the HEADER          5 B/record saved, and the field becomes load-bearing
--   pos      integer CENTIMETRES 41 B/record saved. rec.pos has exactly ONE reader in the
--            live tree (core/event's tryMigrate, which feeds spatial.cellOf at a grid of
--            >= 1 cm); every other consumer takes the LIVE actor's position. Integer cm
--            preserves cellOf exactly for any gridCm >= 1. The 14 digits %.14g prints
--            describe a structure that jitters by more than a metre between scans.
--   buildId  KEPT VERBATIM, though the key already contains it: any two of
--            {key, buildId, pos} reconstruct the third, so a mangled key is REPAIRABLE
--            rather than fatal. 21 B/record for a recovery property.
--
-- Measured on this tree's own encoder: 174 B/record (v2) -> 111 B/record (format 3), 36.2%
-- smaller and still fully legible. The field names were NOT shortened to b/d/p/s: that was
-- measured at a further 9%, bought by making the one artefact a player might open
-- unreadable, in a tree that greps its own state files and quotes them in its comments.

local DROPPED_ON_WRITE = { pack = true, v = true, altKeys = true }

local function cm(v)
    if type(v) ~= "number" or v ~= v then return 0 end
    if v == math.huge or v == -math.huge then return 0 end
    return math.floor(v + 0.5)      -- round-to-nearest, correct for negatives (spatial's q)
end

local function posArray(pos)
    if type(pos) ~= "table" then return nil end
    if pos[1] ~= nil then return { cm(pos[1]), cm(pos[2]), cm(pos[3]) } end
    if pos.x == nil and pos.y == nil and pos.z == nil then return nil end
    return { cm(pos.x), cm(pos.y), cm(pos.z) }
end

local function posTable(pos)
    if type(pos) ~= "table" then return nil end
    if pos[1] ~= nil then return { x = pos[1] or 0, y = pos[2] or 0, z = pos[3] or 0 } end
    if pos.x == nil and pos.y == nil and pos.z == nil then return nil end
    return { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 }
end

-- "<buildId>@<qx>,<qy>,<qz>" -> buildId, or nil when the key does not split. A key that does
-- not split is NOT a reason to drop a record: whatever buildId it carries is kept.
local function buildIdFromKey(key)
    if type(key) ~= "string" then return nil end
    return key:match("^(.+)@%-?%d+,%-?%d+,%-?%d+$")
end

local function dehydrate(rec)
    local out = {}
    for k, v in pairs(rec) do
        if not DROPPED_ON_WRITE[k] and k ~= "pos" then out[k] = v end
    end
    out.pos = posArray(rec.pos)
    return out
end

-- ⚠️ `v` IS NOT RESTORED, and that is a deliberate departure from the specification, which
-- asks for "pack/v absent on disk, restored in memory". It was written while core/event.lua
-- still kept REC_VERSION and stampRecord still compared `rec.v`; neither exists any more —
-- the shape statement moved to the document header, where it is DISPATCHED on. Putting `v`
-- back would give a record loaded from disk a field that a record just bound by the scan does
-- not have, which is a worse thing to hand a debugger than no field at all. `altKeys` goes for
-- the same reason it goes on the way out: nothing writes it and nothing reads it.
local function hydrate(rec, packId, key)
    if type(rec) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(rec) do
        if k ~= "pos" and not DROPPED_ON_WRITE[k] then out[k] = v end
    end
    out.pos  = posTable(rec.pos)
    out.pack = (packId ~= M.UNOWNED) and packId or nil
    if type(out.buildId) ~= "string" or #out.buildId == 0 then
        out.buildId = buildIdFromKey(key)      -- repaired from the key when the field is gone
    end
    return out
end

M.__hydrate   = hydrate     -- named for test/cases/store_state.lua, not for callers
M.__dehydrate = dehydrate

--=============================================================================
-- the merged world view
--=============================================================================

local writeManifest   -- forward: defined with the manifest, used by flush()

-- A save id that changed under us means a different world: flush what is still dirty for the
-- OLD one and start clean. core/event.lua calls M.unload() on world-left and this is the belt
-- to that brace — spatial.resetSaveId() is called from one place and a missed teardown must
-- not write one world's records into another world's folder.
--
-- THE GUARD IS NOT DEFENSIVE, IT IS LOAD-BEARING, twice over. The teardown flush re-enters
-- here through flushDirty, so without `S.syncing` this recurses until the stack ends; and
-- while it is set, M.saveDir() keeps answering the OLD id, which is what makes the flush land
-- in the directory the records actually belong to instead of in the new world's.
local function syncSave()
    local now = spatial.saveId()
    if S.save == now or S.syncing then return end
    if S.save ~= nil then
        S.syncing = true
        log.info(string.format("save changed from %s to %s — flushing and dropping the store's "
            .. "caches", tostring(S.save), tostring(now)))
        local ok, err = pcall(M.unload)
        S.syncing = nil
        if not ok then log.warn("the store's teardown raised: " .. tostring(err)) end
    end
    S.save = now
end

---The merged view core/event.lua reads and writes: { entities = {...}, orphans = {...} }.
---The SAME table for the life of the world (and across an F9 reload), cleared in place by
---unload(). Touches no disk.
---@return table world
function M.world()
    syncSave()
    return S.world
end

---Has this pack's file been read this world? (An ATTEMPT counts: a refused or absent file is
---not retried on every scan.)
---@param packId string?
---@return boolean
function M.isLoaded(packId)
    return S.loaded[normPack(packId)] == true
end

---Bring in the COMPATIBILITY BUCKET — the records that name no pack — once per world.
---
---WHY IT IS A NAMED CALL AND NOT A SIDE EFFECT OF loadPack. It was tried as one, and three
---checks caught it: the store's whole efficiency claim is "one mod's world load reads one
---mod's bytes", and a `loadPack` that quietly opened a second file broke exactly that, plus
---the first-write README and the audit ordering. The bucket is a BUILDING-record concern, so
---the only caller that should pay for it is the building scan — not `db.set`, not `storeFor`,
---not a pack reading its own key/value data.
---
---WHY THE BUCKET EXISTS. `def` and `pack` are stamped on the first scan that BINDS a record,
---so every record written before format 3 — all four of the real sample files in this tree,
---100% of them — carries neither, and a migrating player's whole world lands here. It DRAINS:
---stampRecord attributes each record as its structure is bound and the next flush partitions
---it into the owning pack's file, so after a session or two the bucket is empty. A
---transitional cost, named rather than sold as free.
---
---What this replaces: core/event.lua open-coding the literal `_unowned` three times, in a file
---whose own header says it holds no file name and no cache. The runtime says WHEN; this module
---says WHAT and WHY.
---@return boolean loaded
function M.loadCompatBucket()
    if S.loaded[M.UNOWNED] then return true end
    return M.loadPack(M.UNOWNED) ~= false
end

---Mark a pack's file as needing a write. nil => the unattributed bucket.
---@param packId string?
function M.markDirty(packId)
    S.dirty[normPack(packId)] = true
end

---Load one pack's file into the merged view. Idempotent, and the ONLY route by which a file
---is read. Returns true, or false + why (a refusal is a real answer, not an error).
---@param packId string?
---@return boolean ok, string? err
function M.loadPack(packId)
    packId = normPack(packId)
    syncSave()
    if S.loaded[packId] then
        local m = S.meta[packId]
        if m and m.lastError and m.readOnly then return false, m.lastError end
        return true
    end
    S.loaded[packId] = true          -- one attempt per world, whatever the outcome
    local meta = metaFor(packId)
    local key  = internalKey(packId)

    local doc, err = IO.get(key)
    if type(doc) ~= "table" then
        -- `doc == nil` is what makes this "there is no file", NOT `err == nil`. A file holding
        -- a bare JSON scalar — `42`, `"just a string"` — decodes cleanly, so IO.get hands the
        -- value straight back with no error at all; testing the error alone read that as an
        -- absent file and let the next flush destroy it. A value that came back is a file that
        -- exists, whatever its shape.
        if doc == nil and (err == "absent" or err == nil) then
            meta.health = "ok"       -- no file yet is the normal case, not a failure
            return true
        end
        if doc ~= nil then
            err = string.format("the file holds a bare JSON %s, not a state document",
                type(doc) == "number" and "number" or type(doc))
        end
        -- A file that will not parse. It is NOT overwritten and NOT deleted: the move aside
        -- is recorded and performed by the next WRITE (nothing may write on a read), and the
        -- pack starts from whatever the backend's own .json -> .tmp -> .bak recovery gave it,
        -- which here is nothing.
        meta.health          = "unparseable"
        meta.lastError       = err
        meta.quarantinePending = true
        S.seen[packId] = true
        log.warn(string.format("state file %s.json would not parse (%s). It is NOT overwritten: "
            .. "it will be moved verbatim into %s/%s/ on the next write and '%s' starts this "
            .. "session empty. Nothing in Palworld's own save is affected",
            key, tostring(err), M.saveDir(), M.QUARANTINE, packId))
        return false, err
    end

    -- IT PARSED. THAT IS NOT THE SAME AS IT BEING ONE OF OURS, and the difference used to be
    -- a hole straight through the never-delete policy. "A file that will not parse is never
    -- overwritten" was enforced by the decoder alone, so anything that was legal JSON — a
    -- list, someone's notes, a config file copied into the wrong folder, a hand-edit that lost
    -- the outer object — loaded as `health = "ok"` with no records, and THE NEXT FLUSH WROTE
    -- OVER IT with no warning and no quarantine copy. Measured before this check: `[1,2,3]`,
    -- `{"hello":"world"}`, `"just a string"` and `42` were all silently destroyed.
    --
    -- Every document this store has ever written carries the `palforge` header — flush()
    -- builds it unconditionally — so its absence means the file is not ours, and the honest
    -- answer to a file we do not understand is the one the policy already gives: leave the
    -- bytes alone, move them aside verbatim on the next write, start this pack empty.
    if type(doc.palforge) ~= "table" then
        meta.health            = "not-a-state-file"
        meta.lastError         = "the file is valid JSON but has no PalForge header"
        meta.quarantinePending = true
        S.seen[packId] = true
        log.warn(string.format("state file %s.json is valid JSON but is NOT a PalForge state "
            .. "document (it has no 'palforge' header). It is NOT overwritten: it will be moved "
            .. "verbatim into %s/%s/ on the next write and '%s' starts this session empty. If "
            .. "you put that file there on purpose, move it somewhere that is not state/",
            key, M.saveDir(), M.QUARANTINE, packId))
        return false, meta.lastError
    end

    S.seen[packId] = true
    local head = doc.palforge

    -- A format this build cannot read is REFUSED, not guessed at. Truncating a newer file
    -- with an older writer is the one way a downgrade loses data permanently.
    local fmt = tonumber(head.format)
    if fmt and fmt > M.FORMAT then
        meta.health    = "future-format"
        meta.readOnly  = true
        meta.lastError = string.format("the file says format %d and this build knows %d",
            fmt, M.FORMAT)
        log.warn(string.format("state file %s.json was written in format %d and this build of "
            .. "PalForge knows format %d. It is left ALONE — not read, not written — so a newer "
            .. "file is never truncated by an older writer. '%s' has no records this session",
            key, fmt, M.FORMAT, packId))
        return false, meta.lastError
    end

    -- SAVE IDENTITY. The file says which save it belongs to; if that disagrees with the folder
    -- it is sitting in, the folder was renamed or copied. Refuse BOTH directions and name both
    -- ids: silently adopting it is how one world's structures end up described by another
    -- world's state. M.rebind() is the deliberate exception and the only thing that sets
    -- S.adopting — a player saying "yes, I copied that world on purpose".
    if type(head.save) == "string" and #head.save > 0 and head.save ~= M.saveDir()
       and not S.adopting then
        meta.health    = "save-mismatch"
        meta.readOnly  = true
        meta.lastError = string.format("the file says it belongs to save '%s' and it is sitting "
            .. "in '%s'", head.save, M.saveDir())
        log.warn(string.format("state file %s.json says save '%s' but sits in the folder for "
            .. "save '%s'. It is neither read nor written this session — a copied or renamed "
            .. "world is detectable instead of silently adopted. If the copy was deliberate, "
            .. "PalForge.core.state.rebind() adopts every file in this folder",
            key, head.save, M.saveDir()))
        return false, meta.lastError
    end

    local w = S.world
    local n = 0
    if type(doc.buildings) == "table" then
        for k, rec in pairs(doc.buildings) do
            if w.entities[k] == nil and w.orphans[k] == nil then
                local h = hydrate(rec, packId, k)
                if h then w.entities[k] = h; n = n + 1 end
            end
        end
    end
    if type(doc.orphans) == "table" then
        for k, rec in pairs(doc.orphans) do
            if w.entities[k] == nil and w.orphans[k] == nil then
                local h = hydrate(rec, packId, k)
                if h then w.orphans[k] = h; n = n + 1 end
            end
        end
    end
    S.data[packId]   = type(doc.data) == "table" and doc.data or {}
    S.ledger[packId] = type(doc.ledger) == "table" and doc.ledger or {}

    meta.health   = "ok"
    meta.records  = n
    meta.bytes    = IO.bytes(key)
    -- The DECLARED version wins over the one in the file: the declared one is the build that
    -- is about to write, the one in the file is the build that wrote last. A pack that
    -- declares nothing keeps whatever the file remembered, which is better than forgetting it.
    meta.packVer  = meta.packVer or head.packVer
    return true
end

--=============================================================================
-- the write path
--=============================================================================

-- state/README.txt, written on the FIRST WRITE and never on a read. It is the answer to the
-- question that started this design — "could removing the mod make my world unloadable" —
-- left where the player will find it, next to the files themselves.
local README = table.concat({
    "This folder holds PalForge's own saved state. It is NOT part of Palworld's save -- the",
    "game's save is untouched and loads fine without PalForge. Each `w_...` folder belongs to",
    "one Palworld save; `_save.json` inside it says which. To back up or move a world's",
    "PalForge state, copy the whole `w_...` folder. Deleting this folder loses the state mods",
    "kept for your buildings; it does not affect your Palworld save.",
    "",
}, "\n")

local function ensureReadme()
    if S.readme then return end
    S.readme = true
    if IO.existsRaw("README.txt") then return end
    IO.writeRaw("README.txt", README)
end

-- A file that would not parse is moved aside HERE — on the write that is about to replace it
-- — rather than on the read that found it. Nothing may write on a read, and the bytes are
-- worth keeping right up to the moment something needs the name back.
local function drainQuarantine(packId, meta)
    if not meta.quarantinePending then return end
    meta.quarantinePending = nil
    local dest = string.format("%s/%s/%s_%s", M.saveDir(), M.QUARANTINE,
        os.date("!%Y-%m-%dT%H-%M-%SZ"), packId)
    local ok, why = IO.moveAside(internalKey(packId), dest)
    if ok then
        log.warn(string.format("the unreadable state file for '%s' was moved to state/%s.json — "
            .. "its bytes are unchanged and nothing was deleted. '%s' is being written fresh",
            packId, dest, packId))
    else
        log.warn(string.format("the unreadable state file for '%s' could NOT be moved aside "
            .. "(%s); it is being overwritten by this session's records",
            packId, tostring(why)))
    end
end

-- Partition the merged view for one pack. O(all records) per flushed pack and deliberately
-- so — see the header. A record whose `state` will not survive the codec is SKIPPED and
-- named; the rest of the pack's flush proceeds.
--
-- WHAT THE GUARD COSTS, stated because it is paid on every flush: utils/json's validate ends
-- by encoding the value, so a record's `state` is encoded twice per flush — once to be
-- measured against the 64 KiB limit and once inside the document. A structure's state is a
-- handful of fields, the flush is at most every 10 s and only while something is dirty, and
-- the alternative is the whole pack's file failing on one bad record instead of one record
-- being skipped by name. Nothing here validates the RECORD's own fields: those are written
-- by this file and by core/event, not by a pack.
--
-- ⚠️ AND WHY IT IS STILL PAID, because the obvious fix is not one. `json.validate` now RETURNS
-- the text it produced (utils/json.lua, fourth return value), so the measured bytes are there
-- for the taking — but the second pass is not a second encode of `state` on its own. It is the
-- encode of the WHOLE DOCUMENT, which contains `state` as a sub-table. Reusing the first pass
-- would mean splicing a pre-encoded fragment into a document encode, and this store's tests
-- assert that a machine-written document is BYTE-IDENTICAL through the strict path. Trading a
-- guaranteed-identical serialiser for one saved pass over a handful of fields is the wrong way
-- round. The return value is there for a caller who wants the text for its own sake; this one
-- deliberately does not take it.
local function partition(packId)
    local w = S.world
    local buildings, orphans = {}, {}
    local nb, no = 0, 0
    local skipped = nil
    local function take(dst, key, rec)
        local ok, path, why = M.check(rec.state)
        if not ok then
            skipped = skipped or {}
            skipped[#skipped + 1] = string.format("%s (state.%s %s)", key, tostring(path or "?"),
                tostring(why or "cannot be saved"))
            return false
        end
        dst[key] = dehydrate(rec)
        return true
    end
    for key, rec in pairs(w.entities) do
        if type(rec) == "table" and packOfRec(rec) == packId then
            if take(buildings, key, rec) then nb = nb + 1 end
        end
    end
    for key, rec in pairs(w.orphans) do
        if type(rec) == "table" and packOfRec(rec) == packId then
            if take(orphans, key, rec) then no = no + 1 end
        end
    end
    return buildings, orphans, nb, no, skipped
end

local function isEmpty(t)
    return type(t) ~= "table" or next(t) == nil
end

---Write one pack's file NOW. Returns true, or false + why — and on a failure the pack STAYS
---DIRTY so the next pump retries it. A flush that cannot write must never look like one that
---did.
---@param packId string?
---@return boolean ok, string? err
function M.flush(packId)
    packId = normPack(packId)
    syncSave()
    local meta = metaFor(packId)

    if meta.readOnly then
        warnOnce("readonly:" .. packId .. ":" .. tostring(meta.lastError),
            string.format("'%s' is not being written this session: %s. Its records are held in "
                .. "memory and nothing on disk is changed", packId, tostring(meta.lastError)))
        return false, meta.lastError
    end

    -- READ BEFORE WRITE. A pack marked dirty without ever being read would otherwise have its
    -- `data` and `ledger` sections written as empty — the file is the whole truth for that
    -- pack, so it must be loaded before it is replaced.
    if not S.loaded[packId] then
        local ok, err = M.loadPack(packId)
        if not ok and meta.readOnly then return false, err end
    end

    local key = internalKey(packId)
    local buildings, orphans, nb, no, skipped = partition(packId)
    local data   = S.data[packId]
    local ledger = S.ledger[packId]

    local doc = {
        palforge = {
            format    = M.FORMAT,
            mod       = packId,
            save      = M.saveDir(),
            forge     = env.version,
            packVer   = meta.packVer,
            wrote     = os.time(),
            buildings = nb,
        },
        buildings = buildings,
        orphans   = orphans,
    }
    if not isEmpty(data)   then doc.data   = data end
    if not isEmpty(ledger) then doc.ledger = ledger end

    -- NOTHING AT ALL TO SAY, AND NO FILE YET: write nothing. This is what keeps F-8 true —
    -- a pack that registers a definition but never records anything creates no file and no
    -- directory.
    if nb == 0 and no == 0 and isEmpty(data) and isEmpty(ledger) and not S.seen[packId] then
        S.dirty[packId] = nil
        return true
    end

    ensureReadme()
    drainQuarantine(packId, meta)

    local ok, err = IO.put(key, doc)
    if not ok then
        meta.health    = "write-failing"
        meta.lastError = err
        warnOnce("write:" .. packId .. ":" .. tostring(err), string.format(
            "the state file for '%s' could NOT be written (%s). Its records are KEPT in memory "
            .. "and the write is retried on the next flush — nothing has been lost yet, and "
            .. "nothing in Palworld's own save is affected", packId, tostring(err)))
        return false, err
    end

    S.dirty[packId] = nil
    S.seen[packId]  = true
    meta.health     = skipped and "records-skipped" or "ok"
    meta.lastWrite  = os.time()
    meta.bytes      = IO.bytes(key)
    meta.records    = nb
    meta.orphans    = no
    if skipped then
        meta.lastError = string.format("%d record(s) were skipped: %s", #skipped,
            table.concat(skipped, "; "))
        warnOnce("skip:" .. packId .. ":" .. meta.lastError, string.format(
            "'%s': %d structure record(s) could not be saved and were SKIPPED; the rest of the "
            .. "pack was written normally. %s", packId, #skipped, meta.lastError))
    else
        meta.lastError = nil
    end
    writeManifest()
    return true
end

---Write every pack whose records changed. The 10 s pump, inst:save() and the world-left
---teardown all land here. Returns false if ANY pack failed (and those stay dirty).
---@return boolean ok, string? err
function M.flushDirty()
    syncSave()
    local names = {}
    for p in pairs(S.dirty) do names[#names + 1] = p end
    if #names == 0 then return true end
    table.sort(names)
    local okAll, firstErr = true, nil
    for _, p in ipairs(names) do
        local ok, err = M.flush(p)
        if not ok then okAll = false; firstErr = firstErr or err end
    end
    return okAll, firstErr
end

---World left: write everything still dirty, then drop every cache so the next world starts
---from its own files. Clears the shared tables IN PLACE (see the header).
function M.unload()
    local ok, err = M.flushDirty()
    if not ok then
        log.warn(string.format("the world is being left with unwritten state (%s). The records "
            .. "are still in memory but this session ends here — the last successful write is "
            .. "what is on disk", tostring(err)))
    end
    for p in pairs(S.loaded) do IO.forget(internalKey(p)) end
    IO.forget(internalKey(M.MANIFEST))
    for k in pairs(S.world.entities) do S.world.entities[k] = nil end
    for k in pairs(S.world.orphans)  do S.world.orphans[k]  = nil end
    for k in pairs(S.loaded) do S.loaded[k] = nil end
    for k in pairs(S.dirty)  do S.dirty[k]  = nil end
    for k in pairs(S.data)   do S.data[k]   = nil end
    for k in pairs(S.ledger) do S.ledger[k] = nil end
    for k in pairs(S.meta)   do S.meta[k]   = nil end
    for k in pairs(S.seen)   do S.seen[k]   = nil end
    S.migrated     = nil
    S.migratedRead = nil        -- the next save's marker is a different file's
    S.save         = nil
end

--=============================================================================
-- the manifest — ADVISORY, and never on the read path
--=============================================================================
--
-- Two jobs, and no third: `packs` lets an audit enumerate without a directory listing Lua
-- cannot do, and `name` is the only way a human tells w_1DF0E44B… from w_9C3A11F2…. Nothing
-- in loadPack consults it. A second copy of the truth that can disagree with the first is
-- the failure class this store exists to remove, so the manifest is allowed to be wrong.

-- ⚠️ THIS UNIONS WITH WHAT IS ALREADY ON DISK, and the reason is a measurement rather than
-- caution. `S.seen` and `S.loaded` describe THIS SESSION only, so a session that touched one
-- pack used to rewrite the manifest down to that one pack: a real run went
-- `["_unowned","attestpack"]` -> `["attestpack"]` while `_unowned.json` was still sitting on
-- disk holding a real record. Nothing broke — the manifest is advisory and `loadPack` never
-- consults it, so the record kept loading through refreshDefs — but `audit()` is the one
-- caller that exists, and it enumerates from here. An audit that silently stops mentioning a
-- pack whose file is right there is worse than no audit.
--
-- Reading the manifest to write the manifest is deliberate and is not the "second copy of the
-- truth" this file's header warns about: the union only ever ADDS a name, and a name here is
-- a hint about where to look, never an answer about what exists.
local readManifest    -- forward: defined with the rest of the manifest below, used here

local function knownPacks()
    local out, seen = {}, {}
    local prior = readManifest()
    if type(prior) == "table" and type(prior.packs) == "table" then
        for _, p in ipairs(prior.packs) do
            if type(p) == "string" and #p > 0 and not seen[p] then seen[p] = true; out[#out + 1] = p end
        end
    end
    for p in pairs(S.seen)   do if not seen[p] then seen[p] = true; out[#out + 1] = p end end
    for p in pairs(S.loaded) do if not seen[p] then seen[p] = true; out[#out + 1] = p end end
    table.sort(out)
    return out
end

-- The world's DISPLAY name, when the game will say. This used to be a probe for a function
-- core/spatial did not have — so the manifest's `name` was always absent and the comment here
-- said "exposing it is a one-line addition to core/spatial". It was, and it has been made:
-- spatial.saveName() reads the same measured (GetSelectedWorldName, SelectedWorldName) pair
-- the save-id probe already fell back to. nil stays a legitimate answer (no world, or a build
-- that will not say), and the manifest omits the field rather than inventing a label.
local function saveName()
    local ok, n = pcall(spatial.saveName)
    return (ok and type(n) == "string" and #n > 0) and n or nil
end

local migratedBlock   -- forward: defined with readManifest, used by writeManifest

writeManifest = function()
    local packs = knownPacks()
    -- The `migrated` block is the ONLY part of this advisory file that is load-bearing, and
    -- it is the one part this function does not itself produce. Ask for it rather than
    -- reading S.migrated directly — see migratedBlock for what goes wrong otherwise.
    local mig = migratedBlock()
    local sig = table.concat(packs, ",") .. "|" .. tostring(mig and mig.at or "")
    if S.manifestSig == sig then return true end
    local doc = {
        palforge = {
            format   = M.FORMAT,
            forge    = env.version,
            save     = M.saveDir(),
            name     = saveName(),
            packs    = packs,
            wrote    = os.time(),
            migrated = mig,
        },
    }
    local ok = IO.put(internalKey(M.MANIFEST), doc)
    if ok then S.manifestSig = sig end
    return ok
end

-- Assigns to the local forward-declared above knownPacks rather than introducing a new one:
-- knownPacks unions this file's `packs` with the session's, so the two have to be the SAME
-- upvalue. `local function readManifest()` here would shadow it and leave knownPacks calling
-- nil — which is exactly what the store suite caught the first time this union was written.
readManifest = function()
    local doc = IO.get(internalKey(M.MANIFEST))
    if type(doc) ~= "table" or type(doc.palforge) ~= "table" then return nil end
    return doc.palforge
end

-- The migration marker, from this session if migrate() ran and from the FILE if it did not.
--
-- ⚠️ THE FALLBACK IS THE WHOLE POINT, and without it the marker is erased by ordinary use.
-- S.migrated is set in exactly one place — inside migrate(), on the path that actually
-- migrates something. migrate() returns early WITHOUT setting it whenever the legacy file is
-- absent, which is every session after the first (and every session of a player who never had
-- one). So a manifest rebuilt from S.migrated alone drops `migrated` on the next ordinary
-- flush, and the marker is gone.
--
-- What that costs is not cosmetic. The marker is the only thing that stops migrate() running
-- twice. Erase it, restore an old backup over the legacy file — or simply keep the legacy
-- file, which is policy, since it is never deleted — and the next migrate() sees an
-- unmigrated world and re-adds every record in it, including the structures the player has
-- since dismantled. Measured on real disk before this fix: session 1 migrates, session 2
-- dismantles one structure and flushes, session 3 brings it back.
--
-- Read once per save, then remembered; unload() clears it with the rest of the save's state.
migratedBlock = function()
    if S.migrated == nil and not S.migratedRead then
        S.migratedRead = true
        local man = readManifest()
        S.migrated = (man and type(man.migrated) == "table") and man.migrated or nil
    end
    return S.migrated
end

--=============================================================================
-- migration off the single legacy file
--=============================================================================
--
-- ONE-SHOT, at the first world.ready for a save that has an entities_<saveId>.json and no
-- store directory yet.
--
-- ATTRIBUTION IS THREE-TIERED, AND THE THIRD TIER IS THE ONE THAT MATTERS. All four real
-- sample files in this tree are 100% v1 records — no `def`, no `pack` — because core/event
-- stamps those only on the first scan that BINDS a record. A migration keyed on `def` would
-- therefore find it absent on exactly the records that most need migrating. So:
--   1. rec.pack, when present
--   2. object_manager.owner("building", rec.def), when rec.def is present
--   3. rec.buildId -> the UNIQUE registered definition claiming it. Exactly one -> that
--      definition's pack. Zero or several -> _unowned.json, buildId intact.
-- and _unowned is then ADOPTED LATER, automatically, at the next flush after stampRecord
-- attributes a record on bind.
--
-- THE LEGACY FILE IS NEVER TOUCHED — not renamed, not deleted. Rolling back to an older
-- PalForge is doing nothing. The marker lives in _save.json's `migrated` block with a
-- FINGERPRINT that does two jobs: the migration cannot run twice, and if the player later
-- restores a backup over that file the fingerprint no longer matches and the newly-appeared
-- records are ADDED — never replacing what is already there.

-- SIZE + RECORD COUNT + THE FIRST 24 BYTES. NOT A HASH, and it does not pretend to be: it is
-- a cheap "is this the same file I read before". `kind` says which of the two routes produced
-- it, because the byte route needs a path the backend does not always expose and the
-- canonical route (re-encode the decoded value; the encoder sorts its keys, so it is stable)
-- answers the same question about the same records without one.
-- The two halves of the fingerprint that cost NOTHING to read: the file's size and its first
-- 24 bytes. Both are O(1) — a seek and a 24-byte read — and neither needs the decoder.
-- nil, nil when the file is not there or will not open.
local function legacyStamp(key)
    local bytes = IO.bytes(key)
    if not bytes then return nil, nil end
    local path = IO.path and IO.path(key) or nil
    local head = ""
    if path then
        local f = io.open(path, "rb")
        if f then head = f:read(24) or ""; f:close() end
    end
    return bytes, head
end

local function fingerprint(legacy, key)
    local n = 0
    for _ in pairs(legacy.entities or {}) do n = n + 1 end
    for _ in pairs(legacy.orphans  or {}) do n = n + 1 end
    local bytes, head = legacyStamp(key)
    if bytes then
        return string.format("%d:%d:%s", bytes, n, head), "bytes"
    end
    local text = json.encode(legacy) or ""
    return string.format("%d:%d:%s", #text, n, text:sub(1, 24)), "canonical"
end

-- Does the marker already describe the file that is on disk, judged WITHOUT parsing it?
--
-- WHY THIS EXISTS. M.migrate used to open and decode the whole legacy file as its first act and
-- only then compare fingerprints, so every player who ever had one paid a full parse at the
-- first world load of every session, forever — measured at 500 records: 77.6 KB read, 15.1 ms
-- of json.decode, and 262 KB of tables the module-level cache then held for the rest of the
-- process. That is the same order as the saving the whole redesign is sold on, charged to the
-- exact population the migration exists for.
--
-- The fingerprint is "<bytes>:<records>:<first 24 bytes>". Only the middle term needs the
-- decoder, and it is derived from the same bytes the other two describe — a file whose size and
-- head are unchanged is the file the marker was written for. A false NEGATIVE here is harmless
-- (migrate parses and the fingerprint comparison answers properly); a false positive would need
-- an edit that preserves both the byte count and the first 24 characters.
local function markerMatchesDisk(man, key)
    if type(man) ~= "table" or type(man.fingerprint) ~= "string" then return false end
    local bytes, head = legacyStamp(key)
    if not bytes then return false end
    local wasBytes, rest = man.fingerprint:match("^(%d+):%d+:(.*)$")
    return wasBytes ~= nil and tonumber(wasBytes) == bytes and rest == head
end

-- resolvedBuildId -> packId, for build ids exactly ONE registered definition claims.
-- Ambiguity answers nil, which sends the record to _unowned with its buildId intact.
local function claimIndex()
    local claims = {}
    for id, cls in pairs(om.all("building")) do
        local entry = om.entry("building", id)
        local pack  = entry and entry.pack or nil
        local ids   = (type(cls) == "table" and type(cls.buildIds) == "table") and cls.buildIds
                      or { (type(cls) == "table" and cls.id) or id }
        for _, bid in ipairs(ids) do
            if type(bid) == "string" and #bid > 0 then
                local r = om.resolve(bid) or bid
                local held = claims[r]
                if held == nil then claims[r] = { pack = pack, n = 1 }
                else held.n = held.n + 1; if held.pack ~= pack then held.pack = nil end end
            end
        end
    end
    local out = {}
    for r, c in pairs(claims) do
        if c.n == 1 and c.pack then out[r] = c.pack end
    end
    return out
end

---Migrate the single pre-format-3 file into per-pack shards. One-shot; a no-op when there is
---nothing to migrate or it has already run. Returns a report, or nil.
---@return table? report
function M.migrate()
    syncSave()
    local legacyKey = M.legacyKey()

    -- THE CHEAP HALF FIRST. For every player who has already migrated — which is every player
    -- who ever had a legacy file, on every world load after the first — this answers in two
    -- O(1) reads instead of a whole-file parse. See markerMatchesDisk for the measurement.
    local marker = S.migrated or (readManifest() or {}).migrated
    if markerMatchesDisk(marker, legacyKey) then
        S.migrated = marker
        return nil
    end

    local legacy, lerr = IO.get(legacyKey)
    if type(legacy) ~= "table" or type(legacy.entities) ~= "table" then
        if lerr and lerr ~= "absent" then
            log.warn(string.format("the legacy state file %s.json would not parse (%s). It is "
                .. "left exactly as it is — nothing is migrated out of it and nothing overwrites "
                .. "it", legacyKey, tostring(lerr)))
        end
        return nil
    end

    -- `marker` was read before the parse; the full fingerprint is the authority and still gets
    -- the last word, so a file whose size and head happen to match but whose contents changed
    -- is caught here rather than skipped above.
    local man = marker
    local fp, fpKind = fingerprint(legacy, legacyKey)
    if type(man) == "table" and man.fingerprint == fp then
        S.migrated = man
        IO.forget(legacyKey)                        -- nothing reads it again this session
        return nil                                  -- already done, same file
    end
    local rerun = (type(man) == "table")

    local claims  = claimIndex()
    local perPack = {}
    local report  = { from = legacyKey .. ".json", records = 0, added = 0, packs = {},
                      orphans = 0, unowned = 0, rerun = rerun, fingerprintOf = fpKind }

    local function attribute(rec)
        if type(rec.pack) == "string" and #rec.pack > 0 then return normPack(rec.pack) end
        if type(rec.def) == "string" then
            local ok, p = pcall(om.owner, "building", rec.def)
            if ok and type(p) == "string" and #p > 0 then return p end
        end
        if type(rec.buildId) == "string" then
            local p = claims[rec.buildId]
            if p then return p end
        end
        return M.UNOWNED
    end

    local w = S.world
    local function absorb(src, dst, why)
        if type(src) ~= "table" then return end
        for key, rec in pairs(src) do
            if type(rec) == "table" then
                report.records = report.records + 1
                local pack = attribute(rec)
                perPack[pack] = (perPack[pack] or 0) + 1
                if pack == M.UNOWNED then report.unowned = report.unowned + 1 end
                -- ADD WHAT IS MISSING, NEVER REPLACE WHAT IS THERE. A re-run after a restored
                -- backup must not roll a live record back to its migration-time state.
                if w.entities[key] == nil and w.orphans[key] == nil then
                    local h = hydrate(rec, pack, key)
                    if h then
                        h.pos = posTable(posArray(h.pos))   -- quantized once, here
                        h.altKeys = nil
                        if why then
                            h.orphanedAt = tonumber(h.orphanedAt) or os.time()
                            h.why        = h.why or why
                        end
                        dst[key] = h
                        report.added = report.added + 1
                        if why then report.orphans = report.orphans + 1 end
                    end
                end
                M.markDirty(pack)
            end
        end
    end

    -- The shard files must be READ before they are written (a re-run after a restored backup
    -- lands in files that already exist), and loading them first is also what makes the
    -- "never replace what is there" rule above mean anything.
    local packsToLoad = {}
    for _, src in ipairs({ legacy.entities, legacy.orphans }) do
        if type(src) == "table" then
            for _, rec in pairs(src) do
                if type(rec) == "table" then packsToLoad[attribute(rec)] = true end
            end
        end
    end
    for p in pairs(packsToLoad) do M.loadPack(p) end

    absorb(legacy.entities, w.entities, nil)
    absorb(legacy.orphans,  w.orphans,  "unclaimed")

    for p, n in pairs(perPack) do report.packs[p] = n end

    S.migrated = {
        at          = os.time(),
        from        = legacyKey .. ".json",
        records     = report.records,
        bytes       = IO.bytes(legacyKey),
        fingerprint = fp,
        fingerprintOf = fpKind,
    }
    local okAll = M.flushDirty()
    writeManifest()

    local names = {}
    for p, n in pairs(report.packs) do names[#names + 1] = string.format("%s=%d", p, n) end
    table.sort(names)
    log.info(string.format("migrated %d record(s) from state/%s into state/%s/ (%s)%s. THE "
        .. "LEGACY FILE IS UNTOUCHED — it is not renamed and not deleted, so reverting to an "
        .. "older PalForge means doing nothing%s",
        report.records, report.from, M.saveDir(), table.concat(names, ", "),
        rerun and " [re-run: the legacy file changed since the last migration, so only the "
        .. "records that were MISSING were added]" or "",
        okAll and "" or ". ⚠️ at least one shard could not be written and is still dirty"))
    return report
end

--=============================================================================
-- the ledger — an INTENT LOG, never a mirror
--=============================================================================
--
-- What is real, and the only thing that is: WHAT THIS PACK MADE THE GAME RECORD. Appended
-- only on a SUCCESSFUL call and only when object_manager can name a pack for the id — a
-- vanilla row cannot stop existing, so Item.get("Wood"):give(1) writes nothing here.
--
-- It records that PalForge asked the game to write a NAME, and when. It does NOT know
-- whether the item is still in the bag: the inventory is FPalWorldSaveData
-- .ItemContainerSaveData, a map of MANY containers the game owns, and PalForge reaches
-- exactly one of them (the local player's bag, and only with a spawned weapon actor). A
-- mirror would be wrong the first time the player used a chest.
--
-- It is what makes removal SAFE TO DESCRIBE: per save, per pack, and it survives the pack's
-- uninstall, so PalForge can name — id by id — every FName in that save that no longer has a
-- DataTable row behind it. Nothing else in this tree can produce that list.

---Append one successful, pack-owned write to the ledger. `kind` is item | tech | passive | pal.
---@param packId string
---@param kind string
---@param id string
---@param n integer?
---@return boolean ok, string? err
function M.ledgerAdd(packId, kind, id, n)
    if type(packId) ~= "string" or #packId == 0 then return false, "no pack" end
    if not LEDGER_KIND[kind] then return false, "unknown ledger kind '" .. tostring(kind) .. "'" end
    if type(id) ~= "string" or #id == 0 then return false, "no id" end
    syncSave()
    packId = normPack(packId)
    local led = S.ledger[packId]
    if not led then led = {}; S.ledger[packId] = led end
    local bucket = led[kind]
    if not bucket then bucket = {}; led[kind] = bucket end
    local e = bucket[id]
    if not e then e = { n = 0 }; bucket[id] = e end
    e.n  = (tonumber(e.n) or 0) + (tonumber(n) or 1)
    e.at = os.time()
    M.markDirty(packId)
    return true
end

-- What a reclaim can and cannot undo, and WHY — read off the binary rather than assumed.
local RECLAIM = {
    item    = { can = true,  limit = "the local player's own bag only, and it needs a spawned "
                             .. "weapon actor; an item moved to a chest is out of reach" },
    passive = { can = true,  limit = "per actor you can hold — party pals and the player, not "
                             .. "the box" },
    tech    = { can = false, limit = "IMPOSSIBLE: UPalCheatManager declares four unlock entries "
                             .. "and no lock; LockTechnology / RemoveTechnology / "
                             .. "ResetTechnology / ForgetTechnology are ZERO hits in Pal.hpp. "
                             .. "unlock() is one-way" },
    pal     = { can = false, limit = "there is no per-individual removal; the cheat manager's "
                             .. "deletions are world-scale" },
}

--=============================================================================
-- the pack handle — PalForge.pack("mypack").store
--=============================================================================

-- Copy a value out of the runtime's tables. The depth cap is the cheap defence against a
-- cycle a pack built in memory after a load: the value was validated on the way IN, but
-- nothing re-validates a live table between two flushes, and a copy that recurses forever
-- would take the whole scan down.
local function deepCopy(v, depth)
    if type(v) ~= "table" then return v end
    if (depth or 0) > 16 then return nil end
    local out = {}
    for k, sub in pairs(v) do out[k] = deepCopy(sub, (depth or 0) + 1) end
    return out
end

-- The pack's own key/value table, read from disk on FIRST TOUCH and not before. storeFor()
-- itself opens nothing — that is what keeps "a pack installed but registering nothing costs
-- zero reads" true for a pack that never calls its store either.
local function dataOf(packId)
    syncSave()
    if not S.loaded[packId] then M.loadPack(packId) end
    local d = S.data[packId]
    if not d then d = {}; S.data[packId] = d end
    return d
end

local function ledgerOf(packId)
    syncSave()
    if not S.loaded[packId] then M.loadPack(packId) end
    local l = S.ledger[packId]
    if not l then l = {}; S.ledger[packId] = l end
    return l
end

---The handle a pack gets as `PalForge.pack("mypack").store`. Memoized, and the pack id is
---BAKED IN — there is no way to name another pack's store through it. Touches no disk:
---building it creates no file and no directory.
---
---`packVer` is the pack's own declared version (`api.pack(id, { version = "1.0.0" })`). It is
---written into the file header as `palforge.packVer` and read by nothing: it is there so a
---state file can say which build of a pack wrote it, which is the first question asked when a
---record looks wrong after an update. It rides here because api/init.lua's scoped table is
---memoized around this call and there is no other moment at which the version is known.
---@param packId string
---@param packVer string?
---@return table store
function M.storeFor(packId, packVer)
    packId = normPack(packId)
    if type(packVer) == "string" and #packVer > 0 then metaFor(packId).packVer = packVer end
    local held = S.stores[packId]
    if held then return held end

    local db = {}

    -- ---- the pack's own key/value data ----

    function db.get(key)
        if type(key) ~= "string" then return nil end
        return dataOf(packId)[key]
    end

    -- VALIDATES NOW, at the pack's own call site, and says what is wrong in the pack's own
    -- vocabulary. The alternative is a value that encodes to `null` ten minutes later inside
    -- a flush the author never sees.
    function db.set(key, value)
        if type(key) ~= "string" or #key == 0 then
            return false, string.format("%s:store.set: the key must be a non-empty string", packId)
        end
        local ok, path, why = M.check(value)
        if not ok then
            local where = (path and #path > 0) and (key .. "." .. path) or key
            return false, string.format("%s:store.set(%q): field %s %s", packId, key, where,
                tostring(why or "cannot be saved"))
        end
        dataOf(packId)[key] = value
        M.markDirty(packId)
        return true
    end

    function db.delete(key)
        local d = dataOf(packId)
        if type(key) ~= "string" or d[key] == nil then return false end
        d[key] = nil
        M.markDirty(packId)
        return true
    end

    function db.keys()
        local out = {}
        for k in pairs(dataOf(packId)) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    -- The LIVE table: mutate it and call save(). Handed out deliberately — a pack's own
    -- key/value data is the pack's, unlike a structure record, which the runtime also holds.
    function db.data() return dataOf(packId) end

    function db.save()
        syncSave()
        M.markDirty(packId)
        return M.flush(packId)
    end

    -- ---- structures ----

    -- That structure's state table — the SAME table the instance's self.state is, so a
    -- mutation here is written on the next flush. Answers only for records THIS pack owns.
    function db.building(instOrKey)
        local key = type(instOrKey) == "table" and instOrKey.key or instOrKey
        if type(key) ~= "string" then return nil end
        syncSave()
        local w = S.world
        local rec = w.entities[key] or w.orphans[key]
        if type(rec) ~= "table" or packOfRec(rec) ~= packId then return nil end
        if type(rec.state) ~= "table" then rec.state = {} end
        return rec.state
    end

    -- COPIES. This is the hole it closes: PalForge.utils.file.get(key) used to hand a pack
    -- the runtime's LIVE record table, so a pack could rewrite another pack's records — or
    -- its own key — by accident and the runtime would never know.
    function db.buildings()
        syncSave()
        local out = {}
        local function add(src, quarantined)
            for key, rec in pairs(src) do
                if type(rec) == "table" and packOfRec(rec) == packId then
                    out[#out + 1] = {
                        key         = key,
                        buildId     = rec.buildId,
                        def         = rec.def,
                        pos         = rec.pos and { x = rec.pos.x, y = rec.pos.y, z = rec.pos.z } or nil,
                        state       = deepCopy(rec.state),
                        orphanedAt  = rec.orphanedAt,
                        why         = rec.why,
                        quarantined = quarantined or nil,
                    }
                end
            end
        end
        add(S.world.entities, false)
        add(S.world.orphans, true)
        table.sort(out, function(a, b) return a.key < b.key end)
        return out
    end

    -- ---- the ledger ----

    function db.ledger() return deepCopy(ledgerOf(packId)) end

    ---What this pack made the game record, and what of it can be taken back. `opts.apply`
    ---attempts the reclaim; without it this is a REPORT and nothing is undone. The report
    ---NAMES what it could not undo, which is the half that matters: a technology unlock
    ---cannot be reversed at all and the report says so in those words.
    function db.reclaim(opts)
        opts = type(opts) == "table" and opts or {}
        local led = ledgerOf(packId)
        local rep = { pack = packId, save = M.saveDir(), applied = opts.apply == true,
                      entries = {}, unreclaimable = {} }
        for _, kind in ipairs(M.LEDGER_KINDS) do
            local bucket = led[kind]
            if type(bucket) == "table" then
                local ids = {}
                for id in pairs(bucket) do ids[#ids + 1] = id end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    local e   = bucket[id]
                    local rule = RECLAIM[kind]
                    local row = { kind = kind, id = id, n = tonumber(e.n) or 0, at = e.at,
                                  reclaimable = rule.can, limit = rule.limit,
                                  status = rule.can and "reclaimable" or "impossible" }
                    if not rule.can then rep.unreclaimable[#rep.unreclaimable + 1] = row end
                    rep.entries[#rep.entries + 1] = row
                end
            end
        end
        -- The DOING half is deliberately not built here: it needs api/item's take and
        -- core/character's RemovePassiveSkill, and this module requires nothing from api/ —
        -- that is what keeps the dependency graph acyclic. This delivers reclaim's INPUT.
        if rep.applied then
            for _, row in ipairs(rep.entries) do
                if row.reclaimable then row.status = "not attempted (no reclaim driver on this build)" end
            end
        end
        local parts = {}
        for _, row in ipairs(rep.entries) do
            parts[#parts + 1] = string.format("%s %s x%d (%s)", row.kind, row.id, row.n,
                row.reclaimable and "reclaimable" or "CANNOT be undone")
        end
        rep.text = (#parts == 0)
            and string.format("'%s' has asked the game to record nothing in save %s, so there "
                .. "is nothing to reclaim.", packId, M.saveDir())
            or string.format("'%s' made the game record %d thing(s) in save %s: %s. A technology "
                .. "unlock can NEVER be undone — the cheat manager declares four unlocks and no "
                .. "lock — so an uninstall leaves those names in the save with no DataTable row "
                .. "behind them.", packId, #rep.entries, M.saveDir(), table.concat(parts, ", "))
        return rep
    end

    -- ---- where and how it is ----

    function db.saveId() return M.saveDir() end
    function db.path()   return IO.path and IO.path(internalKey(packId)) or ("state/" .. internalKey(packId) .. ".json") end
    function db.stats()  return M.stats(packId) end
    function db.diagnose() return M.diagnose(packId) end

    S.stores[packId] = db
    return db
end

--=============================================================================
-- reporting
--=============================================================================

---Everything a log line or a diagnostic needs about one pack's file.
---@param packId string?
---@return table
function M.stats(packId)
    packId = normPack(packId)
    syncSave()
    local meta = S.meta[packId] or {}
    local key  = internalKey(packId)
    local nb, no = 0, 0
    for _, rec in pairs(S.world.entities) do
        if type(rec) == "table" and packOfRec(rec) == packId then nb = nb + 1 end
    end
    for _, rec in pairs(S.world.orphans) do
        if type(rec) == "table" and packOfRec(rec) == packId then no = no + 1 end
    end
    local nd, nl = 0, 0
    for _ in pairs(S.data[packId] or {}) do nd = nd + 1 end
    for _, bucket in pairs(S.ledger[packId] or {}) do
        for _ in pairs(bucket) do nl = nl + 1 end
    end
    return {
        pack      = packId,
        path      = IO.path and IO.path(key) or ("state/" .. key .. ".json"),
        bytes     = meta.bytes,
        buildings = nb,
        orphans   = no,
        data      = nd,
        ledger    = nl,
        loaded    = S.loaded[packId] == true,
        dirty     = S.dirty[packId] == true,
        lastWrite = meta.lastWrite,
        lastError = meta.lastError,
        health    = meta.health or "unread",
    }
end

local function human(bytes)
    if type(bytes) ~= "number" then return "not written yet" end
    if bytes < 1024 then return string.format("%d bytes", bytes) end
    return string.format("%.1f KB", bytes / 1024)
end

local function ago(ts)
    if type(ts) ~= "number" then return nil end
    local d = os.time() - ts
    if d < 2 then return "just now" end
    if d < 120 then return string.format("%d seconds ago", d) end
    if d < 7200 then return string.format("%d minutes ago", math.floor(d / 60)) end
    return string.format("%d hours ago", math.floor(d / 3600))
end

---One English paragraph about one pack's state, for a log line or a support question at 2am.
---@param packId string?
---@return string
function M.diagnose(packId)
    packId = normPack(packId)
    local st = M.stats(packId)
    local parts = {}
    parts[#parts + 1] = string.format("Pack '%s', save %s%s: %d structure%s and %d saved value%s, "
        .. "in %s (%s).", packId,
        saveName() and string.format("%q ", saveName()) or "",
        M.saveDir(), st.buildings, st.buildings == 1 and "" or "s",
        st.data, st.data == 1 and "" or "s", st.path, human(st.bytes))
    local when = ago(st.lastWrite)
    parts[#parts + 1] = when and string.format("Last written %s.", when)
        or "It has not been written this session."
    if st.orphans > 0 then
        -- Name the OLDEST quarantined record: "one of them" is not something anyone can act on.
        local oldestKey, oldest = nil, nil
        for key, rec in pairs(S.world.orphans) do
            if type(rec) == "table" and packOfRec(rec) == packId then
                local t = tonumber(rec.orphanedAt) or 0
                if oldest == nil or t < oldest then oldest, oldestKey = t, key end
            end
        end
        local rec = oldestKey and S.world.orphans[oldestKey] or nil
        local why = (rec and rec.why == "missing")
            and "the structure stopped being reported by the world scan"
            or string.format("no loaded definition claims the build id %q",
                tostring(rec and rec.buildId or "?"))
        parts[#parts + 1] = string.format("%d record%s quarantined: %s has been kept since %s "
            .. "because %s; it will come back by itself if that structure or that definition "
            .. "returns.", st.orphans, st.orphans == 1 and " is" or "s are", tostring(oldestKey),
            (oldest and oldest > 0) and os.date("!%Y-%m-%d", oldest) or "an unrecorded date", why)
    end
    if st.ledger > 0 then
        parts[#parts + 1] = string.format("%d id%s recorded in the ledger — those are names this "
            .. "pack asked the GAME to write into its own save.", st.ledger,
            st.ledger == 1 and " is" or "s are")
    end
    parts[#parts + 1] = st.lastError and string.format("⚠️ %s", tostring(st.lastError))
        or "Nothing has failed."
    parts[#parts + 1] = "The Palworld save itself is untouched — PalForge has never written to it."
    return table.concat(parts, " ")
end

---Every pack this save's store knows about, with its stats. Uses the manifest to name packs
---whose files exist but were never loaded (nothing else can list a directory from Lua) —
---and READS NOTHING ELSE: a pack that is merely named here still costs zero file opens.
---@return table
function M.audit()
    syncSave()
    local out = { save = M.saveDir(), packs = {} }
    local names, seen = {}, {}
    for _, p in ipairs(knownPacks()) do
        if not seen[p] then seen[p] = true; names[#names + 1] = p end
    end
    local man = readManifest()
    if man and type(man.packs) == "table" then
        for _, p in ipairs(man.packs) do
            if type(p) == "string" and not seen[p] then seen[p] = true; names[#names + 1] = p end
        end
    end
    table.sort(names)
    for _, p in ipairs(names) do out.packs[#out.packs + 1] = M.stats(p) end
    out.migrated = S.migrated or (man and man.migrated) or nil
    return out
end

---Adopt every file in this save's folder that names a DIFFERENT save — the one-call escape
---hatch for the legitimate "I copied a world" case. It clears the refusal and re-reads; the
---next flush rewrites each file with this save's id in it.
---@return integer adopted
function M.rebind()
    syncSave()
    local n = 0
    for p, meta in pairs(S.meta) do
        if meta.health == "save-mismatch" then
            meta.health, meta.readOnly, meta.lastError = "unread", nil, nil
            S.loaded[p] = nil
            IO.forget(internalKey(p))
            S.adopting = true
            local ok = M.loadPack(p)
            S.adopting = nil
            if ok then n = n + 1; M.markDirty(p) end
        end
    end
    log.info(string.format("rebind: %d state file(s) in state/%s/ were adopted by this save. "
        .. "They will be rewritten with this save's id on the next flush", n, M.saveDir()))
    return n
end

---Delete one pack's file for this save. The player-facing spelling of "this mod is gone and
---I want its state gone too" — and the only DESTRUCTIVE call in this module, which is why it
---is a call and never something that happens by itself.
---@param packId string
---@return boolean ok, string? err
function M.uninstall(packId)
    packId = normPack(packId)
    syncSave()
    local key = internalKey(packId)
    local ok, err = IO.remove(key)
    S.loaded[packId], S.dirty[packId], S.seen[packId] = nil, nil, nil
    S.data[packId], S.ledger[packId], S.meta[packId] = nil, nil, nil
    for k, rec in pairs(S.world.entities) do
        if type(rec) == "table" and packOfRec(rec) == packId then S.world.entities[k] = nil end
    end
    for k, rec in pairs(S.world.orphans) do
        if type(rec) == "table" and packOfRec(rec) == packId then S.world.orphans[k] = nil end
    end
    S.manifestSig = nil
    log.warn(string.format("uninstall: state/%s.json %s. This deletes the state PalForge kept "
        .. "for '%s' in this save; Palworld's own save is not touched", key,
        ok and "was DELETED" or ("was not deleted (" .. tostring(err) .. ")"), packId))
    return ok, err
end

---Every pack this session has loaded or written, sorted. (Not the same question as
---object_manager.packs(), which answers "who has DEFINED anything".)
---@return string[]
function M.packs()
    syncSave()
    return knownPacks()
end

---Drop every cache without writing anything. Tests only — a session uses unload().
---S.warned is deliberately NOT cleared: "once per distinct reason" is a property of the
---SESSION's log, not of a world, and a suite that resets between checks would otherwise
---print the same warning once per check.
function M.__reset()
    for k in pairs(S.world.entities) do S.world.entities[k] = nil end
    for k in pairs(S.world.orphans)  do S.world.orphans[k]  = nil end
    for _, t in ipairs({ S.loaded, S.dirty, S.data, S.ledger, S.meta, S.seen, S.stores }) do
        for k in pairs(t) do t[k] = nil end
    end
    S.save, S.migrated, S.manifestSig, S.readme = nil, nil, nil, false
    S.migratedRead = nil
end

return M
