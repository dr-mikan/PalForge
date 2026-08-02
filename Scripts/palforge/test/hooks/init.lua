-- palforge/test/hooks — THE MEASUREMENTS THAT CANNOT BE TAKEN WITH THE GAME SWITCHED OFF.
--
-- Everything in plan/TODO.md falls into one of two piles. One pile is reachable from a text
-- editor: a wrong comment, a missing README, an id that should have been validated at define
-- time. The other pile is not reachable from anywhere but a running Palworld — does the write
-- land, does the hook fire, does the colour change, is the sound audible — and that pile has
-- been carried for months as prose in a plan file, as `_G.PALFORGE_TEST_*` globals set by hand,
-- and as probes bound to keys that the game had already taken.
--
-- This directory is that second pile, DECLARED. One file per measurement, each one naming the
-- plan/TODO.md item it closes, what it needs on screen, whether it writes into a real save, and
-- what its output means. Nothing here runs unless it is asked for by name.
--
--   local hooks = require("palforge.test.hooks")
--   hooks.declare{
--       id     = "pal-skills-equip",           -- the plan/TODO.md item id, verbatim
--       item   = "Open (1) — ...",         -- where it sits in that file. Spell it so it
--                                          -- survives the file being reorganised: a section
--                                          -- number goes stale, "Closed <date> — <finding>"
--                                          -- does not, and this string is printed by every
--                                          -- `pf_hooks` and every run.
--       needs  = { world = true, pal = true }, -- world | player | pal | title
--       writes = true,                         -- mutates a save -> needs env.debugHooks[id]
--       desc   = "one sentence",
--       run    = function(h) h:log("...") h:pass("...") end,
--   }
--
-- THE THREE GATES, and why a hook says which one closed rather than skipping quietly.
--
--   1. env.debug        no hook FILE is even loaded without it. `dev` gives you the keys and
--                       the suite; `debug` gives you this directory. See env.lua.
--   2. needs = { ... }  what has to be true in the running game: a loaded world, a player
--                       pawn, a pal standing near you, or the title screen.
--   3. writes = true    additionally needs env.debugHooks[<id>] == true. Nothing that mutates
--                       a character, an inventory or the world runs off `debug` alone, because
--                       `debug` is a session-wide switch and a write is a per-experiment
--                       decision taken on a throwaway save.
--
-- ⚠️ `_G.PALFORGE_TEST_WRITE_WAZA = true` IS THE OLD SPELLING of
-- `env.debugHooks["pal-skills-equip"] = true`, and it still works. That global is written into
-- plan/TODO.md, into test/cases/skill.lua:579 and into core/character.lua:86 as THE way to
-- arm the waza write; those three sentences are load-bearing history, and a reader who follows
-- one of them must not find a switch that has been quietly renamed. Both are honoured, and the
-- run block says which one carried it. See M.writeAllowed.
-- The traffic runs BOTH WAYS: test/cases/skill.lua's own gate asks M.writeAllowed rather than
-- reading the global directly, so arming the canonical switch opens the F1 check too.
--
-- ⚠️ A SILENT SKIP IS THE EXACT FAILURE MODE THIS TREE HAS BEEN BITTEN BY THREE TIMES. A probe
-- on Palworld's own volume key bound successfully and never fired; a console command registered
-- into a window UE4SS ships switched off; a test skipped for want of a world and reported the
-- same "0 failed" as a test that ran. In all three the log said nothing was wrong. So every
-- refusal here NAMES THE GATE and says the sentence that opens it, and `pf_hooks` prints that
-- for every declared hook before anything is run.
--
-- OUTPUT SHAPE. Identical to the probes under test/probes/, deliberately, so a block can be
-- lifted out of UE4SS.log and pasted straight into plan/TODO.md:
--
--   #### BEGIN pal-skills-equip
--   ... lines ...
--   #### END pal-skills-equip
--
-- A hook that keeps watching after its body returns (anything driven by core/poll, anything
-- that arms a RegisterHook and waits for the operator to act) prints FURTHER bracketed blocks
-- of its own — `#### BEGIN <id>-1`, `-2`, ... — through h:beginBlock/h:endBlock. The END the
-- framework prints closes the SETUP block only, and a hook in that shape says so in its own
-- words before it returns.
--
-- ⚠️ AND WHILE ONE OF THOSE WATCHERS IS ALIVE, F9 IS REFUSED. Every poller registered through
-- core/poll brackets itself with core/reload's async guard (core/poll.lua:123,134), because a
-- reload that drops the modules a UE4SS callback is still holding is how this tree crashed
-- before. Most hooks here run a watcher for 12 to 180 seconds, so a reload attempted in that
-- window is refused BY NAME — the message says which chain is outstanding and how old it is.
-- That is the guard working, not a defect. It clears itself when the watcher retires, at its
-- own 180 s stale cap, or immediately from the Lua console with
-- `require('palforge.core.reload').asyncReset()`. Deploy, then run the hook; not the reverse.
--
-- HOW TO RUN ONE. Three routes, because three input routes have failed in turn on a real
-- machine and each time the work was fine and only the way in was missing:
--
--   the UE4SS console   pf_hooks               list everything, with each hook's gate state
--                       pf_hook <id>           run one by its plan/TODO.md id
--                       pf_hooks_all           run every hook whose gate is open
--   a key               nothing here is on a key. Keys are not ours to reserve.
--   autorun.txt         pf_hook_<id_with_underscores>, e.g. pf_hook_item_datatable_row_read.
--                       One generated action per declared hook, because core/autorun.lua reads
--                       `[delay] name` and has no way to carry an argument (core/autorun.lua:74-82).
--
-- NOTHING HERE MAY RAISE AT LOAD. Requiring this directory in a headless lua5.4 with no engine
-- at all must work — the hook BODIES may reach for FindAllOf and StaticFindObject freely, but
-- every such module is required from inside `run`, never at the top of a file. That is what
-- makes `luac5.4 -p` plus a headless require a real check on this directory rather than a
-- syntax pass.
local env     = require("palforge.env")
local log     = require("palforge.utils.log").scope("hooks")
local support = require("palforge.test.support")

local M = {}

-- The hook files, in the order pf_hooks_all runs them: READ-ONLY FIRST. A run that ends in a
-- crash should have printed everything that could be printed before it got to the write, and
-- the one write in this tree that correlates with a crash — pal_skills_equip — is therefore
-- LAST. (This sentence used to place it "last entry but one", which was already untrue when it
-- was written and would have gone on drifting every time an entry was added. A position in a
-- list is not a name; the hook is named.)
-- `game_build_live` leads because it is the cheapest read here and it establishes WHICH BUILD
-- produced every block below it — a log full of measurements that does not say what game took
-- them is the gap the startup banner and env.gameBuild exist to close.
M.FILES = {
    -- read-only, no operator action
    "game_build_live",
    -- keymap_coverage is second because it is the ONLY hook here that declares no `needs` at
    -- all: UE4SS's `Key` table is a process global, so it answers at the title screen, during a
    -- load, and in a session where nothing else in this directory can run.
    "keymap_coverage",
    "mesh_actor_identity",
    "item_datatable_row_read",
    "audio_custom_file_loader",
    "building_record_orphans",
    -- store_base_load_cost is the only READ-ONLY member of the format-3 store's set, and it is
    -- here rather than beside its three siblings for that reason alone: it opens no file it did
    -- not find, writes nothing anywhere, and answers the efficiency half of the store pass —
    -- what a real base costs to load — which is a number every other store block is quoted
    -- against. It pairs with building_record_orphans above the way that one pairs with
    -- building_actor_streaming below: orphans says what the store is HOLDING, this one says
    -- what holding it COST, and streaming says what the game did to the actors underneath.
    "store_base_load_cost",
    -- read-only, but they arm hooks and want the operator to do something in game
    -- building_actor_streaming LEADS this group because it is the highest-priority measurement
    -- of the store pass and the one thing the operator does for it — walk away from a base —
    -- can be done while every hook below is still printing. It decides whether R-1 (a miss
    -- QUARANTINES a record instead of deleting it) fixed a live data-loss bug or a latent one,
    -- and it pairs with building_record_orphans above: that one reads the records, this one
    -- reads the actors the records are about.
    "building_actor_streaming",
    "ui_update_event",
    "pal_spawned_fresh",
    "skill_hit_source",
    "ui_host_layer",
    "ui_backhandler",
    -- building_runtime_reload is in THIS group and not the one above because the thing it wants
    -- the operator to do is press F9 BETWEEN two runs of it. It is the one hook whose
    -- measurement spans a reload, which is also why it arms no poller: a live poller refuses the
    -- very press it is asking for (core/poll.lua:123,134).
    "building_runtime_reload",
    -- LAST, because each one CHANGES SOMETHING while it runs. NINE of these eleven declare
    -- `writes = true` and so need their own env.debugHooks entry on top of env.debug:
    -- mesh_color_change, building_unlock, item_satiety_write, skill_projectile_spawn,
    -- pal_spawn_persisted, pal_skills_equip, and the three store writers below. TWO sit here for ordering only and
    -- deliberately do NOT declare writes, because `writes` means "a save is mutated" and
    -- neither mutates one:
    -- audio_setvolume_audible makes the game loud and then quiet again (its own header,
    -- audio_setvolume_audible.lua:26-27), and mesh_texture_import allocates a UTexture2D that
    -- nothing in this process can destroy and writes an 82-byte PNG next to itself, which is a
    -- change to the running process and to a directory rather than to the player's save.
    -- This comment used to read "writes = true, each behind its own env.debugHooks entry" over
    -- all four, which promised a gate one of them does not have; it then said "only THREE of
    -- these four", which new entries have twice since made wrong in the other direction. The
    -- count is worth keeping correct because it is the only place that says at a glance how many
    -- opt-ins a full write run needs.
    --
    -- item_satiety_write and skill_projectile_spawn write LESS than the three around them —
    -- one puts back the exact value it read, the other fires a single bullet — but both push an
    -- argument at a UFunction whose declaration is the thing being measured, so they run after
    -- everything that only reads.
    "mesh_texture_import",
    "mesh_color_change",
    "audio_setvolume_audible",
    "building_unlock",
    "item_satiety_write",
    "skill_projectile_spawn",
    -- THE THREE STORE WRITERS, and they stretch the definition of `writes` on purpose. None of
    -- them touches Palworld's save: they create, corrupt and rewrite files under
    -- <Mods>/PalForge/state/, which by the strict reading is the same class of change as
    -- mesh_texture_import's 82-byte PNG two entries up. They declare it anyway, because after
    -- the format-3 pass the claim being defended is that PalForge is careful with the files
    -- under its own directory, and a hook that made files in a player's state/ because somebody
    -- left env.debug on in a dev overlay would be the first counter-example. `writes` is the
    -- only per-experiment gate the framework has, so it is the one used — and each file's
    -- header says this in its own words rather than leaving it to be inferred from the flag.
    --
    -- save_survives_pack_removal is last of the three because it is the only one that asks the
    -- OPERATOR to do something destructive (uninstall a pack, then reload a save that holds
    -- that pack's ids), and it is the one that answers the question the whole store pass was
    -- started for.
    "store_save_roundtrip",
    "store_crash_recovery",
    "save_survives_pack_removal",
    -- pal_spawn_persisted puts a pal in the world and CANNOT take it back — core/state.lua's
    -- RECLAIM records `pal` as can = false because the cheat manager's deletions are
    -- world-scale. It sits here rather than with the two "less invasive" writers above for that
    -- reason: what it leaves behind is permanent, and it exists because core/ledger.lua declares
    -- a `pal` kind that nothing writes and pointed at a hook that did not exist.
    "pal_spawn_persisted",
    "pal_skills_equip",
}

-- The four things a hook may declare it needs, and the sentence that opens each. These strings
-- are the whole point of the gate: "skipped" is not a result, "skipped because there is no pal
-- near you, whistle one out or run pf_spawn" is.
local NEEDS = {
    world  = { what = "a loaded world",
               open = "load a save; a hook that reads a world subsystem cannot run at the title screen" },
    player = { what = "a live player pawn",
               open = "load a save and wait for your character to finish spawning" },
    pal    = { what = "a pal standing near you",
               open = "whistle a pal out, or run pf_spawn and wait ~10 s for it to arrive" },
    title  = { what = "the TITLE SCREEN (no world loaded)",
               open = "quit to the title screen; this hook reads the title menu, which does not exist in a save" },
}

M.declared = {}   -- id -> spec
M.order    = {}   -- ids, in declaration order

--=============================================================================
-- the build stamp
--
-- Deliberately a copy of test/init.lua's `buildStamp` rather than a call into it, even though
-- that file now exports `M.buildStamp` / `M.envStamp`: test/init.lua requires THIS module, and
-- requiring it back would either be a load-time cycle or — worse, from a run body — would load
-- the whole suite, bind F1 and register every console command as a side effect of printing one
-- line. Three lines is the cheaper and quieter answer.
-- A log whose stamp predates the deploy you just did is not evidence about the code you just
-- wrote — Lua that is already loaded STAYS loaded, and that has cost a full round of debugging
-- more than once.
--=============================================================================

local function buildStamp()
    local ok, stamp = pcall(require, "palforge.build")
    return (ok and type(stamp) == "string") and stamp or "unstamped (not deployed by tools/deploy.sh)"
end

--=============================================================================
-- declaration
--=============================================================================

---Declare a hook. Returns false and a reason when it was refused, so a hook file that is
---wrong about itself says so at load rather than at run.
---@param spec table
---@return boolean ok, string? reason
function M.declare(spec)
    if not env.debug then
        -- Should be unreachable: M.load() refuses before it requires anything. Kept because a
        -- hook file is an ordinary module and someone will eventually require one directly.
        return false, "env.debug is false, so nothing under test/hooks may declare itself"
    end
    if type(spec) ~= "table" then return false, "declare() takes a table" end

    local id = spec.id
    if type(id) ~= "string" or id == "" then
        return false, "a hook needs an `id` — the plan/TODO.md item id, spelled exactly as that file spells it"
    end
    if not id:match("^[%w%-_]+$") then
        return false, string.format("hook id %q may only contain letters, digits, - and _ "
            .. "(it becomes a console command name and an autorun.txt line)", id)
    end
    if M.declared[id] then
        return false, string.format("hook id %q is already declared — two files claim one "
            .. "plan/TODO.md item, and merging them silently would hide one of the two", id)
    end
    if type(spec.run) ~= "function" then
        return false, string.format("hook %q has no run(h) function", id)
    end
    for need in pairs(spec.needs or {}) do
        if not NEEDS[need] then
            return false, string.format("hook %q needs %q, which is not one of world / player / pal / title",
                id, tostring(need))
        end
    end

    M.declared[id] = spec
    M.order[#M.order + 1] = id
    return true
end

---Load every hook file. THE env.debug GATE LIVES HERE: with it off nothing under this
---directory is even required, and the honest line saying so is printed once.
---@return integer declared
function M.load()
    if not env.debug then
        log.info("env.debug = false, so no game-required hook is loaded. These are the "
            .. "measurements that need Palworld running; they are off in a shipped copy on "
            .. "purpose. Turn them on with `env.debug = true` in Scripts/palforge_dev.lua "
            .. "(tools/deploy.sh writes that file; see env.lua), then `pf_hooks` lists them.")
        return 0
    end
    for _, name in ipairs(M.FILES) do
        local ok, err = pcall(require, "palforge.test.hooks." .. name)
        if not ok then log.err(string.format("hook file %q failed to load: %s", name, tostring(err))) end
    end
    log.info(string.format("%d game-required hook(s) declared; `pf_hooks` prints each one's "
        .. "gate state and what would open it", #M.order))
    return #M.order
end

--=============================================================================
-- gates
--=============================================================================

---May a WRITING hook run? Returns false, or true plus the name of the switch that allowed it.
---
---⚠️ `_G.PALFORGE_TEST_WRITE_WAZA` IS THE OLD SPELLING of `env.debugHooks["pal-skills-equip"]`
---and it still works. It is written into plan/TODO.md, into test/cases/skill.lua:579 and
---into core/character.lua:86 as the way to arm the waza write, and those three sentences are
---load-bearing history — a reader who follows them must not find a switch that has been
---silently renamed out from under them.
---
---This is also the function test/cases/skill.lua's F1 gate asks, so the two spellings open the
---same two doors. It is safe to call with env.debug false: it reads env.debugHooks and one
---global and declares nothing, which is why the case file may require this module unguarded.
---@param id string
---@return boolean allowed, string? via
function M.writeAllowed(id)
    if type(env.debugHooks) == "table" and env.debugHooks[id] == true then
        return true, string.format("env.debugHooks[%q]", id)
    end
    if id == "pal-skills-equip" and _G.PALFORGE_TEST_WRITE_WAZA then
        return true, "_G.PALFORGE_TEST_WRITE_WAZA — the OLD SPELLING of "
            .. "env.debugHooks[\"pal-skills-equip\"]; both are honoured"
    end
    return false
end

---Which gates are closed on a hook, and what would open each. An empty list means it can run.
---@param spec table
---@return table[] closed   # { { gate =, what =, open = }, ... }
function M.closedGates(spec)
    local closed = {}
    local function add(gate, what, open)
        closed[#closed + 1] = { gate = gate, what = what, open = open }
    end

    if not env.debug then
        add("env.debug", "the whole test/hooks directory",
            "set env.debug = true in Scripts/palforge_dev.lua and reload (F9) or restart")
    end

    -- ORDER MATTERS BELOW. `pal` implies a world; asking for the pal first would report "no pal
    -- near you" at the title screen, which is true and useless. World first, then pawn, then pal.
    local needs = spec.needs or {}
    local haveWorld = support.worldReady()
    if needs.world and not haveWorld then
        add("needs.world", NEEDS.world.what, NEEDS.world.open)
    end
    if needs.title and haveWorld then
        add("needs.title", NEEDS.title.what, NEEDS.title.open)
    end
    if needs.player and not support.player() then
        add("needs.player", NEEDS.player.what, NEEDS.player.open)
    end
    if needs.pal and haveWorld and not (support.nearbyPal()) then
        add("needs.pal", NEEDS.pal.what, NEEDS.pal.open)
    end

    if spec.writes and not M.writeAllowed(spec.id) then
        add("writes", "an opt-in for a hook that MUTATES A REAL SAVE",
            string.format("set env.debugHooks[%q] = true in Scripts/palforge_dev.lua, on a save "
                .. "you do not mind losing", spec.id))
    end
    return closed
end

--=============================================================================
-- the run context: h:log / h:pass / h:fail / h:note
--=============================================================================

local Ctx = {}
Ctx.__index = Ctx

local function fmt(f, ...)
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, f, ...)
        return ok and s or tostring(f)
    end
    return tostring(f)
end

---A plain line inside the block.
function Ctx:log(f, ...) log.info(fmt(f, ...)) end

---An observation that is not a verdict — the shape of a thing, a count, a warning about what
---the number does NOT mean.
function Ctx:note(f, ...) log.info("NOTE " .. fmt(f, ...)) end

---Something was measured and it is what it should be.
function Ctx:pass(f, ...)
    self.passes = self.passes + 1
    log.info("PASS " .. fmt(f, ...))
end

---Something was measured and it is NOT what it should be. A hook that answers the question
---with a negative should use :pass for a CONFIRMED negative and :fail only for a genuine
---defect — `skill-hit-source` exists to confirm that nothing carries a waza, and that is a
---pass, not a failure.
function Ctx:fail(f, ...)
    self.failures = self.failures + 1
    log.err("FAIL " .. fmt(f, ...))
end

---A refusal: something this hook chose not to do, and why. Never a silent return.
function Ctx:warn(f, ...) log.warn("WARN " .. fmt(f, ...)) end

---A named value, in the shape the probes print: `VALUE <name> = <v>`.
function Ctx:value(name, v) log.info(string.format("VALUE %-38s = %s", tostring(name), tostring(v))) end

---A titled sub-section inside the block.
function Ctx:section(title) log.info("-- " .. tostring(title) .. " --") end

---AN INSTRUCTION TO THE PERSON AT THE KEYBOARD. Goes to UE4SS.log AND onto the player's screen,
---because a hook that needs the inventory opened and says so only in a log file is a hook whose
---operator never finds out. Several hooks here cannot produce their measurement without one.
function Ctx:ask(f, ...)
    local text = fmt(f, ...)
    log.info("DO NOW: " .. text)
    support.announce(self.id .. ": " .. text)
end

---Open an extra bracketed block, for a hook that keeps reporting after run() returns.
function Ctx:beginBlock(suffix)
    log.info(string.format("#### BEGIN %s%s", self.id, suffix and ("-" .. tostring(suffix)) or ""))
end

---Close one opened with :beginBlock.
function Ctx:endBlock(suffix)
    log.info(string.format("#### END %s%s", self.id, suffix and ("-" .. tostring(suffix)) or ""))
end

--=============================================================================
-- running
--=============================================================================

---Run one hook by its plan/TODO.md id. Returns true when the body ran to completion; false
---(with a named, printed reason) when a gate refused it or the body raised.
---@param id string
---@return boolean ran, string? why
function M.run(id)
    local spec = M.declared[id]
    if not spec then
        if not env.debug then
            log.warn(string.format("no hook %q: env.debug is false, so none is loaded. %s",
                tostring(id), "Set env.debug = true in Scripts/palforge_dev.lua and reload."))
            return false, "env.debug"
        end
        log.warn(string.format("no hook %q. Declared: %s", tostring(id),
            #M.order > 0 and table.concat(M.order, ", ") or "(none)"))
        return false, "unknown id"
    end

    local closed = M.closedGates(spec)
    log.info(string.format("#### BEGIN %s", id))
    log.info(string.format("NOTE %s  [%s]", tostring(spec.desc or ""), tostring(spec.item or "?")))
    log.info(string.format("NOTE build %s | dev=%s debug=%s | game %s (live %s)",
        buildStamp(), tostring(env.dev), tostring(env.debug),
        tostring(env.gameBuild), tostring(env.gameBuildLive or "not read yet")))

    if #closed > 0 then
        -- THE REFUSAL, NAMED. Every line says which gate closed and the sentence that opens it.
        for _, c in ipairs(closed) do
            log.warn(string.format("REFUSED %s: this hook needs %s. TO OPEN IT: %s",
                c.gate, c.what, c.open))
        end
        log.info(string.format("NOTE %s did NOT run, and nothing about %s was measured. The "
            .. "line(s) above are the reason, not a result.", id, id))
        log.info(string.format("#### END %s", id))
        return false, closed[1].gate
    end

    if spec.writes then
        local _, via = M.writeAllowed(id)
        log.warn(string.format("⚠️ THIS HOOK WRITES INTO THE LOADED SAVE. It is running because "
            .. "%s. Everything it changes is stated below before it is done.", tostring(via)))
    end

    local h = setmetatable({ id = id, spec = spec, passes = 0, failures = 0 }, Ctx)
    local ok, err = pcall(spec.run, h)
    if not ok then
        log.err(string.format("FAIL %s raised: %s", id, tostring(err)))
        h.failures = h.failures + 1
    end
    log.info(string.format("NOTE %s finished: %d pass, %d fail", id, h.passes, h.failures))
    log.info(string.format("#### END %s", id))
    return ok == true
end

---Run every hook whose gate is open, in M.FILES order (read-only first). The closed ones are
---listed with their reasons rather than passed over in silence.
---@return integer ran, integer skipped
function M.runAll()
    local ran, skipped = 0, 0
    if #M.order == 0 then
        for _, line in ipairs(M.report()) do log.info(line) end
        return 0, 0
    end
    for _, id in ipairs(M.order) do
        local spec = M.declared[id]
        if #M.closedGates(spec) == 0 then
            if M.run(id) then ran = ran + 1 else skipped = skipped + 1 end
        else
            skipped = skipped + 1
            local closed = M.closedGates(spec)
            log.info(string.format("SKIP %-26s %s (%s)", id, closed[1].gate, closed[1].open))
        end
    end
    log.info(string.format("hooks: %d ran, %d skipped. `pf_hooks` says what would open each "
        .. "skipped one.", ran, skipped))
    return ran, skipped
end

---One line per declared hook: what it measures, what it needs, whether it writes, and — when
---it cannot run right now — which gate is shut and the sentence that opens it.
---@return string[]
function M.report()
    local out = {}
    local function add(f, ...) out[#out + 1] = fmt(f, ...) end

    add("hooks: build %s | dev=%s debug=%s | game %s (live %s)",
        buildStamp(), tostring(env.dev), tostring(env.debug),
        tostring(env.gameBuild), tostring(env.gameBuildLive or "not read yet"))
    if not env.debug then
        add("hooks: env.debug = false, so NO hook is loaded and none of the game-required "
            .. "measurements can be taken. TO OPEN IT: set `env.debug = true` in "
            .. "Scripts/palforge_dev.lua (tools/deploy.sh writes that file — see env.lua), "
            .. "then reload with F9 or restart the game.")
        return out
    end
    if #M.order == 0 then
        -- TWO CAUSES, AND THEY LOOK IDENTICAL FROM HERE, so both are named rather than the
        -- likelier one guessed at. M.load() is what requires the files, and the only caller is
        -- test/init.lua — so a session where palforge.test itself failed to load reaches this
        -- line having never ATTEMPTED a hook file, and reporting that as "they all failed"
        -- would send a reader looking for a fault in every file in FILES, none of which was
        -- ever opened. (That sentence used to say "twelve files"; FILES has grown three times
        -- since, and a count written into prose beside a list that changes is a count that lies.)
        add("hooks: env.debug is on and nothing declared itself. Either M.load() has not run at "
            .. "all — it is called from test/init.lua, so check for a [test] or [registry] error "
            .. "above — or every file in test/hooks/init.lua's FILES list failed to load, in "
            .. "which case there is one [hooks][err] line naming each.")
        return out
    end

    add("hooks: %d declared. `pf_hook <id>` runs one, `pf_hooks_all` runs every OPEN one, and "
        .. "autorun.txt takes the generated name in the last column.", #M.order)
    for _, id in ipairs(M.order) do
        local spec = M.declared[id]
        local closed = M.closedGates(spec)
        local needs = {}
        for need in pairs(spec.needs or {}) do needs[#needs + 1] = need end
        table.sort(needs)
        add("hooks   %-26s %-9s needs=%-18s %s", id,
            spec.writes and "WRITES" or "read",
            #needs > 0 and table.concat(needs, "+") or "nothing",
            #closed == 0 and "OPEN — it will run" or "CLOSED")
        add("hooks     %s  [%s]", tostring(spec.desc or ""), tostring(spec.item or "?"))
        for _, c in ipairs(closed) do
            add("hooks     CLOSED %s: needs %s. TO OPEN IT: %s", c.gate, c.what, c.open)
        end
        add("hooks     autorun.txt: %s", M.actionName(id))
    end
    return out
end

---The generated action name for a hook id. autorun.txt reads `[delay] name` and cannot carry
---an argument (core/autorun.lua:74-82), so every hook gets its own name in test's ACTIONS
---table — the same trick test/init.lua already uses for the six probes.
---@param id string
---@return string
function M.actionName(id) return "pf_hook_" .. tostring(id):gsub("%-", "_") end

---The declared ids, in load order. For test/init.lua, which generates one action per hook.
---@return string[]
function M.ids()
    local out = {}
    for i, id in ipairs(M.order) do out[i] = id end
    return out
end

return M
