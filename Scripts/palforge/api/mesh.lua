-- palforge/api/mesh.lua — PUBLIC mesh API + implementation (SELF-CONTAINED).
--
-- A mesh is the VISUAL a definition wears: a model asset plus how to paint it. It follows
-- the same shape as every other api module (call it to define, plus get / get_all + a
-- Handle carrying actions), and it exists as its own domain so a mesh can be declared
-- ONCE, named, and reused by name across pals, buildings and anything else that renders:
--
--   local body = Mesh{ id = "example:body",
--                      model = "/Game/Pal/Model/Character/Monster/X/SK_X.SK_X",
--                      texture = "C:/mods/example/body.png" }
--   Pal{ id = "example:Boss", mesh = body }         -- nest the defined mesh
--   Pal{ id = "example:Add",  mesh = Mesh.get("example:body") }
--   body:attachTo(ctx.actor)                        -- or attach it yourself
--
-- Nesting works because the Handle's metatable carries `__spec` (see core/schema): the
-- validator unwraps it to the plain declaration, so `mesh = Mesh{ ... }` and the inline
-- `mesh = { model = "..." }` are validated identically and reach core.mesh the same way.
-- That is why api/pal reuses THIS shape rather than declaring a copy of it — one shape,
-- so the two spellings can never drift.
--
-- HOW IT INTEGRATES: defining registers the definition in object_manager under
-- ("mesh", id); attaching lowers the declaration to core.mesh, which dispatches on
-- `kind` (procedural / static / skeletal / obj) and guards against re-stacking.
-- core.mesh remembers which backend dressed each actor, so :setColor and :detach reach
-- that same backend rather than guessing from a colour table that carries no kind.
--
-- WHAT EACH KIND DOES WITH THE PAINT FIELDS. All four kinds honour every field of the
-- spec: `model` + `scale` + `offset` place the model, and `texture` / `color` / `material`
-- / `params` become a dynamic material instance on the component the backend dressed —
-- one per material slot. The one thing that is kind-specific is what a MID can be made
-- FROM: a procedural OBJ section owns no material, so it has to be parented to a base
-- material that happens to be loaded (supply one with `material` if the default guesses
-- miss), while a static or skeletal asset arrives with authored materials and is instanced
-- directly. `animClass` is skeletal-only, as marked.
--
-- POINTING AT A GAME ASSET IS THE MAIN CASE, and `Mesh.assets` is where the paths live:
--
--   Pal{ id = "pack:Boss",   mesh = { model = Mesh.assets.SK.PinkCat,
--                                     animClass = Mesh.assets.ABP.PinkCat } }
--   Building{ id = "pack:Statue", mesh = { model = Mesh.assets.SM.ChestWood } }
--
-- Both defaults already line up with those tables — Mesh.Spec fills kind = "skeletal" (a
-- creature body) and Building.Spec.Mesh fills kind = "static" (a prop) — so the two lines
-- above need no `kind` and neither does the shorter `mesh = { model = "/Game/..." }` form.
-- Every entry in Mesh.assets was observed in THIS build; core/mesh/assets.lua cites where.
-- The mesh, its materials and its textures all arrive together, because a cooked asset
-- carries its own material slots and those slots carry their own textures — nothing has to
-- be imported for the game's own art to render. What a spec's `texture` / `color` add is an
-- OVERRIDE on top of that, through the dynamic material instance — and `texture` points at an
-- asset too, so a re-skin needs no file on the player's disk either:
--
--   Mesh{ id = "pack:heli", model = Mesh.assets.SK.AttackHelicopter,
--         params = { texture = { ["Base Texture"] = Mesh.assets.T.HelicopterBase,
--                                ["Normal Map"]   = Mesh.assets.T.HelicopterNormal } } }
--
-- Those parameter names are MEASURED off a running game (core/mesh/base/renderer.lua), and
-- `texture` accepts either a /Game/... path or an absolute .png of your own; the string's
-- shape decides which route it takes, and only one of the two can ever apply to it.
--
-- A path that does not resolve, or resolves to the wrong class (an SM_ static mesh declared
-- on a pal, whose kind defaults to skeletal), is a logged English error and a false — never
-- a raw object handed to a typed engine setter. That check is not politeness: a UStaticMesh
-- is NOT a USkinnedAsset (they are siblings, dumps/cxx/Engine.hpp:20511 vs :21631) and a
-- wrong argument type faults inside UE4SS's marshalling where pcall cannot see it.

-- PACK-RELATIVE PATHS. `model` and `texture` accept a path RELATIVE to the .lua file that
-- declared the mesh, resolved at define time against that file's own directory:
--
--   Mesh{ id = "example:marker", kind = "obj", model = "art/marker.obj" }
--
-- An absolute path still works and is untouched, and so is every /Game/... object path (it
-- starts with "/", which utils.file.isAbsolute counts as absolute for exactly this reason).
-- Before this, the only documented shape was the one in the docs' own examples —
-- `C:/mods/example/marker.obj` — a path that is correct on exactly one machine, which made
-- the one asset route a pack can genuinely ship on unshippable. See utils/file/init.lua for
-- how the calling file is found, and for the case it deliberately refuses to guess at.
local om     = require("palforge.core.object_manager")
local mesh   = require("palforge.core.mesh")
local schema = require("palforge.core.schema")
local file   = require("palforge.utils.file")
local log    = require("palforge.utils.log").scope("mesh")

--=============================================================================
-- SPEC — the shape of Mesh{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("Mesh.Spec")         -- every field, its type, default and meaning
--   schema.get("Mesh.Spec").fields   -- the same, as a table, for tooling
--
-- `id` is optional here and only here: a mesh written INLINE inside another definition
-- (`mesh = { model = "..." }`) has nothing to name. Defining one directly requires an id,
-- since an unnamed definition could never be looked up again.
--=============================================================================

local Spec = schema.define("Mesh.Spec", {
    { "id",        type = "string", check = schema.nonEmpty,
                   doc = "mesh id, e.g. \"pack:name\" (required when defined directly; omit when inline)" },
    { "kind",      type = "string", values = { "procedural", "static", "skeletal", "obj" },
                   default = "skeletal", doc = "which core.mesh backend renders it" },
    { "model",     type = "string", required = true,
                   doc = "a /Game/... USkeletalMesh or UStaticMesh path (see Mesh.assets); for procedural / obj, an .obj file path - absolute, or relative to the .lua file that declares it" },
    { "animClass", type = "string",
                   doc = "a /Game/... ABP path, with or without the _C tail (see Mesh.assets.ABP); skeletal only" },
    { "scale",     type = "number", doc = "uniform scale applied to the attached mesh" },
    { "offset",    type = "table",  doc = "{ x, y, z } offset from the mesh's normal position, in cm" },
    { "texture",   type = "string",
                   doc = "a /Game/... UTexture2D path (see Mesh.assets.T), or a png of your own - absolute, or relative to the .lua file that declares it" },
    { "color",     type = "table",  doc = "tint { r, g, b, a } in 0..1" },
    { "material",  type = "string", doc = "base material asset path to instance from" },
    { "params",    type = "table",
                   doc = "extra material parameters: { vector = { name = {r,g,b,a} }, scalar = { name = n }, texture = { name = \"/Game/... or <abs png>\" } }" },
}, { handle = "Mesh.Handle" })   -- a Mesh.Handle satisfies this shape too (see __spec below)

--=============================================================================
-- DEFINE-TIME CROSS-FIELD WORK: the kind/prefix check, and pack-relative paths.
--
-- Both of these need to see the WHOLE declaration, and schema's per-field `check` is handed
-- only the field's own value — so they hang off Mesh.Spec's validate rather than off a
-- field. Doing it here rather than in `define()` below is what makes them apply to an INLINE
-- mesh too (`Pal{ mesh = { model = "..." } }`), because api/pal nests THIS spec object and
-- core/schema calls `f.of:validate(...)` on it.
--=============================================================================

-- Prefix -> the kind that prefix really is, for the one mistake ordinary pack code makes.
--
-- Mesh.Spec defaults `kind` to "skeletal" (a named mesh is a creature body), so
-- `Mesh{ model = "/Game/.../SM_ChestWood.SM_ChestWood" }` — a perfectly reasonable thing to
-- type — declares a STATIC mesh as skeletal. core/mesh/skeletal.lua:68-78 names that as the
-- mistake and it is a real one, not a nitpick: `USkeletalMesh : USkinnedAsset` and
-- `UStaticMesh : UStreamableRenderAsset` are SIBLINGS (dumps/cxx/Engine.hpp:20511 vs :21631),
-- so the asset would reach `SetSkinnedAssetAndUpdate(USkinnedAsset*, bool)` as a wrong
-- argument TYPE — the shape that faults inside UE4SS's marshalling where pcall cannot see it.
-- The class check in core/mesh/assets.lua catches it before it can, at ATTACH time, in a
-- world. This catches it at LOAD time, with no world, which is where an author is looking.
--
-- It WARNS rather than raising, and that is deliberate: the prefix is a naming convention
-- this build follows everywhere the tree has measured (every SM_/SK_ entry in
-- core/mesh/assets.lua's catalog), but a convention is not a guarantee, and refusing to load
-- a pack over a filename would be claiming more than the evidence supports.
local KIND_BY_PREFIX = { SM_ = "static", SK_ = "skeletal" }

local function warnKindPrefix(spec)
    local kind  = spec.kind or "skeletal"
    local model = spec.model
    if type(model) ~= "string" or kind == "procedural" or kind == "obj" then return end
    local last = model:match("([^/]+)$")
    if not last then return end
    for prefix, realKind in pairs(KIND_BY_PREFIX) do
        if last:sub(1, #prefix) == prefix and realKind ~= kind then
            log.warn(string.format(
                "Mesh%s declares kind = %q but its model is named %q - the %s prefix is this "
                .. "build's convention for a %s mesh. A UStaticMesh and a USkeletalMesh are "
                .. "sibling classes, not relatives, so the wrong one will be refused by the "
                .. "class check at attach time and nothing will render. Did you mean "
                .. "kind = %q?",
                spec.id and (" " .. spec.id) or " (inline)", kind, last, prefix, realKind,
                realKind))
            return
        end
    end
end

local specValidate = Spec.validate   -- the shared implementation, before this one shadows it

-- Mesh.Spec's own validate: the declared shape first (unchanged), then the two cross-field
-- passes above. Assigning here rawsets on the SPEC OBJECT, so it shadows core/schema's
-- method for this one spec and every caller — direct, nested, or tooling — goes through it.
function Spec:validate(t, context)
    local out = specValidate(self, t, context)
    -- Relative paths resolve against the CALLING pack's directory. utils.file walks out of
    -- PalForge's own tree to find that caller, which is why this works at whatever stack
    -- depth the declaration arrives at: `Mesh{ ... }` and `Pal{ mesh = { ... } }` are two
    -- and four frames deep respectively, and a fixed count would be wrong for one of them.
    if type(out.model) == "string" then out.model = file.resolvePackPath(out.model) end
    if type(out.texture) == "string" then out.texture = file.resolvePackPath(out.texture) end
    warnKindPrefix(out)
    return out
end

--=============================================================================
-- the registered mesh DEFINITION class
--=============================================================================

local Class = {}
Class.__index = Class

-- The spec core.mesh consumes. A definition IS that spec — the declaration validated,
-- with defaults filled — so there is nothing to lower and one field list to maintain.
-- Kept as a method so a definition can override it for a fully computed mesh.
function Class:source() return self end

--=============================================================================
-- TOP — the module surface: Mesh{ ... } / Mesh.get / Mesh.get_all
--=============================================================================

---The mesh domain. CALL it to define a mesh; the two named functions look existing ones up.
---@class palforge.mesh
---@overload fun(spec: Mesh.Spec, opts: table?): Mesh.Handle
local Mesh = {}

local wrap  -- forward decl; the Mesh.Handle wrapper is defined in the BOTTOM section

---Define a NAMED mesh and register it. Returns a handle you can attach, or nest
---directly in another definition (`Pal{ mesh = Mesh{ ... } }`).
---`spec` is validated against Mesh.Spec: `model` is required, unknown fields are an error.
---
---`opts` (optional, contract C2) — omitting it behaves exactly as before:
---  `opts.register == false`  build and return the Handle, register NOTHING. This is what a
---                            catalog accessor needs: reading a definition out of a native
---                            catalog used to REGISTER it as a side effect, which quietly
---                            made a read into a write against the shared registry.
---  `opts.pack == "id"`       register under that pack id (contract C3), so a collision can
---                            name both owners instead of last-wins in silence.
---@param spec Mesh.Spec
---@param opts table?
---@return Mesh.Handle
local function define(spec, opts)
    -- Validated at the call site by the shared parser, like the other seven domains. The old
    -- `opts = (type(opts) == "table") and opts or {}` coerced a non-table to empty and then read
    -- `opts.register` straight off it, so `Mesh(spec, "register")` and `{ regsiter = false }` were
    -- both silently "register it" rather than errors. schema.defineOpts raises on either.
    local register, pack = schema.defineOpts(opts, "Mesh")
    spec = Spec:validate(spec, "Mesh")
    if spec.id == nil then
        error("PalForge: Mesh: field \"id\" is required (an unnamed mesh cannot be "
            .. "looked up again - write it inline as mesh = { ... } instead)", 0)
    end
    -- DEFINE-TIME id SHAPE CHECK (contract C4). An id with a colon must have both halves
    -- match ^[%w_]+$ — the exact shape om.resolve requires — because an id that cannot
    -- resolve registers fine and is then silently dead at every engine boundary. Raising
    -- here, in the same style as the schema errors, is the whole point: "my-pack:Bench"
    -- becomes a line the author reads at load instead of a mesh that never renders.
    --
    -- Called unguarded, like the other seven domains. It used to be behind `if om.validId`
    -- because that function was landing in the same sweep as this file; it is in
    -- core/object_manager.lua now, and a presence guard on a function this module's own
    -- contract requires would turn "the check was removed" into "meshes stopped being
    -- checked", silently — the exact failure mode this check exists to prevent.
    local okId, why = om.validId(spec.id)
    if not okId then
        error(string.format("PalForge: Mesh: id %q is not a valid PalForge id: %s",
            tostring(spec.id), tostring(why)), 0)
    end
    -- `spec` is already a fresh, validated, defaults-filled copy that nothing else holds
    -- a reference to, so the definition can BE it rather than another transcription.
    local cls = setmetatable(spec, Class)
    if register then
        pcall(function()
            om.register("mesh", spec.id, cls, pack and { pack = pack } or nil)
        end)
    end
    return wrap(cls)
end

-- Calling the module IS defining:  Mesh{ id = "example:body", model = "..." }
setmetatable(Mesh, { __call = function(_, spec, opts) return define(spec, opts) end })

---Get a previously-defined mesh by id. Errors when nothing is registered under it —
---unlike a pal or an item there is no sensible thin fallback, since a mesh with no
---model would silently render nothing.
---@param id string
---@return Mesh.Handle
function Mesh.get(id)
    assert(type(id) == "string" and #id > 0, "Mesh.get: id (string) is required")
    local cls = om.get("mesh", id)
    if not cls then
        error(string.format("PalForge: Mesh.get(%q): no mesh is defined under that id", id), 0)
    end
    return wrap(cls)
end

---Every PalForge-registered mesh, as a list of handles.
---@return Mesh.Handle[]
function Mesh.get_all()
    local out = {}
    for _, cls in pairs(om.all("mesh")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the mesh OBJECT (Mesh.Handle): actions
-- Meshes have no lifecycle of their own — they are worn by something else — so the
-- handle's surface is actions plus the declaration it stands for.
--=============================================================================

---A defined mesh. Obtain one from Mesh{ ... } / Mesh.get / Mesh.get_all.
---@class Mesh.Handle
---@field id string   # the mesh's id
local Handle = {}
Handle.__index = Handle

-- `__spec` is what lets a handle be passed straight into another definition: core/schema
-- unwraps it to the declaration it stands for before validating that against the nested
-- spec. Re-validation copies, so the caller can never reach the definition through it.
Handle.__spec = function(self) return self._cls:source() end

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Attach this mesh to a live actor, once (core.mesh guards against re-stacking).
---Fail-soft false when the actor is not valid.
---
---RETURNS `true`, or `false` PLUS AN ENGLISH REASON. The true path is unchanged, so a caller
---writing `if m:attachTo(a) then` is unaffected; what is new is that the sentence the
---backend already produced ("… is a StaticMesh, not a SkinnedAsset", "that path did not
---resolve and its package is not in memory either") comes back to the caller instead of only
---reaching UE4SS.log. An author who got a bare `false` had no way to tell a wrong path from
---a wrong kind from an actor that is not a character.
---@param actor any   # the pawn to decorate (e.g. ctx.actor)
---@return boolean ok, string? reason
function Handle:attachTo(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then
        return false, "attachTo: the actor is not a live UObject"
    end
    return mesh.attachOnce(actor, self._cls:source())
end

---Re-tint an already-attached mesh on `actor`. The re-tint goes to whichever backend
---actually dressed the actor; this mesh's own `kind` is passed only as the hint for the
---case where the attach did not go through PalForge. Works whether or not the mesh
---declared a `color`: the dynamic material is made on the spot if it does not exist yet.
---False — never a pretended tint — when nothing of ours is on the actor to write to.
---@param actor any
---@param color table  # { r, g, b, a } in 0..1
---@return boolean ok, string? reason
function Handle:setColor(actor, color)
    if not (actor and actor.IsValid and actor:IsValid()) then
        return false, "setColor: the actor is not a live UObject"
    end
    return mesh.setColor(actor, color, self._cls.kind)
end

---Undo attachTo, so the actor can be dressed afresh. procedural and static destroy the
---component they added; skeletal, which swaps the pawn's OWN body, puts back the asset,
---scale, offset and materials it captured before the swap. False when nothing of
---PalForge's is on the actor, and when the undo did not execute.
---@param actor any
---@return boolean ok, string? reason
function Handle:detach(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then
        return false, "detach: the actor is not a live UObject"
    end
    return mesh.detach(actor)
end

-- ---- queries ----

---The lowered spec core.mesh will render.
---@return table
function Handle:source() return self._cls:source() end
---@return string
function Handle:model() return self._cls.model end
---@return string
function Handle:kind() return self._cls.kind or "skeletal" end

--=============================================================================
-- the ASSET catalog — /Game/... paths that are known to exist in this build
--=============================================================================

---Known-good game asset paths plus the resolver behind them. A pack reaches everything it
---needs through this one table:
---
---  Mesh.assets.SM.<name>    UStaticMesh paths       (kind = "static")
---  Mesh.assets.SK.<name>    USkeletalMesh paths     (kind = "skeletal")
---  Mesh.assets.ABP.<name>   AnimBlueprintGeneratedClass paths (`animClass`)
---  Mesh.assets.T.<name>     UTexture2D paths        (`texture`, `params.texture`)
---  Mesh.assets.MI.<name>    material instance paths (`material`)
---  Mesh.assets.palMesh(n)   the conventional SK_ path for a monster folder name
---  Mesh.assets.palAnim(n)   the conventional ABP _C path for the same
---  Mesh.assets.load(p, o)   resolve one yourself -> obj, or nil + why
---  Mesh.assets.probe(sink)  try them all and report (read-only)
---
---Every table entry was OBSERVED in this build — either in the live loaded-object sweep or
---read off a live actor's own component — and core/mesh/assets.lua cites which for each. The
---two builder functions return a path SHAPE and are documented as the weaker claim they are.
Mesh.assets = mesh.assets

---Resolve every asset every REGISTERED mesh declares, and report it as one block. Re-exported
---from core.mesh so a pack has it beside the rest of the domain: `Mesh.validateDeclared()`.
---This is the answer to "my boss is invisible" — it turns a wrong `model` from a silent
---no-render into one MESHVALIDATE line naming the id, the field and what the path resolved
---to. Read-only in the sense that matters (it loads packages; it writes to no actor,
---component or save). Meant to run once at world.ready; safe to run again by hand.
Mesh.validateDeclared = mesh.validateDeclared

Mesh.Class = Class   -- the base class (used for subclassing / override detection)
return Mesh
