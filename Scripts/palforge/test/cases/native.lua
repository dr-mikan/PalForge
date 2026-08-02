-- palforge/test/cases/native.lua — the native content catalogs, and the naming rule they share.
--
-- Scripts/palforge/native/*.lua declare the game's OWN content through the same constructors a
-- pack uses, and expose one NAMED FIELD per row: `native.items.Arrow_Fire`,
-- `native.pals.BlueSkyDragon`, `native.skills.CraftSpeed_3`. Three claims hold that up, and each
-- of them is the sort that stays true until the day it silently does not:
--
--   1. THE NAMING RULE IS COLLISION-PROOF, not merely collision-free today. The rule is written
--      round the identity function precisely so that no two ids can want the same field (see
--      native/_catalog.lua). This suite re-derives the whole mapping from every catalog on every
--      run and asserts the mapping is injective — so a game patch that adds a punctuated id
--      cannot quietly make two rows fight over one name.
--   2. A NAMED FIELD IS THE SAME OBJECT AS get(id). Two ways in, one definition. If the metatable
--      ever built a second handle beside the cache, an event handler declared on one would be
--      invisible from the other.
--   3. READING A NAME REGISTERS NOTHING AT ALL — not the catalog, and not the one row either.
--      This is the publish gate (F-8) and it is the claim with a player's save file on the other
--      end of it: a registered BUILDING definition is not inert, because core/event's refreshDefs
--      picks it up on the next 500 ms scan, every matching actor in the world becomes a tracked
--      instance, and a newly tracked instance is PERSISTED into the per-world JSON that nothing
--      prunes. So `buildings.Stone_Foundation` in a tooltip must not be a write. This suite
--      measures the registry across a read instead of trusting the comment — and it used to
--      measure the OPPOSITE ("exactly one class more"), which is how a read that published
--      went unnoticed for as long as it did.
--
-- NOTHING HERE NEEDS A WORLD. Every claim is about Lua tables — no spawn, no give, no play — so
-- this suite passes in full at the title screen. It also creates no test ids: it reads catalogs
-- the kernel already loaded, and the few handles it materialises are for REAL game rows, which
-- is exactly what a pack author's first line would do.
local T       = require("palforge.core.unittests")
local om      = require("palforge.core.object_manager")
local catalog = require("palforge.native._catalog")

local s = T.suite("native")

-- The catalogs under test, with the object_manager type each registers under and one row that is
-- known to be in it. The row ids are real and come from the dumps
-- (dumps/catalog/datatables/), not from anything this suite invented.
local CATALOGS = {
    { name = "buildings", otype = "building", row = "PalBoxV2"          },
    { name = "items",     otype = "item",     row = "Arrow_Fire"        },
    { name = "pals",      otype = "pal",      row = "BlueSkyDragon"     },
    { name = "skills",    otype = "skill",    row = "Legend"            },
    { name = "effects",   otype = "effect",   row = "Sleep"             },
    { name = "audio",     otype = "audio",    row = "AKE_Pal_Footstep"  },
}

for _, c in ipairs(CATALOGS) do
    c.module = require("palforge.native." .. c.name)
end

-- Every id a catalog holds, whatever shape its CATALOG is: an array of ids for five of them, a
-- map keyed by id for native.audio (its values are asset paths).
local function idsOf(mod)
    local out, cat = {}, rawget(mod, "CATALOG") or {}
    if #cat > 0 then
        for _, id in ipairs(cat) do out[#out + 1] = id end
    else
        for id in pairs(cat) do out[#out + 1] = id end
    end
    return out
end

-- How many classes object_manager holds right now, across every type. The laziness measurement.
local function registeredCount()
    local n = 0
    for _, otype in ipairs(om.TYPES) do
        for _ in pairs(om.all(otype)) do n = n + 1 end
    end
    return n
end

--=============================================================================
-- the naming rule itself (native/_catalog.lua)
--=============================================================================

s:test("an id that is already a Lua identifier is its own name, which is why it cannot collide",
function(t)
    for _, id in ipairs({ "Wood", "PalBoxV2", "Wooden_foundation", "_leading", "A1" }) do
        t:truthy(catalog.isName(id), id .. " is a Lua identifier and must be taken verbatim")
    end
    for _, id in ipairs({ "CraftSpeed*3", "1First", "has space", "dash-ed", "" }) do
        t:eq(catalog.isName(id), false, string.format("%q is not usable as a field name", id))
    end
end)

s:test("a Lua keyword is never a field name, because native.end would not even parse", function(t)
    for _, kw in ipairs({ "end", "for", "nil", "function", "true", "repeat" }) do
        t:eq(catalog.isName(kw), false, kw .. " must not be taken verbatim")
        t:eq(catalog.aliasFor(kw), kw .. "_", kw .. " must be escaped, not left alone")
    end
end)

s:test("normalisation replaces what it must and nothing else, and always lands on an identifier",
function(t)
    t:eq(catalog.aliasFor("CraftSpeed*3"), "CraftSpeed_3")
    t:eq(catalog.aliasFor("a b.c-d"), "a_b_c_d")
    t:eq(catalog.aliasFor("3Sixty"), "_3Sixty", "a leading digit gets a prefix, not a rename")
    t:eq(catalog.aliasFor("***"), "___")
    t:eq(catalog.aliasFor(""), "_", "even an empty id lands on something addressable")
    -- and the output of the rule always satisfies the rule
    for _, id in ipairs({ "CraftSpeed*3", "a b.c-d", "3Sixty", "***", "", "end" }) do
        t:truthy(catalog.isName(catalog.aliasFor(id)),
            string.format("aliasFor(%q) must itself be a legal field name", id))
    end
end)

s:test("normalisation is pure: the same id always produces the same candidate", function(t)
    t:eq(catalog.aliasFor("CraftSpeed*3"), catalog.aliasFor("CraftSpeed*3"))
    -- which is what makes rule (3) deterministic — the tie-break depends only on CATALOG order,
    -- never on what has been asked for before.
    t:eq(catalog.aliasFor("x*y"), "x_y")
end)

s:test("index() gives the first of two colliding ids the name and leaves the second reachable",
function(t)
    -- Contrived, because no real catalog has a collision — which is exactly why it has to be
    -- contrived. Both rows exist; only one can own the field.
    local set, aliases, unnamed = catalog.index({ "a*b", "a-b", "plain" })
    t:eq(aliases["a_b"], "a*b", "the FIRST id in catalog order keeps the name")
    t:truthy(unnamed["a-b"], "the second must be recorded, not silently dropped")
    t:eq(aliases["plain"], nil, "an id that is already a name is not an alias of itself")
    t:truthy(set["a-b"], "losing the name must not lose membership — get(id) still finds it")
end)

s:test("an id that already owns a name beats an alias that wants it", function(t)
    local _, aliases, unnamed = catalog.index({ "a_b", "a*b" })
    t:eq(aliases["a_b"], nil, "the real id a_b keeps its own field")
    t:truthy(unnamed["a*b"], "and the alias that wanted it is recorded as unnamed")
end)

--=============================================================================
-- every catalog, against the rule
--=============================================================================

s:test("every row in every catalog either owns a name, has an alias, or is listed as unnamed",
function(t)
    for _, c in ipairs(CATALOGS) do
        local aliases, unnamed = c.module.ALIASES or {}, c.module.UNNAMED or {}
        local byId = {}
        for name, id in pairs(aliases) do byId[id] = name end

        local named, aliased, skipped = 0, 0, 0
        for _, id in ipairs(idsOf(c.module)) do
            if catalog.isName(id) then named = named + 1
            elseif byId[id] then aliased = aliased + 1
            elseif unnamed[id] then skipped = skipped + 1
            else
                t:truthy(false, string.format("native.%s: the id %q has no name and no reason why",
                    c.name, id))
            end
        end
        t:truthy(named > 0, "native." .. c.name .. " must expose some rows by name")
        -- Recorded rather than asserted at an exact number: a game patch may legitimately add
        -- punctuated rows. What must never happen is the fourth case above.
        t:eq(named + aliased + skipped, #idsOf(c.module),
            "native." .. c.name .. ": every row must be accounted for")
    end
end)

s:test("the name mapping is INJECTIVE in every catalog: no two rows want the same field",
function(t)
    for _, c in ipairs(CATALOGS) do
        local owner = {}
        for _, id in ipairs(idsOf(c.module)) do
            if catalog.isName(id) then
                t:eq(owner[id], nil, string.format(
                    "native.%s: %q would be claimed twice — a DataTable cannot repeat a row key",
                    c.name, id))
                owner[id] = id
            end
        end
        for name, id in pairs(c.module.ALIASES or {}) do
            t:eq(owner[name], nil, string.format(
                "native.%s: the alias %q (for %q) collides with a row of that name", c.name, name, id))
            owner[name] = id
        end
    end
end)

s:test("no row is shadowed by the module's own surface, which __index could never reach",
function(t)
    for _, c in ipairs(CATALOGS) do
        for id, why in pairs(c.module.UNNAMED or {}) do
            -- UNNAMED is expected to be empty in this build; if it is not, the reason must at
            -- least be a real string a reader can act on rather than a bare true.
            t:type(why, "string", string.format(
                "native.%s: %q is unnamed and must say why", c.name, id))
        end
    end
end)

--=============================================================================
-- a named field IS the handle, and IS the one get(id) hands back
--=============================================================================

s:test("a named field resolves to a handle carrying exactly the row's own id", function(t)
    for _, c in ipairs(CATALOGS) do
        local h = c.module[c.row]
        t:truthy(h, string.format("native.%s.%s must resolve", c.name, c.row))
        t:eq(h.id, c.row, "the handle must carry the id it was named after, not a normalised one")
    end
end)

s:test("a named field and get(id) are the SAME handle, so a definition is never made twice",
function(t)
    for _, c in ipairs(CATALOGS) do
        t:eq(c.module[c.row], c.module.get(c.row),
            string.format("native.%s.%s must BE native.%s.get(%q)", c.name, c.row, c.name, c.row))
    end
end)

s:test("an unknown name reads as nil, exactly like a key of any other table", function(t)
    for _, c in ipairs(CATALOGS) do
        t:eq(c.module.NoSuchRowExistsAnywhere, nil,
            "native." .. c.name .. " must not invent content for a name it does not have")
        t:eq(c.module.get("NoSuchRowExistsAnywhere"), nil,
            "native." .. c.name .. ".get must not invent content either")
    end
end)

s:test("the module's own surface still wins over the lazy names", function(t)
    for _, c in ipairs(CATALOGS) do
        t:type(c.module.get, "function", "native." .. c.name .. ".get must still be the function")
        t:type(c.module.CATALOG, "table", "native." .. c.name .. ".CATALOG must still be the data")
    end
end)

--=============================================================================
-- THE PUBLISH GATE (F-8): a read is a read, and publishing is a call you make
--=============================================================================

s:test("reading a name registers NOTHING — the publish gate, measured", function(t)
    -- A row nothing else in the suite touches, so this measures a first read.
    --
    -- THIS TEST USED TO ASSERT THE OPPOSITE. It read "reading one name registers one class, not
    -- a catalog" and its arithmetic was right while its premise was wrong: for buildings a
    -- registered definition makes core/event track and PERSIST every matching actor in the
    -- world, so the one welcome class was a field read that started writing a record for every
    -- Stone_Gate in the player's base. The handle is what a read is for; the registration is
    -- what it must not do.
    local ROW = "Stone_Gate"
    local buildings = require("palforge.native.buildings")
    t:eq(om.isRegistered("building", ROW), false,
        "the row must start unregistered — the catalog is data")

    local before = registeredCount()
    local h = buildings[ROW]
    local after = registeredCount()

    t:eq(h.id, ROW, "the read must still hand back a real, complete handle")
    t:eq(om.isRegistered("building", ROW), false,
        "reading the name must NOT have published a definition core/event would track")
    t:eq(om.get("building", ROW), nil, "and the registry must not hold a class for it")
    t:eq(after, before, "not one class more than before, let alone 498")

    -- reading it again builds nothing further either: get(id) is the cache the metatable rides on
    local again = buildings[ROW]
    t:eq(again, h, "the second read must be the same handle")
    t:eq(registeredCount(), after, "and must still not register anything at all")
end)

s:test("every catalog's accessor is gated, not just the building one", function(t)
    -- The gate is one rule in all six catalogs. Five of them persist nothing, so this is the
    -- cheap half — but a per-domain exception is exactly how the building one came to exist.
    -- Rows chosen because nothing else in this suite reads them.
    local ROWS = {
        { name = "buildings", otype = "building", row = "Stone_Fence"                  },
        { name = "items",     otype = "item",     row = "Arrow_Poison"                 },
        { name = "pals",      otype = "pal",      row = "FlowerDinosaur"               },
        { name = "skills",    otype = "skill",    row = "HP_ACC_up3"                   },
        { name = "effects",   otype = "effect",   row = "Darkness"                     },
        { name = "audio",     otype = "audio",    row = "AKE_General_FireBlast_Shoot"  },
    }
    for _, c in ipairs(ROWS) do
        local mod = require("palforge.native." .. c.name)
        local h = mod[c.row]
        t:truthy(h, string.format("native.%s.%s must resolve (a row of the real dump)",
            c.name, c.row))
        t:eq(om.isRegistered(c.otype, c.row), false, string.format(
            "reading native.%s.%s must not publish a %s definition", c.name, c.row, c.otype))
    end
end)

s:test("the two curated buildings define themselves without registering themselves", function(t)
    -- F-8's other half: WorkBench and PalBoxV2 were unconditional Building{...} calls at module
    -- load, so every install began persisting a record for every workbench and pal box in every
    -- save, for content no pack requested. They are still declared, in full, with their meshes —
    -- what they no longer do is publish themselves.
    local buildings = require("palforge.native.buildings")
    t:truthy(buildings.WorkBench:mesh(), "the curated declaration must be intact")
    t:truthy(buildings.PalBox:mesh(),    "...for both of them")
    t:eq(om.isRegistered("building", "WorkBench"), false,
        "requiring native.buildings must not start tracking every workbench in the save")
    t:eq(om.isRegistered("building", "PalBoxV2"), false,
        "...nor every pal box")
end)

s:test("publish(id) is the opt-in, and it publishes the very handle the catalog cached",
function(t)
    -- Exercised on an ITEM, deliberately, and this is not squeamishness: publishing a BUILDING
    -- id is the one thing in this tree that makes PalForge write to the player's save, and a
    -- test that runs on an F1 press in a live session must not start tracking real structures to
    -- prove that it can. The building path is the same three lines (native/buildings.lua's
    -- M.publish) over the same catalog.publish; what is specific to buildings is core/event, and
    -- measuring THAT needs a world -- it is a test/hooks/ candidate, not a headless case.
    --
    -- AND IT CLEANS UP AFTER ITSELF, both ends. F1 runs this suite again and again in one
    -- session and publishing is permanent by design, so run 2 would otherwise fail on run 1's
    -- leftovers — which is precisely what the OLD read test did, invisibly: it asserted the row
    -- started unregistered and then registered it by reading, so its second run could only pass
    -- because nobody pressed F1 twice. om.unregister is C3's explicit "forget".
    local items = require("palforge.native.items")
    local ROW = "MetalDetector"
    t:type(items.publish, "function", "every catalog must offer the opt-in")

    om.unregister("item", ROW)
    local h = items[ROW]
    t:truthy(h, "the row must resolve")
    t:eq(om.isRegistered("item", ROW), false, "and must start unpublished")

    local published = items.publish(ROW)
    t:eq(published, h, "publish must return the SAME handle, not a second definition")
    t:eq(om.isRegistered("item", ROW), true, "and the id must now be taken")
    -- The class that went into the registry is the class behind that handle. `_cls` is the only
    -- link from a handle to its class and there is no public accessor for it; native/_catalog's
    -- publish() reads the same field, and this is the assertion that it read the right one.
    t:eq(om.get("item", ROW), rawget(h, "_cls"),
        "the registry must hold the catalog's own class, not a rebuilt twin")
    t:eq(om.owner("item", ROW), "palforge",
        "and it must be attributable to the framework, so a pack collision names both sides")

    -- Idempotent: publishing again is the same class under the same id, not a second one.
    local n = registeredCount()
    t:eq(items.publish(ROW), h, "a second publish must hand back the same handle")
    t:eq(registeredCount(), n, "and must not add a second entry")

    t:eq(items.publish("NoSuchRowExistsAnywhere"), nil,
        "publishing something that is not in the catalog must invent nothing")

    -- Leave the registry as this suite found it: the header's "creates no test ids" claim covers
    -- ids this file PUBLISHES too, and a stale one would quietly change what the next run counts.
    om.unregister("item", ROW)
    t:eq(om.isRegistered("item", ROW), false, "the suite must not leave a published id behind")
end)

s:test("the catalogs are still overwhelmingly unregistered after this suite has run", function(t)
    -- The kernel loads six catalogs holding 8299 rows between them. If loading one ever started
    -- materialising its rows, this is where it would show: the registry would be in the
    -- thousands rather than the dozens.
    t:truthy(registeredCount() < 500, string.format(
        "object_manager holds %d classes — a catalog is being registered eagerly", registeredCount()))
end)

--=============================================================================
-- aliases, where the rule stops being theoretical
--=============================================================================

s:test("the two punctuated skill rows are reachable by alias AND by their real id", function(t)
    local skills = require("palforge.native.skills")
    for alias, id in pairs({ CraftSpeed_3 = "CraftSpeed*3", CraftSpeed_5 = "CraftSpeed*5" }) do
        t:eq(skills.ALIASES[alias], id, alias .. " must be published as an alias for " .. id)

        local h = skills[alias]
        t:truthy(h, "native.skills." .. alias .. " must resolve")
        t:eq(h.id, id, "the alias is a second NAME; the handle keeps the game's own id")
        t:eq(skills.get(id), h, "get(the real id) must be the same handle")

        -- get() normalises NOTHING, deliberately: an id string is the spelling that can never
        -- be ambiguous, so the alias exists only on the field side.
        t:eq(skills.get(alias), nil, "get must not accept the alias as an id")
    end
end)

s:test("the rows the previous catalog dropped are back, and the count matches both DataTables",
function(t)
    local skills = require("palforge.native.skills")
    t:eq(#skills.PASSIVE, 1905, "DT_PassiveSkill_Main_Common has 1905 rows")
    t:eq(#skills.PARTNER, 682, "DT_PartnerSkillParameter has 682 rows")
    t:eq(#skills.CATALOG, 2587, "the merged catalog is both, and used to be 2585")
end)

--=============================================================================
-- truthfulness: a native handle must not claim what the id does not have
--=============================================================================

s:test("a skill's kind comes from the table it is a row of, not from Skill.Spec's default",
function(t)
    local skills = require("palforge.native.skills")
    -- "active" is Skill.Spec's default, so a passive-trait row answering "active" would be
    -- indistinguishable from one that was never asked. These two rows come from different
    -- tables and must answer differently.
    t:eq(skills.tableOf("Legend"), "DT_PassiveSkill_Main_Common")
    t:eq(skills.Legend:kind(), "passive", "a passive-trait row must not call itself active")

    t:eq(skills.tableOf("BOSS_FireKirin"), "DT_PartnerSkillParameter")
    t:eq(skills.BOSS_FireKirin:kind(), "active", "a partner skill is invoked")

    t:eq(skills.tableOf("nothing at all"), nil, "an id from no table names no table")
end)

s:test("every catalog says which DataTable it stands for, so a regeneration cannot drift",
function(t)
    t:eq(require("palforge.native.buildings").TABLE, "DT_BuildObjectDataTable_Common")
    t:eq(require("palforge.native.items").TABLE,     "DT_ItemDataTable_Common")
    t:eq(require("palforge.native.pals").TABLE,      "DT_PalMonsterParameter_Common")
    local skills = require("palforge.native.skills")
    t:eq(skills.TABLES.passive, "DT_PassiveSkill_Main_Common")
    t:eq(skills.TABLES.partner, "DT_PartnerSkillParameter")
end)

s:test("the row counts still match the dumps the catalogs were generated from", function(t)
    -- Not decoration: these four numbers are the whole claim that a catalog is the GAME's
    -- content rather than a hand-list somebody stopped updating. They come from
    -- dumps/catalog/datatables/<table>.json, dumped from a live session on 2026-07-26.
    t:eq(#require("palforge.native.buildings").CATALOG, 498)
    t:eq(#require("palforge.native.items").CATALOG,     2466)
    t:eq(#require("palforge.native.pals").CATALOG,      753)
    t:eq(#require("palforge.native.skills").CATALOG,    2587)
end)

s:test("a curated definition and its row are one handle, not two competing registrations",
function(t)
    -- The pre-seeding at the bottom of each catalog is what makes this true. Without it, reading
    -- the row's name would build a BARE definition over the top of the hand-written one and its
    -- mesh and its event handlers would vanish.
    local buildings = require("palforge.native.buildings")
    t:eq(buildings.PalBoxV2, buildings.PalBox, "the row's name must reach the curated handle")
    t:truthy(buildings.PalBoxV2:mesh(), "...with the hand-written mesh still on it")

    local pals = require("palforge.native.pals")
    t:eq(pals.ChickenPal, pals.Chicken, "the row's name must reach the curated demo")
    t:truthy(pals.ChickenPal:mesh(), "...with its mesh intact")

    local items = require("palforge.native.items")
    t:eq(items.Wood, items.get("Wood"), "a curated field whose name IS its row id is one field")
    t:eq(items.Wood:name(), "Wood")

    local skills = require("palforge.native.skills")
    t:eq(skills.FlameThrower, skills.Fireball, "a curated id is reachable by its own name too")

    local audio = require("palforge.native.audio")
    t:eq(audio.AKE_BGM_Title, audio.MainTheme, "and reading a name must not re-define a BGM as SE")
    t:eq(audio.AKE_BGM_Title:kind(), "bgm", "...which is what its kind would show if it had")
end)

s:test("one creature, two spellings: both handles exist, and the catalog carries the mapping",
function(t)
    -- The sharp edge that is DOCUMENTED rather than fixed, asserted so it cannot drift into
    -- being fixed by accident (which would break dispatch) or into being forgotten.
    --   SheepBall / WorkBench — the BLUEPRINT id, what the runtime dispatches on.
    --   Sheepball / Workbench — the DataTable row FName, what the icon table is keyed by.
    -- Two handles, one thing, different capabilities. Neither spelling can be dropped.
    local pals = require("palforge.native.pals")
    t:eq(pals.ROW_ID.SheepBall, "Sheepball", "the row spelling must be readable as DATA")
    t:eq(pals.SheepBall.id, "SheepBall", "the curated demo keeps the dispatch spelling")
    t:eq(pals.Sheepball.id, "Sheepball", "and the row keeps its own")
    t:truthy(pals.SheepBall ~= pals.Sheepball, "they are two handles, and the docs say why")
    t:type(pals.iconOf, "function", "the catalog offers the lookup that follows the mapping")

    local buildings = require("palforge.native.buildings")
    t:eq(buildings.ROW_ID.WorkBench, "Workbench", "the same split, in the same shape")
    t:eq(buildings.WorkBench.id, "WorkBench")
    t:eq(buildings.Workbench.id, "Workbench")
    t:type(buildings.iconOf, "function")

    -- WHAT THIS CANNOT ASSERT HEADLESSLY: that pals.iconOf("SheepBall") comes back with the
    -- game's own artwork. core/icons reads a live DataTable, so at the title screen both
    -- spellings answer nil and a green assertion here would mean nothing. The measurement —
    -- iconOf(blueprint spelling) hits via ROW_ID while Handle:iconOf on the same id misses — is
    -- a world-needing check and belongs in test/hooks/ as `native-two-spellings-icon`.
end)

s:test("a lazy native handle declares no mesh, so :render / :renderOn report false rather than lying",
function(t)
    -- The game already draws its own buildings and creatures. PalForge's render attaches OUR
    -- declared mesh, and a lazy handle has none — so an honest false, not a silent no-op that
    -- reads like success.
    local buildings = require("palforge.native.buildings")
    t:eq(buildings.Stone_Gate:mesh(), nil, "a lazy building declares no mesh")
    t:eq(buildings.Stone_Gate:render(), 0, "so nothing is attached, and it says 0")

    local pals = require("palforge.native.pals")
    t:eq(pals.BlueSkyDragon:mesh(), nil, "a lazy pal declares no mesh")
    t:eq(pals.BlueSkyDragon:renderOn(nil), false, "so :renderOn is false, not a pretend true")
end)

return s
