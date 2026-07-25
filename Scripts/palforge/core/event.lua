-- PalForge core.event: the ONE unified event system, built on ReactiveX (rxlua,
-- vendored at palforge/utils/vendor/rx.lua). Every lifecycle moment is a named CHANNEL
-- (a hot Rx Subject). This ONE file holds the whole 導線:
--   BUS      : channels + subscribe/emit/operators
--   SOURCE   : native game event  ->  emit(channel, ctx)
--   DISPATCH : channel            ->  the object's lifecycle hook
--
-- End-to-end:
--   native event → SOURCE emit → channel → DISPATCH subscribe → resolve() → inst:onX(ctx)
--
-- The BUILDING source/dispatch below is a faithful re-integration of the parked
-- Phase-2 building runtime (tmp/building_runtime_ref.lua ← deprecated/entity.lua +
-- deprecated/events.lua): a module-local instance registry (scan / instance tracking /
-- persistence), the RequestBuild + OnBeginInteract native hooks, and the world-ready
-- watch. The runtime no longer calls hooks directly — the scan/hooks EMIT channels and
-- DISPATCH resolves the live instance and calls the hook (place fires exactly once).
-- The PAL/ITEM sources stay honest `-- TODO(dump):` (no native dump exists yet); their
-- DISPATCH is wired and starts firing the moment a source emits.
--
--   local event = require("palforge.core.event")
--   event.on("pal.spawned", function(ctx) end)
--   event.observable("building.interact"):filter(...):subscribe(...)
--   local off = event.on("tick", function(c) end); off:unsubscribe()

local Rx  = require("palforge.core.vendor.rx")
local log = require("palforge.utils.log").scope("event")

-- Building-runtime deps (self-contained generic primitives; NO deprecated/tmp require).
local object_manager = require("palforge.core.object_manager")
local spatial        = require("palforge.core.spatial")
local file           = require("palforge.utils.file")
-- The api.building BASE class (not the module): its inert hook defaults are the baseline
-- `overrides()` compares a definition against, and `cls:new(spec)` — used by makeInstance
-- to turn a placed actor into a live instance — resolves through it.
local BuildingBase   = require("palforge.api.building").Class

local M = { Rx = Rx }   -- expose Rx so consumers can build observables / use operators

-- Every valid lifecycle channel (a Subject is pre-created for each).
M.CHANNELS = {
    "gameStart",                                                       -- registry.initialize
    "world.ready", "world.left",                                       -- world load / unload
    "building.place", "building.load", "building.interact", "building.remove",
    "pal.spawned", "pal.damaged", "pal.death", "pal.captured",
    "item.obtain", "item.use", "item.craft", "item.discard",
    "tick",                                                            -- periodic heartbeat
}

M.TICK_MS = 500   -- central heartbeat interval (the tick SOURCE uses it)
local SCAN_MS = M.TICK_MS  -- building reconstruction scan cadence (quantized to the heartbeat)

-- =====================================================================================
-- BUS (Rx)
-- =====================================================================================
local subjects = {}
local function subject(name)
    assert(type(name) == "string" and #name > 0, "event: channel name required")
    subjects[name] = subjects[name] or Rx.Subject.create()
    return subjects[name]
end

function M.channel(name) return subject(name) end       -- Subject (subscribe + push)
function M.observable(name) return subject(name) end    -- read-side alias for operator chains
function M.on(name, onNext, onError, onCompleted) return subject(name):subscribe(onNext, onError, onCompleted) end
function M.emit(name, payload) return subject(name):onNext(payload) end

for _, n in ipairs(M.CHANNELS) do subject(n) end        -- pre-create so subscribe-before-emit works

-- Run fn every `ms` (quantized to the heartbeat). Returns a disposer.
function M.every(ms, fn)
    assert(type(ms) == "number" and ms > 0 and type(fn) == "function", "event.every(ms>0, fn)")
    local acc = 0
    return M.on("tick", function()
        acc = acc + M.TICK_MS
        if acc >= ms then acc = 0; pcall(fn) end
    end)
end

-- =====================================================================================
-- SOURCES — native game event -> emit(channel, ctx).
-- =====================================================================================

-- IMPLEMENTED: the heartbeat. LoopAsync at TICK_MS emits "tick".
local function installTickSource()
    local ok = pcall(function()
        local n = 0
        LoopAsync(M.TICK_MS, function()
            ExecuteInGameThread(function()
                n = n + 1
                pcall(function() M.emit("tick", { count = n, now = os.clock() }) end)
            end)
            return false  -- keep looping
        end)
    end)
    log[ok and "info" or "warn"](ok and "tick source live" or "tick source: LoopAsync unavailable")
end

-- =====================================================================================
-- BUILDING INSTANCE REGISTRY  (module-local; ported from tmp/building_runtime_ref.lua,
-- itself a port of deprecated/entity.lua). Tracks the LIVE instances behind the
-- building.* channels: scan / instance tracking / persistence / deferred mesh.
-- =====================================================================================

-- module-local registry + live instances (the domain state, not a public API).
local Registry = {
    defs         = {},   -- clsId -> def { id, cls, buildIds, gridCm, tickInterval, hooks } (cached)
    byBuildId    = {},   -- resolvedBuildId -> def
    instances    = {},   -- key -> instance
    tickList     = {},   -- array of instances whose class overrides onTick
    pending      = {},   -- placement intents { buildId, pos, player }
    placeObservers = {}, -- every-placement diagnostics fan-out (no public entry point; see NOTE)
    wantFastScan = false,
}
-- weak actor -> instance map (actors are engine objects; don't keep them alive)
local instancesByActor = setmetatable({}, { __mode = "k" })

local MISS_THRESHOLD        = 6    -- consecutive scans an instance may be unseen before removal
local INTERACT_DEBOUNCE_SEC = 1.0
local READY_POLLS           = 5    -- consecutive ~1s polls with a valid player pawn

local worldReady = false  -- world-load gate (set by the ready-watch source below)
local readyCount = 0
local lastInteract = {}   -- "<actorName>" -> os.clock()

-- ---- persistence (per-world file, via utils.file) ----
local worldCache = nil     -- { version, entities = { key -> record } }
local worldDirty = false

local function worldKey()
    return "entities_" .. spatial.saveId()
end

local function loadWorld()
    if worldCache then return worldCache end
    local data = file.get(worldKey())
    if type(data) ~= "table" or type(data.entities) ~= "table" then
        data = { version = 1, entities = {} }
    end
    worldCache = data
    return worldCache
end

local function flushWorld()
    if not worldCache or not worldDirty then return end
    file.setAndFlush(worldKey(), worldCache)
    worldDirty = false
end

-- ---- class helpers ----
-- Does cls override the base hook `name`? The base Building defaults are inert no-ops,
-- so we only tick / index classes that actually implement the hook (faithful to the
-- deprecated `if def.onX`).
local function overrides(cls, name)
    return cls[name] ~= nil and cls[name] ~= BuildingBase[name]
end

-- Does this instance carry a readable mesh (a self:mesh() with a `model` path)?
local function hasMesh(inst)
    local ok, m = pcall(function() return inst:mesh() end)
    return ok and type(m) == "table" and m.model ~= nil
end

-- Build a def from a registered building CLASS. The going-live def used to be built in
-- Building:register(); now it is derived from object_manager's catalog (registry no
-- longer calls cls:register()). Port of Building:register's validation + lowering.
local function buildDef(cls)
    local id = cls.id or cls.__name
    local tickInterval = cls.tickInterval or 1
    if type(tickInterval) ~= "number" or tickInterval < 1 or tickInterval % 1 ~= 0 then tickInterval = 1 end
    local buildIds = cls.buildIds or { id }
    local resolved = {}
    for _, bid in ipairs(buildIds) do
        local r = object_manager.resolve(bid)
        if r then table.insert(resolved, r) end
    end
    return {
        id           = id,
        cls          = cls,
        buildIds     = resolved,
        gridCm       = cls.gridCm or spatial.GRID_CM,
        tickInterval = tickInterval,
        hooks = {
            place      = overrides(cls, "onPlace"),
            load       = overrides(cls, "onLoad"),
            tick       = overrides(cls, "onTick"),
            remove     = overrides(cls, "onRemove"),
            rightClick = overrides(cls, "onRightClick"),
        },
    }
end

-- Refresh defs + byBuildId from the central catalog. Cheap; cached def objects are
-- reused (stable inst.def identity) unless a class is (re)registered. Called before
-- the scan and before recording a placement intent, so buildings defined AFTER
-- start() are picked up.
local function refreshDefs()
    for id, cls in pairs(object_manager.all("building")) do
        local def = Registry.defs[id]
        if not def or def.cls ~= cls then
            def = buildDef(cls)
            Registry.defs[id] = def
        end
        for _, r in ipairs(def.buildIds) do
            Registry.byBuildId[r] = def
        end
    end
end

-- ---- instance object (port of entity.makeInstance + model instance sugar) ----
local function makeInstance(def, buildId, actor, pos, state, key)
    -- A placed structure IS a Building class instance: cls:new(spec) sets the class
    -- metatable, so lifecycle dispatch (inst:onPlace/onTick/onRightClick/...) and the
    -- visual methods (inst:mesh/material/render/update) resolve directly.
    local inst = def.cls:new({
        def   = def, key = key, buildId = buildId,
        pos   = pos, cell = spatial.cellOf(pos, def.gridCm),
        actor = actor, state = state or {},
        missingStreak = 0,
    })
    -- Per-instance persistence closures (INSTANCE FIELDS, like actor/pos — not additions
    -- to the Building class method set). The persisted record's `state` is the SAME table
    -- reference as inst.state, so an in-place mutation is written on the next flush.
    inst.setDirty = function(self)
        worldDirty = true
        local rec = loadWorld().entities[self.key]
        if rec then rec.state = self.state end
    end
    inst.save = function(self) self:setDirty(); flushWorld() end
    inst.isValid = function(self)
        return self.actor and self.actor.IsValid and self.actor:IsValid()
    end
    return inst
end

-- write/refresh the persisted record for an instance
local function persist(inst)
    local w = loadWorld()
    w.entities[inst.key] = { buildId = inst.buildId, pos = inst.pos, state = inst.state, altKeys = {} }
    worldDirty = true
end

-- register a live instance: index, deferred mesh, tick set.
local function addInstance(inst)
    Registry.instances[inst.key] = inst
    if inst.actor then instancesByActor[inst.actor] = inst end
    spatial.indexAdd(inst)
    -- mesh: DEFERRED. Adding a ProceduralMeshComponent to an actor still mid-init (the
    -- frame it's placed) can touch an invalid native object and crash during building.
    -- Mark it pending; the scan's fast path attaches it on a LATER scan, once the actor
    -- has proven stable (seen again). (deprecated _meshPending pattern — dodges the
    -- documented access violation.)
    if inst.actor and hasMesh(inst) then inst._meshPending = true end
    if inst.def.hooks.tick then table.insert(Registry.tickList, inst) end
end

-- bookkeeping removal ONLY — the onRemove hook is fired via the building.remove DISPATCH
-- (scan-miss path emits it while the instance is still tracked so resolve() finds it);
-- world-left teardown calls this WITHOUT emitting (onWorldLeft covers that, records kept).
local function removeInstance(key, reason)
    local inst = Registry.instances[key]
    if not inst then return end
    spatial.indexRemove(inst)
    if inst.actor then instancesByActor[inst.actor] = nil end
    for i = #Registry.tickList, 1, -1 do
        if Registry.tickList[i] == inst then table.remove(Registry.tickList, i); break end
    end
    Registry.instances[key] = nil
    -- delete persisted record only on genuine removal (not world-left)
    if reason ~= "world_left" then
        loadWorld().entities[key] = nil
        worldDirty = true
    end
end

-- ---- placement intent (from the RequestBuild source hook) ----
local function onPlaceRequest(resolvedBuildId, pos, player)
    for _, fn in ipairs(Registry.placeObservers) do pcall(fn, resolvedBuildId, pos, player) end
    refreshDefs()  -- a building defined post-start must be known before we match its id
    if not Registry.byBuildId[resolvedBuildId] then return end
    Registry.wantFastScan = true  -- a building we manage was just placed -> scan promptly
    table.insert(Registry.pending, { buildId = resolvedBuildId, pos = pos, player = player })
    while #Registry.pending > 16 do table.remove(Registry.pending, 1) end
end

local function popPendingNear(buildId, pos)
    if not pos then return nil end
    local best, bestI, bestD = nil, nil, math.huge
    for i, p in ipairs(Registry.pending) do
        if p.buildId == buildId and p.pos then
            local d = spatial.dist2(pos, p.pos)
            if d < bestD and d <= (300 * 300) then best, bestI, bestD = p, i, d end
        end
    end
    if bestI then table.remove(Registry.pending, bestI) end
    return best
end

-- ---- reconstruction scan (crash-safe; gated on worldReady) ----
-- resolveBuildId(actor): 3-tier. 1) class-name BP_BuildObject_<Id>_C direct map;
-- 2) actor's MapObjectModel.BuildObjectId; 3) position match against a persisted record
-- (handled in the scan below).
local function resolveBuildId(actor)
    local ok, cls = pcall(function() return actor:GetClass():GetFullName() end)
    if ok and cls then
        local nm = cls:match("BP_BuildObject_([%w_]+)_C")
        if nm and Registry.byBuildId[nm] then return nm end
    end
    local ok2, bid = pcall(function()
        local m = actor.MapObjectModel or (actor.GetModel and actor:GetModel())
        if m and m:IsValid() then return m.BuildObjectId:ToString() end
    end)
    if ok2 and bid and Registry.byBuildId[bid] then return bid end
    return nil
end

local function actorPos(actor)
    local ok, loc = pcall(function()
        return actor.K2_GetActorLocation and actor:K2_GetActorLocation() or actor:GetActorLocation()
    end)
    if not ok or not loc then return nil end
    local p = { x = loc.X, y = loc.Y, z = loc.Z }
    if (p.x == 0 and p.y == 0 and p.z == 0) then return nil end -- not-ready sentinel
    return p
end

-- One reconstruction pass. Discovers NEW building actors -> creates+tracks the instance
-- and EMITS building.place (matched to a pending RequestBuild intent) / building.load
-- (reconstructed from a saved record). Vanished instances past the miss threshold EMIT
-- building.remove and are dropped. Each channel emit fires the object's hook via DISPATCH
-- (never a direct inst:onX here). The instance-creation branch runs once per key, so
-- building.place emits exactly once per placement.
local function scanOnce()
    if not worldReady then return 0 end
    refreshDefs()
    local okFind, actors = pcall(FindAllOf, "PalBuildObject")
    if not okFind or type(actors) ~= "table" then return 0 end
    local matched = {}
    local changes = 0

    for _, actor in ipairs(actors) do
        local ok = pcall(function()
            if not (actor and actor:IsValid()) then return end

            -- FAST PATH: identity is the ACTOR, not the quantized position (a placed
            -- building's location jitters by >1 cell between scans; keying new instances
            -- off that would churn the same actor into endless instances).
            local bound = instancesByActor[actor]
            if bound and Registry.instances[bound.key] == bound then
                bound.missingStreak = 0
                matched[bound.key] = true
                local p = actorPos(actor)
                if p then bound.pos = p end
                -- deferred mesh: the actor survived >=1 scan, so it's initialized now.
                if bound._meshPending then
                    bound._meshPending = false
                    pcall(function() bound:render() end)
                end
                return
            end

            local pos = actorPos(actor)
            if not pos then return end -- not ready; retried next scan

            local buildId = resolveBuildId(actor)
            -- tier 3: position match against a persisted record for any of our builds
            if not buildId then
                for _, def in pairs(Registry.defs) do
                    for _, bid in ipairs(def.buildIds) do
                        local k = spatial.keyOf(bid, spatial.cellOf(pos, def.gridCm))
                        if loadWorld().entities[k] then buildId = bid; break end
                    end
                    if buildId then break end
                end
            end
            if not buildId then return end
            local def = Registry.byBuildId[buildId]
            if not def then return end

            local cell = spatial.cellOf(pos, def.gridCm)
            local key = spatial.keyOf(buildId, cell)
            matched[key] = true

            local inst = Registry.instances[key]
            if inst then
                -- Same key already held. Reuse only if unbound or the same actor; do NOT
                -- steal another live actor's instance (two buildings in one cell).
                local sameActor = inst.actor == actor
                local heldValid = inst.actor and not sameActor
                    and pcall(function() return inst.actor:IsValid() end) and inst.actor:IsValid()
                if not heldValid then
                    inst.actor = actor; inst.pos = pos
                    instancesByActor[actor] = inst
                    inst.missingStreak = 0
                    if not sameActor and hasMesh(inst) then inst._meshPending = true end
                end
                return
            end

            local rec = loadWorld().entities[key]
            local pend = popPendingNear(buildId, pos)
            local state
            if rec then state = rec.state or {}
            elseif def.cls.defaultState then
                -- defaultState may be a factory function or a plain table. Passed the
                -- class as self so `function Cls:defaultState()` also works.
                local oks, s = pcall(function()
                    local ds = def.cls.defaultState
                    if type(ds) == "function" then return ds(def.cls) end
                    return ds
                end)
                state = (oks and type(s) == "table") and s or {}
            else state = {} end

            inst = makeInstance(def, buildId, actor, pos, state, key)
            if not rec then persist(inst) end
            addInstance(inst)
            changes = changes + 1

            -- EMIT (dispatch resolves the instance and calls the hook). Fresh placement
            -- matched to a RequestBuild intent -> building.place; every newly tracked
            -- instance -> building.load (reconstructed = it came from a saved record).
            if not rec and pend then
                M.emit("building.place", {
                    key = key, actor = actor, pos = pos, buildId = buildId,
                    player = pend.player, firstSeen = true,
                })
            end
            M.emit("building.load", {
                key = key, actor = actor, pos = pos, buildId = buildId,
                reconstructed = (rec ~= nil),
            })
        end)
        if not ok then log.warn("scan: actor pass failed") end
    end

    -- removal sweep
    for key, inst in pairs(Registry.instances) do
        if not matched[key] then
            inst.missingStreak = (inst.missingStreak or 0) + 1
            if inst.missingStreak >= MISS_THRESHOLD then
                -- emit BEFORE dropping so DISPATCH's resolve() still finds the instance.
                M.emit("building.remove", { key = key, buildId = inst.buildId, actor = inst.actor, reason = "missing" })
                removeInstance(key, "missing")
                changes = changes + 1
            end
        end
    end
    Registry.wantFastScan = false  -- consumed by this pass
    return changes
end

-- ---- per-instance tick (port of ticker.tickInstance; circuit-breaks on failure) ----
local function tickOne(inst, ctx)
    if inst.tickBroken then return end
    if not (inst.actor and inst.def.hooks.tick) then return end
    local n = (type(ctx) == "table" and ctx.count) or 0
    if inst.def.tickInterval > 1 and n % inst.def.tickInterval ~= 0 then return end
    local ok, e = pcall(function() inst:onTick(ctx) end)
    if not ok then
        inst.tickFails = (inst.tickFails or 0) + 1
        log.err(string.format("onTick '%s' failed: %s", inst.key, tostring(e)))
        if inst.tickFails >= 5 then
            inst.tickBroken = true
            log.warn("onTick '" .. inst.key .. "' disabled after 5 failures")
        end
    else
        inst.tickFails = 0
    end
end

local function tickAll(ctx)
    for i = 1, #Registry.tickList do
        tickOne(Registry.tickList[i], ctx)
    end
end

-- world-left teardown: drop live instances, keep saved records (port of entity.onWorldLeft).
-- Runs AFTER world.left has been emitted (so onWorldLeft dispatched while still live).
local function dropAllInstances()
    flushWorld()
    local keys = {}
    for k in pairs(Registry.instances) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do removeInstance(k, "world_left") end
    instancesByActor = setmetatable({}, { __mode = "k" })
    spatial.indexReset()
    worldCache = nil  -- re-read on next world (saveId may differ)
    spatial.resetSaveId()
end

-- =====================================================================================
-- SOURCE world — ready-watch (port of entity/events.startReadyWatch). LoopAsync(1000)
-- polling the player pawn: N stable polls -> emit world.ready; going invalid -> emit
-- world.left (then drop live instances). This gate also guards the building scan/hooks
-- (don't touch objects during the load storm).
-- =====================================================================================
local function installWorldSource()
    local ok, e = pcall(function()
        LoopAsync(1000, function()
            ExecuteInGameThread(function()
                local okFind, pawn = pcall(FindFirstOf, "PalPlayerCharacter")
                local valid = okFind and pawn and pawn:IsValid()
                if valid then
                    readyCount = readyCount + 1
                    if readyCount == READY_POLLS then
                        worldReady = true
                        log.info("world ready - building dispatch enabled")
                        pcall(function() M.emit("world.ready") end)
                    end
                else
                    local wasReady = worldReady
                    worldReady = false
                    readyCount = 0
                    if wasReady then
                        log.info("world left - building dispatch paused")
                        pcall(function() M.emit("world.left") end)
                        pcall(dropAllInstances)
                    end
                end
            end)
            return false -- keep polling
        end)
    end)
    if not ok then
        -- fail OPEN but loudly: dispatch works, at the cost of the load-storm guard.
        worldReady = true
        log.warn("ready-watch unavailable (" .. tostring(e) .. ") - dispatch always on")
    end
end

-- =====================================================================================
-- SOURCE building — port of events.install (place-intent + interact) + the scan.
-- =====================================================================================
local function get(param) return param:get() end

local function tryHook(path, fn)
    local ok, e = pcall(RegisterHook, path, fn)
    if not ok then log.warn("hook unavailable (feature disabled): " .. path .. " -> " .. tostring(e)) end
end

local function installBuildingSource()
    -- place intent: RequestBuild_ToServer(FName BuildObjectId, FVector Location, ...).
    -- The actor doesn't exist yet; the scan reconciles this intent against the real
    -- GetActorLocation once it sees the new actor (-> building.place).
    tryHook("/Script/Pal.PalNetworkPlayerComponent:RequestBuild_ToServer", function(self, buildObjectId, location)
        if not worldReady then return end
        local ok, e = pcall(function()
            local id = get(buildObjectId):ToString()
            local pos = nil
            pcall(function()
                local loc = get(location)
                if loc then pos = { x = loc.X, y = loc.Y, z = loc.Z } end
            end)
            local player = FindFirstOf("PalPlayerCharacter")
            onPlaceRequest(id, pos, player)
        end)
        if not ok then log.err("building source: place-intent handler: " .. tostring(e)) end
    end)

    -- interact: OnBeginInteractBuilding(self = building actor, other = interactor).
    -- Resolve the id from the class name and EMIT building.interact; DISPATCH resolves the
    -- live instance (by actor) and calls onRightClick.
    tryHook("/Script/Pal.PalBuildObject:OnBeginInteractBuilding", function(self, other)
        if not worldReady then return end
        local ok, e = pcall(function()
            local building = get(self)
            local otherActor = get(other)
            -- filter: only characters (buildings interact with each other; V3)
            local charClass = StaticFindObject("/Script/Pal.PalCharacter")
            if not (otherActor and otherActor:IsValid()) then return end
            if charClass and charClass:IsValid() and not otherActor:IsA(charClass) then return end

            local actorName = building:GetFullName()
            local now = os.clock()
            if lastInteract[actorName] and (now - lastInteract[actorName]) < INTERACT_DEBOUNCE_SEC then return end
            lastInteract[actorName] = now

            -- identify the building id from its class name: BP_BuildObject_<Id>_C
            local cls = building:GetClass():GetFullName()
            local id = cls:match("BP_BuildObject_([%w_]+)_C") or cls
            M.emit("building.interact", { actor = building, player = otherActor, buildId = id })
        end)
        if not ok then log.err("building source: interact handler: " .. tostring(e)) end
    end)

    -- reconstruction scan on the shared heartbeat (gated on worldReady inside scanOnce).
    M.every(SCAN_MS, scanOnce)

    -- NOTE (from deprecated): no OnCompleteBuild_ServerInternal hook — it fires for every
    -- building during the world-load storm, and touching half-initialized
    -- UPalMapObjectModel memory there caused a native EXCEPTION_ACCESS_VIOLATION (pcall
    -- cannot catch native faults). Placements are reconciled by the deferred scan instead.
end

-- =====================================================================================
-- SOURCE pal / item — HONEST TODO. No deprecated implementation exists for pal/item
-- lifecycle detection, so there is nothing to port. Do NOT invent native event names;
-- the DISPATCH below is already wired and starts firing the moment a source emits.
-- =====================================================================================
-- Native hooks CONFIRMED by the in-game event probe (dump/06_events.txt):
--   capture -> PalCharacterParameterComponent:SetIsCapturedProcessing(bool started=true)
--   damage  -> PalCharacter:OnDamageReaction    death -> PalCharacter:OnDeadCharacter
-- (spawn candidate BroadcastOnCompleteInitializeParameter is UNCONFIRMED — pals pre-existed
--  the probe; kept as a best-effort hook, refine after a spawn probe.)
local function installPalSource()
    -- capture: SetIsCapturedProcessing(true) on the pal's param component; the pal actor
    -- is the component's owner. (probe: a1=true, self=BP_ChickenPal_C.CharacterParameterComponent)
    tryHook("/Script/Pal.PalCharacterParameterComponent:SetIsCapturedProcessing", function(self, started)
        if not worldReady then return end
        pcall(function()
            if get(started) ~= true then return end
            local comp = get(self)
            local actor; pcall(function() actor = comp:GetOwner() end)
            M.emit("pal.captured", { actor = actor, comp = comp })
        end)
    end)
    -- damage: OnDamageReaction (self = the character taking damage).
    tryHook("/Script/Pal.PalCharacter:OnDamageReaction", function(self)
        if not worldReady then return end
        pcall(function() M.emit("pal.damaged", { actor = get(self) }) end)
    end)
    -- death: OnDeadCharacter (self = the dead character).
    tryHook("/Script/Pal.PalCharacter:OnDeadCharacter", function(self)
        if not worldReady then return end
        pcall(function() M.emit("pal.death", { actor = get(self) }) end)
    end)
    -- spawned (UNCONFIRMED candidate): fires when a pal finishes parameter init.
    tryHook("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter", function(self)
        if not worldReady then return end
        pcall(function() M.emit("pal.spawned", { actor = get(self) }) end)
    end)
end

-- Native hooks — both CONFIRMED by the in-game probe (dump/06_events.txt):
--   use    -> PalItemUseProcessor:UseItemToCharacter_ServerInternal, item id on the
--             UScriptStruct param's .Id  (probe: a2 = { Id = "Berries" }).
--   obtain -> PalPlayerState:AddItemGetLog_ToClient — the game's own "obtained item(s)"
--             log; item id + count on the struct param  (probe: a1 = { StaticItemId =
--             "PalSphere", Num = 3 }). Fires on pickup / loot / reward, so it is the right
--             semantic for onObtain. (Silent internal adds that don't surface a get-log are
--             not covered — acceptable; those aren't "the player obtained an item" events.)
local function installItemSource()
    -- get a hook param's value; nil on failure.
    local function getv(p) local ok, v = pcall(function() return p:get() end); if ok then return v end end
    -- read a stringy field off a struct/object value; nil if absent/empty/None.
    local function fstr(v, field)
        if v == nil then return nil end
        local raw; pcall(function() raw = v[field] end)
        if raw == nil then return nil end
        local s = (type(raw) == "userdata" and raw.ToString) and raw:ToString() or tostring(raw)
        if s == nil or s == "" or s == "None" then return nil end
        return s
    end

    -- use: scan the params for the .Id-bearing struct (a2 first) so a shifted signature
    -- still resolves; emit the item id + the target actor (a1).
    tryHook("/Script/Pal.PalItemUseProcessor:UseItemToCharacter_ServerInternal", function(self, a1, a2, a3, a4)
        if not worldReady then return end
        pcall(function()
            local id
            for _, p in ipairs({ a2, a1, a3, a4 }) do
                local v = getv(p); if v ~= nil then id = fstr(v, "Id"); if id then break end end
            end
            if not id then return end
            M.emit("item.use", { itemId = id, actor = getv(a1), processor = get(self) })
        end)
    end)

    -- obtain: scan the params for the struct carrying StaticItemId (+ Num count).
    tryHook("/Script/Pal.PalPlayerState:AddItemGetLog_ToClient", function(self, a1, a2, a3, a4)
        if not worldReady then return end
        pcall(function()
            local id, count
            for _, p in ipairs({ a1, a2, a3, a4 }) do
                local v = getv(p)
                if v ~= nil then
                    local sid = fstr(v, "StaticItemId") or fstr(v, "ItemId")
                    if sid then id = sid; pcall(function() count = v.Num end); break end
                end
            end
            if not id then return end
            M.emit("item.obtain", { itemId = id, count = count })
        end)
    end)
    -- TODO(dump): item.craft (crafting used a work-process, not the get-log) / item.discard —
    -- hook these after a craft-complete / discard probe round.
end

-- =====================================================================================
-- DISPATCH — channel -> the object's lifecycle hook. resolve() maps a ctx to the live
-- instance behind it (buildings: the tracked instance; pal/item: nil for now).
-- =====================================================================================

-- Resolve the PalForge Pal CLASS behind a pal ctx. Pals have no per-instance
-- tracking (no scan) — instead we identify the actor's BlueprintGeneratedClass
-- (BP_<Id>_C, e.g. BP_ChickenPal_C -> "ChickenPal") and return the class registered
-- for that id. The class acts as `self` for the hook; the author's hook reads
-- ctx.actor. A vanilla pal with no PalForge definition -> nil (dispatch no-ops).
local function resolvePalClass(ctx)
    if type(ctx) ~= "table" or ctx.actor == nil then return nil end
    local id
    pcall(function()
        local full = ctx.actor:GetClass():GetFullName()
        if type(full) == "string" then id = full:match("BP_([%w_]+)_C") end
    end)
    if not id then return nil end
    -- exact id: native pals define under the game id (e.g. Pal.define("ChickenPal")).
    local cls = object_manager.get("pal", id)
    if cls then return cls end
    -- namespaced pals: a registered "pack:name" whose resolved fname == the BP id
    -- (covers a modded BP_<pack>_<name>_C class). Fail-soft over the snapshot.
    for regId, c in pairs(object_manager.all("pal")) do
        local okR, r = pcall(object_manager.resolve, regId)
        if okR and r == id then return c end
    end
    return nil
end

-- Resolve the PalForge Item CLASS behind an item ctx. Like pals, items have no
-- per-instance tracking — the ctx carries the game item id (ctx.itemId, e.g. "Berries")
-- and we return the class registered/materialized for it (curated wrapper or a lazy
-- catalog build). A vanilla item with no PalForge definition -> nil (dispatch no-ops).
local function resolveItemClass(ctx)
    if type(ctx) ~= "table" or not ctx.itemId then return nil end
    return object_manager.get("item", ctx.itemId)
end

-- Resolve the concrete handler for `ctx`. Buildings resolve to the live INSTANCE by
-- key (channel emits carry it), then by actor (interact carries only the actor), then
-- a buildId+pos fallback. Pals/items resolve to the defined CLASS by id (BP class name
-- for pals, ctx.itemId for items). Unknown -> nil (dispatch no-ops).
local function resolve(otype, ctx) --> instance | class | nil
    if otype == "pal" then return resolvePalClass(ctx) end
    if otype == "item" then return resolveItemClass(ctx) end
    if otype ~= "building" then return nil end
    if type(ctx) ~= "table" then return nil end
    if ctx.key and Registry.instances[ctx.key] then return Registry.instances[ctx.key] end
    if ctx.actor and instancesByActor[ctx.actor] then return instancesByActor[ctx.actor] end
    if ctx.buildId and ctx.pos then
        local def = Registry.byBuildId[ctx.buildId]
        if def then
            local k = spatial.posKey(ctx.buildId, ctx.pos, def.gridCm)
            if Registry.instances[k] then return Registry.instances[k] end
        end
    end
    return nil
end

local function call(otype, hook, ctx)
    local inst = resolve(otype, ctx)
    if inst and type(inst[hook]) == "function" then pcall(function() inst[hook](inst, ctx) end) end
end

-- Fire a shared world-lifecycle hook on every live building (base defaults are inert).
local function eachLiveBuilding(hook, ctx)
    for _, inst in pairs(Registry.instances) do
        if type(inst[hook]) == "function" then pcall(function() inst[hook](inst, ctx or {}) end) end
    end
end

local function installDispatch()
    -- world -> shared hooks on every live object
    M.on("world.ready", function(ctx) eachLiveBuilding("onWorldReady", ctx) end)
    M.on("world.left",  function(ctx) eachLiveBuilding("onWorldLeft", ctx) end)
    -- building (place fires exactly once: the scan emits it only on instance creation)
    M.on("building.place",    function(ctx) call("building", "onPlace", ctx) end)
    M.on("building.load",     function(ctx) call("building", "onLoad", ctx) end)
    M.on("building.interact", function(ctx) call("building", "onRightClick", ctx) end)
    M.on("building.remove",   function(ctx) call("building", "onRemove", ctx) end)
    -- tick -> onTick on every live building (tickList + tickInterval + circuit-breaker)
    M.on("tick", function(ctx) tickAll(ctx) end)
    -- pal (resolve -> the defined Pal CLASS by BP class name; fires for any PalForge
    -- pal, no-op for a vanilla pal). The source hooks emit ctx.actor.
    M.on("pal.spawned",  function(ctx) call("pal", "onSpawned", ctx) end)
    M.on("pal.damaged",  function(ctx) call("pal", "onDamaged", ctx) end)
    M.on("pal.death",    function(ctx) call("pal", "onDeath", ctx) end)
    M.on("pal.captured", function(ctx) call("pal", "onCaptured", ctx) end)
    -- item (resolve nil for now -> no-op)
    M.on("item.obtain",  function(ctx) call("item", "onObtain", ctx) end)
    M.on("item.use",     function(ctx) call("item", "onUse", ctx) end)
    M.on("item.craft",   function(ctx) call("item", "onCraft", ctx) end)
    M.on("item.discard", function(ctx) call("item", "onDiscard", ctx) end)
end

-- =====================================================================================
-- INSPECTION — read-only views onto the building instance registry. This is how the
-- public api reaches the live structures behind a definition (api/building's
-- Handle:instances()); the registry itself stays module-local.
-- =====================================================================================

-- Every LIVE instance of a building definition, as a list. `buildId` filters by the
-- definition id (cls.id) OR by the matched game build id; nil returns every instance.
function M.instances(buildId)
    local out = {}
    for _, inst in pairs(Registry.instances) do
        if buildId == nil or inst.buildId == buildId
            or (inst.def and inst.def.id == buildId) then
            out[#out + 1] = inst
        end
    end
    return out
end

-- The live instance bound to `actor`, or nil. (What the interact dispatch resolves.)
function M.instanceOfActor(actor)
    if actor == nil then return nil end
    return instancesByActor[actor]
end

-- Is the world loaded far enough for the building runtime to touch objects?
function M.isWorldReady() return worldReady end

-- =====================================================================================
-- start: wire the whole 導線 once (called by registry.initialize)
-- =====================================================================================
local started = false
function M.start()
    if started then return end
    started = true
    -- sources (native -> channel)
    installTickSource(); installWorldSource(); installBuildingSource()
    installPalSource();  installItemSource()
    -- dispatch (channel -> object hook)
    installDispatch()
    log.info("event wired: bus + sources (tick/world/building live; pal/item TODO(dump)) + dispatch")
end

return M
