-- palforge/api/player.lua — PUBLIC player API. Thin facade over utils/player.
local player = require("palforge.core.player")
local schema = require("palforge.core.schema")

---A world coordinate — what this module produces and what Pal:spawn consumes. It belongs
---to no single domain, so it is named without a domain prefix; the type generator gives
---such shapes their own "Common" section. Declared for the type definitions and for
---schema.help("Coord"); nothing binds it.
schema.define("Coord", {
    { "x", type = "number", required = true, doc = "world X in centimetres" },
    { "y", type = "number", required = true, doc = "world Y in centimetres" },
    { "z", type = "number", required = true, doc = "world Z in centimetres" },
})

---@class palforge.player
local Player = {}

---The local player character, or nil if not in a world yet.
---@return any  # APalPlayerCharacter | nil
function Player.character() return player.character() end

---The player's world coordinate { x, y, z }, or nil if unavailable.
---@return Coord?
function Player.coordinate() return player.location() end

---The player's coordinate offset by (dx, dy, dz) — the common "near me" case.
---@param dx number
---@param dy number
---@param dz number
---@return Coord?
function Player.coordinateOffset(dx, dy, dz) return player.locationOffset(dx, dy, dz) end

return Player
