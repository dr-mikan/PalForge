-- PalForge core.recipes: the game's own crafting recipe for an item id, read off
-- DT_ItemRecipeDataTable_Common through the STRUCT route.
--
-- MEASURED WORKING IN GAME, 2026-08-02, hook `item-datatable-row-read` (2 pass / 0 fail):
--
--     dt:FindRow('Arrow')  -> userdata, ScriptStruct /Script/Pal.PalItemRecipe
--        Product_Count   = number(10)
--        WorkAmount      = number(1000.0)
--        Material1_Id    = userdata(Wood)      <- an FName; needs :ToString()
--        Material1_Count = number(2)
--
-- All four columns came off the row BY NAME, which is the whole reason this file exists: a
-- recipe is ONE call, not the thirteen GetDataTableColumnAsString calls core/icons has to make.
--
-- WHY THAT WAS IN DOUBT, and why there is no second route here. core/icons reads its column as
-- TEXT because the value in an icon row is a TSoftObjectPtr userdata that answers none of the
-- nineteen member names a soft pointer could plausibly expose — the struct could not be opened
-- from Lua at all. That failure does not apply to an int32 or an FName, and the run above is
-- what proved it: ints and FNames index off the struct fine. The column route was run as the
-- CONTROL on the same press and also answered, so it stays a MEASURED FACT in the log and NOT a
-- fallback in this file. A fallback whose condition cannot occur is a branch nobody can ever
-- test, and this tree spent 2026-08-02 deleting those.
--
-- THE TABLE. dumps/reflection/01_datatables.txt (a real session) has both spellings under
-- /Game/Pal/DataTable/Item/ carrying the same twenty columns and the same 1414 rows, keyed by
-- item id: DT_ItemRecipeDataTable_Common (the plain table) and DT_ItemRecipeDataTable (the
-- CompositeDataTable that aggregates it). _Common is asked for FIRST because _Common is the one
-- the 2026-08-02 run actually read; the composite is second, for a build that ships only it.
--
-- THE ROW'S REAL 20 PROPERTIES, read off the live build by the same hook:
--   Product_Id:Name, Product_Count:Int, WorkAmount:Float, WorkableAttribute:Int,
--   UnlockItemID:Name, Material1..5_Id:Name, Material1..5_Count:Int, EnergyType:Enum,
--   EnergyAmount:Int, CraftExpRate:Float, DenyRecipeChain:Array, Editor_RowNameHash:Int
-- Five of them become the returned recipe (see M.fromRow); the rest are read by nobody, because
-- inventing a field for a column no caller asked for is how a shape stops being reviewable.
--
-- Strictly fail-soft, like every other engine boundary here: no world, no table, no row, a row
-- that answers nothing -> nil, and nothing raises. NOTHING NEGATIVE IS CACHED — the table
-- handle cache it borrows from core/icons is positives-only-and-retry, and 2026-08-02 is also
-- the day a cached FALLBACK in core/spatial put a whole session in the wrong save bucket. There
-- is no cache of parsed rows at all: FindRow is one call into a table that is already resolved
-- and cached, so a recipe read is cheap enough that a second cache would only be a second thing
-- to invalidate.
--
--   local recipes = require("palforge.core.recipes")
--   recipes.resolve("Arrow")  -- { product = "Arrow", count = 10, work = 1000.0,
--                             --   materials = { Wood = 2 } }  |  nil
--
-- THE ID IS THE ROW SPELLING (C5). This module does not resolve "pack:Potion" -> "pack_Potion";
-- its caller does, at the boundary, because `or self.id` — fall back to the LITERAL, never to
-- nothing — is the rule stated at each call site rather than hidden one layer down.
local log   = require("palforge.utils.log").scope("recipes")
local icons = require("palforge.core.icons")

local M = {}

-- Tried in order. See the header: _Common is the spelling that was measured answering.
M.TABLES = { "DT_ItemRecipeDataTable_Common", "DT_ItemRecipeDataTable" }

-- How many Material<N>_Id / Material<N>_Count pairs a row carries. FIVE, from the property list
-- above; a sixth would simply read nil, but walking to it would be walking on a guess.
local MATERIAL_SLOTS = 5

-- UE4SS hands a value over either bare or wrapped in RemoteUnrealParam, with the real value
-- behind :get(). The struct read measured on 2026-08-02 handed the numbers over bare and the
-- FName as a plain userdata, so the unwrap is not load-bearing on THIS build — it is here
-- because the array read one module over measured the opposite (an array with the right LENGTH
-- and every value blank was three wrong turns' worth of debugging), and the two shapes cost two
-- lines to accept.
--
-- Deliberately a LOCAL COPY of the unwrap inside core/icons.lua's toList rather than a shared
-- helper: there it is one step of flattening a TArray, which is a job this module does not have.
-- Merging them would mean reshaping a file this module otherwise only borrows findTable from.
local function unwrap(v)
    if type(v) ~= "userdata" then return v end
    for _, get in ipairs({ function() return v:get() end, function() return v:Get() end }) do
        local ok, inner = pcall(get)
        if ok and inner ~= nil and inner ~= v then return inner end
    end
    return v
end

-- A column read as a plain string, or nil. An FName column arrives as userdata and MUST be
-- :ToString()'d — that is the one shape note the measurement wrote down explicitly
-- (`Material1_Id = userdata(Wood)`).
--
-- ANYTHING THAT IS NOT ALREADY A STRING IS ASKED FOR ToString, without first testing that it is
-- userdata. The type is not what this needs to know — the member is — and the pcall covers the
-- values that cannot even be indexed (a number, a boolean), which come back nil as they should.
-- It also keeps the parse runnable with no engine at all, which is the difference between a
-- shape this suite proves on every run and one that only a loaded save can exercise.
local function str(v)
    v = unwrap(v)
    if type(v) == "string" then return #v > 0 and v or nil end
    local ok, s = pcall(function() return v.ToString and v:ToString() end)
    if ok and type(s) == "string" and #s > 0 then return s end
    return nil
end

-- A column read as a number, or nil. tonumber, not a type test: an Int that arrives as the
-- string "2" is still a 2, and a value that is neither is not silently turned into 0.
local function num(v)
    v = unwrap(v)
    local n = tonumber(v)
    if type(n) == "number" then return n end
    return nil
end

-- An id column that names nothing. An unused material slot carries the empty FName, which
-- ToString's to "None" — the same string core/icons already refuses when zipping icon paths.
local function named(s)
    return (s ~= nil and s ~= "" and s ~= "None") and s or nil
end

---Turn a recipe ROW into the Item.Spec.Recipe table PalForge hands back, or nil when the row
---answered nothing this module can use.
---
---`row` is whatever supports `row[<column name>]`: the live ScriptStruct dt:FindRow returns in
---game, and a plain Lua table headless — which is not a testing convenience bolted on, it is
---what keeps the SHAPE decidable without a save. `id` is the row key, used as the product when
---the row's own Product_Id is empty.
---
---The returned shape is Item.Spec.Recipe, the same table a pack DECLARES, so :recipeOf has one
---return type and no caller has to branch on where it came from:
---   { product = string, count = number, work = number?, station = nil,
---     materials = { [itemId] = count } }
---   * product  <- Product_Id, else `id`. The row key and the product agree on every vanilla
---                 row measured, but the column is what the game reads, so the column wins.
---   * count    <- Product_Count, how many one craft yields; 1 when unreadable, which is
---                 Item.Spec.Recipe's own declared default rather than a number invented here.
---   * work     <- WorkAmount (a float: 1000.0 for Arrow), nil when unreadable.
---   * station  <- ALWAYS nil. The row has no station id. It has WorkableAttribute, an enum of
---                 what KIND of station can run the recipe, and filling a documented "workbench
---                 / station id" field with an enum number would be a confidently wrong answer
---                 — the one outcome worse than nil.
---   * materials<- Material1..5_Id / _Count. A slot whose id is empty or "None" IS NOT A
---                 MATERIAL and is not emitted. Two slots naming the same id are SUMMED, because
---                 a map cannot hold the id twice and dropping one would understate the cost.
---                 A count that will not read is 0, never omitted: an ingredient the caller
---                 cannot see is worse than an ingredient with a suspicious number on it.
---
---nil when the row answered no product count, no work amount and no material at all — that is
---a struct that did not answer by name, and an empty shell would look like a free recipe.
---@param row any
---@param id string?
---@return Item.Spec.Recipe?
function M.fromRow(row, id)
    if row == nil then return nil end

    local get = function(col)
        local v
        pcall(function() v = row[col] end)
        return v
    end

    local materials, slots = {}, 0
    for i = 1, MATERIAL_SLOTS do
        local mid = named(str(get("Material" .. i .. "_Id")))
        if mid then
            materials[mid] = (materials[mid] or 0) + (num(get("Material" .. i .. "_Count")) or 0)
            slots = slots + 1
        end
    end

    local yield = num(get("Product_Count"))
    local work  = num(get("WorkAmount"))
    if slots == 0 and yield == nil and work == nil then return nil end

    return {
        product   = named(str(get("Product_Id"))) or id,
        count     = yield or 1,
        work      = work,
        materials = materials,
    }
end

-- Said once per session, so a log reader can tell "the read never ran" from "the read ran and
-- the row is not there". The same discipline core/icons.lua's library() uses, and for the same
-- reason: a silent nil is indistinguishable from a nil nobody looked for.
local saidNoTable = false

---The game's recipe for `id` — the ROW SPELLING, already resolved by the caller — or nil.
---
---nil covers every miss with no distinction, deliberately: no engine, the recipe table not
---loaded in this session, no row for this id, or a row that answered nothing. A caller's
---response to all four is the same (use what was declared, or say nothing), and a module that
---returned four different nils would only be inviting somebody to branch on them.
---@param id string
---@return Item.Spec.Recipe?
function M.resolve(id)
    if type(id) ~= "string" or #id == 0 then return nil end
    local sawTable = false
    for _, name in ipairs(M.TABLES) do
        local tbl = icons.findTable(name)
        if tbl then
            sawTable = true
            -- ⚠️ ONE PLAIN LUA STRING. FindRow is UE4SS's own binding on UDataTable, not a
            -- marshalled UFunction, so FName(id) is the wrong TYPE here and the three-argument
            -- C++ template signature is not what is bound. Getting an argument type wrong on
            -- this build is what closed the game once (test/probe.lua:22-29).
            local row
            pcall(function() row = tbl:FindRow(id) end)
            local recipe = M.fromRow(row, id)
            if recipe then return recipe end
        end
    end
    if not sawTable and not saidNoTable then
        saidNoTable = true
        log.info(string.format("%s is not loaded in this session, so no recipe can be read yet — "
            .. "it is retried, not given up on (said once)", M.TABLES[1]))
    end
    return nil
end

return M
