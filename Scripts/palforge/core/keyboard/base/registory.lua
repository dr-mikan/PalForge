-- PalForge utils.keyboard.base.registory: the keybind registry. A rewrite of the
-- old inline `RegisterKeyBind(Key.F4, ...)` block into an extensible framework.
--
-- Behaviour files under palforge.core.keyboard.functions.* self-register their key
-- by calling register(); load() pulls them all in. Each key is installed with the
-- engine exactly ONCE — the handler runs on the game thread inside a pcall so a bad
-- callback can never crash the input path.
--
--   local reg = require("palforge.core.keyboard.base.registory")
--   reg.register("F1", function() ... end)   -- in a functions/*.lua file
--   reg.load()                               -- in the kernel (dev only)
--
-- Fail-soft: if RegisterKeyBind or the Key table is unavailable, register() logs a
-- warning and returns false rather than throwing.
local log = require("palforge.utils.log").scope("keyboard")

local M = {}

-- keyName ("F1"/"F4"/...) -> { key, fn, opts }. The RegisterKeyBind closure calls
-- rec.fn by reference, so re-registering a bound key just swaps the function without
-- installing a second engine binding.
M.bound = {}

-- Built-in behaviour files shipped with PalForge (always loaded by load()). New
-- files dropped into functions/ are also auto-discovered (see load()); this list is
-- the reliable floor that works even when a directory scan isn't available.
-- NOTE: some of these dev keybinds (like the dump probe) are TEMPORARY diagnostics and
-- should be removed once their purpose is served. f1 currently holds the audio play-
-- mechanism self-test (moved off F8, which Palworld does not deliver) — delete f1.lua +
-- restore its example when audio is confirmed.
M.BUILTIN = { "f1", "f4_unlock" }

-- Register `fn` on `keyName`. Installs the engine keybind once per key; a later
-- register() on the same key replaces the callback in place. `opts` is stored for
-- callers (reserved; e.g. { desc = "..." }). Returns true if bound/updated.
function M.register(keyName, fn, opts)
    if type(keyName) ~= "string" or #keyName == 0 or type(fn) ~= "function" then
        log.warn("register: expected (keyName:string, fn:function)")
        return false
    end
    local existing = M.bound[keyName]
    if existing then
        existing.fn = fn          -- swap behaviour; keep the single engine binding
        existing.opts = opts or existing.opts
        log.info("rebind " .. keyName)
        return true
    end
    local rec = { key = keyName, fn = fn, opts = opts or {} }
    M.bound[keyName] = rec
    local ok = pcall(function()
        assert(type(RegisterKeyBind) == "function", "RegisterKeyBind unavailable")
        assert(type(Key) == "table" or type(Key) == "userdata", "Key table unavailable")
        local code = Key[keyName]
        assert(code ~= nil, "Key['" .. keyName .. "'] not found")
        RegisterKeyBind(code, function()
            ExecuteInGameThread(function()
                local okc, e = pcall(rec.fn)
                if not okc then log.err(keyName .. " handler failed: " .. tostring(e)) end
            end)
        end)
    end)
    if ok then
        log.info("bound " .. keyName)
    else
        log.warn("could not bind " .. keyName .. " (keybinds unavailable this session)")
    end
    return ok
end

-- Whether a key currently has a behaviour bound.
function M.isBound(keyName) return M.bound[keyName] ~= nil end

-- The list of currently bound key names.
function M.keys()
    local out = {}
    for k in pairs(M.bound) do out[#out + 1] = k end
    table.sort(out)
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
    log.info(string.format("keybinds loaded (%d function file(s): %s)", loaded, table.concat(M.keys(), ",")))
    return loaded
end

return M
