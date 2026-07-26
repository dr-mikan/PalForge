-- PalForge core.spawn: engine glue for putting content INTO the world. The actual native
-- calls live here (the api/impl split: api/*:spawn() declares the capability, this holds
-- the engine call), so base classes stay declaration-only.
--
-- ⚠️ NO PAL SPAWN ROUTE HAS BEEN OBSERVED TO WORK ON THIS BUILD — measured, not suspected. In
-- a loaded save with a live world on 2026-07-26, with a cheat manager that already existed
-- (CheatManagerEnabler logged "CheatManager already exist") and on the game thread (every
-- keybind and hook enters through ExecuteInGameThread), cm:SpawnMonster(FName("ChickenPal"),
-- level) completed WITHOUT RAISING and no new PalCharacter existed 1.2 s later; the palAt
-- placement pass ran twice and found no new pal actor to place. So the call reaches the
-- engine and does nothing. Every route here still reports what it OBSERVED, and a route that
-- observed nothing returns false.
--
-- WHAT dumps/cxx/ SETTLED (read 2026-07-26; UE4SS's own CXXHeaderDump of this install, 1579
-- headers of real signatures out of the shipping binary). Three candidate explanations for
-- that no-op are now DEAD, and the surviving one is named at TODO(pal-spawnmonster-signature):
--   * WRONG ARITY — dead. Pal.hpp:16176 declares UPalCheatManager::SpawnMonster(const FName
--     CharacterID, int32 Level) and :16175 SpawnMonsterForPlayer(const FName& CharacterID,
--     int32 Num, int32 Level). Those are exactly the two lists this file passes. The
--     AddItem_ServerInternal shape (four passed, six declared) does NOT repeat here.
--   * A CLASS-WIDE GATE — dead. All 470 lines of `class UPalCheatManager : public
--     UCheatManager` (Pal.hpp:16085-16554) were read. It holds six members —
--     DebugWindowSetting, DebugProgressPresetDataTable, SpawnerInfoReporterClass, PalImGui,
--     PalCountSystem, SpawnInfoReporter — and not one of them is a spawn mode, a target, an
--     enable flag or a "spawn at the reticle" concept. There is no SpawnMonster_ToServer, no
--     _ServerInternal twin and no second overload anywhere on the class.
--   * A BLIND MEASUREMENT — dead, and this one matters most: the world delta below really
--     would have seen a pal. APalMonsterCharacter derives APalNPC derives APalCharacter
--     (Pal.hpp:10167, 10195, 8956), and dumps/reflection/04_live_objects.txt shows the
--     FindAllOf("PalCharacter") sweep returning BP_PinkCat_C out of a live world — a monster
--     blueprint, not a player. Subclasses are enumerated. A spawned pal would have been counted.
--
-- TWO CAPABILITIES, TWO OBJECTS, ONE ROUTE EACH — no route falls back onto another, so a false
-- names one call rather than hiding three.
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
-- WHAT A `true` MEANS. None of these calls answers anything — an unknown CharacterID neither
-- throws nor reports — so "the native call RAN" is worth nothing and is no longer reported as
-- success. The only evidence in reach is the world itself: FindAllOf("PalCharacter")
-- immediately before the call and immediately again after it. M.pal and M.palAt return true
-- ONLY when a pal that was not there a statement ago is there now; otherwise they warn and
-- return false. That immediate look cannot be fooled by a wild pal streaming in — the two
-- enumerations are adjacent statements on the game thread with no tick between them — but it
-- CAN miss an actor that materializes a few frames late, so both routes still look AGAIN
-- ~1.2 s later and log what they find. That deferred line is what recorded the bug above, and
-- it is where the route coming alive would show up first.
-- The one exception is M.palForPlayer: it summons into the party/box, which nothing here can
-- enumerate, so its true still means only "the call was issued". It says so at its own doc.
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

-- How many live PalCharacters are in the world that were not in `before`. This is the whole
-- of what this module can measure: no spawn call on this build answers anything, so a count
-- taken against a snapshot is the only thing that can tell a spawn from a no-op.
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

-- Deferred spawn CONFIRMATION, log-only, and the SECOND look: the immediate count at the call
-- site catches a spawn that is synchronous, this one catches an actor that materializes a few
-- frames late. Its warning is what recorded the standing bug — the call ran, nothing arrived —
-- so it stays armed on exactly the path that reported false. Costs one FindAllOf per spawn the
-- caller asked for, and nothing at all where the async pair is unavailable.
local function canDefer()
    return type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function"
end

local function confirmSpawnLater(before, what)
    if not (before and canDefer()) then return end
    LoopAsync(1200, function()
        ExecuteInGameThread(function()
            pcall(function()
                local n = newPalCount(before)
                if n > 0 then
                    log.info(string.format("%s: %d new PalCharacter in the world 1.2 s later", what, n))
                else
                    log.warn(string.format("%s: the call ran but NO new PalCharacter appeared "
                        .. "1.2 s later either — the route produced nothing (see TODO "
                        .. "pal-spawnmonster-signature). A CharacterID the game does not have "
                        .. "looks exactly the same from here", what))
                end
            end)
        end)
        return true   -- one shot
    end)
end

-- THE spawn call, made once for both world routes, wrapped in the only measurement available:
-- the world enumerated immediately before it and immediately after. Answers
--   ran       the native call executed without raising — worth nothing on its own,
--   appeared  how many PalCharacters exist now that did not exist a statement ago,
--   before    that snapshot, for the deferred pass that looks again 1.2 s later,
--   level     which evidence core.signature fired on ("declared" / "present"), or nil when
--             it refused and the game was never touched.
--
-- The declared shape is (const FName CharacterID, int32 Level) — dumps/cxx/Pal.hpp:16176 —
-- i.e. NameProperty then IntProperty, which is the same FName-plus-integer marshalling this
-- tree already performs successfully on this exact object every time utils/items unlocks a
-- technology through cm:UnlockOneTechnology(FName(...)) (Pal.hpp:16104). That is why "present"
-- evidence is acceptable for this call and would not be for a struct one.
--
-- TODO(pal-spawnmonster-signature): THE SIGNATURE HALF IS CLOSED — the name is kept because
-- api/pal.lua, the pal test suite and test/probes/reflect.lua all cite it, but the unknown it
-- names has moved. What dumps/cxx/ ELIMINATED on 2026-07-26 is written out at the file header:
-- the parameter list is exactly the two arguments passed here, the cheat-manager class carries
-- no gate/mode/target/enable flag of any kind, and the world delta below really does enumerate
-- monster subclasses so it would have SEEN a pal. None of the three explanations anyone had
-- survives.
-- WHAT IS STILL UNKNOWN, and it is now one question rather than three: WHERE the call has to
-- run. The dump has no function bodies, so this is a hypothesis, offered because it is the
-- only one the headers still support — Palworld routes every mutating debug action through the
-- SERVER, never the local object. APalPlayerController declares a _ToServer twin for each one
-- (Debug_AddMoney_ToServer, Debug_AddPlayerExp_ToServer, Debug_Muteki_ToServer,
-- Debug_SetStatusPoint_ToServer, Debug_ForceSpawnRarePal_ToServer, and the general
-- Debug_CheatCommand_ToServer(FString Command) at Pal.hpp:10970 with
-- Debug_ReceiveCheatCommand_ToClient(FString Message) coming back at :10956), and
-- UPalCheatManager itself carries EnableCommandToServer() (:16440) and CommandToServer(const
-- FString Command) (:16501). Those exist because the game does NOT expect a cheat issued where
-- the caller lacks authority to do anything locally — which is precisely the observed
-- behaviour: runs, raises nothing, changes nothing. It also explains why UnlockOneTechnology
-- works on the same object: technology is the player's own replicated data, an actor is not.
-- WHY THAT DOES NOT MAKE THE FORWARD A FIX YET, and why it is not wired: every one of those
-- names is confirmed on the LIVE build (dumps/reflection/02_reflection.txt:190-213) but nothing
-- says the single-player session is non-authoritative, and on an authoritative controller a
-- Server RPC just runs its implementation locally — i.e. straight back into this same function.
-- Swapping a measured-dead direct call for the same call reached through an unverified command
-- STRING would trade one unknown for two. So the direct call stays and the forward is the named
-- next experiment.
-- WHAT THE NEXT RUN MUST DO (read-only first, one line each, in a loaded save):
--   1. print the network role — local pc = FindFirstOf("PalPlayerController"); print(pc.Role,
--      pc.RemoteRole, pc:HasAuthority()). An authoritative controller kills the hypothesis
--      outright and the search moves to the CharacterID and the spawn location instead.
--   2. only if step 1 says the session is NOT authority: in a THROWAWAY world,
--      pc:Debug_CheatCommand_ToServer("SpawnMonster ChickenPal 5") — one FString, which is a
--      scalar core.signature will pass — then count FindAllOf("PalCharacter") before and after.
--      A rise is the close; nothing is one more elimination and is worth as much.
local SPAWN_MONSTER_PARAMS = { "NameProperty", "IntProperty" }

local function spawnMonster(cm, name, level)
    local before = snapshotPals()
    local ran, _, level_ = sig.call(cm, "SpawnMonster", SPAWN_MONSTER_PARAMS, FName(name), level)
    return ran, (ran and newPalCount(before) or 0), before, level_
end

-- Spawn a WILD pal of game CharacterID `charId` at `level` INTO THE WORLD, near the player
-- (visible, un-owned). CharacterID is the game code id (e.g. "ChickenPal", "Kitsunebi",
-- "BlueSkyDragon") = a PalForge Pal's id; a namespaced id resolves to its row spelling.
--
-- Returns true ONLY when a PalCharacter that was not in the world a statement ago is in it
-- now. On this build that has never happened (see the file header): the call runs, nothing
-- appears, and this answers false. The 1.2 s confirmation still runs on that path — an actor
-- arriving late would show up there, and that is the line that would say the route came alive.
function M.pal(charId, level)
    if type(charId) ~= "string" or #charId == 0 then return false end
    level = tonumber(level) or 1
    local cm = cheatManager()
    if not cm then
        log.warn("spawn.pal: no PalCheatManager and none could be constructed (no player controller yet?)")
        return false
    end
    local name = charName(charId)
    local ran, appeared, before, evidence = spawnMonster(cm, name, level)
    if not ran then
        -- core.signature has already logged WHY — a refusal (the live class does not declare
        -- SpawnMonster the way dumps/cxx does) or a binding error naming the arity it wanted.
        log.err(string.format("spawn.pal: SpawnMonster did not execute for %s [evidence %s]",
            name, tostring(evidence)))
        return false
    end
    if appeared > 0 then
        log.info(string.format("spawn.pal(world) %s (lv %d): %d new PalCharacter in the world "
            .. "[evidence %s]", name, level, appeared, evidence))
        return true
    end
    log.warn(string.format("spawn.pal: SpawnMonster(%s, lv %d) ran [evidence %s] and NOTHING "
        .. "spawned — no spawn route has been observed to work on this build, so this reports "
        .. "false (see TODO pal-spawnmonster-signature). Watching for a late arrival",
        name, level, evidence))
    confirmSpawnLater(before, "spawn.pal " .. name)
    return false
end

-- ---- coordinate placement (post-spawn relocation) ----
-- No spawn call in this file takes a location, so a coordinate spawn is spawn-then-move: we
-- relocate the freshly-spawned actor once it materializes, identifying it by UObject address
-- so only the pal we just added is moved. That the actor appears NEAR THE PLAYER, and a few
-- frames late, is inherited belief — it is what the C++ bridge's UPalCharacterManager::
-- SpawnNewCharacter did (it ignored the requested SpawnParameter.SpawnLocation, verified
-- 2026-07-23), and that bridge is not installed here. Nothing has ever spawned through THIS
-- file, so the near-the-player anchor below is untested along with everything else.

-- ONE route, and the one deliberate exception to "every engine call goes through
-- core.signature". K2_TeleportTo is the character-aware relocate — it updates the movement
-- component and resolves encroachment, so the pal keeps its AI and physics instead of freezing —
-- and dumps/cxx/Engine.hpp:7971 declares it `bool K2_TeleportTo(FVector DestLocation, FRotator
-- DestRotation)`: two StructProperty arguments. core.signature REFUSES a struct on "present"
-- evidence, and "present" is what this build is expected to answer (a UFunction is a UObject in
-- UE4SS's Lua API, so its parameter walk is often unavailable) — routing this through sig.call
-- would therefore not make the relocate safer, it would permanently delete a half that has never
-- yet had anything to move. So the existence of the function is checked through core.signature
-- (that much it can always answer) and the call itself is made directly.
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

-- Relocate ONLY our freshly-spawned pal to (x,y,z). The spawn is expected to drop it right at
-- the player, so among pals absent from `before` we move the SINGLE one nearest the player's
-- spawn position (px,py,pz) — never a batch, so wild pals that streamed in meanwhile are not
-- dragged along (that was the "20 -> 40 floating pals" bug). Retries; the actor is expected
-- deferred. Returns true ONLY when a new pal was found AND the move reported success. Nobody
-- can receive that today — every call site is a retry timer that ran long after palAt returned
-- — so the return exists for the log line to be honest and for a future caller to poll on.
--
-- TODO(pal-spawn-placement): NARROWED by the 2026-07-26 in-game run, and now BLOCKED behind
-- pal-spawnmonster-signature. What that run settled: this pass RUNS in a live world. It
-- reached its own last line — "no new pal actor appeared to place" — twice, so the 400 ms
-- retry chain, the enumeration and the reporting all work end to end. What it could not
-- settle, and cannot until something spawns at all: the found / moved / landed half. No run
-- of teleportActor on a real pawn, and no read-back distance, exists anywhere in either tree.
-- NARROWED again by dumps/cxx/Engine.hpp: the relocate is no longer three guesses but the one
-- declared call, K2_TeleportTo(FVector, FRotator) at :7971 (see teleportActor). So a failure
-- here can no longer mean "we called the wrong name" — it means the teleport itself refused.
local function placeNewPal(before, px, py, pz, x, y, z, tries)
    tries = tries or 0
    local best, bd
    for _, a in ipairs(palActors()) do
        if a and a.IsValid and a:IsValid() then
            local id = actorId(a)
            if id and not before[id] then
                local l = actorLoc(a)
                if l then
                    local dx, dy, dz = l.X - px, l.Y - py, l.Z - pz
                    local d = dx * dx + dy * dy + dz * dz
                    if not bd or d < bd then bd, best = d, a end
                end
            end
        end
    end
    if best then
        local moved = teleportActor(best, x, y, z)
        if moved then
            -- Read the position BACK: the relocate calls report "the call ran", and only the
            -- actor's own location says whether it landed. This is the one line that can ever
            -- prove the coordinate route works, so it prints what was asked and what happened.
            local l = actorLoc(best)
            if l then
                local dx, dy, dz = (l.X or 0) - x, (l.Y or 0) - y, (l.Z or 0) - z
                log.info(string.format("spawn.palAt: placed new pal at (%.0f,%.0f,%.0f); it "
                    .. "reads back (%.0f,%.0f,%.0f), off by %.0f",
                    x, y, z, l.X, l.Y, l.Z, math.sqrt(dx * dx + dy * dy + dz * dz)))
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
    if tries < 6 and canDefer() then
        LoopAsync(400, function()
            ExecuteInGameThread(function() pcall(placeNewPal, before, px, py, pz, x, y, z, tries + 1) end)
            return true
        end)
    else
        log.warn("spawn.palAt: no new pal actor appeared to place — after ~2.4 s of retries "
            .. "there is still nothing in the world that was not there before the spawn call, "
            .. "so there is nothing to move (see TODO pal-spawnmonster-signature)")
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
