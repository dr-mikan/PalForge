-- palforge/test/probes/watch.lua — arms the live hooks and watches while YOU play (the F7 probe).
--
-- Closes five plan/TODO.md items that no amount of reflection can settle, because each one asks
-- "does the game CALL this when a human does that": item-craft-source, item-discard-source,
-- pal-spawned-hook, pal-spawned-fresh and skill-hit-source. The sixth section, pal-spawn-
-- placement, now runs as a REGRESSION check: that item closed on 2026-07-26 when the spawn was
-- observed placing a pal on its exact coordinate, and this is where a build that breaks it, or a
-- machine slower than the one it was measured on, would show up. It needs a
-- LOADED SAVE with a workbench, a stack of Wood, a Berries and a pal in the box within reach:
-- the probe arms hooks, prints a numbered list of actions, and then only YOU can make the game
-- fire them. Budget about 60 s of play.
--
-- THIS IS THE ONE PROBE THAT IS NOT PURELY PASSIVE. It registers native hooks, and UE4SS has
-- no way to unregister one — everything it arms stays armed until you quit the game. It also
-- spawns ONE ChickenPal in front of you, because pal-spawn-placement is about OUR spawn path
-- rather than a game hook. Nothing is written to the save.
--
-- Reading the result: every line is inside `#### BEGIN <id>` / `#### END <id>`, every hook line
-- starts `HOOK <label>` and carries `t=+Ns` since arming, so the actions can be told apart by
-- their timestamps. Lines that arrive after the block closed are prefixed LATE (the deferred
-- spawn pass and the window summary land there — that is expected, not a bug).
local probe   = require("palforge.test.probe")
local support = require("palforge.test.support")

local M = {}

-- How many matching names a reflection sweep prints per class. probe.LIST_LIMIT (400) is the
-- ceiling for a full dump; a watch run enumerates a dozen classes, so it stays far below it.
local MATCH_CAP    = math.min(20, probe.LIST_LIMIT)
-- How many DISCOVERED functions may be armed per section. Every hook is permanent, so the
-- number of them is capped on purpose rather than "arm everything that matched".
local MAX_ARM      = 6
-- How long the player is asked to keep acting before the summary line prints.
local WINDOW_SEC   = 60

-- Set by M.run so every hook line can say how long after arming it fired.
local T0 = 0
local function since() return os.clock() - T0 end

-- Fire counts for the hooks this file arms itself (probe.watch keeps its own count privately,
-- so those are reported by "grep for the label" instead).
M.counts = {}

--=============================================================================
-- inline helpers — everything probe.lua does not already have, written with its own
-- pcall-per-engine-call discipline. probe.lua is owned by another agent; nothing here
-- reaches into it beyond its public helpers.
--=============================================================================

---Render ANY hook parameter value in one line. probe.describe is built for UObjects and
---answers "userdata(invalid or plain)" for an FName or a bare struct — which is exactly the
---value these three TODO items are asking about, so it is rendered properly here: FName via
---ToString(), numbers WITH THEIR SIGN, structs by class name.
local function render(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" or t == "boolean" then return string.format("%s(%s)", t, tostring(v)) end
    if t == "string" then return string.format("string(%q)", v) end
    local s; if pcall(function() s = v:ToString() end) and type(s) == "string" then
        return string.format("%s:ToString()=%q", t, s)
    end
    if probe.valid(v) then return probe.describe(v) end
    local cn; pcall(function() cn = v:GetClass():GetFName():ToString() end)
    if cn then return string.format("%s<%s>", t, tostring(cn)) end
    return string.format("%s(opaque)", t)
end

---A hook parameter's value, or nil. UE4SS hands params in as wrappers with :get().
local function pget(p)
    local v; local ok = pcall(function() v = p and p:get() end)
    if not ok then return nil end
    return v
end

---Try a fixed list of field names on a value and print the ones that exist. Used where the
---struct layout is unknown but the field we want has a short list of plausible spellings.
local function fieldsOf(v, names, tag)
    if type(v) ~= "userdata" and type(v) ~= "table" then return 0 end
    local n = 0
    for _, f in ipairs(names) do
        local got; local ok = pcall(function() got = v[f] end)
        if ok and got ~= nil then
            n = n + 1
            probe.line("%s   .%s = %s", tag, f, render(got))
        end
    end
    return n
end

---Walk a value's whole class chain printing every property AND its current value. This is the
---full-fat version skill-hit-source asks for; it is budgeted because one damage struct can
---carry dozens of fields and this runs inside a hook.
local function walkFields(v, tag, budget)
    budget = budget or 40
    if type(v) ~= "userdata" and type(v) ~= "table" then return end
    local c; pcall(function() c = v:GetClass() end)
    local depth, printed = 0, 0
    while probe.valid(c) and depth < 6 and printed < budget do
        probe.line("%s STRUCT[%d] %s", tag, depth, probe.full(c))
        pcall(function()
            c:ForEachProperty(function(pr)
                if printed >= budget then return end
                pcall(function()
                    local n = probe.name(pr)
                    printed = printed + 1
                    local val; local ok = pcall(function() val = v[n] end)
                    probe.line("%s   FIELD %s : %s = %s", tag, n, probe.className(pr),
                        ok and render(val) or "read raised")
                end)
            end)
        end)
        local sup; pcall(function() sup = c:GetSuperStruct() end)
        if not probe.valid(sup) then pcall(function() sup = c.SuperStruct end) end
        c = sup
        depth = depth + 1
    end
    if printed >= budget then probe.line("%s   ... fields capped at %d", tag, budget) end
end

---Every UFunction name on a class, collected WITHOUT printing them. A class with 400 functions
---printed once per class would bury the run; the caller prints only what it matched.
local function fnNames(cls)
    local names = {}
    if not probe.valid(cls) then return names end
    pcall(function()
        cls:ForEachFunction(function(fn) pcall(function() names[#names + 1] = probe.name(fn) end) end)
    end)
    table.sort(names)
    return names
end

---Reflect one class and print only the function names containing one of `words`. Returns the
---class and the matches. An absent class prints "absent" and answers {} — that is a result.
local function grepFns(path, words, label)
    local cls = probe.class(path)
    if not cls then return nil, {} end
    local names = fnNames(cls)
    local hits = {}
    for _, n in ipairs(names) do
        local low = n:lower()
        for _, w in ipairs(words) do
            if low:find(w, 1, true) then hits[#hits + 1] = n; break end
        end
    end
    probe.line("FN %s: %d function(s), %d matching %s", label or path, #names, #hits,
        "{" .. table.concat(words, "|") .. "}")
    for i, n in ipairs(hits) do
        if i > MATCH_CAP then probe.line("FN   ... (%d more matches)", #hits - MATCH_CAP); break end
        probe.line("FN   %s", n)
    end
    if #names == 0 then probe.line("FN   <ForEachFunction returned nothing on this class>") end
    return cls, hits
end

---Arm a hook with a caller-supplied body. probe.watch is the standard tool and is used for every
---hook whose question is only "did it fire, on what"; this exists for the two hooks whose TODO
---paragraph demands parameter VALUES (an FName id, a signed count, a struct's fields), which
---probe.watch's describe cannot render. Same pcall shape, same "armed -> ok/FAILED" line.
local function armDetailed(path, label, maxLines, onFire)
    maxLines = maxLines or 24
    M.counts[label] = 0
    local ok = pcall(function()
        RegisterHook(path, function(self, a1, a2, a3, a4)
            M.counts[label] = (M.counts[label] or 0) + 1
            local n = M.counts[label]
            if n > maxLines then return end
            pcall(onFire, n, self, a1, a2, a3, a4)
            if n == maxLines then
                probe.line("HOOK %s — line cap %d reached, further fires are counted only", label, maxLines)
            end
        end)
    end)
    probe.line("NOTE armed %s -> %s", path, ok and "ok" or "FAILED (function not found on this build)")
    return ok
end

---Arm up to MAX_ARM of the discovered names on `cls`, skipping obvious getters.
local function armDiscovered(classPath, hits, prefix, maxLines, limit)
    local armed = 0
    for _, n in ipairs(hits) do
        if armed >= (limit or MAX_ARM) then break end
        local low = n:lower()
        local getterish = low:find("^get") or low:find("^is") or low:find("^can") or low:find("^set")
        if not getterish then
            local short = classPath:match("([^%.]+)$") or classPath
            probe.watch(classPath .. ":" .. n, string.format("%s %s.%s", prefix, short, n), maxLines or 12)
            armed = armed + 1
        end
    end
    if armed == 0 then probe.line("NOTE nothing armed on %s (no non-getter match)", classPath) end
    return armed
end

--=============================================================================
-- item-craft-source
--=============================================================================

local function item_craft_source()
    probe.begin("item-craft-source")
    probe.note("no candidate function for 'a bench finished an item' exists anywhere in either "
        .. "tree, so this section REFLECTS first and arms whatever it found.")

    probe.section("reflection: which craft/production functions exist at all")
    local WORDS = { "craft", "product", "complete", "finish", "output", "work" }
    local targets = {
        "/Script/Pal.PalMapObjectProductItemModel",
        "/Script/Pal.PalMapObjectConcreteModelBase",
        "/Script/Pal.PalWorkProgressModel",
        "/Script/Pal.PalWorkProgress",
        "/Script/Pal.PalMapObjectWorkeeModel",
    }
    local found = {}
    for _, path in ipairs(targets) do
        local cls, hits = grepFns(path, WORDS)
        if cls and #hits > 0 then found[#found + 1] = { path = path, cls = cls, hits = hits } end
    end
    if #found == 0 then
        probe.note("every candidate class is absent or exposes no matching function — that CLOSES "
            .. "the reflection half: item.craft cannot be sourced from these classes on this build.")
    end

    probe.section("signatures of the strongest candidates")
    -- The parameter list is the other half of the answer (which param carries the id + count),
    -- and it is readable statically, so it is printed before anything is armed.
    local shown = 0
    for _, f in ipairs(found) do
        for _, n in ipairs(f.hits) do
            local low = n:lower()
            if shown < 4 and (low:find("complete") or low:find("finish") or low:find("product")
                or low:find("output") or low:find("craft")) then
                probe.params(f.cls, n)
                shown = shown + 1
            end
        end
    end
    if shown == 0 then probe.line("PARAM (nothing worth printing a signature for)") end

    probe.section("arming")
    local armed = 0
    for _, f in ipairs(found) do
        local strong = {}
        for _, n in ipairs(f.hits) do
            local low = n:lower()
            if low:find("complete") or low:find("finish") or low:find("product")
                or low:find("output") or low:find("craft") then
                strong[#strong + 1] = n
            end
        end
        armed = armed + armDiscovered(f.path, strong, "craft", 12, 3)
    end
    probe.line("NOTE %d craft candidate hook(s) armed", armed)

    probe.note("ACTION 1 — craft ONE item at a workbench and let it finish. Then grep the log "
        .. "for 'HOOK craft'.")
    probe.note("A HIT (any 'HOOK craft ...' line) names the craft-complete function and shows "
        .. "which param carries the item id and count — installItemSource in core/event.lua can "
        .. "then emit item.craft and Item onCraft goes live for every definition.")
    probe.note("A MISS (no 'HOOK craft' line after you crafted, or '0 craft candidate hook(s) "
        .. "armed') closes the cheap route permanently: craft completion is not on the "
        .. "MapObject/WorkProgress models, and item.craft must be sourced from the get-log with a "
        .. "discriminator, or stay author-emitted. Say which of the two you saw.")
    probe.finish()
end

--=============================================================================
-- item-discard-source
--=============================================================================

local ITEM_FIELDS = { "ID", "Id", "StaticItemId", "ItemId", "ItemName", "Num", "Count", "StackCount" }

local function item_discard_source()
    probe.begin("item-discard-source")
    probe.note("the standing hypothesis is that a DROP is just AddItem_ServerInternal arriving "
        .. "with a NEGATIVE Count. Nobody has ever seen the sign of that param, so this hook "
        .. "prints a1 as an FName string and a2 as a number VERBATIM, sign included.")

    probe.section("reflection: is there a dedicated drop/discard function instead")
    local WORDS = { "discard", "drop", "remove", "sub", "consume", "trash", "throw", "lost", "destroy" }
    grepFns("/Script/Pal.PalPlayerInventoryData", WORDS)
    grepFns("/Script/Pal.PalItemContainer", WORDS)
    grepFns("/Script/Pal.PalMapObjectDropItemModel", WORDS)
    grepFns("/Script/Pal.PalMapObjectPickableItemModel", WORDS)

    probe.section("arming")
    -- core/event.lua already hooks this same path for item.obtain; a second registration is
    -- additive in UE4SS and does not disturb it. Ours is the one that prints the sign.
    armDetailed("/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal", "item.add", 30,
        function(n, self, a1, a2, a3, a4)
            local id, count = pget(a1), pget(a2)
            probe.line("HOOK item.add #%d t=+%.1fs  a1=%s  a2=%s  a3=%s  a4=%s",
                n, since(), render(id), render(count), render(pget(a3)), render(pget(a4)))
            local num = tonumber(count)
            if num then
                probe.line("HOOK item.add #%d   SIGN %s (%s)", n,
                    (num < 0 and "NEGATIVE" or (num > 0 and "positive" or "zero")), tostring(num))
            end
            fieldsOf(id, ITEM_FIELDS, string.format("HOOK item.add #%d", n))
        end)

    probe.note("ACTION 2 — drop a stack of Wood on the ground.")
    probe.note("ACTION 3 — destroy/trash one stack from the inventory menu.")
    probe.note("ACTION 4 — eat one Berries. Leave ~5 s between each so the t=+Ns stamps separate "
        .. "them (or type 'pf_mark drop' / 'pf_mark trash' / 'pf_mark eat' in the UE4SS console).")
    probe.note("A HIT with SIGN NEGATIVE for any of the three means item.discard can be emitted "
        .. "straight from installItemSource's existing AddItem hook — and it simultaneously "
        .. "confirms that utils.items.take's negative-delta call really removes items.")
    probe.note("A MISS (the hook fires only on pickups, never on a drop/trash/eat) means dropping "
        .. "does NOT route through AddItem: item.discard needs one of the functions listed under "
        .. "the reflection section above, and utils.items.take's negative delta is unproven. "
        .. "Paste the reflection list too — it is the candidate set either way.")
    probe.finish()
end

--=============================================================================
-- pal-spawned-hook
--=============================================================================

local function pal_spawned_hook()
    probe.begin("pal-spawned-hook")
    probe.note("BroadcastOnCompleteInitializeParameter has been armed once before, at MOD LOAD, "
        .. "and counted 0 calls. This run arms it in a FULLY LOADED world, which is the case "
        .. "that was never tested. core/event.lua arms the same path after world.ready; a second "
        .. "registration is additive.")

    -- The baseline matters: "0 fires" only means something if pals actually exist to fire.
    local pals = probe.allOf("PalCharacter")
    probe.line("NOTE %d PalCharacter actor(s) live at arming time (the player is one of them)", #pals)

    probe.params(probe.class("/Script/Pal.PalCharacter"), "BroadcastOnCompleteInitializeParameter")
    probe.watch("/Script/Pal.PalCharacter:BroadcastOnCompleteInitializeParameter",
        "pal.init", 24)

    probe.note("ACTION 5 — stand still for ~30 s (expect NOTHING: any fire while idle means this "
        .. "hook is a re-init signal, not a spawn signal), then release ONE pal from the palbox. "
        .. "The probe also spawns a ChickenPal for you in the pal-spawn-placement section below.")
    probe.note("Each 'HOOK pal.init' line prints self= the actor's BP class and full name — that "
        .. "is what says whether it is the NEW pal or an existing one being re-initialised.")
    probe.note("A HIT only after the release/spawn, naming the new pal's BP class, confirms "
        .. "Pal.Spec.Events.onSpawned as LIVE and the doc string in api/pal.lua drops "
        .. "'(UNCONFIRMED candidate)'.")
    probe.note("A MISS (0 lines across the whole window) closes the candidate permanently: "
        .. "onSpawned must be re-sourced, and the fallbacks armed in the pal-spawned-fresh "
        .. "section below are the next place to look.")
    probe.finish()
end

--=============================================================================
-- pal-spawned-fresh
--=============================================================================

local function pal_spawned_fresh()
    probe.begin("pal-spawned-fresh")
    probe.note("same hook as pal-spawned-hook, asked from the channel's side: does "
        .. "BroadcastOnCompleteInitializeParameter fire for a pal born AFTER the load storm, and "
        .. "is `self` then the NEW pal's actor. It is armed once, in the pal-spawned-hook section "
        .. "above — read its 'HOOK pal.init' lines for this item too. This section arms only the "
        .. "FALLBACKS the TODO names, so nothing is hooked twice.")

    probe.section("fallback 1: PalCharacter:BeginPlay")
    probe.watch("/Script/Pal.PalCharacter:BeginPlay", "pal.beginplay", 16)

    probe.section("fallback 2: the spawner classes")
    local WORDS = { "spawn" }
    local spawners = {
        "/Script/Pal.PalMonsterSpawner",
        "/Script/Pal.PalMonsterSpawnerBase",
        "/Script/Pal.PalMonsterSpawnerManager",
        "/Script/Pal.PalCharacterManager",
    }
    local armed = 0
    for _, path in ipairs(spawners) do
        local cls, hits = grepFns(path, WORDS)
        if cls and #hits > 0 and armed < MAX_ARM then
            armed = armed + armDiscovered(path, hits, "pal.spawner", 8, 2)
        end
    end
    -- Live spawner objects say which of those names the shipping build actually uses.
    probe.allOf("PalMonsterSpawner")
    probe.line("NOTE %d spawner hook(s) armed", armed)

    probe.note("ACTION 6 — release a pal from the palbox, then travel far enough for a wild pal to "
        .. "stream in, then let the probe's own ChickenPal spawn (next section) land.")
    probe.note("A HIT on 'HOOK pal.init' whose self= is a pal BP class you just created makes "
        .. "pal.spawned a real spawn signal — core/event.lua:900's TODO comes out unchanged.")
    probe.note("A MISS on pal.init but a HIT on 'HOOK pal.beginplay' or 'HOOK pal.spawner' names "
        .. "the replacement source: core/event.lua's tryHookAfterWorldReady switches path and the "
        .. "channel, dispatch and Pal onSpawned keep working as they are.")
    probe.note("A MISS on ALL of them means no pal-birth signal is reachable from Lua on this "
        .. "build, and pal.spawned has to fall back to the existing 3 s PAL_SCAN sweep "
        .. "(first-seen actor = spawned). That is a real answer too — say so.")
    probe.finish()
end

--=============================================================================
-- skill-hit-source
--=============================================================================

local SKILL_FIELDS = { "WazaType", "Waza", "WazaID", "SkillId", "SkillID", "AttackType", "AttackId",
                       "AttackerId", "DamageType", "Type", "Id", "ID", "Name" }

local function skill_hit_source()
    probe.begin("skill-hit-source")
    probe.note("OnDamageReaction is the ONE damage hook confirmed to fire (it is already "
        .. "core/event.lua's pal.damaged source). The only question is whether any of its params "
        .. "carries the waza/skill FName — so this dumps each param struct's WHOLE field list "
        .. "with values, twice, then just the interesting fields.")

    probe.params(probe.class("/Script/Pal.PalCharacter"), "OnDamageReaction")

    armDetailed("/Script/Pal.PalCharacter:OnDamageReaction", "pal.damage", 10,
        function(n, self, a1, a2, a3, a4)
            local tag = string.format("HOOK pal.damage #%d", n)
            local s = pget(self)
            probe.line("%s t=+%.1fs  self=%s", tag, since(), render(s))
            for i, p in ipairs({ a1, a2, a3, a4 }) do
                local v = pget(p)
                probe.line("%s   a%d=%s", tag, i, render(v))
                if v ~= nil then
                    if n <= 2 then
                        -- The first two firings get the full walk; that is where the field NAME
                        -- we are hunting for shows up. Later ones stay short.
                        walkFields(v, string.format("%s a%d", tag, i), 40)
                    else
                        fieldsOf(v, SKILL_FIELDS, string.format("%s   a%d", tag, i))
                    end
                end
            end
        end)

    probe.note("ACTION 7 — hit a pal with a NAMED move (a fire attack from your own pal, say), "
        .. "wait ~5 s, then hit one with a plain melee swing. The two blocks are diffed against "
        .. "each other: a field that changes with the move is the skill id.")
    probe.note("A HIT — any FIELD whose value differs between the named move and the melee hit, "
        .. "and reads like a waza row name — gives core/event.lua a skill.hit channel keyed by "
        .. "skill id, and pal.damaged's existing ctx is simply extended with it.")
    probe.note("A MISS (identical field values for both, or no struct params at all) closes it: "
        .. "the skill identity is NOT reachable from the damage hook, Skill onHit stays "
        .. "Handle:hit-only, and the next candidate is the (so far 0-firing) "
        .. "PalPlayerController:SkillDamageReactionComponent_ProcessDamage_ToServer.")
    probe.finish()
end

--=============================================================================
-- pal-spawn-placement
--
-- The odd one out: this item is about OUR code path, not a game hook, so the probe performs
-- the spawn itself and reports what core/spawn's deferred pass logged.
--=============================================================================

local spawnSinkInstalled = false

---Mirror [PalForge.spawn] log lines into this probe's own output. The placement outcome is
---written by core/spawn's retry chain seconds after this section has closed, so without this
---the answer lands somewhere else in a busy log. Bounded, and installed at most once: the
---logger has addSink but no removeSink.
local function captureSpawnLog(budget)
    if spawnSinkInstalled then
        probe.note("spawn-log capture already installed earlier this session (it is permanent)")
        return true
    end
    local ok = pcall(function()
        local logger = require("palforge.utils.log")
        local left = budget or 24
        logger.addSink(function(level, scope, msg)
            if scope ~= "spawn" or left <= 0 then return end
            left = left - 1
            -- scope is "spawn", ours is "probe", so this can never recurse.
            probe.line("LATE [PalForge.spawn][%s] %s", tostring(level), tostring(msg))
        end)
    end)
    spawnSinkInstalled = ok
    probe.line("NOTE mirroring [PalForge.spawn] log lines into this probe -> %s",
        ok and "ok" or "FAILED (utils.log unavailable)")
    return ok
end

local function pal_spawn_placement()
    probe.begin("pal-spawn-placement")
    probe.note("THIS SECTION SPAWNS ONE ChickenPal ~6 m in front of you. It is the only state "
        .. "this probe creates; kill it or walk away afterwards. Everything else here is a read.")

    local target = support.inFront(600, 50)
    if not target then
        probe.line("VALUE support.inFront -> nil (no player location) — nothing spawned")
        probe.note("re-run inside a loaded world; with no coordinate there is nothing to place.")
        probe.finish()
        return
    end
    probe.line("VALUE target coordinate -> (%.0f, %.0f, %.0f)", target.x, target.y, target.z)

    local baseline = support.nearestPal(target)
    probe.line("VALUE before: %d PalCharacter(s) live, nearest to target is %s",
        baseline and baseline.count or 0,
        baseline and string.format("%.0f cm away", baseline.dist) or "unknown")

    -- Armed BEFORE the call so the immediate world-delta line is caught along with the
    -- deferred outcome.
    captureSpawnLog(24)

    local spawned, err
    local ok = pcall(function()
        local Pal = require("palforge.api.pal")
        spawned = Pal.get("ChickenPal"):spawn(target)
    end)
    if not ok then
        err = "api.pal route raised"
        pcall(function()
            local spawn = require("palforge.core.spawn")
            spawned = spawn.palAt("ChickenPal", 1, target.x, target.y, target.z)
            err = "api.pal raised; fell back to core.spawn.palAt"
        end)
    end
    probe.line("VALUE Pal.get('ChickenPal'):spawn(target) -> %s%s",
        tostring(spawned), err and ("  [" .. err .. "]") or "")
    -- What this boolean means has changed twice. It was "accepted", which was wrong; then it was
    -- a world count taken in the statement after the call, which was worse — the spawn is
    -- ASYNCHRONOUS, so that count read 0 for spawns that worked and the whole route was written
    -- off as dead on the strength of it. It now means what it can: the native call was issued.
    probe.note("true is the EXPECTED answer, and it says only that the call was ISSUED — "
        .. "core.signature matched SpawnMonster's live declaration and it ran. false means the "
        .. "call was refused or raised, or there was no cheat manager to make it on, and the "
        .. "[PalForge.spawn] lines above say which. The PAL is seconds away: on 2026-07-26 it "
        .. "arrived ~5.9 s after the call, and the placement chain moved it onto the target off "
        .. "by 0 cm. The LATE lines below are where that shows up.")

    -- Read the world back LONG after the call. This used to fire at 5 s, which is EARLIER than
    -- the only arrival anyone has timed (5.9 s) — it would have printed "the nearest pal is 600
    -- cm away, probably just you" about a spawn that was seconds from landing on the target.
    -- 12 s is double the measured arrival, and it is a nominal 12 s at that: LoopAsync +
    -- ExecuteInGameThread stretch under load, so the real wait is longer, never shorter.
    local READBACK_MS = 12000
    if type(LoopAsync) == "function" then
        LoopAsync(READBACK_MS, function()
            local body = function()
                pcall(function()
                    local near = support.nearestPal(target)
                    if near then
                        probe.line("LATE pal-spawn-placement: %d s later the nearest PalCharacter to "
                            .. "(%.0f,%.0f,%.0f) is %.0f cm away (%d pals live). Under ~100 means "
                            .. "the coordinate route WORKED here too; ~600 is probably just you.",
                            READBACK_MS // 1000, target.x, target.y, target.z, near.dist, near.count)
                    else
                        probe.line("LATE pal-spawn-placement: %d s later no PalCharacter could be "
                            .. "enumerated at all", READBACK_MS // 1000)
                    end
                end)
            end
            if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(body) else body() end
            return true   -- one shot
        end)
        probe.note("a LATE readback line prints ~12 s from now, AFTER this block's #### END.")
    else
        probe.note("LoopAsync is unavailable this session, so no readback is scheduled — read the "
            .. "[PalForge.spawn] LATE lines instead.")
    end

    probe.note("PASTE every LATE [PalForge.spawn] line: exactly one of 'placed new pal at (...); "
        .. "it reads back (...), off by N (T s after the call)' / 'found the new pal but "
        .. "K2_TeleportTo did not report success' / 'no new pal actor appeared to place' is the "
        .. "outcome, and the T is worth as much as the N.")
    probe.note("pal-spawn-placement itself is CLOSED — it was observed end to end on 2026-07-26, "
        .. "off by 0 cm twice — so this section is now a REGRESSION check plus a timing sample: "
        .. "the one number nobody has more than two of is how long the pal takes to arrive on "
        .. "hardware that is not the machine it was measured on.")
    probe.note("A MISS ('K2_TeleportTo did not report success' -> the one declared relocate refuses "
        .. "a PalCharacter here; 'no new pal actor appeared' -> nothing arrived within 20 looks, "
        .. "which is ~2x the measured arrival) is a REOPENING, and the T on the surviving lines "
        .. "is the first thing to look at.")
    probe.finish()
end

--=============================================================================
-- the run
--=============================================================================

---Print the standing warning + the numbered action list. Runs BEFORE anything is armed,
---on screen and in the log, because a hook cannot be taken back.
local function announcePlan()
    local screen = {
        "watch probe: ARMING NATIVE HOOKS NOW",
        "they CANNOT be removed until you restart the game",
        "1. craft one item at a workbench",
        "2. drop a stack of Wood on the ground",
        "3. trash one stack from the inventory menu",
        "4. eat one Berries",
        "5. release one pal from the palbox",
        "6. hit a pal with a NAMED move, then plain melee",
        "keep acting for ~" .. WINDOW_SEC .. " s, ~5 s apart. Then read UE4SS.log",
    }
    for _, line in ipairs(screen) do support.announce(line) end

    probe.line("#### BEGIN watch")
    probe.line("NOTE this probe ARMS NATIVE HOOKS. UE4SS cannot unregister a hook: every hook "
        .. "armed below stays armed until you quit the game. Nothing is written to your save.")
    probe.line("NOTE it also SPAWNS ONE ChickenPal in front of you (pal-spawn-placement is about "
        .. "PalForge's own spawn path, not a game hook). That is the only state it creates.")
    probe.line("NOTE do these, ~5 s apart, while it watches (about %d s):", WINDOW_SEC)
    probe.line("NOTE   1. craft ONE item at a workbench            -> grep 'HOOK craft'")
    probe.line("NOTE   2. drop a stack of Wood on the ground       -> grep 'HOOK item.add'")
    probe.line("NOTE   3. trash ONE stack from the inventory menu  -> grep 'HOOK item.add'")
    probe.line("NOTE   4. eat ONE Berries                          -> grep 'HOOK item.add'")
    probe.line("NOTE   5. release ONE pal from the palbox          -> grep 'HOOK pal.init'")
    probe.line("NOTE   6. hit a pal with a NAMED move, then melee  -> grep 'HOOK pal.damage'")
    probe.line("NOTE every hook line carries t=+Ns since arming, so the six actions are told "
        .. "apart by their timestamps; type 'pf_mark <text>' in the UE4SS console between "
        .. "actions if you want explicit separators.")
    probe.line("#### END watch")
end

---Optional console separator: `pf_mark drop` prints a marker line into the same log.
local function installMarker()
    local ok = pcall(function()
        RegisterConsoleCommandHandler("pf_mark", function(_, params)
            local text = (type(params) == "table" and table.concat(params, " ")) or ""
            probe.line("#### MARKER %s t=+%.1fs", (#text > 0 and text or "(unnamed)"), since())
            return true
        end)
    end)
    probe.line("NOTE console command 'pf_mark <text>' -> %s", ok and "available" or "unavailable")
    return ok
end

---Print the watch window's closing summary once the player has had their 60 s.
local function closeWindowLater()
    if type(LoopAsync) ~= "function" then
        probe.line("NOTE LoopAsync unavailable — no closing summary will print; the hooks are "
            .. "armed regardless and keep logging.")
        return false
    end
    LoopAsync(WINDOW_SEC * 1000, function()
        pcall(function()
            probe.line("#### BEGIN watch-summary")
            probe.line("NOTE the %d s window is up. Hooks armed by this probe are STILL ARMED and "
                .. "keep logging until you quit the game.", WINDOW_SEC)
            local any = false
            for label, n in pairs(M.counts) do
                any = true
                probe.line("NOTE fired: %-12s %d time(s)", label, n)
            end
            if not any then probe.line("NOTE no self-counted hook fired") end
            probe.line("NOTE for the rest, grep 'HOOK craft', 'HOOK pal.init', 'HOOK pal.beginplay' "
                .. "and 'HOOK pal.spawner'. NO LINE IS AN ANSWER: it closes that candidate.")
            probe.line("NOTE now copy every '#### BEGIN <id>' .. '#### END <id>' block plus any "
                .. "LATE / HOOK / MARKER lines below them, and paste them into the matching "
                .. "plan/TODO.md item.")
            probe.line("#### END watch-summary")
        end)
        support.announce("watch: " .. WINDOW_SEC .. " s window closed - copy UE4SS.log")
        return true   -- one shot
    end)
    return true
end

-- Run every section. Returns the number that ran.
function M.run()
    if not support.player() then
        probe.line("NOTE watch.lua needs a LOADED SAVE: load your world, stand next to a workbench "
            .. "with a stack of Wood, a Berries and a pal in the box, then press the probe key "
            .. "again. Nothing was armed and nothing was spawned.")
        return 0
    end

    T0 = os.clock()
    announcePlan()
    installMarker()

    local sections = {
        { "item-craft-source",   item_craft_source },
        { "item-discard-source", item_discard_source },
        { "pal-spawned-hook",    pal_spawned_hook },
        { "pal-spawned-fresh",   pal_spawned_fresh },
        { "skill-hit-source",    skill_hit_source },
        { "pal-spawn-placement", pal_spawn_placement },
    }

    local ran = 0
    for _, s in ipairs(sections) do
        local ok, err = pcall(s[2])
        if ok then
            ran = ran + 1
        else
            -- A section that raises still counts as a section that reported: say which one and
            -- why, rather than letting one bad call take the other five down with it.
            probe.line("NOTE section %s RAISED: %s (its block may be unterminated)", s[1], tostring(err))
            probe.finish()
        end
    end

    closeWindowLater()
    probe.line("NOTE watch: %d of %d section(s) ran; now go do the six actions.", ran, #sections)
    support.announce("watch: " .. ran .. " section(s) armed - go act")
    return ran
end

return M
