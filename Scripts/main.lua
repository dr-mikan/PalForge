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
--      declared and the running game build, the dev/debug state and the single-player statement,
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
-- WHAT THE FIRST LIVE RUN SETTLED — measured 2026-08-02 16:39:33, hook `game-build-live`, in a
-- loaded save. All three UKismetSystemLibrary reads answered, every one of them as a userdata
-- unwrapped by :ToString(), and NONE of the three carries Palworld's own patch version:
--
--   GetBuildVersion   (dumps/cxx/Engine.hpp:14991)  "++UE5+Release-5.1-CL-0"     FApp's branch/CL
--   GetEngineVersion  (Engine.hpp:14977)            "5.1.1-0+++UE5+Release-5.1"  the UNREAL version
--   GetGameName       (Engine.hpp:14974)            "Pal"                        the project name
--
-- GetBuildVersion carried `comparable = true` here on the guess that FApp's branch string would
-- be Palworld's. It is Unreal's: its digits reduce to 5.5.1.0 against the declared 1.0.2.101103,
-- so this file raised a MISMATCH **warn on every single start** for a comparison that can never
-- succeed. A warning that always fires teaches its reader to ignore warnings, which is worse than
-- not having one. All three are now `comparable = false`. They are still read and still logged,
-- as CONTEXT — the engine is UE 5.1.1 and the project is "Pal" — and are compared with nothing.
--
-- WHERE PALWORLD'S OWN VERSION LIVES. Two routes exist and both are wired ABOVE the Kismet three,
-- each one confirmed present in the LIVE game's own reflection dump, not only in the header dump:
--   * UPalGameInstance::DisplayVersion — dumps/cxx/Pal.hpp:18842, an FString property, listed
--     live under /Script/Pal.PalGameInstance (dumps/reflection/02_reflection.txt:80). This is the
--     string the title screen prints in its corner. No argument, so no argument to get wrong.
--   * UPalUtility::GetDisplayVersion(WorldContextObject) — Pal.hpp:32372, the Blueprint accessor
--     for the same field, also listed live (02_reflection.txt:2201). Tried second, and through
--     core/signature rather than directly, because it TAKES an argument: a wrong-typed argument
--     faults inside UE4SS's marshalling where pcall cannot see it, and signature is the module
--     that refuses that call instead of making it.
-- NEITHER HAS ANSWERED IN A RUN YET. Both need a live UPalGameInstance, which does not exist at
-- the moment UE4SS starts a Lua mod, and the 2026-08-02 run measured only the Kismet three. The
-- world.ready retry at the end of this section is what gives them their chance, and the hook
-- prints both raw. If they turn out to answer nothing either, then Palworld's patch version is
-- not reachable from Lua on this build at all — a settled negative, and the log says so in words.

-- UE4SS hands a string back in more than one shape. A plain Lua string is the common case; an
-- array element or an out-parameter arrives wrapped in RemoteUnrealParam with the real value
-- behind :get() — the wrapper that made the icon column read the right LENGTH with nothing in
-- it (Closed: icons-row-read). An FString RETURN is a third shape and is the one measured on
-- 2026-08-02: userdata with :ToString() and no :get(). All three are unwrapped here, and
-- anything else is reported as no answer rather than tostring()'d into a fake one.
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

-- One live object of a class, or nil. FindFirstOf matches SUBCLASSES, which is what makes this
-- find the game's own BP_PalGameInstance_C and not only an exact UPalGameInstance.
local function liveObject(className)
    if type(FindFirstOf) ~= "function" then return nil end
    local o
    pcall(function() o = FindFirstOf(className) end)
    if o and o.IsValid ~= nil and o:IsValid() then return o end
    return nil
end

-- Route 1: the FString property the title screen prints.
local function readGameInstanceVersion()
    local gi = liveObject("PalGameInstance")
    if not gi then return nil, "no live PalGameInstance yet" end
    local ok, raw = pcall(function() return gi.DisplayVersion end)
    if not ok then return nil, "DisplayVersion raised: " .. tostring(raw) end
    local s = asString(raw)
    if s then return s end
    if raw == nil then return nil, "PalGameInstance declares no DisplayVersion on this build" end
    return nil, "DisplayVersion answered an unreadable " .. type(raw)
end

-- Route 2: the Blueprint accessor for that same field. Only attempted when there is a live
-- UObject to hand it as WorldContextObject — without one there is nothing to pass, and a call
-- is not worth inventing an argument for.
local function readUtilityVersion()
    local u
    pcall(function() u = StaticFindObject("/Script/Pal.Default__PalUtility") end)
    if not (u and u.IsValid ~= nil and u:IsValid()) then
        return nil, "PalUtility CDO did not resolve"
    end
    local ctx = liveObject("PalGameInstance") or liveObject("PalPlayerCharacter")
    if not ctx then return nil, "no live UObject to pass as WorldContextObject" end
    local ok, raw = require("palforge.core.signature")
        .call(u, "GetDisplayVersion", { "ObjectProperty" }, ctx)
    if not ok then return nil, "GetDisplayVersion was refused or raised (core/signature said so)" end
    local s = asString(raw)
    return s, (s == nil) and "GetDisplayVersion answered nothing" or nil
end

-- Route 3: the three UKismetSystemLibrary strings, each taking no parameters. The CDO is looked
-- up once and only memoised on success, so a lookup that failed this early still gets retried.
local kismetLib
local function readKismet(fn)
    return function()
        if not kismetLib then
            pcall(function()
                kismetLib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            end)
            if not (kismetLib and kismetLib.IsValid ~= nil and kismetLib:IsValid()) then
                kismetLib = nil
                return nil, "UKismetSystemLibrary CDO did not resolve"
            end
        end
        local ok, raw = pcall(function() return kismetLib[fn] and kismetLib[fn](kismetLib) end)
        if not ok then return nil, fn .. " raised: " .. tostring(raw) end
        local s = asString(raw)
        return s, (s == nil) and (fn .. " answered nothing") or nil
    end
end

-- The candidate routes in the order they are tried. `comparable` means ONE thing: may this
-- string be compared with env.gameBuild — a Palworld patch number — at all? Only Palworld's own
-- version may. The three engine reads are context and nothing else. test/hooks/game_build_live.lua
-- restates this list; the two must stay in step.
local BUILD_READS = {
    { name = "PalGameInstance.DisplayVersion", comparable = true,  read = readGameInstanceVersion },
    { name = "PalUtility.GetDisplayVersion",   comparable = true,  read = readUtilityVersion      },
    { name = "GetBuildVersion",                comparable = false, read = readKismet("GetBuildVersion")  },
    { name = "GetEngineVersion",               comparable = false, read = readKismet("GetEngineVersion") },
    { name = "GetGameName",                    comparable = false, read = readKismet("GetGameName")      },
}

---Every route, tried in order. NOTHING short-circuits: the engine strings are worth logging even
---when Palworld's own version answered, and the reason a route did not answer is worth as much
---as the answer.
---@return table[] results  # { { name =, value =, comparable =, why = }, ... } in BUILD_READS order
local function readLiveBuild()
    local out = {}
    for i, r in ipairs(BUILD_READS) do
        local v, why = r.read()
        out[i] = { name = r.name, value = v, comparable = r.comparable, why = why }
    end
    return out
end

local function answered(results, name)
    for _, r in ipairs(results) do if r.name == name then return r.value end end
    return nil
end

---Palworld's own version, and the route that carried it — or nil. An engine string is NEVER
---promoted into this slot: that promotion is exactly what made this file cry wolf.
local function palVersion(results)
    for _, r in ipairs(results) do
        if r.comparable and r.value then return r.value, r.name end
    end
    return nil
end

---What Unreal said about itself, as one clause — or nil when even that did not answer, which is
---what a session with no engine under it looks like.
local function engineIdentity(results)
    local bits = {}
    local eng, br, proj = answered(results, "GetEngineVersion"),
                          answered(results, "GetBuildVersion"), answered(results, "GetGameName")
    if eng  then bits[#bits + 1] = "engine " .. eng end
    if br   then bits[#bits + 1] = "branch " .. br end
    if proj then bits[#bits + 1] = string.format("project %q", proj) end
    return (#bits > 0) and table.concat(bits, ", ") or nil
end

---Route by route, why Palworld's own version did not answer. This is the sentence that keeps the
---negative honest: "did not answer" with no reason is indistinguishable from "was never asked".
local function palRouteTrail(results)
    local bits = {}
    for _, r in ipairs(results) do
        if r.comparable then
            bits[#bits + 1] = r.name .. ": " .. tostring(r.value or r.why or "no answer")
        end
    end
    return table.concat(bits, "; ")
end

---What env.gameBuildLive carries. Palworld's own version when a route answered; otherwise the
---word `unknown` IN THE VALUE, with the engine string in brackets. Three banners print this
---field verbatim (here, test/init.lua, test/hooks/init.lua) and none of them compares it, so
---handing one an engine string to print under the word "live" would restate the same false
---claim in three more places.
local function liveField(results)
    local v = palVersion(results)
    if v then return v end
    local eng = answered(results, "GetEngineVersion") or answered(results, "GetBuildVersion")
    return eng and ("unknown (engine " .. eng .. ")") or nil
end

-- Both strings reduced to their digit runs, so a formatting difference is not reported as a
-- version difference: "v1.0.2.101103" and "Ver. 1.0.2 (101103)" both reduce to "1.0.2.101103".
-- The shape DisplayVersion answers in has not been observed yet, so the loose comparison stays:
-- a false "they match" is a quiet no-op, where a false mismatch is the thing this section was
-- rewritten to stop.
local function digitSignature(s)
    local parts = {}
    for run in tostring(s):gmatch("%d+") do parts[#parts + 1] = run end
    return table.concat(parts, ".")
end

local results = readLiveBuild()
local liveBuild, liveSource = palVersion(results)
env.gameBuildLive = liveField(results)

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
    "PalForge v%s starting | game build: declared %s, running %s | dev=%s debug=%s | dev overlay: %s",
    tostring(env.version),
    tostring(env.gameBuild),
    liveBuild and (liveBuild .. " (" .. liveSource .. ")") or "not read (see the next line)",
    tostring(env.dev), tostring(env.debug), devOverlay))
log.info(SINGLE_PLAYER)

---THE ONE LINE ABOUT THE BUILD, and it is `warn` only when two PALWORLD version strings actually
---disagree. Until 2026-08-02 the warn fired on every start, because the string being compared was
---Unreal's branch and could never match a Palworld patch number; the run that proved that is in
---the block comment above. Silence is now the normal case: when the running version answers and
---matches, the banner above has already said so and there is nothing to add.
---@param res table[]     # a readLiveBuild() result list
---@param when string     # "at startup" | "at the first world.ready"
---@return boolean        # did Palworld's own version answer?
local function reportBuild(res, when)
    local v, src = palVersion(res)
    if v then
        if digitSignature(v) ~= digitSignature(env.gameBuild) then
            log.warn(string.format(
                "game build MISMATCH: this build of PalForge was measured against %s and the "
                .. "running game reports %s (%s, read %s). Nothing in the framework is a version "
                .. "check and most of it will still work — but if a call into the game starts "
                .. "failing, THIS is the line to quote, because it is the difference between "
                .. "PalForge being broken and the game having moved.",
                tostring(env.gameBuild), v, src, when))
        elseif when ~= "at startup" then
            log.info(string.format("game build: the running game reports %s (%s, read %s), which "
                .. "is the build this copy of PalForge was measured against",
                v, src, when))
        end
        return true
    end
    local engine = engineIdentity(res)
    log.info(string.format(
        "game build: this copy of PalForge was measured against %s, and the running game's own "
        .. "patch version is NOT reachable from Lua %s (%s). %s%s",
        tostring(env.gameBuild), when, palRouteTrail(res),
        engine and ("What Unreal answers is its own identity — " .. engine .. " — which names the "
                    .. "engine and the project, never Palworld's patch. ")
               or "Unreal's own identity did not answer either, so nothing at all was readable. ",
        when == "at startup"
            and "It is asked once more at the first world.ready, when a PalGameInstance exists."
            or "So there is nothing to compare against automatically: if a call into the game "
             .. "starts failing, check that declared build by hand against the version the title "
             .. "screen prints in its corner."))
    return false
end

reportBuild(results, "at startup")

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

-- ONE retry for the build read, from the first loaded world. UE4SS starts a Lua mod early — long
-- before a UPalGameInstance exists — so the two routes that carry Palworld's OWN version cannot
-- answer at startup, while the three engine strings can and did (measured 2026-08-02 16:38:19,
-- the banner printed them). This is the read that gives those two routes a live game to answer
-- from. Armed only when the startup read carried no Palworld version, one-shot, and it speaks
-- exactly once — this is a diagnostic, not a heartbeat.
if not liveBuild then
    pcall(function()
        local event = require("palforge.core.event")
        local done = false
        event.on("world.ready", function()
            if done then return end
            done = true
            local later = readLiveBuild()
            env.gameBuildLive = liveField(later) or env.gameBuildLive
            reportBuild(later, "at the first world.ready")
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

-- THE STORE, AND WHY IT IS THE ONE CORE MODULE REQUIRED BEHIND A pcall. Every other entry below
-- is a bare require, and that is right for them: if core/event cannot load, PalForge cannot do
-- its job and the error should be immediate. The store is different in exactly one way — it is
-- where a PLAYER'S data lives. A store that fails to load must degrade to "no persistence this
-- session", named in the log, rather than take the whole framework down and make every pack in
-- the load order look broken. api/init.lua's `.store` member does the same thing for the same
-- reason, and answers a refusal that says why instead of a nil.
local state, ledger
do
    local ok, mod = pcall(require, "palforge.core.state")
    if ok and type(mod) == "table" then
        state = mod
    else
        log.err("core.state did not load: " .. tostring(mod) .. ". PalForge.core.state is absent, "
            .. "nothing a pack saves will survive this session, and building state will not be "
            .. "read or written. Everything else is unaffected")
    end
    -- The ledger is the list of ids PalForge asked the GAME to write (see core/ledger.lua). It
    -- is what makes an uninstall answerable, so it is exposed rather than kept private.
    local okL, modL = pcall(require, "palforge.core.ledger")
    if okL and type(modL) == "table" then ledger = modL end
end

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
        -- PERSISTENCE, and the two halves of the removal question it answers.
        --   state   PalForge's OWN saved state: one JSON file per pack, per save, under
        --           <Mods>/PalForge/state/. Nothing here is inside Palworld's .sav — delete
        --           the mod folder and the world still loads. A pack reaches its own slice
        --           through PalForge.pack("mypack").store, which cannot name another pack's.
        --   ledger  the names PalForge asked the GAME to write (an item id into an inventory,
        --           a technology into the player's list, a passive onto a pal). Those DO live
        --           in the save, and this is the only thing in the tree that can list them.
        -- Both may be nil this session; see the pcall above, which says so in the log.
        state          = state,
        ledger         = ledger,
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
