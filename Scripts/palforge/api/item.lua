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
--   WIRED (live, confirmed native hooks — see core/event installItemSource). All four fire.
--   This list used to carry a "NOT WIRED YET" section naming onCraft and onDiscard as having
--   no native source; both were closed on 2026-07-26 and are described in full below:
--     onObtain  <- PalPlayerState:AddItemGetLog_ToClient, plus the inventory add path
--                  (ctx.itemId, ctx.count, ctx.via = "getlog" | "additem")
--     onUse     <- PalItemUseProcessor:UseItemToCharacter_ServerInternal
--                  (ctx.itemId; ctx.actor = the LOCAL player pawn — the character who used
--                   the item, which is the one used ON only for self-use; ctx.itemData and
--                   ctx.targetId carry the raw params)
--     onCraft   <- PalMapObjectConvertItemModel / PalMapObjectProductItemModel:
--                  OnFinishWorkInServer (ctx.itemId, ctx.recipeId, ctx.via = "convert" |
--                  "product"). Closed as item-craft-source: crafting at a real machine was
--                  seen carrying the channel's first event. ctx.count is nil BY DESIGN — the
--                  per-craft count lives in the recipe row and a hook is no place for a
--                  DataTable read.
--     onDiscard <- PalNetworkItemComponent:RequestDrop_ToServer / RequestDispose_ToServer
--                  (ctx.itemId, ctx.count, ctx.reason = "drop" | "dispose"). Closed as
--                  item-discard-source, observed live; the source is core/event.lua:1955-2114.
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
--   * :take WORKS and is measured the same way — true only when the count was seen to FALL.
--     Observed in the same press that proved :give: "take Wood x3: 164 -> 161". The items are
--     CONSUMED, not dropped, so nothing is left at the player's feet to walk back over — which
--     is what makes charging a cost possible at all. The route is the game's own consume,
--     APalWeaponBase:RequestConsumeItem, reached through the player's loadout component.
--     ONE CONSTRAINT: the consume is a method ON a weapon actor, so a player carrying nothing
--     has no route and this reports false saying so. Equipping anything is enough — the weapon
--     need only be spawned, not in hand, and it spends the id it is HANDED rather than its own
--     ammunition. The inventory itself has no removal at all: its whole class chain declares
--     nothing that subtracts, and a NEGATIVE Count through the add was measured accepted and
--     inert (161 -> 161).
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
--   * :iconOf goes to the live icon DataTable through core.icons AND THE READ WORKS: on
--     2026-07-26 core/icons read DT_ItemIconDataTable in a live save and 1183 of its 1207
--     rows handed back an icon path (icons-row-read, Closed). So a vanilla item id answers
--     with the game's own artwork and the declared `icon` really is the fallback it was
--     always described as. :recipeOf is the half that is still declarative — see its marker.
--
--   Item{
--       id = "Berries", name = "Red Berries", category = "consumable",
--       events = {
--           onUse = function(item, ctx) log.info(tostring(ctx.actor)) end,
--       },
--   }
--   Item.get("Wood"):count()       -- what the inventory holds now (nil = could not read)
--   Item.get("Wood"):give(10)      -- true only if the count was seen to rise; see ACTIONS above
--   Item.get("Wood"):take(3)       -- consumes them; true only if the count was seen to fall

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
    -- OBSERVED LIVE, 2026-07-26, and closed as item-craft-source. Crafting at a real machine
    -- fires this: core/event hooks OnFinishWorkInServer on the two work models that carry an
    -- item id — PalMapObjectConvertItemModel (the recipe benches and furnaces) and
    -- PalMapObjectProductItemModel (the fixed-output producers) — and the channel was seen
    -- carrying its first event in a real save. The doc string below still read "(unverified in
    -- game)" when the 2026-07-31 audit went through, which is worse than saying nothing: it is
    -- what an author reads out of schema.help("Item.Spec.Events") and out of the generated
    -- types.lua tooltip, and it talks people out of a channel that works.
    -- `ctx.count` is nil BY DESIGN and stays nil: the per-craft count lives in the recipe row
    -- (DT_ItemRecipeDataTable's Product_Count) and a hook is no place for a DataTable read.
    { "onCraft",   type = "function", sig = "fun(self: Item.Handle, ctx: table)",
                   doc = "LIVE - a crafting machine finished it (ctx.recipeId, ctx.via; ctx.count is nil)" },
    -- OBSERVED LIVE, 2026-07-26, with the slot resolving to a real item id, and closed as
    -- item-discard-source. The source is core/event.lua:1955-2114 (the hooks themselves at :2106 and :2112). Two things had to be right. A
    -- drop does NOT go through AddItem_ServerInternal — that hook was armed and fired zero
    -- times across two sessions, because dropping goes through UPalNetworkItemComponent, one
    -- class over from everywhere the search had looked. And the container holding the dropped
    -- slot is not necessarily one of the inventory helper's, so the container set comes from a
    -- world sweep matched on an exact GUID.
    -- The doc string below still said "NO native source exists" at the 2026-07-31 audit, five
    -- days after the firing, and this is the one place a pack author looks: it is what
    -- schema.help("Item.Spec.Events") prints and what types.lua shows in the editor.
    -- ONE HONEST LIMIT: a drop whose slot cannot be resolved to an item id emits NOTHING
    -- rather than an event with a guessed id, and core/event says so once per distinct reason.
    { "onDiscard", type = "function", sig = "fun(self: Item.Handle, ctx: table)",
                   doc = "LIVE - dropped or trashed (ctx.count, ctx.reason = \"drop\" | \"dispose\")" },
})

---What you pass to Item{ ... }. `id` is the only required field.
-- `id` carries schema.validId, not schema.nonEmpty: a namespaced id has to survive
-- object_manager.resolve to reach the game at all ("pack:Potion" -> the row spelling
-- "pack_Potion"), so an id that cannot — "my-pack:Potion", a hyphen — is refused HERE rather
-- than registering and being silently inert. The rule is written once, in core/schema.lua.
local Spec = schema.define("Item.Spec", {
    { "id",          type = "string", required = true, check = schema.validId,
                     doc = "item id: a game ItemId (\"Wood\") or \"pack:name\"" },
    { "name",        type = "string",
                     doc = "display name for YOUR ui/tooling; not the in-game name (defaults to id)" },
    { "description", type = "string", doc = "one-line description, for UI and tooling" },
    { "category",    type = "string", default = "material",
                     values = { "material", "consumable", "equipment", "ammo", "ingredient", "other" },
                     doc = "what kind of inventory content this is (PalForge's own classification)" },
    { "maxStack",    type = "number", default = 1,
                     doc = "stack ceiling you declare; the GAME's ceiling is a DataTable column" },
    -- ONE KIND OF THING, declared. `icon` used to carry no `type =` at all, while the live
    -- lookup beside it answers a /Game/... asset PATH as a plain string (core/icons reads the
    -- icon column as text — the TSoftObjectPtr in the row cannot be unwrapped from Lua, so
    -- the string is not a convenience, it is the only value that route can produce). An
    -- accessor that returns "a string path, or whatever you happened to declare" is one every
    -- caller has to branch on, and native/ui/tree.lua does exactly that today. So the
    -- declared fallback is a string path too, and :iconOf answers string|nil, always.
    { "icon",        type = "string",
                     doc = "/Game/... texture path used when the icon DataTable has no row for this id" },
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
-- DT_ItemRecipeDataTable_Common has a row for it. That is now the ONLY half of
-- item-datatable-row-read still open — see the marker on :iconOf, which no longer waits on
-- anything itself.
function Class:recipeOf() return self.recipe end

-- The inventory icon, and THE ROW READ WORKS. This comment used to say that reading a
-- DataTable row "has never been observed to work from Lua on this build"; that was true when
-- it was written and stopped being true on 2026-07-26, when icons-row-read read
-- DT_ItemIconDataTable in a live save and 1183 of its 1207 rows handed back an icon path
-- (the other 24 are rows that genuinely carry none). So a vanilla item id resolves to the
-- game's own artwork here and self.icon is the fallback it was always described as.
--
-- HOW it is read, because two obvious routes are dead ends and core/icons.lua:284-345 carries
-- the full write-up: the row accessors are NOT UFunctions and not on UDataTable — UE4SS binds
-- FindRow / GetRowNames / GetRowMap / GetAllRows / ForEachRow onto UDataTable itself, which is
-- why every reflection sweep missed them (dumps/cxx/Engine.hpp shows UDataTable declaring five
-- properties and ZERO functions). FindRow then works and the measured column IS on the row —
-- but its value is a TSoftObjectPtr userdata that answers none of the nineteen member names a
-- soft pointer could plausibly expose, so the struct cannot be opened from Lua. What is read
-- instead is the whole column as text, via UDataTableFunctionLibrary::GetDataTableColumnAsString,
-- zipped against dt:GetRowNames() — two calls per table, cached.
--
-- TODO(item-datatable-row-read): THE RECIPE HALF ONLY. :recipeOf still answers the declared
-- recipe and never the game's, and what is unknown is no longer the accessor — it is whether a
-- scalar / FName column can be indexed off the struct FindRow hands back. That was never tried:
-- the TSoftObjectPtr failure that forced the column detour does not apply to an int32 or an
-- FName. If the struct route stays shut, a recipe is assembled the way icons are, with one
-- GetDataTableColumnAsString call per column — thirteen calls per table, once, cached, which is
-- perfectly affordable. Everything around it is measured (dumps/reflection/01_datatables.txt,
-- a real session): DT_ItemRecipeDataTable_Common is loaded under /Game/Pal/DataTable/Item/ with
-- 1414 rows, the row keys are the item ids, and the row struct carries Product_Id,
-- Product_Count, Material1_Id..Material5_Id, Material1_Count..Material5_Count, WorkAmount,
-- CraftExpRate, EnergyType, EnergyAmount, UnlockItemID, WorkableAttribute, DenyRecipeChain.
--
-- THE ID IS RESOLVED FIRST (F-3/C5). The live table is keyed by the row spelling PalSchema
-- writes, so `Item{ id = "pack:Potion" }:iconOf()` has to ask for "pack_Potion"; handing
-- icons.resolve the raw "pack:Potion" could never hit a row, and every namespaced item silently
-- looked like an item whose icon simply was not in the table. `or self.id` is the rule at every
-- engine boundary: an id that fails to resolve falls back to the LITERAL, never to nothing.
function Class:iconOf()
    local id = om.resolve(self.id) or self.id
    local ok, tex = pcall(function() return icons.resolve(icons.TABLES.item, id) end)
    if ok and tex ~= nil then return tex end
    return self.icon
end

--=============================================================================
-- TOP — the module surface: Item{ ... } / Item.get / Item.get_all
--=============================================================================

---The item domain. CALL it to define an item; the two named functions look existing ones up.
---@class palforge.item
---@overload fun(spec: Item.Spec, opts: table?): Item.Handle
local Item = {}

local wrap  -- forward decl; the Item.Handle wrapper is defined in the BOTTOM section

---Define an item (give an item id behaviour + metadata) and register it.
---`spec` is validated against Item.Spec: `id` is required, unknown fields are an error.
---
---`opts` is optional and omitting it behaves exactly as it always has:
---  { register = false }   build and return the handle, register NOTHING. This is what a
---                         native catalog uses to fabricate a definition for a READ, so that
---                         reading `native.items.Wood` stops writing to the registry.
---  { pack = "mypack" }    register attributed to that pack, which is what gives a collision
---                         a "who" (see object_manager.register). PalForge.pack("mypack").Item
---                         is the same thing without passing it per call.
---@param spec Item.Spec
---@param opts table?
---@return Item.Handle
local function define(spec, opts)
    local register, pack = schema.defineOpts(opts, "Item")
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
    -- so core/event + get() find it — unless the caller asked for a definition that stays out
    -- of the registry (opts.register == false), which is a build, not a define.
    if register then
        pcall(function() om.register("item", spec.id, cls, { pack = pack }) end)
    end
    return handle
end

-- Calling the module IS defining:  Item{ id = "Berries", ... }
setmetatable(Item, { __call = function(_, spec, opts) return define(spec, opts) end })

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

---WORKS, and is measured. Add `count` of this item to the local player's inventory (default 1)
---through the inventory's OWN write, PalPlayerInventoryData:AddItem_ServerInternal.
---
---`ok` is the measurement, never the call: CountItemNum is read before and after, and true means
---the count was seen to RISE. false means the inventory could not be reached, the live declaration
---did not match so the call was refused outright, the inventory REFUSED and named its reason (it
---answers a named EPalItemOperationResult, which the log carries), the count could not be read
---afterwards (UNKNOWN is never reported as success), or the count did not move. Every outcome logs
---a line naming the item, the count and the evidence level.
---Observed in a real save: "give Wood x3: 140 -> 143", with the game's own pickup event firing
---alongside it. See utils.items.give.
---@param count integer?
---@return boolean ok  # true only when the inventory count was measured to rise
function Handle:give(count) return items.give(self.id, count or 1) end

---Remove `count` of this item from the local player's inventory (default 1) through the game's own
---APalWeaponBase:RequestConsumeItem(const FName& StaticItemId, int32 ConsumeNum), measured the
---same way as :give — true only when the count was seen to FALL.
---
---The items are CONSUMED, not dropped: nothing lands at the player's feet for them to walk back
---over, which is what makes charging a cost possible at all. The request is clamped to what the
---inventory actually holds, and skipped when it holds none.
---⚠️ ONE CONSTRAINT. The consume is a method on a WEAPON ACTOR (it is the path a throw weapon
---takes when it spends what it threw), reached through the player's own loadout component — so a
---player carrying nothing has no route and this reports false saying exactly that. Equipping
---anything is enough: the weapon need only be spawned, not in hand.
---
---Observed working, in the same press that proved :give — "take Wood x3: 164 -> 161" — which
---also settles that it spends the id it is HANDED rather than the weapon's own ammunition.
---The inventory itself cannot subtract: see utils.items.take for the whole eliminated list,
---including the negative-Count hypothesis that was finally measured dead.
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
---The icon as a /Game/... asset path: the live DataTable's row for this id, else the declared
---`icon`, else nil. One kind of value, never an engine object — see the Item.Spec `icon` note.
---@return string?
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
