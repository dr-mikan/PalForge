-- palforge/api/item.lua — PUBLIC item API + implementation (SELF-CONTAINED).
--
-- An item is a piece of inventory content: materials, consumables, equipment, ammo.
-- Same shape as every other api module (define / get / get_all + a Handle object with
-- actions and grouped `events`).
--
-- HOW IT INTEGRATES: Item.define registers the definition class in object_manager under
-- ("item", id). core/event's item source hooks the game's own calls and emits channels;
-- DISPATCH resolves the class by the game item id carried on the event and calls
-- cls:onXxx(ctx) with the class as self.
--
--   WIRED (live, confirmed native hooks — see core/event installItemSource):
--     onObtain  <- PalPlayerState:AddItemGetLog_ToClient   (ctx.itemId, ctx.count)
--     onUse     <- PalItemUseProcessor:UseItemToCharacter_ServerInternal (ctx.itemId, ctx.actor)
--   NOT WIRED YET (channel + dispatch exist, no native source found):
--     onCraft / onDiscard — nothing emits item.craft / item.discard, so these never fire.
--     They stay declarable so a pack's code is future-proof.
--
-- ACTIONS are real: :give / :take move the count through the game's own server path
-- (AddItem_ServerInternal, via utils.items) and :iconOf reads the live icon DataTable.
-- Publishing a BRAND-NEW item row into the game's data tables is NOT possible from Lua
-- alone (that is PalSchema's job) — define() gives an existing id behaviour, it does not
-- create inventory content.
--
--   Item.define{
--       id = "Berries", displayName = "Red Berries", category = "consumable",
--       events = { onUse = function(self, ctx) log.info(tostring(ctx.actor)) end },
--   }
--   Item.get("Wood"):give(10)

local om    = require("palforge.core.object_manager")
local icons = require("palforge.core.icons")
local items = require("palforge.utils.items")

--=============================================================================
-- TYPES (LuaLS annotations — editor intellisense only; zero runtime cost)
--=============================================================================

---A crafting recipe for the item that produces it.
---@class Item.Recipe
---@field materials table<string, integer>  # { <itemId> = <count> }
---@field count     integer?                # output count (default 1)
---@field work      number?                 # work amount
---@field station   string?                 # workbench / station id

---The lifecycle handlers an item can respond to. All optional. Each receives the item
---class as `self` and the event context `ctx`.
---@class Item.Events
---@field onObtain  fun(self: Item.Handle, ctx: table)  # LIVE — entered the inventory (ctx.count)
---@field onUse     fun(self: Item.Handle, ctx: table)  # LIVE — used / consumed (ctx.actor)
---@field onCraft   fun(self: Item.Handle, ctx: table)  # declarable; no native source yet
---@field onDiscard fun(self: Item.Handle, ctx: table)  # declarable; no native source yet

---What you pass to Item.define. `id` is required; everything else is optional.
---@class Item.Spec
---@field id          string        # item id: a game ItemId ("Wood") or "pack:name"
---@field displayName string?       # shown in UI (defaults to id)
---@field category    string?       # material | consumable | equipment | ammo | ...
---@field maxStack    integer?      # inventory stack ceiling
---@field icon        any?          # fallback icon when the DataTable lookup misses
---@field recipe      Item.Recipe?  # the recipe that produces THIS item
---@field events      Item.Events?  # lifecycle handlers (grouped)

--=============================================================================
-- the registered item DEFINITION class (what core/event dispatches to)
-- Defaults are inert; define{ events = {...} } overrides them per item.
--=============================================================================

local Class = {}
Class.__index = Class
Class.category = "material"
Class.maxStack = 1
Class.icon     = nil
Class.recipe   = nil

function Class:onObtain(ctx) end
function Class:onUse(ctx) end
function Class:onCraft(ctx) end
function Class:onDiscard(ctx) end

-- This item's recipe, or nil if it is not craftable. Override to build one dynamically.
function Class:recipeOf() return self.recipe end

-- The live inventory icon: look the id up in the item icon DataTable, falling back to
-- the declared self.icon on any miss.
function Class:iconOf()
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.item, self.id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — module functions
--=============================================================================

---@class palforge.item
local Item = {}

local wrap  -- forward decl; the Item.Handle wrapper is defined in the BOTTOM section

---Define an item (give an item id behaviour + metadata) and register it.
---@param spec Item.Spec
---@return Item.Handle
function Item.define(spec)
    assert(type(spec) == "table",
        "Item.define: pass a table, e.g. Item.define{ id = 'X', events = {...} }")
    assert(type(spec.id) == "string" and #spec.id > 0, "Item.define: spec.id (string) is required")
    local cls = setmetatable({
        id          = spec.id,
        displayName = spec.displayName or spec.id,
        category    = spec.category,
        maxStack    = spec.maxStack,
        icon        = spec.icon,
        recipe      = spec.recipe,
    }, Class)
    cls.__index = cls
    if type(spec.events) == "table" then
        for name, handler in pairs(spec.events) do cls[name] = handler end  -- onUse, ...
    end
    pcall(function() om.register("item", spec.id, cls) end)  -- so core/event + get() find it
    return wrap(cls)
end

---Get an EXISTING item by id: a previously-defined one, else a thin definition over any
---game ItemId (so vanilla items are actionable too). Never nil.
---@param id string
---@return Item.Handle
function Item.get(id)
    assert(type(id) == "string" and #id > 0, "Item.get: id (string) is required")
    local cls = om.get("item", id) or setmetatable({ id = id }, Class)
    return wrap(cls)
end

---Every PalForge-registered item, as a list of handles.
---@return Item.Handle[]
function Item.get_all()
    local out = {}
    for _, cls in pairs(om.all("item")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the item OBJECT (Item.Handle): actions + lifecycle events
--=============================================================================

---A definable item. Obtain one from Item.define / Item.get / Item.get_all.
---@class Item.Handle
---@field id string   # the item's game ItemId
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Add `count` of this item to the local player's inventory (default 1).
---@param count integer?
---@return boolean ok
function Handle:give(count) return items.give(self.id, count or 1) end

---Remove `count` of this item from the local player's inventory (default 1).
---@param count integer?
---@return boolean ok
function Handle:take(count) return items.take(self.id, count or 1) end

-- ---- lifecycle events (fired by core.event on the definition; forward for manual use) ----

---@param ctx table  # ctx.count = how many were obtained
function Handle:onObtain(ctx) if self._cls.onObtain then return self._cls:onObtain(ctx) end end
---@param ctx table  # ctx.actor = who used it
function Handle:onUse(ctx) if self._cls.onUse then return self._cls:onUse(ctx) end end
---@param ctx table
function Handle:onCraft(ctx) if self._cls.onCraft then return self._cls:onCraft(ctx) end end
---@param ctx table
function Handle:onDiscard(ctx) if self._cls.onDiscard then return self._cls:onDiscard(ctx) end end

-- ---- queries ----

---@return Item.Recipe?
function Handle:recipeOf() return self._cls:recipeOf() end
---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:displayName() return self._cls.displayName or self.id end
---@return string
function Handle:category() return self._cls.category or "material" end
---@return integer
function Handle:maxStack() return self._cls.maxStack or 1 end

Item.Class = Class   -- the base hook table (used for override detection / subclassing)
return Item
