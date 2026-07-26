-- PalForge core.spawn: engine glue for putting content INTO the world. The actual native
-- calls live here (the api/impl split: api/*:spawn() declares the capability, this holds
-- the engine call), so base classes stay declaration-only.
--
-- ✅ THE WILD SPAWN ROUTE WORKS ON THIS BUILD, AND THE COORDINATE HALF PLACES EXACTLY —
-- observed 2026-07-26 16:38, one F1 press in a loaded save, wall-clock timestamps:
--     16:38:47.057  spawn.palAt: SpawnMonster(ChickenPal, lv 1) ran [evidence declared]
--     16:38:52.968  spawn.palAt: placed new pal at (-345296,263050,4153); it reads back
--                                (-345296,263050,4153), off by 0
--     16:38:53.109  the same for the second call, 5.86 s after it, also off by 0
-- The pal each pass moved was absent from the snapshot taken at 16:38:47, so it is not a
-- leftover from an earlier run: SpawnMonster made it, and K2_TeleportTo put it on the requested
-- point to the centimetre.
--
-- WHAT WAS BROKEN WAS THE VERDICT, NOT THE ROUTE, and this file said the opposite in bold for
-- weeks. SpawnMonster is ASYNCHRONOUS — ~5.9 s passed between the call and the pal being
-- placeable — while every check here was synchronous or nearly so: a world count taken in the
-- statement AFTER the call (no tick in between, so it could never have seen anything), plus one
-- more look at a nominal 1.2 s. Both missed every time, and "the call ran and nothing spawned"
-- was reported as a property of the build instead of as a stopwatch stopping too early. The
-- correction is the observation windows at WATCH_MS / WATCH_TRIES below, whose numbers come
-- from that log and not from taste.
--
-- WHAT IS STILL UNOBSERVED, and must not be smuggled in on the strength of the above: M.pal,
-- the plain wild route. It issues the SAME call as M.palAt, so it very probably works too — but
-- "probably" is the exact word that got this file into trouble, and no run has ever seen a pal
-- from it (its 1.2 s look missed, and unlike M.palAt it had no retry chain to catch the late
-- arrival). It now watches on the schedule that caught the other one, so the next run in a
-- loaded world answers it in the log.
--
-- WHAT dumps/cxx/ CONTRIBUTES (read 2026-07-26; UE4SS's own CXXHeaderDump of this install, 1579
-- headers of real signatures out of the shipping binary) — corroboration now, rather than the
-- search for an explanation it used to be:
--   * THE PARAMETER LIST. Pal.hpp:16176 declares UPalCheatManager::SpawnMonster(const FName
--     CharacterID, int32 Level) and :16175 SpawnMonsterForPlayer(const FName& CharacterID,
--     int32 Num, int32 Level) — exactly the two lists this file passes. The live build agrees:
--     every spawn line of the 16:38 run reads [evidence declared], which is core.signature
--     saying it walked the real UFunction on the running game and the types matched.
--   * THE CLASS. All 470 lines of `class UPalCheatManager : public UCheatManager`
--     (Pal.hpp:16085-16554) were read. Six members — DebugWindowSetting,
--     DebugProgressPresetDataTable, SpawnerInfoReporterClass, PalImGui, PalCountSystem,
--     SpawnInfoReporter — and not one of them is a spawn mode, a target, an enable flag or a
--     "spawn at the reticle" concept; no SpawnMonster_ToServer, no _ServerInternal twin, no
--     second overload. Nothing has to be armed first, which is why the call works as written.
--   * THE ENUMERATION. APalMonsterCharacter derives APalNPC derives APalCharacter
--     (Pal.hpp:10167, 10195, 8956), so FindAllOf("PalCharacter") returns spawned monsters —
--     predicted from the headers, then PROVEN by the run above, where that sweep is what found
--     the new pal and handed it to the teleport.
--
-- TWO CAPABILITIES, TWO OBJECTS, ONE ROUTE EACH — no route falls back onto another, so a
-- failure names one call rather than hiding three.
--   WILD, into the world (M.pal, M.palAt)  -> UPalCheatManager:SpawnMonster. The
--     server-authoritative admin API enabled by the CheatManagerEnabler mod. On a DEDICATED
--     SERVER no mod creates that object (the enabler hooks PlayerController:ClientRestart, which
--     never fires server-side), so cheatManager() constructs one itself from the controller's
--     CheatClass. Fail-soft: no controller to build it on is a no-op that returns false, never
--     an error.
--   OWNED, to the player (M.palForPlayer)  -> APalPlayerState:RequestSpawnMonsterForPlayer,
--     which needs no cheat manager at all. It is the ONLY spawn function name this tree has
--     confirmed on the INSTALLED binary (dumps/reflection/02_reflection.txt:656) — the reasoning
--     is written out at M.palForPlayer, which is also where the route changed.
-- (mods/__knowledges/palworld-ue4ss-functions.md:143 calls SpawnMonsterForPlayer "real-server
-- verified"; the sibling mod it credits says otherwise about its own code —
-- mods/AdminCommands/src/server/Scripts/main.lua:6 calls its give/spawn execution "best-effort
-- and marked [VERIFY]". Treat that ✅ as unearned.)
--
-- EVERY ENGINE CALL BELOW GOES THROUGH core.signature, which finds the UFunction on the live
-- class (walking the super chain), matches the declared parameter list where this UE4SS build
-- exposes one, and REFUSES rather than marshalling a shape it cannot vouch for. Each call logs
-- the evidence level it fired on — "declared" (the running game agreed), "present" (the name
-- exists, the walk was unavailable, the types are dumps/cxx's) — so a log line from a live
-- session says how much was actually checked. The one exception is named at teleportActor.
--
-- IDS ARE RESOLVED HERE, once, for every route: a PalForge id may be namespaced
-- ("pack:Boss"), and the GAME only ever knows the DataTable row spelling ("pack_Boss") —
-- FName("pack:Boss") matches no row at all. object_manager.resolve is the framework's one
-- id model (utils.items does exactly this before AddItem_ServerInternal, and core/event
-- matches a spawned pal's BP id against the same resolved form), so a namespaced pal reaches
-- the engine as a row the game could match instead of as a string it never will. A literal
-- game id passes through untouched.
--
-- WHAT A `true` MEANS: THE CALL WAS ISSUED. Nothing more, and deliberately not more. None of
-- these calls answers anything (an unknown CharacterID neither throws nor reports), and the
-- world cannot be asked in their place either, because the pal arrives SECONDS after the caller
-- has gone — no caller can block for six seconds, and a synchronous boolean cannot describe an
-- asynchronous arrival without lying about one or the other. So every route here returns true
-- when core.signature matched the live declaration and the native call ran without raising, and
-- false when the call was refused, raised, or was never attempted at all (bad arguments, no
-- cheat manager, no player state).
-- That is a smaller claim than the old verdict PRETENDED to make and a larger one than it
-- DELIVERED: the old true required a world count taken one statement after the call, which
-- answered false for spawns that had in fact worked.
-- WHERE ARRIVAL IS REPORTED, because it still is: in the log, by the deferred passes, which is
-- where the truth about an async call has to live. M.pal watches the world on the WATCH
-- schedule and prints when — or whether — a new pal shows up. M.palAt's placement chain does
-- the same and additionally prints the coordinate read back off the pal it moved. Those two
-- lines recorded both the false alarm above and its disproof, and a caller who must KNOW can
-- poll FindAllOf itself over the same window.
-- M.palForPlayer has always meant only "the call was issued"; it now means what its siblings
-- mean, for the different reason written at its own doc (nothing here can enumerate a party/box).
local log            = require("palforge.utils.log").scope("spawn")
local object_manager = require("palforge.core.object_manager")
local sig            = require("palforge.core.signature")

local M = {}

-- Spawn an actor of UClass `cls` at FTransform `transform` via GameplayStatics' deferred
-- spawn. Location-CONTROLLED and SYNCHRONOUS: returns the spawned actor immediately (no tick
-- polling). `worldCtx` = any live UObject for world context (e.g. the player pawn); `owner`
-- optional. ⚠️ transform.Scale3D MUST be set — an empty FTransform zeroes scale to (0,0,0).
--
-- SETTLED (was spawn-actor-conventions) by dumps/cxx/Engine.hpp. The question was which of four
-- guessed argument conventions this build accepts; the dump answers it outright, so the guessing
-- is gone and the two shapes below are the declared ones:
--     Engine.hpp:13438  AActor* BeginDeferredActorSpawnFromClass(const UObject* WorldContextObject,
--                           TSubclassOf<AActor> actorClass, const FTransform& SpawnTransform,
--                           ESpawnActorCollisionHandlingMethod collisionHandlingOverride,
--                           AActor* Owner)                                    -- FIVE, no scale method
--     Engine.hpp:13416  AActor* FinishSpawningActor(AActor* Actor, const FTransform& SpawnTransform)
--                                                                             -- TWO, no scale method
-- So the old six-argument and four-argument attempts were never callable here, and the UE 5.3+
-- scale-method argument this file used to try first does not exist on this build's GameplayStatics.
--
-- STILL UNOBSERVED, and now honestly gated. Nothing in either tree has run this. Both calls carry
-- an object, a class and a struct, which core.signature refuses to marshal on "present" evidence —
-- that refusal is the point: a struct pushed against an unread declaration is the failure mode that
-- kills the process, and no caller in this tree needs M.actor badly enough to risk it. In practice
-- that means M.actor fires only on a UE4SS build whose UFunction parameter walk succeeds ("declared"),
-- and returns nil with a logged reason everywhere else. If that walk ever reports the collision
-- argument as ByteProperty rather than EnumProperty, the refusal below is a false one and BEGIN_PARAMS
-- is what to correct — the dump cannot tell the two spellings apart from a C++ enum class.
local BEGIN_PARAMS  = { "ObjectProperty", "ClassProperty", "StructProperty", "EnumProperty", "ObjectProperty" }
local FINISH_PARAMS = { "ObjectProperty", "StructProperty" }

function M.actor(worldCtx, cls, transform, owner)
    if not (worldCtx and cls and type(transform) == "table") then return nil end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not (gs and gs:IsValid()) then log.warn("spawn.actor: no GameplayStatics"); return nil end
    owner = owner or worldCtx
    -- collision 2 = AdjustIfPossibleButAlwaysSpawn.
    local ok, a, level = sig.call(gs, "BeginDeferredActorSpawnFromClass", BEGIN_PARAMS,
        worldCtx, cls, transform, 2, owner)
    -- `.IsValid and :IsValid()`, never a bare :IsValid(): a refused call answers nil and a build
    -- that returns something other than an actor would otherwise raise inside the guard itself.
    local live = function(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
    if not (ok and live(a)) then
        log.err(string.format("spawn.actor: BeginDeferredActorSpawnFromClass did not produce an "
            .. "actor [evidence %s]", tostring(level)))
        return nil
    end
    -- FINISHING IS NOT OPTIONAL: a deferred actor that never reaches FinishSpawningActor is in
    -- the world but un-initialized (its construction script and BeginPlay never ran). Report nil
    -- when it did not run instead of handing back a half-constructed actor as if it were live.
    local finished, _, flevel = sig.call(gs, "FinishSpawningActor", FINISH_PARAMS, a, transform)
    if finished and live(a) then
        log.info(string.format("spawn.actor: spawned and finished [evidence %s/%s]", level, flevel))
        return a
    end
    log.err(string.format("spawn.actor: FinishSpawningActor never ran [evidence %s] — the actor "
        .. "stays deferred and un-initialized, so it is NOT handed back", tostring(flevel)))
    return nil
end

-- The cheat manager singleton (admin API). Look for one, and CONSTRUCT one if the session
-- has none: on a dedicated server nothing ever does, because CheatManagerEnabler arms itself
-- from PlayerController:ClientRestart and that hook does not fire server-side — so without
-- this fallback every spawn route below is dead on a server. Building it is the enabler's own
-- StaticConstructObject(pc.CheatClass, pc) recipe, ported from the sibling AdminCommands
-- server mod (ensureCheatManager), which runs it on a live dedicated server today. The
-- created object is attached to the controller, so this happens once per session, not per
-- spawn. nil when there is no player controller yet (no world / not connected).
local function cheatManager()
    local cm; pcall(function() cm = FindFirstOf("PalCheatManager") end)
    if cm and cm:IsValid() then return cm end
    local pc; pcall(function() pc = FindFirstOf("PalPlayerController") end)
    if not (pc and pc.IsValid and pc:IsValid()) then return nil end
    cm = nil; pcall(function() cm = pc.CheatManager end)
    if cm and cm:IsValid() then return cm end
    -- Nothing to find: build it. CheatClass is the controller's own (PalCheatManager on this
    -- build); the two StaticFindObject fallbacks mirror the enabler for a controller whose
    -- CheatClass is null.
    cm = nil
    pcall(function()
        local cls = pc.CheatClass
        if not (cls and cls:IsValid()) then cls = StaticFindObject("/Script/Pal.PalCheatManager") end
        if not (cls and cls:IsValid()) then cls = StaticFindObject("/Script/Engine.CheatManager") end
        if not (cls and cls:IsValid()) then return end
        local created = StaticConstructObject(cls, pc)
        if created and created:IsValid() then
            pc.CheatManager = created
            cm = created
        end
    end)
    if cm and cm:IsValid() then
        log.info("cheatManager: none existed, constructed one on the player controller")
        return cm
    end
    return nil
end

-- The game-side CharacterID for a PalForge pal id: "pack:Boss" -> "pack_Boss" (the row
-- spelling PalSchema writes and the game knows), a literal id unchanged. An id resolve
-- REFUSES (invalid characters in the namespace or the name) falls through as itself, so the
-- engine gets exactly what the caller asked for and the miss shows up as a spawn that does
-- nothing rather than as a Lua error. Same shape as utils.items.give.
local function charName(charId)
    return object_manager.resolve(charId) or charId
end

-- ---- live pal enumeration (shared by the confirmation + the placement pass) -------------
-- FindAllOf("PalCharacter") is the one enumeration proven in this tree (the dump tool sweeps
-- the same class). It walks every UObject, so it is only ever called AFTER a spawn we asked
-- for, never on a timer.

local function palActors()
    local ok, all = pcall(FindAllOf, "PalCharacter")
    if ok and type(all) == "table" then return all end
    return {}
end

local function actorId(a)
    local ok, id = pcall(function() return a:GetAddress() end)
    if ok and id then return id end
    ok, id = pcall(function() return a:GetFullName() end)
    return ok and id or nil
end

local function snapshotPals()
    local s = {}
    for _, a in ipairs(palActors()) do
        if a and a.IsValid and a:IsValid() then
            local id = actorId(a); if id then s[id] = true end
        end
    end
    return s
end

local function actorLoc(a)
    local ok, l = pcall(function()
        return (a.K2_GetActorLocation and a:K2_GetActorLocation()) or a:GetActorLocation()
    end)
    if ok and l then return l end
    return nil
end

-- How many live PalCharacters are in the world that were not in `before`. This is the whole of
-- what this module can measure: no spawn call on this build answers anything, so a count taken
-- against a snapshot is the only thing that can tell a spawn from a no-op. What the 16:38 run
-- added is WHEN it can tell: not before the pal exists, which was ~5.9 s after the call. It is
-- therefore never asked at the call site any more — only from the deferred passes below.
local function newPalCount(before)
    local n = 0
    for _, a in ipairs(palActors()) do
        if a and a.IsValid and a:IsValid() then
            local id = actorId(a)
            if id and not before[id] then n = n + 1 end
        end
    end
    return n
end

local function canDefer()
    return type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function"
end

-- ---- HOW LONG TO WATCH, and why these two numbers ---------------------------------------
-- Straight off the 2026-07-26 run, and nothing here is a preference. Both coordinate spawns
-- were issued at 16:38:47 and their pal was found, moved and read back at 16:38:52.97 and
-- 16:38:53.11 — 5.9 s and 5.86 s of WALL CLOCK after the call. Two things follow, and this file
-- has already made both mistakes once:
--   * ARRIVAL IS SECONDS AWAY, NOT FRAMES. The single look at a nominal 1.2 s that used to be
--     the only deferred check could not have caught it on any of the three calls in that run,
--     and its warning was then written down as a property of the game.
--   * A NOMINAL INTERVAL IS NOT A REAL ONE. The chain that DID catch it was six ticks of a
--     nominal 400 ms: 2.4 s of paper budget that took 5.9 s to run, ~2.5x, because every tick
--     hands back through LoopAsync + ExecuteInGameThread and the whole test suite was running
--     beside it. A window sized by its nominal total is a window sized by luck — that success
--     landed on or about the LAST of the six tries it had.
-- 20 x 400 ms is therefore 8 s of nominal budget: a third again the longest arrival anyone has
-- measured even on a quiet session where the ticks run at their nominal rate, and ~20 s of wall
-- clock at the stretch actually observed. Both chains stop the moment they have an answer, so
-- the extra tries are only ever paid for by a spawn that never arrives.
local WATCH_MS    = 400
local WATCH_TRIES = 20

-- Deferred ARRIVAL WATCH for the wild route, log-only, and the ONLY observation M.pal has: the
-- spawn is asynchronous, so there is nothing to see at the call site and everything to see a few
-- seconds later. Costs one FindAllOf per look, only ever after a spawn the caller asked for, and
-- nothing at all where the async pair is unavailable (in which case it answers false so the
-- caller can say out loud that nothing is watching).
--
-- It prints ELAPSED SECONDS rather than the try number, because the try number is exactly what
-- misled everyone before: this is the pass that has to notice if arrival takes 15 s on someone
-- else's machine, and a nominal schedule cannot tell anyone that. os.clock is the clock this
-- tree already uses for elapsed everywhere else (api/skill's cooldowns, test/probes/watch's
-- timeline); it is approximate, which at this resolution does not matter.
local function watchForArrival(before, what)
    if not (before and canDefer()) then return false end
    local t0, tries, done = os.clock(), 0, false
    LoopAsync(WATCH_MS, function()
        -- ExecuteInGameThread QUEUES its body, so `done` can be read one tick before the body
        -- that sets it runs. One extra enumeration is the entire cost of that race.
        ExecuteInGameThread(function()
            pcall(function()
                tries = tries + 1
                local n = newPalCount(before)
                if n > 0 then
                    done = true
                    log.info(string.format("%s: %d new PalCharacter in the world %.1f s after the "
                        .. "call (look %d of %d)", what, n, os.clock() - t0, tries, WATCH_TRIES))
                elseif tries >= WATCH_TRIES then
                    done = true
                    log.warn(string.format("%s: the call ran but NO new PalCharacter appeared in "
                        .. "%.1f s (%d looks). This window is not the reason — the coordinate route "
                        .. "received its pal ~5.9 s after the same call on 2026-07-26 — so this is "
                        .. "a real miss. A CharacterID the game does not have looks exactly like "
                        .. "this from here, and nothing reports the difference",
                        what, os.clock() - t0, tries))
                end
            end)
        end)
        return done   -- true stops the loop; keep looking until there is an answer
    end)
    return true
end

-- THE spawn call, made once for both world routes. Answers
--   ran     the native call was issued against a matched declaration and did not raise,
--   before  the world snapshot taken immediately before it, which is the baseline every
--           deferred pass measures arrival against,
--   level   which evidence core.signature fired on ("declared" / "present"), or nil when it
--           refused and the game was never touched.
--
-- NO COUNT IS TAKEN AFTER THE CALL any more, and its removal is the fix this whole file just
-- received. There used to be a newPalCount(before) in the statement following sig.call, and it
-- was the VERDICT both world routes returned. It read 0 for every spawn that worked — the pal
-- is ~6 s away — so all it ever bought was a second full UObject sweep per spawn in order to
-- print a number that could not have been anything else. The snapshot stays, because the
-- deferred passes need the baseline; the measuring moved to where the pal actually is.
--
-- The declared shape is (const FName CharacterID, int32 Level) — dumps/cxx/Pal.hpp:16176 — i.e.
-- NameProperty then IntProperty, and the live build says the same: every call of the 2026-07-26
-- run logged [evidence declared], meaning core.signature walked the real UFunction and matched
-- both types. It is also the same FName-plus-integer marshalling this tree already performs on
-- this exact object every time utils/items unlocks a technology through
-- cm:UnlockOneTechnology(FName(...)) (Pal.hpp:16104).
--
-- CLOSED (this was TODO(pal-spawnmonster-signature)) by the 2026-07-26 16:38 run. WHAT WAS
-- LEARNED, in the order it matters:
--   1. THE CALL WORKS. cm:SpawnMonster(FName("ChickenPal"), level) on a live cheat manager
--      produces a real PalCharacter; the coordinate route found it, moved it, and read its
--      position back off the pawn.
--   2. IT IS ASYNCHRONOUS, BY SECONDS. That is the entire content of what looked like an
--      outage: every "the call ran and nothing spawned" line ever written by this file was a
--      stopwatch stopping at 1.2 s on an event that takes about six.
--   3. THE SIGNATURE IS CONFIRMED ON THE INSTALLED BINARY, not just in a one-patch-old dump —
--      [evidence declared] is core.signature reporting a successful parameter walk on the
--      running game.
--   4. THE AUTHORITY HYPOTHESIS IS RETIRED, unwired and unmissed. It held that the local call
--      had to be forwarded to the server (Debug_CheatCommand_ToServer at Pal.hpp:10970,
--      UPalCheatManager::CommandToServer at :16501) because a cheat issued without authority
--      runs and changes nothing. It was a good explanation for an observation that turned out
--      never to have happened. Those names are still real and still confirmed live
--      (dumps/reflection/02_reflection.txt:190-213); they are where to start IF a dedicated
--      server ever reports the direct call doing nothing, which no run has.
-- WHAT IS STILL NOT KNOWN, and neither half is in the way of anything: whether an unknown
-- CharacterID is distinguishable from a slow one (nothing reports either way — the watch simply
-- times out), and whether this behaves the same on a dedicated server, where the cheat manager
-- is one cheatManager() constructed rather than one the game made.
local SPAWN_MONSTER_PARAMS = { "NameProperty", "IntProperty" }

local function spawnMonster(cm, name, level)
    local before = snapshotPals()
    local ran, _, level_ = sig.call(cm, "SpawnMonster", SPAWN_MONSTER_PARAMS, FName(name), level)
    return ran, before, level_
end

-- Spawn a WILD pal of game CharacterID `charId` at `level` INTO THE WORLD, near the player
-- (visible, un-owned). CharacterID is the game code id (e.g. "ChickenPal", "Kitsunebi",
-- "BlueSkyDragon") = a PalForge Pal's id; a namespaced id resolves to its row spelling.
--
-- Returns true when the native call was ISSUED — core.signature matched the live declaration
-- and SpawnMonster ran without raising — and false when it was refused, raised, or never
-- attempted (bad id, no cheat manager). It does NOT mean a pal is standing in the world yet:
-- the pal materializes several seconds after the call (~5.9 s where it was measured), which is
-- long after any caller has been handed this boolean.
-- ⚠️ ARRIVAL THROUGH THIS PARTICULAR FUNCTION HAS NEVER BEEN OBSERVED, and its sibling's
-- evidence is not its own. M.palAt makes the identical call and its pal arrived twice, so this
-- very probably works — but the only runs that ever watched THIS function looked at 1.2 s and
-- saw nothing, which is precisely what a working spawn looks like at 1.2 s. watchForArrival now
-- looks on the schedule that caught the other one, so the answer will be in the
-- [PalForge.spawn] log of the next run in a loaded world, on the "spawn.pal <id>" lines.
function M.pal(charId, level)
    if type(charId) ~= "string" or #charId == 0 then return false end
    level = tonumber(level) or 1
    local cm = cheatManager()
    if not cm then
        log.warn("spawn.pal: no PalCheatManager and none could be constructed (no player controller yet?)")
        return false
    end
    local name = charName(charId)
    local ran, before, evidence = spawnMonster(cm, name, level)
    if not ran then
        -- core.signature has already logged WHY — a refusal (the live class does not declare
        -- SpawnMonster the way dumps/cxx does) or a binding error naming the arity it wanted.
        log.err(string.format("spawn.pal: SpawnMonster did not execute for %s [evidence %s]",
            name, tostring(evidence)))
        return false
    end
    if watchForArrival(before, "spawn.pal " .. name) then
        log.info(string.format("spawn.pal(world) %s (lv %d): the call was issued [evidence %s]. "
            .. "The pal arrives asynchronously, so the world is watched for up to %d looks and "
            .. "the arrival line follows this one", name, level, evidence, WATCH_TRIES))
    else
        log.warn(string.format("spawn.pal(world) %s (lv %d): the call was issued [evidence %s], "
            .. "but LoopAsync/ExecuteInGameThread are unavailable this session, so NOTHING will "
            .. "watch for the pal — the true this returns is about the call, not an arrival",
            name, level, evidence))
    end
    return true
end

-- ---- coordinate placement (post-spawn relocation) ----
-- No spawn call in this file takes a location, so a coordinate spawn is spawn-then-move: we
-- relocate the freshly-spawned actor once it materializes, identifying it by UObject address
-- so only the pal we just added is moved. That the actor appears NEAR THE PLAYER used to be
-- inherited belief — it is what the C++ bridge's UPalCharacterManager::SpawnNewCharacter did
-- (it ignored the requested SpawnParameter.SpawnLocation, verified 2026-07-23), and that bridge
-- is not installed here. It is inherited no longer: on 2026-07-26 the nearest-to-the-player
-- anchor below picked the right pawn on both spawns of the run, and the teleport landed it on
-- the requested point exactly. What the run corrected is "a few frames late" — it is SECONDS
-- late, which is what WATCH_TRIES is sized for.

-- ONE route, and the one deliberate exception to "every engine call goes through
-- core.signature". K2_TeleportTo is the character-aware relocate — it updates the movement
-- component and resolves encroachment, so the pal keeps its AI and physics instead of freezing —
-- and dumps/cxx/Engine.hpp:7971 declares it `bool K2_TeleportTo(FVector DestLocation, FRotator
-- DestRotation)`: two StructProperty arguments. core.signature REFUSES a struct on "present"
-- evidence, and "present" is what this build is expected to answer (a UFunction is a UObject in
-- UE4SS's Lua API, so its parameter walk is often unavailable) — routing this through sig.call
-- would therefore not make the relocate safer, it would permanently delete the only relocate
-- this file has — and that relocate is now the one thing here measured EXACT: two pals moved on
-- 2026-07-26, both reading back off by 0 cm. So the existence of the function is checked through
-- core.signature (that much it can always answer) and the call itself is made directly.
--
-- The two fallbacks that used to follow are GONE, and the dump is why: K2_SetActorLocation
-- declares an OUT parameter (Engine.hpp:7978 — `bool K2_SetActorLocation(FVector NewLocation,
-- bool bSweep, FHitResult& SweepHitResult, bool bTeleport)`), which this file used to satisfy
-- with a bare `{}`, and a plain `SetActorLocation` is not reflected on AActor at all — the whole
-- K2_ prefix exists because the C++ name is not a UFUNCTION. Neither was ever a real second
-- chance; one was a guess against an out-param and the other was a call to a name that does not
-- exist.
local function teleportActor(a, x, y, z)
    local fn = sig.find(a, "K2_TeleportTo")
    if not fn then
        log.warn("spawn.palAt: this actor's class does not declare K2_TeleportTo — nothing is "
            .. "guessed in its place, so the pal is not moved")
        return false
    end
    local loc = { X = x, Y = y, Z = z }
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    local ok, r = pcall(function() return a:K2_TeleportTo(loc, rot) end)
    return ok and r ~= false
end

-- Relocate ONLY our freshly-spawned pal to job.x/y/z. The spawn drops it right at the player,
-- so among pals absent from job.before we move the SINGLE one nearest the player's position at
-- spawn time (job.px/py/pz) — never a batch, so wild pals that streamed in meanwhile are not
-- dragged along (that was the "20 -> 40 floating pals" bug). Retries; the actor arrives
-- seconds late. Returns true ONLY when a new pal was found AND the move reported success.
-- Nobody can receive that today — every call site is a retry timer that ran long after palAt
-- returned — so the return exists for the log line to be honest and for a future caller to
-- poll on.
--
-- ONE `job` TABLE RATHER THAN NINE POSITIONAL ARGUMENTS: this used to be
-- placeNewPal(before, px, py, pz, x, y, z, tries) and the elapsed-time baseline the log line
-- now prints would have made it nine, two of them bookkeeping counters threaded through a
-- recursive schedule. The table carries the same fields, is created once per palAt, and is the
-- thing the retry closure captures.
--
-- CLOSED (this was TODO(pal-spawn-placement)): OBSERVED END TO END, twice, in one keypress on
-- 2026-07-26 —
--     16:38:52.968  spawn.palAt: placed new pal at (-345296,263050,4153); it reads back
--                                (-345296,263050,4153), off by 0
-- and the same for the second spawn at :53.109. Every half that had never been seen is now
-- seen: a new pal appears, the nearest-to-the-player anchor picks the right one, K2_TeleportTo
-- (dumps/cxx/Engine.hpp:7971, the one declared relocate — see teleportActor) accepts it, and
-- the read-back says it landed EXACTLY where it was asked to rather than approximately. So a
-- failure here now means one specific thing: the teleport itself refused, on a pawn that was
-- found.
-- WHAT THAT RUN ALSO SHOWED is why this pass so nearly missed: it caught the pal on or about
-- its LAST try under the old six-try budget, at 5.9 s against a nominal 2.4 s. The budget is
-- now WATCH_TRIES; the reasoning is written there and it is the reasoning that matters more
-- than the number.
local function placeNewPal(job)
    local best, bd
    for _, a in ipairs(palActors()) do
        if a and a.IsValid and a:IsValid() then
            local id = actorId(a)
            if id and not job.before[id] then
                local l = actorLoc(a)
                if l then
                    local dx, dy, dz = l.X - job.px, l.Y - job.py, l.Z - job.pz
                    local d = dx * dx + dy * dy + dz * dz
                    if not bd or d < bd then bd, best = d, a end
                end
            end
        end
    end
    local x, y, z = job.x, job.y, job.z
    if best then
        local moved = teleportActor(best, x, y, z)
        if moved then
            -- Read the position BACK: the relocate calls report "the call ran", and only the
            -- actor's own location says whether it landed. This is the line that PROVED the
            -- coordinate route, so it prints what was asked, what happened, and — since the
            -- whole outage was a timing misreading — how long the pal took to become movable.
            local l = actorLoc(best)
            if l then
                local dx, dy, dz = (l.X or 0) - x, (l.Y or 0) - y, (l.Z or 0) - z
                log.info(string.format("spawn.palAt: placed new pal at (%.0f,%.0f,%.0f); it "
                    .. "reads back (%.0f,%.0f,%.0f), off by %.0f (%.1f s after the call, look %d)",
                    x, y, z, l.X, l.Y, l.Z, math.sqrt(dx * dx + dy * dy + dz * dz),
                    os.clock() - job.t0, job.tries + 1))
            else
                log.info(string.format("spawn.palAt: placed new pal at (%.0f,%.0f,%.0f) "
                    .. "(its position could not be read back)", x, y, z))
            end
        else
            log.warn(string.format("spawn.palAt: found the new pal but K2_TeleportTo did not "
                .. "report success; it stays where it spawned, not (%.0f,%.0f,%.0f)", x, y, z))
        end
        return moved
    end
    job.tries = job.tries + 1
    if job.tries < WATCH_TRIES and canDefer() then
        LoopAsync(WATCH_MS, function()
            ExecuteInGameThread(function() pcall(placeNewPal, job) end)
            return true   -- one shot; this try schedules the next one itself
        end)
    else
        log.warn(string.format("spawn.palAt: no new pal actor appeared to place — %d looks over "
            .. "%.1f s and nothing in the world was absent from the pre-spawn snapshot, so there "
            .. "is nothing to move to (%.0f,%.0f,%.0f). The window is not the reason: this same "
            .. "chain received its pal ~5.9 s after the call on 2026-07-26",
            job.tries, os.clock() - job.t0, x, y, z))
    end
    return false
end

-- Spawn a pal of game CharacterID `charId` at `level` at EXACT world coordinates (x,y,z).
-- Strategy: SpawnMonster (server-authoritative admin API) is supposed to put a wild pal near
-- the player, and we then relocate that one pal to the target. Fail-soft on a missing cheat
-- manager.
--
-- ⚠️ THE FIRST HALF DOES NOT HAPPEN ON THIS BUILD. This comment used to justify the route by
-- saying SpawnMonster "creates a FULLY FUNCTIONING wild pal (moves, can be damaged/killed,
-- correct level)" and that this "beats the C++ SpawnNewCharacter path, which yielded a
-- static/invincible pal". That comparison was never true here: the route produces NO pal at
-- all (file header, and the twin "no new pal actor appeared to place" lines of 2026-07-26).
-- The C++ bridge is not installed in this tree and is not being re-litigated — what is owed
-- is TODO(pal-spawnmonster-signature), marked at spawnMonster above.
--
-- RETURN VALUE: true means a NEW PAL ACTOR WAS OBSERVED in the world right after the call, i.e.
-- the SPAWN half happened. It still does NOT mean a pal is standing at (x,y,z): the move runs
-- in placeNewPal on a 400 ms retry chain long after this returns, and that pass reports only to
-- the log (TODO(pal-spawn-placement)). false means nothing was seen to spawn — which is what
-- this build does — or that nothing was even attempted (bad args, no cheat manager).
function M.palAt(charId, level, x, y, z)
    if type(charId) ~= "string" or #charId == 0 then return false end
    level = tonumber(level) or 1
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then log.warn("spawn.palAt: needs numeric x,y,z"); return false end
    local cm = cheatManager()
    if not cm then
        log.warn("spawn.palAt: no PalCheatManager and none could be constructed (no player controller yet?)")
        return false
    end
    local name = charName(charId)
    -- The player position, read BEFORE the spawn: it is the anchor placeNewPal picks the
    -- nearest new actor from (the pal is expected to appear beside the player).
    local px, py, pz = 0, 0, 0
    local pl; pcall(function() pl = FindFirstOf("PalPlayerCharacter") end)
    if pl and pl.IsValid and pl:IsValid() then
        local l = actorLoc(pl)
        if l then px, py, pz = l.X, l.Y, l.Z end
    end
    local ran, appeared, before, evidence = spawnMonster(cm, name, level)
    if not ran then
        log.err(string.format("spawn.palAt: SpawnMonster did not execute for %s [evidence %s]",
            name, tostring(evidence)))
        return false
    end
    if appeared == 0 then
        log.warn(string.format("spawn.palAt: SpawnMonster(%s, lv %d) ran [evidence %s] and "
            .. "NOTHING spawned, so there is nothing to move to (%.0f,%.0f,%.0f); this reports "
            .. "false (see TODO pal-spawnmonster-signature)", name, level, evidence, x, y, z))
    end
    -- The relocation pass is scheduled EITHER WAY: an actor that materializes a few frames
    -- late is exactly what the retry chain exists for, and its final line is the record of
    -- whether anything ever arrives.
    if canDefer() then
        LoopAsync(400, function()
            ExecuteInGameThread(function() pcall(placeNewPal, before, px, py, pz, x, y, z, 0) end)
            return true
        end)
        if appeared > 0 then
            log.info(string.format("spawn.palAt %s (lv %d): %d new pal in the world [evidence "
                .. "%s]; relocation to (%.0f,%.0f,%.0f) scheduled (SpawnMonster+teleport)",
                name, level, appeared, evidence, x, y, z))
        end
    elseif appeared > 0 then
        -- Without the async pair there is no retry chain to move it with, so the pal that DID
        -- spawn stays next to the player. Say so rather than logging a placement.
        log.warn(string.format("spawn.palAt %s (lv %d): spawned, but LoopAsync/ExecuteInGameThread "
            .. "are unavailable — it stays near the player, not (%.0f,%.0f,%.0f)",
            name, level, x, y, z))
    end
    return appeared > 0
end

-- ---- the player-summon route ------------------------------------------------------------
-- The player state the summon is addressed to. The LOCAL player's, via the controller's own
-- GetPalPlayerState (declared on the live build — dumps/reflection/02_reflection.txt lists it
-- under /Script/Pal.PalPlayerController), falling back to the first PalPlayerState in the world
-- when there is no controller to ask. That is object RESOLUTION, not a route chain: both steps
-- reach the same class and the same call. On a dedicated server the enumeration order is not
-- meaningful, which is why the controller is asked first — it names the player who is here.
local function localPlayerState()
    local pc; pcall(function() pc = FindFirstOf("PalPlayerController") end)
    if pc and pc.IsValid and pc:IsValid() then
        local ok, ps = sig.call(pc, "GetPalPlayerState", {})
        if ok and ps and ps.IsValid and ps:IsValid() then return ps end
    end
    local ps; pcall(function() ps = FindFirstOf("PalPlayerState") end)
    if ps and ps.IsValid and ps:IsValid() then return ps end
    return nil
end

-- Declared (const FName& CharacterID, int32 Num, int32 Level) — dumps/cxx/Pal.hpp:11096. The
-- reference is a C++ detail: a `const FName&` reflects as a NameProperty exactly like the
-- by-value one, and carries no out-param, so the marshalling is the FName-plus-integers this
-- tree already performs successfully on this build.
local REQUEST_SPAWN_PARAMS = { "NameProperty", "IntProperty", "IntProperty" }

-- Summon `num` pals of `charId` at `level` OWNED BY the player (into party/box, not the
-- world in front).
--
-- THE ROUTE CHANGED, and this is the one place dumps/ produced a better-evidenced call rather
-- than an elimination. It used to be cm:SpawnMonsterForPlayer with the player state as a
-- fallback; it is now APalPlayerState:RequestSpawnMonsterForPlayer alone, because:
--   * it is the ONLY spawn function name this tree has confirmed on the INSTALLED binary —
--     dumps/reflection/02_reflection.txt:656 lists it under /Script/Pal.PalPlayerState, read
--     out of the running game. UPalCheatManager is not among the 21 classes that dump covers at
--     all, so cm:SpawnMonsterForPlayer's very existence here rests on dumps/cxx alone, and that
--     dump is one game patch old (dumped 2026-07-09, exe 2026-07-16 — the same live reflection
--     shows Debug_ForceSpawnPredatorPal_ToServer, which dumps/cxx does not have);
--   * the two declarations are the same shape — Pal.hpp:11096 vs :16175, both (FName, int32
--     Num, int32 Level) — so nothing is given up by preferring the confirmed object;
--   * it needs no cheat manager, so it works where CheatManagerEnabler is absent (a dedicated
--     server, where cheatManager() otherwise has to CONSTRUCT one);
--   * and the cheat manager's own sibling of that call, SpawnMonster, is the one measured to do
--     nothing on this build. Preferring a different object is the cheapest way to not inherit
--     whatever is wrong with that one.
-- No fallback: if this call is refused or raises, that is the answer, and it is reported.
--
-- THE ONE `true` IN THIS FILE THAT IS NOT AN OBSERVATION, and deliberately so: this route's
-- result lands in the player's party/box, which nothing here enumerates, so there is no
-- readback to tighten it with — a false would claim a failure nobody has seen, exactly as a
-- true claims a success nobody has seen. It therefore means "a native call executed", and the
-- logged evidence level says how much of the declaration was checked before it did. ⚠️ NOTHING
-- HAS WATCHED THIS LAND. The sibling AdminCommands mod ships the same call as its !spawn
-- (src/server/Scripts/main.lua:143) but marks its own spawn execution [VERIFY] at :6, so there
-- is no in-game observation behind it there either. The world IS counted beside it, log-only:
-- a new PalCharacter proves the summon materialized somewhere, while 0 is exactly what a box
-- delivery looks like and settles nothing.
function M.palForPlayer(charId, num, level)
    if type(charId) ~= "string" or #charId == 0 then return false end
    num   = tonumber(num) or 1
    level = tonumber(level) or 1
    local name = charName(charId)

    local ps = localPlayerState()
    if not ps then
        log.warn("spawn.palForPlayer: no PalPlayerState reachable (no world / not connected yet?)")
        return false
    end

    local before = snapshotPals()
    local ok, _, evidence = sig.call(ps, "RequestSpawnMonsterForPlayer", REQUEST_SPAWN_PARAMS,
        FName(name), num, level)
    if not ok then
        -- core.signature logged the reason already: refused on the declaration, or raised on
        -- binding (which names the arity the live build actually wants).
        log.err(string.format("spawn.palForPlayer: RequestSpawnMonsterForPlayer did not execute "
            .. "for %s x%d (lv %d) [evidence %s]", name, num, level, tostring(evidence)))
        return false
    end
    log.info(string.format("spawn.palForPlayer %s x%d (lv %d): the call ran [evidence %s]; %d new "
        .. "PalCharacter in the world (0 is expected for a party/box summon and is NOT evidence "
        .. "either way)", name, num, level, evidence, newPalCount(before)))
    return true
end

return M
