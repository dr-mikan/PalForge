-- PalForge native._catalog: the ONE naming rule the native catalogs share, and the lazy
-- named-field machinery that hangs off it. Nothing here knows about pals or items — it is
-- given a list of ids and a way to build a handle, and it makes the ids reachable as fields.
--
-- WHY IT IS SHARED RATHER THAN COPIED. Every catalog in this directory wants the same thing:
-- a Lua-identifier handle for each row the game declares, so a pack author can write
-- `native.items.Wood` instead of remembering that the id string is spelled "Wood". The rule
-- for turning a game id into that identifier has to be the SAME rule in all of them, or
-- `items.Wood` and `buildings.Workbench` stop meaning the same kind of thing. Five copies of a
-- normaliser is exactly how that drifts, so it is written once, here, and each catalog spends
-- two lines on it:
--
--   local set, aliases, unnamed = catalog.index(M.CATALOG)     -- membership + the alias table
--   catalog.expose(M, set, aliases, M.get, unnamed)            -- installs the named fields
--
--=============================================================================
-- THE NAMING RULE
--=============================================================================
--
-- (1) IDENTITY. An id that is ALREADY a Lua identifier, and is not a Lua keyword, is its own
--     name, spelled exactly as the DataTable spells it. `M.Wood` is the handle for "Wood";
--     `M.PalBoxV2` for "PalBoxV2"; `M.Wooden_foundation` for "Wooden_foundation".
--
--     COLLISIONS ARE IMPOSSIBLE ON THIS BRANCH, not merely unlikely, and that is the reason
--     the rule is written this way round rather than as a prettifier. The mapping is the
--     IDENTITY function, and ids inside one catalog are unique by construction — they are
--     FName row keys of a UDataTable, which cannot repeat. Two distinct ids therefore cannot
--     want the same field, and no tie-breaking is needed because no tie can occur.
--
--     MEASURED, over the six catalogs this file serves (dumps/catalog/datatables/, 2026-07;
--     re-derived from the loaded modules 2026-08-02): 8297 of 8299 ids take this branch — all
--     498 build-object ids, all 2466 item ids, all 753 pal ids, all 1957 AkAudioEvent names,
--     all 38 EPalStatusID names, and 2585 of the 2587 skill rows.
--
--     This used to read "8259 of 8261, over the five catalogs", which listed native.effects'
--     38 EPalStatusID names in the breakdown and then left them out of both the total and the
--     count of catalogs. The breakdown was right; the totals were 38 and one short.
--
-- (2) NORMALISATION. Anything else becomes an identifier: every byte outside [A-Za-z0-9_] is
--     replaced by "_", a result that starts with a digit gets a "_" in front of it, an empty
--     result becomes "_", and a result that is a Lua KEYWORD gets a "_" after it. The keyword
--     case is not fussiness: `native.end` is a SYNTAX ERROR, so the dot form this whole file
--     exists to provide could never reach such a field at all.
--
--     The result is an ALIAS — a SECOND name for the id, never a replacement. get(id) still
--     takes the id exactly as the game spells it and normalises nothing, so an alias can only
--     ever add a way in. Aliases are published as M.ALIASES (name -> id) so they are readable
--     at runtime rather than folklore.
--
--     The only two ids in this build that need one are the DT_PassiveSkill_Main_Common rows
--     `CraftSpeed*3` and `CraftSpeed*5`, which become skills.CraftSpeed_3 / skills.CraftSpeed_5.
--     (They are also why the rule is not academic: the previous native/skills.lua CATALOG had
--     silently DROPPED both rows rather than face the "*", so the catalog claimed 2585 rows
--     where the game has 2587.)
--
-- (3) WHAT HAPPENS WHEN TWO IDS WANT THE SAME NAME. An alias is published ONLY IF NOTHING ELSE
--     CLAIMS THE NAME — not an id that owns it under rule (1), and not an alias an earlier id
--     already took. Order in the CATALOG decides, and the CATALOG is a fixed literal, so the
--     outcome is identical on every load and on every machine.
--
--     A refused alias is NOT silently dropped and NOT silently overwritten. The id simply
--     keeps no named field — it is still reachable through get(id), which is the spelling that
--     can never be ambiguous — and the refusal is recorded in M.UNNAMED with the reason. So the
--     answer to "what happens when two ids normalise to the same name" is: the first keeps the
--     name, the second keeps its id, and both facts are readable from Lua.
--
--     Rule (1) cannot participate in a collision, so this can only ever be provoked by rule
--     (2) — i.e. by ids the game spells with punctuation. Today that is two ids and they do
--     not collide with anything, so M.UNNAMED is empty in all six catalogs.
--
-- (4) THE MODULE'S OWN SURFACE WINS, AND SAYS SO. Named fields are served by a metatable
--     __index, which fires only for keys the module does not really have — so an id spelled
--     "get" or "CATALOG" would hand back the function or the list instead of a handle, quietly.
--     expose() therefore checks the module's own keys against the membership set and reports
--     any real conflict (into M.UNNAMED and the log) instead of leaving it to be discovered by
--     a pack author whose `catalog.get` turned out not to be a handle.
--
--     A CURATED field that stands for its own id is not a conflict and is not reported:
--     `buildings.WorkBench` is a Building handle whose .id is "WorkBench", so the field and the
--     lazy lookup would have produced the same thing — the field just gets there first, with
--     the hand-written mesh on it. Measured 2026-08-02, by walking each loaded module against
--     its own membership set: no id in any of the six catalogs is really shadowed, and the
--     EIGHT module fields whose name is also a member id are all of the harmless kind —
--     items.Wood / Berries / Arrow, effects.Poison / Burn / Freeze, buildings.WorkBench and
--     pals.SheepBall, each a curated field whose .id IS the key. (The count used to say
--     "three": it named the items and stopped there.) skills.FlameThrower is not among them
--     because its module field is the NICKNAME M.Fireball.
--
--=============================================================================
-- WHY THE NAMED FIELDS ARE LAZY, AND WHY THEY ARE NOT CACHED ONTO THE MODULE
--=============================================================================
--
-- 8299 eager definition calls would put 8299 classes into object_manager at mod load — content
-- nobody asked for, in the registry that core/event walks — for a catalog whose whole point is
-- that most of it is never touched. So a named field is a metatable __index that resolves to
-- the module's own get(id), which already builds on first use and caches. That is a legitimate
-- use of __index and this comment is the paperwork for it: the fields do not exist until they
-- are read, and reading one costs one table lookup plus whatever get(id) costs the first time.
--
-- Laziness bounds that cost by ACCESS COUNT, which is the wrong quantity on its own: a picker
-- that walks a whole CATALOG is one legitimate feature away, and it would have paid the full
-- 8299 anyway. That is why laziness is now only half of it — see THE PUBLISH GATE below, which
-- makes the per-read cost zero rows in the registry rather than one.
--
-- __index deliberately does NOT rawset the handle onto the module afterwards. get(id) already
-- caches, so the second read is a table lookup either way, and NOT writing keeps `pairs(module)`
-- meaning "the module's own surface" — which is what the rule (4) check above reads, and what
-- anything else inspecting a catalog would expect. A module that grew a new key every time
-- someone looked something up would make that check depend on access history.
--
--   local buildings = require("palforge.native.buildings")
--   buildings.PalBoxV2:instances()     -- built on this line, not at load
--   buildings.get("PalBoxV2")          -- the same handle; get(id) is the cache
--
--=============================================================================
-- THE PUBLISH GATE: BUILDING A HANDLE IS NOT PUBLISHING A DEFINITION
--=============================================================================
--
-- Laziness alone was never enough, and the reason is specific rather than tidiness. Until
-- 2026-08-02 every accessor in this directory built its handle with a plain `X{ id = id }`,
-- which REGISTERS the definition into object_manager. For five of the six domains that is
-- merely content nobody asked for sitting in a table. For BUILDINGS it is not inert:
-- core/event.lua's refreshDefs walks object_manager.all("building") before every 500 ms scan,
-- so a registered def makes every matching actor in the world a TRACKED instance, and a newly
-- tracked instance is PERSISTED on the spot (scanOnce's instance-creation branch calls
-- persist(), which writes into the per-world entities_<save> JSON). Named by FUNCTION rather
-- than by line: core/event.lua is 2700 lines and every line number quoted into this file has
-- already gone stale once.
--
-- So `buildings.Stone_Foundation` — one field read, in a tooltip — used to start writing a
-- record for every stone foundation in the base, and a pack that walked
-- native.buildings.CATALOG to fill a picker registered all 498 and persisted the whole base.
-- Nothing DELETES those records (F-7 quarantines rather than deletes, on purpose: a pack that
-- is merely not loaded today must not cost the player their state), so the file only ever grew,
-- in every install, for content no pack requested.
--
-- The rule this directory now follows, and the reason both halves are needed:
--
--   * A READ NEVER REGISTERS. Every accessor passes `{ register = false }` to its domain
--     constructor (contract C2), so a handle is built and cached and object_manager does not
--     hear about it. Everything a handle can do without being in the registry still works:
--     :give / :spawn / :play / :unlock / :iconOf / :mesh / :kind are all id-driven.
--   * PUBLISHING IS A CALL YOU MAKE. `<catalog>.publish(id)` registers the very handle the
--     catalog already cached — M.publish below — so the two things registration is actually
--     for come back on request and only on request: core/event tracking a building's live
--     instances (:instances(), the deferred mesh attach, persistence) and a lookup through
--     the domain's own X.get / X.get_all finding the catalog's handle rather than fabricating
--     a fresh one. Defining your own X{ id = <the same id>, ... } does the same thing and
--     replaces it, which is the documented way to attach handlers.
--
-- Publishing is what has a cost, so publishing is what a pack asks for by name.

local log = require("palforge.utils.log").scope("native")
local om  = require("palforge.core.object_manager")

local M = {}

---The pack id the FRAMEWORK's own definitions register under (contract C3). Every native
---catalog publishes with it, so an id that ends up owned by two definitions can name who
---replaced whom instead of leaving "palforge or a pack?" to be guessed from the id alone.
M.PACK = "palforge"

-- Lua's reserved words. See rule (2): a field named after one cannot be written with a dot at
-- all. None of the 8299 ids in this build is one; the rule handles the case anyway, because the
-- next game patch is under no obligation to keep it that way.
local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
    ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
    ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

---Rule (1): is `id` usable as a Lua field name exactly as the game spells it?
---@param id any
---@return boolean
function M.isName(id)
    return type(id) == "string"
        and id:find("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
        and not KEYWORDS[id]
end

---Rule (2): the identifier an id that isName() rejects would like to be called. PURE — it does
---no collision handling at all (that is rule (3), in index), so the same id always produces the
---same candidate and the rule can be reasoned about one id at a time.
---@param id string
---@return string
function M.aliasFor(id)
    local name = (id:gsub("[^A-Za-z0-9_]", "_"))
    if name == "" then name = "_" end
    if name:find("^[0-9]") then name = "_" .. name end
    if KEYWORDS[name] then name = name .. "_" end
    return name
end

---One pass over a catalog: the membership set every get(id) already needs, plus rules (2) and
---(3). Cheap by design — the per-id work is one anchored string.find, and everything else
---happens only for the ids that fail it.
---
---`ids` is either an ARRAY of ids (the usual CATALOG shape) or a MAP keyed by id (native.audio,
---whose catalog is name -> asset path). They are told apart by `#ids > 0`, which is exact for
---these two shapes: a real catalog list is never empty, and a map keyed by FName strings has no
---[1]. For a map with no accumulator the membership set IS the map — its own values are the
---membership — so nothing is copied.
---
---For a map, rule (3) resolves aliases in SORTED id order rather than catalog order, because
---`pairs` has no order to be deterministic about. It makes no difference today (no map-shaped
---catalog has an alias at all) and it means the outcome is still identical on every load.
---
---@param ids string[]|table<string, any>   the catalog
---@param value any|nil                     what to record per id in `set` (default true). A
---                                         catalog with more than one source table stores which
---                                         one a row came from here; see native/skills.lua.
---@param acc table|nil                     { set=, aliases=, unnamed= } to EXTEND rather than
---                                         start fresh, so a catalog built from two DataTables
---                                         can index each in turn into one set.
---@return table set       # id -> value, the membership test
---@return table aliases   # name -> id, only for names that are not ids themselves
---@return table unnamed   # id -> why it has no named field (empty in every catalog today)
function M.index(ids, value, acc)
    local isList  = (#ids > 0)
    local set     = (acc and acc.set) or (isList and {} or ids)
    local aliases = (acc and acc.aliases) or {}
    local unnamed = (acc and acc.unnamed) or {}
    if value == nil then value = true end

    local pending   -- the ids that need rule (2); nil until one turns up, which is the norm
    if isList then
        for _, id in ipairs(ids) do
            set[id] = value
            if not M.isName(id) then pending = pending or {}; pending[#pending + 1] = id end
        end
    else
        for id in pairs(ids) do
            if set ~= ids then set[id] = value end
            if not M.isName(id) then pending = pending or {}; pending[#pending + 1] = id end
        end
        if pending then table.sort(pending) end
    end

    -- Rule (3) needs the WHOLE membership set before it can tell whether a candidate name is
    -- already an id, which is why it is a second pass — over the tiny pending list, not the
    -- catalog. Two ids in this build; normally none.
    for _, id in ipairs(pending or {}) do
        local name = M.aliasFor(id)
        if set[name] ~= nil then
            unnamed[id] = string.format("would be %q, which is already the id of another row", name)
        elseif aliases[name] then
            unnamed[id] = string.format("would be %q, which %q took first", name, aliases[name])
        else
            aliases[name] = id
        end
    end
    return set, aliases, unnamed
end

---Install the lazy named fields on a native catalog module. Call it LAST in the module, after
---get and after the curated definitions and their pre-seeding, so the rule (4) check sees the
---module's complete own surface.
---
---   catalog.expose(M, { set = set, aliases = aliases, unnamed = unnamed,
---                       get = M.get, label = "native.items" })
---
---@param module table   the catalog module table (its M)
---@param opts table     { set, aliases, unnamed, get, label } — set/aliases/unnamed come
---                      straight from index(), get is the module's own lazy constructor, and
---                      label names the module in the one warning this can produce.
---@return table unnamed
function M.expose(module, opts)
    local set     = opts.set
    local aliases = opts.aliases or {}
    local get     = opts.get
    local unnamed = opts.unnamed or {}
    local label   = opts.label or "native catalog"

    -- Rule (4). O(the module's own fields) — about a dozen — not O(ids), because it walks the
    -- module and asks the set, never the other way round.
    for key, v in pairs(module) do
        if type(key) == "string" and set[key] ~= nil
            and not (type(v) == "table" and v.id == key) then
            unnamed[key] = string.format("the module's own %q field shadows it; use get(%q)", key, key)
            log.warn(string.format("%s: the id %q is shadowed by the module's own field of that "
                .. "name — reach it with get(%q)", label, key, key))
        end
    end

    setmetatable(module, {
        -- Fires only for keys the module does not really have, so CATALOG / get / ALIASES /
        -- every curated field short-circuit it and cost nothing.
        __index = function(_, key)
            if type(key) ~= "string" then return nil end
            local id = (set[key] ~= nil) and key or aliases[key]
            if id == nil then return nil end      -- an unknown name reads as nil, like any table
            return get(id)
        end,
    })
    return unnamed
end

---Publish an already-built native handle into object_manager: the opt-in half of the publish
---gate above. The handle is registered AS IT IS — the class the catalog cached is the class
---that goes into the registry — so `<catalog>.publish(id)` and a later `<catalog>.<Name>` are
---one definition, with whatever mesh, kind or handlers the curated entry declared still on it.
---Rebuilding it through the constructor instead would leave the module's own curated field
---pointing at the older, unregistered twin.
---
---Reaches into the handle's private `_cls` on purpose: every domain wraps its class the same
---way (`{ id = cls.id, _cls = cls }`, api/item.lua:331 and its five siblings) and there is no
---public accessor for it. If one is ever added this is the single call site to move.
---
---Fail-soft like everything else in this layer, and NOISY about it — object_manager.register
---returns nil + a reason rather than raising, and a silent refusal here would look exactly
---like a successful publish that later tracks nothing.
---
---@param otype string       # object_manager type: "building" | "item" | "pal" | ...
---@param handle table|nil   # the handle the catalog cached (nil is a no-op, returns false)
---@param label string|nil   # module name for the log line, e.g. "native.buildings"
---@return boolean ok
---@return string? why       # why it was refused, when it was
function M.publish(otype, handle, label)
    local cls = (type(handle) == "table") and rawget(handle, "_cls") or nil
    if cls == nil then
        return false, "no handle to publish (the id is not in this catalog)"
    end
    local id = cls.id or handle.id
    local ok, err = om.register(otype, id, cls, { pack = M.PACK })
    if not ok then
        err = err or "object_manager.register refused it"
        log.warn(string.format("%s: refused to publish %q as a %s definition: %s",
            label or "native catalog", tostring(id), tostring(otype), err))
        return false, err
    end
    return true
end

return M
