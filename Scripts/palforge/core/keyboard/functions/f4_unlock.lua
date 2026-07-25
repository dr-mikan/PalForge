-- PalForge keybind F4: unlock all technology (dev). Mirrors the old F4 dev bind, but
-- as an extensible behaviour file that reuses the reusable utils.items helper. Only
-- loaded when env.dev (the registry's load() runs only in dev). Custom buildings +
-- chests appear in the BUILD menu after this.
local reg   = require("palforge.core.keyboard.base.registory")
local items = require("palforge.utils.items")

reg.register("F4", function()
    items.unlockAllTech()
end)
