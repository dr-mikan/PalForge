-- PalForge core.mesh.base.renderer: the abstract renderer contract. Every mesh
-- backend (procedural OBJ, and the TODO static / skeletal ones) extends this and
-- overrides what it implements. Self-contained (no PalForge deps).
--
-- Contract:
--   renderer:attach(actor, spec)   -> attach a mesh to `actor` from `spec`
--   renderer:setColor(actor, color)-> re-tint an attached mesh
--   renderer:detach(actor)         -> remove the attached mesh
-- The defaults are inert (return false) so an unfinished backend is a safe no-op.
local Renderer = {}
Renderer.__index = Renderer
Renderer.__name  = "Renderer"
Renderer.__super = nil

-- Create a subclass. Call with `:` — e.g. Renderer:extend("Procedural").
function Renderer.extend(parent, name)
    local cls = setmetatable({}, { __index = parent })
    cls.__index = cls
    cls.__name  = name or "AnonRenderer"
    cls.__super = parent
    return cls
end

-- Instantiate (backends are used as singletons, but new() is here for symmetry with
-- the other core base classes).
function Renderer.new(cls, spec)
    return setmetatable(spec or {}, cls)
end

-- Call the parent class's implementation of `method` from within an override.
function Renderer.super(self, method, ...)
    local cls    = getmetatable(self)
    local parent = cls and cls.__super
    if parent and parent[method] then return parent[method](self, ...) end
end

-- ---- contract (override in a backend; defaults inert) ----

-- Attach a mesh described by `spec` to `actor`. Returns true on success.
function Renderer:attach(actor, spec) return false end

-- Re-tint an already-attached mesh. `color` = {r,g,b,a} 0..1. Returns true if applied.
function Renderer:setColor(actor, color) return false end

-- Remove the attached mesh from `actor`. Returns true if something was removed.
function Renderer:detach(actor) return false end

return Renderer
