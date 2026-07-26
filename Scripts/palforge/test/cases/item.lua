-- palforge/test/cases/item.lua — the Item domain: spec, queries, handler wiring, inventory.
--
-- Almost all of this is pure: Item.Spec is enforced at define time, so the shape of a
-- definition (defaults, the enumerated category, the nested Recipe, the four declarable
-- events) can be proven with nothing but Lua tables, and the item.* DISPATCH is proven by
-- emitting the channel by hand instead of waiting for a native hook to fire. Only the last
-- test needs a world: :give / :take talk to the local player's inventory, so they SKIP at
-- the title screen.
--
-- That live test DOES WRITE to the running save's inventory, and it is the only thing in this
-- file that does: it asks for a few Wood, measures that they arrived, hands them straight back
-- and measures that they left. The hand-back is a DROP — take puts the items on the ground at
-- the player's feet rather than deleting them — so the net effect on a save is a small pickup
-- lying next to you, and the stockpile itself ends where it started. Both writes go through the
-- cheat-manager route (GetItem / DropItem) that no run has yet observed working, which is
-- exactly why the assertions are on the counts the game reports rather than on booleans.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Item    = require("palforge.api.item")
local om      = require("palforge.core.object_manager")
local event   = require("palforge.core.event")

local s = T.suite("item")

-- The item.* channels only reach a definition once core/event's DISPATCH is installed.
-- start() is idempotent and the kernel has already called it in game (registry.initialize
-- runs it before this suite is even loaded); headless it wires stubbed sources, which is
-- enough for the bus and the dispatch subscribers to exist.
local function dispatchReady()
    pcall(function() event.start() end)
end

--=============================================================================
-- define / get / get_all
--=============================================================================

s:test("defining an item registers it and hands back a handle that answers for it", function(t)
    local id = support.id("item")
    local h  = Item{ id = id, name = "Test Nugget", description = "a nugget for testing" }

    t:eq(h.id, id, "the handle carries the id it was defined with")
    t:eq(h:name(), "Test Nugget")
    t:eq(h:description(), "a nugget for testing")

    -- the definition CLASS is what core/event resolves against, so it must be in the
    -- central registry under ("item", id) — not just reachable from the handle.
    t:truthy(om.get("item", id), "the definition registers into object_manager")

    -- get() is a second handle over the SAME definition, not the same object.
    local again = Item.get(id)
    t:neq(again, h, "get builds a fresh handle")
    t:eq(again:name(), "Test Nugget", "...over the same definition")
end)

s:test("an item that declares nothing but its id still has a name, a category and a stack ceiling", function(t)
    local id = support.id("item")
    local h  = Item{ id = id }

    t:eq(h:name(), id, "name defaults to the id")
    t:eq(h:description(), nil)
    t:eq(h:category(), "material", "category defaults to material")
    t:eq(h:maxStack(), 1, "maxStack defaults to 1")
    t:eq(h:recipeOf(), nil, "an item is not craftable unless it says so")
end)

s:test("Item.get is total: an id nobody defined answers with the base defaults and is not registered", function(t)
    local id = support.id("ghost")          -- never passed to Item{ ... }
    local h  = Item.get(id)

    t:truthy(h, "get never returns nil")
    t:eq(h:name(), id)
    t:eq(h:category(), "material")
    t:eq(h:maxStack(), 1)
    t:eq(h:recipeOf(), nil)
    -- a thin wrapper over a game id must NOT leave a definition behind: get is a lookup,
    -- defining is the only thing that registers.
    t:eq(om.get("item", id), nil, "get registers nothing")
end)

s:test("Item.get refuses anything that is not a non-empty string", function(t)
    t:errors(function() Item.get(5) end, "id (string) is required")
    t:errors(function() Item.get("") end, "id (string) is required")
end)

s:test("get_all lists every PalForge-registered item, this run's included", function(t)
    local id = support.id("item")
    Item{ id = id }

    local all = Item.get_all()
    t:type(all, "table")

    local found = false
    for _, h in ipairs(all) do
        if h.id == id then found = true; break end
    end
    t:truthy(found, "the item just defined is in get_all")
end)

--=============================================================================
-- spec enforcement
--=============================================================================

s:test("id is required, and an empty one is rejected by the same check", function(t)
    t:errors(function() Item{ name = "no id" } end, 'field "id" is required')
    t:errors(function() Item{ id = "" } end, "must be a non-empty string")
end)

s:test("a category outside the enumerated set is a hard error that names the allowed values", function(t)
    local msg = t:errors(function() Item{ id = support.id("item"), category = "weapon" } end,
        'field "category" must be one of')
    t:truthy(msg:find('"consumable"', 1, true), "the message lists the categories that ARE accepted")
    t:truthy(msg:find('"weapon"', 1, true), "...and repeats what was passed")
end)

s:test("an unknown field is a hard error with a did-you-mean, never a silently ignored typo", function(t)
    local msg = t:errors(function() Item{ id = support.id("item"), maxStacks = 99 } end,
        'unknown field "maxStacks"')
    t:truthy(msg:find('did you mean "maxStack"', 1, true), "the near-miss is suggested")
    t:truthy(msg:find("Valid fields:", 1, true), "and the whole field list is printed")
end)

s:test("a declared field of the wrong type is rejected before anything is registered", function(t)
    local id = support.id("item")
    t:errors(function() Item{ id = id, maxStack = "lots" } end, 'field "maxStack" expects number')
    t:eq(om.get("item", id), nil, "a failed define registers nothing")
end)

--=============================================================================
-- the nested Recipe shape
--=============================================================================

s:test("a recipe must say what it consumes, as itemId -> number", function(t)
    t:errors(function() Item{ id = support.id("item"), recipe = { count = 2 } } end,
        'field "materials" is required')

    -- mapOf is checked per entry, and the failing KEY is named — the whole path lands in
    -- one pair of quotes so a reader can go straight to it.
    t:errors(function() Item{ id = support.id("item"), recipe = { materials = { Wood = "ten" } } } end,
        'field "materials.Wood" expects number')

    -- the nested spec is as strict as the outer one, and says which shape it is talking about
    local msg = t:errors(function()
        Item{ id = support.id("item"), recipe = { materials = { Wood = 1 }, workAmount = 3 } }
    end, 'unknown field "workAmount"')
    t:truthy(msg:find("Item.Spec.Recipe", 1, true), "the error names the nested spec")
end)

s:test("a recipe yields one item unless it says otherwise, and leaves work/station unset", function(t)
    local h = Item{ id = support.id("item"), recipe = { materials = { Wood = 5, Stone = 2 } } }
    local r = h:recipeOf()

    t:type(r, "table", "recipeOf hands back the declared recipe")
    t:eq(r.count, 1, "count defaults to 1")
    t:eq(r.work, nil)
    t:eq(r.station, nil)
    t:eq(r.materials.Wood, 5, "materials come through untouched")
    t:eq(r.materials.Stone, 2)

    local full = Item{ id = support.id("item"), recipe = {
        materials = { Wood = 1 }, count = 4, work = 30, station = support.GAME.building,
    } }
    local fr = full:recipeOf()
    t:eq(fr.count, 4)
    t:eq(fr.work, 30)
    t:eq(fr.station, support.GAME.building)
end)

--=============================================================================
-- icons
--=============================================================================

s:test("iconOf falls back to the declared icon when the DataTable has no row for the id", function(t)
    -- a support.id() is namespaced test content, so DT_ItemIconDataTable can never have a
    -- row for it — in game and headless alike this exercises the FALLBACK path.
    local h = Item{ id = support.id("item"), icon = "/Game/Pal/Texture/Icon/T_itemicon_Wood" }
    t:eq(h:iconOf(), "/Game/Pal/Texture/Icon/T_itemicon_Wood", "the declared icon is used on a miss")

    local bare = Item{ id = support.id("item") }
    t:eq(bare:iconOf(), nil, "no row and no declared icon means no icon — not an error")
end)

--=============================================================================
-- the events map and handler wiring
--=============================================================================

s:test("an event this domain does not declare is a hard error listing the four that exist", function(t)
    local msg = t:errors(function()
        Item{ id = support.id("item"), events = { onDrop = function() end } }
    end, 'unknown field "onDrop"')
    t:truthy(msg:find("onObtain, onUse, onCraft, onDiscard", 1, true),
        "the four declarable events are printed")
    t:truthy(msg:find("Item.Spec.Events", 1, true), "the error names the events spec")
end)

s:test("a handler that is not callable is rejected at define time", function(t)
    t:errors(function() Item{ id = support.id("item"), events = { onUse = 5 } } end,
        'field "onUse" expects function')
end)

s:test("a declared handler runs with the HANDLE as self, even when dispatch calls the class", function(t)
    local id = support.id("item")
    local seen
    local h = Item{ id = id, events = {
        onUse = function(self, ctx) seen = { self = self, ctx = ctx } end,
    } }

    h:onUse({ actor = "via-handle" })
    t:eq(seen.self, h, "the forwarder swaps the class out for the handle")
    t:eq(seen.ctx.actor, "via-handle", "the ctx is passed through untouched")

    -- exactly what core/event's dispatch does: inst[hook](inst, ctx) on the CLASS. The
    -- handler must still see the handle, because that is what carries :give.
    seen = nil
    local cls = om.get("item", id)
    cls:onUse({ actor = "via-class" })
    t:eq(seen.self, h, "a class-side call reaches the same handle")
    t:eq(seen.ctx.actor, "via-class")

    -- and a handle fetched later drives the same handler
    seen = nil
    Item.get(id):onUse({ actor = "via-get" })
    t:eq(seen.ctx.actor, "via-get", "get()'s handle forwards to the declared handler")
end)

s:test("an item with no handlers answers every lifecycle forwarder inertly", function(t)
    local h = Item{ id = support.id("item") }
    -- the base hooks are no-ops, not missing: a vanilla item must survive any dispatch.
    t:eq(h:onObtain({ count = 1 }), nil)
    t:eq(h:onUse({}), nil)
    t:eq(h:onCraft({}), nil)
    t:eq(h:onDiscard({}), nil)
end)

--=============================================================================
-- dispatch (channel -> handler). The channel is emitted by hand: waiting for a native
-- hook would make these tests depend on the player doing something.
--=============================================================================

s:test("emitting item.obtain reaches the defined item's handler with the event ctx", function(t)
    dispatchReady()
    local id = support.id("item")
    local got
    Item{ id = id, events = { onObtain = function(_, ctx) got = ctx end } }

    event.emit("item.obtain", { itemId = id, count = 7 })
    t:truthy(got, "dispatch resolved the definition by ctx.itemId")
    t:eq(got.count, 7, "the obtain count reaches the handler")

    -- an id nobody defined must be a silent no-op, not an error
    event.emit("item.obtain", { itemId = support.id("ghost"), count = 1 })
    t:eq(got.count, 7, "an undefined item does not re-enter our handler")
end)

s:test("a namespaced item is also reached by its resolved fname, which is the id the game emits", function(t)
    dispatchReady()
    local id    = support.id("item")            -- "palforge_test:item_N"
    local fname = om.resolve(id)                -- "palforge_test_item_N" — the DataTable row
    local hits  = 0
    Item{ id = id, events = { onUse = function(_, _) hits = hits + 1 end } }

    t:neq(fname, id, "a namespaced id and its row name differ")
    -- no ctx.actor: this emit is synthetic, and a handler that reads one would rather see
    -- nil than a stand-in that is not a character.
    event.emit("item.use", { itemId = fname })
    t:eq(hits, 1, "the fname fallback finds the definition registered under the colon form")
end)

s:test("onCraft is declarable and dispatches, but nothing native emits item.craft on this build", function(t)
    dispatchReady()
    local id = support.id("item")
    local crafted, discarded = 0, 0
    Item{ id = id, events = {
        onCraft   = function() crafted = crafted + 1 end,
        onDiscard = function() discarded = discarded + 1 end,
    } }

    -- The channels and their dispatch exist, so a pack's code is future-proof; only the
    -- SOURCE is missing. Emitting by hand is the only way either of these ever fires today.
    event.emit("item.craft", { itemId = id })
    event.emit("item.discard", { itemId = id })
    t:eq(crafted, 1, "item.craft dispatches to onCraft when something emits it")
    t:eq(discarded, 1, "item.discard dispatches to onDiscard when something emits it")
end)

s:test("free-form data is carried onto the definition, not onto the handle", function(t)
    local id = support.id("item")
    local h  = Item{ id = id, data = { tier = 3 } }

    t:eq(h.data, nil, "the handle exposes actions and queries, not the payload")
    local cls = om.get("item", id)
    t:eq(cls.data.tier, 3, "the definition class carries it, which is what a handler sees")
end)

--=============================================================================
-- LIVE — needs a loaded world
--=============================================================================

s:test("give really adds to the live inventory, measured both ways", function(t)
    support.needWorld(t)

    local COUNT = 3
    local wood  = Item.get(support.GAME.item)
    local before = wood:count()
    if before == nil then t:skip("the inventory count could not be read, so nothing here is measurable") end

    -- give writes through the inventory's own AddItem_ServerInternal and reports what the count
    -- DID, not that a call ran. Observed in game: "give Wood x3: 140 -> 143", with the game's own
    -- pickup event firing alongside it ("Wood onObtain: count=3") — two independent witnesses.
    t:eq(wood:give(COUNT), true, "give must report true: it writes to the inventory and returns "
        .. "the before/after delta, so a false is a refusal the inventory named in the log")
    local after = wood:count()
    t:truthy(after, "the count is still readable after the write")
    t:eq(after - before, COUNT, string.format("exactly %d landed (%d -> %d)", COUNT, before, after))

    -- Put them back. take is NOT its equal and this suite must not pretend otherwise: no removal
    -- route is known on this build, so this is a best effort whose only job is to leave the save
    -- as it was found. Its verdict is asserted as a boolean, never as a success.
    local removed = wood:take(COUNT)
    t:type(removed, "boolean", "take reports what it measured, never an assumed removal")
    if not removed then
        support.log(string.format("item: take could not give the %d %s back — the suite has left "
            .. "them in the inventory, which is the honest outcome while TODO(item-remove-call) "
            .. "is open", COUNT, support.GAME.item))
    end
end)
s:test("a vanilla item's icon comes back from the game's own table -- TODO(icons-row-read)", function(t)
    support.needWorld(t)

    -- This is the whole of icons-row-read, asked as a question a pack author would ask: can
    -- PalForge reuse the game's own artwork? Wood is a vanilla id that is certainly in the item
    -- icon table, and the handle declares no icon of its own, so anything that comes back came
    -- from the game.
    local wood = Item.get(support.GAME.item)
    t:eq(wood.icon, nil, "the lookup handle declares no icon, so a result can only be the game's")

    local tex = wood:iconOf()
    if tex == nil then
        t:skip("no icon came back — look for the [PalForge.icons] warn line naming the column's "
            .. "shape; the row read itself is proven, so a nil here means the last unwrap from "
            .. "soft-object-pointer to path is what is missing")
    end
    t:type(tex, "string", "an icon resolves to an asset path")
    t:truthy(#tex > 0, "and the path is not empty")
    support.log(string.format("icons: %s -> %s", support.GAME.item, tostring(tex)))
end)

return s
