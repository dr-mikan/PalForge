-- palforge/core/character.lua — a pal's or player's own parameter object, and the two things
-- worth writing to it: its active skills and its passive skills.
--
-- Palworld keeps everything per-CHARACTER on a UPalIndividualCharacterParameter, one per
-- individual, reached from any actor in a single call (dumps/cxx/Pal.hpp:32340, on the
-- PalUtility CDO that utils/items already resolves for the inventory):
--
--     UPalIndividualCharacterParameter* GetIndividualCharacterParameterByActor(const AActor*);
--
-- and that object (dumps/cxx/Pal.hpp:20822) is where the skill lists live:
--
--     void AddEquipWaza(EPalWazaID WazaID);          -- an ACTIVE skill (a "waza")
--     void RemoveEquipWaza(EPalWazaID WazaID);
--     void ClearEquipWaza();
--     TArray<EPalWazaID> GetEquipWaza();             -- and the read-back that verifies a write
--     TArray<EPalWazaID> GetEquipableWaza();
--     bool HasMasteredWaza(EPalWazaID WazaID);
--     void AddPassiveSkill(FName AddSkill, FName OverrideSkill);   -- a PASSIVE skill
--     void RemovePassiveSkill(FName SkillId);
--     TArray<FName> GetPassiveSkillList();
--
-- Every argument on that list is a scalar — an enum integer or an FName — so none of them is
-- the shape that faults inside UE4SS marshalling, and every write has a matching read to prove
-- it landed. That is the whole reason this is reachable at all.
--
-- ACTIVE SKILLS ARE AN ENUM, PASSIVES ARE NAMES. It is not a stylistic difference and a caller
-- cannot use one where the other is wanted: an active skill is one of 309 EPalWazaID values
-- (dumps/cxx/Pal_enums.hpp) and is addressed by that name or its integer, while a passive is an
-- FName row id and is addressed as a string. M.addSkill routes on which one the id is.
--
--   local ch = require("palforge.core.character")
--   ch.addSkill(pawn, "FireBlast")            -- an EPalWazaID name: an active skill
--   ch.addSkill(pawn, "Legend")               -- not one: treated as a passive skill FName
--   ch.skillsOn(pawn)                         -- { active = {...}, passive = {...} }
--
-- SERVER AUTHORITY is the thing to suspect first if a live run reports false with evidence
-- "declared". APalPlayerController carries AddEquipWaza_ToServer(FPalInstanceID, EPalWazaID)
-- and ReplaceEquipWaza_ToServer, which is the game's own path for a remote client. Those take
-- an FPalInstanceID STRUCT, which core.signature will not pass on an unread declaration, so the
-- direct call is what is wired — correct on a single-player or host session, and the read-back
-- below is what will say if it is not enough elsewhere.
--
-- TODO(pal-skills-equip): unknown whether these writes LAND. Everything else is settled — the
-- route from an actor, the four write calls and their matching read-backs, and the 309-value
-- EPalWazaID vocabulary that had no source anywhere before. What no run has done is call one.
-- Because every write here is verified by reading the character back, one press of F1 in a
-- loaded world answers it without ambiguity: a true means the skill was SEEN on the character,
-- not that a call did not raise. Two things to watch in the log — the evidence level (an
-- EnumProperty build spells EPalWazaID differently from a ByteProperty one, which shows up as a
-- refusal rather than a crash), and a "declared" call that still does not land, which would
-- point at server authority and make APalPlayerController's AddEquipWaza_ToServer the next
-- read (it takes an FPalInstanceID struct, so core.signature will not fire it unattended).
local log       = require("palforge.utils.log").scope("character")
local signature = require("palforge.core.signature")

local M = {}

-- EPalWazaID, verbatim from dumps/cxx/Pal_enums.hpp. `None` and the trailing MAX sentinel are
-- omitted: neither is a skill. These are the game's own spellings, so they are what a pack
-- writes in `Pal{ skills = { ... } }` for an active skill.
M.WAZA = {
    ["Human_Punch"] = 1,
    ["WorkAttack"] = 2,
    ["Throw"] = 3,
    ["Scratch"] = 4,
    ["EnergyShot"] = 5,
    ["Unique_Anubis_LowRoundKick"] = 6,
    ["Unique_Anubis_GroundPunch"] = 7,
    ["Unique_Anubis_Tackle"] = 8,
    ["Unique_Deer_PushupHorn"] = 9,
    ["HyperBeam"] = 10,
    ["PowerShot"] = 11,
    ["PowerBall"] = 12,
    ["Unique_Garm_Bite"] = 13,
    ["Intimidate"] = 14,
    ["Unique_Boar_Tackle"] = 15,
    ["Unique_PinkCat_CatPunch"] = 16,
    ["Unique_FlowerDinosaur_Whip"] = 17,
    ["Unique_SheepBall_Roll"] = 18,
    ["Unique_ChickenPal_ChickenPeck"] = 19,
    ["Unique_Gorilla_GroundPunch"] = 20,
    ["Unique_Grassmammoth_Earthquake"] = 21,
    ["AirCanon"] = 22,
    ["Unique_GrassPanda_MusclePunch"] = 23,
    ["Unique_RobinHood_BowSnipe"] = 24,
    ["Unique_Alpaca_Tackle"] = 25,
    ["Unique_KingAlpaca_BodyPress"] = 26,
    ["Unique_Werewolf_Scratch"] = 27,
    ["Unique_FengyunDeeper_CloudTempest"] = 28,
    ["Unique_Baphomet_SwallowKite"] = 29,
    ["Unique_HerculesBeetle_BeetleTackle"] = 30,
    ["Unique_HawkBird_Storm"] = 31,
    ["Unique_Eagle_GlidingNail"] = 32,
    ["SelfDestruct"] = 33,
    ["SelfDestruct_Bee"] = 34,
    ["SelfExplosion"] = 35,
    ["Unique_Garm_BiteV2"] = 36,
    ["Unique_GuardianDog_Bite"] = 37,
    ["Unique_GuardianDog_BiteV2"] = 38,
    ["RadiantBarrage"] = 39,
    ["FireBlast"] = 40,
    ["Flamethrower"] = 41,
    ["FireBall"] = 42,
    ["FlareArrow"] = 43,
    ["FireSeed"] = 44,
    ["Unique_Horus_FlareBird"] = 45,
    ["FlareTornado"] = 46,
    ["Inferno"] = 47,
    ["Unique_FireKirin_Tackle"] = 48,
    ["Unique_AmaterasuWolf_FireCharge"] = 49,
    ["Unique_VolcanicMonster_MagmaAttack"] = 50,
    ["Unique_FlameBuffalo_FlameHorn"] = 51,
    ["Eruption"] = 52,
    ["FlameWall"] = 53,
    ["FlameFunnel"] = 54,
    ["Unique_AmaterasuWolf_Bite"] = 55,
    ["Unique_AmaterasuWolf_BiteV2"] = 56,
    ["WaterGun"] = 57,
    ["WaterWave"] = 58,
    ["HydroPump"] = 59,
    ["WaterBall"] = 60,
    ["TidalWave"] = 61,
    ["AquaJet"] = 62,
    ["BubbleShot"] = 63,
    ["AcidRain"] = 64,
    ["SeaGush"] = 65,
    ["RipTide"] = 66,
    ["DiversionLaser"] = 67,
    ["HydroSlicer"] = 68,
    ["Unique_BluePlatypus_Toboggan"] = 69,
    ["Unique_TentacleTurtle_HydroSpin"] = 70,
    ["Unique_SakuraSaurus_Water_SplashTackle"] = 71,
    ["WindCutter"] = 72,
    ["GrassTornado"] = 73,
    ["SolarBeam"] = 74,
    ["SeedMachinegun"] = 75,
    ["SeedMine"] = 76,
    ["RootAttack"] = 77,
    ["SpecialCutter"] = 78,
    ["CrossWind"] = 79,
    ["ReflectiveShuriken"] = 80,
    ["HealingTree"] = 81,
    ["Unique_QueenBee_SpinLance"] = 82,
    ["ThunderRain"] = 83,
    ["ThunderBall"] = 84,
    ["LineThunder"] = 85,
    ["CrossThunder"] = 86,
    ["ThreeThunder"] = 87,
    ["ElecWave"] = 88,
    ["Thunderbolt"] = 89,
    ["ThunderFunnel"] = 90,
    ["SpreadPulse"] = 91,
    ["LockonLaser"] = 92,
    ["LightningStrike"] = 93,
    ["ThunderSpear"] = 94,
    ["Unique_ElecPanda_ElecScratch"] = 95,
    ["Unique_Kirin_LightningTackle"] = 96,
    ["Unique_FlowerDinosaur_Electric_ThunderWhip"] = 97,
    ["Unique_ThunderDog_Bite"] = 98,
    ["Unique_ThunderDog_BiteV2"] = 99,
    ["IceMissile"] = 100,
    ["BlizzardLance"] = 101,
    ["SnowStorm"] = 102,
    ["IcicleThrow"] = 103,
    ["IceBlade"] = 104,
    ["Unique_IceHorse_IceBladeAttack"] = 105,
    ["Unique_IceNarwhal_JumpingHorn"] = 106,
    ["Unique_KingAlpaca_Ice_IcePress"] = 107,
    ["SandTornado"] = 108,
    ["ThrowRock"] = 109,
    ["RockLance"] = 110,
    ["MudShot"] = 111,
    ["StoneShotgun"] = 112,
    ["Unique_DrillGame_ShellAttack"] = 113,
    ["Unique_Deer_Ground_DirtyHorn"] = 114,
    ["Unique_Gorilla_Ground_EarthPunch"] = 115,
    ["Unique_GoldenHorse_Bite"] = 116,
    ["Unique_GoldenHorse_BiteV2"] = 117,
    ["DarkLaser"] = 118,
    ["DarkWave"] = 119,
    ["ShadowBall"] = 120,
    ["Psychokinesis"] = 121,
    ["PoisonShot"] = 122,
    ["GhostFlame"] = 123,
    ["GravityShot"] = 124,
    ["Unique_DarkCrow_TelePoke"] = 125,
    ["Unique_Baphomet_Dark_DarkKite"] = 126,
    ["Unique_IceHorse_Dark_DarkBladeAttack"] = 127,
    ["Unique_AmaterasuWolf_Dark_Bite"] = 128,
    ["Unique_AmaterasuWolf_Dark_BiteV2"] = 129,
    ["Unique_BlackPuppy_Bite"] = 130,
    ["Unique_BlackPuppy_BiteV2"] = 131,
    ["DragonMeteor"] = 132,
    ["DragonBreath"] = 133,
    ["DragonWave"] = 134,
    ["DragonCanon"] = 135,
    ["Unique_FairyDragon_FairyTornado"] = 136,
    ["Funnel_DreamDemon"] = 137,
    ["Funnel_RaijinDaughter"] = 138,
    ["StardustArrow"] = 139,
    ["Tremor"] = 140,
    ["FrostBreath"] = 141,
    ["DiamondFall"] = 142,
    ["BeamSlicer"] = 143,
    ["Commet"] = 144,
    ["DarkBall"] = 145,
    ["PoisonFog"] = 146,
    ["DarkLegion"] = 147,
    ["DarkCanon"] = 148,
    ["DarkArrow"] = 149,
    ["DarkPulse"] = 150,
    ["Apocalypse"] = 151,
    ["StarMine"] = 152,
    ["AirBlade"] = 153,
    ["HolyBlast"] = 154,
    ["RootLance"] = 155,
    ["LineGeyser"] = 156,
    ["WallSplash"] = 157,
    ["TriSpark"] = 158,
    ["ThunderStorm"] = 159,
    ["SandTwister"] = 160,
    ["IcicleLine"] = 161,
    ["ThreeCommet"] = 162,
    ["CommetRain"] = 163,
    ["BlastCanon"] = 164,
    ["ChargeCanon"] = 165,
    ["RangeThunder"] = 166,
    ["Railbolt"] = 167,
    ["ShokeiLaser"] = 168,
    ["BubbleShower"] = 169,
    ["WaterBalloon"] = 170,
    ["IciclePierce"] = 171,
    ["DoubleIcicleThrow"] = 172,
    ["IceAge"] = 173,
    ["RaidCutter"] = 174,
    ["WindEdge"] = 175,
    ["FlareTwister"] = 176,
    ["TrisRing"] = 177,
    ["Unique_BirdDragon_FireBreath"] = 178,
    ["Unique_BlackMetalDragon_FirePunch"] = 179,
    ["Unique_DarkScorpion_Pierce"] = 180,
    ["Unique_GhostBeast_Tossin"] = 181,
    ["Unique_JetDragon_JumpBeam"] = 182,
    ["Unique_ThunderBird_ThunderStorm"] = 183,
    ["Unique_Yeti_SnowBall"] = 184,
    ["Unique_NaughtyCat_CatPress"] = 185,
    ["Unique_IceDeer_IceHorn"] = 186,
    ["Unique_KingBahamut_AirCrash"] = 187,
    ["Unique_Manticore_InfernoStrike"] = 188,
    ["Unique_SoldierBee_NeedleLance"] = 189,
    ["Unique_ThunderDog_InazumaShorai"] = 190,
    ["Unique_BlackCentaur_TwoSpearRushes"] = 191,
    ["Unique_BlackGriffon_TackleLaser"] = 192,
    ["Unique_SakuraSaurus_SideTackle"] = 193,
    ["Unique_ThunderDragonMan_ThunderSwordAttack"] = 194,
    ["Unique_RedArmorBird_TriplePeck"] = 195,
    ["Unique_CaptainPenguin_BodySlide"] = 196,
    ["Unique_CaptainPenguin_Black_BodySlide_Electric"] = 197,
    ["Unique_Ronin_Iai"] = 198,
    ["Unique_GrassRabbitMan_GrassRoundKick"] = 199,
    ["Unique_SaintCentaur_OneSpearRushes"] = 200,
    ["Unique_Umihebi_WindingTackle"] = 201,
    ["Unique_WeaselDragon_FlyingTackle"] = 202,
    ["Unique_WhiteTiger_IceScratch"] = 203,
    ["Unique_IceCrocodile_SpitAttack"] = 204,
    ["Unique_BirdDragon_Ice_IceBreath"] = 205,
    ["Unique_FireKirin_Dark_DarkTossin"] = 206,
    ["Unique_VolcanicMonster_Ice_IceAttack"] = 207,
    ["Unique_LeafMomonga_SomerSault"] = 208,
    ["Unique_Yeti_Grass_GrassBall"] = 209,
    ["Unique_GrassPanda_Electric_ElectricPunch"] = 210,
    ["Unique_NightLady_WarpBeam"] = 211,
    ["Unique_NightLady_WarpBeam_Straight"] = 212,
    ["Unique_NightLady_FlameNightmare"] = 213,
    ["Unique_MoonQueen_MoonBeam"] = 214,
    ["Unique_MoonQueen_MoonBlade"] = 215,
    ["Unique_KingBahamut_ArmSmash"] = 216,
    ["Unique_WingGolem_RoundCutter"] = 217,
    ["Unique_ScorpionMan_Uppercut"] = 218,
    ["Unique_FeatherOstrich_Tossin"] = 219,
    ["Unique_DarkAlien_JumpScractch"] = 220,
    ["Unique_SifuDog_Counter"] = 221,
    ["Unique_ThunderDragonMan_NumerousSwordAttack"] = 222,
    ["Unique_ElecPanda_GatlingAttack"] = 223,
    ["Unique_LilyQueen_LilyHealing"] = 224,
    ["Unique_LilyQueen_WindBarrier"] = 225,
    ["Unique_Horus_PerfectStorm"] = 226,
    ["Unique_BlackGriffon_TackleLaser2"] = 227,
    ["Unique_MoonQueen_IceMoonBlade"] = 228,
    ["Unique_DarkMechaDragon_SetFunnel"] = 229,
    ["Unique_DarkMechaDragon_ConvergentBeam"] = 230,
    ["Unique_DarkMechaDragon_FunnelLaser"] = 231,
    ["Unique_DarkMechaDragon_BeamSlash"] = 232,
    ["Unique_DarkMechaDragon_WarpComet"] = 233,
    ["Unique_Umihebi_Fire_FireWindingTackle"] = 234,
    ["Unique_PurpleSpider_SpiderRaid"] = 235,
    ["Unique_MysteryMask_LifeSteal"] = 236,
    ["Unique_GrimGirl_BrutalMachete"] = 237,
    ["Unique_SnowTigerBeastman_TrampleSlash"] = 238,
    ["Unique_SnowTigerBeastman_SnowImpact"] = 239,
    ["Unique_WhiteShieldDragon_ShieldTackle"] = 240,
    ["Unique_NightBlueHorse_DeathStep"] = 241,
    ["Unique_BlueThunderHorse_FlashDash"] = 242,
    ["Unique_WhiteDeer_HolyPillar"] = 243,
    ["Unique_GoldenHorse_StoneDash"] = 244,
    ["Unique_WhiteTiger_Ground_IronScratch"] = 245,
    ["Unique_FengyunDeeper_Electric_ThunderTempest"] = 246,
    ["Unique_Werewolf_Ice_SnowScratch"] = 247,
    ["Unique_Horus_Water_AquaStorm"] = 248,
    ["Unique_AmaterasuWolf_Dark_DarkCharge"] = 249,
    ["Unique_OctopursGirl_InkJet"] = 250,
    ["Unique_StuffedShark_HiddenWeapon"] = 251,
    ["Unique_Plesiosaur_LongBreath"] = 252,
    ["Unique_TropicalOstrich_DashKick"] = 253,
    ["Unique_GhostAnglerfish_SweepBait"] = 254,
    ["Unique_GhostAnglerfish_Fire_SweepBait_Fire"] = 255,
    ["Unique_PoseidonOrca_TorrentLaser"] = 256,
    ["Unique_VolcanoDragon_VolcanicLaser"] = 257,
    ["Unique_VolcanoDragon_MagmaSpit"] = 258,
    ["Unique_Sekhmet_RollingScratch"] = 259,
    ["Unique_Sekhmet_SomersaultScratch"] = 260,
    ["Unique_LegendDeer_WarpPillarBurst"] = 261,
    ["Unique_LegendDeer_BarrierRelease_Normal"] = 262,
    ["Unique_LegendDeer_BarrierRelease_Grass"] = 263,
    ["Unique_LegendDeer_BarrierRelease_Water"] = 264,
    ["Unique_LegendDeer_RadiantPurge"] = 265,
    ["Unique_LegendDeer_RadiantWingRush"] = 266,
    ["Unique_LegendDeer_RadiantPurge_Otomo"] = 267,
    ["Unique_Yakushima_SummonServant"] = 268,
    ["Unique_Yakushima_EyeTossin"] = 269,
    ["Unique_Yakushima_MouthTossin"] = 270,
    ["Unique_YakushimaMonster001_SlimePress_Normal"] = 271,
    ["Unique_YakushimaMonster001_SlimePress_Leaf"] = 272,
    ["Unique_YakushimaMonster001_SlimePress_Water"] = 273,
    ["Unique_YakushimaMonster001_SlimePress_Fire"] = 274,
    ["Unique_YakushimaMonster001_SlimePress_Dark"] = 275,
    ["Unique_YakushimaMonster001_SlimePress_Rainbow"] = 276,
    ["Unique_YakushimaBoss001_Small_DemonEyeCharge"] = 277,
    ["Unique_YakushimaMonster002_SwordCharge"] = 278,
    ["Unique_YakushimaMonster003_BatCharge"] = 279,
    ["PredatorBeam"] = 280,
    ["PredatorWave"] = 281,
    ["PredatorLockon"] = 282,
    ["RockBeat"] = 283,
    ["IceWall"] = 284,
    ["Funnel_RaijinDaughter_Water"] = 285,
    ["BlueThunderHorse_PartnerSkill"] = 286,
    ["Unique_YakushimaBoss001_Green_PhantasmalBolt"] = 287,
    ["Unique_YakushimaBoss001_Green_PhantasmalEye"] = 288,
    ["Unique_YakushimaBoss001_Green_PhantasmalSphere"] = 289,
    ["Unique_YakushimaBoss001_Green_PhantasmalDeathray"] = 290,
    ["Unique_YakushimaBoss002_PhantasmalBolt"] = 291,
    ["Unique_YakushimaBoss002_PhantasmalEye"] = 292,
    ["Unique_YakushimaBoss002_PhantasmalSphere"] = 293,
    ["Unique_YakushimaBoss002_PhantasmalDeathray"] = 294,
    ["PoseidonOrca_PartnerSkill_SpearBullet"] = 295,
    ["PoseidonOrca_PartnerSkill"] = 296,
    ["Unique_BluePlatypus_Toboggan_Fire"] = 297,
    ["Human_Rolling"] = 298,
    ["Weapon_Use"] = 299,
    ["Unique_YakushimaBoss001_Green_2_PhantasmalBolt"] = 300,
    ["Unique_YakushimaBoss001_Green_2_PhantasmalEye"] = 301,
    ["Unique_YakushimaBoss001_Green_2_PhantasmalSphere"] = 302,
    ["Unique_YakushimaBoss001_Green_2_PhantasmalDeathray"] = 303,
    ["Unique_YakushimaBoss002_2_PhantasmalBolt"] = 304,
    ["Unique_YakushimaBoss002_2_PhantasmalEye"] = 305,
    ["Unique_YakushimaBoss002_2_PhantasmalSphere"] = 306,
    ["Unique_YakushimaBoss002_2_PhantasmalDeathray"] = 307,
    ["Unique_NightBlueHorse_Tossin"] = 308,
    ["Unique_BlueThunderHorse_Tossin"] = 309,
}

local loweredWaza = nil
local function wazaId(id)
    if type(id) == "number" then return id end
    if type(id) ~= "string" then return nil end
    if M.WAZA[id] then return M.WAZA[id] end
    if not loweredWaza then
        loweredWaza = {}
        for k, v in pairs(M.WAZA) do loweredWaza[k:lower()] = v end
    end
    return loweredWaza[id:lower()]
end

---Is `id` one of the game's active skills (an EPalWazaID)? Anything else is treated as a
---passive skill name, which is why this is the routing question and not a validation one.
---@return boolean
function M.isActiveSkill(id) return wazaId(id) ~= nil end

---Every active-skill name this build declares, sorted. 309 of them, so this is for lookups and
---error messages rather than for printing.
---@return string[]
function M.wazaNames()
    local out = {}
    for k in pairs(M.WAZA) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--=============================================================================
-- the parameter object
--=============================================================================

-- The PalUtility CDO — the same object utils/items resolves for the inventory chain.
local util = nil
local function utility()
    if util == nil then
        local ok, u = pcall(StaticFindObject, "/Script/Pal.Default__PalUtility")
        util = (ok and u) or false
    end
    return util or nil
end

---The individual parameter object for `actor`, or nil when it cannot be reached (no game, not a
---PalCharacter, or the accessor is not declared here). nil is UNKNOWN, never "has none".
function M.paramsOf(actor)
    if actor == nil then return nil end
    local u = utility()
    if not u then return nil end
    local ok, obj = signature.call(u, "GetIndividualCharacterParameterByActor",
        { "ObjectProperty" }, actor)
    if not ok or obj == nil then return nil end
    local okv, valid = pcall(function() return obj.IsValid and obj:IsValid() end)
    if not (okv and valid) then return nil end
    return obj
end

-- Flatten a UE4SS TArray into a plain Lua list. UE4SS hands arrays back in three shapes
-- depending on build and element type, so all three are tried. FName elements are ToString'd;
-- enum elements arrive as numbers and are mapped back to their names where one exists, because
-- a caller asked in names and should be answered in names.
local nameOfWaza = nil
local function readList(arr, asWaza)
    if arr == nil then return {} end
    if not nameOfWaza then
        nameOfWaza = {}
        for k, v in pairs(M.WAZA) do nameOfWaza[v] = k end
    end
    local out = {}
    local function push(v)
        if type(v) == "number" then
            out[#out + 1] = (asWaza and nameOfWaza[v]) or v
        elseif type(v) == "string" then
            out[#out + 1] = v
        elseif type(v) == "userdata" then
            local ok, s = pcall(function() return v.ToString and v:ToString() end)
            if ok and type(s) == "string" and #s > 0 and s ~= "None" then out[#out + 1] = s end
        end
    end
    if pcall(function() arr:ForEach(function(_, v) push(v) end) end) and #out > 0 then return out end
    local n; pcall(function() n = #arr end)
    if type(n) == "number" and n > 0 then
        for i = 1, n do local v; pcall(function() v = arr[i] end); push(v) end
        if #out > 0 then return out end
        for i = 1, n do local v; pcall(function() v = arr:Get(i - 1) end); push(v) end
    end
    return out
end

--=============================================================================
-- reading
--=============================================================================

---The skills `actor` currently carries: { active = { <waza names> }, passive = { <FNames> } }.
---An empty list means the read worked and found none; nil for the whole table means the
---parameter object could not be reached at all.
---@return table?
function M.skillsOn(actor)
    local p = M.paramsOf(actor)
    if not p then return nil end
    local _, equip   = signature.call(p, "GetEquipWaza", {})
    local _, passive = signature.call(p, "GetPassiveSkillList", {})
    return { active = readList(equip, true), passive = readList(passive, false) }
end

--=============================================================================
-- writing
--=============================================================================

-- Every write below reports what the READ-BACK saw, never that the call ran. These functions
-- take a live pawn as their argument, and "it did not raise" is exactly the evidence that let
-- :give and :spawn claim success for months while doing nothing.
local function contains(list, want)
    for _, v in ipairs(list or {}) do if v == want then return true end end
    return false
end

---Teach `actor` the skill `id`. An EPalWazaID name (or integer) is added as an ACTIVE skill;
---anything else is added as a PASSIVE skill by name.
---
---Returns true only when the read-back shows the skill is there afterwards.
---@return boolean ok
function M.addSkill(actor, id)
    local p = M.paramsOf(actor)
    if not p then
        log.warn(string.format("addSkill %s: no character parameters on that actor "
            .. "(not a PalCharacter, or no world)", tostring(id)))
        return false
    end

    local waza = wazaId(id)
    if waza then
        local ok, _, level = signature.call(p, "AddEquipWaza", { "ByteProperty" }, waza)
        if not ok then return false end
        local after = M.skillsOn(actor)
        local landed = after and contains(after.active, type(id) == "string" and id or nil)
        log.info(string.format("addSkill %s (EPalWazaID %d) [%s] -> %s",
            tostring(id), waza, level, landed and "equipped" or "not in the read-back"))
        return landed == true
    end

    -- A passive takes TWO FNames: the skill to add, and the one it replaces. Passing an empty
    -- FName for the second is how "add without replacing" is expressed — there is no one-argument
    -- overload, and omitting it would be marshalled as zero, which is a different call.
    local ok, _, level = signature.call(p, "AddPassiveSkill",
        { "NameProperty", "NameProperty" }, FName(tostring(id)), FName(""))
    if not ok then return false end
    local after = M.skillsOn(actor)
    local landed = after and contains(after.passive, tostring(id))
    log.info(string.format("addSkill %s (passive) [%s] -> %s",
        tostring(id), level, landed and "added" or "not in the read-back"))
    return landed == true
end

---Take the skill `id` back off `actor`. Routes the same way addSkill does.
---@return boolean ok
function M.removeSkill(actor, id)
    local p = M.paramsOf(actor)
    if not p then return false end

    local waza = wazaId(id)
    local ok
    if waza then
        ok = signature.call(p, "RemoveEquipWaza", { "ByteProperty" }, waza)
    else
        ok = signature.call(p, "RemovePassiveSkill", { "NameProperty" }, FName(tostring(id)))
    end
    if not ok then return false end

    local after = M.skillsOn(actor)
    if not after then return false end
    local still = contains(after.active, id) or contains(after.passive, tostring(id))
    return not still
end

---Clear every ACTIVE skill from `actor`. Passives are untouched — the game has no equivalent
---bulk call for them, and inventing one out of a loop would hide a partial failure.
---@return boolean ok
function M.clearSkills(actor)
    local p = M.paramsOf(actor)
    if not p then return false end
    local ok = signature.call(p, "ClearEquipWaza", {})
    if not ok then return false end
    local after = M.skillsOn(actor)
    return after ~= nil and #after.active == 0
end

return M
