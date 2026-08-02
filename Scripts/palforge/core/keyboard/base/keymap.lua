-- OBSERVED WORKING, 2026-07-28, in a loaded save:
--
--   source config   empty  0 mapping(s)    every container reports its own Num() as 0
--   source project  read   107 mapping(s)  ActionMappings 75, AxisMappings 28, ConsoleKeys 4
--   last refresh took 0.032 s and made 0 name look-up(s)
--   64 free, 24 taken by the game, 9 held by PalForge, 1 refused outright, 67 unanswerable
--
-- W -> MoveForward [project/axis], X -> AutoRun, Z -> VoiceChatPushToTalk. The axis half was
-- the half worth insisting on: W/A/S/D are axis mappings, and a keymap that read only the
-- action maps would have called the four most-used keys in the game free.
--
-- BOTH source verdicts are real answers, and they are different answers. `project read` is the
-- shipped bindings. `config empty` is the game saying the player has not rebound anything —
-- Palworld stores the key config as OVERRIDES — which is why the three-state verdict
-- (read/empty/refused) had to exist: a two-state one would have called this a failure.
--
-- The look-up route cost nothing here, and that is by design rather than luck: it runs only for
-- a container whose own Num() disagrees with what the walk produced. A clean walk builds not one
-- FName.
--
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
--=============================================================================
-- WHAT THE FIRST LIVE RUN MEASURED, AND WHAT IT COST TO EXPLAIN
--
-- The first version of this file ran in a loaded world and reported, precisely:
--
--     source config  refused 0 mapping(s)   [the subsystem and its KeyConfigSettings both read,
--                                            and every map inside came back empty]
--     source project refused 0 mapping(s)   [UInputSettings resolved and every mapping array
--                                            came back empty]
--
-- Both objects resolved. Every container read as nothing. The diagnostic separated "absent" from
-- "resolved but empty", which was worth having — and then it stopped, because "empty" was doing
-- the work of three different facts. Three things are now known and each one is a line of code
-- below rather than a paragraph of hope.
--
-- 1. ⚠️ THE ARRAY READER WAS DROPPING EVERY ELEMENT, AND THAT IS ALMOST CERTAINLY THE WHOLE OF
--    THE `project` ZERO. UE4SS's TArray:ForEach hands the callback (index, elem) where elem is a
--    **RemoteUnrealParam / LocalUnrealParam wrapper**, and the real value is behind `:get()`
--    (RE-UE4SS UE4SS/src/LuaType/LuaTArray.cpp, ForEach pushes with Operation::GetParam;
--    ue4ss/Docs/lua-api/classes/remoteunrealparam.md). eachArray unwrapped nothing, so every
--    element reached the callback as a wrapper, `elem.ActionName` read nil off a userdata whose
--    __index only carries Get/get/set/type, and the mapping was silently dropped. The array
--    iterated the right NUMBER of times and produced nothing — which is exactly the shape
--    core/icons.lua:362-375 already recorded ("the right LENGTH with every value blank") for the
--    same wrapper, in the same tree, three weeks earlier. eachMap unwrapped; eachArray did not.
--    That asymmetry was the bug.
--
-- 2. TMap ITERATION EXISTS ON THIS BUILD. The install ships
--    ue4ss/Docs/lua-api/classes/tmap.md documenting Find / Add / Contains / Remove / Empty /
--    #TMap **and ForEach**, and RE-UE4SS's UE4SS/src/LuaType/LuaTMap.cpp implements ForEach for
--    the UE4SS this game actually runs (v3.0.1 Beta, SHA c838a8ac). So "a TMap cannot be walked
--    from Lua" is NOT true here and is not the explanation for the config zero. What is left,
--    and what is now MEASURED instead of assumed, is `#map` — the __len metamethod is
--    FScriptMap::Num(). `#map == 0` is the map itself saying it is empty, which is a real and
--    reportable answer: Palworld stores the player's key config as OVERRIDES, so a player who
--    has never rebound a key leaves those maps genuinely empty and the defaults live in the
--    project source. Every container below records its own `#`, so "empty" and "unreadable" can
--    never be confused again.
--
-- 3. AND THE LOOK-UP ROUTE, FOR WHEN A WALK IS NOT ENOUGH. A map that will not iterate can still
--    be asked about a key it might hold — Contains(key) then Find(key) — provided you know the
--    key. core/keyboard/base/actions.lua supplies the names (Palworld's own, from
--    DT_UIInputAction and from the project arrays). It runs only when `#map` says there is
--    something in there that the walk did not produce, so the normal case costs nothing.
--
-- ⚠️⚠️ THE ONE WAY TO CRASH THE GAME FROM HERE, WRITTEN OUT BECAUSE IT IS NOT GUESSABLE.
-- TMap's Find / Contains / Remove push the key through UE4SS's pusher for the key property, and
-- for an FName key that is push_nameproperty with Operation::Set, whose entire body is
--     auto& lua_object = params.lua.get_userdata<LuaType::FName>(params.stored_at_index);
-- (RE-UE4SS UE4SS/src/LuaType/LuaUObject.cpp, push_nameproperty). get_userdata does NO type
-- check — it reads an internal uservalue and casts lua_touserdata's result. Hand it a Lua STRING
-- and lua_touserdata returns NULL and the cast dereferences it: a native access violation inside
-- UE4SS's marshalling, precisely the class of fault core/signature.lua exists to prevent and
-- precisely what closed the game once this session. So `map:Find("Jump")` is a crash and
-- `map:Find(FName("Jump"))` is correct. Every call below builds an FName first, and fnameFor()
-- is the only place one is made.
--   (This is also why the module still calls NO UFunction. Find/Contains/ForEach/#/GetRowNames
--    are UE4SS's own bindings on the container object, not marshalled Palworld functions, so
--    core/signature.lua's parameter-list check has nothing to check and nothing to refuse. The
--    hazard here is the ARGUMENT TYPE, and it is closed by construction rather than by a check.)
--
-- ⚠️ AND ONE WAY TO CORRUPT THE GAME'S DATA. UE4SS's TArray __index is not a read: LuaTArray.cpp
-- prepare_to_handle calls AddZeroed when the index is past Num(), so `arr[i]` for i > #arr GROWS
-- THE GAME'S ARRAY. Nothing below indexes an array outside 1..#arr, and nothing below ever will.
-- (`arr:Get(i)` was in the old ladder and has been removed: TArray has no Get member, so it fell
-- through to that same __index with the string "Get" as the subscript, which can only ever throw.)
--=============================================================================
--
-- THE TWO NAMESPACES, which is the part nobody warns you about. UE4SS binds by MICROSOFT
-- VIRTUAL-KEY NAME ("INS", "SPACE", "NUM_ZERO", "OEM_COMMA" — ue4ss/Docs/lua-api/table-
-- definitions/key.md lists them all). Unreal names the same keys quite differently ("Insert",
-- "SpaceBar", "NumPadZero", "Comma"). A lookup that forgets this finds nothing and reports
-- every key free, which is worse than reporting nothing at all. M.FKEY is that translation,
-- written out in full, and every entry it cannot justify is `false` rather than a guess.
--
-- ⚠️ THE COUNT IS 165, NOT 156, AND THE OLD NUMBER WAS WRONG IN THIS FILE'S OWN COMMENTS.
-- Counted on 2026-08-02 out of RE-UE4SS's shipped key.md (the code block under "Key-code
-- strings"): 165 names. M.FKEY has 165 rows and the two sets are IDENTICAL — zero names in the
-- Key table that M.FKEY lacks, zero rows in M.FKEY that the Key table does not have. The live run
-- recorded at the top of this file agrees and always did: 64 + 24 + 9 + 1 + 67 = 165 rows. So
-- M.lookup's union over M.FKEY and the live Key table adds no row on this build, and it exists
-- for the build where that stops being true — a name UE4SS will bind and this table has never
-- heard of used to be missing from the report entirely instead of showing as `unknown`.
--
--   local keymap = require("palforge.core.keyboard.base.keymap")
--   local st = keymap.status("INS")     -- { state = "game", actions = {...}, why = "..." }
--   for _, line in ipairs(keymap.lines()) do print(line) end
local log     = require("palforge.utils.log").scope("keymap")
-- Palworld's own action names and key names, live table first and a shipped copy behind it.
-- Data only: requiring it makes no engine call, so this module stays loadable headless.
local actions = require("palforge.core.keyboard.base.actions")

local M = {}

---Re-exported so a caller can see which names the look-up route will ask about without reaching
---past this module.
M.actions = actions

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

-- ⚠️ THE UNWRAP, AND IT APPLIES TO ARRAYS TOO. UE4SS hands a container's elements to Lua as a
-- RemoteUnrealParam (remote data) or a LocalUnrealParam (local copy); both are dynamic wrappers
-- and the value is behind :get() (ue4ss/Docs/lua-api/classes/{remote,local}unrealparam.md). The
-- old eachMap did this and the old eachArray did NOT, which is how the project source read the
-- right number of elements and produced zero mappings — the identical failure core/icons.lua:
-- 362-375 records for GetDataTableColumnAsString. One unwrap, used by both walkers, so the two
-- cannot drift apart again.
local function unwrap(p)
    if type(p) ~= "userdata" and type(p) ~= "table" then return p end
    local v; if pcall(function() v = p:get() end) and v ~= nil and v ~= p then return v end
    return p
end

-- A container's OWN count. `#` on a UE4SS TArray or TMap is the __len metamethod and it is
-- FScriptArray::Num() / FScriptMap::Num() — the container answering for itself, before any
-- iteration and before any of our code can lose anything. nil means the value would not answer
-- `#` at all, which is a different fact from answering 0 and is reported as one.
local function sizeOf(c)
    if c == nil then return nil end
    local n; local ok = pcall(function() n = #c end)
    if ok and type(n) == "number" then return n end
    return nil
end

-- Walk a UE4SS TArray. Returns how many elements reached `fn`, and which route carried them.
--
-- ⚠️ THE INDEX FALLBACK STAYS INSIDE 1..#arr AND MUST. LuaTArray.cpp's prepare_to_handle calls
-- AddZeroed when the subscript is past Num(), so reading `arr[i]` out of bounds APPENDS TO THE
-- GAME'S ARRAY. The loop bound is the array's own `#`, never a guess.
local function eachArray(arr, fn)
    if arr == nil then return 0, "absent" end
    local n = 0
    local function push(v) if v ~= nil then n = n + 1; pcall(fn, unwrap(v)) end end
    if pcall(function() arr:ForEach(function(_, v) push(v) end) end) and n > 0 then
        return n, "ForEach"
    end
    local len = sizeOf(arr)
    if len == nil then return n, "no-length" end
    if len <= 0 then return n, "empty" end
    for i = 1, len do local v; pcall(function() v = arr[i] end); push(v) end
    return n, (n > 0) and "index" or "refused"
end

-- Walk a UE4SS TMap. ForEach is documented on this install
-- (ue4ss/Docs/lua-api/classes/tmap.md) and implemented in RE-UE4SS's LuaTMap.cpp, so it is tried
-- first; what it cannot do is tell us it iterated nothing BECAUSE the map is empty rather than
-- because the walk failed, which is why the caller measures `#` separately.
local function eachMap(m, fn)
    if m == nil then return 0, "absent" end
    local n = 0
    local ok = pcall(function()
        m:ForEach(function(k, v)
            n = n + 1
            pcall(fn, unwrap(k), unwrap(v))
        end)
    end)
    if n > 0 then return n, "ForEach" end
    return 0, ok and "iterated-nothing" or "refused"
end

--=============================================================================
-- LOOKING A MAP UP INSTEAD OF WALKING IT
--
-- Contains(key) answers without throwing; Find(key) THROWS when the key is absent
-- (ue4ss/Docs/lua-api/classes/tmap.md says so in as many words). So a miss is normal traffic
-- here, not a fault, and it is counted rather than logged — 244 "not found" lines would bury the
-- one line that matters.
--
-- Contains FIRST, and that is not a micro-optimisation. UE4SS's throw path runs
-- LuaMadeSimple::handle_error, which does `lua_settop(state, 0)` — it CLEARS THE WHOLE LUA STACK
-- — before longjmp'ing to the enclosing pcall, and it does so from inside a C++ frame holding a
-- TArray local. Doing that several hundred times per refresh to ask a question Contains answers
-- for free is not something to build on. Find runs only on a hit.
--=============================================================================

-- Build the FName for a name, or nil.
--
-- ⚠️ NEVER PASS THE STRING. See the header: TMap's key pusher casts lua_touserdata's result to an
-- FName with no type check, so a Lua string is a NULL dereference inside UE4SS.
--
-- The round-trip check is not paranoia either. UE4SS's FName(string) returns the FName for
-- "None" when the string has never been registered in this build's global name table
-- (ue4ss/Docs/lua-api.md:150-152). Asking Contains about "None" is asking a different question
-- than the one intended, and a map that happened to hold a None key would answer yes to every
-- unregistered name we tried. A name that does not round-trip is dropped and counted.
local function fnameFor(name)
    if type(FName) ~= "function" then return nil end
    local fn; if not pcall(function() fn = FName(name) end) then return nil end
    if fn == nil then return nil end
    if str(fn) ~= name then return nil end
    return fn
end

-- Ask one map about every candidate name. `fn(name, value)` is called for each hit.
-- Returns how many keys were found.
local function findIn(m, pool, fn)
    local found = 0
    for _, c in ipairs(pool) do
        local hit; pcall(function() hit = m:Contains(c.fname) end)
        if hit == true then
            local v; local ok = pcall(function() v = m:Find(c.fname) end)
            if ok and v ~= nil then
                found = found + 1
                pcall(fn, c.name, unwrap(v))
            end
        end
    end
    return found
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
    tried    = nil,     -- os.clock() of the last ATTEMPT, successful or not (see snapshot)
    cost     = nil,     -- seconds the last refresh took
    lookups  = 0,       -- Contains() calls the last refresh made
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
for _, s in ipairs(M.SOURCES) do s.state, s.entries, s.containers = "unread", 0, {} end

local function source(id)
    for _, s in ipairs(M.SOURCES) do if s.id == id then return s end end
end

--=============================================================================
-- THE PER-CONTAINER RECORD — the thing whose absence made "empty" unfalsifiable
--
-- One of these per TMap / TArray we touch. It is the difference between the old log line
--
--     source config refused 0 mapping(s)  [every map inside came back empty]
--
-- and a line that can be acted on, because it separates the four things that sentence was
-- covering for:
--
--   num = nil               the property did not read back at all, or would not answer `#`
--   num = 0                 THE CONTAINER SAYS IT IS EMPTY. A real answer, not a failure —
--                           Palworld keeps the player's key config as OVERRIDES, so a player who
--                           has never rebound anything leaves these maps genuinely empty.
--   num > 0, visited = 0    the container has entries and neither route produced one: a READ
--                           fault, and the one case worth chasing.
--   num > 0, added < found  entries came out and could not be turned into a (key, action) pair —
--                           a shape problem in the value, not in the walk.
--=============================================================================

local function container(rec, id, what)
    local c = { id = id, what = what, num = nil, route = "unread", visited = 0, found = 0, added = 0 }
    rec.containers[#rec.containers + 1] = c
    return c
end

-- One printable line per container. This is what a future session reads first.
local function containerLine(sid, c)
    local size = (c.num == nil) and "?" or tostring(c.num)
    local plural = (c.num == 1) and "entry" or "entries"
    local note
    if c.num == nil then
        note = "the property did not read back, or would not answer `#` — nothing is claimed "
            .. "about whether the game has entries here"
    elseif c.num == 0 then
        note = "THE CONTAINER ITSELF SAYS IT IS EMPTY (its own Num()), so there is nothing to "
            .. "read and no read has failed"
    elseif c.visited > 0 and c.added == 0 then
        note = string.format("⚠️ %d %s came out of the walk and NOT ONE BECAME A MAPPING — the "
            .. "elements are reaching Lua and their shape is not what this reader expects. A "
            .. "fault in PalForge.", c.visited, (c.visited == 1) and "entry" or "entries")
    elseif c.found == 0 then
        note = string.format("⚠️ it holds %d %s and neither route reached one. Two things do "
            .. "that and the `via` column says which were tried: the walk and the look-up both "
            .. "refused on this build, OR every key in it is a name no action-name source lists "
            .. "(the look-up can only ask about names it has).", c.num, plural)
    elseif c.added == 0 then
        note = string.format("⚠️ %d %s was reached and none became a mapping — the value's shape, "
            .. "not the walk", c.found, (c.found == 1) and "entry" or "entries")
    elseif c.found < c.num then
        note = string.format("%d of %d %s reached; the rest carry a key no action-name source "
            .. "lists, so they are UNSEEN rather than absent", c.found, c.num, plural)
    else
        note = "read in full"
    end
    return string.format("keymap:   %-8s %-32s #=%-5s via %-18s visited=%d found=%d added=%d | %s",
        sid, c.id, size, c.route, c.visited, c.found, c.added, note)
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

--=============================================================================
-- THE CANDIDATE NAMES — built once per refresh, and only if something needs them
--
-- Materialising the pool costs one FName per name, and an FName is an engine call. A session
-- where every map walks cleanly (or is honestly empty) must not pay for it, so the pool is a
-- CLOSURE that builds on first demand and never twice. Every reader that wants it calls
-- pool.get(); a refresh that never needs a look-up never touches FName at all.
--
-- The pool is the UNION of two halves, and neither is enough alone:
--   * the UI action names, from the live DT_UIInputAction or the shipped copy of its 244 row
--     names (core/keyboard/base/actions.lua)
--   * every ActionName / AxisName the PROJECT source produced this refresh — the gameplay
--     names ("Jump", "Attack", the movement axes) that DT_UIInputAction does not contain
-- which is why refresh() reads the project source FIRST.
--=============================================================================
local function newPool()
    local raw, seen, built = {}, {}, nil
    local p = {}
    -- Add a name discovered while reading a source. Free — no engine call until get().
    function p.offer(name)
        if type(name) == "string" and #name > 0 and not seen[name] then
            seen[name] = true
            raw[#raw + 1] = name
        end
    end
    ---@return table list, table stats
    function p.get()
        if built then return built, p.stats end
        local names, rec = actions.names()
        for _, n in ipairs(names) do p.offer(n) end
        built = {}
        local unregistered = 0
        for _, n in ipairs(raw) do
            local fn = fnameFor(n)
            if fn then built[#built + 1] = { name = n, fname = fn }
            else unregistered = unregistered + 1 end
        end
        p.stats = { total = #raw, usable = #built, unregistered = unregistered,
            source = rec.source, why = rec.why }
        actions.note()
        log.info(string.format("action names: %d candidate(s), %d have an FName in this build's "
            .. "name table, %d do not and cannot be looked up", #raw, #built, unregistered))
        return built, p.stats
    end
    function p.wanted() return #raw end
    return p
end

-- SOURCE 1: the player's own config. This is the one that matters — it is what the options
-- screen writes and what the game actually obeys, so a player who moved Inventory onto F7 is
-- reflected here and nowhere else.
--
-- ⚠️ AND IT IS AN OVERRIDE STORE, WHICH IS WHY EMPTY IS A REAL ANSWER. Palworld writes into
-- FPalKeyConfigSettings what the player CHANGED; the shipped bindings live in the project source
-- below. So `#MouseAndKeyboardActionMappings == 0` on a save where nobody has opened the key
-- config screen is the game telling the truth, not a read that failed — and the container record
-- is what lets the log say which of the two it is instead of guessing.
local function readConfig(index, actions_, pool)
    local rec = source("config")
    rec.containers = {}
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

    -- Walk a map, then — only if its own `#` says entries are still unaccounted for — look the
    -- rest up by name. `onPair(actionName, value)` does the adding and returns how many mappings
    -- it produced. Both routes go through the same body, so a mapping found by Find is indexed
    -- identically to one found by ForEach.
    local function readMap(id, what, onPair)
        local c = container(rec, id, what)
        local m = field(kc, id)
        c.num = sizeOf(m)
        if m == nil then c.route = "absent"; return 0 end
        if c.num == 0 then c.route = "empty"; return 0 end

        -- Counted by DISTINCT KEY, not by callback. When both routes run, Find re-finds
        -- everything ForEach already handed over; add() would dedupe the mappings anyway, but
        -- `found` is compared against the container's own `#` in the report and a double count
        -- there would make an incomplete read look complete.
        local added, seen = 0, {}
        local function take(name, v)
            if not name or seen[name] then return end
            seen[name] = true
            c.found = c.found + 1
            added = added + (onPair(name, v) or 0)
        end

        local visited, route = eachMap(m, function(k, v) take(str(k), v) end)
        c.visited, c.route = visited, route

        -- The look-up route. It runs when the walk did not account for everything the map says
        -- it holds — which covers both "ForEach produced nothing" and "ForEach produced some".
        if c.num == nil or c.found < c.num then
            local list = pool.get()
            state.lookups = state.lookups + #list
            local before = c.found
            findIn(m, list, take)
            c.route = (visited > 0) and (route .. "+Find") or "Find"
            if c.found == before and visited == 0 then c.route = route .. "/Find-miss" end
        end
        c.added = added
        return added
    end

    -- The action bindings: FName -> FPalKeyConfigKeys { MainKey, SecondaryKey } (Pal.hpp:3974).
    n = n + readMap("MouseAndKeyboardActionMappings",
        "FName -> FPalKeyConfigKeys, the player's rebound actions (Pal.hpp:3974)",
        function(name, v)
            local a = 0
            if add(index, actions_, keyNameOf(field(v, "MainKey")), name, "config/main") then a = a + 1 end
            if add(index, actions_, keyNameOf(field(v, "SecondaryKey")), name, "config/second") then a = a + 1 end
            return a
        end)

    -- The UI bindings: FName -> FKey directly, no Main/Secondary pair (Pal.hpp:3978).
    n = n + readMap("MouseAndKeyboardUIInputMappings",
        "FName -> FKey, the menu keys (Pal.hpp:3978)",
        function(name, v)
            return add(index, actions_, keyNameOf(v), name, "config/ui") and 1 or 0
        end)

    -- The axis bindings: an array, and each element carries its own AxisName because
    -- FPalAxisKeyConfigKeys extends FPalKeyConfigKeys with one (Pal.hpp:623-628). Movement
    -- lives here — W/A/S/D are axis mappings, not actions — so a keymap without this half
    -- would report the four most-used keys in the game as free. No look-up route is needed or
    -- possible: an array is enumerable and each element names itself.
    do
        local c = container(rec, "MouseAndKeyboardAxisMappings",
            "FPalAxisKeyConfigKeys[], the player's rebound movement axes (Pal.hpp:3975)")
        local arr = field(kc, "MouseAndKeyboardAxisMappings")
        c.num = sizeOf(arr)
        local added = 0
        local visited, route = eachArray(arr, function(e)
            local axis = str(field(e, "AxisName"))
            if not axis then return end
            c.found = c.found + 1
            pool.offer(axis)
            if add(index, actions_, keyNameOf(field(e, "MainKey")), axis, "config/axis") then added = added + 1 end
            if add(index, actions_, keyNameOf(field(e, "SecondaryKey")), axis, "config/axis2") then added = added + 1 end
        end)
        c.visited, c.route, c.added = visited, route, added
        n = n + added
    end

    rec.entries = n
    if n == 0 then
        -- Say WHICH of the two it is, from the containers' own counts, rather than offering the
        -- reader both hypotheses again.
        local anySize, allEmpty = false, true
        for _, c in ipairs(rec.containers) do
            if c.num ~= nil then anySize = true; if c.num > 0 then allEmpty = false end end
        end
        if anySize and allEmpty then
            rec.state, rec.why = "empty",
                "every container inside KeyConfigSettings reports its own size as 0. That is the "
                .. "game answering, not a read failing: Palworld stores the player's key config "
                .. "as OVERRIDES, so a save where nobody has rebound a key has nothing here and "
                .. "the shipped bindings are the `project` source's job"
        else
            rec.state, rec.why = "refused",
                "KeyConfigSettings read and at least one container reports entries, and neither "
                .. "the walk nor the name look-up turned one into a mapping. The per-container "
                .. "lines below say where it stopped, and there are only two ways to get here: "
                .. "both routes refuse on this build, or every key in that container is a name "
                .. "no action-name source lists (core/keyboard/base/actions.lua is where that "
                .. "list comes from, and the project arrays are the other half of it)"
        end
    else
        rec.state, rec.why = "read", nil
    end
    return n
end

-- SOURCE 2: the project's defaults. Weaker evidence than the player's config — it is what the
-- game SHIPPED with, not necessarily what it is obeying — but it covers the actions the config
-- map has no entry for, and it is readable at the title screen where the subsystem is not.
--
-- READ FIRST, and not only for its own sake: every ActionName and AxisName it yields goes into
-- the candidate pool, and those are the gameplay names ("Jump", the movement axes) that no
-- DataTable in the catalog contains. Without this half the config maps could only ever be looked
-- up by UI action name.
local function readProject(index, actions_, pool)
    local rec = source("project")
    rec.containers = {}
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

    local function readArr(id, what, onElem)
        local c = container(rec, id, what)
        local arr = field(is, id)
        c.num = sizeOf(arr)
        local added = 0
        local visited, route = eachArray(arr, function(e)
            c.found = c.found + 1
            added = added + (onElem(e) or 0)
        end)
        c.visited, c.route, c.added = visited, route, added
        return added
    end

    n = n + readArr("ActionMappings",
        "FInputActionKeyMapping[], the shipped DefaultInput.ini actions (Engine.hpp:13683)",
        function(m)
            local action = str(field(m, "ActionName"))
            if action then pool.offer(action) end
            return add(index, actions_, keyNameOf(field(m, "Key")), action, "project/action", mods(m))
                and 1 or 0
        end)
    n = n + readArr("AxisMappings",
        "FInputAxisKeyMapping[], the shipped movement axes (Engine.hpp:13684)",
        function(m)
            local axis = str(field(m, "AxisName"))
            if axis then pool.offer(axis) end
            return add(index, actions_, keyNameOf(field(m, "Key")), axis, "project/axis") and 1 or 0
        end)
    -- UE's own console keys. Not an action mapping and easy to miss: these are the keys that
    -- open the engine console, they are claimed below the game entirely, and a mod that binds
    -- one gets exactly the F7 experience (Engine.hpp:13689).
    n = n + readArr("ConsoleKeys",
        "FKey[], the keys that open UE's own console (Engine.hpp:13689)",
        function(k)
            return add(index, actions_, keyNameOf(k), "<UE console>", "project/console") and 1 or 0
        end)

    rec.entries = n
    if n > 0 then
        rec.state, rec.why = "read", nil
        return n
    end

    -- ⚠️ THE THREE ZEROES, KEPT APART. The old code collapsed them into "every mapping array came
    -- back empty", which is what made the first live run unactionable.
    local sized, populated, visited = 0, 0, 0
    for _, c in ipairs(rec.containers) do
        if c.num ~= nil then sized = sized + 1; if c.num > 0 then populated = populated + 1 end end
        visited = visited + c.visited
    end
    if sized == 0 then
        rec.state, rec.why = "refused",
            "UInputSettings resolved but not one of ActionMappings / AxisMappings / ConsoleKeys "
            .. "would answer `#` — the properties are declared (Engine.hpp:13683-13689) and this "
            .. "build did not hand them over as containers at all"
    elseif populated == 0 then
        rec.state, rec.why = "empty",
            "UInputSettings resolved and every array reports its own size as 0. On a build whose "
            .. "input runs through its own key config (FPalKeyConfigSettings) and its own UI "
            .. "action table (DT_UIInputAction), the legacy DefaultInput.ini arrays being genuinely "
            .. "empty is a REAL answer and not a failed read — but it also means the only place "
            .. "left that can name a key is the config source"
    else
        rec.state, rec.why = "refused", string.format(
            "UInputSettings resolved and %d array(s) report entries, %d element(s) reached the "
            .. "reader, and not one became a mapping — a shape fault in the element, not an "
            .. "empty array. See the per-container lines", populated, visited)
    end
    return n
end

---Re-read the game's key bindings NOW. Returns how many mappings landed, and a note.
---
---Builds into a fresh index and swaps it in only if something was read, so a refresh attempted
---at the title screen (where the subsystem does not exist) cannot blank a good reading taken
---inside a world.
---WHAT A REFRESH COSTS, because 244 look-ups per re-read is not free and pretending otherwise is
---how a demand-driven read becomes a stall.
---
---  the walk           four property reads, three container walks and one `#` per container.
---                     This is what a refresh costs in the ordinary case and it is what the old
---                     version cost: microseconds.
---  the look-up route  runs ONLY for a map whose own `#` says it holds entries the walk did not
---                     produce. When it runs it is one FName per candidate name (built once per
---                     refresh, shared by both maps) plus one Contains per name per map, plus one
---                     Find per HIT. With the shipped 244 UI names and whatever the project
---                     arrays add, that is a few hundred Contains calls — each one a hash lookup
---                     in an FScriptMap, no allocation, no throw. `state.lookups` counts them and
---                     `state.cost` records the wall-clock seconds, both printed by M.lines(), so
---                     this paragraph can be checked against a real run instead of believed.
---
---AND IT STILL HAPPENS ON DEMAND ONLY. M.MAX_AGE bounds it in ELAPSED SECONDS (core/poll.lua's
---rule: never a tick count), nothing polls, and the change hooks below only set a flag.
---@return integer mappings, string note
function M.refresh()
    -- ⚠️ THE LAZY INSTALL, AND IT IS THE RELEASE BUILD'S ONLY ROUTE TO THE CHANGE-WATCH.
    -- M.install()'s only caller used to be registory.load(), which runs inside `if env.dev`
    -- (core/registry.lua) — so a shipped build never armed the two change hooks and never took an
    -- initial reading. It is called from HERE rather than from snapshot() because a caller that
    -- asks for a re-read explicitly (test/init.lua's pf_keys does) never goes through snapshot's
    -- staleness gate and would otherwise never arm it. Idempotent, pcall'd, and free after the
    -- first success. M.install's own doc has the whole of what this closes.
    if not M.INSTALL.done then pcall(M.install) end
    local t0 = os.clock()
    state.lookups = 0
    local index, actions_ = {}, {}
    local pool = newPool()
    -- PROJECT FIRST. Its arrays are the only source of the gameplay action and axis NAMES, and
    -- the config maps are looked up by name — so reading them the other way round would leave
    -- every non-UI action unaskable.
    local n = readProject(index, actions_, pool)
    n = n + readConfig(index, actions_, pool)
    state.dirty = false
    state.tried = os.clock()
    state.cost = state.tried - t0
    if n == 0 then
        local parts = {}
        for _, s in ipairs(M.SOURCES) do
            parts[#parts + 1] = string.format("%s=%s", s.id, s.state)
        end
        return 0, string.format("no source produced a mapping (%s) in %.3f s, %d look-up(s)",
            table.concat(parts, " "), state.cost, state.lookups)
    end
    state.index, state.actions = index, actions_
    state.read, state.at = true, state.tried
    local keys = 0
    for _ in pairs(index) do keys = keys + 1 end
    return n, string.format("%d mapping(s) over %d key(s) in %.3f s, %d look-up(s)",
        n, keys, state.cost, state.lookups)
end

---The current reading, refreshing first if it is stale or something said it moved.
---
---There is no poller behind this and there never will be: a re-read only matters when somebody is
---about to ask a question, so it happens when they ask.
---
---⚠️ THE STALENESS BOUND IS ON THE LAST ATTEMPT, NOT THE LAST SUCCESS, and that is a bug fix
---rather than a nicety. The old test was `not state.read or ... state.at == nil`, and `at` is only
---set by a refresh that READ something — so in a session where nothing is readable (the title
---screen, or the first live run of this module) every single question re-read the whole game.
---M.lookup() asks 165 of them in a row (the count was written as 156 here and in test/cases/ui.lua
---and is wrong: RE-UE4SS's key.md lists 165 names and the live run at the top of this file adds up
---to the same 165), so that one run performed 165 full refreshes and the log never said so. With
---the look-up route now in the path that would have been tens of thousands of engine calls to
---answer a question that had already failed. `tried` is stamped by every refresh, successful or
---not, so a failure is cached for M.MAX_AGE exactly like a success.
---@return table index
function M.snapshot()
    local stale = state.dirty
        or (state.tried == nil)
        or ((os.clock() - state.tried) > M.MAX_AGE)
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
---Call it from a world.ready subscription rather than at load: core/event.lua:46-53 records a
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

---The install record. Printed by M.lines(), because "the change-watch never armed" and "the
---player never rebound anything" produce exactly the same silent log and are not the same fact.
M.INSTALL = { done = false, attempts = 0, armedNow = false,
    why = "M.install() has not been called yet" }

---Subscribe M.watch to world.ready and take a first reading there.
---
---core/event is required LAZILY and inside a pcall for the reason api/ui.lua:513-522 gives for
---native/ui/tree: this module must stay loadable, and testable, with no event system and no
---UE4SS at all. Idempotent: the subscription is made once and every later call is a boolean read.
---
---⚠️ IT IS NO LONGER DEV-ONLY, AND THAT WAS A SHIPPED GAP RATHER THAN A TIDINESS ONE. Until
---2026-08-02 the only caller was registory.load() (core/keyboard/base/registory.lua), whose one
---caller is core/registry.lua inside `if env.dev`. So in a RELEASE build the world.ready
---change-watch never armed and no initial reading was ever taken. Nothing was ever WRONG —
---M.snapshot() re-reads on demand and M.MAX_AGE bounds how old an answer can be — but a key the
---player rebound mid-session went unnoticed for up to 30 s, and the two hooks that make it
---instant were never registered at all. That stopped being hypothetical the moment a pack could
---declare UI{ keys = ... }: api/ui -> native/ui/keys.arm -> registory.claim -> M.status ->
---M.snapshot is a RELEASE path into this module, and it is a shipped capability. M.refresh() now
---calls this on first demand, so a release build arms itself the first time anything asks a key
---question; registory.load() still calls it directly in dev, which only moves the arming earlier.
---
---⚠️ AND IT ARMS THE WATCH AT ONCE WHEN THE WORLD IS ALREADY UP. A lazy install that only
---subscribed would wait for the NEXT world load, and in a session where the player loads one save
---and stays in it that is never — the release build would have the subscription and none of the
---benefit. The immediate arm is gated on core/event's own isWorldReady() (core/event.lua:2774)
---rather than on anything this module can see for itself, and that gate is precisely the one the
---world-load-storm rule wants: core/event.lua:1314 (tryHookAfterWorldReady) arms native hooks after world.ready BECAUSE
---the ready-watch opens that gate only once the storm is over. Arming here is therefore the same
---moment the dev path has always used, reached from a different direction.
---@return boolean subscribed
function M.install()
    if M.INSTALL.done then return true end
    M.INSTALL.attempts = M.INSTALL.attempts + 1
    local armedNow = false
    local ok, err = pcall(function()
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
        if type(event.isWorldReady) == "function" and event.isWorldReady() == true then
            M.watch()
            armedNow = true
        end
    end)
    M.INSTALL.done, M.INSTALL.armedNow = ok, armedNow
    if ok then
        M.INSTALL.why = string.format("subscribed to world.ready on attempt %d%s",
            M.INSTALL.attempts,
            armedNow and "; the world was ALREADY up when the first question arrived, so the "
                .. "change-watch was armed there and then rather than waiting for a world load "
                .. "that may never come" or "")
    else
        M.INSTALL.why = string.format("attempt %d failed: %s. There is no change-watch and no "
            .. "initial reading this session; answers stay correct because snapshot() re-reads on "
            .. "demand, and they are up to %d s stale after a rebind",
            M.INSTALL.attempts, tostring(err), M.MAX_AGE)
    end
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

-- M.actionsOn(name) STOOD HERE AND WAS REMOVED ON 2026-08-02. It was `M.status(name).actions`
-- and it never acquired a caller anywhere in the tree (plan/TODO.md §6 lists it as dead surface).
-- It is deleted rather than wired because its SHAPE is wrong for this module, which is the more
-- useful half of the finding: it hands back a list and drops the `why` sentence, and an empty
-- list from it is indistinguishable between "the game has nothing on this key" and "nothing could
-- be read, so nothing is claimed". Collapsing those two is the exact failure every other answer
-- in this file is written to prevent — see M.status's header on why "free" and "unknown" are
-- different states. A caller that wants the actions wants the status: `M.status(name).actions`.

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
        -- ⚠️ THE LINES THAT DID NOT EXIST, and their absence is why the first live run ended in
        -- two hypotheses instead of an answer. One row per container, carrying the container's
        -- OWN size next to what our reader got out of it.
        for _, c in ipairs(s.containers or {}) do out[#out + 1] = containerLine(s.id, c) end
    end
    for _, r in ipairs(M.WATCH) do
        out[#out + 1] = string.format("keymap: watch  %-8s %-8s fired=%d | %s%s",
            r.id, r.state, r.fired, r.what,
            r.why and ("  [" .. tostring(r.why) .. "]") or "")
    end
    -- The install line. Without it "watch set pending" reads as a mystery; with it, "the
    -- subscription was never made" and "it was made and the hook refused" are two sentences.
    out[#out + 1] = string.format("keymap: install %-8s attempts=%d | the world.ready "
        .. "subscription that arms the change-watch and takes the first reading  [%s]",
        M.INSTALL.done and "done" or "none", M.INSTALL.attempts, tostring(M.INSTALL.why))
    local names = (actions.state.source == "unread")
        and "no action-name source was needed — every container either walked cleanly or said it "
            .. "was empty, so not one FName was built"
        or string.format("action names came from the %s copy of %s: %s",
            actions.state.source, actions.TABLE, tostring(actions.state.why))
    out[#out + 1] = string.format("keymap: last refresh took %.3f s and made %d name look-up(s); "
        .. "%s. The re-read is on DEMAND with a %d s staleness bound in ELAPSED SECONDS — nothing "
        .. "here polls and no tick count is used.",
        state.cost or 0, state.lookups or 0, names, M.MAX_AGE)

    if not state.read then
        out[#out + 1] = "keymap: NOTHING HAS BEEN READ, so every `is this key free` answer this "
            .. "session is \"unknown\" and says so. READ THE CONTAINER LINES ABOVE BEFORE "
            .. "CONCLUDING ANYTHING: `#=0` is the game saying that container is empty, which is a "
            .. "real answer; `#=?` is a property that would not answer at all; and `#=N` with "
            .. "added=0 is the only one of the three that is a fault in this code. The config "
            .. "source also needs a LOADED WORLD (UPalOptionSubsystem is a world subsystem)."
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

-- THE ROWS OF THE LOOKUP TABLE — the UNION of every source that can name a bindable key,
-- upper-cased, de-duplicated, and each row remembering WHICH sources named it.
--
-- ⚠️ THE UNION IS THE WHOLE POINT AND IT USED TO BE M.FKEY ALONE. The old M.lookup iterated
-- M.FKEY while its own doc said "one row per entry in UE4SS's Key table" (plan/TODO.md §7 filed
-- exactly this), so a name UE4SS will happily bind and M.FKEY has never heard of was MISSING FROM
-- THE REPORT ENTIRELY instead of appearing as `unknown` — and `unknown` is the one status this
-- report exists to produce. The guard against that drift is test/cases/ui.lua's "the name map
-- covers every key UE4SS can actually bind" case, which SKIPS headlessly (there is no Key table
-- outside the game), so the invariant was asserted only in a live run that somebody had to
-- remember to make. Reading the live table here means the drift shows up in the log, in the
-- report that is already being read for this exact question, without the suite.
--
-- ⚠️ AND ON THIS BUILD THE UNION ADDS NOTHING, WHICH IS THE RESULT AND NOT A REASON TO DROP IT.
-- Measured 2026-08-02 against RE-UE4SS's shipped key.md: 165 Key names, 165 M.FKEY rows, and the
-- two sets are identical in both directions. So the two drift counters on the summary line should
-- both read 0 in a live run today; the day one of them does not is the day this was worth
-- writing, and until then it is the report stating the invariant rather than a skipped test
-- claiming it.
--
-- The four sources, kept apart in `from` so a reader can tell why a row is here:
--   fkey      M.FKEY — every name PalForge has a translation for, including the ones it has
--             deliberately marked `false` ("Unreal has no FKey for this, so nothing is claimed")
--   ue4ss     the live `Key` table — the names THIS PROCESS can actually bind. A row that is
--             here and not in `fkey` is the drift above, and it is flagged in its own line.
--   owned     what PalForge itself currently holds, passed in by core/keyboard's registry
--   refused   what PalForge refuses outright (Esc), from the same place
local function bindableNames(owned, refused)
    local seen, rows = {}, {}
    local function add(name, from)
        if type(name) ~= "string" or #name == 0 then return end
        local up = name:upper()
        local row = seen[up]
        if not row then row = { name = up, from = {} }; seen[up] = row; rows[#rows + 1] = row end
        row.from[from] = true
    end
    local known = 0
    for name in pairs(M.FKEY) do add(name, "fkey"); known = known + 1 end
    -- ⚠️ A TYPE TEST AND A pcall, BOTH. registory's install() already accepts a `Key` that is
    -- userdata rather than a table on some build, and pairs() over a userdata with no __pairs
    -- raises — a report that raises is a report nobody gets, which is worse than a short one.
    local live = 0
    if type(Key) == "table" then
        pcall(function() for name in pairs(Key) do add(name, "ue4ss"); live = live + 1 end end)
    end
    for name in pairs(owned) do add(name, "owned") end
    for name in pairs(refused) do add(name, "refused") end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows, live, known
end

---THE LOOKUP TABLE: every name that can be bound in this session, and what PalForge knows about
---each one.
---
---One row per name in the UNION of M.FKEY, UE4SS's live `Key` table, the binds PalForge holds and
---the names it refuses (bindableNames above says why the union rather than M.FKEY alone). So a
---question that used to cost a live run ("can I have F6?") costs a glance at a log, and a name
---UE4SS can bind that this module cannot translate appears as `unknown` — which is a real answer
---— instead of not appearing at all.
---
---`owned` is an optional map of keyName -> description for the binds PalForge itself holds, which
---is how the third case — already taken by us — appears here as well; core/keyboard's registry
---passes its own (registory.owned()).
---@param owned table<string,string>?     # keyName -> description, for the binds PalForge holds
---@param refused table<string,string>?   # keyName -> reason, for the names PalForge never binds
---@return string[]
function M.lookup(owned, refused)
    M.snapshot()
    owned, refused = owned or {}, refused or {}
    local rows, live, known = bindableNames(owned, refused)
    local out = { string.format("keymap: %-20s %-18s %-8s %s", "UE4SS NAME", "UNREAL FKEY",
        "STATUS", "WHAT HAS IT") }
    local n = { free = 0, game = 0, unknown = 0, palforge = 0, refused = 0 }
    local untranslated, unbindable = 0, 0
    for _, row in ipairs(rows) do
        local name = row.name
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
        -- THE TWO DRIFTS, marked on the row rather than left to be re-derived. Neither is fatal
        -- and both are facts about PalForge's own table, so they are appended to whatever the
        -- game's answer was rather than replacing it.
        if not row.from.fkey then
            untranslated = untranslated + 1
            what = what .. "  ⚠️ UE4SS WILL BIND THIS NAME AND M.FKEY HAS NO ROW FOR IT — nothing "
                .. "can be said about the key until keymap.lua's table gains one"
        elseif live > 0 and not row.from.ue4ss then
            unbindable = unbindable + 1
            what = what .. "  [M.FKEY has a row and this UE4SS's Key table does not — the name "
                .. "cannot be bound in this session whatever the game has on it]"
        end
        n[status] = (n[status] or 0) + 1
        out[#out + 1] = string.format("keymap: %-20s %-18s %-8s %s",
            name, st.fkey or "-", status, what)
    end
    out[#out + 1] = string.format("keymap: %d free, %d taken by the game, %d held by PalForge, "
        .. "%d refused outright, %d unanswerable — \"free\" means no action in the game's key "
        .. "config uses it, which is not the same as \"the press will arrive\"",
        n.free or 0, n.game or 0, n.palforge or 0, n.refused or 0, n.unknown or 0)
    out[#out + 1] = string.format("keymap: %d row(s) over the union of M.FKEY (%d), UE4SS's live "
        .. "Key table (%d%s), and what PalForge holds or refuses. %d name(s) UE4SS can bind have "
        .. "no M.FKEY row and are unanswerable BECAUSE OF THIS TABLE rather than because of the "
        .. "game; %d name(s) in M.FKEY are not in this session's Key table at all.",
        #rows, known,
        live, (live == 0) and " — absent, so this run proves nothing about drift" or "",
        untranslated, unbindable)
    return out
end

return M
