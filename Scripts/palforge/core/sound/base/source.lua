-- PalForge core.sound.base.source: the abstract SoundSource contract. A source
-- is one playable thing — a native Wwise SoundID (native.lua) or a custom audio file
-- (file.lua). Extends this and overrides play/stop. Self-contained.
--
-- Contract:
--   source:play(actor)  -> start this source on `actor`
--   source:stop(actor)  -> stop this source on `actor`
-- Defaults are fail-soft no-ops.
local SoundSource = {}
SoundSource.__index = SoundSource
SoundSource.__name  = "SoundSource"
SoundSource.__super = nil

-- Create a subclass. Call with `:` — e.g. SoundSource:extend("NativeSource").
function SoundSource.extend(parent, name)
    local cls = setmetatable({}, { __index = parent })
    cls.__index = cls
    cls.__name  = name or "AnonSoundSource"
    cls.__super = parent
    return cls
end

-- Instantiate. `spec` (e.g. { id = ... } or { path = ... }) becomes the source's state.
function SoundSource.new(cls, spec)
    return setmetatable(spec or {}, cls)
end

-- Call the parent class's implementation of `method` from within an override.
function SoundSource.super(self, method, ...)
    local cls    = getmetatable(self)
    local parent = cls and cls.__super
    if parent and parent[method] then return parent[method](self, ...) end
end

-- ---- contract (override in an impl; defaults inert) ----

-- Start this source on `actor`. Returns true if a native call executed.
function SoundSource:play(actor) return false end

-- Stop this source on `actor`.
function SoundSource:stop(actor) return false end

return SoundSource
