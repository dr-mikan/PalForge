-- PalForge core.player: quick access to the local player character and its world coordinate.
-- Handy for coordinate spawning — e.g. Pal:spawn{ at = player.location() } or offset from it.
-- (It says core.player rather than utils.player because that is where it lives and how every
-- caller asks for it — `require("palforge.core.player")`, from api/player.lua and
-- test/cases/player.lua. The old name in this line was the one thing here that was wrong.)
--
-- READ-ONLY, AND NOTHING HERE PASSES AN ARGUMENT TO THE GAME. The one UFunction called is
-- K2_GetActorLocation, which takes NO parameters — and a parameter list is the only thing that
-- can fault inside UE4SS's marshalling (core/signature.lua's header has the full account). That
-- is why this one is called directly rather than through core.signature: there is no declaration
-- to check, because there are no arguments to get wrong.
-- nil always means UNKNOWN (no world yet, no pawn), never a zero coordinate — a caller that
-- treats nil as (0,0,0) would place content at the world origin.
--
-- Liveness is core.uobject.live throughout — the framework's one answer to that question,
-- pcall-guarded, so a stale handle that throws on the IsValid call itself reads as "not live"
-- instead of escaping into the caller.
local uo = require("palforge.core.uobject")

local M = {}

-- The local player character (APalPlayerCharacter), or nil if not in a world yet.
function M.character()
    local p; pcall(function() p = FindFirstOf("PalPlayerCharacter") end)
    if uo.live(p) then return p end
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
