-- palforge/test/probes/reflect.lua — the read-only reflection sweep behind the F5 key.
--
-- Twenty-five plan/TODO.md items are all blocked on the same KIND of missing fact: a class
-- that may or may not exist in the shipping build, a UFunction's real parameter list, a row
-- struct's real column names. One press answers all of them at once. The ids this closes, in
-- the order they are printed: audio-akevent-play-signature, audio-volume-rtpc,
-- audio-custom-file-loader, item-remove-call, item-inventory-count-readback,
-- item-datatable-row-read, icons-row-read, icons-row-column, pal-icon-row, skill-icon-key,
-- spawn-actor-conventions, spatial-saveid, mesh-static-setstaticmesh, mesh-texture-import,
-- mesh-detach-destroycomponent, mesh-base-material, building-leftclick, building-break,
-- building-break-source, skill-activate-source, skill-passive-source, effect-native-status,
-- pal-skills-equip, ui-host-paths, ui-update-event. WHAT YOU NEED ON SCREEN: a loaded save
-- and nothing else — no pal has to be near you, nothing has to be crafted, and (for the
-- richest ui-host-paths block) opening the Inventory and the Build menu first costs nothing.
--
-- STRICTLY READ-ONLY. Several of those TODO paragraphs also describe a live half — call
-- AddItem_ServerInternal with a negative Count, add a component and destroy it, AddChild a
-- throwaway TextBlock into the HUD, arm a RegisterHook and go hit something. NONE of that
-- happens here: this probe only looks up, enumerates and calls getters, so it is safe in a
-- real save. Every section that has such a half ends with a NOTE naming it and saying which
-- key (F6 / F7) or console line performs it, so the reader knows what is still owed.
--
-- LOG VOLUME. A class whose whole function list is the answer is dumped whole (PalBuildObject,
-- PalSoundUtility, GameplayStatics, PalPlayerInventoryData, UDataTable, ...). Everything else
-- is greped against a needle list — and a grep ALWAYS prints the total alongside the match
-- count, so "182 total, 0 matching {destroy dismantl ...}" is a finding, not a gap.
local probe   = require("palforge.test.probe")
local support = require("palforge.test.support")

local M = {}

--=============================================================================
-- local helpers
--
-- probe.lua owns engine access; these are the few shapes it does not carry, written with
-- the same discipline — every engine touch inside a pcall, every answer printable, nothing
-- that writes. probe.lua belongs to someone else and is not edited from here.
--=============================================================================

---Case-insensitive plain-substring match against a list of lowercase needles.
local function matches(s, needles)
    local low = tostring(s):lower()
    for _, n in ipairs(needles) do
        if low:find(n, 1, true) then return true end
    end
    return false
end

---The UClass of an object (a CDO's class, an actor's class), or nil.
local function classOf(o)
    local k; pcall(function() k = o:GetClass() end)
    return probe.valid(k) and k or nil
end

---An object's class as a full path, for lines where the class PATH is the answer.
local function classFull(o)
    local k = classOf(o)
    return k and probe.full(k) or "?"
end

---The dumper's fname(): ToString when the value has one, tostring otherwise, never a raise.
local function asText(v)
    local s
    local ok = pcall(function()
        local t = type(v)
        if (t == "userdata" or t == "table") and v.ToString then s = v:ToString() else s = tostring(v) end
    end)
    return ok and tostring(s) or "?"
end

---Everything a class declares, as { name = , kind = }. `which` is "fn" or "prop".
---Returns the list plus whether the ForEach call was accepted at all — an unavailable
---ForEachFunction is itself a result worth printing.
local function collect(cls, which)
    local out = {}
    if not probe.valid(cls) then return out, false end
    local ok = pcall(function()
        if which == "fn" then
            cls:ForEachFunction(function(f)
                pcall(function() out[#out + 1] = { name = probe.name(f), kind = "UFunction" } end)
            end)
        else
            cls:ForEachProperty(function(p)
                pcall(function() out[#out + 1] = { name = probe.name(p), kind = probe.className(p) } end)
            end)
        end
    end)
    return out, ok
end

---Print only the members whose name matches `needles`, but ALWAYS print the total. A class
---with 400 functions costs three lines here instead of four hundred, and a zero-match line
---still closes its question: it says the name is not on that class under any spelling tried.
local function grep(cls, label, which, needles)
    local tag = (which == "fn") and "FN" or "PROP"
    label = tostring(label or "?")
    if not probe.valid(cls) then probe.line("%s %s -> <class absent>", tag, label); return {} end
    local all, ok = collect(cls, which)
    if not ok then
        probe.line("%s %s -> <ForEach%s unavailable>", tag, label, (which == "fn") and "Function" or "Property")
        return {}
    end
    local hits = {}
    for _, e in ipairs(all) do if matches(e.name, needles) then hits[#hits + 1] = e end end
    table.sort(hits, function(a, b) return a.name < b.name end)
    probe.line("%s %s -> %d total, %d matching {%s}", tag, label, #all, #hits, table.concat(needles, " "))
    for i, e in ipairs(hits) do
        if i > probe.LIST_LIMIT then probe.line("%s   ... (%d more)", tag, #hits - probe.LIST_LIMIT); break end
        probe.line("%s   %s : %s", tag, e.name, e.kind)
    end
    return hits
end

---grep every class in a super chain. `seen` is shared across the calls of ONE section, so a
---chain that re-enters a class already listed says so and moves on instead of repeating it.
---`sink`, when given, collects the hits as { cls = , name = , kind = , which = } so a caller
---can expand signatures afterwards without walking twice.
local function walkChain(cls, label, needles, seen, maxDepth, sink)
    seen = seen or {}
    local k, depth = cls, 0
    while probe.valid(k) and depth < (maxDepth or 10) do
        local key = probe.full(k)
        if seen[key] then
            probe.line("CHAIN [%d] %s (already listed above)", depth, key)
        else
            seen[key] = true
            probe.line("CHAIN [%d] %s", depth, key)
            local tag = string.format("%s[%d]", tostring(label), depth)
            local fh = grep(k, tag, "fn", needles)
            local ph = grep(k, tag, "prop", needles)
            if sink then
                for _, e in ipairs(fh) do sink[#sink + 1] = { cls = k, name = e.name, kind = e.kind, which = "fn" } end
                for _, e in ipairs(ph) do sink[#sink + 1] = { cls = k, name = e.name, kind = e.kind, which = "prop" } end
            end
        end
        local parent; pcall(function() parent = k:GetSuperStruct() end)
        if not probe.valid(parent) then pcall(function() parent = k.SuperStruct end) end
        k = parent
        depth = depth + 1
    end
end

---probe.params for the first `max` hits of one class's grep.
local function paramsFor(cls, hits, max)
    max = max or 8
    for i, e in ipairs(hits) do
        if i > max then probe.line("PARAM   ... (%d more shortlisted, not expanded)", #hits - max); break end
        probe.params(cls, e.name)
    end
end

---probe.params for the hits a chain walk collected, narrowed to the `prime` needles — a
---shortlist of ninety names is not a shortlist, and the signature only matters for the ones
---that could plausibly be the call.
local function paramsForHits(hits, prime, max)
    max = max or 12
    local n = 0
    for _, e in ipairs(hits) do
        if e.which == "fn" and ((not prime) or matches(e.name, prime)) then
            n = n + 1
            if n > max then
                probe.line("PARAM   ... (more matched {%s}; expand the rest by hand from the FN lines above)",
                    table.concat(prime or {}, " "))
                break
            end
            probe.params(e.cls, e.name)
        end
    end
    if n == 0 then probe.line("PARAM   (nothing in the shortlist matched {%s})", table.concat(prime or {}, " ")) end
end

---Read a property and print both the human value and the engine identity.
local function readValue(obj, propName)
    local v; local ok = pcall(function() v = obj[propName] end)
    if not ok then probe.line("VALUE %s -> read raised", tostring(propName)); return nil end
    probe.line("VALUE %s = %s   [%s]", tostring(propName), asText(v), probe.describe(v))
    return v
end

---Iterate a UE array defensively: `#arr` first (UE4SS binds it for TArray), then :ForEach.
---Returns the length, or nil when neither shape worked.
local function eachArray(arr, max, fn)
    local n; if not pcall(function() n = #arr end) then n = nil end
    if type(n) == "number" then
        for i = 1, math.min(n, max) do
            local e; if pcall(function() e = arr[i] end) then pcall(fn, i, e) end
        end
        return n
    end
    local count = 0
    local ok = pcall(function()
        arr:ForEach(function(i, e)
            count = count + 1
            if count <= max then
                local v = e; pcall(function() v = e:get() end)
                pcall(fn, i, v)
            end
        end)
    end)
    return ok and count or nil
end

---Live instances of a class, named, capped. probe.allOf prints the count for us.
local function listInstances(className, max)
    local all = probe.allOf(className)
    max = max or 40
    for i = 1, math.min(#all, max) do probe.line("LIVE   %s", probe.full(all[i])) end
    if #all > max then probe.line("LIVE   ... (%d more)", #all - max) end
    return all
end

-- ONE FindAllOf("DataTable") sweep for the whole run, cached by name. Nine sections want a
-- table by name and the sweep touches EVERY loaded table — core/icons records that route as
-- the crash-prone one (a stale pointer there raises an access violation Lua's pcall cannot
-- catch), so it happens exactly once per press instead of once per section.
local dtIndex = nil
local function dataTableByName(name)
    if not dtIndex then
        dtIndex = {}
        for _, o in ipairs(probe.allOf("DataTable")) do
            if probe.valid(o) then dtIndex[probe.name(o)] = o end
        end
    end
    local found = dtIndex[name]
    probe.line("CLASS DataTable %s -> %s", name, found and probe.full(found) or "absent")
    return found
end

-- The five column names core/icons guesses at (core/icons.lua ICON_COLUMNS), kept in front
-- of whatever a row struct really declares so a hit stays attributable to one or the other.
local ICON_GUESSES = { "SoftIcon", "IconName", "IconTexture", "Icon", "Texture" }

---Column names off probe.columns' return, as a plain list.
local function colNames(rows, max)
    local out = {}
    for i, r in ipairs(rows or {}) do
        if i > (max or 24) then break end
        out[#out + 1] = r.name
    end
    return out
end

---Concatenate two column lists without duplicates, first list first.
local function merge(first, rest)
    local out, seen = {}, {}
    for _, list in ipairs({ first or {}, rest or {} }) do
        for _, c in ipairs(list) do
            if not seen[c] then seen[c] = true; out[#out + 1] = c end
        end
    end
    return out
end

---Every proposed row-VALUE read on a live UDataTable, then the row indexed by `cols`.
---Lighter than probe.rowAccessors, which re-dumps DataTableFunctionLibrary on every call;
---that listing is printed once (under icons-row-read) and this is used everywhere else.
local function tryRow(dt, rowName, cols)
    if not probe.valid(dt) then probe.line("VALUE <no table> for row %s", tostring(rowName)); return end
    local key; pcall(function() key = FName(rowName) end)
    probe.line("VALUE FName(%q) -> %s", tostring(rowName), key ~= nil and asText(key) or "FName() unavailable")
    local attempts = {
        { "GetDataTableRowFromName(FName)",  function() return dt:GetDataTableRowFromName(key) end },
        { "GetDataTableRowFromName(string)", function() return dt:GetDataTableRowFromName(rowName) end },
        { "FindRow(FName,'probe',false)",    function() return dt:FindRow(key, "probe", false) end },
        { "GetRow(FName)",                   function() return dt:GetRow(key) end },
        { "GetRowNames()",                   function() return dt:GetRowNames() end },
    }
    for _, a in ipairs(attempts) do
        local ok, v = pcall(a[2])
        probe.line("VALUE dt:%s -> %s", a[1], ok and probe.describe(v) or ("raised: " .. tostring(v)))
        if ok and v ~= nil and (type(v) == "userdata" or type(v) == "table") then
            local n; pcall(function() n = #v end)
            if type(n) == "number" and n > 0 then probe.line("VALUE   (length %d)", n) end
            for _, c in ipairs(cols or {}) do
                local cv; local okc = pcall(function() cv = v[c] end)
                if okc and cv ~= nil then
                    probe.line("VALUE   .%s = %s   [%s]", c, asText(cv), probe.describe(cv))
                end
            end
        end
    end
end

---A UEnum's members, by asking for the name of each value in turn. Nothing in either tree
---has ever captured EPalStatusEffectType, so "GetNameByValue unavailable" is itself the news.
local function dumpEnum(e, label, maxValue)
    if not probe.valid(e) then probe.line("VALUE enum %s -> absent", tostring(label)); return end
    local any = false
    for v = 0, (maxValue or 63) do
        local nm; local ok = pcall(function() nm = e:GetNameByValue(v) end)
        if not ok then probe.line("VALUE enum %s -> GetNameByValue unavailable", tostring(label)); return end
        local s = asText(nm)
        if s ~= "" and s ~= "nil" and s ~= "None" and s ~= "?" then
            any = true
            probe.line("VALUE enum %s[%d] = %s", tostring(label), v, s)
        end
    end
    if not any then probe.line("VALUE enum %s -> no value 0..%d answered with a name", tostring(label), maxValue or 63) end
end

---The local player's UPalPlayerInventoryData, by the exact route utils/items/init.lua takes
---(PalUtility CDO -> PlayerState -> InventoryData). Every link is printed, so a nil says
---WHICH step broke. Read-only: all three are getters.
local function inventory()
    local util = probe.find("/Script/Pal.Default__PalUtility")
    if not util then return nil end
    local pawn = probe.firstOf("PalPlayerCharacter")
    if not pawn then return nil end
    local ps = probe.callGet(util, "GetPlayerStateByPlayer", pawn)
    if not probe.valid(ps) then return nil end
    local inv = probe.callGet(ps, "GetInventoryData")
    if not probe.valid(inv) then return nil end
    return inv
end

---Depth-first widget walk in exactly the shape native/ui/_widget.findByName uses
---(GetChildrenCount/GetChildAt, a child's own .WidgetTree.RootWidget, GetContent when the
---child count is zero). A child count that RAISES prints '-', and that is what identifies a
---non-panel. `budget` caps the node count so one deep HUD cannot bury the rest of the run.
local function walkWidget(w, depth, budget)
    if not probe.valid(w) or depth > 14 or budget.n <= 0 then return end
    budget.n = budget.n - 1
    local n
    local okN = pcall(function() n = w:GetChildrenCount() end)
    probe.line("WIDGET %s%s <%s> children=%s", string.rep("  ", depth), probe.name(w), classFull(w),
        (okN and n ~= nil) and tostring(n) or "-")
    pcall(function()
        local tree = w.WidgetTree
        if probe.valid(tree) and probe.valid(tree.RootWidget) then
            walkWidget(tree.RootWidget, depth + 1, budget)
        end
    end)
    local count = (okN and n) or 0
    for i = 0, count - 1 do
        local c; pcall(function() c = w:GetChildAt(i) end)
        if c then walkWidget(c, depth + 1, budget) end
    end
    if count == 0 then
        local ct; pcall(function() ct = w:GetContent() end)
        if probe.valid(ct) then walkWidget(ct, depth + 1, budget) end
    end
end

--=============================================================================
-- Audio
--=============================================================================

local function audio_akevent_play_signature()
    probe.begin("audio-akevent-play-signature")

    probe.section("the CDO the whole Audio domain calls through")
    local cdo = probe.find("/Script/Pal.Default__PalSoundUtility")
    local cls = cdo and classOf(cdo)
    probe.line("CLASS PalSoundUtility class -> %s", cls and probe.full(cls) or "absent")

    probe.section("every UFunction on UPalSoundUtility, unfiltered — the full list IS the answer")
    probe.functions(cls, "PalSoundUtility")

    probe.section("signatures, in declared parameter order (a ReturnValue line is the PlayingID question)")
    for _, fn in ipairs({ "PlayAkEventSoundByActor", "PlaySoundByActor", "StopSoundByActor",
                          "IsSoundPlayingByActor", "PlayAkEventSound", "StopAkEventSoundByActor" }) do
        probe.params(cls, fn)
    end

    probe.section("the AkAudioEvent asset the play route would be handed")
    local path = "/Game/Pal/Sound/Events/SE/UI/Item/AKE_GrabItem.AKE_GrabItem"
    local ev = probe.find(path)
    if not ev then
        -- LoadAsset only pulls the asset into memory; nothing is posted, nothing plays.
        pcall(function() ev = LoadAsset(path) end)
        probe.line("CLASS LoadAsset(%s) -> %s", path, probe.valid(ev) and probe.full(ev) or "absent")
    end
    if probe.valid(ev) then probe.line("VALUE asset class = %s", probe.className(ev)) end
    probe.allOf("AkAudioEvent")

    probe.note("HIT: a PlayAkEventSoundByActor with (AActor*, UAkAudioEvent*) and an int32 ReturnValue "
        .. "means core/sound/native can keep its call AND gain a real per-sound Handle:stop. "
        .. "A different order, or an FName second parameter, means the call is being made wrong today.")
    probe.note("MISS: no such function on the list above closes the current route entirely — Audio must "
        .. "then be re-sourced from whatever Play* names the unfiltered dump does show.")
    probe.note("STILL OWED (read-only probe, nothing is played here): the audibility half. Paste into the "
        .. "UE4SS console: local u=StaticFindObject('/Script/Pal.Default__PalSoundUtility'); "
        .. "print(pcall(function() return u:PlayAkEventSoundByActor(FindFirstOf('PalPlayerCharacter'), "
        .. "StaticFindObject('" .. path .. "')) end)) — and report whether you HEARD it.")
    probe.finish()
end

local function audio_volume_rtpc()
    probe.begin("audio-volume-rtpc")

    probe.section("(1) does any volume-capable class exist on this build at all")
    local targets = {
        { "/Script/Pal.Default__PalSoundUtility",       "PalSoundUtility" },
        { "/Script/AkAudio.Default__AkGameplayStatics", "AkGameplayStatics" },
        { "/Script/AkAudio.Default__AkComponent",       "AkComponent" },
        { "/Script/AkAudio.Default__AkAudioEvent",      "AkAudioEvent" },
    }
    local VOL = { "rtpc", "volume", "bus", "gain", "fade", "mute" }
    for _, t in ipairs(targets) do
        local o = probe.find(t[1])
        local k = o and classOf(o)
        probe.section("(2/3) " .. t[2] .. " — volume-ish names and their parameters")
        local hits = grep(k, t[2], "fn", VOL)
        paramsFor(k, hits, 6)
    end

    probe.section("(4) the RTPC / bus names themselves — nothing in either tree can supply these")
    listInstances("AkRtpc", 60)
    listInstances("AkAuxBus", 40)
    listInstances("AkAudioBank", 40)

    probe.section("live AkComponents and what owns them")
    local comps = probe.allOf("AkComponent")
    if probe.valid(comps[1]) then
        probe.line("LIVE   first = %s", probe.full(comps[1]))
        local outer; pcall(function() outer = comps[1]:GetOuter() end)
        probe.line("LIVE   outer = %s", probe.valid(outer) and probe.full(outer) or "?")
    end

    probe.note("HIT: any SetRTPCValue* with a printed parameter list, PLUS one AkRtpc name that reads like "
        .. "a volume, and setVolume can be written — the parameter list also decides its final shape "
        .. "(setVolume(v) vs setVolume(v, actor) vs a module-level bus call).")
    probe.note("MISS: four 'absent' lines plus '#AkRtpc -> none' means there is no volume entry point "
        .. "reflected here, and Audio.Handle:setVolume should be documented as permanently false "
        .. "rather than left looking implementable.")
    probe.finish()
end

local function audio_custom_file_loader()
    probe.begin("audio-custom-file-loader")

    probe.section("(1) class existence — a run of 'absent' closes this item permanently")
    local paths = {
        "/Script/Engine.Default__SoundWave",
        "/Script/Engine.Default__SoundBase",
        "/Script/Engine.Default__GameplayStatics",
        "/Script/AkAudio.Default__AkExternalMediaAsset",
        "/Script/AkAudio.Default__AkMediaAsset",
        "/Script/AkAudio.Default__AkGameplayStatics",
    }
    local found = {}
    for _, p in ipairs(paths) do found[p] = probe.find(p) end

    probe.section("(2) does a 2D sound path survive into shipping")
    local gs = found["/Script/Engine.Default__GameplayStatics"]
    grep(gs and classOf(gs), "GameplayStatics", "fn", { "sound", "audio" })
    probe.note("the COMPLETE GameplayStatics function list is dumped once, under spawn-actor-conventions")

    probe.section("(3) Wwise external-source entry points")
    for _, p in ipairs({ "/Script/AkAudio.Default__AkExternalMediaAsset",
                         "/Script/AkAudio.Default__AkMediaAsset",
                         "/Script/AkAudio.Default__AkGameplayStatics" }) do
        local k = found[p] and classOf(found[p])
        local hits = grep(k, p, "fn", { "external", "media", "source", "post", "load" })
        paramsFor(k, hits, 6)
    end

    probe.section("(4) can UE4SS Lua construct an engine object on this build at all")
    for _, g in ipairs({ "NewObject", "StaticConstructObject", "StaticConstructObject_Internal",
                         "LoadAsset", "FindObject" }) do
        probe.line("VALUE _G.%s -> %s", g, type(_G[g]))
    end

    probe.section("(5) is either pipeline alive in memory")
    probe.allOf("SoundWave")
    probe.allOf("SoundBase")
    probe.allOf("AkMediaAsset")
    probe.allOf("AkExternalMediaAsset")

    probe.note("HIT: a live AkExternalMediaAsset/AkMediaAsset class plus a Post*WithExternalSources-style "
        .. "function is the ONLY shape in which Audio.Spec.soundFile can ever work.")
    probe.note("MISS: all six absent, zero SoundWave and zero AkMediaAsset instances, and no constructor "
        .. "global -> the decision (not the implementation) follows: delete Audio.Spec.soundFile and "
        .. "core/sound/file.lua, or demote soundFile so it stops outranking a working soundPath.")
    probe.finish()
end

--=============================================================================
-- Item
--=============================================================================

local function item_remove_call()
    probe.begin("item-remove-call")

    probe.section("resolve the inventory the way utils/items does")
    local inv = inventory()
    if not probe.valid(inv) then
        probe.note("no inventory reachable — the CLASS/LIVE/VALUE lines above name the link that broke; "
            .. "nothing below can run, and that alone is worth pasting back.")
        probe.finish()
        return
    end
    probe.line("CLASS inventory = %s", probe.full(inv))
    local cls = classOf(inv)
    probe.line("CLASS inventory class = %s", cls and probe.full(cls) or "?")

    probe.section("every UFunction on the inventory class, unfiltered")
    probe.functions(cls, "PalPlayerInventoryData")

    probe.section("signatures of every removal name anyone has proposed, plus the add call itself")
    for _, fn in ipairs({ "RemoveItem", "RemoveItem_ServerInternal", "SubItem", "ConsumeItem",
                          "DecreaseItem", "DeleteItem", "DiscardItem", "DropItem", "TakeItem",
                          "LostItem", "UseItem", "AddItem_ServerInternal" }) do
        probe.params(cls, fn)
    end

    local REMOVE = { "remove", "sub", "consume", "discard", "drop", "take", "lost", "delete", "decrease", "trash", "throw" }

    probe.section("the container behind the inventory")
    local ccls = probe.find("/Script/Pal.PalItemContainer")
    paramsFor(ccls, grep(ccls, "PalItemContainer", "fn", REMOVE), 8)

    probe.section("the whole inventory class chain, removal names only")
    walkChain(cls, "inv", REMOVE, {}, 8)

    probe.note("HIT: any resolved Remove/Sub/Consume signature above replaces the negative-Count "
        .. "hypothesis in utils/items.take outright — take() gets a real call and a real result.")
    probe.note("MISS: nothing but AddItem_ServerInternal on the whole chain means the negative Count IS "
        .. "the only candidate, and only the live delta below can settle it.")
    probe.note("STILL OWED (this probe never writes to an inventory): the delta test. In a THROWAWAY "
        .. "world, console: local i=<the inv above>; print(i:CountItemNum(FName('Wood'))); "
        .. "i:AddItem_ServerInternal(FName('Wood'), -1, false, 0.0); print(i:CountItemNum(FName('Wood'))) "
        .. "— both numbers on one line, then repeat with -3.")
    probe.finish()
end

local function item_inventory_count_readback()
    probe.begin("item-inventory-count-readback")

    local inv = inventory()
    if not probe.valid(inv) then
        probe.note("no inventory reachable (see the lines above) — count() cannot be settled this run")
        probe.finish()
        return
    end
    local cls = classOf(inv)

    probe.section("is CountItemNum bound to Lua at all")
    local member; local okm = pcall(function() member = inv.CountItemNum end)
    probe.line("VALUE inv.CountItemNum -> %s (lua type %s)",
        okm and tostring(member) or "read raised", okm and type(member) or "?")

    probe.section("and what does it ANSWER — an integer, or something tonumber() turns into nil")
    local calls = {
        { "inv:CountItemNum(FName('Wood'))", function() return inv:CountItemNum(FName("Wood")) end },
        { "inv:CountItemNum('Wood')",        function() return inv:CountItemNum("Wood") end },
    }
    for _, c in ipairs(calls) do
        local ok, v = pcall(c[2])
        local num; pcall(function() num = tonumber(v) end)
        probe.line("VALUE %s -> ok=%s value=%s luatype=%s tonumber=%s [%s]",
            c[1], tostring(ok), asText(v), type(v), tostring(num), ok and probe.describe(v) or "raised")
    end

    probe.section("the signature, and every sibling name that might replace it")
    for _, fn in ipairs({ "CountItemNum", "GetItemNum", "GetItemCount", "HasItem", "GetItemStackCount",
                          "GetItemCountByStaticId", "CountItemNumByStaticId" }) do
        probe.params(cls, fn)
    end

    probe.note("HIT: a plain number back means give()/take() keep their measured verification and this "
        .. "item closes with no code change at all.")
    probe.note("MISS: 'call raised' or a userdata that tonumber() nils means both degrade permanently to "
        .. "'the call was issued', and the replacement read (walking the container's slots) has to be "
        .. "written — the PalItemContainer function list under item-remove-call is where it starts.")
    probe.finish()
end

local function item_datatable_row_read()
    probe.begin("item-datatable-row-read")

    probe.section("DT_ItemIconDataTable — schema, then every accessor anyone has proposed")
    local icon = dataTableByName("DT_ItemIconDataTable")
    local icols = colNames(probe.columns(icon, "DT_ItemIconDataTable"))
    -- probe.rowAccessors is the toolkit's full sweep (signatures + calls + the
    -- DataTableFunctionLibrary listing). It runs ONCE for the whole probe, here.
    probe.rowAccessors(icon, "Wood")
    tryRow(icon, "Wood", merge(ICON_GUESSES, icols))

    probe.section("DT_ItemRecipeDataTable_Common — the same sequence verbatim, row 'Arrow'")
    local recipe = dataTableByName("DT_ItemRecipeDataTable_Common")
    local rcols = colNames(probe.columns(recipe, "DT_ItemRecipeDataTable_Common"))
    tryRow(recipe, "Arrow", merge({ "Product_Count", "WorkAmount", "Material1_Id", "Material1_Count" }, rcols))

    probe.note("HIT: one accessor returning an indexable struct settles iconOf AND recipeOf for every "
        .. "domain at once — the tables, the row keys and the column names are already known, only "
        .. "the fetch in the middle was missing.")
    probe.note("MISS: every accessor raising or answering nil means UDataTable exposes no row VALUE to "
        .. "Lua here; recipeOf must then be sourced from the on-disk catalog instead, and core/icons "
        .. "findRow should stop pretending.")
    probe.finish()
end

--=============================================================================
-- Icons
--=============================================================================

local function icons_row_read()
    probe.begin("icons-row-read")

    probe.section("(1) what a live UDataTable actually exposes")
    local dt = dataTableByName("DT_ItemIconDataTable")
    local dcls = dt and classOf(dt)
    probe.functions(dcls, "UDataTable")
    local seen = {}
    if dcls then seen[probe.full(dcls)] = true end
    walkChain(dcls, "UDataTable", { "row" }, seen, 6)

    probe.section("(2) UDataTableFunctionLibrary — where GetDataTableRowFromName really lives in stock UE")
    local lib = probe.find("/Script/Engine.Default__DataTableFunctionLibrary")
    probe.functions(lib and classOf(lib), "DataTableFunctionLibrary")

    probe.section("(3) anything Pal-specific that reads a row for us")
    local u = probe.find("/Script/Pal.Default__PalUtility")
    grep(u and classOf(u), "PalUtility", "fn", { "icon", "row", "texture", "datatable" })

    probe.note("HIT: any reflected row-value function on ANY of the three lists is the whole item — "
        .. "core/icons.findRow swaps its two guesses for that name and iconOf goes live for all four "
        .. "domains at once.")
    probe.note("MISS: three lists with no row-value function confirms the standing suspicion "
        .. "(GetDataTableRowFromName is a CustomThunk, FindRow is an unreflected C++ template) and "
        .. "icons must be sourced from the on-disk catalog instead of at runtime.")
    probe.finish()
end

local function icons_row_column()
    probe.begin("icons-row-column")

    -- No readable row is needed for this one: the RowStruct carries the schema whether or not
    -- a row value can ever be fetched, which is why this item can close even if icons-row-read
    -- comes back empty. The GetFullName lines also settle core/icons' unverified PACKAGE_DIRS.
    for _, name in ipairs({ "DT_ItemIconDataTable", "DT_ItemIconDataTable_Common",
                            "DT_PalCharacterIconDataTable", "DT_PalCharacterIconDataTable_Common",
                            "DT_BuildObjectIconDataTable", "DT_BuildObjectIconDataTable_Common",
                            "DT_partnerSkillIconDataTable" }) do
        probe.section(name)
        local dt = dataTableByName(name)
        probe.columns(dt, name)
    end

    probe.note("HIT: the property that holds the texture ref (and its class — NameProperty vs "
        .. "SoftObjectProperty vs ObjectProperty) replaces core/icons' ICON_COLUMNS guess list, so "
        .. "readIcon looks in the right place the first time.")
    probe.note("MISS: 'no RowStruct' on every table means the schema is not reachable from Lua either, "
        .. "and the column names have to come out of the packaged assets instead.")
    probe.note("Each CLASS line above is also the table's REAL package path — paste them and core/icons' "
        .. "PACKAGE_DIRS stop being guesses.")
    probe.finish()
end

local function skill_icon_key()
    probe.begin("skill-icon-key")

    probe.section("STEP 1/2 — the table and its columns (fact (b) in full)")
    local dt = dataTableByName("DT_partnerSkillIconDataTable")
    local cols = colNames(probe.columns(dt, "DT_partnerSkillIconDataTable"))
    probe.note("STEP 3, what a UDataTable can do, is dumped once under icons-row-read")

    probe.section("STEP 4/5 — fact (a): read row 'Alpaca', which the catalog proves is real")
    tryRow(dt, "Alpaca", merge(ICON_GUESSES, cols))

    probe.note("HIT: the column holding the texture ref plus a working read gives iconOf for the 303 "
        .. "pal-named partner skills — and, being the same core/icons chain, item / pal / building too.")
    probe.note("MISS: columns printed but every read nil means only the accessor is missing (see "
        .. "icons-row-read); NO columns either means this table is not reachable from Lua at all and "
        .. "Skill.Handle:iconOf can only ever return the declared icon.")
    probe.finish()
end

--=============================================================================
-- Pal
--=============================================================================

local function pal_icon_row()
    probe.begin("pal-icon-row")

    local dt = dataTableByName("DT_PalCharacterIconDataTable")
    probe.section("(a) columns, exactly as the dumper walks them")
    local cols = colNames(probe.columns(dt, "DT_PalCharacterIconDataTable"))
    probe.section("(b) the row read, on 'ChickenPal' — a confirmed row of this table (674 on disk)")
    tryRow(dt, "ChickenPal", merge(ICON_GUESSES, cols))

    probe.note("HIT: a non-nil row plus one column holding a texture ref gives Pal.Handle:iconOf a real "
        .. "answer — and through core/icons.resolve, item / skill / building the same day.")
    probe.note("MISS: every accessor nil while the columns DID print means the schema half is closed and "
        .. "only the read is blocked; see icons-row-read for where the accessor has to come from.")
    probe.finish()
end

local function pal_skills_equip()
    probe.begin("pal-skills-equip")

    local NEEDLES = { "waza", "skill", "passive", "learn", "equip", "add" }
    local seen, hits = {}, {}

    probe.section("the four classes that could own a skill attach")
    for _, p in ipairs({ "/Script/Pal.PalCharacter", "/Script/Pal.PalCharacterParameterComponent",
                         "/Script/Pal.PalIndividualCharacterParameter",
                         "/Script/Pal.PalMonsterParameterComponent" }) do
        local c = probe.find(p)
        if c then
            seen[probe.full(c)] = true
            local hf = grep(c, p, "fn", NEEDLES)
            grep(c, p, "prop", NEEDLES)
            for _, e in ipairs(hf) do hits[#hits + 1] = { cls = c, name = e.name, which = "fn" } end
        end
    end

    probe.section("a live pal's own class chain — the BP subclass StaticFindObject cannot name")
    local pal = probe.allOf("PalCharacter")[1]
    if probe.valid(pal) then
        probe.line("LIVE   first = %s <%s>", probe.full(pal), probe.className(pal))
        walkChain(classOf(pal), "live PalCharacter", NEEDLES, seen, 10, hits)
    else
        probe.note("no live PalCharacter — the CDO lists above still stand, but the Blueprint half is "
            .. "missing; re-run with a pal deployed")
    end

    probe.section("signatures of the plausible ones")
    paramsForHits(hits, { "waza", "passive", "learn", "equip" }, 12)

    probe.note("HIT: one call taking an FName (or a waza struct) is all Pal.Spec.skills needs — the "
        .. "field is already validated and stored, it just attaches nothing today.")
    probe.note("MISS: no Waza/Skill/Learn/Equip name anywhere on those four classes or the BP chain "
        .. "means skills stays author metadata and must be documented as such.")
    probe.finish()
end

--=============================================================================
-- Spawn and world
--=============================================================================

local function spawn_actor_conventions()
    probe.begin("spawn-actor-conventions")

    probe.section("the two UFunctions by direct path — a UFunction is a UStruct, so parameters enumerate")
    for _, p in ipairs({ "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass",
                         "/Script/Engine.GameplayStatics:FinishSpawningActor" }) do
        local f = probe.find(p)
        probe.properties(f, p)
    end

    probe.section("fallback route: the CDO's class, unfiltered (this list also serves audio-custom-file-loader)")
    local cdo = probe.find("/Script/Engine.Default__GameplayStatics")
    local cls = cdo and classOf(cdo)
    probe.functions(cls, "GameplayStatics")

    probe.section("the same two signatures via GetFunctionByName, in declared order")
    probe.params(cls, "BeginDeferredActorSpawnFromClass")
    probe.params(cls, "FinishSpawningActor")

    probe.note("HIT: the parameter COUNT and order settle which of core/spawn.actor's four conventions is "
        .. "the real one — watch for a trailing scale-method enum, which is 5.3+ in stock UE and is the "
        .. "argument most likely to be missing today.")
    probe.note("MISS: both paths absent AND no such names on the CDO's class means deferred spawning is "
        .. "not reachable from Lua here, and core.spawn.actor should say so instead of trying four ways.")
    probe.note("STILL OWED (this probe spawns nothing): the live call. Console, throwaway world: "
        .. "require('palforge.core.spawn').actor(FindFirstOf('PalPlayerCharacter'), "
        .. "StaticFindObject('/Script/Engine.StaticMeshActor'), { Translation = <player pos>, "
        .. "Rotation = {}, Scale3D = { X=1, Y=1, Z=1 } }) — paste its 'convention N worked' / "
        .. "'all conventions failed' / 'FinishSpawningActor never ran' line.")
    probe.finish()
end

local function spatial_saveid()
    probe.begin("spatial-saveid")

    local gi = probe.firstOf("PalGameInstance")
    if not gi then
        probe.note("no live PalGameInstance — saveId() cannot be settled without one; re-run in a save")
        probe.finish()
        return
    end
    probe.line("CLASS PalGameInstance class = %s", classFull(gi))

    probe.section("(1) the whole class chain, save/world identifiers only")
    local NEEDLES = { "save", "world", "guid", "slot", "id", "name" }
    local hits = {}
    walkChain(classOf(gi), "PalGameInstance", NEEDLES, {}, 12, hits)

    probe.section("(2) and what each of those properties actually HOLDS right now")
    local read, seen = 0, {}
    for _, e in ipairs(hits) do
        if e.which == "prop" and not seen[e.name] then
            seen[e.name] = true
            read = read + 1
            if read > 40 then probe.line("VALUE ... (more matched; read the rest by hand)"); break end
            readValue(gi, e.name)
        end
    end
    if read == 0 then probe.note("no property on the whole chain matched save/world/guid/slot/id/name") end

    probe.note("HIT: a property whose value DIFFERS between two save files is the answer, and saveId() "
        .. "can return a real w_<id> so each world gets its own state/entities_<id>.json.")
    probe.note("MISS: a chain with no such property — or one whose value is constant — leaves the honest "
        .. "documentation as 'one shared persistence bucket per install'.")
    probe.note("CRITICAL: this block is only conclusive when run in TWO DIFFERENT saves and both logs are "
        .. "pasted. A constant value is as useless as today's 'world' fallback.")
    probe.finish()
end

--=============================================================================
-- Mesh
--=============================================================================

local function mesh_static_setstaticmesh()
    probe.begin("mesh-static-setstaticmesh")

    local cls = probe.find("/Script/Engine.StaticMeshComponent")

    probe.section("the two calls kind=\"static\" rests on")
    probe.params(cls, "SetStaticMesh")
    probe.params(cls, "GetStaticMesh")
    probe.params(cls, "GetNumMaterials")

    probe.section("and whether a read-back path exists at all")
    grep(cls, "StaticMeshComponent", "fn", { "staticmesh" })
    grep(cls, "StaticMeshComponent", "prop", { "staticmesh", "mesh" })

    probe.section("the asset a shipped WorkBench would be handed")
    local asset = probe.find("/Game/Pal/Model/Prop/Architecture/WorkBenchPrimitive/SM_WorkBenchPrimitive.SM_WorkBenchPrimitive")
    if probe.valid(asset) then probe.line("VALUE asset class = %s", probe.className(asset)) end
    probe.allOf("StaticMeshComponent")

    probe.note("HIT: SetStaticMesh taking exactly one ObjectProperty, plus either a GetStaticMesh "
        .. "UFunction or a StaticMesh property to read back, and kind=\"static\" is unblocked — with it "
        .. "every curated building and every inline Building.Spec.Mesh.")
    probe.note("MISS: 'function absent' means the setter is not reflected and the static backend needs a "
        .. "different component class entirely.")
    probe.note("STILL OWED (adding a component to your pawn is a state change, so it is not done here): "
        .. "the live round trip — AddComponentByClass, SetStaticMesh, read it back — belongs to the F6 "
        .. "pass or the console.")
    probe.finish()
end

local function mesh_texture_import()
    probe.begin("mesh-texture-import")

    local krl = probe.find("/Script/Engine.Default__KismetRenderingLibrary")
    local cls = krl and classOf(krl)
    probe.section("every UFunction on UKismetRenderingLibrary")
    probe.functions(cls, "KismetRenderingLibrary")
    probe.section("the one that matters, and what it wants as its world context")
    probe.params(cls, "ImportFileAsTexture2D")

    probe.note("HIT: the parameter list tells us whether the first argument is a WorldContextObject that "
        .. "will accept an actor (what core/mesh passes today) and whether the path is an FString — "
        .. "which is the whole of Mesh.Spec.texture on all four kinds.")
    probe.note("MISS: 'krl absent' or 'function absent' closes texture import permanently, and the field "
        .. "should be documented as unsupported rather than left logging tex-fail forever.")
    probe.note("STILL OWED (importing creates a texture object, so it is not done here): call it three "
        .. "ways from the console with a real PNG on disk — the player pawn, FindFirstOf('World') and "
        .. "krl itself as the context — and report which one returns a valid UTexture2D.")
    probe.finish()
end

local function mesh_detach_destroycomponent()
    probe.begin("mesh-detach-destroycomponent")

    probe.section("the component class the procedural backend adds")
    local pmc = probe.find("/Script/ProceduralMeshComponent.ProceduralMeshComponent")
    probe.allOf("ProceduralMeshComponent")

    probe.section("K2_DestroyComponent, wherever it is declared in the chain")
    probe.params(pmc, "K2_DestroyComponent")
    local ac = probe.find("/Script/Engine.ActorComponent")
    probe.params(ac, "K2_DestroyComponent")
    probe.params(ac, "DestroyComponent")
    grep(ac, "ActorComponent", "fn", { "destroy", "unregister", "detach" })
    local sc = probe.find("/Script/Engine.SceneComponent")
    grep(sc, "SceneComponent", "fn", { "destroy", "detach" })

    probe.note("HIT: one ObjectProperty parameter means the Blueprint shape (comp:K2_DestroyComponent(comp)) "
        .. "is right and detach can be trusted; NO parameters means we are passing an argument the call "
        .. "does not declare, which is the likeliest reason detach reports true and removes nothing.")
    probe.note("MISS: no destroy function on the chain at all means detach cannot be honest on any backend "
        .. "and must stop clearing its once-guard.")
    probe.note("STILL OWED (adding and destroying components mutates your pawn): the count test — "
        .. "FindAllOf('ProceduralMeshComponent') before, add one, try each call shape, count again — "
        .. "belongs to the F6 pass.")
    probe.finish()
end

local function mesh_base_material()
    probe.begin("mesh-base-material")

    probe.section("the five candidates core/mesh already probes (StaticFindObject only — read-only)")
    local ok = pcall(function()
        for _, r in ipairs(require("palforge.core.mesh").probeMaterials() or {}) do
            probe.line("MATPROBE %s %s", r.found and "FOUND" or "-----", tostring(r.path))
        end
    end)
    if not ok then probe.line("MATPROBE <core.mesh.probeMaterials unavailable>") end

    probe.section("what IS loaded, and which of it carries a colour parameter")
    for _, cn in ipairs({ "Material", "MaterialInstanceConstant", "MaterialInterface" }) do
        local all = listInstances(cn, 40)
        local checked, carrying = math.min(#all, 30), 0
        for i = 1, checked do
            local m = all[i]
            local arr; local okr = pcall(function() arr = m.VectorParameterValues end)
            if okr and arr ~= nil then
                local names = {}
                local n = eachArray(arr, 12, function(_, e)
                    local nm; pcall(function() nm = e.ParameterInfo.Name:ToString() end)
                    names[#names + 1] = tostring(nm)
                end)
                if n and n > 0 then
                    carrying = carrying + 1
                    probe.line("MAT %s -> VectorParameterValues[%s] { %s }",
                        probe.full(m), tostring(n), table.concat(names, ", "))
                end
            end
        end
        probe.line("MAT %s: %d of the first %d carry a non-empty VectorParameterValues", cn, carrying, checked)
    end

    probe.note("HIT: ONE loaded material path with a colour vector parameter goes to the front of "
        .. "Renderer.BASE_MATERIAL_CANDIDATES, and the entire material layer on the one backend that is "
        .. "proven to render comes alive.")
    probe.note("MISS: five MATPROBE '-----' lines and no VectorParameterValues anywhere means no cooked "
        .. "material can parent a MID here, and procedural meshes are permanently white — setColor on "
        .. "them should then be documented as structurally false.")
    probe.finish()
end

--=============================================================================
-- Building
--=============================================================================

local CLICKY = { "damage", "hit", "attack", "take", "receive", "click", "press", "shot" }

local function building_leftclick()
    probe.begin("building-leftclick")

    probe.section("(1) every UFunction on PalBuildObject — unfiltered; the ABSENCE is the finding")
    local cls = probe.find("/Script/Pal.PalBuildObject")
    probe.functions(cls, "PalBuildObject")

    probe.section("(2) a real placed structure and its whole super chain")
    local all = probe.allOf("PalBuildObject")
    local a = all[1]
    local seen, hits = {}, {}
    if cls then seen[probe.full(cls)] = true end   -- already dumped whole, just above
    if probe.valid(a) then
        probe.line("LIVE   first = %s <%s>", probe.full(a), classFull(a))
        walkChain(classOf(a), "placed", CLICKY, seen, 10, hits)
    else
        probe.note("no placed PalBuildObject in the world — the base class list above still stands, but "
            .. "the BP_BuildObject_<Id>_C half is missing; place a Workbench and re-run")
    end

    probe.section("(3) parameters of every strike-ish name, base class included")
    local baseHits = grep(cls, "PalBuildObject", "fn", CLICKY)
    paramsFor(cls, baseHits, 8)
    paramsForHits(hits, { "click", "press", "hit", "attack" }, 8)

    probe.note("HIT: one function that runs when the player strikes a structure makes onLeftClick "
        .. "wireable with three lines — a channel name, a tryHook in installBuildingSource and an M.on "
        .. "in installDispatch. Nothing in api/building has to change.")
    probe.note("MISS: a complete function list with no click or strike path is the answer too — "
        .. "events.onLeftClick then has no native source and should be documented as manual-only "
        .. "(Handle:onLeftClick) rather than left looking live.")
    probe.note("STILL OWED (hooks are F7, and this probe arms none): RegisterHook each candidate above, "
        .. "melee a placed Workbench, and paste which fired.")
    probe.finish()
end

local function building_break()
    probe.begin("building-break")

    -- PalNetworkPlayerComponent and PalPlayerRecordData are the two PROVEN owners of the build
    -- lifecycle (RequestBuild_ToServer, OnCompleteBuild_ServerInternal), so a destroy counterpart
    -- is likeliest to sit beside them. The needle list is deliberately wide — it keeps 'build'
    -- and 'complete' in, so the known pair prints and confirms the enumeration really worked.
    local DESTROY = { "destroy", "dismantl", "deconstruct", "demolish", "remove", "break", "repair",
                      "build", "complete" }
    for _, p in ipairs({ "/Script/Pal.PalBuildObject", "/Script/Pal.PalNetworkPlayerComponent",
                         "/Script/Pal.PalPlayerRecordData", "/Script/Pal.PalMapObjectConcreteModelBase" }) do
        probe.section(p)
        local c = probe.find(p)
        local hits = grep(c, p, "fn", DESTROY)
        paramsFor(c, hits, 8)
    end

    probe.note("HIT: the key question is what PARAM 1 is — a build ACTOR, a UPalMapObjectModel (as "
        .. "OnCompleteBuild_ServerInternal takes) or an FName build id. That decides instance- vs "
        .. "class-dispatch for onBreak, and it is visible in the PARAM lines above without hooking "
        .. "anything.")
    probe.note("MISS: four classes with no destroy counterpart confirms dump_targets.md's position that "
        .. "destruction is only observable through the scan miss sweep, and onRemove's reason can never "
        .. "be better than 'missing'.")
    probe.note("STILL OWED (F7, and note the recorded native access violation for this hook class during "
        .. "the world-load storm): in a THROWAWAY world, RegisterHook the best candidate, dismantle one "
        .. "Workbench, paste the log.")
    probe.finish()
end

local function building_break_source()
    probe.begin("building-break-source")

    local cls = probe.find("/Script/Pal.PalBuildObject")

    probe.section("(1a) OnDamage — the one destruction-adjacent hook ever seen to fire (label BUILD.damage)")
    probe.params(cls, "OnDamage")
    grep(cls, "PalBuildObject", "fn", { "damage", "destroy", "break", "dead", "die", "hp", "health" })
    probe.note("the COMPLETE PalBuildObject function list is dumped once, under building-leftclick")

    probe.section("(1b) every property on PalBuildObject — does it expose HP to read at all")
    probe.properties(cls, "PalBuildObject")

    probe.note("HIT: an HP-ish property plus OnDamage's parameter list tells us whether one hook can "
        .. "serve both building.break (HP reaching zero) and a damage channel — that is a building.break "
        .. "channel plus an honest reason='dismantled' on onRemove.")
    probe.note("MISS: no HP property and a parameterless OnDamage means damage cannot be told from "
        .. "destruction from our side, and onBreak stays blocked on building-break's search instead.")
    probe.note("STILL OWED (F7): hook OnDamage, then (a) hit a wooden wall once, (b) destroy it, "
        .. "(c) dismantle another from the build menu — with a marker line before each.")
    probe.finish()
end

--=============================================================================
-- Skill and Effect
--=============================================================================

local function skill_activate_source()
    probe.begin("skill-activate-source")

    -- PalPlayerController:PlaySkill is already RULED OUT: armed in the v4 and v6 probes and
    -- fired 0 times. What is wanted here is a NAME nobody has proposed yet.
    local NEEDLES = { "waza", "skill", "action", "activate", "execute", "fire", "shot", "attack" }
    local seen, hits = {}, {}

    probe.section("STEP 1 — the eight classes, existence first (the existence answers are load-bearing)")
    for _, n in ipairs({ "PalCharacter", "PalPlayerCharacter", "PalPlayerController", "PalActionComponent",
                         "PalCombatComponent", "PalWazaBase", "PalSkillBase", "PalActionBase" }) do
        local c = probe.find("/Script/Pal." .. n)
        if c then walkChain(c, n, NEEDLES, seen, 8, hits) end
    end

    probe.section("STEP 1b — the live Blueprint subclass, which StaticFindObject cannot reach")
    local pc = probe.firstOf("PalPlayerCharacter")
    if pc then
        probe.line("LIVE   class = %s", classFull(pc))
        walkChain(classOf(pc), "live PalPlayerCharacter", NEEDLES, seen, 10, hits)
    end

    probe.section("STEP 2 — signatures: a NameProperty or a struct is what would carry the skill id")
    paramsForHits(hits, { "waza", "activate", "execute", "playskill" }, 12)

    probe.note("HIT: any function carrying a waza/skill FName is the skill.activate source — one channel "
        .. "in core/event M.CHANNELS plus a dispatch, and every pack's onActivate stops being manual-only.")
    probe.note("MISS: eight classes, the BP chain and no id-carrying candidate means onActivate has no "
        .. "game-driven source on this build and native/skills.lua's Fireball stays a manual call.")
    probe.note("STILL OWED (F7): arm the top candidates, then have a Pal use a move and the player use a "
        .. "partner skill; paste which fired, how many times, and every parameter value.")
    probe.finish()
end

local function skill_passive_source()
    probe.begin("skill-passive-source")

    local hits = {}

    probe.section("STEP 1 — the live pal's own chain (passive/skill names only; add/set/remove alone is "
        .. "too broad to print on a 12-level chain)")
    local pal = probe.firstOf("PalCharacter")
    local seen = {}
    if pal then
        probe.line("LIVE   class = %s", classFull(pal))
        walkChain(classOf(pal), "live PalCharacter", { "passive", "waza", "skill", "learn", "equip" }, seen, 10, hits)
    else
        probe.note("no live PalCharacter — deploy a pal and re-run for the Blueprint half")
    end

    probe.section("STEP 1b — the candidate holders; whether each EXISTS is itself load-bearing")
    local FULL = { "passive", "skill", "waza", "add", "remove", "set", "array" }
    for _, n in ipairs({ "PalIndividualCharacterParameter", "PalCharacterParameterComponent",
                         "PalIndividualCharacterHandle", "PalPassiveSkillComponent", "PalCharacterContainer" }) do
        local c = probe.find("/Script/Pal." .. n)
        if c and not seen[probe.full(c)] then
            seen[probe.full(c)] = true
            local hf = grep(c, n, "fn", FULL)
            grep(c, n, "prop", FULL)
            for _, e in ipairs(hf) do hits[#hits + 1] = { cls = c, name = e.name, which = "fn" } end
        end
    end

    probe.section("STEP 2 — signatures: is the argument a passive row FName, or an index into a fixed array")
    paramsForHits(hits, { "passive" }, 12)

    probe.note("HIT: an attach/detach pair means Handle:equip can really attach the passive instead of "
        .. "only running the pack's handler, and a skill.equip / skill.unequip source becomes possible.")
    probe.note("MISS: no Passive function anywhere — and especially no PalPassiveSkillComponent class at "
        .. "all — means kind=\"passive\" is PalForge-side bookkeeping only, permanently.")
    probe.note("STILL OWED (F7): arm every Add*/Remove* found, then capture a Pal, use the passive-skill "
        .. "bench, and pull a Pal in and out of the party.")
    probe.finish()
end

local function effect_native_status()
    probe.begin("effect-native-status")

    local NAMES = { "PalStatusEffectComponent", "PalBadStatusComponent", "PalCharacterParameterComponent",
                    "PalIndividualCharacterParameter", "PalCharacter", "PalPlayerCharacter",
                    "PalStatusUtility", "PalDamageUtility" }

    probe.section("STEP 1 — which of these classes exist here (the existence answers alone are the news)")
    local classes = {}
    for _, n in ipairs(NAMES) do classes[n] = probe.find("/Script/Pal." .. n) end

    probe.section("STEP 2 — enumerate, status names only")
    local NEEDLES = { "status", "ailment", "effect", "buff", "debuff" }
    local seen, hits = {}, {}
    for _, n in ipairs(NAMES) do
        if classes[n] then walkChain(classes[n], n, NEEDLES, seen, 8, hits) end
    end
    local pc = probe.firstOf("PalPlayerCharacter")
    if pc then
        probe.line("LIVE   class = %s", classFull(pc))
        walkChain(classOf(pc), "live PalPlayerCharacter", NEEDLES, seen, 10, hits)
    end

    probe.section("STEP 3 — signatures: a Byte/EnumProperty means the enum form, a NameProperty the FName form")
    paramsForHits(hits, { "add", "remove", "apply", "set", "clear", "attach" }, 12)

    probe.section("STEP 4 — the enum members themselves, never captured in any dump")
    for _, e in ipairs({ "EPalStatusEffectType", "EPalBadStatusType", "EPalStatusType" }) do
        dumpEnum(probe.find("/Script/Pal." .. e), e, 63)
    end

    probe.note("HIT: an add/remove pair plus the enum member names IS Effect.Spec.nativeStatus — those "
        .. "printed member names are literally the values the field must hold, and native/effects.lua's "
        .. "empty Poison / Burn / Freeze bodies can be filled the same day.")
    probe.note("MISS: eight 'absent' lines and no enum means the game's own ailments are unreachable from "
        .. "Lua, and nativeStatus must be removed rather than left validated-and-ignored.")
    probe.note("STILL OWED (F7): arm the shortlisted add/remove functions and deliberately catch each "
        .. "ailment (stand in fire, take poison, freeze, get wet, get electrified) — the parameter value "
        .. "printed per ailment is the mapping.")
    probe.finish()
end

--=============================================================================
-- UI
--=============================================================================

local function ui_host_paths()
    probe.begin("ui-host-paths")

    -- The ROOT classes are already known from deprecated/catalog/ui_widget_classes.txt; what is
    -- missing is one level down. A node whose children= prints a NUMBER answered
    -- GetChildrenCount, which is the cheap read-only proxy for "is a UPanelWidget"; a '-' is a
    -- leaf that raised, i.e. definitely not an injection host.
    for _, n in ipairs({ "PalUIHUDLayoutBase", "PalUIWorldHUDWidgetCanvas",
                         "PalUIInsideBaseCampCanvas", "PalUIInventoryEquipment" }) do
        probe.section(n)
        local r = probe.firstOf(n)
        if probe.valid(r) then
            local budget = { n = 150 }
            local root
            pcall(function()
                local t = r.WidgetTree
                if probe.valid(t) then root = t.RootWidget end
            end)
            if probe.valid(root) then
                walkWidget(root, 0, budget)
            else
                probe.line("WIDGET %s -> no WidgetTree.RootWidget; walking the widget itself", n)
                walkWidget(r, 0, budget)
            end
            -- Say so rather than let a truncated tree look like a complete one.
            if budget.n <= 0 then probe.line("WIDGET ... (150-node budget exhausted; this tree is deeper)") end
        end
    end

    probe.section("every live UserWidget, once — open the Inventory and the Build menu before pressing the key")
    local seen, shown = {}, 0
    for _, w in ipairs(probe.allOf("UserWidget")) do
        local key = probe.full(w)
        if not seen[key] then
            seen[key] = true
            shown = shown + 1
            if shown <= 150 then probe.line("WIDGET %s <%s> %s", probe.name(w), classFull(w), key) end
        end
    end
    if shown > 150 then probe.line("WIDGET ... (%d more unique)", shown - 150) end

    probe.note("HIT: any named child with a numeric children= inside the HUD tree is a candidate host — "
        .. "its name goes into native/ui/_widget M.PATHS and PalForge panels can finally be parented "
        .. "into the game's OWN screens instead of a separate viewport layer.")
    probe.note("MISS: a tree of '-' everywhere means no panel is reachable one level down and the "
        .. "viewport layer (widget.screen) stays the only host — which is a documentable answer.")
    probe.note("STILL OWED (adding a widget to the live HUD is a state change, so it is not done here): "
        .. "for each numeric-children node, construct a throwaway TextBlock, AddChild it, print the slot "
        .. "class, RemoveChild it. That confirms AddChild really answers.")
    probe.finish()
end

local function ui_update_event()
    probe.begin("ui-update-event")

    local NEEDLES = { "open", "show", "construct", "refresh", "update", "setup", "close", "hide" }
    for _, n in ipairs({ "PalUIManagerSubsystem", "PalUIHUDLayoutBase", "PalUITitleBase",
                         "PalUIInventoryEquipment" }) do
        probe.section(n)
        local cls = probe.find("/Script/Pal." .. n)
        local cdo = probe.find("/Script/Pal.Default__" .. n)
        local k = cls or (cdo and classOf(cdo))
        local hits = grep(k, n, "fn", NEEDLES)
        paramsFor(k, hits, 6)
    end

    probe.note("HIT: one hookable Open/Show/Construct function is a ui.* channel in core/event, so "
        .. "UI.Handle:autoRefresh stops being the only driver and TitleMenu can re-inject on the rebuild "
        .. "signal instead of on a 2 s timer.")
    probe.note("MISS: no such function on any of the four means polling is not a shortcut but the only "
        .. "mechanism available, and autoRefresh should be documented as such.")
    probe.note("STILL OWED (F7): RegisterHook every name above, then open and close the inventory, open "
        .. "the build menu and return to the title screen; paste which paths fired and in what order.")
    probe.finish()
end

--=============================================================================
-- run
--=============================================================================

-- Every section, in plan/TODO.md order. Each one is pcall-guarded in M.run so a section that
-- raises (a stale pointer, a class that answers strangely) cannot cost the other twenty-four
-- their block.
local SECTIONS = {
    { "audio-akevent-play-signature",   audio_akevent_play_signature },
    { "audio-volume-rtpc",              audio_volume_rtpc },
    { "audio-custom-file-loader",       audio_custom_file_loader },
    { "item-remove-call",               item_remove_call },
    { "item-inventory-count-readback",  item_inventory_count_readback },
    { "item-datatable-row-read",        item_datatable_row_read },
    { "icons-row-read",                 icons_row_read },
    { "icons-row-column",               icons_row_column },
    { "pal-icon-row",                   pal_icon_row },
    { "skill-icon-key",                 skill_icon_key },
    { "spawn-actor-conventions",        spawn_actor_conventions },
    { "spatial-saveid",                 spatial_saveid },
    { "mesh-static-setstaticmesh",      mesh_static_setstaticmesh },
    { "mesh-texture-import",            mesh_texture_import },
    { "mesh-detach-destroycomponent",   mesh_detach_destroycomponent },
    { "mesh-base-material",             mesh_base_material },
    { "building-leftclick",             building_leftclick },
    { "building-break",                 building_break },
    { "building-break-source",          building_break_source },
    { "skill-activate-source",          skill_activate_source },
    { "skill-passive-source",           skill_passive_source },
    { "effect-native-status",           effect_native_status },
    { "pal-skills-equip",               pal_skills_equip },
    { "ui-host-paths",                  ui_host_paths },
    { "ui-update-event",                ui_update_event },
}

---Run every section. Returns the number that ran.
---@return integer
function M.run()
    -- Every section reads live objects (FindAllOf / FindFirstOf / a live inventory). At the
    -- title screen they would all print nils, which is indistinguishable from a real absence —
    -- and a false "absent" here would close a plan item wrongly. So: refuse, and say why.
    if not support.player() then
        probe.line("#### reflect.lua NOT RUN — no world")
        probe.note("load a save first, then press the key again. Every section here reads LIVE objects, "
            .. "so at the title screen it would print a run of nils that looks exactly like a genuine "
            .. "'this build does not have it' — the one answer this probe must never fake.")
        return 0
    end

    probe.line("#### reflect.lua — %d section(s), read-only (nothing below writes, spawns, plays or hooks)", #SECTIONS)
    support.announce("probe: reflect (" .. #SECTIONS .. " sections) -> UE4SS.log")

    local ran = 0
    for _, s in ipairs(SECTIONS) do
        local ok, err = pcall(s[2])
        if ok then
            ran = ran + 1
        else
            -- The block may have been left open by the raise; close it so the log stays greppable.
            probe.line("#### SECTION %s RAISED: %s", s[1], tostring(err))
            probe.finish()
        end
    end

    probe.line("#### reflect.lua done — %d/%d section(s) ran", ran, #SECTIONS)
    support.announce("probe: reflect done (" .. ran .. "/" .. #SECTIONS .. ")")
    return ran
end

return M
