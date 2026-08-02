-- test/hooks/ui-host-layer — ASK THE GAME TO PUT A SCREEN UP, THE WAY THE GAME DOES.
--
-- plan/TODO.md "Owed work" §4, first bullet: *"`UI.Spec.host = "layer"` (api/ui.lua:814) and
-- `backHandler = true` (:826) — both refused at define time without a `Frame` root, neither ever
-- seen working."* This hook owns the first half; test/hooks/ui_backhandler.lua owns the second.
--
-- WHAT "layer" MEANS, and why it is a different thing from the route that works. `host = "game"`
-- adds our widget to the in-game layout's own CanvasPanel_Root — PalForge does the adding, and
-- that route is PROVEN: `pf_uidecl: MOUNTED into PalPrimaryGameLayoutBase.CanvasPanel_Root |
-- slot=CanvasPanelSlot` is in the log. `host = "layer"` instead hands the widget to
-- `UCommonActivatableWidgetContainerBase::BP_AddWidget` on one of the layout's registered
-- CommonUI layers (CommonUI.hpp:194, UPrimaryGameLayout.Layers at CommonGame.hpp:158), which
-- CREATES, STACKS, ACTIVATES and REGISTERS it with the action router — and RemoveWidget takes
-- all of that back. It is how a Palworld screen goes up, and nothing of ours has ever gone up
-- that way.
--
-- ⚠️ THE LAYER TAGS ARE REGISTERED AT RUNTIME and no header lists them (RegisterLayer,
-- CommonGame.hpp:160). So block [1] prints what this build actually registered before anything
-- is mounted: `host = "layer"` cannot be written correctly without that list, and a mount that
-- fails for want of a tag must not be read as the route not existing.
--
-- Read-only with respect to the save. It puts a panel on screen for 45 s and takes it down
-- again, on the CLOCK through core/poll — never on a keypress, so nothing can strand it — and
-- the only thing it takes from the player is the cursor flag, which is read, restored exactly,
-- and additionally swept by the dead-man in native/ui/_widget.lua if this Lua state disappears.
local hooks = require("palforge.test.hooks")

local UP_S     = 45
local REPORT_S = 12

hooks.declare{
    id    = "ui-host-layer",
    item  = "Closed 2026-08-02 — mounted through the game's own CommonUI layer",
    needs = { world = true },
    desc  = "push a panel onto one of Palworld's own CommonUI layers through BP_AddWidget and "
         .. "report whether the game accepted it",
    run = function(h)
        local UI      = require("palforge.api.ui")
        local native  = require("palforge.native.ui")
        local support = require("palforge.test.support")
        local poll    = require("palforge.core.poll")
        local tree    = native.tree

        --------------------------------------------------------------------
        h:section("[1] which CommonUI layers this build registered")
        --------------------------------------------------------------------
        for _, line in ipairs(tree.layerReport()) do h:log("LAYER %s", tostring(line)) end
        local layers = native.widget.uiLayers()
        h:value("layers with a live container", #layers)
        if #layers == 0 then
            h:fail("no layer container was found, so BP_AddWidget has nothing to be called on. "
                .. "The mount below WILL fail and its failure will say nothing about the route. "
                .. "Run this from inside a loaded world with the HUD up.")
        end

        --------------------------------------------------------------------
        h:section("[2] the panel")
        --------------------------------------------------------------------
        -- A Frame ROOT IS REQUIRED and that requirement is the reason this has never been seen:
        -- api/ui.lua refuses `host = "layer"` at define time without one, because the thing
        -- BP_AddWidget takes is an activatable widget and only the Frame carries the game's own
        -- window class. The colour goes on a Border INSIDE the frame — `Frame{ color = }` is
        -- refused, since a Frame wears the game's own art and nothing here can tint it.
        local Panel = UI{
            id    = "palforge_test:HookLayer",
            name  = "the game's own route: pushed onto a CommonUI layer",
            host  = "layer",
            z     = 30,
            input = "clicks",
            root  = UI.Frame{
                UI.Border{ color = { 0.05, 0.55, 0.52, 0.92 },
                    UI.SizeBox{ width = 440, height = 170,
                        UI.VBox{ padding = 12,
                            UI.Label{ text = "PalForge  LAYER  (BP_AddWidget)", size = 20, native = true },
                            UI.Label{ text = "the GAME pushed me: created, stacked, activated" },
                            UI.Label{ text = "I go away by myself at " .. UP_S .. " s" },
                        },
                    },
                },
            },
        }
        local panel = Panel:new{}
        -- autoMount rather than mount: the in-game layout may not be up at the moment this runs,
        -- and the same subscription that retries the mount is the one that re-evaluates the
        -- bindings once it is in.
        panel:autoMount(nil, 1000)
        h:pass("declared and asked to mount. It was ACCEPTED AT DEFINE TIME, which is already "
            .. "one measured fact: the Frame-root requirement is satisfied by this spec.")
        h:ask("look at the top-left of your screen for a TEAL panel. Its absence is a result too.")
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN ui-host-layer-verdict below.")

        poll.every("ui-host-layer", function(elapsed)
            if elapsed < REPORT_S then return false end
            h:beginBlock("verdict")
            local st = panel:state()
            if not panel:isMounted() then
                h:log("FAIL NOT MOUNTED after %d s: %s", REPORT_S, tostring(panel:lastError()))
                h:log("NOTE that string names the step that refused — no layer container, no tag, "
                    .. "BP_AddWidget absent, or the call raising. `host = \"game\"` remains the "
                    .. "proven route and nothing else is affected by this.")
                h:endBlock("verdict")
                return true
            end

            -- The evidence, read off the BUILT TREE rather than inferred.
            local slotCls, rootCls, layerHit = "?", "?", "no"
            pcall(function() slotCls = st._tree.slot:GetClass():GetFName():ToString() end)
            pcall(function() rootCls = st._tree.root:GetClass():GetFName():ToString() end)
            pcall(function() layerHit = st._tree.layer and "yes" or "no" end)
            h:log("PASS MOUNTED THROUGH THE GAME'S OWN ROUTE. z=%s | slot=%s | rootClass=%s | "
                .. "layer=%s", tostring(st.zOrder), slotCls, rootCls, layerHit)
            h:log("VALUE input grab -> %s", st._input
                and (table.concat(st._input.applied or {}, " + ")
                     .. (st._input.note and ("  [" .. st._input.note .. "]") or ""))
                or "nothing taken")
            h:log("NOTE rootClass=WBP_PalCommonWindow_C means the panel is wearing the game's own "
                .. "window chrome; Border means the Frame fell back and a [ui] warning above "
                .. "names the class that was missing.")
            h:log("NOTE layer=yes is the line that closes `UI.Spec.host = \"layer\"`: PalForge "
                .. "can put a screen up the way the game does, activated and registered with the "
                .. "CommonUI action router.")

            poll.every("ui-host-layer down", function(e2)
                if e2 < (UP_S - REPORT_S) then return false end
                local gone = panel:unmount()
                h:beginBlock("down")
                h:log("VALUE unmount -> %s — through RemoveWidget if the game had put it on a "
                    .. "layer, which is also what makes the action router restore whatever input "
                    .. "config was underneath.", tostring(gone))
                h:log("VALUE swept test definitions = %d", support.sweep())
                h:endBlock("down")
                return true
            end)
            h:endBlock("verdict")
            return true
        end)
    end,
}
