-- PalForge core.uobject: the four questions every layer asks about a UObject, in one
-- place — is it live, what is it, what is its name, and what do I KEY A TABLE ON.
--
-- WHY THIS FILE EXISTS. Three of these were private copies in three layers
-- (core/mesh/assets.lua, core/sound/native.lua, core/icons.lua), which is how the sound
-- loader ended up without the class check the mesh loader has — the check that turns "a
-- wrong-typed object marshalled into a typed native parameter", the shape that closed the
-- game once, into an English string.
--
-- THE FOURTH ONE IS THE IMPORTANT ONE, and it is not a convenience.
--
--   UE4SS MINTS A FRESH USERDATA WRAPPER PER LOOKUP. Two references to one UObject are
--   NOT the same Lua value, and Lua indexes a table by userdata IDENTITY, so no
--   metamethod can rescue `t[actor]`.
--
-- This tree measured that twice before it was believed — utils/items/init.lua's cheat
-- manager comparison, and core/mesh/skeletal.lua's mesh read-back — and then keyed five
-- per-actor tables on a handle anyway. Every consequence was silent: a detach that did
-- nothing, an attachOnce that stacked a second component nothing could ever destroy, a
-- skeletal "undo" that restored PalForge's own mesh, and a declared Building{ mesh = ... }
-- that set _meshPending once and never rendered.
--
--   local uo = require("palforge.core.uobject")
--   local k = uo.key(actor)              -- the ONLY thing a per-actor table may be keyed on
--   if k then byActor[k] = { actor = actor, comp = comp } end   -- keep the handle in the VALUE
--
-- A nil key means the object would not answer its own name (dead, or mid-teardown). A
-- caller must treat that as "no record", never as a key — `t[nil]` raises in Lua.
--
-- NOTHING HERE RAISES. Every engine touch is inside pcall: a stale handle can throw on the
-- IsValid call itself, and none of the callers may let that escape.
local M = {}

--=============================================================================
-- liveness
--=============================================================================

---Is `o` a live UObject?
---
---`UObject:IsValid()` on this UE4SS is a real liveness check rather than a null check
---(`is_object_in_global_unreal_object_map(ptr) && !ptr->IsUnreachable()`), so this genuinely
---protects the world.ready -> quit-to-title -> load-another-save path. The residual risk is
---ABA (a new UObject at a freed address), not plain staleness.
---@param o any
---@return boolean
function M.live(o)
    local ok, v = pcall(function() return o ~= nil and o.IsValid ~= nil and o:IsValid() end)
    return ok and v == true
end

--=============================================================================
-- identity
--=============================================================================

---The object's full name, or nil — `"BP_ChickenPal_C /Game/.../Level:PersistentLevel.BP_ChickenPal_C_2"`.
---
---This is the only string that identifies ONE UObject across two lookups. nil when the
---object will not answer (dead, or the call itself raised).
---@param o any
---@return string?
function M.fullName(o)
    local n
    pcall(function() n = o:GetFullName() end)
    if type(n) == "string" and #n > 0 then return n end
    return nil
end

---THE TABLE KEY for anything recorded per UObject. Same value as fullName; a separate name
---because the intent at a call site is different and greppable: `uo.key(actor)` says "this
---table is not keyed on a handle".
---@param o any
---@return string?
function M.key(o)
    return M.fullName(o)
end

---Do `a` and `b` name the same UObject? Two handles onto one object compare false with `==`,
---so this is the only comparison that means anything. False when either will not answer,
---because "unreadable" is not "equal".
---@param a any
---@param b any
---@return boolean
function M.same(a, b)
    local ka = M.fullName(a)
    if not ka then return false end
    return ka == M.fullName(b)
end

--=============================================================================
-- class
--=============================================================================

---An object's class chain as short class names, leaf first — for a USkeletalMesh:
---`{ "SkeletalMesh", "SkinnedAsset", "StreamableRenderAsset", "Object" }`.
---
---This is the GetSuperStruct walk core/signature.lua already uses to find a UFunction on a
---native ancestor, and test/cases/player.lua records it as proved in game. Bounded at 12 so
---a cycle cannot hang the caller; fail-soft, so whatever was readable before a step failed is
---what comes back and an engine that answers nothing returns an empty list.
---@param obj any
---@return string[]
function M.classChain(obj)
    local out = {}
    if not M.live(obj) then return out end
    local k; pcall(function() k = obj:GetClass() end)
    local depth = 0
    while M.live(k) and depth < 12 do
        local ok, name = pcall(function() return k:GetFName():ToString() end)
        if not (ok and type(name) == "string" and #name > 0) then break end
        out[#out + 1] = name
        local parent
        pcall(function() parent = k:GetSuperStruct() end)
        if not M.live(parent) then pcall(function() parent = k.SuperStruct end) end
        k, depth = parent, depth + 1
    end
    return out
end

---The object's own class name ("PalMonsterCharacter"), or nil.
---@param obj any
---@return string?
function M.className(obj)
    return (M.classChain(obj))[1]
end

---Is `obj` an instance of `className` (or of anything deriving from it)? `className` is the
---SHORT UE name with no U/A prefix: "StaticMesh", "SkinnedAsset", "AkAudioEvent".
---
---A false here is only ever "the chain we could read does not contain it" — an object whose
---class will not answer returns an empty chain and therefore false, which is why callers
---treat it as a refusal to proceed rather than as proof of the wrong type.
---@param obj any
---@param className string
---@return boolean
function M.isA(obj, className)
    for _, name in ipairs(M.classChain(obj)) do
        if name == className then return true end
    end
    return false
end

---A one-line description for a log: `"SkeletalMesh /Game/.../SK_PinkCat.SK_PinkCat"`.
---@param obj any
---@return string
function M.describe(obj)
    if not M.live(obj) then return "(nothing)" end
    return string.format("%s %s", M.className(obj) or "?", tostring(M.fullName(obj) or "?"))
end

return M
