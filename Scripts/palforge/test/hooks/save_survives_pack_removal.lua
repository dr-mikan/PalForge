-- test/hooks/save-survives-pack-removal — THE QUESTION THAT STARTED THE WHOLE STORE PASS.
--
-- "If I remove the mod, does my world still load?"
--
-- HALF OF THAT IS ALREADY ANSWERED, AND THE ANSWER IS YES, AND IT IS NOT THE INTERESTING HALF.
-- PalForge's own state is a JSON SIDECAR under <Mods>/PalForge/state/. It has never written
-- into Palworld's .sav — grep the tree for SaveGame, RequestSave, WriteSave or .sav and there
-- is nothing under Scripts/palforge to find. Delete the mod folder and the sidecar goes with
-- it; the game's save is exactly as it was. state/README.txt says so where a player will see
-- it, and every store hook in this directory ends by saying it again.
--
-- THE HALF THAT IS REAL IS THE OPPOSITE SHAPE, and it is what this hook is about: WHAT PALFORGE
-- ASKS THE GAME TO WRITE. Three calls do that, and each one puts a NAME into Palworld's own
-- save:
--
--   Item.Handle:give      -> a StaticItemId in an inventory container (FPalWorldSaveData
--                            .ItemContainerSaveData, Pal.hpp:7927)
--   Building.Handle:unlock-> a row appended to the player's unlocked-technology list
--   Skill.Handle:teach    -> a passive FName on a pal's individual parameters
--
-- When the id is a pack's own — `mypack_Potion` — that row exists in DT_ItemDataTable ONLY
-- because PalSchema injected it at load. Remove the pack and the save is holding a name with no
-- row behind it. That is the actual removal risk, it has nothing to do with PalForge's sidecar,
-- and the ledger this pass added is the only thing in the tree that can name those ids one by
-- one, per save, per pack, AFTER the pack is gone.
--
-- WHY THIS IS EMPIRICAL OR IT IS NOTHING. Everything readable off the shipping binary says that
-- shape is a MISSING LOOKUP rather than a broken file — the save stores plain FNames, rows are
-- resolved through accessors built to fail (UPalItemDataTable::TryGetStaticItemData returns a
-- bool; the whole BP_FindRow(row, bool& outValid) family does the same), and EPalSaveError
-- declares { Success, NotFound, Unknown, Broken, OutOfMemory } with no "unknown content"
-- member. But the LOAD PATH ITSELF IS UNREFLECTED C++ (FPalBinaryMemory and friends), so there
-- is nothing to hand core/signature.describe and no UFunction to hook. No amount of reading
-- settles it. Somebody has to remove a pack and press Load, and nobody ever has.
--
-- THE PROTOCOL — TWO LAUNCHES, AND A SAVE YOU DO NOT MIND LOSING:
--
--   1. In a throwaway save, with a pack installed whose item you are carrying:
--          pf_hook save-survives-pack-removal          <- run 1, the BEFORE snapshot
--      It records every ledgered id, whether each still has a DataTable row, and how many of
--      each you are holding.
--   2. QUIT THE GAME. Remove that pack's mod folder — both halves if it has two, the PalSchema
--      JSON that injects the rows and the PalForge Lua that defines them.
--   3. Relaunch. LOAD THE SAME SAVE. Whether it loads at all is the headline result and you
--      will know it before this hook runs.
--   4. pf_hook save-survives-pack-removal              <- run 2, the AFTER comparison
--
-- ⚠️ writes = true, and the write is the OPERATOR'S, not this hook's. Nothing here calls give,
-- unlock or teach; it reads a ledger, reads an inventory, and stores its own snapshot under the
-- pack id `pf_probe` (the same file store-save-roundtrip uses — one file to delete, and this
-- hook only ever touches the key "removal" inside it). The opt-in exists because step 2 asks
-- you to uninstall a mod and reload a save that has that mod's ids written into it, and that is
-- a per-experiment decision taken on a throwaway save — which is exactly what the `writes` gate
-- is for.
local hooks = require("palforge.test.hooks")

local PROBE = "pf_probe"

-- DT_ItemDataTable's object path. The package directory is proven — dumps/reflection/
-- 01_datatables.txt printed every loaded table with its package — and dt:GetRowNames() is the
-- accessor core/icons.lua already uses in a real save (UE4SS binds it onto UDataTable itself,
-- which is why every reflection sweep of the class shows zero functions). What is NOT used here
-- is dt:FindRow's returned struct: whether a scalar column can be indexed off it is still open
-- (item-datatable-row-read), and a row NAME is the whole question anyway.
local ITEM_DT = "/Game/Pal/DataTable/Item/DT_ItemDataTable.DT_ItemDataTable"

local function rowNameSet()
    if type(StaticFindObject) ~= "function" then return nil, "no StaticFindObject this session" end
    local ok, dt = pcall(StaticFindObject, ITEM_DT)
    if not (ok and dt and dt:IsValid()) then
        return nil, "DT_ItemDataTable is not loaded (" .. ITEM_DT .. ")"
    end
    local okN, names = pcall(function() return dt:GetRowNames() end)
    if not (okN and type(names) == "table") then
        return nil, "GetRowNames did not answer on this build"
    end
    local set, n = {}, 0
    for _, nm in ipairs(names) do
        local s = tostring(nm)
        -- The elements arrive wrapped in RemoteUnrealParam on some routes; :get() unwraps.
        if type(nm) == "userdata" then
            local okG, v = pcall(function() return nm:get() end)
            if okG and v ~= nil then s = tostring(v) end
        end
        set[s] = true
        n = n + 1
    end
    return set, nil, n
end

local function ageWords(sec)
    if type(sec) ~= "number" then return "an unrecorded time" end
    if sec < 90 then return string.format("%d seconds", sec) end
    if sec < 5400 then return string.format("%d minutes", math.floor(sec / 60)) end
    if sec < 172800 then return string.format("%.1f hours", sec / 3600) end
    return string.format("%.1f days", sec / 86400)
end

hooks.declare{
    id     = "save-survives-pack-removal",
    item   = "Implemented, never exercised by a game",
    needs  = { world = true, player = true },
    writes = true,
    desc   = "name every id PalForge made THIS save record, then — after you uninstall the pack "
          .. "and reload — say what became of each. The only thing that answers the question "
          .. "the store pass was started for",
    run = function(h)
        local state = require("palforge.core.state")
        local items = require("palforge.utils.items")
        local om    = require("palforge.core.object_manager")

        --------------------------------------------------------------------
        h:section("[1] the two halves of the question, and which one is real")
        --------------------------------------------------------------------
        h:value("this save", state.saveDir())
        h:value("PalForge's own state lives in", tostring(state.storeFor(PROBE, "hook").path()
            :match("^(.*[\\/])") or "?"))
        h:pass("HALF ONE IS SETTLED BY CONSTRUCTION AND NEEDS NO RUN: PalForge writes a JSON "
            .. "sidecar under <Mods>/PalForge/state/ and has never written into Palworld's "
            .. ".sav. Delete the mod folder and the sidecar goes with it; the game's save is "
            .. "untouched and loads. That is a property of where the bytes go, not of anything "
            .. "measured here.")
        h:note("HALF TWO IS THE ONE THIS HOOK EXISTS FOR: what PalForge asked the GAME to "
            .. "record. Item:give writes a StaticItemId into an inventory container, "
            .. "Building:unlock appends to the unlocked-technology list, Skill:teach appends a "
            .. "passive FName to a pal. When those names came from a pack, the DataTable row "
            .. "behind them exists only because PalSchema injected it — so removing the pack "
            .. "leaves the save holding a name with nothing behind it.")
        h:note("EVERY STRUCTURAL SIGN SAYS THAT IS A MISSING LOOKUP AND NOT A BROKEN FILE: the "
            .. "save stores plain FNames, rows resolve through accessors built to fail "
            .. "(TryGetStaticItemData -> bool, the BP_FindRow(row, bool&) family), and "
            .. "EPalSaveError has no 'unknown content' member. NONE OF THAT IS PROOF. The load "
            .. "path is unreflected C++ (FPalBinaryMemory) — there is nothing to "
            .. "signature.describe and no UFunction to hook — so this is empirical or it is "
            .. "nothing, and nobody has yet loaded a save whose pack was gone.")

        --------------------------------------------------------------------
        h:section("[2] what PalForge has made THIS save record")
        --------------------------------------------------------------------
        local audit = state.audit()
        local rows, byKind = {}, {}
        for _, st in ipairs(audit.packs) do
            if st.pack ~= PROBE then
                local db  = state.storeFor(st.pack)
                local led = db.ledger() or {}
                for _, kind in ipairs({ "item", "tech", "passive", "pal" }) do
                    for id, e in pairs(led[kind] or {}) do
                        rows[#rows + 1] = { pack = st.pack, kind = kind, id = id,
                                            n = tonumber(e.n) or 0, at = e.at }
                        byKind[kind] = (byKind[kind] or 0) + 1
                    end
                end
            end
        end
        table.sort(rows, function(a, b)
            if a.pack ~= b.pack then return a.pack < b.pack end
            if a.kind ~= b.kind then return a.kind < b.kind end
            return a.id < b.id
        end)
        h:value("packs with a state file for this save", #audit.packs)
        h:value("ledgered ids", #rows)
        h:value("  of kind item / tech / passive / pal", string.format("%d / %d / %d / %d",
            byKind.item or 0, byKind.tech or 0, byKind.passive or 0, byKind.pal or 0))

        if #rows == 0 then
            h:note("NOTHING IS LEDGERED FOR THIS SAVE, so there is nothing here that could "
                .. "outlive a pack. That is the ordinary state of a save where no pack has "
                .. "called give / unlock / teach with an id of its own — and it is also why "
                .. "this hook's own answer is 'not yet': the experiment needs a pack that has "
                .. "actually written a name into this save.")
            h:note("TO SET IT UP: install a pack that ships its own item (a PalSchema JSON row "
                .. "plus a PalForge definition), take one with Item.get('mypack:Potion'):give(1) "
                .. "or by crafting it, and run this hook again. The ledger records only ids "
                .. "whose row a pack put there — a vanilla give writes nothing here, because a "
                .. "vanilla row cannot stop existing.")
        end

        --------------------------------------------------------------------
        h:section("[3] does each of those ids still have a row, and is it in your bag")
        --------------------------------------------------------------------
        local set, why, nRows = rowNameSet()
        h:value("DT_ItemDataTable rows readable", set and (nRows .. " rows") or ("NO — " .. tostring(why)))
        if not set then
            h:warn("without the row list this hook cannot tell 'the pack is gone' from 'the "
                .. "table is not loaded yet'. It is loaded lazily; open your inventory or a "
                .. "crafting bench once and run this again.")
        end

        local snapshot = { at = os.time(), save = state.saveDir(), ids = {} }
        for _, r in ipairs(rows) do
            local hasRow = set and (set[r.id] == true) or nil
            local count  = nil
            if r.kind == "item" then
                local okC, c = pcall(items.count, r.id)
                count = okC and tonumber(c) or nil
            end
            local owner = nil
            local okO, o = pcall(om.owner, r.kind == "item" and "item" or "building", r.id)
            if okO and type(o) == "string" then owner = o end
            h:log("  %-14s %-8s %-32s row=%-7s bag=%-6s recorded=%d  owner=%s",
                r.pack, r.kind, r.id,
                hasRow == nil and "?" or (hasRow and "YES" or "GONE"),
                count == nil and "-" or tostring(count), r.n, tostring(owner))
            snapshot.ids[r.id] = { pack = r.pack, kind = r.kind, n = r.n,
                                   hasRow = hasRow, count = count }
        end

        --------------------------------------------------------------------
        h:section("[4] BEFORE and AFTER")
        --------------------------------------------------------------------
        local db   = state.storeFor(PROBE, "hook")
        local prev = db.get("removal")
        if type(prev) ~= "table" or type(prev.ids) ~= "table" then
            h:note("THIS IS RUN 1 — the BEFORE snapshot. It has just been written; nothing is "
                .. "compared yet.")
            h:ask("now: QUIT THE GAME, remove that pack's mod folder (BOTH halves — the "
                .. "PalSchema JSON that injects the rows and the PalForge Lua that defines "
                .. "them), relaunch, load THIS SAVE, and run `pf_hook "
                .. "save-survives-pack-removal` again.")
            h:note("⚠️ USE A SAVE YOU DO NOT MIND LOSING. The whole experiment is 'what happens "
                .. "to a save that references content which is no longer installed', and the "
                .. "honest answer to 'is that safe' is that nobody knows yet — which is why "
                .. "this hook needs an opt-in and says this sentence.")
        else
            local age = os.time() - (tonumber(prev.at) or os.time())
            h:value("the previous snapshot was taken", ageWords(age) .. " ago")
            h:value("it named", tostring(prev.save))
            if prev.save ~= state.saveDir() then
                h:warn("the previous snapshot was taken in save %q and this is %q, so the "
                    .. "comparison below is between two different worlds and means nothing. "
                    .. "Run this in the save the snapshot came from.", tostring(prev.save),
                    state.saveDir())
            end

            -- THE HEADLINE RESULT, and it needed no measurement beyond arriving here.
            h:pass("THIS SAVE LOADED. Whatever changed between the two runs, Palworld opened "
                .. "the world, spawned a player pawn and ran to the point where a Lua hook "
                .. "could ask it questions. If a pack was removed in between, that is the "
                .. "first observation anyone has of a Palworld save loading while it holds ids "
                .. "whose DataTable rows are gone.")

            local lost, kept, vanished = 0, 0, 0
            for id, was in pairs(prev.ids) do
                local nowRow = set and (set[id] == true) or nil
                local nowCount = nil
                if was.kind == "item" then
                    local okC, c = pcall(items.count, id)
                    nowCount = okC and tonumber(c) or nil
                end
                local rowWord = (was.hasRow == nil or nowRow == nil) and "?"
                    or (was.hasRow and not nowRow) and "ROW REMOVED"
                    or (not was.hasRow and nowRow) and "row appeared"
                    or (nowRow and "row still there" or "row absent both times")
                if was.hasRow and nowRow == false then lost = lost + 1
                elseif nowRow == true then kept = kept + 1 end
                local bagWord = (was.count == nil or nowCount == nil) and "?"
                    or (nowCount == was.count) and string.format("still %d", nowCount)
                    or string.format("%d -> %d", was.count, nowCount)
                if was.count and nowCount == 0 and was.count > 0 then vanished = vanished + 1 end
                h:log("  %-32s %-18s  bag: %s", id, rowWord, bagWord)
            end
            h:value("ids whose row is now GONE", lost)
            h:value("ids whose row is still there", kept)
            h:value("item ids whose count dropped to zero", vanished)

            if lost == 0 then
                h:note("NO ROW DISAPPEARED between the two runs, so the pack was still "
                    .. "installed and this run is a CONTROL rather than the experiment. It is "
                    .. "worth having — it says the snapshot survives a reload unchanged — but "
                    .. "the question is still open. Remove the pack and run it a third time.")
            elseif vanished == 0 then
                h:pass("⚠️ THE ANSWER, AND IT IS THE GOOD ONE: %d id(s) lost their DataTable "
                    .. "row, the save still loaded, and the item slots are still reported by "
                    .. "the inventory. A missing row behaves as a MISSING LOOKUP, exactly as "
                    .. "the accessors' shape suggested — the save is not corrupt, it is "
                    .. "holding a name the game cannot resolve. Write this into "
                    .. "plan/TODO.md verbatim; it is the sentence the removal contract has "
                    .. "been carrying as an inference.", lost)
                h:note("what this does NOT establish: how the item renders, whether it is "
                    .. "usable, and whether a stack of it can be moved. 'The save loads' is the "
                    .. "question that was asked and it is the one that is answered.")
            else
                h:fail("%d id(s) lost their row and %d item id(s) now count ZERO where they "
                    .. "counted more before. The save loaded, but the items are gone from the "
                    .. "bag — so removing a pack COSTS THE PLAYER THE ITEMS, and the removal "
                    .. "contract in plan/TODO.md needs that sentence added to it in exactly "
                    .. "these words.", lost, vanished)
            end
        end

        local okSet, whySet = db.set("removal", snapshot)
        if not okSet then
            h:fail("the snapshot could not be stored: %s", tostring(whySet))
        else
            local okSave, saveErr = db.save()
            h:value("snapshot stored", tostring(okSave) ..
                (saveErr and (" (" .. tostring(saveErr) .. ")") or ""))
        end

        --------------------------------------------------------------------
        h:section("[5] what can be taken back, and what never can")
        --------------------------------------------------------------------
        for _, st in ipairs(audit.packs) do
            if st.pack ~= PROBE then
                local rep = state.storeFor(st.pack).reclaim()
                h:log("  %s", rep.text)
                for _, row in ipairs(rep.unreclaimable) do
                    h:log("      CANNOT BE UNDONE: %s %s — %s", row.kind, row.id, row.limit)
                end
            end
        end
        h:note("A TECHNOLOGY UNLOCK CAN NEVER BE UNDONE ON THIS BUILD, and that is a read rather "
            .. "than a guess: UPalCheatManager declares four unlock entries and no lock, and "
            .. "LockTechnology / RemoveTechnology / ResetTechnology / ForgetTechnology have "
            .. "ZERO hits across all 1579 headers in dumps/cxx/. Building.Handle:unlock is "
            .. "one-way, and the ledger's job for that kind is to NAME it rather than to fix it.")
        h:note("this hook stored its snapshot under the pack id %q, the same file "
            .. "store-save-roundtrip uses, under the key \"removal\". Remove it with "
            .. "require('palforge.core.state').uninstall('%s') when you are done — and note "
            .. "that doing so also discards the BEFORE snapshot, so do it after run 2 and not "
            .. "between the two.", PROBE, PROBE)
    end,
}
