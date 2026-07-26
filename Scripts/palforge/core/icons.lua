-- PalForge core.icons: runtime icon resolution from Palworld's icon DataTables. Every
-- domain's iconOf() (item / pal / skill / building) comes through here: given an icon-table
-- descriptor and a content id, find the live UDataTable, read the row keyed by that id, and
-- hand back the texture ref that row carries. Only palforge.utils.log is required.
--
-- WHAT IS PROVEN HERE AND WHAT IS NOT — read this before trusting a return value:
--   * The TABLE NAMES are real. Every one below, `_Common` siblings included, exists in the
--     390-table catalog dump (PalSmith/deprecated/catalog/datatables/).
--   * FINDING a table BY NAME is proven: FindAllOf("DataTable") + o:GetFName():ToString() is
--     the one route in this tree that ever handed back live UDataTable objects — it is how
--     that catalog was dumped (tests/catalog.lua:141-163). That runs first, and it is the
--     step this module actually fixed.
--   * The /Game PACKAGE PATHS are NOT proven. They appear nowhere else in either tree, and
--     no dump ever recorded an icon table's path — the dumper only ever recorded object
--     NAMES. They survive as a last-resort fallback only, now written in the "Package.Object"
--     form LoadAsset actually wants (the convention that works in core/sound/native.lua).
--   * READING A ROW is proven NOWHERE. No artifact in either tree has ever read a DataTable
--     row VALUE from Lua; the catalog dumper read row NAMES only. GetDataTableRowFromName /
--     FindRow are the right UE5 members to try, but neither has been observed to fire on this
--     build, and the icon column is a probe list (see ICON_COLUMNS) rather than a fact.
--   So: this module now finds the table for real, and the last two steps stay best-effort.
--
-- Strictly fail-soft. Every engine call is inside a pcall, any miss at any step returns nil,
-- and each domain's iconOf() then falls back to the declared `icon`. Nothing throws when the
-- game is absent.
--
--   local icons = require("palforge.core.icons")
--   local tex = icons.resolve(icons.TABLES.item, "Wood")   -- texture ref | nil
--
-- Row keys are the vanilla ids spelled EXACTLY as the table spells them ("Sheepball",
-- "Workbench") and matching is case-sensitive; carrying the DataTable spelling alongside the
-- blueprint one is the native catalogs' job, not this module's.
local log = require("palforge.utils.log").scope("icons")

local M = {}

-- Icon DataTable candidates per domain, tried in order. `_Common` is Palworld's sibling-table
-- convention (PalSchema resolves DT_TechnologyRecipeUnlock -> _Common the same way) and is
-- listed second wherever the catalog actually has one — it does for item, pal and building,
-- and does NOT for the partner-skill table, which therefore stands alone.
-- NOTE on skill: DT_partnerSkillIconDataTable is keyed by PAL id, not by skill id (its 311
-- rows are Alpaca/Anubis/Bastet/...), so only pal-derived partner skills can ever hit it;
-- passive skills have no icon row and fall back to the declared icon by design.
M.TABLES = {
    item     = { "DT_ItemIconDataTable",         "DT_ItemIconDataTable_Common" },
    pal      = { "DT_PalCharacterIconDataTable", "DT_PalCharacterIconDataTable_Common" },
    skill    = { "DT_partnerSkillIconDataTable" },
    building = { "DT_BuildObjectIconDataTable",  "DT_BuildObjectIconDataTable_Common" },
}

-- UNVERIFIED package directories, used only by the last-resort path fallback below. The
-- directories are the historical guesses from this file's first version and nothing in either
-- tree corroborates them; a miss here is the expected outcome. They are kept because the
-- attempt costs one LoadAsset per name per retry window, and because a table that is not
-- loaded yet is invisible to the discovery sweep.
local PACKAGE_DIRS = {
    DT_ItemIconDataTable                = "/Game/Pal/DataTable/Item/",
    DT_ItemIconDataTable_Common         = "/Game/Pal/DataTable/Item/",
    DT_PalCharacterIconDataTable        = "/Game/Pal/DataTable/Character/",
    DT_PalCharacterIconDataTable_Common = "/Game/Pal/DataTable/Character/",
    DT_partnerSkillIconDataTable        = "/Game/Pal/DataTable/PartnerSkill/",
    DT_BuildObjectIconDataTable         = "/Game/Pal/DataTable/MapObject/Building/",
    DT_BuildObjectIconDataTable_Common  = "/Game/Pal/DataTable/MapObject/Building/",
}

-- Columns a row may carry the texture ref under, probed in order. `SoftIcon` leads because it
-- is the one name the shipping binary's FName table ties to an icon ROW STRUCT (it sits on
-- FPalBuildObjectIconData); `IconName` is a real Palworld column too — it is on
-- FPalStaticItemDataStruct, and __knowledges/palworld-ue4ss-functions.md:119 records it on the
-- technology-unlock row — and it was this file's original guess. `IconTexture` / `Icon` /
-- `Texture` are defensive leftovers; "Icon" does not appear in that name table at all, and each
-- extra probe costs one nil index, so they stay last. All of this is name-table inference: no
-- row has ever actually been read here, so the ORDER is a bet, not a measurement.
local ICON_COLUMNS = { "SoftIcon", "IconName", "IconTexture", "Icon", "Texture" }

-- Seconds between full discovery sweeps, and between retries for one table name. A /Game
-- asset can be absent right after boot and present later, so a miss must stay retryable —
-- but a per-frame FindAllOf would be a real cost, hence the window. With no os.time (never
-- the case in UE4SS, but the module must not depend on it) now() is 0 forever and we degrade
-- to a single attempt per name, which is safe: it never spins.
local RETRY_COOLDOWN = 30

-- name -> live UDataTable, kept for the session. Positives only: a table object is stable
-- once loaded, whereas a negative would freeze in a state the game can still leave.
local tableCache = {}
local lastTry    = {}   -- name -> when we last went looking for it
local lastSweep  = nil  -- when the last FindAllOf sweep ran

local function now()
    local ok, t = pcall(os.time)
    return (ok and type(t) == "number") and t or 0
end

-- IsValid when the object exposes it; an object that does not is assumed usable.
local function isValid(o)
    if o == nil then return false end
    local ok, v = pcall(function()
        if o.IsValid then return o:IsValid() end
        return true
    end)
    return ok and v ~= false
end

-- Object name. GetFName():ToString() is reliably bound; GetName() is not (calling an unbound
-- GetName() throws and silently killed the old dump), so it is tried second. Same shape as
-- the dumper's objName at tests/catalog.lua:125-131.
local function objName(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    if ok and type(n) == "string" and #n > 0 then return n end
    ok, n = pcall(function() return o:GetName() end)
    if ok and type(n) == "string" and #n > 0 then return n end
    return nil
end

-- Every table name any domain might ask for, read fresh so extending M.TABLES keeps working.
local function wantedNames(extra)
    local want = {}
    for _, names in pairs(M.TABLES) do
        if type(names) == "table" then
            for _, n in ipairs(names) do want[n] = true end
        elseif type(names) == "string" then
            want[names] = true
        end
    end
    if type(extra) == "string" then want[extra] = true end
    return want
end

-- Sweep every loaded UDataTable once and cache the ones we care about by name. This is the
-- expensive call in the module — FindAllOf walks the whole UObject array — so it is lazy
-- (never at load), rate-limited to once per RETRY_COOLDOWN, and fills the cache for ALL of
-- M.TABLES in one pass so four domains cost one sweep. Deliberately touches each object as
-- little as possible (IsValid + GetFName, no row access): tests/catalog.lua:7-10 warns that
-- enumerating natives can hit a stale pointer, and that raises an access violation Lua's
-- pcall cannot catch. That warning is why this never runs on a timer.
local function sweep(target)
    local t = now()
    if lastSweep and (t - lastSweep) < RETRY_COOLDOWN then return end
    lastSweep = t
    if type(FindAllOf) ~= "function" then return end
    local ok, all = pcall(FindAllOf, "DataTable")
    if not ok or type(all) ~= "table" then return end
    local want = wantedNames(target)
    for _, dt in ipairs(all) do
        if isValid(dt) then
            local name = objName(dt)
            if name and want[name] and tableCache[name] == nil then
                tableCache[name] = dt
                log.info("discovered icon DataTable " .. name)
            end
        end
    end
end

-- Last resort: ask the loader for the asset by path, LoadAsset first and StaticFindObject
-- second — the sequence proven for /Game assets in core/sound/native.lua:29-38, in the
-- "Package.Object" form it needs. The DIRECTORY is still a guess (see PACKAGE_DIRS), so a nil
-- here says nothing about whether the table exists.
local function loadTable(name)
    local dir = PACKAGE_DIRS[name]
    if not dir then return nil end
    local path = dir .. name .. "." .. name
    local a
    pcall(function() if type(LoadAsset) == "function" then a = LoadAsset(path) end end)
    if not isValid(a) then
        a = nil
        pcall(function() if type(StaticFindObject) == "function" then a = StaticFindObject(path) end end)
    end
    if isValid(a) then return a end
    return nil
end

-- The live UDataTable named `name`, or nil. Cache first (free), then discovery, then the path
-- fallback. A cached object that has gone invalid (world teardown) is dropped and looked up
-- again rather than handed back.
local function findTable(name)
    if type(name) ~= "string" or #name == 0 then return nil end
    local cached = tableCache[name]
    if cached ~= nil then
        if isValid(cached) then return cached end
        tableCache[name] = nil
    end
    local t = now()
    local last = lastTry[name]
    if last and (t - last) < RETRY_COOLDOWN then return nil end
    lastTry[name] = t

    sweep(name)
    local tbl = tableCache[name]
    if tbl then return tbl end

    tbl = loadTable(name)
    if tbl then
        tableCache[name] = tbl
        log.info("loaded icon DataTable " .. name .. " by path")
    end
    return tbl
end

-- The id as an FName when the engine is there, as the raw string when it is not. Passing
-- FName("...") into a reflected call is the documented convention (__knowledges/
-- palworld-ue4ss-functions.md, "Lua ハマりどころ"); UE4SS also coerces plain strings in many
-- places, so findRow tries both.
local function nameArg(id)
    local ok, n = pcall(function()
        if type(FName) == "function" then return FName(id) end
        return nil
    end)
    if ok and n ~= nil then return n end
    return id
end

-- Fetch the row struct for `id`, across the row-access APIs a UDataTable may expose. NEITHER
-- of these has been observed to work on this build — reading a row value from Lua is a
-- capability nobody in this tree has demonstrated — so a nil here means "the unproven route
-- did not fire", not "there is no such row".
local function findRow(tbl, id)
    local key = nameArg(id)
    -- 1) GetDataTableRowFromName(RowName), FName first then the raw string.
    local ok, row = pcall(function()
        if tbl.GetDataTableRowFromName then return tbl:GetDataTableRowFromName(key) end
    end)
    if ok and row ~= nil then return row end
    if key ~= id then
        ok, row = pcall(function()
            if tbl.GetDataTableRowFromName then return tbl:GetDataTableRowFromName(id) end
        end)
        if ok and row ~= nil then return row end
    end
    -- 2) FindRow(RowName, ContextString, bWarnIfRowMissing) — the reflected fallback.
    ok, row = pcall(function()
        if tbl.FindRow then return tbl:FindRow(key, "palforge.icons", false) end
    end)
    if ok and row ~= nil then return row end
    return nil
end

-- Read the texture ref off a row, probing each candidate column. An FName / soft ref that
-- exposes ToString is normalized to a string; an empty string or "None" means the column is
-- there but unset, so the probe moves on instead of handing back a lie. An object handle with
-- no ToString comes back as-is (callers only need a truthy handle). Anything that is neither
-- string nor userdata — a stray number or bool — is not an icon and is skipped.
local function readIcon(row)
    for _, col in ipairs(ICON_COLUMNS) do
        local ok, v = pcall(function() return row[col] end)
        if ok and v ~= nil then
            if type(v) == "userdata" then
                local oks, s = pcall(function() return v.ToString and v:ToString() end)
                if oks and type(s) == "string" then
                    if #s > 0 and s ~= "None" then return s end
                else
                    return v
                end
            elseif type(v) == "string" and #v > 0 and v ~= "None" then
                return v
            end
        end
    end
    return nil
end

-- Normalize a table spec into the ordered list of table NAMES to try. Accepts what M.TABLES
-- holds (a list of names) and, for compatibility, a bare name or a legacy "/Game/..." object
-- path — the trailing name is what discovery matches on either way.
local function namesOf(spec)
    if type(spec) == "string" then spec = { spec } end
    if type(spec) ~= "table" then return {} end
    local out = {}
    for _, s in ipairs(spec) do
        if type(s) == "string" and #s > 0 then
            out[#out + 1] = s:match("([^/%.]+)$") or s
        end
    end
    return out
end

-- Resolve the icon texture ref for `id` from the first candidate table that yields one.
-- `spec` is an M.TABLES entry (or a single table name / legacy path). Returns the texture ref
-- — a string path or an engine object — or nil on any miss: table not found, row not found,
-- no readable column, or no game at all.
function M.resolve(spec, id)
    if type(id) ~= "string" or #id == 0 then return nil end
    for _, name in ipairs(namesOf(spec)) do
        local tbl = findTable(name)
        if tbl then
            local row = findRow(tbl, id)
            if row ~= nil then
                local tex = readIcon(row)
                if tex ~= nil then return tex end
            end
        end
    end
    return nil
end

return M
