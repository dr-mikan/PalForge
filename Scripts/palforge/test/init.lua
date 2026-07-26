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

    log.info(string.format("running %d suite(s): %s", #names, table.concat(names, ", ")))
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

-- Wire it up on require: load the cases, then put the whole run on F1. Re-bind it from
-- your own code if F1 is taken — M.bind replaces a binding in place.
M.load()
M.bind("F1")

return M
