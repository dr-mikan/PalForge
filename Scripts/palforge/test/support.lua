-- palforge/test/support.lua — the shared helpers every case file uses.
--
-- These tests run INSIDE the game, so two things matter that a headless suite never
-- has to think about:
--
--   * Most of the api needs a loaded world. A case that touches the world calls
--     support.needWorld(t) first, which SKIPS the test (not fails it) when there is no
--     player pawn — so the same suite is green at the title screen and meaningful in a
--     save. Nothing here throws on a missing engine global.
--   * A run must not leave content behind. Ids come from support.id(), which mixes in a
--     per-run counter, so running the suite ten times never collides with itself.
local log = require("palforge.utils.log").scope("test")

local M = {}

--=============================================================================
-- reporting
--=============================================================================

-- Put a line on the player's screen as well as in UE4SS.log — an in-game test you have
-- to alt-tab to read is an in-game test you stop running. Silent no-op with no world.
function M.announce(msg)
    pcall(function()
        local util   = StaticFindObject("/Script/Pal.Default__PalUtility")
        local player = FindFirstOf("PalPlayerCharacter")
        if util and util:IsValid() and player and player:IsValid() then
            util:SendSystemAnnounce(player, "[PalForge] " .. tostring(msg))
        end
    end)
end

function M.log(msg) log.info(msg) end

--=============================================================================
-- world access
--=============================================================================

-- The local player pawn, or nil. Never throws, even with no engine at all.
function M.player()
    local pawn
    pcall(function() pawn = FindFirstOf("PalPlayerCharacter") end)
    if pawn and pawn.IsValid and pawn:IsValid() then return pawn end
    return nil
end

-- Is there a world to act on? core/event's gate is the authority once it is running;
-- the pawn check covers the moment before the ready watch has settled.
function M.worldReady()
    local ok, ready = pcall(function() return require("palforge.core.event").isWorldReady() end)
    if ok and ready then return true end
    return M.player() ~= nil
end

-- Skip the current test unless a world is loaded. Returns the player pawn so a case can
-- write `local pawn = support.needWorld(t)`.
function M.needWorld(t)
    local pawn = M.player()
    if not pawn then t:skip("no world loaded") end
    return pawn
end

-- Skip unless the named engine global exists (LoopAsync, FindAllOf, ...). Some sessions
-- and some hosts do not expose all of them.
function M.needGlobal(t, name)
    if type(_G[name]) ~= "function" then t:skip(name .. " unavailable this session") end
end

-- An actor's world location as { x, y, z }, or nil.
function M.location(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then return nil end
    local ok, loc = pcall(function()
        return (actor.K2_GetActorLocation and actor:K2_GetActorLocation()) or actor:GetActorLocation()
    end)
    if ok and loc then return { x = loc.X, y = loc.Y, z = loc.Z } end
    return nil
end

-- A point `dist` cm in front of the player and `up` cm above it — where a spawn test puts
-- things so they are visibly not on top of you. nil with no world.
function M.inFront(dist, up)
    local pawn = M.player()
    if not pawn then return nil end
    local here = M.location(pawn)
    if not here then return nil end

    local fwd; pcall(function() fwd = pawn:GetActorForwardVector() end)
    local fx, fy = (fwd and fwd.X) or 1.0, (fwd and fwd.Y) or 0.0
    local mag = math.sqrt(fx * fx + fy * fy)
    if mag < 0.01 then fx, fy, mag = 1.0, 0.0, 1.0 end

    return { x = here.x + (fx / mag) * (dist or 600.0),
             y = here.y + (fy / mag) * (dist or 600.0),
             z = here.z + (up or 50.0) }
end

-- The PalCharacter closest to a coordinate, with its distance: { actor, pos, dist, count }.
-- Used to prove a spawn really landed where it was asked to. nil when nothing is findable.
function M.nearestPal(coord)
    local ok, all = pcall(FindAllOf, "PalCharacter")
    if not (ok and type(all) == "table") then return nil end

    local best, bestDist, count = nil, nil, 0
    for _, actor in ipairs(all) do
        local pos = M.location(actor)
        if pos then
            count = count + 1
            local dx, dy, dz = pos.x - coord.x, pos.y - coord.y, pos.z - coord.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if not bestDist or d < bestDist then best, bestDist = { actor = actor, pos = pos }, d end
        end
    end
    if not best then return nil end
    best.dist, best.count = bestDist, count
    return best
end

-- A live PalCharacter that is NOT the player: the nearest actual pal, or nil when there is
-- none nearby. Some capabilities only make sense on a pal — equipped moves are the clear case,
-- since a player has none and the first live run showed the player pawn carrying zero — so a
-- test that needs one must be able to say so and skip instead of drawing a conclusion from the
-- wrong kind of character.
function M.nearbyPal()
    local pawn = M.player()
    if not pawn then return nil end
    local here = M.location(pawn)
    if not here then return nil end

    local ok, all = pcall(FindAllOf, "PalCharacter")
    if not (ok and type(all) == "table") then return nil end

    local best, bestDist
    for _, actor in ipairs(all) do
        if actor ~= pawn then
            local pos = M.location(actor)
            if pos then
                local dx, dy, dz = pos.x - here.x, pos.y - here.y, pos.z - here.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if not bestDist or d < bestDist then best, bestDist = actor, d end
            end
        end
    end
    return best
end

--=============================================================================
-- test data
--=============================================================================

local counter = 0

-- A definition id that is unique across every run in this session, so re-running the
-- suite never re-registers over its own previous content.
--   support.id("pal")  -->  "palforge_test:pal_1"
function M.id(name)
    counter = counter + 1
    return string.format("palforge_test:%s_%d", name or "obj", counter)
end

-- The prefix every id from M.id() carries, for callers that want to sweep them up.
M.NAMESPACE = "palforge_test"

-- Is this id one of ours? Ids are namespaced, so nothing here can touch real content.
function M.isTestId(id)
    return type(id) == "string" and id:sub(1, #M.NAMESPACE + 1) == M.NAMESPACE .. ":"
end

-- Un-register everything this suite defined. Defining is permanent — object_manager has
-- no expiry — so without this, pressing the key ten times would leave ten runs' worth of
-- throwaway definitions in the live registry that core/event then walks on every scan.
-- Only ids in our own namespace are touched, so real content can never be swept.
---@return integer removed
function M.sweep()
    local om = require("palforge.core.object_manager")
    local removed = 0
    for _, otype in ipairs(om.TYPES) do
        for id in pairs(om.all(otype)) do          -- all() is a snapshot, safe to mutate under
            if M.isTestId(id) then
                pcall(function() om.register(otype, id, nil) end)
                removed = removed + 1
            end
        end
    end
    return removed
end

--=============================================================================
-- game ids the suites lean on
--
-- Real rows from the native catalogs, so a live check exercises content the game
-- actually has rather than something invented here.
--=============================================================================

M.GAME = {
    pal      = "ChickenPal",
    pal2     = "SheepBall",
    item     = "Wood",
    consume  = "Berries",
    building = "WorkBench",
    palbox   = "PalBoxV2",
    bgm      = "AKE_BGM_Title",
}

return M
