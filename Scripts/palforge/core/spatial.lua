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
-- DRIVING IT — the whole contract, in call order:
--   on place / load   spatial.indexAdd(inst)       -- building runtime: core/event.lua:253
--   on remove         spatial.indexRemove(inst)    -- building runtime: core/event.lua:269
--   on world left     spatial.indexReset()         -- building runtime: core/event.lua:492
--   after a move      spatial.indexUpdate(inst)    -- NOBODY calls this; see the gap below
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
-- Nothing in PalForge queries it today. The consumer it was built for is the sibling
-- mod's logistics graph (PalLogistics/network.lua: exactly the call above at
-- CONNECT_RADIUS 350, then union-find over the resulting adjacency) — a reference, not
-- a live caller: that file still requires the removed `palsmith.*` modules and would
-- need its requires swapped to palforge.core.* before it loads again.
--
-- KNOWN GAP, deliberately NOT fixed here: the building scan refreshes an instance's
-- position in place (core/event.lua:359 `bound.pos = p`) without re-bucketing it, so an
-- instance that MOVES far enough keeps its old bucket and a query can miss it. The fix is
-- one line — spatial.indexUpdate(bound) next to that refresh — but it belongs to the
-- building runtime, and core.spatial deliberately knows nothing about it. Until that hook
-- exists, a caller whose instances can move calls reindexAll() before a batch of queries.
M.BUCKET_CM = 200
M.index = {}  -- bucketKey -> { [instance]=true }

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

function M.indexReset()
    M.index = {}
end

-- ---- world/save id for the persistence namespace ----
-- Memoized. Probes a few likely sources; falls back to a single "world" bucket
-- (fine for the single-player slice). The seams (FindFirstOf) are read lazily so
-- headless tests that don't define them get the fallback.
local cachedSaveId = nil

local function tryProbe()
    if type(FindFirstOf) ~= "function" then return nil end
    local ok, id = pcall(function()
        local gi = FindFirstOf("PalGameInstance")
        if gi and gi:IsValid() then
            for _, field in ipairs({ "WorldGuid", "WorldSaveName", "SaveName" }) do
                local okf, v = pcall(function() return gi[field] end)
                if okf and v then
                    local oks, s = pcall(function() return v.ToString and v:ToString() or tostring(v) end)
                    if oks and s and #s > 0 then return s end
                end
            end
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
