-- test/hooks/ui-backhandler — DOES CLAIMING THE COMMONUI BACK ACTION DO ANYTHING?
--
-- plan/TODO.md "Owed work" §4, first bullet, second half: `backHandler = true`
-- (api/ui.lua:826) — refused at define time without a `Frame` root, and never seen working.
--
-- WHAT IT CLAIMS. `backHandler = true` sets `bIsBackHandler` (CommonUI.hpp:149) on the element's
-- window before it is activated, which is how a Palworld screen says "Esc closes ME". Esc is not
-- a key on this build: it is the UI ACTION "UIEscape" / "UICancel" (rows of DT_UIInputAction),
-- routed by CommonUI's action router, which is why a UE4SS keybind on ESCAPE is refused by name
-- everywhere in this tree — a keybind can only ever be BESIDE that path, never in it.
--
-- ⚠️ THE OPEN QUESTION IS UPSTREAM OF OURS, and it is worth being precise about which question
-- this hook answers. `pf_uiroute` arms a counter on
-- /Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction and asks whether that route
-- fires AT ALL on this build. THIS hook asks the next question down: given a widget of ours that
-- has claimed the back action, does Esc reach IT. If pf_uiroute's `backAction` counter is 0,
-- read that first — a zero there explains a zero here and the two must not be diagnosed
-- separately.
--
-- ⚠️ AND THE THING THAT MUST NOT HAPPEN AGAIN. Two earlier live runs BROKE Esc: the game's own
-- pause menu would not open while a PalForge panel was up. The cause is understood — PalForge
-- was calling SetInputMode_GameAndUIEx on the player controller, which is not how Palworld
-- works. Palworld declares the input mode as DATA on the widget
-- (UPalActivatableWidget.InputConfig, Pal.hpp:13369) and lets the action router apply and
-- restore it. PalForge no longer makes that call ANYWHERE. So the FIRST instruction this hook
-- gives is "press Esc and check the game still behaves", and a broken Esc here is a finding
-- about the mount path rather than about backHandler.
--
-- The panel takes itself down on the CLOCK at 60 s through core/poll, so a broken Esc can never
-- strand anyone: no keypress is needed to get rid of it.
local hooks = require("palforge.test.hooks")

local REPORT_S = 12
local DOWN_S   = 60

hooks.declare{
    id    = "ui-backhandler",
    item  = "Closed 2026-08-02 — the healthy negative: input is not swallowed",
    needs = { world = true },
    desc  = "mount a panel that claims the CommonUI BACK action and find out what Esc then does",
    run = function(h)
        local UI      = require("palforge.api.ui")
        local support = require("palforge.test.support")
        local poll    = require("palforge.core.poll")

        --------------------------------------------------------------------
        h:section("[1] the panel that claims Esc")
        --------------------------------------------------------------------
        -- host = "layer" as well, deliberately: bIsBackHandler is read by the action router when
        -- the widget is ACTIVATED, and the router only activates what it put up itself. Claiming
        -- the back action on a widget the router never saw would be a test of nothing. That does
        -- couple this hook to ui-host-layer — run that one first, and if it did not mount, this
        -- one cannot either and its silence means nothing.
        local Panel = UI{
            id          = "palforge_test:HookBack",
            name        = "claims the CommonUI back action",
            host        = "layer",
            z           = 40,
            input       = "clicks",
            backHandler = true,
            root = UI.Frame{
                UI.Border{ color = { 0.62, 0.10, 0.55, 0.92 },
                    UI.SizeBox{ width = 460, height = 180,
                        UI.VBox{ padding = 12,
                            UI.Label{ text = "PalForge  backHandler = true", size = 20, native = true },
                            UI.Label{ text = "PRESS ESC. Either I close, or the game's menu opens." },
                            UI.Label{ text = "Both are results. I go away by myself at 60 s." },
                        },
                    },
                },
            },
        }
        local panel = Panel:new{}
        panel:autoMount(nil, 1000)
        h:pass("declared and asked to mount. It was ACCEPTED AT DEFINE TIME — the Frame-root "
            .. "requirement api/ui.lua:826 imposes is satisfied by this spec.")

        --------------------------------------------------------------------
        h:section("[2] what the game's own screens do with the back action")
        --------------------------------------------------------------------
        -- Read-only context, so a negative below can be attributed. If NO live Palworld widget
        -- has bIsBackHandler set either, the property is not how this build routes Esc at all
        -- and the whole `backHandler` idea is mis-specified rather than merely unreachable.
        local seen, claimed = 0, 0
        for _, className in ipairs({ "PalActivatableWidget", "PalUserWidget" }) do
            local all = {}
            pcall(function() all = FindAllOf(className) or {} end)
            for _, w in ipairs(all) do
                seen = seen + 1
                local v; pcall(function() v = w.bIsBackHandler end)
                if v == true then
                    claimed = claimed + 1
                    if claimed <= 8 then
                        local cls; pcall(function() cls = w:GetClass():GetFName():ToString() end)
                        h:value("bIsBackHandler on a GAME widget", tostring(cls))
                    end
                end
            end
            if seen > 0 then break end
        end
        h:value("live activatables", seen)
        h:value("...of which claim the back action", claimed)
        if seen > 0 and claimed == 0 then
            h:note("not one of Palworld's own live widgets has bIsBackHandler set. Either none is "
                .. "currently up that wants Esc, or this build does not route its back action "
                .. "through that property — which would make `backHandler` mis-specified rather "
                .. "than unreachable, and is a stronger finding than a silent panel.")
        end

        --------------------------------------------------------------------
        h:section("[3] what to do in game")
        --------------------------------------------------------------------
        h:ask("⚠️ PRESS ESC. Watch which of three things happens: (1) MY PANEL closes, (2) the "
            .. "game's PAUSE MENU opens as normal, (3) NOTHING happens at all.")
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN ui-backhandler-verdict below.")

        poll.every("ui-backhandler", function(elapsed)
            if elapsed < REPORT_S then return false end
            h:beginBlock("verdict")
            if not panel:isMounted() then
                h:log("FAIL NOT MOUNTED after %d s: %s", REPORT_S, tostring(panel:lastError()))
                h:log("NOTE backHandler was never tested: a claim on a widget the action router "
                    .. "never activated is a claim on nothing. Run ui-host-layer first — if that "
                    .. "one cannot mount either, the layer route is the finding and this item is "
                    .. "blocked behind it rather than answered.")
                h:endBlock("verdict")
                return true
            end
            local st = panel:state()
            local rootCls = "?"
            pcall(function() rootCls = st._tree.root:GetClass():GetFName():ToString() end)
            h:log("PASS mounted, rootClass=%s, and bIsBackHandler was written before activation",
                rootCls)
            h:log("NOTE HOW TO READ WHAT YOU SAW:")
            h:log("NOTE   (1) THE PANEL CLOSED on Esc -> `backHandler = true` WORKS. PalForge can "
                .. "put up a screen that Esc dismisses the way every Palworld screen is "
                .. "dismissed, and api/ui.lua:826's UNMEASURED warning comes out.")
            h:log("NOTE   (2) the game's PAUSE MENU opened instead -> the claim was ignored. Esc "
                .. "reached the router and the router did not consider our widget the back "
                .. "handler. Cross-check pf_uiroute's `backAction` counter: >0 there with this "
                .. "outcome means the route fires and our widget is not in the stack it walks.")
            h:log("NOTE   (3) NOTHING happened -> ⚠️ THE WORST OUTCOME and the one two earlier "
                .. "runs produced: Esc is broken while our panel is up. PalForge no longer calls "
                .. "SetInputMode anywhere, so this would be a NEW cause in the mount path, and it "
                .. "must be reported with the input-grab line printed below.")
            h:log("VALUE input grab -> %s", st._input
                and (table.concat(st._input.applied or {}, " + ")
                     .. (st._input.note and ("  [" .. st._input.note .. "]") or ""))
                or "nothing taken")

            poll.every("ui-backhandler down", function(e2)
                if e2 < (DOWN_S - REPORT_S) then return false end
                h:beginBlock("down")
                h:log("VALUE unmount -> %s (on the CLOCK, so a broken Esc can never strand it)",
                    tostring(panel:unmount()))
                h:log("VALUE swept test definitions = %d", support.sweep())
                h:endBlock("down")
                return true
            end)
            h:endBlock("verdict")
            return true
        end)
    end,
}
