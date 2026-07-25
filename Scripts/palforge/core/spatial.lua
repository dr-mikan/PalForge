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
-- O(all buildings). The domain calls indexAdd/indexRemove on instance add/remove.
-- Bucket size is a fixed coarse grid independent of per-entity GRID overrides.
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
