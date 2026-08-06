-- PalForge native.buildings: the catalog of the game's OWN placeable structures, declared
-- through api/building the same way a pack declares its own.
--
--   local buildings = require("palforge.native.buildings")
--   buildings.PalBoxV2:iconOf()         -- a NAMED handle for every row the game has
--   buildings.get("PalBoxV2")           -- the same handle, by id string
--   buildings.WorkBench:unlock()        -- curated: carries a mesh and a display name
--   buildings.publish("PalBoxV2")       -- opt in to TRACKING (and to persistence) — see below
--
--   (a) M.CATALOG  — every DT_BuildObjectDataTable_Common row id, 498 of them.
--   (b) M.<Name>   — a Building handle per row, built on first read. native/_catalog.lua owns
--                    the naming rule; for this table it is the identity, because every one of
--                    the 498 ids is already a Lua identifier.
--   (c) M.get(id)  — the same handles by id string; nil for anything not in the catalog.
--   (d) M.publish(id) — register that handle as a live building definition. THE ONLY THING IN
--                    THIS FILE THAT MAKES PALFORGE WRITE TO A SAVE.
--   (e) CURATED    — a few hand-written definitions (mesh + display name).
--
-- NOTHING IN THIS FILE REGISTERS ANYTHING AT LOAD, AND A READ REGISTERS NOTHING EITHER. That is
-- a deliberate change (2026-08-02) and it is the one item in this file with a save file on the
-- other end of it, so the measurement is written out rather than summarised:
--
--   * core/event.lua's refreshDefs walks object_manager.all("building") before each
--     500 ms scan. Every registered def is matched against the live actors, every match becomes
--     a TRACKED instance, and a newly tracked instance is PERSISTED immediately
--     (core/event.lua's scan -> persist(), which writes a record into the per-world
--     entities_<saveid> JSON). Nothing DELETES those records: the orphan pass added with F-7
--     quarantines a record whose build id no definition claims any more — it moves to the
--     file's `orphans` section, is logged, and moves back the moment something claims the id
--     again — so un-publishing a building later does not undo the writing, it relabels it.
--     Deliberately: quarantine is conservative because a pack that is merely not loaded today
--     must not cost the player their structures' state. The only thing that ever removes a
--     record is the ORPHAN_MAX cap, oldest first. So "do not write it in the first place" is
--     still the whole of the defence, which is what this file does.
--   * So `buildings.Stone_Foundation` used to be enough — one field read, in a tooltip — to
--     start writing a record for every stone foundation in the base, and walking M.CATALOG to
--     fill a picker registered all 498 and persisted the whole base.
--   * Worse, two of them did it with nobody reading anything: M.WorkBench and M.PalBox were
--     unconditional `Building{...}` calls at module load, so every install wrote a JSON record
--     for every workbench and pal box in every save, for content no pack had asked for. A
--     framework may not leave a growing file in a player's install as the price of being
--     installed.
--
-- The handles are unchanged; only their REGISTRATION is now opt-in. M.get / the named fields
-- build with `{ register = false }` (contract C2), and M.publish(id) hands the very same cached
-- handle to object_manager when a pack decides it wants the tracking.
--
-- WHAT A LAZY NATIVE HANDLE HONESTLY DOES, because a Building handle carries more actions than
-- a bare vanilla id can back:
--   * :unlock() and :iconOf() are REAL for every id here and need no registration at all: both
--     are id-driven table reads, and each id is a real build-object row.
--   * :instances() — and with it the lifecycle handlers, the deferred mesh attach and the
--     persisted record — answers EMPTY until you call M.publish(id) (or define your own
--     Building{ id = <the same id> }). It is core/event's registry-driven scan that fills it,
--     and an unregistered def is not in that registry. This is the publish gate above, stated
--     from the caller's side: tracking is a real capability with a real cost, so it is asked
--     for rather than assumed.
--   * :render() returns 0 and that is correct, not a failure. Building.Handle:render attaches
--     PalForge's OWN declared mesh to the live actors (api/building.lua:295) and a lazy handle
--     declares none — the game is already drawing the structure's real mesh. Only the curated
--     entries below, and a definition of your own, have a mesh to attach.
--   * :iconOf() DOES answer for real: core/icons reads DT_BuildObjectIconDataTable keyed by
--     exactly these row ids (567 of 571 rows carry an icon, measured 2026-07-26). Nothing has
--     to be declared for that — the id IS the key.
--   * :name() answers the id, not the in-game name. The localised one is a DT_BuildObjectNameText
--     row VALUE, and reading a row value from Lua is still unsolved on this build (the
--     item-datatable-row-read marker in api/item.lua). A curated entry names itself by hand.
--
-- ONE STRUCTURE, TWO SPELLINGS, AND WHAT THAT COSTS YOU. The game itself spells the primitive
-- workbench two ways and this catalog carries both, because both are real:
--
--   "WorkBench"  — the BLUEPRINT id (live actor BP_BuildObject_WorkBench_C). It is what the
--                  building runtime keys on, so it is the id the curated definition below uses
--                  and the id M.publish("WorkBench") makes track real workbenches.
--   "Workbench"  — the DT_BuildObjectDataTable_Common row FName (lowercase b), and therefore
--                  the key DT_BuildObjectIconDataTable answers to.
--
-- The consequence is not theoretical and it is not a typo to be fixed: `buildings.WorkBench` and
-- `buildings.Workbench` are TWO HANDLES for ONE structure with DIFFERENT capabilities.
-- `buildings.WorkBench:iconOf()` MISSES (there is no row of that spelling) and
-- `buildings.Workbench:iconOf()` HITS; conversely it is the "WorkBench" spelling that tracking
-- keys on, per the dump note on the curated definition below, so that is the one to publish.
-- native/pals.lua has exactly the same split for SheepBall / Sheepball, for the same reason.
--
-- What is done about it here, given that neither spelling can be dropped: the alternate is
-- carried as DATA in M.ROW_ID, and M.iconOf(id) follows it — so `buildings.iconOf("WorkBench")`
-- answers the game's own artwork while `buildings.WorkBench:iconOf()` still misses. Handle:iconOf
-- cannot consult it: it is api/building.lua's method and it reads self.id and self.icon only. A
-- Building.Spec field for the icon-table spelling (`iconId`) would close the gap on the handle
-- itself; until it exists this module's iconOf is the whole of it.

local Building = require("palforge.api.building")
local catalog  = require("palforge.native._catalog")

local M = {}

-- The one DataTable this catalog stands for. Named rather than described so a regeneration
-- cannot pick a different table by accident.
M.TABLE = "DT_BuildObjectDataTable_Common"

-- CATALOG (DATA): every DT_BuildObjectDataTable_Common row id — all 498 of them, verified
-- against dumps/catalog/datatables/DT_BuildObjectDataTable_Common.json (count 498, exact set
-- match, 2026-07-26). GENERATED — do not hand-edit; regenerate from a fresh dump.
M.CATALOG = {
  "FarmBlockV2_wheet", "FarmBlockV2_tomato", "FarmBlockV2_Lettuce", "FarmBlockV2_Berries", "FarmBlockV2_Carrot", "FarmBlockV2_Onion",
  "FarmBlockV2_Potato", "PalFoodBox", "Wooden_foundation", "Wooden_wall", "Wood_WindowWall", "Wood_TriangleWall",
  "Wooden_roof", "Wood_SlantedRoof", "Wooden_stair", "Wooden_DoorWall", "Wooden_pillar", "DefenseWall_Wood",
  "Wood_Gate", "Stone_Foundation", "Stone_wall", "Stone_WindowWall", "Stone_TriangleWall", "Stone_Roof",
  "Stone_SlantedRoof", "Stone_Stair", "Stone_DoorWall", "Stone_pillar", "DefenseWall", "Stone_Gate",
  "Metal_Foundation", "Metal_wall", "Metal_WindowWall", "Metal_TriangleWall", "Metal_Roof", "Metal_SlantedRoof",
  "Metal_Stair", "Metal_DoorWall", "Metal_pillars", "DefenseWall_Metal", "Metal_Gate", "DefenseBowGun",
  "DefenseMachinegun", "DefenseMissile", "DefenseWait", "ElectricGenerator", "FastTravelPoint", "ItemChest",
  "ItemChest_02", "ItemChest_03", "PlayerBed_02", "PlayerBed_03", "BuildableGoddessStatue", "Heater",
  "ElectricHeater", "Cooler", "ElectricCooler", "Torch", "WallTorch", "Lamp",
  "CeilingLamp", "LargeLamp", "LargeCeilingLamp", "Trap_LegHold", "Trap_LegHold_Big", "Trap_Noose",
  "Trap_MovingPanel", "Trap_MineElecShock", "Trap_MineFreeze", "Trap_MineAttack", "MedicalPalBed_02", "MedicalPalBed_03",
  "MedicalPalBed_04", "PalBoxV2", "DisplayCharacter", "CharacterRankUp", "SphereFactory_Black_01", "SphereFactory_Black_02",
  "SphereFactory_Black_03", "SphereFactory_Black_04", "HatchingPalEgg", "ElectricHatchingPalEgg", "MultiElectricHatchingPalEgg", "MultiHatchingPalEgg",
  "Spa", "Spa2", "Spa3", "BlastFurnace", "BlastFurnace2", "BlastFurnace3",
  "BlastFurnace4", "CampFire", "CookingStove", "ElectricKitchen", "HugeKitchen", "Factory_Hard_01",
  "Factory_Hard_02", "Factory_Hard_03", "Factory_Hard_04", "MedicineFacility_01", "MedicineFacility_02", "MedicineFacility_03",
  "StonePit", "CopperPit", "CopperPit_2", "WeaponFactory_Dirty_01", "WeaponFactory_Dirty_02", "WeaponFactory_Dirty_03",
  "WeaponFactory_Dirty_04", "Workbench", "StationDeforest2", "WorkBench_SkillUnlock", "Crusher", "FlourMill",
  "BreedFarm", "RepairBench", "ToolBoxV1", "OlympicCauldron", "Fountain", "FlowerBed",
  "Silo", "Stump", "MiningTool", "Cauldron", "Snowman", "TransmissionTower",
  "BaseCampWorkHard", "CoolerBox", "Refrigerator", "Signboard", "WallSignboard", "MonsterFarm",
  "DamagedScarecrow", "BaseCampBattleDirector", "Barrel_Wood", "Box_Wood", "Shelf_Wood", "Shelf_Cask_Wood",
  "Shelf_Hang01_Wood", "Shelf01_Stone", "Shelf02_Stone", "Shelf03_Stone", "Shelf04_Stone", "Shelf01_Wall_Iron",
  "Shelf05_Stone", "Shelf06_Stone", "Shelf07_Stone", "Shelf01_Wall_Stone", "Shelf01_Iron", "Shelf02_Iron",
  "Shelf03_Iron", "Shelf04_Iron", "Container01_Iron", "Box01_Iron", "Box02_Iron", "TableSquare_Wood",
  "TableCircular_Wood", "Bench_Wood", "Stool_Wood", "Stool_High_Wood", "Chair01_Wood", "Shelf_Hang02_Wood",
  "Counter_Wood", "Plant01_Plant", "Plant02_Plant", "Plant03_Plant", "Plant04_Plant", "Ivy01",
  "Ivy02", "Ivy03", "Rug01_Stone", "Rug02_Stone", "Rug03_Stone", "Rug04_Stone",
  "Chair01_Stone", "Chair02_Stone", "Stool01_Stone", "Desk01_Stone", "TableCircular01_Stone", "TableDresser01_Stone",
  "Sofa01_Stone", "Sofa02_Stone", "Sofa03_Stone", "BathTub_Stone", "Box01_Stone", "Partition_Stone",
  "TowlRack01_Stone", "Mirror01_Stone", "Mirror02_Stone", "Mirror01_Wall_Stone", "Piano01_Stone", "Piano02_Stone",
  "TableSink01_Stone", "Toilet01_Stone", "ToiletHolder01_Stone", "Curtain01_Wall_Stone", "Globe01_Stone", "Stove01_Stone",
  "Clock01_Wall_Iron", "Clock01_Stone", "Chair02_Iron", "Stool01_Iron", "TableCircular01_Iron", "Desk01_Iron",
  "TableSide01_Iron", "TableSquare01_Iron", "TableSquare02_Iron", "CableCoil01_Iron", "GarbageBag_Iron", "PipeClay01_Iron",
  "Tire01_Iron", "Barrel01_Iron", "Barrel02_Iron", "Barrel03_Iron", "Chair01_Iron", "Sofa01_Iron",
  "Sofa02_Iron", "Chair01_Pal", "GoalSoccer_Iron", "MachineGame01_Iron", "MachineVending01_Iron", "Television01_Iron",
  "SignExit_Ceiling_Iron", "SignExit_Wall_Iron", "TrafficCone01_Iron", "TrafficCone02_Iron", "TrafficCone03_Iron", "TrafficLight01_Iron",
  "TrafficSign01_Iron", "TrafficSign02_Iron", "TrafficSign03_Iron", "TrafficSign04_Iron", "TrafficBarricade01_Iron", "TrafficBarricade02_Iron",
  "TrafficBarricade03_Iron", "TrafficBarricade04_Iron", "TrafficBarricade05_Iron", "Decal_PalSticker_PinkCat", "Rug_Wood", "Light_FirePlace01",
  "Light_FirePlace02", "Light_LightPole01", "Light_LightPole02", "Light_LightPole03", "Light_LightPole04", "Light_FloorLamp01",
  "Light_FloorLamp02", "Light_CandleSticks_Top", "Light_CandleSticks_Wall", "Altar", "CoolerPalFoodBox", "DismantlingConveyor",
  "ElectricGenerator_Large", "OilPump", "CoalPit", "SulfurPit", "IceCrusher", "Glass_foundation",
  "Glass_wall", "Glass_WindowWall", "Glass_TriangleWall", "Glass_roof", "Glass_SlantedRoof", "Glass_stair",
  "Glass_DoorWall", "Glass_pillars", "SkinChange", "JapaneseStyle_wall_01", "JapaneseStyle_DoorWall_01", "JapaneseStyle_DoorWall_02",
  "JapaneseStyle_roof_01", "JapaneseStyle_roof_02", "JapaneseStyle_SlantedRoof", "JapaneseStyle_TriangleWall", "JapaneseStyle_WindowWall", "JapaneseStyle_foundation",
  "JapaneseStyle_stair", "JapaneseStyle_Pillar", "SanityDecrease1", "WorkSpeedIncrease1", "QuartzPit", "Factory_Money",
  "ItemChest_04", "MedicalPalBed_05", "BaseCampItemDispenser", "GuildChest", "WoodCreator", "Expedition",
  "ItemBooth", "Lab", "PalBooth", "OperatingTable", "ManualElectricGenerator", "Farm_SkillFruits",
  "Wooden_ladder", "PalMedicineBox", "EnergyStorage_Electric", "Headstone", "JapaneseStyle_DoorWall_03", "Byobu",
  "Kakejiku", "Zaisu", "Zabuton", "Irori", "Toro", "Andon",
  "Shishiodoshi", "Bonsai", "Koro", "Seika", "Tansu", "Fudukue",
  "CompositeDesk", "GlobalPalStorage", "DimensionPalStorage", "Wire_Fence", "SF_foundation", "SF_wall",
  "SF_WindowWall", "SF_TriangleWall", "SF_roof", "SF_SlantedRoof", "SF_stair", "SF_DoorWall",
  "SF_Pillars", "LilyQueenStatue", "ConservationGroupBannerA", "ConservationGroupBannerB", "Banyan_Big", "Hunter_GangFlag",
  "PalCage", "WoodenBarricade", "WallTorch02", "CandleStand", "FireStand", "Wood_Fence",
  "Stone_Fence", "Iron_Fence", "Glass_Fence", "JapaneseStyle_Fence", "SF_Fence", "CrystalPit",
  "FishingPond1", "FishingPond2", "BaseCampWorkerExtraStation", "SF_Desk", "SF_Chair", "LanternTop",
  "Shrine_Lantern", "GuardianDogStatue", "Hunter_Flag", "Hunter_Banner", "Believer_Flag", "Believer_Banner",
  "FireCult_Flag", "FireCult_Banner", "Police_Flag", "Police_Banner", "Scientist_Flag", "Scientist_Banner",
  "Ninja_Flag", "Ninja_Banner", "YakushimaBoss002_Relic", "Wooden_TriangleFoundation", "Wooden_DiagonalWall", "Wooden_TriangleRoof",
  "Wooden_TriangleStairsCorner", "Wood_TriangleWallReverse", "Wooden_WallGate", "DamagedScarecrow_Test", "Wooden_SlopedRoofCorner", "Wooden_PyramidRoof",
  "Stone_TriangleFoundation", "Stone_DiagonalWall", "Stone_TriangleRoof", "Stone_TriangleStairsCorner", "Stone_TriangleWallReverse", "Stone_WallGate",
  "Stone_SlopedRoofCorner", "Stone_PyramidRoof", "Iron_TriangleFoundation", "Iron_DiagonalWall", "Iron_TriangleRoof", "Iron_TriangleStairsCorner",
  "Iron_TriangleWallReverse", "Iron_WallGate", "Iron_SlopedRoofCorner", "Iron_PyramidRoof", "Glass_TriangleFoundation", "Glass_DiagonalWall",
  "Glass_TriangleRoof", "Glass_TriangleStairsCorner", "Glass_TriangleWallReverse", "Glass_WallGate", "Glass_SlopedRoofCorner", "Glass_PyramidRoof",
  "JapaneseStyle_TriangleFoundation", "JapaneseStyle_DiagonalWall", "JapaneseStyle_TriangleRoof_01", "JapaneseStyle_TriangleRoof_02", "JapaneseStyle_TriangleStairsCorner_01", "JapaneseStyle_TriangleStairsCorner_02",
  "JapaneseStyle_TriangleWallReverse", "JapaneseStyle_WallGate", "JapaneseStyle_SlopedRoofCorner", "JapaneseStyle_PyramidRoof", "SF_TriangleFoundation", "SF_DiagonalWall",
  "SF_TriangleRoof", "SF_TriangleStairsCorner", "SF_TriangleWallReverse", "SF_WallGate", "SF_SlopedRoofCorner", "SF_PyramidRoof",
  "Wooden_SlopedRoofCornerReverse", "Stone_SlopedRoofCornerReverse", "Iron_SlopedRoofCornerReverse", "Glass_SlopedRoofCornerReverse", "JapaneseStyle_SlopedRoofCornerReverse", "SF_SlopedRoofCornerReverse",
  "Ancient_SlopedRoofCornerReverse", "AncientWorkBench", "AncientElectricGenerator", "AncientBlastFurnace", "AncientCookingStove", "AncientMultiProduct",
  "AncientFarmBlock", "DefenseMachinegun_AutoTurret", "MultiElectricHatchingPalEggWithBreed", "AncientRelicRecycler", "SkyIslandOrePit", "FurnitureTree01_Green",
  "FurnitureTree02_Green", "FurnitureTree03_Green", "FurnitureTree01_Red", "FurnitureTree02_Red", "FurnitureTree03_Red", "FurnitureTree01_Yellow",
  "FurnitureTree02_Yellow", "FurnitureTree03_Yellow", "FurnitureTree01_Cherry", "FurnitureTree02_Cherry", "FurnitureTree03_Cherry", "FurnitureTree01_Tropical",
  "FurnitureTree02_Tropical", "FurnitureTree03_Tropical", "FurnitureTree01_Snow", "FurnitureTree02_Snow", "FurnitureTree03_Snow", "FurnitureTree01_Desert",
  "FurnitureTree02_Desert", "FurnitureTree03_Desert", "FurnitureTree01_Bamboo", "FurnitureTree02_Bamboo", "FurnitureTree03_Bamboo", "FurnitureBush01_Green",
  "FurnitureBush01_Yellow", "FurnitureBush01_Flower", "FurnitureBush02_Flower", "FurnitureBush01_Tropical", "FurnitureBush01_Snow", "FurnitureStone01",
  "TableCircular_Wood_None", "TableSquare_Wood_None", "JetDragonStatue", "IceHorseStatue", "ArcadeVideoGame", "Ancient_foundation",
  "Ancient_wall", "Ancient_roof", "Ancient_stair", "Ancient_DoorWall", "Ancient_TriangleWall", "Ancient_SlantedRoof",
  "Ancient_WindowWall", "Ancient_Pillars", "DarkIsland_Flag", "DarkIsland_Banner", "SkyIsland_Flag", "SkyIsland_Banner",
  "Ancient_TriangleFoundation", "Ancient_DiagonalWall", "Ancient_TriangleRoof", "Ancient_TriangleStairsCorner", "Ancient_TriangleWallReverse", "Ancient_WallGate",
  "Ancient_SlopedRoofCorner", "Ancient_PyramidRoof", "Ancient_Fence", "BaseCampWorkHard02", "BaseCampWorkHard03", "StationDeforest3",
  "Clinic", "Ancient_Clinic", "Ancient_Spa", "Ancient_AirConditioner", "Ancient_MedicalPalBed", "OilPump02",
}

-- Membership set + on-demand cache for get(), plus the alias table the naming rule produces
-- (empty here: all 498 ids are already Lua identifiers, so every name is its own id). One pass,
-- the same one that used to build `set` alone.
local set, aliases, unnamed = catalog.index(M.CATALOG)
local cache = {}

---Names that are NOT ids — a second spelling for a row the game names with punctuation.
---Empty for this catalog; see native/_catalog.lua rule (2).
M.ALIASES = aliases
---Rows with no named field, and why. Empty for this catalog; see rules (3) and (4).
M.UNNAMED = unnamed

-- get(id): a Building wrapper for ANY real catalog id, built on first use + cached.
-- Returns nil if id is not a known build-object row. NOT called eagerly — nothing walks the
-- whole catalog, and neither does reading a named field, which comes through here.
--
-- `{ register = false }` (contract C2) is the publish gate, and for THIS domain it is the
-- difference between a read and a write to the player's save: a registered building def is
-- picked up by core/event's refreshDefs on the next 500 ms scan and every matching actor in the
-- world becomes a tracked, persisted instance. See the header. The handle is fully built and
-- fully cached — only object_manager is left out of it, until M.publish(id) says otherwise.
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    -- `iconId` carries the DataTable ROW spelling when it differs from the blueprint /
    -- build id. M.ROW_ID has held that pair as data for a while, but only this module's
    -- own M.iconOf consulted it, so the HANDLE a caller actually holds still missed —
    -- `buildings.WorkBench:iconOf()` is the case. Declaring it on the spec moves the
    -- workaround to where the lookup happens, and Class:iconOf tries it before the id.
    local h = Building({ id = id, iconId = M.ROW_ID and M.ROW_ID[id] or nil }, { register = false, pack = catalog.PACK })
    cache[id] = h
    return h
end

---Publish this catalog's handle for `id` as a LIVE building definition: register it with
---object_manager so core/event's scan starts resolving placed actors to it. That is what turns
---:instances(), the lifecycle handlers, the deferred mesh attach and the persisted record on —
---and it is also what starts writing to the save, which is why it is a call and not a read.
---
---Idempotent, and it publishes the SAME handle the named field hands back, so a curated entry
---keeps its mesh and its display name. Returns nil for an id this catalog does not have.
---
---   local buildings = require("palforge.native.buildings")
---   buildings.publish("WorkBench")            -- now workbenches are tracked and persisted
---   for _, inst in ipairs(buildings.WorkBench:instances()) do ... end
---
---@param id string
---@return Building.Handle?
function M.publish(id)
    local h = M.get(id)
    if not h then return nil end
    catalog.publish("building", h, "native.buildings")
    return h
end

---The DataTable row spelling for an id whose BLUEPRINT spelling differs — the two-spellings
---note in the header. Published as data so the mismatch is readable at runtime rather than
---folklore, and consumed by M.iconOf below.
M.ROW_ID = { WorkBench = "Workbench" }

---This structure's icon, resolved through BOTH spellings: the id as given, then the row
---spelling M.ROW_ID knows it by. `buildings.WorkBench:iconOf()` misses because the icon table
---is keyed by the DataTable row FName and "WorkBench" is not one; this function is the way in
---that does not make the caller know that.
---@param id string
---@return any?  # texture ref from DT_BuildObjectIconDataTable, else nil
function M.iconOf(id)
    local h = M.get(id)
    local tex = h and h:iconOf()
    if tex ~= nil then return tex end
    local row = id and M.ROW_ID[id]
    local rh = row and M.get(row)
    return rh and rh:iconOf() or nil
end

-- ---- CURATED wrappers (real dump ids, with mesh + display name) ----
--
-- THESE TWO USED TO REGISTER THEMSELVES AT MODULE LOAD, and that is the defect this file was
-- opened for. `require("palforge.native.buildings")` happens at mod start for every install
-- (core/registry.lua:30), so an unconditional Building{...} here meant core/event tracked and
-- PERSISTED every workbench and every pal box in every save from the first scan onwards, for
-- content nobody had asked for, into a file that only ever grows — the orphan pass added since
-- (core/event.lua's pruneOrphans) QUARANTINES a record nothing claims rather than deleting it,
-- by design, so removing the definition afterwards would not have undone the write.
--
-- They are still declared here, in full, with their meshes — a pack can read them, unlock them,
-- ask them for an icon, and take their mesh spec. What changed is that the declaration is no
-- longer a REGISTRATION: `{ register = false }` builds and returns the handle and stops there.
-- Everything registration bought is one call away and is now attributable to whoever made it:
--
--   require("palforge.native.buildings").publish("WorkBench")
--
-- and a pack that wants its own behaviour on the same structure keeps doing what it always did,
-- which is to declare Building{ id = "WorkBench", events = { ... } } and be registered by it.

M.WorkBench = Building({
    -- WorkBench — the vanilla primitive workbench, bound to Palworld's OWN build object.
    -- Real dispatch/build id "WorkBench" (live actor BP_BuildObject_WorkBench_C,
    -- dump/04_live_objects + 06_events). The DT_BuildObjectDataTable row FName is spelled
    -- "Workbench" (lowercase b); the runtime keys off the BP id, so we define under
    -- "WorkBench" — which is therefore NOT itself a CATALOG member (pre-seeded below).
    id          = "WorkBench",
    -- Same split as SheepBall/Sheepball: the build id is "WorkBench", the icon row
    -- "Workbench". Class:iconOf tries iconId before id, so this handle hits.
    iconId      = "Workbench",
    name        = "Workbench",
    gridCm      = 100,
    mesh = {
        kind  = "static",
        model = "/Game/Pal/Model/Prop/Architecture/WorkBenchPrimitive/SM_WorkBenchPrimitive.SM_WorkBenchPrimitive",
    },
}, { register = false, pack = catalog.PACK })

M.PalBox = Building({
    -- PalBox — the base-camp Pal storage box. Real build id "PalBoxV2" (live actor
    -- BP_BuildObject_PalBoxV2_C; DT row FName also "PalBoxV2", a CATALOG member).
    id          = "PalBoxV2",
    name        = "Pal Box",
    gridCm      = 100,
    mesh = {
        kind  = "static",
        model = "/Game/Pal/Model/Other/PalBox/SM_PalBox.SM_PalBox",
    },
}, { register = false, pack = catalog.PACK })

-- Pre-seed curated into the get() set + cache so get(id) returns the curated handle
-- (mesh/lifecycle intact) rather than a bare one, and so get("WorkBench") resolves even
-- though the DT row is spelled "Workbench".
--
-- NOTE what this makes of the named fields, because the two spellings are BOTH real and mean
-- different things. `buildings.WorkBench` is the curated handle on the blueprint id the runtime
-- dispatches by; `buildings.Workbench` is the DataTable row, whose lazy handle is what the icon
-- table answers to. Neither is a typo for the other and neither is hidden — the split is written
-- out in the header and carried as data in M.ROW_ID, and M.iconOf(id) is the one call that
-- follows it. The same holds for M.PalBox, which is a nickname rather than an id —
-- `buildings.PalBoxV2` is the row's own name and resolves to this very handle through the cache
-- below.
for _, h in ipairs({ M.WorkBench, M.PalBox }) do
    set[h.id] = true
    cache[h.id] = h
end

-- LAST: hang the lazy named fields off the module. After the curated definitions, so the
-- rule-(4) shadow check sees the module's complete own surface. See native/_catalog.lua.
catalog.expose(M, { set = set, aliases = aliases, unnamed = unnamed,
                    get = M.get, label = "native.buildings" })

return M
