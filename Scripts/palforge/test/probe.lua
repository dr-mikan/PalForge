-- palforge/test/probe.lua — the shared toolkit every probe under test/probes/ uses.
--
-- A probe is not a test. A test asks "does this work"; a probe asks "what IS this", writes
-- the answer to UE4SS.log, and stops. Each one exists to close one entry in plan/TODO.md,
-- where the same id appears — press the key, copy the block, and the missing fact is known.
--
-- OUTPUT SHAPE. Everything a probe writes is bracketed so it can be lifted out of a busy
-- log by eye or by grep:
--
--   #### BEGIN <id>
--   ... lines ...
--   #### END <id>
--
-- Lines are prefixed by kind (CLASS / FN / PARAM / PROP / VALUE / NOTE) so the shape is
-- obvious without reading the probe that produced it.
--
-- SAFETY. Every engine call goes through pcall, and every helper answers with a printable
-- string rather than raising. A probe running against a class that does not exist on this
-- build must print "absent" and carry on — that is a result, not a failure. Nothing here
-- writes to the save or changes game state.
--
-- ONE RULE ABOVE ALL: NEVER CALL A UFUNCTION WITH AN ARGUMENT TYPE YOU ARE NOT SURE OF.
-- "Try it both ways and see which works" reads like exactly what a probe is for, and it
-- closed the game on the first real run: `inv:CountItemNum(FName("Wood"))` answered 135, and
-- the very next line, `inv:CountItemNum("Wood")`, faulted inside UE4SS's argument marshalling
-- and took Palworld down. That fault is native — pcall does not see it, and there is no
-- amount of guarding on this side that makes it survivable.
-- So: read the signature with M.params and pass what it declares, or do not call at all and
-- leave the question in plan/TODO.md. A probe that crashes loses the whole run's findings.
--
--   local probe = require("palforge.test.probe")
--   probe.begin("mesh-static-setstaticmesh")
--   local cls = probe.class("/Script/Engine.StaticMeshComponent")
--   probe.functions(cls)
--   probe.finish()
local log = require("palforge.utils.log").scope("probe")

local M = {}

-- How many entries a bulk listing prints before it stops. A class with 400 functions would
-- otherwise bury the rest of the run; the count is always printed, so nothing is hidden.
M.LIST_LIMIT = 400

local current = nil

--=============================================================================
-- output
--=============================================================================

---Write one line into the current block.
function M.line(fmt, ...)
    local text = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    log.info(text)
end

---Open a block for the plan/TODO.md item `id`.
function M.begin(id, note)
    current = id
    M.line("#### BEGIN %s", id)
    if note then M.line("NOTE %s", note) end
end

---Close the current block.
function M.finish()
    if current then M.line("#### END %s", current) end
    current = nil
end

---A titled sub-section inside a block.
function M.section(title) M.line("-- %s --", title) end

---A plain observation.
function M.note(fmt, ...) M.line("NOTE " .. tostring(fmt), ...) end

--=============================================================================
-- safe reflection primitives
--
-- Names come back as strings or "?" — never nil, never a raise. `valid` is the one guard
-- every other helper leans on.
--=============================================================================

function M.valid(o)
    local ok, v = pcall(function() return o ~= nil and o.IsValid and o:IsValid() end)
    return ok and v == true
end

function M.full(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and tostring(s) or "?"
end

function M.name(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and tostring(s) or "?"
end

function M.className(o)
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and tostring(s) or "?"
end

---Describe any value in one line: its Lua type, and for engine objects its class and name.
function M.describe(v)
    local t = type(v)
    if t ~= "userdata" and t ~= "table" then return string.format("%s(%s)", t, tostring(v)) end
    if not M.valid(v) then return t .. "(invalid or plain)" end
    return string.format("%s %s", M.className(v), M.full(v))
end

--=============================================================================
-- lookups
--=============================================================================

---StaticFindObject with a printed result. Returns the object or nil.
function M.find(path)
    local o; pcall(function() o = StaticFindObject(path) end)
    M.line("CLASS %s -> %s", path, M.valid(o) and M.full(o) or "absent")
    return M.valid(o) and o or nil
end

---The class at an engine path. Same as find, named for readability at the call site.
M.class = M.find

-- There is no M.cdo(scriptClass) any more. It built "/Script/Pal.Default__X" out of
-- "Pal.X" by pattern substitution and had no caller: every probe in the tree writes the
-- CDO path out in full instead (test/probes/reflect.lua does it about twenty times —
-- :329, :401, :453, :464-466, :474-477, :523, :539, :550, :767, :771, :1010), because a
-- probe's whole job is to say exactly which engine path it asked for, and a mangled one
-- printed by the helper is one more thing to disbelieve when a lookup reads "absent".
-- Use M.find with the literal path.

---The first live instance of a class name, printed. Returns it or nil.
function M.firstOf(className)
    local o; pcall(function() o = FindFirstOf(className) end)
    M.line("LIVE %s -> %s", className, M.valid(o) and M.full(o) or "none")
    return M.valid(o) and o or nil
end

---Every live instance of a class name. Returns the list (possibly empty).
function M.allOf(className)
    local list; pcall(function() list = FindAllOf(className) end)
    if type(list) ~= "table" then
        M.line("LIVE %s -> none", className)
        return {}
    end
    M.line("LIVE %s -> %d instance(s)", className, #list)
    return list
end

--=============================================================================
-- enumeration
--=============================================================================

---Every UFunction on a class, printed as FN lines. Returns the names.
function M.functions(cls, label)
    local names = {}
    if not M.valid(cls) then M.line("FN <no class %s>", tostring(label or "")); return names end
    local ok = pcall(function()
        cls:ForEachFunction(function(fn) pcall(function() names[#names + 1] = M.name(fn) end) end)
    end)
    if not ok then M.line("FN <ForEachFunction unavailable>"); return names end
    table.sort(names)
    M.line("FN count=%d on %s", #names, label or M.full(cls))
    for i, n in ipairs(names) do
        if i > M.LIST_LIMIT then M.line("FN ... (%d more)", #names - M.LIST_LIMIT); break end
        M.line("FN %s", n)
    end
    return names
end

---Every property on a class or struct, printed as PROP lines. Returns the names.
function M.properties(cls, label)
    local rows = {}
    if not M.valid(cls) then M.line("PROP <no class %s>", tostring(label or "")); return rows end
    local ok = pcall(function()
        cls:ForEachProperty(function(p)
            pcall(function() rows[#rows + 1] = { name = M.name(p), kind = M.className(p) } end)
        end)
    end)
    if not ok then M.line("PROP <ForEachProperty unavailable>"); return rows end
    M.line("PROP count=%d on %s", #rows, label or M.full(cls))
    for i, r in ipairs(rows) do
        if i > M.LIST_LIMIT then M.line("PROP ... (%d more)", #rows - M.LIST_LIMIT); break end
        M.line("PROP %s : %s", r.name, r.kind)
    end
    return rows
end

-- Find a UFunction on `owner`, which may be a UClass OR a live object / CDO. The first run
-- printed "function absent" for every lookup because it only ever asked GetFunctionByName on
-- what the caller passed, and callers pass CDOs — a CDO has no such method, its CLASS does.
-- Member access is the route that demonstrably works: reading inv.CountItemNum handed back a
-- UFunction userdata, so that is tried too.
local function findFunction(owner, fnName)
    if not M.valid(owner) then return nil end
    local fn

    -- owner is already a UClass / UStruct
    pcall(function() fn = owner:GetFunctionByName(fnName) end)
    if M.valid(fn) then return fn, "class:GetFunctionByName" end
    pcall(function() fn = owner:GetFunctionByNameInChain(fnName) end)
    if M.valid(fn) then return fn, "class:GetFunctionByNameInChain" end

    -- owner is an object: ask its class, then walk the super chain
    local cls; pcall(function() cls = owner:GetClass() end)
    if M.valid(cls) then
        pcall(function() fn = cls:GetFunctionByName(fnName) end)
        if M.valid(fn) then return fn, "GetClass():GetFunctionByName" end
        pcall(function() fn = cls:GetFunctionByNameInChain(fnName) end)
        if M.valid(fn) then return fn, "GetClass():GetFunctionByNameInChain" end

        local k, depth = cls, 0
        while M.valid(k) and depth < 12 do
            pcall(function() fn = k:GetFunctionByName(fnName) end)
            if M.valid(fn) then return fn, "super chain [" .. depth .. "]" end
            local parent; pcall(function() parent = k:GetSuperStruct() end)
            if not M.valid(parent) then pcall(function() parent = k.SuperStruct end) end
            k, depth = parent, depth + 1
        end
    end

    -- member access: reading the name off an object yields the bound UFunction
    local member; pcall(function() member = owner[fnName] end)
    if type(member) == "userdata" then return member, "member access" end

    return nil
end

---A UFunction's parameter list — the one thing that lets a caller be written correctly.
---`owner` may be a UClass or a live object; both are tried, because a CDO does not answer
---GetFunctionByName but its class does.
---
---Reading this is what a probe is FOR: a call written against a guessed argument list either
---throws (visible) or faults natively (fatal). Print the list, then write the call.
function M.params(owner, fnName)
    if not M.valid(owner) then M.line("PARAM <no owner> for %s", tostring(fnName)); return end

    local fn, how = findFunction(owner, fnName)
    if not fn then M.line("PARAM %s -> function absent", fnName); return nil end
    M.line("PARAM %s -> %s   (found via %s)", fnName, M.full(fn), how)

    local n = 0
    local listed = pcall(function()
        fn:ForEachProperty(function(p)
            pcall(function()
                n = n + 1
                local flags = ""
                pcall(function()
                    local off = p:GetOffset_Internal()
                    if off then flags = string.format(" @%d", off) end
                end)
                M.line("PARAM   %d %s : %s%s", n, M.name(p), M.className(p), flags)
            end)
        end)
    end)

    if not listed or n == 0 then
        -- ForEachProperty is not on a UFunction on every build; the parameter count still is.
        local parms; pcall(function() parms = fn:GetNumParms() end)
        local size;  pcall(function() size = fn:GetParmsSize() end)
        M.line("PARAM   (no property walk; NumParms=%s ParmsSize=%s)",
            tostring(parms), tostring(size))
    end
    return fn
end

---Walk an object's class chain, printing each class and optionally its members.
function M.chain(obj, withMembers)
    if not M.valid(obj) then M.line("CHAIN <invalid object>"); return end
    local k; pcall(function() k = obj:GetClass() end)
    local depth = 0
    while M.valid(k) and depth < 12 do
        M.line("CHAIN [%d] %s", depth, M.full(k))
        if withMembers then
            M.functions(k, "  chain[" .. depth .. "]")
            M.properties(k, "  chain[" .. depth .. "]")
        end
        local parent; pcall(function() parent = k:GetSuperStruct() end)
        if not M.valid(parent) then pcall(function() parent = k.SuperStruct end) end
        k = parent
        depth = depth + 1
    end
end

---Try to read a property off an object and print what came back.
function M.read(obj, propName)
    local v; local ok = pcall(function() v = obj[propName] end)
    M.line("VALUE %s -> %s", propName, ok and M.describe(v) or "read raised")
    return ok and v or nil
end

---Try to CALL a method with no side effects and print what came back. Use only for getters.
function M.callGet(obj, fnName, ...)
    local args = { ... }
    local v; local ok = pcall(function() v = obj[fnName](obj, table.unpack(args)) end)
    M.line("VALUE %s() -> %s", fnName, ok and M.describe(v) or "call raised")
    return ok and v or nil
end

--=============================================================================
-- DataTables
--
-- The tree has only ever extracted row NAMES. Reading a row VALUE is the open question
-- behind every iconOf and recipeOf item, so it gets a dedicated helper.
--
-- M.dataTable IS THE FALLBACK, NOT THE FRONT DOOR, and that is a measurement rather than a
-- preference. It walks M.allOf("DataTable") once per call, and that sweep is the crash-prone
-- one: tests/catalog.lua:6-10 records FindAllOf("DataTable") touching a stale pointer as an
-- EXCEPTION_ACCESS_VIOLATION that Lua pcall cannot catch. So nothing calls it in a loop —
-- test/probes/reflect.lua wants a table by name in nine sections and wrote its own CACHED
-- dataTableByName (reflect.lua:247-260) that sweeps once for the whole run, and
-- test/hooks/item_datatable_row_read.lua:87-91 tries the cheap named FindObject first and
-- only sweeps when that misses. Reach for it the same way: name lookup first, this second.
--=============================================================================

---Find a live UDataTable by its FName, by sweeping every loaded one. Returns it or nil.
---Prefer FindObject("DataTable", name) and fall back to this — see the note above.
function M.dataTable(tableName)
    local found
    for _, o in ipairs(M.allOf("DataTable")) do
        if M.valid(o) and M.name(o) == tableName then found = o; break end
    end
    M.line("CLASS DataTable %s -> %s", tableName, found and M.full(found) or "absent")
    return found
end

---Print a table's column names, from its RowStruct — the schema half of the icon question.
function M.columns(dt, tableName)
    if not M.valid(dt) then return {} end
    local rs; pcall(function() rs = dt.RowStruct end)
    if not M.valid(rs) then M.line("PROP <no RowStruct on %s>", tostring(tableName)); return {} end
    M.line("NOTE RowStruct of %s = %s", tostring(tableName), M.full(rs))
    local rows = M.properties(rs, "RowStruct " .. tostring(tableName))
    return rows
end

---Try every row-value accessor anyone has proposed, printing what each one answers.
function M.rowAccessors(dt, rowName)
    if not M.valid(dt) then return end
    M.section("row accessors for " .. tostring(rowName))
    local cls; pcall(function() cls = dt:GetClass() end)
    for _, fnName in ipairs({ "GetDataTableRowFromName", "FindRow", "GetRow", "GetRowMap", "GetRowNames" }) do
        M.params(cls, fnName)
    end
    -- Every call below passes an FName, which is what a row key is. Do not add a variant
    -- that passes the raw string "to see" — that faults natively and ends the session.
    for _, fnName in ipairs({ "GetDataTableRowFromName", "FindRow", "GetRow" }) do
        local v; local ok = pcall(function() v = dt[fnName](dt, FName(rowName)) end)
        M.line("VALUE dt:%s(FName(%q)) -> %s", fnName, rowName, ok and M.describe(v) or "call raised")
        if ok and (type(v) == "userdata" or type(v) == "table") then
            for _, col in ipairs({ "SoftIcon", "IconName", "IconTexture", "Icon", "Texture" }) do
                local iv; local okr = pcall(function() iv = v[col] end)
                if okr and iv ~= nil then M.line("VALUE   .%s -> %s", col, M.describe(iv)) end
            end
        end
    end
    local lib = M.find("/Script/Engine.Default__DataTableFunctionLibrary")
    if lib then
        local libCls; pcall(function() libCls = lib:GetClass() end)
        M.functions(libCls, "DataTableFunctionLibrary")
    end
end

--=============================================================================
-- watching (the F8 shape)
--=============================================================================

---Arm a native hook and log every call, with its parameters described. Returns true when
---the hook was accepted. Hooks cannot be removed in UE4SS, so a probe that arms one says so.
function M.watch(hookPath, label, maxLines)
    maxLines = maxLines or 40
    local seen = 0
    local ok = pcall(function()
        RegisterHook(hookPath, function(self, a1, a2, a3, a4)
            seen = seen + 1
            if seen > maxLines then return end
            pcall(function()
                local parts = { string.format("HOOK %s #%d", label, seen) }
                local s; pcall(function() s = self and self:get() end)
                parts[#parts + 1] = "self=" .. M.describe(s)
                for i, p in ipairs({ a1, a2, a3, a4 }) do
                    local v; pcall(function() v = p and p:get() end)
                    if v ~= nil then parts[#parts + 1] = string.format("a%d=%s", i, M.describe(v)) end
                end
                M.line(table.concat(parts, "  "))
            end)
        end)
    end)
    M.line("NOTE armed %s -> %s", hookPath, ok and "ok" or "FAILED (function not found on this build)")
    return ok
end

return M
