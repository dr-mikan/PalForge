-- PalForge utils.unittests: a tiny, self-contained unit-test framework. No external
-- deps (only palforge.utils.log for the summary). This is the BASE that palforge.test.units
-- extends — content mods author suites the same way.
--
--   local T = require("palforge.core.unittests")
--   local s = T.suite("audio")
--   s:test("plays", function(t)
--       t:assert(cond, "must be true")
--       t:eq(a, b, "a equals b")
--   end)
--   local results = T.run()   -- runs every registered suite; prints a summary
--
-- A failing assertion aborts its own test (raises), the runner catches it and marks
-- that test failed, then moves on. A test that cannot run right now calls t:skip(why)
-- and is counted separately — that is how the in-game suites stay green outside a
-- loaded world. T.run() returns
--   { passed, failed, skipped, total, needs = { <need> -> count },
--     suites = { { name, passed, failed, skipped, total, failures, skips, needs } } }
--
-- A SKIP CARRIES A DIRECTION, and that is the difference between a summary that means
-- something and one that does not. The audit that produced plan/TODO.md counted 26 checks in
-- the API suite that skip when there is NO world and 9 that skip when there IS one (the UI
-- element's refusal paths, the events source gate, the player facade's no-world half); a
-- headless run of the whole suite on 2026-08-02, after the conversions below, reported 27
-- world-directed skips. "N skipped" cannot tell the two directions apart, so a run that
-- measured almost nothing and a run that measured almost everything printed the same green
-- line. Every skip now says which session state WOULD have run it:
--
--   t:skipNeedsWorld(why)          -- load a save and press the key again
--   t:skipNeedsNoWorld(why)        -- quit to the title screen and press the key again
--   t:skipNeedsNoEngine(why)       -- no UE4SS at all: only a headless lua5.4 run measures it
--   t:skipNeedsHook(id, why)       -- only test/hooks/<id> can measure it; `pf_hook_<id>` runs it
--   t:skipOptIn(why)               -- deliberately off: it writes to a real save
--   t:skipNeedsSetup(why)          -- a world IS loaded, but not in the state this needs
--   t:skipUnanswerable(why)        -- this session could not answer — that IS the finding
--   t:skip(why)                    -- unclassified; still counted, and reported as unstated
--
-- and M.run() prints the breakdown plus the sentence saying how many runs are needed. The bare
-- one-argument t:skip(why) still works exactly as it did — case files convert at their own
-- pace, and everything unconverted is reported as "did not say" rather than disappearing.
--
-- ⚠️ THERE ARE THREE ENVIRONMENTS, NOT TWO, and modelling only two is what the first real
-- in-game run (2026-08-02 16:39:05 title, 16:40:18 in a save) reported as four FAILURES:
--
--   headless          lua5.4, no UE4SS globals at all
--   engine, no world  the game is running and sitting on the title screen
--   engine and world  a save is loaded and there is a player pawn
--
-- A check whose claim is "with no engine under it, this refuses" is green in the first and RED
-- in the other two, because UE4SS being present is enough to make it false — no save required.
-- Both game states reported the same four failures for exactly that reason, and none of the
-- four was a defect in the code under test. NEEDS.NOENGINE is that third direction, and the
-- predicate behind it asks whether UE4SS's own globals exist, never whether a pawn does
-- (test/support.lua: M.engine / M.needNoEngine).
--
-- THE WORLD PAIR IS ONE PREDICATE, ASKED TWICE. skipNeedsNoWorld is the exact negation of
-- skipNeedsWorld — both sides go through test/support.lua's M.worldLoaded() — so a gated PAIR
-- always has exactly one half running. The same title-screen run proved what happens when they
-- disagree: the world half asked for a player pawn (absent at the title, correctly) while the
-- inverse half asked whether an OWNER existed, and a PalPlayerController and a GameInstance are
-- both up at the title screen, so BOTH directions closed at once and 6 checks that should have
-- been the whole point of that run reported "6 need no world" instead of running. An owner is
-- not a world; it is an ENGINE, and those six are NEEDS.NOENGINE now.
local log = require("palforge.utils.log").scope("unittests")

local M = {}
M._suites = {}   -- every suite created via M.suite(); M.run() runs all of these

-- ---- skip directions ----
-- The eight values a skip can carry: seven states it is waiting on, plus the bucket for a bare
-- t:skip(reason) that named none. The value is what the summary prints, so it is a short
-- human string rather than an enum number; NEEDS_PHRASE below turns it into the clause the
-- summary line reads with.
M.NEEDS = {
    WORLD    = "world",       -- needs a loaded save
    NOWORLD  = "no-world",    -- needs the title screen (engine up, no world loaded)
    NOENGINE = "no-engine",   -- needs NO UE4SS at all: only a headless lua5.4 run measures it
    HOOK     = "hook",        -- needs a declared test/hooks/<id> run, C7
    OPTIN    = "opt-in",      -- deliberately off; it would write to the tester's save
    SETUP    = "setup",       -- a world is loaded but is not in the state the check needs
    SESSION  = "session",     -- this session could not answer (a native route is absent)
    UNSTATED = "unstated",    -- a bare t:skip(reason) that has not declared a direction
}

-- Report order, so the breakdown reads the same way every run.
local NEEDS_ORDER = { M.NEEDS.WORLD, M.NEEDS.NOWORLD, M.NEEDS.NOENGINE, M.NEEDS.HOOK,
                      M.NEEDS.OPTIN, M.NEEDS.SETUP, M.NEEDS.SESSION, M.NEEDS.UNSTATED }

local NEEDS_PHRASE = {
    [M.NEEDS.WORLD]    = "need a world",
    [M.NEEDS.NOWORLD]  = "need no world",
    [M.NEEDS.NOENGINE] = "need no engine",
    [M.NEEDS.HOOK]     = "need a declared test/hooks run",
    [M.NEEDS.OPTIN]    = "are opt-in",
    [M.NEEDS.SETUP]    = "need the world set up differently",
    [M.NEEDS.SESSION]  = "could not be answered by this session",
    [M.NEEDS.UNSTATED] = "did not say which",
}

local NEEDS_VALID = {}
for _, n in ipairs(NEEDS_ORDER) do NEEDS_VALID[n] = true end

-- ---- the three ENVIRONMENTS ----
-- Three of the eight directions are not "this session lacked something" but "this check belongs
-- to a different environment", and they are mutually exclusive: a run is headless, or on the
-- title screen, or in a save, and never two of those. Everything the summary says about how
-- many runs a full measurement takes is derived from THIS table and nowhere else, so adding a
-- fourth environment later means adding one row rather than editing four sentences.
local ENVIRONMENT_ORDER = { M.NEEDS.WORLD, M.NEEDS.NOWORLD, M.NEEDS.NOENGINE }

local ENVIRONMENT = {
    [M.NEEDS.WORLD] = {
        where  = "inside a loaded save",
        why    = "there is no world loaded",
        action = "load a save and press the key again",
    },
    [M.NEEDS.NOWORLD] = {
        where  = "at the title screen",
        why    = "a world IS loaded",
        action = "quit to the title screen and press the key again",
    },
    [M.NEEDS.NOENGINE] = {
        where  = "with no engine under them (a headless lua5.4 run)",
        why    = "UE4SS is under this run, and these assert what PalForge does with NO engine",
        action = "no key press in any session state reaches them, so run the suite headless: "
              .. "`cd Scripts && lua5.4 -e 'package.path=\"./?.lua;./?/init.lua;\"..package.path; "
              .. "local e=require(\"palforge.env\") e.dev=true e.debug=true "
              .. "require(\"palforge.test\").run()'`",
    },
}

-- A zeroed counter table, so the breakdown can always be indexed without a nil check.
local function newNeeds()
    local t = {}
    for _, n in ipairs(NEEDS_ORDER) do t[n] = 0 end
    return t
end

---The breakdown clause for a `needs` table: "3 need a world, 1 needs no world". Exported
---because the run summary is printed in TWO places with two different audiences — this file
---writes the full form to UE4SS.log, and test/init.lua puts a short form on the player's
---SCREEN, which is the surface a tester actually reads while the game is running. The
---direction is the whole point of the skip regime, so the screen must not be the one place it
---is dropped; and a second hand-written copy of these phrases is how the two would drift.
---@param needs table   # M.NEEDS value -> count
---@return string?      # nil when nothing was skipped
function M.needsPhrase(needs)
    if type(needs) ~= "table" then return nil end
    local parts = {}
    for _, n in ipairs(NEEDS_ORDER) do
        if (needs[n] or 0) > 0 then
            parts[#parts + 1] = string.format("%d %s", needs[n], NEEDS_PHRASE[n])
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

---Which ENVIRONMENTS this run left unmeasured, in report order. Empty when the run covered
---every environment its checks name.
---@param needs table   # M.NEEDS value -> count
---@return string[]     # a subset of { NEEDS.WORLD, NEEDS.NOWORLD, NEEDS.NOENGINE }
function M.environmentsPending(needs)
    local out = {}
    if type(needs) ~= "table" then return out end
    for _, n in ipairs(ENVIRONMENT_ORDER) do
        if (needs[n] or 0) > 0 then out[#out + 1] = n end
    end
    return out
end

---Is this run part of a measurement rather than the whole of one? True when checks from more
---than one environment are waiting, which is the state in which NO SINGLE RUN has measured
---everything.
---
---⚠️ THE NAME IS KEPT AND THE MEANING IS WIDENED, deliberately. It used to be "the world half
---and the no-world half are both waiting" and there were only two environments to be waiting
---in; there are three now (see the ENVIRONMENT table above), so the honest question is "is more
---than one environment waiting". test/init.lua calls this to decide whether to put the sentence
---on the player's SCREEN, and every case that used to answer true still answers true — it just
---also answers true when the headless-only checks are the ones that did not run. A second
---function with a second name would have left that screen line silently narrower than the log.
---@param needs table
---@return boolean
function M.needsTwoRuns(needs)
    return #M.environmentsPending(needs) > 1
end

---The sentence that says which environments this run did not measure and what would. nil when
---it measured every environment its checks name.
---
---Exported for the same reason needsPhrase is: the run summary is written in TWO places (this
---file to UE4SS.log, test/init.lua to the player's screen) and the wording of the environment
---sentence is the thing a tester acts on, so it is formatted once here rather than spelled a
---second time there.
---@param needs table
---@return string?
function M.needsRunsSentence(needs)
    local pending = M.environmentsPending(needs)
    if #pending == 0 then return nil end

    -- One environment waiting: name it, say why it did not run, and say what would run it.
    if #pending == 1 then
        local e = ENVIRONMENT[pending[1]]
        return string.format("tests: %d check(s) were not measured because %s — %s.",
            needs[pending[1]], e.why, e.action)
    end

    -- More than one: the run is a fraction of a measurement and the count of runs is the point.
    local parts = {}
    for _, n in ipairs(pending) do
        parts[#parts + 1] = string.format("%d check(s) only run %s", needs[n], ENVIRONMENT[n].where)
    end
    local last = table.remove(parts)
    return string.format("tests: NO SINGLE RUN MEASURES EVERYTHING — %s and %s. Run it once in "
        .. "each; a green run is %d runs.", table.concat(parts, ", "), last, #pending)
end

-- ---- assertion context (the `t` handed to each test body) ----
-- Sentinel-wrapped errors so the runner can tell an assertion failure and a deliberate
-- skip from an unexpected Lua error (all three stop the test; only the last is a bug).
local function failAssert(msg)
    error({ __unittest_fail = true, msg = msg or "assertion failed" }, 0)
end

local Assert = {}
Assert.__index = Assert

-- Stop this test without failing it: the precondition it needs is not there (no world
-- loaded, no player pawn, a native route this session does not have).
--
-- `needs` is one of M.NEEDS and says what WOULD have run it; omitting it is still legal and
-- lands in the "unstated" bucket. A direction that is not one of the eight is a FAILURE, not
-- a skip — a typo'd direction would otherwise silently make the check invisible again, which
-- is the exact defect this API exists to remove.
function Assert:skip(reason, needs)
    if needs ~= nil and not NEEDS_VALID[needs] then
        self:fail("unittests: unknown skip direction '" .. tostring(needs)
            .. "'; use one of T.NEEDS.WORLD / NOWORLD / NOENGINE / HOOK / OPTIN / SETUP / SESSION")
    end
    error({ __unittest_skip = true, msg = reason or "precondition not met",
            needs = needs or M.NEEDS.UNSTATED }, 0)
end

-- The seven directions, spelled as their own calls so a case file reads as a statement about
-- what is missing rather than a string the summary has to guess at.

---This check only runs inside a loaded save.
function Assert:skipNeedsWorld(reason)
    self:skip(reason or "no world loaded", M.NEEDS.WORLD)
end

---This check only runs with NO world — the title screen, with the engine still up. The inverse
---gate: it is verifying a refusal path that a loaded world would turn into a real action.
---
---⚠️ IT IS THE ENGINE-IS-UP HALF. If what the check actually needs is that there be no engine
---AT ALL — no PlayerController, no GameInstance, no LoadAsset — this is the wrong direction and
---skipNeedsNoEngine is the right one, because a PalPlayerController and a GameInstance are both
---already up on the title screen (measured 2026-08-02, 16:39:05: six ui checks gated on
---widget.owner() skipped at the title screen, which is the one state they were written for).
function Assert:skipNeedsNoWorld(reason)
    self:skip(reason or "a world is loaded; this asserts the no-world path", M.NEEDS.NOWORLD)
end

---This check only runs with NO ENGINE AT ALL — a headless lua5.4 process. It asserts what a
---call does when the UE4SS globals it needs are simply not there, and UE4SS being loaded is
---enough to falsify it: no save has to be loaded, so BOTH game states are the wrong one.
---
---⚠️ NOT skipNeedsNoWorld, and the difference is the whole of finding 1 from the 2026-08-02 run.
---Four checks whose failure messages read "nothing resolves without a game", "headless there is
---no live table" and "nothing is readable with no game" were green under lua5.4 and red at the
---title screen AND in a save, identically, because "a game" in those sentences means the ENGINE
---and the suite only had a gate for the WORLD. A check gated this way is honest about the fact
---that no key press in any session state can reach it.
function Assert:skipNeedsNoEngine(reason)
    self:skip(reason or "UE4SS is loaded; this asserts the no-engine path", M.NEEDS.NOENGINE)
end

---This check can only be measured with the game doing something a test cannot make it do, so
---it is measured by a DECLARED hook under test/hooks/ (C7) and named here. A skip that names
---a hook is traceable to something that can actually be run; a skip that names nothing is
---the thing this regime exists to abolish, so an id is required and its absence is a failure.
---@param hookId string   # the plan/TODO.md item id, e.g. "pal-skills-equip"
function Assert:skipNeedsHook(hookId, reason)
    if type(hookId) ~= "string" or #hookId == 0 then
        self:fail("unittests: skipNeedsHook(hookId, reason) needs the test/hooks/<id> that "
            .. "measures this; a skip with no traceable route is what the explicit-skip "
            .. "regime replaced")
    end
    -- The runnable name, spelled the way the hook runner generates it: autorun.txt reads
    -- "[delay] name" and cannot carry an argument, so every hook gets its own action with the
    -- dashes turned into underscores (test/hooks/init.lua M.actionName is the authority; this
    -- is the one line of it repeated here so the base framework keeps no dependency on the
    -- in-game hook layer). `pf_hooks` lists every declared hook and why each would skip.
    local action = "pf_hook_" .. tostring(hookId):gsub("%-", "_")
    self:skip(string.format("%s [measured by test/hooks/%s — list with `pf_hooks`, run it "
        .. "with `%s`]", reason or "only measurable with the game running", hookId, action),
        M.NEEDS.HOOK)
end

---Deliberately off by default: running it would write to the tester's real save.
function Assert:skipOptIn(reason)
    self:skip(reason or "opt-in: this writes to a real save", M.NEEDS.OPTIN)
end

---A world IS loaded, but not in the state this check needs (no pal standing nearby, the
---ailment is already on the pawn, the inventory is empty). Actionable by the tester.
function Assert:skipNeedsSetup(reason)
    self:skip(reason or "the world is not in the state this check needs", M.NEEDS.SETUP)
end

---This session could not answer: a native route, global or catalog the check reads is not
---there. Distinct from every other direction because pressing the key again in another state
---will not help — the skip text IS the finding.
function Assert:skipUnanswerable(reason)
    self:skip(reason or "this session could not answer", M.NEEDS.SESSION)
end

function Assert:assert(cond, msg)
    self.count = self.count + 1
    if not cond then failAssert(msg or "expected a truthy value") end
end

function Assert:eq(a, b, msg)
    self.count = self.count + 1
    if a ~= b then
        failAssert(msg or ("expected " .. tostring(b) .. ", got " .. tostring(a)))
    end
end

function Assert:neq(a, b, msg)
    self.count = self.count + 1
    if a == b then failAssert(msg or ("expected value ~= " .. tostring(b))) end
end

function Assert:truthy(v, msg) self:assert(v and true or false, msg) end
function Assert:falsy(v, msg)  self:assert(not v, msg) end

function Assert:type(v, want, msg)
    self.count = self.count + 1
    if type(v) ~= want then
        failAssert(msg or ("expected a " .. want .. ", got " .. type(v)))
    end
end

-- Floats that came back through the engine rarely compare exactly; give them a window.
function Assert:near(a, b, eps, msg)
    self.count = self.count + 1
    eps = eps or 0.001
    if type(a) ~= "number" or type(b) ~= "number" or math.abs(a - b) > eps then
        failAssert(msg or ("expected " .. tostring(b) .. " +/- " .. tostring(eps)
                           .. ", got " .. tostring(a)))
    end
end

-- Assert that `fn` RAISES, optionally that the message matches `pattern` (a plain
-- substring, not a Lua pattern — the api's error text is full of magic characters).
-- Returns the message so a caller can assert more about it.
function Assert:errors(fn, pattern, msg)
    self.count = self.count + 1
    local ok, e = pcall(fn)
    if ok then failAssert(msg or "expected this call to raise, but it returned") end
    local text = (type(e) == "table" and e.msg) and tostring(e.msg) or tostring(e)
    if pattern and not text:find(pattern, 1, true) then
        failAssert(msg or ("error should mention " .. string.format("%q", pattern)
                           .. ", got: " .. text))
    end
    return text
end

-- Explicitly fail the current test.
function Assert:fail(msg)
    self.count = self.count + 1
    failAssert(msg or "explicit failure")
end

-- ---- suite ----
local Suite = {}
Suite.__index = Suite

-- Add a test case. `fn(t)` receives an assertion context. Chainable.
function Suite:test(name, fn)
    assert(type(name) == "string", "unittests: test name (string) required")
    assert(type(fn) == "function", "unittests: test body (function) required")
    self.tests[#self.tests + 1] = { name = name, fn = fn }
    return self
end

-- Run something once after this suite's LAST test, whatever the results were. This is where
-- a suite gives back what it took: the API suites register throwaway definitions, and
-- object_manager has no expiry, so a suite that does not clean up after itself grows the
-- registry that namespaced dispatch walks on every missed lookup, once per key press.
-- Chainable. A teardown that raises is logged and does not fail the suite — it ran after
-- every measurement was already taken, so it cannot invalidate one.
function Suite:after(fn)
    assert(type(fn) == "function", "unittests: teardown body (function) required")
    self.teardowns = self.teardowns or {}
    self.teardowns[#self.teardowns + 1] = fn
    return self
end

-- Run just this suite. Returns
--   { name, passed, failed, skipped, total, failures, skips, needs }
-- where `skips[i].needs` is one of M.NEEDS and `needs` counts them by direction.
function Suite:run()
    local passed, failed, skipped, failures, skips = 0, 0, 0, {}, {}
    local needs = newNeeds()
    for _, tc in ipairs(self.tests) do
        local ctx = setmetatable({ count = 0 }, Assert)
        local ok, e = pcall(tc.fn, ctx)
        if ok then
            passed = passed + 1
        elseif type(e) == "table" and e.__unittest_skip then
            skipped = skipped + 1
            local need = NEEDS_VALID[e.needs] and e.needs or M.NEEDS.UNSTATED
            needs[need] = needs[need] + 1
            skips[#skips + 1] = { test = tc.name, msg = e.msg, needs = need }
            log.info(string.format("SKIP [%s] %s (%s): %s",
                self.name, tc.name, need, tostring(e.msg)))
        else
            failed = failed + 1
            local msg = (type(e) == "table" and e.__unittest_fail) and e.msg or tostring(e)
            failures[#failures + 1] = { test = tc.name, msg = msg }
            log.err(string.format("FAIL [%s] %s: %s", self.name, tc.name, msg))
        end
    end
    for _, fn in ipairs(self.teardowns or {}) do
        local okDown, err = pcall(fn, self)
        if not okDown then
            log.warn(string.format("teardown [%s] raised: %s", self.name, tostring(err)))
        end
    end
    return { name = self.name, passed = passed, failed = failed, skipped = skipped,
             total = passed + failed + skipped, failures = failures, skips = skips,
             needs = needs }
end

-- Create (and globally register) a suite. Re-creating a name returns the SAME suite so a
-- module that is required twice adds its cases once instead of duplicating the whole run.
function M.suite(name)
    name = name or "suite"
    local existing = M.byName(name)
    if existing then return existing end
    local s = setmetatable({ name = name, tests = {} }, Suite)
    M._suites[#M._suites + 1] = s
    return s
end

-- There is deliberately no M.reset(). It existed as "drop every registered suite, mainly for
-- tooling" and had no caller anywhere in the tree: the suite list is process-lifetime, and the
-- one thing that really does need a fresh slate — reloading edited case files — is F9, which
-- drops every palforge.* module (core/reload.lua) and so rebuilds this table from nothing.
-- A second, silent way to empty the registry is a trap rather than a feature.

-- A registered suite by name, or nil.
function M.byName(name)
    for _, s in ipairs(M._suites) do
        if s.name == name then return s end
    end
    return nil
end

-- The names of every registered suite, sorted.
function M.names()
    local out = {}
    for _, s in ipairs(M._suites) do out[#out + 1] = s.name end
    table.sort(out)
    return out
end

-- Run suites and print a one-line summary via utils.log. Pass an explicit list of suites,
-- or a list/single NAME to run only those; otherwise runs every registered suite.
-- Returns { passed, failed, skipped, total, suites = { <per-suite result> } }.
function M.run(suites)
    if type(suites) == "string" then suites = { suites } end
    if type(suites) == "table" and type(suites[1]) == "string" then
        local picked = {}
        for _, n in ipairs(suites) do
            local s = M.byName(n)
            if s then picked[#picked + 1] = s
            else log.warn("no suite named '" .. n .. "' (have: " .. table.concat(M.names(), ", ") .. ")") end
        end
        suites = picked
    end
    suites = suites or M._suites

    local passed, failed, skipped, results = 0, 0, 0, {}
    local needs = newNeeds()
    for _, s in ipairs(suites) do
        local r = s:run()
        passed  = passed + r.passed
        failed  = failed + r.failed
        skipped = skipped + r.skipped
        for _, n in ipairs(NEEDS_ORDER) do needs[n] = needs[n] + (r.needs and r.needs[n] or 0) end
        results[#results + 1] = r
    end
    local total = passed + failed + skipped
    log.info(string.format("tests: %d passed, %d failed, %d skipped (%d total)",
        passed, failed, skipped, total))

    -- THE LINE THAT MAKES A GREEN RUN READABLE. "0 failed" says nothing on its own when a
    -- third of the checks never ran; what a reader needs is which of them would run in the
    -- state they are NOT in, and whether pressing the key again would help at all.
    if skipped > 0 then
        log.info(string.format("tests: %d skipped (%s)", skipped,
            M.needsPhrase(needs) or "no direction recorded"))

        -- The environment sentence, and it is a statement of fact about this suite rather than
        -- advice: checks written for different environments cannot both run in one press, so no
        -- single press has ever measured everything. THREE environments now (headless / title
        -- screen / loaded save), and the wording is built from the ENVIRONMENT table at the top
        -- of this file so the third one is named exactly the way the first two are.
        local sentence = M.needsRunsSentence(needs)
        if sentence then log.info(sentence) end
        if needs[M.NEEDS.HOOK] > 0 then
            log.info(string.format("tests: %d check(s) can only be measured by a declared hook "
                .. "— `pf_hooks` lists them with the reason each one would skip, and each SKIP "
                .. "line above names the action that runs its own.", needs[M.NEEDS.HOOK]))
        end
    end

    return { passed = passed, failed = failed, skipped = skipped, total = total,
             needs = needs, suites = results }
end

return M
