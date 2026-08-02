-- PalForge core.spatial: world-position quantization, per-instance keys, a
-- hash-grid neighbour index, and the persistence world id. Self-contained generic
-- primitive. Pure except saveId() which probes UE globals lazily (falls back to a
-- single "world" bucket). Ported from the old runtime.
--
-- A placed building has no stable per-instance id we control (actor full-names
-- are volatile, and reused vanilla BPs share a class name). We therefore key an
-- instance by its QUANTIZED WORLD POSITION (a BlockPos analog):
--   key = "<buildId>@<qx>,<qy>,<qz>"
-- The canonical position is always the live actor's GetActorLocation.
--
-- WHAT THE KEY DOES NOT CARRY, AND WHERE THAT LIVES INSTEAD (F-7). `buildId` is the
-- RESOLVED game build id — "WorkBench", "mypack_Bench" — because it is matched against what
-- the game emits, and it therefore names no pack and no definition. So the key alone cannot
-- answer "whose record is this?", and a persistence file shared by every pack needs an
-- answer. It is not fixed by widening the key: changing the key format invalidates every
-- record every player already has, and the pack id is not knowable from an actor in the
-- world. The owner rides INSIDE the record instead — core/event.lua writes `v` (record
-- version), `def` (the definition id, e.g. "mypack:Bench") and `pack` (the owning pack id,
-- when object_manager can attribute it) into every record and stamps old ones on first bind.
--
-- TWO CONSEQUENCES OF A POSITIONAL KEY, both deliberate and both worth knowing:
--   * Renaming what a definition attaches to changes the key, so nothing migrates by
--     itself. core/event.lua migrates the one unambiguous case (the record still names a
--     registered definition, and that definition now claims exactly one build id) and
--     QUARANTINES the rest rather than deleting them, so the player's state survives a
--     rename and comes back if the id comes back. See its header for the whole policy.
--   * Two definitions that resolve to the same build id share one key space and therefore
--     one record. core/event.lua's refreshDefs picks a deterministic winner and logs the
--     collision; it cannot split the state, because there is only one structure standing
--     there and only one record describing it.
--
-- The neighbour index is not automatic: it has a small drive contract (what to call
-- on place, on remove and to query) written out at "hash-grid neighbour index" below.
local M = {}

M.GRID_CM = 100  -- default cell size (1 m). Dense entities (pipes) can override.

-- round-to-nearest; correct for negatives in Lua (floor(x+0.5)).
local function q(v, grid)
    return math.floor(v / grid + 0.5)
end

-- pos = {x,y,z}; returns {qx,qy,qz} integer cell indices.
function M.cellOf(pos, grid)
    grid = grid or M.GRID_CM
    return { qx = q(pos.x or 0, grid), qy = q(pos.y or 0, grid), qz = q(pos.z or 0, grid) }
end

function M.keyOf(buildId, cell)
    return string.format("%s@%d,%d,%d", buildId, cell.qx, cell.qy, cell.qz)
end

function M.posKey(buildId, pos, grid)
    return M.keyOf(buildId, M.cellOf(pos, grid))
end

-- squared distance between two {x,y,z} (cm^2).
local function dist2(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end
M.dist2 = dist2

-- ---- hash-grid neighbour index ----
-- Buckets instances by a coarse cell so neighbour queries are O(neighbours), not
-- O(all buildings). Bucket size is a fixed coarse grid independent of per-entity
-- GRID overrides. The index is a plain in-memory map over whatever the caller puts
-- in it: it stores instance TABLES (anything carrying `pos = {x,y,z}`), never reads
-- the game, and holds STRONG references — an instance dropped without indexRemove
-- stays alive in here until indexReset.
--
-- DRIVING IT — the whole contract, in call order (the building runtime's function is named
-- rather than its line, because the line moves and the name does not):
--   on place / load   spatial.indexAdd(inst)       -- core/event.lua  addInstance
--   on remove         spatial.indexRemove(inst)    -- core/event.lua  removeInstance
--   on world left     spatial.indexReset()         -- core/event.lua  dropAllInstances
--   after a move      spatial.indexUpdate(inst)    -- core/event.lua  scanOnce, fast path
--   to query          spatial.neighbors(pos, radiusCm, exclude) -> { inst, ... }
--
-- Placed buildings are therefore already in the index; querying is the caller's half
-- and needs nothing but a position (core.spatial is public as PalForge.core.spatial):
--
--   local spatial = require("palforge.core.spatial")
--   for _, inst in ipairs(require("palforge.core.event").instances("MyPipe")) do
--       local near = spatial.neighbors(inst.pos, 350, inst)   -- everything within 3.5 m
--   end
--
-- THE IN-TREE CONSUMER is api/building's `Building.Instance:neighbors(radiusCm)` — the
-- same two calls, wrapped so a pack writes `self:neighbors(350)` inside any instance hook.
-- It runs reindexAll over core.event.instances() first, which is what closes the gap
-- below for every api-level caller. The ORIGINAL consumer, and the reason the grid is
-- shaped this way, is the sibling mod's logistics graph (PalLogistics/network.lua:108,140
-- — exactly the loop above at CONNECT_RADIUS 350, then union-find over the resulting
-- adjacency); that file is a reference, not a live caller, since it still requires the
-- removed `palsmith.*` modules and would need its requires swapped to palforge.core.*.
--
-- THE KNOWN GAP IS CLOSED, and the history is worth keeping because the shape of it recurs.
-- This header used to say the building scan refreshed an instance's position in place
-- (`bound.pos = p`) WITHOUT re-bucketing it, so an instance that moved far enough kept its
-- old bucket and a raw neighbors() could miss it — and that the one-line fix belonged to the
-- building runtime. The call was in fact already written there, on the line below that
-- refresh; what was broken was the lookup above it. The scan found the instance for an actor
-- through a table keyed on the actor USERDATA, UE4SS mints a fresh wrapper per lookup, and
-- the scan re-reads its actors from FindAllOf every pass — so the fast path missed on every
-- sweep after the first and neither the position refresh nor the re-bucket ever ran at all.
-- Re-keying that table on core.uobject.key (contract C1) is what made this hook real. The
-- lesson core.spatial keeps from it: an index whose driver is somebody else's code is only
-- as live as that driver's own identity model.
--
-- reindexAll below is therefore no longer a workaround for a missing hook, but it stays: a
-- caller with instances the building runtime does not own — anything a pack indexes itself —
-- still has no driver, and Building.Instance:neighbors keeps calling it because O(tracked)
-- pure Lua is cheaper than reasoning about whether the last scan has run yet.
M.BUCKET_CM = 200

-- THE INDEX LIVES ON _G, for the same reason core/event's instance registry does. A hot
-- reload (F9) builds a fresh core.spatial while the building runtime's live instances —
-- which are held on _G — keep existing, and every one of them carries an `_bucket` string
-- naming a bucket in the index that was current when it was added. A fresh empty table here
-- would mean neighbors() answering {} for a base full of structures, with `_bucket` set on
-- every instance and no bucket to match it. Sharing the table keeps the two halves of the
-- index — the buckets here and the `_bucket` stamps out there — describing one thing.
M.index = _G.__PalForgeSpatialIndex or {}   -- bucketKey -> { [instance]=true }
_G.__PalForgeSpatialIndex = M.index

local function bucketKey(pos)
    return string.format("%d,%d,%d",
        math.floor((pos.x or 0) / M.BUCKET_CM),
        math.floor((pos.y or 0) / M.BUCKET_CM),
        math.floor((pos.z or 0) / M.BUCKET_CM))
end

function M.indexAdd(instance)
    if not (instance and instance.pos) then return end
    local bk = bucketKey(instance.pos)
    instance._bucket = bk
    local b = M.index[bk]; if not b then b = {}; M.index[bk] = b end
    b[instance] = true
end

function M.indexRemove(instance)
    local bk = instance and instance._bucket
    if bk and M.index[bk] then
        M.index[bk][instance] = nil
        if next(M.index[bk]) == nil then M.index[bk] = nil end
    end
    if instance then instance._bucket = nil end
end

-- Re-bucket an instance whose position changed.
function M.indexUpdate(instance)
    if not instance then return end
    local nb = instance.pos and bucketKey(instance.pos) or nil
    if nb ~= instance._bucket then
        M.indexRemove(instance)
        M.indexAdd(instance)
    end
end

-- Re-bucket a whole collection: `instances` is any table whose VALUES are instances —
-- an array (core.event.instances(buildId)) or a key->instance map. Returns how many
-- entries were visited. This is the caller-side stand-in for the missing per-scan
-- indexUpdate hook described in the section header: run it once before a batch of
-- neighbour queries if your instances can move. It is O(n) and touches buckets only for
-- the entries whose cell actually changed, so re-running it on a static base is cheap.
-- It does NOT remove index entries that are absent from `instances` — dropping an
-- instance is still indexRemove's job.
function M.reindexAll(instances)
    if type(instances) ~= "table" then return 0 end
    local n = 0
    for _, inst in pairs(instances) do
        if type(inst) == "table" and inst.pos then
            M.indexUpdate(inst)
            n = n + 1
        end
    end
    return n
end

-- Instances within `radiusCm` of `pos`, excluding `exclude`. Scans a
-- (2*span+1)^3 block of buckets, span = ceil(radiusCm / BUCKET_CM). This is
-- provably enough: two points radiusCm apart differ by at most
-- ceil(radiusCm / BUCKET_CM) bucket indices on any axis, so no in-radius edge is
-- missed at a bucket boundary -- including radius > BUCKET_CM (e.g. 350 -> span 2).
function M.neighbors(pos, radiusCm, exclude)
    local out = {}
    if not pos then return out end
    local r2 = radiusCm * radiusCm
    local span = math.max(1, math.ceil(radiusCm / M.BUCKET_CM))
    local bx = math.floor((pos.x or 0) / M.BUCKET_CM)
    local by = math.floor((pos.y or 0) / M.BUCKET_CM)
    local bz = math.floor((pos.z or 0) / M.BUCKET_CM)
    for dx = -span, span do
        for dy = -span, span do
            for dz = -span, span do
                local b = M.index[string.format("%d,%d,%d", bx + dx, by + dy, bz + dz)]
                if b then
                    for inst in pairs(b) do
                        if inst ~= exclude and inst.pos and dist2(pos, inst.pos) <= r2 then
                            table.insert(out, inst)
                        end
                    end
                end
            end
        end
    end
    return out
end

-- Empty the index. CLEARED IN PLACE, never replaced: the table is shared through _G (see
-- M.index above), so assigning a fresh one would leave a pre-reload module — and anything
-- that captured `spatial.index` in a local — reading a table this module no longer writes.
function M.indexReset()
    for k in pairs(M.index) do M.index[k] = nil end
end

-- ---- world/save id for the persistence namespace ----
-- Memoized. Reads the selected save off the live PalGameInstance; falls back to a single
-- "world" bucket. The seams (FindFirstOf) are read lazily so headless tests that don't
-- define them get the fallback.
--
-- MEASURED (dumps/reflection/02_reflection.txt, /Script/Pal.PalGameInstance). The class
-- carries BOTH a getter and a backing field for the selected save, and for the world's
-- display name beside it:
--     [functions]  .GetSelectedWorldSaveDirectoryName   .GetSelectedWorldName
--     [properties] :SelectedWorldSaveDirectoryName      :SelectedWorldName
-- The save DIRECTORY name is the identity we want: it is the per-save folder the game
-- writes into, so two saves cannot share it, whereas :SelectedWorldName is the label the
-- player typed and two saves may well carry the same one. The name is therefore tried
-- first and the display name only as a second chance.
--
-- The same 111-property listing settles the previous guesses in the negative: WorldGuid,
-- WorldSaveName and SaveName appear nowhere on the class, so the old probe could only ever
-- have produced the "world" fallback — which is exactly the one artifact a real session
-- left behind (`state/entities_world.json`, PalSmith commit dc206a6).
--
-- WHAT IS STILL INFERRED: 02_reflection lists NAMES only, never signatures, so the getters
-- are called no-arg and every read is pcall'd; and the values have not been compared
-- across two save files, so per-save uniqueness rests on what the name means. Both
-- residuals are safe — a raising call, an empty string or a value that turns out to be
-- constant just lands back on the shared "world" bucket, which is the documented normal
-- case (keys are position-based and a record only binds when an actor of the right build
-- id is standing there), not an error path.
local cachedSaveId = nil

-- Coerce one reflected value to a non-empty Lua string, or nil. An FString arrives as a
-- plain string and an FName-like arrives with :ToString(); NOTHING ELSE is accepted. In
-- particular there is deliberately no tostring() fallback: a reflected call that hands back
-- a table (UE4SS wraps multiple out-params that way) would stringify to its ADDRESS, which
-- differs every launch and would rename the persistence file on every session.
local function asName(v)
    local s
    if type(v) == "string" then
        s = v
    elseif type(v) == "number" then
        s = tostring(v)
    elseif type(v) == "table" or type(v) == "userdata" then
        local ok, t = pcall(function() return v.ToString and v:ToString() end)
        if ok and type(t) == "string" then s = t end
    end
    if type(s) ~= "string" or s == "" or s == "None" then return nil end
    return s
end

local function tryProbe()
    if type(FindFirstOf) ~= "function" then return nil end
    local ok, id = pcall(function()
        local gi = FindFirstOf("PalGameInstance")
        if not (gi and gi:IsValid()) then return nil end
        -- Getter first, backing property second, for each of the two measured names.
        for _, pair in ipairs({
            { "GetSelectedWorldSaveDirectoryName", "SelectedWorldSaveDirectoryName" },
            { "GetSelectedWorldName", "SelectedWorldName" },
        }) do
            local okF, v = pcall(function() return gi[pair[1]] and gi[pair[1]](gi) end)
            local s = okF and asName(v) or nil
            if not s then
                local okP, pv = pcall(function() return gi[pair[2]] end)
                s = okP and asName(pv) or nil
            end
            if s then return s end
        end
        return nil
    end)
    return ok and id or nil
end

function M.saveId()
    if cachedSaveId then return cachedSaveId end
    local probed = tryProbe()
    cachedSaveId = probed and ("w_" .. probed:gsub("[^%w_]", "_")) or "world"
    return cachedSaveId
end

function M.resetSaveId() cachedSaveId = nil end

return M
