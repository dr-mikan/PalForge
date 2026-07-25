-- PalForge utils.file: the persistence FACADE, backed by the default json_file
-- backend (JSON key/value files under <Mods>/PalForge/state/). Self-contained.
--
-- PUBLIC API — the same method names the old core.util.store exposed, so callers
-- (core.building) only change their `require` (...util.store -> ...util.file) and
-- their local var name (store -> file):
--   M.get(key)              -> value | nil
--   M.set(key, val)         -- stage in memory
--   M.setAndFlush(key, val) -- stage + persist immediately
--   M.flush(key)            -- persist (key, or everything staged)
local backend = require("palforge.utils.file.json_file")

local M = {}

-- Read a key -> value (decoded), or nil.
function M.get(key) return backend:get(key) end

-- Stage a key in memory (persist later via flush / setAndFlush).
function M.set(key, value) return backend:set(key, value) end

-- Stage a key and persist it immediately.
function M.setAndFlush(key, value) return backend:setAndFlush(key, value) end

-- Persist a key (nil = everything staged).
function M.flush(key) return backend:flush(key) end

return M
