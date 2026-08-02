-- PalForge env: the shared, mutable runtime config. Cached by require(), so this
-- table is a process-wide singleton — any module reads `require("palforge.env").dev`
-- and main.lua (or a companion mod) may override a field by mutating this table
-- BEFORE calling registry.initialize().
--
--   local env = require("palforge.env")
--   if env.dev then ... end          -- read
--   env.dev = true                    -- dev build (do this before initialize())
--
-- ⚠️ THE DEFAULTS BELOW ARE THE SHIPPED, PLAYER-FACING ONES, and they are all OFF.
-- `dev = true` used to be the shipped default, which meant a copy deployed as-is gave
-- every player F1-F10 — including F4, unlock all technologies — and ran the test suites
-- at boot. A release toggle that defaults to "on" is a release toggle that ships on, so
-- the direction is inverted: nothing here turns itself on, and the DEV LOOP is what
-- switches it.
--
-- HOW A DEV SESSION TURNS IT ON. Scripts/main.lua requires an OPTIONAL module named
-- `palforge_dev` (Scripts/palforge_dev.lua) immediately before registry.initialize() and
-- ignores it when absent. That file is written into the deployed tree by
-- `tools/deploy.sh` (its default mode) and is NOT in the repository — it is gitignored —
-- so a player who copies this tree can never end up with one. `tools/deploy.sh --release`
-- deletes any stale copy on the way past.
--
--   -- Scripts/palforge_dev.lua, written by tools/deploy.sh
--   local env = require("palforge.env")
--   env.dev   = true
--   env.debug = true
--
-- THE THREE SWITCHES, from least to most invasive:
--   dev    loads the dev keybinds (nine keys), the headless unit bundle at boot, the
--          in-game API suite behind F1, F9 reload and the ps_catalog dumper.
--   debug  additionally loads test/hooks — the measurements that CANNOT run without a
--          running game (see Scripts/palforge/test/hooks/init.lua). Implies nothing on
--          its own: a hook still has to be asked for by name.
--   debugHooks[id] = true
--          per-hook opt-in for the hooks that WRITE into a real save. Nothing that
--          mutates a character, an inventory or the world runs off `debug` alone.
return {
    dev        = false,       -- THE dev/release switch (dev tools load only when true)
    debug      = false,       -- game-required test hooks (test/hooks); needs dev too
    debugHooks = {},          -- per-hook opt-in for the hooks that WRITE: { ["pal-skills-equip"] = true }
    name       = "PalForge",
    -- `version` is not only a log line any more: core/state.lua stamps it into the header of
    -- every state file it writes (`palforge.forge`), so this string ends up on a player's disk,
    -- once per mod per save, saying which build of the framework wrote those records. Changing
    -- it is free — nothing dispatches on it — but it is the first thing anyone reads when a
    -- record looks wrong after an update, so it should mean what it says.
    --
    -- TWO THINGS THAT ARE NOT HERE, deliberately, and where they are instead. WHERE the store
    -- writes is resolved by utils/file/json_file.lua from its own module path (a debug.getinfo
    -- walk to <Mods>/PalForge/state/), which is what keeps "delete the mod folder and it is all
    -- gone" structurally true rather than dependent on a setting someone can point elsewhere.
    -- The ON-DISK FORMAT VERSION is core/state.lua's M.FORMAT, next to the code that dispatches
    -- on it. Neither belongs in a table whose whole job is dev/release switches.
    version    = "0.3.0",

    -- The Palworld build every capability in plan/TODO.md's Closed list was measured
    -- against. Printed in the startup line and stated in the README, because a framework
    -- that does not say which build it was measured on gives its users no way to tell
    -- "PalForge is broken" from "the game moved" — this tree has already been bitten once
    -- by exactly that gap (AddItem declared five parameters where dumps/cxx/Pal.hpp had
    -- four, because the header dump predated the installed build by a single patch).
    --
    -- `gameBuild` IS DECLARED BY HAND AND IT IS NOW VERIFIABLE — that changed on 2026-08-02 and
    -- this note used to say the opposite. `gameBuildLive` is what Scripts/main.lua fills in from
    -- the running game and prints beside the declared string.
    --
    -- MEASURED 16:39:33 (hook `game-build-live`, run 1): UKismetSystemLibrary answers
    -- "++UE5+Release-5.1-CL-0" / "5.1.1-0+++UE5+Release-5.1" / "Pal" — Unreal's branch, Unreal's
    -- version and the project name. NONE of them carries Palworld's patch number, which is why
    -- the startup banner's MISMATCH warning was a defect in the reader rather than a fact about
    -- the install, and why `comparable` sits on none of the three.
    --
    -- MEASURED 17:37:40 (run 2): UPalGameInstance::DisplayVersion — the string Palworld puts on
    -- its own title screen — answers "v1.0.2.101103", and UPalUtility::GetDisplayVersion answers
    -- the same through core/signature with evidence `declared`. Two independent routes, matching
    -- the value below. It is not readable at STARTUP (there is no PalGameInstance yet), so
    -- main.lua reads it at the first world.ready and says so in the meantime; a mismatch after
    -- that line is a real one.
    gameBuild     = "v1.0.2.101103",
    gameBuildLive = nil,

    -- SINGLE-PLAYER ONLY. There is no server-synchronisation layer in PalForge and that is
    -- a deliberate scope decision: core/spawn builds a PalCheatManager off the LOCAL player
    -- controller, item spend goes through a locally spawned APalWeaponBase, and every event
    -- source is a local RegisterHook. Dedicated servers and co-op guests are not supported
    -- and are not tested. See the README and the startup line.
    multiplayer = false,
}
