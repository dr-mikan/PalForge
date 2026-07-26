-- PalForge native.items: the catalog of the game's OWN inventory content, declared through
-- api/item the same way a pack declares its own.
--
--   local items = require("palforge.native.items")
--   items.Arrow_Fire:give(20)      -- a NAMED handle for every row the game has
--   items.get("Arrow_Fire")        -- the same handle, by id string
--   items.Wood:give(5)             -- curated: carries an onObtain handler
--
--   (a) M.CATALOG  — every DT_ItemDataTable_Common row id, 2466 of them.
--   (b) M.<Name>   — an Item handle per row, built on first read. native/_catalog.lua owns the
--                    naming rule; for this table it is the identity, because every one of the
--                    2466 ids is already a Lua identifier.
--   (c) M.get(id)  — the same handles by id string; nil for anything not in the catalog.
--   (d) CURATED    — a few hand-written definitions with live lifecycle hooks.
--
-- Only the CURATED definitions call Item{ ... } at load, so only they self-register into
-- object_manager at mod start; a named field and get(id) both define on demand. That is why
-- requiring this file never registers the thousands of catalog ids.
--
-- WHAT A LAZY NATIVE HANDLE HONESTLY DOES. The three ACTIONS are the real thing and are
-- measured (api/item.lua's ACTIONS block): :count reads the live inventory through the game's
-- own CountItemNum, :give writes through AddItem_ServerInternal, :take consumes through
-- RequestConsumeItem, and all three report the measurement rather than the call. Every id here
-- is a real DT_ItemDataTable_Common row, so all three mean something for all 2466.
--
-- The QUERIES are a different matter and must not be read as facts about the game:
--   * :maxStack() answers 1 and :category() answers "material" for a lazy handle. Those are
--     Item.Spec's DEFAULTS (api/item.lua:136-140), not the row's MaxStackCount column. The real
--     values are DT_ItemDataTable row VALUES and reading a row value from Lua is still unsolved
--     on this build — see the item-datatable-row-read marker in api/item.lua. Deliberately NOT
--     papered over by guessing per-id numbers here: a made-up 9999 would be indistinguishable
--     from a measured one.
--   * :name() answers the id, not the localised in-game name (a DT_ItemNameText row value, same
--     unsolved read). The curated entries below name themselves by hand.
--   * :recipeOf() answers nil even though DT_ItemRecipeDataTable_Common has a row for most of
--     these. Same read.
--   * :iconOf() DOES answer for real, and needs nothing declared: core/icons reads
--     DT_ItemIconDataTable keyed by exactly these row ids — 1183 of 1207 rows carry an icon,
--     measured 2026-07-26. The 1259 catalog ids with no icon row fall back to nil, honestly.

local Item    = require("palforge.api.item")
local catalog = require("palforge.native._catalog")
local log     = require("palforge.utils.log").scope("native.items")

local M = {}

-- The one DataTable this catalog stands for.
M.TABLE = "DT_ItemDataTable_Common"

-- CATALOG (DATA): every DT_ItemDataTable_Common row id — all 2466 of them, verified against
-- dumps/catalog/datatables/DT_ItemDataTable_Common.json (count 2466, exact set match,
-- 2026-07-26). GENERATED — do not hand-edit; regenerate from a fresh dump.
M.CATALOG = {
  "Money", "AnimalSkin", "AnimalSkin2", "Arrow", "Arrow_Poison", "Arrow_Fire",
  "AssaultRifle_Default1", "Scales", "Scales2", "Axe_Tier_00", "Axe_Tier_01", "Axe_Tier_02",
  "Axe_Tier_03", "MetalDetector", "Bat", "Bat2", "MeatCutterKnife", "ElecBaton",
  "Bat_NPC", "Berries", "Berries2", "Baked_Berries", "BowGun", "CaptureRope",
  "Charcoal", "Claws", "Claws2", "ClawsPendant", "Cloth", "Cloth2",
  "ClothArmor", "ClothHat", "Coal", "CopperArmor", "CopperHelmet", "CopperIngot",
  "CopperOre", "DoubleBarrelShotgun", "ElectronicCircuit", "EnergyDrink", "ExplosiveBullet", "Fang",
  "Fang2", "FangNecklace", "FarmCrop_Tmp", "Fiber", "FishMeat", "FishMeat2",
  "Flint", "FurArmor", "FurHelmet", "GrilledMeat", "GunPowder", "GunPowder2",
  "HandGun_Default", "DecalGun_1", "DecalGun_2", "DecalGun_3", "DecalGun_4", "DecalGun_5",
  "Handgun_NPC", "LaserRifle_NPC", "Herbs", "Medicines", "LuxuryMedicines", "MindControlDrug",
  "Poppy", "Opium", "Narcotic", "StatusPointResetSan", "HomingSphereLauncher", "IronArmor",
  "IronHelmet", "IronIngot", "IronOre", "Kitsunebi_Fire", "LargeBullet", "LaserBullet",
  "LaserRifle", "Launcher_Default", "Launcher_Meat", "Leather", "Leather2", "Processed_Wood",
  "HighGrade_Processed_Wood", "Premium_Processed_Wood", "MachineParts", "MachineParts2", "Meat", "Meat2",
  "PalSphere", "PalSphere_Mega", "PalSphere_Giga", "PalSphere_Tera", "PalSphere_Master", "PalSphere_Legend",
  "PalSphere_Robbery", "PalSphere_Debug", "Pan", "PenguinLauncher", "Pickaxe_Tier_00", "Pickaxe_Tier_01",
  "Pickaxe_Tier_02", "Pickaxe_Tier_03", "PumpActionShotgun", "RocketLauncher_NPC", "SniperRifle_Default", "AssaultRifle_NPC",
  "AssaultRifle_NPC_GrassBoss", "BowGun_NPC", "Seed_Tmp", "Sharkkid_Scale", "Shotgun_NPC", "FlameThrower_NPC",
  "GatlingGun_NPC", "FragGrenade_NPC", "SingleShotRifle", "SmallBullet", "InkBullet", "HandgunBullet",
  "RifleBullet", "ShotgunBullet", "RoughBullet", "MachingunBullet", "AssaultRifleBullet", "MagnumBullet",
  "SphereLauncher", "SphereLauncher_Once", "StealArmor", "StealHelmet", "StealIngot", "Stone",
  "Pal_crystal_L", "PAL_Growth_Stone_S", "PAL_Growth_Stone_XL", "Unko_S", "Unko_L", "Sword",
  "ThrowStone", "FragGrenade", "FragGrenade_Fire", "FragGrenade_Elec", "FragGrenade_Ice", "Tomato",
  "VenisonBoiledInTomato", "WaterBucket", "WeakerBow", "Bow_Poison", "Bow_Fire", "BowGun_Poison",
  "BowGun_Fire", "RecurveBow", "Bow_triple", "Bow_Fifth", "BerrySeeds", "PotatoSeedPotatoes",
  "TomatoSeeds", "WheatSeeds", "Wheat", "Flour", "Potato_old", "Corn",
  "Pumpkin", "Baked_Potato", "Wood", "Wood_Fine", "Wood_WorldTree", "Wool",
  "CrudeOil", "Plastic", "Computer", "AIcore", "Bio_Coolant", "Bio_Battery",
  "Thermal_Core", "Corrosive_Solvent", "Lettuce", "Grape", "Hop", "Egg",
  "Milk", "HotMilk", "JamBun", "Potage", "Salad", "Omelet",
  "FriedVegetables", "HotDog", "Pancake", "MarinatedMushrooms", "MushroomSoup", "Curry_old",
  "Carbonara", "BLT", "Cheeseburger", "Pizza", "MeatSauce", "Cake",
  "MushroomStew", "Sandwich", "CornSoup", "Stew", "Hamburger", "GrilledFish",
  "SeafoodSoup", "FriedEggs", "LuxuryOmelette", "Beer", "Wine", "Antibiotic_Normal",
  "Antibiotic_Good", "Antibiotic_Super", "FishingRod_Old", "FishingRod_Super", "FishingRod_Legendary", "Torch",
  "Glider_Old", "Glider_Good", "Glider_Super", "Glider_Legendary", "PV_Glider_Manta", "LightzHelmet",
  "GasMask", "NightVisionGoggles", "Relic", "Ruby", "Sapphire", "Eemerald",
  "Diamond", "CashFang", "CashScales", "TechnologyBook_G1", "TechnologyBook_G2", "TechnologyBook_G3",
  "AncientTechnologyBook_G1", "SkillUnlock_Carbunclo", "SkillUnlock_Garm", "Debug_Handgun_Poison", "Debug_Handgun_Burn", "Debug_Handgun_Wetness",
  "Debug_Handgun_Freeze", "Debug_Handgun_Electrical", "Debug_Handgun_Muddy", "Debug_Handgun_IvyCling", "Debug_Handgun_Darkness", "Debug_Handgun_Stun",
  "Debug_Handgun_AttackUp", "Debug_Handgun_DefenseUp", "AirGrapplingGun", "PalEgg_Normal_01", "PalEgg_Normal_02", "PalEgg_Normal_03",
  "PalEgg_Normal_04", "PalEgg_Normal_05", "PalEgg_Fire_01", "PalEgg_Fire_02", "PalEgg_Fire_03", "PalEgg_Fire_04",
  "PalEgg_Fire_05", "PalEgg_Water_01", "PalEgg_Water_02", "PalEgg_Water_03", "PalEgg_Water_04", "PalEgg_Water_05",
  "PalEgg_Leaf_01", "PalEgg_Leaf_02", "PalEgg_Leaf_03", "PalEgg_Leaf_04", "PalEgg_Leaf_05", "PalEgg_Electricity_01",
  "PalEgg_Electricity_02", "PalEgg_Electricity_03", "PalEgg_Electricity_04", "PalEgg_Electricity_05", "PalEgg_Ice_01", "PalEgg_Ice_02",
  "PalEgg_Ice_03", "PalEgg_Ice_04", "PalEgg_Ice_05", "PalEgg_Earth_01", "PalEgg_Earth_02", "PalEgg_Earth_03",
  "PalEgg_Earth_04", "PalEgg_Earth_05", "PalEgg_Dark_01", "PalEgg_Dark_02", "PalEgg_Dark_03", "PalEgg_Dark_04",
  "PalEgg_Dark_05", "PalEgg_Dragon_01", "PalEgg_Dragon_02", "PalEgg_Dragon_03", "PalEgg_Dragon_04", "PalEgg_Dragon_05",
  "Shield_01", "Shield_02", "Shield_03", "Shield_04", "Shield_05", "RepairKit",
  "PalCrystal_Ex", "SkillUnlock_Umihebi_Fire", "SkillUnlock_Deer_Ground", "SkillUnlock_Hedgehog_Ice", "SkillUnlock_FlowerDinosaur_Electric", "SkillUnlock_GrassMammoth_Ice",
  "SkillUnlock_LazyDragon_Electric", "SkillUnlock_FireKirin_Dark", "SkillUnlock_SakuraSaurus_Water", "SkillUnlock_FairyDragon_Water", "SkillUnlock_Manticore_Dark", "SkillUnlock_Suzaku_Water",
  "SkillUnlock_Serpent_Ground", "SkillUnlock_VolcanicMonster_Ice", "SkillUnlock_IceHorse_Dark", "SkillUnlock_GrassPanda_Electric", "SkillUnlock_Yeti_Grass", "SkillUnlock_KingAlpaca_Ice",
  "SkillUnlock_BirdDragon_Ice", "SkillUnlock_WindChimes_Ice", "SkillUnlock_Umihebi", "SkillUnlock_Deer", "SkillUnlock_Hedgehog", "SkillUnlock_Kitsunebi",
  "SkillUnlock_Boar", "SkillUnlock_Monkey", "SkillUnlock_Penguin", "SkillUnlock_Alpaca", "SkillUnlock_FlowerDinosaur", "SkillUnlock_GrassMammoth",
  "SkillUnlock_Kirin", "SkillUnlock_ElecPanda", "SkillUnlock_LazyDragon", "SkillUnlock_FireKirin", "SkillUnlock_SakuraSaurus", "SkillUnlock_FlameBuffalo",
  "SkillUnlock_BlueDragon", "SkillUnlock_FairyDragon", "SkillUnlock_FengyunDeeper", "SkillUnlock_ColorfulBird", "SkillUnlock_Eagle", "SkillUnlock_NegativeOctopus",
  "SkillUnlock_FlyingManta", "SkillUnlock_GhostBeast", "SkillUnlock_FlowerRabbit", "SkillUnlock_Manticore", "SkillUnlock_Suzaku", "SkillUnlock_Serpent",
  "SkillUnlock_RaijinDaughter", "SkillUnlock_VolcanicMonster", "SkillUnlock_AmaterasuWolf", "SkillUnlock_DreamDemon", "SkillUnlock_BlackFurDragon", "SkillUnlock_IceHorse",
  "SkillUnlock_Horus", "SkillUnlock_KingBahamut", "SkillUnlock_IceDeer", "SkillUnlock_BlackGriffon", "SkillUnlock_ElecLion", "SkillUnlock_GuardianDog",
  "SkillUnlock_BlackMetalDragon", "SkillUnlock_SkyDragon", "SkillUnlock_ThunderDog", "SkillUnlock_GrassPanda", "SkillUnlock_Yeti", "SkillUnlock_HawkBird",
  "SkillUnlock_JetDragon", "SkillUnlock_HadesBird", "SkillUnlock_KingAlpaca", "SkillUnlock_SaintCentaur", "SkillUnlock_DarkMutant", "SkillUnlock_ThunderBird",
  "SkillUnlock_RedArmorBird", "SkillUnlock_BlackCentaur", "SkillUnlock_MopKing", "SkillUnlock_GoldenHorse", "SkillUnlock_BadCatgirl", "SkillUnlock_NaughtyCat",
  "SkillUnlock_FeatherOstrich", "SkillUnlock_DrillGame", "SkillUnlock_BirdDragon", "SkillUnlock_WeaselDragon", "SkillUnlock_WindChimes", "MakeshiftHandgun",
  "Accessory_HP_1", "Accessory_HP_2", "Accessory_HP_3", "Accessory_AT_2", "Accessory_AT_3", "Accessory_defense_1",
  "Accessory_defense_2", "Accessory_defense_3", "Accessory_WorkSpeed_1", "Accessory_WorkSpeed_2", "Accessory_WorkSpeed_3", "Accessory_HeatResist_1",
  "Accessory_HeatResist_2", "Accessory_HeatResist_3", "Accessory_CoolResist_1", "Accessory_CoolResist_2", "Accessory_CoolResist_3", "Accessory_NormalResist_1",
  "Accessory_NormalResist_2", "Accessory_NormalResist_3", "Accessory_FireResist_1", "Accessory_FireResist_2", "Accessory_FireResist_3", "Accessory_AquaResist_1",
  "Accessory_AquaResist_2", "Accessory_AquaResist_3", "Accessory_ThunderResist_1", "Accessory_ThunderResist_2", "Accessory_LeafResist_1", "Accessory_LeafResist_2",
  "Accessory_IceResist_3", "Accessory_EarthResist_1", "Accessory_EarthResist_2", "Accessory_EarthResist_3", "Accessory_DarkResist_1", "Accessory_DarkResist_2",
  "Accessory_DarkResist_3", "Accessory_DragonResist_1", "Accessory_DragonResist_2", "Accessory_DragonResist_3", "PalUpgradeStone", "PalUpgradeStone2",
  "PalUpgradeStone3", "Mushroom", "BakedMushroom", "Sulfur", "Honey", "Sweet",
  "Quartz", "PalOil", "Polymer", "ElectricOrgan", "Venom", "FireOrgan",
  "IceOrgan", "bone", "Sand", "Silicon", "Cement", "CarbonFiber",
  "Horn", "PalFluid", "PalItem_ColorfulBird", "PalItem_PlantSlime", "PalItem_CaptainPenguin", "PalItem_CatMage",
  "SkillCard_PowerShot", "SkillCard_PowerBall", "SkillCard_HyperBeam", "SkillCard_AirCanon", "SkillCard_SelfDestruct", "SkillCard_WindCutter",
  "SkillCard_GrassTornado", "SkillCard_SolarBeam", "SkillCard_SeedMachinegun", "SkillCard_RootAttack", "SkillCard_SeedMine", "SkillCard_WaterGun",
  "SkillCard_WaterBall", "SkillCard_HydroPump", "SkillCard_AquaJet", "SkillCard_BubbleShot", "SkillCard_AcidRain", "SkillCard_FireBlast",
  "SkillCard_Flamethrower", "SkillCard_FireBall", "SkillCard_FlareArrow", "SkillCard_FireSeed", "SkillCard_Inferno", "SkillCard_FlareTornado",
  "SkillCard_ElecWave", "SkillCard_Thunderbolt", "SkillCard_LineThunder", "SkillCard_ThunderFunnel", "SkillCard_SpreadPulse", "SkillCard_LockonLaser",
  "SkillCard_ThunderBall", "SkillCard_ThreeThunder", "SkillCard_LightningStrike", "SkillCard_ThrowRock", "SkillCard_SandTornado", "SkillCard_RockLance",
  "SkillCard_MudShot", "SkillCard_StoneShotgun", "SkillCard_IceMissile", "SkillCard_BlizzardLance", "SkillCard_IcicleThrow", "SkillCard_IceBlade",
  "SkillCard_FrostBreath", "SkillCard_DarkWave", "SkillCard_ShadowBall", "SkillCard_Psychokinesis", "SkillCard_PoisonShot", "SkillCard_GhostFlame",
  "SkillCard_DarkLaser", "SkillCard_DragonBreath", "SkillCard_DragonCanon", "SkillCard_DragonWave", "SkillCard_DragonMeteor", "PalItem_ToSell_01",
  "PalItem_ToSell_02", "PalItem_ToSell_03", "PalItem_ToSell_04", "PalItem_ToSell_05", "MonsterEquipWeapon_Dummy", "Spear",
  "Spear_2", "Spear_3", "Spear_QueenBee", "Spear_SoldierBee", "Spear_ForestBoss", "Lantern",
  "AutoMealPouch_Tier1", "AutoMealPouch_Tier2", "AutoMealPouch_Tier3", "AutoMealPouch_Tier4", "AutoMealPouch_Tier5", "GrapplingGun",
  "GrapplingGun2", "GrapplingGun3", "GrapplingGun4", "Head001", "Head001_2", "Head001_3",
  "Head001_4", "Head001_5", "Head002", "Head002_2", "Head002_3", "Head002_4",
  "Head002_5", "Head003", "Head003_2", "Head003_3", "Head003_4", "Head003_5",
  "Head004", "Head004_2", "Head004_3", "Head004_4", "Head004_5", "Head005",
  "Head005_2", "Head005_3", "Head005_4", "Head005_5", "Head006", "Head006_2",
  "Head006_3", "Head006_4", "Head006_5", "Head007", "Head007_2", "Head007_3",
  "Head007_4", "Head007_5", "Head008", "Head008_2", "Head008_3", "Head008_4",
  "Head008_5", "Head009", "Head009_2", "Head009_3", "Head009_4", "Head009_5",
  "Head010", "Head010_2", "Head010_3", "Head010_4", "Head010_5", "Head011",
  "Head011_2", "Head011_3", "Head011_4", "Head011_5", "Head012", "Head012_2",
  "Head012_3", "Head012_4", "Head012_5", "Head013", "Head013_2", "Head013_3",
  "Head013_4", "Head013_5", "Head014", "Head014_2", "Head014_3", "Head014_4",
  "Head014_5", "Head015", "Head015_2", "Head015_3", "Head015_4", "Head015_5",
  "Head016", "Head016_2", "Head016_3", "Head016_4", "Head016_5", "Head017",
  "Head017_2", "Head017_3", "Head017_4", "Head017_5", "Blueprint_Head001_1", "Blueprint_Head001_2",
  "Blueprint_Head001_3", "Blueprint_Head001_4", "Blueprint_Head001_5", "Blueprint_Head002_1", "Blueprint_Head002_2", "Blueprint_Head002_3",
  "Blueprint_Head002_4", "Blueprint_Head002_5", "Blueprint_Head003_1", "Blueprint_Head003_2", "Blueprint_Head003_3", "Blueprint_Head003_4",
  "Blueprint_Head003_5", "Blueprint_Head004_1", "Blueprint_Head004_2", "Blueprint_Head004_3", "Blueprint_Head004_4", "Blueprint_Head004_5",
  "Blueprint_Head005_1", "Blueprint_Head005_2", "Blueprint_Head005_3", "Blueprint_Head005_4", "Blueprint_Head005_5", "Blueprint_Head006_1",
  "Blueprint_Head006_2", "Blueprint_Head006_3", "Blueprint_Head006_4", "Blueprint_Head006_5", "Blueprint_Head007_1", "Blueprint_Head007_2",
  "Blueprint_Head007_3", "Blueprint_Head007_4", "Blueprint_Head007_5", "Blueprint_Head008_1", "Blueprint_Head008_2", "Blueprint_Head008_3",
  "Blueprint_Head008_4", "Blueprint_Head008_5", "Blueprint_Head009_1", "Blueprint_Head009_2", "Blueprint_Head009_3", "Blueprint_Head009_4",
  "Blueprint_Head009_5", "Blueprint_Head010_1", "Blueprint_Head010_2", "Blueprint_Head010_3", "Blueprint_Head010_4", "Blueprint_Head010_5",
  "Blueprint_Head011_1", "Blueprint_Head011_2", "Blueprint_Head011_3", "Blueprint_Head011_4", "Blueprint_Head011_5", "Blueprint_Head012_1",
  "Blueprint_Head012_2", "Blueprint_Head012_3", "Blueprint_Head012_4", "Blueprint_Head012_5", "Blueprint_Head013_1", "Blueprint_Head013_2",
  "Blueprint_Head013_3", "Blueprint_Head013_4", "Blueprint_Head013_5", "Blueprint_Head014_1", "Blueprint_Head014_2", "Blueprint_Head014_3",
  "Blueprint_Head014_4", "Blueprint_Head014_5", "Blueprint_Head015_1", "Blueprint_Head015_2", "Blueprint_Head015_3", "Blueprint_Head015_4",
  "Blueprint_Head015_5", "Blueprint_Head016_1", "Blueprint_Head016_2", "Blueprint_Head016_3", "Blueprint_Head016_4", "Blueprint_Head016_5",
  "Blueprint_Head017_1", "Blueprint_Head017_2", "Blueprint_Head017_3", "Blueprint_Head017_4", "Blueprint_Head017_5", "MateItem01",
  "TreasureBoxKey01", "TreasureBoxKey02", "TreasureBoxKey03", "Musket", "BlueprintTest", "WeakerBow_2",
  "WeakerBow_3", "WeakerBow_4", "WeakerBow_5", "BowGun_2", "BowGun_3", "BowGun_4",
  "BowGun_5", "AssaultRifle_Default2", "AssaultRifle_Default3", "AssaultRifle_Default4", "AssaultRifle_Default5", "PumpActionShotgun_2",
  "PumpActionShotgun_3", "PumpActionShotgun_4", "PumpActionShotgun_5", "HandGun_Default_2", "HandGun_Default_3", "HandGun_Default_4",
  "HandGun_Default_5", "Launcher_Default_2", "Launcher_Default_3", "Launcher_Default_4", "Launcher_Default_5", "Musket_2",
  "Musket_3", "Musket_4", "Musket_5", "DoubleBarrelShotgun_2", "DoubleBarrelShotgun_3", "DoubleBarrelShotgun_4",
  "DoubleBarrelShotgun_5", "SingleShotRifle_2", "SingleShotRifle_3", "SingleShotRifle_4", "SingleShotRifle_5", "ClothArmor_2",
  "ClothArmor_3", "ClothArmor_4", "ClothArmor_5", "FurArmor_2", "FurArmor_3", "FurArmor_4",
  "FurArmor_5", "CopperArmor_2", "CopperArmor_3", "CopperArmor_4", "CopperArmor_5", "IronArmor_2",
  "IronArmor_3", "IronArmor_4", "IronArmor_5", "StealArmor_2", "StealArmor_3", "StealArmor_4",
  "StealArmor_5", "FurHelmet_2", "FurHelmet_3", "FurHelmet_4", "FurHelmet_5", "CopperHelmet_2",
  "CopperHelmet_3", "CopperHelmet_4", "CopperHelmet_5", "IronHelmet_2", "IronHelmet_3", "IronHelmet_4",
  "IronHelmet_5", "StealHelmet_2", "StealHelmet_3", "StealHelmet_4", "StealHelmet_5", "Blueprint_WeakerBow_2",
  "Blueprint_WeakerBow_3", "Blueprint_WeakerBow_4", "Blueprint_WeakerBow_5", "Blueprint_BowGun_2", "Blueprint_BowGun_3", "Blueprint_BowGun_4",
  "Blueprint_BowGun_5", "Blueprint_AssaultRifle_Default2", "Blueprint_AssaultRifle_Default3", "Blueprint_AssaultRifle_Default4", "Blueprint_AssaultRifle_Default5", "Blueprint_PumpActionShotgun_2",
  "Blueprint_PumpActionShotgun_3", "Blueprint_PumpActionShotgun_4", "Blueprint_PumpActionShotgun_5", "Blueprint_HandGun_Default_2", "Blueprint_HandGun_Default_3", "Blueprint_HandGun_Default_4",
  "Blueprint_HandGun_Default_5", "Blueprint_Launcher_Default_2", "Blueprint_Launcher_Default_3", "Blueprint_Launcher_Default_4", "Blueprint_Launcher_Default_5", "Blueprint_Musket_2",
  "Blueprint_Musket_3", "Blueprint_Musket_4", "Blueprint_Musket_5", "Blueprint_DoubleBarrelShotgun_2", "Blueprint_DoubleBarrelShotgun_3", "Blueprint_DoubleBarrelShotgun_4",
  "Blueprint_DoubleBarrelShotgun_5", "Blueprint_SingleShotRifle_2", "Blueprint_SingleShotRifle_3", "Blueprint_SingleShotRifle_4", "Blueprint_SingleShotRifle_5", "Blueprint_FurHelmet_2",
  "Blueprint_FurHelmet_3", "Blueprint_FurHelmet_4", "Blueprint_FurHelmet_5", "Blueprint_CopperHelmet_2", "Blueprint_CopperHelmet_3", "Blueprint_CopperHelmet_4",
  "Blueprint_CopperHelmet_5", "Blueprint_IronHelmet_2", "Blueprint_IronHelmet_3", "Blueprint_IronHelmet_4", "Blueprint_IronHelmet_5", "Blueprint_StealHelmet_2",
  "Blueprint_StealHelmet_3", "Blueprint_StealHelmet_4", "Blueprint_StealHelmet_5", "Blueprint_ClothArmor_2", "Blueprint_ClothArmor_3", "Blueprint_ClothArmor_4",
  "Blueprint_ClothArmor_5", "Blueprint_FurArmor_2", "Blueprint_FurArmor_3", "Blueprint_FurArmor_4", "Blueprint_FurArmor_5", "Blueprint_CopperArmor_2",
  "Blueprint_CopperArmor_3", "Blueprint_CopperArmor_4", "Blueprint_CopperArmor_5", "Blueprint_IronArmor_2", "Blueprint_IronArmor_3", "Blueprint_IronArmor_4",
  "Blueprint_IronArmor_5", "Blueprint_StealArmor_2", "Blueprint_StealArmor_3", "Blueprint_StealArmor_4", "Blueprint_StealArmor_5", "Blueprint_ClothArmorHeat_2",
  "Blueprint_ClothArmorHeat_3", "Blueprint_ClothArmorHeat_4", "Blueprint_ClothArmorHeat_5", "Blueprint_ClothArmorCold_2", "Blueprint_ClothArmorCold_3", "Blueprint_ClothArmorCold_4",
  "Blueprint_ClothArmorCold_5", "Blueprint_FurArmorHeat_2", "Blueprint_FurArmorHeat_3", "Blueprint_FurArmorHeat_4", "Blueprint_FurArmorHeat_5", "Blueprint_FurArmorCold_2",
  "Blueprint_FurArmorCold_3", "Blueprint_FurArmorCold_4", "Blueprint_FurArmorCold_5", "Blueprint_CopperArmorHeat_2", "Blueprint_CopperArmorHeat_3", "Blueprint_CopperArmorHeat_4",
  "Blueprint_CopperArmorHeat_5", "Blueprint_CopperArmorCold_2", "Blueprint_CopperArmorCold_3", "Blueprint_CopperArmorCold_4", "Blueprint_CopperArmorCold_5", "Blueprint_IronArmorHeat_2",
  "Blueprint_IronArmorHeat_3", "Blueprint_IronArmorHeat_4", "Blueprint_IronArmorHeat_5", "Blueprint_IronArmorCold_2", "Blueprint_IronArmorCold_3", "Blueprint_IronArmorCold_4",
  "Blueprint_IronArmorCold_5", "Blueprint_StealArmorHeat_2", "Blueprint_StealArmorHeat_3", "Blueprint_StealArmorHeat_4", "Blueprint_StealArmorHeat_5", "Blueprint_StealArmorCold_2",
  "Blueprint_StealArmorCold_3", "Blueprint_StealArmorCold_4", "Blueprint_StealArmorCold_5", "ClothArmorHeat", "ClothArmorHeat_2", "ClothArmorHeat_3",
  "ClothArmorHeat_4", "ClothArmorHeat_5", "ClothArmorCold", "ClothArmorCold_2", "ClothArmorCold_3", "ClothArmorCold_4",
  "ClothArmorCold_5", "FurArmorHeat", "FurArmorHeat_2", "FurArmorHeat_3", "FurArmorHeat_4", "FurArmorHeat_5",
  "FurArmorCold", "FurArmorCold_2", "FurArmorCold_3", "FurArmorCold_4", "FurArmorCold_5", "CopperArmorHeat",
  "CopperArmorHeat_2", "CopperArmorHeat_3", "CopperArmorHeat_4", "CopperArmorHeat_5", "CopperArmorCold", "CopperArmorCold_2",
  "CopperArmorCold_3", "CopperArmorCold_4", "CopperArmorCold_5", "IronArmorHeat", "IronArmorHeat_2", "IronArmorHeat_3",
  "IronArmorHeat_4", "IronArmorHeat_5", "IronArmorCold", "IronArmorCold_2", "IronArmorCold_3", "IronArmorCold_4",
  "IronArmorCold_5", "StealArmorHeat", "StealArmorHeat_2", "StealArmorHeat_3", "StealArmorHeat_4", "StealArmorHeat_5",
  "StealArmorCold", "StealArmorCold_2", "StealArmorCold_3", "StealArmorCold_4", "StealArmorCold_5", "Meat_ChickenPal",
  "Meat_SheepBall", "Meat_Kelpie", "Meat_Eagle", "Meat_Boar", "Meat_LazyCatfish", "Meat_Deer",
  "Meat_IceDeer", "Meat_BerryGoat", "Meat_CowPal", "Meat_SakuraSaurus", "Meat_GrassMammoth", "BakedMeat_ChickenPal",
  "BakedMeat_SheepBall", "BakedMeat_Kelpie", "BakedMeat_Eagle", "BakedMeat_Boar", "BakedMeat_LazyCatfish", "BakedMeat_Deer",
  "BakedMeat_IceDeer", "BakedMeat_BerryGoat", "BakedMeat_CowPal", "BakedMeat_SakuraSaurus", "BakedMeat_GrassMammoth", "ChickenSaute",
  "GrilledSheepHerbs", "GenghisKhan", "Eaglestew", "BaconEggs", "StewedIceDeer", "FriedChicken",
  "HotDog_2", "DeerLocoMoco", "DeerStew", "Hamburger_2", "Cheeseburger_2", "FriedKelpie",
  "Chowder", "GatlingGun", "HeadEquip023", "HeadEquip024", "HeadEquip025", "HeadEquip026",
  "HeadEquip027", "HeadEquip028", "HeadEquip029", "HeadEquip030", "HeadEquip031", "HeadEquip032",
  "HeadEquip033", "PalSummon", "PalSummon_NightLady", "PalSummon_NightLady_Dark", "PalSummon_NightLady_Parts", "PalSummon_NightLady_Dark_Parts",
  "AncientParts2", "Accessory_Nonkilling", "Potion_Low", "Potion", "Potion_High", "CaveMushroom",
  "Accessory_TalentChecker", "Elixir_hp_01", "Elixir_stamina_01", "Elixir_attack_01", "Elixir_workspeed_01", "Elixir_weight_01",
  "Elixir_hp_02", "Elixir_stamina_02", "Elixir_attack_02", "Elixir_workspeed_02", "Elixir_weight_02", "Lotus_hp_01",
  "Lotus_stamina_01", "Lotus_attack_01", "Lotus_workspeed_01", "Lotus_weight_01", "PalItem_PinkRabbit", "PalItem_MopBaby",
  "PalItem_NegativeOctopus", "PalItem_RaijinDaughter", "PalItem_LizardMan", "FlameThrower", "Lotus_hp_02", "Lotus_stamina_02",
  "Lotus_attack_02", "Lotus_workspeed_02", "Lotus_weight_02", "PlasticArmor", "PlasticHelmet", "ExpBoost_01",
  "ExpBoost_02", "ExpBoost_03", "ExpBoost_04", "LvUP_01", "Fruit_hp_01", "Fruit_attack_01",
  "Fruit__defense_01", "GrenadeLauncher", "GuidedMissileLauncher", "MultiGuidedMissileLauncher", "LaserGatlingGun", "Glider_Tera",
  "Shield_Ultra", "PalSphere_Ultimate", "FragGrenade_Super", "Homeward", "Rankup_1", "Rankup_2",
  "Rankup_3", "Rankup_4", "Rankup_Arbitrary", "Accessory_HeatColdResist_1", "Accessory_HeatColdResist_2", "Accessory_HeatColdResist_3",
  "PalSummon_NightLady_Dark_2", "PalSummon_NightLady_Dark_Parts_2", "HeadEquip001_purple", "SkillUnlock_KingBahamut_Dragon", "SkillUnlock_HadesBird_Electric", "SkillUnlock_SkyDragon_Grass",
  "SkillUnlock_WeaselDragon_Fire", "FlamethrowerBullet", "MissileBullet", "GrenadeBullet", "PalSummon_KingBahamut_Dragon", "PalSummon_KingBahamut_Dragon_Parts",
  "PalSummon_KingBahamut_Dragon_2", "PalSummon_KingBahamut_Dragon_Parts_2", "Accessory_MaxWeightUp_01", "Accessory_MaxWeightUp_02", "Accessory_MaxWeightUp_03", "GYM_Head_Grass",
  "GYM_Head_Electric", "GYM_Head_Forest", "GYM_Head_Snow", "GYM_Head_Desert", "MissileLauncher_NPC", "GrenadeLauncher_NPC",
  "HeadEquip041", "PlasticArmorHeat", "PlasticArmorCold", "PlasticArmorWeight", "Gasoline", "Propellant",
  "GatlingBullet", "MeteorDrop", "DogCoin", "MakeshiftHandgun_2", "MakeshiftHandgun_3", "MakeshiftHandgun_4",
  "MakeshiftHandgun_5", "Blueprint_MakeshiftHandgun_2", "Blueprint_MakeshiftHandgun_3", "Blueprint_MakeshiftHandgun_4", "Blueprint_MakeshiftHandgun_5", "UnlockEquipmentSlot_Accessory_01",
  "UnlockEquipmentSlot_Accessory_02", "LaserRifle_2", "LaserRifle_3", "LaserRifle_4", "LaserRifle_5", "Blueprint_LaserRifle_2",
  "Blueprint_LaserRifle_3", "Blueprint_LaserRifle_4", "Blueprint_LaserRifle_5", "FlameThrower_2", "FlameThrower_3", "FlameThrower_4",
  "FlameThrower_5", "Blueprint_FlameThrower_2", "Blueprint_FlameThrower_3", "Blueprint_FlameThrower_4", "Blueprint_FlameThrower_5", "GrenadeLauncher_2",
  "GrenadeLauncher_3", "GrenadeLauncher_4", "GrenadeLauncher_5", "Blueprint_GrenadeLauncher_2", "Blueprint_GrenadeLauncher_3", "Blueprint_GrenadeLauncher_4",
  "Blueprint_GrenadeLauncher_5", "GuidedMissileLauncher_2", "GuidedMissileLauncher_3", "GuidedMissileLauncher_4", "GuidedMissileLauncher_5", "Blueprint_GuidedMissileLauncher_2",
  "Blueprint_GuidedMissileLauncher_3", "Blueprint_GuidedMissileLauncher_4", "Blueprint_GuidedMissileLauncher_5", "MultiGuidedMissileLauncher_2", "MultiGuidedMissileLauncher_3", "MultiGuidedMissileLauncher_4",
  "MultiGuidedMissileLauncher_5", "Blueprint_MultiGuidedMissileLauncher_2", "Blueprint_MultiGuidedMissileLauncher_3", "Blueprint_MultiGuidedMissileLauncher_4", "Blueprint_MultiGuidedMissileLauncher_5", "GatlingGun_2",
  "GatlingGun_3", "GatlingGun_4", "GatlingGun_5", "Blueprint_GatlingGun_2", "Blueprint_GatlingGun_3", "Blueprint_GatlingGun_4",
  "Blueprint_GatlingGun_5", "GYM_Head_Sakurajima", "SkillCard_AirBlade", "SkillCard_RootLance", "SkillCard_SpecialCutter", "SkillCard_LineGeyser",
  "SkillCard_WallSplash", "SkillCard_FlameWall", "SkillCard_Eruption", "SkillCard_TriSpark", "SkillCard_ThunderRain", "SkillCard_ThunderStorm",
  "SkillCard_Tremor", "SkillCard_SandTwister", "SkillCard_IcicleLine", "SkillCard_DiamondFall", "SkillCard_DarkCanon", "SkillCard_DarkArrow",
  "SkillCard_DarkPulse", "SkillCard_Apocalypse", "SkillCard_BeamSlicer", "SkillCard_Commet", "SkillCard_BlastCanon", "PlasticArmor_2",
  "PlasticArmor_3", "PlasticArmor_4", "PlasticArmor_5", "PlasticArmorHeat_2", "PlasticArmorHeat_3", "PlasticArmorHeat_4",
  "PlasticArmorHeat_5", "PlasticArmorCold_2", "PlasticArmorCold_3", "PlasticArmorCold_4", "PlasticArmorCold_5", "PlasticArmorWeight_2",
  "PlasticArmorWeight_3", "PlasticArmorWeight_4", "PlasticArmorWeight_5", "PlasticHelmet_2", "PlasticHelmet_3", "PlasticHelmet_4",
  "PlasticHelmet_5", "Blueprint_PlasticArmor_2", "Blueprint_PlasticArmor_3", "Blueprint_PlasticArmor_4", "Blueprint_PlasticArmor_5", "Blueprint_PlasticArmorHeat_2",
  "Blueprint_PlasticArmorHeat_3", "Blueprint_PlasticArmorHeat_4", "Blueprint_PlasticArmorHeat_5", "Blueprint_PlasticArmorCold_2", "Blueprint_PlasticArmorCold_3", "Blueprint_PlasticArmorCold_4",
  "Blueprint_PlasticArmorCold_5", "Blueprint_PlasticArmorWeight_2", "Blueprint_PlasticArmorWeight_3", "Blueprint_PlasticArmorWeight_4", "Blueprint_PlasticArmorWeight_5", "Blueprint_PlasticHelmet_2",
  "Blueprint_PlasticHelmet_3", "Blueprint_PlasticHelmet_4", "Blueprint_PlasticHelmet_5", "SkillUnlock_MushroomDragon", "SkillUnlock_MushroomDragon_Dark", "SkillUnlock_MoonQueen",
  "Blueprint_HeadEquip025_1", "Blueprint_HeadEquip025_2", "Blueprint_HeadEquip025_3", "Blueprint_HeadEquip025_4", "Blueprint_HeadEquip025_5", "Blueprint_HeadEquip026_1",
  "Blueprint_HeadEquip026_2", "Blueprint_HeadEquip026_3", "Blueprint_HeadEquip026_4", "Blueprint_HeadEquip026_5", "Blueprint_HeadEquip028_1", "Blueprint_HeadEquip028_2",
  "Blueprint_HeadEquip028_3", "Blueprint_HeadEquip028_4", "Blueprint_HeadEquip028_5", "Blueprint_HeadEquip031_1", "Blueprint_HeadEquip031_2", "Blueprint_HeadEquip031_3",
  "Blueprint_HeadEquip031_4", "Blueprint_HeadEquip031_5", "Blueprint_HeadEquip032_1", "Blueprint_HeadEquip032_2", "Blueprint_HeadEquip032_3", "Blueprint_HeadEquip032_4",
  "Blueprint_HeadEquip032_5", "HeadEquip025_2", "HeadEquip025_3", "HeadEquip025_4", "HeadEquip025_5", "HeadEquip026_2",
  "HeadEquip026_3", "HeadEquip026_4", "HeadEquip026_5", "HeadEquip028_2", "HeadEquip028_3", "HeadEquip028_4",
  "HeadEquip028_5", "HeadEquip031_2", "HeadEquip031_3", "HeadEquip031_4", "HeadEquip031_5", "HeadEquip032_2",
  "HeadEquip032_3", "HeadEquip032_4", "HeadEquip032_5", "Katana_NPC", "Blueprint_MultiGuidedMissileLauncher", "Unlock_Picking_Tier1",
  "SkillUnlock_WhiteAlienDragon", "Launcher_Meteor", "MeteorBullet", "Unlock_Picking_Tier2", "Unlock_Picking_Tier3", "PoisonMushroom",
  "MushroomJuice", "SkillCard_HolyBlast", "SkillCard_FlameFunnel", "FragGrenade_Dark", "FragGrenade_Dragon", "FragGrenade_Ground",
  "FragGrenade_Leaf", "FragGrenade_Water", "Katana", "BeamSword", "SemiAutoShotgun", "PalSummon_DarkMechaDragon",
  "PalSummon_DarkMechaDragon_Parts", "PalUpgradeStone4", "EnergyRocketLauncher", "PotatoSeeds", "CarrotSeeds", "OnionSeeds",
  "Potato", "Carrot", "Onion", "Gyoza", "StirFriedVegetables", "PotatoChips",
  "Yakisoba", "SpringRolls", "Gratin", "Minestrone", "Curry", "MeatAndPotatoes",
  "Quiche", "BowGun_Poison_2", "BowGun_Poison_3", "BowGun_Poison_4", "BowGun_Poison_5", "Blueprint_BowGun_Poison_2",
  "Blueprint_BowGun_Poison_3", "Blueprint_BowGun_Poison_4", "Blueprint_BowGun_Poison_5", "BowGun_Fire_2", "BowGun_Fire_3", "BowGun_Fire_4",
  "BowGun_Fire_5", "Blueprint_BowGun_Fire_2", "Blueprint_BowGun_Fire_3", "Blueprint_BowGun_Fire_4", "Blueprint_BowGun_Fire_5", "SFArmor",
  "PalRevive", "AdditionalInventory_001", "AdditionalInventory_002", "AdditionalInventory_003", "AdditionalInventory_004", "HeadEquip044",
  "EnergyLauncherBullet", "SFArmorHeat", "SFArmorCold", "SFArmorWeight", "OldRevolver", "Pickaxe_Steal",
  "Axe_Steal", "SFHelmet", "MakeshiftAssaultRifle", "SemiAutoRifle", "MakeshiftSubmachineGun", "SubmachineGun",
  "MakeshiftShotgun", "GYM_Head_Viking", "BelieverFatCane", "PredatorCrystal", "BountyProof_1", "PalGenderReverseTest",
  "PalPassiveSkillChangeTest", "PalPassiveSkillChangeTest2", "AncientParts3", "SFHelmet_2", "SFHelmet_3", "SFHelmet_4",
  "SFHelmet_5", "SFArmor_2", "SFArmor_3", "SFArmor_4", "SFArmor_5", "SFArmorHeat_2",
  "SFArmorHeat_3", "SFArmorHeat_4", "SFArmorHeat_5", "SFArmorCold_2", "SFArmorCold_3", "SFArmorCold_4",
  "SFArmorCold_5", "SFArmorWeight_2", "SFArmorWeight_3", "SFArmorWeight_4", "SFArmorWeight_5", "Accessory_JumpPower_Increase",
  "Accessory_JumpCount_Increase1", "Accessory_JumpCount_Increase2", "Accessory_JumpCount_Increase3", "Accessory_AirDash1", "Accessory_AirDash2", "Accessory_AirDash3",
  "Accessory_AirDash4", "LaserGatlingBullet", "LaserGatlingGun_2", "LaserGatlingGun_3", "LaserGatlingGun_4", "LaserGatlingGun_5",
  "EnergyRocketLauncher_2", "EnergyRocketLauncher_3", "EnergyRocketLauncher_4", "EnergyRocketLauncher_5", "Shield_SF", "TEST_CaptureItemModifier",
  "PalSphere_Exotic", "CompoundBow", "ReinforcedArrow", "SFBow", "SFArrow", "Chromium",
  "StainlessSteel", "PalSummon_DarkMechaDragon_2", "PalSummon_DarkMechaDragon_Parts_2", "Potion_Extreme", "NightStone", "PalDarkParts",
  "SphereModule_Heavy", "SphereModule_Curve", "SphereModule_Sniper", "SphereModule_Curve2", "SphereModule_Sniper2", "SphereModule_Homing",
  "Blueprint_SFHelmet_2", "Blueprint_SFHelmet_3", "Blueprint_SFHelmet_4", "Blueprint_SFHelmet_5", "Blueprint_SFArmor_2", "Blueprint_SFArmor_3",
  "Blueprint_SFArmor_4", "Blueprint_SFArmor_5", "Blueprint_SFArmorHeat_2", "Blueprint_SFArmorHeat_3", "Blueprint_SFArmorHeat_4", "Blueprint_SFArmorHeat_5",
  "Blueprint_SFArmorCold_2", "Blueprint_SFArmorCold_3", "Blueprint_SFArmorCold_4", "Blueprint_SFArmorCold_5", "Blueprint_SFArmorWeight_2", "Blueprint_SFArmorWeight_3",
  "Blueprint_SFArmorWeight_4", "Blueprint_SFArmorWeight_5", "Blueprint_LaserGatlingGun_2", "Blueprint_LaserGatlingGun_3", "Blueprint_LaserGatlingGun_4", "Blueprint_LaserGatlingGun_5",
  "Blueprint_EnergyRocketLauncher_2", "Blueprint_EnergyRocketLauncher_3", "Blueprint_EnergyRocketLauncher_4", "Blueprint_EnergyRocketLauncher_5", "SemiAutoShotgun_2", "SemiAutoShotgun_3",
  "SemiAutoShotgun_4", "SemiAutoShotgun_5", "OldRevolver_2", "OldRevolver_3", "OldRevolver_4", "OldRevolver_5",
  "MakeshiftAssaultRifle_2", "MakeshiftAssaultRifle_3", "MakeshiftAssaultRifle_4", "MakeshiftAssaultRifle_5", "SemiAutoRifle_2", "SemiAutoRifle_3",
  "SemiAutoRifle_4", "SemiAutoRifle_5", "MakeshiftSubmachineGun_2", "MakeshiftSubmachineGun_3", "MakeshiftSubmachineGun_4", "MakeshiftSubmachineGun_5",
  "SubmachineGun_2", "SubmachineGun_3", "SubmachineGun_4", "SubmachineGun_5", "MakeshiftShotgun_2", "MakeshiftShotgun_3",
  "MakeshiftShotgun_4", "MakeshiftShotgun_5", "Blueprint_SemiAutoShotgun_2", "Blueprint_SemiAutoShotgun_3", "Blueprint_SemiAutoShotgun_4", "Blueprint_SemiAutoShotgun_5",
  "Blueprint_OldRevolver_2", "Blueprint_OldRevolver_3", "Blueprint_OldRevolver_4", "Blueprint_OldRevolver_5", "Blueprint_MakeshiftAssaultRifle_2", "Blueprint_MakeshiftAssaultRifle_3",
  "Blueprint_MakeshiftAssaultRifle_4", "Blueprint_MakeshiftAssaultRifle_5", "Blueprint_SemiAutoRifle_2", "Blueprint_SemiAutoRifle_3", "Blueprint_SemiAutoRifle_4", "Blueprint_SemiAutoRifle_5",
  "Blueprint_MakeshiftSubmachineGun_2", "Blueprint_MakeshiftSubmachineGun_3", "Blueprint_MakeshiftSubmachineGun_4", "Blueprint_MakeshiftSubmachineGun_5", "Blueprint_SubmachineGun_2", "Blueprint_SubmachineGun_3",
  "Blueprint_SubmachineGun_4", "Blueprint_SubmachineGun_5", "Blueprint_MakeshiftShotgun_2", "Blueprint_MakeshiftShotgun_3", "Blueprint_MakeshiftShotgun_4", "Blueprint_MakeshiftShotgun_5",
  "TEST_BossDefeatReward", "YakushimaBlade", "BossDefeatReward_WeaselDragon", "BossDefeatReward_MopKing", "BossDefeatReward_PlantSlime", "BossDefeatReward_LazyCatfish",
  "BossDefeatReward_CaptainPenguin", "BossDefeatReward_BlueDragon", "BossDefeatReward_NaughtyCat", "BossDefeatReward_HawkBird", "BossDefeatReward_SkyDragon", "BossDefeatReward_CatVampire",
  "BossDefeatReward_KingAlpaca", "BossDefeatReward_SakuraSaurus", "BossDefeatReward_CatMage", "BossDefeatReward_Ronin", "BossDefeatReward_FengyunDeeper", "BossDefeatReward_FlowerDoll",
  "BossDefeatReward_ThunderBird", "BossDefeatReward_HerculesBeetle", "BossDefeatReward_SakuraSaurus_Water", "BossDefeatReward_FairyDragon", "BossDefeatReward_LazyDragon_Electric", "BossDefeatReward_Kirin",
  "BossDefeatReward_QueenBee", "BossDefeatReward_GrassPanda_Electric", "BossDefeatReward_Mutant", "BossDefeatReward_GrassRabbitMan", "BossDefeatReward_Yeti_Grass", "BossDefeatReward_GrassMammoth",
  "BossDefeatReward_VioletFairy", "BossDefeatReward_WhiteMoth", "BossDefeatReward_DarkScorpion", "BossDefeatReward_Suzaku", "BossDefeatReward_Umihebi", "BossDefeatReward_KingAlpaca_Ice",
  "BossDefeatReward_FlowerDinosaur_Electric", "BossDefeatReward_Anubis", "BossDefeatReward_BlackMetalDragon", "BossDefeatReward_KingBahamut", "BossDefeatReward_LilyQueen_Dark", "BossDefeatReward_DarkScorpion_Ground",
  "BossDefeatReward_WingGolem", "BossDefeatReward_GrimGirl", "BossDefeatReward_BlueThunderHorse", "BossDefeatReward_AmaterasuWolf_Dark", "BossDefeatReward_FengyunDeeper_Electric", "BossDefeatReward_WhiteDeer",
  "BossDefeatReward_WhiteShieldDragon", "BossDefeatReward_Horus_Water", "BossDefeatReward_JetDragon", "BossDefeatReward_IceHorse", "BossDefeatReward_SaintCentaur", "WorkSuitability_AddTicket_EmitFlame",
  "WorkSuitability_AddTicket_Watering", "WorkSuitability_AddTicket_Seeding", "WorkSuitability_AddTicket_GenerateElectricity", "WorkSuitability_AddTicket_Handcraft", "WorkSuitability_AddTicket_Collection", "WorkSuitability_AddTicket_Deforest",
  "WorkSuitability_AddTicket_Mining", "WorkSuitability_AddTicket_ProductMedicine", "WorkSuitability_AddTicket_Cool", "WorkSuitability_AddTicket_Transport", "WorkSuitability_AddTicket_MonsterFarm", "SkillUnlock_DarkMechaDragon",
  "SkillUnlock_NightBlueHorse", "SkillUnlock_WhiteShieldDragon", "SkillUnlock_WhiteDeer", "SkillUnlock_PurpleSpider", "SkillUnlock_BlueThunderHorse", "SkillUnlock_SnowTigerBeastman",
  "SkillUnlock_AmaterasuWolf_Dark", "SkillUnlock_FengyunDeeper_Electric", "SkillUnlock_Horus_Water", "SkillUnlock_BlackPuppy", "SkillUnlock_Kitsunebi_Ice", "SkillUnlock_RaijinDaughter_Water",
  "RainbowCrystal", "SFBow_2", "SFBow_3", "SFBow_4", "SFBow_5", "Blueprint_SFBow_2",
  "Blueprint_SFBow_3", "Blueprint_SFBow_4", "Blueprint_SFBow_5", "BossDefeatReward_BlackPuppy", "BossDefeatReward_GhostRabbit", "BossDefeatReward_NightBlueHorse",
  "BossDefeatReward_BlueberryFairy", "BossDefeatReward_BadCatgirl", "BossDefeatReward_GoldenHorse", "BossDefeatReward_MysteryMask", "BossDefeatReward_PurpleSpider", "BossDefeatReward_IceHorse_Dark",
  "CompoundBow_2", "CompoundBow_3", "CompoundBow_4", "CompoundBow_5", "Blueprint_CompoundBow_2", "Blueprint_CompoundBow_3",
  "Blueprint_CompoundBow_4", "Blueprint_CompoundBow_5", "BossDefeatReward_Kitsunebi_Ice", "BossDefeatReward_RaijinDaughter_Water", "BossDefeatReward_WhiteTiger_Ground", "BossDefeatReward_BerryGoat_Dark",
  "BossDefeatReward_Werewolf_Ice", "BossDefeatReward_PinkRabbit_Grass", "BossDefeatReward_HerculesBeetle_Ground", "FishingRod_Test", "ChargeLaserRifle", "OverHeatRifle",
  "EnergyShotgun", "PalDopingShot", "PalDopingShot_2", "PalDopingShot_3", "PalHealingGrenade", "Otomo_ElementBoost_Normal_1",
  "Otomo_ElementBoost_Fire_1", "Otomo_ElementBoost_Water_1", "Otomo_ElementBoost_Electricity_1", "Otomo_ElementBoost_Leaf_1", "Otomo_ElementBoost_Ice_1", "Otomo_ElementBoost_Earth_1",
  "Otomo_ElementBoost_Dark_1", "Otomo_ElementBoost_Dragon_1", "Otomo_ElementBoost_Normal_2", "Otomo_ElementBoost_Fire_2", "Otomo_ElementBoost_Water_2", "Otomo_ElementBoost_Electricity_2",
  "Otomo_ElementBoost_Leaf_2", "Otomo_ElementBoost_Ice_2", "Otomo_ElementBoost_Earth_2", "Otomo_ElementBoost_Dark_2", "Otomo_ElementBoost_Dragon_2", "Otomo_ElementBoost_Normal_3",
  "Otomo_ElementBoost_Fire_3", "Otomo_ElementBoost_Water_3", "Otomo_ElementBoost_Electricity_3", "Otomo_ElementBoost_Leaf_3", "Otomo_ElementBoost_Ice_3", "Otomo_ElementBoost_Earth_3",
  "Otomo_ElementBoost_Dark_3", "Otomo_ElementBoost_Dragon_3", "Otomo_Attack_up1", "Otomo_Attack_up2", "Otomo_Attack_up3", "Otomo_Defense_up1",
  "Otomo_Defense_up2", "Otomo_Defense_up3", "Otomo_PalExp_Increase_1", "Otomo_PalExp_Increase_2", "Otomo_PalExp_Increase_3", "Otomo_MoveSpeed_up_1",
  "MeaninglessItem_ButcheringImportPal", "PalSummon_YakushimaBoss002", "ChargeLaserRifleBullet", "OverheatRifleBullet", "EnergyShotgunBullet", "PalDopingShotBullet",
  "Blueprint_Hunter_GangFlag", "Salvage_TreasureBoxKey01", "Salvage_TreasureBoxKey02", "YakushimaHeadEquip001", "YakushimaHeadEquip002", "YakushimaArmor001",
  "SkillCard_IceWall", "SkillCard_ReflectiveShuriken", "SkillCard_DiversionLaser", "SkillCard_HydroSlicer", "PalPassiveSkillChange_NonKilling", "PalPassiveSkillChange_Nocturnal",
  "PalPassiveSkillChange_HatchingSpeed_Up", "PalPassiveSkillChange_CoolTimeReduction_Up_2", "PalPassiveSkillChange_CoolTimeReduction_Up_1", "PalPassiveSkillChange_Stamina_Up_2", "PalPassiveSkillChange_Stamina_Up_1", "PalPassiveSkillChange_Stamina_Up_3",
  "PalPassiveSkillChange_MoveSpeed_up_1", "PalPassiveSkillChange_MoveSpeed_up_2", "PalPassiveSkillChange_MoveSpeed_up_3", "PalPassiveSkillChange_PAL_FullStomach_Down_1", "PalPassiveSkillChange_PAL_FullStomach_Down_2", "PalPassiveSkillChange_PAL_FullStomach_Down_3",
  "PalPassiveSkillChange_PAL_Sanity_Down_1", "PalPassiveSkillChange_PAL_Sanity_Down_2", "PalPassiveSkillChange_PAL_Sanity_Down_3", "PalPassiveSkillChange_PAL_ALLAttack_up1", "PalPassiveSkillChange_PAL_ALLAttack_up2", "PalPassiveSkillChange_PAL_ALLAttack_up3",
  "PalPassiveSkillChange_Deffence_up1", "PalPassiveSkillChange_Deffence_up2", "PalPassiveSkillChange_Deffence_up3", "PalPassiveSkillChange_CraftSpeed_up1", "PalPassiveSkillChange_CraftSpeed_up2", "PalPassiveSkillChange_CraftSpeed_up3",
  "PalPassiveSkillChange_Noukin", "PalGenderReverse", "BattleTicket", "Blueprint_OverheatRifle_2", "Blueprint_OverheatRifle_3", "Blueprint_OverheatRifle_4",
  "Blueprint_OverheatRifle_5", "Lantern_High", "YakushimaHeadEquip003", "YakushimaParts001", "YakushimaParts002", "YakushimaParts003",
  "Blueprint_ChargeLaserRifle_2", "Blueprint_ChargeLaserRifle_3", "Blueprint_ChargeLaserRifle_4", "Blueprint_ChargeLaserRifle_5", "Blueprint_EnergyShotgun_2", "Blueprint_EnergyShotgun_3",
  "Blueprint_EnergyShotgun_4", "Blueprint_EnergyShotgun_5", "EnergyShotgun_2", "EnergyShotgun_3", "EnergyShotgun_4", "EnergyShotgun_5",
  "ChargeLaserRifle_2", "ChargeLaserRifle_3", "ChargeLaserRifle_4", "ChargeLaserRifle_5", "OverHeatRifle_2", "OverHeatRifle_3",
  "OverHeatRifle_4", "OverHeatRifle_5", "Blueprint_LilyQueenStatue", "Blueprint_ConservationGroupBannerA", "Blueprint_ConservationGroupBannerB", "Blueprint_Wire_Fence",
  "Blueprint_WoodenBarricade", "Blueprint_WallTorch02", "Blueprint_FireStand", "Blueprint_CandleStand", "YakushimaHeadEquip006", "SkillCard_RockBeat",
  "SkillCard_ThunderSpear", "SkillCard_GravityShot", "Blueprint_LanternTop", "Blueprint_Shrine_Lantern", "Blueprint_GuardianDogStatue", "YakushimaHeadEquip004",
  "YakushimaHeadEquip005", "TreasureMap01", "TreasureMap02", "TreasureMap03", "TreasureMap04", "TreasureMap05",
  "SkillCard_DarkLegion", "SkillCard_ChargeCanon", "SkillCard_IciclePierce", "SkillCard_RangeThunder", "YakushimaBlade002", "YakushimaBlade003",
  "YakushimaGun001", "YakushimaLantern001", "YakushimaBlade004", "YakushimaBlade005", "Elixir_hp_Yakushima", "YakushimaIngot001",
  "YakushimaIngot002", "GatlingGun_NPC_GrassBoss", "SkillUnlock_IceNarwhal", "SkillUnlock_GhostAnglerfish", "SkillUnlock_LeafMomonga", "SkillUnlock_IceSeal",
  "SkillUnlock_Plesiosaur", "SkillUnlock_TropicalOstrich", "SkillUnlock_PoseidonOrca", "SkillUnlock_NegativeOctopus_Neutral", "SkillUnlock_Penguin_Electric", "SkillUnlock_FlyingManta_Thunder",
  "SkillUnlock_BlueDragon_Ice", "SkillUnlock_GhostAnglerfish_Fire", "SkillUnlock_IceNarwhal_Fire", "FishingRod_01_1", "FishingRod_01_2", "FishingRod_02_1",
  "FishingRod_02_2", "FishingRod_03_1", "FishingRod_03_2", "Blueprint_SF_Desk", "Blueprint_SF_Chair", "GrapplingGun5",
  "BossDefeatReward_IceNarwhal", "BossDefeatReward_IceNarwhal_Fire", "BossDefeatReward_PoseidonOrca", "FishingBait_1", "FishingBait_2", "FishingBait_3",
  "FishingBait_1_A", "FishingBait_1_B", "FishingBait_2_A", "FishingBait_2_B", "FishingBait_3_A", "FishingBait_3_B",
  "Meat_OctopusGirl", "Meat_JellyfishFairy", "Meat_JellyfishGhost", "Meat_IceCrocodile", "OctopusGirl_Takoyaki", "JellyfishFairy_jelly",
  "JellyfishGhost_jelly", "BakedMeat_IceCrocodile", "ManganeseOre", "ManganeseIngot", "AffectionFruit_01", "Blueprint_YakushimaBlade004",
  "Blueprint_YakushimaBlade004_2", "Blueprint_YakushimaBlade004_3", "Blueprint_YakushimaBlade004_4", "Blueprint_YakushimaBlade004_5", "Blueprint_YakushimaBlade003", "Blueprint_YakushimaBlade003_2",
  "Blueprint_YakushimaBlade003_3", "Blueprint_YakushimaBlade003_4", "Blueprint_YakushimaBlade003_5", "Blueprint_YakushimaGun001", "Blueprint_YakushimaGun001_2", "Blueprint_YakushimaGun001_3",
  "Blueprint_YakushimaGun001_4", "Blueprint_YakushimaGun001_5", "Blueprint_YakushimaLantern001", "SkillUnlock_GrassGolem", "SkillUnlock_GrassGolem_Dark", "PAL_Growth_Stone_L",
  "SkillUnlock_KingSunfish", "SkillUnlock_KingSunfish_Thunder", "Pal_crystal_S", "Blueprint_YakushimaLantern001_2", "Blueprint_YakushimaLantern001_3", "Blueprint_YakushimaLantern001_4",
  "Blueprint_YakushimaLantern001_5", "Blueprint_YakushimaBlade002", "Blueprint_YakushimaBlade002_2", "Blueprint_YakushimaBlade002_3", "Blueprint_YakushimaBlade002_4", "Blueprint_YakushimaBlade002_5",
  "Blueprint_YakushimaHeadEquip001", "Blueprint_YakushimaHeadEquip001_2", "Blueprint_YakushimaHeadEquip001_3", "Blueprint_YakushimaHeadEquip001_4", "Blueprint_YakushimaHeadEquip001_5", "Blueprint_YakushimaHeadEquip002",
  "Blueprint_YakushimaHeadEquip002_2", "Blueprint_YakushimaHeadEquip002_3", "Blueprint_YakushimaHeadEquip002_4", "Blueprint_YakushimaHeadEquip002_5", "Blueprint_YakushimaArmor001", "Blueprint_YakushimaArmor001_2",
  "Blueprint_YakushimaArmor001_3", "Blueprint_YakushimaArmor001_4", "Blueprint_YakushimaArmor001_5", "Blueprint_YakushimaHeadEquip003", "Blueprint_YakushimaHeadEquip003_2", "Blueprint_YakushimaHeadEquip003_3",
  "Blueprint_YakushimaHeadEquip003_4", "Blueprint_YakushimaHeadEquip003_5", "Blueprint_YakushimaHeadEquip004", "Blueprint_YakushimaHeadEquip004_2", "Blueprint_YakushimaHeadEquip004_3", "Blueprint_YakushimaHeadEquip004_4",
  "Blueprint_YakushimaHeadEquip004_5", "Blueprint_PalSummon_YakushimaBoss002", "YakushimaBlade002_2", "YakushimaBlade002_3", "YakushimaBlade002_4", "YakushimaBlade002_5",
  "YakushimaBlade003_2", "YakushimaBlade003_3", "YakushimaBlade003_4", "YakushimaBlade003_5", "YakushimaGun001_2", "YakushimaGun001_3",
  "YakushimaGun001_4", "YakushimaGun001_5", "YakushimaLantern001_2", "YakushimaLantern001_3", "YakushimaLantern001_4", "YakushimaLantern001_5",
  "YakushimaBlade004_3", "YakushimaBlade004_4", "YakushimaBlade004_5", "YakushimaHeadEquip001_2", "YakushimaHeadEquip001_3", "YakushimaHeadEquip001_4",
  "YakushimaHeadEquip001_5", "YakushimaHeadEquip002_2", "YakushimaHeadEquip002_3", "YakushimaHeadEquip002_4", "YakushimaHeadEquip002_5", "YakushimaArmor001_2",
  "YakushimaArmor001_3", "YakushimaArmor001_4", "YakushimaArmor001_5", "YakushimaHeadEquip003_2", "YakushimaHeadEquip003_3", "YakushimaHeadEquip003_4",
  "YakushimaHeadEquip003_5", "YakushimaHeadEquip004_2", "YakushimaHeadEquip004_3", "YakushimaHeadEquip004_4", "YakushimaHeadEquip004_5", "Launcher_Meteor_5",
  "Blueprint_Launcher_Meteor_5", "SkillCard_RipTide", "SkillCard_CrossWind", "SkillCard_IceAge", "QuestItem_Farmer_1", "QuestItem_Zoe_1",
  "QuestItem_Breeder_1", "Blueprint_FishingRod_01_2", "Blueprint_FishingRod_02_2", "Blueprint_FishingRod_03_2", "Seafood_Salada", "Supplement",
  "Blueprint_Salvage_TreasureBoxKey01", "Blueprint_Salvage_FishingBait_1_A", "Blueprint_Salvage_FishingBait_1_B", "Blueprint_Salvage_FishingBait_2_A", "Blueprint_Salvage_FishingBait_2_B", "Blueprint_Salvage_FishingBait_3_B",
  "HeadEquip045", "Player_Outfit_Kigurumi001", "PalSummon_YakushimaBoss002_2", "HandgunShield", "Blueprint_YakushimaBoss002_Relic", "PalPassiveSkillChange_TrainerATK_UP_1",
  "PalPassiveSkillChange_TrainerDEF_UP_1", "PalPassiveSkillChange_TrainerWorkSpeed_UP_1", "PalPassiveSkillChange_SalePrice_Up_1", "PalPassiveSkillChange_SwimSpeed_up_2", "PalPassiveSkillChange_TrainerMining_up1", "PalPassiveSkillChange_TrainerLogging_up1",
  "PalPassiveSkillChange_SalePrice_Up_2", "PalPassiveSkillChange_SwimSpeed_up_1", "PalPassiveSkillChange_PAL_CorporateSlave", "AffectionFruit_02", "LettuceSeeds", "SkillUnlock_Monkey_Fire",
  "FishingRod_Good", "Accessory_AT_1", "SkillUnlock_LegendDeer", "SkillUnlock_BlackPuppy_Ice", "SkillUnlock_NightBlueHorse_Neutral", "YakushimaBlade004_2",
  "Sweet_Caramel", "WaterBuildKit", "OctaviaRevolver", "OctaviaRevolver_2", "OctaviaRevolver_3", "OctaviaRevolver_4",
  "OctaviaRevolver_5", "OctaviaShotgun", "OctaviaShotgun_2", "OctaviaShotgun_3", "OctaviaShotgun_4", "OctaviaShotgun_5",
  "PalSummon_LegendDeer", "PalSummon_LegendDeer_Parts", "PalSummon_LegendDeer_2", "PalSummon_LegendDeer_Parts_2", "Octavia001_Armor", "Octavia002_Armor",
  "Octavia001_Armor_5", "Octavia002_Armor_5", "HeadEquip046", "Blueprint_Zoe_Halloweenskin_1", "QuestItem_Zoe_Halloweenskin_1", "PlayerDropItem",
  "Blueprint_OctaviaRevolver_2", "Blueprint_OctaviaRevolver_3", "Blueprint_OctaviaRevolver_4", "Blueprint_OctaviaRevolver_5", "Blueprint_OctaviaShotgun_2", "Blueprint_OctaviaShotgun_3",
  "Blueprint_OctaviaShotgun_4", "Blueprint_OctaviaShotgun_5", "Blueprint_Octavia001_Armor_5", "Blueprint_Octavia002_Armor_5", "PalEgg_WorldTree_01", "PalEgg_WorldTree_02",
  "PalEgg_WorldTree_03", "PalEgg_WorldTree_04", "PalEgg_WorldTree_05", "PalAwakening_Test", "PalAwakening_Water", "PalAwakening_Electric",
  "PalAwakening_Ground", "PalAwakening_Grass", "PalAwakening_Fire", "PalAwakening_Ice", "PalAwakening_Dragon", "PalAwakening_Dark",
  "PalAwakening_Neutral", "PalAwakening_Material_Water", "PalAwakening_Material_Electric", "PalAwakening_Material_Ground", "PalAwakening_Material_Grass", "PalAwakening_Material_Fire",
  "PalAwakening_Material_Ice", "PalAwakening_Material_Dragon", "PalAwakening_Material_Dark", "PalAwakening_Material_Neutral", "LaserMiningTool", "PalPassiveSkillChange_SwimSpeed_ConsumeTest",
  "SkyIslandOre", "WorldTreeOre", "BossDefeatReward_FlowerPrince", "BossDefeatReward_Mothman", "BossDefeatReward_BossRush", "PalPassiveSkillChange_Consumable_WorldTree_ATK",
  "PalPassiveSkillChange_Consumable_WorldTree_DEF", "PalPassiveSkillChange_Consumable_WorldTree_CraftSpeed", "PalPassiveSkillChange_Consumable_WorldTree_FullStomach", "PalPassiveSkillChange_Consumable_WorldTree_Sanity", "PalPassiveSkillChange_Consumable_WorldTree_MoveSpeed", "PalPassiveSkillChange_Consumable_WorldTree_ATK_DEF",
  "PalPassiveSkillChange_Consumable_CraftSpeed_up3", "PalPassiveSkillChange_Consumable_Deffence_up3", "PalPassiveSkillChange_Consumable_Rare", "PalPassiveSkillChange_Consumable_Legend", "PalPassiveSkillChange_Consumable_Witch", "PalPassiveSkillChange_Consumable_EternalFlame",
  "PalPassiveSkillChange_Consumable_Invader", "PalPassiveSkillChange_Consumable_PAL_ALLAttack_up3", "PalPassiveSkillChange_Consumable_PAL_FullStomach_Down_3", "PalPassiveSkillChange_Consumable_PAL_Sanity_Down_3", "PalPassiveSkillChange_Consumable_MoveSpeed_up_3", "PalPassiveSkillChange_Consumable_Stamina_Up_3",
  "PalPassiveSkillChange_Consumable_Vampire", "PalPassiveSkillChange_Consumable_Nushi", "PalPassiveSkillChange_Consumable_SwimSpeed_up_3", "PalPassiveSkillChange_Consumable_Salvation", "WorldTreeRelic_01", "WorldTreeRelic_02",
  "WorldTreeRelic_03", "WorldTreeRelic_04", "WorldTreeRelic_05", "WorldTreeHolyWater", "SkyBow", "SkyBow_2",
  "SkyBow_3", "SkyBow_4", "SkyBow_5", "SkySubmachineGun", "SkySubmachineGun_2", "SkySubmachineGun_3",
  "SkySubmachineGun_4", "SkySubmachineGun_5", "SkyShotgun", "SkyShotgun_2", "SkyShotgun_3", "SkyShotgun_4",
  "SkyShotgun_5", "SkyAssaultRifle", "SkyAssaultRifle_2", "SkyAssaultRifle_3", "SkyAssaultRifle_4", "SkyAssaultRifle_5",
  "SkyGrenadeLauncher", "SkyGrenadeLauncher_2", "SkyGrenadeLauncher_3", "SkyGrenadeLauncher_4", "SkyGrenadeLauncher_5", "SkyBeamSword",
  "SkyBeamSword_2", "SkyBeamSword_3", "SkyBeamSword_4", "SkyBeamSword_5", "WidePenetrateShotgun", "WidePenetrateShotgun_2",
  "WidePenetrateShotgun_3", "WidePenetrateShotgun_4", "WidePenetrateShotgun_5", "DroneLauncher", "DroneLauncher_2", "DroneLauncher_3",
  "DroneLauncher_4", "DroneLauncher_5", "ElectricArcAssaultRifle", "ElectricArcAssaultRifle_2", "ElectricArcAssaultRifle_3", "ElectricArcAssaultRifle_4",
  "ElectricArcAssaultRifle_5", "BeamLauncher", "BeamLauncher_2", "BeamLauncher_3", "BeamLauncher_4", "BeamLauncher_5",
  "Blueprint_SkyBow_2", "Blueprint_SkyBow_3", "Blueprint_SkyBow_4", "Blueprint_SkyBow_5", "Blueprint_SkySubmachineGun_2", "Blueprint_SkySubmachineGun_3",
  "Blueprint_SkySubmachineGun_4", "Blueprint_SkySubmachineGun_5", "Blueprint_SkyShotgun_2", "Blueprint_SkyShotgun_3", "Blueprint_SkyShotgun_4", "Blueprint_SkyShotgun_5",
  "Blueprint_SkyAssaultRifle_2", "Blueprint_SkyAssaultRifle_3", "Blueprint_SkyAssaultRifle_4", "Blueprint_SkyAssaultRifle_5", "Blueprint_SkyGrenadeLauncher_2", "Blueprint_SkyGrenadeLauncher_3",
  "Blueprint_SkyGrenadeLauncher_4", "Blueprint_SkyGrenadeLauncher_5", "Blueprint_SkyBeamSword_2", "Blueprint_SkyBeamSword_3", "Blueprint_SkyBeamSword_4", "Blueprint_SkyBeamSword_5",
  "Blueprint_WidePenetrateShotgun_2", "Blueprint_WidePenetrateShotgun_3", "Blueprint_WidePenetrateShotgun_4", "Blueprint_WidePenetrateShotgun_5", "Blueprint_DroneLauncher_2", "Blueprint_DroneLauncher_3",
  "Blueprint_DroneLauncher_4", "Blueprint_DroneLauncher_5", "Blueprint_ElectricArcAssaultRifle_2", "Blueprint_ElectricArcAssaultRifle_3", "Blueprint_ElectricArcAssaultRifle_4", "Blueprint_ElectricArcAssaultRifle_5",
  "Blueprint_BeamLauncher_2", "Blueprint_BeamLauncher_3", "Blueprint_BeamLauncher_4", "Blueprint_BeamLauncher_5", "Sword_2", "Sword_3",
  "Sword_4", "Sword_5", "Katana_2", "Katana_3", "Katana_4", "Katana_5",
  "BeamSword_2", "BeamSword_3", "BeamSword_4", "BeamSword_5", "Spear_ForestBoss_5", "Blueprint_Sword_2",
  "Blueprint_Sword_3", "Blueprint_Sword_4", "Blueprint_Sword_5", "Blueprint_Katana_2", "Blueprint_Katana_3", "Blueprint_Katana_4",
  "Blueprint_Katana_5", "Blueprint_BeamSword_2", "Blueprint_BeamSword_3", "Blueprint_BeamSword_4", "Blueprint_BeamSword_5", "Blueprint_Spear_ForestBoss_5",
  "UnlockEquipmentSlot_Weapon_01", "AssaultRifle_NPC_Otomo", "Handgun_NPC_Otomo", "Shotgun_NPC_Otomo", "FlameThrower_NPC_Otomo", "GatlingGun_NPC_Otomo",
  "FragGrenade_NPC_Otomo", "RocketLauncher_NPC_Otomo", "Bat_NPC_Otomo", "BowGun_NPC_Otomo", "LaserRifle_NPC_Otomo", "MissileLauncher_NPC_Otomo",
  "GrenadeLauncher_NPC_Otomo", "Katana_NPC_Otomo", "BelieverFatCane_Otomo", "WingGlider_Test", "Relic_01", "Relic_02",
  "Relic_03", "Relic_04", "Relic_05", "Relic_06", "Relic_07", "Relic_08",
  "Relic_09", "Relic_10", "Relic_11", "PAL_Growth_Stone_M", "Accessory_ThunderResist_3", "SkillUnlock_GhostDragon",
  "SkillUnlock_GhostDragon_Fire", "Accessory_LeafResist_3", "Accessory_IceResist_1", "Accessory_IceResist_2", "SkillUnlock_ThunderFluffyBird", "SkillUnlock_ThunderBird_Ice",
  "SkillUnlock_WhiteDeer_Dark", "SkyLightBullet", "SkyHeavyBullet", "WidePenetrateShotgunBullet", "ElectricArcAssaultRifleBullet", "BeamLauncherBullet",
  "WingGlider_Fuel", "KeySphere_01", "KeySphere_02", "KeySphere_03", "KeySphere_04", "KeySphere_05",
  "KeySphere_06", "KeySphere_07", "KeySphere_08", "SkyislandIngot", "WorldTreeIngot", "AncientArmor",
  "AncientArmorHeat", "AncientArmorCold", "AncientArmorWeight", "AncientHelmet", "AncientHelmet_2", "AncientHelmet_3",
  "AncientHelmet_4", "AncientHelmet_5", "AncientArmor_2", "AncientArmor_3", "AncientArmor_4", "AncientArmor_5",
  "AncientArmorHeat_2", "AncientArmorHeat_3", "AncientArmorHeat_4", "AncientArmorHeat_5", "AncientArmorCold_2", "AncientArmorCold_3",
  "AncientArmorCold_4", "AncientArmorCold_5", "AncientArmorWeight_2", "AncientArmorWeight_3", "AncientArmorWeight_4", "AncientArmorWeight_5",
  "Blueprint_AncientHelmet_2", "Blueprint_AncientHelmet_3", "Blueprint_AncientHelmet_4", "Blueprint_AncientHelmet_5", "Blueprint_AncientArmor_2", "Blueprint_AncientArmor_3",
  "Blueprint_AncientArmor_4", "Blueprint_AncientArmor_5", "Blueprint_AncientArmorHeat_2", "Blueprint_AncientArmorHeat_3", "Blueprint_AncientArmorHeat_4", "Blueprint_AncientArmorHeat_5",
  "Blueprint_AncientArmorCold_2", "Blueprint_AncientArmorCold_3", "Blueprint_AncientArmorCold_4", "Blueprint_AncientArmorCold_5", "Blueprint_AncientArmorWeight_2", "Blueprint_AncientArmorWeight_3",
  "Blueprint_AncientArmorWeight_4", "Blueprint_AncientArmorWeight_5", "PalSphere_Ancient_1", "PalSphere_Ancient_2", "BeamSword_NPC", "PalEgg_MutationPal",
  "WingGlider", "WhaleWhistleFragment_01", "WhaleWhistleFragment_02", "WhaleWhistleFragment_03", "WhaleWhistleFragment_04", "WhaleWhistle",
  "Blueprint_Accessory_HP_1_2", "Blueprint_Accessory_AT_1_2", "Blueprint_Accessory_defense_1_2", "Blueprint_Accessory_WorkSpeed_1_2", "Blueprint_Accessory_HeatResist_1_2", "Blueprint_Accessory_CoolResist_1_2",
  "Blueprint_Accessory_NormalResist_1_2", "Blueprint_Accessory_FireResist_1_2", "Blueprint_Accessory_AquaResist_1_2", "Blueprint_Accessory_ThunderResist_1_2", "Blueprint_Accessory_LeafResist_1_2", "Blueprint_Accessory_IceResist_1_2",
  "Blueprint_Accessory_EarthResist_1_2", "Blueprint_Accessory_DarkResist_1_2", "Blueprint_Accessory_DragonResist_1_2", "Blueprint_Accessory_HeatColdResist_1_2", "Blueprint_Accessory_MaxWeightUp_01_2", "Blueprint_Otomo_ElementBoost_Normal_1_2",
  "Blueprint_Otomo_ElementBoost_Fire_1_2", "Blueprint_Otomo_ElementBoost_Water_1_2", "Blueprint_Otomo_ElementBoost_Electricity_1_2", "Blueprint_Otomo_ElementBoost_Leaf_1_2", "Blueprint_Otomo_ElementBoost_Ice_1_2", "Blueprint_Otomo_ElementBoost_Earth_1_2",
  "Blueprint_Otomo_ElementBoost_Dark_1_2", "Blueprint_Otomo_ElementBoost_Dragon_1_2", "Blueprint_Otomo_Attack_up1_2", "Blueprint_Otomo_Defense_up1_2", "Blueprint_Otomo_PalExp_Increase_1_2", "Relic_12",
  "Accessory_PPAT_1", "Blueprint_Accessory_PPAT_1", "Accessory_PPDF_1", "Blueprint_Accessory_PPDF_1", "Accessory_HCMW_1", "Blueprint_Accessory_HCMW_1",
  "Accessory_HCHP_1", "Blueprint_Accessory_HCHP_1", "UniqueMaterial_FlowerPrince", "UniqueMaterial_Mothman", "Accessory_ExplosionResist", "Accessory_DFHP_1",
  "Blueprint_Accessory_DFHP_1", "Accessory_WKMC_1", "Blueprint_Accessory_WKMC_1", "Otomo_ATNormal_ElementBoost_1", "Blueprint_Otomo_ATNormal_ElementBoost_1", "Otomo_ATFire_ElementBoost_1",
  "Blueprint_Otomo_ATFire_ElementBoost_1", "Otomo_ATWater_ElementBoost_1", "Blueprint_Otomo_ATWater_ElementBoost_1", "Otomo_ATElectricity_ElementBoost_1", "Blueprint_Otomo_ATElectricity_ElementBoost_1", "Otomo_ATLeaf_ElementBoost_1",
  "Blueprint_Otomo_ATLeaf_ElementBoost_1", "Otomo_ATIce_ElementBoost_1", "Blueprint_Otomo_ATIce_ElementBoost_1", "Otomo_ATEarth_ElementBoost_1", "Blueprint_Otomo_ATEarth_ElementBoost_1", "Otomo_ATDark_ElementBoost_1",
  "Blueprint_Otomo_ATDark_ElementBoost_1", "Otomo_ATDragon_ElementBoost_1", "Blueprint_Otomo_ATDragon_ElementBoost_1", "Accessory_NonkChecker_1", "Blueprint_Accessory_NonkChecker_1", "Accessory_JumpAir_1",
  "Blueprint_Accessory_JumpAir_1", "Accessory_JumpAir_2", "Blueprint_Accessory_JumpAir_2", "Accessory_SuperJumpAir_1", "Blueprint_Accessory_SuperJumpAir_1", "Accessory_SuperJumpAir_2",
  "Blueprint_Accessory_SuperJumpAir_2", "Otomo_DFNormal_ElementBoost_1", "Blueprint_Otomo_DFNormal_ElementBoost_1", "Otomo_DFFire_ElementBoost_1", "Blueprint_Otomo_DFFire_ElementBoost_1", "Otomo_DFWater_ElementBoost_1",
  "Blueprint_Otomo_DFWater_ElementBoost_1", "Otomo_DFElectricity_ElementBoost_1", "Blueprint_Otomo_DFElectricity_ElementBoost_1", "Otomo_DFLeaf_ElementBoost_1", "Blueprint_Otomo_DFLeaf_ElementBoost_1", "Otomo_DFIce_ElementBoost_1",
  "Blueprint_Otomo_DFIce_ElementBoost_1", "Otomo_DFEarth_ElementBoost_1", "Blueprint_Otomo_DFEarth_ElementBoost_1", "Otomo_DFDark_ElementBoost_1", "Blueprint_Otomo_DFDark_ElementBoost_1", "Accessory_HeatFire_1",
  "Blueprint_Accessory_HeatFire_1", "Accessory_ColdIce_1", "Blueprint_Accessory_ColdIce_1", "Accessory_Otomo_Fire_1", "Blueprint_Accessory_Otomo_Fire_1", "Accessory_Otomo_Water_1",
  "Blueprint_Accessory_Otomo_Water_1", "Accessory_Otomo_Electricity_1", "Blueprint_Accessory_Otomo_Electricity_1", "Accessory_Otomo_Earth_1", "Blueprint_Accessory_Otomo_Earth_1", "Accessory_Otomo_Leaf_1",
  "Blueprint_Accessory_Otomo_Leaf_1", "Accessory_Otomo_Dark_1", "Blueprint_Accessory_Otomo_Dark_1", "Accessory_Otomo_Dargon_1", "Blueprint_Accessory_Otomo_Dargon_1", "Accessory_Otomo_Ice_1",
  "Blueprint_Accessory_Otomo_Ice_1", "Accessory_Otomo_Fire_2", "Blueprint_Accessory_Otomo_Fire_2", "BronzeSword", "Bat3", "Bat3_2",
  "Bat3_3", "Bat3_4", "Bat3_5", "Spear_ForestBoss2", "Spear_ForestBoss2_5", "Blueprint_Bat3_2",
  "Blueprint_Bat3_3", "Blueprint_Bat3_4", "Blueprint_Bat3_5", "Blueprint_Spear_ForestBoss2_5", "SkillCard_WindBurst", "HeadEquip048",
  "Otomo_PalConfidence_Increase_1", "Blueprint_Otomo_PalConfidence_Increase_1", "SkillCard_BubbleShower", "SkillCard_SeaGush", "UnlockEquipmentSlot_Weapon_02", "HeadEquip050",
  "HeadEquip053", "Blueprint_WhaleWhistle", "HeadEquip054", "HeadEquip049", "Accessory_Avoid_1", "Blueprint_Accessory_Avoid_1",
  "Meat_SwordCutlassFish", "GrilledSwordCutlassFish", "OctopusGirl_Takoyaki2", "HeadEquip051", "HeadEquip052", "SkyBowArrow",
  "SkySubmachineGunBullet", "SkyShotgunBullet", "SkyAssaultRifleBullet", "SkyGrenadeLauncherBullet", "Wood_Ancient", "Lava_Ancient",
  "BeastBone_Ancient", "Cake02", "Cake03", "Cake04", "Cake05", "PalEgg_MutationPal_01",
  "PalEgg_MutationPal_02", "PalEgg_MutationPal_03", "Blueprint_Otomo_PalConfidence_Increase_1_fix", "Blueprint_Accessory_Avoid_1_fix", "HeadEquip055", "HeadEquip056",
  "HeadEquip057", "HeadEquip058", "HeadEquip059", "SkillUnlock_CubeTurtle", "SkillUnlock_CubeTurtle_Neutral", "SkillUnlock_VolcanoDragon",
  "SkillUnlock_VolcanoDragon_Ice", "SkillUnlock_Kirin_Ice", "SkillUnlock_Thunderdog_Ice", "SkillUnlock_DomeArmorDragon", "SkillUnlock_SumoDog", "SkillUnlock_IceSeal_Ground",
  "SkillUnlock_ThiefBird", "SkillUnlock_BlueSkyDragon", "SkillUnlock_LotusDragon", "PalEgg_MutationPal_04", "PalEgg_MutationPal_05", "HeadEquip060",
  "HeadEquip061", "HeadEquip062", "BossDefeatReward_FireKirin", "BossDefeatReward_CubeTurtle", "BossDefeatReward_VolcanicMonster", "BossDefeatReward_KabukiMan",
  "BossDefeatReward_VolcanoDragon_Ice", "BossDefeatReward_GrassGolem", "BossDefeatReward_MushroomLady", "BossDefeatReward_WhiteDeer_Dark", "BossDefeatReward_RockBeast_Ice", "BossDefeatReward_LotusDragon",
  "BossDefeatReward_FoxExorcist", "BossDefeatReward_ThunderFluffyBird", "BossDefeatReward_ElecLizard", "BossDefeatReward_ElecSnail", "BossDefeatReward_GhostDragon", "BossDefeatReward_LilyQueen",
  "BossDefeatReward_ElecPanda", "BossDefeatReward_GrassGolem_Dark", "BossDefeatReward_Manticore", "BossDefeatReward_FlameBuffalo", "BossDefeatReward_IceFox", "BossDefeatReward_FoxMage",
  "BossDefeatReward_CubeTurtle_Neutral", "BossDefeatReward_MoonChild", "BossDefeatReward_ScorpionMan_Electric", "BossDefeatReward_RockBeast", "BossDefeatReward_VolcanoDragon", "BossDefeatReward_CactusDoll",
  "BossDefeatReward_DomeArmorDragon", "PalPassiveSkillChange_PlayerSP_DecreaseRate_Passive", "PalPassiveSkillChange_AutoHPRegeneRate_Passive", "PalPassiveSkillChange_ReloadSpeedUp_Passive", "Shield_07", "Otomo_DFDragon_ElementBoost_1",
  "Blueprint_Otomo_DFDragon_ElementBoost_1", "PalPassiveSkillChange_Consumable_MutationPal_Babysitter", "PalPassiveSkillChange_Consumable_MutationPal_Mutant", "PalPassiveSkillChange_Consumable_MutationPal_Immortal", "PalPassiveSkillChange_Consumable_MutationPal_ExplosionResist", "PalPassiveSkillChange_Consumable_RideJumpCount_Increase2",
}

-- Membership set + on-demand cache for get(), plus the alias table the naming rule produces
-- (empty here: all 2466 ids are already Lua identifiers, so every name is its own id). One
-- pass, the same one that used to build `set` alone.
local set, aliases, unnamed = catalog.index(M.CATALOG)
local cache = {}

---Names that are NOT ids. Empty for this catalog; see native/_catalog.lua rule (2).
M.ALIASES = aliases
---Rows with no named field, and why. Empty for this catalog; see rules (3) and (4).
M.UNNAMED = unnamed

-- get(id): an Item wrapper for ANY real catalog id, built on first use + cached; nil
-- if id is not a known item row. defining sets .id and registers into object_manager.
-- Reading a named field comes through here, so it is just as lazy.
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    local h = Item{ id = id }
    cache[id] = h
    return h
end

-- ---- CURATED wrappers (real DT_ItemDataTable row ids) ----

-- Wood — the vanilla wood material. onObtain fires via the CONFIRMED item.obtain dispatch
-- (PalPlayerState:AddItemGetLog_ToClient, ctx.itemId=="Wood") when the player picks up /
-- harvests wood; the log proves the obtain 導線 like Berries.onUse does for use.
M.Wood = Item{
    id          = "Wood",
    name        = "Wood",
    category    = "material",
    maxStack    = 9999,
    events = {
        onObtain = function(self, ctx)
            log.info("Wood onObtain: count=" .. tostring(ctx and ctx.count))
        end,
    },
}

-- Berries — the vanilla red-berry food (a consumable). onUse fires via the CONFIRMED
-- item.use dispatch (UseItemToCharacter_ServerInternal, ctx.itemId=="Berries"); the log
-- proves the item lifecycle 導線 like the ChickenPal demo does for pals.
M.Berries = Item{
    id          = "Berries",
    name        = "Red Berries",
    category    = "consumable",
    maxStack    = 100,
    events = {
        onUse = function(self, ctx)
            log.info("Berries onUse: target=" .. tostring(ctx and ctx.actor))
            -- TODO: restore satiety/health through the native gameplay layer.
        end,
        onObtain = function(self, ctx)
            log.info("Berries onObtain: count=" .. tostring(ctx and ctx.count))
        end,
    },
}

-- Arrow — vanilla bow ammunition (siblings in the table include Arrow_Fire,
-- Arrow_Poison, both CATALOG members).
M.Arrow = Item{
    id          = "Arrow",
    name        = "Arrow",
    category    = "ammo",
    maxStack    = 999,
}

-- Pre-seed curated so get(id) returns the curated handle (hooks intact). All three are named
-- exactly as their row is, so the curated field and the named field are the same field — the
-- hand-written declaration simply gets there first, and the lazy path never overwrites it.
for _, h in ipairs({ M.Wood, M.Berries, M.Arrow }) do
    set[h.id] = true
    cache[h.id] = h
end

-- LAST: hang the lazy named fields off the module. After the curated definitions, so the
-- rule-(4) shadow check sees the module's complete own surface. See native/_catalog.lua.
catalog.expose(M, { set = set, aliases = aliases, unnamed = unnamed,
                    get = M.get, label = "native.items" })

return M
