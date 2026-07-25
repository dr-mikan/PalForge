-- PalForge core.mesh: the runtime-mesh FACADE. Dispatches to a backend by
-- `spec.kind` (default "procedural"). Self-contained (no PalForge deps beyond the
-- backends it loads).
--
-- PUBLIC API — preserved exactly from the old flat core.mesh so callers
-- (api.building / api.pal) don't change:
--   M.attach(actor, spec)      -- attach a mesh (dispatched by spec.kind)
--   M.attachOnce(actor, spec)  -- attach once per actor (guarded); gated by M.ENABLED
--   M.setColor(actor, color)   -- re-tint an attached mesh
--   M.ENABLED                  -- global kill-switch for runtime meshes
--
-- Backends are the class tables from mesh.* used as singletons (their methods carry
-- no per-instance state). New mesh kinds register in the `renderers` table below.
local M = {}

-- Global kill-switch for runtime meshes. Flip off if marker attachment ever
-- destabilizes anything (the rest of the framework does not depend on meshes).
M.ENABLED = true

local DEFAULT_KIND = "procedural"

-- kind -> renderer backend
local renderers = {
    procedural = require("palforge.core.mesh.procedural"),
    static     = require("palforge.core.mesh.static"),
    skeletal   = require("palforge.core.mesh.skeletal"),
}
renderers.obj = renderers.procedural  -- alias: "obj" is the procedural OBJ backend

-- Pick the backend for a spec. A spec/color table without an explicit `.kind`
-- (e.g. the {r,g,b,a} color passed to setColor) falls back to the default backend,
-- preserving the old flat-module behaviour exactly.
local function rendererFor(spec)
    local kind = (type(spec) == "table" and spec.kind) or DEFAULT_KIND
    return renderers[kind] or renderers[DEFAULT_KIND]
end

-- Attach a mesh described by `spec` (dispatched by spec.kind). Returns true on success.
function M.attach(actor, spec)
    return rendererFor(spec):attach(actor, spec)
end

-- Attach once per actor (the backend guards against re-stacking). Gated by the
-- global M.ENABLED kill-switch. Returns true on success / already-attached.
function M.attachOnce(actor, spec)
    if not M.ENABLED then return false end
    if not (actor and spec) then return false end
    local r = rendererFor(spec)
    if r.attachOnce then return r:attachOnce(actor, spec) end
    return r:attach(actor, spec)  -- fallback for a backend without a once-guard
end

-- Re-tint an already-attached mesh. `color` = {r,g,b,a} 0..1 (no kind -> default
-- backend). Safe no-op if the actor has no live material.
function M.setColor(actor, color)
    return rendererFor(color):setColor(actor, color)
end

-- ---- discovery / parse helpers (delegated to the procedural backend; were public
-- ---- on the old flat module) ----
function M.parseObj(path) return renderers.procedural.parseObj(path) end
function M.probeMaterials(extra) return renderers.procedural.probeMaterials(extra) end

return M
