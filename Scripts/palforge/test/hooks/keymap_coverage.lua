-- test/hooks/keymap-key-coverage — THE HALF OF THE KEYMAP GUARD THAT ONLY A GAME CAN RUN.
--
-- plan/TODO.md Owed work §3, second bullet: *"`test/cases/ui.lua`'s keymap-coverage case still
-- has an in-game-only half … the COVERAGE assertion against UE4SS's live `Key` table can only
-- run in a game."* That case (test/cases/ui.lua:1506) asserts everything decidable from the
-- table alone — populated, no blank or duplicate rows, `translate()` agreeing with every row,
-- and the seventeen names this tree binds or refuses by name each having one — and then reaches
-- `t:skipUnanswerable` because there is no `Key` table outside UE4SS. This hook is what it skips.
--
-- WHY THE MISSING HALF IS THE ONE THAT MATTERS. `keymap.M.FKEY` is the translation between the
-- TWO NAMESPACES — UE4SS binds by Microsoft virtual-key name ("INS", "SPACE", "NUM_ZERO",
-- "OEM_COMMA") and Unreal names the same keys "Insert", "SpaceBar", "NumPadZero", "Comma" — and
-- everything that answers "is this key free?" goes through it. A name UE4SS will happily bind
-- that FKEY has never heard of is not answered "unknown": until `M.lookup` learned to take the
-- UNION it was MISSING FROM THE REPORT ENTIRELY, which is the silent-skip failure this whole
-- directory exists to refuse, one layer down. The drift can only appear when UE4SS's table
-- changes, and only a running UE4SS has that table.
--
-- ⚠️ AND "FREE" IS STILL NOT "THE PRESS ARRIVES". This hook measures NAME COVERAGE — whether the
-- two tables describe the same set of keys — and nothing else. Whether Palworld has an action on
-- a key is `pf_keys` (keymap.lookup, which needs a loaded world for the config), and whether a
-- bound key's press ever reaches Lua is a third question that cost this tree a whole session on
-- F7, Palworld's own volume key. Three different questions; this one is the cheapest and the
-- only one that is answerable at the title screen.
--
-- THE COUNT IS 165. Counted on 2026-08-02 out of RE-UE4SS's shipped key.md, and `M.FKEY` has 165
-- rows that match it in both directions — so the expected result of this hook TODAY is two empty
-- drift lists, and the day either is not empty is the day it was worth declaring. Two comments in
-- keymap.lua used to say 156; that number came from nowhere and is corrected in both places.
--
-- NO `needs`, DELIBERATELY. `Key` is a UE4SS global, not a world subsystem: it is there at the
-- title screen and it is there during a load. This is the only hook in the directory that runs
-- in any session state at all, which also makes it the cheapest thing to put in autorun.txt.
--
-- Read-only in the strongest sense available: it reads two Lua tables and calls
-- `keymap.translate`, which is pure. It touches no engine object, no config, no key binding and
-- no file.
local hooks = require("palforge.test.hooks")

-- What RE-UE4SS's key.md documents for this generation, and what keymap.lua's header claims to
-- match. A live count that differs from this is not automatically a defect — UE4SS grows keys —
-- but it is the fact that makes every drift below attributable to a version rather than a typo.
local DOCUMENTED_KEY_NAMES = 165

local function countPairs(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

hooks.declare{
    id    = "keymap-key-coverage",
    item  = "Owed work §3 (test blind spots that remain)",
    desc  = "cross keymap.FKEY against UE4SS's live Key table, one row per name, and name every "
         .. "drift in both directions — the half test/cases/ui.lua has to skip",
    run = function(h)
        local keymap    = require("palforge.core.keyboard.base.keymap")
        local registory = require("palforge.core.keyboard.base.registory")

        --------------------------------------------------------------------
        h:section("[1] is UE4SS's Key table reachable at all")
        --------------------------------------------------------------------
        h:value("type(Key)", type(Key))
        local live = {}
        local liveN = 0
        if type(Key) == "table" then
            -- A pcall as well as the type test, and both for a reason registory already hit:
            -- `Key` is userdata rather than a table on some builds, and pairs() over userdata
            -- with no __pairs RAISES. A report that raises is a report nobody gets.
            pcall(function()
                for name in pairs(Key) do
                    if type(name) == "string" then live[name:upper()] = true; liveN = liveN + 1 end
                end
            end)
        end

        local fkey = keymap.FKEY
        local fkeyN, fkeyFalse = 0, 0
        for name, v in pairs(fkey) do
            fkeyN = fkeyN + 1
            if v == false then fkeyFalse = fkeyFalse + 1 end
            if type(name) ~= "string" then
                h:fail("keymap.FKEY has a non-string key (%s). Every row must be a UE4SS key "
                    .. "name.", type(name))
            end
        end

        if liveN == 0 then
            h:warn("REFUSED, and the gate is the SESSION rather than the world: there is no "
                .. "UE4SS `Key` table in this process, so the coverage direction — does FKEY have "
                .. "a row for every name UE4SS can bind — cannot be asked. No save, no menu and "
                .. "no world state opens this. TO OPEN IT: run this hook from inside a Palworld "
                .. "session with UE4SS loaded (`pf_hook keymap-key-coverage` in the UE4SS "
                .. "console, or `pf_hook_keymap_key_coverage` in autorun.txt). This is exactly "
                .. "the state test/cases/ui.lua:1583 reports with skipUnanswerable, for the same "
                .. "reason.")
            h:value("keymap.FKEY rows (the half that IS decidable here)", fkeyN)
            h:value("  of which explicit `false` (Unreal has no FKey for it)", fkeyFalse)
            h:value("  of which a US-LAYOUT ASSUMPTION", countPairs(keymap.LAYOUT_ASSUMED))
            h:note("nothing about drift was measured. The line above is a shape check the F1 "
                .. "suite already makes headlessly and is NOT this hook's result.")
            return
        end

        --------------------------------------------------------------------
        h:section("[2] the two tables, counted")
        --------------------------------------------------------------------
        h:value("UE4SS Key names this session", liveN)
        h:value("keymap.FKEY rows", fkeyN)
        h:value("  of which explicit `false` (Unreal has no FKey for it)", fkeyFalse)
        h:value("  of which a US-LAYOUT ASSUMPTION", countPairs(keymap.LAYOUT_ASSUMED))
        h:value("documented count both tables should be", DOCUMENTED_KEY_NAMES)
        if liveN ~= DOCUMENTED_KEY_NAMES then
            h:note("this session's UE4SS publishes %d names, not the %d counted out of the "
                .. "shipped key.md. That is a fact about the UE4SS BUILD, and it is what makes "
                .. "any drift below attributable — write the number into plan/TODO.md beside the "
                .. "drift lists.", liveN, DOCUMENTED_KEY_NAMES)
        end

        --------------------------------------------------------------------
        h:section("[3] one row per name, over the union of both tables")
        --------------------------------------------------------------------
        -- The UNION, not either table: a row that is in one and not the other is precisely the
        -- thing being looked for, and iterating either alone hides one of the two directions.
        local names, seen = {}, {}
        for name in pairs(fkey) do
            if type(name) == "string" and not seen[name] then seen[name] = true; names[#names + 1] = name end
        end
        for name in pairs(live) do
            if not seen[name] then seen[name] = true; names[#names + 1] = name end
        end
        table.sort(names)

        h:log("%-22s %-7s %-7s %-18s %-8s %s", "UE4SS NAME", "IN FKEY", "IN Key",
            "UNREAL FKEY", "CONF", "STATUS")
        local keyOnly, fkeyOnly = {}, {}
        for _, name in ipairs(names) do
            local hasRow  = fkey[name] ~= nil
            local hasLive = live[name] == true
            local spelling, conf = keymap.translate(name)
            local status
            if hasRow and hasLive then
                status = "ok"
            elseif hasLive then
                status = "⚠️ DRIFT — UE4SS WILL BIND THIS AND FKEY HAS NO ROW"
                keyOnly[#keyOnly + 1] = name
            else
                status = "not bindable in this session (FKEY row, no Key entry)"
                fkeyOnly[#fkeyOnly + 1] = name
            end
            h:log("%-22s %-7s %-7s %-18s %-8s %s", name,
                hasRow and (fkey[name] == false and "false" or "yes") or "-",
                hasLive and "yes" or "-",
                spelling or "-", conf or "-", status)
        end
        h:value("rows printed (the union)", #names)

        --------------------------------------------------------------------
        h:section("[4] the two drifts, named")
        --------------------------------------------------------------------
        -- They are not symmetric and must not be reported as if they were.
        if #keyOnly == 0 then
            h:pass("EVERY name UE4SS can bind has a row in keymap.FKEY. This is the assertion "
                .. "test/cases/ui.lua cannot make headlessly, and it holds on this build.")
        else
            h:fail("%d name(s) UE4SS WILL BIND have no keymap.FKEY row: %s. Each is unanswerable "
                .. "BECAUSE OF PALFORGE'S TABLE rather than because of the game — status() can "
                .. "only say \"unknown\" for it forever, and before M.lookup took the union it "
                .. "would not have appeared in the operator's report at all. FIX: add a row to "
                .. "core/keyboard/base/keymap.lua's M.FKEY — the Unreal spelling, or an explicit "
                .. "`false` when Unreal's EKeys registry genuinely has no entry.",
                #keyOnly, table.concat(keyOnly, ", "))
        end
        if #fkeyOnly == 0 then
            h:pass("and every keymap.FKEY row names something this UE4SS can actually bind, so "
                .. "the two sets are identical in both directions.")
        else
            h:note("%d FKEY row(s) are not in this session's Key table: %s. This is the HARMLESS "
                .. "direction — the name simply cannot be bound in this process, whatever "
                .. "Palworld has on it — and M.lookup already marks each such row. It becomes "
                .. "interesting only if a name this tree BINDS is in the list; block [5] is that "
                .. "check.", #fkeyOnly, table.concat(fkeyOnly, ", "))
        end

        --------------------------------------------------------------------
        h:section("[5] the names PalForge itself holds or refuses")
        --------------------------------------------------------------------
        -- The F1 case checks these against FKEY only, because FKEY is all it can see. In here
        -- the stronger question is available: is a key this tree actually binds one UE4SS can
        -- bind at all? A no there is not a table defect, it is a key that never fires — which is
        -- the F7 story, and the reason `registory.register` prints its keymap verdict on the
        -- `bound <KEY>` line itself.
        local owned = registory.owned()
        local held = {}
        for name in pairs(owned) do held[#held + 1] = name end
        table.sort(held)
        h:value("keys PalForge holds this session", #held > 0 and table.concat(held, ", ")
            or "none — this is not a dev session, or the keyboard layer never loaded")
        local badRow, badLive = {}, {}
        for _, name in ipairs(held) do
            if fkey[name] == nil then badRow[#badRow + 1] = name end
            if not live[name] then badLive[#badLive + 1] = name end
        end
        for name in pairs(registory.FORBIDDEN or {}) do
            if fkey[name] == nil then badRow[#badRow + 1] = name .. " (refused by name)" end
        end
        if #badRow == 0 then
            h:pass("every key this tree binds or refuses BY NAME has a keymap row, so \"is it "
                .. "free\" is answerable for all of them.")
        else
            h:fail("PalForge binds or refuses %s and keymap.FKEY has no row for it, so PalForge "
                .. "answers \"unknown\" about a key PalForge itself is using.",
                table.concat(badRow, ", "))
        end
        if #badLive == 0 and #held > 0 then
            h:pass("and every one of them is a name UE4SS's own Key table carries, so each bind "
                .. "addressed a real key rather than being accepted and dropped.")
        elseif #badLive > 0 then
            h:fail("PalForge holds %s, and this UE4SS's Key table has NO SUCH NAME. "
                .. "RegisterKeyBind cannot have bound it to anything: that key can never fire, "
                .. "and from the log it is indistinguishable from a probe that ran and found "
                .. "nothing — which is the exact failure this directory's header lists three "
                .. "times over.", table.concat(badLive, ", "))
        end

        h:note("WHAT TO WRITE IN plan/TODO.md: Owed work §3's second bullet says the coverage "
            .. "assertion \"can only run in a game\". After a run of this hook it has run in one: "
            .. "record this session's Key count (%d), the FKEY row count (%d), and the two drift "
            .. "lists — %d name(s) UE4SS-only, %d name(s) FKEY-only.",
            liveN, fkeyN, #keyOnly, #fkeyOnly)
    end,
}
