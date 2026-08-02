-- PalForge tests.catalog: the DataTable dumper — a dev discovery tool. Extracts every
-- loaded UDataTable's row names (item ids, build-object ids, pal ids, tech rows, ...)
-- into JSON under <Scripts>/catalog/. This is how PalForge learns concrete game ids on
-- any version. Ported self-contained from palforge.deprecated.catalog (file helpers
-- inlined; logging via utils.log; encoding via utils.json).
--
-- OPT-IN ONLY. dump() enumerates native objects via FindAllOf and touches them; a
-- stale pointer there raises an EXCEPTION_ACCESS_VIOLATION that Lua pcall CANNOT catch
-- and crashes the game. Never auto-run — call it deliberately, in a throwaway world
-- (console: `ps_catalog`, wired dev-only by the kernel; or tests.catalog.dump()).
local log  = require("palforge.utils.log").scope("catalog")
local json = require("palforge.utils.json")

local M = {}

-- Interesting tables to also mirror under friendly names (best-effort substring match).
local FRIENDLY = {
    item  = "ItemDataTable",
    build = "BuildObjectDataTable",
    pal   = "MonsterParameter",
    tech  = "TechnologyRecipeUnlock",
}

-- ---- self-contained file helpers (ported from deprecated.core; Windows shell) ----
local function catalogDir()
    local here = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
    -- here = .../Scripts/palforge/test/tools/  ->  .../Scripts/catalog/
    return here .. "..\\..\\catalog\\"
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function ensureDir(dir)
    pcall(function() os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '" 2>nul') end)
    return exists(dir)
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function writeFile(path, text)
    local f = io.open(path, "wb")
    if not f then return false end
    local ok = pcall(function() f:write(text); f:close() end)
    return ok
end

-- ---- row/name extraction (ported verbatim in behaviour) ----

-- Turn one FName-ish element (FName, RemoteUnrealParam wrapper, or string) into a
-- clean string, or nil. Unwraps :get() wrappers and drops empty / "None".
local function fnameToString(v)
    if v == nil then return nil end
    if type(v) == "userdata" then
        local okg, inner = pcall(function() return v.get and v:get() end)
        if okg and inner ~= nil then v = inner end
    end
    local ok, s = pcall(function()
        if type(v) == "userdata" and v.ToString then return v:ToString() end
        return tostring(v)
    end)
    if ok and s and #s > 0 and s ~= "None" then return s end
    return nil
end

-- Extract a UE4SS TArray<FName> into a sorted, de-duped Lua array of strings.
local function arrayToStrings(arr)
    local out, seen = {}, {}
    if arr == nil then return out end
    local function add(v)
        local s = fnameToString(v)
        if s and not seen[s] then seen[s] = true; out[#out + 1] = s end
    end
    pcall(function()
        if arr.ForEach then arr:ForEach(function(_, elem) add(elem) end) end
    end)
    if #out == 0 then
        pcall(function()
            local n = 0
            if arr.GetArrayNum then n = arr:GetArrayNum()
            elseif type(arr) == "table" then n = #arr end
            for i = 1, n do
                local got = false
                pcall(function() if arr[i] ~= nil then add(arr[i]); got = true end end)
                if not got then pcall(function() add(arr:Get(i - 1)) end) end
            end
        end)
    end
    table.sort(out)
    return out
end

-- Row names of a UDataTable. UDataTable:GetRowNames() isn't always reflected; the
-- BlueprintCallable UDataTableFunctionLibrary path is the reliable fallback.
local dtLib = nil
local function rowNames(dt)
    local arr1
    do local ok, a = pcall(function() return dt:GetRowNames() end); if ok then arr1 = a end end
    if dtLib == nil then
        dtLib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary") or false
    end
    local arr2, outTbl = nil, {}
    if dtLib then
        local ok2, a2 = pcall(function() return dtLib:GetDataTableRowNames(dt, outTbl) end)
        if ok2 then arr2 = a2 end
    end
    for _, cand in ipairs({ arr1, arr2, outTbl }) do
        local r = arrayToStrings(cand)
        if #r > 0 then return r end
    end
    return {}
end

-- Object name. GetFName():ToString() is reliably bound; GetName() is not, so try it
-- second (calling an unbound GetName() throws and silently killed the old dump).
local function objName(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    if ok and n and #n > 0 then return n end
    ok, n = pcall(function() return o:GetName() end)
    if ok and n and #n > 0 then return n end
    return nil
end

-- Dump every loaded UDataTable's row names to <Scripts>/catalog/datatables/. Returns
-- a summary { count, friendly } or nil on failure. Opt-in / throwaway-world only.
function M.dump()
    local dir = catalogDir()
    log.info("dumping DataTables to " .. dir .. "datatables\\ ...")
    ensureDir(dir)
    ensureDir(dir .. "datatables\\")

    local okFind, all = pcall(FindAllOf, "DataTable")
    if not okFind or type(all) ~= "table" then
        log.warn("FindAllOf(DataTable) failed (" .. tostring(all) .. ")")
        return nil
    end
    log.info("found " .. #all .. " DataTable objects")

    local index, friendly = {}, {}
    for _, dt in ipairs(all) do
        pcall(function()
            if not (dt and dt:IsValid()) then return end
            local name = objName(dt)
            if not name or #name == 0 then return end
            local names = rowNames(dt)
            if #names == 0 then return end
            local text = json.encode({ table = name, count = #names, rows = names })
            if text then writeFile(dir .. "datatables\\" .. name .. ".json", text) end
            index[name] = #names
            for key, needle in pairs(FRIENDLY) do
                if name:find(needle, 1, true) then friendly[key] = { table = name, count = #names } end
            end
        end)
    end

    local idxText = json.encode({ tables = index, friendly = friendly })
    if idxText then writeFile(dir .. "index.json", idxText) end
    local n = 0; for _ in pairs(index) do n = n + 1 end
    log.info(string.format("dumped %d datatables -> %sdatatables\\", n, dir))

    -- Name the build-object table in the log while the operator is still looking at it. This
    -- is logBuildIds' one caller, and it belongs here: the table it names is the first one
    -- anyone reaches for after a dump (it is where the vanilla chest and bench ids live), and
    -- reading it back off the index.json just written is proof the file landed. Before this
    -- the function had no caller anywhere in the tree.
    M.logBuildIds()

    return { count = n, friendly = friendly }
end

-- Log which DataTable the build-object ids came from, read back out of the index.json that
-- dump() has just written. Silent when there is no index (no dump has run in this install).
function M.logBuildIds()
    local text = readFile(catalogDir() .. "index.json")
    local idx = text and json.decode(text)
    if idx and idx.friendly and idx.friendly.build then
        log.info("build table = " .. idx.friendly.build.table ..
            " (" .. idx.friendly.build.count .. " rows) — see catalog\\datatables\\")
    end
end

return M
