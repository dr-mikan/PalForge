-- PalForge dev tool: generate Scripts/palforge/types.lua from the api specs.
--
-- Every api module declares its shape as data (see core/schema.lua), so the LuaLS type
-- definitions can be DERIVED from those declarations instead of hand-maintained beside
-- them — one source of truth, and no chance of the annotations drifting from what
-- a definition call actually accepts.
--
-- Run it from the repo root with a plain Lua (no game needed):
--   lua5.4 tools/gen-types.lua
--
-- It writes Scripts/palforge/types.lua. Re-run it whenever a spec changes; the file is
-- annotations only, so nothing requires it at runtime — LuaLS just has to see it in the
-- workspace for `Pal{ ... }` to complete and for "go to definition" to land on the
-- field list.

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

-- The api modules do not publish their specs — a domain is a thing you CALL, not a
-- namespace to browse — so requiring them is what puts their shapes into the schema
-- registry, and the registry is what this walks. Requiring the api as a whole keeps the
-- module list in ONE place (api/init.lua) instead of a second copy that has to be kept
-- in step with it.
require("palforge.api")

--=============================================================================
-- schema field -> LuaLS type
--=============================================================================

-- The alias name a field with an enumerated `values` list gets, e.g. Skill.Spec.Kind.
local function aliasName(specName, field)
    return specName .. "." .. field.name:sub(1, 1):upper() .. field.name:sub(2)
end

local function luaType(field, specName)
    -- a nested shape can be written inline OR passed as the handle a definition returned
    -- (core/schema unwraps it through `__spec`), so the field accepts either. The spec
    -- names its own handle, so this cannot disagree with what validation accepts.
    if field.of then
        return field.of.name .. (field.of.handle and ("|" .. field.of.handle) or "")
    end
    if field.values then return aliasName(specName, field) end
    if field.sig then return field.sig end
    if field.arrayOf then return field.arrayOf .. "[]" end
    if field.mapOf then return "table<string, " .. field.mapOf .. ">" end
    if not field.type then return "any" end
    return field.type
end

-- Which section a spec belongs in: the first segment of its name, so "Pal.Spec" and
-- "Pal.Spec.Events" both land under Pal and "Mesh.Spec" under Mesh — including when
-- another domain reuses it (api/pal's `mesh` field is Mesh.Spec, declared once). A
-- name with no domain prefix is a shape shared across domains, e.g. Coord.
local function sectionOf(spec)
    return spec.name:match("^([^.]+)%.") or "Common"
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
w("-- (LuaLS / lua-language-server) can complete the fields of every X{ ... } call,")
w("-- show each field's meaning, and jump from a spec name to its field list.")
w("--")
w("-- Every domain has the same shape — the module itself is the constructor:")
w("--   X{ id = ..., name = ..., description = ..., events = { onFoo = fn } } -> X.Handle")
w("--   X.get(id) -> X.Handle        X.get_all() -> X.Handle[]")
w("---@meta")
w()

-- One pass in declaration order — a nested shape is declared before the spec that
-- references it, and each module's shapes are contiguous, so grouping is just "start a
-- new section whenever the name's domain changes".
local section = nil
for _, spec in ipairs(schema.all()) do
    if sectionOf(spec) ~= section then
        section = sectionOf(spec)
        w("--=============================================================================")
        w("-- " .. section)
        w("--=============================================================================")
        w()
    end

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

--=============================================================================
-- the native content catalogs
--
-- Scripts/palforge/native/*.lua expose one NAMED FIELD per row the game declares —
-- `native.items.Arrow_Fire`, `native.pals.BlueSkyDragon` — and those fields are served by a
-- metatable __index (see native/_catalog.lua for why: 8261 eager definitions at mod load would
-- be absurd). An editor cannot see through a metatable, so without this pass the whole point of
-- the named fields — that they are DISCOVERABLE, instead of you having to know an id string —
-- would be true at runtime and invisible while typing.
--
-- So the fields are enumerated here, from the catalogs THEMSELVES rather than from a list kept
-- beside them: this requires each module and reads its CATALOG, its ALIASES and its own surface,
-- so a regenerated catalog regenerates its annotations and the two cannot drift. The naming rule
-- is not re-implemented either — native/_catalog.lua is asked.
--=============================================================================

local catalog = require("palforge.native._catalog")

-- Which native catalogs to emit, and the handle type each hands back. native/ui is deliberately
-- absent: it is a catalog of WIDGET CLASSES, not of game content, and has no CATALOG of row ids.
local NATIVE = {
    { module = "palforge.native.buildings", field = "buildings", handle = "Building.Handle" },
    { module = "palforge.native.items",     field = "items",     handle = "Item.Handle" },
    { module = "palforge.native.pals",      field = "pals",      handle = "Pal.Handle" },
    { module = "palforge.native.skills",    field = "skills",    handle = "Skill.Handle" },
    { module = "palforge.native.effects",   field = "effects",   handle = "Effect.Handle" },
    { module = "palforge.native.audio",     field = "audio",     handle = "Audio.Handle" },
}

-- Every id a catalog holds, whatever shape its CATALOG is (an array of ids, or a map keyed by
-- id — see native.audio).
local function idsOf(mod)
    local out = {}
    local c = rawget(mod, "CATALOG") or {}
    if #c > 0 then
        for _, id in ipairs(c) do out[#out + 1] = id end
    else
        for id in pairs(c) do out[#out + 1] = id end
    end
    return out
end

local nativeNames = 0
w("--=============================================================================")
w("-- native content catalogs")
w("--")
w("-- One named field per row the game declares. The fields are lazy at runtime (a metatable")
w("-- __index over the module's own get(id), see Scripts/palforge/native/_catalog.lua); these")
w("-- annotations are what makes them completable in an editor.")
w("--=============================================================================")
w()

for _, dom in ipairs(NATIVE) do
    local ok, mod = pcall(require, dom.module)
    if not ok or type(mod) ~= "table" then
        io.stderr:write(string.format("gen-types: skipping %s (%s)\n", dom.module, tostring(mod)))
    else
        local unnamed = rawget(mod, "UNNAMED") or {}
        local aliases = rawget(mod, "ALIASES") or {}

        -- (a) the module's OWN surface, read off the module rather than listed here, so a
        --     catalog that grows a helper gets it annotated without this file being touched.
        --     Curated handles (native.pals.Chicken) are tables carrying an .id — they are named
        --     fields too, just hand-written ones, so they are emitted with the handle type.
        local own = {}
        for key, v in pairs(mod) do
            if type(key) == "string" then
                local t = type(v)
                if t == "function" then
                    own[key] = (key == "get" or key == "bgm" or key == "se")
                        and ("fun(id: string): " .. dom.handle .. "?")
                        or  (key == "tableOf") and "fun(id: string): string?"
                        or  "function"
                elseif t == "table" and type(rawget(v, "id")) == "string" then
                    own[key] = dom.handle
                elseif t == "table" then
                    -- an id LIST (CATALOG, PASSIVE, PARTNER) vs a keyed table (ALIASES, TABLES)
                    own[key] = (#v > 0) and "string[]" or "table<string, string>"
                elseif t == "string" then
                    own[key] = "string"
                end
            end
        end

        -- (b) the lazy names: an id that is its own name (the naming rule's identity branch),
        --     plus every published alias, minus anything rule (3) or (4) refused.
        local lazy = {}
        for _, id in ipairs(idsOf(mod)) do
            if catalog.isName(id) and not unnamed[id] and not own[id] then lazy[#lazy + 1] = id end
        end
        for name in pairs(aliases) do
            if not own[name] then lazy[#lazy + 1] = name end
        end
        table.sort(lazy)

        local ownKeys = {}
        for key in pairs(own) do ownKeys[#ownKeys + 1] = key end
        table.sort(ownKeys)

        w("---@class palforge.native." .. dom.field)
        for _, key in ipairs(ownKeys) do
            w(string.format("---@field %s %s", key, own[key]))
        end
        for _, name in ipairs(lazy) do
            local id = aliases[name]
            w(string.format("---@field %s %s%s", name, dom.handle,
                id and string.format(" # alias for the id %q", id) or ""))
        end
        w()
        nativeNames = nativeNames + #lazy
    end
end

w("---@class palforge.native")
for _, dom in ipairs(NATIVE) do
    w(string.format("---@field %s palforge.native.%s", dom.field, dom.field))
end
w("---@field ui table")
w()

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
print(string.format("wrote %s (%d classes, %d lines, %d native catalog names)",
    path, classes, #out, nativeNames))
