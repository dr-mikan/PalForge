-- PalForge utils.file.json_file: the default persistence backend — simple JSON
-- key/value files under the PalForge Mods dir. Extends the base backend. Moved
-- VERBATIM from the old core.util.store (depends only on utils.json + the shared
-- logger; the file/dir helpers it used to pull from deprecated/core stay inlined).
--
-- Each key is its own file: <Mods>/PalForge/state/<key>.json
local json    = require("palforge.utils.json")
local Backend = require("palforge.utils.file.base.backend")
local log     = require("palforge.utils.log").scope("file")

local JsonFile = Backend:extend("JsonFile")

-- ---- inlined file/dir helpers (were deprecated/core.readFile / .ensureDir /
-- ---- .writeFile) ----
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local SEP = package.config:sub(1, 1)   -- "\\" on Windows, "/" elsewhere

-- Ensure a directory exists (mkdir -p equivalent). Returns true on success. Windows is
-- the real target (UE4SS), but the POSIX branch keeps headless runs working too.
local function ensureDir(dir)
    local ok = pcall(function()
        if SEP == "\\" then
            os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '" 2>nul')
        else
            os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
        end
    end)
    return ok and exists(dir)
end

-- Atomic-ish write: write to <path>.tmp then rename over <path> so a crash mid-
-- write can't leave a truncated file. Returns ok, err.
local function writeFile(path, text)
    local tmp = path .. ".tmp"
    local f, oerr = io.open(tmp, "wb")
    if not f then return false, "open failed: " .. tostring(oerr) end
    local ok, werr = pcall(function()
        f:write(text)
        f:close()
    end)
    if not ok then pcall(function() f:close() end); return false, "write failed: " .. tostring(werr) end
    -- Windows os.rename fails if the destination exists; remove it first.
    os.remove(path)
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        -- fall back to a direct write if rename is unavailable
        local f2 = io.open(path, "wb")
        if not f2 then return false, "rename failed: " .. tostring(rerr) end
        f2:write(text); f2:close()
        os.remove(tmp)
    end
    return true
end

-- Base dir resolved from THIS module's path. The on-disk target must stay
-- <Mods>/PalForge/state/. This file lives at
--   .../PalForge/Scripts/palforge/utils/file/json_file.lua
-- so reaching PalForge/ means going FOUR dirs up from here:
--   file -> utils -> palforge -> Scripts -> PalForge, then /state/.
-- (Keep this count in step with the module's depth — it was one too deep while this file
--  lived under core/util/, which silently put state/ outside the mod dir.)
local function stateDir()
    local here = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
    local up   = table.concat({ "..", "..", "..", "..", "state" }, SEP)
    return here .. up .. SEP
end

local cache = {}

local function pathFor(key)
    return stateDir() .. key .. ".json"
end

-- Read a key -> value (decoded), or nil.
function JsonFile:get(key)
    if cache[key] ~= nil then return cache[key] end
    local text = readFile(pathFor(key))
    if not text then return nil end
    local v = json.decode(text)
    cache[key] = v
    return v
end

-- Set a key in memory (call flush() or use setAndFlush to persist).
function JsonFile:set(key, value)
    cache[key] = value
end

function JsonFile:flush(key)
    local dir = stateDir()
    ensureDir(dir)
    local keys = key and { key } or {}
    if not key then for k in pairs(cache) do table.insert(keys, k) end end
    local okAll = true
    for _, k in ipairs(keys) do
        local text, eerr = json.encode(cache[k])
        if not text then
            log.warn("encode failed for '" .. k .. "': " .. tostring(eerr)); okAll = false
        else
            local ok, werr = writeFile(pathFor(k), text)
            if not ok then log.warn("write failed for '" .. k .. "': " .. tostring(werr)); okAll = false end
        end
    end
    return okAll
end

function JsonFile:setAndFlush(key, value)
    self:set(key, value)
    return self:flush(key)
end

return JsonFile
