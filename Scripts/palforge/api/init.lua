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
-- The ---@type annotations make LuaLS auto-complete the bare globals.
-- (UE4SS gives each Lua mod its own state, so these globals are mod-local — no clash
--  with the game or other mods.)

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
return {
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
