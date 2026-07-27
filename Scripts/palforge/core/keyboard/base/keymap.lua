-- palforge/core/keyboard/base/keymap.lua — WHAT PALWORLD HAS ALREADY TAKEN, read out of the
-- running game instead of guessed at.
--
-- WHY THIS FILE EXISTS, and it is the most expensive lesson in this tree. Three input routes
-- failed in one session and every one of them failed SILENTLY:
--
--   F7   Palworld's own volume control. RegisterKeyBind returned normally, the log said the
--        probe was armed, and the key never once arrived (core/autorun.lua:19-22).
--   F8   the same again, on a second key.
--   the console  registers perfectly well into a window UE4SS ships switched off.
--
-- The first two were indistinguishable, from the log, from "the probe ran and found nothing",
-- because `arrived = 0` had exactly one reading and no way to narrow it. native/ui/keys.lua said
-- so in as many words: "There is no API anywhere that answers 'is this key free'."
--
-- THERE IS ONE, AND IT IS THE PLAYER'S OWN CONFIG. Palworld does not keep its key bindings in a
-- constant; it keeps them in a struct on a world subsystem, the same struct the options screen
-- edits, and every field of it is reflected and therefore readable from Lua:
--
--   UPalOptionSubsystem.KeyConfigSettings                 dumps/cxx/Pal.hpp:26132
--     -> FPalKeyConfigSettings                            dumps/cxx/Pal.hpp:3972
--          TMap<FName, FPalKeyConfigKeys> MouseAndKeyboardActionMappings   :3974
--          TArray<FPalAxisKeyConfigKeys>  MouseAndKeyboardAxisMappings     :3975
--          TMap<FName, FKey>              MouseAndKeyboardUIInputMappings  :3979
--     -> FPalKeyConfigKeys { FKey MainKey; FKey SecondaryKey; }            :3965
--     -> FKey { FName KeyName; }                          dumps/cxx/InputCore.hpp:6
--
-- and, underneath it, the project's own defaults from DefaultInput.ini:
--
--   UInputSettings.ActionMappings / .AxisMappings         dumps/cxx/Engine.hpp:13683-13684
--     -> FInputActionKeyMapping { FName ActionName; bShift/bCtrl/bAlt/bCmd; FKey Key; }  :3251
--
-- NONE OF THAT IS A FUNCTION CALL. Every one of those is a PROPERTY READ off a live object, so
-- core/signature.lua's whole hazard — an argument whose type faults inside UE4SS's marshalling
-- where pcall cannot see it, which closed the game once already — does not arise here. Nothing
-- in this file calls a UFunction. That is deliberate and it is why this route is safe to take.
--
-- ⚠️ AND WHAT IT STILL CANNOT PROMISE. This answers "does the GAME have an action on this key".
-- It does NOT answer "will UE4SS see this key", and those are not the same question:
--
--   * a key can be claimed by something that is not in the key config at all — the Steam
--     overlay, the OS, UE's own console keys (UInputSettings.ConsoleKeys, Engine.hpp:13690),
--     a hardcoded viewport binding. F7 may well turn out to be one of these; the probe below
--     is what settles it, and "free here and still never arrives" is a REAL and reportable
--     outcome rather than a contradiction.
--   * a key the game DOES have an action on may still reach UE4SS perfectly well, because a
--     UE4SS keybind observes and does not consume. Both fire.
--
-- So this module narrows `arrived = 0` from one unreadable fact to a cross of two readable
-- ones, and native/ui/keys.lua's report says which of the resulting cases holds. That is the
-- whole of the improvement and it is stated in those terms rather than as "keys work now".
--
-- THE TWO NAMESPACES, which is the part nobody warns you about. UE4SS binds by MICROSOFT
-- VIRTUAL-KEY NAME ("INS", "SPACE", "NUM_ZERO", "OEM_COMMA" — ue4ss/Docs/lua-api/table-
-- definitions/key.md lists all 156). Unreal names the same keys quite differently ("Insert",
-- "SpaceBar", "NumPadZero", "Comma"). A lookup that forgets this finds nothing and reports
-- every key free, which is worse than reporting nothing at all. M.FKEY is that translation,
-- written out in full, and every entry it cannot justify is `false` rather than a guess.
--
--   local keymap = require("palforge.core.keyboard.base.keymap")
--   local st = keymap.status("INS")     -- { state = "game", actions = {...}, why = "..." }
--   for _, line in ipairs(keymap.lines()) do print(line) end
local log = require("palforge.utils.log").scope("keymap")

local M = {}

--=============================================================================
-- THE NAME MAP — UE4SS's Microsoft virtual-key names -> Unreal's FKey names
--
-- The left-hand side is exactly the `Key` table UE4SS publishes (ue4ss/Docs/lua-api/table-
-- definitions/key.md); the right-hand side is what an FKey's KeyName reads as. The evidence
-- for the right-hand side is the game's OWN data: DT_PalRichTextControlKeyIcon has one row per
-- key it can draw an icon for, and its 117 row names are FKey names
-- (dumps/catalog/datatables/DT_PalRichTextControlKeyIcon.json:1) — "SpaceBar", "NumPadZero",
-- "BackSpace", "Insert", "Left", "Hyphen", "Tilde" and so on.
--
-- `false` means "PalForge knows no FKey name for this one". That is NOT the same as "free":
-- a name this table cannot translate is answered "unknown", never "free", because inventing a
-- clean answer out of a missing one is the exact failure this module was written to stop.
--=============================================================================

---UE4SS key name -> FKey name, or false when no FKey name is known for it.
M.FKEY = {
    -- mouse. UE4SS exposes five buttons; UE names the two side buttons "Thumb".
    LEFT_MOUSE_BUTTON = "LeftMouseButton",
    RIGHT_MOUSE_BUTTON = "RightMouseButton",
    MIDDLE_MOUSE_BUTTON = "MiddleMouseButton",
    XBUTTON_ONE = "ThumbMouseButton",
    XBUTTON_TWO = "ThumbMouseButton2",

    -- the editing / navigation block, where the two spellings disagree most
    BACKSPACE = "BackSpace",       -- UE capitalises the S
    TAB = "Tab",
    RETURN = "Enter",              -- not "Return"
    PAUSE = "Pause",
    CAPS_LOCK = "CapsLock",
    ESCAPE = "Escape",
    SPACE = "SpaceBar",            -- not "Space"
    PAGE_UP = "PageUp",
    PAGE_DOWN = "PageDown",
    END = "End",
    HOME = "Home",
    LEFT_ARROW = "Left",           -- UE drops the "Arrow"
    UP_ARROW = "Up",
    RIGHT_ARROW = "Right",
    DOWN_ARROW = "Down",
    INS = "Insert",                -- UE4SS abbreviates, UE does not
    DEL = "Delete",
    NUM_LOCK = "NumLock",
    SCROLL_LOCK = "ScrollLock",

    -- the numeric keypad's operators, which UE names after the operation
    MULTIPLY = "Multiply",
    ADD = "Add",
    SUBTRACT = "Subtract",
    DECIMAL = "Decimal",
    DIVIDE = "Divide",

    -- ⚠️ OEM_*: THE PUNCTUATION KEYS, AND THEY ARE KEYBOARD-LAYOUT DEPENDENT. A Windows OEM
    -- virtual-key code names a POSITION on the keyboard, not a character, so VK_OEM_1 is the
    -- semicolon on a US layout and something else on a German or French one. The mappings below
    -- are the US layout's, they are marked as assumptions in M.LAYOUT_ASSUMED, and a status
    -- built on one says so in its own sentence rather than claiming to have measured it.
    OEM_ONE = "Semicolon",
    OEM_PLUS = "Equals",
    OEM_COMMA = "Comma",
    OEM_MINUS = "Hyphen",
    OEM_PERIOD = "Period",
    OEM_TWO = "Slash",
    OEM_THREE = "Tilde",
    OEM_FOUR = "LeftBracket",
    OEM_FIVE = "Backslash",
    OEM_SIX = "RightBracket",
    OEM_SEVEN = "Apostrophe",

    -- NO FKEY IS KNOWN FOR THESE, and each `false` is a statement rather than an omission.
    -- Unreal's EKeys registry (the thing an FKey name comes from) simply has no entry for the
    -- IME keys, the browser/media/launch keys, the Windows keys, or the legacy VK codes below.
    -- A key here is answered "unknown", so nothing is claimed either way about it.
    CANCEL = false, CLEAR = false, SELECT = false, PRINT = false, EXECUTE = false,
    PRINT_SCREEN = false, HELP = false, SLEEP = false, APPS = false,
    LEFT_WIN = false, RIGHT_WIN = false,   -- UE's LeftCommand/RightCommand are the MAC keys
    SEPARATOR = false, OEM_EIGHT = false, OEM_102 = false, OEM_CLEAR = false,
    IME_KANA = false, IME_HANGUEL = false, IME_HANGUL = false, IME_ON = false, IME_JUNJA = false,
    IME_FINAL = false, IME_HANJA = false, IME_KANJI = false, IME_OFF = false, IME_CONVERT = false,
    IME_NONCONVERT = false, IME_ACCEPT = false, IME_MODECHANGE = false, IME_PROCESS = false,
    BROWSER_BACK = false, BROWSER_FORWARD = false, BROWSER_REFRESH = false, BROWSER_STOP = false,
    BROWSER_SEARCH = false, BROWSER_FAVORITES = false, BROWSER_HOME = false,
    VOLUME_MUTE = false, VOLUME_DOWN = false, VOLUME_UP = false,
    MEDIA_NEXT_TRACK = false, MEDIA_PREV_TRACK = false, MEDIA_STOP = false, MEDIA_PLAY_PAUSE = false,
    LAUNCH_MAIL = false, LAUNCH_MEDIA_SELECT = false, LAUNCH_APP1 = false, LAUNCH_APP2 = false,
    PACKET = false, ATTN = false, CRSEL = false, EXSEL = false, EREOF = false, PLAY = false,
    ZOOM = false, PA1 = false,
}

---The entries of M.FKEY that are an assumption about the player's KEYBOARD LAYOUT rather than a
---fact about the two naming schemes. A status resting on one of these says so.
M.LAYOUT_ASSUMED = {
    OEM_ONE = true, OEM_PLUS = true, OEM_COMMA = true, OEM_MINUS = true, OEM_PERIOD = true,
    OEM_TWO = true, OEM_THREE = true, OEM_FOUR = true, OEM_FIVE = true, OEM_SIX = true,
    OEM_SEVEN = true,
}

-- The families where the two schemes agree letter for letter, filled in here rather than typed
-- out eighty times. A..Z and F1..F12 are literally identical in both; the digit rows and the
-- keypad are not, and each gets its own spelling.
local WORD = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
do
    for i = 0, 25 do
        local c = string.char(65 + i)
        M.FKEY[c] = c
    end
    for i = 1, 12 do M.FKEY["F" .. i] = "F" .. i end
    -- ⚠️ F13..F24 ARE IN UE4SS'S TABLE AND NOT IN UNREAL'S. Unreal's EKeys registry defines F1
    -- through F12 and stops; there is no FKey named "F13", which means no Palworld action can
    -- be bound to one. That is a strong claim to make out of an absence, so it is NOT turned
    -- into "free" — these are `false`, i.e. "unknown", and a caller that arms one is told the
    -- answer rests on nothing. If a live keymap ever shows an F13 the index will still find it
    -- by name, because the index is keyed on what the GAME said, never on this table.
    for i = 13, 24 do M.FKEY["F" .. i] = false end
    for i = 1, 10 do
        M.FKEY[WORD[i]:upper()] = WORD[i]                 -- ZERO -> Zero
        M.FKEY["NUM_" .. WORD[i]:upper()] = "NumPad" .. WORD[i]  -- NUM_ZERO -> NumPadZero
    end
end

---Translate a UE4SS key name into the FKey name Unreal would spell it with.
---@param name string       # a UE4SS Key table name, e.g. "INS"
---@return string? fkey, string confidence   # confidence: "known" | "layout" | "none"
function M.translate(name)
    if type(name) ~= "string" then return nil, "none" end
    local up = name:upper()
    local f = M.FKEY[up]
    if f == nil then
        -- Not in the table at all. This is not a UE4SS key name we have ever seen; say so
        -- rather than falling back to the identity, which is how a typo becomes a false "free".
        return nil, "none"
    end
    if f == false then return nil, "none" end
    return f, M.LAYOUT_ASSUMED[up] and "layout" or "known"
end

--=============================================================================
-- READING THE LIVE GAME — property walks only, never a call
--=============================================================================

local function alive(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o.IsValid and o:IsValid() end)
    return ok and v == true
end

-- An FName, an FString or a plain string, as a Lua string. nil for the empty and "None" cases,
-- which UE uses for "nothing is set here" and which must never become an index entry.
--
-- ⚠️ NO tostring() FALLBACK, and that is the load-bearing line. tostring() on an object with no
-- ToString gives "table: 0x5a44e8aff080" — a perfectly truthy string that sails into the index
-- as a key name and matches nothing ever again. A mock run produced exactly that page of output.
-- An unreadable name is nil here, so the mapping is dropped and the source's own count says a
-- source read nothing, which is a fault anyone can see.
local function str(v)
    if v == nil then return nil end
    if type(v) == "string" then return (v ~= "" and v ~= "None") and v or nil end
    if type(v) == "number" then return tostring(v) end
    -- Not typed on "userdata": UE4SS hands FNames back as userdata, and a caller that wraps one
    -- (a hook param, a test double) is the same value one indirection out. Ask for the METHOD.
    local s
    if type(v) == "table" or type(v) == "userdata" then
        pcall(function() s = v:ToString() end)
    end
    if type(s) ~= "string" or s == "" or s == "None" then return nil end
    return s
end

-- A struct field, read defensively. Every read in this file goes through here because a
-- property that does not exist on a given build must be a nil, not a raise.
local function field(o, name)
    if o == nil then return nil end
    local v; pcall(function() v = o[name] end)
    return v
end

-- The FKey's name. FKey has exactly one reflected member, FName KeyName (InputCore.hpp:6-11),
-- so this is the whole of what an FKey can tell us.
local function keyNameOf(fkey)
    return str(field(fkey, "KeyName"))
end

-- Walk a UE4SS TArray. Three shapes exist depending on build and element type (:ForEach, a
-- #-indexable userdata, :Get(i-1)) and all three are tried in that order — the same ladder
-- core/event.lua:735-746 documents as the one array reader in this tree that has been read back
-- from a live save.
local function eachArray(arr, fn)
    if arr == nil then return 0 end
    local n = 0
    local function push(v) if v ~= nil then n = n + 1; pcall(fn, v) end end
    if pcall(function() arr:ForEach(function(_, v) push(v) end) end) and n > 0 then return n end
    local len; pcall(function() len = #arr end)
    if type(len) ~= "number" or len <= 0 then return n end
    for i = 1, len do local v; pcall(function() v = arr[i] end); push(v) end
    if n > 0 then return n end
    for i = 1, len do local v; pcall(function() v = arr:Get(i - 1) end); push(v) end
    return n
end

-- Walk a UE4SS TMap. ForEach is the documented iterator and the only one
-- (ue4ss/Docs/lua-api/classes/tmap.md), and it hands both halves in as params that may or may
-- not need :get() unwrapping depending on whether the element is local or remote — so both
-- shapes are accepted rather than one being assumed.
local function unwrap(p)
    if type(p) ~= "userdata" and type(p) ~= "table" then return p end
    local v; if pcall(function() v = p:get() end) and v ~= nil then return v end
    return p
end

local function eachMap(m, fn)
    if m == nil then return 0 end
    local n = 0
    pcall(function()
        m:ForEach(function(k, v)
            n = n + 1
            pcall(fn, unwrap(k), unwrap(v))
        end)
    end)
    return n
end

--=============================================================================
-- THE INDEX — one entry per FKey name the game has an action on
--=============================================================================

-- lowercased FKey name -> { key = <as the game spelled it>, actions = { { action, via, mods } } }
-- Lowercased because nothing guarantees the two sources spell a name with the same case, and a
-- lookup that misses on case reports a taken key as free.
local state = {
    read     = false,   -- has any source ever produced a single mapping
    at       = nil,     -- os.clock() when it last did
    index    = {},
    actions  = {},      -- action name -> { <FKey name>, ... }
    dirty    = true,    -- something says the config may have moved; re-read on next demand
}
M.state = state

---How long a reading stays good without any signal that it moved, in SECONDS.
---
---Bound on elapsed time and never on a tick count, for core/poll.lua's reason: the heartbeat's
---bodies drain in bursts and a tick budget can expire inside one second. Nothing here polls at
---all — the re-read happens on DEMAND, when somebody asks a question — so this number is a
---staleness bound, not an interval, and no timer exists to get wrong.
M.MAX_AGE = 30

---Where a reading can come from. Each keeps its own record, exactly as the click router keeps
---one per route (native/ui/_widget.lua:171-179): "the config source is read and the project
---source is absent" is an actionable sentence and "the keymap is empty" is not.
M.SOURCES = {
    { id = "config",
      what = "UPalOptionSubsystem.KeyConfigSettings — the key config THE PLAYER EDITS "
          .. "(Pal.hpp:26132, struct at :3972)" },
    { id = "project",
      what = "UInputSettings.ActionMappings/AxisMappings — the project's own DefaultInput.ini "
          .. "(Engine.hpp:13683-13684)" },
}
for _, s in ipairs(M.SOURCES) do s.state, s.entries = "unread", 0 end

local function source(id)
    for _, s in ipairs(M.SOURCES) do if s.id == id then return s end end
end

-- Put one (key, action) pair into the index. `via` says which source and which slot it came
-- from, because "bound as a secondary key in the player's config" and "bound in the shipped
-- defaults" are different facts and a report that merges them is a report you cannot act on.
local function add(index, actions, fkeyName, action, via, mods)
    if not fkeyName or not action then return false end
    local k = fkeyName:lower()
    local e = index[k]
    if not e then e = { key = fkeyName, actions = {} }; index[k] = e end
    for _, a in ipairs(e.actions) do
        if a.action == action and a.via == via then return false end
    end
    e.actions[#e.actions + 1] = { action = action, via = via, mods = mods }
    local list = actions[action]
    if not list then list = {}; actions[action] = list end
    list[#list + 1] = fkeyName
    return true
end

-- SOURCE 1: the player's own config. This is the one that matters — it is what the options
-- screen writes and what the game actually obeys, so a player who moved Inventory onto F7 is
-- reflected here and nowhere else.
local function readConfig(index, actions)
    local rec = source("config")
    local subsys; pcall(function() subsys = FindFirstOf("PalOptionSubsystem") end)
    if not alive(subsys) then
        rec.state, rec.why, rec.entries = "absent",
            "no live UPalOptionSubsystem — it is a UPalWorldSubsystem, so it exists only "
            .. "inside a loaded world (there is none at the title screen)", 0
        return 0
    end

    local kc = field(subsys, "KeyConfigSettings")
    if kc == nil then
        rec.state, rec.why, rec.entries = "refused",
            "UPalOptionSubsystem is live but its KeyConfigSettings property did not read back "
            .. "(Pal.hpp:26132 declares it; this build did not hand it over)", 0
        return 0
    end

    local n = 0
    -- The action bindings: FName -> FPalKeyConfigKeys { MainKey, SecondaryKey }.
    eachMap(field(kc, "MouseAndKeyboardActionMappings"), function(k, v)
        local action = str(k)
        if not action then return end
        if add(index, actions, keyNameOf(field(v, "MainKey")), action, "config/main") then n = n + 1 end
        if add(index, actions, keyNameOf(field(v, "SecondaryKey")), action, "config/second") then n = n + 1 end
    end)
    -- The UI bindings: FName -> FKey directly, no Main/Secondary pair (Pal.hpp:3979).
    eachMap(field(kc, "MouseAndKeyboardUIInputMappings"), function(k, v)
        local action = str(k)
        if add(index, actions, keyNameOf(v), action, "config/ui") then n = n + 1 end
    end)
    -- The axis bindings: an array, and each element carries its own AxisName because
    -- FPalAxisKeyConfigKeys extends FPalKeyConfigKeys with one (Pal.hpp:623-628). Movement
    -- lives here — W/A/S/D are axis mappings, not actions — so a keymap without this half
    -- would report the four most-used keys in the game as free.
    eachArray(field(kc, "MouseAndKeyboardAxisMappings"), function(e)
        local axis = str(field(e, "AxisName"))
        if not axis then return end
        if add(index, actions, keyNameOf(field(e, "MainKey")), axis, "config/axis") then n = n + 1 end
        if add(index, actions, keyNameOf(field(e, "SecondaryKey")), axis, "config/axis2") then n = n + 1 end
    end)

    rec.entries = n
    if n == 0 then
        rec.state, rec.why = "refused",
            "the subsystem and its KeyConfigSettings both read, and every map inside came back "
            .. "empty — either this build does not iterate a TMap property from Lua, or the "
            .. "player's config genuinely has no entries yet"
    else
        rec.state, rec.why = "read", nil
    end
    return n
end

-- SOURCE 2: the project's defaults. Weaker evidence than the player's config — it is what the
-- game SHIPPED with, not necessarily what it is obeying — but it covers the actions the config
-- map has no entry for, and it is readable at the title screen where the subsystem is not.
local function readProject(index, actions)
    local rec = source("project")
    local is
    -- The CDO is where a UInputSettings' ini-loaded values live, and FindFirstOf explicitly
    -- returns the first NON-default instance (ue4ss/Docs/lua-api.md), so it can never find it.
    -- StaticFindObject by path is the route, and the same one core/icons.lua:349 and
    -- core/spawn.lua:138 already use for a Default__ object on this build.
    pcall(function() is = StaticFindObject("/Script/Engine.Default__InputSettings") end)
    if not alive(is) then pcall(function() is = FindFirstOf("InputSettings") end) end
    if not alive(is) then
        rec.state, rec.why, rec.entries = "absent",
            "no UInputSettings: /Script/Engine.Default__InputSettings did not resolve and there "
            .. "is no non-default instance either", 0
        return 0
    end

    local n = 0
    local function mods(m)
        local out = {}
        for prop, label in pairs({ bShift = "Shift", bCtrl = "Ctrl", bAlt = "Alt", bCmd = "Cmd" }) do
            local v = field(m, prop)
            if v == true or v == 1 then out[#out + 1] = label end
        end
        table.sort(out)
        return #out > 0 and table.concat(out, "+") or nil
    end
    eachArray(field(is, "ActionMappings"), function(m)
        local action = str(field(m, "ActionName"))
        if add(index, actions, keyNameOf(field(m, "Key")), action, "project/action", mods(m)) then
            n = n + 1
        end
    end)
    eachArray(field(is, "AxisMappings"), function(m)
        local axis = str(field(m, "AxisName"))
        if add(index, actions, keyNameOf(field(m, "Key")), axis, "project/axis") then n = n + 1 end
    end)
    -- UE's own console keys. Not an action mapping and easy to miss: these are the keys that
    -- open the engine console, they are claimed below the game entirely, and a mod that binds
    -- one gets exactly the F7 experience (Engine.hpp:13690).
    eachArray(field(is, "ConsoleKeys"), function(k)
        if add(index, actions, keyNameOf(k), "<UE console>", "project/console") then n = n + 1 end
    end)

    rec.entries = n
    rec.state, rec.why = (n > 0) and "read" or "refused", (n == 0)
        and "UInputSettings resolved and every mapping array came back empty" or nil
    return n
end

---Re-read the game's key bindings NOW. Returns how many mappings landed, and a note.
---
---Builds into a fresh index and swaps it in only if something was read, so a refresh attempted
---at the title screen (where the subsystem does not exist) cannot blank a good reading taken
---inside a world.
---@return integer mappings, string note
function M.refresh()
    local index, actions = {}, {}
    local n = readConfig(index, actions) + readProject(index, actions)
    state.dirty = false
    if n == 0 then
        local parts = {}
        for _, s in ipairs(M.SOURCES) do
            parts[#parts + 1] = string.format("%s=%s", s.id, s.state)
        end
        return 0, "no source produced a mapping (" .. table.concat(parts, " ") .. ")"
    end
    state.index, state.actions = index, actions
    state.read, state.at = true, os.clock()
    local keys = 0
    for _ in pairs(index) do keys = keys + 1 end
    return n, string.format("%d mapping(s) over %d key(s)", n, keys)
end

---The current reading, refreshing first if it is stale or something said it moved.
---
---There is no poller behind this and there never will be: a re-read costs a handful of property
---walks and only matters when somebody is about to ask a question, so it happens when they ask.
---@return table index
function M.snapshot()
    local stale = (not state.read)
        or state.dirty
        or (state.at == nil)
        or ((os.clock() - state.at) > M.MAX_AGE)
    if stale then pcall(M.refresh) end
    return state.index
end

--=============================================================================
-- NOTICING THAT THE PLAYER REBOUND SOMETHING
--
-- A reading taken once at load is a reading that is wrong the moment somebody opens the options
-- screen, and "dynamically loaded" was the requirement. Two things keep it current, and neither
-- one is a timer:
--
--   1. THE STALENESS BOUND above. Every question older than M.MAX_AGE seconds re-reads first.
--      This alone is correct; it is simply up to that many seconds late.
--   2. THE GAME'S OWN CHANGE PATH, hooked. Then it is not late at all.
--
-- ⚠️ WHAT IS HOOKED, AND WHY NOT THE DELEGATE. UPalOptionSubsystem broadcasts
-- OnChangeKeyConfigDelegate(prev, new) (Pal.hpp:26113-26114) and that is the obvious target and
-- the wrong one: the `__DelegateSignature` UFunction a dumper prints for a delegate is a
-- SIGNATURE, never executed, and a hook on one fires never. native/ui/_widget.lua:196-203 has
-- the same finding for BP_OnClicked and refuses to arm a route that would report itself armed
-- and see nothing. So the targets here are functions that really are CALLED:
--
--   /Script/Pal.PalOptionSubsystem:SetKeyConfigSettings   the setter the options screen calls
--                                                         (Pal.hpp:26150)
--   /Script/Pal.PalPlayerInput:OnChangeKeyConfig          the listener that rebuilds the live
--                                                         mappings from it (Pal.hpp:26924)
--
-- THE HOOK BODIES TOUCH NOTHING. Each one sets a boolean and increments a counter — no engine
-- object is read, no parameter is unwrapped, nothing is queued onto the game thread. That
-- matters twice over: a hook body is the one place a half-initialised object can be handed to
-- you (core/event.lua's world-load-storm warning), and the actual re-read is then free to
-- happen later, on demand, from ordinary Lua.
--=============================================================================

---The change-notification routes, with the same per-route record the click router keeps.
M.WATCH = {
    { id = "set",    state = "pending", fired = 0,
      path = "/Script/Pal.PalOptionSubsystem:SetKeyConfigSettings",
      what = "UPalOptionSubsystem::SetKeyConfigSettings (Pal.hpp:26150) — what the options "
          .. "screen calls when the player presses apply" },
    { id = "listen", state = "pending", fired = 0,
      path = "/Script/Pal.PalPlayerInput:OnChangeKeyConfig",
      what = "UPalPlayerInput::OnChangeKeyConfig (Pal.hpp:26924) — the listener that rebuilds "
          .. "the live mappings out of the new settings" },
}

local watching = false

---Arm the change hooks. Idempotent, safe to call with no UE4SS at all, and never raises.
---
---Call it from a world.ready subscription rather than at load: core/event.lua:769-776 records a
---native access violation and a wedged UE4SS hook dispatch from hooks armed into the world-load
---storm. Neither of these two fires during that storm — they fire when a human presses apply —
---but the rule is the rule and arming late costs nothing.
---@return integer armed
function M.watch()
    if watching then return 0 end
    watching = true
    local armed = 0
    for _, r in ipairs(M.WATCH) do
        if type(RegisterHook) ~= "function" then
            r.state, r.why = "refused", "RegisterHook is not available in this session"
        else
            local ok, a, b = pcall(RegisterHook, r.path, function()
                r.fired = r.fired + 1
                state.dirty = true
            end)
            if ok then
                r.state, r.why, r.ids, armed = "armed", nil, { a, b }, armed + 1
            else
                r.state, r.why = "refused", tostring(a)
            end
        end
        log.info(string.format("watch %s: %s%s", r.id, r.state,
            r.why and ("  [" .. tostring(r.why) .. "]") or ""))
    end
    return armed
end

---Subscribe M.watch to world.ready and take a first reading there.
---
---core/event is required LAZILY and inside a pcall for the reason api/ui.lua:513-522 gives for
---native/ui/tree: this module must stay loadable, and testable, with no event system and no
---UE4SS at all. Called by core/keyboard's registry at load; harmless to call twice.
---@return boolean subscribed
function M.install()
    local ok = pcall(function()
        local event = require("palforge.core.event")
        event.on("world.ready", function()
            M.watch()
            local n, note = M.refresh()
            log.info(string.format("read the game's key config: %s", note))
            if n == 0 then
                log.warn("nothing was read, so `is this key free` cannot be answered this "
                    .. "session — every status will say \"unknown\" and say why")
            end
        end)
    end)
    return ok
end

--=============================================================================
-- THE ANSWER
--=============================================================================

---What the GAME has on this key. `name` is a UE4SS Key table name ("INS", "F7", "NUM_ZERO").
---
---Returns a record, never nil:
---  state    "game"    the live key config has at least one action on it — `actions` lists them
---           "free"    a reading exists, the FKey name is known, and nothing in it uses this key
---           "unknown" no reading exists, or no FKey name is known for this UE4SS name
---  fkey     the Unreal name it was looked up under, when there is one
---  actions  { { action, via, mods }, ... } for "game"
---  why      a sentence, always — including for "free", because "free" is a claim and a claim
---           should carry what it rests on
---
---⚠️ "free" MEANS "NO ACTION IN THE GAME'S KEY CONFIG USES IT". It does not mean the press will
---arrive: the Steam overlay, the OS and UE's own bindings are all outside this config and
---outside this answer. See the header.
---@param name string
---@return table status
function M.status(name)
    local up = tostring(name or ""):upper()
    local fkey, confidence = M.translate(up)
    local out = { key = up, fkey = fkey, confidence = confidence, actions = {} }

    if not fkey then
        out.state = "unknown"
        out.why = string.format("PalForge knows no Unreal FKey name for the UE4SS key %q, so it "
            .. "cannot look it up in the game's key config. Either it is one of the names Unreal "
            .. "has no FKey for at all (the IME, browser, media and Windows keys, F13..F24) or it "
            .. "is not a UE4SS key name — the table is core/keyboard/base/keymap.lua's M.FKEY", up)
        return out
    end

    local index = M.snapshot()
    if not state.read then
        local parts = {}
        for _, s in ipairs(M.SOURCES) do
            parts[#parts + 1] = string.format("%s=%s", s.id, s.state)
        end
        out.state = "unknown"
        out.why = string.format("%s is Unreal's %s, and the game's key config has not been read "
            .. "this session (%s) — inside a loaded world it is readable, at the title screen it "
            .. "is not", up, fkey, table.concat(parts, " "))
        return out
    end

    local e = index[fkey:lower()]
    if not e or #e.actions == 0 then
        out.state = "free"
        out.why = string.format("%s is Unreal's %s and NO action in the game's live key config "
            .. "uses it%s. That is the strongest thing anyone can say about a key here; it is "
            .. "still not a promise the press arrives, because the Steam overlay, the OS and "
            .. "UE's own bindings are outside this config", up, fkey,
            confidence == "layout"
                and " (ASSUMING a US keyboard layout — an OEM virtual-key names a position, not "
                    .. "a character, so on another layout this is a different key)"
                or "")
        return out
    end

    out.state, out.actions = "game", e.actions
    local names = {}
    for _, a in ipairs(e.actions) do
        names[#names + 1] = string.format("%s [%s%s]", a.action, a.via, a.mods and ("+" .. a.mods) or "")
    end
    out.why = string.format("%s is Unreal's %s and the game has %d binding(s) on it: %s. A UE4SS "
        .. "keybind OBSERVES and does not consume, so taking it does not stop the game's own "
        .. "action — and the game may also claim the key below UE4SS, in which case the press "
        .. "never arrives at all", up, fkey, #e.actions, table.concat(names, ", "))
    return out
end

---Every action the game has on this key, as { action, via, mods } — empty for a free or an
---unanswerable key.
---@param name string
---@return table[]
function M.actionsOn(name) return M.status(name).actions end

--=============================================================================
-- REPORTING — the probe that turns every future key question into a lookup
--=============================================================================

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

---The whole live keymap, as printable lines: every source's state, then every key the game has
---an action on, then every action and where it sits.
---
---This is the thing that was worth the most and did not exist: with no console and no reliable
---key, "what has Palworld already taken" was unanswerable, and every key choice in this tree was
---a guess that could only be tested by shipping it and watching nothing happen.
---@return string[]
function M.lines()
    M.snapshot()
    local out = {}
    for _, s in ipairs(M.SOURCES) do
        out[#out + 1] = string.format("keymap: source %-8s %-8s %d mapping(s) | %s%s",
            s.id, s.state, s.entries or 0, s.what,
            s.why and ("  [" .. tostring(s.why) .. "]") or "")
    end
    for _, r in ipairs(M.WATCH) do
        out[#out + 1] = string.format("keymap: watch  %-8s %-8s fired=%d | %s%s",
            r.id, r.state, r.fired, r.what,
            r.why and ("  [" .. tostring(r.why) .. "]") or "")
    end

    if not state.read then
        out[#out + 1] = "keymap: NOTHING HAS BEEN READ, so every `is this key free` answer this "
            .. "session is \"unknown\" and says so. The config source needs a LOADED WORLD "
            .. "(UPalOptionSubsystem is a world subsystem); run this from inside a save."
        return out
    end

    local keys = sortedKeys(state.index)
    out[#out + 1] = string.format("keymap: %d key(s) carry an action, read %.0f s ago",
        #keys, os.clock() - (state.at or os.clock()))
    for _, k in ipairs(keys) do
        local e = state.index[k]
        local parts = {}
        for _, a in ipairs(e.actions) do
            parts[#parts + 1] = string.format("%s [%s%s]", a.action, a.via,
                a.mods and ("+" .. a.mods) or "")
        end
        out[#out + 1] = string.format("keymap:   %-22s %s", e.key, table.concat(parts, ", "))
    end
    return out
end

---THE LOOKUP TABLE: every name UE4SS can bind, and what PalForge knows about it.
---
---One row per entry in UE4SS's Key table, so a question that used to cost a live run ("can I
---have F6?") costs a glance at a log. `owned` is an optional map of keyName -> description for
---the binds PalForge itself holds, which is how the third case — already taken by us — appears
---here as well; core/keyboard's registry passes its own.
---@param owned table<string,string>?     # keyName -> description, for the binds PalForge holds
---@param refused table<string,string>?   # keyName -> reason, for the names PalForge never binds
---@return string[]
function M.lookup(owned, refused)
    M.snapshot()
    owned, refused = owned or {}, refused or {}
    local names = sortedKeys(M.FKEY)
    local out = { string.format("keymap: %-20s %-18s %-8s %s", "UE4SS NAME", "UNREAL FKEY",
        "STATUS", "WHAT HAS IT") }
    local n = { free = 0, game = 0, unknown = 0, palforge = 0, refused = 0 }
    for _, name in ipairs(names) do
        local st = M.status(name)
        local status, what = st.state, "-"
        -- The refusal outranks everything, because it is the one row where the game's answer is
        -- irrelevant: whatever Palworld does or does not have on Esc, PalForge will not take it.
        if refused[name] then
            status, what = "refused", refused[name]
        elseif owned[name] then
            status, what = "palforge", owned[name]
            if st.state == "game" then
                what = what .. "  ⚠️ AND the game: " .. st.actions[1].action
            end
        elseif st.state == "game" then
            local parts = {}
            for _, a in ipairs(st.actions) do parts[#parts + 1] = a.action .. " [" .. a.via .. "]" end
            what = table.concat(parts, ", ")
        elseif st.state == "unknown" then
            what = st.fkey and "the config has not been read" or "no Unreal FKey name is known"
        end
        n[status] = (n[status] or 0) + 1
        out[#out + 1] = string.format("keymap: %-20s %-18s %-8s %s",
            name, st.fkey or "-", status, what)
    end
    out[#out + 1] = string.format("keymap: %d free, %d taken by the game, %d held by PalForge, "
        .. "%d refused outright, %d unanswerable — \"free\" means no action in the game's key "
        .. "config uses it, which is not the same as \"the press will arrive\"",
        n.free or 0, n.game or 0, n.palforge or 0, n.refused or 0, n.unknown or 0)
    return out
end

return M
