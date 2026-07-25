-- PalForge utils.player: quick access to the local player character and its world coordinate.
-- Handy for coordinate spawning — e.g. Pal:spawn{ at = player.location() } or offset from it.
local M = {}

-- The local player character (APalPlayerCharacter), or nil if not in a world yet.
function M.character()
    local p; pcall(function() p = FindFirstOf("PalPlayerCharacter") end)
    if p and p.IsValid and p:IsValid() then return p end
    return nil
end

-- The player's world coordinate as { x, y, z }, or nil if unavailable. Also indexable as
-- [1],[2],[3] and via .X/.Y/.Z so it drops straight into spawn helpers.
function M.location()
    local p = M.character()
    if not p then return nil end
    local ok, l = pcall(function()
        return (p.K2_GetActorLocation and p:K2_GetActorLocation()) or p:GetActorLocation()
    end)
    if not (ok and l) then return nil end
    return { x = l.X, y = l.Y, z = l.Z, X = l.X, Y = l.Y, Z = l.Z, l.X, l.Y, l.Z }
end

-- Convenience: the player's coordinate offset by (dx,dy,dz) — the common "spawn near me" case.
function M.locationOffset(dx, dy, dz)
    local o = M.location()
    if not o then return nil end
    local x, y, z = o.x + (dx or 0), o.y + (dy or 0), o.z + (dz or 0)
    return { x = x, y = y, z = z, X = x, Y = y, Z = z, x, y, z }
end

return M
