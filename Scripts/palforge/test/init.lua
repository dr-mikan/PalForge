-- palforge/test — the in-game API test suite.
--
-- One case file per domain under test/cases/, each registering a suite with
-- palforge.core.unittests. The kernel requires THIS file at startup, which loads every
-- case and binds the runner to a key; nothing runs until you press it, because these
-- tests spawn pals and hand out items.
--
--   PRESS F1 IN GAME  ->  run every suite, print a summary to UE4SS.log, and put the
--                         pass/fail line on screen.
--
-- F5..F8 are DISCOVERY PROBES rather than tests. They write what the engine actually looks
-- like — class listings, real function signatures, DataTable columns — so the open items in
-- plan/TODO.md can be closed. Each brackets its output with `#### BEGIN <id>` / `#### END
-- <id>`; copy a block out of the log and that item's missing fact is known.
--
--   F5  reflection dump          needs a loaded save
--   F6  the pal's mesh           needs a pal standing near you
--   F8  watch native hooks       needs you to craft / drop / spawn while it runs
--   F2  the title menu button    needs the title screen
--   F3  the same button, in-world  loads the title class into a save and reads its tree
--   F10 count the UI hooks       arms four counters, then wants a quit-to-title and a reload
--
-- The last two exist because there is no way to make anyone press a key: they are reachable
-- from core/autorun as pf_uislot and pf_uievents, and both work from a LOADED WORLD.
--
-- ⚠️ AND THE MEASUREMENTS THAT NEED THE GAME RUNNING ARE NOT HERE. They are DECLARED HOOKS
-- under test/hooks/, loaded only when `env.debug` is true and never run unless asked for by
-- name: `pf_hooks` lists them with each one's gate state, `pf_hook <id>` runs one,
-- `pf_hooks_all` runs every one whose gate is open. That is where "does the waza write land",
-- "can a recipe row be read", "does a colour change" and the rest live now — see
-- test/hooks/init.lua. A suite ASKS WHETHER SOMETHING WORKS; a hook MEASURES WHAT THE ENGINE
-- DOES, and the two do not belong on the same key.
--
-- Results land in UE4SS.log under [PalForge.test] and [PalForge.unittests], in this SHAPE —
-- deliberately with no numbers written into this comment, because the ones that used to be
-- here ("13 suite(s)", "294 total") were contradicted by M.CASES below within a month and a
-- comment nobody can verify is worse than no comment:
--
--   [PalForge.test][info] build <stamp> | dev=<b> debug=<b> | game <declared> (live <read>) |
--                         running <n> suite(s): schema, registry, definitions, pal, ...
--   [PalForge.unittests][info] SKIP [pal] spawns at a coordinate: no world loaded
--   [PalForge.unittests][info] tests: <p> passed, <f> failed, <s> skipped (<total> total)
--   [PalForge.unittests][info] tests: <s> skipped (<n> need a world, <n> need no world, ...)
--   [PalForge.unittests][info] tests: NO SINGLE RUN MEASURES EVERYTHING — ...
--   [PalForge.test][info] swept <n> test definition(s)
--
-- The last two of those also go ON SCREEN through support.announce (M.run below), because the
-- direction of a skip is the whole reason the direction exists and the log is not what a tester
-- is looking at while the game is running.
--
-- The AUTHORITATIVE suite count is `#M.CASES` in this file and nowhere else; the check count
-- is whatever the run prints. A test that needs a world SKIPS rather than fails when there is
-- none, so the same run is meaningful at the title screen and in a save — and note that the
-- skips go BOTH ways: some checks are inverse-gated and skip when a world IS loaded (the UI
-- element's refusal paths, for instance), so no single press can run every check and two runs
-- are needed for full coverage.
-- Every definition a run creates is namespaced (palforge_test:*) and swept afterwards, so
-- pressing the key repeatedly leaves the registry exactly as it found it.
--
-- BINDING A KEY. That is the whole point of test.bind — one line, four shapes:
--
--   local test = require("palforge.test")
--   test.bind("F1")                              -- everything (installed by default)
--   test.bind("F2", "pal")                       -- one suite
--   test.bind("F3", { "item", "effect" })        -- several
--   test.bind("F5", function()                   -- anything at all
--       Pal.get("ChickenPal"):spawn(Player.coordinate())
--   end, { desc = "spawn a chicken" })
--
-- Put those calls in a file under palforge/core/keyboard/functions/ (it is auto-loaded)
-- or anywhere that runs at startup. Re-binding a key replaces its behaviour in place.
--
-- ADDING A CASE. Create test/cases/<name>.lua:
--
--   local T       = require("palforge.core.unittests")
--   local support = require("palforge.test.support")
--   local s = T.suite("<name>")
--   s:test("does the thing", function(t)
--       local pawn = support.needWorld(t)      -- omit for a pure test
--       t:eq(actual, expected, "what should hold")
--   end)
--   return s
--
-- then add "<name>" to M.CASES below.
local T       = require("palforge.core.unittests")
local reg     = require("palforge.core.keyboard.base.registory")
local support = require("palforge.test.support")
local log     = require("palforge.utils.log").scope("test")

-- The build stamp tools/deploy.sh writes next to the modules it copies. Printed at the top of
-- every run, because Lua that is already loaded STAYS loaded: deploying new files changes
-- nothing in a running game until F9. A log whose stamp predates the deploy you just did is not
-- evidence about the code you just wrote — it has cost a full round of debugging more than once.
-- Absent (a source tree run, or a hand copy) is reported as such rather than faked.
local function buildStamp()
    local ok, stamp = pcall(require, "palforge.build")
    return (ok and type(stamp) == "string") and stamp or "unstamped (not deployed by tools/deploy.sh)"
end

-- THE SAME DISCIPLINE, EXTENDED TO THE THREE OTHER THINGS A RESULT DEPENDS ON — and each one
-- has already been mistaken for a defect once:
--   dev / debug   which tooling was even LOADED. `dev = false` loads no suite and no key at
--                 all, and `debug = false` loads no test/hooks — so "the hook printed nothing"
--                 and "the hook was never loaded" produce identical silence unless the flags
--                 are in the log beside the result.
--   game build    which Palworld the numbers were measured against. This tree has been bitten
--                 once by exactly that gap: AddItem declared five parameters where
--                 dumps/cxx/Pal.hpp had four, because the header dump predated the installed
--                 build by a single patch. `gameBuildLive` is what the running game reports and
--                 a mismatch with `gameBuild` is visible here rather than inferred from a
--                 broken call.
---@return string
local function envStamp()
    local env = require("palforge.env")
    return string.format("build %s | dev=%s debug=%s | game %s (live %s)",
        buildStamp(), tostring(env.dev), tostring(env.debug),
        tostring(env.gameBuild), tostring(env.gameBuildLive or "not read yet"))
end

local M = {}

M.support = support

-- Exported so the hook runner and anything else that reports a result can print the same
-- provenance line, rather than growing a second copy of it that drifts.
M.buildStamp = buildStamp
M.envStamp   = envStamp

-- Case files, in run order: the pure ones first so a structural break is reported before
-- anything touches the world.
M.CASES = {
    "schema",
    "registry",
    "definitions",
    "native",
    "pal",
    "item",
    "building",
    "skill",
    "effect",
    "audio",
    "mesh",
    "ui",
    "player",
    "events",
}

-- Discovery probes, and the key each is bound to. A probe is not a test: it does not pass or
-- fail, it writes what the engine actually looks like to UE4SS.log so an open item in
-- plan/TODO.md can be closed. Each one brackets its output with `#### BEGIN <id>` and
-- `#### END <id>`, where <id> is the item's id in that file.
-- ⚠️ F7 IS PALWORLD'S OWN VOLUME KEY. The game claims it before UE4SS sees it, so a probe bound
-- there can never be pressed — `watch` sat on F8 and was simply unreachable. Nothing in the log
-- said so either: the bind succeeded, the key just never arrived.
--
-- So `watch` moved to F8 and `title` to F2. If another key turns out to be taken, change it
-- HERE and nowhere else — this table is the only place a probe key is written.
--
-- THE KEYS BELOW ARE NO LONGER A GUESS, and this is the one line worth re-reading. The kernel
-- prints every binding at startup AND `pf_keys` prints Palworld's whole live key config with a
-- status for every bindable name (core/keyboard/base/keymap.lua). So before moving a probe key,
-- run pf_keys from inside a save and pick one the lookup table calls `free` — and if a key that
-- reads `free` still never arrives, THAT is a finding about something outside the key config
-- (the Steam overlay, the OS, UE's own console keys) rather than another blind swap.
-- ⚠️ Note what pf_keys still cannot see: F7 may well read `free` there. The game's key config is
-- not the only thing that can take a key, and the report says so in its own words.
M.PROBES = {
    { name = "reflect", key = "F5", needs = "a loaded save",
      desc = "reflection dump: classes, functions, parameters, DataTable rows" },
    { name = "pal",     key = "F6", needs = "a pal standing near you",
      desc = "the pal's mesh component, its animation class and its materials" },
    { name = "watch",   key = "F8", needs = "a loaded save, then craft / drop / spawn",
      desc = "arms native hooks and logs what fires while you act" },
    { name = "title",   key = "F2", needs = "the title screen",
      desc = "the game's own title menu button, so ours can match it" },
    -- The two below are the in-world halves of the last two UI items, and they exist BECAUSE
    -- of the note above: no key can be relied on, so both are written to be run from
    -- core/autorun (pf_uislot, pf_uievents) in a loaded save. The keys are a convenience only.
    { name = "uislot",  key = "F3", needs = "a loaded save",
      desc = "the title menu button's inner slot, read from a world instead of the title" },
    { name = "uievents", key = "F10", needs = "a loaded save, then a quit to title and a reload",
      desc = "counts the four UI-rebuild hooks, including across a whole world load" },
}

-- WHAT A COMMAND DOES, kept apart from HOW IT IS INVOKED. Three input routes have now failed in
-- turn — a key the game had already claimed, a second key, and a console that UE4SS ships
-- switched off — and each time the work itself was fine and only the way in was missing. So the
-- work lives here, named, and anything can run it: a console when there is one, a key when one
-- is free, and core/autorun when there is neither.
M.ACTIONS = {
    pf_tests = function() M.run() end,

-- ---- the game-required measurements (test/hooks) ----
--
-- THE USER'S SECOND EXPLICIT ASK, and the reason this block exists rather than another five
-- pf_* actions: everything that can only be settled with Palworld RUNNING is a DECLARED HOOK
-- under test/hooks/, loaded only when env.debug is true, each one naming the plan/TODO.md item
-- it closes, what it needs on screen and whether it writes into a save. The scatter of
-- `_G.PALFORGE_TEST_*` globals it replaces could not be listed, could not say why it had
-- skipped, and had to be set by hand from a console that ships switched off.
--
--   pf_hooks       list every declared hook, its gate state, and the sentence that opens it
--   pf_hook <id>   run one by its plan/TODO.md id (the console passes the argument through)
--   pf_hooks_all   run every hook whose gate is open, read-only ones first
--
-- ⚠️ A CLOSED GATE IS PRINTED, NEVER SKIPPED SILENTLY. Three input routes and one skipped test
-- have each cost this tree a session by being indistinguishable from "ran and found nothing".
pf_hooks = function()
    local hooks = require("palforge.test.hooks")
    for _, line in ipairs(hooks.report()) do log.info(line) end
end,

-- Takes the id as its one argument. From the UE4SS console that is `pf_hook pal-skills-equip`;
-- from autorun.txt it is the generated per-hook name instead (pf_hook_pal_skills_equip),
-- because core/autorun.lua reads `[delay] name` and has no way to carry an argument.
pf_hook = function(id)
    local hooks = require("palforge.test.hooks")
    if id == nil or id == "" then
        log.warn("pf_hook needs an id: pf_hook <id>. `pf_hooks` lists them.")
        for _, line in ipairs(hooks.report()) do log.info(line) end
        return
    end
    hooks.run(tostring(id))
end,

pf_hooks_all = function()
    local hooks = require("palforge.test.hooks")
    hooks.runAll()
end,

-- pf_keys — PRINT PALWORLD'S WHOLE LIVE KEYMAP, AND WHAT EVERY BINDABLE NAME'S STATUS IS.
--
-- The single highest-value action in this table, and the one that did not exist for the whole
-- of the session that produced the three input failures at the top of this file. Until now
-- "can I have F6?" cost a deploy, a world load, a keypress and a log that said nothing either
-- way. It now costs a lookup.
--
-- READ-ONLY, ONE SHOT, NOTHING TO DO IN GAME. It walks properties only — no UFunction is
-- called anywhere in the path (core/keyboard/base/keymap.lua's header says why that matters),
-- nothing is written to the player's settings or save, and it takes about a second.
--
-- IT NEEDS A LOADED WORLD. UPalOptionSubsystem is a UPalWorldSubsystem: at the title screen it
-- does not exist and the config half cannot be read. Run it from inside a save.
--
-- WHAT COMES OUT, in four blocks:
--   1. the SOURCES and the change WATCHES, one line each with their state — so "the keymap is
--      empty" can never be the whole story; the line above it says which read refused and why.
--   1b. ★ NEW, AND THE FIRST THING TO READ: one CONTAINER line per TMap and TArray touched,
--      carrying the container's OWN size (`#=`) beside what the reader got out of it. The first
--      live run of this probe ended with "resolved but empty" and two hypotheses, because
--      nothing separated "the game has nothing here" from "our reader dropped it". These lines
--      settle it every time:
--        #=0                     the container says it is empty. A REAL ANSWER. Palworld keeps
--                                the key config as OVERRIDES, so a save where nobody rebound a
--                                key legitimately has nothing in it.
--        #=?                     the property would not answer `#` at all — nothing is claimed.
--        #=N with added=0        ⚠️ the only one of the three that is a bug in PalForge.
--        found<N                 the map has entries no action-name source could name; they are
--                                unseen rather than absent, and the count says how many.
--      `via` names the route that carried it: ForEach, index, Find, or ForEach+Find.
--   2. every key the game has an action on, with the action names and where each mapping came
--      from: [config/main] and [config/second] are the PLAYER'S own bindings, [config/axis] is
--      movement, [config/ui] is the menu keys, [project/*] is the shipped DefaultInput.ini and
--      [project/console] is UE's own console key.
--   3. THE LOOKUP TABLE: one row per name UE4SS can bind, its Unreal FKey name, and its status —
--      free / game / palforge / unknown. This is the block to copy out and keep.
--
-- HOW TO READ A STATUS:
--   free      no action in the game's key config uses it. The strongest thing anyone can say
--             about a key here — and STILL not a promise the press arrives, because the Steam
--             overlay, the OS and UE's own bindings are outside this config.
--   game      Palworld has an action on it. Binding it means both fire, or the press never
--             reaches UE4SS at all. That is what F7 was.
--   palforge  this mod already holds it (F1 is the test runner). The right-hand column says
--             which binding, and a ⚠️ there means it collides with the game as well.
--   unknown   the config could not be read (no world), or Unreal has no FKey name for that
--             UE4SS name at all. Never treat one as free.
--
-- WHAT IT COSTS, so the number in the log can be checked rather than trusted: the refresh line
-- prints its own wall-clock seconds and the number of name look-ups it made. Zero look-ups means
-- every container walked cleanly or was honestly empty; a few hundred means a map held entries
-- the walk did not produce and each candidate action name was asked about with Contains().
pf_keys = function()
    local keymap = require("palforge.core.keyboard.base.keymap")
    local reg    = require("palforge.core.keyboard.base.registory")
    log.info("#### BEGIN keymap")
    local n, note = keymap.refresh()
    log.info("pf_keys: refresh -> " .. tostring(note))
    for _, line in ipairs(keymap.lines()) do log.info("pf_keys " .. line) end
    for _, line in ipairs(reg.report()) do log.info("pf_keys " .. line) end
    for _, line in ipairs(keymap.lookup(reg.owned(), reg.FORBIDDEN)) do log.info("pf_keys " .. line) end
    log.info("#### END keymap")
    support.announce(string.format("pf_keys: %d game mapping(s) in %.3f s (%d name look-up(s)) "
        .. "— UE4SS.log has the lookup table, and the `keymap:   <source> <container>` lines "
        .. "above it say what each container held", n,
        keymap.state.cost or 0, keymap.state.lookups or 0))
end,
-- ---- commands that CREATE the situation a source needs ----
--
-- Two channels are only observable while something specific is happening, and both used to
-- mean "go and play until it does". skill.hit needs a melee blow that actually connects, and
-- skill.equip needs a passive to change on a real pal — which in an ordinary save means
-- catching a pal strong enough to fight, i.e. grinding a game you may not want to grind.
--
-- PalForge can make both. Spawning works and is measured; the passive write goes through the
-- same AddPassiveSkill this tree already hooks. So these produce the situation instead of
-- waiting for it.
-- NO COORDINATE, deliberately. The coordinate route works — it places the pal exactly, off by
-- 0 — but placing is an extra step that can put a pal somewhere a player cannot see or reach:
-- a live run put one at z=8521, reported success, and the player never found it. Without a
-- coordinate the game itself decides, which is beside the player, and that is the whole
-- requirement here: something to hit.
--
-- Then it LOOKS BACK. "The call was issued" is not "there is a pal in front of me", and the gap
-- between those two is what wasted a run — so this reports what is actually nearby, with its
-- class and its distance, instead of leaving anyone to go and search.
pf_spawn = function()
    local Pal  = require("palforge.api.pal")
    local poll = require("palforge.core.poll")
    local ok = Pal.get(support.GAME.pal):spawn()
    log.info(string.format("pf_spawn: %s issued for %s — the game places it beside you, and it "
        .. "takes a few seconds", tostring(ok), support.GAME.pal))

    poll.every("pf_spawn look-back", function(elapsed)
        if elapsed < 10 then return false end
        local pal, cls = support.nearbyPal()
        if not pal then
            log.warn("pf_spawn: 10 s later there is still no PalMonsterCharacter near you")
            return true
        end
        local here, there = support.location(support.player()), support.location(pal)
        local d = (here and there)
            and math.sqrt((there.x - here.x) ^ 2 + (there.y - here.y) ^ 2 + (there.z - here.z) ^ 2)
            or nil
        log.info(string.format("pf_spawn: the nearest pal is a %s, %s away — that is what to hit "
            .. "for skill.hit", tostring(cls), d and string.format("%.0f cm", d) or "unreadable"))
        return true
    end)
end,

-- pf_mesh — THE ONE ACTION THAT PUTS A GAME ASSET ON SCREEN.
--
-- Everything about the mesh chain has been "declared correctly" for a while and nothing has
-- been WATCHED. This settles that in one run, in three stages, and each stage's log line means
-- something different:
--
--   [1] RESOLVE (read-only). core.mesh.assets tries every catalogued /Game/... path and prints
--       `ASSET OK`/`ASSET MISS` with the class of whatever came back. This is the half no dump
--       could ever settle for the animation blueprints — 05_assets.txt:803 says
--       `AnimBlueprint classes : 0 loaded` and dumps/cxx ships ABP_Player.hpp, so the question
--       has always been the RESOLVE, and `ASSET OK ABP.PinkCat -> AnimBlueprintGeneratedClass
--       ...` is the line that closes it. `ASSET MISS ABP.*` closes it the other way and says
--       loading an asset does not bring its generated class in.
--
--   [2] ATTACH, through the PUBLIC api. `Mesh{ ... }:attachTo(player)`, not a core call — the
--       point is the pack-facing 導線, so it goes the way a pack goes. `kind = "static"` adds a
--       component OF OURS to the player and touches nothing the player already wears; a
--       skeletal attach would swap the player's own body, which nothing unattended may do to
--       someone's save. A red tint is declared as well, so one look answers two questions.
--
--   [3] LOOK, then UNDO. 30 s on the clock (core.poll, elapsed — never a tick count), then
--       :detach destroys the component again. WHAT TO LOOK FOR, in order of what it proves:
--         * a wooden chest floating in front of you  -> path -> LoadAsset -> SetStaticMesh ->
--           a visible component. The whole chain works. This has never been seen.
--         * the chest is RED                          -> the dynamic material instance and the
--           measured parameter names work too (base/renderer.lua's COLOR_PARAMS).
--         * a chest but NOT red                       -> mesh chain yes, material names no —
--           read the MATDESC block this prints for the names that asset really carries.
--         * nothing at all, with `attachTo -> true`   -> it attached somewhere you cannot see;
--           the offset below is relative to the pawn, so raise OFFSET.z and run it again.
--         * nothing at all, with `attachTo -> false`  -> the log line above it says which step.
pf_mesh = function()
    local Mesh = require("palforge.api.mesh")
    local mesh = require("palforge.core.mesh")
    local poll = require("palforge.core.poll")

    -- [1] resolve every catalogued path. Read-only; loads packages and touches no actor.
    log.info("pf_mesh [1/3] resolving every known /Game/... path (read-only)")
    local found = mesh.probeAssets(support.log)
    local ok, miss = 0, 0
    for _, r in ipairs(found) do if r.ok then ok = ok + 1 else miss = miss + 1 end end
    log.info(string.format("pf_mesh [1/3] %d resolved, %d did not, of %d catalogued paths",
        ok, miss, #found))

    local pawn = support.player()
    if not pawn then
        log.warn("pf_mesh [2/3] no player pawn, so nothing can be dressed - the resolve above "
            .. "is still the answer to the asset half")
        return
    end

    -- [2] attach, through the public api, exactly as a pack would write it.
    -- ChestWood is the single strongest path in the catalog: the live loaded-object sweep
    -- printed it (05_assets.txt:1628) AND the game was rendering it off a real
    -- BP_BuildObject_ItemChest_C's StaticMeshComponent (04_live_objects.txt:6).
    local OFFSET = { x = 150, y = 0, z = 120 }
    local handle = Mesh{
        id    = support.id("mesh_live"),
        kind  = "static",
        model = mesh.assets.SM.ChestWood,
        scale = 1.0,
        offset = OFFSET,
        color = { 1.0, 0.15, 0.15, 1.0 },
    }
    local attached = handle:attachTo(pawn)
    log.info(string.format("pf_mesh [2/3] attachTo -> %s | %s at +%d,+%d,+%d from you",
        tostring(attached), mesh.assets.SM.ChestWood, OFFSET.x, OFFSET.y, OFFSET.z))
    if not attached then
        log.warn("pf_mesh [2/3] nothing was attached - the [mesh] log line just above names "
            .. "the step that refused (resolve, AddComponentByClass, SetStaticMesh, read-back)")
        return
    end

    -- What the asset's OWN materials are called. This is the same read that found BaseColor
    -- and 'Base Texture' on the player, pointed at a shipped prop instead: if the tint below
    -- does not land, these are the names it should have been writing.
    mesh.describeMaterials(pawn, support.log)

    -- [3] look at it, then take it off again. Bounded on ELAPSED SECONDS, never on ticks:
    -- the heartbeat's bodies drain in bursts and a tick budget can expire in one second
    -- (core/poll.lua's own warning).
    log.info("pf_mesh [3/3] LOOK IN FRONT OF YOU - it comes off again in 30 s")
    support.announce("pf_mesh: a chest should be in front of you (red if the tint landed)")
    poll.every("pf_mesh detach", function(elapsed)
        if elapsed < 30 then return false end
        local gone = handle:detach(pawn)
        log.info(string.format("pf_mesh [3/3] detach -> %s (true = K2_DestroyComponent ran and "
            .. "the component is off; false = it did not, and the chest is still there)",
            tostring(gone)))
        return true
    end)
end,

pf_teach = function()
    local character = require("palforge.core.character")
    local pal, cls = support.nearbyPal()
    if not pal then
        log.warn("pf_teach: no pal near you — run pf_spawn first, wait for it, then try again")
        return
    end
    -- A PASSIVE, deliberately. Passives go in as FNames through AddPassiveSkill, which is
    -- the call this tree hooks for skill.equip; the ACTIVE-move write is a different call
    -- (AddEquipWaza), it once correlated with the game closing, and it is still opt-in.
    -- WHERE THAT OPT-IN LIVES HAS MOVED: it is the declared hook `pal-skills-equip`
    -- (test/hooks/pal_skills_equip.lua), armed with `env.debugHooks["pal-skills-equip"] = true`
    -- and run by name with `pf_hook pal-skills-equip`. The old spelling
    -- `_G.PALFORGE_TEST_WRITE_WAZA = true` still works and is still honoured — plan/TODO.md,
    -- test/cases/skill.lua and core/character.lua:59 all name it — but the hook is where the
    -- measurement is written down now, and it is the one that reads its target's class back
    -- before it writes.
    local SKILL = "Legend"
    log.info(string.format("pf_teach: giving %s to the nearest pal (a %s)", SKILL, tostring(cls)))
    local ok = character.addSkill(pal, SKILL)
    log.info(string.format("pf_teach: %s — watch for skill.equip carrying its first event",
        ok and "the read-back shows it on the pal" or "the read-back did not show it"))
end,

-- The ONE claim about the native catalogs that a headless run cannot settle.
--
-- test/cases/native proves the naming rule, the laziness and the identity of the handles, and
-- all of that is pure Lua. What it cannot prove is that a handle reached BY NAME — with nothing
-- declared on it, no icon, no mesh — still answers with the game's own icon, which is the whole
-- reason a native handle is worth having over a bare id string. :iconOf() goes through
-- core/icons to a live DataTable, so it needs a loaded world and it needs the game.
--
-- It also looks at the two things a lazy handle must NOT claim, so a false is reported as the
-- correct answer rather than read as a failure: no declared mesh (the game draws its own) and no
-- declared stack size (that is a DataTable column this build cannot read).
pf_native = function()
    local native = require("palforge.native")
    local probes = {
        { "buildings", "PalBoxV2"    }, { "buildings", "Workbench" },
        { "items",     "Arrow_Fire"  }, { "items",     "Stone"     },
        { "pals",      "BlueSkyDragon" }, { "pals",    "Sheepball" },
        { "skills",    "BOSS_FireKirin" },
    }
    log.info("pf_native: reading a NAMED handle out of each catalog — nothing was declared on any "
        .. "of these, so every answer below comes from the game")
    for _, p in ipairs(probes) do
        local mod, name = native[p[1]], p[2]
        local h = mod and mod[name]
        if not h then
            log.warn(string.format("pf_native: native.%s.%s did not resolve at all", p[1], name))
        else
            local okIcon, icon = pcall(function() return h:iconOf() end)
            log.info(string.format("pf_native: native.%s.%s -> id=%s icon=%s",
                p[1], name, tostring(h.id),
                (okIcon and icon ~= nil) and tostring(icon) or "nil (no row, or the read did not fire)"))
        end
    end

    -- and the honest negatives, named so a reader does not mistake them for breakage
    local box = native.buildings.PalBoxV2
    log.info(string.format("pf_native: PalBoxV2 has %d live instance(s); :render() attached %d of "
        .. "them (0 is CORRECT for a curated mesh the game already draws over)",
        #box:instances(), box:render()))
    local gate = native.buildings.Stone_Gate
    log.info(string.format("pf_native: Stone_Gate declares no mesh (%s), so :render() is %d — the "
        .. "game is drawing its own", tostring(gate:mesh()), gate:render()))
    log.info(string.format("pf_native: items.Stone:count()=%s (LIVE), :maxStack()=%d (PalForge's "
        .. "default, NOT the game's column — see native/items.lua)",
        tostring(native.items.Stone:count()), native.items.Stone:maxStack()))
end,

-- pf_uidecl — A DECLARED PANEL, INSIDE THE GAME'S OWN UI. The other action that puts something
-- on screen, and the only one that puts it in a panel the GAME draws.
--
-- MOUNTING IS CLOSED. The panel was seen, on screen, in the game's own canvas:
--   pf_uidecl: MOUNTED into PalPrimaryGameLayoutBase.CanvasPanel_Root | slot=CanvasPanelSlot
-- What was NOT closed is everything after that: the button did nothing, and four separate
-- things could each have been the reason. This run separates them, and every outcome below is
-- attributable to exactly one of them rather than to "the UI does not work".
--
-- WHAT THIS RUN IS ASKING, in the order the log answers it:
--
--   1. IS A CLICK HOOK ARMED AT ALL. The router prints one line per route with the ids
--      RegisterHook returned, or the refusal text it threw. The old code pcall'd that away and
--      printed "hook installed" / "hook FAILED" with no reason, which is why nobody could tell.
--   2. DOES ANY CLICK REACH ANY WIDGET. Each route counts every click it sees on every
--      CommonUI button in the whole game — not just ours. So `seen=0` after you have clicked
--      the game's own menu buttons means no hook is firing; `seen>0, dispatched=0` means the
--      hooks work and OUR widget is not the one being clicked.
--   3. CAN THE MOUSE REACH OURS. The panel declares `input = "clicks"`, so it asks the engine
--      for Game+UI and a cursor. If that call lands you can click it during ordinary play; if
--      it does not, the Esc route is the fallback and step 2 tells the two apart.
--   4. DOES IT LOOK NATIVE. A UI.Frame (the game's own WBP_PalCommonWindow chrome), a
--      `native = true` label (BP_PalTextBlock_C) and a UI.Sprite showing the vanilla Wood icon.
--      Any of the three that could not use the game's widget logs a `[ui]` warning naming which
--      class was missing and what was used instead — it never fails silently and never fails
--      the mount.
--
-- WHAT TO LOOK FOR ON SCREEN, in order of what each one proves:
--   * a panel with the game's own window chrome, top-left  -> Frame adopted WBP_PalCommonWindow.
--     A plain dark rectangle instead -> the fallback Border; read the [ui] warning for why.
--   * a small item icon next to the text                   -> Sprite: core/icons resolved a
--     vanilla id to a real texture and SetBrushFromTexture landed. Never seen before this run.
--   * the "alive N s" line COUNTS UP                       -> bindings re-evaluate on the poll.
--   * clicking the button changes ITS OWN label            -> the whole loop: hook -> router ->
--     instance state -> binding -> the button's own SetText.
--   * a mouse cursor you can move onto the panel           -> input = "clicks" landed.
-- It stays on screen: nothing takes it down but a reload (F9) or leaving the world.
pf_uidecl = function()
    local UI   = require("palforge.api.ui")
    local tree = require("palforge.native.ui").tree
    local poll = require("palforge.core.poll")
    local VBox, HBox, Label, Button = UI.VBox, UI.HBox, UI.Label, UI.Button
    local Frame, Sprite, SizeBox = UI.Frame, UI.Sprite, UI.SizeBox
    local t0 = os.clock()

    local Panel = UI{
        id    = "palforge_test:DeclPanel",
        name  = "Declared panel",
        host  = "game",     -- CanvasPanel_Root inside WBP_PalOverallUILayout
        -- ASK FOR THE MOUSE. The default is "none" and the default is right for a HUD readout;
        -- this panel has a button, so it says so. On unmount the cursor flag goes back exactly
        -- as it was and the input mode is left alone (Game+UI still lets the player move and
        -- look) — see the INPUT block in native/ui/_widget.lua.
        input = "clicks",
        root  = Frame{ color = { 0.05, 0.04, 0.03, 0.92 },
            VBox{ padding = 10,
                Label{ text = "PalForge — declared UI", size = 20, native = true },
                HBox{
                    -- Wood is an item id every save has. A miss here is a NAMED miss: the
                    -- sprite maker says whether core/icons had no row or the texture did not
                    -- load, and the mount fails with that sentence rather than drawing blank.
                    SizeBox{ width = 48, height = 48,
                        Sprite{ name = "icon", icon = "Wood", matchSize = false } },
                    Label{ name = "clock", vAlign = "center", padding = { left = 8 },
                           text = function() return string.format("alive %.0f s", os.clock() - t0) end },
                },
                Button{ name = "hit",
                        text    = function(self) return "clicked " .. (self.clicks or 0) .. "x" end,
                        onClick = function(self) self.clicks = (self.clicks or 0) + 1 end },
            },
        },
    }

    -- autoMount, not mount: at the moment this runs the in-game layout may not be up yet, and
    -- the same subscription that keeps retrying is the one that refreshes the bindings once it
    -- is in. One heartbeat subscription, no timer of its own (api/ui.lua's poll).
    local panel = Panel:new{ clicks = 0 }
    panel:autoMount(nil, 1000)
    log.info("pf_uidecl: a declared panel is trying to mount into the game's own UI root")

    local function reportClicks(when)
        for _, line in ipairs(tree.clickReport()) do log.info("pf_uidecl " .. when .. ": " .. line) end
    end

    poll.every("pf_uidecl look-back", function(elapsed)
        if elapsed < 12 then return false end
        if not panel:isMounted() then
            log.warn("pf_uidecl: NOT mounted after 12 s — " .. tostring(panel:lastError()))
            reportClicks("at 12 s")
            return true
        end
        -- The evidence line: which slot class the canvas handed back, and the full name of the
        -- widget that is now in the game's tree. Both are read off the built tree rather than
        -- inferred, and a "CanvasPanelSlot" here is what closes ui-host-paths on OBSERVATION.
        local st = panel:state()
        local slotCls, rootName, rootCls, hostWhat = "?", "?", "?", "?"
        pcall(function() slotCls = st._tree.slot:GetClass():GetFName():ToString() end)
        pcall(function() rootName = st._tree.root:GetFullName() end)
        pcall(function() rootCls = st._tree.root:GetClass():GetFName():ToString() end)
        pcall(function() hostWhat = st._host.what end)
        log.info(string.format("pf_uidecl: MOUNTED into %s | slot=%s | root=%s | rootClass=%s",
            hostWhat, slotCls, rootName, rootCls))
        -- rootClass is the LOOK question in one word: WBP_PalCommonWindow_C means the panel is
        -- wearing the game's own chrome; Border means the fallback ran and a [ui] warning above
        -- says which class was missing.
        log.info(string.format("pf_uidecl: input grab -> %s",
            st._input and table.concat(st._input.applied or {}, " + ")
                .. (st._input.note and ("  [" .. st._input.note .. "]") or "")
                or "none taken (read the [ui] line above for why)"))
        reportClicks("at 12 s")
        support.announce("pf_uidecl: panel up — click its button; then press Esc and click again")
        return true
    end)

    -- THE SECOND LOOK IS THE MEASUREMENT. Twelve seconds in, nobody has clicked anything yet and
    -- every counter is zero, which proves nothing. This one runs a minute later, by which time
    -- the player has been asked to click our button twice and the game's own menu once — and the
    -- three counters then say which of the four candidate faults is the real one.
    poll.every("pf_uidecl click verdict", function(elapsed)
        if elapsed < 75 then return false end
        reportClicks("at 75 s")
        local st = panel:state()
        log.info(string.format("pf_uidecl: our button was clicked %d time(s) as far as the "
            .. "element is concerned", tonumber(st.clicks) or -1))
        log.info("pf_uidecl: HOW TO READ THE THREE LINES ABOVE — "
            .. "(a) a route that says `refused` never armed, and its bracketed text is "
            .. "RegisterHook's own message; "
            .. "(b) seen=0 on BOTH routes after you clicked the game's own menu means no click "
            .. "hook fires at all on this build, and the click PATH is the fault; "
            .. "(c) seen>0 with dispatched=0 means the hooks fire for the game's buttons and "
            .. "never for ours — the mouse is not reaching our widget, which is the input half; "
            .. "(d) dispatched>0 with clicks=0 means the router delivered and the handler or the "
            .. "binding is the fault. Exactly one of these is true.")
        return true
    end)
end,

-- pf_uiroute — ⚠️ WHAT PALWORLD ITSELF DOES WITH ITS UI, ITS INPUT MODE AND ESC.
--
-- THE MOST IMPORTANT ACTION IN THIS FILE, and the one that should have existed before anything
-- of ours ever touched an input mode. Two live runs broke Esc while a PalForge panel was up, and
-- both times the diagnosis was a guess about UE internals this repo cannot read. This does not
-- guess: it reads the game's own objects and then WATCHES the game do the thing, with hooks whose
-- whole body is a counter.
--
-- WHAT THE DUMP ALREADY SETTLED (so this probe only has to confirm it in the running process):
--   * Palworld screens declare their input mode as DATA on the widget —
--     UPalActivatableWidget.InputConfig / .GameMouseCaptureMode (Pal.hpp:13369-13370),
--     EPalWidgetInputMode { Default, GameAndMenu, Game, Menu } (Pal_enums.hpp:5367).
--   * CommonUI's action router applies it, and the game WATCHES it change from the outside:
--     APalHUDInGame::OnActiveInputModeChanged(ECommonInputMode) (Pal.hpp:9742).
--   * Esc is not a key: it is the UI action "UIEscape" / "UICancel" (rows of DT_UIInputAction),
--     bound by UPalUserWidget::RegisterActionBinding (Pal.hpp:31898) or claimed generically with
--     bIsBackHandler / BP_OnHandleBackAction (CommonUI.hpp:149, :172).
--   * A screen is put up through a LAYER: UPrimaryGameLayout.Layers (CommonGame.hpp:158) and
--     UCommonActivatableWidgetContainerBase::BP_AddWidget (CommonUI.hpp:194).
--
-- WHAT ONLY A RUN CAN ANSWER, and each is one line of this block's output:
--   1. WHICH LAYER TAGS this layout registers. They are registered at runtime
--      (RegisterLayer, CommonGame.hpp:160) and no header lists them. `host = "layer"` needs one.
--   2. WHAT THE GAME'S OWN SCREENS DECLARE in InputConfig — i.e. what value PalForge should be
--      writing for "clicks" and for "exclusive", read off the widgets rather than chosen.
--   3. DOES OnActiveInputModeChanged FIRE when a menu opens. If it does, the router really is
--      the thing that owns the mode, and writing the mode anywhere else is writing behind it.
--   4. WHICH ACTIONS the game binds, on what, and whether Esc arrives as one.
--   5. WHETHER BP_OnHandleBackAction IS EVEN CALLED on this build — the route api/ui's
--      `backHandler` depends on.
--
-- ⚠️ IT ARMS HOOKS, AND UE4SS CANNOT UNREGISTER ONE (core/event.lua:33 and :2161). They stay for the
-- session. Every handler here is a counter plus one pcall'd string read, capped at the first few
-- dozen samples, which is the shape probes/uievents.lua established as survivable.
--
-- WHAT TO DO IN GAME: open the INVENTORY and close it, then press ESC to open the pause menu and
-- ESC again to close it. That is all. Verdicts print themselves at 30 s, 60 s and 90 s.
pf_uiroute = function()
    local native = require("palforge.native.ui")
    local widget, tree = native.widget, native.tree
    local sig  = require("palforge.core.signature")
    local poll = require("palforge.core.poll")

    local S = { hooks = {}, counts = {}, samples = {}, armed = {} }
    local function say(fmt, ...) log.info("pf_uiroute: " .. string.format(fmt, ...)) end
    local function sample(bucket, text)
        local list = S.samples[bucket]
        if not list then list = {}; S.samples[bucket] = list end
        if #list < 24 then list[#list + 1] = tostring(text) end
    end

    log.info("#### BEGIN ui-common-route")

    -- [1] THE LAYERS. The one question `host = "layer"` cannot be written without.
    say("[1/5] the in-game layout's registered CommonUI layers (UPrimaryGameLayout.Layers, "
        .. "CommonGame.hpp:158) — these tag names are the argument host = \"layer\" takes")
    for _, line in ipairs(tree.layerReport()) do log.info("pf_uiroute " .. line) end

    -- [2] THE CENSUS. Every live Palworld activatable, and the two bytes that ARE the input mode
    -- on this build. Reading them off the game's own screens is how PalForge learns what to
    -- write, instead of picking an enum value out of a header and hoping.
    say("[2/5] live UPalActivatableWidget census — InputConfig is EPalWidgetInputMode "
        .. "{0 Default, 1 GameAndMenu, 2 Game, 3 Menu} (Pal_enums.hpp:5367); GameMouseCaptureMode "
        .. "is EMouseCaptureMode {0 NoCapture .. 3 DuringMouseDown} (Engine_enums.hpp:2237)")
    local seen, active, shown = 0, 0, 0
    for _, className in ipairs({ "PalActivatableWidget", "PalUserWidget" }) do
        local all = {}
        pcall(function() all = FindAllOf(className) or {} end)
        for _, w in ipairs(all) do
            seen = seen + 1
            local row = {}
            local isActive
            pcall(function() isActive = w.bIsActive end)
            if isActive then active = active + 1 end
            -- Only the ACTIVE ones are printed in full: an in-game session holds hundreds of
            -- widget archetypes and a census that prints all of them is a census nobody reads.
            if isActive and shown < 24 then
                shown = shown + 1
                for _, f in ipairs({ "InputConfig", "GameMouseCaptureMode", "bIsBackHandler",
                                     "bIsModal", "bSupportsActivationFocus", "bAutoActivate" }) do
                    local v; pcall(function() v = w[f] end)
                    row[#row + 1] = f .. "=" .. tostring(v)
                end
                local cls; pcall(function() cls = w:GetClass():GetFName():ToString() end)
                log.info(string.format("pf_uiroute VALUE active %-44s %s",
                    tostring(cls), table.concat(row, " ")))
            end
        end
        if seen > 0 then break end
    end
    say("[2/5] %d activatable(s) live, %d ACTIVE, %d printed", seen, active, shown)
    if active == 0 then
        say("[2/5] nothing is active — either this ran before the HUD came up, or FindAllOf does "
            .. "not reach these. Open a menu and run pf_uiroute again; the number is the answer.")
    end

    -- [3] THE DECLARATIONS. sig.describe calls NOTHING; it prints the live parameter list, which
    -- is the fact a correct call needs and the fact no header can be trusted for.
    say("[3/5] the shapes, read off the live UFunctions — nothing is called")
    local layers = widget.uiLayers()
    if layers[1] and layers[1].container then
        sig.describe(layers[1].container, "BP_AddWidget")
        sig.describe(layers[1].container, "RemoveWidget")
        sig.describe(layers[1].container, "GetActiveWidget")
    else
        say("[3/5] no layer container to read BP_AddWidget off — see block [1/5]")
    end
    local anyWidget = widget.findFirst("PalUserWidget")
    if anyWidget then
        sig.describe(anyWidget, "RegisterActionBinding")
        sig.describe(anyWidget, "RegisterActionBinding_NotConcume")
        sig.describe(anyWidget, "ActivateWidget")
    end
    local hudLayout = widget.findFirst("PalUIHUDLayoutBase")
    if hudLayout then sig.describe(hudLayout, "AddHUD") end
    local hud = widget.findFirst("PalHUDInGame")
    if hud then sig.describe(hud, "AddHUD") end

    -- [4] THE HOOKS. Counters, and a capped pcall'd sample of the one string that matters.
    say("[4/5] arming the watchers — they cannot be unregistered and stay for the session")
    local HOOKS = {
        { key = "inputModeChanged", path = "/Script/Pal.PalHUDInGame:OnActiveInputModeChanged",
          why = "the ROUTER telling the game its active input mode changed. If this fires when "
             .. "you open a menu, the router owns the mode and writing it anywhere else is "
             .. "writing behind it — which is the whole diagnosis of the two broken Esc runs" },
        { key = "actionBound",      path = "/Script/Pal.PalUserWidget:RegisterActionBinding",
          why = "every named UI action the game's own screens bind. Look for UIEscape / UICancel" },
        { key = "actionBoundFree",  path = "/Script/Pal.PalUserWidget:RegisterActionBinding_NotConcume",
          why = "the same, in the game's own non-consuming form" },
        { key = "backAction",       path = "/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction",
          why = "the generic BACK handler. If this never fires, api/ui's `backHandler` cannot "
             .. "work on this build and the action-name route is the only one left" },
        { key = "activated",        path = "/Script/CommonUI.CommonActivatableWidget:ActivateWidget",
          why = "a screen coming up — the moment the router reads InputConfig" },
        { key = "deactivated",      path = "/Script/CommonUI.CommonActivatableWidget:DeactivateWidget",
          why = "a screen going down — the moment the router puts the previous mode back" },
    }
    for _, h in ipairs(HOOKS) do S.counts[h.key] = 0 end
    if type(RegisterHook) ~= "function" then
        say("[4/5] RegisterHook is unavailable this session; nothing is watched and blocks 3-5 "
            .. "of the question list stay open")
    else
        for _, h in ipairs(HOOKS) do
            local key = h.key
            local ok = pcall(RegisterHook, h.path, function(ctx, p1)
                S.counts[key] = S.counts[key] + 1
                -- ONE pcall'd read, capped. The context and the first parameter are the only two
                -- things worth having, and both are read through :get() inside a pcall because a
                -- half-initialised object is exactly the read that has faulted natively before.
                pcall(function()
                    local o = ctx and ctx.get and ctx:get() or nil
                    local cls = o and o:GetClass():GetFName():ToString() or "?"
                    local arg = ""
                    if p1 and p1.get then
                        local v = p1:get()
                        arg = " " .. tostring(v and v.ToString and v:ToString() or v)
                    end
                    sample(key, cls .. arg)
                end)
            end)
            S.armed[key] = ok == true
            log.info(string.format("pf_uiroute VALUE armed %-62s -> %s", h.path,
                ok and "ok" or "FAILED (not hookable on this build)"))
        end
    end
    log.info("#### END ui-common-route")

    say("[5/5] NOW, IN GAME, and it is two ordinary actions: (a) open your INVENTORY and close "
        .. "it. (b) press ESC to open the pause menu and ESC again to close it. Nothing else. "
        .. "Verdicts print at 30 s, 60 s and 90 s.")
    support.announce("pf_uiroute: open the inventory, then press Esc twice")

    local phase = 0
    poll.every("pf_uiroute", function(elapsed)
        local due = (elapsed >= 30 and phase < 1) and 1
            or (elapsed >= 60 and phase < 2) and 2
            or (elapsed >= 90 and phase < 3) and 3 or nil
        if not due then return elapsed >= 95 end
        phase = due
        log.info(string.format("#### BEGIN ui-common-route-%d", phase))
        for _, h in ipairs(HOOKS) do
            log.info(string.format("pf_uiroute VALUE %-18s fired=%-6d armed=%s",
                h.key, S.counts[h.key], tostring(S.armed[h.key])))
            for _, s in ipairs(S.samples[h.key] or {}) do
                log.info("pf_uiroute SAMPLE " .. h.key .. ": " .. s)
            end
        end
        if phase == 3 then
            log.info("pf_uiroute NOTE HOW TO READ IT, in the order the answers matter:")
            for _, h in ipairs(HOOKS) do
                log.info(string.format("pf_uiroute NOTE   %-18s %s", h.key, h.why))
            end
            log.info("pf_uiroute NOTE inputModeChanged > 0 CONFIRMS the design PalForge now "
                .. "follows: the mode belongs to the CommonUI action router, is derived from the "
                .. "activatable stack, and is restored by DEACTIVATION rather than by any call. "
                .. "inputModeChanged == 0 while menus opened and closed would falsify it, and "
                .. "would be the single most valuable line in this log.")
            log.info("pf_uiroute NOTE actionBound / actionBoundFree SAMPLES name the UI actions "
                .. "the game binds and the widget class each is bound on. A \"UIEscape\" or "
                .. "\"UICancel\" among them is the exact mechanism a mod would have to join to be "
                .. "IN Esc's path rather than beside it — and the reason ESCAPE stays refused as "
                .. "a UE4SS keybind is that a keybind can only ever be beside it.")
            log.info("#### END ui-common-route-3")
            return true
        end
        log.info(string.format("#### END ui-common-route-%d", phase))
        return false
    end)
end,

-- pf_uiz — THREE PANELS, AND THE THREE THINGS THE LAST RUN LEFT OPEN.
--
-- The previous run answered the z-order and BOTH halves of the key-routing rule, and they are
-- not re-litigated here; they ride along because the same two panels prove them for free. What
-- it left open, and what this run is shaped around:
--
--   ⚠️ 1. DOES ESC WORK. The last run made it WORSE — the game's menu would not even open — and
--      the cause is now understood: PalForge was calling SetInputMode_GameAndUIEx on the player
--      controller, which is not how Palworld works. Palworld declares the mode on the WIDGET
--      (UPalActivatableWidget.InputConfig, Pal.hpp:13369) and lets CommonUI's action router
--      apply and restore it. PalForge no longer makes that call ANYWHERE. So the first thing to
--      do in this run is press Esc, and it should behave exactly as it does with no mod loaded.
--
--   2. THE MOUSE HALF, which has never once been exercised. The last run refused
--      MIDDLE_MOUSE_BUTTON, correctly: the keymap knows the game binds it (DirectAttackOrder)
--      and PalForge does not take a bound input without being told to. On a default install ALL
--      THREE mouse buttons are bound, so there is no "free" one to pick instead — the honest
--      move is to say so at the call site, which is what `overrideButtons = { "middle" }` is.
--      ⚠️ THE GAME'S OWN ACTION STILL FIRES: a UE4SS keybind observes and never consumes, so
--      middle-clicking will ALSO order your pal to attack. That is what an override means and
--      this run is where it gets demonstrated honestly rather than described.
--
--   3. THE FRAME COLOUR. The last run reported the bottom panel drawing BLACK where a colour was
--      declared on the Frame. `Frame{ color = ... }` is now REFUSED at define time — a Frame
--      wears the game's own window art and nothing here can tint it — so this run declares the
--      colour where it belongs, on a Border INSIDE the frame, in a colour nobody can mistake for
--      black. Whether the game's chrome is there at all is answered by the `rootClass=` line:
--      WBP_PalCommonWindow_C means the chrome, Border means it fell back and a [ui] warning
--      above says why.
--
--   4. ⚠️ AND THE NEW ROUTE, measured for the first time: a third panel declares host = "layer"
--      and asks the GAME to put it up — BP_AddWidget on one of the layout's own CommonUI layers
--      (CommonUI.hpp:194), which creates, stacks, activates and registers it with the action
--      router, and RemoveWidget takes all of that back. It also declares backHandler = true,
--      i.e. it CLAIMS the CommonUI back action, which is how a Palworld screen says "Esc closes
--      me". If it never mounts, its lastError() says which step refused and nothing is lost.
--
-- SAFE BY CONSTRUCTION, and deliberately so even though the Esc understanding may still be
-- wrong: every panel unmounts itself on ELAPSED SECONDS through core/poll (45 s, 90 s, 100 s),
-- no key is needed to get rid of any of them, and the only thing any of them takes from the
-- player is the cursor flag — which is readable, restored exactly, and additionally swept by the
-- dead-man in native/ui/_widget.lua if this Lua state disappears without unmounting.
pf_uiz = function()
    local UI   = require("palforge.api.ui")
    local tree = require("palforge.native.ui").tree
    local poll = require("palforge.core.poll")
    local VBox, Label, Border, SizeBox, Frame, Button =
        UI.VBox, UI.Label, UI.Border, UI.SizeBox, UI.Frame, UI.Button

    -- Two keys rather than one: neither is known to be free, and two independent chances cost
    -- nothing. The mouse button is OVERRIDDEN rather than declared, for the reason in the header.
    local KEYS, BUTTON = { "INS", "END" }, "middle"

    -- THE BOTTOM PANEL. The game's own window chrome, with the declared colour where a declared
    -- colour can actually land — on a Border INSIDE the frame. Bright magenta on purpose: the
    -- last run could not tell "the colour worked" from "the colour did nothing" because the
    -- colour that was declared, {0.05,0.07,0.12}, is very nearly black itself.
    local Bottom = UI{
        id    = "palforge_test:ZBottom",
        name  = "z = 10, the panel underneath",
        host  = "game",
        z     = 10,
        input = "clicks",
        keys  = KEYS,
        onKeyPressed   = function(self, ctx)
            self.keyHits = (self.keyHits or 0) + 1
            log.info(string.format("pf_uiz: BOTTOM took key %s (z=%d) — so nothing is above it "
                .. "any more", tostring(ctx.key), ctx.z))
        end,
        overrideButtons = { BUTTON },
        onMousePressed = function(self, ctx)
            self.mouseHits = (self.mouseHits or 0) + 1
            log.info(string.format("pf_uiz: BOTTOM took mouse %q (z=%d) THROUGH the panel above "
                .. "it — a press goes to the topmost panel that WANTS it. The game's own "
                .. "DirectAttackOrder fired too; an override shares, it does not steal",
                tostring(ctx.button), ctx.z))
        end,
        root = Frame{
            Border{ color = { 0.62, 0.10, 0.55, 0.92 },
                SizeBox{ width = 470, height = 260,
                    VBox{ padding = 12,
                        Label{ text = "PalForge  BOTTOM  z = 10", size = 20, native = true },
                        Label{ text = "this MAGENTA is a Border INSIDE the game's Frame" },
                        Label{ name = "counts", text = function(self)
                            return string.format("keys taken %d   |   middle-click taken %d",
                                self.keyHits or 0, self.mouseHits or 0)
                        end },
                        Label{ text = "a key reaches me only once the RED panel is gone" },
                        Button{ text = function(self)
                                    return string.format("clicked %dx  (press Esc first)",
                                        self.clicks or 0)
                                end,
                                onClick = function(self)
                                    self.clicks = (self.clicks or 0) + 1
                                    log.info("pf_uiz: BOTTOM's button was CLICKED — the click "
                                        .. "router reached our widget")
                                end },
                        Label{ text = "I go away by myself at 100 s" },
                    },
                },
            },
        },
    }

    -- THE TOP PANEL. Takes nothing at all (input = "none" is the default and is the right
    -- default), declares no mouse interest, and is smaller so the panel underneath shows around
    -- it. It is also the control for the frame question: a plain Border, in a colour that has
    -- always worked.
    local Top = UI{
        id    = "palforge_test:ZTop",
        name  = "z = 20, the panel on top",
        host  = "game",
        z     = 20,
        keys  = KEYS,
        onKeyPressed = function(self, ctx)
            self.keyHits = (self.keyHits or 0) + 1
            log.info(string.format("pf_uiz: TOP took key %s (z=%d) — and the panel underneath did "
                .. "NOT, which is the rule", tostring(ctx.key), ctx.z))
        end,
        root = Border{ color = { 0.32, 0.08, 0.06, 0.97 },
            SizeBox{ width = 340, height = 130,
                VBox{ padding = 10,
                    Label{ text = "PalForge  TOP  z = 20", size = 20, native = true },
                    Label{ name = "counts", text = function(self)
                        return string.format("keys taken %d   |   no mouse declared",
                            self.keyHits or 0)
                    end },
                    Label{ text = "I unmount myself at 45 s" },
                },
            },
        },
    }

    -- ⚠️ THE PANEL THAT ASKS THE GAME TO PUT IT UP. host = "layer" pushes a real Palworld window
    -- onto one of the in-game layout's own CommonUI layers through BP_AddWidget, so the action
    -- router — not us — owns its activation, its focus and its input mode; and backHandler = true
    -- claims the CommonUI BACK action, which is the mechanism a Palworld screen uses to say "Esc
    -- closes me". BOTH ARE UNMEASURED. If the push refuses, this element simply never mounts and
    -- its lastError() names the step; the other two panels are unaffected either way.
    local Layer = UI{
        id    = "palforge_test:ZLayer",
        name  = "the game's own route: pushed onto a CommonUI layer",
        host  = "layer",
        z     = 30,
        input = "clicks",
        backHandler = true,
        root = Frame{
            Border{ color = { 0.05, 0.55, 0.52, 0.92 },
                SizeBox{ width = 420, height = 150,
                    VBox{ padding = 12,
                        Label{ text = "PalForge  LAYER  (BP_AddWidget)", size = 20, native = true },
                        Label{ text = "the GAME pushed me: activated, focused and input-configured" },
                        Label{ text = "backHandler = true — Esc may close ME. I go at 90 s anyway" },
                    },
                },
            },
        },
    }

    local bottom = Bottom:new{ keyHits = 0, mouseHits = 0, clicks = 0 }
    local top    = Top:new{ keyHits = 0 }
    local layer  = Layer:new{}
    -- autoMount for all three: the in-game layout may not be up yet, and the same subscription
    -- that retries the mount is the one that re-evaluates the counters once it is in.
    bottom:autoMount(nil, 1000)
    top:autoMount(nil, 1000)
    layer:autoMount(nil, 1000)
    log.info("pf_uiz: three panels are trying to mount — two into the game's UI root (z = 10, 20) "
        .. "and one through the game's own BP_AddWidget layer route")

    local function report(when)
        for _, line in ipairs(UI.report()) do log.info("pf_uiz " .. when .. ": " .. line) end
        for _, line in ipairs(tree.clickReport()) do log.info("pf_uiz " .. when .. ": " .. line) end
    end

    -- What a panel actually got, read off its built tree rather than inferred: which slot class
    -- the host handed back (a CanvasPanelSlot is the one that has a ZOrder at all), what the root
    -- widget really is (WBP_PalCommonWindow_C = the game's chrome; Border = the fallback), and
    -- what the input grab did — which is now only ever the cursor, by design.
    local function evidence(tag, h)
        local st = h:state()
        if not h:isMounted() then
            log.warn(string.format("pf_uiz: %s is NOT mounted — %s", tag, tostring(h:lastError())))
            return
        end
        local slotCls, rootCls = "?", "?"
        pcall(function() slotCls = st._tree.slot:GetClass():GetFName():ToString() end)
        pcall(function() rootCls = st._tree.root:GetClass():GetFName():ToString() end)
        log.info(string.format("pf_uiz: %s mounted | z=%s | slot=%s | rootClass=%s | layer=%s | "
            .. "input -> %s%s", tag, tostring(st.zOrder), slotCls, rootCls,
            tostring(st._tree and st._tree.layer and "yes" or "no"),
            st._input and table.concat(st._input.applied or {}, " + ") or "nothing taken",
            (st._input and st._input.note) and ("  [" .. st._input.note .. "]") or ""))
    end

    local phase = 0
    poll.every("pf_uiz", function(elapsed)
        if elapsed >= 12 and phase < 1 then
            phase = 1
            evidence("TOP   ", top)
            evidence("BOTTOM", bottom)
            evidence("LAYER ", layer)
            report("at 12 s")
            log.info("pf_uiz: NOW, in this order — "
                .. "(a) ⚠️ PRESS ESC TWICE. The game's menu must open AND close, exactly as it "
                .. "does with no mod loaded. This is the whole point of the run. "
                .. "(b) with the menu OPEN, click BOTTOM's button; its label must count up. "
                .. "(c) close the menu, then press INS and END: only the RED panel's counter may "
                .. "move. "
                .. "(d) press the MIDDLE mouse button: only the MAGENTA panel's counter may move, "
                .. "and your pal will be given an attack order as well — that is the game's own "
                .. "binding, which an override shares rather than takes.")
            support.announce("pf_uiz: press Esc TWICE first, then click, INS/END, middle-click")
        elseif elapsed >= 45 and phase < 2 then
            phase = 2
            top:unmount()
            log.info("pf_uiz: the TOP panel has unmounted itself. Press INS or END again — the "
                .. "same key must now reach the BOTTOM panel, because nothing is above it.")
            support.announce("pf_uiz: top panel gone — press INS / END again")
        elseif elapsed >= 55 and phase < 3 then
            phase = 3
            report("at 55 s")
        elseif elapsed >= 90 and phase < 4 then
            phase = 4
            layer:unmount()
            log.info("pf_uiz: the LAYER panel has unmounted itself — through RemoveWidget if the "
                .. "game had put it on a layer, which is also what makes the action router "
                .. "restore whatever input config was underneath.")
        elseif elapsed >= 100 and phase < 5 then
            phase = 5
            bottom:unmount()
            log.info("pf_uiz: the BOTTOM panel has unmounted itself; the cursor flag is restored "
                .. "exactly as it was found (it is the one half that is readable).")
        elseif elapsed >= 105 then
            report("final")
            log.info("pf_uiz: HOW TO READ IT — "
                .. "(a) ⚠️ Esc opened AND closed the game's menu -> the diagnosis holds: the "
                .. "input mode belongs to Palworld's CommonUI action router, and PalForge not "
                .. "writing it is what fixed this. Esc still broken -> the diagnosis is WRONG and "
                .. "something else in the mount path is in the router's way; run pf_uiroute, "
                .. "whose `inputModeChanged` counter says whether the router is even involved. "
                .. "(b) BOTTOM's button counted up with the menu open -> the click router reaches "
                .. "our widget; it did not -> read the `clicks:` lines above for seen/dispatched. "
                .. "(c) the red panel's key counter moved and the magenta one's did not -> the key "
                .. "rule holds; after 45 s the magenta one's moving instead is the same rule. "
                .. "(d) the magenta counter moved on middle-click -> the mouse half works and the "
                .. "override is what unlocked it; `keys: MIDDLE_MOUSE_BUTTON refused` again means "
                .. "overrideButtons did not reach the arm call. "
                .. "(e) rootClass=WBP_PalCommonWindow_C -> the panel wears the game's own chrome, "
                .. "and the MAGENTA is the Border inside it, which is where a declared colour can "
                .. "land. rootClass=Border -> the chrome was not available and a [ui] warning "
                .. "above names what was missing. "
                .. "(f) the LAYER panel mounted at all -> BP_AddWidget works and PalForge can put "
                .. "a screen up the way the game does. It did not -> its lastError() names the "
                .. "step, and `host = \"game\"` remains the proven route.")
            support.announce("pf_uiz: done — all three panels are down")
            return true
        end
        return false
    end)
end,
}
for _, p in ipairs(M.PROBES) do
    M.ACTIONS["pf_" .. p.name] = function() M.probe(p.name) end
end

-- LOAD THE GAME-REQUIRED HOOKS, and generate one action per hook.
--
-- The env.debug gate lives inside hooks.load(): with it off nothing under test/hooks is
-- required, no action is generated, and the ONE line it logs says so and says how to turn it
-- on. `pf_hooks` still exists and still answers — a runner that vanishes with its hooks is a
-- runner that cannot tell you why they are missing.
--
-- ONE NAME PER HOOK because core/autorun.lua parses `[delay] name` and cannot carry an
-- argument (core/autorun.lua:62-67), so `pf_hook <id>` is a console-only spelling. This is the
-- same trick the six probes above use, and it is what makes every measurement in this tree
-- reachable with no key and no console — which matters because three input routes have failed
-- in turn on a real machine.
do
    local okHooks, hooks = pcall(require, "palforge.test.hooks")
    if not okHooks then
        log.err("test/hooks failed to load: " .. tostring(hooks))
    else
        hooks.load()
        for _, id in ipairs(hooks.ids()) do
            M.ACTIONS[hooks.actionName(id)] = function() hooks.run(id) end
        end
    end
end

M.loaded = {}   -- case name -> suite (or false when the file failed to load)

---Load every case file so its suite registers. Idempotent: require caches, and
---unittests.suite() returns the existing suite for a name it already has.
---@return integer count
function M.load()
    local n = 0
    for _, name in ipairs(M.CASES) do
        local before = T.byName(name)
        local ok, res = pcall(require, "palforge.test.cases." .. name)
        if ok then
            -- unittests.suite() hands back an existing suite of the same name, so a case
            -- file that collides with someone else's suite would silently append to it and
            -- the key would run their tests too. Say so rather than merging quietly.
            if before then
                log.warn("case '" .. name .. "' shares its suite name with an already "
                    .. "registered suite; the two are now merged")
            end
            M.loaded[name] = res
            n = n + 1
        else
            M.loaded[name] = false
            log.err("case '" .. name .. "' failed to load: " .. tostring(res))
        end
    end
    return n
end

---The suite names THIS module owns, in run order. Deliberately not every suite the
---framework knows about: palforge.tests registers its own headless bundle into the same
---registry, and pressing the key should run the API suite, not everything in the process.
---@return string[]
function M.suites()
    local out = {}
    for _, name in ipairs(M.CASES) do
        if M.loaded[name] then out[#out + 1] = name end
    end
    return out
end

---Run the suites and report. `which` is nil (every suite this module owns), a suite name,
---or a list of them. Returns the results table from core.unittests.
function M.run(which)
    local names = which
    if names == nil then names = M.suites() end
    if type(names) == "string" then names = { names } end

    log.info(string.format("%s | running %d suite(s): %s",
        envStamp(), #names, table.concat(names, ", ")))
    support.announce("tests: running " .. #names .. " suite(s)")

    local results = T.run(names)

    -- Defining is permanent, so a run that registered throwaway content has to take it
    -- back out — otherwise pressing the key repeatedly grows the live registry that
    -- core/event walks on every scan.
    local removed = support.sweep()
    if removed > 0 then log.info("swept " .. removed .. " test definition(s)") end

    -- THE ON-SCREEN SUMMARY CARRIES THE DIRECTION TOO, and that is not cosmetic. A skip has a
    -- direction now (core/unittests: NEEDS.WORLD / NOWORLD / HOOK / OPTIN / SETUP / SESSION),
    -- and the world-gated and the inverse-gated checks CANNOT both run in one press — so a
    -- bare "N skipped" on screen is the exact shape of the failure this tree has been bitten by
    -- three times: a run that measured two thirds of itself and reported the same "0 failed" as
    -- a run that measured all of it. The full breakdown is in UE4SS.log; the announce is what a
    -- tester actually reads without alt-tabbing, so it gets the same clause and the same
    -- sentence, formatted by core/unittests rather than spelled a second time here.
    local line = string.format("tests: %d passed, %d failed, %d skipped",
        results.passed, results.failed, results.skipped)
    local breakdown = T.needsPhrase and T.needsPhrase(results.needs)
    if breakdown then line = line .. " (" .. breakdown .. ")" end
    support.announce(line)
    if T.needsTwoRuns and T.needsTwoRuns(results.needs) then
        support.announce("tests: NO SINGLE RUN MEASURES EVERYTHING — press the key once in a "
            .. "loaded save and once at the title screen; a green run is two runs")
    end

    -- Repeat each failure on screen; a summary that says "3 failed" and nothing else
    -- means going back to the log anyway.
    for _, suite in ipairs(results.suites) do
        for _, f in ipairs(suite.failures) do
            support.announce(string.format("FAIL [%s] %s: %s", suite.name, f.test, f.msg))
        end
    end
    return results
end

---Bind a key to a test run. `what` is nil (every suite), a suite name, a list of names,
---or a function to call. `opts` is passed through to the keybind registry (e.g. desc).
---@param key string        # "F1", "F2", ... as named in UE4SS's Key table
---@param what nil|string|string[]|function
---@param opts table?
---@return boolean bound
function M.bind(key, what, opts)
    local desc
    local fn
    if type(what) == "function" then
        fn, desc = what, (opts and opts.desc) or "custom"
    else
        local names = what
        if type(names) == "string" then names = { names } end
        fn = function() M.run(names) end
        desc = (opts and opts.desc)
            or (names and ("tests: " .. table.concat(names, ", ")) or "tests: all suites")
    end

    local merged = { desc = desc }
    for k, v in pairs(opts or {}) do merged[k] = v end
    return reg.register(key, fn, merged)
end

---Run one discovery probe by name ("reflect", "pal", "watch", "title"). Returns how many of
---its sections ran; 0 means the probe said what it needed and stopped.
---@param name string
---@return integer sections
function M.probe(name)
    local ok, mod = pcall(require, "palforge.test.probes." .. tostring(name))
    if not ok then
        log.err("probe '" .. tostring(name) .. "' failed to load: " .. tostring(mod))
        return 0
    end
    if type(mod.run) ~= "function" then
        log.err("probe '" .. tostring(name) .. "' has no run()")
        return 0
    end
    log.info("probe " .. name .. " starting - copy everything between the BEGIN and END markers")
    support.announce("probe " .. name .. ": writing to UE4SS.log")
    local ran, err = pcall(mod.run)
    if not ran then
        log.err("probe '" .. name .. "' raised: " .. tostring(err))
        return 0
    end
    return tonumber(err) or 0
end

---What is bound where — AND what Palworld has on the same key. Handy from a console command.
---
---It delegates to core/keyboard's own report rather than re-formatting reg.bound, because the
---second column is the one that was missing: `watch` sat unreachable on the game's volume key
---for a whole session while the log cheerfully said it was bound. The game half reads "unknown"
---at load (the config needs a loaded world) and fills in from world.ready onward.
---@return string[]
function M.bindings() return reg.report() end

-- Wire it up on require: load the cases, put the whole run on F1, and give each discovery
-- probe its own key. Re-bind any of them from your own code — M.bind replaces a binding in
-- place, so `test.bind("F5", "pal")` would take F5 back for a suite.
M.load()
M.bind("F1")
for _, p in ipairs(M.PROBES) do
    M.bind(p.key, function() M.probe(p.name) end,
        { desc = string.format("probe %s (%s) - needs %s", p.name, p.desc, p.needs) })
end

-- A CONSOLE COMMAND FOR EVERY ACTION, so a key the game has taken can never block one again.
-- F7 turned out to be Palworld's own volume control: the bind succeeded, the key never arrived,
-- and from the log that was indistinguishable from a probe that ran and found nothing. Keys are
-- convenient and they are not ours to reserve; a command is.
--
-- ⚠️ THE NAMES ARE NOT LISTED HERE ANY MORE, and that is deliberate. A hand-written list in a
-- comment is exactly what went stale in this file and in autorun.txt at the same time: this
-- block used to name six commands while M.ACTIONS held fifteen, and autorun.txt:7 named ten
-- while running four others as live lines a hundred lines further down. The AUTHORITATIVE list
-- is M.ACTIONS, and installCommands PRINTS it, sorted, every session — that line in the log is
-- the one to read, and it cannot drift because it is generated from the table it describes.
--
-- Open the UE4SS console (its GUI window) and type one. Same work, same output, no key involved.
local function installCommands()
    if type(RegisterConsoleCommandHandler) ~= "function" then
        log.warn("console commands unavailable this session; the keys above are the only way in")
        return
    end
    -- REGISTERING A COMMAND IS NOT THE SAME AS BEING ABLE TO TYPE ONE. UE4SS ships with its
    -- console switched off, and this handler registers perfectly well into a window that does
    -- not exist — which is exactly the failure the console was added to escape from, one layer
    -- further down. The log said "console commands: pf_spawn pf_teach ..." while there was
    -- nowhere to put them.
    --
    -- Turn it on in ue4ss/UE4SS-settings.ini and restart the game:
    --     ConsoleEnabled = 1
    --     GuiConsoleEnabled = 1
    --     GuiConsoleVisible = 1
    -- The setting cannot be read from here, so this is a note rather than a check.
    -- The body is queued onto the game thread, because everything it touches is a live UObject.
    -- It is also wrapped: a console command that raises takes UE4SS's handler down with it, and
    -- a typo in a dev command is not worth a broken console.
    --
    -- THE ARGUMENT IS PASSED THROUGH, which it was not before. UE4SS hands a console handler
    -- (fullCommand, parameters, outputDevice) and this wrapper used to discard all three, so an
    -- action could only ever be a verb with no object — which is why `pf_hook <id>` needs it.
    -- Every existing action ignores the extra value (Lua drops a surplus argument), so nothing
    -- else changes shape.
    local function register(name, run)
        pcall(function()
            RegisterConsoleCommandHandler(name, function(_fullCommand, parameters)
                local arg = (type(parameters) == "table") and parameters[1] or nil
                local body = function()
                    local ok, err = pcall(run, arg)
                    if not ok then log.err(name .. " failed: " .. tostring(err)) end
                end
                if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(body) else body() end
                return true
            end)
        end)
    end
    for name, run in pairs(M.ACTIONS) do register(name, run) end

    local names = {}
    for name in pairs(M.ACTIONS) do names[#names + 1] = name end
    table.sort(names)
    log.info("console commands: " .. table.concat(names, "  "))
    log.info("if you cannot type those, UE4SS's console is off: set ConsoleEnabled, "
        .. "GuiConsoleEnabled and GuiConsoleVisible to 1 in ue4ss/UE4SS-settings.ini and restart")
end
installCommands()

-- Print the bindings once, at load. A key the GAME has already claimed still binds successfully
-- here and simply never fires — that is how `watch` sat unreachable on Palworld's volume key —
-- so the log has to carry which key is on what, or a probe that cannot be pressed looks exactly
-- like a probe that found nothing.
--
-- The `game:` column reads "the game's key config has not been read" HERE and that is correct
-- rather than a defect: this runs at mod load, the config lives on a world subsystem, and there
-- is no world yet. Run `pf_keys` from inside a save for the filled-in version.
for _, line in ipairs(M.bindings()) do log.info(line) end

return M
