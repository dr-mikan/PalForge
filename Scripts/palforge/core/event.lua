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
-- The PAL source arms six native hooks plus a slow onTick sweep, the ITEM source six, and
-- the SKILL source eight. Most were found in dumps/cxx/Pal.hpp — UE4SS's own CXXHeaderDump
-- of the installed binary — which is the first source in this tree that could answer "what
-- does the game call when X happens" without the game running. Each carries, at its hook,
-- the EVIDENCE CLASS it was wired on:
--   recorded firing  > reflected in the live build > declared in the header dump only.
-- Nothing below is wired on less than a real declaration, and the two channels that STILL
-- have no source (building.leftclick, building.break) say so with the reason.
--
-- SOME CHANNELS CARRY SEVERAL SOURCES AT ONCE, and that is deliberate rather than untidy.
-- A play session on 2026-07-26 measured four hooks REGISTERING and never firing —
-- PlayActionByWazaID, MakeDamageInfoByWazaType, AddPassiveSkill/RemovePassiveSkill and
-- BroadcastOnCompleteInitializeParameter — while ten other channels announced in the same
-- session. UE4SS cannot unregister a hook, so those four stay armed (a silent hook costs
-- nothing) and the candidates the dump named to replace them are armed BESIDE them. Whichever
-- one the shipping build actually reaches wins, and announceVia logs which that was, once.
-- Every one of them is guarded on the identity it needs (a named EPalWazaID, a live actor),
-- so an extra source can only add silence, never a wrong event.
--
-- ARMED LATE, ON PURPOSE. Some of those hooks — building.build's
-- OnCompleteBuild_ServerInternal, the three pal.spawned candidates, the three passive ones
-- — also fire for every PRE-EXISTING object during the world-load storm, where the
-- reference library records one native access violation and one wedged UE4SS callback
-- layer. None is registered at start(): they go through tryHookAfterWorldReady, a
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
-- core/character owns the ONE EPalWazaID name<->value table in this tree (309 names, taken
-- verbatim from dumps/cxx/Pal_enums.hpp). The skill source below receives that enum as a bare
-- integer from two native hooks and has to answer a caller in NAMES, so it reads that table
-- rather than keeping a second copy that could drift. (core/character requires only log and
-- signature, so this is not a cycle; api/pal already pulls it in one line above.)
local character      = require("palforge.core.character")

local M = { Rx = Rx }   -- expose Rx so consumers can build observables / use operators

-- Every valid lifecycle channel (a Subject is pre-created for each).
M.CHANNELS = {
    "gameStart",                                                       -- registry.initialize
    "world.ready", "world.left",                                       -- world load / unload
    "building.place", "building.load", "building.interact", "building.remove",
    "building.build",                                                  -- build COMPLETE (class-dispatched)
    "pal.spawned", "pal.damaged", "pal.death", "pal.captured",
    "item.obtain", "item.use", "item.craft", "item.discard",
    "skill.activate", "skill.hit", "skill.equip", "skill.unequip",     -- Skill.Spec.Events
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
-- PROOF OF LIFE, one line per channel per session, at the moment it first carries something.
--
-- A source that fires and a source that does not look identical from the log, because a channel
-- with no matching definition dispatches to nobody and says nothing. That cost a full play
-- session: every hook registered, the player crafted, dropped and fought, and the log showed no
-- skill.activate and no item.craft — which could equally have meant "the hook never fired" or
-- "it fired and no pack had declared that skill". Those need opposite next steps.
--
-- The tick channel is excluded: it fires twice a second forever and its liveness is never in
-- doubt.
function M.emit(name, payload) return subject(name):onNext(payload) end

-- What a SOURCE uses. Identical to M.emit except it announces the first time a channel carries
-- something, which is the one thing the log could not say.
--
-- A source that fires and a source that does not look identical from outside, because a channel
-- with no matching definition dispatches to nobody and prints nothing. That cost a whole play
-- session: every hook registered, the player crafted, dropped and fought, and the log showed no
-- skill.activate and no item.craft — which could equally have meant "the hook never fired" or
-- "it fired and no pack had declared that skill". Those need opposite next steps.
--
-- Deliberately NOT inside M.emit. The test suite emits every channel by hand to prove dispatch
-- works, so putting this there marked all twenty as live the moment F1 ran and answered the
-- question with the suite's own noise. Only a native source announces.
--
-- The tick channel is excluded: it fires twice a second forever and its liveness is never in
-- doubt.
local firstEmit = {}
local function srcEmit(name, payload)
    if not firstEmit[name] and name ~= "tick" then
        firstEmit[name] = true
        log.info(string.format("channel %s carried its first event this session — the native "
            .. "source is LIVE, whether or not any definition handled it", name))
    end
    return subject(name):onNext(payload)
end

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
                pcall(function() srcEmit("tick", { count = n, now = os.clock() }) end)
                -- Everything in this tree that needs to watch the world repeatedly rides HERE,
                -- rather than asking UE4SS for a timer of its own. This loop is armed once per
                -- session and never stops, so it creates no registry references to tear down —
                -- and a teardown race on those is what removes the engine tick hook and kills
                -- every keybind in the mod. See core/poll.lua for the full account.
                -- Required fresh each tick, never captured: this closure was armed on the FIRST
                -- load and keeps running across every reload, so it must reach the CURRENT
                -- module rather than the one that existed when it was created.
                pcall(function() require("palforge.core.poll").drain() end)
            end)
            return false  -- keep looping, for the life of the process
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
                srcEmit("building.place", {
                    key = key, actor = actor, pos = pos, buildId = buildId,
                    player = pend.player, firstSeen = true,
                })
            end
            srcEmit("building.load", {
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
                srcEmit("building.remove", { key = key, buildId = inst.buildId, actor = inst.actor, reason = "missing" })
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
                        pcall(function() srcEmit("world.left") end)
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

-- ---- hook-parameter readers, shared by every SOURCE below --------------------------------
-- These three used to live inside installItemSource. They are module-level now because the
-- item, skill and craft/discard sources all read parameters the same way and a second copy of
-- "how do you get a value out of a UE4SS hook param" is exactly the thing that drifts.

---A hook param's value, or nil on failure. UE4SS hands params in as wrappers with :get().
local function getv(p) local ok, v = pcall(function() return p:get() end); if ok then return v end end

---Read a stringy FIELD off a struct/object value; nil if absent, empty or "None".
local function fstr(v, field)
    if v == nil then return nil end
    local raw; pcall(function() raw = v[field] end)
    if raw == nil then return nil end
    local s = (type(raw) == "userdata" and raw.ToString) and raw:ToString() or tostring(raw)
    if s == nil or s == "" or s == "None" then return nil end
    return s
end

---Is `o` a live UObject? Every hook below that reaches THROUGH one object to reach another
---(a component to its owner, a notify state to its filter) asks this first, because an
---engine object handed to a hook can be mid-teardown and a property read on one of those is
---the shape that faults natively — which pcall cannot catch.
local function alive(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o.IsValid and o:IsValid() end)
    return ok and v == true
end

---A STABLE table key for a UObject, as a string.
---
---Not the userdata. UE4SS builds a fresh Lua wrapper on every `:get()` / FindAllOf element, so
---`t[obj]` written in one hook call is not `t[obj]` read in the next even for the identical
---engine object — a table keyed on the wrapper silently never matches and every dedupe or
---diff built on it degrades to "always new". GetFullName() is the object's unique path
---(`PalPassiveSkillComponent /Game/.../BP_ChickenPal_C_2147460233.PassiveSkillComponent`) and
---is the same string every time. nil when it cannot be read, and every caller treats that as
---"do not remember this one" rather than as a key.
local function objKey(o)
    if o == nil then return nil end
    local s; pcall(function() s = o:GetFullName() end)
    if type(s) ~= "string" or s == "" then return nil end
    return s
end

---Read a hook param that IS the value (a bare FName / number), not a struct field.
local function pstr(p)
    local v = getv(p)
    if v == nil then return nil end
    local s
    if type(v) == "userdata" and v.ToString then pcall(function() s = v:ToString() end)
    else s = tostring(v) end
    if s == nil or s == "" or s == "None" then return nil end
    return s
end

---Walk a UE4SS TArray, calling fn(value) per element. UE4SS hands arrays back in three shapes
---depending on build and element type (a :ForEach, a #-indexable userdata, or a :Get(i-1)), so
---all three are tried in that order — the same ladder core/character.lua:450 uses, which is the
---one array reader in this tree that has been read back from a live save. Elements are NOT
---unwrapped here: every caller below wants the struct itself, not a scalar behind :get().
local function eachArray(arr, fn)
    if arr == nil then return 0 end
    local n = 0
    local function push(v) if v ~= nil then n = n + 1; pcall(fn, v) end end
    if pcall(function() arr:ForEach(function(_, v) push(v) end) end) and n > 0 then return n end
    local len; pcall(function() len = #arr end)
    if type(len) ~= "number" or len <= 0 then return n end
    for i = 1, len do local v; pcall(function() v = arr[i] end); push(v) end
    if n > 0 then return n end
    for i = 1, len do local v; pcall(function() v = arr:Get(i - 1) end); push(v) end
    return n
end

local function tryHook(path, fn)
    local ok, e = pcall(RegisterHook, path, fn)
    if not ok then log.warn("hook unavailable (feature disabled): " .. path .. " -> " .. tostring(e)) end
end

-- Which SOURCE first carried a given channel, announced once per (channel, source) pair.
--
-- srcEmit already says "this channel is live", and that was enough while every channel had one
-- source. Three of them do not any more: pal.spawned, skill.activate and skill.hit each carry
-- several candidate hooks, armed side by side precisely because nobody knows which one the
-- shipping build reaches — and "skill.activate works" is not an actionable sentence when the
-- next step differs completely depending on whether the action OBJECT or the player's action
-- COMPONENT is what fired. One extra line, once, is the difference between a measurement and
-- a rumour. It is the same reasoning as srcEmit's own proof-of-life line, one level finer.
local viaSeen = {}
local function announceVia(channel, via)
    local k = channel .. "\0" .. tostring(via)
    if viaSeen[k] then return end
    viaSeen[k] = true
    log.info(string.format("%s carried its first event from source %q — that is the path that "
        .. "works on this build", channel, tostring(via)))
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
            srcEmit("building.interact", { actor = building, player = otherActor, buildId = id })
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
            pcall(function() srcEmit("world.ready") end)
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
                srcEmit("building.build", { buildId = id, model = m })
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
-- (the spawn candidates are armed LATE and there are now THREE of them — the broadcaster,
--  measured silent, plus the two delegate TARGETS the dump named to replace it. See the hooks
--  themselves. onTick has no native source at all; it is driven by the sweep above, which is
--  why that sweep exists.)
local function installPalSource()
    -- THREE sources can describe one pal finishing its parameter init, so a spawn is deduped
    -- PER ACTOR rather than per id: the same character reaching two of them is one spawn, and
    -- two different pals born in the same frame are two. The key is objKey's stable string,
    -- NOT the actor wrapper — see objKey for why a wrapper cannot be a table key here. An
    -- actor whose name will not read is emitted without being remembered, because a duplicate
    -- event is a smaller wrong than a dropped one.
    --
    -- Bounded on purpose: pals stream in and out for a whole session and the keys are strings,
    -- so nothing would ever release them. At the cap the table is dropped whole — the only
    -- cost of that is that a pal which initialises twice across the boundary is reported
    -- twice, which is what handlers are already told to tolerate.
    local SPAWN_DEDUPE_SEC = 1.0
    local SPAWN_KEYS_MAX   = 2048
    local lastSpawn, lastSpawnN = {}, 0
    local function emitSpawned(actor, via)
        if not alive(actor) then return end
        local now = os.clock()
        local key = objKey(actor)
        if key then
            if lastSpawn[key] and (now - lastSpawn[key]) < SPAWN_DEDUPE_SEC then return end
            if lastSpawnN >= SPAWN_KEYS_MAX then lastSpawn, lastSpawnN = {}, 0 end
            if lastSpawn[key] == nil then lastSpawnN = lastSpawnN + 1 end
            lastSpawn[key] = now
        end
        announceVia("pal.spawned", via)
        srcEmit("pal.spawned", { actor = actor, via = via })
    end

    -- capture: SetIsCapturedProcessing(true) on the pal's param component; the pal actor
    -- is the component's owner. (probe: a1=true, self=BP_ChickenPal_C.CharacterParameterComponent)
    tryHook("/Script/Pal.PalCharacterParameterComponent:SetIsCapturedProcessing", function(self, started)
        if not worldReady then return end
        pcall(function()
            if get(started) ~= true then return end
            local comp = get(self)
            local actor; pcall(function() actor = comp:GetOwner() end)
            srcEmit("pal.captured", { actor = actor, comp = comp })
        end)
    end)
    -- damage: OnDamageReaction (self = the character taking damage).
    tryHook("/Script/Pal.PalCharacter:OnDamageReaction", function(self)
        if not worldReady then return end
        pcall(function() srcEmit("pal.damaged", { actor = get(self) }) end)
    end)
    -- death: OnDeadCharacter (self = the dead character).
    tryHook("/Script/Pal.PalCharacter:OnDeadCharacter", function(self)
        if not worldReady then return end
        pcall(function() srcEmit("pal.death", { actor = get(self) }) end)
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
    --
    -- WHAT dumps/cxx SETTLED, 2026-07-26, and it is the architectural half of the question.
    -- `void BroadcastOnCompleteInitializeParameter()` is declared on APalCharacter at
    -- Pal.hpp:9087 with ZERO parameters, so `self` really is the character and there is
    -- nothing else the hook could hand us. What it broadcasts is
    -- `OnCompleteInitializeParameterDelegateMap` (:9016), a map keyed by
    -- EPalCharacterCompleteDelegatePriority and filled through BindOnCompleteInitialize-
    -- ParameterDelegate (:9088). And the SPAWN API rides that very map:
    -- UPalCharacterManager::SpawnNewCharacterWithInitializeParameterCallback (Pal.hpp:15538)
    -- takes an `EPalCharacterCompleteDelegatePriority InitializeParameterCallbackPriority`
    -- alongside its InitializeParameterCallback — the game's own way of saying "call me when
    -- this NEW character finishes initialising" is a subscription to this broadcast. A pal
    -- created after world load therefore does broadcast; that is no longer a hope.
    -- MEASURED SILENT, 2026-07-26. Armed after world.ready in a real save (UE4SS logged the
    -- registration as hooks 39, 40), pals were caught and released, and pal.spawned carried
    -- nothing while ten other channels announced. So the suspicion below is now the finding:
    -- the BROADCASTER is not reachable through ProcessEvent. It stays armed — UE4SS cannot
    -- unregister — and the two delegate TARGETS it names are armed beside it.
    tryHookAfterWorldReady("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter",
        function(self)
            if not worldReady then return end
            pcall(function() emitSpawned(get(self), "BroadcastOnCompleteInitializeParameter") end)
        end)

    -- THE REPLACEMENT, and the dump names TWO of them rather than one. Everything bound to
    -- APalCharacter's OnCompleteInitializeParameterDelegateMap has the signature
    -- `OnCompleteInitializeParameter__DelegateSignature(APalCharacter* InCharacter)`
    -- (Pal.hpp:9052), so any function in the binary with that exact parameter list is a bound
    -- handler — and a dynamic-delegate target is always invoked through ProcessEvent, which is
    -- the path RegisterHook can see. Reading the classes whole turned up three; two are wired:
    --
    --   APalPlayerCharacter::OnCompleteInitializeParameter(APalCharacter*)   (Pal.hpp:10637)
    --     EVIDENCE CLASS: REFLECTED + DECLARED. The name is in the live build's own
    --     PalPlayerCharacter listing (dumps/reflection/02_reflection.txt, the block at :738),
    --     which is the strongest any pal.spawned candidate has ever had. `self` is the PLAYER
    --     and a1 is the character that finished initialising — so the emit reads ctx.actor off
    --     a1, never off self. Its limit: it only fires for characters the PLAYER subscribed
    --     to, which is the otomo/party path rather than every wild pal that streams in.
    --
    --   APalNPC::OnCompletedInitParam(APalCharacter*)                        (Pal.hpp:10203)
    --     EVIDENCE CLASS: DECLARED ONLY. But it is the one bound on the PAL's own side, so it
    --     does not depend on anyone else having subscribed — and APalMonsterCharacter (:10167)
    --     inherits it without redeclaring, so the base UFunction is the one ProcessEvent runs
    --     and this hook sees every pal. `self` and a1 should be the same character here; a1 is
    --     preferred and self is the fallback.
    --
    -- The third, APalNPC::MasterWazaSetup(APalCharacter*) (:10205), is deliberately NOT armed:
    -- it has the same signature and is therefore the same broadcast, but its name says it
    -- exists to set up mastered moves, and a third hook on one moment buys nothing that the
    -- second does not.
    tryHookAfterWorldReady("/Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter",
        function(self, inCharacter)
            if not worldReady then return end
            pcall(function()
                emitSpawned(getv(inCharacter), "PalPlayerCharacter:OnCompleteInitializeParameter")
            end)
        end)

    tryHookAfterWorldReady("/Script/Pal.PalNPC:OnCompletedInitParam",
        function(self, inCharacter)
            if not worldReady then return end
            pcall(function()
                local who = getv(inCharacter)
                if not alive(who) then who = get(self) end
                emitSpawned(who, "PalNPC:OnCompletedInitParam")
            end)
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
--                bool IsAssignPassive, float LogDelay) — the signature the reference library
--                calls fully verified (__knowledges/palworld-ue4ss-functions.md:76-85,
--                "✅完全検証"), and param1 is a bare FName with no struct dig. Read the leading
--                params ONLY, and read them positionally: the live build rejected a call to
--                this function with "expected 6 parameters, received 4", so it declares two
--                more than that library and dumps/cxx/Pal.hpp:27053 list, and nothing here
--                knows what they are (that is settled now: the add takes five arguments and is
--                also why utils.items.give no longer CALLS this; it goes through the cheat
--                manager). A hook only reads what is handed to it, so the extra parameters cost
--                this source nothing. Its weakness is the mirror of the get-log's strength: the
--                first two params are certain, the FIRING for a player pickup is not — see 1.
--                Both are armed because they fail in opposite directions; neither is
--                authoritative enough to drop.
--             Silent internal adds that surface no get-log are covered only if they take
--             route 2; NEITHER is ever read as a craft. That distinction has not moved: a
--             crafted item still surfaces through the same get-log, so item.craft is sourced
--             from the production models below and never inferred from an obtain.
--   craft  -> the two MapObject models that finish a production WORK (see below).
--   discard-> the two player-initiated removals on PalNetworkItemComponent (see below).
local function installItemSource()
    -- getv / fstr / pstr are module-level (see the readers above tryHook).

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
            srcEmit("item.use", {
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
    -- `emitting` is a separate concern: an onObtain handler that gives an item can re-enter
    -- this hook. utils.items.give issues UPalCheatManager:GetItem rather than the add below,
    -- but a cheat that puts items in an inventory has every reason to end up in the same
    -- inventory add this source watches — unmeasured either way, and the guard costs nothing.
    -- Without it that recurses until the stack dies for any id the dedupe window does not cover.
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
            srcEmit("item.obtain", { itemId = id, count = count, via = via })
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

    -- obtain 2: the inventory add. a1 is a bare FName, a2 the count — read positionally, and
    -- only those two, because the leading pair is the part of this declaration that is not in
    -- doubt (the live build declares six parameters in total; see the header note). A NEGATIVE
    -- count would be a removal rather than an obtain, so it is skipped rather than reported as
    -- one — a cheap guard on a shape nothing in this tree has been seen to produce, since
    -- utils.items.take drops items through the cheat manager and never signs a count.
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

    -- =================================================================================
    -- item.craft — A PRODUCTION WORK FINISHED. Two hooks, and they are not a fallback
    -- chain: they are two DIFFERENT machines that produce items, on two different classes,
    -- and neither is consulted when the other misses.
    --
    -- WHAT THE DUMP SAID. dumps/cxx/Pal.hpp declares one function name on nine classes,
    -- always with the same single parameter — `void OnFinishWorkInServer(UPalWorkBase* Work)`
    -- — and it is a UFUNCTION bound to UPalWorkBase::OnFinishWorkInServerDelegate
    -- (Pal.hpp:32807), i.e. a dynamic multicast delegate. That matters more than the name:
    -- a dynamic delegate is broadcast through UObject::ProcessEvent, which is the path
    -- RegisterHook can see, so this is not a C++-internal call that a hook would sit behind
    -- silently. Two of those nine carry an item id and are the ones wired:
    --   * UPalMapObjectConvertItemModel (Pal.hpp:22631, hook at :22669) — the recipe benches
    --     and furnaces. `FName CurrentRecipeId` (:22641) is the recipe being made, and the
    --     recipe table is keyed BY PRODUCT ITEM ID: dumps/reflection/01_datatables.txt:54129+
    --     lists DT_ItemRecipeDataTable_Common's rows as Money / PalSphere / Arrow /
    --     RoughBullet / ..., which are item ids. So the recipe id IS the item id for a vanilla
    --     recipe, and it is handed over under both names so a pack need not rely on that.
    --   * UPalMapObjectProductItemModel (Pal.hpp:24327, hook at :24341) — the fixed-output
    --     producers. `FName ProductItemId` (:24333) names the item outright.
    -- Neither model exposes the COUNT: for the convert route the per-craft count lives in the
    -- recipe row's Product_Count (FPalItemRecipe, Pal.hpp), which is a DataTable read this
    -- source deliberately does not make inside a hook. ctx.count is nil, and that is honest
    -- rather than a 1 nobody measured.
    --
    -- EVIDENCE CLASS: DECLARED ONLY — the weakest of the three. Neither class is among the 21
    -- in dumps/reflection/02_reflection.txt, so the live build has not been asked whether it
    -- still carries them, and no craft-shaped hook has ever been armed in a recorded session.
    -- What makes wiring it right anyway is that the failure mode is silence, not noise: if
    -- the function is absent tryHook logs "hook unavailable" and the channel stays as empty as
    -- it is today, and if it fires it can only mean a production work completed. That is the
    -- opposite of the OnDamage trap that killed building.leftclick, where the candidate DID
    -- fire — 196 times, on a 12 s decay timer — and would have run every pack's handler.
    -- OBSERVED LIVE, 2026-07-26: "channel item.craft carried its first event this session".
    -- Crafting at a real machine reaches OnFinishWorkInServer on one of the two work models
    -- below and the channel carries it. The evidence class was DECLARED ONLY when this was
    -- wired — neither class is among the 21 in dumps/reflection/02_reflection.txt — and it is
    -- now a firing anyone can reproduce by crafting anything.
    -- STILL DECLARATIVE: ctx.count is nil. The count lives in the recipe row, and a hook is no
    -- place for a DataTable read.
    local function craftSource(path, field, via)
        tryHook(path, function(self, work)
            if not worldReady then return end
            pcall(function()
                local m = getv(self)
                if not (m and m.IsValid and m:IsValid()) then return end
                local id = fstr(m, field)
                if not id then return end
                srcEmit("item.craft", {
                    itemId   = id,
                    recipeId = id,       -- same value under the name the convert route calls it
                    count    = nil,      -- not on the model; see the note above
                    model    = m,
                    work     = getv(work),
                    via      = via,
                })
            end)
        end)
    end
    craftSource("/Script/Pal.PalMapObjectConvertItemModel:OnFinishWorkInServer",
        "CurrentRecipeId", "convert")
    craftSource("/Script/Pal.PalMapObjectProductItemModel:OnFinishWorkInServer",
        "ProductItemId", "product")

    -- =================================================================================
    -- item.discard — THE PLAYER THREW IT AWAY. Two hooks, both on the same component and
    -- both player-initiated, so there is nothing to dedupe between them.
    --
    -- WHAT THE DUMP SAID, and it overturns the standing hypothesis rather than confirming
    -- it. `UPalNetworkItemComponent` (dumps/cxx/Pal.hpp:25686) declares eight `_ToServer`
    -- RPCs, and two of them are exactly the two actions the old probe script asked a human
    -- to perform:
    --   RequestDrop_ToServer(TArray<FPalItemSlotIdAndNum> DropSlotAndNumArray,
    --                        FVector DropLocation, bool IsAutoPickup)     (Pal.hpp:25696)
    --   RequestDispose_ToServer(FGuid RequestID, FPalItemSlotIdAndNum SlotInfo) (:25697)
    -- So the answer to "is a drop an AddItem_ServerInternal with a negative Count" is NO, and
    -- it never could have been: dropping does not go through the inventory add at all, which
    -- is why that hook was armed successfully and fired zero times across both recorded
    -- sessions. The reason the search kept missing is that it was run against the wrong
    -- classes — PalPlayerInventoryData and PalItemContainer really do have no removal (this
    -- file's old note was right about that), because removal lives on a NETWORK component,
    -- one class over, beside RequestSwap / RequestMove / RequestMoveToContainer.
    --
    -- EVIDENCE CLASS: DECLARED ONLY for the two names — neither class is in 02_reflection.txt
    -- — but the SHAPE is proven. `_ToServer` is a UE RPC, always dispatched through
    -- ProcessEvent, and this file already runs two of them successfully: RequestBuild_ToServer
    -- drives the whole building runtime, and PalNetworkPlayerComponent's
    -- RequestUnlockTechnology_ToServer is recorded firing 3 times in 06_events.txt.
    --
    -- THE ONE WEAK LINK, stated plainly because it is where this will fail if it fails: the
    -- params carry SLOT IDS, not item ids. FPalItemSlotIdAndNum is { FPalItemSlotId SlotId;
    -- int32 Num } and FPalItemSlotId is { FPalContainerId ContainerId; int32 SlotIndex }
    -- (Pal.hpp:3922-3934) — so the id has to be read off the slot the request points at,
    -- BEFORE the server empties it, which is why this is a pre-hook. slotItemId below does
    -- that walk and every step of it is unobserved on this build. When it cannot resolve, the
    -- source emits NOTHING rather than an event with a guessed id, and says so once.
    -- OBSERVED LIVE, 2026-07-26: "channel item.discard carried its first event this session",
    -- with no resolution warning, so the slot really did resolve to an item id.
    -- Two things had to be right and only the first was obvious. A drop does NOT go through
    -- AddItem_ServerInternal — that hook was armed and fired zero times across two sessions
    -- because dropping goes through UPalNetworkItemComponent, one class over. And the container
    -- holding the dropped slot is NOT necessarily one of the player inventory helper's: the
    -- first live firing reported "no container of the player's 6 matched", so the set comes from
    -- FindAllOf now. The GUID match is exact, which is what makes the wider search safe.

    ---FGuid equality, field-wise. Neither UE4SS nor this tree has a comparison operator for a
    ---struct param, so the four int32s are read individually; a read that comes back nil makes
    ---this false rather than accidentally-equal (two unreadable guids must not match).
    local function guidEq(a, b)
        local ok, eq = pcall(function()
            if a == nil or b == nil or a.A == nil or b.A == nil then return false end
            return a.A == b.A and a.B == b.B and a.C == b.C and a.D == b.D
        end)
        return ok and eq == true
    end

    ---Every live UPalItemContainer, as a plain list.
    ---
    ---THIS USED TO ASK THE PLAYER'S INVENTORY HELPER, and the first live drop is what showed
    ---that is too narrow: "no container of the player's 6 matched the dropped slot's id". Six
    ---containers listed, none of them the one the item came out of. A Palworld player has more
    ---containers than InventoryMultiHelper carries — the inventory data also reaches them by
    ---TYPE (TryGetContainerFromInventoryType, TryGetEquipmentContainerIDFromStaticItemID) — and
    ---a drop can come from any of them.
    ---
    ---So ask the world instead. The match is on an exact GUID, so a wider search cannot produce
    ---a WRONG answer, only a right one or none — which is the property that makes widening safe
    ---here and would not make it safe anywhere the match were fuzzy.
    local function allContainers()
        local out = {}
        pcall(function()
            local list = FindAllOf("PalItemContainer")
            if type(list) ~= "table" then return end
            for i = 1, #list do
                local c = list[i]
                local ok, live = pcall(function() return c.IsValid and c:IsValid() end)
                if ok and live then out[#out + 1] = c end
            end
        end)
        return out
    end

    ---Resolve one FPalItemSlotId to the item id sitting in it right now.
    ---
    ---Returns the id, or nil plus WHICH STEP FAILED. That second return is not decoration: the
    ---first live firing of this hook reported "the slot could not be resolved" and named none of
    ---the five things that could have gone wrong, which is the exact shape of diagnostic that has
    ---cost this project a run at a time all day. Every member name below is verified against
    ---dumps/cxx/Pal.hpp — FPalItemSlotId{ContainerId,SlotIndex}, FPalContainerId{ID},
    ---UPalContainerBase{ID}, UPalItemContainerMultiHelper{Containers} — so a failure here is a
    ---live-state fact, not a typo, and the message has to say which one.
    ---@return string? id, string? failedStep
    local function slotItemId(slotId)
        local wanted, index
        pcall(function() wanted = slotId.ContainerId.ID end)   -- FPalContainerId wraps one FGuid
        pcall(function() index = slotId.SlotIndex end)
        if wanted == nil then return nil, "slotId.ContainerId.ID unreadable" end
        if type(index) ~= "number" then
            return nil, "slotId.SlotIndex is " .. type(index) .. ", not a number"
        end

        local containers = allContainers()
        if #containers == 0 then
            return nil, "FindAllOf('PalItemContainer') listed none"
        end
        for _, c in ipairs(containers) do
            local cid; pcall(function() cid = c.ID.ID end)
            if guidEq(cid, wanted) then
                local slot; pcall(function() slot = c:Get(index) end)
                if slot == nil then
                    return nil, string.format("container matched but Get(%d) answered nil", index)
                end
                local id; pcall(function() id = slot.ItemId.StaticId:ToString() end)
                if id == nil then return nil, "slot.ItemId.StaticId unreadable" end
                if id == "" or id == "None" then
                    -- The likeliest cause, and worth naming rather than lumping in with a
                    -- failure: this is a PRE hook, but the client may already have cleared the
                    -- slot locally before the server RPC is sent. If that is what this is, the
                    -- id has to come from somewhere other than the slot.
                    return nil, string.format("slot %d in the matched container is already empty "
                        .. "(id %q) — the slot may be cleared before the RPC is sent", index, id)
                end
                return id
            end
        end
        return nil, string.format("none of the %d live containers matched the dropped slot's id "
            .. "— the container may not exist as a UObject at the moment the RPC is sent",
            #containers)
    end

    -- One line per session, not per drop: an unresolvable slot is a standing fact about the
    -- build, and repeating it every time the player cleans out a bag would be noise.
    -- One line per distinct REASON, not one per session and not one per drop. The first live
    -- firing logged its miss, and a second drop that failed differently would have been silent
    -- behind it — which is how a single flag turns two findings into one.
    local discardMissSeen = {}
    local function emitDiscard(entry, reason)
        local slotId, num
        pcall(function() slotId = entry.SlotId end)
        pcall(function() num = entry.Num end)
        if slotId == nil then return end
        local id, why = slotItemId(slotId)
        if not id then
            local key = tostring(why or "the slot could not be resolved")
            if not discardMissSeen[key] then
                discardMissSeen[key] = true
                log.warn("item.discard: " .. key .. " — the channel stays silent for this "
                    .. "kind of drop — the channel is otherwise live")
            end
            return
        end
        srcEmit("item.discard", { itemId = id, count = tonumber(num), reason = reason })
    end

    -- drop: an ARRAY of slots, so one emit per entry. The Num on the entry is what is leaving
    -- the bag, which is the number a handler wants — not the slot's whole stack.
    tryHook("/Script/Pal.PalNetworkItemComponent:RequestDrop_ToServer", function(self, slots)
        if not worldReady then return end
        pcall(function() eachArray(getv(slots), function(e) emitDiscard(e, "drop") end) end)
    end)

    -- dispose: trashing one stack from the inventory menu. a1 is the request guid, a2 the slot.
    tryHook("/Script/Pal.PalNetworkItemComponent:RequestDispose_ToServer", function(self, _reqId, slotInfo)
        if not worldReady then return end
        pcall(function() emitDiscard(getv(slotInfo), "dispose") end)
    end)
end

-- =====================================================================================
-- SOURCE skill — the four channels behind Skill.Spec.Events. Until 2026-07-26 there was
-- no skill channel in this file at all; api/skill's handlers only ever ran from
-- Handle:activate / :hit / :equip / :unequip.
--
-- The two combat sources are both BlueprintFunctionLibrary statics on /Script/Pal.PalUtility,
-- which is the strongest class this file could have landed on: PalUtility is one of the 21
-- classes reflected out of the LIVE build (dumps/reflection/02_reflection.txt:2049), both
-- names appear in that listing, and its sibling library PalSoundUtility is recorded firing
-- 286 times in one session (06_events.txt) — so a static on one of these libraries is
-- something the shipping game demonstrably calls through reflection.
--
--   activate -> UPalUtility::PlayActionByWazaID(AActor* actionActor, AActor* TargetActor,
--               EPalWazaID WazaID)                                      (Pal.hpp:32037)
--               Three scalar-ish parameters, and every one of them is a thing this channel
--               needs: who acted, what they aimed at, and WHICH MOVE. That last one is the
--               identity no other candidate carried — PalPlayerController:PlaySkill was
--               armed twice and never fired, and the action-component routes (PlayAction,
--               PlayActionByType) carry a UClass rather than a waza id.
--   hit      -> UPalUtility::MakeDamageInfoByWazaType(Attacker, Defencer, AttackerHitComponent,
--               DefenderHitComponent, HitLocation, FoliageIndex, EPalWazaID WazaType, ...)
--                                                                       (Pal.hpp:32046)
--               The seventh parameter is the waza and the second is the victim.
--
-- AND HERE IS WHY IT IS THIS FUNCTION AND NOT THE DAMAGE HOOK — the dump closed the route
-- this channel had been waiting on. OnDamageReaction's single parameter is
-- `FPalDamageRactionInfo` (Pal.hpp:1885), whose COMPLETE field list is IsBlow, BlowVelocity,
-- IsLeanBackAnime, IsStan, IsLargeDown, HitLocation. No skill, no waza, no attacker. And the
-- fallback everyone assumed would carry it, `FPalDamageInfo` (:1834), has 40 fields and still
-- no EPalWazaID — the closest are `EPalWazaCategory Category` (a Melee/Shot bucket, not an
-- identity) and `FName AttackStaticItemID` (the weapon). So the victim side cannot answer
-- "which skill" on this build at all, at any depth of struct walking, and the attacker side
-- is the only side that can. That is a settled negative, not an untried idea.
--
-- EVIDENCE CLASS: REFLECTED (the live build declares both names) + DECLARED (the header dump
-- gives both signatures). Wiring them cannot misfire — PlayActionByWazaID with a waza id is a
-- move being played by definition — so silence is the only failure mode.
--
-- AND SILENCE IS WHAT THEY PRODUCED. MEASURED 2026-07-26, in a real save: both registered
-- (UE4SS logged `Registered native hook (29, 30)` and `(31, 32)`), a pal fought and killed
-- another pal, pal.damaged and pal.death both carried events and announced themselves, and
-- NEITHER skill channel carried anything. Ten other channels announced in the same session.
-- So these two are Blueprint-facing helpers that the shipping C++ combat path walks past.
-- They stay armed — UE4SS cannot unregister a hook, and a helper that is silent costs
-- nothing — but they are no longer the only source on either channel.
--
-- WHAT THE DUMP SAYS THE COMBAT PATH ACTUALLY IS, read 2026-07-26 out of dumps/cxx/Pal.hpp
-- by reading the classes whole rather than grepping for guessed names:
--
--   A pal's move is an ACTION OBJECT, and the waza id is a field ON that object.
--   UPalActionWazaBase (Pal.hpp:13270) is `public UPalActionBase` and adds exactly one thing
--   that matters here: `EPalWazaID WazaID` at 0x0158 (:13272), with `GetWazaID()` beside it
--   (:13279). Which action class belongs to which move is a per-pal table:
--   UPalStaticCharacterParameterComponent::WazaActionInstancedMap is
--   `TMap<EPalWazaID, TSubclassOf<UPalActionBase>>` (:29469). The AI picks the slot
--   (UPalAIActionCombatBase::NextIsWaza / NextWazaSlotIndex, :12637-12638), the action
--   component instantiates and plays the class (UPalActionComponent::PlayAction_Internal /
--   PlayAction_ToALL, :13171-13173), and the played object gets OnBeginAction() (:13122).
--   So `self.WazaID` on a live action IS the move's identity, with no lookup and no struct
--   walk — and UPalActionBase carries GetActionCharacter() (:13141) and GetActionTarget()
--   (:13138) for the other two things this channel needs.
--
-- SO TWO MORE ACTIVATE SOURCES ARE ARMED ALONGSIDE PlayActionByWazaID. Both are guarded on a
-- readable, named EPalWazaID, so a non-waza action (jump, roll, eat, build) emits nothing:
-- the failure mode of each is silence, never a wrong event.
--
--   activate (2) -> /Script/Pal.PalActionBase:OnBeginAction  (Pal.hpp:13122)
--        `self` is the action object itself, so this is the shortest possible route to the
--        identity. EVIDENCE CLASS: DECLARED ONLY — UPalActionBase is not among the 21 classes
--        in 02_reflection.txt and has never been armed. THE ONE WAY IT FAILS, stated plainly:
--        OnBeginAction reads like a Blueprint event, and Palworld's waza actions are BP
--        classes. If a BP subclass implements it, that subclass owns its own UFunction, and
--        ProcessEvent runs THAT one — a hook on the base would sit behind it forever. This is
--        the same "is the call site reachable" doubt as pal.spawned, and it resolves the same
--        way: by arming it and looking.
--
--   activate (3) -> /Script/Pal.PalPlayerCharacter:OnBeginAction(const UPalActionBase* action)
--        (Pal.hpp:10651). A DELEGATE TARGET of UPalActionComponent::OnActionBeginDelegate
--        (:13158-13159, signature ActionStartDelegate__DelegateSignature at :13194) — the one
--        evidence class in this file that has never yet failed, because a dynamic delegate is
--        always broadcast through ProcessEvent. EVIDENCE CLASS: REFLECTED + DECLARED — the
--        name `.OnBeginAction` is in the live build's own PalPlayerCharacter listing
--        (02_reflection.txt, the block at :738). ITS LIMIT, and it is a real one: `self` is
--        the PLAYER, so it is bound to the PLAYER's action component. It covers the player's
--        own waza actions (a partner skill, a summoned-weapon move) and NOT a pal's, which
--        run on the pal's own component with a different set of listeners. It is armed
--        because a narrow source that fires beats a broad one that does not.
--
--   hit (2) -> /Script/Pal.PalAnimNotifyState_AttackCollision:OnHit(UPrimitiveComponent*
--        MyHitComponent, AActor* HitActor, UPrimitiveComponent* HitComponent,
--        const TArray<int32>& FoliageIndex, FVector HitLocation, int32 HitCount)
--        (Pal.hpp:13576). This is the melee/collision attack window itself: the notify state
--        holds `UPalHitFilter* AttackFilter` (:13571), the filter for an attack is a
--        UPalAttackFilter which carries `EPalWazaID Waza` (:14069) and `AActor* Attacker`
--        (:14077), and this OnHit is a DELEGATE TARGET — its parameter list matches
--        UPalHitFilter::OnHitDelegate's signature (:20614) field for field. That matters
--        twice over: it means ProcessEvent, and it means the hit already PASSED the filter
--        (MaxHitNum, HitInterval, the intersection test), so this is a landed hit rather than
--        a raw overlap. EVIDENCE CLASS: DECLARED ONLY. Its limit: it is the COLLISION path.
--        A projectile move lands through APalBullet instead (:8849), whose fields carry
--        OwnerStaticItemId and no waza at all — so a ranged pal move is still uncovered by
--        this hook, and by every other one in the dump.
--
-- TODO(skill-activate-source): NARROWED, not closed. PlayActionByWazaID is MEASURED SILENT in
-- combat, so it is no longer a candidate — it is a ruled-out one kept armed for free. What is
-- unmeasured is whether either replacement is reachable: PalActionBase:OnBeginAction (does the
-- base UFunction run, or does a BP override take the ProcessEvent) and
-- PalPlayerCharacter:OnBeginAction (fires, but only for the player). If BOTH stay silent while
-- a pal visibly attacks, the remaining lead in the dump is UPalActionComponent's
-- PlayAction_ToALL (:13171) — a NetMulticast RPC, the shape that has never failed here — but
-- it hands over `TSubclassOf<UPalActionBase>` rather than an id, so it would need the class ->
-- waza direction of WazaActionInstancedMap (:29469) resolved first, and nothing in this tree
-- has read a TMap keyed by an enum yet.
-- TODO(skill-hit-source): NARROWED. MakeDamageInfoByWazaType is MEASURED SILENT while
-- pal.damaged fired in the same fight, so damage is not built through that helper. The
-- collision-notify route above replaces it for melee. What stays open is the PROJECTILE half:
-- no class in dumps/cxx carries both a bullet and an EPalWazaID, so if a ranged move must
-- report hits, the id has to come from the ACTION that spawned the bullet
-- (UPalActionWazaBase.WazaID) and be carried forward — which needs skill.activate to work
-- first. Do NOT go back to the damage structs: FPalDamageInfo (:1834, 40 fields) and
-- FPalDamageResult (:1896, 12 fields) both have no EPalWazaID, and that is settled.
--
-- The passive pair writes to a character rather than to the world:
--   equip   -> UPalIndividualCharacterParameter::AddPassiveSkill(FName AddSkill,
--              FName OverrideSkill)                                     (Pal.hpp:21155)
--   unequip -> UPalIndividualCharacterParameter::RemovePassiveSkill(FName SkillId)   (:21003)
-- EVIDENCE CLASS: REFLECTED + DECLARED, and stronger than the combat pair on the reflected
-- half — PalIndividualCharacterParameter is reflected in full in 02_reflection.txt:1107 and
-- both names are in that listing. The open question the TODO used to carry ("passive row FName
-- vs an index into a fixed-size array") is ANSWERED: both take FNames, one for remove and two
-- for add, and no struct is involved. The OWNER comes off the same object as the property
-- `APalCharacter* IndividualActor` (:20910), so nothing has to be searched for.
--
-- `OverrideSkill` is handed through as ctx.overrides and is NOT read as an unequip. The name
-- does not say which of the two ids is being displaced, and inventing an unequip out of an
-- ambiguous parameter is the kind of wiring this file refuses on principle.
--
-- AND THAT PAIR IS ALSO MEASURED SILENT. Same session, 2026-07-26: both registered (UE4SS
-- logged hooks 35-38), pals were caught and released, and neither channel carried anything.
-- So the passive list is not maintained one name at a time through those two — or at least
-- not through a call site RegisterHook can see.
--
--   equip/unequip (2) -> /Script/Pal.PalPassiveSkillComponent:SetupSkillFromSelf(
--        UObject* OwnerObject, const TArray<FName>& skillList)              (Pal.hpp:26582)
--        The dump's answer to "then how DOES a passive get attached": wholesale, as a LIST,
--        by the component that owns passive effects. UPalPassiveSkillComponent (:26565) is
--        the thing that actually applies them — it holds `TArray<FPalPassiveSkillEffectInfos>
--        SkillInfos` (:26573), broadcasts OnStartSkillEffect / OnEndSkillEffect (:26567-26572)
--        and rewrites damage through OverrideDamageInfoBySkill (:26584). SetupSkillFromSelf is
--        how the names get in.
--        BECAUSE IT IS A LIST AND NOT AN EVENT, this source DIFFS: the names it has last seen
--        for that component are remembered in a weak table, a name that is new emits
--        skill.equip and a name that has gone emits skill.unequip. Stated plainly, because it
--        is the cost of the only route the dump offers: the FIRST call for a component emits
--        equip for every passive that character already has. A pal streaming into the world
--        will therefore announce its four passives once. That is honest — at that moment those
--        passives really are being attached to that character — but it is not the same thing
--        as "the player just added one", and a handler must be idempotent for it.
--        EVIDENCE CLASS: DECLARED ONLY. Armed after world.ready like the pair above.
--
-- TODO(skill-passive-source): NARROWED. AddPassiveSkill / RemovePassiveSkill are MEASURED
-- SILENT across a session of catching and releasing pals, so they are ruled out as the route
-- (kept armed, since they cost nothing and cannot misfire). What is unmeasured is whether
-- SetupSkillFromSelf fires, and if it does, WHICH moments it covers — the expectation is
-- character init, capture-time assignment, and the Statue of Power, and none of the three is
-- observed. If it too is silent, the remaining lead is
-- UPalMapObjectOperatingTableModel:RequestChangePassiveSkill (Pal.hpp:24094), the bench's own
-- request, which takes the passive FName as its third parameter and is an ordinary server
-- request rather than a broadcast — narrower (the bench only), but reachable.
-- =====================================================================================
local function installSkillSource()
    -- EPalWazaID arrives as a bare integer (core/character.lua:449 documents that enum
    -- elements come through as numbers), and every public surface in this tree speaks skill
    -- NAMES, so the one shared table is inverted once, lazily.
    local nameOfWaza
    ---An EPalWazaID as a number, whether it arrived as one or inside a wrapper. A hook PARAM
    ---is an int; a PROPERTY read off a live object (UPalActionWazaBase.WazaID,
    ---UPalAttackFilter.Waza) may come back wrapped, and the two new activate sources read
    ---properties rather than params.
    local function wazaNum(v)
        if v == nil then return nil end
        local n = tonumber(v)
        if n then return n end
        local inner; pcall(function() inner = v:get() end)
        return tonumber(inner)
    end
    local function wazaName(v)
        local n = wazaNum(v)
        if not n then return nil end
        if not nameOfWaza then
            nameOfWaza = {}
            for k, id in pairs(character.WAZA) do nameOfWaza[id] = k end
        end
        return nameOfWaza[n]     -- EPalWazaID::None is 0 and is absent from the table, so a
                                 -- non-waza action drops out here rather than being emitted
    end

    -- THREE sources feed skill.activate, TWO feed skill.hit and TWO feed each of the passive
    -- pair, and several of them can legitimately describe the SAME moment: an action begins on
    -- the player's component AND on the action object; a passive is added by name AND appears
    -- in the next whole-list setup. A repeat of the same skill id inside this window is
    -- dropped, exactly as the two item.obtain sources are deduped and for the same reason.
    --
    -- Keyed on (channel, id) ONLY, never on the owner. The cost is stated rather than hidden:
    -- two pals using the same move, or two pals streaming in with the same passive, within a
    -- quarter second are reported once. That is shorter than any attack animation and cheaper
    -- than letting a duplicate run every pack's handler twice. The table is bounded by the
    -- number of distinct skill ids the session has seen, so it cannot grow without limit the
    -- way an owner-keyed one would.
    local SKILL_DEDUPE_SEC = 0.25
    local lastSkill = {}
    local function emitSkill(channel, id, ctx, via)
        local now = os.clock()
        local k = channel .. "\0" .. id
        if lastSkill[k] and (now - lastSkill[k]) < SKILL_DEDUPE_SEC then return end
        lastSkill[k] = now
        ctx.via = via
        announceVia(channel, via)
        srcEmit(channel, ctx)
    end

    -- activate. ctx.owner is the actor that played the move (what onActivate is handed as its
    -- second argument); ctx.target is what it was aimed at, which may be nil for a move with
    -- no target.
    --
    -- SOURCE 1 — MEASURED SILENT in real combat (see the header). Kept armed because UE4SS
    -- cannot unregister and a silent helper costs nothing; if it ever does fire, the via line
    -- says so and this comment is wrong rather than the wiring.
    tryHook("/Script/Pal.PalUtility:PlayActionByWazaID", function(self, actionActor, targetActor, wazaID)
        if not worldReady then return end
        pcall(function()
            local id = wazaName(getv(wazaID))
            if not id then return end
            emitSkill("skill.activate", id, {
                skillId = id,
                wazaId  = wazaNum(getv(wazaID)),
                owner   = getv(actionActor),
                actor   = getv(actionActor),   -- same value under the name the pal channels use
                target  = getv(targetActor),
            }, "PlayActionByWazaID")
        end)
    end)

    ---SOURCES 2 and 3 share this: given a live UPalActionBase, emit skill.activate IF it is a
    ---waza action. `WazaID` exists only on UPalActionWazaBase (Pal.hpp:13272), so reading it
    ---off a jump or an eat action answers nil and nothing is emitted — which is what makes
    ---arming a hook this broad safe. GetActionCharacter / GetActionTarget (Pal.hpp:13141,
    ---:13138) are declared on the BASE, so they are available whatever the subclass is.
    local function emitFromAction(action, via)
        if not alive(action) then return end
        local raw; pcall(function() raw = action.WazaID end)
        local n = wazaNum(raw)
        if not n then return end
        local id = wazaName(n)
        if not id then return end
        local owner;  pcall(function() owner = action:GetActionCharacter() end)
        local target; pcall(function() target = action:GetActionTarget() end)
        if not alive(owner) then owner = nil end
        if not alive(target) then target = nil end
        emitSkill("skill.activate", id, {
            skillId = id,
            wazaId  = n,
            owner   = owner,
            actor   = owner,
            target  = target,
            action  = action,      -- the UPalActionWazaBase itself, for a pack that wants more
        }, via)
    end

    -- SOURCE 2 — the action object announcing its own start. `self` IS the move.
    tryHook("/Script/Pal.PalActionBase:OnBeginAction", function(self)
        if not worldReady then return end
        pcall(function() emitFromAction(getv(self), "PalActionBase:OnBeginAction") end)
    end)

    -- SOURCE 3 — the PLAYER's action component announcing a start to its listener. a1 is the
    -- action; `self` is the player and is deliberately NOT used as the owner, because the
    -- action's own GetActionCharacter is the authority (a summoned weapon's action is played
    -- on the weapon, not on the player).
    tryHook("/Script/Pal.PalPlayerCharacter:OnBeginAction", function(self, action)
        if not worldReady then return end
        pcall(function() emitFromAction(getv(action), "PalPlayerCharacter:OnBeginAction") end)
    end)

    -- hit. The waza is the SEVENTH parameter, so this is the one hook in the file that reads
    -- past a4; UE4SS hands every declared parameter to the callback, and a build that hands
    -- over fewer simply leaves wazaType nil and the guard below drops the event.
    -- SOURCE 1 — MEASURED SILENT while pal.damaged fired in the same fight. Kept armed.
    tryHook("/Script/Pal.PalUtility:MakeDamageInfoByWazaType",
        function(self, attacker, defender, _aHit, _dHit, hitLocation, _foliage, wazaType)
            if not worldReady then return end
            pcall(function()
                local id = wazaName(getv(wazaType))
                if not id then return end
                emitSkill("skill.hit", id, {
                    skillId  = id,
                    wazaId   = wazaNum(getv(wazaType)),
                    target   = getv(defender),     -- onHit's second argument
                    owner    = getv(attacker),
                    attacker = getv(attacker),
                    location = getv(hitLocation),
                }, "MakeDamageInfoByWazaType")
            end)
        end)

    -- SOURCE 2 — the attack-collision anim notify, after its hit filter accepted the overlap.
    -- The identity is on the FILTER, not on any parameter: UPalAttackFilter.Waza (Pal.hpp:14069)
    -- and .Attacker (:14077). a2 is the victim and a5 the hit location. The `AttackFilter`
    -- property is typed UPalHitFilter, so a notify whose filter is a plain hit filter has no
    -- .Waza and drops out — same guard, same silence-not-noise failure mode as the activate pair.
    tryHook("/Script/Pal.PalAnimNotifyState_AttackCollision:OnHit",
        function(self, _myComp, hitActor, _hitComp, _foliage, hitLocation)
            if not worldReady then return end
            pcall(function()
                local notify = getv(self)
                if not alive(notify) then return end
                local filter; pcall(function() filter = notify.AttackFilter end)
                if not alive(filter) then return end
                local raw; pcall(function() raw = filter.Waza end)
                local id = wazaName(raw)
                if not id then return end
                local attacker; pcall(function() attacker = filter.Attacker end)
                if not alive(attacker) then attacker = nil end
                local target = getv(hitActor)
                if not alive(target) then target = nil end
                emitSkill("skill.hit", id, {
                    skillId  = id,
                    wazaId   = wazaNum(raw),
                    target   = target,             -- onHit's second argument
                    owner    = attacker,
                    attacker = attacker,
                    location = getv(hitLocation),
                    filter   = filter,
                }, "PalAnimNotifyState_AttackCollision:OnHit")
            end)
        end)

    -- equip / unequip. ARMED AFTER world.ready, for the same reason as pal.spawned above and
    -- building.build: these sit on a character's parameter object, and reading one of those
    -- while the world-load storm is still initialising them is the exact shape that produced a
    -- native access violation once already. Combat cannot happen during the storm, so the two
    -- hooks above do not need this and are armed at start().
    local function ownerOf(self)
        local p = getv(self)
        if not (p and p.IsValid and p:IsValid()) then return nil, nil end
        local actor; pcall(function() actor = p.IndividualActor end)
        if actor ~= nil and not pcall(function() return actor:IsValid() end) then actor = nil end
        return actor, p
    end

    -- SOURCE 1 — MEASURED SILENT across a session of catching and releasing pals. Kept armed.
    tryHookAfterWorldReady("/Script/Pal.PalIndividualCharacterParameter:AddPassiveSkill",
        function(self, addSkill, overrideSkill)
            if not worldReady then return end
            pcall(function()
                local id = pstr(addSkill)
                if not id then return end
                local actor, params = ownerOf(self)
                emitSkill("skill.equip", id, {
                    skillId   = id,
                    owner     = actor,
                    actor     = actor,
                    params    = params,
                    overrides = pstr(overrideSkill),   -- see the note above: NOT an unequip
                }, "AddPassiveSkill")
            end)
        end)

    tryHookAfterWorldReady("/Script/Pal.PalIndividualCharacterParameter:RemovePassiveSkill",
        function(self, skillId)
            if not worldReady then return end
            pcall(function()
                local id = pstr(skillId)
                if not id then return end
                local actor, params = ownerOf(self)
                emitSkill("skill.unequip", id,
                    { skillId = id, owner = actor, actor = actor, params = params },
                    "RemovePassiveSkill")
            end)
        end)

    -- SOURCE 2 — the passive-effect component being handed the whole list. See the header for
    -- why this is a DIFF and what that costs.
    --
    -- The remembered set is keyed by objKey's stable string for the COMPONENT, never by the
    -- component wrapper — a wrapper is rebuilt on every hook call and a table keyed on one
    -- would see every setup as a first setup and report the whole list as equips every time.
    -- A component genuinely seen for the first time DOES have an empty previous set, and that
    -- is exactly why its whole list surfaces as equips once; see the header.
    --
    -- Bounded for the same reason as the spawn table: string keys are never released by the
    -- garbage collector on their own. At the cap the whole table is dropped, which costs one
    -- repeat of the first-call behaviour for the components seen after it.
    local PASSIVE_KEYS_MAX = 2048
    local passiveSeen, passiveSeenN = {}, 0

    ---One TArray<FName> element as a plain string. The array reader hands elements over
    ---UNWRAPPED-BY-DESIGN (see eachArray), so both shapes are tried: a bare FName with
    ---ToString, and UE4SS's wrapper with the FName behind :get(). core/character.lua's
    ---readList found the same two shapes on GetEquipWaza and is the reason this is not
    ---assumed away.
    local function nameOf(v)
        if v == nil then return nil end
        local s
        if type(v) == "userdata" and v.ToString then pcall(function() s = v:ToString() end) end
        if s == nil then
            local inner; pcall(function() inner = v:get() end)
            if inner ~= nil then
                if type(inner) == "userdata" and inner.ToString then
                    pcall(function() s = inner:ToString() end)
                else
                    s = tostring(inner)
                end
            end
        end
        if s == nil or s == "" or s == "None" then return nil end
        return s
    end

    tryHookAfterWorldReady("/Script/Pal.PalPassiveSkillComponent:SetupSkillFromSelf",
        function(self, ownerObject, skillList)
            if not worldReady then return end
            pcall(function()
                local comp = getv(self)
                if not alive(comp) then return end
                local key = objKey(comp)
                if not key then return end   -- no stable identity => no honest diff => no event

                local now = {}
                eachArray(getv(skillList), function(v)
                    local n = nameOf(v)
                    if n then now[n] = true end
                end)

                local prev = passiveSeen[key] or {}
                if passiveSeenN >= PASSIVE_KEYS_MAX then passiveSeen, passiveSeenN = {}, 0 end
                if passiveSeen[key] == nil then passiveSeenN = passiveSeenN + 1 end
                passiveSeen[key] = now

                -- The OWNER. The component's actor is what a handler wants (a character), and
                -- OwnerObject is what the game passed — which need not be an actor at all,
                -- since equipment carries passives too. Prefer the actor, fall back to the
                -- argument, and hand BOTH over so a pack can tell an equipment passive from a
                -- character one.
                local actor; pcall(function() actor = comp:GetOwner() end)
                if not alive(actor) then actor = nil end
                local src = getv(ownerObject)
                local who = actor or (alive(src) and src or nil)

                for name in pairs(now) do
                    if not prev[name] then
                        emitSkill("skill.equip", name, {
                            skillId = name, owner = who, actor = who,
                            component = comp, source = src,
                        }, "SetupSkillFromSelf")
                    end
                end
                for name in pairs(prev) do
                    if not now[name] then
                        emitSkill("skill.unequip", name, {
                            skillId = name, owner = who, actor = who,
                            component = comp, source = src,
                        }, "SetupSkillFromSelf")
                    end
                end
            end)
        end)
end

-- =====================================================================================
-- DISPATCH — channel -> the object's lifecycle hook. resolve() maps a ctx to whatever
-- stands behind it: the tracked INSTANCE for buildings, the definition CLASS for pals,
-- items, skills, and building.build (which fires before any instance exists).
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

-- Resolve the PalForge Skill CLASS behind a skill ctx. Same shape as items: skills have no
-- per-instance tracking, the ctx carries the game skill id (ctx.skillId — an EPalWazaID NAME
-- like "FireBlast" for the two combat channels, a passive row FName like "Legend" for the two
-- passive ones), and the definition registered for it acts as `self`. Note that only a skill
-- DEFINED with Skill{ ... } is registered: Skill.get("X") on an id nobody defined hands back a
-- thin handle that was never put in the catalog, so dispatch no-ops for it — which is the same
-- rule pals and items follow and the reason a vanilla move fires nothing.
local function resolveSkillClass(ctx)
    if type(ctx) ~= "table" or not ctx.skillId then return nil end
    local cls = object_manager.get("skill", ctx.skillId)
    if cls then return cls end
    -- namespaced skills: a registered "pack:name" whose resolved fname == the game id.
    for regId, c in pairs(object_manager.all("skill")) do
        local okR, r = pcall(object_manager.resolve, regId)
        if okR and r == ctx.skillId then return c end
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
    if otype == "skill" then return resolveSkillClass(ctx) end
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

-- Skill hooks take THREE arguments, not two: api/skill declares them as
-- onActivate(self, owner, ctx) / onHit(self, target, ctx) / onEquip(self, owner, ctx), because
-- a skill's subject is the character it acted on rather than the skill itself. call() above
-- passes (self, ctx) and cannot serve them without silently shifting every handler's arguments
-- by one, so the skill channels get their own dispatcher rather than a widened shared one.
-- Same resolve table, same pcall-and-LOG discipline.
local function callSkill(hook, subject, ctx, channel)
    local cls = resolve("skill", ctx)
    if cls and type(cls[hook]) == "function" then
        local ok, e = pcall(function() cls[hook](cls, subject, ctx) end)
        if not ok then
            log.err(string.format("%s -> %s handler failed: %s", tostring(channel), hook, tostring(e)))
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
    -- item (resolve -> the defined Item CLASS by ctx.itemId, exact or namespaced). All four
    -- have a native source now; craft and discard are the two whose sources are wired from
    -- the header dump and not yet seen firing in game.
    on("item.obtain",  function(ctx) call("item", "onObtain", ctx, "item.obtain") end)
    on("item.use",     function(ctx) call("item", "onUse", ctx, "item.use") end)
    on("item.craft",   function(ctx) call("item", "onCraft", ctx, "item.craft") end)
    on("item.discard", function(ctx) call("item", "onDiscard", ctx, "item.discard") end)
    -- skill (resolve -> the defined Skill CLASS by ctx.skillId; three-argument handlers, so
    -- callSkill rather than call — see the note on it). The subject differs per channel:
    -- onHit is handed the TARGET, the other three the owner.
    on("skill.activate", function(ctx) callSkill("onActivate", ctx and ctx.owner, ctx, "skill.activate") end)
    on("skill.hit",      function(ctx) callSkill("onHit", ctx and ctx.target, ctx, "skill.hit") end)
    on("skill.equip",    function(ctx) callSkill("onEquip", ctx and ctx.owner, ctx, "skill.equip") end)
    on("skill.unequip",  function(ctx) callSkill("onUnequip", ctx and ctx.owner, ctx, "skill.unequip") end)
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
    installPalSource();  installItemSource(); installSkillSource()
    -- dispatch (channel -> object hook)
    installDispatch()
    reload.markArmed()
    log.info("event wired: bus + sources (tick/world/building/pal/item/skill; onBuild, the "
        .. "three onSpawned candidates and the three passive ones arm at world.ready; "
        .. "skill.activate has three sources and skill.hit two, and the log says which one "
        .. "carried it; building.leftclick and building.break have no native source and never "
        .. "will) + dispatch")
end

return M
