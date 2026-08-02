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
-- and measures that they left. The add is the inventory's own AddItem_ServerInternal and it is
-- OBSERVED working; the hand-back is a consume through the weapon's RequestConsumeItem and no run
-- has watched that succeed yet, which is exactly why its assertion is on the count the game
-- reports rather than on a boolean. The worst case is that the Wood stays in the bag.
--
-- The declaration test beside it writes NOTHING. It prints what the live build declares for the
-- removal candidates, because a printed parameter list is what ended the add's long outage and it
-- is the only safe thing to do with a candidate (InitInventory) whose name suggests it may wipe.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Item    = require("palforge.api.item")
local items   = require("palforge.utils.items")
local om      = require("palforge.core.object_manager")
local event   = require("palforge.core.event")

local s = T.suite("item")

-- Throwaway definitions go back out as soon as this suite finishes; defining is permanent
-- and every id below is namespaced test content.
support.sweepAfter(s)

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
-- the recipe READ — core/recipes, the game's own DT_ItemRecipeDataTable_Common row
--
-- The parse is decidable HEADLESS and is tested that way. core.recipes.fromRow takes anything
-- that answers row[<column>], which in game is the live ScriptStruct dt:FindRow hands back and
-- here is a plain Lua table shaped like the row measured on 2026-08-02 (hook
-- item-datatable-row-read: Product_Count=10, WorkAmount=1000.0, Material1_Id=Wood as an FName,
-- Material1_Count=2). So the SHAPE, the empty-slot filtering and the FName unwrap are proven in
-- every run, and only "is that really what the table holds" waits for a save.
--=============================================================================

-- An FName as it arrives from the engine: a userdata is not constructible in plain Lua, so the
-- stand-in is a table with the one member the measurement said matters — :ToString(). It stands
-- for the shape, not for the userdata; the live half of this file is what tests the userdata.
local function fname(s) return setmetatable({}, { __index = { ToString = function() return s end } }) end

s:test("a recipe row is read into the declared Item.Spec.Recipe shape, materials included", function(t)
    local recipes = require("palforge.core.recipes")

    -- Exactly the row the 2026-08-02 run printed, plus the four empty material slots a real
    -- row carries beside the one that is filled.
    local r = recipes.fromRow({
        Product_Id      = fname("Arrow"),
        Product_Count   = 10,
        WorkAmount      = 1000.0,
        Material1_Id    = fname("Wood"),
        Material1_Count = 2,
        Material2_Id    = fname("None"),
        Material2_Count = 0,
        Material3_Id    = fname(""),
        Material4_Id    = nil,
        Material5_Id    = fname("None"),
        WorkableAttribute = 3,        -- read by nobody: it is an enum, not a station id
    }, "Arrow")

    t:type(r, "table", "a row that answers by name becomes a recipe")
    t:eq(r.product, "Arrow", "Product_Id is an FName and is ToString'd")
    t:eq(r.count, 10, "Product_Count is how many one craft yields")
    t:eq(r.work, 1000.0, "WorkAmount comes through as the float it is")
    t:eq(r.station, nil, "the row has no station id, so station stays nil rather than an enum")
    t:eq(r.materials.Wood, 2, "the filled material slot is { <itemId> = <count> }")

    -- the four empty slots must not become materials — "None" is the empty FName's ToString
    local n = 0
    for _ in pairs(r.materials) do n = n + 1 end
    t:eq(n, 1, "an empty or None material slot is not a material")
    t:eq(r.materials.None, nil, "the empty FName never lands in the map as an id")
end)

s:test("two slots naming the same material are summed, and a plain string id reads the same as an FName", function(t)
    local recipes = require("palforge.core.recipes")

    local r = recipes.fromRow({
        Product_Count   = 1,
        Material1_Id    = "Wood",       -- already a string: no unwrap needed
        Material1_Count = 2,
        Material2_Id    = fname("Wood"),
        Material2_Count = 3,
    }, "Plank")

    t:eq(r.materials.Wood, 5, "a map cannot hold the id twice, so the counts add up")
    t:eq(r.product, "Plank", "with no Product_Id the row key is the product")
end)

s:test("a row that answers nothing is nil, not an empty recipe that looks free", function(t)
    local recipes = require("palforge.core.recipes")

    t:eq(recipes.fromRow(nil, "Arrow"), nil, "no row, no recipe")
    t:eq(recipes.fromRow({}, "Arrow"), nil,
        "a struct that answers no column by name must not become { materials = {} }, which "
        .. "would read as a recipe that costs nothing")

    -- a count with no id is still not a material, and on its own is still not a recipe
    t:eq(recipes.fromRow({ Material1_Count = 4 }, "Arrow"), nil)
    -- but ONE readable column is enough to say the struct answered
    local work = recipes.fromRow({ WorkAmount = 50 }, "Arrow")
    t:type(work, "table")
    t:eq(work.count, 1, "an unreadable Product_Count defaults to 1, the spec's own default")
end)

s:test("resolve never raises and answers nil with no game under it", function(t)
    local recipes = require("palforge.core.recipes")

    t:eq(recipes.resolve(nil), nil, "a non-string id is refused rather than passed to FindRow")
    t:eq(recipes.resolve(""), nil)
    -- headless there is no DataTable at all; in game this id has no row. Either way the
    -- contract is the same one every engine boundary here keeps: nil, and nothing thrown.
    t:eq(recipes.resolve(support.id("ghost")), nil,
        "an id with no row answers nil, whether or not a table was found")
end)

s:test("a declared recipe WINS over the game's row, and an item with neither answers nil", function(t)
    -- Wood is a vanilla id with a real row in DT_ItemRecipeDataTable_Common, so this is the
    -- precedence question asked where it actually bites: a pack that describes its own
    -- crafting for a vanilla id must get ITS numbers back, in game and headless alike.
    -- register = false: this builds a definition WITHOUT putting it in the registry, which
    -- matters here and nowhere else in this file — every other id is namespaced test content
    -- the sweep takes back out, and "Wood" is not. A registered definition for a vanilla id
    -- would outlive the suite and take that id's live item.* events with it.
    local mine = Item({ id = support.GAME.item, recipe = { materials = { Stone = 99 }, count = 7 } },
        { register = false })
    local r = mine:recipeOf()
    t:eq(r.count, 7, "the declared count is not overruled by Product_Count")
    t:eq(r.materials.Stone, 99, "nor are the declared materials")
    t:eq(r.materials.Wood, nil, "the game's row did not leak into the declared one")

    -- and the declared table is handed back AS DECLARED, not copied and rebuilt
    t:eq(mine:recipeOf(), r, "the same declared table comes back every call")

    -- an id nobody declared, that no table can have a row for
    t:eq(Item.get(support.id("ghost")):recipeOf(), nil, "no declaration and no row is nil")
end)

--=============================================================================
-- restores — the one field on Item.Spec that WRITES to a character
--
-- The engine half was measured on 2026-08-02 by the hook item-satiety-write, on a live
-- character: satiety 31.648391723633 -> 21.648391723633 through SetFullStomach, and the HP
-- write landing through AddHPByRate(float). Everything decidable WITHOUT a save is decided
-- here — the spec accepts the field, refuses every shape this build cannot keep, the
-- arithmetic clamps, and the item.use subscriber really reaches the definition — and only the
-- write itself waits for a world, at the bottom of this file.
--=============================================================================

s:test("an item can declare what using it restores, and hands the declaration back", function(t)
    local h = Item{ id = support.id("item"), restores = { satiety = 20 } }
    t:type(h:restores(), "table", "the declaration is readable off the handle")
    t:eq(h:restores().satiety, 20)
    t:eq(h:restores().hpRate, nil, "a vital that was not declared stays nil")

    local both = Item{ id = support.id("item"), restores = { satiety = 5, hpRate = 0.25 } }
    t:eq(both:restores().hpRate, 0.25, "the two vitals are independent")

    t:eq(Item{ id = support.id("item") }:restores(), nil,
        "an item that restores nothing says nil, not an empty table that looks like a promise")
end)

s:test("a restore that names no vital, or a vital of the wrong type, is refused at define time", function(t)
    local msg = t:errors(function() Item{ id = support.id("item"), restores = {} } end,
        "must name at least one vital")
    t:truthy(msg:find("subscribe to item.use and write nothing", 1, true),
        "the refusal says what an empty restore would have done")

    t:errors(function() Item{ id = support.id("item"), restores = { satiety = "lots" } } end,
        'field "satiety" expects number')

    -- 0 is the shape that reads as a declaration and cannot move a bar
    t:errors(function() Item{ id = support.id("item"), restores = { satiety = 0 } } end,
        "0 restores nothing")

    -- an unknown vital is named against the nested spec, with the did-you-mean the outer
    -- fields get: a silently ignored `stamina` would be a food item that never fed anyone
    local unknown = t:errors(function()
        Item{ id = support.id("item"), restores = { stamina = 10 } }
    end, 'unknown field "stamina"')
    t:truthy(unknown:find("Item.Spec.Restores", 1, true), "the error names the nested spec")
    t:truthy(unknown:find("satiety, hpRate, hp", 1, true), "and lists the fields that exist")
end)

s:test("an absolute HP amount is REFUSED at define time, with the measurement that justifies it", function(t)
    -- THE BAR: anything that cannot work on this build refuses while it is being written, and
    -- names why. `hp` is declared as a field precisely so that this sentence is what an author
    -- gets instead of an "unknown field" that names no cause.
    local msg = t:errors(function()
        Item{ id = support.id("item"), restores = { hp = 50 } }
    end, "an absolute HP amount cannot be written on this build")
    t:truthy(msg:find("FFixedPoint64", 1, true), "the refusal names the struct that blocks it")
    t:truthy(msg:find("Pal.hpp:15933", 1, true), "and where the declaration was read")
    t:truthy(msg:find("Declare hpRate instead", 1, true), "and what to write instead")
    t:truthy(msg:find("item-satiety-write", 1, true), "and the hook that measured it")
end)

s:test("hpRate is a FRACTION, and a value outside -1..1 is refused with the reason it is one", function(t)
    local msg = t:errors(function()
        Item{ id = support.id("item"), restores = { hpRate = 50 } }
    end, "is not a rate")
    t:truthy(msg:find("AddHPByRate", 1, true), "the refusal names the only HP write this build has")
    t:truthy(msg:find("0.25 is a quarter", 1, true), "and says what a rate means")

    t:errors(function() Item{ id = support.id("item"), restores = { hpRate = -1.5 } } end,
        "is not a rate")
    t:errors(function() Item{ id = support.id("item"), restores = { hpRate = 0 } } end,
        "0 heals nothing")

    -- the boundaries themselves are legal: a full heal, and the -0.1 the hook actually wrote
    t:eq(Item{ id = support.id("item"), restores = { hpRate = 1 } }:restores().hpRate, 1)
    t:eq(Item{ id = support.id("item"), restores = { hpRate = -0.1 } }:restores().hpRate, -0.1)
end)

s:test("the satiety arithmetic clamps to the bar, and is decided without an engine", function(t)
    local character = require("palforge.core.character")

    -- the numbers the 2026-08-02 run actually read off a live character. Compared with a
    -- tolerance rather than with ==: satiety is a float and the sum of two of them is not
    -- required to be bit-identical to the literal a reader would write for it.
    local target = character.satietyTarget(31.648391723633, 100.0, 20)
    t:truthy(math.abs(target - 51.648391723633) < 1e-9,
        "a restore adds to what the character has, got " .. tostring(target))
    t:eq(character.satietyTarget(95, 100, 20), 100, "and never overfills the bar")
    t:eq(character.satietyTarget(10, 100, -30), 0, "a drain stops at empty")
    t:eq(character.satietyTarget(100, 100, 20), 100, "a full character has nothing to gain")
    t:eq(character.satietyTarget(50, nil, 20), 70,
        "an unreadable maximum still applies the floor rather than refusing to compute")
end)

s:test("a restore with no character under it is a false that says why, never a raise", function(t)
    local character = require("palforge.core.character")

    local ok, why = character.restore(nil, { satiety = 20 })
    t:eq(ok, false, "there is no pawn headless, so nothing was written")
    t:type(why, "string", "and the reason is an English sentence, not a nil")
    t:truthy(why:find("satiety", 1, true), "which names the vital that did not land")

    -- an unknown vital is refused by the engine boundary too, not only by the spec: a direct
    -- caller of core.character must not be able to ask for something that silently no-ops
    local okKey, whyKey = character.restore({}, { stamina = 10 })
    t:eq(okKey, false)
    t:truthy(whyKey:find("is not a vital PalForge can write", 1, true))
    t:truthy(whyKey:find("satiety", 1, true), "and the message lists the ones that are")

    -- the rate rule is enforced where the write happens, not only where it is declared
    local okRate, whyRate = character.addHPByRate({}, 5)
    t:eq(okRate, false)
    t:truthy(whyRate:find("is not a rate", 1, true))
    local okZero, whyZero = character.addHPByRate({}, 0)
    t:eq(okZero, false)
    t:truthy(whyZero:find("heals nothing", 1, true), "a rate of 0 is refused before any object "
        .. "is asked for, so it is decidable with no engine at all")

    -- and an item that declares nothing answers the same way rather than pretending
    local okNone, whyNone = Item{ id = support.id("item") }:restoreOn(nil)
    t:eq(okNone, false)
    t:truthy(whyNone:find("declares no restores", 1, true))
end)

s:test("item.use reaches the declared restore — the wiring, proven without a world", function(t)
    dispatchReady()
    local id  = support.id("item")
    local h   = Item{ id = id, restores = { satiety = 20 } }
    local cls = om.get("item", id)
    t:truthy(cls, "the definition is in the registry, which is what the subscriber resolves")

    -- The write itself needs a live character, so what is asserted here is the ROUTE: the
    -- subscriber exists, it resolves the definition off ctx.itemId, and it hands over the
    -- character the channel carried. Standing in for the engine call is the only way to see
    -- that headless, and it is the same substitution the recipe row tests make.
    local real, seen = cls.restoreOn, {}
    cls.restoreOn = function(self, actor)
        seen[#seen + 1] = { cls = self, actor = actor }
        return true
    end

    event.emit("item.use", { itemId = id, actor = "pretend-pawn" })
    t:eq(#seen, 1, "using the item applied its restore exactly once")
    t:eq(seen[1].actor, "pretend-pawn", "the character the channel carried is who it is applied to")
    t:eq(seen[1].cls, cls, "and it is the definition's own declaration that is applied")

    -- the game emits the PalSchema row name, never the colon form a pack declared
    event.emit("item.use", { itemId = om.resolve(id) })
    t:eq(#seen, 2, "the resolved fname finds the same definition")

    -- an item that declares no restore, and an id nobody defined, must both be silent no-ops
    local plain = support.id("item")
    Item{ id = plain, events = { onUse = function() end } }
    event.emit("item.use", { itemId = plain, actor = "pretend-pawn" })
    event.emit("item.use", { itemId = support.id("ghost"), actor = "pretend-pawn" })
    t:eq(#seen, 2, "nothing else was touched")

    cls.restoreOn = real
    t:eq(h:restores().satiety, 20, "the definition is unchanged by the dispatch")
end)

s:test("a declared events.onUse does NOT displace the restore, which is why it is a subscriber", function(t)
    dispatchReady()
    local id   = support.id("item")
    local runs = 0
    Item{ id = id, restores = { satiety = 20 },
          events = { onUse = function() runs = runs + 1 end } }

    local cls, applied = om.get("item", id), 0
    local real = cls.restoreOn
    cls.restoreOn = function() applied = applied + 1; return true end

    event.emit("item.use", { itemId = id, actor = "pretend-pawn" })
    t:eq(runs, 1, "the author's handler ran")
    t:eq(applied, 1, "AND the restore was applied — the handler overrides onUse, not the vitals")
    cls.restoreOn = real
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
    if before == nil then
        -- A pawn exists (needWorld passed) and the inventory still would not answer, so this
        -- is not something another run in another state fixes: the [PalForge.items] line
        -- naming the failed lookup is the finding, and the check is counted as unanswered
        -- rather than quietly folded into the green count.
        t:skipUnanswerable("the inventory count could not be read on this pawn, so the "
            .. "before/after that give and take are measured with does not exist — see the "
            .. "[PalForge.items] log line naming which lookup failed")
    end

    -- give writes through the inventory's own AddItem_ServerInternal and reports what the count
    -- DID, not that a call ran. Observed in game: "give Wood x3: 140 -> 143", with the game's own
    -- pickup event firing alongside it ("Wood onObtain: count=3") — two independent witnesses.
    t:eq(wood:give(COUNT), true, "give must report true: it writes to the inventory and returns "
        .. "the before/after delta, so a false is a refusal the inventory named in the log")
    local after = wood:count()
    t:truthy(after, "the count is still readable after the write")
    t:eq(after - before, COUNT, string.format("exactly %d landed (%d -> %d)", COUNT, before, after))

    -- Put them back, and this run is what leaves the save exactly as it was found. take works
    -- now — observed as "take Wood x3: 164 -> 161" in the same press that gave them — so the
    -- round trip is assertable rather than hoped for.
    --
    -- It is still not asserted UNCONDITIONALLY, and the reason is a real constraint rather than
    -- doubt: take goes through a weapon's own consume, and a player carrying nothing has no
    -- weapon actor to ask. A tester in that state should see a clear message, not a red test for
    -- something they are not doing wrong.
    local removed = wood:take(COUNT)
    t:type(removed, "boolean", "take reports what it measured, never an assumed removal")
    if removed then
        local back = wood:count()
        t:eq(back, before, string.format("the %d %s went back out again (%d -> %s)",
            COUNT, support.GAME.item, after, tostring(back)))
    else
        support.log(string.format("item: take left the %d %s in the inventory. The route is "
            .. "proven, so the [PalForge.items] line above names the state this run was in — "
            .. "most likely nothing equipped, which means no weapon actor to ask",
            COUNT, support.GAME.item))
    end
end)

s:test("the removal candidates' live declarations are printed, and none of them is called", function(t)
    support.needWorld(t)

    -- READ-ONLY, deliberately. sig.describe walks a UFunction on the running build and logs the
    -- shape it found; it calls nothing. That distinction is the whole test: InitInventory is a
    -- candidate precisely because "Init" might mean SET (so Count 0 would be a removal) and might
    -- equally mean WIPE, and the only safe first move on a real save is to read its parameter
    -- list. The same printed-declaration move is what ended the add's outage, where the live
    -- build turned out to declare one more parameter than dumps/cxx/Pal.hpp does.
    local read = items.describeRemoval()
    t:type(read, "table", "describeRemoval reports what it managed to read")

    if read.InitInventory == nil then
        support.log("item: InitInventory's declaration was not read (no cheat manager — needs "
            .. "CheatManagerEnabler); dumps/cxx/Pal.hpp:16379 says (FName, int32)")
    else
        t:type(read.InitInventory, "string", "an evidence level came back for InitInventory")
        support.log("item: InitInventory declaration evidence = " .. read.InitInventory)
    end

    if read.RequestConsumeItem == nil then
        support.log("item: RequestConsumeItem's declaration was not read — the player has no "
            .. "spawned weapon actor, which is also why :take has no route in this session")
    else
        t:type(read.RequestConsumeItem, "string", "an evidence level came back for the take route")
        t:neq(read.RequestConsumeItem, "absent",
            "the build must still declare the call :take makes; an absent here means "
            .. "dumps/cxx/Pal.hpp:11776 has gone stale the way AddItem_ServerInternal did")
    end
end)
s:test("a declared restore really moves a live character's satiety, and puts it back", function(t)
    local pawn      = support.needWorld(t)
    local character = require("palforge.core.character")

    -- THE WRITE, on the player, exactly as the hook item-satiety-write made it on 2026-08-02
    -- (31.648391723633 -> 21.648391723633, restored). It is safe to assert unconditionally for
    -- one reason: SetFullStomach is an EXACT setter, so the value this run finds is the value
    -- it puts back — unlike HP, whose only undo is FullRecoveryHP and heals to maximum instead
    -- of to what was there. That is why the HP write stays in the opt-in hook and this suite
    -- only reads it, below.
    local before, max = character.satietyOf(pawn)
    if before == nil then
        t:skipUnanswerable("satiety did not read on this pawn, so there is no before/after to "
            .. "measure a restore with — the [PalForge.signature] line names the getter that "
            .. "refused. A route that cannot read cannot be shown to write")
    end
    t:type(before, "number", "GetFullStomach answers a plain float")
    if max then t:truthy(max > 0, "and the bar has a width") end

    -- DOWN by five when there is room to come back up, up by five when the character is empty.
    -- Either way the target is inside the bar, so nothing is lost to a clamp and the delta the
    -- assertion expects is the delta the game can actually deliver.
    local delta = (before > 5) and -5 or 5
    local h = Item{ id = support.id("item"), restores = { satiety = delta } }

    local ok, why = h:restoreOn(pawn)
    t:eq(ok, true, "restoreOn reports what the read-back saw: " .. tostring(why))

    local after = character.satietyOf(pawn)
    t:type(after, "number", "satiety is still readable after the write")
    t:truthy(math.abs(after - (before + delta)) < 0.01, string.format(
        "the bar moved by exactly the declared amount (%s -> %s, wanted %s)",
        tostring(before), tostring(after), tostring(before + delta)))

    -- and this run leaves the save as it found it
    local back = character.setSatiety(pawn, before)
    t:eq(back, true, "satiety was put back to the value this run found")
    t:truthy(math.abs((character.satietyOf(pawn) or -1) - before) < 0.01,
        string.format("read back at %s", tostring(before)))
    support.log(string.format("item: satiety %s of %s, restored %s and put back",
        tostring(before), tostring(max), tostring(delta)))
end)

s:test("the HP rate reads on a live character, and a bad rate is refused before anything is written", function(t)
    local pawn      = support.needWorld(t)
    local character = require("palforge.core.character")

    -- READ-ONLY, deliberately, and this is the one place in the suite where that is a decision
    -- rather than a limitation. AddHPByRate IS measured landing (2026-08-02, hook
    -- item-satiety-write, on the player), but its only undo is FullRecoveryHP, which heals to
    -- MAXIMUM rather than back to what it found — so a suite that ran it would leave a damaged
    -- tester healthier than it found them and could not honestly call that a restore. The write
    -- stays in the opt-in hook, where the operator agreed to it; what is checked here is that
    -- the component and its read-back are reachable, which is everything the write rests on.
    local comp = character.parameterComponentOf(pawn)
    if comp == nil then
        t:skipUnanswerable("the UPalCharacterParameterComponent could not be read off this pawn "
            .. "(Pal.hpp:8960, getter at :9078). AddHPByRate is declared there and nowhere else, "
            .. "so this session cannot say whether the HP half is reachable")
    end
    local rate = character.hpRateOf(pawn)
    t:type(rate, "number", "GetHPRate answers the fraction the write is measured against")
    t:truthy(rate >= 0, "and it is a rate, not a points value")

    -- the refusal path, asserted where a real component exists: it must still refuse, and it
    -- must refuse WITHOUT calling anything
    local ok, why = character.addHPByRate(pawn, 5)
    t:eq(ok, false, "a rate of 5 is refused even with a live component to write to")
    t:truthy(why:find("is not a rate", 1, true), "and says what a rate is")
    t:truthy(math.abs((character.hpRateOf(pawn) or -1) - rate) < 1e-4,
        "the refusal wrote nothing: the HP rate is where it was")
    support.log(string.format("item: HP rate %s, AddHPByRate reachable on %s",
        tostring(rate), tostring(comp)))
end)

s:test("a vanilla item's icon comes back from the game's own table", function(t)
    support.needWorld(t)

    -- This is the whole of icons-row-read, asked as a question a pack author would ask: can
    -- PalForge reuse the game's own artwork? Wood is a vanilla id that is certainly in the item
    -- icon table, and the handle declares no icon of its own, so anything that comes back came
    -- from the game.
    local wood = Item.get(support.GAME.item)
    t:eq(wood.icon, nil, "the lookup handle declares no icon, so a result can only be the game's")

    local tex = wood:iconOf()
    if tex == nil then
        -- A nil here is not "not measured yet", it is a question about the COLUMN, and there
        -- is a declared hook that asks it properly: item-datatable-row-read walks the struct
        -- dt:FindRow(id) hands back and prints what each column type unwraps to. Naming it is
        -- the point of the direction — the reader is one action away from the answer instead
        -- of one grep away from the log line that hints at it.
        t:skipNeedsHook("item-datatable-row-read",
            "no icon came back — the [PalForge.icons] warn line names the column's shape, and "
            .. "the row read itself is proven, so a nil here means the last unwrap from "
            .. "soft-object-pointer to path is what is missing")
    end
    t:type(tex, "string", "an icon resolves to an asset path")
    t:truthy(#tex > 0, "and the path is not empty")
    support.log(string.format("icons: %s -> %s", support.GAME.item, tostring(tex)))
end)

s:test("a vanilla item's recipe comes back from the game's own table", function(t)
    support.needWorld(t)

    -- ARROW, and not support.GAME.item: Wood is gathered, not crafted, so a nil for it would
    -- say nothing. Arrow is the row the 2026-08-02 run read column by column
    -- (Product_Count=10, WorkAmount=1000.0, Material1_Id=Wood, Material1_Count=2), so this
    -- check is that measurement asked again through the public API — the one thing the hook
    -- could not do, because recipeOf did not reach the game when the hook was written.
    local arrow = Item.get("Arrow")
    t:eq(arrow._cls.recipe, nil, "the lookup handle declares no recipe, so a result is the game's")

    local r = arrow:recipeOf()
    if r == nil then
        -- Not a failure of the route: DT_ItemRecipeDataTable_Common has to be LOADED, and a
        -- save that has never opened a crafting bench may not have pulled it in. The
        -- [PalForge.recipes] line says which of the two it was.
        t:skipUnanswerable("no recipe came back for Arrow — either the recipe DataTable is not "
            .. "loaded in this session (open a crafting bench and run again; core/recipes says "
            .. "so once in the log) or the row is not there. The struct route itself is "
            .. "measured, so this is a question about the save, not about the read")
    end

    t:type(r, "table", "a vanilla id resolves to the game's recipe")
    t:type(r.count, "number", "Product_Count came off the row")
    t:eq(r.station, nil, "the game's row never fills station")
    t:type(r.materials, "table", "the materials map is always present")

    local mats = {}
    for id, n in pairs(r.materials) do
        t:type(id, "string", "a material id is a plain string, never an unconverted FName")
        t:type(n, "number")
        t:eq(id ~= "None" and #id > 0, true, "an empty material slot is never emitted")
        mats[#mats + 1] = string.format("%s x%s", id, tostring(n))
    end
    t:truthy(#mats > 0, "Arrow's recipe consumes something — Wood x2 when this was measured")
    support.log(string.format("recipes: Arrow -> %s x%s, work=%s, from { %s }",
        tostring(r.product), tostring(r.count), tostring(r.work), table.concat(mats, ", ")))
end)

return s
