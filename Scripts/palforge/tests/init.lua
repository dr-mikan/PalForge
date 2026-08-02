-- PalForge tests: the dev-only test suite bundle. Requiring the suite files below
-- registers each into palforge.core.unittests; run() then executes them all. The
-- kernel (palforge.core.registry) requires this and calls run() ONLY when env.dev.
--
--   local tests = require("palforge.tests")
--   tests.run()          -- run every registered suite, print a summary
--   tests.catalog.dump() -- opt-in DataTable dumper (dev discovery tool)
--
-- Add a suite: create tests/<name>_test.lua that does `T.suite(...)` + `:test(...)`,
-- then require it here so it registers.
local T = require("palforge.core.unittests")

-- Each suite file returns its suite, so this bundle can run exactly its own — the
-- in-game suites under palforge.test register into the same framework and must NOT be
-- dragged into the startup run (they spawn pals and hand out items; F1 runs those).
-- The parentheses matter: require returns (module, loaderpath), and the LAST expression in
-- a table constructor expands to all of its results — without them the loader path lands
-- in the list as a third "suite".
-- Two files, 8 checks, and that is the whole of the startup run — core/registry.lua:91-94
-- calls M.run() here inside `if env.dev`.
--
-- tests/spawn.lua used to sit beside these and was NOT one of them: nothing required it, it
-- was never in this list, and its own header said it was superseded and wrong in two ways
-- (it verified placement at 3 s when the only timed arrivals took ~4-6 s, and its gate was
-- written when :spawn returned false for a spawn that worked). Sitting in a live directory
-- with a warning header is not the same as being marked dead, so on 2026-08-02 it moved to
-- palforge/deprecated/spawn.lua. Nothing here changed with it.
local SUITES = {
    (require("palforge.tests.audio_test")),
    (require("palforge.tests.object_manager_test")),
}

local M = {}

-- Run this bundle's suites. Returns the aggregate results table.
function M.run()
    return T.run(SUITES)
end

-- The catalog DataTable dumper (dev discovery tool; opt-in, never auto-run).
M.catalog = require("palforge.tests.catalog")

return M
