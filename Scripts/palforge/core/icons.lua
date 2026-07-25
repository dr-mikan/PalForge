-- PalForge utils.icons: runtime icon resolution from Palworld's icon DataTables.
-- Self-contained generic primitive (only palforge.utils.log). Given an icon
-- DataTable path and a content id, it finds the table via StaticFindObject, looks
-- up the row keyed by that id, and reads the texture ref from the row's icon column.
--
-- Icon VALUES were NOT dumped in-game, only the TABLE paths and the fact that rows
-- are keyed by the content id with an `IconName`/icon column. So every step here is
-- resolved at RUNTIME and is strictly fail-soft: any engine miss (table absent, no
-- row, no column) returns nil, and each base's iconOf() falls back to self.icon.
--
--   local icons = require("palforge.core.icons")
--   local tex = icons.resolve(icons.TABLES.item, "Wood")   -- texture ref | nil
--
-- The four table paths are the dump-confirmed ones; nothing here is invented.

local M = {}

-- Dump-confirmed icon DataTable object paths, keyed by object type.
M.TABLES = {
    item     = "/Game/Pal/DataTable/Item/DT_ItemIconDataTable",
    pal      = "/Game/Pal/DataTable/Character/DT_PalCharacterIconDataTable",
    skill    = "/Game/Pal/DataTable/PartnerSkill/DT_partnerSkillIconDataTable",
    building = "/Game/Pal/DataTable/MapObject/Building/DT_BuildObjectIconDataTable",
}

-- Column names a row may carry the texture ref under. `IconName` is the dump-noted
-- one; the rest are defensive fallbacks (icon values were not dumped, so we probe).
local ICON_COLUMNS = { "IconName", "Icon", "Texture" }

-- Find the DataTable object for a path. Returns the object or nil (fail-soft).
local function findTable(path)
    if type(path) ~= "string" or #path == 0 then return nil end
    if type(StaticFindObject) ~= "function" then return nil end
    local ok, tbl = pcall(StaticFindObject, path)
    if not ok or tbl == nil then return nil end
    -- honour IsValid when the object exposes it; otherwise assume usable.
    local okv, valid = pcall(function()
        if tbl.IsValid then return tbl:IsValid() end
        return true
    end)
    if okv and valid == false then return nil end
    return tbl
end

-- Fetch the row (a UStruct handle) for `id`, across the row-access APIs UE4SS may
-- expose on a UDataTable. Returns the row handle or nil.
local function findRow(tbl, id)
    -- 1) GetDataTableRowFromName(RowName) — the id string is auto-coerced to FName.
    local ok, row = pcall(function()
        if tbl.GetDataTableRowFromName then return tbl:GetDataTableRowFromName(id) end
    end)
    if ok and row ~= nil then return row end
    -- 2) FindRow(RowName, ContextString, bWarnIfRowMissing) — the reflected fallback.
    ok, row = pcall(function()
        if tbl.FindRow then return tbl:FindRow(id, "palforge.icons", false) end
    end)
    if ok and row ~= nil then return row end
    return nil
end

-- Read the texture ref off a row, trying each known icon column. An FName / soft
-- ref that exposes ToString is normalized to a string; anything else is returned
-- as-is (the caller only needs a truthy handle).
local function readIcon(row)
    for _, col in ipairs(ICON_COLUMNS) do
        local ok, v = pcall(function() return row[col] end)
        if ok and v ~= nil then
            local oks, s = pcall(function()
                if type(v) == "userdata" and v.ToString then return v:ToString() end
                return nil
            end)
            if oks and type(s) == "string" and #s > 0 then return s end
            return v
        end
    end
    return nil
end

-- Resolve the icon texture ref for `id` from the DataTable at `iconTablePath`.
-- Returns the texture ref (string path or engine object) or nil on any miss.
function M.resolve(iconTablePath, id)
    if type(id) ~= "string" or #id == 0 then return nil end
    local tbl = findTable(iconTablePath)
    if not tbl then return nil end
    local row = findRow(tbl, id)
    if not row then return nil end
    return readIcon(row)
end

return M
