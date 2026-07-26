-- PalForge native.buildings: the HYBRID catalog for placeable structures. ONE file
-- per data domain, replacing the old native/building/ subdirectory.
--
--   (a) M.CATALOG  — every real DT_BuildObjectDataTable_Common row id from the dump.
--   (b) M.get(id)  — a lazy, cached Building handle for ANY catalog id (nil otherwise).
--   (c) CURATED    — a few hand-written definitions (mesh + lifecycle).
--
-- Only the CURATED definitions call Building{ ... } at load, so they self-register into
-- object_manager; the CATALOG stays plain DATA and get(id) defines on demand. That is why
-- requiring this file never registers the hundreds of catalog ids.
--
--   local buildings = require("palforge.native.buildings")
--   buildings.get("PalBoxV2")   -- lazy handle    buildings.WorkBench:unlock()  -- curated

local Building = require("palforge.api.building")

local M = {}

-- CATALOG (DATA): every DT_BuildObjectDataTable_Common row id (dump/01_datatables.txt).
-- GENERATED — do not hand-edit; regenerate from a fresh dump.
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

-- membership set + on-demand cache for get().
local set = {}
for _, id in ipairs(M.CATALOG) do set[id] = true end
local cache = {}

-- get(id): a Building wrapper for ANY real catalog id, built on first use + cached.
-- Returns nil if id is not a known build-object row. defining sets .id and registers
-- the class into object_manager. NOT called eagerly — nothing walks the whole catalog.
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    local h = Building{ id = id }
    cache[id] = h
    return h
end

-- ---- CURATED wrappers (real dump ids, with mesh + lifecycle) ----

-- WorkBench — the vanilla primitive workbench, bound to Palworld's OWN build object.
-- Real dispatch/build id "WorkBench" (live actor BP_BuildObject_WorkBench_C,
-- dump/04_live_objects + 06_events). The DT_BuildObjectDataTable row FName is spelled
-- "Workbench" (lowercase b); the runtime keys off the BP id, so we define under
-- "WorkBench" — which is therefore NOT itself a CATALOG member (pre-seeded below).
M.WorkBench = Building{
    id          = "WorkBench",
    name        = "Workbench",
    gridCm      = 100,
    mesh = {
        kind  = "static",
        model = "/Game/Pal/Model/Prop/Architecture/WorkBenchPrimitive/SM_WorkBenchPrimitive.SM_WorkBenchPrimitive",
    },
}

-- PalBox — the base-camp Pal storage box. Real build id "PalBoxV2" (live actor
-- BP_BuildObject_PalBoxV2_C; DT row FName also "PalBoxV2", a CATALOG member).
M.PalBox = Building{
    id          = "PalBoxV2",
    name        = "Pal Box",
    gridCm      = 100,
    mesh = {
        kind  = "static",
        model = "/Game/Pal/Model/Other/PalBox/SM_PalBox.SM_PalBox",
    },
}

-- Pre-seed curated into the get() set + cache so get(id) returns the curated handle
-- (mesh/lifecycle intact) rather than a bare one, and so get("WorkBench") resolves even
-- though the DT row is spelled "Workbench".
for _, h in ipairs({ M.WorkBench, M.PalBox }) do
    set[h.id] = true
    cache[h.id] = h
end

return M
