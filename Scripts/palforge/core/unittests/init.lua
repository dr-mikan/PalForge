-- PalForge utils.unittests: a tiny, self-contained unit-test framework. No external
-- deps (only palforge.utils.log for the summary). This is the BASE that palforge.tests
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
--   { passed, failed, skipped, total, suites = { { name, passed, failed, skipped,
--     total, failures, skips } } }
local log = require("palforge.utils.log").scope("unittests")

local M = {}
M._suites = {}   -- every suite created via M.suite(); M.run() runs all of these

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
function Assert:skip(reason)
    error({ __unittest_skip = true, msg = reason or "precondition not met" }, 0)
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

-- Run just this suite. Returns { name, passed, failed, skipped, total, failures, skips }.
function Suite:run()
    local passed, failed, skipped, failures, skips = 0, 0, 0, {}, {}
    for _, tc in ipairs(self.tests) do
        local ctx = setmetatable({ count = 0 }, Assert)
        local ok, e = pcall(tc.fn, ctx)
        if ok then
            passed = passed + 1
        elseif type(e) == "table" and e.__unittest_skip then
            skipped = skipped + 1
            skips[#skips + 1] = { test = tc.name, msg = e.msg }
            log.info(string.format("SKIP [%s] %s: %s", self.name, tc.name, tostring(e.msg)))
        else
            failed = failed + 1
            local msg = (type(e) == "table" and e.__unittest_fail) and e.msg or tostring(e)
            failures[#failures + 1] = { test = tc.name, msg = msg }
            log.err(string.format("FAIL [%s] %s: %s", self.name, tc.name, msg))
        end
    end
    return { name = self.name, passed = passed, failed = failed, skipped = skipped,
             total = passed + failed + skipped, failures = failures, skips = skips }
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
    for _, s in ipairs(suites) do
        local r = s:run()
        passed  = passed + r.passed
        failed  = failed + r.failed
        skipped = skipped + r.skipped
        results[#results + 1] = r
    end
    local total = passed + failed + skipped
    log.info(string.format("tests: %d passed, %d failed, %d skipped (%d total)",
        passed, failed, skipped, total))
    return { passed = passed, failed = failed, skipped = skipped, total = total, suites = results }
end

-- Drop all globally registered suites (fresh slate; mainly for tooling/tests).
function M.reset() M._suites = {} end

return M
