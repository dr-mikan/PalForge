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
-- FOOD AND MEDICINE — `restores`, the one field on this spec that WRITES TO A CHARACTER.
--   Item{ id = "Berries", restores = { satiety = 20 } }
--   Item{ id = "pack:Bandage", restores = { hpRate = 0.25 } }   -- a quarter of maximum HP
-- When that item is USED, PalForge writes the vitals on the character carried by the item.use
-- channel (ctx.actor, the local player pawn). Both writes were measured landing on a live
-- character on 2026-08-02 by the hook item-satiety-write — satiety 31.648 -> 21.648 through
-- SetFullStomach, health through AddHPByRate(float) — and core/character.lua's vitals section
-- carries the whole measurement. Two things a pack author has to know, and both are in the
-- field's own doc string so schema.help("Item.Spec") says them too:
--   * IT IS ADDITIVE, NEVER A REPLACEMENT. item.use is a hook on the game's OWN consume
--     (UPalItemUseProcessor:UseItemToCharacter_ServerInternal) — a call PalForge watches rather
--     than makes — so a vanilla food id still restores whatever the game restores, and this
--     field is added on top of it. Declare it on a vanilla consumable only if you mean "and
--     also".
--   * HP IS A RATE, NOT POINTS, because every absolute HP write on this build takes
--     FFixedPoint64, a struct UE4SS cannot marshal from Lua. `restores = { hp = 50 }` is
--     REFUSED at define time with that measurement in the message rather than accepted and
--     quietly ignored.
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
--   * `restores` IS LIVE, and it is the only field on this spec that is: it writes satiety and
--     health onto the character an item was used on, through core/character. Everything below
--     is the declarative half.
--   * name / description / category / maxStack / recipe are metadata PalForge stores and
--     hands back through the queries below (`recipe` is stored AND, when you declare none, the
--     game's own row is read for you — see :recipeOf). They are NOT written to the game in
--     either direction, and that is what this bullet is about: an item's real
--     stack size, its real recipe and its very existence live in DT_ItemDataTable /
--     DT_ItemRecipeDataTable rows, which Lua cannot author — that is PalSchema's job (see
--     PalSmith/packs/ExamplePack/items/example_items.jsonc, where MaxStackCount and the
--     Recipe block are declared as JSON). Defining gives an EXISTING item id behaviour; it
--     does not create inventory content and it does not re-balance it.
--   * :iconOf goes to the live icon DataTable through core.icons AND THE READ WORKS: on
--     2026-07-26 core/icons read DT_ItemIconDataTable in a live save and 1183 of its 1207
--     rows handed back an icon path (icons-row-read, Closed). So a vanilla item id answers
--     with the game's own artwork and the declared `icon` really is the fallback it was
--     always described as.
--   * :recipeOf ALSO reaches the game now, through core.recipes, and this bullet used to say
--     it was "the half that is still declarative". On 2026-08-02 the hook
--     item-datatable-row-read read DT_ItemRecipeDataTable_Common's 'Arrow' row off the struct
--     dt:FindRow hands back — Product_Count=10, WorkAmount=1000.0, Material1_Id=Wood(FName),
--     Material1_Count=2, all four by name, 2 pass / 0 fail. THE PRECEDENCE IS THE OPPOSITE OF
--     :iconOf's, on purpose; the two fields' own doc strings say so and :recipeOf explains why.
--     What is still declarative-only, and is not a defect: defining an item does not CREATE the
--     row. A recipe the game will run is authored as PalSchema JSON.
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

local om        = require("palforge.core.object_manager")
local icons     = require("palforge.core.icons")
local recipes   = require("palforge.core.recipes")
local items     = require("palforge.utils.items")
local schema    = require("palforge.core.schema")
-- The engine boundary for `restores`. core/character owns the two vitals writes and their
-- read-backs; this file owns the DECLARATION and the channel it is applied from. core.event is
-- NOT required here — it is required lazily, on the first define that declares a restore, for
-- the load-order reason api/effect.lua's ensureDriver spells out (core.event requires
-- api.building, so requiring it at the top of an api module builds a cycle).
local character = require("palforge.core.character")
local log       = require("palforge.utils.log").scope("item")
-- WHAT THIS PACK MADE THE GAME WRITE. :give is one of the three calls in the whole framework
-- that puts a name into PALWORLD'S save rather than into PalForge's own sidecar, so a
-- successful, pack-owned give is recorded in core/ledger. This file does NOT require that
-- module: the record is written by utils.items.give, at the engine boundary, so that every
-- caller of the public toolbox is covered and not only this one. Fail-soft either way — a
-- ledger append never raises and never changes what :give returns.

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

---A crafting recipe. THIS IS ALSO WHAT :recipeOf HANDS BACK WHEN IT READS THE GAME'S OWN ROW,
---which is why the shape is declared once and used both ways: an accessor that answered "the
---table you declared, or some other shape from the DataTable" would make every caller branch
---on where the answer came from, and the `icon` field's note records what that costs.
---
---Declaring one is AUTHOR METADATA: PalForge stores it, hands it back, and writes nothing to
---the game — Lua cannot author a DataTable row, so a recipe the game will actually RUN is
---declared as PalSchema JSON (PalSmith/packs/ExamplePack/items/example_items.jsonc). What
---changed on 2026-08-02 is the READ: with nothing declared, :recipeOf now answers the live
---DT_ItemRecipeDataTable_Common row for the id, mapped onto these same fields
---(Product_Id -> product, Product_Count -> count, WorkAmount -> work,
---MaterialN_Id/_Count -> materials). `station` is never filled from the game: the row carries
---WorkableAttribute, an enum of what KIND of station can run it, and no station id at all.
local Recipe = schema.define("Item.Spec.Recipe", {
    { "materials", type = "table", mapOf = "number", required = true,
                   doc = "{ <itemId> = <count> } consumed by one craft" },
    { "count",     type = "number", default = 1, doc = "how many of this item one craft yields" },
    { "work",      type = "number", doc = "work amount the station must put in" },
    { "station",   type = "string", doc = "workbench / station id that can craft it" },
    { "product",   type = "string",
                   doc = "item id one craft yields (defaults to the item it is declared on)" },
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

-- A number that is really a number: NaN and the infinities pass `type(v) == "number"` and are
-- exactly what a caller reaches by dividing two configuration values, so they are refused here
-- rather than pushed at a live character as a float.
local function finite(v)
    if v ~= v then return false, "must be a number, and NaN is not one" end
    if v == math.huge or v == -math.huge then return false, "must be a finite number" end
    return true
end

local function satietyAmount(v)
    local ok, why = finite(v)
    if not ok then return false, why end
    if v == 0 then
        return false, "0 restores nothing. Leave the field out rather than declaring a restore "
            .. "that cannot move the bar"
    end
    return true
end

local function hpRateAmount(v)
    local ok, why = finite(v)
    if not ok then return false, why end
    if v == 0 then
        return false, "0 heals nothing. Leave the field out rather than declaring a heal that "
            .. "cannot move the bar"
    end
    if v < -1 or v > 1 then
        return false, string.format("%s is not a rate. hpRate is a FRACTION of the character's "
            .. "maximum HP — 0.25 is a quarter of full health, 1 is a full heal, -0.1 takes a "
            .. "tenth off — because UPalCharacterParameterComponent::AddHPByRate(float) "
            .. "(Pal.hpp:16016) is the only HP write on this build that does not take the "
            .. "FFixedPoint64 struct (measured 2026-08-02, hook item-satiety-write)", tostring(v))
    end
    return true
end

-- THE REFUSAL, at define time, with the measurement in it. `hp` is declared as a field for one
-- reason: so that an author who writes the obvious thing gets this sentence while they are
-- writing it, instead of an "unknown field" that names no cause. It can never validate.
local function noAbsoluteHP()
    return false, "an absolute HP amount cannot be written on this build, so PalForge will not "
        .. "accept a declaration that promises one. Every absolute HP write takes FFixedPoint64, "
        .. "a STRUCT — UPalCharacterParameterComponent::SetHP (Pal.hpp:15933) and ::AddHP "
        .. "(:16018), UPalIndividualCharacterParameter::AddHP (:21156) — and a struct argument "
        .. "faults inside UE4SS's own marshalling where pcall cannot see it. Declare hpRate "
        .. "instead: a fraction of maximum HP through AddHPByRate(float), which was measured "
        .. "landing on a live character on 2026-08-02 (hook item-satiety-write)"
end

---WHAT USING THIS ITEM RESTORES — the live half of Item.Spec, and the two vitals this build was
---measured writing (2026-08-02, hook item-satiety-write, on a live character):
---
---    restores = { satiety = 20 }        -- 20 points of the satiety bar
---    restores = { hpRate = 0.25 }       -- a quarter of maximum HP
---    restores = { satiety = 20, hpRate = 0.25 }   -- both; each is measured separately
---
---ADDITIVE, NEVER A REPLACEMENT. PalForge does not perform the eating: item.use is a hook on the
---game's own UPalItemUseProcessor:UseItemToCharacter_ServerInternal, so a vanilla food id still
---restores everything the game restores and this is applied ON TOP. Declaring
---`restores = { satiety = 20 }` on Berries means "and 20 more", not "20 instead".
---
---WHO IT IS APPLIED TO: ctx.actor from item.use, which is the LOCAL PLAYER PAWN — the character
---who USED the item, which is the character used ON for self-use (food, potions). Feeding a pal
---goes to the pal through the game's own path and PalForge's write still lands on the player, so
---declare this for items a player consumes. Nothing is written when there is no live character;
---the [PalForge.item] log line says which vital did not land and why.
---
---A negative value drains rather than restores, and that is measured too: the -0.1 rate the hook
---wrote is exactly this call.
local Restores = schema.define("Item.Spec.Restores", {
    { "satiety", type = "number", check = satietyAmount,
                 doc = "satiety POINTS added on use, clamped to the bar (100.0 wide when measured); added to the game's own effect, never instead of it" },
    { "hpRate",  type = "number", check = hpRateAmount,
                 doc = "health restored as a FRACTION of maximum HP: 0.25 = a quarter, 1 = a full heal, -0.1 hurts (the only HP write this build allows from Lua)" },
    { "hp",      type = "number", check = noAbsoluteHP,
                 doc = "REFUSED at define time, always: an absolute HP amount takes FFixedPoint64, a struct UE4SS cannot marshal from Lua (measured 2026-08-02, hook item-satiety-write). Declare hpRate instead" },
})

-- A restore that names no vital is a promise with nothing behind it: `restores = {}` would
-- register, subscribe to item.use and write nothing forever. It is refused where it is written.
local function declaresAVital(v)
    if v.satiety ~= nil or v.hpRate ~= nil then return true end
    return false, "a restore must name at least one vital — { satiety = <points> } and/or "
        .. "{ hpRate = <fraction of maximum HP> }. An empty restore would subscribe to item.use "
        .. "and write nothing"
end

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
    -- THE TWO-SPELLINGS TRAP, as a field instead of as folklore. The same thing is spelled
    -- one way as a blueprint / build id and another as a DataTable row on this build —
    -- SheepBall / Sheepball, WorkBench / Workbench — and `icons.resolve` is case-SENSITIVE
    -- (core/icons.lua:40-42), so the id dispatch keys on is not always the id the icon table
    -- answers to. native/pals.lua carries M.ROW_ID for exactly this and its own M.iconOf works
    -- around it, but that is catalog-level: a HANDLE still missed, because Class:iconOf had
    -- only `id` to go on. Declaring the row id closes it at the level a pack actually holds.
    { "iconId",      type = "string",
                     doc = "the DataTable ROW id to look the icon up under, when the game spells this thing differently in its icon table than in its blueprint / build id. Defaults to `id`." },
    { "icon",        type = "string",
                     doc = "/Game/... texture path used when the icon DataTable has no row for this id" },
    { "recipe",      type = "table", of = Recipe,
                     doc = "the recipe that produces THIS item (metadata; see Item.Spec.Recipe)" },
    { "restores",    type = "table", of = Restores, check = declaresAVital,
                     doc = "what USING this item restores, ADDED to the game's own effect: { satiety = 20, hpRate = 0.25 } (LIVE - see Item.Spec.Restores)" },
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
Class.restores = nil

function Class:onObtain(ctx) end
function Class:onUse(ctx) end
function Class:onCraft(ctx) end
function Class:onDiscard(ctx) end

-- Write this item's declared restore onto one character, NOW. Every route into the vitals goes
-- through here — the item.use subscriber below, and Handle:restoreOn for a pack that wants to
-- feed someone from its own code — so there is one place that decides what a declaration means
-- and one place a test can watch.
--
-- Returns core/character.restore's verdict unchanged: true only when every declared vital was
-- seen to move in a read-back, false plus the English reason otherwise. An item that declares
-- no restore is a false with a reason, not an error: dispatch reaches every used item.
function Class:restoreOn(actor)
    if type(self.restores) ~= "table" then
        return false, string.format("%s declares no restores, so using it writes no vitals",
            tostring(self.id))
    end
    return character.restore(actor, self.restores)
end

-- This item's recipe: the DECLARED one when there is one, else the GAME'S OWN ROW. Override to
-- build one dynamically. Both halves answer the same shape, Item.Spec.Recipe — see its note.
--
-- MEASURED, 2026-08-02, hook item-datatable-row-read, 2 pass / 0 fail. The sentence this
-- comment replaced said :recipeOf "never reads the game", and the reason it did not was one
-- open question: core/icons had to abandon the struct FindRow returns because the icon column's
-- TSoftObjectPtr answers no member name from Lua, and nobody had tried the same index on an
-- int32 or an FName. That run tried it. `dt:FindRow('Arrow')` handed back a live ScriptStruct
-- /Script/Pal.PalItemRecipe and all four probed columns came off it BY NAME —
-- Product_Count=10, WorkAmount=1000.0, Material1_Id=Wood (an FName, needing :ToString()),
-- Material1_Count=2. So a recipe is ONE call, and core/recipes.lua is that call.
--
-- THE DECLARED RECIPE WINS, and this is the one place in this file where the declared value
-- beats the live one. It is not an inconsistency with :iconOf below, it is each field's own
-- documented contract being kept:
--   * `icon` is documented as "used when the icon DataTable has NO ROW for this id" — it says
--     of itself that it is a fallback, so the live table wins.
--   * `recipe` is documented as what the author declares ABOUT THEIR OWN ITEM, and an author
--     who writes one has said something PalForge must not overrule. Overruling it would also
--     be silent: a pack that gives a vanilla id a recipe of its own for its own crafting
--     system would get the vanilla numbers back and nothing would say why.
-- The practical shape of it: declared items cost no engine call at all, and the game read is
-- what answers for every id nobody declared — which is every vanilla id, the case a pack
-- author actually asks about.
--
-- THE ID IS RESOLVED FIRST (F-3/C5), for the reason spelled out on :iconOf: the live table is
-- keyed by the row spelling PalSchema writes, so "pack:Potion" has to ask for "pack_Potion",
-- and `or self.id` — fall back to the LITERAL, never to nothing — is the rule at every engine
-- boundary. core/recipes deliberately does NOT do this itself; the boundary is here.
--
-- Fail-soft: no world, no table, no row, a row that answers nothing -> nil, and the pcall is
-- the same belt-and-braces :iconOf wears (core/recipes raises nothing on its own).
function Class:recipeOf()
    if self.recipe ~= nil then return self.recipe end
    local id = om.resolve(self.id) or self.id
    local ok, recipe = pcall(function() return recipes.resolve(id) end)
    if ok and recipe ~= nil then return recipe end
    return nil
end

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
-- soft pointer could plausibly expose, so THAT value cannot be opened from Lua. What is read
-- instead is the whole column as text, via UDataTableFunctionLibrary::GetDataTableColumnAsString,
-- zipped against dt:GetRowNames() — two calls per table, cached. The limit is the SOFT POINTER,
-- not the struct: :recipeOf indexes ints and FNames straight off a row (2026-08-02).
--
-- THE RECIPE HALF IS CLOSED TOO, and the item-datatable-row-read marker that stood here is gone
-- with it — deliberately, so a grep for open markers no longer stops on this file. What it asked
-- — can a scalar / FName column be indexed off the struct FindRow hands back — was answered yes
-- on 2026-08-02 (see :recipeOf above), so the thirteen-call column detour it planned for is not
-- needed and was not written.
--
-- THE ID IS RESOLVED FIRST (F-3/C5). The live table is keyed by the row spelling PalSchema
-- writes, so `Item{ id = "pack:Potion" }:iconOf()` has to ask for "pack_Potion"; handing
-- icons.resolve the raw "pack:Potion" could never hit a row, and every namespaced item silently
-- looked like an item whose icon simply was not in the table. `or self.id` is the rule at every
-- engine boundary: an id that fails to resolve falls back to the LITERAL, never to nothing.
function Class:iconOf()
    -- THE ROW ID FIRST, then the id, then the declared fallback. `iconId` exists because the id
    -- this thing DISPATCHES on is not always the id the icon table answers to: the same creature
    -- is SheepBall as a blueprint and Sheepball as a DataTable row, the same structure is
    -- WorkBench and Workbench, and icons.resolve is case-SENSITIVE (core/icons.lua:40-42). The
    -- catalogs have carried that as data since native/pals.lua's M.ROW_ID, but only their own
    -- iconOf() consulted it, so a HANDLE — which is what a pack holds — still missed. Trying the
    -- declared row id first and the id second means both spellings hit and neither has to be
    -- known by the caller.
    local tried = {}
    if type(self.iconId) == "string" and #self.iconId > 0 then
        tried[#tried + 1] = om.resolve(self.iconId) or self.iconId
    end
    tried[#tried + 1] = om.resolve(self.id) or self.id
    for _, id in ipairs(tried) do
        local ok, tex = pcall(function() return icons.resolve(icons.TABLES.item, id) end)
        if ok and tex ~= nil then return tex end
    end
    return self.icon
end

--=============================================================================
-- the item.use SUBSCRIBER — where a declared `restores` becomes a write
--
-- WHY THIS IS A SUBSCRIBER AND NOT Class:onUse. core/event's dispatch calls cls:onUse(ctx), and
-- an item that declares `events.onUse` REPLACES that method with the author's handler (see the
-- forwarder in define below). A restore hung off onUse would therefore stop working for exactly
-- the items that also declare a handler, silently. So the restore listens to the channel in its
-- own right, beside the dispatch, the way api/effect.lua drives itself off "tick".
--
-- core/event.lua is NOT edited for this and does not know it exists: the channel it emits
-- already carries everything needed — ctx.itemId and ctx.actor, a real player pawn (measured
-- live; item.use fires off UPalItemUseProcessor:UseItemToCharacter_ServerInternal).
--
-- ONE SUBSCRIPTION PER SESSION, and it survives a hot reload the way core/event's own dispatch
-- does: the handle is parked on _G and the previous one is unsubscribed before a new one is
-- taken, because a reload that simply subscribed again would apply every restore twice, then
-- three times.
--=============================================================================

local restoreDriver = false

-- Resolved the same way core/event's dispatch resolves an item ctx: the exact id first (a
-- native item defines under the game id), then the namespaced form, because the game emits the
-- PalSchema row name "pack_Potion" and never the colon form the pack declared.
local function definitionFor(itemId)
    if itemId == nil then return nil end
    local cls = om.get("item", itemId)
    if cls then return cls end
    return (om.byResolved("item", itemId))
end

local function applyRestore(ctx)
    if type(ctx) ~= "table" then return end
    local cls = definitionFor(ctx.itemId)
    if not cls or type(cls.restores) ~= "table" then return end
    local ok, why = cls:restoreOn(ctx.actor)
    if ok then
        log.info(string.format("%s restored %s", tostring(ctx.itemId),
            table.concat((function()
                local parts = {}
                for k, v in pairs(cls.restores) do parts[#parts + 1] = k .. "=" .. tostring(v) end
                table.sort(parts)
                return parts
            end)(), ", ")))
    else
        -- A false here is the normal answer at a title screen, on a dedicated server with no
        -- local pawn, and on a character who is already full. It is logged at warn with the
        -- reason attached, because "my food item did nothing" needs a sentence, not silence.
        log.warn(string.format("%s: nothing was restored — %s", tostring(ctx.itemId),
            tostring(why)))
    end
end

-- Subscribe on the FIRST define that declares a restore, so requiring this module costs nothing
-- and a pack that declares no food never puts a subscriber on the bus.
local function ensureRestoreDriver()
    if restoreDriver then return true end
    local ok = pcall(function()
        local event = require("palforge.core.event")
        local prev = _G.__PalForgeItemRestoreSub
        if prev then pcall(function() prev:unsubscribe() end) end
        _G.__PalForgeItemRestoreSub = event.on("item.use", function(ctx)
            -- Pack data drives this, so it stays pcall'd — but the error is LOGGED, never
            -- swallowed: the same rule core/event's dispatch keeps for a handler that raises.
            local okRun, err = pcall(applyRestore, ctx)
            if not okRun then log.err("item.use restore failed: " .. tostring(err)) end
        end)
    end)
    restoreDriver = ok
    return ok
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
        iconId      = spec.iconId,
        recipe      = spec.recipe,
        restores    = spec.restores,
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
    -- A declared restore only reaches a character through the item.use subscriber, so the first
    -- one to be declared is what puts that subscriber on the bus. Before the driver existed this
    -- was the whole gap: the channel fired, the handler ran, and nothing could write a vital.
    if spec.restores then ensureRestoreDriver() end
    -- so core/event + get() find it — unless the caller asked for a definition that stays out
    -- of the registry (opts.register == false), which is a build, not a define.
    if register then
        -- The ids this definition MENTIONS — same reasoning as api/pal.lua. A recipe names
        -- other ITEMS (its materials, its product) and a BUILDING (the station that crafts
        -- it); all three are ids a pack can write in another pack's namespace.
        local refs = {}
        local rec = spec.recipe
        if type(rec) == "table" then
            for mat in pairs(rec.materials or {}) do refs[#refs + 1] = mat end
            if type(rec.product) == "string" then refs[#refs + 1] = rec.product end
            if type(rec.station) == "string" then refs[#refs + 1] = rec.station end
        end
        pcall(function() om.register("item", spec.id, cls, { pack = pack, refs = refs }) end)
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
---
---⚠️ THIS IS THE ONE ITEM ACTION THAT REACHES PALWORLD'S OWN SAVE, and it is the only reason
---removing a pack can matter at all. PalForge's own state is a sidecar it owns; a StaticItemId
---is not — it lands in FPalWorldSaveData.ItemContainerSaveData, which the game writes. When the
---id belongs to a PACK, the row behind it exists only because PalSchema injected it, so a
---successful give is recorded in core/ledger — per save, per pack — and that list is what lets
---PalForge name, id by id, what an uninstall would leave dangling. A literal game id records
---nothing: a vanilla row cannot stop existing. See core/ledger.lua's header.
---@param count integer?
---@return boolean ok  # true only when the inventory count was measured to rise
function Handle:give(count)
    local n = count or 1
    -- The ledger row is written by utils.items.give itself, at the engine boundary, NOT here.
    -- It used to be here, and that covered exactly one of that function's callers: anything
    -- reaching `PalForge.utils.items.give` — a documented public toolbox — put a pack-owned
    -- FName into the player's save with the removal report never hearing about it. See the end
    -- of utils/items.give for the whole reasoning; core/character.addSkill does the same.
    return items.give(self.id, n)
end

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

---WORKS, and is measured. Write this item's declared `restores` onto `actor` right now, without
---waiting for the player to use one — for a pack that feeds someone from its own code (a
---campfire, a quest reward, a passive that ticks).
---
---The verdict is the READ-BACK, never the call: true only when every declared vital was seen to
---move afterwards. false plus an English reason for everything else, and the reasons name the
---state rather than shrugging — no live character, satiety already full, the game accepted the
---call and nothing moved. Applying an item that declares no restore is a false saying so.
---
---Measured on a live character 2026-08-02 (hook item-satiety-write): satiety through
---SetFullStomach, health through AddHPByRate. See core/character.lua's vitals section.
---@param actor userdata  # a live character — the player pawn, or a pal
---@return boolean ok, string? reason
function Handle:restoreOn(actor) return self._cls:restoreOn(actor) end

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

---The recipe that produces this item: the DECLARED one if this item declares one, else the
---game's own DT_ItemRecipeDataTable_Common row for the id, else nil. One shape either way —
---`{ product, count, work, station, materials = { [itemId] = count } }` (Item.Spec.Recipe).
---
---From the game's row: `product` is Product_Id, `count` is Product_Count (how many one craft
---yields), `work` is WorkAmount, `materials` are the MaterialN_Id/_Count pairs with the empty
---slots dropped, and `station` is always nil — the row names a work ATTRIBUTE, not a station.
---`Item.get("Arrow"):recipeOf()` answers `count = 10, work = 1000.0, materials = { Wood = 2 }`
---on the build this was measured against (2026-08-02).
---
---DECLARING A RECIPE WINS over the game's row: it is your statement about your own item, and
---PalForge does not overrule it. See Class:recipeOf for why this is the opposite way round
---from :iconOf. nil means nobody declared one and the game has no row to read — never an error.
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
---What using this item restores, as declared — `{ satiety = 20, hpRate = 0.25 }` — or nil when
---this item restores nothing of PalForge's own (which is every item that declares no such
---field, including every vanilla consumable: the GAME's own effect is not readable from here
---and is never reported as ours). The declared table itself, not a copy.
---@return Item.Spec.Restores?
function Handle:restores() return self._cls.restores end

Item.Class = Class   -- the base hook table (used for override detection / subclassing)
return Item
