-- PalForge utils.file.base.backend: the abstract persistence-backend contract.
-- A backend maps string keys to decoded values and can flush them to durable
-- storage. json_file (JSON-on-disk) is the default backend; a future backend (an
-- in-memory or engine-savegame one) only has to satisfy this contract. Self-contained.
--
-- Contract:
--   backend:get(key)             -> value | nil
--   backend:set(key, val)        -- stage a value in memory
--   backend:setAndFlush(key, val)-- stage + persist immediately
--   backend:flush(key)           -- persist (key, or everything staged)
-- Defaults are inert so an unfinished backend is a safe no-op.
local Backend = {}
Backend.__index = Backend
Backend.__name  = "Backend"
Backend.__super = nil

-- Create a subclass. Call with `:` — e.g. Backend:extend("JsonFile").
function Backend.extend(parent, name)
    local cls = setmetatable({}, { __index = parent })
    cls.__index = cls
    cls.__name  = name or "AnonBackend"
    cls.__super = parent
    return cls
end

-- Instantiate (backends are used as singletons, but new() is here for symmetry).
function Backend.new(cls, spec)
    return setmetatable(spec or {}, cls)
end

-- Call the parent class's implementation of `method` from within an override.
function Backend.super(self, method, ...)
    local cls    = getmetatable(self)
    local parent = cls and cls.__super
    if parent and parent[method] then return parent[method](self, ...) end
end

-- ---- contract (override in a backend; defaults inert) ----

-- Read a key -> value (decoded), or nil.
function Backend:get(key) return nil end

-- Stage a key in memory (persist later via flush / setAndFlush).
function Backend:set(key, val) end

-- Persist a key (nil = everything staged). Returns true on success.
function Backend:flush(key) return false end

-- Stage a key and persist it immediately. Returns true on success.
function Backend:setAndFlush(key, val)
    self:set(key, val)
    return self:flush(key)
end

return Backend
