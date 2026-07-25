-- palforge/api/player.lua — PUBLIC player API. Thin facade over utils/player.
local player = require("palforge.core.player")

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
