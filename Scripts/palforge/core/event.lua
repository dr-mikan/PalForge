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
-- The PAL source arms six native hooks plus a slow onTick sweep, the ITEM source seven, and
-- the SKILL source eight. (The item count read "six" here for as long as craft was one hook;
-- it is seven now — use, get-log, inventory add, the two OnFinishWorkInServer craft models,
-- drop and dispose. Counted from the tryHook calls in installItemSource, not from memory.) Most were found in dumps/cxx/Pal.hpp — UE4SS's own CXXHeaderDump
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
-- ONE OF THOSE FOUR HAS SINCE CARRIED, which is the whole argument for keeping a silent hook
-- armed rather than deleting it. AddPassiveSkill fired later in that same day and closed
-- skill-passive-source: what made it carry was a WRITE — core.character.addSkill putting a
-- passive on a live pal — so the earlier silence was a fact about the game's own bench and
-- party writes, not about the hook. See installSkillSource's SOURCE 1 for the detail. The other
-- three of the four are still silent, and each says so at its own hook.
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
-- ==== FOUR RULES THIS FILE IS BUILT ON. Each one was a defect first. ====================
--
-- 1. NOTHING PER-ACTOR IS KEYED ON A HANDLE. UE4SS mints a fresh userdata wrapper per
--    lookup, so `t[actor]` written in one scan is not `t[actor]` read in the next even for
--    the identical engine object. Every per-actor table here is keyed on
--    core.uobject.key(actor) — the GetFullName string — and the handle rides in the VALUE.
--    The building scan used to key its actor->instance map on the wrapper, and the FindAllOf
--    it runs every 500 ms hands back a new wrapper each time, so the fast path missed on
--    every sweep after the one that created the instance and the WHOLE of it went unrun:
--    the position refresh, spatial.indexUpdate, the only line that resets missingStreak on a
--    healthy structure, and the consumption of _meshPending — so a declared
--    Building{ mesh = ... } was marked pending once and never rendered. Every scan took the
--    slow path instead, which re-derived the key from the position and then declined to
--    touch the instance it found because the actor "differed" from the one already held.
--    The instance itself remembers the key it is bound under (inst.actorKey), because a DEAD
--    actor will not answer its own name and removal still has to find the entry.
--
-- 2. THE RUNTIME STATE LIVES ON _G, exactly like the bus below and for the same reason.
--    A hot reload (F9) builds a fresh module while the native hooks and LoopAsync loops
--    armed by the FIRST load keep running. Anything held in a module-local table would be
--    written by those old closures and read by nobody: the new installDispatch resolved
--    against a new, permanently empty instance registry, so after one F9 no building hook
--    fired again, onTick was dead and Building.Handle:instances() returned {} forever. One
--    table, _G.__PalForgeBuildingRegistry, holds the def/instance registry, the actor index,
--    the world-ready gate, the pal sweep's memo and the persistence cache. core.reload must
--    NOT wipe it; it is not a module, so its KEEP list does not have to.
--
-- 3. THE PERSISTENT DRIVERS RE-ENTER THE CURRENT MODULE. The scan, the flush, the pal sweep,
--    the ready-watch and the RequestBuild place-intent hook are armed once per session and
--    cannot be taken back, so each one calls require("palforge.core.event").__xxxPump()
--    rather than the copy of the function it captured. Otherwise the code that keeps running
--    after a reload is the OLD code — the old buildDef, the old scan, the old dispatch, over
--    the old api.building base class — and it would fight the new module over the shared
--    tables above. The registry is NOT part of that list any more: core/reload.lua keeps
--    palforge.core.object_manager across the wipe (its KEEP table), so both modules read one
--    registry and a pre-reload driver at least sees the current definitions. That is what
--    makes the fallback in pump() safe; it is not a reason to drop the pump. This is the same
--    technique the tick source already uses for core.poll, one level up.
--
-- 4. ONLY A REGISTERED DEFINITION IS EVER TRACKED, AND TRACKING PERSISTS. This is a publish
--    gate, not a preference. refreshDefs takes its defs from object_manager's registry and
--    from nowhere else, so a building becomes tracked when — and only when — a Building{...}
--    define call REGISTERED it. The consequence is why the rule is written here: a tracked
--    def means every matching actor in the world becomes a live instance AND a record in the
--    player's save file. A catalog READ (native.buildings.Foundation, or a picker iterating
--    CATALOG) must therefore not register, or reading a tooltip starts persisting the whole
--    base; the domain constructors take `opts.register == false` for that. Do not widen this
--    to "any class object_manager can produce" — that is the same bug with a new spelling.
--
-- ==== WHAT IS PERSISTED, WHO OWNS IT, AND WHAT IS NEVER DELETED (F-7) ==================
--
-- THIS FILE NO LONGER OWNS A BYTE OF IT. core.state owns the files, the caches, the dirty
-- sets and every failure decision; core.event owns the RUNTIME. What this file sees is one
-- MERGED VIEW — `state.world()`, the same `{ entities = {…}, orphans = {…} }` shape it used
-- to hold itself — so the scan's per-actor lookup is still a single hash hit and never walks
-- N files. It says which pack a change belongs to (`state.markDirty(pack)`) and core.state
-- decides which file that is.
--
-- ONE FILE PER MOD ID, PER SAVE (format 3): state/<saveId>/<packId>.json, plus _unowned.json
-- for records no pack can be attributed to. The mod id is object_manager's pack identity —
-- the same string `owner("building", defId)` answers and `PalForge.pack("id")` scopes on —
-- promoted from a FIELD inside the record to the FILENAME. What that buys, and it is the
-- reason the split was asked for: a pack that is installed but registers nothing costs ZERO
-- reads, a pack that is UNINSTALLED costs zero reads forever and cannot be evicted by
-- another pack's growth, and removing one pack's state is deleting one file by name instead
-- of a prune pass over a file every pack shares. A record is still keyed
-- `<resolvedBuildId>@<cell>` (core.spatial) — unchanged, deliberately: every key would move
-- if that changed, no live instance would find its record, and the scan would write a SECOND
-- record for every structure in the base.
--
-- NOTHING IS EVER SILENTLY DESTROYED, and R-1 widened that from one absence to two.
--
--   * UNCLAIMED — no registered definition claims the record's build id. QUARANTINED
--     (`orphans`, `why = "unclaimed"`), logged with a count and with the packs it belonged
--     to, moved BACK the moment a definition claims that build id again. A pack that is
--     merely not loaded today (a player disables a mod for one evening, a pack that defines
--     its buildings lazily has not got there yet) must not cost the player their state.
--
--   * MISSING — the actor was not in FindAllOf for MISS_THRESHOLD consecutive scans. This
--     used to DELETE the record outright, three seconds after the sweep stopped seeing the
--     actor, and that is the one line in this file that could have cost a player a whole
--     base. FindAllOf enumerates in-memory UObjects only, and everything readable off the
--     shipping binary says map objects are spawned and disposed by proximity: Palworld keeps
--     a persistent `Model` apart from a transient `ConcreteModel`
--     (FPalMapObjectSaveData{ MapObjectId, Model, ConcreteModel }, dumps/cxx/Pal.hpp:4639),
--     ~10 classes carry OnAvailableConcreteModel / OnNotAvailableConcreteModel delegate
--     pairs (:14252-14699), TryGetConcreteModel has a `Failed` out-pin
--     (Pal_enums.hpp:2853-2857) and UPalMapObjectConcreteModelBase carries :bDisposed. NONE
--     of that has been measured in game — hook `building-actor-streaming` is the measurement
--     and it is the highest-priority one in this pass. So a miss QUARANTINES too
--     (`why = "missing"`), and the scan's bind path takes the record back out of quarantine
--     ON SIGHT rather than waiting for the once-per-world prune, which by then has already
--     run. A structure that streams out and back inside one session keeps its state either
--     way, and the change is correct whether or not streaming turns out to happen: it turns
--     a possibly-catastrophic silent deletion into a bounded, logged, self-reversing move.
--
-- The miss sweep cannot simply STOP, either — it is the only destruction signal that exists
-- in this build (see the "NO building.break" note at the bottom of the building source: none
-- of the four candidate classes declares a Destroy / Dismantle / Demolish entry, destruction
-- appears only as delegate FIELDS RegisterHook cannot address). So it stays, and it moves
-- instead of deleting. `building.remove` still emits with reason = "missing"; no pack sees a
-- change.
--
-- The only destructive act left is the quarantine cap (ORPHAN_MAX), and it is now applied PER
-- PACK FILE rather than to the whole save. That is a scope change, not a policy change, and
-- it matters: one pack's 4096 quarantined records used to evict another pack's. Past the cap
-- the OLDEST records of THAT pack are dropped, oldest first, and the log says how many, for
-- which pack, and why.
--
-- ONE CASE THAT WAS ON THAT LIST AND NO LONGER IS, because two halves of this sweep met: an
-- F9 hot reload. core/reload.lua used to wipe palforge.core.object_manager with everything
-- else and re-require only palforge.native.*, so every pack's definitions vanished until the
-- game was restarted — which, with this prune in place, would have quarantined every pack
-- record in the save about thirty seconds after the press. core/reload.lua now KEEPS
-- object_manager (its KEEP table, the F-5 fix), so the registry survives the wipe and a
-- reload changes nothing about what is claimed. The two changes have to stay together: if
-- object_manager is ever dropped from KEEP again, ORPHAN_GRACE_SCANS is all that stands
-- between a reload and a mass quarantine.
--
-- RENAMING AN ID. The record key is the resolved BUILD id, so changing what a definition
-- attaches to changes the key and nothing migrates by itself. The narrow, unambiguous case
-- IS migrated, because the record now remembers its definition id: a record whose `def` is
-- still registered, whose build id that def no longer claims, where the def now claims
-- exactly ONE build id and the target key is free, is re-keyed in place and logged. Anything
-- ambiguous (two candidate build ids, an occupied target) is left alone and quarantined
-- instead. Renaming the DEFINITION id itself still loses the binding — there is no rename
-- map anywhere in the framework to consult — but the state is recoverable: it sits in
-- quarantine until the old id comes back. (`altKeys`, written by persist() and read by
-- nothing since the port, is gone. It was not a migration; it was an empty table.)
--
--   local event = require("palforge.core.event")
--   event.on("pal.spawned", function(ctx) end)
--   event.observable("building.interact"):filter(...):subscribe(...)
--   local off = event.on("tick", function(c) end); off:unsubscribe()

local Rx  = require("palforge.core.vendor.rx")
local log = require("palforge.utils.log").scope("event")
-- The one place that answers "is this UObject live" and "what may I key a table on".
-- Rule 1 in the header is enforced through uo.key / uo.same and nothing else; see
-- core/uobject.lua for the measurement behind it.
local uo  = require("palforge.core.uobject")

-- Building-runtime deps (self-contained generic primitives; NO deprecated/tmp require).
local object_manager = require("palforge.core.object_manager")
local spatial        = require("palforge.core.spatial")
-- core.state owns every persisted byte: the per-save directory, one document per mod id, the
-- dirty sets, the atomic write, the quarantine of a file that will not parse, and the one-shot
-- migration off the old single-file format. This file holds no file name, no cache and no
-- codec any more — it asks for the merged view and names the pack a change belongs to.
-- (core.state requires utils.file / utils.json / core.spatial / core.object_manager and
-- nothing from api/, so this is not a cycle.)
local state          = require("palforge.core.state")
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
-- FLUSH_EVERY = 20 ticks, :37 "and only when dirty"), which is exactly what the flush pump
-- does: core.state writes the documents that were marked dirty and nothing else.
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
-- ⚠️ THE pcall USED TO SWALLOW THE ERROR, AND THAT COST A WHOLE SESSION TO DIAGNOSE.
--
-- 2026-08-06: the building scan ran exactly once after world.ready and then never again. No
-- cost report, no autorun entry firing, no building.load — while the log stayed busy with
-- RegisterHook-driven channels, because those do not ride this driver. From outside, "the
-- heartbeat stopped" and "the callback raises on every tick" are the SAME OBSERVATION: silence.
-- There was no way to tell them apart without adding a line, which is the definition of a
-- diagnostic gap in the one place every periodic behaviour in this file passes through.
--
-- The pcall itself is right and stays: one bad subscriber must not stop the heartbeat for
-- everything else. What was wrong is discarding what it caught. The error is now reported —
-- ONCE per distinct message per subscriber, because a driver that fires twice a second would
-- otherwise turn one defect into a log flood, which is its own way of hiding it.
local everyFails = {}   -- "<ms>:<message>" -> true, so each distinct failure is said once
function M.every(ms, fn)
    assert(type(ms) == "number" and ms > 0 and type(fn) == "function", "event.every(ms>0, fn)")
    local acc = 0
    return M.on("tick", function()
        acc = acc + M.TICK_MS
        if acc >= ms then
            acc = 0
            local ok, err = pcall(fn)
            if not ok then
                local key = tostring(ms) .. ":" .. tostring(err)
                if not everyFails[key] then
                    everyFails[key] = true
                    log.err(string.format(
                        "a %d ms repeating callback RAISED and has been failing silently: %s. "
                        .. "The heartbeat is unaffected and every other subscriber still runs; "
                        .. "this one has done nothing since. Said once per distinct error.",
                        ms, tostring(err)))
                end
            end
        end
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

-- THE RUNTIME STATE, ON _G. Rule 2 in the header: the sources are armed once per SESSION
-- and a hot reload builds a fresh module underneath them, so every table an old closure
-- writes and a new module reads has to be the SAME table. It was module-local until F-5 was
-- written up, and the measured consequence was total: after one F9 the new dispatch resolved
-- `building.place/load/interact/remove` against a new, permanently empty `instances`, the
-- tick list was empty so onTick never ran again, and Building.Handle:instances() answered {}
-- for the rest of the session. Everything the runtime remembers is in here, and it is the
-- only state in this file that a reload must not lose.
local RT = _G.__PalForgeBuildingRegistry
if not RT then
    RT = {
        defs      = {},   -- registryId -> def { id, cls, pack, buildIds, gridCm, tickInterval, hooks }
        byBuildId = {},   -- resolvedBuildId -> def   (REBUILT by refreshDefs, never appended to)
        instances = {},   -- key -> instance
        tickList  = {},   -- array of instances whose class overrides onTick
        pending   = {},   -- placement intents { buildId, pos, player }
        -- uo.key(actor) -> instance. NOT the actor wrapper (rule 1); a string key cannot be
        -- weak, so entries are removed explicitly through unbindActor/removeInstance and the
        -- instance carries the key it was bound under.
        byActor   = {},
        world     = { ready = false, pendingReady = false, readyCount = 0,
                      scans = 0, pruned = false },
        pal       = { classOf = {}, classOfN = 0, defCount = -1,
                      tickState = setmetatable({}, { __mode = "k" }) },
        -- WAS the persistence cache (`cache` + `dirty`); core.state holds both now, keyed per
        -- save AND per pack, which is the split this table could not express. What is left
        -- here is the one persistence fact that belongs to the RUNTIME rather than to the
        -- store: which pack documents THIS world has already asked core.state to load, so the
        -- scan does not re-ask twice a second and the orphan hook can print what was and was
        -- not loaded — "not loaded" being the mechanism that protects an absent pack's records.
        store     = { packsAsked = {} },
    }
    _G.__PalForgeBuildingRegistry = RT
end
local Registry         = RT
local instancesByActor = RT.byActor
local gate             = RT.world     -- the world-load gate, shared with the old closures
local store            = RT.store     -- the per-world load memo, shared for the same reason
-- A session that started before the store split has an RT.store carrying the OLD two fields
-- and no packsAsked (rule 2: this table is on _G and outlives the module). Fill it in rather
-- than replacing the table — the pre-reload closures hold the table itself.
store.packsAsked = store.packsAsked or {}

local MISS_THRESHOLD        = 6    -- consecutive scans an instance may be unseen before removal
local INTERACT_DEBOUNCE_SEC = 1.0
local READY_POLLS           = 5    -- consecutive ~1s polls with a valid player pawn

-- =====================================================================================
-- SCAN COST — measured, not estimated, because the estimate was what got this wrong
-- =====================================================================================
--
-- WHAT HAPPENED ON 2026-08-06. `building-actor-streaming` published 48 build ids into a base
-- of 623 PalBuildObject actors. One sweep bound 227 instances; the next consumed every one of
-- their `_meshPending` flags, so hundreds of LoadAsset + component creations landed in a single
-- game-thread callback. Palworld closed seven seconds later. Nothing in this file had a budget
-- — `grep budget` over 2200 lines returned nothing — so there was no mechanism that could have
-- spread that work even in principle.
--
-- THE STEADY STATE IS THE BIGGER PROBLEM, and it is the one a player reaches without any hook.
-- A Palworld base grows without bound. Per sweep, for N tracked actors, this scan pays:
--
--   FindAllOf("PalBuildObject")   1   walks EVERY UObject — this file already calls it the
--                                     known periodic-hitch source, at PAL_SCAN_MS
--   actor:IsValid()               N   native
--   uo.key(actor) = GetFullName() N   native — the price of the A-1 fix, paid every sweep
--   actorPos() = K2_GetActorLocation  N   native
--   spatial.indexUpdate           N   Lua
--
-- At 623 actors and 2 Hz that is ~3,700 native calls a second for actors that are already bound
-- and have not changed. At 5,000 it is ~30,000. The shape is wrong, not the constant.
--
-- SO: MEASURE FIRST. These counters are written by scanOnce and reported once every
-- SCAN_REPORT_EVERY sweeps, at a cost of a few integer adds per sweep. Every number in the
-- paragraphs above is COUNTED FROM THE CODE and none of it has been timed in a running game;
-- the report line is what replaces the arithmetic with a measurement, and it is deliberately
-- landing before the budget below rather than after, so the two can be compared.
-- THE FIRST REPORT COMES EARLY, AND THAT IS A LIVENESS SIGNAL RATHER THAN A COST ONE. On
-- 2026-08-06 the scan ran once after world.ready and then went quiet, and with a 60 s reporting
-- cadence there was no way to tell "the sweep is cheap and reporting later" from "the sweep is
-- dead" for a whole minute. 20 sweeps is ~10 s: long enough to average, short enough that its
-- ABSENCE is information while the operator is still looking at the screen.
local SCAN_REPORT_FIRST = 20    -- sweeps before the first report (~10 s at SCAN_MS = 500)
local SCAN_REPORT_EVERY = 120   -- sweeps between cost reports thereafter (~60 s)
local scanCost = RT.scanCost or { sweeps = 0, ms = 0, peakMs = 0, actors = 0, bound = 0,
                                  rendered = 0, deferredBind = 0, deferredRender = 0,
                                  findMs = 0, loopMs = 0, idle = 0, discovered = 0 }
RT.scanCost = scanCost

-- Handed to the actor loop when the scan declines to enumerate, so the loop needs no second
-- shape. One table for the life of the module; nothing ever writes to it.
local EMPTY_ACTORS = {}

-- How many sweeps a converged scan waits before enumerating once as a safety net. 60 at
-- SCAN_MS = 500 is 30 s. It exists because a structure can appear with no hook of its own —
-- streamed in, spawned by something PalForge does not see — and without it such a structure
-- would wait for the next placement anywhere in the world. At one sweep in sixty it costs
-- 1/60th of what the unconditional enumeration cost, which at the 2026-08-07 measurement is
-- 65 ms every 30 s instead of 65 ms twice a second.
local DISCOVER_IDLE_SWEEPS = 60

-- Consecutive enumerations that must find nothing and leave nothing unaccounted for before the
-- scan goes idle. See the convergence block in scanOnce for why one is not enough.
local DISCOVER_SETTLE = 2

-- Ask the next sweep to enumerate. Every caller is an EVENT — a placement intent, a definition
-- arriving or leaving, a world load, a tracked handle going invalid — which is the whole point:
-- discovery is driven by things happening, and the idle re-check above is a net under it rather
-- than the mechanism. Public so a pack that spawns a structure by some route PalForge cannot
-- see has a supported way to say so.
function M.discoverSoon()
    local g = RT.world
    g.discoverDue = true
end

-- =====================================================================================
-- SCAN BUDGET — the fix for the burst half
-- =====================================================================================
--
-- A sweep may CREATE at most this many new instances and RENDER at most this many deferred
-- meshes. Anything over the budget is not dropped: it is simply not done this sweep, and the
-- next sweep finds the same actor unbound and tries again. That is what makes the carry-over
-- free — the scan is idempotent by construction, so "do less now" needs no queue.
--
-- WHY THESE NUMBERS. A bind is a table build plus a spatial insert plus a persistence mark;
-- a render is a LoadAsset and a component creation, which is the expensive one and the one
-- that was in the crash. 16 binds a sweep populates a 623-structure base in ~20 s of walking
-- around it, which is invisible next to a world load; 4 renders a sweep is 8 meshes a second.
-- Both are deliberately readable at runtime (`event.SCAN_BIND_BUDGET = 64`) so a session that
-- wants the old all-at-once behaviour can ask for it and see what it costs.
M.SCAN_BIND_BUDGET   = 16
M.SCAN_RENDER_BUDGET = 4

-- world.ready is DEFERRED: the ready-watch opens gate.ready and raises gate.pendingReady,
-- and the first reconstruction scan that completes afterwards emits the channel. The scan
-- is what creates the live instances, so emitting at gate-open time would dispatch
-- onWorldReady over an empty registry (which is exactly what it used to do).
local lastInteract = {}   -- "<actorName>" -> os.clock()

-- ---- persistence (core.state owns the files; this file owns the runtime) ----
--
-- WHAT LIVES WHERE, now that the store has moved out. `state.world()` is the MERGED view of
-- every pack document loaded for this save — one `{ entities, orphans }` pair, the exact
-- shape this file used to hold as `store.cache`, so every reader below is unchanged. Which
-- FILE a record belongs to is `rec.pack`, and the one thing this file has to do about it is
-- say `state.markDirty(rec.pack)` when it changes something. There are seven such sites and
-- each is marked `-- DIRTY <n>` so they can be counted against the list in the store spec.
--
-- THE RECORD'S PACK, NOT THE DEFINITION'S, decides the file. They agree once stampRecord has
-- run, and before that they deliberately do not: an unattributed record (the whole of a
-- migrated player's file — `def` and `pack` are stamped only on the first scan that BINDS a
-- record, so every record written before that is bare) lives in `_unowned` until the bind
-- moves it. Marking the definition's pack there would dirty a file the record is not in and
-- leave the file it IS in unwritten.
--
-- The record SHAPE is core.state's business now (format 3: `pack` is the filename and `v` is
-- the document header's `format`), which is why REC_VERSION is gone from here. What this file
-- still owns is the two fields that describe the record's relationship to the REGISTRY —
-- `def` and `pack` — because the scan is the only thing that ever knows which definition
-- claimed a structure. stampRecord writes them; core.state carries them.

-- Quarantine bounds. ORPHAN_GRACE_SCANS delays the one prune pass per world long enough for
-- a pack that defines its buildings at world.ready (or lazily, on first use) to have done so;
-- ORPHAN_MAX is the only limit in this file whose enforcement DELETES a player's record, and
-- it says so in the log when it does. It is applied PER PACK FILE (see pruneOrphans): the
-- cap is a bound on one mod's quarantine, and before the split one pack at the cap evicted
-- another pack's records — a mod the player had not touched in months paying for a mod they
-- had just uninstalled.
local ORPHAN_GRACE_SCANS = 60      -- ~30 s at SCAN_MS = 500
local ORPHAN_MAX         = 4096

-- The two reasons a record is quarantined rather than deleted, written into the record as
-- `why` so a hook, a log line and `db.diagnose()` can tell them apart without guessing:
--   "unclaimed"  no REGISTERED definition claims this record's build id (the pack is not
--                loaded today). Decided by pruneOrphans, once per world.
--   "missing"    the ACTOR was not in FindAllOf for MISS_THRESHOLD consecutive scans.
--                Decided by the scan's miss sweep, and reversed by its bind path.
local WHY_UNCLAIMED = "unclaimed"
local WHY_MISSING   = "missing"

-- Move a record into quarantine, keeping every byte of it. The ONLY way a record leaves
-- `entities` other than tryMigrate's re-key; there is deliberately no other statement in this
-- file that assigns nil into w.entities[key].
local function quarantine(w, key, rec, why)
    rec.orphanedAt = rec.orphanedAt or os.time()
    rec.why        = why
    w.orphans[key] = rec
    w.entities[key] = nil
    state.markDirty(rec.pack)
    return rec
end

-- The other direction, and the half R-1 is really about: take `key` back OUT of quarantine.
-- Returns the record, or nil when there was nothing quarantined under that key.
--
-- Called from the scan's BIND PATH, on sight, not only from the once-per-world prune. That is
-- the whole point: the prune runs once, at scan 60, and a structure that streams out at scan
-- 400 and back at scan 460 would otherwise wait for the next world load to get its state
-- back — by which time the same sweep would have quarantined it again.
--
-- Returns the record AND the reason it had been held, because the caller's log line is the
-- only place that reason is ever read and this clears the field on its way past.
---@return table|nil rec, string|nil why
local function unquarantine(w, key)
    local rec = w.orphans[key]
    if type(rec) ~= "table" then return nil, nil end
    local why       = rec.why
    w.orphans[key]  = nil
    rec.orphanedAt  = nil
    rec.why         = nil
    w.entities[key] = rec
    state.markDirty(rec.pack)
    return rec, why
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

-- Which pack owns a definition, when object_manager can say. `owner` is part of the
-- registry surface added for the pack-identity work (contract C3); this file is written to
-- run with or without it, because a nil owner is a perfectly good record — it means
-- "registered before pack identity existed, or by a caller that declared no pack" — and an
-- unattributed record must still be persisted, not dropped.
local function ownerOf(defId)
    if type(object_manager.owner) ~= "function" then return nil end
    local ok, pack = pcall(object_manager.owner, "building", defId)
    if ok and type(pack) == "string" and #pack > 0 then return pack end
    return nil
end

-- One warning per (definition id, declared build id) pair. buildDef only runs when a class
-- is first seen or re-registered, so this is already rare; the set exists so a pack that
-- re-registers in a loop cannot turn one broken id into a log flood.
local badBuildIdSeen = {}

-- Build a def from a registered building CLASS. The going-live def used to be built in
-- Building:register(); now it is derived from object_manager's catalog (registry no
-- longer calls cls:register()). Port of Building:register's validation + lowering.
--
-- AN ID THAT WILL NOT RESOLVE FALLS BACK TO THE LITERAL, AND SAYS SO (F-4). This loop used
-- to DROP such an id. That is the one behaviour in the tree that turns a definition inert
-- with no log line at all: an empty buildIds means byBuildId never learns the id, the scan
-- never matches an actor, and onPlace / onLoad / onTick / onRemove never fire — for a
-- definition that registered successfully and answers every read a pack makes about it. The
-- rest of the tree resolves engine-bound ids as `resolve(x) or x` (utils/items, core/spawn,
-- api/building's Handle:unlock), so the literal fallback is what the file already believed;
-- only this call site disagreed. A literal that names no real BuildObjectId simply never
-- matches, which is a silent MISS rather than a silent DEATH, and the warning below names
-- the id and the reason resolve gave so the author can fix the shape (`my-pack:Bench` — a
-- hyphen — is the shape that produced this). Define-time validation (om.validId, contract
-- C4) is the other half and catches it earlier; this half is the engine boundary, and both
-- are wanted: a def can reach here from a registry write that predates the check.
local function buildDef(cls, regId)
    local id = cls.id or regId or cls.__name
    local tickInterval = cls.tickInterval or 1
    if type(tickInterval) ~= "number" or tickInterval < 1 or tickInterval % 1 ~= 0 then tickInterval = 1 end
    local buildIds = cls.buildIds or { id }
    local resolved = {}
    for _, bid in ipairs(buildIds) do
        if type(bid) ~= "string" or #bid == 0 then
            -- Not an id at all. There is no literal to fall back TO, so this one really is
            -- dropped — and unlike the old behaviour it is dropped out loud.
            local k = tostring(id) .. "\0" .. tostring(bid)
            if not badBuildIdSeen[k] then
                badBuildIdSeen[k] = true
                log.warn(string.format("building '%s': buildIds entry of type %s is not an id "
                    .. "and is IGNORED — that entry can never match a placed actor",
                    tostring(id), type(bid)))
            end
        else
            local r, why = object_manager.resolve(bid)
            if not r then
                local k = id .. "\0" .. bid
                if not badBuildIdSeen[k] then
                    badBuildIdSeen[k] = true
                    log.warn(string.format("building '%s': build id %q does not resolve (%s) — "
                        .. "using it LITERALLY, which is what every other engine boundary does. "
                        .. "It will only match an actor whose BuildObjectId is spelled exactly "
                        .. "that; a namespaced id must be [%%w_]+:[%%w_]+ to become <pack>_<name>",
                        tostring(id), bid, tostring(why or "no reason given")))
                end
                r = bid
            end
            resolved[#resolved + 1] = r
        end
    end
    return {
        id           = id,
        cls          = cls,
        pack         = ownerOf(regId or id),
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

-- One warning per (resolved build id, loser, winner) triple — a standing collision must not
-- reprint itself twice a second, and a collision whose OUTCOME changes is a different fact
-- and does get its own line.
local buildIdConflictSeen = {}

-- Refresh defs + byBuildId from the central catalog. Cheap; cached def objects are
-- reused (stable inst.def identity) unless a class is (re)registered. Called before
-- the scan and before recording a placement intent, so buildings defined AFTER
-- start() are picked up.
--
-- THE ONLY SOURCE OF TRACKED DEFINITIONS IS object_manager's REGISTRY (rule 4 in the
-- header). Nothing here builds a def from a catalog table, a spec or an id string: a
-- building is tracked because a define call registered it, and being tracked is what makes
-- every matching actor in the world a live instance AND a line in the player's save file.
--
-- DETERMINISTIC, AND IT REBUILDS RATHER THAN APPENDS. Two problems lived in the four lines
-- this replaces. (1) It walked pairs(), whose order is unspecified, and let the last writer
-- win, so with two definitions claiming one resolved build id — which `resolve` allows,
-- since "my:pack_Thing" and "my_pack:Thing" both become "my_pack_Thing" — the owner of a
-- placed structure varied BETWEEN SESSIONS with nothing logged. Ids are sorted and the
-- FIRST one wins now: same registry, same answer, every launch, and the loser is named in
-- the log. (2) byBuildId was add-only, so re-defining a building with different buildIds
-- left the old ids pointing at a def nothing else referenced any more. It is rebuilt from
-- the live registry each pass and defs whose id is no longer registered are retired with it.
--
-- AND IT IS WHAT DRIVES THE LAZY LOAD. Registration is the only event in this framework that
-- says "this mod has state in this save" — so the pack document is read HERE, on first sight
-- of a definition that pack owns, and nowhere else. The read path the store split was asked
-- for falls straight out of that: nothing is opened at game start, nothing is opened at world
-- load, nothing is opened for a pack that is installed but registers no building, and a pack
-- that is UNINSTALLED is never opened again, ever, so its records cannot be touched by
-- anything. F-8 survives it exactly — asking core.state to load a document touches no disk
-- when there is no file, creates no directory, and with zero registered building definitions
-- this loop does not run at all.
local function refreshDefs()
    local live = object_manager.all("building")

    local ids = {}
    for id in pairs(live) do ids[#ids + 1] = id end
    table.sort(ids)

    local byBuildId = {}
    for _, id in ipairs(ids) do
        local cls = live[id]
        local def = Registry.defs[id]
        if not def or def.cls ~= cls then
            def = buildDef(cls, id)
            Registry.defs[id] = def
        end
        -- LAZY LOAD, ONCE PER PACK PER WORLD. The memo is on RT (per world, cleared by the
        -- teardown) rather than trusting state.loadPack's own idempotence to be free: this
        -- runs for every registered definition, twice a second, for the life of the session.
        --
        -- BUT core.state IS THE AUTHORITY, not the memo, and the `and` below is what says so.
        -- Two tables have to agree here and they are owned by different modules; if this one
        -- ever said "asked" while core.state's caches had been dropped, the runtime would be
        -- looking at an EMPTY record set with every structure still standing, would persist a
        -- fresh empty record for each of them, and the next flush would write that over the
        -- player's state. Both tables live on _G today (RT here, __PalForgeState there) so a
        -- hot reload keeps them in step — this line means the invariant does not depend on
        -- that staying true. state.isLoaded counts an ATTEMPT, so a refused file is not
        -- retried twice a second either.
        local packId = def.pack or state.UNOWNED
        if not (store.packsAsked[packId] and state.isLoaded(packId)) then
            store.packsAsked[packId] = true
            local okL, errL = state.loadPack(packId)
            if okL == false then
                log.warn(string.format("pack '%s': its saved state for this world could NOT be "
                    .. "read (%s). Its structures will behave as though they had never been "
                    .. "placed, and core.state has NOT overwritten the file — read its log line "
                    .. "for where the unreadable copy was put", packId, tostring(errL)))
            end
        end
        for _, r in ipairs(def.buildIds) do
            local held = byBuildId[r]
            if held == nil then
                byBuildId[r] = def
            elseif held ~= def then
                local k = r .. "\0" .. tostring(held.id) .. "\0" .. tostring(def.id)
                if not buildIdConflictSeen[k] then
                    buildIdConflictSeen[k] = true
                    log.warn(string.format("build id %q is claimed by TWO definitions, '%s' "
                        .. "(pack %s) and '%s' (pack %s) — '%s' wins because the registered ids "
                        .. "are sorted, which at least makes it the same one every session. "
                        .. "They also SHARE one record key space, so a placed structure's saved "
                        .. "state is handed to whichever wins",
                        r, tostring(held.id), tostring(held.pack or "?"),
                        tostring(def.id), tostring(def.pack or "?"), tostring(held.id)))
                end
            end
        end
    end

    -- THE COMPATIBILITY BUCKET, whenever any building definition exists — this file says WHEN,
    -- core/state says WHAT and WHY. It used to spell `_unowned` out three times here, which put
    -- the store's own read policy in a module whose header says it holds no file name and no
    -- cache; `state.loadCompatBucket()` is the same measurement with the reasoning next to the
    -- rule that names the bucket. See its doc comment for why it is a named call rather than a
    -- side effect of loadPack — a loadPack that opened it implicitly broke the store's
    -- one-mod-one-file read claim, and three checks said so.
    if #ids > 0 then state.loadCompatBucket() end

    -- Retire: replace the index wholesale (a stale build id must stop resolving) and drop
    -- defs for ids the registry no longer holds. Existing INSTANCES keep the def object they
    -- were created with, which is what makes inst.def identity stable across a redefinition.
    -- A CHANGED CLAIM SET IS A REASON TO ENUMERATE. A definition arriving mid-session claims
    -- build ids that standing actors may already match, and a converged scan would otherwise
    -- never look at them again. Compared by the claimed ids rather than by the def objects,
    -- because a redefinition that claims the same ids changes nothing the scan can find.
    local sig = {}
    for r in pairs(byBuildId) do sig[#sig + 1] = r end
    table.sort(sig)
    sig = table.concat(sig, "\0")
    if sig ~= Registry.buildIdSig then
        Registry.buildIdSig = sig
        RT.world.discoverDue = true
    end

    Registry.byBuildId = byBuildId
    for id in pairs(Registry.defs) do
        if live[id] == nil then Registry.defs[id] = nil end
    end
end

-- ---- the actor -> instance index (rule 1 in the header; contract C1) ----
-- Bind `inst` to `actor` under uo.key(actor) and remember the key ON the instance. The
-- remembered key is not a convenience: an actor that has been destroyed will not answer
-- GetFullName any more, and removal — which happens exactly when the actor is gone — would
-- otherwise have no way to find the entry it must clear. An actor that will not answer at
-- all is bound to nothing and the instance is still tracked by key; it simply takes the
-- scan's slow path until it answers.
local function bindActor(inst, actor, actorKey)
    local k = actorKey or uo.key(actor)
    if inst.actorKey and inst.actorKey ~= k then instancesByActor[inst.actorKey] = nil end
    inst.actor    = actor
    inst.actorKey = k
    if k then instancesByActor[k] = inst end
end

local function unbindActor(inst)
    if inst.actorKey then instancesByActor[inst.actorKey] = nil end
    inst.actorKey = nil
end

-- ---- instance object (port of entity.makeInstance + model instance sugar) ----
-- `initialState`, NOT `state`: the module-local `state` is core.state, and a parameter
-- spelled the same would shadow the store inside every closure built here. Renamed on
-- contact rather than aliased, because the two things are one letter apart and the shadow
-- would be silent.
local function makeInstance(def, buildId, actor, pos, initialState, key)
    -- A placed structure IS a Building class instance: cls:new(spec) sets the class
    -- metatable, so lifecycle dispatch (inst:onPlace/onTick/onRightClick/...) and the
    -- visual methods (inst:mesh/material/render/update) resolve directly.
    local inst = def.cls:new({
        def   = def, key = key, buildId = buildId,
        pos   = pos, cell = spatial.cellOf(pos, def.gridCm),
        actor = actor, state = initialState or {},
        missingStreak = 0,
    })
    -- The record this instance's state belongs to, wherever it currently sits. `orphans` is
    -- in the search because R-1 made quarantine reversible and therefore reachable while the
    -- instance is still alive: the miss sweep can quarantine a record the same scan the actor
    -- comes back, and a setDirty in between must still land on the record rather than on
    -- nothing.
    local function recordOf(self)
        local w = state.world()
        return w.entities[self.key] or w.orphans[self.key], w
    end
    -- Per-instance persistence closures (INSTANCE FIELDS, like actor/pos — not additions
    -- to the Building class method set). The persisted record's `state` is the SAME table
    -- reference as inst.state, so an in-place mutation is written on the next flush.
    inst.setDirty = function(self)                                        -- DIRTY 3
        local rec = recordOf(self)
        if rec then rec.state = self.state end
        state.markDirty((rec and rec.pack) or (self.def and self.def.pack))
    end
    -- RETURNS ok, err now, and that is not cosmetic. The old flushWorld discarded its own
    -- result and cleared `dirty` regardless, so one unencodable state table anywhere in the
    -- save turned every subsequent write into a silent no-op and a whole session's building
    -- state disappeared. A pack that wants durability NOW can see whether it got it:
    --     local ok, err = self:save(); if not ok then print("save failed: " .. err) end
    inst.save = function(self)                                            -- DIRTY 4
        self:setDirty()
        local rec = recordOf(self)
        return state.flush((rec and rec.pack) or (self.def and self.def.pack))
    end
    inst.isValid = function(self) return uo.live(self.actor) end
    return inst
end

-- Stamp a record with WHO it belongs to (F-7). A record used to carry buildId / pos / state
-- and an `altKeys` table that nothing ever wrote to and nothing ever read — no owner, no way
-- for a later load to say which pack's line this is. It carries `def` and `pack` now, and an
-- old record is upgraded in place the first time the scan binds it, which is the only moment
-- the runtime knows which definition claimed a structure.
--
-- ATTRIBUTION IS A FILE MOVE, which is why this returns the PREVIOUS pack as well as whether
-- anything changed. Under one shared file a stamp was a field write; under one file per mod
-- id it takes the record out of `_unowned.json` and puts it in `<pack>.json`, so BOTH
-- documents are dirty and marking only one leaves a duplicate behind in the other. The
-- marking is done at the call site rather than here because persist() stamps a record that
-- has never been on disk — there is no previous file for that one, and dirtying `_unowned`
-- for it would create a document nothing needs.
-- `v` IS NOT TOUCHED HERE, and that is a deliberate hand-off rather than an omission. The
-- per-record version became the document header's `format`: core.state drops `v` on write and
-- puts the current format back on read, so a record in memory always carries one and no code
-- outside that module has any business setting it. `altKeys` is dropped on write for the same
-- reason and is cleared here as well, because it is the one field a HUMAN might still see in
-- an old file and the orphan hook counts how many records still carry it.
---@return boolean changed, string|nil previousPack
local function stampRecord(rec, inst)
    if type(rec) ~= "table" then return false, nil end
    local defId = inst.def and inst.def.id or nil
    local pack  = inst.def and inst.def.pack or nil
    local prev  = rec.pack
    if rec.def == defId and rec.pack == pack and rec.altKeys == nil then return false, prev end
    rec.def     = defId
    rec.pack    = pack
    rec.altKeys = nil          -- the dead field, removed on contact rather than rewritten
    return true, prev
end

-- write/refresh the persisted record for an instance
local function persist(inst)                                              -- DIRTY 1
    local w = state.world()
    local rec = { buildId = inst.buildId, pos = inst.pos, state = inst.state }
    stampRecord(rec, inst)
    w.entities[inst.key] = rec
    state.markDirty(rec.pack)
end

-- register a live instance: index, deferred mesh, tick set.
local function addInstance(inst)
    Registry.instances[inst.key] = inst
    if inst.actor then bindActor(inst, inst.actor) end
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
    unbindActor(inst)
    for i = #Registry.tickList, 1, -1 do
        if Registry.tickList[i] == inst then table.remove(Registry.tickList, i); break end
    end
    Registry.instances[key] = nil
    -- R-1: A MISS QUARANTINES, IT DOES NOT DELETE. This is the line that used to read
    -- `loadWorld().entities[key] = nil`, and it was the most dangerous statement in the file.
    --
    -- The only evidence behind it is "FindAllOf did not return this actor for MISS_THRESHOLD
    -- consecutive scans" — three seconds at SCAN_MS = 500 — and FindAllOf enumerates
    -- in-memory UObjects only. That is the same CLASS of statement as "no definition claims
    -- this build id", which this file already refuses to delete on, in words written a few
    -- hundred lines below: *"Deleting on that evidence would cost the player every
    -- structure's state for a reason that reverses itself."* An actor the player has walked
    -- away from reverses itself the moment they walk back.
    --
    -- Whether the game really does dispose base structures by proximity is UNMEASURED — the
    -- header lists what the binary says and hook `building-actor-streaming` is the
    -- measurement. This change does not wait for it, because it is right either way: if
    -- streaming happens, it was silently deleting every structure's pack state about three
    -- seconds after the player left the base; if it does not, a genuinely demolished
    -- structure's record sits in quarantine, bounded by ORPHAN_MAX, visible in the log and in
    -- `db.diagnose()`, and restored on sight if the same structure is ever seen again.
    --
    -- world-left is unchanged and still keeps the record where it is: leaving a world is not
    -- evidence about a structure at all.
    if reason ~= "world_left" then
        local w   = state.world()
        local rec = w.entities[key]
        if type(rec) == "table" then quarantine(w, key, rec, WHY_MISSING) end   -- DIRTY 5
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
    -- A placement is the clearest possible reason to enumerate: an actor is about to exist
    -- that nothing is tracking. This is what makes the converged scan wake up.
    RT.world.discoverDue = true
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

-- ---- reconstruction scan (crash-safe; gated on gate.ready) ----
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

-- ---- the orphan pass: quarantine, restore, and the one narrow rename migration (F-7) ----
--
-- WHY THERE HAS TO BE ONE. The miss sweep at the bottom of the scan only walks
-- Registry.instances — live structures the scan can still see — so a record belonging to a
-- pack that is no longer installed is never visited by anything, ever. There was no prune,
-- no orphan scan and no TTL, in a file that is shared by every pack and only ever appended
-- to; the checked-in state/entities_world.json is what that looks like after one session.
--
-- WHY IT DOES NOT DELETE. "No definition claims this build id" is NOT the same statement as
-- "this pack is gone". A player disables a mod for one evening, a pack defines its buildings
-- lazily and has not got there yet, a definition is being renamed. (An F9 hot reload used to
-- be the first item on this list — core/reload wiped object_manager and re-required only
-- palforge.native.*, so a press dropped every pack's content until the game restarted. It
-- keeps object_manager now, so a reload no longer unclaims anything; the header has the
-- account.) Deleting on that evidence would
-- cost the player every structure's state for a reason that reverses itself. So an orphan is
-- MOVED to the file's `orphans` section, keeping its bytes, and moved back the moment
-- something claims its build id again. The player's state is recoverable by reinstalling the
-- pack — including after an id rename, by renaming it back.
--
-- WHAT IT COSTS, stated plainly: the file still grows in the one case where growth is
-- genuinely permanent (a pack uninstalled forever), and only the ORPHAN_MAX cap bounds it.
-- That cap is the single destructive act in this file and it names itself in the log.
--
-- WHAT THE SPLIT CHANGED HERE, and it is one line of behaviour rather than one of structure:
-- the growth is now confined to the file of the pack that caused it. A pack uninstalled
-- forever grows ITS document, which nothing loads any more, so it costs the player no read
-- time at all and is deleted by deleting one file by name. (`orphanCount`, which counted the
-- whole save's quarantine for a cap that is now per pack, went with it — the cap does its own
-- counting per document below.)

-- The one migration a record can carry itself through. `def` is registered, the record's
-- build id is one that def no longer claims, and the def now claims exactly ONE build id:
-- then the structure at that position belongs to that build id and the record is re-keyed
-- there. Anything ambiguous — several candidate build ids, or an occupied target key — is
-- refused and left to quarantine, because guessing which of two ids a player's chest state
-- belongs to is worse than keeping it where it is.
local function tryMigrate(w, key, rec)
    if type(rec.def) ~= "string" or type(rec.pos) ~= "table" then return nil end
    local def = Registry.defs[rec.def]
    if not def or #def.buildIds ~= 1 then return nil end
    local bid = def.buildIds[1]
    if bid == rec.buildId then return nil end
    local newKey = spatial.keyOf(bid, spatial.cellOf(rec.pos, def.gridCm))
    if newKey == key or w.entities[newKey] ~= nil or Registry.instances[newKey] then return nil end
    rec.buildId = bid
    w.entities[newKey] = rec
    w.entities[key] = nil
    state.markDirty(rec.pack)                                             -- DIRTY 7
    log.info(string.format("record %s migrated to %s: definition '%s' is still registered and "
        .. "now declares exactly one build id (%q), so the structure's saved state follows the "
        .. "rename instead of being orphaned", key, newKey, rec.def, bid))
    return newKey
end

local function pruneOrphans()
    local w = state.world()
    local restored, quarantined, junk = 0, 0, 0
    local packs = {}

    -- RESTORE FIRST, so a pack that came back this session gets its records before anything
    -- else looks at them, and so a record cannot be counted as an orphan twice.
    --
    -- The CONDITION is unchanged by R-1 and deliberately so: it asks only whether a
    -- registered definition claims the build id, not why the record was quarantined. A
    -- `why = "missing"` record whose pack IS loaded therefore comes back here too. That reads
    -- odd until you name what the alternative would be — leaving a record in quarantine on
    -- the strength of a sighting that failed once, minutes ago, while the definition that
    -- owns it is loaded and its structure may be standing in front of the player. The scan's
    -- bind path is the fast half of the same statement; this is the slow half.
    for key, rec in pairs(w.orphans) do
        if type(rec) ~= "table" then
            -- Not a record, so it names no pack and nothing can attribute it. `_unowned` is
            -- the only document it can have come from and the only one that has to be
            -- rewritten without it — state.markDirty(nil) is that document by definition.
            w.orphans[key] = nil; junk = junk + 1
            state.markDirty(nil)                                          -- DIRTY 6
        elseif rec.buildId and Registry.byBuildId[rec.buildId] and w.entities[key] == nil then
            unquarantine(w, key)                                          -- DIRTY 6
            restored = restored + 1
        end
    end

    -- Snapshot the keys before touching the table: tryMigrate INSERTS a re-keyed record, and
    -- adding a key to a table that a pairs() walk is in the middle of is undefined in Lua.
    local live = {}
    for key in pairs(w.entities) do live[#live + 1] = key end
    for _, key in ipairs(live) do
        local rec = w.entities[key]
        if rec == nil then                          -- moved by an earlier tryMigrate
            -- nothing to do
        elseif type(rec) ~= "table" then
            -- Not a record at all (a hand-edited or truncated file). Nothing can own it and
            -- nothing can read it; quarantining junk would only make the junk permanent.
            w.entities[key] = nil
            junk = junk + 1
            state.markDirty(nil)                                          -- DIRTY 6
        elseif not (type(rec.buildId) == "string" and Registry.byBuildId[rec.buildId]) then
            if not tryMigrate(w, key, rec) then
                quarantine(w, key, rec, WHY_UNCLAIMED)                    -- DIRTY 6
                quarantined = quarantined + 1
                packs[tostring(rec.pack or rec.def or "unattributed")] = true
            end
        end
    end

    -- THE CAP, PER PACK FILE. Oldest first, by the time the record was quarantined; a record
    -- with no orphanedAt (written by a version that had none) sorts as oldest, which is the
    -- conservative direction only if it is genuinely old — it is, because the field has been
    -- written since quarantine existed.
    --
    -- PER PACK is the change format 3 brought, and it is a scope change rather than a policy
    -- change. Under one shared file the cap counted every pack's quarantine together, so one
    -- pack that had been uninstalled for a year and had 4096 records in the file could push
    -- ANOTHER pack's records over the edge and delete them — a mod paying for a neighbour's
    -- history. Each document now has its own budget, which is also the only reading of the
    -- cap that survives "one file per mod id" as a sentence.
    local dropped, droppedPacks = 0, {}
    local byPack = {}
    for k, rec in pairs(w.orphans) do
        -- state.packOf, not a local re-derivation: this counts records against a per-pack cap
        -- and the flush partitions them into files, so the two have to agree on WHOSE a record
        -- is. The copy that used to be here omitted the reserved-name check, which meant a
        -- record carrying `pack = "_save"` was capped against `_save` and written into
        -- `_unowned.json` — two answers to one question, in the one place that must have one.
        local p = state.packOf(rec)
        local g = byPack[p]
        if not g then g = {}; byPack[p] = g end
        g[#g + 1] = k
    end
    for p, keys in pairs(byPack) do
        if #keys > ORPHAN_MAX then
            table.sort(keys, function(a, b)
                local ta = tonumber(w.orphans[a] and w.orphans[a].orphanedAt) or 0
                local tb = tonumber(w.orphans[b] and w.orphans[b].orphanedAt) or 0
                if ta ~= tb then return ta < tb end
                return a < b                     -- deterministic tie-break
            end)
            local over = #keys - ORPHAN_MAX
            for i = 1, over do w.orphans[keys[i]] = nil; dropped = dropped + 1 end
            droppedPacks[#droppedPacks + 1] = string.format("%s (%d)", p, over)
            state.markDirty(p)                                            -- DIRTY 6
        end
    end

    if restored + quarantined + junk + dropped > 0 then
        local names = {}
        for p in pairs(packs) do names[#names + 1] = p end
        table.sort(names)
        local liveN = 0
        for _ in pairs(w.entities) do liveN = liveN + 1 end
        log.info(string.format("world records: %d restored, %d quarantined%s, %d unreadable "
            .. "dropped, %d live. A quarantined record is one whose build id NO registered "
            .. "definition claims this session — it is kept, not deleted, and comes back by "
            .. "itself if the pack is loaded again",
            restored, quarantined,
            (#names > 0 and (" (" .. table.concat(names, ", ") .. ")") or ""),
            junk, liveN))
        if dropped > 0 then
            table.sort(droppedPacks)
            log.warn(string.format("world records: %d record(s) were DELETED permanently because "
                .. "a pack's quarantine held more than %d entries — %s. This is the only place "
                .. "PalForge destroys a saved record, and the cap is now per pack file, so no "
                .. "other pack's records were touched by it",
                dropped, ORPHAN_MAX, table.concat(droppedPacks, ", ")))
        end
    end
end

-- One reconstruction pass. Discovers NEW building actors -> creates+tracks the instance
-- and EMITS building.place (matched to a pending RequestBuild intent) / building.load
-- (reconstructed from a saved record). Vanished instances past the miss threshold EMIT
-- building.remove and are dropped. Each channel emit fires the object's hook via DISPATCH
-- (never a direct inst:onX here). The instance-creation branch runs once per key, so
-- building.place emits exactly once per placement.
local function scanOnce()
    if not gate.ready then return 0 end
    refreshDefs()

    -- ONE orphan pass per loaded world, and not immediately (F-7). The grace period is not
    -- politeness: refreshDefs above is the only thing that decides whether a build id is
    -- claimed, and a pack may still be defining — native catalogs materialize lazily, a pack
    -- may define from its own world.ready handler. Quarantining before it has spoken would
    -- move records out and the next pass would move them straight back, twice per world load,
    -- for nothing. gate.pruned is cleared by the world-left teardown, so a second world in the
    -- same session gets its own pass.
    gate.scans = (gate.scans or 0) + 1
    if not gate.pruned and gate.scans >= ORPHAN_GRACE_SCANS then
        gate.pruned = true
        local okP, eP = pcall(pruneOrphans)
        if not okP then log.warn("world records: the orphan pass failed: " .. tostring(eP)) end
    end

    local t0 = os.clock()

    -- ⚠️ NOTHING TO MATCH MEANS NOTHING TO ENUMERATE. Measured 2026-08-06 in a 623-structure
    -- base with ZERO building definitions registered: **69.25 ms average, 124 ms peak, every
    -- 500 ms** — 14% of wall-clock held on the game thread by a Lua callback that bound nothing,
    -- rendered nothing and could not have, because no definition claimed any build id. Every one
    -- of those milliseconds went into FindAllOf plus IsValid / GetFullName / K2_GetActorLocation
    -- over 623 actors, and then a `if not buildId then return end` for every single one.
    --
    -- That is the DEFAULT state of the framework: a player with no building pack installed pays
    -- the entire cost of the building runtime forever, for a feature they are not using. The
    -- early-out is not an optimisation of the scan, it is the scan declining to run.
    --
    -- `Registry.byBuildId` is rebuilt by refreshDefs() above, so this reads the current truth on
    -- every sweep and costs one `next`. The moment a pack registers a Building, the scan resumes
    -- on the next sweep with no further signal needed.
    --
    -- The removal sweep below is NOT skipped: instances can outlive the definition that made
    -- them (a pack unregistering, an F9 reload), and those still have to be able to go away.
    local anyDef = next(Registry.byBuildId) ~= nil

    -- =================================================================================
    -- TRACKING — what is already known, checked without enumerating anything
    -- =================================================================================
    --
    -- MEASURED 2026-08-07, 623 structures: 64.88 ms a sweep, 44.97 of it in FindAllOf and
    -- 19.92 in the per-actor loop, and it is LINEAR in the actor count — 0.0723 ms per actor
    -- in find at 498 actors and 0.0722 at 623. That linearity is the finding: FindAllOf's cost
    -- here is not the global UObject walk, it is MATERIALISING ONE LUA WRAPPER PER ACTOR, and
    -- this scan threw all 623 away twice a second to use three of them. Projected forward at
    -- 0.104 ms per actor per sweep, 5,000 structures is 520 ms a sweep against a 500 ms
    -- interval: the scan stops keeping up before a large base does anything unusual.
    --
    -- An instance already holds its own actor handle (bindActor stores it). Asking THAT handle
    -- whether it is still live is one native call, and the count is the number of TRACKED
    -- structures rather than the number that exist. A pack watching five workbenches pays five
    -- calls a sweep in a base of any size.
    --
    -- A handle going invalid is also the wake signal for discovery: something was destroyed or
    -- streamed out, and only an enumeration can tell which.
    -- ⚠️ THIS PASS DOES NOT DECIDE PRESENCE, ONLY ABSENCE — and getting that backwards broke
    -- two R-1 checks the first time this was written. A live handle is NOT evidence that the
    -- structure is still in the world's actor list: a stub, or a real object the enumeration
    -- legitimately stopped returning, answers IsValid perfectly well. So a live handle marks
    -- nothing as matched; it simply costs one native call and tells us there is no news.
    --
    -- A DEAD handle is the strong signal, and it is the one worth paying for: it means
    -- something was destroyed or unloaded, and only an enumeration can say which instances are
    -- affected. So it wakes discovery, and the ENUMERATION — exactly as before this change —
    -- remains the only thing that may declare an instance missing.
    local matched = {}
    local anyDead = false
    local trackedCount = 0
    for _, inst in pairs(Registry.instances) do
        trackedCount = trackedCount + 1
        if not (inst.actor ~= nil and uo.live(inst.actor)) then anyDead = true end
    end

    -- =================================================================================
    -- DISCOVERY — the only thing that needs FindAllOf, and it converges
    -- =================================================================================
    --
    -- Discovery answers exactly one question: is there an actor here that nothing is tracking
    -- yet? That is true at a world load, when a structure is placed, and when one comes back
    -- after being lost — and it is FALSE the rest of the time, which is the whole of the saving.
    --
    -- `gate.discoverDue` is set by those events (see setDiscoverDue) and cleared by a sweep that
    -- enumerated and bound NOTHING NEW: zero new binds is convergence, because the world was
    -- enumerated in full and had nothing to give. The idle re-check is a safety net rather than
    -- a mechanism — a structure that streams in with no hook of its own would otherwise wait for
    -- the next placement — and at one sweep in DISCOVER_IDLE_SWEEPS it costs 1/60th of what the
    -- unconditional enumeration did.
    if anyDead then gate.discoverDue = true end
    gate.sinceDiscover = (gate.sinceDiscover or 0) + 1
    local discover = anyDef and (gate.discoverDue or gate.sinceDiscover >= DISCOVER_IDLE_SWEEPS)

    local actors = EMPTY_ACTORS
    local tFind = os.clock()
    if discover then
        gate.sinceDiscover = 0
        local okFind, found = pcall(FindAllOf, "PalBuildObject")
        if not okFind or type(found) ~= "table" then return 0 end
        actors = found
        tFind = os.clock()
    end
    -- `matched` is built by the TRACKING pass above, not here: an instance whose own handle is
    -- still live is present whether or not this sweep enumerated anything. The loop below only
    -- ADDS to it, for actors discovery found.
    local changes = 0

    -- THIS SWEEP'S BUDGET. Read from the module fields rather than captured, so a session can
    -- retune them between sweeps. Nothing that goes over is dropped: the scan is idempotent, so
    -- an actor left unbound this sweep is simply found unbound on the next one and tried again.
    -- That is the whole mechanism — no queue, no ordering, no state to get wrong — and it is
    -- what turns 227 binds in one game-thread callback into 16 a sweep.
    local bindBudget   = tonumber(M.SCAN_BIND_BUDGET)   or 16
    local renderBudget = tonumber(M.SCAN_RENDER_BUDGET) or 4
    local deferredBind, deferredRender = 0, 0

    for _, actor in ipairs(actors) do
        local ok = pcall(function()
            if not (actor and actor:IsValid()) then return end

            -- FAST PATH: identity is the ACTOR, not the quantized position (a placed
            -- building's location jitters by >1 cell between scans; keying new instances
            -- off that would churn the same actor into endless instances).
            --
            -- KEYED ON uo.key(actor), NOT ON THE ACTOR (A-1/A-2, contract C1). `actors` comes
            -- from a fresh FindAllOf every scan and UE4SS mints a new userdata wrapper per
            -- lookup, so the old `instancesByActor[actor]` missed on EVERY sweep after the one
            -- that created the instance. Three silent failures came out of that one miss and
            -- all three are fixed by this line: missingStreak never reset (so a structure was
            -- one bad scan away from a spurious building.remove and could never accumulate the
            -- six it needs), spatial.indexUpdate below never ran (the "KNOWN GAP" core/spatial
            -- attributes to this runtime), and _meshPending — set once in addInstance and
            -- consumed ONLY here — was never consumed, so a declared Building{ mesh = ... }
            -- never rendered itself although api/pal.lua and plan/TODO.md both said it always
            -- had. The handle is refreshed from this sweep's fresher one on every hit.
            local actorKey = uo.key(actor)
            local bound = actorKey and instancesByActor[actorKey] or nil
            if bound and Registry.instances[bound.key] == bound then
                bound.actor = actor          -- C1: keep the freshest wrapper in the record
                bound.missingStreak = 0
                matched[bound.key] = true
                local p = actorPos(actor)
                if p then
                    bound.pos = p
                    -- RE-BUCKET. core.spatial's hash grid keys on the position it was
                    -- indexed at, and this line is the only place an instance ever moves —
                    -- so without the update a structure that drifts far enough keeps its old
                    -- bucket and spatial.neighbors(pos, r) stops finding it. core/spatial.lua
                    -- named this exact call as its one missing hook; the call was here all
                    -- along and the actor-keyed lookup above is what stopped it running.
                    -- Cheap: it compares the bucket key and only touches the index when that
                    -- key actually changed.
                    spatial.indexUpdate(bound)
                end
                -- deferred mesh: the actor survived >=1 scan, so it's initialized now.
                -- BUDGETED. A render is a LoadAsset plus a component creation, and it is the
                -- expensive half of the 2026-08-06 crash: hundreds of these landed in one
                -- callback because every instance bound by the previous sweep had its flag set.
                -- The flag is only CLEARED when the render is actually attempted, so an instance
                -- deferred here keeps its place and renders on a later sweep.
                if bound._meshPending then
                    if renderBudget > 0 then
                        renderBudget = renderBudget - 1
                        bound._meshPending = false
                        pcall(function() bound:render() end)
                    else
                        deferredRender = deferredRender + 1
                    end
                end
                return
            end

            local pos = actorPos(actor)
            if not pos then return end -- not ready; retried next scan

            local buildId = resolveBuildId(actor)
            -- tier 3: position match against a persisted record for any of our builds.
            -- UNCHANGED except that the record set is fetched ONCE instead of once per
            -- (definition, build id) pair — `loadWorld()` was a single field test and
            -- `state.world()` is a call, and this is the innermost loop of the scan.
            if not buildId then
                local records = state.world().entities
                for _, def in pairs(Registry.defs) do
                    for _, bid in ipairs(def.buildIds) do
                        local k = spatial.keyOf(bid, spatial.cellOf(pos, def.gridCm))
                        if records[k] then buildId = bid; break end
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
                -- steal another live actor's instance (two buildings in one cell). This guard
                -- is why a position-derived key works as well as it does in practice and it
                -- is kept exactly as it was — only the two IDENTITY tests underneath it
                -- changed, because `inst.actor == actor` compared two userdata WRAPPERS and
                -- was therefore false even for the same engine object, which made every
                -- re-encounter look like a different actor arriving in an occupied cell.
                local sameActor = (inst.actorKey ~= nil and inst.actorKey == actorKey)
                    or uo.same(inst.actor, actor)
                local heldValid = inst.actor ~= nil and not sameActor and uo.live(inst.actor)
                if not heldValid then
                    bindActor(inst, actor, actorKey)
                    inst.pos = pos
                    inst.missingStreak = 0
                    if not sameActor and hasMesh(inst) then inst._meshPending = true end
                end
                return
            end

            -- BUDGETED. Everything below this line CREATES: a record read, a possible
            -- unquarantine, an instance, a spatial insert, a persistence mark and two channel
            -- emits. Deferring here rather than after `makeInstance` is what makes the deferral
            -- free — nothing has been allocated or emitted yet, so the next sweep reaching this
            -- same actor does exactly what this one would have done.
            if bindBudget <= 0 then
                deferredBind = deferredBind + 1
                return
            end
            bindBudget = bindBudget - 1

            local w   = state.world()
            local rec = w.entities[key]
            -- R-1, THE RESTORE HALF: a record this session already quarantined comes back out
            -- ON SIGHT. Both reasons are honoured and both are reversals of an absence — the
            -- structure is standing here, which is the strongest possible evidence against
            -- "the actor is gone" (why = "missing", the miss sweep) and against "no
            -- definition claims this build id" (why = "unclaimed", the prune), since we only
            -- reach this line because a registered definition claims exactly this build id.
            --
            -- IT HAS TO BE HERE and not only in pruneOrphans. That pass runs ONCE per world,
            -- at scan 60; a structure the player walks away from at scan 400 and back to at
            -- scan 460 would otherwise be reconstructed with a fresh, empty state table while
            -- its real state sat in quarantine, and the next flush would write the empty one.
            if rec == nil then
                local why
                rec, why = unquarantine(w, key)
                if rec then
                    log.info(string.format("record %s came back out of quarantine: its actor is "
                        .. "in this scan again (it was held as %q, not deleted, so its state "
                        .. "table came back with it)", key, tostring(why or "quarantined")))
                end
            end
            local pend = popPendingNear(buildId, pos)
            -- `recState`, not `state`: the module-local `state` is the store, and this used to
            -- shadow it for the rest of the block.
            local recState
            if rec then recState = rec.state or {}
            elseif def.cls.defaultState then
                -- defaultState may be a factory function or a plain table. Passed the
                -- class as self so `function Cls:defaultState()` also works.
                local oks, s = pcall(function()
                    local ds = def.cls.defaultState
                    if type(ds) == "function" then return ds(def.cls) end
                    return ds
                end)
                recState = (oks and type(s) == "table") and s or {}
            else recState = {} end

            inst = makeInstance(def, buildId, actor, pos, recState, key)
            if rec then
                -- An EXISTING record, being bound for the first time this session: attribute
                -- it to its definition and its pack (F-7). This is the only moment a bare
                -- record — no def, no pack, one dead `altKeys` — can be attributed, because
                -- it is the only moment the runtime knows which definition claimed it.
                --
                -- BOTH DOCUMENTS ARE MARKED. Attribution MOVES the record between files: it
                -- was being written into `_unowned.json` (or into the previous owner's, after
                -- a pack renamed itself) and belongs in `<pack>.json` from now on. Marking
                -- only the destination would leave the record duplicated in the source file
                -- forever, and the copy left behind would be the STALE one.
                local changed, prevPack = stampRecord(rec, inst)          -- DIRTY 2
                if changed then
                    state.markDirty(prevPack)
                    state.markDirty(rec.pack)
                end
            else
                persist(inst)
            end
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

    -- CONVERGENCE. A discovery that enumerated the world in full and bound nothing new has
    -- nothing left to find, so the next sweep does not enumerate. Anything that could make that
    -- untrue — a placement, a definition arriving, a handle going invalid, a world change —
    -- sets the flag again through setDiscoverDue.

    -- removal sweep — ONLY AFTER A SWEEP THAT ENUMERATED. `matched` is built by the actor loop
    -- above and means "the enumeration listed this instance's actor", which is what it has
    -- always meant. A sweep that declined to enumerate has looked at nothing and therefore may
    -- not conclude that anything is absent; it just does not run this. That is the whole
    -- correctness argument for the convergence: not looking is safe precisely because not
    -- looking also means not judging.
    local anyPending = false
    for key, inst in pairs(discover and Registry.instances or EMPTY_ACTORS) do
        if not matched[key] then
            inst.missingStreak = (inst.missingStreak or 0) + 1
            anyPending = true
            if inst.missingStreak >= MISS_THRESHOLD then
                -- emit BEFORE dropping so DISPATCH's resolve() still finds the instance.
                srcEmit("building.remove", { key = key, buildId = inst.buildId, actor = inst.actor, reason = "missing" })
                removeInstance(key, "missing")
                changes = changes + 1
            end
        end
    end

    -- CONVERGENCE, and the second condition is the one the first attempt got wrong. Binding
    -- nothing new is not enough: an instance the enumeration did NOT list has unfinished
    -- business — it is somewhere between one miss and MISS_THRESHOLD, and only more
    -- enumerations can settle whether it comes back or goes. Converging while a miss was
    -- outstanding froze missingStreak at 1 forever and the structure was never removed, which
    -- is exactly what two R-1 checks caught.
    --
    -- So the scan stops enumerating only when it bound nothing AND nothing is unaccounted for.
    -- Anything that could make that untrue — a placement, a definition arriving, a handle going
    -- invalid, a world change — sets the flag again through M.discoverSoon.
    if discover then
        if changes == 0 and not anyPending then
            gate.cleanRuns = (gate.cleanRuns or 0) + 1
        else
            gate.cleanRuns = 0
        end
        -- TWO CLEAN ENUMERATIONS, not one. One is weak evidence that the world has settled: the
        -- sweep that REMOVES a structure at MISS_THRESHOLD is itself a change, so the sweep
        -- straight after it looks clean while the most interesting thing that could happen —
        -- the structure coming back, which is what a stream-out and stream-in looks like — has
        -- not had a single enumeration to be seen in. Requiring two costs one extra FindAllOf
        -- per settling and is what makes "walk away, walk back" work inside one session.
        if gate.cleanRuns >= DISCOVER_SETTLE then gate.discoverDue = false end
    end

    -- COST, counted rather than argued. os.clock is CPU time for this Lua state, which is the
    -- right measure here: what matters is how long this callback holds the game thread.
    local tEnd = os.clock()
    local dt = tEnd - t0
    scanCost.sweeps  = scanCost.sweeps + 1
    scanCost.ms      = scanCost.ms + dt * 1000
    -- SPLIT, so the next refactor is aimed rather than guessed: FindAllOf walks every UObject in
    -- the process and the per-actor loop pays three native calls each. Which of the two dominates
    -- decides whether the answer is "enumerate less often" or "touch each actor less".
    scanCost.findMs  = scanCost.findMs + (tFind - t0) * 1000
    scanCost.loopMs  = scanCost.loopMs + (tEnd - tFind) * 1000
    if not anyDef then scanCost.idle = scanCost.idle + 1 end
    if discover then scanCost.discovered = scanCost.discovered + 1 end
    scanCost.actors  = scanCost.actors + #actors
    scanCost.bound   = scanCost.bound + changes
    scanCost.deferredBind   = scanCost.deferredBind + deferredBind
    scanCost.deferredRender = scanCost.deferredRender + deferredRender
    if dt * 1000 > scanCost.peakMs then scanCost.peakMs = dt * 1000 end
    scanCost.reports = scanCost.reports or 0
    local due = (scanCost.reports == 0) and SCAN_REPORT_FIRST or SCAN_REPORT_EVERY
    if scanCost.sweeps >= due then
        scanCost.reports = scanCost.reports + 1
        log.info(string.format(
            "scan cost over %d sweeps: %.2f ms avg (%.2f find + %.2f loop), %.2f ms peak | %d "
            .. "actor(s) per sweep | %d bound, %d deferred bind(s), %d deferred render(s) | "
            .. "%d/%d sweep(s) ENUMERATED (%d had no definition to match) | %d tracked | "
            .. "budgets %d/%d",
            scanCost.sweeps, scanCost.ms / scanCost.sweeps,
            scanCost.findMs / scanCost.sweeps, scanCost.loopMs / scanCost.sweeps, scanCost.peakMs,
            math.floor(scanCost.actors / scanCost.sweeps + 0.5), scanCost.bound,
            scanCost.deferredBind, scanCost.deferredRender,
            scanCost.discovered, scanCost.sweeps, scanCost.idle, trackedCount,
            tonumber(M.SCAN_BIND_BUDGET) or 16, tonumber(M.SCAN_RENDER_BUDGET) or 4))
        scanCost.sweeps, scanCost.ms, scanCost.peakMs = 0, 0, 0
        scanCost.actors, scanCost.bound = 0, 0
        scanCost.deferredBind, scanCost.deferredRender = 0, 0
        scanCost.findMs, scanCost.loopMs, scanCost.idle = 0, 0, 0
        scanCost.discovered = 0
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
    local keys = {}
    for k in pairs(Registry.instances) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do removeInstance(k, "world_left") end
    -- CLEARED IN PLACE, never replaced. This table is _G.__PalForgeBuildingRegistry.byActor
    -- and the closures armed on the first load hold the table itself; assigning a fresh one
    -- here would leave them writing into a table the module no longer reads — which is the
    -- F-5 split all over again, one field down.
    for k in pairs(instancesByActor) do instancesByActor[k] = nil end
    spatial.indexReset()
    -- THE STORE'S OWN TEARDOWN, and it is LAST rather than first. It flushes every dirty
    -- document and then drops the per-save caches, so the instance sweep above — which marks
    -- nothing, because a world-left removal keeps its record — cannot race it either way.
    --
    -- Dropping the caches is not tidiness. The backend's module-level cache was never evicted
    -- by anything: `store.cache = nil` here dropped THIS file's reference while the backend
    -- went on holding every record set for every world visited this session, so a long session
    -- that toured four saves kept four saves' records live. state.unload() releases them.
    local okU, errU = pcall(state.unload)
    if not okU then log.warn("world left: the store teardown failed: " .. tostring(errU)) end
    -- The next world asks core.state for its own documents. Cleared IN PLACE, same reason as
    -- instancesByActor above.
    for k in pairs(store.packsAsked) do store.packsAsked[k] = nil end
    store.migrated = nil   -- the next world is a different save with its own legacy file
    gate.scans  = 0    -- the next world gets its own orphan pass, after its own grace period
    gate.pruned = false
    spatial.resetSaveId()
end

-- =====================================================================================
-- THE PUMPS — how a driver armed on the FIRST load reaches the CURRENT module (rule 3).
--
-- UE4SS can take back neither a RegisterHook nor a LoopAsync, so the scan, the flush, the
-- pal sweep and the ready-watch are armed once per SESSION and keep running across every
-- hot reload holding the closure they were created with. That closure sees the modules that
-- existed when it was armed: its api.building base class is the pre-reload one and its copy of
-- every function above is the pre-reload code. Sharing the STATE through _G is only half the
-- fix — with both modules alive, the old one would go on writing defs built by the old
-- buildDef, over the old class table, into the table the new one dispatches from.
--
-- ONE captured module is NOT stale, and it is worth naming because it used to be the loudest
-- item in this paragraph: object_manager. core/reload.lua keeps palforge.core.object_manager
-- across the wipe (KEEP), so the registry an old closure reads and the registry a pack's next
-- define call writes are the same table — a pre-reload driver sees post-reload definitions.
-- That is what makes pump()'s fallback to THIS module a degradation rather than a break.
--
-- So each driver calls a named entry point on whatever `require` answers with NOW. The tick
-- source already does exactly this for core.poll ("Required fresh each tick, never captured")
-- and this is the same technique applied to the four drivers that own runtime state. If the
-- reload left a module that cannot be required or does not carry the entry point, the call
-- falls back to THIS module, so a broken reload degrades to the old behaviour rather than to
-- silence.
-- =====================================================================================
local function pump(name, ...)
    local fn
    local ok, mod = pcall(require, "palforge.core.event")
    if ok and type(mod) == "table" and type(mod[name]) == "function" then fn = mod[name] end
    if fn == nil then fn = M[name] end
    if type(fn) == "function" then return fn(...) end
end

-- One reconstruction pass plus the DEFERRED world.ready emit. The scan is what turns actors
-- into live instances, so world.ready is announced by the first scan that COMPLETES after
-- the gate opened — by then the structures around the player exist and the onWorldReady
-- dispatch has something to iterate. Order matters: scan first, then emit.
function M.__scanPump()
    scanOnce()
    if gate.pendingReady then
        gate.pendingReady = false
        pcall(function() srcEmit("world.ready") end)
        -- THE DECLARED-ASSET PASS (A-6). The one moment it can run: the world is up, the
        -- load storm is over, and every definition that is going to register at startup has.
        -- core.mesh.validateDeclared walks om.all("mesh") — every REGISTERED Mesh{...}, which
        -- is what a Pal or a Building points its own mesh at — resolves each declared model /
        -- animClass / texture / material and logs one MESHVALIDATE block naming what did not
        -- resolve, which turns "my boss is invisible" from a bisect into a log line. A mesh
        -- spec written INLINE in a Building{ mesh = { ... } } block is not in that registry
        -- and is not covered; the scan's render path is what reports on those, one actor at a
        -- time. Guarded on the function existing, so this file still works against a core.mesh
        -- that has not gained it yet.
        pcall(function()
            local m = require("palforge.core.mesh")
            if type(m.validateDeclared) == "function" then m.validateDeclared() end
        end)
        -- The one moment a dev queue can run: the world exists, the player pawn exists, and
        -- nothing has been asked of the keyboard. See core/autorun.lua for why that matters.
        pcall(function() require("palforge.core.autorun").run() end)
    end
end

-- The 10 s batched flush. Writes only the DOCUMENTS that were marked dirty, so one structure
-- changing one number rewrites that pack's file and touches no other pack's — measured at 500
-- records: 102,332 bytes and 7.48 ms of re-encode became 26,419 bytes and 1.78 ms, with the
-- other two packs' files not opened at all.
--
-- IT RETURNS ok, err AND THAT IS THE POINT. The old flushWorld discarded `setAndFlush`'s
-- result and cleared `dirty` regardless, so ONE cyclic state table in ONE pack made encode
-- return nil, logged a single warn line naming a file, and then guaranteed that nothing would
-- ever be retried — the same shape for a full disk, a read-only folder or antivirus holding
-- the handle. A whole session's building state disappeared with one warn line. core.state
-- KEEPS the dirty set on failure, so the next pump tries again.
function M.__flushPump() return state.flushDirty() end

function M.__placeIntent(buildId, pos, player) return onPlaceRequest(buildId, pos, player) end

-- =====================================================================================
-- SOURCE world — ready-watch (port of entity/events.startReadyWatch). LoopAsync(1000)
-- polling the player pawn: N stable polls -> OPEN the gate.ready gate and arm the
-- deferred world.ready emit (the scan below fires it, see gate.pendingReady); going
-- invalid -> emit world.left (then drop live instances). This gate also guards the
-- building scan/hooks (don't touch objects during the load storm).
-- =====================================================================================
-- THE ONE CALLER OF core.state's MIGRATION, and where it sits is the whole of its
-- correctness.
--
-- It has to run at world.ready, because the save id is not knowable before one; and it has to
-- run BEFORE THE FIRST SCAN THAT BINDS AN ACTOR, which is why it is here at the gate flip and
-- not in __scanPump's pendingReady block next to the other once-per-world work. The order is
-- not a preference: migrate() adds what is missing and NEVER replaces what is already there
-- (core/state.lua, `absorb`), which is exactly right for a re-run over a restored backup and
-- exactly wrong if the scan has gone first — the scan would have bound each standing structure
-- to a fresh, EMPTY record, migrate would find those keys occupied, and every one of the
-- player's saved states would be skipped over in favour of the blank the scan had just made.
-- The gate flips here and `scanOnce` returns at `if not gate.ready` until it does, so this is
-- the last moment at which the world view is still empty.
--
-- One-shot per world: `migrated` is cleared by the world-left teardown along with the rest of
-- RT.store. Everything else about it is core/state's — it is a no-op when there is no legacy
-- file, when the fingerprint says it already ran, and when the file will not parse. It is
-- pcall'd because a failed migration must not take the world-ready gate down with it; the
-- records stay in the legacy file, which is never touched either way.
local function migrateOnce()
    if store.migrated then return end
    store.migrated = true
    local ok, rep = pcall(function() return state.migrate() end)
    if not ok then
        log.warn("the one-shot migration of the pre-format-3 state file raised (" ..
            tostring(rep) .. "). The legacy file is untouched and this world starts from " ..
            "whatever the per-mod files hold")
    elseif type(rep) == "table" then
        log.info(string.format("migrated %d record(s) out of the single pre-format-3 state "
            .. "file into per-mod files; %d could not be attributed to a mod yet and are in "
            .. "_unowned.json, which drains as each structure is bound", rep.records or 0,
            rep.unowned or 0))
    end
end

-- One poll of the ready-watch. Public-by-convention (the `__` says "a driver calls this,
-- you do not") because the LoopAsync below must reach the CURRENT copy of it — see pump().
function M.__worldPoll()
    local okFind, pawn = pcall(FindFirstOf, "PalPlayerCharacter")
    local valid = okFind and pawn and pawn:IsValid()
    if valid then
        gate.readyCount = gate.readyCount + 1
        if gate.readyCount == READY_POLLS then
            -- The gate flips HERE (unchanged): every `if not gate.ready then
            -- return end` guard keeps exactly its old load-storm protection.
            -- The CHANNEL is armed instead of emitted — the next scan owns it.
            gate.ready = true
            gate.pendingReady = true
            gate.discoverDue = true   -- a fresh world: nothing is tracked yet
            gate.sinceDiscover = 0
            log.info("world ready - building dispatch enabled")
            migrateOnce()
        end
    else
        local wasReady = gate.ready
        gate.ready = false
        gate.pendingReady = false  -- never emit a ready for a world we already left
        gate.readyCount = 0
        if wasReady then
            log.info("world left - building dispatch paused")
            pcall(function() srcEmit("world.left") end)
            pcall(dropAllInstances)
        end
    end
end

local function installWorldSource()
    local ok, e = pcall(function()
        LoopAsync(1000, function()
            ExecuteInGameThread(function() pump("__worldPoll") end)
            return false -- keep polling
        end)
    end)
    if not ok then
        -- fail OPEN but loudly: dispatch works, at the cost of the load-storm guard.
        -- (Arm the deferred emit too, so world.ready still lands if a heartbeat exists;
        --  when LoopAsync is gone there is no scan either, and nothing emits.)
        gate.ready = true
        gate.pendingReady = true
        gate.discoverDue = true   -- a fresh world: nothing is tracked yet
        gate.sinceDiscover = 0
        log.warn("ready-watch unavailable (" .. tostring(e) .. ") - dispatch always on")
        migrateOnce()   -- the gate opened, so this is still "before the first bind"
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
---(core.uobject.live is the implementation; the name is kept because a dozen hooks below
---read as English with it.)
local function alive(o) return uo.live(o) end

---A STABLE table key for a UObject, as a string.
---
---Not the userdata. UE4SS builds a fresh Lua wrapper on every `:get()` / FindAllOf element, so
---`t[obj]` written in one hook call is not `t[obj]` read in the next even for the identical
---engine object — a table keyed on the wrapper silently never matches and every dedupe or
---diff built on it degrades to "always new". GetFullName() is the object's unique path
---(`PalPassiveSkillComponent /Game/.../BP_ChickenPal_C_2147460233.PassiveSkillComponent`) and
---is the same string every time. nil when it cannot be read, and every caller treats that as
---"do not remember this one" rather than as a key.
---
---The rule this states is now the whole tree's (contract C1) and core.uobject.key is the one
---implementation of it. The name stays because the hooks below read as English with it, and
---because the paragraph above is the measurement that produced the rule.
local function objKey(o) return uo.key(o) end

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
-- left is the `if not gate.ready then return end` line every handler opens with, which
-- stops US from touching the object but not the game from calling us. And if LoopAsync is
-- unavailable there is no scan, so world.ready never lands and the hook never arms at all
-- (fail-soft: that hook's feature is simply off, like any tryHook miss).
local function tryHookAfterWorldReady(path, fn)
    local armed = false
    M.on("world.ready", function()
        if armed then return end        -- one-shot: world.ready re-fires on every world load
        if not gate.ready then return end  -- the CHANNEL is public and anyone may emit it (the
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
        if not gate.ready then return end
        local ok, e = pcall(function()
            local id = get(buildObjectId):ToString()
            local pos = nil
            pcall(function()
                local loc = get(location)
                if loc then pos = { x = loc.X, y = loc.Y, z = loc.Z } end
            end)
            local player = FindFirstOf("PalPlayerCharacter")
            -- Through the pump: this hook was armed once, and the intent it records is read
            -- by the scan, which runs in the CURRENT module. Recording it into the previous
            -- module's idea of the registry would drop every placement made after a reload.
            pump("__placeIntent", id, pos, player)
        end)
        if not ok then log.err("building source: place-intent handler: " .. tostring(e)) end
    end)

    -- interact: OnBeginInteractBuilding(self = building actor, other = interactor).
    -- Resolve the id from the class name and EMIT building.interact; DISPATCH resolves the
    -- live instance (by actor) and calls onRightClick.
    tryHook("/Script/Pal.PalBuildObject:OnBeginInteractBuilding", function(self, other)
        if not gate.ready then return end
        local ok, e = pcall(function()
            local building = get(self)
            local otherActor = get(other)
            -- filter: only characters (buildings interact with each other; V3)
            local charClass = StaticFindObject("/Script/Pal.PalCharacter")
            if not (otherActor and otherActor:IsValid()) then return end
            if charClass and charClass:IsValid() and not otherActor:IsA(charClass) then return end

            -- The debounce key is objKey (core.uobject.key), not a second GetFullName spelled
            -- here — contract C1 says there is one identity helper for a UObject and nothing
            -- invents another. Same string either way; what changes is that a building which
            -- will not answer its own name now returns nil instead of raising and aborting
            -- the whole handler, so the interact is simply not debounced rather than lost.
            local actorName = objKey(building)
            if not actorName then return end
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

    -- Reconstruction scan on the shared heartbeat (gated on gate.ready inside scanOnce),
    -- and the DEFERRED world.ready emit. The scan is what turns actors into live
    -- instances, so world.ready is announced by the first scan that completes after the
    -- gate opened — by then the structures around the player exist and the onWorldReady
    -- dispatch has something to iterate. Order matters: scan first, then emit. The gate
    -- flag itself is untouched, so the notification only moves <= SCAN_MS later.
    -- Buildings that stream in on a LATER scan still miss it; onLoad is the per-instance
    -- startup hook. (M.every already pcalls this body, so a throwing scan just leaves
    -- gate.pendingReady raised and the next pass retries the emit.)
    -- Both drivers below go through pump(): they are subscriptions on the shared bus, made
    -- once per session, and the work they drive owns the shared registry — see the pumps.
    M.every(SCAN_MS, function() pump("__scanPump") end)

    -- Batched persistence flush (see FLUSH_MS). Without it the ONLY writes are inst:save()
    -- and the world-left teardown, so a structure discovered by the scan — and any state a
    -- handler mutated in place after inst:setDirty() — reached disk only on a clean exit and
    -- was lost to an alt-F4 or a crash. The flush is a no-op while no document is dirty, so
    -- this costs one empty-set test every 10 s.
    M.every(FLUSH_MS, function() pump("__flushPump") end)

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
            if not gate.ready then return end
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
-- miss) is memoized against the actor, so later sweeps are a table read.
--
-- THAT CLAIM WAS FALSE UNTIL THE KEY WAS FIXED. The memo was a weak table keyed on the actor
-- WRAPPER, and `actors` comes from a fresh FindAllOf every sweep, so every lookup missed and
-- every pal in the world paid a full resolvePalClass — a GetClass, a GetFullName, a pattern
-- match and, for anything not registered under its exact BP id, a pairs() walk over every
-- registered pal — every three seconds, forever. Same defect as the building scan's
-- actor->instance map (rule 1 in the header, contract C1), same fix: uo.key.
--
-- The consequence of a string key is that it cannot be weak, so the memo is BOUNDED instead:
-- pals stream in and out for a whole session and nothing would ever release those keys. At
-- the cap the table is dropped whole, which costs one re-resolution per actor seen after it —
-- the same trade the spawn dedupe table makes, for the same reason.
local PAL_CLASS_KEYS_MAX = 4096
local palTickState   = RT.pal.tickState                     -- cls -> { fails, broken } (weak)
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
    if not gate.ready then return 0 end
    local pal = RT.pal   -- the memo lives on _G with the rest of the runtime state (rule 2)

    -- A definition can be registered at any time (native/pals.lua materializes one lazily on
    -- first get), so a `false` memoized before that would keep a real pal silent for its
    -- actor's whole life. Drop the memo whenever the registered set changes size — one
    -- snapshot walk per sweep, not per actor.
    local n = 0
    for _ in pairs(object_manager.all("pal")) do n = n + 1 end
    if n ~= pal.defCount then
        pal.defCount = n
        pal.classOf, pal.classOfN = {}, 0
    end
    if n == 0 then return 0 end   -- nothing defined: skip the FindAllOf entirely

    local okFind, actors = pcall(FindAllOf, "PalCharacter")
    if not okFind or type(actors) ~= "table" then return 0 end

    local ticked = 0
    for _, actor in ipairs(actors) do
        local ok = pcall(function()
            if not (actor and actor.IsValid and actor:IsValid()) then return end
            local akey = uo.key(actor)
            local cls = akey and pal.classOf[akey]
            if cls == nil then
                cls = resolvePalClass({ actor = actor }) or false
                if akey then
                    if pal.classOfN >= PAL_CLASS_KEYS_MAX then pal.classOf, pal.classOfN = {}, 0 end
                    if pal.classOf[akey] == nil then pal.classOfN = pal.classOfN + 1 end
                    pal.classOf[akey] = cls
                end
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

function M.__palSweep(ctx) return palScanOnce(ctx) end

-- Drive the sweep off the heartbeat, but at its own much slower cadence. Written out rather
-- than handed to M.every because M.every captures its interval: reading M.PAL_SCAN_MS here,
-- every heartbeat, is what makes the constant tunable without editing this loop. The
-- subscription is made once per session and survives a reload, so the sweep itself is
-- reached through pump() and the cadence is read off whichever module answers now.
local function installPalTickSource()
    local acc = 0
    M.on("tick", function(ctx)
        local ok, mod = pcall(require, "palforge.core.event")
        local cur = (ok and type(mod) == "table") and mod or M
        local every = tonumber(cur.PAL_SCAN_MS)
        if not every or every <= 0 then return end   -- 0 / nil / garbage = sweep disabled
        acc = acc + M.TICK_MS
        if acc < every then return end
        acc = 0
        pcall(pump, "__palSweep", ctx)
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
        if not gate.ready then return end
        pcall(function()
            if get(started) ~= true then return end
            local comp = get(self)
            local actor; pcall(function() actor = comp:GetOwner() end)
            srcEmit("pal.captured", { actor = actor, comp = comp })
        end)
    end)
    -- damage: OnDamageReaction (self = the character taking damage).
    tryHook("/Script/Pal.PalCharacter:OnDamageReaction", function(self)
        if not gate.ready then return end
        pcall(function() srcEmit("pal.damaged", { actor = get(self) }) end)
    end)
    -- death: OnDeadCharacter (self = the dead character).
    tryHook("/Script/Pal.PalCharacter:OnDeadCharacter", function(self)
        if not gate.ready then return end
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
            if not gate.ready then return end
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
            if not gate.ready then return end
            pcall(function()
                emitSpawned(getv(inCharacter), "PalPlayerCharacter:OnCompleteInitializeParameter")
            end)
        end)

    tryHookAfterWorldReady("/Script/Pal.PalNPC:OnCompletedInitParam",
        function(self, inCharacter)
            if not gate.ready then return end
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
        if not gate.ready then return end
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
        if not gate.ready then return end
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
        if not gate.ready then return end
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
            if not gate.ready then return end
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
        if not gate.ready then return end
        pcall(function() eachArray(getv(slots), function(e) emitDiscard(e, "drop") end) end)
    end)

    -- dispose: trashing one stack from the inventory menu. a1 is the request guid, a2 the slot.
    tryHook("/Script/Pal.PalNetworkItemComponent:RequestDispose_ToServer", function(self, _reqId, slotInfo)
        if not gate.ready then return end
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
-- OBSERVED LIVE, 2026-07-26, during real combat:
--     skill.activate carried its first event from source "PalActionBase:OnBeginAction"
-- The source that works is the ACTION OBJECT, not a utility that builds one. PlayActionByWazaID
-- stays armed as the control that proved it: it registered successfully and carried nothing
-- while a pal fought and killed another pal, which is what sent the search to the action side.
-- A pal's move IS a UPalActionWazaBase, it carries its own EPalWazaID, and hooking it puts the
-- identity a handler needs on `self` instead of in someone else's argument list.
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
        if not gate.ready then return end
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
        if not gate.ready then return end
        pcall(function() emitFromAction(getv(self), "PalActionBase:OnBeginAction") end)
    end)

    -- SOURCE 3 — the PLAYER's action component announcing a start to its listener. a1 is the
    -- action; `self` is the player and is deliberately NOT used as the owner, because the
    -- action's own GetActionCharacter is the authority (a summoned weapon's action is played
    -- on the weapon, not on the player).
    tryHook("/Script/Pal.PalPlayerCharacter:OnBeginAction", function(self, action)
        if not gate.ready then return end
        pcall(function() emitFromAction(getv(action), "PalPlayerCharacter:OnBeginAction") end)
    end)

    -- hit. The waza is the SEVENTH parameter, so this is the one hook in the file that reads
    -- past a4; UE4SS hands every declared parameter to the callback, and a build that hands
    -- over fewer simply leaves wazaType nil and the guard below drops the event.
    -- SOURCE 1 — MEASURED SILENT while pal.damaged fired in the same fight. Kept armed.
    tryHook("/Script/Pal.PalUtility:MakeDamageInfoByWazaType",
        function(self, attacker, defender, _aHit, _dHit, hitLocation, _foliage, wazaType)
            if not gate.ready then return end
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
            if not gate.ready then return end
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

    -- SOURCE 1 — THIS IS THE SOURCE THAT CARRIED. Two measurements, in this order, and the
    -- second overtook the first:
    --   1. MEASURED SILENT across a session of catching and releasing pals. Kept armed on the
    --      strength of the declaration alone, which is the policy in this file's header.
    --   2. FIRED, 2026-07-26 — skill.equip carried its first event with via = "AddPassiveSkill",
    --      and the item closed as skill-passive-source. The write that triggered it came from
    --      PalForge itself: core.character.addSkill put a passive on a live BP_ChickenPal_C and
    --      read it back. So (1) is a fact about the GAME's own bench and party writes — which
    --      still have not been seen to reach this function — and not about the hook.
    -- A handler must therefore be ready to hear about a change its own pack made. What is still
    -- unsettled is only which call the GAME uses when a player edits a passive at a bench;
    -- SOURCE 2 below stays armed beside this one and has carried nothing yet, and announceVia
    -- names whichever wins. See api/skill.lua's onEquip/onUnequip block for the full account.
    -- ⚠️ The unequip DIRECTION has never been recorded firing from any source.
    tryHookAfterWorldReady("/Script/Pal.PalIndividualCharacterParameter:AddPassiveSkill",
        function(self, addSkill, overrideSkill)
            if not gate.ready then return end
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
            if not gate.ready then return end
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
            if not gate.ready then return end
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
    -- (covers a modded BP_<pack>_<name>_C class). ONE INDEXED LOOKUP (contract C3). This
    -- used to copy the whole "pal" bucket with object_manager.all() and walk it with pairs(),
    -- re-resolving every registered id, ONCE PER EVENT — and because pairs() order is
    -- unspecified, two ids that resolve to the same row picked a different winner between
    -- sessions. object_manager maintains the reverse map at register time instead, so this is
    -- O(1) and the collision is a warning at define time rather than a coin flip here.
    return (object_manager.byResolved("pal", id))
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
    -- this every pack-authored item would be silently eventless. One indexed lookup, same
    -- shape as resolvePalClass above — see the note there for what it replaced and why.
    return (object_manager.byResolved("item", ctx.itemId))
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
    -- One indexed lookup, same shape as resolvePalClass above.
    return (object_manager.byResolved("skill", ctx.skillId))
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
    -- By ACTOR: keyed on uo.key, never on the handle. building.interact carries the actor the
    -- native hook was handed, which is a different userdata wrapper from the one the scan
    -- bound the instance under even when it is the same structure — so this lookup used to
    -- fall through to the position fallback below, and onRightClick reached the instance only
    -- when the ctx also carried a position. It does not.
    if ctx.actor then
        local k = uo.key(ctx.actor)
        if k and instancesByActor[k] then return instancesByActor[k] end
    end
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
--
-- Takes ANY handle onto the actor, not the one the scan happened to bind: the lookup is by
-- uo.key(actor), so a pawn from a later FindAllOf or from an event ctx answers the same. A
-- value that is not a UObject — a plain table, a number — has no key and is nil, which is
-- what the suite asserts.
function M.instanceOfActor(actor)
    if actor == nil then return nil end
    local k = uo.key(actor)
    return k and instancesByActor[k] or nil
end

-- Is the world loaded far enough for the building runtime to touch objects?
function M.isWorldReady() return gate.ready end

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
