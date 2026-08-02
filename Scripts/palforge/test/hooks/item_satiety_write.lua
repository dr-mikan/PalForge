-- test/hooks/item-satiety-write — IS THE SATIETY WRITE REACHABLE FROM LUA AT ALL?
--
-- plan/TODO.md Open / Item. Marked in the source at native/items.lua's
-- TODO(item-satiety-write) (:559 as this was written), directly above the Berries definition
-- whose handler logs a line and feeds nobody.
--
-- WHAT THIS HOOK CLOSES. The item is "a pack cannot declare an item that FEEDS or HEALS by its
-- own rules", and its marker narrows that to ONE unread fact: what parameter list
-- `SetFullStomach` declares on the live build, and therefore whether it is callable at all.
-- Everything else the marker names is already settled on paper and is only re-read here as the
-- ground the answer stands on:
--   * the object is reachable. UPalIndividualCharacterParameter is what
--     core.character.paramsOf(actor) hands back, through
--     PalUtility::GetIndividualCharacterParameterByActor (dumps/cxx/Pal.hpp:32340) — the route
--     this tree proved by reading a real pal's four move lists.
--   * the READERS are declared: GetFullStomach (Pal.hpp:21108), GetMaxFullStomach (:21095),
--     GetMaxHP (:21094), GetHP (:21102).
--   * the SETTER is not. dumps/reflection/02_reflection.txt:1298 lists `.SetFullStomach` on
--     /Script/Pal.PalIndividualCharacterParameter (class block from :1107), and the CXX dump's
--     body for that class (Pal.hpp:20822-21161) does not declare it. So there is a name and no
--     signature, and core/signature has nothing to check a call against. That gap is the item.
--
-- THE ONE RULE THIS HOOK IS BUILT AROUND: DESCRIBE, THEN CALL — NEVER THE REVERSE. A wrong
-- ARITY raises and pcall catches it; a wrong TYPE faults inside UE4SS's own marshalling and
-- takes the process with it (core/signature.lua:5-17 — `inv:CountItemNum("Wood")` closed
-- Palworld mid-probe). So block [2] walks the UFunction and PRINTS what the running build
-- declares, and block [4] calls SetFullStomach only if that walk succeeded AND read a single
-- scalar. A declaration that could not be read is not a reason to try it and see.
--
-- TWO PIECES OF CIRCUMSTANTIAL EVIDENCE that satiety is a float, recorded here because they are
-- worth having in the log beside the walk and are NOT a substitute for it:
--   * UPalIndividualCharacterParameter::UpdateFullStomachDelegate(float Current, float Last)
--     (Pal.hpp:20841, delegate signature at :20966) — the value this class broadcasts on every
--     change is a float.
--   * UPalCheatManager::SetFullStomachToBaseCampPal(const float Value) (Pal.hpp:16254) — a
--     DECLARED single-float satiety write, on the cheat-manager surface, aimed at base-camp
--     pals rather than at an arbitrary character. It is described in block [2] as a control and
--     is deliberately not called: it writes to every worker in a base camp at once, which is a
--     far larger mutation than this hook is entitled to make, and the cheat surface has been
--     measured executing perfectly and reaching nothing before (see building-unlock).
--
-- HP IS THE SEPARATE, WORSE CASE and block [3] is all of it that can be run. Every declared HP
-- write takes FFixedPoint64, a struct (`{ int64 Value; }`, Pal.hpp:120-124) — SetHP
-- (Pal.hpp:15933), UPalCharacterParameterComponent::AddHP (:16018),
-- UPalIndividualCharacterParameter::AddHP (:21156) — and a struct argument is the shape that
-- faults where pcall cannot see it. The ONE exception is
-- UPalCharacterParameterComponent::AddHPByRate(float Rate) (Pal.hpp:16016): a single plain
-- float, callable today, never once called. Note the class: AddHPByRate is on the parameter
-- COMPONENT hanging off the actor (APalCharacter::CharacterParameterComponent, Pal.hpp:8960;
-- getter at :9078), NOT on the individual parameter object blocks [1] and [2] use. Two
-- different objects, and asking the wrong one is how a present function reads as absent.
--
-- ⚠️ writes = true, AND THE OPT-IN IS SEPARATE FROM env.debug, because this mutates the loaded
-- save: `env.debugHooks["item-satiety-write"] = true` in Scripts/palforge_dev.lua. What it
-- changes, and how each is put back:
--   block [3]  AddHPByRate(-0.1) on the PLAYER — about a tenth of your health. Undone with
--              FullRecoveryHP() (Pal.hpp:21141, zero arguments), which heals to FULL rather
--              than back to what it found; if you started damaged you end up healthier, and
--              the hook says so rather than claiming it restored anything.
--   block [4]  SetFullStomach(<a tenth of max away>) on the PLAYER, read back, then
--              SetFullStomach(<the value block [1] read>). That restore IS exact, and it only
--              happens at all if the declaration was read in block [2].
-- Nothing here touches a pal, an inventory or an item definition.
--
-- ONE BLOCK, NO WATCHERS. Everything this hook prints is inside the runner's
-- `#### BEGIN item-satiety-write` / `#### END item-satiety-write` brackets, so the whole answer
-- lifts out of UE4SS.log in one piece. It registers no native hook, starts no poller and asks
-- the operator for nothing, so it is finished when the END line prints and F9 is not refused
-- after it (compare the watcher hooks, which print further -1 / -2 blocks and hold the reload
-- guard open — test/hooks/init.lua:58-71).
--
-- A RUN OF NILS IS A RESULT, and which nils they are decides which:
--   * block [1] all nil        -> the individual parameter object could not be reached for the
--                                 player pawn. That is a statement about paramsOf on this build,
--                                 NOT about satiety, and it makes block [2]'s declaration the
--                                 only finding of the run.
--   * block [2] "UNWALKABLE"   -> the setter exists and this UE4SS build will not read its
--                                 parameter list. The item then stays open with a NAMED reason
--                                 (the UFunction property walk), which is a different and much
--                                 better state than "nobody has tried".
--   * block [2] "ABSENT"       -> the reflection listing and this build disagree, and the item
--                                 closes: there is no satiety setter to call.
local hooks = require("palforge.test.hooks")

-- The property classes core/signature refuses to marshal on anything short of a successful
-- walk, mirrored here (core/signature.lua:77-80) because this hook makes its own go / no-go
-- decision and must print WHY rather than let a refusal happen out of sight.
local UNVERIFIABLE = {
    StructProperty = true, ArrayProperty = true, MapProperty = true, SetProperty = true,
    DelegateProperty = true, MulticastDelegateProperty = true, TextProperty = true,
}

-- What arrived, and what number is inside it. A float getter answers a Lua number; GetHP answers
-- FFixedPoint64, so what arrives is the STRUCT and the number is behind its one `Value` field.
-- A struct RETURN is not the hazard a struct ARGUMENT is — nothing is being pushed — but it is
-- the difference between reading an HP and reading a wrapper, which is the same trap
-- RemoteUnrealParam set for the icon column (core/icons.lua, "0 of 1207 rows carry an icon").
local function numberOf(v)
    if type(v) == "number" then return v, "number" end
    if type(v) ~= "userdata" then return nil, type(v) end
    for _, field in ipairs({ "Value", "value" }) do
        local inner; pcall(function() inner = v[field] end)
        if type(inner) == "number" then return inner, "struct." .. field end
    end
    local s; pcall(function() s = v.ToString and v:ToString() end)
    return nil, "userdata(" .. tostring(s) .. ")"
end

-- Read one getter through core/signature — which refuses a name the build does not declare —
-- and print the raw shape beside the extracted number. `{}` as the expected list means "no
-- arguments to get wrong"; the check still refuses an absent function, which is the whole
-- protection a zero-argument call needs.
local function readNumber(h, sig, owner, fnName)
    if owner == nil then
        h:value(fnName .. "()", "no object to ask")
        return nil
    end
    local ok, ret, level = sig.call(owner, fnName, {})
    if not ok then
        h:value(fnName .. "()", "REFUSED or raised (evidence " .. tostring(level) .. ")")
        return nil
    end
    local n, shape = numberOf(ret)
    h:value(fnName .. "()", string.format("%s   [arrived as %s, evidence %s]",
        tostring(n), shape, tostring(level)))
    return n
end

-- THE PARAMETER WALK, PRINTED. Three outcomes and they are three different findings, so each
-- one is named: absent (no such function here), unwalkable (this build will not iterate a
-- UFunction's properties — the types are unread and nothing may be pushed), declared (the
-- running build stated its list and it is in the log).
--
-- Returns the ARGUMENT list — the walk with a trailing ReturnValue dropped, since the return
-- trails the parameters (core/signature.lua:229-231 relies on the same ordering) — and the
-- outcome name.
local function declaration(h, sig, owner, fnName)
    if owner == nil then
        h:value(fnName .. " declaration", "not read — no live object to ask")
        return nil, "no owner"
    end
    local fn, how = sig.find(owner, fnName)
    if not fn then
        h:value(fnName .. " declaration", "ABSENT — this build declares no such function here")
        return nil, "absent"
    end
    local params = sig.paramsOf(fn)
    if not params then
        h:value(fnName .. " declaration", string.format("PRESENT (%s) but UNWALKABLE — this "
            .. "UE4SS build will not iterate a UFunction's properties, so the parameter list "
            .. "was NOT read and nothing may be pushed at it", tostring(how)))
        return nil, "unwalkable"
    end
    local shape, args = {}, {}
    for i, p in ipairs(params) do
        shape[i] = string.format("%s:%s", tostring(p.name), tostring(p.kind))
        if not (i == #params and p.name == "ReturnValue") then args[#args + 1] = p end
    end
    h:value(fnName .. " declaration", string.format("DECLARED (%s) — [%s]",
        tostring(how), table.concat(shape, ", ")))
    return args, "declared"
end

hooks.declare{
    id     = "item-satiety-write",
    item   = "Open / Item",
    -- The marker says needs = { world = true }. `player` is declared as well because every read
    -- and every write below is taken off the PLAYER pawn's parameter object, and "no world" and
    -- "a world that has not finished spawning your character" are two different refusals that
    -- would otherwise both print as one.
    needs  = { world = true, player = true },
    writes = true,
    desc   = "what parameter list does the live build declare for SetFullStomach, and is the "
          .. "satiety / HP write reachable from Lua at all",
    run = function(h)
        local support   = require("palforge.test.support")
        local character = require("palforge.core.character")
        local sig       = require("palforge.core.signature")
        local probe     = require("palforge.test.probe")
        local uo        = require("palforge.core.uobject")

        --------------------------------------------------------------------
        h:section("[1] the two objects, and the four reads")
        --------------------------------------------------------------------
        local pawn = support.player()
        if not pawn then
            -- Unreachable: needs.player gated it. Kept because the world moves between the gate
            -- check and this line, and a nil here must not read as a measurement.
            h:fail("the player pawn that satisfied the gate is gone. Nothing was read and "
                .. "nothing was written.")
            return
        end
        h:value("player pawn", tostring(uo.fullName(pawn)))

        -- OBJECT ONE: the individual parameter object. Blocks [2] and [4] belong to it.
        local params = character.paramsOf(pawn)
        h:value("character.paramsOf(pawn)", probe.valid(params) and probe.full(params)
            or "nil — the individual parameter object could NOT be reached")
        if not probe.valid(params) then
            h:note("every VALUE below this line will be nil, and that is a finding about "
                .. "PalUtility::GetIndividualCharacterParameterByActor on this build rather "
                .. "than about satiety. Block [2] can still run: it asks the CLASS what it "
                .. "declares, not an instance what it holds.")
        end

        -- OBJECT TWO: the parameter COMPONENT on the actor. Block [3] belongs to it, and it is
        -- a different object from the one above — AddHPByRate is declared here and nowhere else
        -- (Pal.hpp:16016, class UPalCharacterParameterComponent).
        local comp
        pcall(function() comp = pawn.CharacterParameterComponent end)
        if not probe.valid(comp) then
            local okGet, got = sig.call(pawn, "GetCharacterParameterComponent", {})
            if okGet then comp = got end
        end
        h:value("pawn.CharacterParameterComponent", probe.valid(comp) and probe.full(comp)
            or "nil — the parameter component could not be read off the pawn")

        local fullStomach = readNumber(h, sig, params, "GetFullStomach")
        local maxStomach  = readNumber(h, sig, params, "GetMaxFullStomach")
        local maxHP       = readNumber(h, sig, params, "GetMaxHP")
        local hp          = readNumber(h, sig, params, "GetHP")
        local hpRate      = readNumber(h, sig, comp,   "GetHPRate")
        if fullStomach and maxStomach then
            h:pass("the satiety READ works on a live pawn: %s of %s. Whatever happens below, "
                .. "an item that wants to DISPLAY satiety is implementable today.",
                tostring(fullStomach), tostring(maxStomach))
        else
            h:note("satiety did not read. Nothing below can be attributed to the setter until "
                .. "this line says otherwise — a route that cannot read cannot be shown to write.")
        end
        if hp == nil and maxHP ~= nil then
            h:note("GetMaxHP answered and GetHP did not. That is the FFixedPoint64 return: the "
                .. "int32 comes back as a number and the struct does not, which is exactly the "
                .. "distinction this hook prints the arrival shape for.")
        end

        --------------------------------------------------------------------
        h:section("[2] THE OPEN QUESTION: what does this build declare for SetFullStomach")
        --------------------------------------------------------------------
        -- NOTHING IS CALLED IN THIS BLOCK. It is the walk and the printout, and it is the one
        -- fact the CXX dump cannot supply: the reflection listing has the NAME
        -- (02_reflection.txt:1298) and the C++ dump has no body for it.
        local owner = probe.valid(params) and params or nil
        if not owner then
            -- The class is askable even when no instance is: core/signature walks a UClass, a
            -- CDO or a live object alike (core/signature.lua:112-145).
            local cdo
            pcall(function() cdo = StaticFindObject("/Script/Pal.Default__PalIndividualCharacterParameter") end)
            if probe.valid(cdo) then
                owner = cdo
                h:note("no live parameter object, so the declaration is being read off the CDO "
                    .. "/Script/Pal.Default__PalIndividualCharacterParameter instead. That "
                    .. "answers the DECLARATION question in full; it is only the call in block "
                    .. "[4] that needs an instance.")
            end
        end

        local args, outcome = declaration(h, sig, owner, "SetFullStomach")
        -- The canonical [signature] line for the same function, so a reader following
        -- core/signature's own logging finds it next to this block's.
        if owner then sig.describe(owner, "SetFullStomach") end

        -- Two controls, described and NOT called. The first is the delegate this class fires on
        -- every satiety change; the second is the cheat-manager write. Both exist to put a
        -- second and third opinion about the VALUE TYPE in the same log block.
        declaration(h, sig, owner, "SetDecreaseFullStomachRates")
        local cm; pcall(function() cm = FindFirstOf("PalCheatManager") end)
        if probe.valid(cm) then
            declaration(h, sig, cm, "SetFullStomachToBaseCampPal")
            h:note("that cheat-manager entry is DESCRIBED ONLY and is never called here: it "
                .. "writes to every worker in a base camp at once, which is a far larger "
                .. "mutation than this hook is entitled to make.")
        end

        local structArg = nil
        for i, p in ipairs(args or {}) do
            if UNVERIFIABLE[p.kind] then structArg = string.format("parameter %d (%s:%s)",
                i, tostring(p.name), tostring(p.kind)) end
        end
        if outcome == "declared" then
            h:pass("THE DECLARATION IS READ, and this is the fact the item was missing: "
                .. "SetFullStomach takes %d argument(s) on this build.", #args)
        elseif outcome == "absent" then
            h:note("the reflection listing names SetFullStomach on this class "
                .. "(02_reflection.txt:1298) and the live build does not answer to it here. "
                .. "That closes the item in the negative: there is no satiety setter to call.")
        elseif outcome == "unwalkable" then
            h:note("the setter EXISTS and its parameter list is unreadable on this UE4SS build. "
                .. "The item stays open with a named reason — the UFunction property walk — "
                .. "which is a different state from `nobody has tried`, and it is the same wall "
                .. "core/spawn.lua's M.actor is behind.")
        else
            -- The fourth outcome, named rather than passed over: there was no object to ask at
            -- all. That is a statement about this SESSION — no live parameter object and no CDO
            -- — and nothing whatever about SetFullStomach.
            h:fail("neither a live UPalIndividualCharacterParameter nor its CDO could be "
                .. "reached, so the declaration was never asked for. This run measured nothing "
                .. "about the setter; it measured that this session could not find the class.")
        end

        --------------------------------------------------------------------
        h:section("[3] the ONE HP write that carries no struct: AddHPByRate(float)")
        --------------------------------------------------------------------
        -- Independent of everything above. It settles whether this SURFACE writes at all,
        -- whatever the satiety question turns out to be — and a float is the one argument on
        -- the whole HP surface that can be pushed without an unread struct.
        if not probe.valid(comp) then
            h:warn("no parameter component, so the one safe HP write could not be attempted. "
                .. "AddHPByRate is declared on UPalCharacterParameterComponent (Pal.hpp:16016) "
                .. "and NOT on the individual parameter object — asking the wrong object is how "
                .. "a present function reads as absent, so this is a miss, not an answer.")
        elseif hpRate ~= nil and hpRate < 0.3 then
            h:warn("REFUSING the -0.1 HP write: this character is at %s of full health and a "
                .. "tenth off the top is not a measurement worth taking on someone who is "
                .. "already hurt. Heal up and run it again.", tostring(hpRate))
        else
            declaration(h, sig, comp, "AddHPByRate")
            h:warn("ABOUT TO WRITE. The next call is AddHPByRate(-0.1) on YOUR CHARACTER — "
                .. "about a tenth of your health. It is put back with FullRecoveryHP() below.")
            local ok, _, level = sig.call(comp, "AddHPByRate", { "FloatProperty" }, -0.1)
            h:value("AddHPByRate(-0.1)", string.format("issued=%s evidence=%s",
                tostring(ok), tostring(level)))
            local after = readNumber(h, sig, params, "GetHP")
            local afterRate = readNumber(h, sig, comp, "GetHPRate")
            local dropped = (hp ~= nil and after ~= nil and after < hp)
                or (hpRate ~= nil and afterRate ~= nil and afterRate < hpRate)
            if ok and dropped then
                h:pass("THE HP WRITE LANDS. A plain float pushed at this surface changed a live "
                    .. "character's health and the read-back sees it. So the surface is not "
                    .. "dead — what blocks feeding and healing is the STRUCT argument on every "
                    .. "other entry, and nothing else.")
            elseif ok then
                h:fail("AddHPByRate was issued and the read-back shows no drop (%s -> %s, rate "
                    .. "%s -> %s). The call ran, so this is authority or a no-op rather than a "
                    .. "marshalling problem — the same shape as GetItem, which was `declared`, "
                    .. "issued, and moved nothing across five runs.",
                    tostring(hp), tostring(after), tostring(hpRate), tostring(afterRate))
            else
                h:note("the call was refused or raised; the [signature] line above names which. "
                    .. "A refusal here is core/signature doing its job, not a defect.")
            end

            -- THE UNDO, and it is not an exact one. FullRecoveryHP() heals to FULL.
            local okHeal = sig.call(params, "FullRecoveryHP", {})
            local healed = readNumber(h, sig, comp, "GetHPRate")
            h:value("FullRecoveryHP()", string.format("issued=%s, HP rate now %s",
                tostring(okHeal), tostring(healed)))
            h:note("FullRecoveryHP heals to MAXIMUM — it does not put back what was found. If "
                .. "you started this run damaged, you are now healthier than you were, and that "
                .. "is stated rather than described as a restore.")
        end

        --------------------------------------------------------------------
        h:section("[4] the satiety write, ONLY on a declaration this build actually stated")
        --------------------------------------------------------------------
        if outcome ~= "declared" then
            -- Each refusal says WHICH of the three it is. "not readable" and "not found" and
            -- "never asked" are three different findings and only one of them is about the game.
            local why = (outcome == "absent" and "not found on this build")
                or (outcome == "unwalkable" and "not readable on this build")
                or "never asked for — there was no object to ask"
            h:warn("REFUSING to call SetFullStomach: the parameter list was %s. A call written "
                .. "against a list nobody read is the one failure shape pcall cannot see, and "
                .. "it has closed this game before. The declaration in block [2] IS the finding "
                .. "of this run — it does not need a call to be worth writing down.", why)
        elseif structArg then
            h:warn("REFUSING to call SetFullStomach: the build declares %s, and a struct "
                .. "marshals BY LAYOUT. That is the same wall the FFixedPoint64 HP writes are "
                .. "behind, now measured rather than assumed — and it is a complete answer: an "
                .. "item cannot feed anyone from Lua on this build.", structArg)
        elseif #args ~= 1 then
            h:warn("REFUSING to call SetFullStomach: the build declares %d arguments and this "
                .. "hook only knows what ONE of them would mean. The list is printed above; the "
                .. "next run can be written against it, which is exactly what block [2] is for.",
                #args)
        elseif not (fullStomach and maxStomach and maxStomach > 0) then
            h:warn("REFUSING to call SetFullStomach: the declaration is readable and takes one "
                .. "%s, but block [1] could not read the CURRENT value, so there would be "
                .. "nothing to restore afterwards and nothing to compare against. A write with "
                .. "no read-back is the thing this tree keeps proving is worthless.",
                tostring(args[1].kind))
        else
            local kind = args[1].kind
            -- A tenth of maximum away from where it is, in whichever direction leaves the
            -- character fed. The exact value matters less than that it is DIFFERENT and that
            -- the original is known and put back.
            local target = fullStomach - maxStomach * 0.1
            if target < maxStomach * 0.05 then target = fullStomach + maxStomach * 0.1 end
            if target > maxStomach then target = maxStomach end
            h:warn("ABOUT TO WRITE. SetFullStomach(%s) on YOUR CHARACTER, declared as one %s by "
                .. "the walk above. The value this run found (%s) is restored immediately "
                .. "afterwards and read back.", tostring(target), tostring(kind),
                tostring(fullStomach))

            local ok, _, level = sig.call(params, "SetFullStomach", { kind }, target)
            local after = readNumber(h, sig, params, "GetFullStomach")
            h:value("SetFullStomach(target)", string.format("issued=%s evidence=%s",
                tostring(ok), tostring(level)))
            local moved = (after ~= nil and math.abs(after - fullStomach) > maxStomach * 0.01)
            if ok and moved then
                h:pass("⭐ THE SATIETY WRITE LANDS: %s -> %s on a live character. item-satiety-"
                    .. "write is answerable in the POSITIVE — an Item.Spec field that restores "
                    .. "satiety is implementable, and this log block is the declaration it "
                    .. "should be written against.", tostring(fullStomach), tostring(after))
            elseif ok then
                h:fail("SetFullStomach was issued against a declaration this build stated, and "
                    .. "the value did not move (%s -> %s). The call ran and reached nothing — "
                    .. "the same pattern as GetItem. An Item.Spec restore field would be a "
                    .. "promise this build does not keep.", tostring(fullStomach), tostring(after))
            else
                h:note("the call was refused or raised; the [signature] line above says which. A "
                    .. "refusal after a successful walk means the walk and the expected type "
                    .. "disagree, and the printed list is what to correct.")
            end

            local okBack = sig.call(params, "SetFullStomach", { kind }, fullStomach)
            local restored = readNumber(h, sig, params, "GetFullStomach")
            if okBack and restored ~= nil and math.abs(restored - fullStomach) <= maxStomach * 0.01 then
                h:pass("satiety put back to the value this run found (%s)", tostring(fullStomach))
            else
                h:fail("⚠️ SATIETY WAS NOT RESTORED. It was %s before this hook ran and reads %s "
                    .. "now. Eat something.", tostring(fullStomach), tostring(restored))
            end
        end

        --------------------------------------------------------------------
        h:section("[5] what this run means for the item surface")
        --------------------------------------------------------------------
        h:note("Item.Spec carries nine fields and not one of them is a restore amount, so a "
            .. "pack's food item logs and the bar moves only when the row it named was already "
            .. "a consumable. That is true today whatever this run said; what this run decides "
            .. "is whether it has to STAY true.")
        h:note("  block [4] PASSED -> the honest next step is an Item.Spec restore field routed "
            .. "through this call, written against the parameter list printed in block [2].")
        h:note("  block [4] REFUSED -> the item closes as a build limitation with a named "
            .. "cause, and native/items.lua's marker should quote the declaration line above "
            .. "rather than describing the gap in the abstract.")
        h:note("  block [3] passed while [4] refused -> the surface writes, and only the struct "
            .. "argument stands between a pack and a healing item. That also settles the same "
            .. "question core/spawn.lua's M.actor is waiting on, from a different direction.")
    end,
}
