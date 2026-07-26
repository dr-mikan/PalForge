-- PalForge native.effects: the catalog of the game's OWN ailments, as Effect handles.
--
-- Palworld's ailments are not DataTable rows — there is no bad-status table anywhere in the
-- dumps, and looking for one was a dead end for a long time. They are an ENUM, EPalStatusID,
-- and core/status.lua carries all 38 of its values verbatim from the game's own headers. This
-- file is the thin layer that turns each of those names into an Effect you can apply.
--
--   local effects = require("palforge.native.effects")
--   effects.Burn:apply(target)          -- curated: carries a duration and a tick interval
--   effects.get("Sleep"):apply(target)  -- any of the 38, built on first use
--   effects.get("Sleep"):remove(target)
--
--   (a) M.CATALOG  — every ailment name this build declares, in the game's own spelling.
--   (b) M.get(id)  — a lazy, cached Effect handle for any catalog id; nil for anything else.
--   (c) M.Poison / M.Burn / M.Freeze — the three with hand-written timings.
--
-- WHAT AN APPLICATION DOES. Two things happen and they are worth keeping apart: PalForge runs
-- its own schedule (duration, interval, stacking, expiry) off core/event's heartbeat, and the
-- effect switches the GAME's ailment on through PalCharacter.StatusComponent — the real symbol
-- on the health bar, running on the game's rules. The switch is the effect runtime's job, in
-- api/effect's apply and expire. There is nothing for a handler here to do, which is why the
-- curated three declare none.
--
-- THE TWO ARE A MIRROR, NOT A MERGE. PalForge does not set an ailment's strength and cannot
-- tell whether the game ended it early. A handle with no `duration` — which is everything
-- M.get builds — switches the ailment on and leaves it there, so PalForge will keep calling it
-- active until you :remove() it. The curated three have durations and come off on their own.
--
-- NOT EVERY VALUE IS AN AILMENT A PACK WANTS. The enum is the game's internal list and it
-- includes timers and bookkeeping (ControlSP, DrownCheck, UNKOTimer, Moratorium, the
-- PalEnhancement series). They are all offered rather than curated away: leaving one out would
-- make it look unsupported when it is merely strange, and M.get builds nothing until it is
-- asked for. The ones a pack usually wants are Poison, Stun, Sleep, Burn, Freeze, Electrical,
-- Darkness, Wetness, AttackUp and DefenseUp.
local Effect = require("palforge.api.effect")
local status = require("palforge.core.status")

local M = {}

-- CATALOG (DATA): every ailment name this build declares, sorted. Derived from core.status
-- rather than hand-listed, so it cannot drift from the enum the calls are actually made with.
-- The hand-written list this replaces held three of the thirty-eight.
M.CATALOG = status.names()

local set = {}
for _, id in ipairs(M.CATALOG) do set[id] = true end
local cache = {}

---An Effect handle for any known ailment name, built on first use and cached; nil for a name
---this build does not declare. The handle carries `nativeStatus`, which is what makes applying
---it switch the game's own ailment on.
---
---No `duration` is set, so an ailment fetched this way stays on until you :remove() it. Define
---your own Effect with the same `nativeStatus` if you want one that times out.
---@param id string
---@return Effect.Handle?
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    local h = Effect{ id = id, nativeStatus = id }
    cache[id] = h
    return h
end

-- ---- CURATED: the three with hand-written timings ----
-- These differ from M.get's handles in one way only — a duration, and for two of them a tick
-- interval, so they come off on their own schedule. They carry no handlers deliberately: the
-- ailment already does whatever the game says it does, and an empty handler would only cost a
-- dispatch. Declare your own Effect with the same `nativeStatus` and an `onTick` if you want a
-- payload of your own on top.

M.Poison = Effect{ id = "Poison", nativeStatus = "Poison", duration = 10.0, interval = 1.0 }
M.Burn   = Effect{ id = "Burn",   nativeStatus = "Burn",   duration = 5.0,  interval = 1.0 }
M.Freeze = Effect{ id = "Freeze", nativeStatus = "Freeze", duration = 3.0 }

-- Pre-seed the curated ones so get(id) hands back the timed handle rather than building a
-- second, durationless definition under the same id.
for _, h in ipairs({ M.Poison, M.Burn, M.Freeze }) do
    set[h.id] = true
    cache[h.id] = h
end

return M
