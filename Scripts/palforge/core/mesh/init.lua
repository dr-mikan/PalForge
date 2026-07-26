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
--   M.assets                         -- core.mesh.assets: the /Game/... resolver + catalog
--   M.ENABLED                        -- global kill-switch for runtime meshes
--
-- WHERE AN ASSET COMES FROM. `spec.model` is a /Game/... OBJECT PATH for the static and
-- skeletal backends and an absolute .obj FILE PATH for the procedural one, and the object
-- path is the primary case: it names something already cooked into the game's own pak, so
-- there is nothing for a player to install and nothing to parse at runtime. M.assets does
-- that resolve for both backends — one implementation, class-checked — and carries the
-- handful of paths that are known to exist in this build (M.assets.SM.ChestWood,
-- M.assets.SK.PinkCat, M.assets.ABP.PinkCat, ...). See core/mesh/assets.lua for provenance.
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

-- The asset layer, re-exported so a pack that has core.mesh already does not have to know
-- the submodule path. This is the one place a KNOWN-GOOD /Game/... path lives.
M.assets = require("palforge.core.mesh.assets")

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

-- Resolve a /Game/... path the way a backend would, without attaching anything. `class` is
-- the short UE class name to require ("StaticMesh", "SkinnedAsset"); omit it to accept
-- whatever is there. Returns the object, or nil + the reason — which is the same string a
-- failed attach logs, so a pack can check a path before it declares one.
function M.resolve(path, class) return M.assets.load(path, { class = class }) end

-- Try every catalogued path and report what resolved. READ-ONLY. This is what pf_mesh runs
-- first, and what to run after a game patch: a path that has stopped resolving says so in
-- one line rather than turning into a silent no-render.
function M.probeAssets(sink) return M.assets.probe(sink) end

-- READ which materials an actor is wearing and which parameter names they carry, writing
-- nothing. This is a DIAGNOSTIC, not a capability, and it exists because both open mesh
-- questions are asset data that no dump can hold: which material a Palworld mesh really
-- carries (mesh-base-material wants one loaded UMaterialInterface to parent a MID to) and
-- which parameter names it exposes (mesh-material-params — the candidate lists in
-- base/renderer are guesses until this prints the real ones). One read in a loaded world
-- answers both. See Renderer.describeMaterials for the declarations it rests on.
--
-- `target` may be a component or an actor. Being a diagnostic, the actor case is allowed
-- the two-step resolve a capability would not be: the backend that DRESSED the actor names
-- its own component, and otherwise the actor's own `.Mesh` is read — the reflected
-- ACharacter property (dumps/cxx/Engine.hpp:8156) that every character in this game has
-- and that the skeletal backend already reaches actors through.
function M.describeMaterials(target, sink)
    local Renderer = require("palforge.core.mesh.base.renderer")
    if target == nil then return {} end

    local comp = target
    local hasGetMaterial
    pcall(function() hasGetMaterial = target.GetMaterial ~= nil end)
    if not hasGetMaterial then
        local r = dressedBy[target]
        comp = (r and r:componentFor(target)) or nil
        if comp == nil then pcall(function() comp = target.Mesh end) end
    end
    return Renderer.describeMaterials(comp, sink)
end

return M
