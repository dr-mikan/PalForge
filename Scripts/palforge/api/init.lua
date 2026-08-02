-- palforge/api/init.lua — THE public API surface, in one place.
--
--   local api = require("palforge.api")      -- namespaced:  api.Pal, api.Item, ...
--   -- requiring it ALSO installs the globals below, so packs can just write:
--   Pal.get("ChickenPal"):spawn(Player.coordinate())
--   Item.get("Wood"):give(10)
--
-- Every module here has the SAME, THREE-MEMBER shape:
--   X{ id = ..., name = ..., description = ..., events = { onFoo = fn } } -> Handle
--   X.get(id) -> Handle          X.get_all() -> Handle[]
-- The module IS the constructor — calling it defines and registers. The Handle it returns
-- carries that domain's ACTIONS (:spawn, :give, :play, :mount, :apply, ...) plus forwarders
-- for its events. Each module's header states exactly which of its events are LIVE (a
-- confirmed native hook emits them) and which are declarable-but-not-yet-fired.
--
-- A DEFINITION READS AS ONE PIECE OF DATA. Everything is named, a nested definition is
-- passed as itself, and events are a plain map of handlers:
--
--   local pal = api.Pal{
--       id          = "test_pal",
--       name        = "Test Pal",
--       description = "A test pal for smoke testing.",
--       mesh        = api.Mesh{
--           id      = "test_pal_mesh",
--           model   = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal",
--           texture = "palforge/test/textures/test_pal.png",
--       },
--       events = {
--           onSpawned = function(pal, ctx)
--               api.Audio.get("AKE_BGM_Title"):play()
--           end,
--       },
--   }
--   pal:spawn(api.Player.coordinate())
--
-- `X{ ... }` is Lua's call-with-a-table sugar for `X({ ... })` — the braces ARE the
-- argument list, which is as close to named arguments as the language gets.
--
-- DEFINE ONCE, ACT MANY TIMES. `X{ ... }` registers a definition; `X.get(id)` just hands
-- you a handle for one. A handler runs on every event, so reach for `get` inside one —
-- `Audio.get("AKE_BGM_Title"):play()` above is a play, where `Audio.bgm{ ... }:play()`
-- would re-declare and re-register the sound on every single spawn.
--
-- KNOWING WHAT TO PASS. Every domain's shape is declared as data (core/schema) and
-- enforced on every call. The declarations are PRIVATE to their module — a domain is a
-- thing you call, not a namespace to browse — but they stay readable through the registry:
--   schema.help("Pal.Spec")          -- every field, its type, default and meaning
--   schema.get("Pal.Spec").fields    -- the same as a table, for tooling
-- `id` is required everywhere, and an undeclared field is a hard error at define time
-- with a did-you-mean — a typo can never be silently ignored. In the editor, the same
-- information comes from Scripts/palforge/types.lua, which is GENERATED from those specs
-- (tools/gen-types.lua), so the completion can never drift from what a call accepts.
--
-- WHO IS DEFINING (F-6). A definition call is a plain Lua call and carries no evidence of
-- which mod made it, so the framework cannot attribute content — and cannot tell a pack
-- overwriting its own id from a pack overwriting SOMEONE ELSE'S — unless the pack says so.
-- `api.pack(packId)` is where it says so:
--
--   local api  = PalForge.pack("mypack")   -- or require("palforge.api").pack("mypack")
--   local Item = api.Item
--   Item{ id = "mypack:Potion" }           -- registered with pack = "mypack"
--
-- It returns the SAME nine members; the eight constructors are wrapped so the define runs
-- inside object_manager.withPack — and so are the two extra define routes a domain adds as
-- named functions (Audio.bgm / Audio.se), because those register too. Everything else
-- (X.get, X.get_all, Player) passes through untouched. Using it is optional and nothing
-- changes for a pack that does not — an unattributed definition registers with pack = nil,
-- exactly as before.
--
-- The ---@type annotations make LuaLS auto-complete the bare globals.
-- (UE4SS gives each Lua mod its own state, so these globals are mod-local — no clash
--  with the game or other mods.)

local om       = require("palforge.core.object_manager")

local Pal      = require("palforge.api.pal")
local Item     = require("palforge.api.item")
local Building = require("palforge.api.building")
local Skill    = require("palforge.api.skill")
local Effect   = require("palforge.api.effect")
local Audio    = require("palforge.api.audio")
local Mesh     = require("palforge.api.mesh")
local UI       = require("palforge.api.ui")
local Player   = require("palforge.api.player")

-- Install the public globals (editor completion is driven by the ---@type below).
---@type palforge.pal
_G.Pal = Pal
---@type palforge.item
_G.Item = Item
---@type palforge.building
_G.Building = Building
---@type palforge.skill
_G.Skill = Skill
---@type palforge.effect
_G.Effect = Effect
---@type palforge.audio
_G.Audio = Audio
---@type palforge.mesh
_G.Mesh = Mesh
---@type palforge.ui
_G.UI = UI
---@type palforge.player
_G.Player = Player

---@class palforge.api
---@field Pal      palforge.pal
---@field Item     palforge.item
---@field Building palforge.building
---@field Skill    palforge.skill
---@field Effect   palforge.effect
---@field Audio    palforge.audio
---@field Mesh     palforge.mesh
---@field UI       palforge.ui
---@field Player   palforge.player
local api = {
    Pal      = Pal,
    Item     = Item,
    Building = Building,
    Skill    = Skill,
    Effect   = Effect,
    Audio    = Audio,
    Mesh     = Mesh,
    UI       = UI,
    Player   = Player,
}

-- ---- the scoped surface: api.pack(packId) ----

-- The eight callable domains. Player is the ninth member and is deliberately NOT wrapped:
-- it defines nothing, it acts on the local player, so there is no registration for a pack
-- id to attribute.
local CONSTRUCTORS = { "Pal", "Item", "Building", "Skill", "Effect", "Audio", "Mesh", "UI" }

-- MEMBERS THAT ARE ALSO CONSTRUCTORS. A domain's define call is normally the module itself
-- (`Item{ ... }`, reached through __call), but Audio has two more: Audio.bgm and Audio.se are
-- plain functions on the module that pin `kind` and then run the SAME define — registration
-- included. They are reached through __index, not __call, so a wrapper that only wraps __call
-- hands the raw function back and `PalForge.pack("mypack").Audio.bgm{ ... }` registers with
-- pack = nil: the one definition route the scoped surface did not cover, and the failure was
-- silent (the sound worked, only the attribution was lost). Named here rather than inferred,
-- because "every function member" would also wrap the accessors, and X.get / X.get_all are
-- specified to pass through unchanged.
local EXTRA_CONSTRUCTORS = {
    Audio = { "bgm", "se" },
}

-- A pack id is the first half of every id the pack will register, so it has to satisfy the
-- same rule `object_manager.resolve` applies to that half. Checked here, loudly, at the top
-- of a pack file, rather than turning into an unresolvable id per definition later.
local PACK_ID = "^[%w_]+$"

-- One scoped table per pack id, so `api.pack("x").Item == api.pack("x").Item` and a pack
-- that calls it in ten files builds eight wrappers, not eighty.
local scopedApis = {}

-- Wrap a domain module: calling it defines INSIDE withPack, so object_manager.register
-- attributes the entry to this pack; every other member (get, get_all, and whatever a
-- domain adds — Audio.bgm, UI's builders) reaches the real module through __index and is
-- unchanged. Varargs are forwarded whole, so the optional second argument of C2
-- (`X(spec, { register = false })`) keeps working through the scoped surface.
-- `extras` names the module's other constructors (see EXTRA_CONSTRUCTORS). Each is wrapped
-- ONCE, at scope-build time, so `p.Audio.bgm == p.Audio.bgm` the way `p.Audio == p.Audio`
-- already held, and so a per-call closure is not minted inside __index.
local function scopeModule(mod, packId, extras)
    local wrapped = nil
    for _, name in ipairs(extras or {}) do
        local fn = mod[name]
        if type(fn) == "function" then
            wrapped = wrapped or {}
            wrapped[name] = function(...) return om.withPack(packId, fn, ...) end
        end
    end
    return setmetatable({}, {
        __call  = function(_, ...) return om.withPack(packId, mod, ...) end,
        __index = wrapped and function(_, k)
            local w = wrapped[k]
            if w ~= nil then return w end
            return mod[k]
        end or mod,
        -- The wrapper is a view, not a copy: writing into it would silently diverge from
        -- the module every other caller sees.
        __newindex = function(_, k)
            error(string.format("PalForge: api.pack(%q) is a read-only view of the api; "
                .. "cannot assign %q on it", packId, tostring(k)), 0)
        end,
    })
end

-- The scoped api. `opts.depends` / `opts.recommends` (arrays of pack ids, or set-like
-- tables) are recorded with object_manager so checkImport can answer "may this pack
-- mention that id?" without every call site threading the set through.
---@param packId string
---@param opts? { depends?: string[], recommends?: string[] }
---@return palforge.api
function api.pack(packId, opts)
    if type(packId) ~= "string" or not packId:match(PACK_ID) then
        error(string.format("PalForge: api.pack(%s): a pack id must be letters, digits or _ "
            .. "(it becomes the \"packid\" half of every \"packid:name\" this pack defines)",
            type(packId) == "string" and string.format("%q", packId) or type(packId)), 0)
    end
    if opts ~= nil then
        if type(opts) ~= "table" then
            error(string.format("PalForge: api.pack(%q): the second argument must be a table "
                .. "of { depends = { ... }, recommends = { ... } }", packId), 0)
        end
        -- Iterating the FIELD NAMES, not { opts.depends, opts.recommends }: a pack that
        -- declares only `recommends` would leave a hole at index 1 of that array and ipairs
        -- would stop before reaching it.
        local deps = {}
        for _, field in ipairs({ "depends", "recommends" }) do
            local list = opts[field]
            if type(list) == "table" then
                for k, v in pairs(list) do
                    if type(v) == "string" then deps[v] = true elseif v then deps[k] = true end
                end
            end
        end
        if next(deps) then om.declareDeps(packId, deps) end
    end

    local scoped = scopedApis[packId]
    if not scoped then
        -- `pack` rides along so the scoped table is a drop-in for the unscoped one: a pack
        -- that wrote `local api = PalForge.pack("mypack")` can still reach api.pack.
        scoped = { Player = Player, pack = api.pack }
        for _, name in ipairs(CONSTRUCTORS) do
            scoped[name] = scopeModule(api[name], packId, EXTRA_CONSTRUCTORS[name])
        end
        scopedApis[packId] = scoped
    end
    return scoped
end

return api
