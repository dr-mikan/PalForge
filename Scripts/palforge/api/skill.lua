-- palforge/api/skill.lua — PUBLIC skill API + implementation (SELF-CONTAINED).
--
-- A skill is what a Pal can do: an active attack or a passive trait. Same shape as every
-- other api module (call it to define, plus get / get_all + a Handle object with actions
-- and grouped `events`).
--
-- HOW IT INTEGRATES: Skill{ ... } registers the definition class in object_manager under
-- ("skill", id), so it is discoverable (Skill.get / Skill.get_all / core.registry) and a
-- Pal declares which skills it owns by id (Pal{ skills = { ... } }).
--
-- HONEST STATE OF THE 導線: there is NO native skill source. The in-game event probe found
-- no hook that says "this Pal used skill X", and Lua cannot inject a row into the skill
-- DataTables (that is PalSchema's job). So:
--   * NOTHING fires these handlers automatically — no channel emits skill.* at all.
--   * What DOES work is MANUAL invocation: :activate(owner) / :hit(target) /
--     :equip(owner) / :unequip(owner) run the handler now, with the cooldown enforced
--     here in Lua. That is enough to drive a skill from your own code — e.g. from a Pal's
--     onTick, a building's onRightClick, or a keybind.
-- When a native source is found it emits skill.* channels and these same handlers fire
-- without any change to a pack's code.
--
--   local Fireball = Skill{
--       id = "example:Fireball", kind = "active", element = "fire",
--       cooldown = 3.0, power = 50,
--       events = { onActivate = function(skill, owner, ctx) --[[ ... ]] end },
--   }
--   Fireball:activate(myPalActor)      -- runs onActivate unless still cooling down

local om     = require("palforge.core.object_manager")
local icons  = require("palforge.core.icons")
local schema = require("palforge.core.schema")

--=============================================================================
-- SPEC — the shape of Skill{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("Skill.Spec")         -- every field, its type, default and meaning
--   schema.get("Skill.Spec").fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
--=============================================================================

---The behaviour handlers a skill can respond to. All optional. Each receives THIS skill's
---handle as its first argument; only MANUAL invocation fires them today (see the header).
---A handler this list does not name is a hard error, not a silent no-op.
local Events = schema.define("Skill.Spec.Events", {
    { "onActivate", type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "an active skill fired (self, owner, ctx)" },
    { "onHit",      type = "function", sig = "fun(self: Skill.Handle, target: any, ctx: table)",
                    doc = "one of its hits landed (self, target, ctx)" },
    { "onEquip",    type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "a passive was attached (self, owner, ctx)" },
    { "onUnequip",  type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "a passive was removed (self, owner, ctx)" },
})

---What you pass to Skill{ ... }. `id` is the only required field.
local Spec = schema.define("Skill.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "skill id: a game row id or \"pack:name\"" },
    { "name",        type = "string", doc = "shown in skill lists (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "kind",        type = "string", values = { "active", "passive" }, default = "active",
                     doc = "an active skill is fired; a passive one is equipped" },
    { "element",     type = "string", doc = "attribute / element (fire, water, ...)" },
    { "cooldown",    type = "number", doc = "seconds between activations (enforced by :activate)" },
    { "power",       type = "number", doc = "base power / magnitude" },
    { "icon",        doc = "fallback icon used when the DataTable lookup misses" },
    { "events",      type = "table", of = Events, doc = "behaviour handlers (grouped)" },
    { "data",        type = "table", doc = "free-form payload of your own, carried onto the definition" },
})

--=============================================================================
-- the registered skill DEFINITION class. Defaults are inert; define{ events = {...} }
-- overrides them per skill.
--=============================================================================

local Class = {}
Class.__index = Class
Class.kind     = "active"
Class.element  = nil
Class.cooldown = nil
Class.power    = nil
Class.icon     = nil

function Class:onActivate(owner, ctx) end
function Class:onHit(target, ctx) end
function Class:onEquip(owner, ctx) end
function Class:onUnequip(owner, ctx) end

-- The skill-list icon: look the id up in the partner-skill icon DataTable, falling back
-- to the declared self.icon on any miss.
function Class:iconOf()
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.skill, self.id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- cooldown bookkeeping. Per (class, owner) so two Pals with the same skill cool down
-- independently. Owners are engine objects — keep the table weak so it never holds a
-- pawn alive past its lifetime.
--=============================================================================

local NO_OWNER = {}   -- sentinel key for :activate() with no owner
local lastFire = setmetatable({}, { __mode = "k" })  -- ownerKey -> { [clsId] = os.clock() }

local function cooling(cls, owner)
    local cd = tonumber(cls.cooldown)
    if not cd or cd <= 0 then return false end
    local bucket = lastFire[owner or NO_OWNER]
    local last = bucket and bucket[cls.id]
    return last ~= nil and (os.clock() - last) < cd
end

local function stamp(cls, owner)
    local key = owner or NO_OWNER
    lastFire[key] = lastFire[key] or {}
    lastFire[key][cls.id] = os.clock()
end

--=============================================================================
-- TOP — the module surface: Skill{ ... } / Skill.get / Skill.get_all
--=============================================================================

---The skill domain. CALL it to define one; the two named functions look existing ones up.
---@class palforge.skill
---@overload fun(spec: Skill.Spec): Skill.Handle
local Skill = {}

local wrap  -- forward decl; the Skill.Handle wrapper is defined in the BOTTOM section

---Define a skill and register it.
---`spec` is validated against Skill.Spec: `id` is required, unknown fields are an error.
---@param spec Skill.Spec
---@return Skill.Handle
local function define(spec)
    spec = Spec:validate(spec, "Skill")
    local cls = setmetatable({
        id          = spec.id,
        name        = spec.name or spec.id,
        description = spec.description,
        kind        = spec.kind,
        element     = spec.element,
        cooldown    = spec.cooldown,
        power       = spec.power,
        icon        = spec.icon,
        data        = spec.data,
    }, Class)
    cls.__index = cls
    local handle = wrap(cls)
    -- dispatch calls cls:onXxx(...) with the CLASS as self; a handler wants the HANDLE
    -- (what the call returned, and what carries :activate / :equip), so each declared
    -- handler goes in behind a forwarder that swaps it in.
    for name, handler in pairs(spec.events or {}) do           -- onActivate, ...
        cls[name] = function(_, ...) return handler(handle, ...) end
    end
    pcall(function() om.register("skill", spec.id, cls) end)
    return handle
end

-- Calling the module IS defining:  Skill{ id = "example:Fireball", ... }
setmetatable(Skill, { __call = function(_, spec) return define(spec) end })

---Get an EXISTING skill by id: a previously-defined one, else a thin definition over any
---game skill id. Never nil.
---@param id string
---@return Skill.Handle
function Skill.get(id)
    assert(type(id) == "string" and #id > 0, "Skill.get: id (string) is required")
    local cls = om.get("skill", id) or setmetatable({ id = id }, Class)
    return wrap(cls)
end

---Every PalForge-registered skill, as a list of handles.
---@return Skill.Handle[]
function Skill.get_all()
    local out = {}
    for _, cls in pairs(om.all("skill")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the skill OBJECT (Skill.Handle): actions + behaviour events
--=============================================================================

---A definable skill. Obtain one from Skill{ ... } / Skill.get / Skill.get_all.
---@class Skill.Handle
---@field id string   # the skill's id
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions (the working entry points — see the header on why these are manual) ----

---Fire this skill for `owner` NOW, unless it is still cooling down. Returns false when the
---skill is passive (nothing is touched, not even the cooldown), false when the cooldown
---blocked it, and otherwise true — the handler ran to completion. A handler that RAISES is
---swallowed here (fail-soft) and reported as false too, with the cooldown already stamped:
---the clock is stamped before the handler runs, so a raising handler still consumed it.
---@param owner any?   # the Pal / character using the skill
---@param ctx   table? # extra context handed to onActivate
---@return boolean fired
function Handle:activate(owner, ctx)
    local cls = self._cls
    if cls.kind == "passive" then return false end
    if cooling(cls, owner) then return false end
    stamp(cls, owner)
    local ok = pcall(function() cls:onActivate(owner, ctx or {}) end)
    return ok
end

---Report a hit on `target`: runs onHit. Ignores the cooldown and `kind`.
---@param target any
---@param ctx table?
---@return boolean ok  # false only when the handler raised
function Handle:hit(target, ctx)
    local ok = pcall(function() self._cls:onHit(target, ctx or {}) end)
    return ok
end

---Run this skill's onEquip handler for `owner` — the "a passive was attached" moment.
---Nothing is attached FOR you: PalForge keeps no equipped set and the game is never told,
---so whatever "equipped" means is what your handler does. Ignores the cooldown and `kind`.
---@param owner any
---@param ctx table?
---@return boolean ok  # false only when the handler raised
function Handle:equip(owner, ctx)
    local ok = pcall(function() self._cls:onEquip(owner, ctx or {}) end)
    return ok
end

---Run this skill's onUnequip handler for `owner` — the counterpart of :equip. Nothing is
---detached FOR you (nothing was attached); undo in the handler what :equip's did. Ignores
---the cooldown and `kind`.
---@param owner any
---@param ctx table?
---@return boolean ok  # false only when the handler raised
function Handle:unequip(owner, ctx)
    local ok = pcall(function() self._cls:onUnequip(owner, ctx or {}) end)
    return ok
end

---Seconds until this skill is ready again for `owner` (0 when ready).
---@param owner any?
---@return number
function Handle:cooldownLeft(owner)
    local cd = tonumber(self._cls.cooldown)
    if not cd or cd <= 0 then return 0 end
    local bucket = lastFire[owner or NO_OWNER]
    local last = bucket and bucket[self.id]
    if not last then return 0 end
    local left = cd - (os.clock() - last)
    return left > 0 and left or 0
end

-- ---- behaviour events (forward to the definition for manual use) ----

---@param owner any
---@param ctx table
function Handle:onActivate(owner, ctx) if self._cls.onActivate then return self._cls:onActivate(owner, ctx) end end
---@param target any
---@param ctx table
function Handle:onHit(target, ctx) if self._cls.onHit then return self._cls:onHit(target, ctx) end end
---@param owner any
---@param ctx table
function Handle:onEquip(owner, ctx) if self._cls.onEquip then return self._cls:onEquip(owner, ctx) end end
---@param owner any
---@param ctx table
function Handle:onUnequip(owner, ctx) if self._cls.onUnequip then return self._cls:onUnequip(owner, ctx) end end

-- ---- queries ----

---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end
---@return string  # "active" | "passive"
function Handle:kind() return self._cls.kind or "active" end
---@return string?
function Handle:element() return self._cls.element end
---@return number?
function Handle:power() return self._cls.power end

Skill.Class = Class   -- the base hook table (used for override detection / subclassing)
return Skill
