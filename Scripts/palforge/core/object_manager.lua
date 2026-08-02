-- PalForge core.object_manager: namespaced ID resolution + a central registry
-- of the framework's object classes across TYPES. Grew out of the old core.util.ids
-- (resolve / ownership / import / display are unchanged) with a cross-type registry
-- added on top.
--
-- ID model (unchanged from ids): content packs use namespaced ids "packid:name". In
-- the game's DataTables the corresponding row FName is "<packid>_<name>" (PalSchema
-- rows are global, so the pack id prefix prevents collisions between packs). Ids
-- WITHOUT a colon are literal game ids ("Wood", "BlueSkyDragon"). The spelling was
-- verified against the dumps rather than assumed: the injected rows in DT_ItemDataTable
-- are exactly `PalSmith_TestPotion` and `example_Potion`.
--
-- Registry: each domain's definition call registers its class here, keyed by object TYPE:
--   register("building", "example:Bench", cls)     -- opts = { pack = "example" } | nil
--   get("building", "example:Bench")  -> cls | nil (UNCHANGED: still the class itself)
--   all("building")                   -> { id -> cls }  (a snapshot copy)
--   entry("building", "example:Bench")-> { cls =, pack =, resolved = } | nil (a copy)
--   byResolved("building", "example_Bench") -> cls, id     -- O(1), the dispatch route
--   isRegistered / owner / unregister      -- "is this id taken", "by whom", "forget it"
-- Type is one of: item | pal | building | skill | effect | audio | mesh | ui (one per api module).
--
-- And two things that are about ids rather than about the registry:
--   validId(id)              -> true | false, reason   -- the resolve shape check, run at
--                                                         DEFINE time by the api constructors
--   withPack(pack, fn, ...)  / currentPack()           -- who is defining right now, so a
--                                                         registration can carry an owner
--
-- WHY THE SELF-CONTAINMENT RULE WAS RELAXED. This module used to state "self-contained
-- generic primitive (no PalForge deps)" and that was true while registration was a bare
-- table write. F-1/F-2 are DETECTABILITY defects — a silent overwrite and a silent
-- resolved-form collision — and a diagnostic that is not logged is not a diagnostic, so
-- the module now needs utils.log. The dependency is taken LAZILY, inside the warning
-- path, and behind a pcall that degrades to a no-op logger: nothing here fails to load,
-- or fails to register, because logging is unavailable. That also keeps the module
-- loadable by tooling outside the game and survives F9 (core/reload.lua wipes
-- object_manager but keeps utils.log, so the lazy require re-fetches a live module
-- rather than closing over a wiped one).
--
-- COLLISION POLICY IS LAST-WINS, AND THAT IS DELIBERATE (docs concepts/definitions.mdx,
-- pinned by test/cases/definitions.lua). Re-defining an id replaces the definition; it
-- never adds a second one, and register never throws. What F-1 added is that a collision
-- is now VISIBLE and ATTRIBUTABLE:
--   * a different class under an id another PACK holds -> log.warn naming the type, the
--     id, the previous owner, the new owner, and that the new definition replaces the old;
--   * the SAME owner re-registering (F9 reload, a pack redefining its own id, the test
--     suites, the native catalogs re-materialising a row) -> no warning. utils.log has
--     three levels and no debug, so this is an info line gated on env.debug;
--   * two DIFFERENT source ids that resolve to ONE game row ("my:pack_Thing" and
--     "my_pack:Thing" are both my_pack_Thing) -> log.warn naming both source ids. That is
--     the F-2 diagnostic and it is what the resolved index exists for.
--
-- A PACK THAT DECLARES AN ID IN ANOTHER PACK'S NAMESPACE IS WARNED, AND STILL REGISTERED.
-- The alternative — refuse outright — was rejected for a measurable reason: seven of the
-- eight domains call this inside `pcall(function() om.register(...) end)` and DISCARD the
-- result (api/item.lua, api/building.lua, api/skill.lua, api/effect.lua, api/audio.lua,
-- api/mesh.lua, api/ui.lua); only api/pal.lua inspects it. A refusal would therefore be
-- invisible at the call site: the author would get a live-looking handle back for a
-- definition that was never registered, i.e. exactly the silent-death shape F-4 is about.
-- A loud warning plus last-wins keeps the failure legible. Turning this into a hard
-- refusal is a one-word change here (`return nil, why`) and becomes correct the day every
-- domain surfaces register's nil + reason the way api/pal.lua already does.
local M = {}

local VALID = "^[%w_]+$"

-- ---- the lazy, fail-soft logger (see "WHY THE SELF-CONTAINMENT RULE WAS RELAXED") ----

local logger
local function log()
    if not logger then
        local ok, mod = pcall(require, "palforge.utils.log")
        if ok and type(mod) == "table" and type(mod.scope) == "function" then
            logger = mod.scope("objects")
        else
            -- No logger available (tooling, or a require cycle during load): stay silent
            -- rather than fail. Registration must never depend on logging.
            logger = { info = function() end, warn = function() end, err = function() end }
        end
    end
    return logger
end

local function warn(fmt, ...)
    log().warn(string.format(fmt, ...))
end

-- The "same owner re-registered" line. utils.log deliberately has only info/warn/err, so
-- the debug-level note in the policy above is an info that only speaks when env.debug is
-- on — an author running the F1 suite re-registers hundreds of test ids per run and must
-- not be told about every one of them.
local function note(fmt, ...)
    local ok, env = pcall(require, "palforge.env")
    if ok and type(env) == "table" and env.debug then
        log().info(string.format(fmt, ...))
    end
end

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

-- DEFINE-TIME SHAPE CHECK (F-4). `resolve` is called at engine boundaries, where a
-- failure is a fallback to the literal; `validId` is called at DEFINE time, where a
-- failure must be a hard error in the domain constructor. Returns true, or false + reason.
--
--   Building{ id = "my-pack:Bench" }   -- a hyphen: VALID rejects it, so it resolves to
--                                      -- nothing, core/event indexes no build id, and the
--                                      -- definition is registered, live-looking and dead.
--
-- No colon at all = a literal game id, accepted for any non-empty string (the game's own
-- rows are the authority on what a literal id may contain, and "Sheepball" style rows are
-- not this module's to police). A colon ANYWHERE means the author meant the namespaced
-- form, so both halves must match ^[%w_]+$ — the shape resolve requires.
--
-- ONE DELIBERATE DIVERGENCE FROM resolve, and it is the strict direction: ":Bench" and
-- "example:" do not match resolve's `^([^:]+):(.+)$` split, so resolve waves them through
-- as literals (pinned in test/cases/registry.lua — "an id with an empty half is not
-- namespaced at all"). validId rejects them, because at define time an id with an empty
-- half is a typo every time, and refusing it here means resolve's literal door is never
-- reached for one. This module does NOT call validId itself: register stays fail-soft and
-- last-wins, and the api constructors are where a bad id must raise.
function M.validId(id)
    if type(id) ~= "string" or #id == 0 then
        return false, "id must be a non-empty string"
    end
    if not id:find(":", 1, true) then return true end   -- literal game id
    -- `[^:]*` (not `+`) on purpose: the empty first half of ":Bench" has to reach the
    -- pattern check to be blamed, instead of failing the split and looking literal.
    local pack, name = id:match("^([^:]*):(.*)$")
    if not pack:match(VALID) then
        return false, "invalid pack id '" .. pack .. "' in '" .. id .. "' (letters/digits/_ only)"
    end
    if not name:match(VALID) then
        return false, "invalid name '" .. name .. "' in '" .. id .. "' (letters/digits/_ only)"
    end
    return true
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

-- packId -> { namespace -> true }, as declared by a pack (depends ∪ recommends).
local declaredDeps = {}

-- Record what a pack declared it depends on, so checkImport has something to consult
-- without every call site threading the set through. api.pack("mypack", { depends = {...} })
-- is the public spelling; `deps` may be an ARRAY of namespaces or a set-like map.
function M.declareDeps(packId, deps)
    if type(packId) ~= "string" or #packId == 0 then return nil end
    if deps == nil then
        declaredDeps[packId] = nil
        return nil
    end
    if type(deps) ~= "table" then return nil end
    local set = {}
    for k, v in pairs(deps) do
        if type(v) == "string" then set[v] = true          -- array form: { "otherpack" }
        elseif v then set[k] = true end                     -- set form:   { otherpack = true }
    end
    declaredDeps[packId] = set
    return set
end

-- What a pack declared, as a set-like table, or nil.
function M.deps(packId)
    return type(packId) == "string" and declaredDeps[packId] or nil
end

-- VALUE REFERENCE / IMPORT: an id MENTIONED inside args (e.g. give_item.item =
-- "otherpack:Thing"). Allowed only for the pack's own namespace, a literal id,
-- or a namespace the pack declared as a dependency. `deps` is a set-like
-- table (namespace -> anything) built from depends ∪ recommends; when it is omitted the
-- set the pack recorded through M.declareDeps is used instead. Soft (warning).
function M.checkImport(refId, packId, deps)
    if type(refId) ~= "string" then return true end
    local ns = refId:match("^([^:]+):")
    if not ns then return true end                 -- literal id
    if ns == packId then return true end           -- own namespace
    deps = deps or (type(packId) == "string" and declaredDeps[packId] or nil)
    if deps and deps[ns] then return true end
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

-- ---- pack identity (F-6) ----

-- WHO IS DEFINING RIGHT NOW. There is no other way to know: a definition call is a plain
-- Lua call from a pack's own require namespace, and nothing in the call itself says which
-- mod made it. api.pack("mypack") wraps every constructor in withPack, so the whole
-- define runs with this set and register can attribute the entry. It is a single value,
-- not a stack keyed by coroutine, because definition calls are synchronous and run on the
-- game thread; withPack nests correctly (it saves and restores the previous value).
local currentPack = nil

function M.currentPack() return currentPack end

-- Run fn(...) with currentPack() == packId, then restore the previous value — including
-- when fn raises, in which case the error is re-raised unchanged (level 0, so a message
-- that already carries its own position is not decorated twice, and a table error — the
-- unittest fail/skip sentinels — survives as a table).
function M.withPack(packId, fn, ...)
    local prev = currentPack
    currentPack = (type(packId) == "string" and #packId > 0) and packId or nil
    local res = table.pack(pcall(fn, ...))
    currentPack = prev
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
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

-- type -> { id -> entry }, entry = { cls = <class>, pack = <packid|nil>, resolved = <fname> }
-- The entry, not the bare class, is what makes F-1 answerable: "is this id taken, and by
-- whom" has no answer if the only thing stored is the class.
local registry = {}

-- type -> { resolvedForm -> source id }. Maintained at register time so the reverse of
-- resolve() is O(1). This is what core/event's dispatch is meant to use: it previously
-- copied the WHOLE bucket per missed lookup (M.all) and then walked it with pairs(),
-- resolving every registered id, once per event — and because pairs() order is
-- unspecified, a resolved-form collision meant which pack's handler ran varied between
-- sessions. The index makes the lookup O(1) and the collision a warning at define time.
local resolvedIdx = {}

local function bucketsFor(otype)
    local bucket = registry[otype]
    if not bucket then bucket = {}; registry[otype] = bucket end
    local index = resolvedIdx[otype]
    if not index then index = {}; resolvedIdx[otype] = index end
    return bucket, index
end

-- Drop (otype, id) if it is registered. Returns true when something was removed.
-- The sharp edge this closes: there used to be no unregister at all, and the tests spelled
-- "forget this" as register(otype, id, nil) — undocumented, in no header and no doc page.
-- That spelling still works and is pinned in test/cases/registry.lua; it is implemented in
-- terms of this. test/support.lua's sweep asks for M.unregister by name now and keeps
-- register(otype, id, nil) only as a fallback, because that file is also the harness a
-- content pack copies and it should not break against an older tree.
function M.unregister(otype, id)
    local bucket = registry[otype]
    local entry  = bucket and bucket[id]
    if not entry then return false end
    bucket[id] = nil
    local index = resolvedIdx[otype]
    -- Only clear the index slot if it still points at THIS id: after a resolved-form
    -- collision the slot belongs to whoever registered last, and dropping one of the two
    -- colliding ids must not silently unhook the other.
    if index and entry.resolved and index[entry.resolved] == id then
        index[entry.resolved] = nil
    end
    return true
end

-- Register a class under (otype, id). `otype` is named to avoid shadowing type().
-- `opts.pack` names the owning pack (defaults to currentPack(), i.e. the pack whose
-- api.pack surface made the call); `opts.refs` is an optional array of ids the definition
-- MENTIONS, which is what checkImport is for.
-- Returns cls on success, or nil + error (fail-soft: never throws). A definition calls
-- this best-effort so a registry hiccup can't break class definition.
-- `cls == nil` forgets the id and answers nil, nil — NOT nil + reason, because forgetting
-- is not a failure. Prefer M.unregister, which says so in its name and reports whether
-- anything was there.
function M.register(otype, id, cls, opts)
    if not VALID_TYPES[otype] then
        return nil, "object_manager.register: unknown type '" .. tostring(otype) .. "'"
    end
    if type(id) ~= "string" or #id == 0 then
        return nil, "object_manager.register: id must be a non-empty string"
    end
    if cls == nil then
        M.unregister(otype, id)
        return nil
    end

    local bucket, index = bucketsFor(otype)
    local prev = bucket[id]

    local pack = (opts and opts.pack) or currentPack
    if type(pack) ~= "string" or #pack == 0 then pack = nil end

    -- Ownership: a pack keying an id inside SOMEONE ELSE'S namespace. Warned, not refused
    -- — see the module header for why, and for the one-word change that makes it a refusal.
    if pack then
        local owned, why = M.checkOwnership(id, pack)
        if not owned then
            warn("%s '%s': %s. It is registered anyway (last-wins), but the id belongs to "
                .. "another pack's namespace and that pack will overwrite it", otype, id, why)
        end
        -- Imports: ids this definition MENTIONS. No domain passes `refs` yet — the api
        -- constructors are the only place that knows which of a spec's fields are id
        -- references (give_item.item, a recipe's ingredients, an unlock's building) — so
        -- this stays an offered wiring point rather than a claim that imports are checked.
        if opts and type(opts.refs) == "table" then
            for _, ref in ipairs(opts.refs) do
                local okRef, whyRef = M.checkImport(ref, pack)
                if not okRef then
                    warn("%s '%s' (pack '%s') %s", otype, id, pack, whyRef)
                end
            end
        end
    end

    -- F-1: the same id, a DIFFERENT class. Last-wins either way; the owners decide whether
    -- this is a collision between packs (loud) or a redefinition by its owner (quiet).
    if prev and prev.cls ~= cls then
        if prev.pack ~= pack then
            warn("%s '%s' was defined by pack '%s' and is being redefined by pack '%s'; "
                .. "the new definition replaces the old one (last-wins)",
                otype, id, tostring(prev.pack), tostring(pack))
        else
            note("%s '%s' redefined by its own pack '%s' (last-wins)",
                otype, id, tostring(pack))
        end
    end

    -- F-2: two different source ids, one game row. "my:pack_Thing" and "my_pack:Thing"
    -- both resolve to my_pack_Thing, because VALID allows `_` in both halves and
    -- resolution is plain concatenation. An unresolvable id (a hyphen, say) indexes under
    -- its LITERAL form — the same fallback every engine boundary uses — so it is still
    -- reachable and still collidable rather than invisible.
    local form = M.resolve(id) or id
    local other = index[form]
    if other and other ~= id then
        warn("%s ids '%s' and '%s' both resolve to the single game row '%s' — one row, two "
            .. "definitions. '%s' now owns the resolved lookup; rename one of them",
            otype, other, id, form, id)
    end

    bucket[id] = { cls = cls, pack = pack, resolved = form }
    index[form] = id
    return cls
end

-- Look up a registered class. Returns cls or nil. UNCHANGED by F-1: every caller that
-- expects the class itself keeps working, and the record is reached through entry().
function M.get(otype, id)
    local bucket = registry[otype]
    local entry  = bucket and bucket[id]
    return entry and entry.cls or nil
end

-- The full registration record: { cls, pack, resolved }, or nil if the id is free.
-- A COPY, for the same reason all() is a copy: the live record is the registry's, and a
-- caller that edited `pack` in place would silently re-attribute someone's content.
function M.entry(otype, id)
    local bucket = registry[otype]
    local entry  = bucket and bucket[id]
    if not entry then return nil end
    return { cls = entry.cls, pack = entry.pack, resolved = entry.resolved }
end

-- Which pack registered this id, or nil (nil = registered by nobody in particular:
-- a bare Item{...} outside any api.pack surface, which is the whole of the old behaviour).
function M.owner(otype, id)
    local bucket = registry[otype]
    local entry  = bucket and bucket[id]
    return entry and entry.pack or nil
end

-- THE public "is this id taken?". Seven of the EIGHT definable domains never return nil from
-- X.get (they fabricate a thin fallback; Mesh is the one that raises instead, because a mesh
-- with no model would silently render nothing), so before this the only honest answer meant
-- reaching past the api into the registry. The ninth api member, Player, defines nothing and
-- has no get at all. Always a boolean.
function M.isRegistered(otype, id)
    local bucket = registry[otype]
    return (bucket and bucket[id]) ~= nil
end

-- Look a class up by its RESOLVED form — the "packid_name" spelling the game's tables and
-- blueprints use. Returns cls, sourceId (both nil on a miss). O(1): this is the index,
-- not a scan. A literal id indexes under itself, so byResolved answers for those too.
function M.byResolved(otype, resolvedId)
    local index  = resolvedIdx[otype]
    local id     = index and index[resolvedId]
    local bucket = registry[otype]
    local entry  = (id and bucket) and bucket[id] or nil
    if not entry then return nil end
    return entry.cls, id
end

-- Snapshot of every registered class of a type: { id -> cls }. Returns a shallow
-- copy so callers can't mutate the live registry. Note that this is O(n) per call and
-- allocates: it is for enumeration (core/registry.registered, the F9 sweep, tooling), NOT
-- for lookups. A dispatch that needs "which class owns this resolved id" wants byResolved.
function M.all(otype)
    local out = {}
    local bucket = registry[otype]
    if bucket then
        for id, entry in pairs(bucket) do out[id] = entry.cls end
    end
    return out
end

return M
