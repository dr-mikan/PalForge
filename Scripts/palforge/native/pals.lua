-- PalForge native.pals: the catalog of the game's OWN creatures, declared through api/pal the
-- same way a pack declares its own.
--
--   local pals = require("palforge.native.pals")
--   pals.BlueSkyDragon:spawn()      -- a NAMED handle for every row the game has
--   pals.get("BlueSkyDragon")       -- the same handle, by id string
--   pals.Chicken:spawn()            -- curated demo: carries a mesh and lifecycle log hooks
--
--   (a) M.CATALOG  — every DT_PalMonsterParameter_Common row id, 753 of them.
--   (b) M.<Name>   — a Pal handle per row, built on first read. native/_catalog.lua owns the
--                    naming rule; for this table it is the identity, because every one of the
--                    753 ids is already a Lua identifier.
--   (c) M.get(id)  — the same handles by id string; nil for anything not in the catalog.
--   (d) M.publish(id) — register that handle with object_manager, on request. See below.
--   (e) CURATED    — the two DEMO creatures (with live lifecycle log hooks).
--
-- Only the CURATED definitions call Pal{ ... } at load, so only they self-register into
-- object_manager at mod start; a named field and get(id) both build on demand. That is why
-- requiring this file never registers the hundreds of pal ids.
--
-- AND A READ NO LONGER REGISTERS EVEN THE ONE ROW IT TOUCHES (2026-08-02). M.get builds with
-- `{ register = false }` (contract C2) — the publish gate, forced by native/buildings.lua where
-- registration is not inert (a registered building def makes core/event track and PERSIST every
-- matching actor, so a field read started writing to the save; the measurement is in that
-- file's header). Pals persist nothing, but the gate is one rule in all six catalogs rather
-- than five exceptions, and it keeps a catalog walk from leaving 753 classes in the registry
-- that every namespaced lookup miss then walks.
--
-- WHAT REGISTRATION IS FOR HERE: core/event dispatches pal.spawned / pal.damaged / pal.death /
-- pal.captured by looking the CharacterID up in object_manager, and Pal.get(id) hands back a
-- registered class instead of fabricating a thin one. A lazy catalog handle declares no
-- handlers, so publishing one changes nothing observable — which is exactly why the two CURATED
-- demos below, which do declare handlers, still register at load and a lazy one does not.
--
-- WHAT A LAZY NATIVE HANDLE HONESTLY DOES:
--   * :spawn() is real for every id here — it hands the CharacterID to the game's own spawn
--     route. Read api/pal.lua's :spawn contract before believing its return: `true` means the
--     native call was ISSUED, the pal arrives seconds later, and the log is where the truth is.
--   * THE CATALOG IS NOT A LIST OF WILD ANIMALS. It is every row of the monster table, which
--     includes encounter variants the game only ever places itself: BOSS_* (field alphas),
--     RAID_*, GYM_*, PREDATOR_*, SUMMON_*, POLICE_*, Quest_*, and the *_Oilrig / *_BossRush /
--     *_Tower series. Spawning one is a real call with a real id and it will behave like the
--     encounter it is, not like a catchable pal. None are curated away: leaving a row out would
--     make it look unsupported when it is merely specialised, and nothing is built until asked.
--   * :iconOf() DOES answer for real, and needs nothing declared: core/icons reads
--     DT_PalIconDataTable keyed by exactly these row ids (674 of 674 rows carry an icon,
--     measured 2026-07-26).
--   * :renderOn(actor) returns false for a lazy handle, and that is correct rather than broken.
--     It attaches PalForge's OWN declared mesh (api/pal.lua:500) and a lazy handle declares
--     none — the game is already drawing the creature. The two curated demos below have one.
--   * :name() answers the id; the localised name is a DataTable row VALUE and reading one from
--     Lua is still unsolved on this build (the marker in api/item.lua).
--   * the lifecycle handlers (onSpawned / onDamaged / onDeath / onCaptured / onTick) only fire
--     for a definition that DECLARES them. A lazy handle declares none, so it is a way to act
--     ON a pal, not a way to be told about one. Declare your own Pal{ id = "...", events = ... }
--     under the same id to be dispatched to — which replaces the registration, see
--     test/cases/definitions.
--
-- ONE CREATURE, TWO SPELLINGS, AND WHAT THAT COSTS YOU. The game itself spells the sheep two
-- ways and this catalog carries both, because both are real:
--
--   "SheepBall"  — the BLUEPRINT id (live actor BP_SheepBall_C). It is what the runtime
--                  dispatches on, so it is the id the curated demo below is declared under.
--   "Sheepball"  — the DT_PalMonsterParameter_Common row FName (lowercase b), and therefore
--                  the key DT_PalCharacterIconDataTable answers to.
--
-- The consequence is not theoretical and it is not a typo to be fixed: `pals.SheepBall` and
-- `pals.Sheepball` are TWO HANDLES for ONE creature with DIFFERENT capabilities.
-- `pals.SheepBall:iconOf()` MISSES (no row is spelled that way) and `pals.Sheepball:iconOf()`
-- HITS; conversely the lifecycle handlers hang off "SheepBall", because that is the id the
-- dispatch carries. native/buildings.lua has the same split for WorkBench / Workbench.
--
-- What is done about it here, given that neither spelling can be dropped: the alternate is
-- carried as DATA in M.ROW_ID and M.iconOf(id) follows it, so `pals.iconOf("SheepBall")` answers
-- the game's own artwork while `pals.SheepBall:iconOf()` still misses. Handle:iconOf cannot
-- consult it — it is api/pal.lua's method and it reads self.id and self.icon only. A Pal.Spec
-- field for the icon-table spelling (`iconId`) would close the gap on the handle itself; until
-- it exists this module's iconOf is the whole of it.

local Pal     = require("palforge.api.pal")
local catalog = require("palforge.native._catalog")
local log     = require("palforge.utils.log").scope("native.pals")

local M = {}

-- The one DataTable this catalog stands for.
M.TABLE = "DT_PalMonsterParameter_Common"

-- CATALOG (DATA): every DT_PalMonsterParameter_Common row id — all 753 of them, verified
-- against dumps/catalog/datatables/DT_PalMonsterParameter_Common.json (count 753, exact set
-- match, 2026-07-26). GENERATED — do not hand-edit; regenerate from a fresh dump.
M.CATALOG = {
  "RAID_NightLady", "RAID_NightLady_Dark", "RAID_NightLady_Dark_2", "RAID_KingBahamut_Dragon", "RAID_KingBahamut_Dragon_2", "GYM_WorldTreeDragon",
  "GYM_WorldTreeDragon_2", "GYM_BlackGriffon", "GYM_ElecPanda", "GYM_Horus", "GYM_LilyQueen", "GYM_ThunderDragonMan",
  "GYM_MoonQueen", "GYM_SnowTigerBeastman", "GYM_BlueSkyDragon", "GYM_ElecPanda_2", "GYM_LilyQueen_2", "GYM_ThunderDragonMan_2",
  "GYM_Horus_2", "GYM_BlackGriffon_2", "GYM_BlackGriffon_2_Avatar", "GYM_MoonQueen_2", "GYM_MoonQueen_2_Servant", "GYM_SnowTigerBeastman_2",
  "GYM_BlueSkyDragon_2", "BadCatgirl", "BlueberryFairy", "BOSS_Alpaca", "BOSS_AmaterasuWolf", "BOSS_Anubis",
  "BOSS_BadCatgirl", "BOSS_Baphomet", "BOSS_Baphomet_Dark", "BOSS_Bastet", "BOSS_Bastet_Ice", "BOSS_BeardedDragon",
  "BOSS_BerryGoat", "BOSS_BirdDragon", "BOSS_BirdDragon_Ice", "BOSS_BlackCentaur", "BOSS_BlackFurDragon", "BOSS_BlackGriffon",
  "BOSS_BlackMetalDragon", "BOSS_BlueberryFairy", "BOSS_BlueDragon", "BOSS_BluePlatypus", "BOSS_Boar", "BOSS_BrownRabbit",
  "BOSS_CaptainPenguin", "BOSS_Carbunclo", "BOSS_CatBat", "BOSS_CatMage", "BOSS_CatMage_Fire", "BOSS_CatVampire",
  "BOSS_ChickenPal", "BOSS_ColorfulBird", "BOSS_CowPal", "BOSS_CuteButterfly", "BOSS_CuteFox", "BOSS_CuteMole",
  "BOSS_DarkCrow", "BOSS_DarkMutant", "BOSS_DarkScorpion", "BOSS_DarkScorpion_Ground", "BOSS_Deer", "BOSS_Deer_Ground",
  "BOSS_DreamDemon", "BOSS_DrillGame", "BOSS_Eagle", "BOSS_ElecCat", "BOSS_ElecLion", "BOSS_ElecPanda",
  "BOSS_FairyDragon", "BOSS_FairyDragon_Water", "BOSS_FengyunDeeper", "BOSS_FireKirin", "BOSS_FireKirin_Dark", "Boss_FlameBambi",
  "BOSS_FlameBuffalo", "BOSS_FlowerDinosaur", "BOSS_FlowerDinosaur_Electric", "BOSS_FlowerDoll", "BOSS_FlowerDoll_Fire", "BOSS_FlowerRabbit",
  "BOSS_FlyingManta", "BOSS_FoxMage", "BOSS_FoxMage_Dark", "BOSS_Ganesha", "BOSS_Garm", "BOSS_GhostBeast",
  "BOSS_GoldenHorse", "BOSS_Gorilla", "BOSS_Gorilla_Ground", "BOSS_GrassDragon", "BOSS_GrassMammoth", "BOSS_GrassMammoth_Ice",
  "BOSS_GrassPanda", "BOSS_GrassPanda_Electric", "BOSS_GrassRabbitMan", "BOSS_HadesBird", "BOSS_HadesBird_Electric", "BOSS_HawkBird",
  "BOSS_Hedgehog", "BOSS_Hedgehog_Ice", "BOSS_HerculesBeetle", "BOSS_HerculesBeetle_Ground", "BOSS_Horus", "BOSS_IceDeer",
  "BOSS_IceFox", "BOSS_IceHorse", "BOSS_IceHorse_Dark", "BOSS_JetDragon", "BOSS_Kelpie", "BOSS_Kelpie_Fire",
  "BOSS_KingAlpaca", "BOSS_KingAlpaca_Ice", "BOSS_KingBahamut", "BOSS_KingBahamut_Dragon", "BOSS_Kirin", "BOSS_Kirin_Ice",
  "BOSS_Kitsunebi", "Boss_LavaGirl", "Boss_LazyCatFish", "BOSS_LazyDragon", "BOSS_LazyDragon_Electric", "BOSS_LilyQueen",
  "BOSS_LilyQueen_Dark", "BOSS_LittleBriarRose", "BOSS_LizardMan", "BOSS_LizardMan_Fire", "BOSS_Manticore", "BOSS_Manticore_Dark",
  "BOSS_Monkey", "BOSS_Monkey_Ice", "BOSS_Monkey_Fire", "BOSS_MopBaby", "BOSS_MopKing", "BOSS_Mutant",
  "BOSS_NaughtyCat", "BOSS_NegativeKoala", "BOSS_NegativeOctopus", "BOSS_NightFox", "BOSS_Penguin", "BOSS_PinkCat",
  "BOSS_PinkKangaroo", "BOSS_PinkLizard", "BOSS_PinkRabbit", "BOSS_PlantSlime", "BOSS_PlantSlime_Flower", "BOSS_QueenBee",
  "BOSS_RaijinDaughter", "BOSS_RedArmorBird", "BOSS_RobinHood", "BOSS_RobinHood_Ground", "BOSS_Ronin", "BOSS_Ronin_Dark",
  "BOSS_SaintCentaur", "BOSS_SakuraSaurus", "BOSS_SakuraSaurus_Water", "BOSS_Serpent", "BOSS_Serpent_Ground", "BOSS_SharkKid",
  "BOSS_SharkKid_Fire", "BOSS_SheepBall", "BOSS_SkyDragon", "BOSS_SkyDragon_Grass", "BOSS_SoldierBee", "BOSS_Suzaku",
  "BOSS_Suzaku_Water", "BOSS_SweetsSheep", "BOSS_SweetsSheep_Ground", "BOSS_TentacleTurtle", "BOSS_ThunderBird", "BOSS_ThunderBird_Ice",
  "BOSS_ThunderDog", "BOSS_ThunderDog_Ice", "BOSS_ThunderDragonMan", "BOSS_Umihebi", "BOSS_Umihebi_Fire", "BOSS_VioletFairy",
  "BOSS_VolcanicMonster", "BOSS_VolcanicMonster_Ice", "BOSS_WaterLizard", "BOSS_WeaselDragon", "BOSS_WeaselDragon_Fire", "BOSS_Werewolf",
  "BOSS_WhiteMoth", "BOSS_WhiteMoth_Neutral", "BOSS_WhiteTiger", "BOSS_WindChimes", "BOSS_WindChimes_Ice", "BOSS_WizardOwl",
  "Boss_WoolFox", "BOSS_Yeti", "BOSS_Yeti_Grass", "BOSS_NightLady", "BOSS_NightLady_Dark", "BOSS_MoonQueen",
  "BOSS_KendoFrog", "BOSS_LeafPrincess", "BOSS_MushroomDragon", "BOSS_MushroomDragon_Dark", "BOSS_SmallArmadillo", "BOSS_FeatherOstrich",
  "BOSS_ScorpionMan", "BOSS_ScorpionMan_Electric", "BOSS_WingGolem", "BOSS_WingGolem_Fire", "BOSS_CandleGhost", "BOSS_GuardianDog",
  "BOSS_SifuDog", "BOSS_MimicDog", "BOSS_DarkAlien", "BOSS_WhiteAlienDragon", "BOSS_VolcanoDragon", "BOSS_VolcanoDragon_Ice",
  "BOSS_DarkMechaDragon", "BOSS_GhostRabbit", "BOSS_GhostRabbit_Grass", "BOSS_NightBlueHorse", "BOSS_NightBlueHorse_Neutral", "BOSS_WhiteShieldDragon",
  "BOSS_BlackPuppy", "BOSS_BlackPuppy_Ice", "BOSS_WhiteDeer", "BOSS_WhiteDeer_Dark", "BOSS_KingWhale", "BOSS_MysteryMask",
  "BOSS_HoodGhost", "BOSS_Sekhmet", "BOSS_ElecLizard", "BOSS_GrimGirl", "BOSS_PurpleSpider", "BOSS_BlueThunderHorse",
  "BOSS_RockBeast", "BOSS_RockBeast_Ice", "BOSS_OctopusGirl", "BOSS_OctopusGirl_Neutral", "BOSS_IceNarwhal", "BOSS_JellyfishFairy",
  "BOSS_BerryGoat_Dark", "BOSS_Kitsunebi_Ice", "BOSS_RaijinDaughter_Water", "BOSS_SnowTigerBeastman", "BOSS_Werewolf_Ice", "BOSS_WhiteTiger_Ground",
  "BOSS_Horus_Water", "BOSS_FengyunDeeper_Electric", "BOSS_AmaterasuWolf_Dark", "BOSS_PinkRabbit_Grass", "BOSS_SnakeGirl", "BOSS_GhostAnglerFish",
  "BOSS_IceWitch", "BOSS_ClownRabbit", "BOSS_LegendDeer", "BOSS_LeafMomonga", "BOSS_SmallYeti", "BOSS_IceCrocodile",
  "BOSS_CactusDoll", "BOSS_CactusDoll_Dark", "BOSS_MushroomLady", "BOSS_StuffedShark", "BOSS_FoxExorcist", "BOSS_IceSeal",
  "BOSS_IceSeal_Ground", "BOSS_CloverFairy", "BOSS_ElecPomeranian", "BOSS_GhostBlackCat", "BOSS_ThiefBird", "BOSS_OniGhostGirl",
  "BOSS_KingCrab", "BOSS_Plesiosaur", "BOSS_TropicalOstrich", "BOSS_GrassGolem", "BOSS_GrassGolem_Dark", "BOSS_SnowPeafowl",
  "BOSS_CubeTurtle", "BOSS_CubeTurtle_Neutral", "BOSS_LongCat", "BOSS_JellyfishGhost", "BOSS_ThunderFluffyBird", "BOSS_MoonChild",
  "BOSS_SamuraiDog", "BOSS_PoseidonOrca", "BOSS_SwordCutlassfish", "BOSS_SwordCutlassfish_Fire", "BOSS_NegativeOctopus_Neutral", "BOSS_Penguin_Electric",
  "BOSS_CaptainPenguin_Black", "BOSS_FlyingManta_Thunder", "BOSS_BluePlatypus_Fire", "BOSS_LazyCatfish_Gold", "BOSS_TentacleTurtle_Ground", "BOSS_KendoFrog_Dark",
  "BOSS_BlueDragon_Ice", "BOSS_IceNarwhal_Fire", "BOSS_GhostAnglerFish_Fire", "BOSS_StuffedShark_Fire", "BOSS_MummyPal", "BOSS_KingSunfish",
  "BOSS_KingSunfish_Thunder", "BOSS_MonochromeQueen", "BOSS_ElecSnail", "BOSS_ElecSnail_Fire", "BOSS_ElecSnail_Ground", "BOSS_LanternButler",
  "BOSS_SumoDog", "BOSS_VenusFlytrap", "BOSS_StrawHatCat", "BOSS_CandleWitch", "BOSS_FluffyBird", "BOSS_FrozenBear",
  "BOSS_DandelionGirl", "BOSS_VolcanicTurtle", "BOSS_ClioneTwins", "BOSS_DarkFlameFox", "BOSS_IceVeilDragon", "BOSS_RedFlowerBird",
  "BOSS_LotusDragon", "BOSS_BlueSkyDragon", "BOSS_BlueWoolRabbit", "BOSS_PandaGirl", "BOSS_GrassMinotaur", "BOSS_GrassMinotaur_Ice",
  "BOSS_MonochromeMushroom", "BOSS_SleeveRabbit", "BOSS_MedjedBird", "BOSS_Mothman", "BOSS_GhostDragon", "BOSS_GhostDragon_Fire",
  "BOSS_FlowerPrince", "BOSS_WorldTreeDragon", "BOSS_KabukiMan", "BOSS_DomeArmorDragon", "BOSS_RockCheetah", "BOSS_ArmorWoodlouse",
  "BOSS_MexicanSalamander", "BOSS_LeafBird", "BOSS_CuteOrca", "BOSS_SnakeQueen", "BrownRabbit", "ElecLion",
  "GoldenHorse", "PinkKangaroo", "TentacleTurtle", "TentacleTurtle_Ground", "BeardedDragon", "WaterLizard",
  "GrassDragon", "Anubis", "Baphomet", "Baphomet_Dark", "Bastet", "Bastet_Ice",
  "Boar", "Carbunclo", "ColorfulBird", "Deer", "Deer_Ground", "DrillGame",
  "Eagle", "ElecPanda", "Ganesha", "Garm", "Gorilla", "Gorilla_Ground",
  "Hedgehog", "Hedgehog_Ice", "Kirin", "Kirin_Ice", "Kitsunebi", "LittleBriarRose",
  "Mutant", "Penguin", "Penguin_Electric", "RaijinDaughter", "SharkKid", "SharkKid_Fire",
  "Sheepball", "Umihebi", "Umihebi_Fire", "Werewolf", "WindChimes", "WindChimes_Ice",
  "Suzaku", "Suzaku_Water", "FireKirin", "FireKirin_Dark", "FairyDragon", "FairyDragon_Water",
  "SweetsSheep", "SweetsSheep_Ground", "WhiteTiger", "Alpaca", "Serpent", "Serpent_Ground",
  "DarkCrow", "BlueDragon", "BlueDragon_Ice", "PinkCat", "NegativeKoala", "FengyunDeeper",
  "VolcanicMonster", "VolcanicMonster_Ice", "GhostBeast", "RobinHood", "RobinHood_Ground", "LazyDragon",
  "LazyDragon_Electric", "AmaterasuWolf", "LizardMan", "LizardMan_Fire", "BluePlatypus", "BluePlatypus_Fire",
  "BlackFurDragon", "BirdDragon", "BirdDragon_Ice", "ChickenPal", "FlowerDinosaur", "FlowerDinosaur_Electric",
  "ElecCat", "IceHorse", "IceHorse_Dark", "GrassMammoth", "GrassMammoth_Ice", "CatVampire",
  "SakuraSaurus", "SakuraSaurus_Water", "Horus", "KingBahamut", "KingBahamut_Dragon", "BerryGoat",
  "IceDeer", "BlackGriffon", "WhiteMoth", "WhiteMoth_Neutral", "CuteFox", "FoxMage",
  "FoxMage_Dark", "PinkLizard", "WizardOwl", "Kelpie", "Kelpie_Fire", "NegativeOctopus",
  "NegativeOctopus_Neutral", "CowPal", "Yeti", "Yeti_Grass", "VioletFairy", "HawkBird",
  "FlowerRabbit", "LilyQueen", "LilyQueen_Dark", "QueenBee", "SoldierBee", "CatBat",
  "GrassPanda", "GrassPanda_Electric", "FlameBuffalo", "ThunderDog", "ThunderDog_Ice", "CuteMole",
  "BlackMetalDragon", "GrassRabbitMan", "IceFox", "JetDragon", "DreamDemon", "Monkey",
  "Monkey_Ice", "Monkey_Fire", "Manticore", "Manticore_Dark", "KingAlpaca", "KingAlpaca_Ice",
  "PlantSlime", "PlantSlime_Flower", "DarkMutant", "MopBaby", "MopKing", "CatMage",
  "CatMage_Fire", "PinkRabbit", "ThunderBird", "ThunderBird_Ice", "HerculesBeetle", "HerculesBeetle_Ground",
  "SaintCentaur", "NightFox", "CaptainPenguin", "CaptainPenguin_Black", "WeaselDragon", "WeaselDragon_Fire",
  "SkyDragon", "SkyDragon_Grass", "HadesBird", "HadesBird_Electric", "RedArmorBird", "Ronin",
  "Ronin_Dark", "FlyingManta", "FlyingManta_Thunder", "BlackCentaur", "FlowerDoll", "FlowerDoll_Fire",
  "NaughtyCat", "CuteButterfly", "DarkScorpion", "DarkScorpion_Ground", "ThunderDragonMan", "WoolFox",
  "LazyCatfish", "LazyCatfish_Gold", "LavaGirl", "FlameBambi", "NightLady", "NightLady_Dark",
  "MoonQueen", "KendoFrog", "KendoFrog_Dark", "LeafPrincess", "MushroomDragon", "MushroomDragon_Dark",
  "SmallArmadillo", "CandleGhost", "ScorpionMan", "ScorpionMan_Electric", "WingGolem", "WingGolem_Fire",
  "GuardianDog", "SifuDog", "FeatherOstrich", "MimicDog", "DarkAlien", "WhiteAlienDragon",
  "VolcanoDragon", "VolcanoDragon_Ice", "DarkMechaDragon", "GhostRabbit", "GhostRabbit_Grass", "NightBlueHorse",
  "NightBlueHorse_Neutral", "WhiteShieldDragon", "BlackPuppy", "BlackPuppy_Ice", "WhiteDeer", "WhiteDeer_Dark",
  "KingWhale", "MysteryMask", "HoodGhost", "Sekhmet", "ElecLizard", "GrimGirl",
  "PurpleSpider", "BlueThunderHorse", "RockBeast", "RockBeast_Ice", "OctopusGirl", "OctopusGirl_Neutral",
  "IceNarwhal", "IceNarwhal_Fire", "JellyfishFairy", "SUMMON_DarkAlien", "SUMMON_DarkAlien_MAX", "SUMMON_WhiteAlienDragon",
  "SUMMON_WhiteAlienDragon_MAX", "PREDATOR_AmaterasuWolf", "PREDATOR_BirdDragon", "PREDATOR_DrillGame", "PREDATOR_FairyDragon", "PREDATOR_FeatherOstrich",
  "PREDATOR_FlowerDinosaur", "PREDATOR_Garm", "PREDATOR_GhostBeast", "PREDATOR_GoldenHorse", "PREDATOR_Gorilla", "PREDATOR_GrassPanda",
  "PREDATOR_GrimGirl", "PREDATOR_Horus_Water", "PREDATOR_LazyDragon", "PREDATOR_Manticore_Dark", "PREDATOR_MushroomDragon", "PREDATOR_MysteryMask",
  "PREDATOR_NightBlueHorse", "PREDATOR_PinkLizard", "PREDATOR_PurpleSpider", "PREDATOR_RedArmorBird", "PREDATOR_ScorpionMan", "PREDATOR_SifuDog",
  "PREDATOR_ThunderDog", "PREDATOR_Umihebi_Fire", "PREDATOR_VolcanicMonster_Ice", "PREDATOR_Werewolf_Ice", "PREDATOR_WhiteTiger_Ground", "PREDATOR_Yeti",
  "PREDATOR_HadesBird_Electric", "PREDATOR_Ronin_Dark", "PREDATOR_CandleGhost", "PREDATOR_Baphomet_Dark", "PREDATOR_VolcanoDragon", "PREDATOR_MummyPal",
  "PREDATOR_Suzaku", "PREDATOR_GrassMammoth_Ice", "PREDATOR_RedFlowerBird", "PREDATOR_GrassMinotaur_Ice", "PREDATOR_PandaGirl", "PREDATOR_DarkScorpion",
  "PREDATOR_SnakeGirl", "PREDATOR_MonochromeQueen", "RAID_DarkMechaDragon", "RAID_DarkMechaDragon_2", "Kitsunebi_Ice", "BerryGoat_Dark",
  "PinkRabbit_Grass", "Werewolf_Ice", "AmaterasuWolf_Dark", "RaijinDaughter_Water", "WhiteTiger_Ground", "FengyunDeeper_Electric",
  "Horus_Water", "SnowTigerBeastman", "WingGolem_Oilrig", "DarkAlien_Oilrig", "Horus_Oilrig", "Baphomet_Dark_Oilrig",
  "HadesBird_Oilrig", "LizardMan_Oilrig", "SnakeGirl", "GhostAnglerfish", "GhostAnglerfish_Fire", "IceWitch",
  "ClownRabbit", "LegendDeer", "LeafMomonga", "SmallYeti", "IceCrocodile", "CactusDoll",
  "CactusDoll_Dark", "MushroomLady", "StuffedShark", "StuffedShark_Fire", "FoxExorcist", "IceSeal",
  "IceSeal_Ground", "CloverFairy", "ElecPomeranian", "GhostBlackCat", "ThiefBird", "OniGhostGirl",
  "KingCrab", "Plesiosaur", "TropicalOstrich", "GrassGolem", "GrassGolem_Dark", "SnowPeafowl",
  "CubeTurtle", "CubeTurtle_Neutral", "LongCat", "JellyfishGhost", "ThunderFluffyBird", "MoonChild",
  "SamuraiDog", "PoseidonOrca", "SwordCutlassfish", "SwordCutlassfish_Fire", "YakushimaMonster001", "YakushimaMonster001_Blue",
  "YakushimaMonster001_Red", "YakushimaMonster001_Purple", "YakushimaMonster001_Pink", "YakushimaMonster001_Rainbow", "YakushimaMonster002", "YakushimaMonster003",
  "YakushimaMonster003_Purple", "YakushimaBoss001", "BOSS_YakushimaBoss001", "YakushimaBoss001_Small", "RAID_YakushimaBoss001_Green", "RAID_YakushimaBoss002",
  "RAID_YakushimaBoss002_Hand_Left", "RAID_YakushimaBoss002_Hand_Right", "Quest_Farmer03_SheepBall", "Quest_Farmer03_PinkCat", "GYM_ElecPanda_Otomo", "RAID_YakushimaBoss002_Head",
  "RAID_YakushimaBoss002_2", "RAID_YakushimaBoss002_Hand_Left_2", "RAID_YakushimaBoss002_Hand_Right_2", "RAID_YakushimaBoss002_Head_2", "RAID_YakushimaBoss001_Green_2", "MummyPal",
  "KingSunfish", "KingSunfish_Thunder", "MonochromeQueen", "ElecSnail", "ElecSnail_Fire", "ElecSnail_Ground",
  "LanternButler", "SumoDog", "VenusFlytrap", "StrawHatCat", "CandleWitch", "FluffyBird",
  "FrozenBear", "DandelionGirl", "VolcanicTurtle", "RAID_LegendDeer", "RAID_LegendDeer_2", "ClioneTwins",
  "DarkFlameFox", "IceVeilDragon", "RedFlowerBird", "SleeveRabbit", "LotusDragon", "BlueSkyDragon",
  "BlueWoolRabbit", "PandaGirl", "GrassMinotaur", "GrassMinotaur_Ice", "MonochromeMushroom", "MedjedBird",
  "Mothman", "GhostDragon", "GhostDragon_Fire", "FlowerPrince", "WorldTreeDragon", "KabukiMan",
  "DomeArmorDragon", "RockCheetah", "ArmorWoodlouse", "MexicanSalamander", "LeafBird", "CuteOrca",
  "SnakeQueen", "BOSS_KingWhale_otomo", "PREDATOR_WhiteShieldDragon_Quest", "PREDATOR_FlowerRabbit_Quest", "POLICE_ThunderDog", "POLICE_HawkBird",
  "BOSS_ElecPanda_BossRush", "BOSS_LilyQueen_BossRush", "BOSS_ThunderDragonMan_BossRush", "BOSS_Horus_BossRush", "BOSS_BlackGriffon_BossRush", "BOSS_MoonQueen_BossRush",
  "BOSS_SnowTigerBeastman_BossRush", "BOSS_BlueSkyDragon_BossRush", "GrassPanda_Electric_Tower", "LazyDragon_Electric_Tower", "PREDATOR_Garm_Quest", "PREDATOR_PinkLizard_Quest",
  "PREDATOR_Umihebi_Fire_Quest", "AmaterasuWolf_Dark_Quest_Friend", "AmaterasuWolf_Dark_Quest_Enemy",
}

-- Membership set + on-demand cache for get(), plus the alias table the naming rule produces
-- (empty here: all 753 ids are already Lua identifiers, so every name is its own id). One pass,
-- the same one that used to build `set` alone.
local set, aliases, unnamed = catalog.index(M.CATALOG)
local cache = {}

---Names that are NOT ids. Empty for this catalog; see native/_catalog.lua rule (2).
M.ALIASES = aliases
---Rows with no named field, and why. Empty for this catalog; see rules (3) and (4).
M.UNNAMED = unnamed

-- get(id): a Pal wrapper for ANY real catalog id, built on first use + cached; nil if
-- id is not a known monster row. Reading a named field comes through here, so it is just as
-- lazy — and, since 2026-08-02, just as non-registering: `{ register = false }` is contract
-- C2's publish gate (see the header). The handle is complete and cached; only object_manager is
-- left out of it, until M.publish(id).
function M.get(id)
    if not id or not set[id] then return nil end
    if cache[id] then return cache[id] end
    local h = Pal({ id = id }, { register = false, pack = catalog.PACK })
    cache[id] = h
    return h
end

---Register this catalog's handle for `id` with object_manager: the opt-in half of the publish
---gate. What it buys is named in the header — pal.* dispatch resolving to this class, and
---Pal.get(id) finding it — and a lazy handle declares no handlers, so publishing one is mostly
---of use to something that wants to see the catalog through Pal.get_all().
---
---Idempotent, and it publishes the SAME handle the named field hands back. Returns nil for an id
---this catalog does not have.
---@param id string
---@return Pal.Handle?
function M.publish(id)
    local h = M.get(id)
    if not h then return nil end
    catalog.publish("pal", h, "native.pals")
    return h
end

---The DataTable row spelling for an id whose BLUEPRINT spelling differs — the two-spellings note
---in the header. Published as data so the mismatch is readable at runtime rather than folklore,
---and consumed by M.iconOf below.
M.ROW_ID = { SheepBall = "Sheepball" }

---This creature's paldeck icon, resolved through BOTH spellings: the id as given, then the row
---spelling M.ROW_ID knows it by. `pals.SheepBall:iconOf()` misses because the icon table is keyed
---by the DataTable row FName and "SheepBall" is not one; this function is the way in that does
---not make the caller know that.
---@param id string
---@return any?  # texture ref from DT_PalCharacterIconDataTable, else nil
function M.iconOf(id)
    local h = M.get(id)
    local tex = h and h:iconOf()
    if tex ~= nil then return tex end
    local row = id and M.ROW_ID[id]
    local rh = row and M.get(row)
    return rh and rh:iconOf() or nil
end

-- ---- CURATED demo creatures (real dump ids, with lifecycle hooks) ----
-- These prove the pal lifecycle end-to-end: kill or catch a wild Chicken/SheepBall and
-- the captured / damaged / death channels (real UE4SS hooks in core.event) dispatch to
-- the hooks below. Hooks are dispatched as cls:hook(ctx); the first arg IS ctx (the
-- channel payload { actor = <pal actor> }). Each just logs to prove it fired.
--
-- BOTH STILL REGISTER AT LOAD, unlike native/buildings.lua's curated pair, and the difference is
-- what registration DOES in each domain. A registered pal class is how core/event finds a
-- handler for a spawn / damage / death / capture it just saw; it starts no tracking and writes
-- no file. A registered BUILDING class starts a scan that persists a record for every matching
-- actor in the world, which is why that pair had to stop registering itself and these two did
-- not. They register under the framework's own pack id (contract C3), so a pack that declares
-- "ChickenPal" replaces a definition whose previous owner can be named.

-- ChickenPal — id "ChickenPal" (live BP_ChickenPal_C; also a CATALOG member).
M.Chicken = Pal({
    id          = "ChickenPal",
    name        = "Chicken Pal (demo)",
    mesh = {
        kind      = "skeletal",
        model     = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal",
        animClass = "/Game/Pal/Blueprint/Character/Monster/PalActorBP/ChickenPal/ABP_ChickenPal.ABP_ChickenPal_C",
    },
    events = {
        onCaptured = function(self, ctx)
            log.info("ChickenPal onCaptured: " .. tostring(ctx and ctx.actor))
        end,
        onDamaged = function(self, ctx)
            log.info("ChickenPal onDamaged: " .. tostring(ctx and ctx.actor))
        end,
        onDeath = function(self, ctx)
            log.info("ChickenPal onDeath: " .. tostring(ctx and ctx.actor))
        end,
    },
}, { pack = catalog.PACK })

-- SheepBall — dispatch id "SheepBall" (live BP_SheepBall_C). The DT row FName is
-- spelled "Sheepball" (lowercase b); the runtime keys off the BP id, so we define
-- under "SheepBall" — which is therefore NOT itself a CATALOG member (pre-seeded).
M.SheepBall = Pal({
    id          = "SheepBall",
    name        = "Sheepball (demo)",
    mesh = {
        kind      = "skeletal",
        model     = "/Game/Pal/Model/Character/Monster/SheepBall/SK_SheepBall.SK_SheepBall",
        animClass = "/Game/Pal/Blueprint/Character/Monster/PalActorBP/SheepBall/ABP_SheepBall.ABP_SheepBall_C",
    },
    events = {
        onCaptured = function(self, ctx)
            log.info("SheepBall onCaptured: " .. tostring(ctx and ctx.actor))
        end,
        onDamaged = function(self, ctx)
            log.info("SheepBall onDamaged: " .. tostring(ctx and ctx.actor))
        end,
        onDeath = function(self, ctx)
            log.info("SheepBall onDeath: " .. tostring(ctx and ctx.actor))
        end,
    },
}, { pack = catalog.PACK })

-- Pre-seed curated so get(id) returns the curated handle (hooks intact), and so
-- get("SheepBall") resolves even though the DT row is spelled "Sheepball".
--
-- NOTE what this makes of the named fields. `M.Chicken` is a NICKNAME — "Chicken" is not a row
-- id, so it names nothing but this hand-written definition, while `pals.ChickenPal` is the row's
-- own name and resolves to this very handle through the cache below. `M.SheepBall` is the
-- blueprint spelling the runtime dispatches by; `pals.Sheepball` is the DataTable row, whose
-- lazy handle is what the icon table answers to. Neither pair is a typo and neither is hidden —
-- the split is written out in the header, carried as data in M.ROW_ID, and followed by M.iconOf.
for _, h in ipairs({ M.Chicken, M.SheepBall }) do
    set[h.id] = true
    cache[h.id] = h
end

-- LAST: hang the lazy named fields off the module. After the curated definitions, so the
-- rule-(4) shadow check sees the module's complete own surface. See native/_catalog.lua.
catalog.expose(M, { set = set, aliases = aliases, unnamed = unnamed,
                    get = M.get, label = "native.pals" })

return M
