-- palforge/api/skill.lua — PUBLIC skill API + implementation (SELF-CONTAINED).
--
-- A skill is what a Pal can do: an active attack or a passive trait. Same shape as every
-- other api module (define / get / get_all + a Handle object with actions and grouped
-- `events`).
--
-- HOW IT INTEGRATES: Skill.define registers the definition class in object_manager under
-- ("skill", id), so it is discoverable (Skill.get / Skill.get_all / core.registry) and a
-- Pal declares which skills it owns by id (Pal.define{ skills = { ... } }).
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
--   local Fireball = Skill.define{
--       id = "example:Fireball", kind = "active", element = "fire",
--       cooldown = 3.0, power = 50,
--       events = { onActivate = function(self, owner, ctx) --[[ ... ]] end },
--   }
--   Fireball:activate(myPalActor)      -- runs onActivate unless still cooling down

local om    = require("palforge.core.object_manager")
local icons = require("palforge.core.icons")

--=============================================================================
-- TYPES (LuaLS annotations — editor intellisense only; zero runtime cost)
--=============================================================================

---The behaviour handlers a skill can respond to. All optional. Each receives the skill
---class as `self`; only MANUAL invocation fires them today (see the header).
---@class Skill.Events
---@field onActivate fun(self: Skill.Handle, owner: any, ctx: table)   # an active skill fired
---@field onHit      fun(self: Skill.Handle, target: any, ctx: table)  # one of its hits landed
---@field onEquip    fun(self: Skill.Handle, owner: any, ctx: table)   # a passive was attached
---@field onUnequip  fun(self: Skill.Handle, owner: any, ctx: table)   # a passive was removed

---What you pass to Skill.define. `id` is required; everything else is optional.
---@class Skill.Spec
---@field id          string        # skill id: a game row id or "pack:name"
---@field displayName string?       # shown in skill lists (defaults to id)
---@field kind        string?       # "active" (default) | "passive"
---@field element     string?       # attribute / element (fire, water, ...)
---@field cooldown    number?       # seconds between activations (enforced by :activate)
---@field power       number?       # base power / magnitude
---@field icon        any?          # fallback icon when the DataTable lookup misses
---@field events      Skill.Events? # behaviour handlers (grouped)

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
-- TOP — module functions
--=============================================================================

---@class palforge.skill
local Skill = {}

local wrap  -- forward decl; the Skill.Handle wrapper is defined in the BOTTOM section

---Define a skill and register it.
---@param spec Skill.Spec
---@return Skill.Handle
function Skill.define(spec)
    assert(type(spec) == "table",
        "Skill.define: pass a table, e.g. Skill.define{ id = 'X', events = {...} }")
    assert(type(spec.id) == "string" and #spec.id > 0, "Skill.define: spec.id (string) is required")
    local cls = setmetatable({
        id          = spec.id,
        displayName = spec.displayName or spec.id,
        kind        = spec.kind,
        element     = spec.element,
        cooldown    = spec.cooldown,
        power       = spec.power,
        icon        = spec.icon,
    }, Class)
    cls.__index = cls
    if type(spec.events) == "table" then
        for name, handler in pairs(spec.events) do cls[name] = handler end  -- onActivate, ...
    end
    pcall(function() om.register("skill", spec.id, cls) end)
    return wrap(cls)
end

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

---A definable skill. Obtain one from Skill.define / Skill.get / Skill.get_all.
---@class Skill.Handle
---@field id string   # the skill's id
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions (the working entry points — see the header on why these are manual) ----

---Fire this skill for `owner` NOW, unless it is still cooling down. Returns false if the
---cooldown blocked it (or the skill is passive), true if the handler ran.
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

---Report a hit on `target` (runs onHit).
---@param target any
---@param ctx table?
---@return boolean ok
function Handle:hit(target, ctx)
    return pcall(function() self._cls:onHit(target, ctx or {}) end)
end

---Attach this (passive) skill to `owner` — runs onEquip.
---@param owner any
---@param ctx table?
---@return boolean ok
function Handle:equip(owner, ctx)
    return pcall(function() self._cls:onEquip(owner, ctx or {}) end)
end

---Remove this (passive) skill from `owner` — runs onUnequip.
---@param owner any
---@param ctx table?
---@return boolean ok
function Handle:unequip(owner, ctx)
    return pcall(function() self._cls:onUnequip(owner, ctx or {}) end)
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
function Handle:displayName() return self._cls.displayName or self.id end
---@return string  # "active" | "passive"
function Handle:kind() return self._cls.kind or "active" end
---@return string?
function Handle:element() return self._cls.element end
---@return number?
function Handle:power() return self._cls.power end

Skill.Class = Class   -- the base hook table (used for override detection / subclassing)
return Skill
