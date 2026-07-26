-- palforge/core/status.lua — the game's own ailment system, addressed by name.
--
-- Palworld carries its status effects on a component every character has:
-- /Script/Pal.PalCharacter exposes a `StatusComponent` property (dumps/reflection/
-- 02_reflection.txt:1007, in the live PalCharacter property list), and the class behind it,
-- UPalStatusComponent, is where the ailment API lives (dumps/cxx/Pal.hpp:29774):
--
--     void AddStatus(EPalStatusID statusID);
--     void RemoveStatus(EPalStatusID statusID);
--     UPalStatusBase* GetExecutionStatus(EPalStatusID statusID);
--     void AddStatusParameter(EPalStatusID statusID, FStatusDynamicParameter Param);
--
-- That settles a search that had been narrowed by elimination for a long time. The old note in
-- api/effect.lua had it exactly right — "reflect the class behind PalCharacter.StatusComponent
-- ... a ByteProperty there means the enum form" — and the answer is the enum form: one integer
-- argument, no struct, no FName. AddStatusParameter's struct variant is deliberately NOT used
-- here (see core/signature.lua on why a struct argument is not passed on an unread declaration).
--
-- THE VOCABULARY, which had no source on disk anywhere before: EPalStatusID, dumps/cxx/
-- Pal_enums.hpp:4246. Thirty-eight named ailments, reproduced below with their real integer
-- values. `Effect{ nativeStatus = "Poison" }` now means something.
--
--   local status = require("palforge.core.status")
--   status.add(pawn, "Poison")      -- true when the game accepted it
--   status.remove(pawn, "Poison")
--   status.isActive(pawn, "Poison")
--
-- NOT YET OBSERVED. The signatures are from a dump generated one game patch before the
-- installed binary, and no run has called any of these. Every call goes through core.signature,
-- which refuses it unless the live class declares it and logs which evidence it fired on. A
-- false here means "the call did not fire", never "the target is immune".
local log       = require("palforge.utils.log").scope("status")
local signature = require("palforge.core.signature")

local M = {}

-- EPalStatusID, verbatim from dumps/cxx/Pal_enums.hpp:4246. `None` (0) and the trailing
-- `EPalStatusID_MAX` sentinel are omitted: neither is an ailment anyone can apply.
--
-- These are the game's own spellings, so they are what `nativeStatus` takes. A few read oddly
-- (UNKOTimer, Moratorium) because they are internal timers rather than player-facing ailments;
-- they are listed because leaving a value out would make it look unsupported when it is simply
-- strange. The ones a pack usually wants: Poison, Stun, Sleep, Burn, Freeze, Electrical,
-- Darkness, Wetness, AttackUp, DefenseUp.
M.ID = {
    ControlSP              = 1,
    GainHP                 = 2,
    StepCooldown           = 3,
    DrownCheck             = 4,
    Poison                 = 5,
    UNKOTimer              = 6,
    Stun                   = 7,
    Coma                   = 8,
    Sleep                  = 9,
    Overwork               = 10,
    Happiness              = 11,
    Resistance             = 12,
    Moratorium             = 13,
    Drown                  = 14,
    Dying                  = 15,
    ShieldRecovery         = 16,
    FallDamage             = 17,
    LavaDamage             = 18,
    Burn                   = 19,
    Wetness                = 20,
    Freeze                 = 21,
    Electrical             = 22,
    Muddy                  = 23,
    IvyCling               = 24,
    Darkness               = 25,
    AttackUp               = 26,
    DefenseUp              = 27,
    CollectItem            = 28,
    LifeSteal              = 29,
    RaidBossStatusChange   = 30,
    RarePalEffect          = 31,
    MorphChange            = 32,
    PalEnhancement         = 33,
    PalEnhancement2        = 34,
    PalEnhancement3        = 35,
    PartBreak              = 36,
    FishingSpotElectrical  = 37,
    HPLock                 = 38,
}

-- The component every PalCharacter carries. Read straight off the actor: it is a property, not
-- a getter, and it is the same on the player pawn and on a pal because both derive from
-- PalCharacter. nil means the actor is not a PalCharacter, or there is no game.
local function componentOf(actor)
    if actor == nil then return nil end
    local comp
    local ok = pcall(function() comp = actor.StatusComponent end)
    if not ok or comp == nil then return nil end
    local okv, valid = pcall(function() return comp.IsValid and comp:IsValid() end)
    if not (okv and valid) then return nil end
    return comp
end

-- Resolve a status NAME to its integer. Names are the game's own spellings and matching is
-- case-insensitive, because "poison" is what a pack author will actually type.
local lowered = nil
local function idOf(name)
    if type(name) == "number" then return name end
    if type(name) ~= "string" then return nil end
    if M.ID[name] then return M.ID[name] end
    if not lowered then
        lowered = {}
        for k, v in pairs(M.ID) do lowered[k:lower()] = v end
    end
    return lowered[name:lower()]
end

---Every status name this build knows, sorted. Useful in an error message, and the honest answer
---to "what can nativeStatus be".
---@return string[]
function M.names()
    local out = {}
    for k in pairs(M.ID) do out[#out + 1] = k end
    table.sort(out)
    return out
end

---Is `name` a status this build declares?
---@return boolean
function M.known(name) return idOf(name) ~= nil end

-- TODO(effect-native-status): unknown whether AddStatus/RemoveStatus FIRE. Everything else is
-- settled — the component is a live property of PalCharacter (dumps/reflection/
-- 02_reflection.txt:1007), the class and its four-function ailment API are declared
-- (dumps/cxx/Pal.hpp:29774), and the vocabulary that had no source anywhere is the 38-value
-- EPalStatusID (dumps/cxx/Pal_enums.hpp:4246). What no run has done is call one. Press F1 in a
-- loaded world: core.signature logs "declared"/"present" and the ailment name, or refuses and
-- says which lookup failed. Watch for the parameter spelling — an EnumProperty build declares
-- it differently from a ByteProperty one, and that mismatch is a refusal, not a crash.
--
-- Shared by add and remove: resolve the component and the id, then make one guarded call.
-- EPalStatusID marshals as a plain integer, which is a scalar — no struct crosses this boundary.
local function invoke(actor, name, fnName, what)
    local id = idOf(name)
    if not id then
        log.err(string.format("%s: '%s' is not a status this build declares — see core.status.names()",
            what, tostring(name)))
        return false
    end
    local comp = componentOf(actor)
    if not comp then
        log.warn(string.format("%s %s: no StatusComponent on that actor (not a PalCharacter, or no world)",
            what, tostring(name)))
        return false
    end
    local ok, _, level = signature.call(comp, fnName, { "ByteProperty" }, id)
    if not ok then
        -- signature.call has already logged the refusal or the raise with its detail. An
        -- EnumProperty build spells the parameter differently from a ByteProperty one, and that
        -- is a real mismatch worth naming rather than retrying blind.
        return false
    end
    log.info(string.format("%s %s (EPalStatusID %d) [%s]", what, tostring(name), id, level))
    return true
end

---Apply the native ailment `name` to `actor`.
---@param name string|integer  # an EPalStatusID name, case-insensitive, or its integer
---@return boolean ok
function M.add(actor, name) return invoke(actor, name, "AddStatus", "status.add") end

---Clear the native ailment `name` from `actor`.
---@return boolean ok
function M.remove(actor, name) return invoke(actor, name, "RemoveStatus", "status.remove") end

---Is the native ailment `name` running on `actor` right now? nil means the question could not
---be asked (no component, or the accessor is not declared) — never false-as-in-no.
---@return boolean?
function M.isActive(actor, name)
    local id = idOf(name)
    local comp = componentOf(actor)
    if not id or not comp then return nil end
    local ok, ret = signature.call(comp, "GetExecutionStatus", { "ByteProperty" }, id)
    if not ok then return nil end
    if ret == nil then return false end
    local okv, valid = pcall(function() return ret.IsValid and ret:IsValid() end)
    return okv and valid == true
end

return M
