-- palforge/test/probes/watch.lua — arms the live hooks and watches while YOU play (the F7 probe).
--
-- Closes seven plan/TODO.md items that no amount of reflection can settle, because each one asks
-- "does the game CALL this when a human does that": item-craft-source, item-discard-source,
-- pal-spawned-hook, pal-spawned-fresh, skill-activate-source, skill-hit-source and
-- skill-passive-source. The eighth section, pal-spawn-placement, now runs as a REGRESSION check:
-- that item closed on 2026-07-26 when the spawn was observed placing a pal on its exact
-- coordinate, and this is where a build that breaks it, or a machine slower than the one it was
-- measured on, would show up. It needs a LOADED SAVE with a workbench, a stack of Wood, a
-- Berries and a pal in the box within reach: the probe arms hooks, prints a numbered list of
-- actions, and then only YOU can make the game fire them. Budget about 60 s of play.
--
-- WHAT CHANGED ON 2026-07-26, and it changes what this file is for. Every one of those seven
-- questions used to be "which function, if any" — so the sections REFLECTED first and armed
-- whatever a name-match turned up. dumps/cxx/Pal.hpp answered the "which function" half for all
-- of them, and core/event.lua now emits every channel from a named, declared native call. So
-- these sections arm THOSE EXACT PATHS and ask the one remaining question: does it fire. A
-- section that prints no HOOK line is now a real finding about the shipping build, and each one
-- says in its own MISS note which candidate is next.
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

-- REMOVED: walkFields, the in-hook "print every property of this struct and its value" walker.
-- It existed for one caller — skill-hit-source, hunting a waza id somewhere inside the damage
-- structs — and dumps/cxx/Pal.hpp printed those field lists statically instead
-- (FPalDamageRactionInfo at :1885 has six fields and none of them is a skill; FPalDamageInfo at
-- :1834 has forty and none of them is either). Running it again would spend a hook budget
-- re-deriving an answer that is now written down, so it is gone rather than kept "just in case".

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

-- The two production models core/event.lua now sources item.craft from, with the field on each
-- that names the produced item. Both were found in dumps/cxx/Pal.hpp; see installItemSource.
local CRAFT_SOURCES = {
    { path  = "/Script/Pal.PalMapObjectConvertItemModel",
      field = "CurrentRecipeId",  what = "recipe benches and furnaces" },
    { path  = "/Script/Pal.PalMapObjectProductItemModel",
      field = "ProductItemId",    what = "fixed-output producers" },
}

local function item_craft_source()
    probe.begin("item-craft-source")
    probe.note("this section is no longer a fishing trip. dumps/cxx/Pal.hpp names the "
        .. "craft-complete function outright — OnFinishWorkInServer(UPalWorkBase*), a UFUNCTION "
        .. "bound to UPalWorkBase::OnFinishWorkInServerDelegate, declared on nine classes of "
        .. "which two carry an item id — and core/event.lua's installItemSource already emits "
        .. "item.craft from both. The ONE thing left is a firing, which only you can produce.")

    probe.section("do the two classes exist on this build, and is the id field readable")
    -- Neither class is among the 21 in dumps/reflection/02_reflection.txt, so their EXISTENCE
    -- in the shipping binary has never actually been asked. That answer alone is load-bearing:
    -- an absent class means core/event's tryHook is logging "hook unavailable" every session.
    for _, c in ipairs(CRAFT_SOURCES) do
        local cls = probe.class(c.path)
        probe.line("NOTE %s -> %s  (%s; item id reads off .%s)", c.path,
            cls and "PRESENT" or "ABSENT", c.what, c.field)
        if cls then probe.params(cls, "OnFinishWorkInServer") end
    end

    probe.section("the wider sweep, in case a third production model is the one you use")
    -- Kept, but with the class names CORRECTED: PalWorkProgressModel and PalMapObjectWorkeeModel
    -- do not exist. Pal.hpp calls them UPalWorkProgress and UPalMapObjectWorkeeModule.
    local WORDS = { "craft", "product", "complete", "finish", "output", "work" }
    for _, path in ipairs({
        "/Script/Pal.PalMapObjectConcreteModelBase",
        "/Script/Pal.PalWorkProgress",
        "/Script/Pal.PalMapObjectWorkeeModule",
    }) do grepFns(path, WORDS) end

    probe.section("arming")
    -- Armed with the model's id field PRINTED, because "it fired" and "it fired with a readable
    -- item id" are two different answers and core/event needs the second one.
    for _, c in ipairs(CRAFT_SOURCES) do
        local field = c.field
        armDetailed(c.path .. ":OnFinishWorkInServer", "craft " .. field, 12,
            function(n, self, a1)
                local m = pget(self)
                local id; pcall(function() id = m[field] end)
                probe.line("HOOK craft %s #%d t=+%.1fs  self=%s  .%s=%s  work=%s",
                    field, n, since(), render(m), field, render(id), render(pget(a1)))
            end)
    end

    probe.note("ACTION 1 — craft ONE item at a workbench and let it finish. Then grep the log "
        .. "for 'HOOK craft'.")
    probe.note("A HIT with a readable .CurrentRecipeId / .ProductItemId CONFIRMS item.craft: the "
        .. "source is already wired, so Item onCraft is live for every definition and the doc "
        .. "line in api/item.lua stops saying 'NO native source exists'.")
    probe.note("A HIT with the id reading None/nil means the hook is right and the FIELD is not — "
        .. "paste the line and core/event's craftSource changes one string.")
    probe.note("A MISS (nothing after you crafted) with both classes PRESENT means the delegate "
        .. "broadcast does not reach RegisterHook here; with a class ABSENT it means the shipping "
        .. "build dropped it. Say which of the two you saw — they have different fixes.")
    probe.finish()
end

--=============================================================================
-- item-discard-source
--=============================================================================

local ITEM_FIELDS = { "ID", "Id", "StaticItemId", "ItemId", "ItemName", "Num", "Count", "StackCount" }

-- The FPalItemSlotIdAndNum a drop request carries, and the two hops core/event.lua takes to
-- turn it into an item id. Printed rather than assumed: every one of those hops is unobserved.
local SLOT_FIELDS = { "SlotId", "Num" }

local function item_discard_source()
    probe.begin("item-discard-source")
    probe.note("the standing hypothesis — that a DROP is AddItem_ServerInternal with a NEGATIVE "
        .. "Count — is DEAD, and dumps/cxx/Pal.hpp says why: dropping does not touch the "
        .. "inventory add at all. UPalNetworkItemComponent (Pal.hpp:25686) declares "
        .. "RequestDrop_ToServer(TArray<FPalItemSlotIdAndNum>, FVector, bool) at :25696 and "
        .. "RequestDispose_ToServer(FGuid, FPalItemSlotIdAndNum) at :25697 — the ground-drop and "
        .. "the inventory-menu trash, one class over from everywhere the search had been looking. "
        .. "core/event.lua now sources item.discard from both. AddItem stays armed here as the "
        .. "CONTROL: it should fire on the pickup and NOT on the drop.")

    probe.section("does the component exist, and what do the two RPCs declare")
    local comp = probe.class("/Script/Pal.PalNetworkItemComponent")
    probe.line("NOTE /Script/Pal.PalNetworkItemComponent -> %s", comp and "PRESENT" or "ABSENT")
    if comp then
        probe.params(comp, "RequestDrop_ToServer")
        probe.params(comp, "RequestDispose_ToServer")
    end
    probe.line("NOTE %d live PalNetworkItemComponent(s)", #probe.allOf("PalNetworkItemComponent"))

    probe.section("reflection: confirm the inventory classes really have no removal")
    local WORDS = { "discard", "drop", "remove", "sub", "consume", "trash", "throw", "lost", "destroy" }
    grepFns("/Script/Pal.PalPlayerInventoryData", WORDS)
    grepFns("/Script/Pal.PalItemContainer", WORDS)
    grepFns("/Script/Pal.PalNetworkItemComponent", WORDS)

    probe.section("arming")
    -- The parameters carry SLOT IDS, not item ids, so what has to be printed is whether the
    -- slot can be walked at all: the container guid, the index, and — the thing core/event
    -- needs — whether a UPalItemContainer can be found that matches.
    armDetailed("/Script/Pal.PalNetworkItemComponent:RequestDrop_ToServer", "discard.drop", 12,
        function(n, self, a1, a2, a3)
            local tag = string.format("HOOK discard.drop #%d", n)
            probe.line("%s t=+%.1fs  self=%s  location=%s  autoPickup=%s",
                tag, since(), render(pget(self)), render(pget(a2)), render(pget(a3)))
            local arr = pget(a1)
            probe.line("%s   a1(array)=%s", tag, render(arr))
            local i = 0
            pcall(function()
                arr:ForEach(function(_, e)
                    i = i + 1
                    if i > 4 then return end
                    probe.line("%s   entry[%d] = %s", tag, i, render(e))
                    fieldsOf(e, SLOT_FIELDS, tag)
                    local sid; pcall(function() sid = e.SlotId end)
                    if sid ~= nil then fieldsOf(sid, { "ContainerId", "SlotIndex" }, tag .. " SlotId") end
                end)
            end)
            if i == 0 then
                probe.line("%s   the TArray could not be walked with :ForEach — try #arr / arr[i]",
                    tag)
            end
        end)

    armDetailed("/Script/Pal.PalNetworkItemComponent:RequestDispose_ToServer", "discard.dispose", 12,
        function(n, self, a1, a2)
            local tag = string.format("HOOK discard.dispose #%d", n)
            local info = pget(a2)
            probe.line("%s t=+%.1fs  self=%s  requestId=%s  slotInfo=%s",
                tag, since(), render(pget(self)), render(pget(a1)), render(info))
            fieldsOf(info, SLOT_FIELDS, tag)
            local sid; pcall(function() sid = info.SlotId end)
            if sid ~= nil then fieldsOf(sid, { "ContainerId", "SlotIndex" }, tag .. " SlotId") end
        end)

    -- CONTROL. core/event.lua already hooks this same path for item.obtain; a second
    -- registration is additive in UE4SS and does not disturb it.
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
    probe.note("A HIT on 'HOOK discard.drop' / 'HOOK discard.dispose' with a readable .SlotIndex "
        .. "confirms the EVENT half of item.discard. The ID half is separate: watch the log for "
        .. "'[PalForge.event][warn] item.discard: the dropped slot could not be resolved' — its "
        .. "ABSENCE means core/event resolved the slot and Item onDiscard is live.")
    probe.note("A MISS on both, in single player, means a _ToServer call on a listen server is "
        .. "executed directly rather than dispatched and the hook never sees it — that is the "
        .. "one thing these two hooks cannot survive, and the next place to look is "
        .. "UPalUIInventoryModel's DropLiftUpItem / TrashLiftUpItem (Pal.hpp:30831-30843), "
        .. "which are UI-side and carry no item id.")
    probe.note("The AddItem control should show 'positive' on the pickup only. A NEGATIVE line "
        .. "would reopen the old hypothesis; nobody has ever seen one.")
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
    probe.note("A MISS (0 lines across the whole window) no longer means the game does not run "
        .. "it — dumps/cxx settled that it does, because UPalCharacterManager's spawn entry "
        .. "point subscribes to the very delegate map this function broadcasts (Pal.hpp:15538 "
        .. "vs :9016). It means the BROADCASTER is not reachable through ProcessEvent, and the "
        .. "replacement is a delegate TARGET: see the pal-spawned-fresh section, which arms "
        .. "APalPlayerCharacter:OnCompleteInitializeParameter for exactly that reason.")
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

    probe.section("fallback 1: a delegate TARGET rather than the broadcaster")
    -- THE point of this run. BroadcastOnCompleteInitializeParameter is the thing that CALLS the
    -- delegates; APalPlayerCharacter::OnCompleteInitializeParameter(APalCharacter* InCharacter)
    -- (dumps/cxx/Pal.hpp:10637) is one of the things it calls, and a dynamic-delegate target is
    -- always invoked through ProcessEvent — which is the path RegisterHook can see. If the
    -- broadcaster is silent and this one is not, that difference IS the answer.
    probe.params(probe.class("/Script/Pal.PalPlayerCharacter"), "OnCompleteInitializeParameter")
    probe.watch("/Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter", "pal.initTarget", 16)

    probe.section("fallback 2: PalCharacter:BeginPlay")
    probe.watch("/Script/Pal.PalCharacter:BeginPlay", "pal.beginplay", 16)

    probe.section("fallback 3: the spawner classes")
    -- CLASS NAMES CORRECTED against dumps/cxx/Pal.hpp: there is no PalMonsterSpawner,
    -- PalMonsterSpawnerBase or PalMonsterSpawnerManager anywhere in the binary, so the three
    -- names this list used to carry could only ever print "absent". The real ones are
    -- APalEnemySpawner (:9449), APalNPCSpawnerBase (:10217) and UPalCharacterManager (:15519).
    local WORDS = { "spawn" }
    local spawners = {
        "/Script/Pal.PalEnemySpawner",
        "/Script/Pal.PalNPCSpawnerBase",
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
    probe.allOf("PalEnemySpawner")
    probe.line("NOTE %d spawner hook(s) armed", armed)

    probe.note("ACTION 6 — release a pal from the palbox, then travel far enough for a wild pal to "
        .. "stream in, then let the probe's own ChickenPal spawn (next section) land.")
    probe.note("A HIT on 'HOOK pal.init' whose self= is a pal BP class you just created makes "
        .. "pal.spawned a real spawn signal and closes both pal-spawned items.")
    probe.note("A MISS on pal.init but a HIT on 'HOOK pal.initTarget', 'HOOK pal.beginplay' or "
        .. "'HOOK pal.spawner' names the replacement source: core/event.lua's "
        .. "tryHookAfterWorldReady switches path and the channel, dispatch and Pal onSpawned "
        .. "keep working as they are. pal.initTarget is the one to hope for — it carries the new "
        .. "character as a PARAMETER rather than as self, so the emit reads ctx.actor off a1.")
    probe.note("A MISS on ALL of them means no pal-birth signal is reachable from Lua on this "
        .. "build, and pal.spawned has to fall back to the existing 3 s PAL_SCAN sweep "
        .. "(first-seen actor = spawned). That is a real answer too — say so.")
    probe.finish()
end

--=============================================================================
-- skill-hit-source
--=============================================================================

---An EPalWazaID integer as a name, so a hook line reads "FireBlast" rather than "137".
local function wazaName(v)
    local n = tonumber(v)
    if not n then return nil end
    local ok, ch = pcall(require, "palforge.core.character")
    if not ok or type(ch) ~= "table" or type(ch.WAZA) ~= "table" then return nil end
    for k, id in pairs(ch.WAZA) do if id == n then return k end end
    return nil
end

---Render a waza parameter as "name(int)" — or say plainly that it is neither.
local function renderWaza(v)
    local n = tonumber(v)
    if not n then return render(v) .. " <-- NOT A NUMBER: the enum did not arrive as an int" end
    return string.format("%s(%d)", tostring(wazaName(n) or "<no EPalWazaID name>"), n)
end

local function skill_activate_source()
    probe.begin("skill-activate-source")
    probe.note("core/event.lua now sources skill.activate from "
        .. "UPalUtility::PlayActionByWazaID(AActor* actionActor, AActor* TargetActor, "
        .. "EPalWazaID WazaID) — dumps/cxx/Pal.hpp:32037, and the name is in the live build's "
        .. "own PalUtility listing (02_reflection.txt:2049). Three scalar parameters, one of "
        .. "which is the move's identity. It has never been armed, so this section exists to "
        .. "find out whether the game calls it or whether it is a Blueprint-facing helper the "
        .. "C++ combat path walks past.")

    probe.params(probe.class("/Script/Pal.PalUtility"), "PlayActionByWazaID")

    armDetailed("/Script/Pal.PalUtility:PlayActionByWazaID", "skill.activate", 16,
        function(n, self, a1, a2, a3)
            probe.line("HOOK skill.activate #%d t=+%.1fs  actor=%s  target=%s  waza=%s",
                n, since(), render(pget(a1)), render(pget(a2)), renderWaza(pget(a3)))
        end)

    probe.note("ACTION 7 — have YOUR pal use a move (send it at something), then use a partner "
        .. "skill yourself, then swing a melee weapon. All three within ~15 s.")
    probe.note("A HIT with a real waza name confirms skill.activate end to end: Skill "
        .. "onActivate is live for any pack that DEFINED a skill under that id.")
    probe.note("A HIT whose waza prints '<no EPalWazaID name>' means core.character.WAZA is out "
        .. "of date against this build — paste the integer.")
    probe.note("A MISS (0 lines after a pal visibly used a move) closes this candidate: the next "
        .. "one is a UPalActionWazaBase subclass's OnBeginAction, because Pal.hpp:13270 puts "
        .. "`EPalWazaID WazaID` on that class itself, so `self` would carry the identity. Say so "
        .. "and core/event's installSkillSource changes one path.")
    probe.finish()
end

local function skill_hit_source()
    probe.begin("skill-hit-source")
    probe.note("THE VICTIM SIDE IS CLOSED, and this is the correction: no struct walking on "
        .. "OnDamageReaction could ever have named the skill. dumps/cxx/Pal.hpp:1885 gives "
        .. "FPalDamageRactionInfo's COMPLETE field list — IsBlow, BlowVelocity, IsLeanBackAnime, "
        .. "IsStan, IsLargeDown, HitLocation — with no skill, no waza and no attacker in it; and "
        .. "FPalDamageInfo (:1834) has 40 fields and still no EPalWazaID, only an "
        .. "EPalWazaCategory bucket and the weapon's AttackStaticItemID. So core/event.lua "
        .. "sources skill.hit from the ATTACKER side instead: "
        .. "UPalUtility::MakeDamageInfoByWazaType(Attacker, Defencer, ..., EPalWazaID WazaType, "
        .. "...) at Pal.hpp:32046, whose 7th parameter is the move and whose 2nd is the victim.")

    probe.params(probe.class("/Script/Pal.PalUtility"), "MakeDamageInfoByWazaType")

    -- Eight parameters deep. armDetailed only forwards four, so this one is armed inline: the
    -- whole point is whether UE4SS hands over a7 at all.
    M.counts["skill.hit"] = 0
    local okHit = pcall(function()
        RegisterHook("/Script/Pal.PalUtility:MakeDamageInfoByWazaType",
            function(self, a1, a2, a3, a4, a5, a6, a7)
                M.counts["skill.hit"] = (M.counts["skill.hit"] or 0) + 1
                local n = M.counts["skill.hit"]
                if n > 12 then return end
                pcall(function()
                    probe.line("HOOK skill.hit #%d t=+%.1fs  attacker=%s  defender=%s",
                        n, since(), render(pget(a1)), render(pget(a2)))
                    probe.line("HOOK skill.hit #%d   a7(waza)=%s  a5(hitLocation)=%s",
                        n, renderWaza(pget(a7)), render(pget(a5)))
                    if pget(a7) == nil then
                        probe.line("HOOK skill.hit #%d   a7 IS NIL — UE4SS did not forward the "
                            .. "7th parameter, so skill.hit cannot read the waza here", n)
                    end
                end)
            end)
    end)
    probe.line("NOTE armed /Script/Pal.PalUtility:MakeDamageInfoByWazaType -> %s",
        okHit and "ok" or "FAILED (function not found on this build)")

    -- The victim hook stays armed as a CONTROL only: it is already core/event's pal.damaged
    -- source, and seeing it fire beside a silent skill.hit tells the two apart.
    armDetailed("/Script/Pal.PalCharacter:OnDamageReaction", "pal.damage", 6,
        function(n, self, a1)
            probe.line("HOOK pal.damage #%d t=+%.1fs  self=%s  a1=%s (control: expected to fire; "
                .. "it carries NO skill id — see the note above)",
                n, since(), render(pget(self)), render(pget(a1)))
        end)

    probe.note("ACTION 8 — hit a pal with a NAMED move (a fire attack from your own pal, say), "
        .. "wait ~5 s, then hit one with a plain melee swing.")
    probe.note("A HIT on 'HOOK skill.hit' with a real waza name on the MOVE and nothing on the "
        .. "melee swing is the ideal answer: it confirms both that the hook fires and that it is "
        .. "waza-specific rather than every-damage. Count the lines per move — this function "
        .. "BUILDS the damage, and a multi-collision move may build one per collision.")
    probe.note("A MISS on skill.hit while 'HOOK pal.damage' fires means damage is built somewhere "
        .. "this helper is not, and Skill onHit stays Handle:hit-only. Do NOT go back to walking "
        .. "the damage struct — that route is closed by the field lists above.")
    probe.finish()
end

local function skill_passive_source()
    probe.begin("skill-passive-source")
    probe.note("the old open question is answered by dumps/cxx/Pal.hpp: "
        .. "UPalIndividualCharacterParameter::AddPassiveSkill(FName AddSkill, FName "
        .. "OverrideSkill) at :21155 and ::RemovePassiveSkill(FName SkillId) at :21003 — FNames, "
        .. "not an index into a fixed-size array, and no struct anywhere. Both names are in the "
        .. "live build's full listing of that class (02_reflection.txt:1107). The owner is the "
        .. "same object's `APalCharacter* IndividualActor` property (:20910). core/event.lua "
        .. "sources skill.equip / skill.unequip from them, armed after world.ready. What is left "
        .. "is which player ACTIONS route through them.")

    local cls = probe.class("/Script/Pal.PalIndividualCharacterParameter")
    probe.params(cls, "AddPassiveSkill")
    probe.params(cls, "RemovePassiveSkill")

    armDetailed("/Script/Pal.PalIndividualCharacterParameter:AddPassiveSkill", "skill.equip", 16,
        function(n, self, a1, a2)
            local p = pget(self)
            local owner; pcall(function() owner = p.IndividualActor end)
            probe.line("HOOK skill.equip #%d t=+%.1fs  add=%s  override=%s  owner=%s",
                n, since(), render(pget(a1)), render(pget(a2)), render(owner))
        end)
    armDetailed("/Script/Pal.PalIndividualCharacterParameter:RemovePassiveSkill", "skill.unequip", 16,
        function(n, self, a1)
            local p = pget(self)
            local owner; pcall(function() owner = p.IndividualActor end)
            probe.line("HOOK skill.unequip #%d t=+%.1fs  skill=%s  owner=%s",
                n, since(), render(pget(a1)), render(owner))
        end)

    probe.note("ACTION 9 — capture ONE wild pal (capture-time random passives are the most "
        .. "likely route), and if you have a Statue of Power / passive-skill bench in reach, "
        .. "change one passive there too. Pulling a pal in and out of the party is the case "
        .. "expected NOT to fire — do it anyway, so a fire there is recorded as a surprise.")
    probe.note("A HIT with a readable passive FName and a non-nil owner confirms skill.equip / "
        .. "skill.unequip: Skill onEquip / onUnequip are live for any DEFINED skill under that "
        .. "id. Note WHICH action produced it — that is the part no dump can answer.")
    probe.note("A STORM of skill.equip lines at world load would mean the world-ready gate is "
        .. "not enough and passives are re-added rather than restored wholesale; say so, and the "
        .. "source needs a first-N-seconds suppressor.")
    probe.note("A MISS on both after a capture means these are C++-internal call sites that "
        .. "RegisterHook cannot see — the next candidate is "
        .. "UPalMapObjectOperatingTableModel:RequestChangePassiveSkill (Pal.hpp:24094), which is "
        .. "the bench's own request and takes the passive FName as its third parameter.")
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
        "5. release one pal from the palbox (wait 10 s)",
        "6. send your pal at something: make it use a MOVE",
        "7. hit a pal with a NAMED move, then plain melee",
        "8. capture one wild pal",
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
    probe.line("NOTE   2. drop a stack of Wood on the ground       -> grep 'HOOK discard.drop'")
    probe.line("NOTE   3. trash ONE stack from the inventory menu  -> grep 'HOOK discard.dispose'")
    probe.line("NOTE   4. eat ONE Berries                          -> grep 'HOOK item.add'")
    probe.line("NOTE   5. release ONE pal, then WAIT 10 s          -> grep 'HOOK pal.init'")
    probe.line("NOTE   6. make your pal USE A MOVE                 -> grep 'HOOK skill.activate'")
    probe.line("NOTE   7. hit a pal with a NAMED move, then melee  -> grep 'HOOK skill.hit'")
    probe.line("NOTE   8. capture ONE wild pal                     -> grep 'HOOK skill.equip'")
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
        { "item-craft-source",     item_craft_source },
        { "item-discard-source",   item_discard_source },
        { "pal-spawned-hook",      pal_spawned_hook },
        { "pal-spawned-fresh",     pal_spawned_fresh },
        { "skill-activate-source", skill_activate_source },
        { "skill-hit-source",      skill_hit_source },
        { "skill-passive-source",  skill_passive_source },
        { "pal-spawn-placement",   pal_spawn_placement },
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
