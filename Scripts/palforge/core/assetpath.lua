-- PalForge core.assetpath: the `<package>.<object>` string rules, in one place.
--
-- WHY THIS FILE EXISTS. `Package.Object` was implemented in core/mesh/assets.lua,
-- re-implemented by hand in core/icons.lua, and ABSENT from core/sound/native.lua — where
-- its absence had a live consequence: api/audio.lua's own documented example writes a
-- package-only `soundPath = "/Game/.../AKE_BGM_Title"`, which resolves to nothing and falls
-- through to the silent branch. The generated catalog uses the full form, so the catalog
-- route worked and the hand-written route in the docs did not.
--
-- A UE object path is `<package>.<object>`. Every path measured off this build carries the
-- tail, so `normalize` appends it when a caller wrote only the package:
-- `/Game/A/SK_X` -> `/Game/A/SK_X.SK_X`. It is a CONVENIENCE and the full form always wins,
-- because the tail is not always a repeat of the package name — `dumps/reflection/
-- 05_assets.txt:937` records `/Game/Pal/Model/Prop/Mug/Sm_Mug.SM_Mug`, whose package and
-- object differ in case.
--
-- Only the LAST segment is inspected, so a directory containing a dot cannot confuse it.
-- (core/mesh/assets.lua's loadClass tested `find(".", 1, true)` over the WHOLE path and
-- therefore left such a path package-only; that is the bug this module's single
-- implementation removes.)
--
-- This module is STRINGS ONLY. It touches no engine function and can be required from
-- anywhere, including a headless unit test. Resolving a path to a live UObject is the
-- loader's job (core/mesh/assets.load, core/sound/native, core/icons) — and class-checking
-- what comes back is core/uobject's.
local M = {}

---Is `path` a UE OBJECT path rather than a file on disk? Object paths are rooted at a mount
---point and always begin with "/" — "/Game/...", "/Engine/...", "/Script/...". A Windows OBJ
---path ("C:/mods/x.obj") never does, which is what lets one `model` field carry both and lets
---a backend say which one it was handed.
---@param path any
---@return boolean
function M.isObjectPath(path)
    return type(path) == "string" and path:sub(1, 1) == "/"
end

---Complete a package-only path to a full `<package>.<object>` object path, and leave an
---already-complete one alone. `/Game/A/SK_X` -> `/Game/A/SK_X.SK_X`.
---
---`suffix` (optional) is appended to the object half — pass "_C" for a blueprint generated
---class, so `/Game/A/ABP_X` -> `/Game/A/ABP_X.ABP_X_C`.
---
---A path that already carries an object half is returned VERBATIM (suffix included or not):
---a caller who wrote the full form has said something this function must not overrule.
---A non-string, or the empty string, comes back unchanged so a caller can pass a value
---through without a type test first.
---@param path string
---@param suffix string?
---@return string
function M.normalize(path, suffix)
    if type(path) ~= "string" or #path == 0 then return path end
    local last = path:match("([^/]+)$")
    if not last or last:find(".", 1, true) then return path end
    return path .. "." .. last .. (suffix or "")
end

---The PACKAGE half of an object path — `/Game/A/SK_X.SK_X` -> `/Game/A/SK_X`. A path with no
---object half is already a package path and comes back unchanged. This is the string
---`LoadAsset` wants when the object half is a generated class that does not exist yet.
---@param path string
---@return string
function M.packageOf(path)
    if type(path) ~= "string" or #path == 0 then return path end
    local dir, last = path:match("^(.*/)([^/]+)$")
    if not last then return path end
    local pkg = last:match("^([^.]+)%.")
    if not pkg then return path end
    return dir .. pkg
end

---The OBJECT half of an object path — `/Game/A/SK_X.SK_Y` -> `"SK_Y"`; nil when the path
---carries no object half.
---@param path string
---@return string?
function M.objectOf(path)
    if type(path) ~= "string" or #path == 0 then return nil end
    local last = path:match("([^/]+)$")
    if not last then return nil end
    return last:match("%.(.+)$")
end

return M
