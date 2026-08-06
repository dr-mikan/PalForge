-- test/hooks/ui-input-exclusive — THE ONE DECLARED SURFACE THAT HAD NO INSTRUMENT.
--
-- plan/TODO.md "Owed work" §1, last bullet: *"`UI.Spec.input = "exclusive"` is the one declared
-- surface in this file with no hook at all. Nothing under `test/hooks/` mounts it. Closing it
-- means declaring a hook, not running one."* This is the declaring.
--
-- WHAT `input = "exclusive"` IS, and why it is not `"clicks"` with more of it. Both are the
-- GAME's own input configs, declared on the element's activatable widget the way every Palworld
-- screen declares them (`UPalActivatableWidget.InputConfig`, Pal.hpp:13369) and put back by the
-- CommonUI action router on unmount:
--
--   "clicks"     GameAndMenu — the mouse reaches our widget AND the game still gets input.
--                Covered by ui-host-layer and ui-backhandler, both of which declare it.
--   "exclusive"  Menu — a MODAL. The game stops receiving gameplay input while it is up. That
--                is what an inventory screen declares, and it is the one nothing of ours has
--                ever asked for.
--
-- ⚠️ WHY THIS ONE IS THE RISKY ONE, said plainly because the operator is the safety net. A modal
-- that goes up and does not come down is a session where the player cannot move. Three things
-- stand between this hook and that, and the hook is built so that all three would have to fail
-- at once:
--   1. the panel comes down ON THE CLOCK through core/poll, never on a keypress — there is no
--      input this hook needs to receive in order to release the player;
--   2. PalForge never calls SetInputMode itself (doing that broke Esc twice); the declaration
--      goes on the widget and the ROUTER restores whatever was underneath on unmount;
--   3. native/ui/_widget.lua's dead-man sweep takes the grab back if this Lua state disappears.
-- It still declares `writes = false` honestly — nothing reaches the save — but it is the hook to
-- run on a throwaway session, and it says so before it puts anything up.
--
-- WHAT WOULD CLOSE THE ITEM. Two lines, and only the second is new information:
--   `input grab -> exclusive` says the declaration reached the widget.
--   THE OPERATOR'S ANSWER to "could you still move?" says whether the game's router acted on it.
-- A mount that succeeds while the player can still run around means Palworld read the config and
-- did nothing with it, which is a different and more interesting result than a refusal.
local hooks = require("palforge.test.hooks")

local UP_S     = 20      -- deliberately short: this is the modal one
local REPORT_S = 8

hooks.declare{
    id    = "ui-input-exclusive",
    item  = "Owed work §1 — the one declared surface with no hook",
    needs = { world = true },
    desc  = "declare input = \"exclusive\" (the game's own Menu mode) on a real panel and report "
         .. "whether the CommonUI router acted on it",
    run = function(h)
        local UI      = require("palforge.api.ui")
        local support = require("palforge.test.support")
        local poll    = require("palforge.core.poll")

        --------------------------------------------------------------------
        h:section("[1] what the declaration requires, before anything goes up")
        --------------------------------------------------------------------
        -- The Frame-root requirement is checked at DEFINE time, so a spec that is accepted has
        -- already told us something: this build's activatable-widget class was found.
        local okRefusal = select(1, pcall(function()
            return UI{ id = "palforge_test:ExclusiveNoFrame", input = "exclusive",
                       render = function() end }
        end))
        if okRefusal then
            h:fail("a spec with input = \"exclusive\" and NO Frame root was ACCEPTED. It should "
                .. "be refused at define time — the input config is declared on an activatable "
                .. "widget and only the Frame builds one. api/ui.lua's wantsActivatable gate has "
                .. "regressed.")
        else
            h:pass("input = \"exclusive\" without a Frame root is refused at define time, which "
                .. "is the guard that keeps the declaration from silently doing nothing.")
        end

        --------------------------------------------------------------------
        h:section("[2] the modal")
        --------------------------------------------------------------------
        h:ask("⚠️ READ THIS FIRST. A panel is about to go up declaring the game's MENU input "
            .. "mode. It takes itself down after " .. UP_S .. " s on a timer — you do not have "
            .. "to press anything, and nothing this hook does depends on receiving input. While "
            .. "it is up, TRY TO WALK. Whether you can is the measurement.")

        local Panel = UI{
            id    = "palforge_test:HookExclusive",
            name  = "input = exclusive (the game's own Menu mode)",
            host  = "game",          -- the PROVEN host route; the subject here is `input`, not `host`
            z     = 40,
            input = "exclusive",
            root  = UI.Frame{
                UI.Border{ color = { 0.55, 0.12, 0.45, 0.94 },
                    UI.SizeBox{ width = 460, height = 180,
                        UI.VBox{ padding = 12,
                            UI.Label{ text = "PalForge  EXCLUSIVE  (Menu input config)", size = 20, native = true },
                            UI.Label{ text = "TRY TO WALK. Can you?" },
                            UI.Label{ text = "I take myself down in " .. UP_S .. " s — no key needed" },
                        },
                    },
                },
            },
        }
        local panel = Panel:new{}
        panel:autoMount(nil, 1000)
        h:pass("declared and asked to mount, with a Frame root and host = \"game\" (the route "
            .. "that is already proven, so a failure below is about `input` and nothing else).")
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN ui-input-exclusive-verdict below.")

        poll.every("ui-input-exclusive", function(elapsed)
            if elapsed < REPORT_S then return false end
            h:beginBlock("verdict")
            local st = panel:state()
            if not panel:isMounted() then
                h:log("FAIL NOT MOUNTED after %d s: %s", REPORT_S, tostring(panel:lastError()))
                h:log("NOTE that string names the step that refused. host = \"game\" is proven, "
                    .. "so a refusal here is either the Frame class or the input declaration "
                    .. "itself — and either way the player was never modal.")
                h:endBlock("verdict")
                return true
            end

            local applied = st._input and table.concat(st._input.applied or {}, " + ") or "nothing taken"
            h:log("VALUE input grab -> %s%s", applied,
                st._input and st._input.note and ("  [" .. st._input.note .. "]") or "")
            h:log("VALUE declared input = exclusive | mounted = yes | z = %s", tostring(st.zOrder))
            h:ask("ANSWER THIS, it is the whole item: while the magenta panel is up, CAN YOU "
                .. "STILL MOVE YOUR CHARACTER? 'no, I was locked' closes the item POSITIVE — the "
                .. "router read our declaration and made the screen modal. 'yes, I could walk' "
                .. "closes it too, differently and more interestingly: the declaration reached "
                .. "the widget and Palworld did not act on it, which is a fact about the router "
                .. "rather than about PalForge.")
            h:note("do NOT answer from the grab line alone. `applied` says what PalForge asked "
                .. "for; only the character moving or not says what the game did with it.")

            poll.every("ui-input-exclusive down", function(e2)
                if e2 < (UP_S - REPORT_S) then return false end
                local gone = panel:unmount()
                h:beginBlock("down")
                h:log("VALUE unmount -> %s — the action router restores whatever input config "
                    .. "was underneath, which is why PalForge never calls SetInputMode itself.",
                    tostring(gone))
                h:log("VALUE swept test definitions = %d", support.sweep())
                h:ask("confirm you can move again. If you cannot, press F9 (reload) — the "
                    .. "dead-man sweep in native/ui/_widget.lua releases the grab.")
                h:endBlock("down")
                return true
            end)
            h:endBlock("verdict")
            return true
        end)
    end,
}
