-- PalForge core.schema: the generic MECHANISM behind every api spec. It holds no type
-- definitions of its own — each api module declares its own shapes (they differ per
-- domain) and this file only turns a declaration into something that validates, fills
-- defaults, documents itself, and can be called as a constructor.
--
-- Declaring a shape (fields are an ARRAY, so their order is preserved for :help() and
-- for the generated type definitions):
--
--   local schema = require("palforge.core.schema")
--   local Mesh = schema.define("Pal.Spec.Mesh", {
--       { "kind",  type = "string", values = { "procedural", "static", "skeletal" },
--                  default = "procedural", doc = "which core.mesh backend renders it" },
--       { "model", type = "string", required = true, doc = "asset path" },
--       { "scale", type = "number", doc = "uniform scale" },
--   })
--
-- Using it:
--   Mesh{ model = "/Game/X.X" }   -- validated COPY with defaults filled (a plain table)
--   Mesh.fields                   -- the ordered declaration, readable at runtime
--   Mesh:help()                   -- human-readable schema dump
--   Mesh:validate(t, "context")   -- same as calling it, with a context for error messages
--
-- STRICTNESS: any problem is a hard error (the caller's define never half-succeeds) —
-- an unknown field, a missing required one, a wrong type, a value outside `values`, a
-- bad element in an `arrayOf`, or a failing `check`. Unknown fields get a did-you-mean
-- suggestion, because a silently ignored typo (meshSpec vs mesh) is the exact failure
-- this layer exists to prevent.
--
-- FIELD DESCRIPTOR
--   [1]      string    the field name (positional, so declaration order is kept)
--   type     string    "string" | "number" | "boolean" | "table" | "function",
--                      or a union like "string|number". Omit to accept anything.
--   required boolean   error when absent
--   default  any       used when absent (a function is called to build a fresh value)
--   values   any[]     the value must be one of these
--   of       Spec      validate the value against a nested spec
--   arrayOf  string    every array element must have this type
--   mapOf    string    every value in the table must have this type
--   doc      string    one-line description (feeds :help() and the type definitions)
--   sig      string    for a function field, its LuaLS signature (e.g. "fun(self, ctx: table)").
--                      Only the generated type definitions read it; validation ignores it.
--   check    fun(v):boolean, string?   extra predicate; return false + reason to reject

local M = {}

--=============================================================================
-- error reporting
--=============================================================================

-- Raise with level 0 so the message is not prefixed with this file's line — the text
-- already names the spec, the field and the caller's context, which is what a pack
-- author needs to see in the UE4SS log.
local function fail(msg)
    error("PalForge: " .. msg, 0)
end

-- Levenshtein distance, used only for did-you-mean on an unknown field.
local function distance(a, b)
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local ai = a:sub(i, i)
        for j = 1, lb do
            local cost = (ai == b:sub(j, j)) and 0 or 1
            local min = prev[j] + 1
            if cur[j - 1] + 1 < min then min = cur[j - 1] + 1 end
            if prev[j - 1] + cost < min then min = prev[j - 1] + cost end
            cur[j] = min
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

-- The closest declared field name to `name`, or nil when nothing is close enough.
-- Containment wins over edit distance: the most common mistake is a decorated name
-- (meshSpec for mesh, iconPath for icon), which reads as obvious to a human but is
-- several edits away. Longest containment first, and only for names of 3+ characters
-- so a short field like `id` cannot match half the declaration.
local function suggest(name, fields)
    local lname = name:lower()

    local best, bestLen = nil, 2
    for _, f in ipairs(fields) do
        local lf = f.name:lower()
        if #lf > bestLen and (lname:find(lf, 1, true) or lf:find(lname, 1, true)) then
            best, bestLen = f.name, #lf
        end
    end
    if best then return best end

    local bestD = math.huge
    for _, f in ipairs(fields) do
        local d = distance(lname, f.name:lower())
        if d < bestD then best, bestD = f.name, d end
    end
    -- otherwise accept only a genuinely close match (a third of the name's length)
    if best and bestD <= math.max(2, math.floor(#name / 3)) then return best end
    return nil
end

--=============================================================================
-- type checking
--=============================================================================

-- Does `v` satisfy the type notation `t` ("string", "string|number", nil = anything)?
local function typeOk(v, t)
    if t == nil then return true end
    local actual = type(v)
    for want in tostring(t):gmatch("[^|]+") do
        if actual == want then return true end
        -- a Spec is callable, so a "function" expectation also accepts one
        if want == "function" and actual == "table" and getmetatable(v)
            and getmetatable(v).__call then return true end
    end
    return false
end

local function quoted(list)
    local out = {}
    for _, v in ipairs(list) do out[#out + 1] = string.format("%q", tostring(v)) end
    return table.concat(out, ", ")
end

local function fieldNames(fields)
    local out = {}
    for _, f in ipairs(fields) do out[#out + 1] = f.name end
    return table.concat(out, ", ")
end

--=============================================================================
-- Spec
--=============================================================================

local Spec = {}
Spec.__index = Spec

-- Calling a spec validates: Mesh{ model = "..." } == Mesh:validate({ model = "..." }).
Spec.__call = function(self, t, context) return self:validate(t, context) end

-- Look up a field descriptor by name.
function Spec:field(name)
    return self._byName[name]
end

-- Validate `t` against this spec and return a NEW plain table with defaults filled.
-- `context` is prepended to error messages (e.g. "Pal.define{ id = 'example:Boss' }").
-- The input is never mutated, and the result is a plain table so nothing downstream
-- can tell a constructed value from a hand-written one.
function Spec:validate(t, context)
    local where = context or self.name
    if t == nil then t = {} end
    if type(t) ~= "table" then
        fail(string.format("%s: expected a table, got %s. Fields: %s",
            where, type(t), fieldNames(self.fields)))
    end

    -- 1. reject anything not declared (with a did-you-mean, since typos are the point)
    for key in pairs(t) do
        if type(key) ~= "string" then
            fail(string.format("%s: keys must be strings, got a %s key", where, type(key)))
        end
        if not self._byName[key] then
            local hint = suggest(key, self.fields)
            fail(string.format("%s: unknown field %q%s. Valid fields: %s",
                where, key,
                hint and (" (did you mean " .. string.format("%q", hint) .. "?)") or "",
                fieldNames(self.fields)))
        end
    end

    -- 2. check every declared field and fill defaults
    local out = {}
    for _, f in ipairs(self.fields) do
        local v = t[f.name]

        if v == nil then
            if f.required then
                fail(string.format("%s: field %q is required (%s)",
                    where, f.name, f.doc or (f.type or "any")))
            end
            if f.default ~= nil then
                v = (type(f.default) == "function") and f.default() or f.default
            end
        end

        if v ~= nil then
            -- "Pal.define: field 'mesh'" — the reference a reader can act on. Array and
            -- map elements extend the name itself (skills[2]) so the whole path is inside
            -- one pair of quotes.
            local function at(suffix)
                return string.format("%s: field %q", where, f.name .. (suffix or ""))
            end

            if not typeOk(v, f.type) then
                fail(string.format("%s expects %s, got %s", at(), f.type, type(v)))
            end

            if f.values then
                local ok = false
                for _, allowed in ipairs(f.values) do
                    if v == allowed then ok = true; break end
                end
                if not ok then
                    fail(string.format("%s must be one of { %s }, got %q",
                        at(), quoted(f.values), tostring(v)))
                end
            end

            if f.arrayOf then
                for i, item in ipairs(v) do
                    if not typeOk(item, f.arrayOf) then
                        fail(string.format("%s expects %s, got %s",
                            at("[" .. i .. "]"), f.arrayOf, type(item)))
                    end
                end
            end

            if f.mapOf then
                for k, item in pairs(v) do
                    if not typeOk(item, f.mapOf) then
                        fail(string.format("%s expects %s, got %s",
                            at("." .. tostring(k)), f.mapOf, type(item)))
                    end
                end
            end

            if f.of then
                -- name the nested spec in the context, so the reader knows which shape
                -- to go and read when the complaint is about a field inside it.
                v = f.of:validate(v, at() .. " (" .. f.of.name .. ")")
            end

            if f.check then
                local ok, why = f.check(v)
                if not ok then
                    fail(string.format("%s is invalid: %s", at(), why or "failed check"))
                end
            end
        end

        out[f.name] = v
    end
    return out
end

-- A human-readable dump of this spec: one line per field, in declaration order.
-- Handy from a console command or a log when you cannot remember the shape.
function Spec:help()
    local lines = { self.name .. " {" }
    for _, f in ipairs(self.fields) do
        local marks = {}
        if f.required then marks[#marks + 1] = "required" end
        if f.default ~= nil and type(f.default) ~= "function" then
            marks[#marks + 1] = "default=" .. tostring(f.default)
        end
        if f.values then marks[#marks + 1] = "one of { " .. quoted(f.values) .. " }" end
        if f.of then marks[#marks + 1] = f.of.name end
        if f.arrayOf then marks[#marks + 1] = f.arrayOf .. "[]" end
        if f.mapOf then marks[#marks + 1] = "map of " .. f.mapOf end
        lines[#lines + 1] = string.format("  %-13s %-10s %s%s",
            f.name, f.type or "any",
            (#marks > 0) and ("(" .. table.concat(marks, ", ") .. ") ") or "",
            f.doc or "")
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

--=============================================================================
-- define
--=============================================================================

-- Build a spec named `name` from an ordered ARRAY of field descriptors. The returned
-- object is callable (a constructor), carries `.fields` / `.name` for introspection,
-- and is what an api module exposes as X.Spec.
function M.define(name, fields)
    assert(type(name) == "string" and #name > 0, "schema.define: name (string) required")
    assert(type(fields) == "table", "schema.define: fields (array of descriptors) required")

    local self = setmetatable({ name = name, fields = {}, _byName = {} }, Spec)
    for i, f in ipairs(fields) do
        local fname = f[1]
        assert(type(fname) == "string" and #fname > 0,
            string.format("schema.define(%s): field #%d needs a name as its first element", name, i))
        assert(not self._byName[fname],
            string.format("schema.define(%s): duplicate field %q", name, fname))
        local desc = {
            name = fname, type = f.type, required = f.required, default = f.default,
            values = f.values, of = f.of, arrayOf = f.arrayOf, mapOf = f.mapOf,
            doc = f.doc, sig = f.sig, check = f.check,
        }
        self.fields[#self.fields + 1] = desc
        self._byName[fname] = desc
    end
    return self
end

-- Is `v` a spec built by define()? (Used by the type-definition generator.)
function M.isSpec(v)
    return type(v) == "table" and getmetatable(v) == Spec
end

-- A non-empty string — the check every id field shares.
function M.nonEmpty(v)
    if type(v) == "string" and #v > 0 then return true end
    return false, "must be a non-empty string"
end

return M
