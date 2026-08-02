-- PalForge tests.object_manager: example suite over the id resolver + central object
-- registry. Pure Lua, runs green headless. Uses "test:*" ids so it never collides
-- with real registered content.
--
-- IT ALSO GIVES THEM BACK. This bundle runs at every dev startup (core/registry.lua:91-94)
-- and again after every F9 reload, and object_manager has no expiry, so two throwaway ids
-- registered here would otherwise sit in the live registry for the rest of the session —
-- in the same buckets namespaced dispatch walks per missed lookup. The teardown below
-- removes exactly the two ids these tests register, and nothing else.
local T  = require("palforge.core.unittests")
local om = require("palforge.core.object_manager")

local s = T.suite("object_manager")

-- om.unregister(otype, id) is the explicit removal; before it existed the only spelling was
-- a registration of nil, which does delete the entry but reads as a definition call. Prefer
-- the explicit one and keep the old spelling as the fallback, so this file works either way.
local function drop(otype, id)
    pcall(function()
        if type(om.unregister) == "function" then om.unregister(otype, id)
        else om.register(otype, id, nil) end
    end)
end

s:after(function()
    drop("item", "test:Widget")
    drop("skill", "test:Zap")
end)

s:test("namespaced id resolves to its DataTable fname", function(t)
    t:eq(om.resolve("example:Bench"), "example_Bench")
end)

s:test("literal id passes through unchanged", function(t)
    t:eq(om.resolve("Wood"), "Wood")
end)

s:test("register + get round-trips a class", function(t)
    local cls = { id = "test:Widget" }
    om.register("item", "test:Widget", cls)
    t:eq(om.get("item", "test:Widget"), cls, "get returns the exact class")
end)

s:test("all() returns a snapshot containing registered ids", function(t)
    om.register("skill", "test:Zap", { id = "test:Zap" })
    local snap = om.all("skill")
    t:assert(snap["test:Zap"] ~= nil, "snapshot contains the registered id")
end)

s:test("register rejects an unknown type (fail-soft)", function(t)
    local ok = om.register("bogus", "test:Nope", {})
    t:assert(ok == nil, "unknown type -> nil, not a throw")
end)

return s
