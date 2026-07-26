-- PalForge core.mesh: the runtime-mesh FACADE. Dispatches to a backend by
-- `spec.kind` (default "procedural"). Self-contained (no PalForge deps beyond the
-- backends it loads).
--
-- PUBLIC API — preserved from the old flat core.mesh so callers (api.building /
-- api.pal) don't change:
--   M.attach(actor, spec)            -- attach a mesh (dispatched by spec.kind)
--   M.attachOnce(actor, spec)        -- attach once per actor (guarded); gated by M.ENABLED
--   M.setColor(actor, color, kind)   -- re-tint an attached mesh (kind is an optional hint)
--   M.detach(actor)                  -- remove again what an attach put on `actor`
--   M.ENABLED                        -- global kill-switch for runtime meshes
--
-- setColor and detach can't dispatch on `spec.kind` — they are handed a {r,g,b,a} colour
-- table or nothing at all — so a successful attach RECORDS which backend dressed the
-- actor and those two follow that record. Without it every re-tint landed on the default
-- backend no matter what the mesh really was, which is why a static or skeletal mesh
-- could never be re-tinted.
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

-- Pick the backend for a spec. A spec without an explicit `.kind` falls back to the
-- default backend, preserving the old flat-module behaviour exactly.
local function rendererFor(spec)
    local kind = (type(spec) == "table" and spec.kind) or DEFAULT_KIND
    return renderers[kind] or renderers[DEFAULT_KIND]
end

-- Which backend dressed each actor, recorded by a SUCCESSFUL attach. Weak keys, so an
-- actor that goes away drops out on its own. This is what setColor and detach dispatch
-- on: neither is handed a spec, so without it they could only ever guess the default.
local dressedBy = setmetatable({}, { __mode = "k" })

local function remember(actor, renderer, ok)
    if ok and actor and renderer then pcall(function() dressedBy[actor] = renderer end) end
    return ok
end

-- Attach a mesh described by `spec` (dispatched by spec.kind). Returns true on success.
function M.attach(actor, spec)
    local r = rendererFor(spec)
    return remember(actor, r, r:attach(actor, spec))
end

-- Attach once per actor (the backend guards against re-stacking). Gated by the
-- global M.ENABLED kill-switch. Returns true on success / already-attached.
function M.attachOnce(actor, spec)
    if not M.ENABLED then return false end
    if not (actor and spec) then return false end
    local r = rendererFor(spec)
    if r.attachOnce then return remember(actor, r, r:attachOnce(actor, spec)) end
    return remember(actor, r, r:attach(actor, spec))  -- backend without a once-guard
end

-- Re-tint an already-attached mesh. `color` = {r,g,b,a} 0..1. Dispatches to the backend
-- that actually dressed `actor`; `kind` is an optional hint used only when the actor was
-- never attached through here (falling back, as before, to the default backend).
-- Safe no-op if the actor has no live material.
function M.setColor(actor, color, kind)
    local r = (actor and dressedBy[actor]) or renderers[kind] or renderers[DEFAULT_KIND]
    return r:setColor(actor, color)
end

-- Remove again what an attach put on `actor`, so it can be dressed afresh. Only a
-- backend that added a component of its own can do this (procedural / static); a
-- skeletal swap has nothing of ours to remove. Returns false when we never dressed this
-- actor, and when the removal did not execute — the record is kept in that case, since
-- the component is still there.
function M.detach(actor)
    if not actor then return false end
    local r = dressedBy[actor]
    if not r then return false end
    local ok = r:detach(actor)
    if ok then dressedBy[actor] = nil end
    return ok
end

-- ---- discovery / parse helpers (delegated to the procedural backend; were public
-- ---- on the old flat module) ----
function M.parseObj(path) return renderers.procedural.parseObj(path) end
function M.probeMaterials(extra) return renderers.procedural.probeMaterials(extra) end

return M
