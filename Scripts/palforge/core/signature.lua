-- palforge/core/signature.lua — call a game UFunction only when its declaration has been
-- checked, and record which evidence the check rested on.
--
-- WHY THIS EXISTS. Calling a UFunction with an argument list that does not match its
-- declaration has two very different outcomes, and only one of them is survivable:
--
--   wrong ARITY  ->  UE4SS refuses before binding anything and raises a normal Lua error.
--                    pcall catches it. This is how we learned AddItem_ServerInternal takes
--                    six parameters where PalForge passed four.
--   wrong TYPE   ->  UE4SS faults inside its own argument marshalling. The process dies.
--                    pcall does NOT see it. `inv:CountItemNum("Wood")` — a bare Lua string
--                    where an FName was declared — closed Palworld mid-probe and cost a
--                    whole run of findings.
--
-- So a wrong type is not a bug to be handled; it is a bug that cannot be handled. The only
-- defence is to not make the call. Everything here exists to decide that question before
-- the call rather than after it.
--
-- WHERE THE EXPECTED TYPES COME FROM. `dumps/cxx/` is UE4SS's own CXXHeaderDump of this game
-- install — 1579 headers, every UFunction with its real C++ signature. It is generated from
-- the shipping binary, not written by hand and not inferred from a name list, which makes it
-- the strongest declaration source in this tree. Its one weakness is age: it is a snapshot,
-- and a game patch can move a signature underneath it. Every caller therefore names both the
-- expected shape AND where it read it, and this module confirms the shape against the LIVE
-- object whenever the running UE4SS build lets it.
--
-- THE THREE EVIDENCE LEVELS, which every call reports:
--
--   "declared"  the live UFunction's parameter list was walked and matches. Nothing is
--               being trusted; the running game agreed. This is the goal.
--   "present"   the function EXISTS on the live class under this exact name and arity could
--               not be walked (a UFunction is a UObject in UE4SS's Lua API, and property
--               iteration on one is not part of the documented surface, so on some builds
--               there is nothing to read). The types are the dump's. The call proceeds.
--   "absent"    no function of that name on the live class. The call is NOT made.
--
--   local sig = require("palforge.core.signature")
--   local ok, ret, how = sig.call(cm, "GetItem", { "NameProperty", "IntProperty" },
--                                 FName("Wood"), 5)
--
-- "present" is a real judgement, not a shrug, and it is only defensible for the shape these
-- calls actually have. Every current caller passes an FName first and plain integers after —
-- the same marshalling PalForge already performs successfully on this build every time
-- utils.items unlocks a technology through cm:UnlockOneTechnology(FName(...)). What is NOT
-- acceptable under "present" is a struct, an out-param, a delegate or an enum argument: those
-- are where marshalling actually breaks. Callers keep to scalars, and this module refuses a
-- shape it was not designed to be confident about (see UNVERIFIABLE_KINDS).
local log = require("palforge.utils.log").scope("signature")

local M = {}

-- Property class names that this module will NOT wave through on "present" evidence. Passing
-- one of these on an unread declaration is how a native marshalling fault happens; if a caller
-- needs one, the live walk has to succeed first.
-- ObjectProperty is deliberately NOT in this list. Handing a live UObject to a parameter
-- declared as a UObject pointer is the most ordinary call UE4SS Lua makes — the userdata IS
-- the pointer, there is no layout to get wrong and nothing to convert. The kinds below are the
-- ones that marshal by VALUE or by layout, where a mismatch writes through a bad shape; that
-- is the failure mode worth refusing an unread declaration over.
local UNVERIFIABLE_KINDS = {
    StructProperty = true, ArrayProperty = true, MapProperty = true, SetProperty = true,
    DelegateProperty = true, MulticastDelegateProperty = true, TextProperty = true,
}

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o.IsValid and o:IsValid() end)
    return ok and v == true
end

local function fname(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and type(s) == "string" and s or nil
end

--=============================================================================
-- finding the function
--=============================================================================

-- ForEachFunction is the documented way to enumerate a UStruct's functions, and a UClass is a
-- UStruct — so this is the route that is specified to work rather than the one that happened
-- to. It also answers the question the caller actually has ("does this build declare this
-- name") without depending on a GetFunctionByName that is absent from the Lua API docs.
local function functionOnClass(cls, fnName)
    if not valid(cls) then return nil end
    local found
    local ok = pcall(function()
        cls:ForEachFunction(function(fn)
            if fname(fn) == fnName then found = fn; return true end
        end)
    end)
    if ok and valid(found) then return found end
    return nil
end

---Find the UFunction `fnName` reachable from `owner`, which may be a live object, a CDO or a
---UClass. Returns the function and a short note on how it was reached, or nil.
---
---The chain walk matters: a cheat manager instance is a BP subclass, and the function is
---declared on a native ancestor several links up.
---@return userdata? fn, string? how
function M.find(owner, fnName)
    if not valid(owner) then return nil end

    -- owner is already a class/struct
    local fn = functionOnClass(owner, fnName)
    if fn then return fn, "ForEachFunction(owner)" end

    local cls; pcall(function() cls = owner:GetClass() end)
    local k, depth = cls, 0
    while valid(k) and depth < 12 do
        fn = functionOnClass(k, fnName)
        if fn then
            return fn, depth == 0 and "ForEachFunction(GetClass())"
                or string.format("ForEachFunction(super chain [%d])", depth)
        end
        local parent; pcall(function() parent = k:GetSuperStruct() end)
        if not valid(parent) then pcall(function() parent = k.SuperStruct end) end
        k, depth = parent, depth + 1
    end

    -- Member access: reading the name off a live object yields the bound UFunction. Measured
    -- on this build (inv.CountItemNum answered a UFunction userdata), and it is the only route
    -- that works when the class walk is unavailable.
    local member; pcall(function() member = owner[fnName] end)
    if type(member) == "userdata" then return member, "member access" end

    return nil
end

--=============================================================================
-- reading the declaration
--=============================================================================

-- Property class names that mean the same thing at the argument boundary. UE spells an enum
-- two ways — ByteProperty for a legacy `enum`, EnumProperty for an `enum class` — and which one
-- a given UFunction declares is not something a caller can know or should have to. The first
-- live run refused three correct calls over exactly this (AddEquipWaza, RemoveEquipWaza,
-- GetExecutionStatus all declare EnumProperty where the dump's `enum class` reads as a byte),
-- and refusing a call whose argument marshals identically is a false alarm, not safety.
local EQUIVALENT = {
    ByteProperty = { EnumProperty = true },
    EnumProperty = { ByteProperty = true },
    -- An FString and an FName are NOT equivalent and never will be: that confusion is the one
    -- that faults natively and closed the game.
}

local function sameKind(want, got)
    if want == got then return true end
    local also = EQUIVALENT[want]
    return also ~= nil and also[got] == true
end

-- The property's class name ("NameProperty", "IntProperty", ...). UE4SS spells this different
-- ways on different builds, so try each and take the first that yields a string rather than
-- assuming one shape.
local function kindOf(p)
    local ok, v = pcall(function() return p:GetClass():GetFName():ToString() end)
    if ok and type(v) == "string" and #v > 0 then return v end
    ok, v = pcall(function() return p:GetClass():GetName() end)
    if ok and type(v) == "string" and #v > 0 then return v end
    return nil
end

---Walk a UFunction's declared parameters. Returns a list of { name, kind } in declared order,
---or nil when this UE4SS build will not iterate a UFunction's properties (which is not an
---error — UFunction is documented as a UObject here, not a UStruct).
---@return table[]?
function M.paramsOf(fn)
    if not valid(fn) then return nil end
    local out = {}
    local ok = pcall(function()
        fn:ForEachProperty(function(p)
            out[#out + 1] = { name = fname(p) or "?", kind = kindOf(p) or "?" }
        end)
    end)
    if not ok or #out == 0 then return nil end
    return out
end

--=============================================================================
-- the guarded call
--=============================================================================

---Check `fnName` on `owner` against `expected`, a list of property class names in declared
---order (the RETURN value, if any, is ignored — it trails the parameters and does not affect
---how arguments marshal).
---
---Returns the evidence level ("declared" / "present" / "absent"), the function, and a printable
---detail line. Nothing is called.
---@param expected string[]
---@return string level, userdata? fn, string detail
function M.check(owner, fnName, expected)
    local fn, how = M.find(owner, fnName)
    if not fn then
        return "absent", nil, fnName .. " is not declared on this build"
    end

    local params = M.paramsOf(fn)
    if not params then
        for _, kind in ipairs(expected) do
            if UNVERIFIABLE_KINDS[kind] then
                return "absent", fn, string.format(
                    "%s exists (%s) but declares a %s, and this build will not walk a "
                    .. "UFunction's properties — a non-scalar argument is not passed on an "
                    .. "unread declaration", fnName, how, kind)
            end
        end
        return "present", fn, string.format("%s exists (%s); parameter walk unavailable, so the "
            .. "argument types are dumps/cxx's", fnName, how)
    end

    -- The walk includes the return value, so compare only the leading arguments.
    local shape = {}
    for i, p in ipairs(params) do shape[i] = string.format("%s:%s", p.name, p.kind) end
    for i, kind in ipairs(expected) do
        local got = params[i]
        if not got then
            return "absent", fn, string.format("%s declares %d properties, fewer than the %d "
                .. "arguments expected — [%s]", fnName, #params, #expected, table.concat(shape, ", "))
        end
        if not sameKind(kind, got.kind) then
            return "absent", fn, string.format("%s parameter %d is %s, not the expected %s — [%s]",
                fnName, i, got.kind, kind, table.concat(shape, ", "))
        end
    end
    return "declared", fn, string.format("%s matches (%s) — [%s]", fnName, how, table.concat(shape, ", "))
end

---Call `owner:fnName(...)` only if `M.check` allows it.
---
---Returns ok, result, level. `ok` false with level "absent" means the call was REFUSED and the
---game was never touched — which is the whole point: a refusal costs a false, and the mistake
---it prevents costs the session.
---@param expected string[]  # property class names, in declared order
---@return boolean ok, any result, string level
function M.call(owner, fnName, expected, ...)
    local level, fn, detail = M.check(owner, fnName, expected)
    if level == "absent" then
        log.err(string.format("refused %s: %s", fnName, detail))
        return false, nil, level
    end

    -- An ObjectProperty parameter takes a live engine object and nothing else. A plain Lua
    -- table cannot be pushed into one, and UE4SS reports that as a bare "[push_objectproperty]
    -- Error" from inside the call — which the first live run produced three times, from tests
    -- that pass {} on purpose to prove the no-world path is fail-soft. It is caught, but the
    -- message names neither the argument nor the reason. Checking here turns it into a sentence.
    for i, kind in ipairs(expected) do
        if kind == "ObjectProperty" then
            local arg = select(i, ...)
            if arg ~= nil and type(arg) ~= "userdata" then
                log.warn(string.format("refused %s: argument %d must be a live engine object, got %s",
                    fnName, i, type(arg)))
                return false, nil, "absent"
            end
        end
    end

    -- Call through `owner:fnName(...)`, NOT through the UFunction object the check just found.
    -- A UFunction's __call needs a context argument only when it was obtained without one, and
    -- M.find reaches it four different ways — so the one call form whose context is never in
    -- doubt is the ordinary member call, which is also the form every working call in this tree
    -- already uses. The found function is for READING the declaration, not for invoking it.
    local args = table.pack(...)
    local ok, ret = pcall(function()
        return owner[fnName](owner, table.unpack(args, 1, args.n))
    end)
    if not ok then
        -- Arity and other binding refusals land here. They are survivable and worth the detail:
        -- the message names the count the engine wanted, which is the fact a fix needs.
        log.err(string.format("%s raised: %s  [%s]", fnName, tostring(ret), detail))
        return false, nil, level
    end
    return true, ret, level
end

return M
