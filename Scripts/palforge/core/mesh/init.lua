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
-- no per-instance state). New mesh kinds register in the `renderers` table below. All
-- THREE now implement the full contract: the material layer that used to sit inside the
-- procedural backend alone lives in mesh.base.renderer, so a spec's color / texture /
-- material / params reach every kind and every kind can be re-tinted and undone.
--
-- The three DEFAULTS for `kind` are deliberately different and all three are real:
-- Mesh.Spec fills "skeletal" (a named mesh is a creature body), Building.Spec.Mesh fills
-- "static" (a structure is a prop), and DEFAULT_KIND below is "procedural" — it only ever
-- applies to a direct core.mesh call whose spec carries no kind at all, which is how the
-- OBJ path was reached before the api existed.
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
-- never attached through here (falling back, as before, to the default backend). A mesh
-- attached with NO colour declared can still be tinted: the backend names the component it
-- dressed and the base makes the dynamic material on the spot. Returns false — never a
-- pretended tint — when there is no such component or nothing accepted the write.
function M.setColor(actor, color, kind)
    local r = (actor and dressedBy[actor]) or renderers[kind] or renderers[DEFAULT_KIND]
    return r:setColor(actor, color)
end

-- Undo an attach, so `actor` can be dressed afresh. What that means depends on the
-- backend: procedural and static destroy the component they added, while skeletal — which
-- dresses the pawn's OWN body component — puts back the asset, scale, offset and
-- materials it captured before the swap. Returns false when we never dressed this actor,
-- and when the undo did not execute — the record is kept in that case, since the change
-- is still on the actor.
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
