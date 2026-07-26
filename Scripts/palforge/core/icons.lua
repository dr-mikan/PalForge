-- PalForge core.icons: runtime icon resolution from Palworld's icon DataTables. Every
-- domain's iconOf() (item / pal / skill / building) comes through here: given an icon-table
-- descriptor and a content id, find the live UDataTable, read the row keyed by that id, and
-- hand back the texture ref that row carries. Only palforge.utils.log is required.
--
-- WHAT IS PROVEN HERE AND WHAT IS NOT — read this before trusting a return value:
--   * The TABLE NAMES are real. Every one below, `_Common` siblings included, exists in the
--     390-table catalog dump (PalSmith/deprecated/catalog/datatables/).
--   * FINDING a table BY NAME is proven, by two routes, and both are used — TARGETED FIRST:
--     UE4SS's FindObject("DataTable", "<name>") is what utils/items/init.lua's
--     technologyRows() uses to read the live technology tables, and it asks for the ONE
--     object we want, touching nothing else; the
--     FindAllOf("DataTable") + o:GetFName():ToString() sweep that dumped the 390-table
--     catalog (tests/catalog.lua:141-163) is the fallback for when that global is absent or
--     misses. The order is not cosmetic: tests/catalog.lua:6-10 records the sweep as
--     crash-prone (it touches EVERY loaded table, and a stale pointer there raises an access
--     violation Lua's pcall cannot catch), which is why utils/items refuses it "inside an
--     ordinary helper" — and iconOf() is exactly that.
--   * The /Game PACKAGE PATHS are now PROVEN. dumps/reflection/01_datatables.txt printed
--     GetFullName() for all 391 loaded DataTables in a real session, and every one of the
--     seven names below appeared under the directory PACKAGE_DIRS already guessed. They stay
--     a last-resort fallback (discovery is cheaper), written in the "Package.Object" form
--     LoadAsset wants — the convention that works in core/sound/native.lua.
--   * The ICON COLUMN of each table is now MEASURED, not inferred — see ICON_COLUMNS_BY_TABLE.
--   * READING THE VALUE reads the whole COLUMN as strings and zips it against the row names,
--     rather than reading a row and indexing it. The row route works — UE4SS binds FindRow onto
--     UDataTable itself and it returns the row with the measured column on it — but the value
--     in that column is a TSoftObjectPtr userdata that answers none of the nineteen member
--     names a soft pointer could plausibly expose, so it cannot be unwrapped from Lua at all.
--     The reasoning, and the list, is above iconMap. NOT observed answering yet: a nil still
--     means "the read did not fire", never "there is no such row".
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
-- All seven are loaded in a live session (01_datatables.txt). The three unsuffixed ones are
-- CompositeDataTables that aggregate their `_Common` sibling, so both spellings carry the same
-- rows and the same column: item 1207 rows, pal 674, building 571/562, skill 311.
-- NOTE on skill: DT_partnerSkillIconDataTable is keyed by PAL id, not by skill id (its 311
-- rows are Alpaca/Anubis/Bastet/...), so only pal-derived partner skills can ever hit it;
-- passive skills have no icon row and fall back to the declared icon by design.
M.TABLES = {
    item     = { "DT_ItemIconDataTable",         "DT_ItemIconDataTable_Common" },
    pal      = { "DT_PalCharacterIconDataTable", "DT_PalCharacterIconDataTable_Common" },
    skill    = { "DT_partnerSkillIconDataTable" },
    building = { "DT_BuildObjectIconDataTable",  "DT_BuildObjectIconDataTable_Common" },
}

-- Package directories, used only by the last-resort path fallback below. MEASURED: every one
-- is the directory 01_datatables.txt printed for that object's GetFullName() in a live session
-- (e.g. "/Game/Pal/DataTable/Item/DT_ItemIconDataTable.DT_ItemIconDataTable"). Kept as a
-- fallback rather than promoted to the primary route because a table that IS loaded is found
-- more cheaply by name, and this path costs one LoadAsset per name per retry window; its real
-- job is the case discovery cannot cover — a table not loaded yet.
local PACKAGE_DIRS = {
    DT_ItemIconDataTable                = "/Game/Pal/DataTable/Item/",
    DT_ItemIconDataTable_Common         = "/Game/Pal/DataTable/Item/",
    DT_PalCharacterIconDataTable        = "/Game/Pal/DataTable/Character/",
    DT_PalCharacterIconDataTable_Common = "/Game/Pal/DataTable/Character/",
    DT_partnerSkillIconDataTable        = "/Game/Pal/DataTable/PartnerSkill/",
    DT_BuildObjectIconDataTable         = "/Game/Pal/DataTable/MapObject/Building/",
    DT_BuildObjectIconDataTable_Common  = "/Game/Pal/DataTable/MapObject/Building/",
}

-- The column each icon table carries its texture ref under. MEASURED, one column per table:
-- dumps/reflection/01_datatables.txt walked `dt.RowStruct` -> `rs:ForEachProperty(...)` over
-- all 391 DataTables loaded in a real session and printed the property list of every one.
-- Item, pal and building tables each have exactly ONE column, and it is the whole row.
--
-- Scoring the five-name guess this replaces (SoftIcon / IconName / IconTexture / Icon /
-- Texture, tried in that order against every table): it would have found building on the
-- first index and item and pal on the fourth, and it would NEVER have found the partner-skill
-- column, whose real name is nothing like any of the five. Three of the five — IconName,
-- IconTexture, Texture — are not columns of any icon table on this build at all.
--
--   DT_ItemIconDataTable[_Common]         [columns] Icon
--   DT_PalCharacterIconDataTable[_Common] [columns] Icon
--   DT_BuildObjectIconDataTable[_Common]  [columns] SoftIcon
--   DT_partnerSkillIconDataTable          [columns] IsSquare_5_116F13E54A95BA260E4C56848C50332E,
--                                                   TextureID_8_2B2F889C43EB586246BDB981B6462ACA
--
-- The partner-skill row struct is a Blueprint UserDefinedStruct, so its properties carry the
-- editor GUID suffix UE appends to every field of one — that decorated spelling IS the
-- reflected property name and is what an index has to use. The undecorated "TextureID" is
-- listed after it only in case a future accessor hands back a struct whose fields were
-- de-suffixed on the way out; it costs one nil index. `IsSquare` is a layout flag, not the
-- texture, so it is not probed.
--
-- The column's TYPE is measured too, by dumps/cxx/Pal.hpp, which declares all three row structs:
--   struct FPalEditorItemIconTableRow  : FTableRowBase { TSoftObjectPtr<UTexture2D> Icon; }
--   struct FPalCharacterIconDataRow    : FTableRowBase { TSoftObjectPtr<UTexture2D> Icon; }
--   struct FPalBuildObjectIconData     : FTableRowBase { TSoftObjectPtr<UTexture2D> SoftIcon; }
-- All three carry ONE field and it is a soft object pointer — an asset PATH, not a live object,
-- which is exactly what a caller wants to hand to LoadAsset. It also independently confirms the
-- column names above, from the shipping binary rather than from a property walk. Reading the
-- column as a string therefore loses nothing: the string IS the soft pointer's path.
local ICON_COLUMNS_BY_TABLE = {
    DT_ItemIconDataTable                = { "Icon" },
    DT_ItemIconDataTable_Common         = { "Icon" },
    DT_PalCharacterIconDataTable        = { "Icon" },
    DT_PalCharacterIconDataTable_Common = { "Icon" },
    DT_BuildObjectIconDataTable         = { "SoftIcon" },
    DT_BuildObjectIconDataTable_Common  = { "SoftIcon" },
    DT_partnerSkillIconDataTable        = { "TextureID_8_2B2F889C43EB586246BDB981B6462ACA", "TextureID" },
}

-- For a table this module has never measured — a modded icon table someone points M.TABLES at.
-- Every name that IS measured above leads, so a pack table spelled like a vanilla one hits on
-- the first index; the rest are the old inference list, kept for reach rather than for truth.
local ICON_COLUMNS_FALLBACK = { "Icon", "SoftIcon", "TextureID", "IconName", "IconTexture", "Texture" }

local function columnsFor(tableName)
    return ICON_COLUMNS_BY_TABLE[tableName] or ICON_COLUMNS_FALLBACK
end

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

-- Full object name, for the log only. This is the one line that turns PACKAGE_DIRS from a
-- guess into a fact: it prints the real package path of a table we actually found.
local function objPath(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    if ok and type(s) == "string" and #s > 0 then return s end
    return "?"
end

-- Cache a discovered table and say so once, with its full name (see objPath).
local function noteTable(name, dt, how)
    tableCache[name] = dt
    log.info(string.format("icon DataTable %s (%s) = %s", name, how, objPath(dt)))
    return dt
end

-- TARGETED lookup — UE4SS's FindObject("DataTable", "<name>") overload (class short name +
-- object short name). Same call utils/items/init.lua's technologyRows() makes for the
-- technology tables, and preferred over the sweep for the reason recorded there: the sweep
-- walks every loaded UDataTable and tests/catalog.lua:6-10 documents that as crash-prone.
-- One targeted lookup costs nothing, and when it hits, the sweep below never runs at all.
local function findObjectByName(name)
    if type(FindObject) ~= "function" then return nil end
    local ok, o = pcall(FindObject, "DataTable", name)
    if ok and isValid(o) then return o end
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
                noteTable(name, dt, "sweep")
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

-- The live UDataTable named `name`, or nil. Cache first (free), then the targeted lookup,
-- then the sweep, then the path fallback — cheapest and safest first. A cached object that
-- has gone invalid (world teardown) is dropped and looked up again rather than handed back.
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

    local tbl = findObjectByName(name)
    if tbl then return noteTable(name, tbl, "FindObject") end

    sweep(name)
    tbl = tableCache[name]
    if tbl then return tbl end

    tbl = loadTable(name)
    if tbl then return noteTable(name, tbl, "path") end
    return nil
end

-- ---------------------------------------------------------------------------
-- reading the icon
--
-- UE4SS BINDS A ROW READER ONTO UDataTable ITSELF, and that is the answer this module spent a
-- long time not finding. It is not a UFunction, which is why every reflection sweep missed it —
-- dumps/cxx/Engine.hpp shows UDataTable declaring five properties and ZERO functions, so the
-- accessors this code used to try were called on an object that genuinely does not have them.
-- UE4SS provides its own (ue4ss/Docs/lua-api/classes/udatatable.md):
--
--     dt:FindRow(string RowName)  -> UScriptStruct | nil   -- by REFERENCE into the table
--     dt:GetRowNames()            -> { "Wood", ... }
--     dt:GetRowMap()              -> { [name] = row }
--     dt:GetAllRows()             -> { { Name =, Data = }, ... }
--     dt:ForEachRow(function(name, row) end)
--
-- Note what FindRow takes: a plain Lua STRING, because it is UE4SS's own binding rather than a
-- marshalled UFunction call. Passing FName("Wood") here is the wrong type for this route, and
-- the old code's three-argument dt:FindRow(key, "palforge.icons", false) was the C++ template's
-- signature, which is not what is bound. One string argument is the whole call.
--
-- The row that comes back is the struct dumps/cxx/Pal.hpp declares, with one field:
--     FPalEditorItemIconTableRow  { TSoftObjectPtr<UTexture2D> Icon; }
--     FPalCharacterIconDataRow    { TSoftObjectPtr<UTexture2D> Icon; }
--     FPalBuildObjectIconData     { TSoftObjectPtr<UTexture2D> SoftIcon; }
-- so indexing it by the measured column name (ICON_COLUMNS_BY_TABLE) yields a soft object
-- pointer — an asset PATH, which is exactly what a caller hands to LoadAsset.

-- The id as a plain string for FindRow. Kept as a named function because the temptation to
-- "also try FName" is exactly what this route does not want: FindRow is a UE4SS binding taking
-- a Lua string, and a marshalled Palworld UFunction taking an FName is a different thing that
-- lives elsewhere. Do not merge them.
local function rowKey(id)
    return (type(id) == "string" and #id > 0) and id or nil
end

-- THE COLUMN, AS STRINGS. The struct route is abandoned and this is why, so nobody retries it.
--
-- FindRow works: it returns the row and the measured column is on it. What comes back from that
-- column is a TSoftObjectPtrUserdata, and on this UE4SS build that userdata answers NOTHING.
-- A probe asked it for all nineteen names a soft pointer plausibly exposes —
--     Get, LoadSynchronous, ToString, ToSoftObjectPath, GetPathName, GetAssetName,
--     GetLongPackageName, GetAssetPathName, GetAssetPathString, IsValid, IsNull, IsPending,
--     ObjectID, AssetPath, AssetPathName, SubPathString, PackageName, AssetName, WeakPtr
-- — and not one of them is readable. There is no documented Lua surface for it either (the
-- UE4SS install ships class docs for UDataTable, Property, UFunction and friends, and none for
-- TSoftObjectPtr). So the value cannot be unwrapped from Lua, and no amount of further guessing
-- at member names changes that.
--
-- What CAN be read is the same column rendered as text, by the one accessor that returns plain
-- strings instead of a struct (dumps/cxx/Engine.hpp, UDataTableFunctionLibrary):
--
--     TArray<FString> GetDataTableColumnAsString(const UDataTable* DataTable, FName PropertyName);
--
-- One row per entry, in RowMap order — and dt:GetRowNames(), UE4SS's own binding, walks the
-- same RowMap in the same order. Zipping the two gives id -> icon path for a whole table in two
-- calls, with no struct ever crossing into Lua. Both arguments are an object pointer and an
-- FName, which this tree marshals successfully every day.
--
-- The earlier attempt at this route failed for a reason that is now fixed: it took the row names
-- from the FUNCTION LIBRARY's GetDataTableRowNames, which answered nothing here. The names come
-- from the table itself now.
local signature = require("palforge.core.signature")

-- The DataTableFunctionLibrary CDO, resolved once. false records a failed resolve so the lookup
-- is not repeated for every icon.
local dtLib = nil
local function library()
    if dtLib == nil then
        local ok, lib = pcall(StaticFindObject, "/Script/Engine.Default__DataTableFunctionLibrary")
        dtLib = (ok and lib) or false
    end
    return dtLib or nil
end

-- Flatten a UE4SS TArray (or a plain Lua array) into a list of strings. UE4SS hands arrays back
-- in three shapes depending on build and element type, so all three are tried; FName elements
-- are ToString'd. This is the same coping utils/items already does for row names.
local function toList(arr)
    if arr == nil then return {} end
    local out = {}

    -- UNWRAP RemoteUnrealParam FIRST. This is what the whole icon route was missing, and it is
    -- not guessable from the C++ signature: GetDataTableColumnAsString declares TArray<FString>,
    -- but UE4SS hands each element over as a RemoteUnrealParam — its dynamic wrapper for any
    -- type — and the string is behind :get(). Without this the array has exactly the right
    -- length and every value reads as blank, which is what "0 of 1207 rows carry an icon" was.
    -- (ue4ss/Docs/lua-api/classes/remoteunrealparam.md: Get() / get() -> the underlying value.)
    local function unwrap(v)
        if type(v) ~= "userdata" then return v end
        for _, get in ipairs({ function() return v:get() end, function() return v:Get() end }) do
            local ok, inner = pcall(get)
            if ok and inner ~= nil and inner ~= v then return inner end
        end
        return v
    end

    local function push(v)
        v = unwrap(v)
        if type(v) == "string" then
            out[#out + 1] = v
        elseif type(v) == "userdata" then
            local ok, str = pcall(function() return v.ToString and v:ToString() end)
            out[#out + 1] = (ok and type(str) == "string") and str or ""
        else
            out[#out + 1] = ""   -- keep the INDEX aligned: the two arrays are zipped by position
        end
    end
    if type(arr) == "table" and #arr > 0 then
        for i = 1, #arr do push(arr[i]) end
        return out
    end
    if pcall(function() arr:ForEach(function(_, v) push(v) end) end) and #out > 0 then return out end
    local n; pcall(function() n = #arr end)
    if type(n) == "number" and n > 0 then
        for i = 1, n do local v; pcall(function() v = arr[i] end); push(v) end
        if #out > 0 then return out end
        for i = 1, n do local v; pcall(function() v = arr:Get(i - 1) end); push(v) end
    end
    return out
end

-- The row names of `tbl`, in RowMap order, through UE4SS's own UDataTable binding.
local function rowNames(tbl)
    local ok, names = pcall(function() return tbl:GetRowNames() end)
    if not ok then return {} end
    return toList(names)
end

-- id -> icon path for one table, built once per table object and kept for the session. Icon
-- tables are fixed assets once loaded (PalSchema injects its rows before play), so a successful
-- build is reusable. A FAILED build is not cached, so a call made before the table finished
-- loading is simply retried on the next one.
local iconMaps = setmetatable({}, { __mode = "k" })
local sampled  = {}   -- one raw-shape sample per table, so a busy log stays readable

-- TODO(icons-row-read): unknown whether GetDataTableColumnAsString is reflected on this build.
-- That is the whole of what is left. The table is found, the row keys read, the column measured,
-- and the accessor's two arguments are the shapes this tree marshals every day — but no run has
-- called it. core.signature refuses it unless the live class declares it, so one F1 in a loaded
-- world answers it in one line: a row count closes the item, and "refused ... is not declared on
-- this build" means the library is unreflected here and icons have no route at all, which is
-- equally an answer.
local function iconMap(tbl, tableName)
    local cached = iconMaps[tbl]
    if cached then return cached end

    local names = rowNames(tbl)
    if #names == 0 then
        log.warn(string.format("icons: %s answered no row names, so no icon can be looked up", tableName))
        return nil
    end

    for _, col in ipairs(columnsFor(tableName)) do
        local key; pcall(function() key = FName(col) end)
        if key then
            local ok, values, level = signature.call(library(), "GetDataTableColumnAsString",
                { "ObjectProperty", "NameProperty" }, tbl, key)
            if ok then
                -- SAMPLE THE RAW ARRAY, once per table. The first run of this route answered
                -- with the right LENGTH and every value empty — 0 of 1207 rows — which can mean
                -- two completely different things: the engine rendered a soft pointer as an
                -- empty string, or toList could not read the elements it was handed and filled
                -- in blanks to keep the indexes aligned. Those need opposite fixes, and nothing
                -- printed so far distinguishes them. So look at element 1 directly.
                if not sampled[tableName] then
                    sampled[tableName] = true
                    local bits = {}
                    bits[#bits + 1] = "container=" .. type(values)
                    local n; pcall(function() n = #values end)
                    bits[#bits + 1] = "#=" .. tostring(n)
                    for _, probe in ipairs({
                        { "[1]",      function() return values[1] end },
                        { "[0]",      function() return values[0] end },
                        { "Get(0)",   function() return values:Get(0) end },
                    }) do
                        local okp, v = pcall(probe[2])
                        if okp and v ~= nil then
                            local str; pcall(function() str = tostring(v) end)
                            -- and what it is once unwrapped, since a RemoteUnrealParam's
                            -- tostring says nothing about the value inside it
                            local inner; pcall(function() inner = v.get and v:get() end)
                            bits[#bits + 1] = string.format("%s=%s(%s)%s", probe[1], type(v), tostring(str),
                                inner ~= nil and string.format(" -> %s(%s)", type(inner), tostring(inner)) or "")
                        end
                    end
                    log.info(string.format("icons: %s column %s raw sample -> %s",
                        tableName, col, table.concat(bits, "  ")))
                end
                local vals = toList(values)
                -- Only zippable if the two really are the same walk of the same RowMap. A length
                -- mismatch means they are not, and pairing them anyway would hand out
                -- confidently WRONG icons — the one outcome worse than nil.
                if #vals == #names then
                    local map, carried = {}, 0
                    for i, id in ipairs(names) do
                        local v = vals[i]
                        if type(v) == "string" and #v > 0 and v ~= "None" then
                            map[id] = v; carried = carried + 1
                        end
                    end
                    log.info(string.format("icons: %s column %s read — %d of %d rows carry an icon [%s]",
                        tableName, col, carried, #names, tostring(level)))
                    iconMaps[tbl] = map
                    return map
                end
                log.warn(string.format("icons: %s column %s returned %d values for %d rows — not "
                    .. "the same row walk, so it is not paired", tableName, col, #vals, #names))
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
            local map = iconMap(tbl, name)
            if map then
                local tex = map[id]
                if tex ~= nil then return tex end
            end
        end
    end
    return nil
end

return M
