-- PalForge native.ui.keys — where a UI key press COMES FROM. The engine seam for
-- UI.Spec's `keys` / `buttons`, and the only file under native/ui that talks to UE4SS's
-- keyboard.
--
-- THE SPLIT IS THE SAME ONE AS EVERYWHERE ELSE HERE. api/ui.lua decides WHO gets a press
-- (the z-ordered routing rule — it is pure Lua and makes no engine call, which is what
-- keeps the whole thing provable headlessly); this file decides WHETHER A PRESS CAN BE
-- HEARD AT ALL, which is entirely a question about UE4SS and about what Palworld has
-- already taken.
--
-- ⚠️ THE THING THIS FILE EXISTS TO SAY OUT LOUD: A BIND THAT SUCCEEDS PROVES NOTHING.
-- UE4SS binds happily to a key the game has already claimed. F7 was Palworld's own volume
-- control: the RegisterKeyBind call returned normally, the log said the probe was armed,
-- and the key never once arrived — which from the log is indistinguishable from a probe
-- that ran and found nothing (core/autorun.lua:19-22, test/init.lua:105-107). There is no
-- API anywhere that answers "is this key free".
--
-- So this module counts ARRIVALS, and M.report() states in words that a count of zero
-- cannot tell "the game took this key" from "nobody pressed it". That sentence is the
-- honest answer to the question, and it is printed rather than left to be inferred,
-- because a silent failure is the bug.
--
-- TWO MORE REFUSALS, both deliberate:
--
--   ESCAPE is never bound. A mod that puts itself in the path of Esc is one keystroke away
--   from being the reason a player cannot close the game's own menu, which is the exact
--   failure the whole input design exists to prevent (see the INPUT block in _widget.lua).
--   A UI element that asks for it is refused by NAME, here, with that reason.
--
--   A key somebody else has already bound is not taken. core/keyboard's registry REPLACES
--   the callback on a second register() of the same key (registory.lua:41-47), so binding
--   F1 from a panel would silently swallow the test runner. "Do not assume a key is free"
--   applies to this tree's own keys as much as to the game's.
--
-- NOTHING IS EVER UNBOUND. UE4SS has no unregister for a keybind — the same fact
-- core/event.lua:779-782 records for hooks — so a key is armed once and stays armed for the
-- session. An element that unmounts stops receiving because the ROUTER stops choosing it,
-- not because the bind went away. That is why the routing lives in api/ui and not here.

local reg = require("palforge.core.keyboard.base.registory")

local M = {}

---The three mouse buttons, as UE4SS's Key table spells them. A pack writes "left"; this is
---the only place that knows the engine's name for it.
---
---A press on one of these is a GLOBAL press notification, not a hit test: UE4SS hands us the
---button going down anywhere on the window, and it cannot tell us what was under the cursor.
---Clicking a widget is a different mechanism entirely (Button{ onClick = ... }, routed through
---the CommonButtonBase hook in _widget.lua). Both are useful and they are not the same event.
M.MOUSE = { left = "LEFT_MOUSE_BUTTON", right = "RIGHT_MOUSE_BUTTON", middle = "MIDDLE_MOUSE_BUTTON" }

---Key names this module refuses outright, with the reason it gives. Escape is the whole list
---and the reason is the mandate: the player must always be able to close the game's own menu.
M.FORBIDDEN = {
    ESCAPE = "Esc is the player's way out of the game's own menu, and PalForge does not put "
        .. "itself in its path — a panel that wants a close key should use any other key, or a "
        .. "Button{ onClick = function(self) self:unmount() end }",
}

-- keyName -> record. One per key, for the life of the session, because a bind is for the life
-- of the session. `arrivals` counts every press that reached us; `routed` / `blocked` are what
-- api/ui's router did with them, reported back through the dispatch return.
M.keys = {}

local function record(name)
    local r = M.keys[name]
    if not r then
        r = { key = name, state = "pending", arrivals = 0, routed = 0, blocked = 0 }
        M.keys[name] = r
    end
    return r
end

-- One press, arriving. `r.dispatch` is api/ui's router; it answers with (id, why) — the id of
-- the element that took it, or nil plus the sentence that says who blocked it. Both halves are
-- counted, because "the key arrives and nothing happens" and "the key never arrives" are two
-- different faults and the log has to tell them apart.
local function fire(r)
    r.arrivals = r.arrivals + 1
    local d = r.dispatch
    if type(d) ~= "function" then
        r.last = "arrived with no router attached"
        return
    end
    local ok, id, why = pcall(d, r.button or r.key)
    if not ok then
        r.last = "the router raised: " .. tostring(id)
        return
    end
    if id then r.routed = r.routed + 1 else r.blocked = r.blocked + 1 end
    r.last = tostring(why or (id and ("-> " .. tostring(id))) or "?")
end

-- Arm ONE name. Idempotent: a second element wanting the same key re-points the dispatcher and
-- installs no second bind. Every outcome is recorded on the record rather than raised, because
-- an element whose key could not be bound still mounts — its panel is not the key.
local function install(name, button, dispatch)
    if type(name) ~= "string" or #name == 0 then return nil end
    local r = record(name)
    r.button = button
    r.dispatch = dispatch

    if r.state == "armed" or r.state == "refused" then return r end

    local why = M.FORBIDDEN[name]
    if why then
        r.state, r.why = "refused", why
        return r
    end
    -- Somebody else's key. registory.register would REPLACE their callback in place
    -- (registory.lua:41-47) and nothing would say so, which is how a panel could quietly eat
    -- the key that runs the test suite.
    if reg.isBound(name) then
        r.state, r.why = "refused", string.format(
            "%s is already bound elsewhere in PalForge (core/keyboard's registry), and taking "
            .. "it would replace that binding in place with nothing said", name)
        return r
    end

    local ok = reg.register(name, function() fire(r) end,
        { desc = "PalForge UI: routed to the topmost mounted element that wants " .. name })
    if ok then
        r.state, r.why = "armed", nil
    else
        r.state, r.why = "refused",
            "RegisterKeyBind refused it, or UE4SS's Key table has no entry spelled " .. name
            .. " (the names are UE4SS's: F1..F24, A..Z, INS, DEL, HOME, END, PAGE_UP, "
            .. "NUM_ZERO.., LEFT_MOUSE_BUTTON, ...)"
    end
    return r
end

---Arm every key and mouse button an element asked for, and point them at the router.
---
---    keys.arm{ keys = { "INS" }, buttons = { "middle" },
---              onKey = UI.routeKey, onMouse = UI.routeMouse }
---
---Returns one record per name — { key, state, why? } — so the caller can log a refusal once
---rather than once per mount attempt. Never raises and never blocks a mount.
---@return table[] records
function M.arm(spec)
    spec = spec or {}
    local out = {}
    for _, k in ipairs(spec.keys or {}) do
        local r = install(tostring(k):upper(), nil, spec.onKey)
        if r then out[#out + 1] = r end
    end
    for _, b in ipairs(spec.buttons or {}) do
        local button = tostring(b):lower()
        local r = install(M.MOUSE[button], button, spec.onMouse)
        if r then out[#out + 1] = r end
    end
    return out
end

---Which key names are armed, refused or never asked for, as printable lines — plus the
---sentence that says what a zero cannot tell you.
---@return string[]
function M.report()
    local names = {}
    for name in pairs(M.keys) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        return { "keys: no mounted element has asked for a key or a mouse button" }
    end

    local out, silent = {}, 0
    for _, name in ipairs(names) do
        local r = M.keys[name]
        if r.state == "armed" and r.arrivals == 0 then silent = silent + 1 end
        out[#out + 1] = string.format("keys: %-20s %-8s arrived=%d routed=%d blocked=%d%s%s",
            name, r.state, r.arrivals, r.routed, r.blocked,
            r.why and ("  [" .. r.why .. "]") or "",
            r.last and ("  last: " .. r.last) or "")
    end
    if silent > 0 then
        out[#out + 1] = string.format(
            "keys: %d armed key(s) have never arrived — AND THAT COUNT CANNOT TELL YOU WHY. "
            .. "UE4SS binds successfully to a key Palworld has already claimed and the key then "
            .. "simply never fires (F7 was the game's volume control: core/autorun.lua:19-22). "
            .. "`arrived=0` means either the game took the key or nobody pressed it, and there "
            .. "is no call anywhere that separates those two. Press the key and read this line "
            .. "again: arrived>0 is the only evidence that exists.", silent)
    end
    return out
end

return M
