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
-- watch — plus the OnCompleteBuild hook that runtime refused (see building.build).
-- The runtime no longer calls hooks directly — the scan/hooks EMIT channels and
-- DISPATCH resolves the live instance and calls the hook (place fires exactly once).
-- The PAL source arms four native hooks plus a slow onTick sweep, and the ITEM source
-- three; what is still marked `-- TODO(<id>):` is narrower than it once was — item.craft
-- and item.discard, for which no native call has been found. Their DISPATCH is wired and
-- starts firing the moment a source emits.
--
-- ARMED LATE, ON PURPOSE. Two of those hooks — building.build's
-- OnCompleteBuild_ServerInternal and pal.spawned's BroadcastOnCompleteInitializeParameter
-- — also fire for every PRE-EXISTING object during the world-load storm, where the
-- reference library records one native access violation and one wedged UE4SS callback
-- layer. Neither is registered at start(): both go through tryHookAfterWorldReady, a
-- one-shot world.ready subscriber. See each hook for what that does and does not buy.
--
-- Not every channel dispatches to a live instance: building.build fires BEFORE the actor
-- exists, so like pal/item it resolves to the DEFINITION CLASS (see resolve()).
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
-- The api.pal BASE class, for the same reason: the pal onTick sweep must be able to tell a
-- definition that really implements onTick from one that inherited the inert default.
-- (Neither api module requires core.event at load time, so this is not a cycle.)
local PalBase        = require("palforge.api.pal").Class

local M = { Rx = Rx }   -- expose Rx so consumers can build observables / use operators

-- Every valid lifecycle channel (a Subject is pre-created for each).
M.CHANNELS = {
    "gameStart",                                                       -- registry.initialize
    "world.ready", "world.left",                                       -- world load / unload
    "building.place", "building.load", "building.interact", "building.remove",
    "building.build",                                                  -- build COMPLETE (class-dispatched)
    "pal.spawned", "pal.damaged", "pal.death", "pal.captured",
    "item.obtain", "item.use", "item.craft", "item.discard",
    "tick",                                                            -- periodic heartbeat
}

M.TICK_MS = 500   -- central heartbeat interval (the tick SOURCE uses it)
local SCAN_MS = M.TICK_MS  -- building reconstruction scan cadence (quantized to the heartbeat)

-- Batched persistence cadence. persist() (a newly discovered structure) and inst:setDirty()
-- only MARK the world dirty; the only thing that ever wrote was inst:save() and the
-- world-left teardown, so everything placed in a session used to survive a clean exit and
-- nothing else. 10 s = the deprecated runtime's own batched flush (deprecated/ticker.lua:19
-- FLUSH_EVERY = 20 ticks, :37 "and only when dirty"), which is exactly what flushWorld does.
local FLUSH_MS = 10000

-- Pal onTick sweep cadence. Deliberately NOT the heartbeat: the sweep is a
-- FindAllOf("PalCharacter"), which walks every UObject and is the known periodic-hitch
-- source (the old scheduler backed off to 4 s settled / ~15 s idle for exactly that
-- reason — deprecated/ticker.lua:13-18), and the building scan already runs one such
-- sweep every SCAN_MS. Public and re-read on every heartbeat, so a pack can retune it at
-- runtime without touching the loop: `require("palforge.core.event").PAL_SCAN_MS = 5000`.
M.PAL_SCAN_MS = 3000

-- =====================================================================================
-- BUS (Rx)
--
-- The subjects and the dispatch subscriptions live on _G, not in this module, so they
-- SURVIVE A HOT RELOAD (core/reload). A native hook armed on the first load holds a closure
-- over whatever `subjects` table existed then; if a reload built a fresh one, those hooks
-- would keep pushing into the old table while the new dispatch listened to the new one, and
-- every hook-driven event would silently stop arriving. Sharing the table through _G keeps
-- the old emitters and the new subscribers on the same channels.
-- =====================================================================================
local bus = _G.__PalForgeBus
if not bus then
    bus = { subjects = {}, dispatch = {} }
    _G.__PalForgeBus = bus
end
local subjects = bus.subjects
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
}
-- weak actor -> instance map (actors are engine objects; don't keep them alive)
local instancesByActor = setmetatable({}, { __mode = "k" })

local MISS_THRESHOLD        = 6    -- consecutive scans an instance may be unseen before removal
local INTERACT_DEBOUNCE_SEC = 1.0
local READY_POLLS           = 5    -- consecutive ~1s polls with a valid player pawn

local worldReady = false  -- world-load gate (set by the ready-watch source below)
-- world.ready is DEFERRED: the ready-watch opens the gate above and raises this flag,
-- and the first reconstruction scan that completes afterwards emits the channel. The scan
-- is what creates the live instances, so emitting at gate-open time would dispatch
-- onWorldReady over an empty registry (which is exactly what it used to do).
local pendingWorldReady = false
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
        -- ONLY the tick flag, and deliberately. The port also computed place / load / remove /
        -- rightClick flags — faithful to a runtime that called def.onX DIRECTLY and had to ask
        -- whether one existed (deprecated/entity.lua's `if def.onX`) — but dispatch here goes
        -- through a channel and calls inst[hook], whose base default is an inert no-op, so
        -- those four were computed and then read by nothing. onTick is the one that still
        -- decides something: membership of tickList, i.e. whether the instance is visited at
        -- all, twice a second.
        hooks = { tick = overrides(cls, "onTick") },
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
-- The reference runtime kept two more pieces of state in this function, and NEITHER
-- survives the port, because in this file nothing could ever read or write them:
--   * `placeObservers`, an every-placement fan-out — the only adder was module-local there
--     too (tmp/building_runtime_ref.lua:318,707), so no pack could ever register one and the
--     loop ran over an empty list forever;
--   * `wantFastScan`, "a building we manage was just placed -> scan promptly" — its only
--     consumer was the deprecated adaptive scheduler (deprecated/ticker.lua:110-113), and
--     this scan runs on EVERY heartbeat (SCAN_MS == TICK_MS), so there is no slower cadence
--     to snap out of.
-- Dead state that reads as a feature is worse than no state.
local function onPlaceRequest(resolvedBuildId, pos, player)
    refreshDefs()  -- a building defined post-start must be known before we match its id
    if not Registry.byBuildId[resolvedBuildId] then return end
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
                if p then
                    bound.pos = p
                    -- RE-BUCKET. core.spatial's hash grid keys on the position it was
                    -- indexed at, and this line is the only place an instance ever moves —
                    -- so without the update a structure that drifts far enough keeps its old
                    -- bucket and spatial.neighbors(pos, r) stops finding it. core/spatial.lua
                    -- names this exact call as its one missing hook ("KNOWN GAP ... it
                    -- belongs to the building runtime"). Cheap: it compares the bucket key
                    -- and only touches the index when that key actually changed.
                    spatial.indexUpdate(bound)
                end
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
-- polling the player pawn: N stable polls -> OPEN the worldReady gate and arm the
-- deferred world.ready emit (the scan below fires it, see pendingWorldReady); going
-- invalid -> emit world.left (then drop live instances). This gate also guards the
-- building scan/hooks (don't touch objects during the load storm).
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
                        -- The gate flips HERE (unchanged): every `if not worldReady then
                        -- return end` guard keeps exactly its old load-storm protection.
                        -- The CHANNEL is armed instead of emitted — the next scan owns it.
                        worldReady = true
                        pendingWorldReady = true
                        log.info("world ready - building dispatch enabled")
                    end
                else
                    local wasReady = worldReady
                    worldReady = false
                    pendingWorldReady = false  -- never emit a ready for a world we already left
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
        -- (Arm the deferred emit too, so world.ready still lands if a heartbeat exists;
        --  when LoopAsync is gone there is no scan either, and nothing emits.)
        worldReady = true
        pendingWorldReady = true
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

-- Register a native hook only ONCE THE WORLD IS READY, never at mod load. For a hook that
-- also fires for every pre-existing object during the world-load storm, arming at load is
-- the pattern the reference library warns about twice: a native EXCEPTION_ACCESS_VIOLATION
-- from reading half-initialized model memory in that storm (deprecated/events.lua, the NOTE
-- kept below), and a storm-firing hook that wedged the shared UE4SS hook dispatch
-- (dump/docs/further_plan.md:61-66). world.ready is itself deferred here — the ready-watch
-- opens the gate after five stable pawn polls and the FIRST COMPLETED SCAN emits the
-- channel — so by the time this fires the load storm is over.
--
-- WHAT IT DOES NOT BUY, plainly: UE4SS has no unregister. On a SECOND world load in the
-- same session the hook is still armed and will fire during that storm; the only defence
-- left is the `if not worldReady then return end` line every handler opens with, which
-- stops US from touching the object but not the game from calling us. And if LoopAsync is
-- unavailable there is no scan, so world.ready never lands and the hook never arms at all
-- (fail-soft: that hook's feature is simply off, like any tryHook miss).
local function tryHookAfterWorldReady(path, fn)
    local armed = false
    M.on("world.ready", function()
        if armed then return end        -- one-shot: world.ready re-fires on every world load
        if not worldReady then return end  -- the CHANNEL is public and anyone may emit it (the
                                           -- test suite does, at the title screen); arm on the
                                           -- GATE, so a synthetic emit cannot arm us into a
                                           -- world-load storm.
        armed = true
        tryHook(path, fn)
    end)
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

    -- Reconstruction scan on the shared heartbeat (gated on worldReady inside scanOnce),
    -- and the DEFERRED world.ready emit. The scan is what turns actors into live
    -- instances, so world.ready is announced by the first scan that completes after the
    -- gate opened — by then the structures around the player exist and the onWorldReady
    -- dispatch has something to iterate. Order matters: scan first, then emit. The gate
    -- flag itself is untouched, so the notification only moves <= SCAN_MS later.
    -- Buildings that stream in on a LATER scan still miss it; onLoad is the per-instance
    -- startup hook. (M.every already pcalls this body, so a throwing scan just leaves
    -- pendingWorldReady raised and the next pass retries the emit.)
    M.every(SCAN_MS, function()
        scanOnce()
        if pendingWorldReady then
            pendingWorldReady = false
            pcall(function() M.emit("world.ready") end)
        end
    end)

    -- Batched persistence flush (see FLUSH_MS). Without it the ONLY writes are inst:save()
    -- and the world-left teardown, so a structure discovered by the scan — and any state a
    -- handler mutated in place after inst:setDirty() — reached disk only on a clean exit and
    -- was lost to an alt-F4 or a crash. flushWorld is a no-op while nothing is dirty, so this
    -- costs one boolean test every 10 s.
    M.every(FLUSH_MS, flushWorld)

    -- build COMPLETE -> building.build (api/building's declarable `onBuild`).
    --     /Script/Pal.PalPlayerRecordData:OnCompleteBuild_ServerInternal(UPalMapObjectModel*)
    -- Recorded ✅ in-game (deprecated/poc/V3-place-interact-hooks/README.md + its probe
    -- main.lua:26-34, 2026-07-16): it fires on build-complete AND for every existing
    -- building at world load, and the build id reads off param1 as
    -- `model:get().BuildObjectId:ToString()` — the field is BuildObjectId, NOT MapObjectId.
    --
    -- ARMED AFTER world.ready, NEVER AT start(). This is the exact hook whose world-load
    -- firing storm produced a native EXCEPTION_ACCESS_VIOLATION when the handler read
    -- half-initialized UPalMapObjectModel memory (deprecated/events.lua, 2026-07-17; pcall
    -- cannot catch a native fault) — which is why the deprecated runtime refused it
    -- outright and why the scan below, not this hook, still owns placement reconciliation.
    -- Deferring the arming keeps us out of the first storm entirely; read
    -- tryHookAfterWorldReady for what that does NOT cover (a second world load in the same
    -- session). onPlace remains the safe placement hook; onBuild is the extra one, and it
    -- is worth testing in a throwaway world first.
    --
    -- The emit carries what the hook can actually prove: the build id and the model. There
    -- is no actor here (the actor may not exist yet, and the scan creates the instance up
    -- to SCAN_MS later), so DISPATCH resolves the DEFINITION CLASS by build id — an
    -- instance-level dispatch would silently no-op forever. See resolveBuildingClass.
    tryHookAfterWorldReady("/Script/Pal.PalPlayerRecordData:OnCompleteBuild_ServerInternal",
        function(self, model)
            if not worldReady then return end
            local ok, e = pcall(function()
                local m = get(model)
                if not (m and m.IsValid and m:IsValid()) then return end
                local id
                pcall(function() id = m.BuildObjectId:ToString() end)
                if id == nil or id == "" or id == "None" then return end
                M.emit("building.build", { buildId = id, model = m })
            end)
            if not ok then log.err("building source: build-complete handler: " .. tostring(e)) end
        end)

    -- NO building.break AND NO building.leftclick CHANNEL — MEASURED, not omitted.
    -- api/building DECLARES onBreak and onLeftClick; neither gets a channel here because
    -- the dumps now show there is nothing to feed one with.
    --
    -- (1) OnDamage is a DETERIORATION TIMER, not a strike and not a death rattle. It was
    --     the one lead (dump/docs/further_plan.md:157-166, harness label BUILD.damage,
    --     dump/auto_mod/Scripts/main.lua:37) and dumps/reflection/06_events.txt settles
    --     what it actually is: 196 firings, every one on a placed WorkBench, at a strict
    --     12-13 s per-structure cadence. The workbench placed at t=306.412 (BUILD.place,
    --     OnFinishBuildWork_ServerInternal) takes its first OnDamage at t=306.933 and 180
    --     more over the following 2250 s and is never destroyed. That is the passive decay
    --     the :DeteriorationDamage / :DeteriorationTotalDamage fields on PalMapObjectModel
    --     describe. It fires with no player involved, so it cannot mean "clicked"; it fires
    --     181 times without a destruction, so it cannot mean "broken".
    --
    -- (2) Nothing else on the candidate classes fires either. 02_reflection.txt lists all
    --     four in full — PalBuildObject (22 fns), PalMapObjectModel (18),
    --     PalMapObjectConcreteModelBase (25), PalNetworkPlayerComponent (77) — and none has
    --     a Destroy / Dismantle / Demolish / Deconstruct / Break / Click / Hit / Attack
    --     entry. Destruction appears only as delegate FIELDS
    --     (PalMapObjectModel:OnDestroyDelegate, :OnDisposeDelegateInServer), which
    --     RegisterHook cannot address by path; PalBuildObject.OnChangeVisualForDismantle is
    --     the dismantle preview visual, not a completion.
    --
    -- So destruction stays covered — one MISS_THRESHOLD late and without an instigator — by
    -- the scan's miss sweep -> building.remove -> onRemove(reason = "missing"), and a left
    -- click stays uncovered. Both DISPATCH paths already exist, so a future source (a BP
    -- subclass graph event, or binding OnDestroyDelegate from C++) only has to emit.
end

-- =====================================================================================
-- SOURCE pal / item — HONEST TODO. No deprecated implementation exists for pal/item
-- lifecycle detection, so there is nothing to port. Do NOT invent native event names;
-- the DISPATCH below is already wired and starts firing the moment a source emits.
-- =====================================================================================

-- Defined in the DISPATCH section below. The pal onTick sweep needs the very same
-- actor -> registered-class resolution the pal channels dispatch through, and two copies
-- of that rule would drift, so the one definition is shared and forward-declared here.
local resolvePalClass

-- ---- pal onTick sweep (the SOURCE behind pal.onTick; there is no native hook) ----------
-- Pals have no instance registry the way buildings do — resolve() hands a pal channel the
-- definition CLASS, not a live object — so nothing can drive a periodic pal hook except a
-- sweep. This is the building scan's shape (enumerate -> identify -> call), minus the
-- registry: FindAllOf("PalCharacter") (the enumeration core/spawn.lua:108-112 already uses),
-- each actor resolved to a REGISTERED pal class, and cls:onTick({ actor = ... }) — the same
-- `self` = class, ctx.actor = pawn contract the other four pal channels have.
--
-- COST is the reason this is not on the heartbeat; see M.PAL_SCAN_MS. Per sweep a pal with
-- no PalForge definition costs ONE failed lookup ever: the result (class, or `false` for a
-- miss) is memoized against the actor in a weak table, so later sweeps are a table read.
local palClassOf     = setmetatable({}, { __mode = "k" })   -- actor -> cls | false (miss)
local palTickState   = setmetatable({}, { __mode = "k" })   -- cls -> { fails, broken }
local palDefCount    = -1                                   -- registered pals at last sweep
local PAL_TICK_FAILS = 5    -- circuit-breaker threshold, same as the building tickOne

-- Does this pal CLASS implement onTick? api/pal's default is an inert no-op, so without
-- this test every pal in the world would cost a pcall per sweep to call nothing.
local function palOverridesTick(cls)
    return cls.onTick ~= nil and cls.onTick ~= PalBase.onTick
end

-- Call one pal class's onTick. Port of tickOne's discipline: pcall'd, the error LOGGED with
-- the id that raised it, and the hook disabled after PAL_TICK_FAILS failures so a broken
-- handler cannot burn the sweep forever. State lives beside the class, not on it — the
-- definition table is public and a pack reads its own fields.
local function palTickOne(cls, ctx)
    local st = palTickState[cls]
    if st and st.broken then return end
    local ok, e = pcall(function() cls:onTick(ctx) end)
    if ok then
        if st then st.fails = 0 end
        return
    end
    st = st or { fails = 0 }
    palTickState[cls] = st
    st.fails = st.fails + 1
    log.err(string.format("pal onTick '%s' failed: %s", tostring(cls.id), tostring(e)))
    if st.fails >= PAL_TICK_FAILS then
        st.broken = true
        log.warn("pal onTick '" .. tostring(cls.id) .. "' disabled after "
            .. PAL_TICK_FAILS .. " failures")
    end
end

-- One sweep. Returns how many pals were ticked (0 whenever the gate is shut or the
-- enumeration is unavailable — never throws).
local function palScanOnce(ctx)
    if not worldReady then return 0 end

    -- A definition can be registered at any time (native/pals.lua materializes one lazily on
    -- first get), so a `false` memoized before that would keep a real pal silent for its
    -- actor's whole life. Drop the memo whenever the registered set changes size — one
    -- snapshot walk per sweep, not per actor.
    local n = 0
    for _ in pairs(object_manager.all("pal")) do n = n + 1 end
    if n ~= palDefCount then
        palDefCount = n
        palClassOf = setmetatable({}, { __mode = "k" })
    end
    if n == 0 then return 0 end   -- nothing defined: skip the FindAllOf entirely

    local okFind, actors = pcall(FindAllOf, "PalCharacter")
    if not okFind or type(actors) ~= "table" then return 0 end

    local ticked = 0
    for _, actor in ipairs(actors) do
        local ok = pcall(function()
            if not (actor and actor.IsValid and actor:IsValid()) then return end
            local cls = palClassOf[actor]
            if cls == nil then
                cls = resolvePalClass({ actor = actor }) or false
                palClassOf[actor] = cls
            end
            if cls and palOverridesTick(cls) then
                ticked = ticked + 1
                palTickOne(cls, {
                    actor = actor,
                    count = (type(ctx) == "table" and ctx.count) or 0,
                    now   = (type(ctx) == "table" and ctx.now) or os.clock(),
                })
            end
        end)
        if not ok then log.warn("pal scan: actor pass failed") end
    end
    return ticked
end

-- Drive the sweep off the heartbeat, but at its own much slower cadence. Written out rather
-- than handed to M.every because M.every captures its interval: reading M.PAL_SCAN_MS here,
-- every heartbeat, is what makes the constant tunable without editing this loop.
local function installPalTickSource()
    local acc = 0
    M.on("tick", function(ctx)
        local every = tonumber(M.PAL_SCAN_MS)
        if not every or every <= 0 then return end   -- 0 / nil / garbage = sweep disabled
        acc = acc + M.TICK_MS
        if acc < every then return end
        acc = 0
        pcall(palScanOnce, ctx)
    end)
end

-- Native hooks CONFIRMED by the in-game event probe (dump/06_events.txt):
--   capture -> PalCharacterParameterComponent:SetIsCapturedProcessing(bool started=true)
--   damage  -> PalCharacter:OnDamageReaction    death -> PalCharacter:OnDeadCharacter
-- (spawn candidate BroadcastOnCompleteInitializeParameter is UNCONFIRMED and is armed LATE
--  — see the hook itself. onTick has no native source at all; it is driven by the sweep
--  above, which is why that sweep exists.)
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
    -- ARMED AFTER world.ready, NEVER AT start() — unlike the three confirmed hooks above.
    -- The probe recorded this one firing 0 times when it was armed at load and the pals it
    -- watched pre-existed it (dump/docs/further_plan.md:83-85), and the same note records
    -- WHY that arming is actively harmful: "BroadcastOnCompleteInitializeParameter fires in
    -- the world-load pal-init storm and wedged the shared hook dispatch; must be armed only
    -- AFTER load, or avoided" (:61-64). Wedging the SHARED dispatch takes the three
    -- confirmed hooks down with it, so late arming protects them, not just this one.
    -- Still unproven that it signals a FRESH spawn: that needs a post-load spawn probe, so
    -- keep handlers idempotent and treat the channel as a candidate.
    -- TODO(pal-spawned-fresh): unknown whether BroadcastOnCompleteInitializeParameter fires for a
    -- pal spawned AFTER world load — every probe pal so far pre-existed the hook (0 firings).
    tryHookAfterWorldReady("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter",
        function(self)
            if not worldReady then return end
            pcall(function() M.emit("pal.spawned", { actor = get(self) }) end)
        end)

    installPalTickSource()   -- the onTick sweep (no native hook exists; see above)
end

-- Native hooks:
--   use    -> PalItemUseProcessor:UseItemToCharacter_ServerInternal. CONFIRMED in-game
--             (deprecated/poc/V2-itemuse-hook/README.md, 2026-07-16 single player, and
--             __knowledges/palworld-ue4ss-functions.md): the signature is
--             (UPalStaticItemDataBase* itemData, FPalInstanceID target) and the item id
--             is read as `param1:get().ID` — PARAM ONE, field spelled "ID" in caps.
--   obtain -> TWO sources, deduped through one emitObtain (see below).
--             1. PalPlayerState:AddItemGetLog_ToClient — the game's own "obtained item(s)"
--                log; item id + count on the struct param a1 (.StaticItemId + .Num).
--                Recorded firing in-game with `Wood onObtain: count=15`
--                (dump/docs/further_plan.md:26, 2026-07-22), and the same note rules the
--                inventory paths OUT for pickups: AddItem_ServerInternal, OnUpdateSlotContent,
--                PickupItemDelegate, RequestAddItem_ToServer and RequestObtainLevelObject
--                all fired 0 times over three probe rounds in single-player.
--             2. PalPlayerInventoryData:AddItem_ServerInternal(FName StaticItemId, int Count,
--                bool IsAssignPassive, float LogDelay) — the best-verified SIGNATURE in the
--                reference library (__knowledges/palworld-ue4ss-functions.md:76-85, "✅完全検証",
--                the same call utils.items.give makes), and param1 is a bare FName with no
--                struct dig. Its weakness is the mirror of the get-log's strength: the
--                signature is certain, the FIRING for a player pickup is not — see 1. Both
--                are armed because they fail in opposite directions; neither is authoritative
--                enough to drop.
--             Silent internal adds that surface no get-log are covered only if they take
--             route 2; nothing here can distinguish crafting from pickup (item.craft stays
--             sourceless on purpose rather than being faked from these).
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

    -- read a hook param that IS the value (a bare FName / number), not a struct field.
    local function pstr(p)
        local v = getv(p)
        if v == nil then return nil end
        local s
        if type(v) == "userdata" and v.ToString then pcall(function() s = v:ToString() end)
        else s = tostring(v) end
        if s == nil or s == "" or s == "None" then return nil end
        return s
    end

    -- use: read the id off the item-data param. a1 FIRST and "ID" FIRST — that is the
    -- only shape ever observed in game (V2 probe, above). "Id"/"StaticId" and the later
    -- params stay as fallbacks so a shifted signature still resolves and nothing that
    -- works today stops working. Indexed (not ipairs) so a nil param can't truncate the
    -- sweep.
    --
    -- ctx.actor — WHAT THE PARAMS REALLY ARE. Under the proven signature
    -- (UPalStaticItemDataBase* itemData, FPalInstanceID target) a1 is the item DATA object
    -- and a2 is an instance ID struct; NEITHER is a character, so the old
    -- `actor = getv(a1)` handed every onUse handler an item-data object where the docs
    -- promised the character. Fixed by moving that value to its true name, ctx.itemData,
    -- and putting a real character under ctx.actor:
    --   * ctx.actor    = FindFirstOf("PalPlayerCharacter"), the LOCAL player pawn. This is
    --     the same value the shipped, in-game-verified predecessor passed for exactly this
    --     hook (deprecated/events.lua:114-121, where it was spelled ctx.player) — the one
    --     route with a track record. CAVEAT, because it is not free: it is the local player,
    --     so it is the character who USED the item, which is the character used ON only for
    --     self-use (food, potions). Feed a pal and the pal is a2, not this. On a dedicated
    --     server FindFirstOf returns whichever player pawn comes first, which need not be
    --     the one who acted. Treat ctx.actor as "a player pawn to act on", not as proof.
    --   * ctx.targetId = a2 raw, the FPalInstanceID. NOT resolved to an actor: no
    --     instance-id -> actor lookup is demonstrated anywhere in either tree, and guessing
    --     one would be a plausible fabrication. Handed over as-is so a pack that learns the
    --     resolution can use it, and so a later probe has somewhere to land.
    tryHook("/Script/Pal.PalItemUseProcessor:UseItemToCharacter_ServerInternal", function(self, a1, a2, a3, a4)
        if not worldReady then return end
        pcall(function()
            local id
            local params = { a1, a2, a3, a4 }
            for i = 1, 4 do
                local v = getv(params[i])
                if v ~= nil then
                    id = fstr(v, "ID") or fstr(v, "Id") or fstr(v, "StaticId")
                    if id then break end
                end
            end
            if not id then return end
            local character; pcall(function() character = FindFirstOf("PalPlayerCharacter") end)
            M.emit("item.use", {
                itemId   = id,
                actor    = character,   -- the local player pawn (see the caveat above)
                player   = character,   -- same value under the name the old runtime used
                itemData = getv(a1),    -- UPalStaticItemDataBase (what ctx.actor used to be)
                targetId = getv(a2),    -- FPalInstanceID, unresolved
                processor = get(self),
            })
        end)
    end)

    -- Both obtain sources funnel through here. They overlap by design (the get-log and the
    -- inventory add are two views of ONE pickup), so a repeat of the same id inside
    -- OBTAIN_DEDUPE_SEC is dropped. The window is per ID, not per (id,count): the two
    -- sources need not agree on the count (a get-log may aggregate), and matching on it
    -- would let a mismatch through as a second obtain. The cost is stated plainly — a
    -- genuine second pickup of the SAME id within the window is lost. Half a second is
    -- shorter than any human repeat pickup and longer than the gap between two views of one.
    --
    -- `emitting` is a separate concern: utils.items.give IS an AddItem_ServerInternal call,
    -- so an onObtain handler that gives an item would re-enter this hook. Without the guard
    -- that recurses until the stack dies for any id the dedupe window does not cover.
    local OBTAIN_DEDUPE_SEC = 0.5
    local lastObtain, emitting = {}, false
    local function emitObtain(id, count, via)
        if emitting then return end
        local now = os.clock()
        local prev = lastObtain[id]
        if prev and (now - prev) < OBTAIN_DEDUPE_SEC then return end
        lastObtain[id] = now
        emitting = true
        local ok, e = pcall(function()
            M.emit("item.obtain", { itemId = id, count = count, via = via })
        end)
        emitting = false
        if not ok then log.err("item.obtain (" .. tostring(via) .. "): " .. tostring(e)) end
    end

    -- obtain 1: the get-log. Scan the params for the struct carrying StaticItemId (+ Num).
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
            emitObtain(id, tonumber(count), "getlog")
        end)
    end)

    -- obtain 2: the inventory add. a1 is a bare FName, a2 the count — read positionally,
    -- because that signature is the verified part of this source. A NEGATIVE count is a
    -- removal (what utils.items.take pushes through this very call), never an obtain, so it
    -- is skipped rather than reported as one.
    tryHook("/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal", function(self, a1, a2, a3, a4)
        if not worldReady then return end
        pcall(function()
            local id = pstr(a1)
            if not id then return end
            local count = tonumber(pstr(a2))
            if count and count <= 0 then return end
            emitObtain(id, count, "additem")
        end)
    end)

    -- item.craft and item.discard stay SOURCELESS, on purpose rather than by omission.
    -- The one signal that is right there — the get-log — cannot stand in for either: a
    -- crafted item surfaces through that same get-log ("Crafting output surfaces through the
    -- same get-log, so item.craft may be redundant with item.obtain",
    -- dump/docs/further_plan.md:38-39), so emitting item.craft from it would report every
    -- pickup as a craft. Neither channel has a candidate native function recorded anywhere:
    -- dump/dump_targets.md:149-150 lists both as `dump to discover`, and the probe harness
    -- (dump/auto_mod/Scripts/main.lua:33-48) never armed one. Their DISPATCH is wired and
    -- begins working the moment an emit lands here.
    -- TODO(item-craft-source): no craft-complete UFunction is known — which class/function the
    -- game calls when a bench finishes an item, and which param carries the id + count.
    -- Still fully open: the 21 classes in dumps/reflection/02_reflection.txt do not include
    -- PalMapObjectProductItemModel / PalMapObjectWorkeeModel / PalWorkProgress*, and no
    -- craft-shaped hook was ever armed, so nothing in the dumps speaks to it.
    --
    -- TODO(item-discard-source): NARROWED by the dumps, not closed. What is now measured:
    -- there is no dedicated drop/discard entry point on the inventory classes at all —
    -- 02_reflection.txt lists PalPlayerInventoryData in full (69 fns; the only removal-shaped
    -- name is TryRemoveEquipment) and PalItemContainer in full (13 fns, all reads), so the
    -- "separate discard UFunction" branch of this question is dead. What is still unknown is
    -- the standing hypothesis: whether a drop arrives as AddItem_ServerInternal with a
    -- NEGATIVE Count. The dumps cannot say — that hook WAS armed successfully (14/14, label
    -- ITEM.add, dump/auto_mod/Scripts/main.lua:44) and never fired once across both recorded
    -- sessions, in either direction, while ITEM.getlog and ITEM.use did; so either the
    -- sessions contained no qualifying action or this call does not run client-side at all.
    -- The next probe has to log ITEM.add and ITEM.getlog side by side across a pickup AND a
    -- drop to tell those two apart.
end

-- =====================================================================================
-- DISPATCH — channel -> the object's lifecycle hook. resolve() maps a ctx to whatever
-- stands behind it: the tracked INSTANCE for buildings, the definition CLASS for pals,
-- items, and building.build (which fires before any instance exists).
-- =====================================================================================

-- Resolve the PalForge Pal CLASS behind a pal ctx. Pals have no per-instance
-- tracking (no scan) — instead we identify the actor's BlueprintGeneratedClass
-- (BP_<Id>_C, e.g. BP_ChickenPal_C -> "ChickenPal") and return the class registered
-- for that id. The class acts as `self` for the hook; the author's hook reads
-- ctx.actor. A vanilla pal with no PalForge definition -> nil (dispatch no-ops).
-- (Forward-declared above the pal SOURCE: the onTick sweep resolves through this too,
-- so both halves of the 導線 share exactly one pal resolver.)
function resolvePalClass(ctx)
    if type(ctx) ~= "table" or ctx.actor == nil then return nil end
    local id
    pcall(function()
        local full = ctx.actor:GetClass():GetFullName()
        if type(full) == "string" then id = full:match("BP_([%w_]+)_C") end
    end)
    if not id then return nil end
    -- exact id: native pals define under the game id (e.g. Pal{ id = "ChickenPal" }).
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
    -- exact id: native items define under the game id (e.g. Item{ id = "Berries" }).
    local cls = object_manager.get("item", ctx.itemId)
    if cls then return cls end
    -- namespaced items: a registered "pack:name" whose resolved fname == the game id
    -- (the game emits the PalSchema row name "pack_name", never the colon form). Without
    -- this every pack-authored item would be silently eventless. Fail-soft over the
    -- snapshot — same shape as resolvePalClass above.
    for regId, c in pairs(object_manager.all("item")) do
        local okR, r = pcall(object_manager.resolve, regId)
        if okR and r == ctx.itemId then return c end
    end
    return nil
end

-- Resolve the PalForge Building DEFINITION CLASS behind a build id. building.build is the
-- one building channel that fires BEFORE an instance exists — at build-complete time the
-- scan has not created it yet (up to SCAN_MS later) and the ctx carries a UPalMapObjectModel
-- rather than the actor, so the instance resolve() below would return nil and onBuild would
-- silently never run. Class-level instead, the same shape as resolvePalClass: the class acts
-- as `self` and the author's hook reads ctx.buildId / ctx.model. Namespaced ids need no
-- extra pass here — refreshDefs indexes every def under its RESOLVED build ids, so a
-- definition declared as "pack:Bench" is already keyed under "pack_Bench", the form the
-- game emits. A vanilla building with no PalForge definition -> nil (dispatch no-ops).
local function resolveBuildingClass(ctx)
    if type(ctx) ~= "table" or not ctx.buildId then return nil end
    refreshDefs()   -- a building defined after start() must be known before we match its id
    local def = Registry.byBuildId[ctx.buildId]
    return def and def.cls or nil
end

-- Resolve the concrete handler for `ctx`. Buildings resolve to the live INSTANCE by
-- key (channel emits carry it), then by actor (interact carries only the actor), then
-- a buildId+pos fallback. Pals/items resolve to the defined CLASS by id (BP class name
-- for pals, ctx.itemId for items), and so does the pseudo-type "buildingClass" — the
-- instance-less route used by building.build. Unknown -> nil (dispatch no-ops).
local function resolve(otype, ctx) --> instance | class | nil
    if otype == "pal" then return resolvePalClass(ctx) end
    if otype == "item" then return resolveItemClass(ctx) end
    if otype == "buildingClass" then return resolveBuildingClass(ctx) end
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

-- Call one object's hook. A handler is pack code, so it stays pcall'd — but the error is
-- LOGGED with the channel and hook that raised it, not swallowed: a typo in an onUse body
-- used to be indistinguishable from a hook that never fired.
local function call(otype, hook, ctx, channel)
    local inst = resolve(otype, ctx)
    if inst and type(inst[hook]) == "function" then
        local ok, e = pcall(function() inst[hook](inst, ctx) end)
        if not ok then
            log.err(string.format("%s -> %s handler failed: %s",
                tostring(channel or otype), hook, tostring(e)))
        end
    end
end

-- Fire a shared world-lifecycle hook on every live building (base defaults are inert).
-- Same logging discipline as call(): one broken instance is skipped, not hidden.
local function eachLiveBuilding(hook, ctx, channel)
    for key, inst in pairs(Registry.instances) do
        if type(inst[hook]) == "function" then
            local ok, e = pcall(function() inst[hook](inst, ctx or {}) end)
            if not ok then
                log.err(string.format("%s -> %s handler failed on '%s': %s",
                    tostring(channel or "world"), hook, tostring(key), tostring(e)))
            end
        end
    end
end

-- Subscribe DISPATCH to every channel. Re-runnable: a hot reload calls this again with the
-- new module's handlers, so the previous run's subscriptions are dropped first — otherwise
-- each reload would add a second dispatcher and every hook would run twice, then three times.
local function installDispatch()
    for _, sub in ipairs(bus.dispatch) do pcall(function() sub:unsubscribe() end) end
    bus.dispatch = {}
    local function on(name, fn) bus.dispatch[#bus.dispatch + 1] = M.on(name, fn) end

    -- world -> shared hooks on every live object. world.ready is emitted by the scan (see
    -- installBuildingSource), so the instances it iterates really exist by then.
    on("world.ready", function(ctx) eachLiveBuilding("onWorldReady", ctx, "world.ready") end)
    on("world.left",  function(ctx) eachLiveBuilding("onWorldLeft", ctx, "world.left") end)
    -- building (place fires exactly once: the scan emits it only on instance creation)
    on("building.place",    function(ctx) call("building", "onPlace", ctx, "building.place") end)
    on("building.load",     function(ctx) call("building", "onLoad", ctx, "building.load") end)
    on("building.interact", function(ctx) call("building", "onRightClick", ctx, "building.interact") end)
    on("building.remove",   function(ctx) call("building", "onRemove", ctx, "building.remove") end)
    -- building.build is the exception: it fires before the actor/instance exists, so it
    -- dispatches to the DEFINITION CLASS (self = the class, like pal/item), not an instance.
    on("building.build",    function(ctx) call("buildingClass", "onBuild", ctx, "building.build") end)
    -- tick -> onTick on every live building (tickList + tickInterval + circuit-breaker)
    on("tick", function(ctx) tickAll(ctx) end)
    -- pal (resolve -> the defined Pal CLASS by BP class name; fires for any PalForge
    -- pal, no-op for a vanilla pal). The source hooks emit ctx.actor.
    on("pal.spawned",  function(ctx) call("pal", "onSpawned", ctx, "pal.spawned") end)
    on("pal.damaged",  function(ctx) call("pal", "onDamaged", ctx, "pal.damaged") end)
    on("pal.death",    function(ctx) call("pal", "onDeath", ctx, "pal.death") end)
    on("pal.captured", function(ctx) call("pal", "onCaptured", ctx, "pal.captured") end)
    -- item (resolve -> the defined Item CLASS by ctx.itemId, exact or namespaced;
    -- item.craft / item.discard have no source yet, so they never carry traffic)
    on("item.obtain",  function(ctx) call("item", "onObtain", ctx, "item.obtain") end)
    on("item.use",     function(ctx) call("item", "onUse", ctx, "item.use") end)
    on("item.craft",   function(ctx) call("item", "onCraft", ctx, "item.craft") end)
    on("item.discard", function(ctx) call("item", "onDiscard", ctx, "item.discard") end)
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
-- The SOURCE layer arms native hooks and starts LoopAsync loops, and UE4SS can take back
-- neither — so it runs once per SESSION, not once per module load. The flag lives on _G
-- (core/reload owns it) so a hot reload cannot re-arm and double every hook.
-- DISPATCH is re-attached on every load, because that is what routes a channel to the
-- freshly-loaded definition classes.
function M.start()
    local reload = require("palforge.core.reload")
    if reload.armed() then
        installDispatch()
        log.info("event re-attached: dispatch rebound to the reloaded modules "
            .. "(native hooks and loops kept from the first load)")
        return
    end

    -- sources (native -> channel)
    installTickSource(); installWorldSource(); installBuildingSource()
    installPalSource();  installItemSource()
    -- dispatch (channel -> object hook)
    installDispatch()
    reload.markArmed()
    log.info("event wired: bus + sources (tick/world/building/pal/item live; onBuild + onSpawned "
        .. "arm at world.ready; craft+discard have no native source) + dispatch")
end

return M
