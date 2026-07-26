-- PalForge native.effects: the HYBRID catalog for status effects (ailments). ONE file
-- per data domain, replacing the old native/effect/ subdirectory.
--
-- NOTE: there is NO bad-status DataTable in the dump. Ailments are the native
-- EPalStatusEffectType ENUM, not DataTable rows — so this CATALOG is the set of known
-- ailment names currently wired (the curated Poison/Burn/Freeze), NOT a dump-extracted
-- row list. Each maps to a native enum value, resolved/applied by the status system
-- (the `-- TODO:` seams below). The full EPalStatusEffectType enum was not present in
-- the reflection dump; extend the CATALOG once it is dumped (see NEEDS OWNER DECISION).
--
--   (a) M.CATALOG  — known ailment names (enum-backed), currently { Poison, Burn, Freeze }.
--   (b) M.get(id)  — a lazy, cached Effect handle for ANY catalog id (nil otherwise).
--   (c) CURATED    — the hand-written Poison/Burn/Freeze definitions.
--
-- The TIMING of an application (duration / interval / expiry) is real — api/effect drives
-- it off core/event's heartbeat. What is missing is the native ailment toggle, so the
-- onApply/onExpire bodies below stay `-- TODO:` while the schedule around them works.
--
--   local effects = require("palforge.native.effects")
--   effects.Burn:apply(target)     effects.get("Poison")  -- lazy handle

local Effect = require("palforge.api.effect")

local M = {}

-- CATALOG (DATA): known ailment names. These map to native EPalStatusEffectType enum
-- values, NOT DataTable rows (there is no bad-status DataTable — see the header note).
M.CATALOG = {
  "Poison", "Burn", "Freeze",
}

local set = {}
for _, id in ipairs(M.CATALOG) do set[id] = true end
local cache = {}

-- get(id): an Effect wrapper for ANY known ailment name, built on first use + cached;
-- nil if id is not a known ailment. defining sets .id and registers into object_manager.
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    local h = Effect{ id = id }
    cache[id] = h
    return h
end

-- ---- CURATED wrappers (native-status-backed ailments, with hooks) ----
-- self.nativeStatus is the native EPalStatusEffectType value to resolve/apply; the
-- apply/remove seams are `-- TODO:` until the native status layer is wired.

M.Poison = Effect{
    id           = "Poison",
    nativeStatus = "Poison",
    duration     = 10.0,
    interval     = 1.0,
    events = {
        onApply = function(self, target, ctx)
            -- TODO: apply self.nativeStatus to `target` through the native status system.
        end,
        onExpire = function(self, target, ctx)
            -- TODO: remove self.nativeStatus from `target`.
        end,
    },
}

M.Burn = Effect{
    id           = "Burn",
    nativeStatus = "Burn",
    duration     = 5.0,
    interval     = 1.0,
    events = {
        onApply = function(self, target, ctx)
            -- TODO: apply self.nativeStatus to `target` through the native status system.
        end,
        onExpire = function(self, target, ctx)
            -- TODO: remove self.nativeStatus from `target`.
        end,
    },
}

M.Freeze = Effect{
    id           = "Freeze",
    nativeStatus = "Freeze",
    duration     = 3.0,
    events = {
        onApply = function(self, target, ctx)
            -- TODO: apply self.nativeStatus to `target` through the native status system.
        end,
        onExpire = function(self, target, ctx)
            -- TODO: remove self.nativeStatus from `target`.
        end,
    },
}

-- Pre-seed curated so get(id) returns the curated handle (hooks intact).
for _, h in ipairs({ M.Poison, M.Burn, M.Freeze }) do
    set[h.id] = true
    cache[h.id] = h
end

return M
