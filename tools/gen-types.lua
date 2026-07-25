-- PalForge dev tool: generate Scripts/palforge/types.lua from the api specs.
--
-- Every api module declares its shape as data (see core/schema.lua), so the LuaLS type
-- definitions can be DERIVED from those declarations instead of hand-maintained beside
-- them — one source of truth, and no chance of the annotations drifting from what
-- define() actually accepts.
--
-- Run it from the repo root with a plain Lua (no game needed):
--   lua5.4 tools/gen-types.lua
--
-- It writes Scripts/palforge/types.lua. Re-run it whenever a spec changes; the file is
-- annotations only, so nothing requires it at runtime — LuaLS just has to see it in the
-- workspace for `Pal.define{ ... }` to complete and for "go to definition" to land on
-- the field list.

local root = (arg and arg[1]) or "."
if root:sub(-1) ~= "/" then root = root .. "/" end
local scripts = root .. "Scripts/"

--=============================================================================
-- Load the api modules with the UE4SS globals stubbed out. Requiring an api module
-- only builds tables, but the natives it pulls in expect these to exist.
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

-- domain name -> module, in the order they should appear in the output
local DOMAINS = {
    { "Pal",      "palforge.api.pal" },
    { "Item",     "palforge.api.item" },
    { "Building", "palforge.api.building" },
    { "Skill",    "palforge.api.skill" },
    { "Effect",   "palforge.api.effect" },
    { "Audio",    "palforge.api.audio" },
    { "UI",       "palforge.api.ui" },
}

--=============================================================================
-- schema field -> LuaLS type
--=============================================================================

-- The alias name a field with an enumerated `values` list gets, e.g. Skill.Spec.Kind.
local function aliasName(specName, field)
    return specName .. "." .. field.name:sub(1, 1):upper() .. field.name:sub(2)
end

local function luaType(field, specName)
    if field.of then return field.of.name end
    if field.values then return aliasName(specName, field) end
    if field.sig then return field.sig end
    if field.arrayOf then return field.arrayOf .. "[]" end
    if field.mapOf then return "table<string, " .. field.mapOf .. ">" end
    if not field.type then return "any" end
    return field.type
end

-- Collect every spec reachable from a domain module: the top-level Spec plus anything
-- hanging off it (Pal.Spec.Mesh, ...) and anything referenced through `of`.
local function collect(domainSpec, seen, order)
    if seen[domainSpec.name] then return end
    seen[domainSpec.name] = true
    -- nested-by-reference first, so a class is declared before it is used
    for _, f in ipairs(domainSpec.fields) do
        if f.of then collect(f.of, seen, order) end
    end
    order[#order + 1] = domainSpec
end

--=============================================================================
-- emit
--=============================================================================

local out = {}
local function w(line) out[#out + 1] = line or "" end

w("-- PalForge type definitions — GENERATED, do not edit.")
w("--")
w("-- Regenerate with:  lua5.4 tools/gen-types.lua")
w("-- Source of truth:  the schema declarations in Scripts/palforge/api/*.lua")
w("--")
w("-- Annotations only: nothing requires this file at runtime. It exists so an editor")
w("-- (LuaLS / lua-language-server) can complete the fields of every define{ ... } call,")
w("-- show each field's meaning, and jump from a spec name to its field list.")
w("--")
w("-- Every domain has the same shape:")
w("--   X.define{ id = ..., <metadata>, events = { onFoo = function(self, ctx) end } } -> X.Handle")
w("--   X.get(id) -> X.Handle        X.get_all() -> X.Handle[]")
w("---@meta")
w()

for _, entry in ipairs(DOMAINS) do
    local domain, modname = entry[1], entry[2]
    local mod = require(modname)
    local top = mod.Spec
    assert(schema.isSpec(top), modname .. " does not expose a Spec")

    local seen, order = {}, {}
    collect(top, seen, order)
    -- also pick up specs that hang off X.Spec but nothing references (e.g. Pal.Spec.Coord)
    for _, v in pairs(top) do
        if schema.isSpec(v) then collect(v, seen, order) end
    end
    table.sort(order, function(a, b)
        if (a == top) ~= (b == top) then return b == top end   -- the domain spec last
        return a.name < b.name
    end)

    w("--=============================================================================")
    w("-- " .. domain)
    w("--=============================================================================")
    w()

    for _, spec in ipairs(order) do
        -- aliases for enumerated fields, declared before the class that uses them
        for _, f in ipairs(spec.fields) do
            if f.values then
                local parts = {}
                for _, v in ipairs(f.values) do parts[#parts + 1] = string.format("%q", tostring(v)) end
                w("---@alias " .. aliasName(spec.name, f) .. " " .. table.concat(parts, "|"))
            end
        end

        w("---@class " .. spec.name)
        for _, f in ipairs(spec.fields) do
            local optional = f.required and "" or "?"
            local notes = {}
            if f.default ~= nil and type(f.default) ~= "function" then
                notes[#notes + 1] = "default " .. tostring(f.default)
            end
            local doc = f.doc or ""
            if #notes > 0 then
                doc = doc .. ((#doc > 0) and " " or "") .. "(" .. table.concat(notes, ", ") .. ")"
            end
            w(string.format("---@field %s%s %s%s", f.name, optional, luaType(f, spec.name),
                (#doc > 0) and (" # " .. doc) or ""))
        end
        w()
    end
end

--=============================================================================
-- write
--=============================================================================
local path = scripts .. "palforge/types.lua"
local f = assert(io.open(path, "wb"), "cannot write " .. path)
f:write(table.concat(out, "\n"))
f:close()

local classes = 0
for _, line in ipairs(out) do
    if line:find("^---@class") then classes = classes + 1 end
end
print(string.format("wrote %s (%d classes, %d lines)", path, classes, #out))
