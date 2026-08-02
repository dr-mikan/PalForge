-- PalForge keybind F4: unlock all technology (dev). Mirrors the old F4 dev bind, but
-- as an extensible behaviour file that reuses the reusable utils.items helper. Only
-- loaded when env.dev (the registry's load() runs only in dev). Custom buildings +
-- chests appear in the BUILD menu after this.
local reg   = require("palforge.core.keyboard.base.registory")
local items = require("palforge.utils.items")

-- register(), not claim(): this is a documented, intentional bind of a specific key in a dev-only
-- session, and being refused because Palworld happens to use F4 would leave the dev with no way
-- in at all. The desc is what reg.report() prints next to whatever the game has on the same key,
-- which is how "F4 does nothing" stops being a mystery — see core/keyboard/base/keymap.lua.
--
-- Since 2026-08-02 register() ASKS the keymap before it binds and prints the verdict on the same
-- line as "bound F4", so the answer is in the log at startup rather than only when somebody
-- thinks to run pf_keys or reg.report(). It still binds either way, which is the whole reason
-- this file uses register(). Read the verdict rather than trusting it in either direction: `free`
-- means no action in Palworld's key config uses F4, and the Steam overlay, the OS and UE's own
-- console keys are outside that config — F7 is the case that taught this tree the difference.
reg.register("F4", function()
    items.unlockAllTech()
end, { desc = "dev: unlock all technology" })
