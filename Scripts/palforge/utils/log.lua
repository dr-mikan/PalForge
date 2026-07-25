-- PalForge utils.log: the ONE shared logger. Replaces the per-module inline
-- `local function log/warn/err ... pcall(print, ...)` blocks that used to be copied
-- into scheduler / building / mesh / store. Self-contained generic primitive
-- (no PalForge deps).
--
-- Usage:
--   local log = require("palforge.utils.log").scope("building")
--   log.info("world ready")
--   log.warn("hook unavailable")
--   log.err("onTick failed")
--
-- Sinks are pluggable: addSink(fn) registers an extra fn(level, scope, msg). The
-- default sink prints "[PalForge.<scope>][<level>] <msg>" via pcall(print, ...).
local M = {}

-- Registered sinks. Each receives (level, scope, msg). The default print sink is
-- installed first; addSink appends more (they all fire).
local sinks = {}

-- Default sink: the fail-soft print that every module used to inline.
local function defaultSink(level, scope, msg)
    pcall(print, "[PalForge." .. tostring(scope) .. "][" .. tostring(level) .. "] " .. tostring(msg))
end
sinks[1] = defaultSink

-- Register an additional sink. fn(level, scope, msg). Non-functions are ignored.
function M.addSink(fn)
    if type(fn) == "function" then table.insert(sinks, fn) end
end

-- Fan a record out to every sink (each guarded so one bad sink can't break logging).
local function emit(level, scope, msg)
    for _, fn in ipairs(sinks) do
        pcall(fn, level, scope, msg)
    end
end

-- Build a scoped logger. Returns a table with .info / .warn / .err, each taking a
-- single message. The scope string is baked in so call sites stay terse.
function M.scope(name)
    return {
        info = function(msg) emit("info", name, msg) end,
        warn = function(msg) emit("warn", name, msg) end,
        err  = function(msg) emit("err",  name, msg) end,
    }
end

return M
