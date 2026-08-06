-- PalForge core.reload: swap the framework's Lua out from under a running game.
--
-- Editing a file and pressing a key beats restarting Palworld every time, so this exists.
-- It drops every palforge.* module from package.loaded and re-runs the kernel, which means a
-- change to an api module, a content pack, a test case or a probe is live in about a second.
--
--   PRESS F9 IN GAME  ->  reload every palforge.* module and re-register the content
--
-- WHAT CANNOT BE RELOADED, and why that is fine
--
-- UE4SS gives no way to take back three things once they exist, so a naive reload would
-- stack a second copy of each on every press:
--
--   RegisterHook      a native hook stays armed for the process. Re-arming it would run
--                     every handler twice, then three times.
--   LoopAsync         a loop keeps running. A second heartbeat would double every tick.
--   RegisterKeyBind   a bound key keeps its engine binding.
--
-- So the ENGINE-FACING layer is armed exactly once per session and the reload leaves it
-- alone: `_G.__PalForgeArmed` records that it happened and survives the module wipe, because
-- it lives on the global table rather than inside a module. core/event checks it before
-- arming anything, and the keybind registry already swaps a bound key's function in place
-- rather than binding again — which is what makes the keys keep working across a reload while
-- pointing at the NEW code.
--
-- Everything above that line — definitions, specs, handlers, the api surface, the test suite,
-- the probes, your own content — is plain Lua and is genuinely replaced.
--
-- WHAT A RELOAD REPLACES AND WHAT IT DOES NOT. Four pieces of state deliberately survive the
-- wipe, and each of them is a failure that was paid for once:
--
--   * THE DEFINITIONS, because `palforge.core.object_manager` is in KEEP below, so the registry
--     table holding every registered class outlives the wipe and a pack's content is still
--     there after F9. It was NOT kept until 2026-08-02, and the paragraph that used to stand
--     here said the opposite of what the code did: the module was dropped with everything else,
--     `registry.initialize()` built a FRESH, EMPTY registry, and only `palforge.native.*` was
--     ever loaded back into it (core/registry.lua CATALOGS). A content pack is a separate UE4SS
--     mod in its own require namespace, it is not in the wipe list below, so it is never
--     re-required and its define calls never run a second time — `package.loaded` still says it
--     is loaded. Its content stayed gone until the game was restarted, in the exact
--     edit-and-press-F9 loop this file exists to provide. Keeping the module keeps the table;
--     the native catalogs then re-register over their OWN ids on the way past, which
--     object_manager treats as a same-owner redefinition rather than a collision, so the reload
--     does not print a warning per native class.
--   * THE EVENT BUS, on `_G.__PalForgeBus` (core/event.lua, the block that builds `bus`). A
--     native hook armed on the first load pushes into the subjects table it closed over, so a
--     fresh one would leave the old emitters talking to nobody while the new dispatch listened
--     to an empty bus.
--   * THE BUILDING RUNTIME REGISTRY, on `_G.__PalForgeBuildingRegistry`, for exactly the same
--     reason and by exactly the same trick. The reconstruction scan is subscribed inside
--     core/event's installBuildingSource and is not re-created by bus.dispatch, so it survives
--     a reload still holding the registry it was created with. While that registry was
--     module-local, the new dispatch resolved building.place / load / interact / remove against
--     a new and permanently empty instance table: no building hook fired again, onTick was
--     dead, and Building.Handle:instances() answered {} for the rest of the session.
--   * THE SPATIAL HASH GRID, on `_G.__PalForgeSpatialIndex` (core/spatial.lua), which is the
--     other half of that registry rather than a separate idea. The live instances above each
--     carry an `_bucket` string naming a bucket in this index, so a fresh empty table here
--     would leave every stamp pointing at a bucket that no longer exists and neighbors()
--     answering {} for a base full of structures. core/spatial clears it IN PLACE for the same
--     reason core/event does with byActor: the pre-reload module still holds the table itself.
--
-- What a reload does NOT undo. A live building instance keeps the handler table it was created
-- with, so a structure placed before the reload runs the OLD onTick until it is rediscovered,
-- and a poller registered with core/poll keeps running the closure it was registered with (the
-- poller list is on _G too) — in the cases where a reload happens at all while one is running,
-- which is now the exception rather than the rule, because core/poll declares every poller to
-- the async guard below and a live poller REFUSES the press. That is worth knowing when a hook
-- seems not to have changed.
local log = require("palforge.utils.log").scope("reload")

local M = {}

-- Modules to keep across a reload. `env` holds the dev toggle a reload must not flip, and
-- utils/log is what reports the reload itself — dropping it mid-flight would lose the report.
-- `core.reload` keeps itself, because it is the module currently running.
--
-- `core.object_manager` is the fourth and the one that had to be argued for: it is the
-- WHAT-EXISTS half of the kernel (core/registry.lua's own responsibility split) and it holds
-- the only copy of every registered definition. Dropping it is what split a pack's content off
-- from the framework at the first F9 — see the block above for the full account.
--
-- ⚠️ `core.state` IS DELIBERATELY ABSENT, AND IT SURVIVES F9 ANYWAY — for a reason that is not
-- this table. Its whole runtime hangs off `_G.__PalForgeState` (core/state.lua:157,174), the same
-- trick core/event uses for the bus and the building registry, so re-requiring the module rebinds
-- to the state that is already there and no record is lost. That is a property of core/state, not
-- a decision recorded here, which is exactly why it is written down here: if anyone ever moves
-- that table off `_G` and into a module-local, **`palforge.core.state` must join this list in the
-- same commit** or the first F9 will hand the runtime an empty store and it will persist empty
-- records over a live base. The failure would be silent and it would be in the player's file.
M.KEEP = {
    ["palforge.env"] = true,
    ["palforge.utils.log"] = true,
    ["palforge.core.reload"] = true,
    ["palforge.core.object_manager"] = true,
}

-- Has the engine-facing layer been armed this session? Lives on _G so it outlives the wipe.
---@return boolean
function M.armed()
    return _G.__PalForgeArmed == true
end

---Record that the engine-facing layer is armed. core/event calls this once.
function M.markArmed()
    _G.__PalForgeArmed = true
end

-- Every currently-loaded palforge.* module, except the ones we keep.
local function loadedModules()
    local names = {}
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:sub(1, 9) == "palforge." and not M.KEEP[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--=============================================================================
-- pending async work
--
-- (M.reload's own doc block is at the bottom of this section, with the function. It used to
-- sit here, above the section header, where no tooling could attach it to anything.)
--
-- WHY RELOADING MID-FLIGHT IS NOT SAFE. UE4SS holds a Lua registry reference to every
-- LoopAsync callback, and the engine-tick hook is what runs them. Clearing package.loaded out
-- from under a callback that is still scheduled can leave that reference pointing at something
-- that is no longer a function, and UE4SS's response is not to skip it:
--
--   [UE4SS.EngineTick.LuaModImpl] Hook threw exception:
--     "[Lua::Registry::get_function_ref] Ref was not function", removing hook!
--
-- It removes the TICK HOOK. Every keybind handler in this tree runs its body inside
-- ExecuteInGameThread, and that queue is drained by the tick — so the keys stop responding
-- while the game carries on perfectly well, which is a confusing thing to debug and costs a
-- restart. That happened once, from an F9 pressed a few seconds after an F1 that had left three
-- spawn watches running for up to twenty seconds each.
--
-- So: anything that schedules a repeating callback registers itself here, and reload REFUSES
-- while any are outstanding rather than risking the hook. The state lives on _G so it survives
-- the reload it is guarding.
--
-- WHO ACTUALLY CALLS THIS. Until 2026-08-02 nothing did, anywhere in the tree, so
-- asyncPending() always answered 0 and the refusal branch below was unreachable while the
-- hazard it describes was live — pf_watch / F8 arms the two longest raw chains in the tree
-- (test/probes/watch.lua: a 12 s placement readback and a 60 s window summary) and an F9 inside
-- that window is exactly the press that cost the session its keybinds. There are now TWO
-- callers:
--
--   * test/probes/watch.lua's asyncGuard, one begin/done pair per raw chain. These are the
--     chains the paragraph above is about, and `core/spawn.lua` used to arm one of its own
--     before it was migrated to core/poll — the likeliest moment the original call sites were
--     lost.
--   * core/poll.lua, one begin per registered poller and one done on every path a poller can
--     retire by (returned true, raised, or M.clear). This paragraph used to say core/poll was
--     deliberately NOT counted, and the code now counts it; see the next block for the
--     argument that changed and for what it costs.
--
-- WHAT A POLLER'S CLAIM MEANS, given that a poller is NOT the hazard this guard was written
-- for. What is dangerous is a UE4SS REGISTRY REFERENCE: one is created per LoopAsync callback
-- and per ExecuteInGameThread body, and core/poll creates neither. It is a plain Lua list on
-- `_G.__PalForgePollers` drained by the ONE heartbeat (core/event.lua installTickSource), that
-- heartbeat is armed once per session and never stopped, and its body re-requires core/poll on
-- every tick instead of capturing it — so the wipe cannot leave UE4SS holding a reference to
-- anything that disappeared, and a poller is an ordinary Lua closure that stays callable
-- whether or not the module it came from is still in package.loaded. What a poller reloaded
-- out from under DOES cost is STALENESS: it keeps running the OLD closure, which M.reload
-- reports rather than clears.
--
-- So a poller's claim is a courtesy, and it is the reason asyncPending() can be read as "how
-- much repeated work is outstanding" at all rather than "how many raw chains a probe armed".
-- It has a price and it is not theoretical: native/ui/_widget's "ui input dead-man" poller
-- lives for as long as a PalForge panel holds the player's input, so an F9 pressed with a panel
-- open is REFUSED and names that poller. The refusal prints the console line that clears it
-- (asyncReset), the stale cap below drops any single claim after 180 s, and closing the panel
-- retires the poller — three ways out, which is what makes the trade acceptable. Flipping it
-- back is one line in core/poll.lua's M.every (drop the guard("asyncBegin", ...) call), not a
-- change here.

-- The outstanding chains, newest last: { { what = string, t0 = number, cap = number } }.
-- A list rather than the bare counter this used to be, because pf_watch arms TWO chains at
-- once and "1 outstanding" is not something anyone can act on — the refusal has to be able to
-- name what it is waiting for.
local function slots()
    local s = _G.__PalForgeAsyncOut
    if type(s) ~= "table" then s = {}; _G.__PalForgeAsyncOut = s end
    return s
end

-- How long an unnamed chain may stay outstanding before the guard stops believing it. The
-- longest RAW chain armed anywhere in this tree is the 60 s window summary in
-- test/probes/watch, and a nominal LoopAsync + ExecuteInGameThread schedule only ever
-- STRETCHES under load (the 12 s readback was measured longer, never shorter), so three times
-- the longest is a bound no honest chain reaches. This exists because the guard is now WIRED:
-- a chain that dies between begin and done would otherwise refuse every reload for the rest of
-- the session, which is a worse failure than the one being prevented.
--
-- A core/poll POLLER declares no duration, so it lands on this default — and one poller in the
-- tree is legitimately unbounded (native/ui/_widget's "ui input dead-man" runs until the panel
-- closes). Three minutes is therefore also the longest an open panel can hold F9 hostage, which
-- is the right direction for a guard whose whole justification is that pollers are the SOFT
-- case: they hold no UE4SS registry reference, so releasing one early costs staleness, not the
-- engine tick hook.
local DEFAULT_CAP_SEC = 180

-- os.clock is the elapsed clock this tree already uses everywhere (core/spawn's arrival watch,
-- core/poll, test/probes/watch's timeline). It is approximate; at three-minute resolution that
-- does not matter.
local function pending()
    local s, now, i = slots(), os.clock(), 1
    while i <= #s do
        local e = s[i]
        if (now - e.t0) > e.cap then
            table.remove(s, i)
            log.warn(string.format("async guard: %q was declared %.0f s ago and has not "
                .. "released, so it is dropped rather than blocking F9 for the rest of the "
                .. "session — either whatever armed it missed an exit path and never called "
                .. "asyncDone, or it is a core/poll poller that is genuinely still running "
                .. "(one exists: the ui input dead-man, which lives as long as a panel holds "
                .. "input). The poller itself is unaffected; only its claim on F9 is dropped",
                e.what, now - e.t0))
        else
            i = i + 1
        end
    end
    -- The two globals the old counter-only guard exposed, kept because the log line and the
    -- Lua console already knew those names — and now derived from the list on every call, so
    -- neither can go stale. `__PalForgeAsyncWhat` used never to be cleared, so a refusal could
    -- name a chain that had finished minutes earlier.
    _G.__PalForgeAsync = #s
    _G.__PalForgeAsyncWhat = (#s > 0) and s[#s].what or nil
    return #s
end

---Call before scheduling a repeating async callback, and pair it with M.asyncDone on EVERY
---exit path — including the one where the scheduling call itself raised.
---
---`what` is printed verbatim in the refusal, so name the chain and its window ("watch
---pal-spawn-placement 12 s readback"), not the module it lives in. `seconds` is optional and
---only shortens the stale-entry cap above: the entry is dropped after three times what you
---declare, three because a nominal schedule stretches under load rather than shrinking.
---
---Returns a token. Handing that token back to asyncDone releases exactly that chain; calling
---asyncDone() with no argument releases the OLDEST outstanding one, which is the shape this
---file has documented from the start and the shape the existing callers use. Both are correct
---while chains finish in the order they were armed, and the token is there for the day one
---does not.
---@param what string?
---@param seconds number?
---@return table token
function M.asyncBegin(what, seconds)
    local e = {
        what = tostring(what or "unnamed async chain"),
        t0   = os.clock(),
        cap  = (type(seconds) == "number" and seconds > 0) and (seconds * 3) or DEFAULT_CAP_SEC,
    }
    local s = slots()
    s[#s + 1] = e
    pending()   -- also refreshes the two legacy _G mirrors
    return e
end

---Call when that callback's chain has finished, on every exit path including the give-up one.
---Idempotent: releasing a token twice, or releasing when nothing is outstanding, does nothing.
---@param token table?  # what asyncBegin returned; omit to release the oldest chain
---@return integer stillOutstanding
function M.asyncDone(token)
    local s = slots()
    if type(token) == "table" then
        for i = 1, #s do
            if s[i] == token then table.remove(s, i); break end
        end
    elseif #s > 0 then
        table.remove(s, 1)
    end
    return pending()
end

---How many repeating callbacks are outstanding right now.
---@return integer
function M.asyncPending() return pending() end

---What is outstanding right now, oldest first: { { what = string, elapsed = number } }. This is
---what the refusal prints, and it is the readable form for the Lua console when a reload is
---being refused and the reason is not obvious.
---@return table[]
function M.asyncOutstanding()
    pending()
    local out, now = {}, os.clock()
    for i, e in ipairs(slots()) do out[i] = { what = e.what, elapsed = now - e.t0 } end
    return out
end

---Force the counter back to zero. The guard is a courtesy, not a lock: a chain that dies
---between begin and done would otherwise refuse every reload for the rest of the session, which
---is a far worse failure than the one being prevented. (The cap in `pending` above is the
---automatic half of the same argument; this is the manual one, for when waiting out three
---minutes is not acceptable.)
---
---There is NO KEY for it, and this comment used to claim there was one — "bound to F9 with a
---modifier by the kernel". M.bind below registers plain "F9" and nothing else, and the only
---place in the tree that touches the engine is core/keyboard/base/registory's `install`, which
---calls `RegisterKeyBind(code, callback)` — the two-argument form, with no modifier array. So a
---modifier chord is unreachable by construction rather than merely unbound. The escape hatch is
---the Lua console, and the refusal message prints the exact line to paste so it is discoverable
---at the moment it is wanted.
function M.asyncReset()
    local n = M.asyncPending()
    _G.__PalForgeAsyncOut, _G.__PalForgeAsync, _G.__PalForgeAsyncWhat = {}, 0, nil
    log.warn(string.format("async counter reset from %d to 0 — reload is unblocked", n))
    return n
end

---Drop every palforge.* module and load the framework again.
---
---Returns ok, plus how many modules were dropped. A failure leaves the OLD modules unloaded
---and the new ones partially loaded, so it says loudly what broke — fix the file and press
---the key again, which is the whole point of having it on a key.
---@return boolean ok, integer dropped
function M.reload()
    -- Refuse rather than break the tick hook. See the block above asyncBegin: a reload that
    -- lands while a LoopAsync chain is outstanding can cost the session its keybinds entirely.
    local waiting = M.asyncPending()
    if waiting > 0 then
        -- Name every outstanding chain and how long it has been outstanding. The caller needs
        -- to know WHICH one to wait for: the two the tree arms are 12 s and 60 s apart, and
        -- "wait a few seconds" is wrong advice for the second of them.
        local parts = {}
        for _, e in ipairs(M.asyncOutstanding()) do
            parts[#parts + 1] = string.format("%s (armed %.0f s ago)", e.what, e.elapsed)
        end
        log.warn(string.format("reload REFUSED: %d async chain(s) still outstanding: %s. Wait for "
            .. "them to print and press the key again. Reloading now can leave UE4SS holding a "
            .. "dead callback reference, and its answer to that is to remove the engine tick "
            .. "hook, which is what runs every keybind in this mod.",
            waiting, table.concat(parts, "; ")))
        log.warn("no key clears this — asyncReset is bound to nothing. If it never clears by "
            .. "itself (it self-expires after 180 s), the Lua console line is: "
            .. "require('palforge.core.reload').asyncReset()")
        return false, 0
    end

    local names = loadedModules()
    log.info(string.format("reloading %d module(s)", #names))

    for _, name in ipairs(names) do package.loaded[name] = nil end

    -- The api installs the bare globals (Pal, Item, ...); clear them so a module that
    -- disappeared from the api does not linger as a stale global.
    for _, g in ipairs({ "Pal", "Item", "Building", "Skill", "Effect", "Audio", "Mesh", "UI", "Player" }) do
        _G[g] = nil
    end

    local ok, err = pcall(function()
        local registry = require("palforge.core.registry")
        registry.initialize()
    end)

    if not ok then
        log.err("reload FAILED: " .. tostring(err))
        log.err("the framework is half-loaded - fix the file and press the key again")
        return false, #names
    end

    log.info(string.format("reloaded %d module(s) - engine hooks kept from the first load", #names))
    -- Say what that costs, because it is not obvious and it has already wasted a session. A
    -- RegisterHook cannot be unregistered, so a hook armed on the first load keeps running its
    -- ORIGINAL callback — the closure it was created with, capturing the module it came from.
    -- Editing the body of a native source and pressing this key changes nothing about what that
    -- hook does. Handlers, definitions, dispatch and every ordinary module reload fine; a change
    -- INSIDE an event source needs the game restarted.
    log.warn("reload does NOT re-arm native hooks: a change inside an event source (core/event's "
        .. "own hook callbacks) needs a game RESTART to take effect. Everything else is live now.")
    -- The other thing that survives and is not obvious. core/poll's list lives on _G so the one
    -- heartbeat can find it across a reload (that is what makes the poll route safe to reload
    -- into at all), which also means every poller registered BEFORE the press keeps running the
    -- closure it was registered with — the new modules do not re-create it. Reported rather
    -- than cleared: a poller is a watch somebody asked for, it finishes on its own clock, and
    -- silently dropping it would lose the answer it was armed to print.
    --
    -- Reaching this line WITH pollers running is now the exceptional case rather than the
    -- ordinary one, and that is worth knowing when reading the log: core/poll declares every
    -- poller to the guard above, so a live poller normally REFUSES the reload before it gets
    -- here. A non-zero count below therefore means the claim was released without the poller
    -- being — asyncReset() from the console, or the 180 s stale cap — which is exactly the case
    -- where "these are old closures" is not obvious and needs saying.
    local pollers = 0
    pcall(function() pollers = require("palforge.core.poll").count() end)
    if pollers > 0 then
        log.info(string.format("%d poller(s) rode the heartbeat across this reload and keep "
            .. "running the OLD closures they were registered with until they finish", pollers))
    end
    return true, #names
end

---Bind the reload to a key. Called by the kernel; `key` defaults to F9.
---
---One plain key, no chord: registory has no modifier surface (see M.asyncReset). So there is no
---second binding here for asyncReset and there cannot be one without changing the keyboard
---layer — which is why the refusal message carries a console line instead.
---@param key string?
---@return boolean bound
function M.bind(key)
    key = key or "F9"
    local reg = require("palforge.core.keyboard.base.registory")
    return reg.register(key, function()
        local ok, n = M.reload()
        pcall(function()
            local util   = StaticFindObject("/Script/Pal.Default__PalUtility")
            local player = FindFirstOf("PalPlayerCharacter")
            if util and util:IsValid() and player and player:IsValid() then
                util:SendSystemAnnounce(player, string.format(
                    "[PalForge] reload %s (%d modules)", ok and "ok" or "FAILED", n))
            end
        end)
    end, { desc = "reload every palforge.* module" })
end

return M
