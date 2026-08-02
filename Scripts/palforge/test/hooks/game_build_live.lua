-- test/hooks/game-build-live — WHICH FUNCTION ANSWERS WITH PALWORLD'S OWN BUILD STRING.
--
-- Scripts/main.lua asks the running game what build it is and records the answer in
-- env.gameBuildLive, so that a user who hits a broken call can tell "PalForge is broken" from
-- "the game moved". That read has NEVER BEEN RUN: no line in any log has ever printed
-- GetBuildVersion on this build, so which of the three candidates carries "v1.0.2.101103" — and
-- whether any of them does — is unknown, and main.lua says so in its own comment rather than
-- guessing. This hook is the run that settles it, and main.lua:101-103 names it by this id.
--
-- WHAT IS AT STAKE IS ONE COMPARISON. main.lua compares only GetBuildVersion against
-- env.gameBuild, and it compares the two strings' DIGIT RUNS rather than the strings, because
-- the live shape is unobserved: "v1.0.2.101103" and a branch string like
-- "++Pal+Release-1.0.2-CL-101103" both reduce to "1.0.2.101103". That looseness is deliberate
-- while nothing is measured — a false "they match" is a quiet no-op, where a false mismatch
-- would train every user to ignore the one line that matters. ONE run of this hook is what
-- allows that comparison to be tightened from a digit-run match to a real one.
--
--   dumps/cxx/Engine.hpp:14991  UKismetSystemLibrary::GetBuildVersion   FApp branch/CL string
--   dumps/cxx/Engine.hpp:14977  UKismetSystemLibrary::GetEngineVersion  the UNREAL version
--   dumps/cxx/Engine.hpp:14974  UKismetSystemLibrary::GetGameName       the project name
--
-- All three take no parameters, which is why they are called directly rather than through
-- core/signature: there is no argument list to get wrong, and a wrong-typed argument is the only
-- failure shape pcall cannot see.
--
-- THE READ IS DUPLICATED HERE ON PURPOSE. main.lua's readLiveBuild is a local in the mod's entry
-- point, which is not on the palforge.* require path and cannot be reached from a module; and
-- the hook wants all three raw values, where main.lua deliberately stops at the first one that
-- answers. What must stay in step between the two files is the CANDIDATE LIST and the unwrapping
-- rule, and both are restated below rather than referenced.
--
-- Reads nothing but three CDO functions. It writes no file, touches no save and mutates nothing
-- except env.gameBuildLive, which main.lua fills in with the same value anyway.
local hooks = require("palforge.test.hooks")

-- Same order and same `comparable` flags as main.lua's BUILD_READS. Only the first is comparable
-- with env.gameBuild at all; the other two describe the engine and the project and would raise a
-- mismatch that means nothing.
local READS = {
    { fn = "GetBuildVersion",  comparable = true,  what = "FApp branch/CL string (Engine.hpp:14991)" },
    { fn = "GetEngineVersion", comparable = false, what = "the UNREAL version (Engine.hpp:14977)" },
    { fn = "GetGameName",      comparable = false, what = "the project name (Engine.hpp:14974)" },
}

-- UE4SS hands a string back in more than one shape: a plain Lua string is the common case, and an
-- array element or out-parameter arrives wrapped in RemoteUnrealParam with the real value behind
-- :get() — the wrapper that once made the icon column read the right LENGTH with nothing in it
-- (Closed: icons-row-read). Both are unwrapped, and the RAW type is printed either way, because
-- "which shape did it arrive in" is half of what this run is for.
local function unwrap(v)
    if type(v) == "string" then return v, "string" end
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:get() end)
        if ok and type(s) == "string" then return s, "userdata:get()" end
        ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s, "userdata:ToString()" end
        return nil, "userdata (neither :get() nor :ToString() answered)"
    end
    return nil, type(v)
end

local function digitSignature(s)
    local parts = {}
    for run in tostring(s):gmatch("%d+") do parts[#parts + 1] = run end
    return table.concat(parts, ".")
end

hooks.declare{
    id    = "game-build-live",
    item  = "Before publish §2 (the game build is declared but never read back)",
    needs = { world = true },
    desc  = "print the raw GetBuildVersion / GetEngineVersion / GetGameName strings so the "
         .. "declared build can be compared against the running one for real",
    run = function(h)
        local env = require("palforge.env")

        h:section("[1] the declared build, and what the startup read already recorded")
        h:value("env.gameBuild (measured against)", env.gameBuild)
        h:value("env.gameBuildLive (startup read)", env.gameBuildLive or "nil — nothing answered")
        if not env.gameBuildLive then
            h:note("a nil there is not yet a defect: main.lua runs before any world exists and "
                .. "the CDO lookup can legitimately answer nothing that early. It retries once at "
                .. "the first world.ready, and this hook runs inside a world, so block [3] below "
                .. "is the read that counts.")
        end

        h:section("[2] the CDO")
        local lib
        pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
        if not (lib and lib.IsValid ~= nil and lib:IsValid()) then
            h:fail("UKismetSystemLibrary's CDO did not resolve, so none of the three functions "
                .. "can be called and NOTHING about the live build was measured. That is a "
                .. "finding about the lookup, not about the build: main.lua takes the same path "
                .. "and would record `unknown` for the same reason.")
            return
        end
        h:pass("/Script/Engine.Default__KismetSystemLibrary resolved")

        h:section("[3] all three, raw — nils printed, never skipped")
        local first, firstFn, firstComparable
        for _, r in ipairs(READS) do
            local ok, raw = pcall(function() return lib[r.fn] and lib[r.fn](lib) end)
            if not ok then
                h:value(r.fn, "RAISED: " .. tostring(raw))
            elseif raw == nil then
                h:value(r.fn, "nil (the function is not declared on this build)")
            else
                local s, shape = unwrap(raw)
                h:value(r.fn, string.format("%q  [arrived as %s]  %s",
                    tostring(s), shape, r.what))
                if s and s ~= "" and not first then
                    first, firstFn, firstComparable = s, r.fn, r.comparable
                end
            end
        end

        h:section("[4] what that means for the comparison main.lua makes")
        if not first then
            h:pass("NONE of the three answered inside a loaded world. That CLOSES the question in "
                .. "the negative: this build reports no build string through UKismetSystemLibrary, "
                .. "env.gameBuildLive can only ever be nil, and the startup line's `unknown "
                .. "(<reason>)` is the honest and final answer rather than a wiring fault.")
            return
        end

        env.gameBuildLive = first
        h:value("first answering function", firstFn)
        h:value("digitSignature(live)", digitSignature(first))
        h:value("digitSignature(env.gameBuild)", digitSignature(env.gameBuild))
        if not firstComparable then
            h:pass(string.format("%s answered but describes the ENGINE or the PROJECT, not the "
                .. "Palworld build, so main.lua records it and does NOT compare it. If "
                .. "GetBuildVersion printed nil above, then nothing on this build carries "
                .. "Palworld's own version and the declared %s can never be checked at runtime.",
                firstFn, tostring(env.gameBuild)))
        elseif digitSignature(first) == digitSignature(env.gameBuild) then
            h:pass(string.format("GetBuildVersion's digits match the declared build. PASTE THE RAW "
                .. "STRING FROM BLOCK [3] INTO plan/TODO.md: once its exact shape is written down, "
                .. "main.lua's digit-run comparison can be tightened into a real one, which is the "
                .. "whole reason this measurement was owed. Declared %s, live %q.",
                tostring(env.gameBuild), first))
        else
            h:fail(string.format("GetBuildVersion answered %q, whose digits (%s) do NOT match the "
                .. "declared %s (%s). Either this install is a different patch from the one every "
                .. "capability in plan/TODO.md's Closed list was measured on — in which case that "
                .. "is exactly the line the startup banner exists to print — or GetBuildVersion "
                .. "carries something other than the Palworld build on this engine, in which case "
                .. "main.lua's `comparable = true` flag on it is wrong and should move.",
                first, digitSignature(first), tostring(env.gameBuild), digitSignature(env.gameBuild)))
        end
    end,
}
