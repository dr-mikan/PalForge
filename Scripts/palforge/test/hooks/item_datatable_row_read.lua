-- test/hooks/item-datatable-row-read — CAN A SCALAR COLUMN BE INDEXED OFF A ROW STRUCT?
--
-- ⭐ ANSWERED, AND IMPLEMENTED. The struct route WORKS: 2 pass on this hook, and `Item.Handle:
-- recipeOf` now reads the game's own row through core/recipes.lua instead of handing back what
-- a pack declared. CONFIRMED RUNNING IN A GAME 2026-08-02 23:33:
--     recipes: Arrow -> Arrow x10, work=1000.0, from { Stone x2, Wood x2 }
-- The source marker this header used to point at is gone, because the implementation replaced
-- the comment that carried it. What remains below is the measurement that got there, and this
-- hook is now the RE-MEASUREMENT: run it against another save or another patch and block [2]
-- says in one line whether the struct route still answers.
--
-- ⚠️ THIS HOOK ALSO CARRIES `item-recipe-of`, folded in rather than given a file of its own,
-- and the two were always one measurement: recipeOf reached no further than `self.recipe`, and
-- the ONLY reason it did not reach the game was the question below. Block [4] calls recipeOf on
-- a vanilla id and prints what a pack author gets, so the item's user-facing half stays in the
-- same log block as its cause. Splitting them would mean two runs to answer one question.
--
-- WHAT WAS ALREADY SETTLED BEFORE THIS RUN, so the hook does not re-ask it:
--   * The ACCESSORS exist and are UE4SS's own bindings on UDataTable, not UFunctions — which is
--     why every reflection sweep missed them (dumps/cxx/Engine.hpp shows UDataTable declaring
--     five properties and ZERO functions). `dt:FindRow(<plain Lua STRING>)`, `dt:GetRowNames()`,
--     `dt:GetRowMap()`, `dt:GetAllRows()`, `dt:ForEachRow()`. See core/icons.lua:317-339.
--   * ⚠️ FindRow takes ONE PLAIN LUA STRING. Not an FName, not three arguments. FName("Arrow")
--     is the wrong type for this route; the three-argument form was the C++ template's
--     signature and is not what UE4SS binds. Getting an argument type wrong on this build is
--     what closed the game once (test/probe.lua:22-29), so this is written out rather than
--     left to a reader's memory.
--   * `icons-row-read` (Closed) read 1183 of 1207 item rows in a live save through
--     GetDataTableColumnAsString zipped against GetRowNames, so the CONTROL below is a route
--     this tree has already proved.
--
-- WHAT THIS HOOK ASKED, and the answer it got: the only row VALUE ever read here had been a
-- TSoftObjectPtr, and that userdata answers none of the nineteen member names a soft pointer
-- could plausibly expose — which forced the column-as-string detour. The guess was that the
-- TSoftObjectPtr failure does NOT apply to an int32 or an FName, and a recipe row is a 15-field
-- struct of ints and FNames. That guess held: indexing the struct by column name answers, so a
-- recipe is ONE call rather than the thirteen-call column detour block [3] plans for.
--
-- ⚠️ AND THE TRAP THAT COST THREE WRONG TURNS: array elements come back wrapped in
-- RemoteUnrealParam and the real value is behind `:get()`. Without unwrapping, the array reads
-- the right LENGTH with every value blank — which is exactly what "0 of 1207 rows carry an
-- icon" was. The control below unwraps, and PRINTS the raw element beside the unwrapped one so
-- the wrapper is visible rather than assumed.
--
-- Read-only. It calls no UFunction whose declaration has not been checked by core/signature,
-- indexes a struct by name, and writes nothing anywhere.
local hooks = require("palforge.test.hooks")

local TABLE  = "DT_ItemRecipeDataTable_Common"
local ROW    = "Arrow"
-- The four columns the item names, chosen because they cover both scalar shapes a recipe row
-- carries: two ints and an FName-ish id. 01_datatables.txt (a real session) lists the full
-- struct: Product_Id, Product_Count, Material1_Id..Material5_Id, Material1_Count..5_Count,
-- WorkAmount, CraftExpRate, EnergyType, EnergyAmount, UnlockItemID, WorkableAttribute,
-- DenyRecipeChain.
local COLUMNS = { "Product_Count", "WorkAmount", "Material1_Id", "Material1_Count" }

-- UE4SS hands values over wrapped in RemoteUnrealParam / LocalUnrealParam; the value is behind
-- :get(). Same two-shaped unwrap core/icons.lua:435-448 already uses, kept local because this
-- hook must print BOTH the wrapper and what is inside it.
local function unwrap(v)
    if type(v) ~= "userdata" then return v, false end
    for _, get in ipairs({ function() return v:get() end, function() return v:Get() end }) do
        local ok, inner = pcall(get)
        if ok and inner ~= nil and inner ~= v then return inner, true end
    end
    return v, false
end

local function describe(v)
    local inner, wrapped = unwrap(v)
    local s
    pcall(function()
        s = (type(inner) == "userdata" and inner.ToString) and inner:ToString() or tostring(inner)
    end)
    return string.format("%s(%s)%s", type(v), tostring(s),
        wrapped and "  [it was wrapped; this is what :get() held]" or "")
end

hooks.declare{
    id    = "item-datatable-row-read",
    item  = "Closed 2026-08-02 — kept as a regression tripwire (recipeOf reaches the game)",
    needs = { world = true },
    desc  = "can a scalar / FName column be indexed off the struct dt:FindRow(id) returns, or "
         .. "must a recipe be assembled column-by-column the way icons are",
    run = function(h)
        local probe = require("palforge.test.probe")
        local sig   = require("palforge.core.signature")

        --------------------------------------------------------------------
        h:section("[1] the table")
        --------------------------------------------------------------------
        local dt
        pcall(function() if type(FindObject) == "function" then dt = FindObject("DataTable", TABLE) end end)
        if not probe.valid(dt) then
            -- The named lookup is the cheap one; the sweep is what core/icons falls back to.
            h:note("FindObject('DataTable', %q) did not answer; sweeping every loaded UDataTable", TABLE)
            dt = probe.dataTable(TABLE)
        end
        if not probe.valid(dt) then
            h:fail("%s is not loaded in this session, so NOTHING below could be measured. That is "
                .. "not an answer about the row route — it is an answer about this save. Try "
                .. "again after opening a crafting bench, which is what forces the table in.", TABLE)
            return
        end
        h:value("table", probe.full(dt))
        local rs; pcall(function() rs = dt.RowStruct end)
        h:value("RowStruct", probe.valid(rs) and probe.full(rs) or "unreadable")
        if probe.valid(rs) then probe.properties(rs, "RowStruct " .. TABLE) end

        --------------------------------------------------------------------
        h:section("[2] THE OPEN QUESTION: index the struct FindRow hands back")
        --------------------------------------------------------------------
        h:note("dt:FindRow takes ONE PLAIN LUA STRING — it is a UE4SS binding, not a marshalled "
            .. "UFunction. FName(%q) is the wrong type here and is not tried.", ROW)
        local row
        local okFind = pcall(function() row = dt:FindRow(ROW) end)
        if not okFind then
            h:fail("dt:FindRow(%q) RAISED. The binding is not present on this UE4SS build, which "
                .. "would also break core/icons' route — check that first.", ROW)
        end
        h:value("type(dt:FindRow('" .. ROW .. "'))", type(row))
        h:value("dt:FindRow('" .. ROW .. "')", row ~= nil and probe.describe(row) or "nil")

        local structHits = 0
        if row == nil then
            h:note("FindRow answered nil for %q. Either this table has no such row (print "
                .. "GetRowNames below and look) or the binding is not reading this table.", ROW)
        else
            for _, col in ipairs(COLUMNS) do
                local v
                local okRead = pcall(function() v = row[col] end)
                if not okRead then
                    h:value(col, "indexing the struct RAISED")
                elseif v == nil then
                    h:value(col, "nil — the struct answered, and not with this name")
                else
                    structHits = structHits + 1
                    h:value(col, describe(v))
                end
            end
            if structHits == #COLUMNS then
                h:pass("THE STRUCT ROUTE WORKS: all %d columns came off the row by name. A recipe "
                    .. "is ONE call instead of thirteen, and Item.Handle:recipeOf can be "
                    .. "implemented on FindRow.", structHits)
            elseif structHits > 0 then
                h:note("%d of %d columns answered off the struct. A partial answer is still an "
                    .. "answer about the ROUTE: indexing works, and the names that came back nil "
                    .. "are spelled differently — the RowStruct property list in block [1] has "
                    .. "the real spellings.", structHits, #COLUMNS)
            else
                h:note("the struct answered NO column by name. That is the same wall the "
                    .. "TSoftObjectPtr hit, now on plain ints, and it closes the struct route: "
                    .. "the control below is then the implementation.")
            end
        end

        --------------------------------------------------------------------
        h:section("[3] THE CONTROL: GetDataTableColumnAsString, zipped against GetRowNames")
        --------------------------------------------------------------------
        -- The route core/icons.lua already proves. If it answers and [2] does not, this is the
        -- implementation: thirteen calls per table, once, cached, is perfectly affordable.
        local names = {}
        pcall(function() names = dt:GetRowNames() or {} end)
        -- `#` is asked for inside a pcall on purpose: GetRowNames is documented to hand back a
        -- plain Lua table, but a build that hands back a TArray userdata instead would raise on
        -- the length operator and lose the whole block for a formatting detail.
        local count = 0
        pcall(function() count = #names end)
        local rowNames, rowIndex = {}, nil
        for i = 1, count do
            local n = unwrap(names[i])
            pcall(function() n = (type(n) == "userdata" and n.ToString) and n:ToString() or n end)
            rowNames[i] = tostring(n)
            if rowNames[i] == ROW then rowIndex = i end
        end
        h:value("dt:GetRowNames()", string.format("%d name(s); %q is at index %s",
            #rowNames, ROW, tostring(rowIndex)))
        if #rowNames > 0 then
            h:value("first three row names", table.concat({ rowNames[1] or "?", rowNames[2] or "?",
                rowNames[3] or "?" }, ", "))
        end

        local lib
        pcall(function() lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary") end)
        if not probe.valid(lib) then
            h:fail("DataTableFunctionLibrary's CDO did not resolve, so the control could not be "
                .. "run and block [2] stands alone.")
        elseif not rowIndex then
            h:fail("%q is not among the %d row names, so there is nothing to zip against. Pick a "
                .. "row from the list above and run this again.", ROW, #rowNames)
        else
            local columnHits = 0
            for _, col in ipairs(COLUMNS) do
                local key; pcall(function() key = FName(col) end)
                local ok, values = sig.call(lib, "GetDataTableColumnAsString",
                    { "ObjectProperty", "NameProperty" }, dt, key)
                if not ok then
                    h:value(col .. " (column)", "the call was REFUSED or raised — the [signature] "
                        .. "line above names what the live build declared")
                else
                    -- SAMPLE THE RAW ELEMENT, not just the unwrapped one. An array that reads the
                    -- right LENGTH with every value blank is the RemoteUnrealParam trap, and the
                    -- only way to tell it from a genuinely empty column is to look at element 1.
                    local raw, n
                    pcall(function() n = #values end)
                    pcall(function() raw = values[rowIndex] end)
                    local v = unwrap(raw)
                    if type(v) == "userdata" then pcall(function() v = v.ToString and v:ToString() end) end
                    h:value(col .. " (column)", string.format("#=%s  [%d] raw=%s  ->  %q",
                        tostring(n), rowIndex, describe(raw), tostring(v)))
                    if v ~= nil and v ~= "" then columnHits = columnHits + 1 end
                    if n and #rowNames > 0 and n ~= #rowNames then
                        h:fail("⚠️ the column has %d entries and the table has %d row names. They "
                            .. "are NOT the same walk of the same RowMap, and zipping them would "
                            .. "hand out confidently WRONG values — the one outcome worse than "
                            .. "nil. core/icons.lua refuses exactly this mismatch.", n, #rowNames)
                    end
                end
            end
            if columnHits > 0 then
                h:pass("the column route answers %d of %d columns for %q, so recipeOf is "
                    .. "implementable whatever block [2] said", columnHits, #COLUMNS, ROW)
            else
                h:fail("NEITHER ROUTE ANSWERED. Both the struct and the column read came back "
                    .. "empty, which is a different finding from either one failing: this table "
                    .. "may be loaded but unpopulated in this save.")
            end
        end

        --------------------------------------------------------------------
        h:section("[4] item-recipe-of: what a pack author gets")
        --------------------------------------------------------------------
        local Item = require("palforge.api.item")
        local handle = Item.get(ROW)
        local recipe
        local okRecipe = pcall(function() recipe = handle:recipeOf() end)
        h:value("Item.get('" .. ROW .. "'):recipeOf()",
            okRecipe and (recipe == nil and "nil — with nothing declared, that now means the ROW "
                .. "could not be read; compare block [2]" or probe.describe(recipe))
                or "raised")
        h:note("recipeOf reads the game's own row through core/recipes.lua when a pack declared "
            .. "none — the route block [2] proved — and falls back to the declared `self.recipe` "
            .. "when there is one (Class:recipeOf). It answered in a game on 2026-08-02 23:33: "
            .. "Arrow -> Arrow x10, work=1000.0, from { Stone x2, Wood x2 }. A nil here is "
            .. "therefore news about THIS save, not the standing behaviour.")
    end,
}
