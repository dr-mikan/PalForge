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
--   claim()    asks first. Esc is refused outright; a key the GAME has an action on is refused
--              unless the caller passed override = true; a key another part of PalForge already
--              holds is refused always. Everything a UI element asks for goes through here.
--   register() does not ask. It is how palforge.test deliberately takes F1 back for the test
--              runner and how a functions/ file installs a behaviour — a documented, intentional
--              replace. It now RECORDS what the game has on the key so the log can say so, but
--              it never refuses, because refusing would break the one caller that means it.
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
    ESCAPE = "Esc is the player's way out of the game's own menu, and PalForge does not put "
        .. "itself in its path — a panel that wants a close key should use any other key, or a "
        .. "Button{ onClick = function(self) self:unmount() end }",
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
function M.register(keyName, fn, opts)
    if type(keyName) ~= "string" or #keyName == 0 or type(fn) ~= "function" then
        log.warn("register: expected (keyName:string, fn:function)")
        return false
    end
    keyName = keyName:upper()

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

    local rec = { key = keyName, fn = fn, opts = opts or {} }
    M.bound[keyName] = rec
    local ok = install(rec)
    if ok then
        log.info("bound " .. keyName)
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
        st.why = st.why .. ". PalForge refused it. If you MEAN to share the key with the game, "
            .. "say so at the call site — UI{ overrideKeys = { \"" .. name .. "\" } }, or "
            .. "reg.claim(key, fn, { override = true })"
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
-- is read once at load is wrong the moment the player opens the options screen, and this is the
-- one place every session passes through.
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
