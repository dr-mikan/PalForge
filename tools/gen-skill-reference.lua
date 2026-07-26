-- PalForge dev tool: generate skills/palforge/reference/api.md — the whole public API as
-- ONE compact Markdown page an AI coding agent can hold in context and write correct Lua
-- from on the first try.
--
-- Same principle as tools/gen-types.lua, same shape: stub the UE4SS globals, require the
-- api modules (that is what puts their PRIVATE shapes into the core/schema registry) and
-- walk schema.all(). Nothing here is hand-written prose about the api — every field, every
-- hook, every method name and every error message is read back from the running modules or
-- from the declarations themselves, so the reference cannot drift from what a call accepts.
--
-- Run it from the repo root with a plain Lua (no game needed):
--   cd <PalForge> && lua5.4 tools/gen-skill-reference.lua .
--
-- WHERE EACH PART COMES FROM
--   spec fields, defaults, enums, docs   the schema registry          schema.all()
--   lifecycle hooks + their signatures   the *.Spec.Events specs      f.sig / f.doc
--   whether a hook FIRES                 the hook's own doc string    "LIVE" / "declarable"
--   module surface (get / get_all / ...) pairs(module) at runtime     + __call detection
--   Handle methods and their arity       the handle's metatable       debug.getlocal names
--   return types and one-line notes      the ---@return annotations   next to each function
--   the validation rules                 REAL failing calls, pcall'd  so the text is exact
--
-- Re-run it whenever a spec, a hook or a handle method changes.

local root = (arg and arg[1]) or "."
if root:sub(-1) ~= "/" then root = root .. "/" end
local scripts = root .. "Scripts/"
local OUT     = root .. "skills/palforge/reference/api.md"
local CMD     = "lua5.4 tools/gen-skill-reference.lua ."

--=============================================================================
-- Load the api modules with the UE4SS globals stubbed out. Requiring an api module only
-- builds tables, but the natives it pulls in expect these to exist.
--=============================================================================
for _, name in ipairs({ "FindFirstOf", "FindAllOf", "StaticFindObject", "LoadAsset",
                        "RegisterHook", "RegisterKeyBind", "RegisterConsoleCommandHandler",
                        "ExecuteInGameThread", "LoopAsync" }) do
    _G[name] = function() return nil end
end
_G.FName = function(s) return { ToString = function() return s end } end
_G.Key = {}

package.path = scripts .. "?.lua;" .. scripts .. "?/init.lua;" .. package.path

local schema = require("palforge.core.schema")
local api    = require("palforge.api")

local SPECS = schema.all()

--=============================================================================
-- text helpers
--=============================================================================

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- One markdown table cell: no newlines, no bare pipes.
local function cell(s)
    s = trim(s):gsub("%s+", " "):gsub("|", "\\|")
    return (s ~= "" and s) or "—"
end

-- A code span safe inside a table cell — a union type ("table|fun(): table") would
-- otherwise end the column early.
local function code(s)
    return "`" .. trim(s):gsub("%s+", " "):gsub("|", "\\|") .. "`"
end

-- As many WHOLE sentences of `s` as fit in `limit`, never fewer than one. A sentence ends
-- at a period followed by whitespace and a capital letter, so "e.g." and "0.5 s" do not
-- split it. Taking more than the first sentence matters: the caveat that a call is a no-op
-- ("NOT IMPLEMENTED — returns false") is routinely the SECOND sentence, and an agent that
-- only saw the first would call it expecting it to work.
local function sentence(s, limit)
    s = trim(s):gsub("%s+", " ")
    limit = limit or 150
    local cuts = { }
    for pos, nxt in s:gmatch("()%.%s+(%a)") do
        if nxt:match("%u") then cuts[#cuts + 1] = pos end
    end
    cuts[#cuts + 1] = #s
    local take = cuts[1]
    for _, pos in ipairs(cuts) do
        if pos <= limit then take = pos else break end
    end
    s = s:sub(1, take)
    if #s > limit then s = s:sub(1, limit - 1):gsub("%s%S*$", "") .. "…" end
    return s
end

-- Hard truncation, for a cell where a whole sentence will not fit anyway.
local function clip(s, limit)
    s = trim(s):gsub("%s+", " ")
    if #s > limit then s = s:sub(1, limit - 1):gsub("%s%S*$", "") .. "…" end
    return s
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

local function lines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
    return out
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--=============================================================================
-- THE DOMAIN LIST — parsed from api/init.lua's requires, so the module list stays in ONE
-- place (that file) and this tool cannot document a stale set. Order is declaration order.
--=============================================================================

local DOMAINS = {}   -- { name = "Pal", file = "pal" }
do
    local text = assert(readFile(scripts .. "palforge/api/init.lua"), "cannot read api/init.lua")
    for name, file in text:gmatch("local%s+(%u[%w_]*)%s*=%s*require%(\"palforge%.api%.([%w_]+)\"%)") do
        DOMAINS[#DOMAINS + 1] = { name = name, file = file }
    end
end
assert(#DOMAINS > 0, "no domains found in api/init.lua")

--=============================================================================
-- SOURCE SCAN — the LuaLS annotations that sit next to each function. They carry the two
-- things a spec cannot: what a call RETURNS, and which ctx fields an event hands over.
-- Everything is keyed by domain, so nothing has to be listed here by hand.
--=============================================================================

local src = {}   -- domain -> { blurb, docs = { ["handle:spawn"] = {...} }, classes = {...} }

local function parseAnnotations(block)
    local info = { summary = {}, returns = {}, ctx = nil, params = {} }
    for _, raw in ipairs(block) do
        local line = trim(raw:gsub("^%s*%-%-%-", ""))
        local tag, rest = line:match("^@(%w+)%s*(.*)$")
        if tag == "return" then
            local ty, tail = rest:match("^(%S+)%s*(.*)$")
            local note = tail and tail:match("#%s*(.*)$") or nil
            info.returns[#info.returns + 1] = { type = ty, note = note }
        elseif tag == "param" then
            local pname, tail = rest:match("^(%S+)%s*(.*)$")
            local note = tail and tail:match("#%s*(.*)$") or nil
            info.params[#info.params + 1] = { name = pname, note = note }
            if pname == "ctx" and note then info.ctx = note end
        elseif tag == nil and line ~= "" then
            info.summary[#info.summary + 1] = line
        end
    end
    info.summary = table.concat(info.summary, " ")
    return info
end

for _, d in ipairs(DOMAINS) do
    local entry = { docs = {}, classes = {}, blurb = nil }
    local text  = assert(readFile(scripts .. "palforge/api/" .. d.file .. ".lua"),
                         "cannot read api/" .. d.file .. ".lua")
    local ls    = lines(text)

    -- the domain blurb: the first sentence of the header's second paragraph, else the tail
    -- of the title line ("-- palforge/api/player.lua — PUBLIC player API. ...").
    do
        local para, started = {}, false
        for i = 2, #ls do
            local line = ls[i]
            if not line:match("^%-%-") then break end
            local body = trim(line:gsub("^%-%-", ""))
            if body == "" then
                if started then break end
            else
                started = true
                para[#para + 1] = body
            end
        end
        entry.blurb = sentence(table.concat(para, " "), 170)
        if entry.blurb == "" then
            -- no second paragraph (api/player.lua): fall back to the title line's own tail
            local title = trim((ls[1] or ""):gsub("^%s*%-%-%s*", ""))
            local at = title:find("—", 1, true)
            entry.blurb = trim(at and title:sub(at + #"—") or title)
        end
    end

    -- annotation blocks -> functions, and ---@class blocks -> their ---@field lists
    local buf, cls = {}, nil
    for _, line in ipairs(ls) do
        if line:match("^%s*%-%-%-") then
            buf[#buf + 1] = line
            local cname = line:match("^%s*%-%-%-@class%s+([%w_%.]+)")
            if cname then cls = { name = cname, fields = {} }; entry.classes[#entry.classes + 1] = cls end
            local fname, ftype, fnote = line:match("^%s*%-%-%-@field%s+(%S+)%s+(%S+)%s*#?%s*(.*)$")
            if fname and cls then
                cls.fields[#cls.fields + 1] = { name = fname, type = ftype,
                                                note = (fnote or ""):gsub("^#%s*", "") }
            end
        else
            if #buf > 0 then
                local key
                local h = line:match("^function%s+Handle:([%w_]+)")
                local c = line:match("^function%s+Class:([%w_]+)")
                local m, f = line:match("^function%s+([%w_]+)%.([%w_]+)")
                if h then key = "handle:" .. h
                elseif c then key = "class:" .. c
                elseif m == d.name and f then key = "mod:" .. f
                elseif line:match("^local%s+function%s+define") then key = "mod:__call" end
                if key then entry.docs[key] = parseAnnotations(buf) end
                buf = {}
            end
            if not line:match("^%s*$") then cls = nil end
        end
    end
    src[d.name] = entry
end

-- The per-instance closures core/event bolts onto a live Building instance (they are
-- instance FIELDS, not Building.Class methods, so no runtime walk of the class finds them).
local INSTANCE_CLOSURES = {}
do
    local text = readFile(scripts .. "palforge/core/event.lua")
    if text then
        local seen = {}
        for name in text:gmatch("inst%.([%w_]+)%s*=%s*function") do
            if not seen[name] then seen[name] = true; INSTANCE_CLOSURES[#INSTANCE_CLOSURES + 1] = name end
        end
        table.sort(INSTANCE_CLOSURES)
    end
end

--=============================================================================
-- RUNTIME PROBE — the module surface and the Handle method set, read off the live tables
-- exactly as a pack sees them. Parameter NAMES come from the debug info of the function
-- itself, so a signature here is the one the function really has.
--=============================================================================

local function signature(fn, name, method)
    local ok, info = pcall(debug.getinfo, fn, "u")
    if not (ok and info) then return name .. "(...)" end
    local args, from = {}, method and 2 or 1   -- a method's first parameter is `self`
    for i = from, info.nparams do
        local _, pname = pcall(debug.getlocal, fn, i)
        args[#args + 1] = pname or ("arg" .. i)
    end
    if info.isvararg then args[#args + 1] = "..." end
    return name .. "(" .. table.concat(args, ", ") .. ")"
end

-- A handle to walk for its method set. Every domain hands one back from get(); Mesh.get
-- refuses an unknown id by design, so that one is probed with a throwaway definition.
local function probeHandle(name)
    local ok, h = pcall(function()
        if name == "Mesh" then return api.Mesh{ id = "_probe_mesh", model = "/probe" } end
        return api[name].get("_probe_" .. name:lower())
    end)
    return ok and h or nil
end

for _, d in ipairs(DOMAINS) do
    local mod = api[d.name]
    local mt  = getmetatable(mod)
    d.callable = (mt ~= nil and mt.__call ~= nil)
    d.hasClass = (type(mod.Class) == "table")

    d.functions = {}
    for _, k in ipairs(sortedKeys(mod)) do
        if type(mod[k]) == "function" then
            d.functions[#d.functions + 1] = { name = k, sig = signature(mod[k], d.name .. "." .. k, false) }
        end
    end

    local h = probeHandle(d.name)
    d.methods, d.hooks = {}, {}
    if h then
        local hmt = getmetatable(h) or {}
        for _, k in ipairs(sortedKeys(hmt)) do
            local v = hmt[k]
            if type(v) == "function" and k:sub(1, 2) ~= "__" then
                local rec = { name = k, sig = signature(v, ":" .. k, true) }
                if k:match("^on%u") then d.hooks[#d.hooks + 1] = rec else d.methods[#d.methods + 1] = rec end
            end
        end
    end

    d.classMethods = {}
    if d.hasClass then
        for _, k in ipairs(sortedKeys(mod.Class)) do
            if type(mod.Class[k]) == "function" and k:sub(1, 2) ~= "__" and not k:match("^on%u") then
                d.classMethods[#d.classMethods + 1] = signature(mod.Class[k], ":" .. k, true)
            end
        end
    end
end

--=============================================================================
-- SPECS, grouped onto their domain. The first segment of a spec name is its domain
-- ("Pal.Spec" / "Pal.Spec.Events" -> Pal); a name with no prefix is a shared shape.
--=============================================================================

local byDomain, shared = {}, {}
for _, d in ipairs(DOMAINS) do byDomain[d.name] = {} end
for _, spec in ipairs(SPECS) do
    local owner = spec.name:match("^([^.]+)%.")
    if owner and byDomain[owner] then
        table.insert(byDomain[owner], spec)
    else
        shared[#shared + 1] = spec
    end
end

-- Two specs declared with the same field names are near-certainly one shape re-declared
-- (schema.derive, or the same four material fields per domain): emit the LATER one as a
-- DIFF against the earlier instead of a second full table. Declaration order is the right
-- tie-break because schema.derive can only name a base that already exists, so the earlier
-- spec is always the original. Nothing is dropped — the diff names every field that really
-- differs, and "identical" is stated when none does.
local FIELD_KEYS = { "type", "required", "default", "values", "arrayOf", "mapOf", "doc", "sig" }
local declIndex = {}
for i, s in ipairs(SPECS) do declIndex[s.name] = i end
local function shapeKey(spec)
    local names = {}
    for _, f in ipairs(spec.fields) do names[#names + 1] = f.name end
    return table.concat(names, ",")
end
-- The earliest-declared spec with the same field list, or nil when this IS the earliest.
local function baseShapeOf(spec)
    for _, other in ipairs(SPECS) do
        if declIndex[other.name] >= declIndex[spec.name] then return nil end
        if shapeKey(other) == shapeKey(spec) then return other end
    end
    return nil
end
local function sameValue(a, b)
    if type(a) == "table" and type(b) == "table" then
        return table.concat(a, "\1") == table.concat(b, "\1")
    end
    return a == b
end
local function diffFields(spec, base)
    local out = {}
    for i, f in ipairs(spec.fields) do
        local g, changed = base.fields[i], {}
        for _, key in ipairs(FIELD_KEYS) do
            if not sameValue(f[key], g[key]) then changed[#changed + 1] = key end
        end
        if (f.of and f.of.name) ~= (g.of and g.of.name) then changed[#changed + 1] = "of" end
        if #changed > 0 then out[#out + 1] = { field = f, base = g, changed = changed } end
    end
    return out
end

--=============================================================================
-- VALIDATION — captured by really making the calls, so the message shapes are exact.
--=============================================================================

local function capture(fn, ...)
    local args = { ... }
    local ok, err = pcall(function() return fn(table.unpack(args)) end)
    if ok then return nil end
    -- assert() prefixes "file:line: "; schema's own errors are raised at level 0 and do not
    return (tostring(err):gsub("^[^%s]-:%d+:%s*", ""))
end

local PalSpec = schema.get("Pal.Spec")
local VALIDATION = {
    { "the argument is not a table", capture(function() return PalSpec:validate(7, "Pal") end) },
    { "a required field is missing", capture(api.Pal, {}) },
    { "an undeclared field (with a did-you-mean)", capture(api.Pal, { id = "x", nam = "Bob" }) },
    { "a field has the wrong type", capture(api.Pal, { id = 7 }) },
    { "a `check` rejects the value", capture(api.Pal, { id = "" }) },
    { "a value is outside the declared `values`", capture(api.Item, { id = "x", category = "junk" }) },
    { "a bad element in an `arrayOf`", capture(api.Pal, { id = "x", skills = { "Fire", 7 } }) },
    { "a bad value in a `mapOf` (inside a nested spec)",
      capture(api.Item, { id = "x", recipe = { materials = { Wood = "3" } } }) },
    { "a nested spec rejects one of its own fields",
      capture(api.Pal, { id = "x", mesh = { kind = "voxel", model = "/m" } }) },
    { "a non-string key", capture(api.Pal, { id = "x", [1] = "y" }) },
    { "a lookup with no id", capture(function() return api.Pal.get(nil) end) },
    { "`Mesh.get` on an undefined mesh", capture(function() return api.Mesh.get("nope") end) },
    { "a mesh defined without an id", capture(api.Mesh, { model = "/m" }) },
    { "`Audio.bgm` / `Audio.se` contradicted", capture(api.Audio.bgm, { id = "x", kind = "se" }) },
}

--=============================================================================
-- EMIT
--=============================================================================

local out = {}
local function w(line) out[#out + 1] = line or "" end

-- The GitHub anchor of a "### Spec.Name" heading.
local function anchor(name) return "#" .. name:lower():gsub("[^%w]", "") end

-- Every rule a field descriptor carries, as one dense cell.
local function rules(f)
    local bits = {}
    if f.required then bits[#bits + 1] = "**required**" end
    if f.default ~= nil and type(f.default) ~= "function" then bits[#bits + 1] = "= `" .. tostring(f.default) .. "`" end
    if type(f.default) == "function" then bits[#bits + 1] = "= (built per call)" end
    if f.values then
        local vs = {}
        for _, v in ipairs(f.values) do vs[#vs + 1] = "`" .. tostring(v) .. "`" end
        bits[#bits + 1] = "one of " .. table.concat(vs, " ")
    end
    if f.arrayOf then bits[#bits + 1] = "each element `" .. f.arrayOf .. "`" end
    if f.mapOf then bits[#bits + 1] = "values `" .. f.mapOf .. "`" end
    if f.of then bits[#bits + 1] = "shape [" .. f.of.name .. "](" .. anchor(f.of.name) .. ")" end
    if f.check then bits[#bits + 1] = "checked" end
    return table.concat(bits, ", ")
end

local function typeOf(f)
    return code(f.sig or f.type or "any")
end

-- The notes cell for one callable: what it DOES (the annotation's prose) and, after a "→",
-- what its return value MEANS (the ---@return note). Both matter and they are different
-- facts — half of this api answers a fail-soft `false`, and which false it is only the
-- return note says. The two share one budget so a row can never run away.
local function noteFor(ann, ret, cap)
    local summary = trim(ann and ann.summary or "")
    local note    = trim(ret and ret.note or "")
    if summary == "" then return sentence(note, cap) end
    if note == "" then return sentence(summary, cap) end
    local main = sentence(summary, cap - 80)
    return main .. " → " .. clip(note, 76)
end

-- Does this hook actually fire today? The answer is already in the doc string the spec
-- declares — a wired hook says LIVE, an unwired one says declarable — so it is read from
-- there rather than restated here.
local function firing(doc)
    doc = doc or ""
    if doc:match("^LIVE") then
        return doc:match("UNCONFIRMED") and "LIVE?" or "LIVE"
    end
    if doc:lower():match("declarable") then return "no" end
    return "manual"
end

local function fieldTable(spec)
    w("| field | type | rules | meaning |")
    w("|---|---|---|---|")
    for _, f in ipairs(spec.fields) do
        w(string.format("| `%s` | %s | %s | %s |", f.name, typeOf(f), cell(rules(f)), cell(f.doc)))
    end
    w()
end

local function eventTable(spec, domain)
    local docs = src[domain] and src[domain].docs or {}
    w("| hook | fires | signature | ctx | meaning |")
    w("|---|---|---|---|---|")
    for _, f in ipairs(spec.fields) do
        local ann = docs["handle:" .. f.name]
        w(string.format("| `%s` | %s | %s | %s | %s |", f.name, firing(f.doc),
            code(f.sig or "fun(self, ctx: table)"), cell(ann and ann.ctx or ""), cell(f.doc)))
    end
    w()
end

local function diffTable(spec, base)
    local d = diffFields(spec, base)
    if #d == 0 then
        w(string.format("Identical to [`%s`](%s) — same fields, same rules.",
            base.name, anchor(base.name)))
        w()
        return
    end
    w(string.format("Same fields as [`%s`](%s), with %d difference%s:",
        base.name, anchor(base.name), #d, (#d == 1) and "" or "s"))
    w()
    w("| field | changed | here | in `" .. base.name .. "` |")
    w("|---|---|---|---|")
    for _, entry in ipairs(d) do
        local here, there = {}, {}
        for _, key in ipairs(entry.changed) do
            local a, b = entry.field[key], entry.base[key]
            if key == "values" then a, b = table.concat(a or {}, " "), table.concat(b or {}, " ") end
            -- a value (default / type / enum) reads as a value; a doc string reads as prose
            local function show(v)
                if v == nil then return "—" end
                if key == "doc" or key == "sig" then return tostring(v) end
                return code(tostring(v))
            end
            here[#here + 1] = show(a); there[#there + 1] = show(b)
        end
        w(string.format("| `%s` | %s | %s | %s |", entry.field.name,
            cell(table.concat(entry.changed, ", ")), cell(table.concat(here, " · ")),
            cell(table.concat(there, " · "))))
    end
    w()
end

-- ---- banner + preamble ----------------------------------------------------

w("<!-- GENERATED FILE — do not edit by hand.")
w("     Regenerate:  cd <PalForge> && " .. CMD)
w("     Generator:   tools/gen-skill-reference.lua")
w("     Truth:       the schema declarations in Scripts/palforge/api/*.lua, read back")
w("                  through the core/schema registry at runtime. -->")
w()
w("# PalForge API reference")
w()
w("Everything a pack can call, generated from the live schema registry. PalForge is a Lua")
w("modding framework for Palworld running under UE4SS.")
w()
w("```lua")
w("local api = require(\"palforge.api\")   -- also installs the globals below, mod-local")
w("```")
w()
w("Every domain has the SAME three-member shape — **the module IS the constructor**:")
w()
w("```lua")
w("local h = Pal{ id = \"NewPal\", name = \"New Pal\",     -- define + register -> Handle")
w("               mesh = Mesh{ id = \"np:body\", model = \"/Game/.../SK_X\" },   -- nest a definition")
w("               events = { onDamaged = function(self, ctx) end } }")
w("Pal.get(\"ChickenPal\"):spawn(Player.coordinate())    -- act on one, defined here or not")
w("Pal.get_all()                                       -- every registered definition")
w("```")
w()
w("* `X{ ... }` is Lua's call-with-a-table sugar for `X({ ... })` — the braces are the")
w("  argument list. Every domain needs an `id` (`Mesh` enforces it in the constructor")
w("  rather than in the spec, so only an INLINE `mesh = { … }` may omit one).")
w("* **Define once, act many times.** `X{ ... }` registers; `X.get(id)` just hands you a")
w("  handle. Inside an event handler use `get` — re-defining on every event re-registers.")
w("* A nested definition is passed as itself: `mesh = Mesh{ ... }` and the inline")
w("  `mesh = { model = ... }` validate identically.")
w("* Where a domain declares an `X.Spec.Events` shape, its handlers are grouped under")
w("  `events = { … }`. An event name that shape does not declare is a hard error at define")
w("  time, not a silent no-op.")
do
    -- state the Class exception rather than a claim that has to be maintained by hand
    local without = {}
    for _, d in ipairs(DOMAINS) do
        if not d.hasClass then without[#without + 1] = "`" .. d.name .. "`" end
    end
    w("* " .. ((#without > 0)
        and ("Every domain module except " .. table.concat(without, ", ") .. " also exposes")
        or "Every domain module also exposes")
      .. " `X.Class`, the base definition")
    w("  class (override detection / subclassing).")
end
w("* A domain's `X.Spec` shapes are PRIVATE — a domain is a thing you call, not a namespace")
w("  to browse. Read them at runtime with `schema.help(\"X.Spec\")` /")
w("  `schema.get(\"X.Spec\").fields`; this page is generated from exactly those.")
w()
w("**Legend — the `fires` column**, read from each hook's own doc string:")
w()
w("| value | means |")
w("|---|---|")
w("| `LIVE` | a confirmed native source emits it; write the handler and it runs |")
w("| `LIVE?` | wired, but never yet observed firing — keep the handler idempotent |")
w("| `no` | *declarable*: the name is accepted, nothing emits it. Your handler never runs |")
w("| `manual` | the doc string carries neither marker — the domain has no native source at"
  .. " all, so the handler runs only when you call it (that domain's own action methods, or"
  .. " the `:onX()` forwarder) |")
w()
w("The `type` column shows the declared LuaLS signature when a field has one, else its")
w("runtime type. In `rules`, `checked` means a predicate runs on the value (on every `id`:")
w("must be a non-empty string). In `notes`, what follows a `→` is what the RETURN VALUE")
w("means — most of this api is fail-soft, so a `false` is information, not an exception.")
w("`—` is \"nothing to say\", never \"unknown\".")
w()

-- ---- domains at a glance --------------------------------------------------

w("## Domains")
w()
w("| domain | define | look up | handle | hooks (live/total) | what it is |")
w("|---|---|---|---|---|---|")
for _, d in ipairs(DOMAINS) do
    local spec, events
    for _, s in ipairs(byDomain[d.name]) do
        if s.name == d.name .. ".Spec" then spec = s end
        if s.name == d.name .. ".Spec.Events" then events = s end
    end
    local live, total = 0, 0
    if events then
        for _, f in ipairs(events.fields) do
            total = total + 1
            if firing(f.doc):match("^LIVE") then live = live + 1 end
        end
    end
    -- the lookup column is whatever the module really exposes: get / get_all first (every
    -- domain but Player has them), then that domain's own extras.
    local named, extras = {}, {}
    for _, fn in ipairs(d.functions) do
        if fn.name == "get" or fn.name == "get_all" then named[fn.name] = fn.sig:gsub("^" .. d.name, "")
        else extras[#extras + 1] = "`" .. fn.sig:gsub("^" .. d.name, "") .. "`" end
    end
    local lookup = {}
    for _, k in ipairs({ "get", "get_all" }) do
        if named[k] then lookup[#lookup + 1] = "`" .. named[k] .. "`" end
    end
    for _, e in ipairs(extras) do lookup[#lookup + 1] = e end
    w(string.format("| [%s](#%s) | %s | %s | %s | %s | %s |",
        d.name, d.name:lower(),
        d.callable and ("`" .. d.name .. "{ … }`") or "—",
        (#lookup > 0) and table.concat(lookup, " ") or "—",
        (#d.methods > 0) and (#d.methods .. " methods") or "—",
        (total > 0) and string.format("%d/%d", live, total) or "—",
        cell(clip(src[d.name].blurb, 92))))
end
w()

-- ---- validation -----------------------------------------------------------

w("## Validation — exactly what is rejected, and the message you get")
w()
w("Every definition call is validated against its spec before anything is registered: a")
w("problem is a **hard error** (level 0, so the text below is the whole message) and the")
w("call never half-succeeds. Messages are captured from real failing calls.")
w()
w("| rejected | message |")
w("|---|---|")
for _, row in ipairs(VALIDATION) do
    w(string.format("| %s | `%s` |", cell(row[1]), cell(row[2] or "(no error)")))
end
w()
w("The context prefix is the call you made (`Pal`, `Item`, …), and a nested spec extends")
w("it — `Pal: field \"mesh\" (Mesh.Spec): …` — so the message always names the shape to go")
w("and read. Array and map elements extend the field name itself (`skills[2]`,")
w("`materials.Wood`). Validation returns a fresh plain COPY with defaults filled; the table")
w("you passed is never mutated.")
w()

-- ---- one section per domain ----------------------------------------------

for _, d in ipairs(DOMAINS) do
    local entry = src[d.name]
    local specs = byDomain[d.name]
    local main, events, nested = nil, nil, {}
    for _, s in ipairs(specs) do
        if s.name == d.name .. ".Spec" then main = s
        elseif s.name == d.name .. ".Spec.Events" then events = s
        else nested[#nested + 1] = s end
    end

    w("## " .. d.name)
    w()
    w(entry.blurb)
    w()

    -- module surface
    w("| call | returns | notes |")
    w("|---|---|---|")
    if d.callable then
        local ann = entry.docs["mod:__call"]
        w(string.format("| `%s{ … }` | `%s.Handle` | %s |", d.name, d.name,
            cell(sentence(ann and ann.summary or "", 130))))
    end
    for _, fn in ipairs(d.functions) do
        local ann = entry.docs["mod:" .. fn.name]
        local ret = ann and ann.returns[1]
        w(string.format("| %s | %s | %s |", code(fn.sig), (ret and code(ret.type) or "—"),
            cell(noteFor(ann, ret, 150))))
    end
    w()

    if main then
        w("### " .. main.name)
        w()
        fieldTable(main)
    end

    if events then
        w("### " .. events.name)
        w()
        w("Declared as `events = { onX = function(self, …) end }` inside `" .. d.name .. "{ … }`.")
        w()
        eventTable(events, d.name)
    end

    for _, s in ipairs(nested) do
        w("### " .. s.name)
        w()
        local base = baseShapeOf(s)
        if base then diffTable(s, base) else fieldTable(s) end
    end

    -- handle
    if #d.methods > 0 or #d.hooks > 0 then
        w("### " .. d.name .. ".Handle")
        w()
        w("| method | returns | notes |")
        w("|---|---|---|")
        for _, m in ipairs(d.methods) do
            local ann = entry.docs["handle:" .. m.name]
            local ret = ann and ann.returns[1]
            w(string.format("| %s | %s | %s |", code(m.sig), (ret and code(ret.type) or "—"),
                cell(noteFor(ann, ret, 215))))
        end
        w()
        if #d.hooks > 0 then
            local names = {}
            for _, h in ipairs(d.hooks) do names[#names + 1] = "`" .. h.sig .. "`" end
            w("Event forwarders (same names as the hooks above; they call the definition's")
            w("handler NOW — a test seam, not the real dispatch): " .. table.concat(names, " ") .. ".")
            w()
        end
    end

    if #d.classMethods > 0 then
        local names = {}
        for _, m in ipairs(d.classMethods) do names[#names + 1] = "`" .. m .. "`" end
        w("`" .. d.name .. ".Class` methods (what `self` resolves inside a handler that gets a")
        w("definition or an instance): " .. table.concat(names, " ") .. ".")
        w()
    end

    -- documented ---@class shapes that carry real fields (Building.Instance, …)
    for _, c in ipairs(entry.classes) do
        if #c.fields >= 2 then
            w("### " .. c.name)
            w()
            w("| field | type | meaning |")
            w("|---|---|---|")
            for _, f in ipairs(c.fields) do
                w(string.format("| `%s` | `%s` | %s |", f.name, f.type, cell(f.note)))
            end
            w()
            if c.name == d.name .. ".Instance" and #INSTANCE_CLOSURES > 0 then
                local names = {}
                for _, n in ipairs(INSTANCE_CLOSURES) do names[#names + 1] = "`:" .. n .. "()`" end
                w("Plus the per-instance closures core/event installs: " ..
                  table.concat(names, " ") .. ".")
                w()
            end
        end
    end
end

-- ---- shared shapes --------------------------------------------------------

if #shared > 0 then
    w("## Shared shapes")
    w()
    w("Declared without a domain prefix: they belong to no single domain.")
    w()
    for _, s in ipairs(shared) do
        w("### " .. s.name)
        w()
        fieldTable(s)
    end
end

--=============================================================================
-- write
--=============================================================================

local text = table.concat(out, "\n") .. "\n"
local dir = OUT:match("^(.*)/[^/]+$")
if dir then os.execute("mkdir -p \"" .. dir .. "\" 2>/dev/null") end
local f = assert(io.open(OUT, "wb"), "cannot write " .. OUT)
f:write(text)
f:close()

local hooks = 0
for _, s in ipairs(SPECS) do
    if s.name:match("%.Events$") then hooks = hooks + #s.fields end
end
print(string.format("wrote %s (%d domains, %d specs, %d hooks, %d lines, %.1f KB)",
    OUT, #DOMAINS, #SPECS, hooks, #out, #text / 1024))
