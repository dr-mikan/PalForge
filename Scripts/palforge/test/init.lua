-- palforge/test — the in-game API test suite.
--
-- One case file per domain under test/cases/, each registering a suite with
-- palforge.core.unittests. The kernel requires THIS file at startup, which loads every
-- case and binds the runner to a key; nothing runs until you press it, because these
-- tests spawn pals and hand out items.
--
--   PRESS F1 IN GAME  ->  run every suite, print a summary to UE4SS.log, and put the
--                         pass/fail line on screen.
--
-- F5..F8 are DISCOVERY PROBES rather than tests. They write what the engine actually looks
-- like — class listings, real function signatures, DataTable columns — so the open items in
-- plan/TODO.md can be closed. Each brackets its output with `#### BEGIN <id>` / `#### END
-- <id>`; copy a block out of the log and that item's missing fact is known.
--
--   F5  reflection dump          needs a loaded save
--   F6  the pal's mesh           needs a pal standing near you
--   F8  watch native hooks       needs you to craft / drop / spawn while it runs
--   F8  the title menu button    needs the title screen
--
-- Results land in UE4SS.log under [PalForge.test] and [PalForge.unittests]:
--
--   [PalForge.test][info] running 13 suite(s): schema, registry, definitions, pal, ...
--   [PalForge.unittests][info] SKIP [pal] spawns at a coordinate: no world loaded
--   [PalForge.unittests][info] tests: 276 passed, 0 failed, 18 skipped (294 total)
--   [PalForge.test][info] swept 217 test definition(s)
--
-- A test that needs a world SKIPS rather than fails when there is none, so the same run
-- is meaningful at the title screen and in a save — the 18 skips above are the world ones.
-- Every definition a run creates is namespaced (palforge_test:*) and swept afterwards, so
-- pressing the key repeatedly leaves the registry exactly as it found it.
--
-- BINDING A KEY. That is the whole point of test.bind — one line, four shapes:
--
--   local test = require("palforge.test")
--   test.bind("F1")                              -- everything (installed by default)
--   test.bind("F2", "pal")                       -- one suite
--   test.bind("F3", { "item", "effect" })        -- several
--   test.bind("F5", function()                   -- anything at all
--       Pal.get("ChickenPal"):spawn(Player.coordinate())
--   end, { desc = "spawn a chicken" })
--
-- Put those calls in a file under palforge/core/keyboard/functions/ (it is auto-loaded)
-- or anywhere that runs at startup. Re-binding a key replaces its behaviour in place.
--
-- ADDING A CASE. Create test/cases/<name>.lua:
--
--   local T       = require("palforge.core.unittests")
--   local support = require("palforge.test.support")
--   local s = T.suite("<name>")
--   s:test("does the thing", function(t)
--       local pawn = support.needWorld(t)      -- omit for a pure test
--       t:eq(actual, expected, "what should hold")
--   end)
--   return s
--
-- then add "<name>" to M.CASES below.
local T       = require("palforge.core.unittests")
local reg     = require("palforge.core.keyboard.base.registory")
local support = require("palforge.test.support")
local log     = require("palforge.utils.log").scope("test")

-- The build stamp tools/deploy.sh writes next to the modules it copies. Printed at the top of
-- every run, because Lua that is already loaded STAYS loaded: deploying new files changes
-- nothing in a running game until F9. A log whose stamp predates the deploy you just did is not
-- evidence about the code you just wrote — it has cost a full round of debugging more than once.
-- Absent (a source tree run, or a hand copy) is reported as such rather than faked.
local function buildStamp()
    local ok, stamp = pcall(require, "palforge.build")
    return (ok and type(stamp) == "string") and stamp or "unstamped (not deployed by tools/deploy.sh)"
end

local M = {}

M.support = support

-- Case files, in run order: the pure ones first so a structural break is reported before
-- anything touches the world.
M.CASES = {
    "schema",
    "registry",
    "definitions",
    "pal",
    "item",
    "building",
    "skill",
    "effect",
    "audio",
    "mesh",
    "ui",
    "player",
    "events",
}

-- Discovery probes, and the key each is bound to. A probe is not a test: it does not pass or
-- fail, it writes what the engine actually looks like to UE4SS.log so an open item in
-- plan/TODO.md can be closed. Each one brackets its output with `#### BEGIN <id>` and
-- `#### END <id>`, where <id> is the item's id in that file.
-- ⚠️ F7 IS PALWORLD'S OWN VOLUME KEY. The game claims it before UE4SS sees it, so a probe bound
-- there can never be pressed — `watch` sat on F8 and was simply unreachable. Nothing in the log
-- says so either: the bind succeeds, the key just never arrives.
--
-- So `watch` moved to F8 and `title` to F2. If another key turns out to be taken, change it
-- HERE and nowhere else — this table is the only place a probe key is written, and the kernel
-- prints the whole list at startup so the current bindings are always in the log.
M.PROBES = {
    { name = "reflect", key = "F5", needs = "a loaded save",
      desc = "reflection dump: classes, functions, parameters, DataTable rows" },
    { name = "pal",     key = "F6", needs = "a pal standing near you",
      desc = "the pal's mesh component, its animation class and its materials" },
    { name = "watch",   key = "F8", needs = "a loaded save, then craft / drop / spawn",
      desc = "arms native hooks and logs what fires while you act" },
    { name = "title",   key = "F2", needs = "the title screen",
      desc = "the game's own title menu button, so ours can match it" },
}

-- WHAT A COMMAND DOES, kept apart from HOW IT IS INVOKED. Three input routes have now failed in
-- turn — a key the game had already claimed, a second key, and a console that UE4SS ships
-- switched off — and each time the work itself was fine and only the way in was missing. So the
-- work lives here, named, and anything can run it: a console when there is one, a key when one
-- is free, and core/autorun when there is neither.
M.ACTIONS = {
    pf_tests = function() M.run() end,
-- ---- commands that CREATE the situation a source needs ----
--
-- Two channels are only observable while something specific is happening, and both used to
-- mean "go and play until it does". skill.hit needs a melee blow that actually connects, and
-- skill.equip needs a passive to change on a real pal — which in an ordinary save means
-- catching a pal strong enough to fight, i.e. grinding a game you may not want to grind.
--
-- PalForge can make both. Spawning works and is measured; the passive write goes through the
-- same AddPassiveSkill this tree already hooks. So these produce the situation instead of
-- waiting for it.
pf_spawn = function()
    local Pal = require("palforge.api.pal")
    local coord = support.inFront(400.0, 50.0)
    local ok = coord and Pal.get(support.GAME.pal):spawn(coord)
    log.info(string.format("pf_spawn: %s issued for %s — it arrives in about 4-8 seconds, "
        .. "then hit it with a melee weapon and watch for skill.hit",
        tostring(ok), support.GAME.pal))
end,

pf_teach = function()
    local character = require("palforge.core.character")
    local pal, cls = support.nearbyPal()
    if not pal then
        log.warn("pf_teach: no pal near you — run pf_spawn first, wait for it, then try again")
        return
    end
    -- A PASSIVE, deliberately. Passives go in as FNames through AddPassiveSkill, which is
    -- the call this tree hooks for skill.equip; the ACTIVE-move write is a different call
    -- (AddEquipWaza) and is still opt-in behind _G.PALFORGE_TEST_WRITE_WAZA because it once
    -- correlated with the game closing.
    local SKILL = "Legend"
    log.info(string.format("pf_teach: giving %s to the nearest pal (a %s)", SKILL, tostring(cls)))
    local ok = character.addSkill(pal, SKILL)
    log.info(string.format("pf_teach: %s — watch for skill.equip carrying its first event",
        ok and "the read-back shows it on the pal" or "the read-back did not show it"))
end,
}
for _, p in ipairs(M.PROBES) do
    M.ACTIONS["pf_" .. p.name] = function() M.probe(p.name) end
end

M.loaded = {}   -- case name -> suite (or false when the file failed to load)

---Load every case file so its suite registers. Idempotent: require caches, and
---unittests.suite() returns the existing suite for a name it already has.
---@return integer count
function M.load()
    local n = 0
    for _, name in ipairs(M.CASES) do
        local before = T.byName(name)
        local ok, res = pcall(require, "palforge.test.cases." .. name)
        if ok then
            -- unittests.suite() hands back an existing suite of the same name, so a case
            -- file that collides with someone else's suite would silently append to it and
            -- the key would run their tests too. Say so rather than merging quietly.
            if before then
                log.warn("case '" .. name .. "' shares its suite name with an already "
                    .. "registered suite; the two are now merged")
            end
            M.loaded[name] = res
            n = n + 1
        else
            M.loaded[name] = false
            log.err("case '" .. name .. "' failed to load: " .. tostring(res))
        end
    end
    return n
end

---The suite names THIS module owns, in run order. Deliberately not every suite the
---framework knows about: palforge.tests registers its own headless bundle into the same
---registry, and pressing the key should run the API suite, not everything in the process.
---@return string[]
function M.suites()
    local out = {}
    for _, name in ipairs(M.CASES) do
        if M.loaded[name] then out[#out + 1] = name end
    end
    return out
end

---Run the suites and report. `which` is nil (every suite this module owns), a suite name,
---or a list of them. Returns the results table from core.unittests.
function M.run(which)
    local names = which
    if names == nil then names = M.suites() end
    if type(names) == "string" then names = { names } end

    log.info(string.format("build %s | running %d suite(s): %s",
        buildStamp(), #names, table.concat(names, ", ")))
    support.announce("tests: running " .. #names .. " suite(s)")

    local results = T.run(names)

    -- Defining is permanent, so a run that registered throwaway content has to take it
    -- back out — otherwise pressing the key repeatedly grows the live registry that
    -- core/event walks on every scan.
    local removed = support.sweep()
    if removed > 0 then log.info("swept " .. removed .. " test definition(s)") end

    local line = string.format("tests: %d passed, %d failed, %d skipped",
        results.passed, results.failed, results.skipped)
    support.announce(line)

    -- Repeat each failure on screen; a summary that says "3 failed" and nothing else
    -- means going back to the log anyway.
    for _, suite in ipairs(results.suites) do
        for _, f in ipairs(suite.failures) do
            support.announce(string.format("FAIL [%s] %s: %s", suite.name, f.test, f.msg))
        end
    end
    return results
end

---Bind a key to a test run. `what` is nil (every suite), a suite name, a list of names,
---or a function to call. `opts` is passed through to the keybind registry (e.g. desc).
---@param key string        # "F1", "F2", ... as named in UE4SS's Key table
---@param what nil|string|string[]|function
---@param opts table?
---@return boolean bound
function M.bind(key, what, opts)
    local desc
    local fn
    if type(what) == "function" then
        fn, desc = what, (opts and opts.desc) or "custom"
    else
        local names = what
        if type(names) == "string" then names = { names } end
        fn = function() M.run(names) end
        desc = (opts and opts.desc)
            or (names and ("tests: " .. table.concat(names, ", ")) or "tests: all suites")
    end

    local merged = { desc = desc }
    for k, v in pairs(opts or {}) do merged[k] = v end
    return reg.register(key, fn, merged)
end

---Run one discovery probe by name ("reflect", "pal", "watch", "title"). Returns how many of
---its sections ran; 0 means the probe said what it needed and stopped.
---@param name string
---@return integer sections
function M.probe(name)
    local ok, mod = pcall(require, "palforge.test.probes." .. tostring(name))
    if not ok then
        log.err("probe '" .. tostring(name) .. "' failed to load: " .. tostring(mod))
        return 0
    end
    if type(mod.run) ~= "function" then
        log.err("probe '" .. tostring(name) .. "' has no run()")
        return 0
    end
    log.info("probe " .. name .. " starting - copy everything between the BEGIN and END markers")
    support.announce("probe " .. name .. ": writing to UE4SS.log")
    local ran, err = pcall(mod.run)
    if not ran then
        log.err("probe '" .. name .. "' raised: " .. tostring(err))
        return 0
    end
    return tonumber(err) or 0
end

---What is bound where, as printable lines. Handy from a console command.
---@return string[]
function M.bindings()
    local out = {}
    for _, key in ipairs(reg.keys()) do
        local rec = reg.bound[key]
        out[#out + 1] = string.format("%-4s %s", key, (rec.opts and rec.opts.desc) or "?")
    end
    return out
end

-- Wire it up on require: load the cases, put the whole run on F1, and give each discovery
-- probe its own key. Re-bind any of them from your own code — M.bind replaces a binding in
-- place, so `test.bind("F5", "pal")` would take F5 back for a suite.
M.load()
M.bind("F1")
for _, p in ipairs(M.PROBES) do
    M.bind(p.key, function() M.probe(p.name) end,
        { desc = string.format("probe %s (%s) - needs %s", p.name, p.desc, p.needs) })
end

-- A CONSOLE COMMAND FOR EVERY PROBE, so a key the game has taken can never block one again.
-- F7 turned out to be Palworld's own volume control: the bind succeeded, the key never arrived,
-- and from the log that was indistinguishable from a probe that ran and found nothing. Keys are
-- convenient and they are not ours to reserve; a command is.
--
--   pf_watch     pf_reflect     pf_pal     pf_title     pf_tests
--
-- Open the UE4SS console (its GUI window) and type one. Same work, same output, no key involved.
local function installCommands()
    if type(RegisterConsoleCommandHandler) ~= "function" then
        log.warn("console commands unavailable this session; the keys above are the only way in")
        return
    end
    -- REGISTERING A COMMAND IS NOT THE SAME AS BEING ABLE TO TYPE ONE. UE4SS ships with its
    -- console switched off, and this handler registers perfectly well into a window that does
    -- not exist — which is exactly the failure the console was added to escape from, one layer
    -- further down. The log said "console commands: pf_spawn pf_teach ..." while there was
    -- nowhere to put them.
    --
    -- Turn it on in ue4ss/UE4SS-settings.ini and restart the game:
    --     ConsoleEnabled = 1
    --     GuiConsoleEnabled = 1
    --     GuiConsoleVisible = 1
    -- The setting cannot be read from here, so this is a note rather than a check.
    -- The body is queued onto the game thread, because everything it touches is a live UObject.
    -- It is also wrapped: a console command that raises takes UE4SS's handler down with it, and
    -- a typo in a dev command is not worth a broken console.
    local function register(name, run)
        pcall(function()
            RegisterConsoleCommandHandler(name, function()
                local body = function()
                    local ok, err = pcall(run)
                    if not ok then log.err(name .. " failed: " .. tostring(err)) end
                end
                if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(body) else body() end
                return true
            end)
        end)
    end
    for name, run in pairs(M.ACTIONS) do register(name, run) end

    local names = {}
    for name in pairs(M.ACTIONS) do names[#names + 1] = name end
    table.sort(names)
    log.info("console commands: " .. table.concat(names, "  "))
    log.info("if you cannot type those, UE4SS's console is off: set ConsoleEnabled, "
        .. "GuiConsoleEnabled and GuiConsoleVisible to 1 in ue4ss/UE4SS-settings.ini and restart")
end
installCommands()

-- Print the bindings once, at load. A key the GAME has already claimed still binds successfully
-- here and simply never fires — that is how `watch` sat unreachable on Palworld's volume key —
-- so the log has to carry which key is on what, or a probe that cannot be pressed looks exactly
-- like a probe that found nothing.
for _, line in ipairs(M.bindings()) do log.info("key " .. line) end

return M
