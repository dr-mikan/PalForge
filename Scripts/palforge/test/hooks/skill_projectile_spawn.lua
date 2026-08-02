-- test/hooks/skill-projectile-spawn — READ THE DECLARATIONS, FIRE THE ONE CALL THAT CARRIES NO
-- STRUCT, AND REFUSE THE REST BY NAME.
--
-- plan/TODO.md Open / Skill. Marked in the source at native/skills.lua's
-- TODO(skill-projectile-spawn) (:652 as this was written), inside the FlameThrower demo's
-- onActivate — the handler that logs, once per session, that it spawned nothing.
--
-- WHAT THE ITEM IS. `Skill{ kind = "active", element = "fire", power = 50 }` defines, registers
-- and dispatches, and `onActivate` runs at exactly the right moment on a real activation — that
-- half is MEASURED (core/event hooks PalActionBase:OnBeginAction and skill.activate carries the
-- waza id; see the skill-hit-source marker at api/skill.lua:118). But element, power and
-- cooldown are framework-side metadata that reach nothing, and the handler has no call available
-- to it that puts an object in the world. So a pack's active skill is a well-timed Lua function
-- and that is all it is.
--
-- WHAT IS ALREADY READ, so this hook does not re-ask it:
--   * APalSkillEffectBase : AActor (dumps/cxx/Pal.hpp:11345), with
--     Initialize(const AActor* SkillOwner, const FVector& MyOffset, AActor* Target,
--     FRandomStream RandomStream) at :11370 and CreateChildSkillEffect(
--     TSubclassOf<APalSkillEffectBase>, FTransform, FRandomStream,
--     ESpawnActorCollisionHandlingMethod, AActor*) at :11374.
--   * the waza row NAMES a class to spawn — FPalWazaDatabaseRaw (Pal.hpp:7534) carries
--     TSubclassOf<UPalWazaBulletEmiiterOverlapBase> BulletEmiiterOverlapClass (:7558), reachable
--     through UPalWazaDatabase::FindWazaForBP(EPalWazaID, FPalWazaDatabaseRaw& OutData)
--     (Pal.hpp:32646 — note the OUT STRUCT BY REFERENCE, which is a push, not a return).
--   * PalForge already has the generic spawn: core/spawn.lua:152's M.actor is
--     BeginDeferredActorSpawnFromClass + FinishSpawningActor, both read off the dump.
--   * APalBullet : AActor (Pal.hpp:8849), and APalMonsterEquipWeaponBase (:10181) declares
--     ShootOneBullet(TSubclassOf<APalBullet>, UNiagaraSystem*, FVector, FRotator, float) at
--     :10186 — and ONE argument-free sibling, ShootOneBulletDefault() at :10185, which is the
--     only entry on this whole surface that needs no struct at all.
--
-- THE SINGLE UNKNOWN FACT is whether a STRUCT argument can be marshalled into a Palworld
-- UFunction on this build. Every route above except one carries an FVector, an FTransform, an
-- FRandomStream or an out-struct by reference.
--
-- ⚠️ AND THAT IS WHY THIS HOOK REFUSES TO ANSWER IT BY TRYING. A wrong ARITY raises and pcall
-- catches it; a wrong TYPE faults inside UE4SS's own argument marshalling and takes the process
-- with it — pcall does not see it, and there is no guarding on this side that makes it
-- survivable (core/signature.lua:5-17; `inv:CountItemNum("Wood")` closed Palworld mid-probe and
-- cost a whole run of findings). A hook that dies mid-block destroys the log it was writing, so
-- a crash is not a worse result than a refusal — it is NO result. What this hook produces
-- instead is the thing the item has never had: THE PARAMETER LIST THE RUNNING BUILD DECLARES,
-- printed for all four candidates, with the struct parameters named one by one and the reason
-- each call was not made attached to it. A refusal that names what the build declared is a
-- complete answer for this item.
--
-- AND IT SETTLES A SECOND ITEM FOR FREE. core/spawn.lua's M.actor has never run: it is gated on
-- exactly this question (BEGIN_PARAMS declares a StructProperty and core/signature refuses one
-- on "present" evidence). Block [1] asks GameplayStatics the same way it asks the Pal classes,
-- so whether that gate can EVER open on this build is answered in the same log block.
--
-- ⚠️ writes = true, and the opt-in is separate from env.debug:
-- `env.debugHooks["skill-projectile-spawn"] = true` in Scripts/palforge_dev.lua. Nothing here
-- writes to a character or an inventory, but block [2] FIRES A REAL BULLET out of a live
-- weapon: whatever is in front of it can be hit, and a pal that takes damage is a save that
-- changed. That is a per-experiment decision on a throwaway save, not something `debug` alone
-- should arm. Stand somewhere empty and face nothing you care about.
--
-- ONE BLOCK, NO WATCHERS. Everything this hook prints is inside the runner's
-- `#### BEGIN skill-projectile-spawn` / `#### END skill-projectile-spawn` brackets, so the whole
-- answer lifts out of UE4SS.log in one piece. It registers no native hook, starts no poller and
-- asks the operator for nothing, so it is finished when the END line prints and F9 is not
-- refused after it (compare the watcher hooks, which print further -1 / -2 blocks and hold the
-- reload guard open — test/hooks/init.lua:58-71).
--
-- A RUN OF NILS IS A RESULT, and which nils decides which:
--   * every declaration "UNWALKABLE" -> this UE4SS build will not read a UFunction's parameter
--     list at all. skill-projectile-spawn then closes as UNANSWERABLE FROM LUA on this build,
--     and core/spawn.lua's M.actor is permanently gated with the same one line as its reason.
--   * declarations read, every candidate carrying a struct -> the answer is the refusal, and it
--     is a complete one: no projectile route is reachable without pushing a struct.
--   * block [2] finds no weapon -> that block measured nothing. It is not evidence about
--     ShootOneBulletDefault; it is evidence that no pal near you had a ranged weapon out.
local hooks = require("palforge.test.hooks")

-- Mirrors core/signature.lua:77-80's UNVERIFIABLE_KINDS. These are the property classes that
-- marshal BY VALUE or BY LAYOUT, where a mismatch writes through a bad shape — the failure mode
-- worth refusing an unread declaration over. ObjectProperty is deliberately not among them: a
-- live UObject handed to a UObject pointer is the most ordinary call UE4SS Lua makes.
local UNVERIFIABLE = {
    StructProperty = true, ArrayProperty = true, MapProperty = true, SetProperty = true,
    DelegateProperty = true, MulticastDelegateProperty = true, TextProperty = true,
}

-- THE PARAMETER WALK, PRINTED, WITH THE STRUCTS NAMED. Three outcomes, three different
-- findings, so each is spelled out rather than collapsed into "no":
--   absent      no function of that name is reachable from this object on this build
--   unwalkable  it exists and this build will not iterate a UFunction's properties. The types
--               are UNREAD, so nothing may be pushed at it, whatever the C++ dump says.
--   declared    the running build stated its list, and it is now in the log
-- Returns { status =, args = {…}, structs = {"…"} } so the caller can decide and, more
-- importantly, SAY WHY.
local function declaration(h, sig, owner, fnName, ownerLabel)
    local out = { status = "no owner", args = {}, structs = {} }
    if owner == nil then
        h:value(fnName .. " on " .. ownerLabel, "not read — no live object of that class to ask")
        return out
    end
    local fn, how = sig.find(owner, fnName)
    if not fn then
        out.status = "absent"
        h:value(fnName .. " on " .. ownerLabel, "ABSENT — this build declares no such function here")
        return out
    end
    local params = sig.paramsOf(fn)
    if not params then
        out.status = "unwalkable"
        h:value(fnName .. " on " .. ownerLabel, string.format("PRESENT (%s) but UNWALKABLE — "
            .. "this UE4SS build will not iterate a UFunction's properties, so its argument "
            .. "types are UNREAD", tostring(how)))
        return out
    end
    out.status = "declared"
    local shape = {}
    for i, p in ipairs(params) do
        shape[i] = string.format("%s:%s", tostring(p.name), tostring(p.kind))
        -- The return trails the parameters (core/signature.lua:229-231 relies on the same
        -- ordering), so a trailing ReturnValue is not an argument and must not be counted as
        -- one — ShootOneBulletDefault RETURNS an APalBullet* and takes nothing.
        if not (i == #params and p.name == "ReturnValue") then
            out.args[#out.args + 1] = p
            if UNVERIFIABLE[p.kind] then
                out.structs[#out.structs + 1] = string.format("%s (parameter %d, %s)",
                    tostring(p.name), i, tostring(p.kind))
            end
        end
    end
    h:value(fnName .. " on " .. ownerLabel, string.format("DECLARED (%s) — [%s]",
        tostring(how), table.concat(shape, ", ")))
    if #out.structs > 0 then
        h:note("%s declares %d argument(s) that marshal by layout: %s. THIS BUILD READ THAT "
            .. "LIST — the types are no longer a guess — and this hook still will not push one, "
            .. "for the reason in its header.", fnName, #out.structs,
            table.concat(out.structs, "; "))
    end
    return out
end

hooks.declare{
    id     = "skill-projectile-spawn",
    item   = "Open / Skill",
    needs  = { world = true, pal = true },
    writes = true,
    desc   = "print the declared parameter list of every projectile / spawn route, fire the one "
          .. "that takes no arguments, and refuse the struct ones by name",
    run = function(h)
        local support = require("palforge.test.support")
        local sig     = require("palforge.core.signature")
        local probe   = require("palforge.test.probe")
        local uo      = require("palforge.core.uobject")

        --------------------------------------------------------------------
        h:section("[1] THE FOUR DECLARATIONS. Nothing in this block is called.")
        --------------------------------------------------------------------
        -- Each one is asked of a LIVE object where the world has one, and of the class default
        -- object otherwise. core/signature walks a UClass, a CDO or an instance alike
        -- (core/signature.lua:112-145), so a CDO answers the DECLARATION question in full — it
        -- is only a CALL that needs something standing in the world.
        local weapon
        pcall(function() weapon = FindFirstOf("PalMonsterEquipWeaponBase") end)
        local weaponLive = probe.valid(weapon)
        if not weaponLive then
            pcall(function() weapon = StaticFindObject("/Script/Pal.Default__PalMonsterEquipWeaponBase") end)
        end
        h:value("APalMonsterEquipWeaponBase", weaponLive
            and ("LIVE " .. probe.full(weapon))
            or (probe.valid(weapon) and ("CDO only — " .. probe.full(weapon))
                or "neither a live instance nor a CDO resolved"))

        local effect
        pcall(function() effect = FindFirstOf("PalSkillEffectBase") end)
        local effectLive = probe.valid(effect)
        if not effectLive then
            pcall(function() effect = StaticFindObject("/Script/Pal.Default__PalSkillEffectBase") end)
        end
        h:value("APalSkillEffectBase", effectLive
            and ("LIVE " .. probe.full(effect))
            or (probe.valid(effect) and ("CDO only — " .. probe.full(effect))
                or "neither a live instance nor a CDO resolved"))

        local gs
        pcall(function() gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
        h:value("GameplayStatics CDO", probe.valid(gs) and probe.full(gs) or "did not resolve")

        local wazaDb
        pcall(function() wazaDb = FindFirstOf("PalWazaDatabase") end)
        h:value("UPalWazaDatabase", probe.valid(wazaDb) and probe.full(wazaDb) or "none live")

        local d = {}
        d.shootDefault = declaration(h, sig, probe.valid(weapon) and weapon or nil,
            "ShootOneBulletDefault", "APalMonsterEquipWeaponBase")
        d.shoot        = declaration(h, sig, probe.valid(weapon) and weapon or nil,
            "ShootOneBullet", "APalMonsterEquipWeaponBase")
        d.child        = declaration(h, sig, probe.valid(effect) and effect or nil,
            "CreateChildSkillEffect", "APalSkillEffectBase")
        d.initialize   = declaration(h, sig, probe.valid(effect) and effect or nil,
            "Initialize", "APalSkillEffectBase")
        d.beginSpawn   = declaration(h, sig, probe.valid(gs) and gs or nil,
            "BeginDeferredActorSpawnFromClass", "GameplayStatics")
        d.finishSpawn  = declaration(h, sig, probe.valid(gs) and gs or nil,
            "FinishSpawningActor", "GameplayStatics")
        d.findWaza     = declaration(h, sig, probe.valid(wazaDb) and wazaDb or nil,
            "FindWazaForBP", "UPalWazaDatabase")

        -- THE HEADLINE, and it is one boolean about this UE4SS build rather than about Palworld:
        -- did ANY walk succeed? Everything downstream — this item, core/spawn.lua's M.actor,
        -- every future struct call in this tree — turns on it.
        local walked, unwalkable = 0, 0
        for _, r in pairs(d) do
            if r.status == "declared" then walked = walked + 1
            elseif r.status == "unwalkable" then unwalkable = unwalkable + 1 end
        end
        h:value("declarations read / unreadable", string.format("%d read, %d present but "
            .. "unwalkable", walked, unwalkable))
        if walked > 0 then
            h:pass("THIS BUILD WALKS A UFUNCTION'S PARAMETERS (%d of them above). That is the "
                .. "condition core/signature calls `declared` evidence, and it is the condition "
                .. "core/spawn.lua's M.actor has always been gated on — its refusal is "
                .. "conditional, not permanent, and the lists above say exactly what it would "
                .. "be pushing.", walked)
        elseif unwalkable > 0 then
            h:note("NOT ONE parameter list could be read, and every candidate exists. So the "
                .. "answer to this item is a property of this UE4SS build: the argument types "
                .. "are unreadable, `present` is the best evidence any of these calls can ever "
                .. "reach, and core/signature refuses a struct on `present` by design. M.actor "
                .. "cannot open on this build either, and that is now measured rather than "
                .. "assumed.")
        else
            h:fail("no candidate was reachable at all — not live, not as a CDO. That is a "
                .. "finding about this SESSION (nothing loaded, or the names differ on this "
                .. "build), not about the projectile route.")
        end

        --------------------------------------------------------------------
        h:section("[2] THE ONE SAFE CALL: ShootOneBulletDefault(), zero arguments")
        --------------------------------------------------------------------
        -- The only entry on this whole surface that pushes nothing. Zero arguments means there
        -- is no marshalling to get wrong, so this is the one thing here that can be tried before
        -- anything else is known — and it is a REAL projectile out of a REAL weapon.
        if not weaponLive then
            h:warn("REFUSING to call ShootOneBulletDefault: no LIVE APalMonsterEquipWeaponBase "
                .. "is in the world. The CDO is not an actor — calling a firing routine on a "
                .. "class default object is not a smaller version of firing it, it is a "
                .. "different and worse thing. TO GET ONE: have a pal with a RANGED attack out "
                .. "and let it start a fight, then run this again. This block measured nothing.")
        elseif d.shootDefault.status == "absent" then
            h:fail("a live weapon actor exists and does not answer to ShootOneBulletDefault. "
                .. "Pal.hpp:10185 declares it on APalMonsterEquipWeaponBase, so either this "
                .. "actor is a different class than it looks or the dump has drifted from the "
                .. "build.")
        elseif #d.shootDefault.args > 0 then
            h:warn("REFUSING to call ShootOneBulletDefault: the walk says it takes %d "
                .. "argument(s) — %s — and the dump says zero. The BUILD wins that argument, "
                .. "and a call written for the dump's shape is exactly the mistake this hook "
                .. "exists to not make.", #d.shootDefault.args,
                (d.shootDefault.args[1] and tostring(d.shootDefault.args[1].kind)) or "?")
        else
            h:value("weapon owner", tostring(uo.fullName(weapon)))
            h:value("weapon class chain", table.concat(uo.classChain(weapon), " : "))
            h:warn("ABOUT TO FIRE A REAL BULLET out of that weapon. Whatever is in front of it "
                .. "can be hit. This is the only call this hook makes.")
            local ok, bullet, level = sig.call(weapon, "ShootOneBulletDefault", {})
            h:value("ShootOneBulletDefault()", string.format("issued=%s evidence=%s",
                tostring(ok), tostring(level)))
            h:value("returned", ok and probe.describe(bullet) or "nothing (refused or raised)")
            if ok and probe.valid(bullet) then
                h:pass("⭐ A PROJECTILE CAME BACK: %s. So SOMETHING in this tree's reach can put "
                    .. "an object in the world — the projectile question is no longer "
                    .. "`impossible`, it is `only reachable through an object the skill surface "
                    .. "does not have`. That is a materially different item.",
                    probe.className(bullet))
                h:note("what it does NOT establish: that a PACK could do this. The call needs a "
                    .. "live APalMonsterEquipWeaponBase, which a Skill handler is never handed "
                    .. "— onActivate receives an owner and a ctx (api/skill.lua's Handle:"
                    .. "activate). Wiring one to the other is design work, not a measurement.")
            elseif ok then
                h:note("the call ran and returned nothing valid. That is the GetItem pattern — "
                    .. "declared, issued, no effect — and on a client-authoritative route it is "
                    .. "as likely to be authority as it is to be the call. Look for a muzzle "
                    .. "flash; if you saw one, the return is the only thing that is empty.")
            else
                h:note("the call was refused or raised, and the [signature] line above says "
                    .. "which. A refusal is core/signature doing its job; a raise is arity, and "
                    .. "the message names the count the engine wanted.")
            end
        end

        --------------------------------------------------------------------
        h:section("[3] THE REFUSAL, NAMED — every remaining route, and its struct")
        --------------------------------------------------------------------
        -- This block is the ANSWER to the item, not an apology for not having one. Each line
        -- names a route, what this build declares for it, and the exact parameter that stops it.
        local blocked = 0
        for _, entry in ipairs({
            { key = "shoot",       what = "ShootOneBullet — the aimed bullet, with muzzle location and rotation" },
            { key = "child",       what = "CreateChildSkillEffect — a skill effect spawning another" },
            { key = "initialize",  what = "APalSkillEffectBase::Initialize — arming a spawned effect" },
            { key = "beginSpawn",  what = "BeginDeferredActorSpawnFromClass — core/spawn.lua's M.actor, first half" },
            { key = "finishSpawn", what = "FinishSpawningActor — core/spawn.lua's M.actor, second half" },
            { key = "findWaza",    what = "FindWazaForBP — the row that NAMES the class to spawn, by out-parameter" },
        }) do
            local r = d[entry.key]
            if r.status == "declared" and #r.structs > 0 then
                blocked = blocked + 1
                h:warn("NOT CALLED — %s. This build declares: %s. Refused because a struct "
                    .. "argument marshals by layout and a mismatch faults natively; that is the "
                    .. "one failure pcall cannot see.", entry.what, table.concat(r.structs, "; "))
            elseif r.status == "declared" then
                h:note("%s declares NO struct argument on this build. It is not refused on "
                    .. "layout grounds, and it is the first place a follow-up run should look.",
                    entry.what)
            elseif r.status == "unwalkable" then
                blocked = blocked + 1
                h:warn("NOT CALLED — %s. It EXISTS and its parameter list is unreadable on this "
                    .. "build, so its argument types are the C++ dump's word alone. The dump "
                    .. "says it carries a struct, and an unread declaration is not something to "
                    .. "push a struct against.", entry.what)
            elseif r.status == "absent" then
                h:note("%s — ABSENT on this build, so there is nothing to refuse and nothing to "
                    .. "call. That is a real answer: the route does not exist here.", entry.what)
            else
                h:note("%s — no object of that class was reachable THIS SESSION, so its "
                    .. "declaration was never asked for. That is a gap in the run, not a fact "
                    .. "about the build.", entry.what)
            end
        end
        h:value("routes refused", blocked)
        if blocked > 0 or walked > 0 then
            h:pass("THE DECLARATIONS ARE ON RECORD AND THE PROCESS IS STILL RUNNING. That is "
                .. "this hook's result: %d route(s) refused by name, each with the build's own "
                .. "parameter list and the exact argument that stops it. The next decision — "
                .. "whether this tree ever pushes a struct at Palworld — is one someone takes "
                .. "deliberately, with this block in front of them, and not as a side effect of "
                .. "a measurement.", blocked)
        else
            -- NOT A PASS. Nothing was read and nothing was refused, so there is nothing on
            -- record — and a run that ends with a green line having measured nothing is the
            -- exact failure this whole directory was built to stop.
            h:fail("NOTHING WAS RECORDED. No declaration was read and no route was refused, so "
                .. "this run says nothing about skill-projectile-spawn. Block [1] names which "
                .. "objects could not be reached; that is what to fix before running it again.")
        end
        h:note("WHAT WOULD OPEN IT, in order: (1) a `declared` walk on "
            .. "BeginDeferredActorSpawnFromClass — block [1] says whether that is even possible "
            .. "here; (2) a struct pushed ONCE, on a throwaway save, from a hook that does "
            .. "nothing else, so that a fault costs one line of log and no findings; (3) only "
            .. "then core/spawn.lua's M.actor, and only then a projectile.")

        --------------------------------------------------------------------
        h:section("[4] what a pack author gets today")
        --------------------------------------------------------------------
        -- The user-facing half, in the same block as its cause. This runs the very definition
        -- the marker sits inside, so the log shows the honest return and the honest log line
        -- next to the declarations that explain them.
        local Skill = require("palforge.api.skill")
        pcall(function() require("palforge.native.skills") end)
        local pal = support.nearbyPal()
        local handle = Skill.get("FlameThrower")
        local fired
        local okAct = pcall(function() fired = handle:activate(pal, { via = "skill-projectile-spawn" }) end)
        h:value("Skill.get('FlameThrower'):activate(pal)", okAct and tostring(fired) or "raised")
        h:note("a `true` there means ONLY that the handler ran to completion — that is what "
            .. "api/skill.lua's Handle:activate is documented to return (false for a passive, "
            .. "false when the cooldown blocked it, false when the handler raised). Nothing "
            .. "came out of it, and the [skills] warning above this line is the demo definition "
            .. "saying so in the one channel that can. Watch your pal: nothing happened, and "
            .. "that is the item.")
        h:note("if the second activation in one session prints no [skills] warning, that is "
            .. "correct and not a missed log — native/skills.lua warns once per session on "
            .. "purpose (its `warnedNoProjectile` flag).")
    end,
}
