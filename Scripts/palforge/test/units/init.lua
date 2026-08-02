-- palforge/test/units — THE HEADLESS BUNDLE, run at boot.
--
-- Two directories used to hold PalForge's tests and the split was an accident rather than a
-- design: `palforge/tests/` (plural) held these two suites plus the DataTable dumper, and
-- `palforge/test/` (singular) held everything else. Nothing in the names said which was which,
-- production code reached into BOTH, and a one-character difference is the kind that is read
-- wrong forever. There is one tree now — `palforge/test/` — and this is its boot corner:
--
--   test/units/    THESE. Pure Lua, no engine, no world. Run at STARTUP, every dev session.
--   test/cases/    the in-game API suite. Runs on F1, because it spawns pals and hands out items.
--   test/hooks/    measurements that cannot be taken with the game switched off. Never auto-run.
--   test/probes/   discovery dumps — not tests; they pass and fail nothing.
--   test/tools/    dev instruments (the DataTable dumper behind ps_catalog).
--
-- WHAT BELONGS HERE is a narrow rule: a suite that touches nothing but Lua tables. If a check
-- needs a world, a pawn, a UObject or a UE4SS global, it is a `cases/` suite (which SKIPS with a
-- reason when its environment is absent) or a `hooks/` measurement. The whole of this bundle
-- runs before the first world exists, in a game that is still loading, so a suite here that
-- blocks or raises delays every startup.
--
--   local units = require("palforge.test.units")
--   units.run()          -- run every suite in this bundle, print a summary
--
-- Nothing outside palforge/test requires this file. test/init.lua's install() runs it, and
-- test/init.lua is the ONE name the kernel knows — see its header for why the dependency points
-- that way.
--
-- Add one: create test/units/<name>.lua that does `T.suite(...)` + `:test(...)` and returns the
-- suite, then require it in SUITES below.
local T = require("palforge.core.unittests")

-- Each suite file returns its suite, so this bundle runs exactly its own — the in-game suites
-- under test/cases register into the same framework and must NOT be dragged into the startup
-- run. The parentheses matter: require returns (module, loaderpath), and the LAST expression in
-- a table constructor expands to all of its results — without them the loader path lands in the
-- list as a third "suite".
--
-- Two files, 8 checks, and that is the whole of the startup run.
--
-- A third file used to sit beside these and was NOT one of them: `spawn.lua`, which nothing
-- required, which was never in this list, and whose own header said it was superseded and wrong
-- in two ways (it verified placement at 3 s when the only timed arrivals took ~4-6 s, and its
-- gate was written when :spawn returned false for a spawn that worked). Sitting in a live
-- directory with a warning header is not the same as being marked dead, so on 2026-08-02 it
-- moved to palforge/deprecated/spawn.lua.
local SUITES = {
    (require("palforge.test.units.audio")),
    (require("palforge.test.units.object_manager")),
}

local M = {}

---Run this bundle's suites. Returns the aggregate results table.
function M.run()
    return T.run(SUITES)
end

return M
