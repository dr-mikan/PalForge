-- PalForge — content framework for Palworld (UE4SS Lua mod). THIN entry point.
-- https://github.com/dr-mikan/PalForge
--
-- Runs as a UE4SS Lua mod. All logic lives under palforge.* (api/ core/ utils/ native/);
-- this file only:
--   1. bootstraps package.path so palforge.* resolves relative to this Scripts dir,
--   2. loads the OPTIONAL dev overlay (Scripts/palforge_dev.lua) — the file that switches
--      env.dev / env.debug on for a dev session, and that no released copy contains,
--   3. asks the RUNNING game what build it is and records the answer in env.gameBuildLive,
--   4. prints the startup banner — the one thing every user sees — carrying the version, the
--      declared and live game build, the dev/debug state and the single-player statement,
--   5. initializes the kernel (api + native catalogs + event system + dev tools),
--   6. publishes the downstream API on _G.PalForge for companion mods to reuse.
--
-- LAYERS
--   api/    the PUBLIC surface a content pack writes against. One module per domain
--           (Pal, Item, Building, Skill, Effect, Audio, Mesh, UI, Player), all the same
--           shape: CALL the module to define — X{ id, ..., events = {...} } — plus
--           X.get(id) / X.get_all(), each returning a Handle that carries that domain's
--           actions. Requiring palforge.api also installs the bare globals
--           (Pal, Item, Building, ...) for terse pack code.
--   core/   the ENGINE. The kernel (registry), the one event system (event: channels +
--           native sources + dispatch + the full building runtime), and the Palworld
--           bridges api/ is built on (object_manager, spawn, mesh, sound, player, icons,
--           spatial, keyboard, unittests, uobject, assetpath, vendor/rx). Not something a
--           pack calls directly.
--   utils/  the generic TOOLBOX a pack does call directly: log, json, file, items.
--   native/ Palworld's own content as data catalogs + a few curated definitions.
--
-- Install layout (the full copy list is in README.md, and it is what tools/deploy.sh copies):
--   ue4ss/Mods/PalForge/enabled.txt               <- UE4SS starts a mod only if this exists
--   ue4ss/Mods/PalForge/Scripts/main.lua          <- this file
--   ue4ss/Mods/PalForge/Scripts/palforge/*        <- modules: api/ core/ native/ test/ utils/
--                                                    plus env.lua, types.lua, autorun.txt
--   ue4ss/Mods/PalForge/Scripts/palforge_dev.lua  <- DEV ONLY. Written by tools/deploy.sh in
--                                                    its default mode, gitignored, and never
--                                                    present in a copy a player installs.

-- Make require() resolve palforge.* relative to this Scripts dir.
local thisDir = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
package.path = thisDir .. "?.lua;" .. thisDir .. "?\\init.lua;" .. package.path

local env      = require("palforge.env")
local registry = require("palforge.core.registry")
local log      = require("palforge.utils.log").scope("main")

--=============================================================================
-- ① the optional dev overlay
--=============================================================================
-- `dev = true` WAS THE SHIPPED DEFAULT until 2026-08-02, which meant a copy deployed as-is
-- gave every player F1-F10 — including F4, unlock all technologies — and ran the test suites
-- at boot. env.lua now defaults both switches OFF and nothing in the framework turns them on;
-- the DEV LOOP does, through this one require.
--
-- Scripts/palforge_dev.lua sets env.dev / env.debug and is written into the DEPLOYED tree by
-- tools/deploy.sh (default mode). It is gitignored, so it cannot reach a player through the
-- repository, and `tools/deploy.sh --release` deletes any stale copy it finds. Its absence is
-- the normal case and says nothing.
--
-- A missing module and a BROKEN one are reported differently on purpose. `pcall(require, ...)`
-- swallows both, and a dev overlay with a syntax error that silently left dev off would read
-- exactly like the framework ignoring the flag — the failure shape this tree has already lost
-- hours to more than once.
local devOverlay
do
    local ok, err = pcall(require, "palforge_dev")
    local msg = tostring(err)
    if ok then
        devOverlay = "loaded"
    elseif msg:find("module 'palforge_dev' not found", 1, true) then
        devOverlay = "absent (release copy)"
    else
        devOverlay = "FAILED TO LOAD"
        log.warn("dev overlay Scripts/palforge_dev.lua exists but did not load, so env.dev is "
            .. "whatever env.lua declares and no dev tooling will start: " .. msg)
    end
end

--=============================================================================
-- ② which Palworld is this, actually
--=============================================================================
-- env.gameBuild is the build every capability in plan/TODO.md's Closed list was MEASURED
-- against. env.gameBuildLive is what the game running right now says it is. Recording both is
-- the whole point: a user who hits a broken call must be able to tell "PalForge is broken"
-- from "the game moved". This tree has already been bitten by exactly that gap — AddItem
-- declared five parameters where dumps/cxx/Pal.hpp had four, because the header dump predated
-- the installed binary by a single patch (Closed: item-additem-signature).
--
-- NOTHING HERE IS MEASURED YET. No run has ever printed these strings, so what each function
-- returns on this build is unknown and the code says so rather than guessing:
--   * UKismetSystemLibrary::GetBuildVersion  (dumps/cxx/Engine.hpp:14991) is FApp's branch/CL
--     string and is the only one of the three that could plausibly carry Palworld's own build,
--     so it is the only one compared against env.gameBuild.
--   * GetEngineVersion (:14977) is the UNREAL version and GetGameName (:14974) is the project
--     name — both are worth logging and neither is comparable to "v1.0.2.101103", so they are
--     recorded with `comparable = false` and never raise a mismatch.
-- All three take no parameters, which is why they are called directly rather than through
-- core/signature: there is no argument list to get wrong, and a wrong-typed argument is the
-- only failure shape pcall cannot see.
--
-- The hook that turns this from "wired" into "measured" is `game-build-live` under
-- Scripts/palforge/test/hooks/ (contract C7) — one run in a loaded save prints all three raw
-- strings and settles which function answers what.
local BUILD_READS = {
    { fn = "GetBuildVersion",  comparable = true  },
    { fn = "GetEngineVersion", comparable = false },
    { fn = "GetGameName",      comparable = false },
}

-- UE4SS hands a string back in more than one shape. A plain Lua string is the common case; an
-- array element or an out-parameter arrives wrapped in RemoteUnrealParam with the real value
-- behind :get() — the wrapper that made the icon column read the right LENGTH with nothing in
-- it (Closed: icons-row-read). Both are unwrapped here, and anything else is reported as no
-- answer rather than tostring()'d into a fake one.
local function asString(v)
    if type(v) == "string" then return (v ~= "" and v) or nil end
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:get() end)
        if ok and type(s) == "string" and s ~= "" then return s end
        ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    return nil
end

---Ask the running game for its build string.
---@return string? value      -- nil when nothing answered
---@return string source      -- the function that answered, or the reason there is no value
---@return boolean comparable -- may this value be compared with env.gameBuild at all?
local function readLiveBuild()
    local lib
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if not (lib and lib.IsValid ~= nil and lib:IsValid()) then
        return nil, "UKismetSystemLibrary CDO did not resolve", false
    end
    local tried = {}
    for _, r in ipairs(BUILD_READS) do
        local ok, raw = pcall(function() return lib[r.fn] and lib[r.fn](lib) end)
        local s = ok and asString(raw) or nil
        if s then return s, r.fn, r.comparable end
        tried[#tried + 1] = r.fn
    end
    return nil, "none of " .. table.concat(tried, "/") .. " answered", false
end

-- Both strings reduced to their digit runs, so a formatting difference is not reported as a
-- version difference: "v1.0.2.101103" and a branch string of the shape "++Pal+Release-1.0.2-
-- CL-101103" both reduce to "1.0.2.101103". The exact live shape is UNOBSERVED (see above), so
-- this is deliberately the loose comparison — a false "they match" is a quiet no-op, where a
-- false mismatch would train every user to ignore the one line that matters.
local function digitSignature(s)
    local parts = {}
    for run in tostring(s):gmatch("%d+") do parts[#parts + 1] = run end
    return table.concat(parts, ".")
end

local liveBuild, buildSource, buildComparable = readLiveBuild()
env.gameBuildLive = liveBuild

--=============================================================================
-- ③ the startup banner
--=============================================================================
-- Printed AFTER the dev overlay ran, so the flags it reports are the ones initialize() will
-- act on, and BEFORE initialize(), so a kernel that throws still leaves this line in the log.
--
-- The multiplayer sentence is verbatim from the project's single-player statement and is
-- repeated word for word in README.md and the docs. It is a scope decision, not an oversight:
-- core/spawn builds a PalCheatManager off the LOCAL player controller, item spend goes through
-- a locally spawned APalWeaponBase::RequestConsumeItem, every event source is a local
-- RegisterHook, and none of it has ever been run against a dedicated server.
local SINGLE_PLAYER =
    "PalForge targets SINGLE-PLAYER Palworld. Dedicated servers and co-op guests are not "
    .. "supported and are not tested: there is no replication layer, and the item, spawn and "
    .. "event routes are all client-authoritative. A pack may appear to work for the host and "
    .. "do nothing for anyone else."

log.info(string.format(
    "PalForge v%s starting | game build: declared %s, live %s | dev=%s debug=%s | dev overlay: %s",
    tostring(env.version),
    tostring(env.gameBuild),
    liveBuild and (liveBuild .. " (" .. buildSource .. ")") or ("unknown (" .. buildSource .. ")"),
    tostring(env.dev), tostring(env.debug), devOverlay))
log.info(SINGLE_PLAYER)

-- The disagreement line, logged ONCE and only when the two values are comparable at all.
if liveBuild and buildComparable then
    if digitSignature(liveBuild) ~= digitSignature(env.gameBuild) then
        log.warn(string.format(
            "game build MISMATCH: this build of PalForge was measured against %s and the running "
            .. "game reports %s (%s). Everything in the framework may still work — nothing here "
            .. "is a version check — but if a call into the game starts failing, THIS LINE is the "
            .. "first thing to quote, because it is the difference between PalForge being broken "
            .. "and the game having moved.",
            tostring(env.gameBuild), liveBuild, buildSource))
    end
elseif liveBuild then
    log.info(string.format("live build string %s came from %s, which reports the engine/project "
        .. "rather than the Palworld build, so it is recorded but NOT compared with the declared "
        .. "%s", liveBuild, buildSource, tostring(env.gameBuild)))
end

--=============================================================================
-- ④ the kernel
--=============================================================================
-- Load + register everything (api, native catalogs, event system, dev tools if env.dev).
local ok, err = pcall(function() registry.initialize() end)
if not ok then
    log.err("initialize failed: " .. tostring(err))
else
    log.info("ready")
end

-- ONE retry for the build read, from the first loaded world. UE4SS runs a Lua mod early and
-- the CDO lookup above can legitimately answer nothing at that point; by world.ready the
-- object map is certainly populated. One-shot, and silent when the startup read already
-- answered — this is a diagnostic, not a heartbeat.
if not env.gameBuildLive then
    pcall(function()
        local event = require("palforge.core.event")
        local done = false
        event.on("world.ready", function()
            if done then return end
            done = true
            local v, src, cmp = readLiveBuild()
            env.gameBuildLive = v
            if v then
                log.info(string.format("game build (read at world.ready): %s (%s); declared %s",
                    v, src, tostring(env.gameBuild)))
                if cmp and digitSignature(v) ~= digitSignature(env.gameBuild) then
                    log.warn(string.format("game build MISMATCH: measured against %s, running "
                        .. "game reports %s (%s)", tostring(env.gameBuild), v, src))
                end
            else
                log.info("game build: unknown at world.ready too (" .. src .. "); every "
                    .. "capability in this build was measured against " .. tostring(env.gameBuild))
            end
        end)
    end)
end

--=============================================================================
-- ⑤ the public surface
--=============================================================================
-- Public surface for downstream Lua mods (companion mods loaded into this VM reuse these).
-- `api` is what a content pack writes against; `utils` is the toolbox; `core` and `native`
-- are exposed for advanced use (custom event channels, catalog lookups).
local api = require("palforge.api")

_G.PalForge = {
    env = env,
    api = api,
    -- The SCOPED surface: `local mine = PalForge.pack("mypack")` returns the same nine
    -- constructors, each registering its definitions under that pack id, so a collision
    -- between two packs can be named in the log instead of silently overwriting. Same
    -- function as require("palforge.api").pack.
    pack = api.pack,
    utils = {
        log   = require("palforge.utils.log"),
        json  = require("palforge.utils.json"),
        file  = require("palforge.utils.file"),
        items = require("palforge.utils.items"),
    },
    core = {
        registry       = registry,
        event          = require("palforge.core.event"),
        object_manager = require("palforge.core.object_manager"),
        spawn          = require("palforge.core.spawn"),
        mesh           = require("palforge.core.mesh"),
        sound          = require("palforge.core.sound"),
        player         = require("palforge.core.player"),
        spatial        = require("palforge.core.spatial"),
        icons          = require("palforge.core.icons"),
        -- The two shared primitives every layer needs and three layers used to keep private
        -- copies of: uobject answers is-it-live / what-is-it / WHAT DO I KEY A TABLE ON
        -- (uobject.key — a handle is minted fresh per lookup and can never be a table key),
        -- and assetpath owns the `<package>.<object>` string rules.
        uobject        = require("palforge.core.uobject"),
        assetpath      = require("palforge.core.assetpath"),
    },
    native = require("palforge.native"),
}

-- Named rather than assumed: until api.pack exists, PalForge.pack is nil and a pack that
-- calls it gets an immediate "attempt to call a nil value" instead of content registered
-- with no owner.
if type(api.pack) ~= "function" then
    log.warn("PalForge.pack is not available this session: palforge.api exports no pack(), so "
        .. "scoped registration (PalForge.pack('mypack').Item{...}) cannot be used and every "
        .. "definition registers unowned")
end

return _G.PalForge
