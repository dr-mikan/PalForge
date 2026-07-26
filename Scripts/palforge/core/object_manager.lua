-- PalForge core.object_manager: namespaced ID resolution + a central registry
-- of the framework's object classes across TYPES. Self-contained generic primitive
-- (no PalForge deps). Grew out of the old core.util.ids (resolve / ownership /
-- import / display are unchanged) with a cross-type registry added on top.
--
-- ID model (unchanged from ids): content packs use namespaced ids "packid:name". In
-- the game's DataTables the corresponding row FName is "<packid>_<name>" (PalSchema
-- rows are global, so the pack id prefix prevents collisions between packs). Ids
-- WITHOUT a colon are literal game ids ("Wood", "BlueSkyDragon").
--
-- Registry: each domain's definition call registers its class here, keyed by object TYPE:
--   register("building", "example:Bench", cls)
--   get("building", "example:Bench")  -> cls | nil
--   all("building")                   -> { id -> cls }  (a snapshot copy)
-- Type is one of: item | pal | building | skill | effect | audio | mesh | ui (one per api module).
local M = {}

local VALID = "^[%w_]+$"

-- "packid:name" -> "packid_name"; "Literal" -> "Literal".
-- Returns resolved string, or nil + error.
function M.resolve(id)
    if type(id) ~= "string" or #id == 0 then return nil, "id must be a non-empty string" end
    local pack, name = id:match("^([^:]+):(.+)$")
    if not pack then return id end -- literal game id
    if not pack:match(VALID) then return nil, "invalid pack id '" .. pack .. "' (letters/digits/_ only)" end
    if not name:match(VALID) then return nil, "invalid name '" .. name .. "' (letters/digits/_ only)" end
    return pack .. "_" .. name
end

-- KEY OWNERSHIP: a pack may only ATTACH behaviors/meshes to ids in its own
-- namespace, or to literal ids. (The id a behavior is keyed on.)
function M.checkOwnership(id, packId)
    local pack = id:match("^([^:]+):")
    if pack and pack ~= packId then
        return false, string.format("'%s' declares an id in namespace '%s' (pack is '%s')", id, pack, packId)
    end
    return true
end

-- VALUE REFERENCE / IMPORT: an id MENTIONED inside args (e.g. give_item.item =
-- "otherpack:Thing"). Allowed only for the pack's own namespace, a literal id,
-- or a namespace the pack declared as a dependency. `declaredDeps` is a set-like
-- table (namespace -> anything) built from depends ∪ recommends. Soft (warning).
function M.checkImport(refId, packId, declaredDeps)
    if type(refId) ~= "string" then return true end
    local ns = refId:match("^([^:]+):")
    if not ns then return true end                 -- literal id
    if ns == packId then return true end           -- own namespace
    if declaredDeps and declaredDeps[ns] then return true end
    return false, string.format("references '%s' but does not declare a dependency on '%s'", refId, ns)
end

-- Reverse mapping for display: "packid_name" -> "packid:name".
-- Preferred form: pass the idregistry (has an authoritative `reverse` map, O(1),
-- unambiguous). Legacy form: pass a set of known pack ids (best-effort,
-- longest-prefix wins to reduce the `_`-in-name ambiguity).
function M.display(fname, source)
    if type(source) == "table" and source.reverse then
        local exact = source.reverse[fname]
        if exact then return exact end
        source = source._knownPacks or nil -- optional fallback set on the registry
    end
    if type(source) == "table" then
        local bestPack, bestLen = nil, -1
        for pack in pairs(source) do
            local prefix = pack .. "_"
            if #pack > bestLen and fname:sub(1, #prefix) == prefix then
                bestPack, bestLen = pack, #pack
            end
        end
        if bestPack then return bestPack .. ":" .. fname:sub(#bestPack + 2) end
    end
    return fname
end

-- ---- central object registry (across TYPES) ----

-- The object types the registry accepts — one per api module. Kept explicit so a typo'd
-- type is caught (register/get/all fail-soft return on an unknown type rather than
-- silently creating a junk bucket).
local VALID_TYPES = {
    item = true, pal = true, building = true, skill = true, effect = true,
    audio = true, mesh = true, ui = true,
}

-- Exposed so tooling can enumerate the registry without hard-coding the list.
M.TYPES = {}
for t in pairs(VALID_TYPES) do M.TYPES[#M.TYPES + 1] = t end
table.sort(M.TYPES)

-- type -> { id -> cls }
local registry = {}

-- Register a class under (otype, id). `otype` is named to avoid shadowing type().
-- Returns cls on success, or nil + error (fail-soft: never throws). A definition calls
-- this best-effort so a registry hiccup can't break class definition.
function M.register(otype, id, cls)
    if not VALID_TYPES[otype] then
        return nil, "object_manager.register: unknown type '" .. tostring(otype) .. "'"
    end
    if type(id) ~= "string" or #id == 0 then
        return nil, "object_manager.register: id must be a non-empty string"
    end
    registry[otype] = registry[otype] or {}
    registry[otype][id] = cls
    return cls
end

-- Look up a registered class. Returns cls or nil.
function M.get(otype, id)
    local bucket = registry[otype]
    return bucket and bucket[id] or nil
end

-- Snapshot of every registered class of a type: { id -> cls }. Returns a shallow
-- copy so callers can't mutate the live registry.
function M.all(otype)
    local out = {}
    local bucket = registry[otype]
    if bucket then
        for id, cls in pairs(bucket) do out[id] = cls end
    end
    return out
end

return M
