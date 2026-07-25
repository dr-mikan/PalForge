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
-- that test failed, then moves on. T.run() collects pass/fail counts and returns
--   { passed, failed, total, suites = { { name, passed, failed, total, failures } } }
local log = require("palforge.utils.log").scope("unittests")

local M = {}
M._suites = {}   -- every suite created via M.suite(); M.run() runs all of these

-- ---- assertion context (the `t` handed to each test body) ----
-- Sentinel-wrapped error so the runner can tell an assertion failure from an
-- unexpected Lua error (both fail the test, but the message is cleaner for asserts).
local function failAssert(msg)
    error({ __unittest_fail = true, msg = msg or "assertion failed" }, 0)
end

local Assert = {}
Assert.__index = Assert

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

-- Run just this suite. Returns { name, passed, failed, total, failures }.
function Suite:run()
    local passed, failed, failures = 0, 0, {}
    for _, tc in ipairs(self.tests) do
        local ctx = setmetatable({ count = 0 }, Assert)
        local ok, e = pcall(tc.fn, ctx)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            local msg = (type(e) == "table" and e.__unittest_fail) and e.msg or tostring(e)
            failures[#failures + 1] = { test = tc.name, msg = msg }
            log.err(string.format("FAIL [%s] %s: %s", self.name, tc.name, msg))
        end
    end
    return { name = self.name, passed = passed, failed = failed,
             total = passed + failed, failures = failures }
end

-- Create (and globally register) a suite.
function M.suite(name)
    local s = setmetatable({ name = name or "suite", tests = {} }, Suite)
    M._suites[#M._suites + 1] = s
    return s
end

-- Run suites and print a one-line summary via utils.log. Pass an explicit list to
-- run ONLY those (e.g. an ad-hoc pass/fail check); otherwise runs every registered
-- suite. Returns { passed, failed, total, suites = { <per-suite result> } }.
function M.run(suites)
    suites = suites or M._suites
    local passed, failed, results = 0, 0, {}
    for _, s in ipairs(suites) do
        local r = s:run()
        passed = passed + r.passed
        failed = failed + r.failed
        results[#results + 1] = r
    end
    local total = passed + failed
    log.info(string.format("tests: %d passed, %d failed (%d total)", passed, failed, total))
    return { passed = passed, failed = failed, total = total, suites = results }
end

-- Drop all globally registered suites (fresh slate; mainly for tooling/tests).
function M.reset() M._suites = {} end

return M
