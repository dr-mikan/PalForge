-- PalForge utils.json: minimal JSON/JSONC codec (pure Lua). Self-contained
-- generic primitive (no PalForge deps). Ported verbatim from the old runtime.
--
-- Decode supports: objects, arrays, strings (with escapes), numbers,
-- true/false/null, // and /* */ comments, trailing commas.
-- Encode is minimal + stable (object keys sorted for deterministic diffs); used by
-- utils.file (json_file backend) for state snapshots.
--
-- ⚠️ THREE THINGS CHANGED HERE FOR THE FORMAT-3 STORE. Two of them were LIVE DEFECTS that
-- had been silently losing or silently accepting a player's data, not missing features, and
-- both were reproduced by running this file before anything was edited.
--
-- 1. encodeTable READ THE VALUE BACK ON THE WRONG KEY, and lost it.
--    The object branch built its sorted key list with `tostring(k)` and then read the value
--    with that STRING: `t[1]` was looked up as `t["1"]` and came back nil, so it was written
--    as JSON null. Measured, before the fix:
--        encode({ [1] = "a", x = "b" })  ->  {"1":null,"x":"b"}
--    i.e. every integer-keyed entry in a table that ALSO has a string key disappeared on
--    every save. `state.slots = { "wood", count = 3 }` is exactly that shape and is exactly
--    what a pack would write. The same read also hit a sparse array
--    ({ [1]="a", [3]="b" } is not `isArray`, so it took the object branch too).
--    The fix keeps the original keys and sorts on their string form; only the SORT sees a
--    string now. After it, the same call answers {"1":"a","x":"b"} — the value survives, and
--    what the round trip cannot preserve is the integer-ness of the key, which is a property
--    of JSON and is why M.validate refuses the shape at the call site instead.
--
-- 2. M.decode ACCEPTED TRAILING GARBAGE. It parsed one value, skipped whitespace and returned
--    without ever asking whether it had reached the end of the input:
--        decode('{"a":1} garbage')  ->  a table, no error
--    A half-written file whose tail is another file's leftovers therefore decoded to a
--    plausible-looking value. It now verifies the parse consumed the whole input and returns
--    nil + "trailing input at byte N" when it did not.
--
-- 3. M.decode ran stripComments UNCONDITIONALLY, over machine-written files that cannot
--    contain a comment. stripComments is a character-at-a-time table.insert loop; measured on
--    this tree's own 500-record state file it was 10.82 ms of a 30.77 ms decode — 36%. The
--    public signature is unchanged: the strict parse runs FIRST, and stripComments is only
--    paid for when that fails, so a hand-edited JSONC file still decodes and a machine-written
--    one never walks its own bytes twice.
--
-- And one thing that is NEW rather than fixed: M.validate, the guard core/state runs over a
-- value at the call site that produced it (§5.3 of the format-3 spec). The encoder below is
-- deliberately LENIENT — a function, a NaN or an infinity becomes JSON null rather than an
-- error, because a flush that fails takes a whole pack's file down with it — and leniency
-- with nobody watching is the same silence defect twice. validate is the watcher: it walks a
-- value once, proportional to the VALUE and never to the file, and names the offending field
-- so the refusal lands on the pack's own line instead of in a log nobody reads.
local M = {}

local function stripComments(s)
    local out, i, n = {}, 1, #s
    local inStr = false
    while i <= n do
        local c = s:sub(i, i)
        if inStr then
            table.insert(out, c)
            if c == "\\" then
                table.insert(out, s:sub(i + 1, i + 1)); i = i + 1
            elseif c == '"' then
                inStr = false
            end
        elseif c == '"' then
            inStr = true; table.insert(out, c)
        elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
            while i <= n and s:sub(i, i) ~= "\n" do i = i + 1 end
            table.insert(out, "\n")
        elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
            i = i + 2
            while i <= n and not (s:sub(i, i) == "*" and s:sub(i + 1, i + 1) == "/") do i = i + 1 end
            i = i + 1
        else
            table.insert(out, c)
        end
        i = i + 1
    end
    return table.concat(out)
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- Parse one JSON value out of `s`. Returns the value AND the position just past it (after
-- trailing whitespace) — the second return is what makes the trailing-input check possible;
-- without it the parser could not tell "the file ended" from "the file went on".
local function decode(s)
    local pos = 1

    local function err(msg)
        error(string.format("JSON error at byte %d: %s", pos, msg), 0)
    end

    local function skipWs()
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- opening quote
        local buf = {}
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(buf) end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                if e == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    local cp = tonumber(hex, 16) or err("bad \\u escape")
                    -- encode BMP codepoint as UTF-8 (surrogate pairs unsupported)
                    if cp < 0x80 then
                        table.insert(buf, string.char(cp))
                    elseif cp < 0x800 then
                        table.insert(buf, string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40))
                    else
                        table.insert(buf, string.char(0xE0 + math.floor(cp / 0x1000),
                            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40))
                    end
                    pos = pos + 6
                else
                    table.insert(buf, ESCAPES[e] or err("bad escape \\" .. tostring(e)))
                    pos = pos + 2
                end
            else
                table.insert(buf, c); pos = pos + 1
            end
        end
        err("unterminated string")
    end

    local function parseNumber()
        local start = pos
        while pos <= #s and s:sub(pos, pos):match("[%d%+%-%.eE]") do pos = pos + 1 end
        return tonumber(s:sub(start, pos - 1)) or err("bad number")
    end

    local function parseObject()
        local obj = {}
        pos = pos + 1 -- {
        skipWs()
        if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skipWs()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end -- trailing comma
            if s:sub(pos, pos) ~= '"' then err("expected key string") end
            local key = parseString()
            skipWs()
            if s:sub(pos, pos) ~= ":" then err("expected ':'") end
            pos = pos + 1
            obj[key] = parseValue()
            skipWs()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1; return obj
            else err("expected ',' or '}'") end
        end
    end

    local function parseArray()
        local arr = {}
        pos = pos + 1 -- [
        skipWs()
        if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            skipWs()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end -- trailing comma
            table.insert(arr, parseValue())
            skipWs()
            local c = s:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1; return arr
            else err("expected ',' or ']'") end
        end
    end

    parseValue = function()
        skipWs()
        local c = s:sub(pos, pos)
        if c == "{" then return parseObject() end
        if c == "[" then return parseArray() end
        if c == '"' then return parseString() end
        if s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
        if s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        if s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
        if c:match("[%d%-]") then return parseNumber() end
        err("unexpected character '" .. tostring(c) .. "'")
    end

    local v = parseValue()
    skipWs()
    return v, pos
end

-- One decode attempt over exactly these bytes. Returns ok, value-or-message.
-- The boolean is separate from the value because JSON `null` decodes to nil and a bare
-- `if v then` would report a legitimate null as a parse failure.
local function attempt(s)
    local ok, v, pos = pcall(decode, s)
    if not ok then return false, tostring(v) end
    if pos <= #s then
        -- Name the byte AND show what is sitting there: "trailing input at byte 8" alone has
        -- sent a reader looking for a syntax error when the real story was a second document
        -- appended to the first by a torn write.
        return false, string.format("trailing input at byte %d (%q)", pos, s:sub(pos, pos + 23))
    end
    return true, v
end

---Decode JSON (or JSONC). Returns the value, or nil + an error message.
---
---STRICT FIRST. A file this tree wrote cannot contain a comment, so the common path never
---runs stripComments at all — that loop was measured at 36% of a 500-record decode. Only when
---the strict parse refuses is the comment-stripped text tried, which is what keeps a
---hand-edited JSONC config decoding exactly as it always did.
---
---Note that a document consisting of the literal `null` decodes to nil WITH NO ERROR, which
---is indistinguishable from a caller's own nil unless the error return is checked. That was
---already true and is unchanged; utils/file/json_file.lua is the one caller that cares and it
---checks.
---@param text string
---@return any|nil value
---@return string? err
function M.decode(text)
    if type(text) ~= "string" then
        return nil, "decode expects a string, got " .. type(text)
    end
    local ok, v = attempt(text)
    if ok then return v end
    local strictErr = v
    local ok2, v2 = attempt(stripComments(text))
    if ok2 then return v2 end
    -- Both refused. Lead with the STRICT message because it names a byte offset into the real
    -- file — the stripped text has different offsets and pointing a reader at a byte that does
    -- not exist in the file they are looking at is worse than saying nothing.
    if v2 ~= strictErr then
        return nil, strictErr .. " (and with comments stripped: " .. tostring(v2) .. ")"
    end
    return nil, strictErr
end

-- ---- encode (used by utils.file json_file backend for state snapshots) ----
-- Minimal, stable JSON encoder. Object keys are sorted for deterministic diffs.
-- A table is treated as an array when it is empty or has a contiguous 1..#t
-- integer key range; otherwise as an object (string keys).
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
              ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }

local function encodeString(s)
    return '"' .. tostring(s):gsub('[%z\1-\31"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
        n = n + 1
    end
    return n == #t
end

local encodeValue

local function encodeTable(t, out)
    if next(t) == nil then table.insert(out, "{}"); return end
    if isArray(t) then
        table.insert(out, "[")
        for i = 1, #t do
            if i > 1 then table.insert(out, ",") end
            encodeValue(t[i], out)
        end
        table.insert(out, "]")
    else
        -- THE ORIGINAL KEYS, kept. Only the ORDERING looks at their string form; the value is
        -- read back on the key pairs() handed over, which is the whole of defect (1) at the
        -- top of this file. `str` is built once so tostring is called n times rather than the
        -- O(n log n) times a comparator that stringified inline would cost.
        local keys, str, n = {}, {}, 0
        for k in pairs(t) do n = n + 1; keys[n] = k; str[k] = tostring(k) end
        table.sort(keys, function(a, b)
            local sa, sb = str[a], str[b]
            -- Two DIFFERENT keys can share a string form (1 and "1"). JSON has one namespace
            -- for object keys, so that document has a duplicate key whichever order we pick —
            -- M.validate refuses the shape rather than letting it get this far. The type
            -- tiebreak is here only so the sort is total and the output is still deterministic
            -- if it ever does.
            if sa == sb then return type(a) < type(b) end
            return sa < sb
        end)
        table.insert(out, "{")
        for i = 1, n do
            local k = keys[i]
            if i > 1 then table.insert(out, ",") end
            table.insert(out, encodeString(str[k]))
            table.insert(out, ":")
            encodeValue(t[k], out)
        end
        table.insert(out, "}")
    end
end

encodeValue = function(v, out)
    local tv = type(v)
    if v == nil then table.insert(out, "null")
    elseif tv == "boolean" then table.insert(out, tostring(v))
    elseif tv == "number" then
        -- avoid "1e+20"/NaN surprises; integers stay integer-formatted
        if v ~= v or v == math.huge or v == -math.huge then table.insert(out, "null")
        elseif v % 1 == 0 then table.insert(out, string.format("%d", v))
        else table.insert(out, tostring(v)) end
    elseif tv == "string" then table.insert(out, encodeString(v))
    elseif tv == "table" then encodeTable(v, out)
    else table.insert(out, "null") end
end

-- Returns a JSON string, or nil + error.
-- DELIBERATELY LENIENT, and M.validate below is the reason that is safe: a function, a NaN or
-- an infinity is written as null rather than raising, because this runs inside a flush that
-- covers a whole pack's file and one bad field must not cost the other 499 records. What must
-- not happen is that the pack never hears about it — that is validate's job, at the call site.
function M.encode(value)
    local out = {}
    local ok, err = pcall(encodeValue, value, out)
    if not ok then return nil, err end
    return table.concat(out)
end

-- ---- validate ----
--
-- THE GUARD THE STORE RUNS AT THE CALL SITE. `db.set(key, value)` and `inst:setDirty()` walk
-- the value through this ONCE and refuse with the reason at the pack's own line, instead of
-- letting the encoder quietly turn the mistake into null and discovering it a session later
-- when a player's chest is empty.
--
-- The nine refusals, and why each one is a refusal rather than a warning:
--
--   cycle              json.encode recurses until the stack goes. A DAG is fine and is NOT
--                      refused (the same table referenced twice simply encodes twice) —
--                      only a table that is its own ancestor.
--   value type         function / userdata / thread encode as null. Nothing can bring them
--                      back, so "saved" would be a lie with a timestamp.
--   non-finite number  NaN and ±inf encode as null. JSON has no spelling for either.
--   key type           a boolean or table key encodes as its tostring ("true",
--                      "table: 0x55e8…") and comes back as that string. The address is not
--                      even stable across sessions.
--   mixed keys         array entries beside named fields. See defect (1) at the top: they no
--                      longer VANISH, but JSON objects have string keys, so `t[1]` comes back
--                      as `t["1"]` and the pack's own `ipairs` stops seeing it.
--   array gap          { [1]=…, [3]=… } is not an array by `isArray`, so it encodes as an
--                      object and its indices come back as strings, same as above.
--   depth              16. Deep enough for any state a building has ever kept here; a limit
--                      exists so a self-similar structure fails with a sentence rather than
--                      with a stack overflow inside a flush.
--   fields             4096 across the whole value.
--   bytes              64 KiB encoded. The limit is on ONE key, not on the file: the largest
--                      pack file this tree has ever produced is 26 KB in total.
--
-- Depth/fields/bytes are policy numbers rather than measurements and are exported as
-- M.LIMITS so the store, the tests and a future tuning pass all read the same table.
M.LIMITS = { depth = 16, fields = 4096, bytes = 64 * 1024 }

-- "a.b", "a.b[3]", 'a["odd key"]' — the path is what makes a refusal actionable. It is
-- RELATIVE to the value handed in, and the root is "": the caller owns the name of the thing
-- (a store key, `self.state`) and prefixes it.
local function childPath(path, k)
    if type(k) == "number" then return path .. "[" .. tostring(k) .. "]" end
    local s = tostring(k)
    if s:match("^[%a_][%w_]*$") then
        return (path == "") and s or (path .. "." .. s)
    end
    return path .. "[" .. string.format("%q", s) .. "]"
end

---Can `value` be saved and read back unchanged? Returns true, or false + the path of the
---offending field (relative to `value`, "" for the value itself) + an English clause about it.
---
---Cost is proportional to the VALUE, never to the file. The structural walk is one pass; the
---byte limit needs a real encoded length rather than an estimate, so a value that survives the
---walk is encoded once more here — a limit that reports a made-up number is worse than no
---limit, and the value is the thing a pack just handed over, not the 26 KB around it.
---@param value any
---@return boolean ok
---@return string? path
---@return string? reason
function M.validate(value)
    local L = M.LIMITS
    local open = {}     -- table -> the path at which it is CURRENTLY being walked
    local fields = 0

    local function walk(v, path, depth)
        local tv = type(v)
        if tv == "string" or tv == "boolean" or tv == "nil" then return nil end

        if tv == "number" then
            if v ~= v then return path, "is not a finite number (nan)." end
            if v == math.huge then return path, "is not a finite number (inf)." end
            if v == -math.huge then return path, "is not a finite number (-inf)." end
            return nil
        end

        if tv ~= "table" then
            return path, string.format("is a %s. Only strings, numbers, booleans, nil and "
                .. "tables of those can be saved.", tv)
        end

        if open[v] then
            return path, string.format("points back at %s. Saved state must be a tree.",
                open[v] == "" and "the value itself" or ("'" .. open[v] .. "'"))
        end
        if depth > L.depth then
            return path, string.format("is nested %d tables deep; the limit is %d.",
                depth, L.depth)
        end

        open[v] = path

        -- One pass over the keys, before any value is looked at: a table whose SHAPE cannot
        -- survive the round trip is refused as a whole rather than field by field.
        local ints, strs, maxInt = 0, 0, 0
        for k in pairs(v) do
            local tk = type(k)
            if tk == "number" and k % 1 == 0 and k >= 1 then
                ints = ints + 1
                if k > maxInt then maxInt = k end
            elseif tk == "string" then
                strs = strs + 1
            else
                open[v] = nil
                return path, string.format("has a %s key (%s). A saved table's keys must be "
                    .. "strings or array indices.", tk, tostring(k))
            end
        end

        if ints > 0 and strs > 0 then
            open[v] = nil
            return path, "mixes array entries with named fields; the array entries come back "
                .. "as the string keys \"1\", \"2\", … and ipairs stops seeing them. "
                .. "Use one or the other."
        end
        if ints > 0 and ints ~= maxInt then
            -- Name the first gap when the array is small enough to scan. A table with one
            -- entry at index 1e9 is not worth a billion iterations to describe precisely.
            local gap
            if maxInt <= L.fields then
                for i = 1, maxInt do if v[i] == nil then gap = i; break end end
            end
            open[v] = nil
            return path, string.format("is an array with a gap%s; a gapped array encodes as an "
                .. "object and its indices come back as strings.",
                gap and (" at index " .. gap) or "")
        end

        fields = fields + ints + strs
        if fields > L.fields then
            open[v] = nil
            return path, string.format("brings the value to %d fields; the limit is %d.",
                fields, L.fields)
        end

        for k, vv in pairs(v) do
            local p, r = walk(vv, childPath(path, k), depth + 1)
            if p then open[v] = nil; return p, r end
        end

        open[v] = nil
        return nil
    end

    local path, reason = walk(value, "", 1)
    if path then return false, path, reason end

    -- The size limit, on the bytes that would really be written. Safe to encode now and only
    -- now: the walk has already established there is no cycle to recurse into.
    local text, eerr = M.encode(value)
    if not text then
        return false, "", "could not be encoded: " .. tostring(eerr)
    end
    if #text > L.bytes then
        return false, "", string.format("is %.0f KiB encoded; the per-key limit is %d KiB.",
            #text / 1024, L.bytes / 1024)
    end
    -- HAND BACK THE TEXT WE ALREADY PRODUCED. The size limit can only be checked on the real
    -- encoded bytes, so this function always encodes; returning the result turns a caller's
    -- "validate, then encode" into "validate, then use what validate encoded". core/state's
    -- partition() was the second pass — a record's `state` went through the encoder twice on
    -- every flush, once to be measured and once to be written.
    --
    -- The extra return is the FOURTH value and every existing caller ignores it, so this changes
    -- nothing for anyone who does not want it: the contract is still `ok` first, then `path` and
    -- `reason` on failure. On failure `text` is nil, because there is nothing valid to hand on.
    return true, nil, nil, text
end

return M
