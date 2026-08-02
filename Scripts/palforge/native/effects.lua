-- PalForge native.effects: the catalog of the game's OWN ailments, as Effect handles.
--
-- Palworld's ailments are not DataTable rows — there is no bad-status table anywhere in the
-- dumps, and looking for one was a dead end for a long time. They are an ENUM, EPalStatusID,
-- and core/status.lua carries all 38 of its values verbatim from the game's own headers. This
-- file is the thin layer that turns each of those names into an Effect you can apply.
--
--   local effects = require("palforge.native.effects")
--   effects.Burn:apply(target)          -- curated: carries a duration and a tick interval
--   effects.Sleep:apply(target)         -- a NAMED handle for every one of the 38
--   effects.get("Sleep"):remove(target) -- the same handle, by id string
--
--   (a) M.CATALOG  — every ailment name this build declares, in the game's own spelling.
--   (b) M.<Name>   — an Effect handle per ailment, built on first read. native/_catalog.lua
--                    owns the naming rule; for this list it is the identity, because every one
--                    of the 38 EPalStatusID names is already a Lua identifier.
--   (c) M.get(id)  — the same handles by id string; nil for anything else.
--   (d) M.publish(id) — register that handle with object_manager, on request. See below.
--   (e) M.Poison / M.Burn / M.Freeze — the three with hand-written timings.
--
-- A READ REGISTERS NOTHING (2026-08-02). M.get builds with `{ register = false }` (contract C2)
-- — the publish gate, forced by native/buildings.lua where registration is not inert (a
-- registered building def makes core/event track and PERSIST every matching actor, so a field
-- read started writing to the player's save). Effects persist nothing, and 38 rows is not a
-- registry problem, but the gate is one rule in all six catalogs rather than five exceptions.
-- Registration is what makes Effect.get(id) hand back this class rather than fabricate a thin
-- one; the effect RUNTIME (apply / expire / the tick schedule) does not consult the registry at
-- all, so an unregistered handle applies and removes ailments exactly as before. The three
-- CURATED ones below still register at load, under the framework's own pack id (contract C3).
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
local Effect  = require("palforge.api.effect")
local catalog = require("palforge.native._catalog")
local status  = require("palforge.core.status")

local M = {}

-- CATALOG (DATA): every ailment name this build declares, sorted. Derived from core.status
-- rather than hand-listed, so it cannot drift from the enum the calls are actually made with.
-- The hand-written list this replaces held three of the thirty-eight.
M.CATALOG = status.names()

-- Membership set + on-demand cache for get(), plus the alias table the naming rule produces
-- (empty here: all 38 enum names are already Lua identifiers, so every name is its own id).
local set, aliases, unnamed = catalog.index(M.CATALOG)
local cache = {}

---Names that are NOT ids. Empty for this catalog; see native/_catalog.lua rule (2).
M.ALIASES = aliases
---Ailments with no named field, and why. Empty for this catalog; see rules (3) and (4).
M.UNNAMED = unnamed

---An Effect handle for any known ailment name, built on first use and cached; nil for a name
---this build does not declare. The handle carries `nativeStatus`, which is what makes applying
---it switch the game's own ailment on.
---
---No `duration` is set, so an ailment fetched this way stays on until you :remove() it. Define
---your own Effect with the same `nativeStatus` if you want one that times out.
---
---`{ register = false }` (contract C2) is the publish gate described in the header: the handle
---is fully built and fully cached, and object_manager is simply not told about it until
---M.publish(id) is called. Applying and removing an ailment never consulted the registry.
---@param id string
---@return Effect.Handle?
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    local h = Effect({ id = id, nativeStatus = id }, { register = false, pack = catalog.PACK })
    cache[id] = h
    return h
end

---Register this catalog's handle for `id` with object_manager: the opt-in half of the publish
---gate. All it buys for an effect is that Effect.get(id) and Effect.get_all() see this handle
---instead of fabricating a thin one — the runtime does not read the registry — so it exists for
---symmetry with the other five catalogs and for tooling that enumerates definitions.
---
---Idempotent, and it publishes the SAME handle the named field hands back, so a curated entry
---keeps its duration and interval. Returns nil for a name this build does not declare.
---@param id string
---@return Effect.Handle?
function M.publish(id)
    local h = M.get(id)
    if not h then return nil end
    catalog.publish("effect", h, "native.effects")
    return h
end

-- ---- CURATED: the three with hand-written timings ----
-- These differ from M.get's handles in one way only — a duration, and for two of them a tick
-- interval, so they come off on their own schedule. They carry no handlers deliberately: the
-- ailment already does whatever the game says it does, and an empty handler would only cost a
-- dispatch. Declare your own Effect with the same `nativeStatus` and an `onTick` if you want a
-- payload of your own on top.
--
-- They register at load, under the framework's own pack id (contract C3) so that a pack
-- declaring "Poison" replaces a definition whose previous owner can be named. Registering an
-- effect writes nothing anywhere: the persistence that made native/buildings.lua's curated pair
-- a release gate is the building runtime's alone.

M.Poison = Effect({ id = "Poison", nativeStatus = "Poison", duration = 10.0, interval = 1.0 },
                  { pack = catalog.PACK })
M.Burn   = Effect({ id = "Burn",   nativeStatus = "Burn",   duration = 5.0,  interval = 1.0 },
                  { pack = catalog.PACK })
M.Freeze = Effect({ id = "Freeze", nativeStatus = "Freeze", duration = 3.0 },
                  { pack = catalog.PACK })

-- Pre-seed the curated ones so get(id) hands back the timed handle rather than building a
-- second, durationless definition under the same id. All three are named exactly as the enum
-- value is, so the curated field and the named field are the same field — the hand-written
-- declaration simply gets there first, and the lazy path never overwrites it.
for _, h in ipairs({ M.Poison, M.Burn, M.Freeze }) do
    set[h.id] = true
    cache[h.id] = h
end

-- LAST: hang the lazy named fields off the module. After the curated definitions, so the
-- rule-(4) shadow check sees the module's complete own surface. See native/_catalog.lua.
catalog.expose(M, { set = set, aliases = aliases, unnamed = unnamed,
                    get = M.get, label = "native.effects" })

return M
