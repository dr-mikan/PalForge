-- test/hooks/game-build-live — DOES ANYTHING THE GAME EXPOSES CARRY PALWORLD'S OWN BUILD STRING?
--
-- Scripts/main.lua asks the running game what build it is and records the answer in
-- env.gameBuildLive, so that a user who hits a broken call can tell "PalForge is broken" from
-- "the game moved". This hook is the run that settles what that read can actually see, and
-- main.lua's ② block names it by this id.
--
-- WHAT THE FIRST RUN SETTLED — 2026-08-02 16:39:33, in a loaded save. All three
-- UKismetSystemLibrary candidates answered, each as a userdata unwrapped by :ToString():
--
--   GetBuildVersion   (dumps/cxx/Engine.hpp:14991)  "++UE5+Release-5.1-CL-0"     FApp's branch/CL
--   GetEngineVersion  (Engine.hpp:14977)            "5.1.1-0+++UE5+Release-5.1"  the UNREAL version
--   GetGameName       (Engine.hpp:14974)            "Pal"                        the project name
--
-- NONE OF THEM IS PALWORLD'S PATCH VERSION. GetBuildVersion is Unreal's branch and CL, and this
-- hook reported its digits (5.5.1.0) failing to match the declared v1.0.2.101103 as a FAIL — which
-- was the wrong verdict on a correct reading. Nothing was broken: the comparison was against a
-- string that can never carry that number. main.lua's `comparable = true` flag has moved off
-- GetBuildVersion, its startup warn is now an info line, and "the digits do not match" is no
-- longer a failure here either. It is the expected reading of an engine string.
--
-- WHAT IS STILL OPEN, and why this hook is worth another run. Palworld's own version has two
-- routes, both listed in the LIVE game's reflection dump and NEITHER ever called:
--
--   UPalGameInstance::DisplayVersion            Pal.hpp:18842   02_reflection.txt:80    property
--   UPalUtility::GetDisplayVersion(WorldCtx)    Pal.hpp:32372   02_reflection.txt:2201  function
--
-- DisplayVersion is the string the title screen prints in its corner, and GetDisplayVersion is
-- the Blueprint accessor for the same field. Both need a live UPalGameInstance, which is why
-- main.lua cannot reach them at mod load and why this hook — which runs inside a world — is
-- where they get asked. One run of block [2] closes the question either way: a string, and
-- env.gameBuild can be verified against the running game for real; nothing, and Palworld's patch
-- version is not reachable from Lua on this build, which is a settled negative and a result.
--
-- THE VERDICT RULES, because a hook that fails for the wrong reason is worse than no hook:
--   FAIL   the Kismet CDO does not resolve, or one of the three strings that answered on
--          2026-08-02 stops answering. That is a real change in what the game exposes.
--   FAIL   a Palworld version string answers and its digits do NOT match env.gameBuild. That is
--          a genuine finding: this install is a different patch from the one every capability in
--          plan/TODO.md's Closed list was measured on, and env.gameBuild is stale.
--   PASS   everything else, including "neither Pal route answered". A confirmed negative is a
--          measurement, and this hook exists to take it.
--
-- THE READ IS DUPLICATED HERE ON PURPOSE. main.lua's readLiveBuild is a local in the mod's entry
-- point, which is not on the palforge.* require path and cannot be reached from a module. What
-- must stay in step between the two files is the ROUTE LIST and the unwrapping rule, and both are
-- restated below rather than referenced.
--
-- Reads two CDOs, one live object and one property. It writes no file, touches no save and
-- mutates nothing except env.gameBuildLive, which main.lua fills in with the same value anyway.
local hooks = require("palforge.test.hooks")

-- Same three, same order and the same `comparable = false` as main.lua's BUILD_READS. `was` is
-- what each answered on 2026-08-02, so a future run shows drift instead of hiding it.
local KISMET = {
    { fn = "GetBuildVersion",  was = "++UE5+Release-5.1-CL-0",
      what = "FApp's branch/CL string (Engine.hpp:14991) — UNREAL's branch, not Palworld's" },
    { fn = "GetEngineVersion", was = "5.1.1-0+++UE5+Release-5.1",
      what = "the UNREAL version (Engine.hpp:14977)" },
    { fn = "GetGameName",      was = "Pal",
      what = "the project name (Engine.hpp:14974)" },
}

-- UE4SS hands a string back in more than one shape: a plain Lua string, an array element or
-- out-parameter wrapped in RemoteUnrealParam with the real value behind :get() — the wrapper that
-- once made the icon column read the right LENGTH with nothing in it (Closed: icons-row-read) —
-- and an FString behind :ToString(), which is the shape every value measured here arrived in.
-- All three are unwrapped, and the RAW shape is printed either way, because "which shape did it
-- arrive in" is half of what this run is for.
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

local function liveObject(className)
    if type(FindFirstOf) ~= "function" then return nil end
    local o
    pcall(function() o = FindFirstOf(className) end)
    if o and o.IsValid ~= nil and o:IsValid() then return o end
    return nil
end

local function fullName(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    return (ok and s) or "(no GetFullName)"
end

hooks.declare{
    id    = "game-build-live",
    item  = "Closed 2026-08-02 — both readers answer v1.0.2.101103",
    needs = { world = true },
    desc  = "settle whether ANY call carries Palworld's own patch version — the two "
         .. "PalGameInstance/PalUtility DisplayVersion routes, plus the three Kismet strings "
         .. "that were measured on 2026-08-02 and carry Unreal's identity rather than the game's",
    run = function(h)
        local env = require("palforge.env")

        h:section("[1] the declared build, and what the startup read already recorded")
        h:value("env.gameBuild (measured against)", env.gameBuild)
        h:value("env.gameBuildLive (startup read)", env.gameBuildLive or "nil — nothing answered")
        h:note("main.lua records `unknown (engine ...)` there when only the Kismet strings "
            .. "answered, on purpose: three banners print that field verbatim and none of them "
            .. "compares it, so handing one an engine string to print under the word `live` would "
            .. "restate a false claim in three more places.")

        --------------------------------------------------------------------------------
        h:section("[2] Palworld's OWN version — the two routes, never called before this run")
        local palVersion, palSource

        local gi = liveObject("PalGameInstance")
        h:value("FindFirstOf(\"PalGameInstance\")", gi and fullName(gi) or "nil — no live instance")
        if gi then
            local ok, raw = pcall(function() return gi.DisplayVersion end)
            if not ok then
                h:value("PalGameInstance.DisplayVersion", "RAISED: " .. tostring(raw))
            elseif raw == nil then
                h:value("PalGameInstance.DisplayVersion",
                    "nil (Pal.hpp:18842 declares it; this build's live object does not)")
            else
                local s, shape = unwrap(raw)
                h:value("PalGameInstance.DisplayVersion",
                    string.format("%q  [arrived as %s]", tostring(s), shape))
                if s and s ~= "" then palVersion, palSource = s, "PalGameInstance.DisplayVersion" end
            end
        end

        local util
        pcall(function() util = StaticFindObject("/Script/Pal.Default__PalUtility") end)
        local haveUtil = util and util.IsValid ~= nil and util:IsValid()
        h:value("/Script/Pal.Default__PalUtility", haveUtil and "resolved" or "did NOT resolve")
        if haveUtil then
            -- Through core/signature rather than directly: this one TAKES a WorldContextObject,
            -- and a wrong-typed argument faults inside UE4SS's marshalling where pcall cannot
            -- see it. signature refuses the call instead of making it, and says which evidence
            -- level it rested on.
            local ctx = gi or liveObject("PalPlayerCharacter")
            if not ctx then
                h:value("PalUtility.GetDisplayVersion", "not called — no live UObject to pass as "
                    .. "WorldContextObject")
            else
                local ok, raw, how = require("palforge.core.signature")
                    .call(util, "GetDisplayVersion", { "ObjectProperty" }, ctx)
                if not ok then
                    h:value("PalUtility.GetDisplayVersion",
                        "refused or raised (core/signature evidence: " .. tostring(how) .. ")")
                else
                    local s, shape = unwrap(raw)
                    h:value("PalUtility.GetDisplayVersion", string.format(
                        "%q  [arrived as %s]  [evidence %s, ctx %s]",
                        tostring(s), shape, tostring(how), fullName(ctx)))
                    if s and s ~= "" and not palVersion then
                        palVersion, palSource = s, "PalUtility.GetDisplayVersion"
                    end
                end
            end
        end

        --------------------------------------------------------------------------------
        h:section("[3] UKismetSystemLibrary, raw — nils printed, never skipped")
        local lib
        pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
        if not (lib and lib.IsValid ~= nil and lib:IsValid()) then
            h:fail("UKismetSystemLibrary's CDO did not resolve, and it DID on 2026-08-02. None of "
                .. "the three engine strings can be called, so nothing about the engine identity "
                .. "was measured. That is a finding about the lookup, not about the build: "
                .. "main.lua takes the same path and would record `unknown` for the same reason.")
        else
            h:pass("/Script/Engine.Default__KismetSystemLibrary resolved")
            for _, r in ipairs(KISMET) do
                local ok, raw = pcall(function() return lib[r.fn] and lib[r.fn](lib) end)
                local s
                if not ok then
                    h:value(r.fn, "RAISED: " .. tostring(raw))
                elseif raw == nil then
                    h:value(r.fn, "nil (the function is not declared on this build)")
                else
                    local shape
                    s, shape = unwrap(raw)
                    h:value(r.fn, string.format("%q  [arrived as %s]  %s",
                        tostring(s), shape, r.what))
                end
                if not (s and s ~= "") then
                    h:fail(string.format("%s answered nothing, and on 2026-08-02 it answered %q. "
                        .. "Something the game exposed then does not answer now — that is a change "
                        .. "in the engine surface and is worth chasing before anything else in "
                        .. "this file is believed.", r.fn, r.was))
                elseif s ~= r.was then
                    h:note(string.format("%s reads %q where 2026-08-02 measured %q. Not a failure "
                        .. "— nothing compares this string — but the install has moved, and the "
                        .. "new value belongs in main.lua's ② block and in this file's header.",
                        r.fn, s, r.was))
                end
            end
            h:pass("the three engine strings printed raw; none of them is comparable with "
                .. "env.gameBuild and none is compared with it")
        end

        --------------------------------------------------------------------------------
        h:section("[4] the verdict — which read, if any, may be compared with env.gameBuild")
        if not palVersion then
            h:pass(string.format(
                "NO route carried Palworld's own version inside a loaded world: neither "
                .. "UPalGameInstance::DisplayVersion nor UPalUtility::GetDisplayVersion answered. "
                .. "That CLOSES the question in the negative — this build reports its patch "
                .. "version nowhere Lua can reach, env.gameBuildLive can only ever say `unknown "
                .. "(engine ...)`, and the declared %s is checked by a human reading the title "
                .. "screen's corner and by nothing else. The startup line saying exactly that is "
                .. "the honest and final answer rather than a wiring fault.",
                tostring(env.gameBuild)))
            return
        end

        env.gameBuildLive = palVersion
        h:value("Palworld's own version", palVersion)
        h:value("the route that carried it", palSource)
        h:value("digitSignature(live)", digitSignature(palVersion))
        h:value("digitSignature(env.gameBuild)", digitSignature(env.gameBuild))
        if digitSignature(palVersion) == digitSignature(env.gameBuild) then
            h:pass(string.format(
                "%s answers %q, whose digits match the declared %s. THE COMPARISON IS REAL NOW: "
                .. "write the raw string into plan/TODO.md and into main.lua's ② block, and the "
                .. "digit-run reduction can be tightened into a string match — it is loose only "
                .. "because this shape had never been seen.",
                palSource, palVersion, tostring(env.gameBuild)))
        else
            h:fail(string.format(
                "%s answers %q, whose digits (%s) do NOT match the declared %s (%s). Both are "
                .. "Palworld's own version strings, so this is not a units problem and not the "
                .. "engine-string confusion this hook used to report: THIS INSTALL IS A DIFFERENT "
                .. "PATCH from the one every capability in plan/TODO.md's Closed list was measured "
                .. "on. Either re-measure on this install and update env.gameBuild, or say in the "
                .. "README which build the Closed list belongs to.",
                palSource, palVersion, digitSignature(palVersion),
                tostring(env.gameBuild), digitSignature(env.gameBuild)))
        end
    end,
}
