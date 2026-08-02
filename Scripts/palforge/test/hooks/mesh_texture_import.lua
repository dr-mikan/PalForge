-- test/hooks/mesh-texture-import-live — THE CALL THAT HAS NEVER ONCE BEEN MADE.
--
-- plan/TODO.md Foundations / Assets / A-5, and the Closed item `mesh-texture-import` it rests
-- on. Those two say the same thing from opposite ends and neither has been in a game:
--
--   Closed / mesh-texture-import   `Engine.hpp:14694` declares
--       UTexture2D* ImportFileAsTexture2D(UObject* WorldContextObject, FString Filename)
--     on UKismetRenderingLibrary. Both halves of the old unknown are answered BY THE DUMP: the
--     world context is a plain UObject* (so an actor qualifies) and the path is an FString — an
--     ordinary Lua string, NOT the FName shape that kills the process. The signature is settled.
--     Nothing has ever called it.
--   A-5 / Still owed                `core/mesh/base/renderer.lua:431` gained a positives-only,
--     weak-valued cache keyed on the exact absolute path, because `resolveTexture` is reached on
--     EVERY attach (writeMaterial calls it once for `def.texture` and once per `params.texture`
--     entry), so `Pal{ mesh = { texture = ".../body.png" } }` imported a fresh UTexture2D for
--     every pal that spawned, tracked by nothing and destroyed by nothing. *"the new cache is
--     unobserved along with the capability it caches."*
--
-- SO THE SECOND HALF IS THE POINT. Anyone can print a signature; what has never been seen is a
-- UTexture2D coming back, and then NOT coming back a second time because the cache answered.
--
-- HOW EACH CLAIM IS MADE DECIDABLE, because "it worked" is not a measurement:
--
--   the import        a non-nil return whose class chain contains Texture2D, with its full name
--                     printed — an imported texture lands in a transient package and saying
--                     WHERE it landed is half of knowing what came back.
--   the cache         `rawequal` on the two returned Lua values. This is the one place in this
--                     tree where rawequal on a UObject wrapper is the RIGHT test and A-1 does not
--                     apply: the cache stores the Lua value it was handed, so a cache hit returns
--                     the identical value BY CONSTRUCTION, while a re-import can only ever return
--                     a fresh one. (A-1 is about comparing two INDEPENDENT lookups, which is a
--                     different question and still answered with uo.same.)
--   positives-only    the import is attempted BEFORE the file exists and again after it is
--                     written. A success after a failure is the retry rule the sweep landed,
--                     stated as an observation rather than as a code reading.
--   the real seam     the last call goes through `Renderer.resolveTexture`, not importTexture —
--                     because resolveTexture is what writeMaterial calls on every attach, and a
--                     cache the actual call site does not reach would be a cache in name only.
--
-- ⚠️ WHAT THIS ALLOCATES, AND NOTHING TAKES IT BACK. A successful run creates ONE UTexture2D in
-- the running process. There is no destroy: UE4SS's Lua layer has no AddToRoot, no FGCObject and
-- no way to destroy a UObject, `Renderer.destroyComponent` is for components and does not apply,
-- and the cache is weak-VALUED — which, as `assets.lua`'s corrected comment says, does not
-- shorten a texture's life, it only lets a dead entry evaporate. The texture is the engine's from
-- the moment it exists and it goes when the engine decides. One 8×8 texture is nothing; a loop
-- calling this thousands of times is exactly the leak A-5 is about, and that is why the cache
-- exists.
--
-- `writes = false`, precisely: it imports into MEMORY and does not touch the save, the player,
-- any actor or any component. It does write ONE FILE — an 82-byte 8×8 PNG next to this hook, so
-- that "the import failed" can never mean "there was no file" — and deletes nothing of yours.
local hooks = require("palforge.test.hooks")

-- This file's own directory, resolved from its own source path at LOAD time — the same one-liner
-- utils/file/json_file.lua uses to find <Mods>/PalForge/state/, and correct in game for the same
-- reason (UE4SS's package.path is absolute, so `source` is an absolute path).
--
-- Deliberately not `utils.file.packDir`. Its NO-ARGUMENT form is the one every caller in the tree
-- uses and it walks OUT of Scripts/palforge/ to find the pack — this file is under
-- Scripts/palforge/, so that walk would step past it and answer with somebody else's frame or
-- nothing. `packDir(1)` from inside `run` would be right (it counts frames correctly; the `+1`
-- lands where it does because `return frameDir(n + 1)` is a proper tail call and packDir's own
-- frame is gone by then), but it has to be called from the right function to stay right, where
-- this is fixed by construction: it is THIS file asking where THIS file is.
local HERE = ((type(debug) == "table" and debug.getinfo and debug.getinfo(1, "S").source) or "")
    :match("@?(.*[\\/])") or ""

local PNG_NAME     = "pf_texture_probe_8x8.png"
local ABSENT_NAME  = "pf_texture_probe_absent.png"   -- never created; the "no file" control

-- An 8×8 magenta/black checkerboard, 8-bit truecolour, non-interlaced. 82 bytes, written out as
-- decimal escapes so this file stays plain ASCII and `luac5.4 -p` clean. Magenta on purpose: it
-- is the colour a reader recognises as "a placeholder that arrived", and 8×8 is a power of two,
-- which removes NPOT from the list of things a failed import could be blamed on.
local PNG =
   "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000"
.. "\000\000\008\000\000\000\008\008\002\000\000\000\075\109\041\220\000"
.. "\000\000\025\073\068\065\084\120\218\099\248\207\240\159\129\129\001"
.. "\147\100\192\042\250\031\010\007\157\014\000\233\048\063\193\165\157"
.. "\078\160\000\000\000\000\073\069\078\068\174\066\096\130"

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

hooks.declare{
    id    = "mesh-texture-import-live",
    item  = "Closed 2026-08-02 — 7 pass; ImportFileAsTexture2D returns a real Texture2D",
    needs = { world = true, player = true },
    desc  = "call ImportFileAsTexture2D for the first time ever, then call it again for the same "
         .. "path and say whether the new cache answered instead of re-importing",
    run = function(h)
        local Renderer = require("palforge.core.mesh.base.renderer")
        local uo       = require("palforge.core.uobject")
        local sig      = require("palforge.core.signature")
        local support  = require("palforge.test.support")

        --------------------------------------------------------------------
        h:section("[1] the world context, and what the build declares")
        --------------------------------------------------------------------
        -- The first argument is a WorldContextObject and the dump settles that it is a plain
        -- UObject*, so the player pawn qualifies — and the pawn is what writeMaterial ends up
        -- passing in production (it hands the ACTOR being dressed).
        local ctx = support.player()
        if not uo.live(ctx) then
            h:fail("no live player pawn, so there is no world context object to pass. The gate "
                .. "should have caught this; if it did not, the pawn went away between the check "
                .. "and now.")
            return
        end
        h:value("world context", uo.describe(ctx))

        local lib
        pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end)
        if not uo.live(lib) then
            h:fail("/Script/Engine.Default__KismetRenderingLibrary did not resolve, so "
                .. "ImportFileAsTexture2D cannot be reached at all and NOTHING about A-5 was "
                .. "measured. Renderer.importTexture takes the same path and would report "
                .. "\"no KismetRenderingLibrary\" for the same reason. That would be a finding "
                .. "about the CDO lookup, not about the import.")
            return
        end
        h:pass("the KismetRenderingLibrary CDO resolved: %s", uo.fullName(lib))
        -- The declaration, printed and NOT called. This is the line the Closed item read out of
        -- dumps/cxx/Engine.hpp; here it is off the running binary.
        h:value("ImportFileAsTexture2D declaration", sig.describe(lib, "ImportFileAsTexture2D"))
        h:note("`declared` means the live parameter list matches { ObjectProperty, StrProperty }, "
            .. "which is what core/signature checks before it will fire. It says nothing about "
            .. "the import succeeding — that is blocks [3] and [4].")

        --------------------------------------------------------------------
        h:section("[2] the file — because \"it failed\" must never mean \"there was none\"")
        --------------------------------------------------------------------
        local override = _G.PALFORGE_HOOK_TEXTURE_PATH
        local path, wroteIt
        if type(override) == "string" and #override > 0 then
            path = override
            h:value("path (from _G.PALFORGE_HOOK_TEXTURE_PATH)", path)
            local n = fileSize(path)
            if not n then
                h:fail("the override path is not readable from this process, so the import below "
                    .. "could only ever fail for a reason that has nothing to do with A-5. Set "
                    .. "_G.PALFORGE_HOOK_TEXTURE_PATH to an absolute path to a PNG that exists, "
                    .. "or unset it and let this hook write its own.")
                return
            end
            h:value("size", n .. " bytes")
            h:note("an operator path is used AS IT IS FOUND: block [3]'s no-file control still "
                .. "runs against a path this hook knows is absent, but the retry-after-miss half "
                .. "is skipped, because deleting somebody's file to prove a cache rule is not a "
                .. "trade this hook will make.")
        else
            path = HERE .. PNG_NAME
            h:value("path (written by this hook)", path)
            if HERE == "" then
                h:fail("this file's own directory could not be resolved from debug.getinfo, so "
                    .. "there is nowhere to put a PNG. Set _G.PALFORGE_HOOK_TEXTURE_PATH to an "
                    .. "absolute path to a PNG and run it again.")
                return
            end
            os.remove(path)   -- so block [3] is a genuine miss and not last run's leftover
            wroteIt = true
        end

        --------------------------------------------------------------------
        h:section("[3] the control: a path with no file behind it")
        --------------------------------------------------------------------
        -- Two things at once. It shows what a FAILED import says (and the two reasons are
        -- different findings: "did not fire" is core/signature refusing on the declaration, and
        -- "returned nothing importable" is the call having really run), and — when this hook owns
        -- the file — it is the miss that block [4] then contradicts.
        local absent = HERE .. ABSENT_NAME
        if fileSize(absent) then
            h:note("%s unexpectedly exists; the no-file control is skipped rather than deleting "
                .. "a file this hook did not create.", absent)
        else
            local t0, why0 = Renderer.importTexture(ctx, absent)
            h:value("importTexture(<a path with no file>)",
                t0 == nil and ("nil — " .. tostring(why0)) or uo.describe(t0))
            if t0 ~= nil then
                h:fail("something came back for a path that has no file behind it. Whatever that "
                    .. "is, it is not this PNG, and every positive result below is suspect.")
            elseif tostring(why0):find("did not fire", 1, true) then
                h:note("core/signature REFUSED the call, so the game was never touched. That is a "
                    .. "statement about the DECLARATION on this build and it makes block [4] "
                    .. "unlikely to succeed — read the [signature] line above; it is the finding.")
            else
                h:pass("the call really ran and the engine imported nothing, which is the correct "
                    .. "answer for a path with no file. The route is reachable.")
            end
        end
        if wroteIt then
            local ok, err = pcall(function()
                local f = assert(io.open(path, "wb"))
                f:write(PNG)
                f:close()
            end)
            if not ok then
                h:fail("could not write the probe PNG to %s (%s). The mod directory may be "
                    .. "read-only. Set _G.PALFORGE_HOOK_TEXTURE_PATH to a PNG that exists and run "
                    .. "it again.", path, tostring(err))
                return
            end
            local n = fileSize(path)
            h:value("wrote the probe PNG", string.format("%s bytes at %s", tostring(n), path))
            if n ~= #PNG then
                h:fail("the file on disk is %s bytes and the embedded image is %d. Something "
                    .. "rewrote it — a text-mode write would corrupt a PNG.", tostring(n), #PNG)
                return
            end
        end

        --------------------------------------------------------------------
        h:section("[4] the import — the first time this call has ever been made")
        --------------------------------------------------------------------
        local t1, why1 = Renderer.importTexture(ctx, path)
        if t1 == nil then
            h:fail("ImportFileAsTexture2D produced nothing for a file that is on disk and %d "
                .. "bytes long: %s. THAT IS THE MEASUREMENT — A-4's table says the pack-supplied "
                .. "texture route is \"Unproven\", and this is the run that would move it to a "
                .. "flat No. Paste this block: the declaration in [1], the reason string here, "
                .. "and the [signature] / [mesh] lines around them.",
                fileSize(path) or -1, tostring(why1))
            return
        end
        h:pass("A TEXTURE CAME BACK. ImportFileAsTexture2D has been called for the first time in "
            .. "this tree's history and it answered.")
        h:value("what came back", uo.describe(t1))
        h:value("class", tostring(uo.className(t1)))
        h:value("full name (where the engine put it)", tostring(uo.fullName(t1)))
        h:value("class chain", table.concat(uo.classChain(t1) or {}, " : "))
        h:value("uo.isA(tex, \"Texture2D\")", tostring(uo.isA(t1, "Texture2D")))
        h:value("uo.isA(tex, \"Texture\")", tostring(uo.isA(t1, "Texture")))
        if not uo.isA(t1, "Texture") then
            h:fail("the returned object is not a UTexture, so SetTextureParameterValue — which "
                .. "takes a UTexture* (Engine.hpp:17574) — would be handed the wrong type. That "
                .. "is the marshalling shape core/mesh/assets.lua exists to refuse, and "
                .. "Renderer.writeMaterial would be pushing it on every attach.")
        else
            h:pass("it satisfies the UTexture* that SetTextureParameterValue declares, so the "
                .. "value is usable at the seam it was imported for.")
        end
        if wroteIt then
            h:pass("AND IT SUCCEEDED AFTER THE MISS IN [3]. The path cache is positives-only and "
                .. "really does retry: a file that was not there yet does not become "
                .. "unimportable for the rest of the session, which was the rule this sweep "
                .. "changed everywhere in this layer.")
        end

        --------------------------------------------------------------------
        h:section("[5] THE POINT: does the cache answer the second time")
        --------------------------------------------------------------------
        local t2 = Renderer.importTexture(ctx, path)
        if t2 == nil then
            h:fail("the SECOND call for the same path produced nothing while the first produced a "
                .. "texture. That is worse than no cache: the same input answered two different "
                .. "ways in the space of a millisecond.")
            return
        end
        local sameValue = rawequal(t1, t2)
        h:value("rawequal(first, second)", tostring(sameValue))
        h:value("uo.key(first)", tostring(uo.key(t1)))
        h:value("uo.key(second)", tostring(uo.key(t2)))
        if sameValue then
            h:pass("THE CACHE ANSWERED. The second call returned the identical Lua value, which "
                .. "only the cache can do — a re-import returns a fresh one every time. A-5's "
                .. "fix is live: `Pal{ mesh = { texture = ... } }` imports once per path per "
                .. "session instead of once per pal that spawns.")
        else
            h:fail("THE CACHE DID NOT ANSWER: two calls for one path returned two different Lua "
                .. "values, so the second went through ImportFileAsTexture2D again. Either the "
                .. "weak-valued table dropped the entry between the two calls (possible in "
                .. "principle, and this run holds a strong reference in `t1`, so it should not "
                .. "be), or the key does not match — the cache is keyed on the EXACT path string. "
                .. "%s", uo.key(t1) == uo.key(t2)
                    and "The two objects have the same full name, so the engine may be answering "
                     .. "with one asset through two wrappers; that would still mean the import "
                     .. "ran twice, which is what A-5 is about."
                    or "The two objects have DIFFERENT full names, so a second UTexture2D really "
                     .. "was created — the per-attach leak A-5 describes, unfixed.")
        end

        --------------------------------------------------------------------
        h:section("[6] the seam production actually uses")
        --------------------------------------------------------------------
        -- writeMaterial never calls importTexture; it calls resolveTexture, which dispatches on
        -- whether the reference is a UE object path. A cache the real call site does not reach
        -- would be a cache in name only, so this is asked separately.
        local t3, why3 = Renderer.resolveTexture(ctx, path)
        h:value("resolveTexture(<the same absolute path>)",
            t3 ~= nil and uo.describe(t3) or ("nil — " .. tostring(why3)))
        if t3 ~= nil and rawequal(t3, t1) then
            h:pass("resolveTexture dispatched a non-object path to importTexture AND got the "
                .. "cached texture — which is the exact line writeMaterial runs once for "
                .. "`def.texture` and once per `params.texture` entry on EVERY attach.")
        elseif t3 == nil then
            h:fail("resolveTexture answered nothing for a path importTexture answered for. The "
                .. "dispatch (assets.isObjectPath) is sending this string to the /Game branch.")
        else
            h:fail("resolveTexture produced a DIFFERENT value from the cached import, so the "
                .. "production call site is not sharing the cache the direct call just used.")
        end

        --------------------------------------------------------------------
        h:section("[7] what this run left in the process")
        --------------------------------------------------------------------
        h:note("ONE UTexture2D was created and nothing destroys it. There is no destroy call for "
            .. "a UObject in UE4SS's Lua layer, PalForge has never pinned one (no AddToRoot, no "
            .. "FGCObject anywhere), and the cache's weak values only let a DEAD entry evaporate "
            .. "— they do not shorten the texture's life. It is the engine's now.")
        if wroteIt then
            h:note("The probe PNG is still at %s (82 bytes). It is deliberately left there: "
                .. "deploy.sh overwrites this directory, and a second run re-creates it anyway.",
                path)
        end
        h:note("WHAT TO WRITE IN plan/TODO.md: A-4's asset table says pack-supplied Texture is "
            .. "\"Unproven — ImportFileAsTexture2D is wired with the right signature and has "
            .. "never once been called\". After a run of this hook that sentence has an answer "
            .. "in it, and A-5's \"Still owed: unobserved\" is decided by block [5] alone.")
    end,
}
