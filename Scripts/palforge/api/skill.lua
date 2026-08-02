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
-- HONEST STATE OF THE 導線, rewritten 2026-07-26 and corrected after the runs that closed
-- skill-activate-source and skill-passive-source. All four handlers have a CHANNEL, a SOURCE
-- and a DISPATCH — core/event.lua declares skill.activate / skill.hit / skill.equip /
-- skill.unequip, arms a native hook for each, and resolves an emit back to the definition
-- registered under that skill id. THREE OF THE FOUR HAVE NOW BEEN SEEN FIRING IN A REAL SAVE:
--   * onActivate — observed in real combat, carried by PalActionBase:OnBeginAction, with the
--     move's own EPalWazaID on `self` (skill-activate-source, Closed);
--   * onEquip / onUnequip — observed from AddPassiveSkill (skill-passive-source, Closed);
--   * onHit — the one that CANNOT fire, and that is SETTLED rather than pending. Both of its
--     sources are measured silent from both sides, and nothing in the damage path carries a
--     waza id at all, so there is no third source left to find. skill-hit-source closes as a
--     negative; declaring onHit now WARNS at define time, and :hit(target) is the only thing
--     that runs it. The comment on the field carries the measurement.
-- This header used to say, in capitals, that none of the four had ever been seen firing. It
-- was written before the runs and left standing after them — which is the expensive kind of
-- stale comment, because the failure is silent: a pack author who believes it writes around a
-- channel that works, and nothing ever tells them. Closing an item includes its doc strings.
--   * a declared `events` table is live for three of the four, and the log names the source
--     the first time each channel carries something, so a session says which path fired;
--   * MANUAL invocation is unchanged and unconditional: :activate(owner) / :hit(target) /
--     :equip(owner) / :unequip(owner) run the handler now, with the cooldown enforced here
--     in Lua — from a Pal's onTick, a building's onRightClick, or a keybind. It is still the
--     only route for onHit;
--   * only a skill DEFINED with Skill{ ... } is dispatched to. Skill.get("FireBlast") hands
--     back a handle that was never registered, so the game firing FireBlast reaches nothing;
--   * ctx.skillId is an EPalWazaID NAME for the two combat channels ("FireBlast", the list is
--     core.character.wazaNames()) and a passive row FName for the two passive ones;
--   * Lua still cannot inject a row into the skill DataTables — that is PalSchema's job — and
--     nothing here reaches the engine except :iconOf, :teach, :forget and :skillsOn.
-- Each hook below records which native function feeds it and how strong the evidence is; the
-- full account, including the one route the dumps CLOSED, is in core/event.lua's SOURCE skill
-- block.
--
-- WHAT AN ACTIVE SKILL CAN AND CANNOT DO, and it is a boundary rather than a gap
-- (skill-projectile-spawn, measured 2026-08-02). A handler decides WHEN it runs and nothing
-- about WHAT comes out: no call reachable from Lua on this build puts a projectile, an effect
-- actor or anything else in the world. Six routes were walked in a real save — the running
-- build DECLARED all six parameter lists — and every one of them takes a struct
-- (FVector / FTransform / FRandomStream / an out-struct by reference), which is the argument
-- shape that faults inside UE4SS's own marshalling where pcall cannot see it. So all six were
-- refused by name and the process survived because the hook refused rather than called.
-- Two consequences are IMPLEMENTED here rather than left as prose:
--   * :spawnProjectile() exists and always answers false with that reason, so the refusal has
--     a name and a measurement instead of being a function a pack author cannot find;
--   * :activate answers `ran, reason` and no longer returns true for a handler that reported
--     it produced nothing — a handler says so by returning false, which is what the curated
--     native/skills.lua FlameThrower now does. `true` means the cooldown was stamped and the
--     handler ran; it has never meant, and cannot mean, that the world changed.
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
local uo        = require("palforge.core.uobject")
local log       = require("palforge.utils.log").scope("skill")

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
    -- THREE SOURCES, and the first of them is a MEASUREMENT rather than a candidate.
    --   1. /Script/Pal.PalUtility:PlayActionByWazaID(AActor*, AActor*, EPalWazaID)
    --      (dumps/cxx/Pal.hpp:32037, reflected at 02_reflection.txt:2049). ARMED AND MEASURED
    --      SILENT, 2026-07-26: a pal fought and killed another pal in a real save, pal.damaged
    --      and pal.death both carried events, this carried nothing. It is a Blueprint-facing
    --      helper the shipping combat path walks past. Still armed (UE4SS cannot unregister,
    --      and a silent hook costs nothing) but it is not what will fire.
    --   2. /Script/Pal.PalActionBase:OnBeginAction (Pal.hpp:13122). `self` IS the move: a pal's
    --      attack is a UPalActionWazaBase, which carries `EPalWazaID WazaID` on the object
    --      itself (:13272), plus GetActionCharacter (:13141) and GetActionTarget (:13138).
    --      THIS IS THE ONE THAT FIRES — measured in real combat, and the failure mode feared
    --      for it (a BP subclass owning the UFunction ProcessEvent runs, leaving a hook on the
    --      base behind it) did not materialise on this build.
    --   3. /Script/Pal.PalPlayerCharacter:OnBeginAction(const UPalActionBase* action)
    --      (Pal.hpp:10651) — a delegate TARGET of UPalActionComponent::OnActionBeginDelegate,
    --      REFLECTED in the live build's PalPlayerCharacter listing. Bound to the PLAYER's
    --      action component, so it covers the player's own waza actions and NOT a pal's.
    -- ctx = { skillId, wazaId, owner, actor, target, via } (+ ctx.action for sources 2 and 3).
    -- `via` names which source carried it; the log announces the first one per session.
    -- onActivate FIRES, observed 2026-07-26 in real combat, carried by
    -- PalActionBase:OnBeginAction, and closed as skill-activate-source. A pal's move is an
    -- action object that holds its own waza id; the utility function this used to hook
    -- registered fine and never carried anything. The doc string below kept saying "none seen
    -- firing" after that run — and it is the sentence schema.help("Skill.Spec.Events") prints
    -- and the generated types.lua shows in the editor, so it was talking authors out of the
    -- one combat channel that works.
    { "onActivate", type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "LIVE - an active skill fired (self, owner, ctx); via = \"PalActionBase:OnBeginAction\"" },
    -- TWO SOURCES, same shape: the first is measured silent, the second replaces it.
    --   1. /Script/Pal.PalUtility:MakeDamageInfoByWazaType(..., EPalWazaID WazaType, ...)
    --      (Pal.hpp:32046, 7th parameter). ARMED AND MEASURED SILENT in the same fight in which
    --      pal.damaged fired, so damage is not built through this helper. Kept armed.
    --   2. /Script/Pal.PalAnimNotifyState_AttackCollision:OnHit(MyHitComponent, HitActor,
    --      HitComponent, FoliageIndex, HitLocation, HitCount) (Pal.hpp:13576) — the melee
    --      attack window itself, and a delegate TARGET whose parameter list matches
    --      UPalHitFilter::OnHitDelegate field for field (:20614), so it runs through
    --      ProcessEvent AND only after the filter accepted the overlap. The identity is on the
    --      notify's `AttackFilter`: UPalAttackFilter.Waza (:14069) and .Attacker (:14077).
    --      DECLARED ONLY. Its limit: this is the COLLISION path. A projectile move lands
    --      through APalBullet (:8849), which carries OwnerStaticItemId and no waza at all.
    -- ctx = { skillId, wazaId, target, owner, attacker, location, via } (+ ctx.filter for 2).
    -- WHAT IS CLOSED: the victim side, permanently. OnDamageReaction's one parameter is
    -- FPalDamageRactionInfo, whose COMPLETE field list is IsBlow / BlowVelocity /
    -- IsLeanBackAnime / IsStan / IsLargeDown / HitLocation (Pal.hpp:1885) — no skill, no waza,
    -- no attacker. FPalDamageInfo (:1834) has 40 fields and FPalDamageResult (:1896) has 12,
    -- and neither has an EPalWazaID. So no amount of struct walking on the damage hook could
    -- ever have named the skill, and the attacker side is the only side that can. Do not
    -- re-probe those structs.
    -- skill-hit-source, CLOSED AS A NEGATIVE. There is no TODO marker here any more, because
    -- the item is not waiting on a measurement: it is waiting on nothing. Three things were
    -- measured, and they rule out different halves of the question.
    --   * MakeDamageInfoByWazaType: armed, silent while a pal fought and killed another pal.
    --   * PalAnimNotifyState_AttackCollision:OnHit: armed, silent in that same session, and
    --     silent again on 2026-07-26 in a session where the player killed a pal by hand —
    --     pal.damaged and pal.death both carried, so a blow certainly connected and certainly
    --     did damage. A hit reaches neither hook, from either side.
    --   * AND THE DAMAGE PATH CARRIES NO WAZA AT ALL, which is why a third hook would not help.
    --     FPalDamageInfo has 40 fields, FPalDamageRactionInfo 6, FPalDamageResult 12, and not
    --     one of the 58 is an EPalWazaID — the closest are EPalWazaCategory (a Melee/Shot
    --     bucket, not an identity) and FName AttackStaticItemID (the weapon). The victim side
    --     cannot answer "which skill" at any depth of struct walking, so the silence above is
    --     not a hook that was pointed at the wrong function. Do not re-probe those structs.
    -- THAT IS WHY THE doc STRING SAYS "never fires" AND NOT "not yet wired". The two read the
    -- same to a pack author skimming schema.help and mean opposite things: one is a channel
    -- that will light up on some later build or some later pass, and the other is a handler
    -- that can never run because the game does not know what to tell it. Declaring onHit is
    -- WARNED at define time for the same reason Audio.Spec.soundFile is refused at define time
    -- (api/audio.lua's refuseSoundFile) — an author who writes a handler that can never be
    -- called deserves to hear about it while they are writing it, not from a silence.
    --
    -- WHY THERE IS NO CORRELATED GUESS BEHIND ANOTHER NAME EITHER, and this was designed and
    -- then declined rather than forgotten. The id could reach a hit by being REMEMBERED from
    -- the activation before it and attributed to the damage after it — skill.activate works and
    -- carries the waza id (source "PalActionBase:OnBeginAction", measured), pal.damaged works,
    -- and a window of a second or so between them is all a correlator would need. That is
    -- INFERENCE, not a source, so it could never live on onHit, which promises the game told
    -- us; it would have to be a separate channel whose NAME says it is a guess. It is not
    -- offered because the one number that would justify it has never been measured: how often
    -- the guess would be wrong. test/hooks/skill_hit_source.lua block [3] exists to count
    -- exactly that — damage events with NO activation in the preceding second (damage a
    -- correlator would blame on a move that had already finished) and damage events with MORE
    -- THAN ONE (damage it would have to pick between) — and the run that would have produced
    -- those two counts measured nothing, because nobody hit anything inside its window. So
    -- PalForge would be shipping a guess with an unmeasured error rate, to authors who cannot
    -- see the error rate, in place of a source. Run that hook in a real fight first; the
    -- numbers it prints are the whole decision, and a channel named for what it is
    -- ("skill.attributedHit", opted into, ctx carrying the gap and the count of candidates) is
    -- the only shape it may ever take. Never onHit.
    { "onHit",      type = "function", sig = "fun(self: Skill.Handle, target: any, ctx: table)",
                    doc = "NEVER FIRES on this build and not for want of a hook: nothing in the damage path carries a waza id, so the game cannot say which move did the damage (skill-hit-source, measured). Declaring it warns at define time; only :hit(target) runs it" },
    -- TWO SOURCES for the pair, and again the first is measured rather than assumed.
    --   1. /Script/Pal.PalIndividualCharacterParameter:AddPassiveSkill(FName AddSkill, FName
    --      OverrideSkill) — Pal.hpp:21155 — and :RemovePassiveSkill(FName SkillId) — :21003.
    --      Both are in the live build's listing of that class (02_reflection.txt:1107) and both
    --      take FNames, not an index; the owner is the same object's `APalCharacter*
    --      IndividualActor` (:20910). THIS IS THE SOURCE THAT CARRIED — see the measurement
    --      below. It had been armed and measured SILENT across an earlier session of catching
    --      and releasing pals, which is a fact about the GAME's own bench/party writes and not
    --      about the hook: what made it carry was a write. ctx = { skillId, owner, actor,
    --      params, overrides, via }. `overrides` is AddPassiveSkill's second argument passed
    --      straight through; it is NOT read as an unequip, because the name does not say which
    --      of the two ids is being displaced.
    --   2. /Script/Pal.PalPassiveSkillComponent:SetupSkillFromSelf(UObject* OwnerObject,
    --      const TArray<FName>& skillList) — Pal.hpp:26582. The component that actually applies
    --      passive effects, handed the WHOLE list. Because it is a list and not an event, the
    --      source DIFFS it against what it last saw for that component: a new name is an equip,
    --      a vanished one an unequip. DECLARED ONLY. THE COST, stated rather than hidden: the
    --      first call for a component emits equip for every passive that character already has,
    --      so a pal streaming into the world announces its four passives once. Keep onEquip
    --      idempotent. ctx = { skillId, owner, actor, component, source, via }.
    -- onEquip FIRES, observed 2026-07-26 and closed as skill-passive-source: skill.equip
    -- carried its first event from source "AddPassiveSkill". The write that triggered it came
    -- from PalForge itself — core/character.addSkill put a passive on a live BP_ChickenPal_C
    -- and read it back — which is a useful property in its own right: the source catches a
    -- pack's own writes as well as the game's, so a handler must be ready to hear about a
    -- change it made itself. It also confirms the passive half of pal-skills-equip in passing.
    -- WHAT IS STILL OPEN, and it is not whether the channel works: SetupSkillFromSelf stays
    -- armed beside it and has carried nothing yet, so which call the GAME uses when a player
    -- changes a passive at a bench is unsettled. The log names the source, so one bench visit
    -- answers it. Both doc strings below said "none seen firing" long after the firing — the
    -- string a pack author reads out of schema.help / types.lua, which is the whole cost.
    { "onEquip",    type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "LIVE - a passive was attached (self, owner, ctx); via names the source" },
    { "onUnequip",  type = "function", sig = "fun(self: Skill.Handle, owner: any, ctx: table)",
                    doc = "LIVE - a passive was removed (self, owner, ctx); via names the source" },
})

---What you pass to Skill{ ... }. `id` is the only required field.
-- `id` carries schema.validId, not schema.nonEmpty: a namespaced id must survive
-- object_manager.resolve to name anything the game has ("pack:Fireball" -> "pack_Fireball"),
-- so an id that cannot resolve is refused at define time instead of registering dead. The
-- rule is written once, in core/schema.lua.
local Spec = schema.define("Skill.Spec", {
    { "id",          type = "string", required = true, check = schema.validId,
                     doc = "skill id: a game row id or \"pack:name\"" },
    { "name",        type = "string", doc = "shown in skill lists (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "kind",        type = "string", values = { "active", "passive" }, default = "active",
                     doc = "an active skill is fired; a passive one is equipped" },
    -- element and power are AUTHOR METADATA, and the doc strings now say so, because the
    -- neighbourhood was misleading: `cooldown` beside them is real — :activate and
    -- :cooldownLeft enforce it in Lua — while these two are validated, stored, handed back by
    -- :element() / :power() and read by NOTHING in the framework. They were not dropped
    -- because a pack's own onActivate is where damage and typing are decided, and carrying
    -- them on the definition is what lets a handler and a UI read one declaration instead of
    -- inventing a parallel `data` convention. A skill's real element and power live in the
    -- game's skill DataTable rows, which Lua cannot author (PalSchema's job) and which nothing
    -- here writes. Item.Spec.Recipe states the same thing about itself in the same words.
    { "element",     type = "string",
                     doc = "attribute / element (fire, water, ...). AUTHOR METADATA: stored and handed back, read by nothing" },
    { "cooldown",    type = "number", doc = "seconds between activations (enforced by :activate)" },
    { "power",       type = "number",
                     doc = "base power / magnitude. AUTHOR METADATA: stored and handed back, read by nothing" },
    -- ONE KIND OF THING, declared — the same decision as Item.Spec.icon, for the same reason:
    -- core/icons answers a /Game/... asset PATH as a plain string (the icon column is read as
    -- text, because the TSoftObjectPtr in the row cannot be unwrapped from Lua), so the
    -- declared fallback is a string path too and :iconOf answers string|nil, always.
    { "icon",        type = "string",
                     doc = "/Game/... texture path used when the icon DataTable has no row for this id" },
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
-- THE ID IS RESOLVED FIRST (F-3/C5). The table is keyed by the row spelling PalSchema writes,
-- so a namespaced id has to be asked for as "pack_Fireball", never "pack:Fireball" — the raw
-- form could not match a row under any circumstances, which made every namespaced skill look
-- like one more miss in a table that misses a lot anyway. `or self.id` is the boundary rule:
-- an id that will not resolve falls back to the LITERAL, never to nothing.
function Class:iconOf()
    local id = om.resolve(self.id) or self.id
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.skill, id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- cooldown bookkeeping. Per (class, owner) so two Pals with the same skill cool down
-- independently.
--
-- THE OWNER KEY IS core.uobject.key (the owner's GetFullName), NOT the owner handle —
-- contract C1. The comment above this table always said "ownerKey"; the code passed the raw
-- handle, and UE4SS mints a fresh userdata wrapper per lookup, so two references to one pawn
-- are not the same Lua value and Lua indexes a table by userdata IDENTITY. The consequence
-- was that `cooldown` did nothing at all for any engine owner: :activate(pawn) stamped the
-- clock under the wrapper the caller happened to hold, and the next :activate — reached
-- through a pawn from a later FindAllOf, or from an event's ctx.actor, which is a different
-- wrapper again — found an empty bucket and fired immediately. `cooldownLeft` answered 0 for
-- the same reason. Nothing raised and nothing was logged; a declared cooldown was simply
-- ignored, which is the silent-failure shape A-1 is about. It only ever worked for the
-- NO_OWNER sentinel and for a plain Lua table owner (which IS identity-stable) — i.e. for
-- exactly the cases test/cases/skill.lua exercises.
--
-- Anything that answers GetFullName is keyed on that name; anything that does not keys on
-- itself. That covers all three cases without asking what type an owner is: a UObject is
-- named, a plain Lua table owner (which a pack is free to pass, and which IS
-- identity-stable) is not and keys on itself, and an object that will not answer its own
-- name falls back to the handle — the old behaviour for that one object, which is the honest
-- floor rather than `t[nil]`, which raises.
--
-- WEAK KEYS ARE GONE WITH THE HANDLE KEY. `__mode = "k"` existed so a cooldown stamp could
-- never hold a pawn alive past its lifetime; a string key is not collectable, so it would
-- have made the table immortal instead. What replaces it is a bounded sweep: a bucket whose
-- newest stamp is older than COOLDOWN_KEEP_SEC can no longer make `cooling` say true for any
-- cooldown a definition can plausibly declare, so it is dropped on the next stamp. The table
-- therefore holds one small bucket per owner that fired something recently, and a pal that
-- despawns takes its bucket with it a minute later.
--=============================================================================

local NO_OWNER = {}   -- sentinel key for :activate() with no owner
local lastFire = {}   -- ownerKey -> { [clsId] = os.clock() }

-- How long a bucket is kept after its newest stamp. Well past any cooldown a definition
-- would declare, and the only thing that bounds this table now that the keys are names.
local COOLDOWN_KEEP_SEC = 600
local lastSweep = 0

-- The bucket key for `owner`. See the C1 note above for the three cases.
local function ownerKey(owner)
    if owner == nil then return NO_OWNER end
    return uo.key(owner) or owner
end

-- Drop buckets nothing can still be cooling in. Runs at most once a minute, from stamp()
-- only — a read must never mutate the table it is answering from.
local function sweep(now)
    if now - lastSweep < 60 then return end
    lastSweep = now
    for key, bucket in pairs(lastFire) do
        local newest = 0
        for _, at in pairs(bucket) do if at > newest then newest = at end end
        if now - newest > COOLDOWN_KEEP_SEC then lastFire[key] = nil end
    end
end

local function cooling(cls, owner)
    local cd = tonumber(cls.cooldown)
    if not cd or cd <= 0 then return false end
    local bucket = lastFire[ownerKey(owner)]
    local last = bucket and bucket[cls.id]
    return last ~= nil and (os.clock() - last) < cd
end

local function stamp(cls, owner)
    local key = ownerKey(owner)
    local now = os.clock()
    sweep(now)
    lastFire[key] = lastFire[key] or {}
    lastFire[key][cls.id] = now
end

--=============================================================================
-- TOP — the module surface: Skill{ ... } / Skill.get / Skill.get_all
--=============================================================================

---The skill domain. CALL it to define one; the two named functions look existing ones up.
---@class palforge.skill
---@overload fun(spec: Skill.Spec, opts: table?): Skill.Handle
local Skill = {}

local wrap  -- forward decl; the Skill.Handle wrapper is defined in the BOTTOM section

-- THE onHit DEFINE-TIME WARNING. A WARNING and not an error, and the difference is the whole
-- design: Audio.Spec.soundFile is refused outright because it was ACTIVELY HARMFUL (it outranked
-- soundId, so declaring it silenced audio that was playing), while onHit is merely never
-- dispatched to — :hit(target) runs it, on any value, and a pack that drives its own combat
-- bookkeeping is entitled to declare one. Erasing that would break working packs to punish a
-- misunderstanding. So the author is TOLD, once per definition, at the moment they wrote it,
-- with the id in the line so a pack with fifty skills knows which one to look at. This is the
-- half of the item a doc string cannot do: schema.help("Skill.Spec.Events") is read by someone
-- who already suspects, and this reaches someone who does not.
local function warnUndispatchableOnHit(spec)
    if type(spec.events) ~= "table" or spec.events.onHit == nil then return end
    log.warn(string.format(
        "Skill{ id = %q } declares onHit, and NOTHING WILL EVER CALL IT for you. The game does "
        .. "not report which move did a hit on this build: both candidate sources are measured "
        .. "silent and the damage path carries no waza id at all (FPalDamageInfo 40 fields, "
        .. "FPalDamageRactionInfo 6, FPalDamageResult 12, not one an EPalWazaID) -- the closed "
        .. "negative skill-hit-source. Your handler runs ONLY when you call skill:hit(target) "
        .. "yourself. If you wanted 'the game fired my skill', that is onActivate, which does "
        .. "fire (via PalActionBase:OnBeginAction, measured).", tostring(spec.id)))
end

---Define a skill and register it.
---`spec` is validated against Skill.Spec: `id` is required, unknown fields are an error.
---
---`opts` is optional and omitting it behaves exactly as it always has:
---  { register = false }   build and return the handle, register NOTHING — what a native
---                         catalog uses so that READING native.skills.FireBlast stops writing
---                         to the registry.
---  { pack = "mypack" }    register attributed to that pack, which is what gives a collision
---                         a "who". PalForge.pack("mypack").Skill is the same thing without
---                         passing it per call.
---@param spec Skill.Spec
---@param opts table?
---@return Skill.Handle
local function define(spec, opts)
    local register, pack = schema.defineOpts(opts, "Skill")
    spec = Spec:validate(spec, "Skill")
    warnUndispatchableOnHit(spec)
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
    -- so core/event's skill dispatch and Skill.get find it — unless the caller asked for a
    -- definition that stays out of the registry, which is a build, not a define.
    if register then
        pcall(function() om.register("skill", spec.id, cls, { pack = pack }) end)
    end
    return handle
end

-- Calling the module IS defining:  Skill{ id = "example:Fireball", ... }
setmetatable(Skill, { __call = function(_, spec, opts) return define(spec, opts) end })

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

---Fire this skill for `owner` NOW, unless it is still cooling down. Answers `ran, reason`.
---
---`true` means EXACTLY this: the cooldown was stamped and this skill's onActivate ran to
---completion without raising and without reporting a failure of its own. It does NOT mean
---anything happened in the world, and on this build it cannot: no call reachable from a skill
---handler puts a projectile or any other actor into Palworld — all six candidate routes take a
---struct argument and are refused (measured 2026-08-02, hook skill-projectile-spawn; the
---refusal is :spawnProjectile below). An active skill is a well-timed Lua function, and what
---it does is whatever your handler does.
---
---`false` NEVER comes alone — the second return is an English reason, one of:
---  * the skill is passive (nothing is touched, not even the cooldown);
---  * the cooldown blocked it, with the remainder;
---  * the handler raised, with the error (swallowed here, fail-soft);
---  * THE HANDLER REPORTED THAT IT COULD NOT DO THE THING. That is the case a boolean used to
---    swallow, and it is now how a handler stays honest: `return false` from onActivate — with
---    an optional reason string — and :activate answers false with it. Anything else the
---    handler returns (a number, a string, true, nothing at all) still means "ran", so no
---    existing handler changes meaning. native/skills.lua's curated FlameThrower is the worked
---    example: it asks :spawnProjectile, is refused, and returns that refusal.
---The clock is stamped BEFORE the handler runs, so a raiser — and a handler that reports
---failure — still consumed the cooldown.
---@param owner any?   # the Pal / character using the skill
---@param ctx   table? # extra context handed to onActivate
---@return boolean ran
---@return string? reason  # always present when `ran` is false
function Handle:activate(owner, ctx)
    local cls = self._cls
    if cls.kind == "passive" then
        return false, "this skill is kind = \"passive\": a passive is equipped, not fired "
            .. "(:equip / :teach), so nothing was run and the cooldown was not touched"
    end
    if cooling(cls, owner) then
        return false, string.format("still cooling down: %.2fs left of the declared %ss",
            self:cooldownLeft(owner), tostring(cls.cooldown))
    end
    stamp(cls, owner)
    -- The handler's OWN return is consulted now, and only a literal `false` counts. nil (a
    -- handler that ends without a return) is by far the commonest value and must keep meaning
    -- "ran"; so must a truthy value a handler happens to compute. Opting in by returning false
    -- is what makes "ran and produced nothing" expressible at all, which a single boolean never
    -- could — see plan/TODO.md Owed work §1, which asked for exactly this distinction.
    local ok, reported, why = pcall(function() return cls:onActivate(owner, ctx or {}) end)
    if not ok then
        return false, "the handler raised (caught here, not propagated): " .. tostring(reported)
    end
    if reported == false then
        return false, (type(why) == "string" and #why > 0) and why
            or "the handler reported that it could not produce its effect, and named no reason"
    end
    return true
end

-- The measured reason, written once so :spawnProjectile and anything that grows beside it
-- cannot drift from each other or from the hook that produced it.
local NO_PROJECTILE_ROUTE =
    "no projectile can be spawned from Lua on this build. Measured 2026-08-02 by hook "
    .. "skill-projectile-spawn in a live save: the running build DECLARED the parameter list of "
    .. "every candidate (ShootOneBullet, CreateChildSkillEffect, APalSkillEffectBase::Initialize, "
    .. "BeginDeferredActorSpawnFromClass, FinishSpawningActor, FindWazaForBP) and all six carry a "
    .. "struct argument -- an FVector, an FTransform, an FRandomStream or an out-struct by "
    .. "reference. A struct marshals by layout, so a mismatch faults inside UE4SS below Lua where "
    .. "pcall cannot see it and takes the process with it, and PalForge has never pushed one. The "
    .. "one argument-free entry on the whole surface, ShootOneBulletDefault(), needs a live "
    .. "APalMonsterEquipWeaponBase, which a skill handler is never handed. This is a refusal, not "
    .. "a bug: nothing about it fails quietly"

---Put a projectile in the world for this skill. ALWAYS answers `false, reason` on this build.
---
---It exists so the boundary has a NAME. A pack author writing onActivate goes looking for the
---call that makes something come out, and the honest answer to that search is a function that
---refuses and says why — measured, dated and attributed to the hook that measured it — rather
---than no function at all, which reads as "I have not found it yet" and costs an evening.
---
---Use it as the curated native/skills.lua FlameThrower does: ask it, and hand its refusal
---straight back out of your handler, so `:activate` answers false with the reason instead of
---true for a fireball nobody saw:
---```lua
---  onActivate = function(self, owner) return self:spawnProjectile(owner) end
---```
---If the route ever opens, this is the one function that changes and every handler shaped like
---that starts working; nothing else in the API has to move.
---@param owner any?  # the Pal / character the projectile would come from
---@param opts table? # accepted and ignored: there is nothing yet to configure
---@return boolean spawned  # always false
---@return string reason
function Handle:spawnProjectile(owner, opts)
    -- The arguments are named and unread on purpose: they are the shape the call WILL have if
    -- the route ever opens, so a handler written against it today does not have to be rewritten
    -- then. Refusing with the signature already right is cheaper than refusing with no signature.
    return false, NO_PROJECTILE_ROUTE
end

---The same refusal as a plain string, for a UI, a log line or a pack that wants to explain
---itself in its own words. Never nil — when a route exists this stops being a constant.
---@return string
function Skill.projectileRefusal() return NO_PROJECTILE_ROUTE end

---Report a hit on `target`: runs onHit. Ignores the cooldown and `kind`.
---
---THE ONLY THING THAT EVER RUNS onHit, and that is measured rather than provisional: the game
---does not report which move did a hit on this build — both candidate sources are silent and
---the damage path carries no waza id at all (skill-hit-source). So "report" is literal. YOU
---decide a hit happened and YOU say so; nothing here watches the world for one.
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

---What `actor` actually carries right now, straight from the game — FOUR lists, not two:
---```
---{ active    = { "FireBlast", ... },   -- the up-to-four moves equipped right now
---  passive   = { "Legend", ... },      -- passive skill FNames
---  equipable = { "Fireball", ... },    -- moves it COULD equip
---  mastered  = { "Fireball", ... } }   -- moves it has learned
---```
---This doc used to name only the first two, which is worse than a missing sentence: a caller
---reads it and never learns that an empty `active` on a wild pal is normal rather than a read
---that missed. `equipable` and `mastered` are read for exactly that reason — they cost one
---call each and they are what distinguishes "nothing equipped" from "nothing reachable"
---(core/character.lua:507-511 is where the four are assembled).
---
---Empty lists mean the read worked and found none; nil for the whole table means the
---character could not be read at all — UNKNOWN, never "has none". This is a query about the
---CHARACTER, not about this skill, and it is on the handle only because that is where a
---caller already is.
---@param actor any
---@return table?
function Handle:skillsOn(actor) return character.skillsOn(actor) end

---Seconds until this skill is ready again for `owner` (0 when ready).
---@param owner any?
---@return number
function Handle:cooldownLeft(owner)
    local cd = tonumber(self._cls.cooldown)
    if not cd or cd <= 0 then return 0 end
    local bucket = lastFire[ownerKey(owner)]
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

---The icon as a /Game/... asset path: the partner-skill DataTable's row for this id (only a
---pal-derived partner skill can have one — that table is keyed by PAL id), else the declared
---`icon`, else nil. One kind of value, never an engine object — see the Skill.Spec `icon` note.
---@return string?
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end
---@return string  # "active" | "passive"
function Handle:kind() return self._cls.kind or "active" end
---The DECLARED element. Author metadata: nothing in PalForge reads it, and the game's own
---typing lives in a DataTable row Lua cannot author. See Skill.Spec.
---@return string?
function Handle:element() return self._cls.element end
---The DECLARED power. Author metadata, exactly like :element() — your onActivate is where a
---number like this turns into anything.
---@return number?
function Handle:power() return self._cls.power end

Skill.Class = Class   -- the base hook table (used for override detection / subclassing)
return Skill
