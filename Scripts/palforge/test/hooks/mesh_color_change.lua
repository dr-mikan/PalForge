-- test/hooks/mesh-color-change — NOBODY HAS EVER WATCHED A COLOUR CHANGE.
--
-- plan/TODO.md "Owed work" §4, third bullet: *"A colour has never been watched changing —
-- `mesh-material-params` closed on measured parameter NAMES and says so; api/pal.lua:424-428 is
-- explicit that a true means the write ran."*
-- (The bullet is quoted as written and its line reference has drifted: the sentence it means is
--  Handle:renderOn's doc string, api/pal.lua:490-497, ending "read every `true` from this
--  function as 'the write ran'".)
--
-- THREE DIFFERENT THINGS, AND ONLY TWO OF THEM ARE MEASURED. core/mesh/base/renderer.lua:113-116
-- says it in its own words:
--   1. the write EXECUTED         — settled: every call is declared exactly as core/signature
--                                   checks it, so "the write did not run" is eliminated.
--   2. the parameter NAMES ARE REAL — settled: BaseColor and 'Base Texture' were read off the
--                                   running game's own materials, not guessed from a header.
--   3. THE TINT IS ON SCREEN      — NOT settled, and not settleable by any amount of code. It
--                                   needs an eye.
--
-- So this hook exists to put a colour in front of a person and ask. It cannot pass or fail
-- itself, and it says so: the verdict line it prints is a form for the operator to fill in.
-- That is honest, and a hook that pretended to judge its own pixels would not be.
--
-- ⚠️ WHY IT IS `writes = true` EVEN THOUGH IT TOUCHES NO SAVE FILE. It adds a component OF OURS
-- to the player's pawn and destroys it again. `kind = "static"` is chosen for exactly that
-- reason: a skeletal attach SWAPS THE PLAYER'S OWN BODY and captures a "original" to restore
-- afterwards, and nothing running unattended may do that to someone's character. If this hook's
-- Lua state disappears mid-run (a reload, a crash), the dead-man in native/ui/_widget.lua does
-- not cover meshes — the component would simply stay on the pawn until the world is left.
--
-- WHAT TO LOOK FOR, in the order each one proves something different:
--   a wooden chest in front of you       -> path -> LoadAsset -> SetStaticMesh -> a visible
--                                           component. That whole chain, watched.
--   it starts RED, turns GREEN, then BLUE -> the dynamic material instance is real AND the
--                                           measured parameter names reach the shader. This is
--                                           the observation nobody has made.
--   a chest that never changes colour     -> mesh yes, tint no. The MATDESC lines this prints
--                                           are the parameter names that asset really carries;
--                                           COLOR_PARAMS is missing whichever one they name.
--   nothing at all, attachTo -> true      -> it is attached where you cannot see it. Raise
--                                           OFFSET.z and run it again.
--   nothing at all, attachTo -> false     -> the [mesh] log line above names the step that
--                                           refused (resolve, AddComponentByClass,
--                                           SetStaticMesh, read-back).
local hooks = require("palforge.test.hooks")

-- Three colours nobody can confuse with each other or with an untinted wooden chest. The
-- previous UI run could not tell "the colour worked" from "the colour did nothing" because the
-- colour it declared was very nearly black; that mistake is not repeated here.
local STEPS = {
    { at = 0,  name = "RED",   color = { 1.00, 0.05, 0.05, 1.0 } },
    { at = 12, name = "GREEN", color = { 0.05, 1.00, 0.05, 1.0 } },
    { at = 24, name = "BLUE",  color = { 0.05, 0.15, 1.00, 1.0 } },
}
local OFFSET   = { x = 150, y = 0, z = 120 }
local DETACH_S = 40

hooks.declare{
    id     = "mesh-color-change",
    item   = "Owed work §2 (declared, shipped, never observed working)",
    needs  = { world = true, player = true },
    writes = true,
    desc   = "put a tinted mesh in front of the player and change its colour twice, so the one "
          .. "thing nobody has watched can be watched",
    run = function(h)
        local Mesh    = require("palforge.api.mesh")
        local mesh    = require("palforge.core.mesh")
        local support = require("palforge.test.support")
        local poll    = require("palforge.core.poll")

        local pawn = support.player()
        if not pawn then
            h:fail("the player pawn that satisfied the gate is gone; nothing was attached.")
            return
        end

        h:warn("about to add a StaticMeshComponent OF PALFORGE'S OWN to your pawn and destroy it "
            .. "again after %d s. Your character's own mesh, materials and save are never "
            .. "written to. If this session ends before the detach, the component stays until "
            .. "you leave the world.", DETACH_S)

        --------------------------------------------------------------------
        h:section("[1] attach, through the PUBLIC api, exactly as a pack would write it")
        --------------------------------------------------------------------
        -- ChestWood is the strongest path in the catalog: a live loaded-object sweep printed it
        -- and the game was rendering it off a real BP_BuildObject_ItemChest_C.
        local handle = Mesh{
            id     = support.id("mesh_color"),
            kind   = "static",
            model  = mesh.assets.SM.ChestWood,
            scale  = 1.0,
            offset = OFFSET,
            color  = STEPS[1].color,     -- declared, so step 1 also tests the ATTACH-TIME tint
        }
        local attached = handle:attachTo(pawn)
        h:value("attachTo(pawn)", tostring(attached))
        h:value("model", tostring(mesh.assets.SM.ChestWood))
        h:value("offset from the pawn", string.format("+%d,+%d,+%d", OFFSET.x, OFFSET.y, OFFSET.z))
        if not attached then
            h:fail("nothing was attached, so no colour can be watched. The [mesh] log line just "
                .. "above names the step that refused.")
            support.sweep()
            return
        end
        h:pass("a component is on the pawn — that half of the chain executed")

        --------------------------------------------------------------------
        h:section("[2] the parameter names this asset really carries")
        --------------------------------------------------------------------
        -- The same read that found BaseColor and 'Base Texture' on the player, pointed at this
        -- prop. If the tints below do not land, these are the names they should have written.
        mesh.describeMaterials(pawn, function(msg) h:log("MATDESC %s", tostring(msg)) end)

        --------------------------------------------------------------------
        h:section("[3] LOOK IN FRONT OF YOU")
        --------------------------------------------------------------------
        h:ask("a chest should be in front of you. It is declared RED now, turns GREEN at +12 s "
            .. "and BLUE at +24 s, then disappears at +%d s. WATCH IT.", DETACH_S)
        h:note("this hook keeps reporting after this block closes: look for "
            .. "#### BEGIN mesh-color-change-step-N and -verdict below.")

        local step, results = 1, {}
        poll.every("mesh-color-change", function(elapsed)
            if step <= #STEPS and elapsed >= STEPS[step].at then
                local s = STEPS[step]
                step = step + 1
                h:beginBlock("step-" .. (step - 1))
                -- Step 1's colour was declared at attach; writing it again is deliberate, so
                -- all three steps go through the SAME call and one of them cannot be the odd
                -- one out for having taken a different route.
                local ok = handle:setColor(pawn, s.color)
                results[#results + 1] = { name = s.name, ok = ok }
                h:log("VALUE setColor -> %s  | the chest should now be %s", tostring(ok), s.name)
                h:log("NOTE a true here means the dynamic material instance exists and the "
                    .. "parameter write executed. It is NOT a promise that anything changed on "
                    .. "screen — that is the whole reason this hook has an operator.")
                support.announce("mesh-color-change: the chest should be " .. s.name .. " now")
                h:endBlock("step-" .. (step - 1))
            end
            if elapsed < DETACH_S then return false end

            h:beginBlock("verdict")
            local gone = handle:detach(pawn)
            h:log("VALUE detach -> %s (true = K2_DestroyComponent ran and the component is off)",
                tostring(gone))
            for _, r in ipairs(results) do
                h:log("VALUE setColor %-6s = %s", r.name, tostring(r.ok))
            end
            h:log("NOTE THE ANSWER IS NOT IN THIS LOG — it is what you saw, and it belongs in "
                .. "plan/TODO.md as one of these four:")
            h:log("NOTE   (1) chest visible AND it went red -> green -> blue. mesh-color-change "
                .. "CLOSES: the dynamic material instance and the measured COLOR_PARAMS names "
                .. "reach the shader, and api/mesh's setColor doc can stop hedging.")
            h:log("NOTE   (2) chest visible, colour never changed. The mesh chain works and the "
                .. "TINT does not: read the MATDESC block above for the parameter names this "
                .. "asset actually exposes and compare them against renderer.lua's COLOR_PARAMS.")
            h:log("NOTE   (3) no chest, attachTo was true. It is attached out of sight; raise "
                .. "OFFSET.z in this file and run it again.")
            h:log("NOTE   (4) no chest, attachTo was false. The [mesh] line names the step.")
            local swept = support.sweep()
            h:log("VALUE throwaway definitions swept = %d", swept)
            h:endBlock("verdict")
            return true
        end)
    end,
}
