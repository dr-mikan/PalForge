-- palforge/api/item.lua — PUBLIC item API + implementation (SELF-CONTAINED).
--
-- An item is a piece of inventory content: materials, consumables, equipment, ammo.
-- Same shape as every other api module (call it to define, plus get / get_all + a Handle
-- object with actions and grouped `events`).
--
-- HOW IT INTEGRATES: Item{ ... } registers the definition class in object_manager under
-- ("item", id). core/event's item source hooks the game's own calls and emits channels;
-- DISPATCH resolves the class by the game item id carried on the event and calls
-- cls:onXxx(ctx) with the class as self.
--
--   WIRED (live, confirmed native hooks — see core/event installItemSource):
--     onObtain  <- PalPlayerState:AddItemGetLog_ToClient, plus the inventory add path
--                  (ctx.itemId, ctx.count, ctx.via = "getlog" | "additem")
--     onUse     <- PalItemUseProcessor:UseItemToCharacter_ServerInternal
--                  (ctx.itemId; ctx.actor = the LOCAL player pawn — the character who used
--                   the item, which is the one used ON only for self-use; ctx.itemData and
--                   ctx.targetId carry the raw params)
--   NOT WIRED YET (channel + dispatch exist, no native source found):
--     onCraft / onDiscard — nothing emits item.craft / item.discard, so these never fire.
--     They stay declarable so a pack's code is future-proof.
--
-- ACTIONS: :give moves the count through the game's own server path (AddItem_ServerInternal,
-- via utils.items) and is the best-proven call in the tree; it now reads the inventory count
-- back, so a bogus id or a full inventory answers false instead of pretending. :take is NOT
-- its equal — no removal call has ever been confirmed on this build, so it pushes a negative
-- delta through that same add call and then re-reads the count, returning whether anything
-- actually left (see utils.items.take).
--
-- WHAT IS DECLARATIVE, NOT LIVE — read this before believing a field did something:
--   * name / description / category / maxStack / recipe are metadata PalForge stores and
--     hands back through the queries below. They are NOT written to the game: an item's real
--     stack size, its real recipe and its very existence live in DT_ItemDataTable /
--     DT_ItemRecipeDataTable rows, which Lua cannot author — that is PalSchema's job (see
--     PalSmith/packs/ExamplePack/items/example_items.jsonc, where MaxStackCount and the
--     Recipe block are declared as JSON). Defining gives an EXISTING item id behaviour; it
--     does not create inventory content and it does not re-balance it.
--   * :iconOf goes to the live icon DataTable through core.icons, but no artifact in this
--     tree has ever read a DataTable row VALUE, so in practice it returns the icon you
--     declared. See the marker on Class:iconOf.
--
--   Item{
--       id = "Berries", name = "Red Berries", category = "consumable",
--       events = {
--           onUse = function(item, ctx) log.info(tostring(ctx.actor)) end,
--       },
--   }
--   Item.get("Wood"):give(10)      -- false if nothing landed
--   Item.get("Wood"):count()       -- what the inventory holds now (nil = could not read)

local om     = require("palforge.core.object_manager")
local icons  = require("palforge.core.icons")
local items  = require("palforge.utils.items")
local schema = require("palforge.core.schema")

--=============================================================================
-- SPEC — the shape of Item{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("Item.Spec")         -- every field, its type, default and meaning
--   schema.get("Item.Spec").fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
--=============================================================================

---A crafting recipe, declared on the item it produces. AUTHOR METADATA: PalForge stores it
---and hands it back from :recipeOf, and nothing else in the framework reads it. A recipe the
---game will actually run is a DT_ItemRecipeDataTable row (columns Product_Count / WorkAmount
---/ MaterialN_Id / MaterialN_Count — the shape these fields mirror), and Lua cannot author a
---DataTable row; declare it as PalSchema JSON and use this to describe the same thing to your
---own code and tooling.
local Recipe = schema.define("Item.Spec.Recipe", {
    { "materials", type = "table", mapOf = "number", required = true,
                   doc = "{ <itemId> = <count> } consumed by one craft" },
    { "count",     type = "number", default = 1, doc = "how many of this item one craft yields" },
    { "work",      type = "number", doc = "work amount the station must put in" },
    { "station",   type = "string", doc = "workbench / station id that can craft it" },
})

---The lifecycle handlers an item can respond to. All optional. Each receives THIS item's
---handle as its first argument and the event context `ctx`. An event this list does not
---name is a hard error, not a silent no-op.
local Events = schema.define("Item.Spec.Events", {
    { "onObtain",  type = "function", sig = "fun(self: Item.Handle, ctx: table)",
                   doc = "LIVE - entered the inventory (ctx.count, ctx.via)" },
    { "onUse",     type = "function", sig = "fun(self: Item.Handle, ctx: table)",
                   doc = "LIVE - used / consumed (ctx.actor = the local player pawn)" },
    -- TODO(item-craft-source): unknown which UFunction reports a craft COMPLETING and which
    -- of its params carries the produced item id + count. Until one is observed this only
    -- fires from a manual event.emit("item.craft", ...).
    { "onCraft",   type = "function", sig = "fun(self: Item.Handle, ctx: table)",
                   doc = "declarable; NO native source exists — fires only on a manual emit" },
    -- TODO(item-discard-source): unknown which UFunction reports a drop / discard / consume,
    -- and whether it is just AddItem_ServerInternal with a negative Count.
    { "onDiscard", type = "function", sig = "fun(self: Item.Handle, ctx: table)",
                   doc = "declarable; NO native source exists — fires only on a manual emit" },
})

---What you pass to Item{ ... }. `id` is the only required field.
local Spec = schema.define("Item.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "item id: a game ItemId (\"Wood\") or \"pack:name\"" },
    { "name",        type = "string",
                     doc = "display name for YOUR ui/tooling; not the in-game name (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "category",    type = "string", default = "material",
                     values = { "material", "consumable", "equipment", "ammo", "ingredient", "other" },
                     doc = "what kind of inventory content this is (PalForge's own classification)" },
    { "maxStack",    type = "number", default = 1,
                     doc = "stack ceiling you declare; the GAME's ceiling is a DataTable column" },
    { "icon",        doc = "fallback icon used when the DataTable lookup misses" },
    { "recipe",      type = "table", of = Recipe,
                     doc = "the recipe that produces THIS item (metadata; see Item.Spec.Recipe)" },
    { "events",      type = "table", of = Events, doc = "lifecycle handlers (grouped)" },
    { "data",        type = "table", doc = "free-form payload of your own, carried onto the definition" },
})

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

-- This item's DECLARED recipe, or nil when none was declared. Override to build one
-- dynamically. It never reads the game: a vanilla id answers nil even though
-- DT_ItemRecipeDataTable_Common has a row for it, because reading a row VALUE is the same
-- unsolved capability :iconOf is waiting on (see the marker there).
function Class:recipeOf() return self.recipe end

-- The inventory icon. core.icons finds the live DT_ItemIconDataTable for real (the
-- FindAllOf sweep that dumped the 390-table catalog), but the last step — reading the row —
-- has never been observed to work from Lua on this build, so this falls back to the declared
-- self.icon and that is what you get in practice.
-- TODO(item-datatable-row-read): unknown which row-VALUE accessor a UDataTable exposes to
-- UE4SS Lua here (GetDataTableRowFromName / FindRow / something else) and what it hands back.
-- Settling it turns both :iconOf and :recipeOf into live reads; nothing else is missing —
-- the tables are found, the row keys are the item ids, and the columns are known
-- (IconName/SoftIcon for icons, Product_Count/WorkAmount/MaterialN_Id for recipes).
function Class:iconOf()
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.item, self.id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — the module surface: Item{ ... } / Item.get / Item.get_all
--=============================================================================

---The item domain. CALL it to define an item; the two named functions look existing ones up.
---@class palforge.item
---@overload fun(spec: Item.Spec): Item.Handle
local Item = {}

local wrap  -- forward decl; the Item.Handle wrapper is defined in the BOTTOM section

---Define an item (give an item id behaviour + metadata) and register it.
---`spec` is validated against Item.Spec: `id` is required, unknown fields are an error.
---@param spec Item.Spec
---@return Item.Handle
local function define(spec)
    spec = Spec:validate(spec, "Item")
    local cls = setmetatable({
        id          = spec.id,
        name        = spec.name or spec.id,
        description = spec.description,
        category    = spec.category,
        maxStack    = spec.maxStack,
        icon        = spec.icon,
        recipe      = spec.recipe,
        data        = spec.data,
    }, Class)
    cls.__index = cls
    local handle = wrap(cls)
    -- dispatch calls cls:onXxx(...) with the CLASS as self; a handler wants the HANDLE
    -- (what the call returned, and what carries :give), so each declared handler goes in
    -- behind a forwarder that swaps it in.
    for name, handler in pairs(spec.events or {}) do           -- onUse, ...
        cls[name] = function(_, ...) return handler(handle, ...) end
    end
    pcall(function() om.register("item", spec.id, cls) end)  -- so core/event + get() find it
    return handle
end

-- Calling the module IS defining:  Item{ id = "Berries", ... }
setmetatable(Item, { __call = function(_, spec) return define(spec) end })

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

---A definable item. Obtain one from Item{ ... } / Item.get / Item.get_all.
---@class Item.Handle
---@field id string   # the item's game ItemId
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions ----

---Add `count` of this item to the local player's inventory (default 1). Goes through the
---game's own AddItem_ServerInternal and then reads the inventory count back, so `ok` is
---false when nothing landed — an id the item table does not know, or no room. (A build that
---will not hand back a count answers true and logs that the add is unverified.)
---@param count integer?
---@return boolean ok  # true when the count was seen to rise, or could not be read at all
function Handle:give(count) return items.give(self.id, count or 1) end

---TRY to remove `count` of this item from the local player's inventory (default 1).
---Removal is UNCONFIRMED: no removal call is known on this build, so this pushes a
---negative delta through the same AddItem_ServerInternal that :give uses and then reads
---the inventory count back. `ok` is true only when that count was seen to fall — false
---means nothing observably left the inventory (see utils.items.take).
---@param count integer?
---@return boolean ok  # true only when the inventory count actually dropped
function Handle:take(count) return items.take(self.id, count or 1) end

---How many of this item the local player is holding right now, or nil when the count cannot
---be read (no world, or CountItemNum unbound — nil is UNKNOWN, never zero). This is the same
---measurement :give and :take report their outcome from.
---@return integer?
function Handle:count() return items.count(self.id) end

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

---@return Item.Spec.Recipe?
function Handle:recipeOf() return self._cls:recipeOf() end
---@return any?  # texture ref from the icon DataTable, else the declared icon
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end
---@return string
function Handle:category() return self._cls.category or "material" end
---@return integer
function Handle:maxStack() return self._cls.maxStack or 1 end

Item.Class = Class   -- the base hook table (used for override detection / subclassing)
return Item
