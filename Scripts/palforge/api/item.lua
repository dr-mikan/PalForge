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
-- ACTIONS — read this before planning anything around :give or :take.
--   * :count WORKS and is measured. It reads the live inventory through the game's own
--     CountItemNum, observed in a loaded save answering 135 for Wood. nil means "could not
--     read", never "none".
--   * :give WORKS and is measured. It writes through the inventory's own
--     PalPlayerInventoryData:AddItem_ServerInternal and then reads the count back — true means
--     the count was seen to RISE, false means the inventory refused and said why (it answers a
--     named EPalItemOperationResult, which the log carries). Observed in a real save:
--     "give Wood x3: 140 -> 143", with the game's own pickup event firing beside it
--     ("Wood onObtain: count=3").
--   * :take DOES NOT WORK YET, and reports false rather than pretending. No removal route is
--     known on this build: the inventory's whole class chain declares nothing that subtracts an
--     item, and a NEGATIVE Count through the add — the standing hypothesis, now finally
--     testable — is accepted and does nothing at all. So a pack cannot charge a cost yet. See
--     TODO(item-remove-call) in utils/items for what has been eliminated and what is left.
--
-- WHAT THAT COST, since it shaped this file for a long time. The add was blocked on ONE
-- argument. The live declaration is five parameters and a return —
-- (FName StaticItemId, int32 Count, bool IsAssignPassive, float LogDelay, bool bNotifyLog) —
-- where dumps/cxx/Pal.hpp has four and no bNotifyLog at all, because the dump was generated one
-- game patch before the installed binary. UE4SS counts the return as a slot, which is where
-- "UFunction expected 6 parameters, received 4" came from. Reading the live declaration is what
-- core.signature is for, and it is why nothing here is called on a dump's word.
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
--   Item.get("Wood"):count()       -- what the inventory holds now (nil = could not read)
--   Item.get("Wood"):give(10)      -- true only if the count was seen to rise; see ACTIONS above
--   Item.get("Wood"):take(3)       -- drops them on the GROUND; true only if the count fell

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
    -- TODO(item-discard-source): unknown which UFunction reports a drop / discard / consume.
    -- Whatever UPalCheatManager:DropItem drives internally is now the first place to look —
    -- that is the call :take makes, so a hook that catches a drop would also catch PalForge's
    -- own removals — but nothing has been hooked or observed there yet.
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
-- That accessor is now the ONLY missing piece for both :iconOf and :recipeOf. Everything
-- around it is measured, in dumps/reflection/01_datatables.txt, from a real session:
--   * the tables are loaded — DT_ItemIconDataTable (1207 rows) and
--     DT_ItemRecipeDataTable_Common (1414 rows on disk), both under /Game/Pal/DataTable/Item/;
--   * the row keys are the item ids ("Stone", "Wood", ...);
--   * the columns are no longer a guess. The icon column is `Icon` — NOT the IconName /
--     SoftIcon this comment used to claim, neither of which is a column of that table (see
--     core/icons ICON_COLUMNS_BY_TABLE). The recipe row struct carries Product_Id,
--     Product_Count, Material1_Id..Material5_Id, Material1_Count..Material5_Count, WorkAmount,
--     CraftExpRate, EnergyType, EnergyAmount, UnlockItemID, WorkableAttribute, DenyRecipeChain.
-- What the 2026-07 dumps cannot settle: the accessor itself. 02_reflection.txt covers 21
-- /Script/Pal.* classes only, so UDataTable / UDataTableFunctionLibrary are absent from it.
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

---Add `count` of this item to the local player's inventory (default 1) through the game's own
---UPalCheatManager:GetItem(FName StaticItemId, int32 Count), and MEASURE the outcome.
---
---`ok` is the measurement, never the call: CountItemNum is read before and after, and true means
---the count was seen to RISE. false means the cheat manager was missing (needs
---CheatManagerEnabler), the live declaration did not match so the call was refused outright, the
---count could not be read afterwards (UNKNOWN is never reported as success), or the count simply
---did not move — an item id the game does not know and a full inventory both execute happily and
---add nothing. Every outcome logs a line naming the item, the count and the evidence level.
---⚠️ NOT YET OBSERVED IN GAME: the signature is UE4SS's CXXHeaderDump of this install
---(dumps/cxx/Pal.hpp:16398), checked against the live class by core.signature, and the cheat
---manager is the object PalForge already unlocks technologies through here — but no run has
---exercised GetItem yet. See utils.items.give.
---@param count integer?
---@return boolean ok  # true only when the inventory count was measured to rise
function Handle:give(count) return items.give(self.id, count or 1) end

---Remove `count` of this item from the local player's inventory (default 1) through the game's
---own UPalCheatManager:DropItem(const FName StaticItemId, const int32 Num), measured the same
---way as :give — true only when the count was seen to FALL.
---
---⚠️ THE ITEMS ARE DROPPED, NOT DESTROYED. They leave the inventory and land on the ground at the
---player's feet, where anyone can pick them back up. The inventory really did lose them, which is
---what :take means, but plan for the pile: a pack that charges a price this way leaves the price
---lying on the floor. Nothing on this build deletes an item instead — the inventory's whole class
---chain declares no remove/consume/discard function at all (utils.items.take,
---TODO(item-remove-call)).
---The request is clamped to what the inventory actually holds, and skipped when it holds none.
---⚠️ NOT YET OBSERVED IN GAME either (dumps/cxx/Pal.hpp:16453; same route, same caveat as :give).
---@param count integer?
---@return boolean ok  # true only when the inventory count was measured to fall
function Handle:take(count) return items.take(self.id, count or 1) end

---WORKS, and is measured. How many of this item the local player is holding right now, or nil
---when the count could not be read (no world / no player — nil is UNKNOWN, never zero). It
---goes through the game's own CountItemNum, which was observed in a loaded save handing Lua a
---plain number (135 Wood). It is the only item action on this build proven end to end, and it
---is also what :give and :take rest on: their verdicts are this read, taken twice.
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
