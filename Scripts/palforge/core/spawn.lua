-- PalForge utils.spawn: engine glue for putting content INTO the world. The actual native
-- calls live here (the api/impl split: api/*:spawn() declares the capability, this holds
-- the engine call), so base classes stay declaration-only.
--
-- Pal spawning goes through UPalCheatManager — the server-authoritative admin API enabled by
-- the CheatManagerEnabler mod; SpawnMonsterForPlayer is real-server verified (see
-- mods/__knowledges/palworld-ue4ss-functions.md). Fail-soft: a missing cheat manager is a
-- no-op that returns false, never an error.
local log = require("palforge.utils.log").scope("spawn")

local M = {}

-- Spawn an actor of UClass `cls` at FTransform `transform` via GameplayStatics' deferred
-- spawn. Location-CONTROLLED and SYNCHRONOUS: returns the spawned actor immediately (no tick
-- polling). `worldCtx` = any live UObject for world context (e.g. the player pawn); `owner`
-- optional. ⚠️ transform.Scale3D MUST be set — an empty FTransform zeroes scale to (0,0,0).
function M.actor(worldCtx, cls, transform, owner)
    if not (worldCtx and cls and type(transform) == "table") then return nil end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not (gs and gs:IsValid()) then log.warn("spawn.actor: no GameplayStatics"); return nil end
    owner = owner or worldCtx
    -- collision 2 = AdjustIfPossibleButAlwaysSpawn; scale method 0 = OverrideRootScale.
    -- Arg count/owner varies across UE builds — try conventions in order until one spawns.
    local attempts = {
        function() return gs:BeginDeferredActorSpawnFromClass(worldCtx, cls, transform, 2, owner, 0) end,
        function() return gs:BeginDeferredActorSpawnFromClass(worldCtx, cls, transform, 2, owner) end,
        function() return gs:BeginDeferredActorSpawnFromClass(worldCtx, cls, transform, 2) end,
        function() return gs:BeginDeferredActorSpawnFromClass(worldCtx, cls, transform) end,
    }
    local a
    for i, fn in ipairs(attempts) do
        local ok, r = pcall(fn)
        if ok and r and r:IsValid() then
            a = r; log.info("spawn.actor: convention " .. i .. " worked"); break
        end
    end
    if a and a:IsValid() then
        pcall(function() gs:FinishSpawningActor(a, transform, 0) end)
        if a:IsValid() then return a end
    end
    log.err("spawn.actor: all BeginDeferredActorSpawnFromClass conventions failed")
    return nil
end

-- The cheat manager singleton (admin API). nil if the enabler mod is absent this session.
local function cheatManager()
    local cm; pcall(function() cm = FindFirstOf("PalCheatManager") end)
    if cm and cm:IsValid() then return cm end
    pcall(function() cm = FindFirstOf("PalPlayerController").CheatManager end)
    if cm and cm:IsValid() then return cm end
    return nil
end

-- Spawn a WILD pal of game CharacterID `charId` at `level` INTO THE WORLD, near the player
-- (visible, un-owned). CharacterID is the game code id (e.g. "ChickenPal", "Kitsunebi",
-- "BlueSkyDragon") = a PalForge Pal's id. Returns true if the native call executed.
function M.pal(charId, level)
    if type(charId) ~= "string" or #charId == 0 then return false end
    level = tonumber(level) or 1
    local cm = cheatManager()
    if not cm then
        log.warn("spawn.pal: no PalCheatManager (CheatManagerEnabler mod missing this session?)")
        return false
    end
    local ok = pcall(function() cm:SpawnMonster(FName(charId), level) end)
    if ok then log.info(string.format("spawn.pal(world) %s (lv %d)", charId, level))
    else log.err("spawn.pal: SpawnMonster threw for " .. charId) end
    return ok
end

-- ---- coordinate placement (post-spawn relocation) ----
-- The native bridge's UPalCharacterManager::SpawnNewCharacter creates the pal NEAR THE PLAYER
-- and ignores the requested SpawnParameter.SpawnLocation (verified 2026-07-23). Palworld spawns
-- the pal's actor deferred (a few frames later), so we relocate the freshly-spawned actor to
-- the target once it materializes. Identity is by UObject address so only the pal we just added
-- is moved.

local function palActors()
    local ok, all = pcall(FindAllOf, "PalCharacter")
    if ok and type(all) == "table" then return all end
    return {}
end

local function actorId(a)
    local ok, id = pcall(function() return a:GetAddress() end)
    if ok and id then return id end
    ok, id = pcall(function() return a:GetFullName() end)
    return ok and id or nil
end

local function snapshotPals()
    local s = {}
    for _, a in ipairs(palActors()) do
        if a and a.IsValid and a:IsValid() then
            local id = actorId(a); if id then s[id] = true end
        end
    end
    return s
end

local function actorLoc(a)
    local ok, l = pcall(function()
        return (a.K2_GetActorLocation and a:K2_GetActorLocation()) or a:GetActorLocation()
    end)
    if ok and l then return l end
    return nil
end

local function teleportActor(a, x, y, z)
    local loc = { X = x, Y = y, Z = z }
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    -- Prefer K2_TeleportTo: it's the character-aware relocate (updates the movement component
    -- and resolves encroachment), so the pal keeps its AI/physics instead of freezing.
    local ok, r = pcall(function() return a:K2_TeleportTo(loc, rot) end)
    if ok and r ~= false then return true end
    if pcall(function() return a:K2_SetActorLocation(loc, false, {}, true) end) then return true end
    if pcall(function() a:SetActorLocation(loc) end) then return true end
    return false
end

-- Relocate ONLY our freshly-spawned pal to (x,y,z). The native spawn drops it right at the
-- player, so among pals absent from `before` we move the SINGLE one nearest the player's spawn
-- position (px,py,pz) — never a batch, so wild pals that streamed in meanwhile are not dragged
-- along (that was the "20 -> 40 floating pals" bug). Retries; the actor spawns deferred.
local function placeNewPal(before, px, py, pz, x, y, z, tries)
    tries = tries or 0
    local best, bd
    for _, a in ipairs(palActors()) do
        if a and a.IsValid and a:IsValid() then
            local id = actorId(a)
            if id and not before[id] then
                local l = actorLoc(a)
                if l then
                    local dx, dy, dz = l.X - px, l.Y - py, l.Z - pz
                    local d = dx * dx + dy * dy + dz * dz
                    if not bd or d < bd then bd, best = d, a end
                end
            end
        end
    end
    if best then
        teleportActor(best, x, y, z)
        log.info(string.format("spawn.palAt: placed new pal at (%.0f,%.0f,%.0f)", x, y, z))
        return
    end
    if tries < 6 and type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function" then
        LoopAsync(400, function()
            ExecuteInGameThread(function() pcall(placeNewPal, before, px, py, pz, x, y, z, tries + 1) end)
            return true
        end)
    else
        log.warn("spawn.palAt: no new pal actor appeared to place")
    end
end

-- Spawn a pal of game CharacterID `charId` at `level` at EXACT world coordinates (x,y,z).
-- Strategy: SpawnMonster (server-authoritative admin API) creates a FULLY FUNCTIONING wild pal
-- (moves, can be damaged/killed, correct level) near the player, then we relocate that one pal
-- to the target. This beats the C++ SpawnNewCharacter path, which yielded a static/invincible
-- pal. Returns true if the spawn executed. Fail-soft on a missing cheat manager.
function M.palAt(charId, level, x, y, z)
    if type(charId) ~= "string" or #charId == 0 then return false end
    level = tonumber(level) or 1
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then log.warn("spawn.palAt: needs numeric x,y,z"); return false end
    local cm = cheatManager()
    if not cm then
        log.warn("spawn.palAt: no PalCheatManager (CheatManagerEnabler mod missing this session?)")
        return false
    end
    -- Snapshot existing pals + the player position (SpawnMonster drops the pal near the player).
    local before = snapshotPals()
    local px, py, pz = 0, 0, 0
    local pl; pcall(function() pl = FindFirstOf("PalPlayerCharacter") end)
    if pl and pl.IsValid and pl:IsValid() then
        local l = actorLoc(pl)
        if l then px, py, pz = l.X, l.Y, l.Z end
    end
    local ok = pcall(function() cm:SpawnMonster(FName(charId), level) end)
    if not ok then
        log.err("spawn.palAt: SpawnMonster threw for " .. charId)
        return false
    end
    if type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function" then
        LoopAsync(400, function()
            ExecuteInGameThread(function() pcall(placeNewPal, before, px, py, pz, x, y, z, 0) end)
            return true
        end)
    end
    log.info(string.format("spawn.palAt %s (lv %d) @ (%.0f,%.0f,%.0f) via SpawnMonster+teleport",
        charId, level, x, y, z))
    return true
end

-- Summon `num` pals of `charId` at `level` OWNED BY the player (into party/box, not the
-- world in front). Returns true if the native call executed.
function M.palForPlayer(charId, num, level)
    if type(charId) ~= "string" or #charId == 0 then return false end
    num   = tonumber(num) or 1
    level = tonumber(level) or 1
    local cm = cheatManager()
    if not cm then log.warn("spawn.palForPlayer: no PalCheatManager"); return false end
    local ok = pcall(function() cm:SpawnMonsterForPlayer(FName(charId), num, level) end)
    if ok then log.info(string.format("spawn.palForPlayer %s x%d (lv %d)", charId, num, level))
    else log.err("spawn.palForPlayer: SpawnMonsterForPlayer threw for " .. charId) end
    return ok
end

return M
