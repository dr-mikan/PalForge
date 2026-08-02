-- PalForge utils.keyboard.base.registory: the keybind registry. A rewrite of the
-- old inline `RegisterKeyBind(Key.F4, ...)` block into an extensible framework.
--
-- Behaviour files under palforge.core.keyboard.functions.* self-register their key
-- by calling register(); load() pulls them all in. Each key is installed with the
-- engine exactly ONCE — the handler runs on the game thread inside a pcall so a bad
-- callback can never crash the input path.
--
--   local reg = require("palforge.core.keyboard.base.registory")
--   reg.claim("INS", fn, { desc = "..." })   -- CHECKED: refuses a key that is not free
--   reg.register("F1", fn)                   -- RAW: binds whatever you name, replacing in place
--   reg.load()                               -- in the kernel (dev only)
--
-- ⚠️ THE TWO FRONT DOORS ARE NOT THE SAME DOOR, and picking the wrong one is how a key dies
-- quietly.
--
--   claim()    asks first, and ACTS on the answer. Esc is refused outright; a key the GAME has an
--              action on is refused unless the caller passed override = true; a key another part
--              of PalForge already holds is refused always. Everything a UI element asks for goes
--              through here.
--   register() asks first and BINDS ANYWAY. It is how palforge.test deliberately takes F1 back
--              for the test runner and how a functions/ file installs a behaviour — a documented,
--              intentional replace — so refusing would break the one caller that means it and
--              leave a dev-only bind with no way in.
--
-- ⚠️ register() DID NOT ASK AT ALL UNTIL 2026-08-02, and that is the gap this note records. All
-- nine PalForge keys go through it; only claim() consulted the keymap, and claim()'s one caller
-- is the UI seam (native/ui/keys.lua). So the F7 class of failure — the bind returns normally,
-- the log says the probe is armed, and the key never once arrives — was still fully possible for
-- a probe key, and M.report() made it VISIBLE after the fact rather than at the moment it
-- happened. register() now consults M.isFree() before the engine bind and says what it found on
-- the same line as "bound F4", so a key Palworld already owns is named in the log at bind time by
-- the game's own action name. It still binds. The one exception is M.FORBIDDEN below, which is
-- not a measurement and is not overridable by anything.
--
-- ⚠️ AND THE WARNING IS HONEST ABOUT WHAT THE KEYMAP CANNOT SEE. A `free` verdict here means "no
-- action in Palworld's key config uses this key". F7 may well read `free` and still never arrive:
-- the Steam overlay, the OS, UE's own console keys and hardcoded viewport bindings are all
-- outside that config. keymap.lua's header sets out the whole of that limit; the point of asking
-- is that "free and it still never arrived" is now a REPORTABLE finding about something else,
-- instead of the unreadable `arrived = 0` it used to be.
--
-- WHERE THE ANSWER COMES FROM. core/keyboard/base/keymap.lua reads Palworld's own key config out
-- of the running game — UPalOptionSubsystem.KeyConfigSettings (Pal.hpp:26132), the struct the
-- options screen edits — plus the project's DefaultInput.ini defaults. Until this existed there
-- was no way to ask whether a key was free and three input routes died silently proving it
-- (core/autorun.lua:19-22). Its header is the one to read for what the answer does and does not
-- cover; the short version is that "free" means "no action in the game's key config uses it",
-- which is not the same as "the press will arrive".
--
-- Fail-soft: if RegisterKeyBind or the Key table is unavailable, register() logs a
-- warning and returns false rather than throwing.
local log    = require("palforge.utils.log").scope("keyboard")
local keymap = require("palforge.core.keyboard.base.keymap")

local M = {}

M.keymap = keymap

-- keyName ("F1"/"F4"/...) -> { key, fn, opts, game }. The RegisterKeyBind closure calls
-- rec.fn by reference, so re-registering a bound key just swaps the function without
-- installing a second engine binding.
M.bound = {}

---Key names NOTHING in PalForge may bind, with the reason each is refused.
---
---Escape is the whole list and the reason is the mandate: the player must always be able to
---close the game's own menu. A live run found a mounted panel stopping Esc from doing that, and
---it is worse than every failure this input design exists to prevent put together. THIS IS NOT
---OVERRIDABLE — claim(..., { override = true }) unlocks a key the game uses and does not unlock
---this one. Declared here rather than in native/ui/keys.lua because it binds every caller of the
---keyboard, not only the UI seam; keys.lua re-exports it.
M.FORBIDDEN = {
    ESCAPE = "Esc is not a KEY on this build and binding it as one is the wrong tool, not just "
        .. "an unsafe one. Palworld's UI is CommonUI: Esc is the named UI action \"UIEscape\" / "
        .. "\"UICancel\" (rows of DT_UIInputAction), mapped through "
        .. "FPalKeyConfigSettings.MouseAndKeyboardUIInputMappings (Pal.hpp:3978) and resolved by "
        .. "UPalCommonUIActionRouter (Pal.hpp:16698) against the ACTIVATABLE WIDGET tree — the "
        .. "game's own screens take it with UPalUserWidget::RegisterActionBinding (Pal.hpp:31898) "
        .. "or by claiming bIsBackHandler (CommonUI.hpp:149). A UE4SS keybind can only OBSERVE "
        .. "the key: it cannot consume it, it has no place in the router's ordering, and it fires "
        .. "whether or not a panel of yours is up. Want Esc to close YOUR panel? Declare "
        .. "UI{ backHandler = true } on a Frame-rooted element, which is that mechanism. Want any "
        .. "close key at all? Use another key, or Button{ onClick = function(self) self:unmount() "
        .. "end }. native/ui/keys.lua's header has the whole path with citations",
}

-- Built-in behaviour files shipped with PalForge (always loaded by load()). New
-- files dropped into functions/ are also auto-discovered (see load()); this list is
-- the reliable floor that works even when a directory scan isn't available.
-- NOTE: F1 is NOT here. palforge.test binds it to the in-game API suite when the kernel
-- requires that module, which is later than load() — so a file in functions/ that also
-- claimed F1 would be silently overridden. Bind test runs through palforge.test.bind
-- instead; everything else belongs here.
M.BUILTIN = { "f4_unlock" }

--=============================================================================
-- IS THIS KEY FREE — the composed answer, with the three cases kept apart
--=============================================================================

---What holds `keyName`, as one record. Never nil.
---
---  state    "forbidden" PalForge refuses this name outright (Esc, and only Esc)
---           "palforge"  something in THIS mod already has it — `owner` says what
---           "game"      Palworld has an action on it — `actions` lists them
---           "free"      the game's key config was read and nothing uses it
---           "unknown"   the config could not be read, or the name has no Unreal FKey
---  why      a sentence, always, naming what the answer rests on
---
---The order matters and is deliberate: our own binding is checked BEFORE the game's, because a
---collision inside PalForge is the one this tree can actually do something about. F1 runs the
---test suite; a panel that quietly replaced it would swallow the whole suite and say nothing
---(register() replaces a callback in place, below).
---@param keyName string
---@return table status
function M.status(keyName)
    local name = tostring(keyName or ""):upper()

    local forbidden = M.FORBIDDEN[name]
    if forbidden then
        return { key = name, state = "forbidden", why = forbidden, actions = {} }
    end

    local rec = M.bound[name]
    if rec then
        local desc = (rec.opts and rec.opts.desc) or "no description"
        return { key = name, state = "palforge", owner = desc, actions = {},
            why = string.format("%s is already bound inside PalForge (%s). Registering it again "
                .. "would REPLACE that callback in place with nothing said, which is how a panel "
                .. "could quietly eat the key that runs the test suite", name, desc) }
    end

    -- UE4SS knows about every Lua mod in the process, not only this one. A yes here means some
    -- OTHER mod holds the key and ours would be a second callback on it; it is reported rather
    -- than refused, because a second keybind is legal and the collision is worth naming.
    local other
    if type(IsKeyBindRegistered) == "function" and type(Key) == "table" then
        local code = Key[name]
        if code ~= nil then pcall(function() other = IsKeyBindRegistered(code) == true end) end
    end

    local st = keymap.status(name)
    st.otherMod = other or nil
    if other then
        st.why = st.why .. ". UE4SS also reports a keybind ALREADY REGISTERED on this key by "
            .. "something in this process that is not PalForge's registry — another Lua mod, most "
            .. "likely; both callbacks will run"
    end
    return st
end

---Is this key safe for a NEW binding — i.e. would claim() take it?
---
---The composed front door: `true` only for the one state claim() takes without an override, and
---the status beside it so a caller that wants to bind anyway can say WHY it is binding anyway.
---M.register() is that caller (it warns and binds); claim() does not use this because it has to
---separate the four refusal cases and needs the status itself.
---
---⚠️ `false` IS NOT "SOMETHING HOLDS IT". It is "claim() would not take it", and that covers
---`unknown` — no reading, or no Unreal FKey name — as well as `game`, `palforge` and `forbidden`.
---A caller that treats a false as "the game has it" will misreport the title screen, where the
---config source cannot be read at all. Branch on `status.state`, never on the boolean alone.
---@param keyName string
---@return boolean free, table status
function M.isFree(keyName)
    local st = M.status(keyName)
    return st.state == "free", st
end

--=============================================================================
-- binding
--=============================================================================

-- The engine half of a bind, shared by register() and claim(). Returns true when the key really
-- went in. Everything that can refuse is named rather than swallowed.
local function install(rec)
    local ok, err = pcall(function()
        assert(type(RegisterKeyBind) == "function", "RegisterKeyBind unavailable")
        assert(type(Key) == "table" or type(Key) == "userdata", "Key table unavailable")
        local code = Key[rec.key]
        assert(code ~= nil, "Key['" .. rec.key .. "'] not found")
        RegisterKeyBind(code, function()
            ExecuteInGameThread(function()
                local okc, e = pcall(rec.fn)
                if not okc then log.err(rec.key .. " handler failed: " .. tostring(e)) end
            end)
        end)
    end)
    rec.bindError = (not ok) and tostring(err) or nil
    return ok
end

-- Register `fn` on `keyName`. Installs the engine keybind once per key; a later
-- register() on the same key replaces the callback in place. `opts` is stored for
-- callers (reserved; e.g. { desc = "..." }). Returns true if bound/updated.
--
-- ⚠️ THE REPLACE IS REAL AND IT USED TO BE SILENT. A second register() on a bound key swaps the
-- behaviour and keeps the one engine binding — which is exactly what palforge.test.bind wants
-- and exactly what a UI panel must never do by accident. It is now logged as a warning naming
-- BOTH descriptions when they differ, so a replacement anyone did not mean is visible in the log
-- instead of being discovered by pressing F1 and getting somebody's panel.
--
-- ⚠️ AND IT NOW ASKS THE KEYMAP FIRST. See the header: this door bound nine keys without ever
-- consulting the one thing in the tree that can answer "has Palworld already got this key". It
-- still binds whatever it is given (bar M.FORBIDDEN) — that is what the door is for — but the
-- answer is in the log at the moment of the bind, naming the game's own action, rather than only
-- in M.report() if somebody thinks to run it.
function M.register(keyName, fn, opts)
    if type(keyName) ~= "string" or #keyName == 0 or type(fn) ~= "function" then
        log.warn("register: expected (keyName:string, fn:function)")
        return false
    end
    keyName = keyName:upper()

    -- ⚠️ THE ONE THING register() REFUSES, AND IT IS NOT THE KEYMAP'S ANSWER. M.FORBIDDEN is
    -- PalForge's own mandate rather than a measurement — the player must always be able to close
    -- the game's menu — and its own doc says "key names NOTHING in PalForge may bind" and "THIS
    -- IS NOT OVERRIDABLE". Until 2026-08-02 only claim() honoured that, so the raw door could
    -- bind the single name the list exists to protect, and the list's sentence was false about
    -- half the module. The refusal names what it refused and why rather than returning a bare
    -- false; nothing in this tree registers Esc, so this changes no existing call site.
    local forbidden = M.FORBIDDEN[keyName]
    if forbidden then
        log.err(string.format("register REFUSED %s and bound nothing — this name is on "
            .. "M.FORBIDDEN, which no front door in this module opens: %s", keyName, forbidden))
        return false
    end

    -- The rebind path does NOT re-ask the keymap, deliberately: the engine binding is not being
    -- made again, the game's answer for this key was already logged when it WAS made, and
    -- palforge.test.bind re-registers on every F9 reload — asking there would repeat the same
    -- sentence about the same key every reload and bury the one line that is new.
    local existing = M.bound[keyName]
    if existing then
        local was = (existing.opts and existing.opts.desc) or "no description"
        local now = (opts and opts.desc) or was
        existing.fn = fn          -- swap behaviour; keep the single engine binding
        existing.opts = opts or existing.opts
        if was ~= now then
            log.warn(string.format("%s was bound to %q and is now %q — the old callback is gone. "
                .. "That is intended for palforge.test.bind and is a bug anywhere else; use "
                .. "reg.claim() to be refused instead of replacing", keyName, was, now))
        else
            log.info("rebind " .. keyName)
        end
        return true
    end

    -- ASK, THEN BIND. pcall'd end to end because this module is fail-soft by design (see the
    -- header): a keymap that raises must never be the reason a dev key does not bind. `free` is
    -- the documented "would claim() take it?" answer and it is what the bound line reports;
    -- `st` carries which of the five cases held, which is what the warnings need.
    local askedOk, free, st = pcall(M.isFree, keyName)
    if not askedOk then free, st = nil, nil end

    if st and st.state == "game" then
        -- The warning the F7 session did not get. Naming the ACTION is the whole of its value:
        -- "F7 is Palworld's volume key" is actionable and "F7 did not work" is not.
        local parts = {}
        for _, a in ipairs(st.actions or {}) do
            parts[#parts + 1] = string.format("%s [%s%s]", a.action, a.via,
                a.mods and ("+" .. a.mods) or "")
        end
        log.warn(string.format("%s IS ALREADY PALWORLD'S: %s. register() binds it anyway — that "
            .. "is what this door is for — but both sit on one key now. A UE4SS keybind OBSERVES "
            .. "and does not consume, so the game's own action still runs; and if the game claims "
            .. "the key BELOW UE4SS the press never reaches Lua at all, which is what happened to "
            .. "F7 (core/autorun.lua:19-22). reg.claim() is the door that refuses instead.",
            keyName, table.concat(parts, ", ")))
    end
    if st and st.otherMod then
        log.warn(string.format("%s already has a keybind registered by something else in this "
            .. "process that is not PalForge's registry — another Lua mod, most likely. Both "
            .. "callbacks will run; UE4SS has no unregister and no way to name the other holder.",
            keyName))
    end

    local rec = { key = keyName, fn = fn, opts = opts or {}, game = st }
    M.bound[keyName] = rec
    local ok = install(rec)
    if ok then
        -- The verdict rides on the "bound" line, so the log answers "and what does the game have
        -- on it" in the same place it says the bind went in. `free` is deliberately not left
        -- bare: it is the strongest thing the key config can say and it is still not a promise.
        local verdict = "keymap: not asked — the check itself raised, which is a fault in "
            .. "PalForge and not an answer about the key"
        if free then
            verdict = "keymap: free — no action in Palworld's key config uses it, which is NOT "
                .. "the same as \"the press will arrive\""
        elseif st and st.state == "game" then
            verdict = "keymap: the game has it, see the warning above"
        elseif st and st.state == "unknown" then
            verdict = "keymap: unknown — " .. (st.fkey
                and "the game's key config has not been read yet (the config source needs a "
                    .. "loaded world), so nothing is claimed either way; run pf_keys inside a save"
                or "PalForge knows no Unreal FKey name for this UE4SS name, so it cannot be "
                    .. "looked up at all")
        end
        log.info(string.format("bound %s [%s]", keyName, verdict))
    else
        log.warn("could not bind " .. keyName .. " (keybinds unavailable this session): "
            .. tostring(rec.bindError))
    end
    return ok
end

---Take `keyName` ONLY IF IT IS FREE. The checked front door.
---
---Returns (false, status) rather than raising for every refusal, and the status carries the
---sentence that says which of the five cases held. `opts`:
---
---  desc      what this binding is, shown in every report
---  override  ⚠️ TAKE A KEY THE GAME ALREADY USES. Deliberate, explicit at the call site, and
---            it buys exactly one thing: PalForge stops refusing. It does NOT stop the game's
---            own action running (a UE4SS keybind observes; it does not consume), it does NOT
---            change the player's key config (PalForge never writes it — see keymap.lua), and
---            it does NOT promise the press ever arrives. Esc is refused with it anyway.
---
---@param keyName string
---@param fn function
---@param opts table?
---@return boolean bound, table status
function M.claim(keyName, fn, opts)
    opts = opts or {}
    local name = tostring(keyName or ""):upper()
    if #name == 0 or type(fn) ~= "function" then
        return false, { key = name, state = "refused",
            why = "claim: expected (keyName:string, fn:function)" }
    end

    local st = M.status(name)
    st.override = opts.override and true or nil

    if st.state == "forbidden" then
        st.refused = true
        return false, st
    end
    if st.state == "palforge" then
        st.refused = true
        st.why = st.why .. ". claim() never steals; if the replacement is intended, say so with "
            .. "reg.register()"
        return false, st
    end
    if st.state == "game" and not opts.override then
        st.refused = true
        -- ⚠️ THE SUGGESTED SPELLING HAS TO BE THE RIGHT ONE FOR THE KIND OF INPUT THIS IS. A
        -- mouse button named in `overrideKeys` is armed as a KEY — same name, wrong router — and
        -- the press then arrives where no element declared it, which is silence from a
        -- declaration that reads correct (native/ui/keys.lua:M.arm says the same thing at the
        -- other end). So the message names `overrideButtons` for the three mouse names.
        local MOUSE = { LEFT_MOUSE_BUTTON = "left", RIGHT_MOUSE_BUTTON = "right",
                        MIDDLE_MOUSE_BUTTON = "middle" }
        local how = MOUSE[name]
            and ("UI{ overrideButtons = { \"" .. MOUSE[name] .. "\" } }")
            or ("UI{ overrideKeys = { \"" .. name .. "\" } }")
        st.why = st.why .. ". PalForge refused it. If you MEAN to share it with the game, say so "
            .. "at the call site — " .. how .. ", or reg.claim(key, fn, { override = true })"
        return false, st
    end

    local rec = { key = name, fn = fn, opts = opts, game = st }
    M.bound[name] = rec
    local ok = install(rec)
    if not ok then
        M.bound[name] = nil
        st.refused = true
        st.why = string.format("RegisterKeyBind refused %s, or UE4SS's Key table has no entry "
            .. "spelled that (the names are UE4SS's: F1..F24, A..Z, INS, DEL, HOME, END, "
            .. "PAGE_UP, NUM_ZERO.., LEFT_MOUSE_BUTTON, ...) — %s", name, tostring(rec.bindError))
        return false, st
    end
    if st.state == "game" then
        log.warn(string.format("%s was taken from the game DELIBERATELY (override): %s",
            name, st.why))
    end
    return true, st
end

-- Whether a key currently has a behaviour bound.
function M.isBound(keyName) return M.bound[tostring(keyName or ""):upper()] ~= nil end

-- The list of currently bound key names.
function M.keys()
    local out = {}
    for k in pairs(M.bound) do out[#out + 1] = k end
    table.sort(out)
    return out
end

---What PalForge itself holds, as keyName -> description. Fed to keymap.lookup so the third
---case — already taken by us — shows up in the same table as the other two.
---@return table<string,string>
function M.owned()
    local out = {}
    for k, rec in pairs(M.bound) do
        out[k] = (rec.opts and rec.opts.desc) or "no description"
    end
    return out
end

---Every PalForge binding with what the GAME has on the same key, as printable lines.
---
---This is the line that was missing when `watch` sat unreachable on Palworld's volume key for a
---whole session: the bind succeeded, the log said so, and nothing anywhere crossed it against
---what the game already had. Now it does, live, at the moment you ask.
---@return string[]
function M.report()
    local names = M.keys()
    if #names == 0 then return { "keyboard: nothing is bound" } end
    local out, shared = {}, 0
    for _, name in ipairs(names) do
        local rec = M.bound[name]
        local st = keymap.status(name)
        if st.state == "game" then shared = shared + 1 end
        local what = "nothing"
        if st.state == "game" then
            local parts = {}
            for _, a in ipairs(st.actions) do parts[#parts + 1] = a.action .. " [" .. a.via .. "]" end
            what = table.concat(parts, ", ")
        elseif st.state == "unknown" then
            what = st.fkey and "the game's key config has not been read" or "no Unreal FKey name is known"
        end
        out[#out + 1] = string.format("keyboard: %-20s %-8s %-40s game: %s",
            name, st.state, (rec.opts and rec.opts.desc) or "no description", what)
    end
    if shared > 0 then
        out[#out + 1] = string.format("keyboard: %d PalForge binding(s) sit on a key Palworld "
            .. "also uses. Both fire — a UE4SS keybind observes rather than consumes — and if "
            .. "the game claims the key BELOW UE4SS the press never arrives at all, which is "
            .. "what happened to F7 (core/autorun.lua:19-22).", shared)
    end
    return out
end

-- Discover behaviour-file module names in functions/ (best-effort, cross-platform).
-- Returns { "f1", "f4_unlock", ... } (without ".lua"); {} if listing is unavailable.
local function scanFunctionNames()
    local src = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
    if not src then return {} end
    local sep = package.config:sub(1, 1)          -- "\\" on Windows, "/" on Unix
    -- src ends with ".../keyboard/base/"; the sibling functions/ dir holds the files.
    local dir = src:gsub("[\\/]base[\\/]$", sep .. "functions" .. sep)
    local cmd = (sep == "\\")
        and ('dir "' .. dir .. '" /b 2>nul')
        or  ('ls -1 "' .. dir .. '" 2>/dev/null')
    local names = {}
    pcall(function()
        local p = io.popen(cmd)
        if not p then return end
        for line in p:lines() do
            local name = line:gsub("[\r\n]", ""):match("^(.-)%.lua$")
            if name and name ~= "init" then names[#names + 1] = name end
        end
        p:close()
    end)
    return names
end

-- Load every keybind behaviour file so it self-registers. Requires the built-in set
-- plus any additional files discovered in functions/. Idempotent (require caches, so
-- a file loaded twice self-registers once). Returns the count loaded.
--
-- It also arms the keymap's change watch, on world.ready rather than here — a key config that
-- is read once at load is wrong the moment the player opens the options screen.
--
-- ⚠️ AND THIS IS NOT "the one place every session passes through", WHICH IS WHAT THE LINE HERE
-- USED TO SAY. load() is DEV-ONLY: its one caller is core/registry.lua inside `if env.dev`, so
-- for the whole of a release build keymap.install() was never called, the change-watch never
-- armed and no initial reading was ever taken. keymap.refresh() now installs itself on first
-- demand (keymap.lua's M.install has the full note), which covers the release path — a pack
-- declaring UI{ keys = ... } reaches native/ui/keys.arm -> M.claim -> keymap.status. The call
-- below is kept because in a dev session it arms the watch at LOAD instead of at the first
-- question, and keymap.install() is idempotent, so calling it from both places costs nothing.
function M.load()
    local seen, order = {}, {}
    local function add(n) if n and not seen[n] then seen[n] = true; order[#order + 1] = n end end
    for _, n in ipairs(M.BUILTIN) do add(n) end
    for _, n in ipairs(scanFunctionNames()) do add(n) end

    local loaded = 0
    for _, n in ipairs(order) do
        local ok, e = pcall(require, "palforge.core.keyboard.functions." .. n)
        if ok then loaded = loaded + 1
        else log.err("keybind function '" .. n .. "' load error: " .. tostring(e)) end
    end
    keymap.install()
    log.info(string.format("keybinds loaded (%d function file(s): %s)", loaded, table.concat(M.keys(), ",")))
    return loaded
end

return M
