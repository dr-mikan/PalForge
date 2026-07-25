-- palforge/api/init.lua — THE public API surface, in one place.
--
--   local api = require("palforge.api")      -- namespaced:  api.Pal, api.Item, ...
--   -- requiring it ALSO installs the globals below, so packs can just write:
--   Pal.get("ChickenPal"):spawn(Player.coordinate())
--   Item.get("Wood"):give(10)
--
-- Every module here has the SAME shape:
--   X.define{ id = ..., <metadata>, events = { onFoo = function(self, ctx) end } } -> Handle
--   X.get(id) -> Handle          X.get_all() -> Handle[]
-- and the Handle carries that domain's ACTIONS (:spawn, :give, :play, :mount, :apply, ...)
-- plus forwarders for its events. Each module's header states exactly which of its events
-- are LIVE (a confirmed native hook emits them) and which are declarable-but-not-yet-fired.
--
-- KNOWING WHAT TO PASS. Every domain's spec is declared as data and is readable at
-- runtime, so you never have to guess:
--   Pal.Spec:help()          -- every field, its type, default and meaning
--   Pal.Spec.fields          -- the same as a table, for tooling
--   Pal.Spec.Mesh{ ... }     -- build (and validate) a nested value on its own
-- `id` is required everywhere, and an undeclared field is a hard error at define time
-- with a did-you-mean — a typo can never be silently ignored. In the editor, the same
-- information comes from Scripts/palforge/types.lua, which is GENERATED from those specs
-- (tools/gen-types.lua), so the completion can never drift from what define() accepts.
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
---@field UI       palforge.ui
---@field Player   palforge.player
return {
    Pal      = Pal,
    Item     = Item,
    Building = Building,
    Skill    = Skill,
    Effect   = Effect,
    Audio    = Audio,
    UI       = UI,
    Player   = Player,
}
