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
-- Results land in UE4SS.log under [PalForge.test] and [PalForge.unittests]:
--
--   [PalForge.test][info] running 13 suite(s): schema, registry, definitions, pal, ...
--   [PalForge.unittests][info] SKIP [pal] spawns at a coordinate: no world loaded
--   [PalForge.unittests][info] tests: 276 passed, 0 failed, 18 skipped (294 total)
--   [PalForge.test][info] swept 217 test definition(s)
--
-- A test that needs a world SKIPS rather than fails when there is none, so the same run
-- is meaningful at the title screen and in a save — the 18 skips above are the world ones.
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

local M = {}

M.support = support

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
-- says so either: the bind succeeds, the key just never arrives.
--
-- So `watch` moved to F8 and `title` to F2. If another key turns out to be taken, change it
-- HERE and nowhere else — this table is the only place a probe key is written, and the kernel
-- prints the whole list at startup so the current bindings are always in the log.
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
    -- (AddEquipWaza) and is still opt-in behind _G.PALFORGE_TEST_WRITE_WAZA because it once
    -- correlated with the game closing.
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

-- pf_uiz — TWO OVERLAPPING PANELS. The z-order and the event-routing rule, put on screen where
-- they can be watched instead of asserted, and the ESC REGRESSION in the same run.
--
-- WHAT THIS ANSWERS, and each answer is separable from the others:
--
--   1. ⚠️ DOES ESC STILL CLOSE THE GAME'S OWN MENU. This is the one that matters. The BOTTOM
--      panel is deliberately the exact configuration that broke it — a UI.Frame (the game's own
--      WBP_PalCommonWindow chrome, a CommonUI activatable) plus input = "clicks" (which calls
--      SetInputMode_GameAndUIEx and therefore hands our widget the keyboard focus). Both halves
--      of the fix are on that path: the focus is handed straight back to the game viewport
--      (SetFocusToGameViewport, dumps/cxx/UMG.hpp:2007) and the frame's CommonUI back-handler /
--      modal / activation-focus flags are forced off before it is activated. Press Esc twice.
--      If the menu opens and closes, the fix holds. If it opens and will not close, it does not,
--      and the two log lines named below say which half failed.
--
--   2. WHICH PANEL IS DRAWN ON TOP. They overlap on purpose and the top one is smaller, so the
--      bottom one shows around its edges. TOP declares z = 20, BOTTOM z = 10.
--
--   3. WHO GETS A KEY. Both panels want the same keys. Only the TOP one may have them — a key
--      does not reach a panel while anything is above it. At 45 s the top panel takes itself
--      down and the same key starts reaching the bottom one, which is the rule changing its
--      answer while you watch.
--
--   4. WHO GETS A MOUSE PRESS. Only the BOTTOM panel declares one, and it gets middle-click even
--      though it is covered — because a press goes to the topmost panel that WANTS it, where a
--      key is blocked by the topmost panel full stop. That difference is the whole design, and
--      this is the one run in which both halves are visible at once.
--
-- ⚠️ WHETHER THE KEYS ARRIVE AT ALL IS NOT SOMETHING THIS CAN PROMISE. Palworld claims keys
-- without telling anyone — F7 was its volume control, the bind succeeded, the key never came —
-- and there is no call that asks whether a key is free. So two keys are declared (INS and END),
-- and the keys report prints, in words, that an arrival count of zero cannot tell "the game took
-- it" from "nobody pressed it". If neither key arrives, THAT is the finding, and the panels still
-- prove the z-order and the mouse half.
--
-- SAFE BY CONSTRUCTION: the top panel unmounts itself at 45 s and the bottom at 100 s, on ELAPSED
-- SECONDS through core/poll — no key is needed to get rid of either, precisely because no key can
-- be relied on. Unmounting is also what gives the cursor back.
pf_uiz = function()
    local UI   = require("palforge.api.ui")
    local tree = require("palforge.native.ui").tree
    local poll = require("palforge.core.poll")
    local VBox, Label, Border, SizeBox, Frame = UI.VBox, UI.Label, UI.Border, UI.SizeBox, UI.Frame

    -- Two keys rather than one, for the reason in the header: neither is known to be free, and
    -- two independent chances cost nothing. Middle-click for the mouse half — the least likely of
    -- the three to be in the middle of something the player is doing.
    local KEYS, BUTTON = { "INS", "END" }, "middle"

    -- THE BOTTOM PANEL. The game's own window chrome, and the input mode that broke Esc — this
    -- one is the regression test as much as it is the lower half of the stack.
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
        buttons = { BUTTON },
        onMousePressed = function(self, ctx)
            self.mouseHits = (self.mouseHits or 0) + 1
            log.info(string.format("pf_uiz: BOTTOM took mouse %q (z=%d) THROUGH the panel above "
                .. "it — a press goes to the topmost panel that WANTS it", tostring(ctx.button), ctx.z))
        end,
        root = Frame{ color = { 0.05, 0.07, 0.12, 0.95 },
            SizeBox{ width = 470, height = 250,
                VBox{ padding = 12,
                    Label{ text = "PalForge  BOTTOM  z = 10", size = 20, native = true },
                    Label{ text = "input = \"clicks\"  +  the game's own window chrome" },
                    Label{ name = "counts", text = function(self)
                        return string.format("keys taken %d   |   middle-click taken %d",
                            self.keyHits or 0, self.mouseHits or 0)
                    end },
                    Label{ text = "a key reaches me only once the RED panel is gone" },
                    Label{ text = "I go away by myself at 100 s" },
                },
            },
        },
    }

    -- THE TOP PANEL. Takes nothing at all (input = "none" is the default and is the right default),
    -- declares no mouse interest, and is smaller so the panel underneath shows around it.
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

    local bottom = Bottom:new{ keyHits = 0, mouseHits = 0 }
    local top    = Top:new{ keyHits = 0 }
    -- autoMount for both: the in-game layout may not be up yet, and the same subscription that
    -- retries the mount is the one that re-evaluates the counters once it is in.
    bottom:autoMount(nil, 1000)
    top:autoMount(nil, 1000)
    log.info("pf_uiz: two panels are trying to mount into the game's own UI root (z = 10 and 20)")

    local function report(when)
        for _, line in ipairs(UI.report()) do log.info("pf_uiz " .. when .. ": " .. line) end
        for _, line in ipairs(tree.clickReport()) do log.info("pf_uiz " .. when .. ": " .. line) end
    end

    -- What a panel actually got, read off its built tree rather than inferred: which slot class
    -- the host handed back (a CanvasPanelSlot is the one that has a ZOrder at all) and what the
    -- input grab really applied — "SetFocusToGameViewport" in that list is the Esc fix having run.
    local function evidence(tag, h)
        local st = h:state()
        if not h:isMounted() then
            log.warn(string.format("pf_uiz: %s is NOT mounted — %s", tag, tostring(h:lastError())))
            return
        end
        local slotCls, rootCls = "?", "?"
        pcall(function() slotCls = st._tree.slot:GetClass():GetFName():ToString() end)
        pcall(function() rootCls = st._tree.root:GetClass():GetFName():ToString() end)
        log.info(string.format("pf_uiz: %s mounted | z=%s | slot=%s | rootClass=%s | input -> %s",
            tag, tostring(st.zOrder), slotCls, rootCls,
            st._input and table.concat(st._input.applied or {}, " + ") or "nothing taken"))
    end

    local phase = 0
    poll.every("pf_uiz", function(elapsed)
        if elapsed >= 12 and phase < 1 then
            phase = 1
            evidence("TOP   ", top)
            evidence("BOTTOM", bottom)
            report("at 12 s")
            log.info("pf_uiz: NOW — (a) press Esc TWICE: the game's menu must open AND close. "
                .. "(b) press INS, then END: only the RED panel's counter may move. "
                .. "(c) press the MIDDLE mouse button: only the BLUE panel's counter may move.")
            support.announce("pf_uiz: press Esc twice, then INS / END, then middle-click")
        elseif elapsed >= 45 and phase < 2 then
            phase = 2
            top:unmount()
            log.info("pf_uiz: the TOP panel has unmounted itself. Press INS or END again — the "
                .. "same key must now reach the BOTTOM panel, because nothing is above it.")
            support.announce("pf_uiz: top panel gone — press INS / END again")
        elseif elapsed >= 55 and phase < 3 then
            phase = 3
            report("at 55 s")
        elseif elapsed >= 100 and phase < 4 then
            phase = 4
            bottom:unmount()
            log.info("pf_uiz: the BOTTOM panel has unmounted itself; the cursor flag is restored "
                .. "exactly as it was found (it is the one half that is readable).")
        elseif elapsed >= 105 then
            report("final")
            log.info("pf_uiz: HOW TO READ IT — "
                .. "(a) Esc opened AND closed the game's menu -> the Esc fix holds; look for "
                .. "`SetFocusToGameViewport` in BOTTOM's input line and for the `[PalForge.ui] "
                .. "frame: ... CommonUI activation flags were ...` line, which is the measurement "
                .. "of which half was the cause. "
                .. "(b) Esc opened it and would not close it -> the fix does NOT hold; those two "
                .. "lines say which half did not run. "
                .. "(c) the red panel's key counter moved and the blue one's did not -> the key "
                .. "rule holds; after 45 s the blue one's moving instead is the same rule. "
                .. "(d) the blue panel's mouse counter moved while the red panel was still up -> "
                .. "the mouse rule holds, and it is genuinely different from the key rule. "
                .. "(e) `arrived=0` on both keys -> Palworld has claimed INS and END, or nobody "
                .. "pressed them, and the keys line above says in words that this count cannot "
                .. "tell those two apart. The z-order and the mouse half are unaffected by it.")
            support.announce("pf_uiz: done — both panels are down")
            return true
        end
        return false
    end)
end,
}
for _, p in ipairs(M.PROBES) do
    M.ACTIONS["pf_" .. p.name] = function() M.probe(p.name) end
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

    log.info(string.format("build %s | running %d suite(s): %s",
        buildStamp(), #names, table.concat(names, ", ")))
    support.announce("tests: running " .. #names .. " suite(s)")

    local results = T.run(names)

    -- Defining is permanent, so a run that registered throwaway content has to take it
    -- back out — otherwise pressing the key repeatedly grows the live registry that
    -- core/event walks on every scan.
    local removed = support.sweep()
    if removed > 0 then log.info("swept " .. removed .. " test definition(s)") end

    local line = string.format("tests: %d passed, %d failed, %d skipped",
        results.passed, results.failed, results.skipped)
    support.announce(line)

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

---What is bound where, as printable lines. Handy from a console command.
---@return string[]
function M.bindings()
    local out = {}
    for _, key in ipairs(reg.keys()) do
        local rec = reg.bound[key]
        out[#out + 1] = string.format("%-4s %s", key, (rec.opts and rec.opts.desc) or "?")
    end
    return out
end

-- Wire it up on require: load the cases, put the whole run on F1, and give each discovery
-- probe its own key. Re-bind any of them from your own code — M.bind replaces a binding in
-- place, so `test.bind("F5", "pal")` would take F5 back for a suite.
M.load()
M.bind("F1")
for _, p in ipairs(M.PROBES) do
    M.bind(p.key, function() M.probe(p.name) end,
        { desc = string.format("probe %s (%s) - needs %s", p.name, p.desc, p.needs) })
end

-- A CONSOLE COMMAND FOR EVERY PROBE, so a key the game has taken can never block one again.
-- F7 turned out to be Palworld's own volume control: the bind succeeded, the key never arrived,
-- and from the log that was indistinguishable from a probe that ran and found nothing. Keys are
-- convenient and they are not ours to reserve; a command is.
--
--   pf_watch     pf_reflect     pf_pal     pf_title     pf_tests     pf_mesh
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
    local function register(name, run)
        pcall(function()
            RegisterConsoleCommandHandler(name, function()
                local body = function()
                    local ok, err = pcall(run)
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
for _, line in ipairs(M.bindings()) do log.info("key " .. line) end

return M
