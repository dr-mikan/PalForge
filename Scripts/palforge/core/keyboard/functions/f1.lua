-- PalForge keybind F1: TEMPORARY coordinate-spawn trigger (dev). Spawns a ChickenPal a few
-- metres from the player through the real Pal.get(id):spawn{at=} chain (tests/spawn.run, which
-- announces the result). References tests/spawn so the path is trivial to cut later — delete
-- this file's body + tests/spawn.lua, and the api/core spawn capability remains.
local reg = require("palforge.core.keyboard.base.registory")

reg.register("F1", function()
    pcall(function() require("palforge.tests.spawn").run("ChickenPal", 5) end)
end)
