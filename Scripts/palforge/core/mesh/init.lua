-- PalForge core.mesh: the runtime-mesh FACADE. Dispatches to a backend by
-- `spec.kind` (default "procedural").
--
-- PUBLIC API — preserved from the old flat core.mesh so callers (api.building /
-- api.pal) don't change:
--   M.attach(actor, spec)            -- attach a mesh (dispatched by spec.kind)
--   M.attachOnce(actor, spec)        -- attach once per actor (guarded); gated by M.ENABLED
--   M.setColor(actor, color, kind)   -- re-tint an attached mesh (kind is an optional hint)
--   M.detach(actor)                  -- remove again what an attach put on `actor`
--   M.validateDeclared(sink)         -- resolve every DECLARED mesh's assets, once, and report
--   M.assets                         -- core.mesh.assets: the /Game/... resolver + catalog
--   M.ENABLED                        -- global kill-switch for runtime meshes
--
-- The first four all now return `true`, or `false` PLUS THE ENGLISH REASON. The boolean-true
-- path is byte-for-byte what it was, so every existing caller is unaffected; what changes is
-- that the good sentence the backends already produce ("… is a StaticMesh, not a SkinnedAsset")
-- no longer stops at the log. A pack author used to get a bare `false` from `Handle:attachTo`
-- and had to go and read UE4SS.log to find out which of half a dozen steps refused.
--
-- This module is no longer dep-free: validateDeclared reads the registry
-- (core.object_manager) and logs (utils.log). Both are self-contained primitives with no
-- dependency back on core.mesh, so there is no cycle.
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
local uo  = require("palforge.core.uobject")
local om  = require("palforge.core.object_manager")
local log = require("palforge.utils.log").scope("mesh")

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

-- Which backend dressed each actor, recorded by a SUCCESSFUL attach. This is what setColor
-- and detach dispatch on: neither is handed a spec, so without it they could only ever guess
-- the default backend, which is why a static or skeletal mesh could never be re-tinted.
--
-- KEYED ON core.uobject.key (the actor's full name), NOT on the actor handle — contract C1.
-- It was a `__mode="k"` table keyed on the handle, and UE4SS mints a fresh userdata wrapper
-- per lookup, so `M.detach(actor)` found nothing and returned false for any actor that had
-- not come out of the very same lookup as the attach — an actor from a later FindAllOf, or
-- from a subsequent event's ctx.actor, which is how essentially every real call site gets
-- one. The record holds the handle: { actor = <freshest handle>, r = <backend> }.
local dressedBy = {}

-- The record for `actor`, re-validated, with the handle refreshed from the caller's fresher
-- one. A record whose actor is no longer live is dropped rather than kept.
local function recordFor(actor)
    local k = uo.key(actor)
    if not k then return nil, nil end
    local rec = dressedBy[k]
    if rec == nil then return nil, k end
    if not uo.live(rec.actor) then dressedBy[k] = nil; return nil, k end
    rec.actor = actor
    return rec, k
end

local function remember(actor, renderer, ok, why)
    if ok and actor and renderer then
        local k = uo.key(actor)
        if k then dressedBy[k] = { actor = actor, r = renderer } end
    end
    return ok, why
end

-- Attach a mesh described by `spec` (dispatched by spec.kind). Returns true on success, or
-- false plus the backend's English reason.
--
-- THE ONCE-GUARD THIS DID NOT HAVE. `M.attach` is public and used to add a component every
-- time it was called; combined with the per-actor store being keyed on a handle (so every
-- re-attach OVERWROTE the record), two calls left one component on the actor that nothing
-- held a reference to and no detach could ever reach. Unbounded growth, silently.
--
-- The guard is "never stack", not "never re-attach": a second attach through the SAME
-- backend destroys that backend's previous component first (static.lua / procedural.lua do
-- it, where the component handle is), and a second attach through a DIFFERENT backend is
-- detached here first. Refusing the second call outright would have been the other option
-- and it is the wrong one — attach takes a SPEC, so a caller passing a new model is asking
-- to change the mesh, and silently ignoring that is the same class of quiet failure this
-- whole change is about. Callers who want "leave it alone if it is already dressed" have
-- M.attachOnce, which is unchanged.
function M.attach(actor, spec)
    local r = rendererFor(spec)
    local prev = recordFor(actor)
    if prev and prev.r ~= r then
        -- a different backend dressed this actor: undo ITS work before this one starts, or
        -- the two records fight over one actor and only the later one is reachable
        local ok, why = prev.r:detach(actor)
        if not ok then
            log.warn("attach: an earlier attach by another backend could not be undone first, "
                .. "so both may now be on this actor - " .. tostring(why))
        end
    end
    return remember(actor, r, r:attach(actor, spec))
end

-- Attach once per actor (the backend guards against re-stacking). Gated by the
-- global M.ENABLED kill-switch. Returns true on success / already-attached, else
-- false plus the reason.
function M.attachOnce(actor, spec)
    if not M.ENABLED then
        return false, "core.mesh.ENABLED is false: runtime meshes are switched off"
    end
    if not (actor and spec) then return false, "core.mesh.attachOnce: no actor or no spec" end
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
    local rec = recordFor(actor)
    local r = (rec and rec.r) or renderers[kind] or renderers[DEFAULT_KIND]
    local ok = r:setColor(actor, color)
    if ok then return true end
    return false, rec
        and "setColor: the backend that dressed this actor had no material instance it could "
            .. "reach or create on its component"
        or "setColor: PalForge has no record of dressing this actor, and the fallback backend "
            .. "(" .. tostring(kind or DEFAULT_KIND) .. ") found nothing of its own on it"
end

-- Undo an attach, so `actor` can be dressed afresh. What that means depends on the
-- backend: procedural and static destroy the component they added, while skeletal — which
-- dresses the pawn's OWN body component — puts back the asset, scale, offset and
-- materials it captured before the swap. Returns false when we never dressed this actor,
-- and when the undo did not execute — the record is kept in that case, since the change
-- is still on the actor.
function M.detach(actor)
    if not actor then return false, "core.mesh.detach: no actor" end
    local rec, k = recordFor(actor)
    if not rec then
        return false, "core.mesh.detach: PalForge has no record of dressing this actor "
            .. "(either nothing was attached through core.mesh, or the actor is gone)"
    end
    local ok, why = rec.r:detach(actor)
    if ok then dressedBy[k] = nil end
    return ok, why
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
        local rec = recordFor(target)
        comp = (rec and rec.r:componentFor(target)) or nil
        if comp == nil then pcall(function() comp = target.Mesh end) end
    end
    return Renderer.describeMaterials(comp, sink)
end

--=============================================================================
-- validate what packs DECLARED (A-6)
--=============================================================================

---Resolve every asset every REGISTERED mesh declares, and report it as one block.
---
---WHY THIS EXISTS. Mesh.Spec checks TYPES at define time (api/mesh.lua) — correct, because
---at define time there is no world and no pak to ask — and nothing replaced that check
---later. So a `model` that is a well-formed string pointing at nothing was indistinguishable
---from a working one until a pal spawned, at which point the failure was one line in
---UE4SS.log and a boss that renders as its default body. `Mesh.assets.probe` walks
---PalForge's OWN catalog, which is a different question: it asks whether the paths this
---framework measured still resolve, not whether the paths a PACK wrote do.
---
---READ-ONLY in the sense that matters: it loads packages (I/O and memory) and writes nothing
---to any actor, component or save. It is meant to run once at world.ready — see the note on
---the call site below — and it is safe to run again by hand at any time.
---
---`sink` is called as sink(line) per line; without one every line goes to the mesh log.
---Returns a list of { id, field, path, ok, detail } so a test or a hook can assert on it.
---
---WHO CALLS IT. core/event.lua's `M.__scanPump`, immediately after it emits world.ready — the
---first scan that completes once the ready gate has opened, so the load storm is over and every
---definition that registers at startup has done so. The call is pcall'd there and guarded on
---this function existing, so neither module depends on the other's version. This module still
---subscribes to nothing itself: it exports the pass, and core/event owns the one moment it runs.
---Calling it again by hand at any time is safe (nothing here writes).
---@param sink fun(line: string)?
---@return table[]
function M.validateDeclared(sink)
    local out = {}
    local function say(line)
        if sink then pcall(sink, line) else log.info(line) end
    end

    -- EVERY DECLARED MESH, INCLUDING THE ONES THAT ARE NOT IN THE MESH REGISTRY. A pack writes
    -- a mesh two ways and only one of them registers:
    --
    --   Pal{ mesh = Mesh{ id = "x", model = ... } }   a NAMED mesh — om.all("mesh") has it
    --   Pal{ mesh = { model = ... } }                 an INLINE mesh — nothing registers it
    --
    -- The inline form is the shorter one and therefore the common one, and until this loop it
    -- was entirely outside this pass: the check that turns "my boss is invisible" into a log
    -- line covered the declaration style a pack was less likely to use. The owning definition
    -- IS registered, though, and it keeps the spec on `meshSpec` (api/pal.lua, api/building.lua),
    -- so the inline ones are reachable through their owner and are reported under
    -- "<owner> (inline)" so the log names something a pack author can find in their own file.
    local specs, ids = {}, {}
    local function add(id, spec)
        if type(spec) == "table" and specs[id] == nil then
            specs[id] = spec
            ids[#ids + 1] = id
        end
    end
    for id, cls in pairs(om.all("mesh")) do
        add(id, (type(cls) == "table" and (cls.source and cls:source() or cls)) or nil)
    end
    for _, otype in ipairs({ "pal", "building" }) do
        for id, cls in pairs(om.all(otype)) do
            if type(cls) == "table" and type(cls.meshSpec) == "table" then
                add(otype .. " " .. id .. " (inline)", cls.meshSpec)
            end
        end
    end
    table.sort(ids)

    say(string.format("MESHVALIDATE %d declared mesh(es)", #ids))
    -- The class each field must resolve to. `kind` decides the model's class for the same
    -- reason attach does: a USkeletalMesh and a UStaticMesh are SIBLINGS, so "resolves" is
    -- not the whole question — "resolves to the right thing" is (core/mesh/assets.lua's
    -- header has the class ladder). A procedural / obj model is a file on disk and is
    -- checked by opening it, because there is no asset to resolve.
    for _, id in ipairs(ids) do
        local spec = specs[id]
        if type(spec) == "table" then
            local kind = spec.kind or "skeletal"
            local function record(field, path, ok, detail)
                out[#out + 1] = { id = id, field = field, path = path, ok = ok, detail = detail }
                say(string.format("MESHVALIDATE %s %s.%s -> %s", ok and "OK  " or "MISS",
                    id, field, tostring(detail)))
            end

            if type(spec.model) == "string" and #spec.model > 0 then
                if kind == "procedural" or kind == "obj" then
                    local f = io.open(spec.model, "rb")
                    if f then
                        f:close()
                        record("model", spec.model, true, "readable OBJ file")
                    else
                        record("model", spec.model, false, "cannot open this file for reading "
                            .. "(a pack-relative path resolves against the pack's own "
                            .. "directory - see utils.file.resolvePackPath)")
                    end
                else
                    local want = (kind == "static") and "StaticMesh" or "SkinnedAsset"
                    local obj, err = M.assets.load(spec.model, { class = want })
                    record("model", spec.model, obj ~= nil,
                        obj and M.assets.describe(obj) or tostring(err))
                end
            end
            if type(spec.animClass) == "string" and #spec.animClass > 0 then
                local c, err = M.assets.loadClass(spec.animClass)
                record("animClass", spec.animClass, c ~= nil,
                    c and M.assets.describe(c) or tostring(err))
            end
            if type(spec.texture) == "string" and #spec.texture > 0 then
                if M.assets.isObjectPath(spec.texture) then
                    local t, err = M.assets.load(spec.texture, { class = "Texture" })
                    record("texture", spec.texture, t ~= nil,
                        t and M.assets.describe(t) or tostring(err))
                else
                    -- A PNG is not resolvable without a world context to import it against,
                    -- and importing one here would be a WRITE of sorts (it creates a
                    -- UTexture2D). Reading the file is the honest half of the question and
                    -- it catches the mistake that actually happens: a path that is right on
                    -- the author's machine and nowhere else.
                    local f = io.open(spec.texture, "rb")
                    if f then
                        f:close()
                        record("texture", spec.texture, true, "readable file (the import "
                            .. "itself is only attempted at attach time)")
                    else
                        record("texture", spec.texture, false, "cannot open this file for "
                            .. "reading (see utils.file.resolvePackPath for pack-relative "
                            .. "paths)")
                    end
                end
            end
            if type(spec.material) == "string" and #spec.material > 0 then
                local m, err = M.assets.load(spec.material, { class = "MaterialInterface" })
                record("material", spec.material, m ~= nil,
                    m and M.assets.describe(m) or tostring(err))
            end
        end
    end

    local ok, miss = 0, 0
    for _, rec in ipairs(out) do
        if rec.ok then ok = ok + 1 else miss = miss + 1 end
    end
    say(string.format("MESHVALIDATE %d asset reference(s) checked, %d resolved, %d did not",
        #out, ok, miss))
    return out
end

return M
