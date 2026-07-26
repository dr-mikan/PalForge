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
-- HONEST STATE OF THE 導線, rewritten 2026-07-26. All four handlers now have a CHANNEL, a
-- SOURCE and a DISPATCH — core/event.lua declares skill.activate / skill.hit / skill.equip /
-- skill.unequip, arms a native hook for each, and resolves an emit back to the definition
-- registered under that skill id. What is still missing is the last mile, and it is the same
-- for all four: NONE OF THE FOUR HOOKS HAS BEEN SEEN TO FIRE IN GAME. They were chosen from
-- dumps/cxx/Pal.hpp (the installed binary's own header dump) with their real signatures, and
-- two of the four classes are reflected in the live build as well, but nobody has yet used a
-- move with them armed. So:
--   * a declared `events` table is no longer inert — but until an F8 run logs a firing,
--     assume it can still be silent, and keep the manual entry points as the reliable path;
--   * MANUAL invocation is unchanged and unconditional: :activate(owner) / :hit(target) /
--     :equip(owner) / :unequip(owner) run the handler now, with the cooldown enforced here
--     in Lua — from a Pal's onTick, a building's onRightClick, or a keybind;
--   * only a skill DEFINED with Skill{ ... } is dispatched to. Skill.get("FireBlast") hands
--     back a handle that was never registered, so the game firing FireBlast reaches nothing;
--   * ctx.skillId is an EPalWazaID NAME for the two combat channels ("FireBlast", the list is
--     core.character.wazaNames()) and a passive row FName for the two passive ones;
--   * Lua still cannot inject a row into the skill DataTables — that is PalSchema's job — and
--     nothing here reaches the engine except :iconOf, :teach and :forget.
-- Each hook below records which native function feeds it and how strong the evidence is; the
-- full account, including the one route the dumps CLOSED, is in core/event.lua's SOURCE skill
-- block.
--
--   local Fireball = Skill{
--       id = "example:Fireball", kind = "active", element = "fire",
--       cooldown = 3.0, power = 50,
--       events = { onActivate = function(skill, owner, ctx) --[[ ... ]] end },
--   }
--   Fireball:activate(myPalActor)      -- runs onActivate unless still cooling down

local om        = require("palforge.core.object_manager")
local icons     = require("palforge.core.icons")
local schema    = require("palforge.core.schema")
local character = require("palforge.core.character")

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
---handle as its first argument, then the subject (the owner, or the TARGET for onHit), then
---ctx. A handler this list does not name is a hard error, not a silent no-op.
local Events = schema.define("Skill.Spec.Events", {
    -- SOURCE: /Script/Pal.PalUtility:PlayActionByWazaID(AActor* actionActor,
    -- AActor* TargetActor, EPalWazaID WazaID) — dumps/cxx/Pal.hpp:32037, and the name is in
    -- the LIVE build's own listing (dumps/reflection/02_reflection.txt:2049 PalUtility). Three
    -- scalar parameters, one of which is the move's identity, which is what every earlier
    -- candidate lacked: PalPlayerController:PlaySkill stays ruled out (armed twice, 0 firings)
    -- and the action-component routes (PlayAction / PlayActionByType) carry a UClass, not a
    -- waza id. ctx = { skillId, wazaId, owner, actor, target }.
    -- TODO(skill-activate-source): unverified IN GAME — reflected and declared, never armed,
    -- so it is unknown whether the C++ combat path goes through this helper or builds its
    -- action directly. Press F8, have a pal use a move, and look for `HOOK skill.activate`.
    -- If it is 0, the next candidate is a UPalActionWazaBase subclass's OnBeginAction:
    -- Pal.hpp:13270 puts `EPalWazaID WazaID` on that class itself, so `self` would carry it.
    { "onActivate", type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "an active skill fired (self, owner, ctx) - source wired, not yet seen firing" },
    -- SOURCE: /Script/Pal.PalUtility:MakeDamageInfoByWazaType(Attacker, Defencer, ...,
    -- EPalWazaID WazaType, ...) — Pal.hpp:32046, 7th parameter, also in the live listing.
    -- ctx = { skillId, wazaId, target, owner, attacker, location }.
    -- WHAT IS CLOSED: the victim side, permanently. OnDamageReaction's one parameter is
    -- FPalDamageRactionInfo, whose COMPLETE field list is IsBlow / BlowVelocity /
    -- IsLeanBackAnime / IsStan / IsLargeDown / HitLocation (Pal.hpp:1885) — no skill, no waza,
    -- no attacker. FPalDamageInfo (:1834) has 40 fields and still no EPalWazaID, only an
    -- EPalWazaCategory bucket and the weapon's AttackStaticItemID. So no amount of struct
    -- walking on the damage hook could ever have named the skill, and the attacker side is
    -- the only side that can. Do not re-probe that struct.
    -- TODO(skill-hit-source): unverified IN GAME, and imperfect by construction even if it
    -- fires — this function BUILDS the damage rather than reporting that it landed, and its
    -- `DamageRatePerCollision` parameter says a multi-collision move may build one per
    -- collision. KEEP onHit IDEMPOTENT. What is left to measure is only the firing.
    { "onHit",      type = "function", sig = "fun(self: Skill.Handle, target: any, ctx: table)",
                    doc = "one of its hits landed (self, target, ctx) - source wired, may repeat per collision" },
    -- SOURCE: /Script/Pal.PalIndividualCharacterParameter:AddPassiveSkill(FName AddSkill,
    -- FName OverrideSkill) — Pal.hpp:21155 — and :RemovePassiveSkill(FName SkillId) — :21003.
    -- Both names are in the live build's full listing of that class (02_reflection.txt:1107).
    -- The old open question is ANSWERED: the parameters are FNames, not an index into a
    -- fixed-size array, and no struct is involved. The owner comes off the same object's
    -- `APalCharacter* IndividualActor` property (:20910), so ctx.owner is a real character.
    -- ctx = { skillId, owner, actor, params, overrides }. `overrides` is AddPassiveSkill's
    -- second argument passed straight through; it is NOT read as an unequip, because the name
    -- does not say which of the two ids is being displaced.
    -- TODO(skill-passive-source): unverified IN GAME. Which player actions route through these
    -- two is still unmeasured — capture-time random assignment and the Statue of Power are the
    -- expectation, party in/out is not. Both are armed only after world.ready, so a passive
    -- restored during the load storm should not surface as an equip; that too is unobserved.
    { "onEquip",    type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "a passive was attached (self, owner, ctx) - source wired, not yet seen firing" },
    { "onUnequip",  type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "a passive was removed (self, owner, ctx) - source wired, not yet seen firing" },
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

-- The skill-list icon: look the id up in the partner-skill icon DataTable, falling back to
-- the declared self.icon on any miss — which is the OVERWHELMINGLY likely outcome, for two
-- separate reasons, so treat `icon` as the real source and this lookup as a bonus:
--   * KEY. The one skill icon table in the 390-table catalog dump,
--     DT_partnerSkillIconDataTable, is keyed by PAL id — its 311 rows are Alpaca / Anubis /
--     Bastet / ... — not by skill id. Intersected against native/skills.lua's CATALOG, 303
--     of 2585 ids match, every one of them a DT_PartnerSkillParameter row that happens to be
--     pal-named; all 1905 DT_PassiveSkill_Main_Common ids miss by construction, and so does
--     the curated "FlameThrower". No icon table in that catalog is keyed by skill id.
--   * READ. No artifact in either tree has ever read a DataTable row VALUE from Lua on this
--     build (the catalog dumper read row NAMES only), so even a matching key is unproven.
-- The icon table read WORKS as of 2026-07-26: core/icons read DT_partnerSkillIconDataTable in a
-- live save and 311 of 311 rows carry an icon. What remains is not a read at all but a KEYING
-- fact this file already records: that table is keyed by PAL id, not by skill id, so only a
-- pal-derived partner skill can ever hit it. A passive skill has no row there and falls back to
-- the declared icon by design, which is the correct answer rather than a missing one.
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
---
---For the OTHER meaning — actually putting this skill on a live pal or player so the game
---itself knows about it — use :teach / :forget below. They are separate on purpose: :equip is
---your own bookkeeping and works on any value, while :teach writes to a real character.
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

---Put this skill on a LIVE character — a pal or the player — so the game itself carries it.
---
---The id decides which kind of skill the game is asked for, because Palworld stores the two
---separately: an id the game knows as an active skill (`"FireBlast"`, `"Psychokinesis"` — the
---full list is core.character.wazaNames()) is added to the character's equipped moves, and any
---other id is added as a passive skill by name. Nothing about this reads your definition's
---`kind` field: `kind` describes YOUR skill's behaviour, and this asks the GAME for one of its
---own, so a pack skill whose id is not a real game skill will be added as a passive under that
---name or not at all.
---
---Returns true only when reading the character back AFTERWARDS shows the skill is there. False
---means it did not land — a target that is not a character, a route the build does not declare,
---or the game refusing the id. It is never "the call ran".
---@param actor any    # a live pal or player character
---@return boolean ok  # true only when the skill was seen ON the character afterwards
function Handle:teach(actor) return character.addSkill(actor, self.id) end

---Take this skill back off a live character. The counterpart of :teach, with the same routing
---and the same read-back: true only when the skill is gone afterwards.
---@param actor any
---@return boolean ok
function Handle:forget(actor) return character.removeSkill(actor, self.id) end

---What `actor` actually carries right now, straight from the game:
---`{ active = { "FireBlast", ... }, passive = { "Legend", ... } }`. Empty lists mean the read
---worked and found none; nil means the character could not be read at all — UNKNOWN, never
---"has none". This is a query about the CHARACTER, not about this skill, and it is on the
---handle only because that is where a caller already is.
---@param actor any
---@return table?
function Handle:skillsOn(actor) return character.skillsOn(actor) end

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
