-- PalForge native.ui.keys — where a UI key press COMES FROM. The engine seam for
-- UI.Spec's `keys` / `overrideKeys` / `buttons`, and the only file under native/ui that talks to
-- UE4SS's keyboard.
--
-- THE SPLIT IS THE SAME ONE AS EVERYWHERE ELSE HERE. api/ui.lua decides WHO gets a press
-- (the z-ordered routing rule — it is pure Lua and makes no engine call, which is what
-- keeps the whole thing provable headlessly); this file decides WHETHER A PRESS CAN BE
-- HEARD AT ALL, which is entirely a question about UE4SS and about what Palworld has
-- already taken.
--
-- ⚠️ WHAT CHANGED, AND WHAT DID NOT. This file used to say, in as many words, that "there is no
-- API anywhere that answers 'is this key free'", and that `arrived = 0` therefore could not tell
-- "the game took this key" from "nobody pressed it". The first half is no longer true:
-- core/keyboard/base/keymap.lua reads Palworld's OWN key config out of the running game — the
-- struct the options screen edits, UPalOptionSubsystem.KeyConfigSettings (Pal.hpp:26132) — plus
-- the project's DefaultInput.ini defaults, and answers per key. So a bind is now checked before
-- it is made, and M.report() can attribute a silence instead of shrugging at it.
--
-- THE SECOND HALF IS STILL TRUE AND IS THE THING NOT TO OVERSELL. A bind that succeeds still
-- proves nothing about ARRIVAL. F7 was Palworld's volume control: RegisterKeyBind returned
-- normally, the log said the probe was armed, and the key never once came
-- (core/autorun.lua:19-22). A key can be claimed by something that is not in the key config at
-- all — the Steam overlay, the OS, UE's own console keys — and none of that is readable from
-- here. What the report can now do is CROSS two facts: whether the game has an action on the
-- key, and whether ANY PalForge key has arrived this session. Those two split the old single
-- unreadable zero into cases that each point somewhere different, and that is the whole of the
-- improvement.
--
-- THREE REFUSALS, all deliberate:
--
--   ESCAPE is never bound, by anything, ever. A mod in Esc's path is one keystroke away from
--   being the reason a player cannot close the game's own menu, which is the exact failure the
--   whole input design exists to prevent (see the INPUT block in _widget.lua). The rule and its
--   reason live in core/keyboard's registry now, because they bind every caller of the keyboard
--   and not only this seam; M.FORBIDDEN re-exports them. `overrideKeys` does NOT unlock it.
--
--   A key somebody else in PalForge has already bound is not taken. The registry REPLACES the
--   callback on a second register() of the same key, so binding F1 from a panel would silently
--   swallow the test runner. reg.claim() refuses instead, and "do not assume a key is free"
--   applies to this tree's own keys as much as to the game's.
--
--   A key THE GAME has an action on is refused too — unless the element said `overrideKeys`.
--
-- ⚠️ WHAT AN OVERRIDE BUYS, EXACTLY ONE THING: PalForge stops refusing. It does not stop the
-- game's own action from firing (a UE4SS keybind observes and does not consume — api/ui.lua says
-- the same about routing), it does not rewrite the player's key config (PalForge never writes
-- it; keymap.lua's header says why), and it cannot make a press arrive that the game is taking
-- below UE4SS. Sharing a key means BOTH things happen, and the honest reading of an override is
-- "I accept that, and I accept I may get nothing".
--
-- NOTHING IS EVER UNBOUND. UE4SS has no unregister for a keybind — the same fact
-- core/event.lua:779-782 records for hooks — so a key is armed once and stays armed for the
-- session. An element that unmounts stops receiving because the ROUTER stops choosing it,
-- not because the bind went away. That is why the routing lives in api/ui and not here.

local reg    = require("palforge.core.keyboard.base.registory")
local keymap = require("palforge.core.keyboard.base.keymap")

local M = {}

M.keymap = keymap

---The three mouse buttons, as UE4SS's Key table spells them. A pack writes "left"; this is
---the only place that knows the engine's name for it.
---
---A press on one of these is a GLOBAL press notification, not a hit test: UE4SS hands us the
---button going down anywhere on the window, and it cannot tell us what was under the cursor.
---Clicking a widget is a different mechanism entirely (Button{ onClick = ... }, routed through
---the CommonButtonBase hook in _widget.lua). Both are useful and they are not the same event.
M.MOUSE = { left = "LEFT_MOUSE_BUTTON", right = "RIGHT_MOUSE_BUTTON", middle = "MIDDLE_MOUSE_BUTTON" }

---Key names PalForge refuses outright, with the reason it gives. Escape is the whole list and the
---reason is the mandate. Declared in core/keyboard's registry — it binds every caller of the
---keyboard, not only this seam — and re-exported here because this is where a UI element's
---refusal is read from.
M.FORBIDDEN = reg.FORBIDDEN

-- keyName -> record. One per key, for the life of the session, because a bind is for the life
-- of the session. `arrivals` counts every press that reached us; `routed` / `blocked` are what
-- api/ui's router did with them, reported back through the dispatch return. `game` is what the
-- live key config said AT ARM TIME, kept so a report can show both then and now.
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
--
-- The whole decision is reg.claim's. This file no longer asks its own questions about who holds
-- a key: one answer, one owner, and the sentence a refusal carries is the registry's.
local function install(name, button, dispatch, override)
    if type(name) ~= "string" or #name == 0 then return nil end
    local r = record(name)
    r.button = button
    r.dispatch = dispatch

    if r.state == "armed" or r.state == "refused" then return r end

    local ok, st = reg.claim(name, function() fire(r) end, {
        desc = "PalForge UI: routed to the topmost mounted element that wants " .. name,
        override = override,
    })
    r.game, r.override = st, override or nil
    if ok then
        r.state, r.why = "armed", nil
        -- A key shared with the game on purpose is worth a word on the record even in success:
        -- it is the one case where "armed" does not mean "ours alone".
        if st and st.state == "game" then r.why = "shared with the game: " .. tostring(st.why) end
    else
        r.state, r.why = "refused", (st and st.why)
            or ("RegisterKeyBind refused " .. name .. ", or UE4SS's Key table has no entry "
                .. "spelled it")
    end
    return r
end

---Arm every key and mouse button an element asked for, and point them at the router.
---
---    keys.arm{ keys = { "INS" }, overrideKeys = { "F7" }, buttons = { "middle" },
---              onKey = UI.routeKey, onMouse = UI.routeMouse }
---
---`overrideKeys` names the keys whose refusal-because-the-game-uses-it is to be waived. They are
---armed alongside `keys` and routed identically; the only difference is that PalForge does not
---stand in the way. A name in both lists is armed once and the override wins — saying it once
---anywhere is saying it — though api/ui refuses that declaration one level up, where the two
---opposite instructions are visible to whoever wrote them.
---
---Returns one record per name — { key, state, why?, game? } — so the caller can log a refusal
---once rather than once per mount attempt. Never raises and never blocks a mount.
---@return table[] records
function M.arm(spec)
    spec = spec or {}
    local override = {}
    for _, k in ipairs(spec.overrideKeys or {}) do override[tostring(k):upper()] = true end

    -- Ordered, and de-duplicated by name: `keys` first, then any `overrideKeys` that were not
    -- also listed there. pairs() order is not stable and a report whose row order moves between
    -- runs is a report nobody can diff, so the two declared LISTS are what is walked.
    local out, seen = {}, {}
    local function one(name, button, dispatch)
        if not name or seen[name] then return end
        seen[name] = true
        local r = install(name, button, dispatch, override[name])
        if r then out[#out + 1] = r end
    end

    for _, k in ipairs(spec.keys or {}) do one(tostring(k):upper(), nil, spec.onKey) end
    for _, k in ipairs(spec.overrideKeys or {}) do one(tostring(k):upper(), nil, spec.onKey) end
    for _, b in ipairs(spec.buttons or {}) do
        local button = tostring(b):lower()
        one(M.MOUSE[button], button, spec.onMouse)
    end
    return out
end

---What the game has on `name`, straight through to core/keyboard. Published so a probe or an
---autorun action can ask without reaching past this seam.
---@param name string
---@return table status
function M.status(name) return reg.status(name) end

---Which key names are armed, refused or never asked for, as printable lines — and, for every
---armed key that has never been pressed, WHICH OF THE POSSIBLE REASONS APPLIES.
---
---⚠️ THIS IS THE PART THAT USED TO BE A SHRUG. The old report ended with a sentence saying that
---`arrived = 0` could not tell "the game took this key" from "nobody pressed it", because no call
---anywhere separated them. One does now, and a silence is crossed against two readable facts:
---
---   * what the GAME's live key config has on that key (core/keyboard/base/keymap.lua), and
---   * whether ANY PalForge UI key has arrived at all this session.
---
---The second is what turns a per-key mystery into a whole-route one: if nothing has ever
---arrived, the fault is the input path and not the key, and no amount of trying other keys will
---find it. The status is re-read HERE rather than reused from arm time, because the player may
---have rebound something since — and because at the title screen the config is unreadable and by
---the time you are reading a report you are usually not at the title screen any more.
---@return string[]
function M.report()
    local names = {}
    for name in pairs(M.keys) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        return { "keys: no mounted element has asked for a key or a mouse button" }
    end

    local out = {}
    local armed, arrived = 0, 0
    local silent = { game = {}, free = {}, unknown = {} }

    for _, name in ipairs(names) do
        local r = M.keys[name]
        local st = keymap.status(name)
        local now = st.state
        if now == "game" then
            local parts = {}
            for _, a in ipairs(st.actions) do parts[#parts + 1] = a.action .. " [" .. a.via .. "]" end
            now = "game: " .. table.concat(parts, ", ")
        elseif now == "free" then
            now = "game: nothing"
        else
            now = "game: unknown"
        end
        if r.state == "armed" then
            armed = armed + 1
            if r.arrivals > 0 then
                arrived = arrived + 1
            else
                local bucket = silent[st.state] or silent.unknown
                bucket[#bucket + 1] = name
            end
        end
        out[#out + 1] = string.format("keys: %-20s %-8s arrived=%d routed=%d blocked=%d  %s%s%s%s",
            name, r.state, r.arrivals, r.routed, r.blocked, now,
            r.override and "  [OVERRIDE: taken from the game on purpose]" or "",
            r.why and ("  [" .. r.why .. "]") or "",
            r.last and ("  last: " .. r.last) or "")
    end

    local quiet = #silent.game + #silent.free + #silent.unknown
    if quiet == 0 then return out end

    -- THE WHOLE-ROUTE VERDICT FIRST. It outranks every per-key reading: if nothing at all has
    -- ever arrived, no per-key answer means anything and swapping keys is wasted effort.
    if armed > 0 and arrived == 0 then
        out[#out + 1] = string.format("keys: NOT ONE of the %d armed key(s) has ever arrived. "
            .. "IF ONE HAS BEEN PRESSED, that is a fault in the INPUT ROUTE rather than in any "
            .. "one key — UE4SS's keybind callback only fires while the game window has focus, "
            .. "and a wedged engine-tick hook takes the whole queue down with it "
            .. "(core/poll.lua:5-16) — and trying a different key will not help until one "
            .. "arrives. If none has been pressed yet, this line says nothing; it gets stronger "
            .. "with every key armed and every press made.", armed)
    end
    if #silent.game > 0 then
        out[#out + 1] = string.format("keys: %s never arrived AND THE GAME HAS AN ACTION ON "
            .. "%s (see the lines above). That is the likeliest reason: Palworld claims the key "
            .. "and the press never reaches UE4SS — which is exactly what F7 did "
            .. "(core/autorun.lua:19-22). Pick a key the report calls `game: nothing`.",
            table.concat(silent.game, ", "), #silent.game == 1 and "it" or "them")
    end
    if #silent.free > 0 then
        out[#out + 1] = string.format("keys: %s never arrived AND THE GAME'S KEY CONFIG HAS "
            .. "NOTHING ON %s. So the game's bindings are NOT the reason. What is left: nobody "
            .. "pressed it, the window did not have focus, or something outside the key config "
            .. "has the key — the Steam overlay, the OS, or UE's own console keys. Press it once "
            .. "and read this line again; arrived>0 is still the only positive evidence there is.",
            table.concat(silent.free, ", "), #silent.free == 1 and "it" or "them")
    end
    if #silent.unknown > 0 then
        out[#out + 1] = string.format("keys: %s never arrived AND THE GAME'S KEY CONFIG COULD NOT "
            .. "BE READ for %s, so this count still cannot tell \"the game took it\" from \"nobody "
            .. "pressed it\" — the old, unattributable answer. The config needs a LOADED WORLD "
            .. "(UPalOptionSubsystem is a world subsystem); run pf_keys from inside a save and "
            .. "these move into one of the two cases above.",
            table.concat(silent.unknown, ", "), #silent.unknown == 1 and "it" or "them")
    end
    return out
end

return M
