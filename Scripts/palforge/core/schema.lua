-- PalForge core.schema: the generic MECHANISM behind every api spec. It holds no type
-- definitions of its own — each api module declares its own shapes (they differ per
-- domain) and this file only turns a declaration into something that validates, fills
-- defaults and documents itself.
--
-- Declaring a shape (fields are an ARRAY, so their order is preserved for :help() and
-- for the generated type definitions):
--
--   local schema = require("palforge.core.schema")
--   local Spec = schema.define("Mesh.Spec", {
--       { "kind",  type = "string", values = { "procedural", "static", "skeletal" },
--                  default = "skeletal", doc = "which core.mesh backend renders it" },
--       { "model", type = "string", required = true, doc = "asset path" },
--       { "scale", type = "number", doc = "uniform scale" },
--   }, { handle = "Mesh.Handle" })
--
-- Using it:
--   Spec:validate(t, "context")   -- validated COPY with defaults filled (a plain table)
--   Spec.fields                   -- the ordered declaration, readable at runtime
--   Spec:help()                   -- human-readable schema dump
--
-- SPECS ARE PRIVATE TO THEIR MODULE. An api module keeps its shapes as locals and does
-- not publish them — `Pal` is a thing you CALL, not a namespace to browse. Everything
-- that needs the declarations reaches them through the registry here instead:
--
--   schema.get("Pal.Spec")   -- the spec object
--   schema.help("Pal.Spec")  -- its field list, printable
--   schema.all()             -- every spec ever declared, in declaration order
--   schema.derive(...)       -- the same shape with different per-field policy
--
-- Two rules that every domain shares live at the bottom of this file rather than in eight
-- api modules: schema.validId (the `check` an `id` field carries — the resolve shape, so an
-- id that could never reach the game is refused while it is being written) and
-- schema.defineOpts (the optional second argument to every X(spec, opts) constructor).
--
-- That is what tools/gen-types.lua walks to generate the editor type definitions, so the
-- annotations still cannot drift from what a define call actually accepts.
--
-- The `__spec` METAFIELD makes nesting work: a handle whose metatable carries it is
-- unwrapped to the plain table it stands for before validation, which is how
-- `mesh = Mesh{ ... }` passes a defined object into another definition without the
-- schema knowing anything about handles. A spec whose values can arrive that way names
-- the handle type ONCE, at its own declaration (`{ handle = "Mesh.Handle" }` above), so
-- every field that points at it through `of` gets the union in the type definitions
-- without restating it.
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
--
-- SPEC OPTIONS (the third argument to define)
--   handle   string    the handle type that also satisfies this shape, through `__spec`
--                      (e.g. "Mesh.Handle"). Types-only, like `sig`: validation already
--                      accepts it, this is what tells the editor so.

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
        -- a callable table stands in for a function wherever one is expected
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
-- defined objects
--=============================================================================

-- A defined object (the handle `Mesh{ ... }` returns, say) stands for the table it was
-- built from. When its metatable carries `__spec`, validation sees that table instead of
-- the handle, so `mesh = Mesh{ ... }` and `mesh = { ... }` reach the nested spec
-- identically — the caller can nest a definition without it becoming a special case.
local function unwrap(v)
    if type(v) ~= "table" then return v end
    local mt = getmetatable(v)
    local tospec = mt and rawget(mt, "__spec")
    if type(tospec) == "function" then return tospec(v) end
    return v
end

--=============================================================================
-- Spec
--=============================================================================

local Spec = {}
Spec.__index = Spec

-- Look up a field descriptor by name.
function Spec:field(name)
    return self._byName[name]
end

-- Validate `t` against this spec and return a NEW plain table with defaults filled.
-- `context` is prepended to error messages (e.g. "Pal" for a Pal{ ... } call).
-- The input is never mutated, and the result is a plain table so nothing downstream
-- can tell a constructed value from a hand-written one.
function Spec:validate(t, context)
    local where = context or self.name
    if t == nil then t = {} end
    t = unwrap(t)
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
            -- only a nested shape can arrive as a defined handle, so only that case pays
            -- for the unwrap (see the `__spec` metafield in the header)
            if f.of then v = unwrap(v) end
            -- "Pal: field 'mesh'" — the reference a reader can act on. Array and map
            -- elements extend the name itself (skills[2]) so the whole path is inside
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
-- define + the registry
--
-- Every spec is recorded here as it is declared, which is what lets an api module keep
-- its shapes PRIVATE: nothing has to be hung off the module table for tooling to find
-- it. Names are globally unique ("Pal.Spec", "Pal.Spec.Events", "Mesh.Spec"), so the
-- registry doubles as a check that two modules never claim the same shape name.
--=============================================================================

local registry = {}   -- name -> spec
local order    = {}   -- specs in declaration order (nested ones come before the top spec)

-- Build a spec named `name` from an ordered ARRAY of field descriptors, plus the optional
-- spec `opts` (today: `handle`). The returned object carries `.fields` / `.name` for
-- introspection. Keep it as a local in the module that declares it; reach it elsewhere
-- via schema.get.
function M.define(name, fields, opts)
    assert(type(name) == "string" and #name > 0, "schema.define: name (string) required")
    assert(type(fields) == "table", "schema.define: fields (array of descriptors) required")
    if registry[name] then
        error(string.format("PalForge: schema.define: %q is already declared", name), 0)
    end

    local self = setmetatable({ name = name, fields = {}, _byName = {},
                                handle = opts and opts.handle }, Spec)
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
    registry[name] = self
    order[#order + 1] = self
    return self
end

-- Declare `name` as a copy of `base` with per-field bits replaced — today `default`, the
-- one thing that is genuinely the CONSUMER's policy rather than the shape's (a structure
-- is a static mesh where a pal is a skeletal one, but both are the same ten fields).
-- Deriving keeps the two in step: a field added to the base reaches every derivative.
--
--   local Mesh = schema.derive("Building.Spec.Mesh", schema.get("Mesh.Spec"), {
--       kind = { default = "static" },
--   })
function M.derive(name, base, overrides)
    assert(type(base) == "table" and getmetatable(base) == Spec,
        "schema.derive: base must be a spec built by schema.define")
    local fields = {}
    for i, f in ipairs(base.fields) do
        local copy = { f.name, type = f.type, required = f.required, default = f.default,
                       values = f.values, of = f.of, arrayOf = f.arrayOf, mapOf = f.mapOf,
                       doc = f.doc, sig = f.sig, check = f.check }
        for key, value in pairs(overrides and overrides[f.name] or {}) do copy[key] = value end
        fields[i] = copy
    end
    for fname in pairs(overrides or {}) do
        assert(base._byName[fname],
            string.format("schema.derive(%s): %q is not a field of %s", name, fname, base.name))
    end
    local derived = M.define(name, fields, { handle = base.handle })

    -- CARRY THE BASE'S OWN `validate`, and this is a correctness fix rather than a convenience.
    -- A spec may rawset `validate` on ITSELF to add cross-field passes that the field list cannot
    -- express — Mesh.Spec does (api/mesh.lua:169), and it is where `resolvePackPath` runs on
    -- `model`/`texture` and where an `SM_` model declared as `kind = "skeletal"` gets warned
    -- about. `M.define` builds a FRESH spec object, so before this line the derivative inherited
    -- only core/schema's shared method and both passes were silently absent from it. The visible
    -- consequence: a named `Mesh{ model = "art/x.obj" }` resolved the relative path and an inline
    -- `Building{ mesh = { model = "art/x.obj" } }` did not — same declaration, two behaviours,
    -- no diagnostic. rawget so an inherited method is not mistaken for an override.
    local own = rawget(base, "validate")
    if own then rawset(derived, "validate", own) end
    return derived
end

---Forget a declared spec. The inverse of `define`, and it exists for one caller shape: a TEST
---that declares throwaway specs and has to leave the registry as it found it. `test/cases/schema`
---registers eight namespaced specs on every F1 press (Inner, Spec, Dup, Derived, ReqDefault,
---FnDefault, Untyped, Checked) and had no way to take them back, so a long dev session grew the
---list `schema.all()` walks — inert, but the sweep in `test/support` could not reach it.
---
---Returns true when something was removed, false when the name was not declared. Never raises:
---forgetting what is not there is the caller's normal case, not an error.
---
---⚠️ NOT a runtime facility. A spec is consumed by a live definition class; dropping one out from
---under a definition does not un-validate anything already built, and re-declaring the same name
---afterwards is what `define`'s duplicate check exists to catch. Use it in teardown, nowhere else.
---@param name string
---@return boolean removed
function M.undefine(name)
    if type(name) ~= "string" or registry[name] == nil then return false end
    local self = registry[name]
    registry[name] = nil
    for i = #order, 1, -1 do
        if order[i] == self then table.remove(order, i) end
    end
    return true
end

---A declared spec by name ("Pal.Spec", "Pal.Spec.Events", ...), or nil.
---@param name string
function M.get(name)
    return registry[name]
end

---Every declared spec, in declaration order. The order matters to the type generator:
---a nested shape is declared before the spec that references it, so emitting them in
---this order declares each class before it is used.
function M.all()
    local out = {}
    for i, s in ipairs(order) do out[i] = s end
    return out
end

---The printable field list of a declared spec — the runtime "what can I pass here?".
---@param name string
---@return string
function M.help(name)
    local spec = registry[name]
    if not spec then
        local names = {}
        for _, s in ipairs(order) do names[#names + 1] = s.name end
        table.sort(names)
        return string.format("PalForge: no spec named %q. Declared: %s",
            tostring(name), table.concat(names, ", "))
    end
    return spec:help()
end

-- A non-empty string — the weakest check an id field can carry. Kept because non-id string
-- fields use it too; every `id` field now carries M.validId below instead.
function M.nonEmpty(v)
    if type(v) == "string" and #v > 0 then return true end
    return false, "must be a non-empty string"
end

--=============================================================================
-- the id rules, written once
--
-- These two live here rather than in each api module for the same reason the specs do:
-- eight domains were enforcing eight slightly different things (in practice: `nonEmpty`
-- and nothing else, in all eight), and a rule that is restated per domain is a rule that
-- drifts per domain. core.object_manager owns the id MODEL; this file owns the moment a
-- definition is checked, so the check is spelled here and delegated there.
--=============================================================================

-- core.object_manager, required lazily and once. Lazily because schema.lua is the bottom
-- of the api stack and must stay loadable on its own (the type generator and the headless
-- tests both load it with no registry in sight); once because a define-heavy startup calls
-- validId per definition and require's package.loaded lookup is not free at that rate.
-- `false` records a failed require so it is not retried per call.
local objectManager
local function manager()
    if objectManager == nil then
        local ok, mod = pcall(require, "palforge.core.object_manager")
        objectManager = ok and mod or false
    end
    return objectManager or nil
end

-- THE ID SHAPE CHECK — what `{ "id", check = schema.validId }` means, and why it is not
-- `nonEmpty` any more (F-4/C4).
--
-- An id with NO colon is a literal game id ("Wood", "ChickenPal") and only has to be a
-- non-empty string. An id WITH a colon is namespaced, and object_manager resolves
-- "packid:name" to the row spelling PalSchema actually writes into the game's tables,
-- "packid_name" — which is only defined when both halves are letters, digits and
-- underscores.
--
-- Before this check existed, `Building{ id = "my-pack:Bench" }` validated (nonEmpty is
-- happy with a hyphen), registered, and was DEAD: resolution failed at the engine boundary,
-- the build id never entered Registry.byBuildId, the actor scan never matched, and none of
-- onPlace/onLoad/onTick/onRemove could ever fire — with no log line anywhere. Refusing it
-- at define time costs one comparison and turns a silent dead definition into a sentence the
-- author reads while writing it.
--
-- The RULE belongs to object_manager, not here: om.validId is its declared home, and
-- om.resolve is the same rule executed — it already answers nil plus the reason for exactly
-- the ids that cannot be resolved. So this delegates, in that order, and deliberately holds
-- no second copy of the pattern, which is the copy that would drift from the resolver.
function M.validId(v)
    if type(v) ~= "string" or #v == 0 then return false, "must be a non-empty string" end
    local om = manager()
    if not om then return true end   -- no registry loaded: there is no id model to enforce
    -- object_manager.validId is the ONE id rule, and this is a forward to it rather than a
    -- preferred-if-present branch with a resolve() fallback behind it. The fallback used to be
    -- here and could never run: object_manager ships in this tree and gained validId in the same
    -- change, so the probe was constant-true. Two spellings of "is this a usable id" is how a
    -- define-time refusal starts disagreeing with the resolver it exists to protect.
    local ok, why = om.validId(v)
    if ok then return true end
    return false, why or "is not an id object_manager can resolve"
        .. ". A namespaced id is \"packid:name\", and both halves may hold letters, digits "
        .. "and _ only, because the row PalSchema writes for it is packid_name"
end

-- THE OPTIONAL SECOND ARGUMENT every domain constructor takes: X(spec, opts) (C2/F-8).
--
--   opts.register == false   build and return the handle, register NOTHING
--   opts.pack     == "id"    register attributed to that pack (see object_manager.register)
--
-- `register = false` exists because a READ was starting to write world state: the native
-- catalogs fabricate a definition on demand with `X{ id = id }`, and for buildings
-- registering is not inert — core/event's 500 ms scan picks the new def up and every matching
-- actor in the world becomes a tracked, PERSISTED instance. So reading native.buildings.
-- Foundation in a tooltip made PalForge start writing a record for every foundation in the
-- base. A non-registering define is the shape that makes a catalog read a read again.
--
-- Returns `register, pack` — two values rather than a table, because that is exactly what a
-- constructor needs and it keeps the call site one line. Anything wrong here is a hard error
-- in the same voice as the spec errors: an option a caller misspells is an option that was
-- silently ignored, which is the failure this whole layer exists to prevent.
---@return boolean register, string? pack
function M.defineOpts(opts, where)
    if opts == nil then return true, nil end
    if type(opts) ~= "table" then
        fail(string.format("%s: the second argument is the options table "
            .. "{ register = false, pack = \"packid\" }, got %s", where, type(opts)))
    end
    for key in pairs(opts) do
        if key ~= "register" and key ~= "pack" then
            fail(string.format("%s: unknown define option %q. Valid options: register, pack",
                where, tostring(key)))
        end
    end
    if opts.register ~= nil and type(opts.register) ~= "boolean" then
        fail(string.format("%s: define option \"register\" expects boolean, got %s",
            where, type(opts.register)))
    end
    if opts.pack ~= nil and (type(opts.pack) ~= "string" or #opts.pack == 0) then
        fail(string.format("%s: define option \"pack\" expects a non-empty pack id string, got %s",
            where, type(opts.pack)))
    end
    return opts.register ~= false, opts.pack
end

return M
