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

---The CDO for a /Script/Pal class name, trying the Default__ form.
function M.cdo(scriptClass)
    return M.find("/Script/" .. scriptClass:gsub("^/Script/", ""):gsub("^(.-%.)", "%1Default__"))
end

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

---A UFunction's parameter list. A UFunction is a UStruct, so its parameters enumerate as
---properties — this is how to learn a call's real signature.
function M.params(cls, fnName)
    if not M.valid(cls) then M.line("PARAM <no class> for %s", tostring(fnName)); return end
    local fn; pcall(function() fn = cls:GetFunctionByName(fnName) end)
    if not M.valid(fn) then
        pcall(function() fn = cls:GetFunctionByNameInChain(fnName) end)
    end
    if not M.valid(fn) then M.line("PARAM %s -> function absent", fnName); return nil end
    M.line("PARAM %s -> %s", fnName, M.full(fn))
    local n = 0
    local ok = pcall(function()
        fn:ForEachProperty(function(p)
            pcall(function()
                n = n + 1
                M.line("PARAM   %d %s : %s", n, M.name(p), M.className(p))
            end)
        end)
    end)
    if not ok then M.line("PARAM   <ForEachProperty unavailable on the function>") end
    if n == 0 then M.line("PARAM   (no parameters listed)") end
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
--=============================================================================

---Find a live UDataTable by its FName. Returns it or nil.
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
-- watching (the F7 shape)
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
