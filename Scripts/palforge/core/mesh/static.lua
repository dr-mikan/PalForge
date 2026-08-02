-- PalForge core.mesh.static: the `kind = "static"` mesh backend — a UE-authored
-- UStaticMesh asset hung on an actor through a UStaticMeshComponent we create at
-- runtime. Extends the base renderer.
--
-- Ported from the PROVEN procedural chain (core/mesh/procedural.lua — in-game verified
-- 2026-07-16 as the V5 runtime-mesh POC, shipped since in PalLogistics):
--   StaticFindObject(<component class>) -> AActor:AddComponentByClass(cls, false, {}, false)
--   -> fill the component -> MANDATORY SetWorldScale3D -> K2_SetRelativeLocation.
-- The scale call is not optional: the empty {} FTransform handed to AddComponentByClass
-- zero-initializes the relative scale, so a component nobody scales is invisible.
-- Collision stays off for the same reason as procedural — a decorative collider both
-- hitches and intercepts the build placement raycast.
--
-- The setter is no longer a guess. dumps/cxx/Engine.hpp:21720 declares, on
-- UStaticMeshComponent (:21687):
--
--     bool SetStaticMesh(class UStaticMesh* NewMesh);
--
-- One argument, an ObjectProperty, and a bool return — exactly the call below. The same
-- class listing also settles the read-back, in the opposite direction: there is NO
-- reflected `GetStaticMesh` anywhere in the 1579-header dump. The asset is reachable only
-- as the UProperty `UStaticMesh* StaticMesh` at Engine.hpp:21693 (offset 0x0580), which is
-- also what dumps/reflection reads off live actors. So meshOn() reads that one property
-- and nothing else — the getter it used to try first cannot exist.
--
-- attach still does not take the call on trust: it reads the asset back and reports
-- success only when it is really sitting there. On any failure the component we added is
-- destroyed again, so a build where the setter is ignored gets an honest false and no
-- orphaned component, not a mesh nobody rendered.
--
-- STILL UNOBSERVED: a correct signature is not a watched success. No run in either tree
-- has seen a UStaticMesh appear on a component this way, and the dump is one game patch
-- (2026-07-09 vs an exe of 2026-07-16) behind the installed binary, which is why the call
-- goes through core.signature and the read-back is kept.
--
-- MATERIAL: an authored UStaticMesh arrives with real materials on its slots, so unlike
-- the procedural section this component can be instanced directly — base/renderer's MID
-- layer does the work and the spec's color / texture / material / params reach it, which
-- is also what makes a later setColor (api/building's Class:update) able to re-tint a
-- structure. The MID is created lazily: an attach that declares no material leaves the
-- mesh's own look untouched until someone actually asks for a tint.
--
-- spec (from api/building:render / api/pal:renderOn):
--   { model = "<UStaticMesh object path>", scale = <number>, offset = { x, y, z },
--     color = { r,g,b,a }, texture = "<abs png>", material = "<base material path>",
--     params = { vector = {...}, scalar = {...}, texture = {...} } }
-- `asset` is accepted as an alias for `model`: this file's original TODO named the field
-- `asset` while every caller passes `model`.
local Renderer = require("palforge.core.mesh.base.renderer")
local assets   = require("palforge.core.mesh.assets")
local sig      = require("palforge.core.signature")
local uo       = require("palforge.core.uobject")
local log      = require("palforge.utils.log").scope("mesh")

local StaticMesh = Renderer:extend("StaticMeshRenderer")

-- The declared shape of UStaticMeshComponent::SetStaticMesh, in the order core.signature
-- checks it: `class UStaticMesh* NewMesh` is an ObjectProperty (dumps/cxx/Engine.hpp:21720).
-- Handing a live UObject to a UObject* parameter is the one argument kind core.signature
-- will pass on "present" evidence, so this call can still fire on a build whose UE4SS
-- cannot walk a UFunction's properties.
local SET_STATIC_MESH_PARAMS = { "ObjectProperty" }

-- Resolving `model` is core.mesh.assets' job now, and this backend asks it for a
-- "StaticMesh" specifically. The private six-line loadAsset that used to sit here took
-- anything at all and handed it to a typed setter — see that module's header for why the
-- class check matters more than the load does. core/mesh/assets.lua also carries the
-- KNOWN-GOOD /Game/... paths (assets.SM.ChestWood and friends), each measured off this build.
local ASSET_CLASS = "StaticMesh"

-- Read the mesh back off a component. ONE path, because the dump leaves only one: the
-- UProperty `class UStaticMesh* StaticMesh` (dumps/cxx/Engine.hpp:21693). This used to try
-- a `GetStaticMesh()` getter first; no such UFunction is declared on UStaticMeshComponent
-- (:21687) or anywhere else in dumps/cxx, so that branch could only ever raise and be
-- swallowed. Nil here is a "cannot tell", not a "not set".
local function meshOn(comp)
    local m
    pcall(function() m = comp.StaticMesh end)
    if m and m.IsValid and m:IsValid() then return m end
    return nil
end

-- Destroying a component we added is Renderer.destroyComponent — one implementation for
-- both component-adding backends, with the K2_DestroyComponent evidence beside it.
local destroyComponent = Renderer.destroyComponent

-- The component this backend created, per actor, so detach removes exactly what attach
-- added (and nothing that was already on the actor), and so base/renderer's setColor
-- knows which component to instance a material on.
--
-- KEYED ON core.uobject.key (the actor's full name), NOT on the actor handle — contract C1.
-- It was a `__mode="k"` table keyed on the handle, and UE4SS mints a fresh userdata wrapper
-- per lookup, so every entry was findable only by the one Lua value that created it. Three
-- of the four silent failures the audit found came out of this one line: detach(actor)
-- returned false and left the component on the pawn forever, attachOnce's guard missed the
-- same way, and the store below then OVERWROTE the record so the first component became
-- unreachable and could never be destroyed. Unbounded growth, no log line.
--
-- The record carries the handle, and the two things that used to be separate tables:
--   { actor = <freshest handle we were given>, comp = <the UStaticMeshComponent we added> }
-- There is no `dressed` flag any more. The once-guard now rests on a FACT that can be
-- re-read — is a component of ours still live on this actor — rather than on a boolean that
-- said only "we set this once", which is the same read-back discipline attach already uses
-- for the mesh setter.
local byActor = {}

-- The record for `actor`, re-validated, with its handle refreshed from the caller's fresher
-- one. A record whose component the engine has already destroyed is DROPPED: there is
-- nothing left to detach and nothing left to guard against.
local function recordFor(actor)
    local k = uo.key(actor)
    if not k then return nil, nil end
    local rec = byActor[k]
    if rec == nil then return nil, k end
    if not uo.live(rec.comp) then byActor[k] = nil; return nil, k end
    rec.actor = actor
    return rec, k
end

-- The component this backend dressed `actor` with (base/renderer contract). This is the
-- whole of what setColor needs: the base creates the MID on demand from it.
function StaticMesh:componentFor(actor)
    local rec = recordFor(actor)
    return rec and rec.comp or nil
end

-- Attach spec's UStaticMesh to `actor` on a component of our own.
-- Returns true only when the asset is confirmed to be sitting on that component; otherwise
-- false PLUS the English reason, which is the same string this logs. The reason is returned
-- as well as logged because a pack author who gets a bare `false` back from attachTo has to
-- go and read UE4SS.log to find out which of half a dozen things went wrong.
function StaticMesh:attach(actor, spec)
    if not (actor and spec) then return false, "static: no actor or no spec" end
    local model = spec.model or spec.asset
    if type(model) ~= "string" or #model == 0 then
        local why = "static: spec carries no model path"
        log.err(why)
        return false, why
    end
    -- THE PRIMARY ROUTE: a /Game/... path, loaded and class-checked. The error string is
    -- deliberately the resolver's own — it distinguishes "that path is not in the pak" from
    -- "that path IS an asset, just not a UStaticMesh", and the second one is the mistake a
    -- pack actually makes (naming an SK_ mesh with kind = "static", or the reverse).
    local asset, rerr = assets.load(model, { class = ASSET_CLASS })
    if not asset then
        local why = "static: " .. tostring(rerr)
        log.err(why)
        return false, why
    end

    -- NEVER STACK. A previous component of ours on this actor is destroyed before a new one
    -- is added, so a second attach cannot leave the first orphaned. That orphan is what the
    -- old code produced whenever the store was overwritten (which, keyed on a handle, was
    -- every time): the component stayed on the pawn with nothing left holding a reference to
    -- it, so no detach could ever reach it. Destroying it is logged, because "your mesh was
    -- replaced" is a thing an author wants to see when they did not expect a second attach.
    local prev = recordFor(actor)
    if prev then
        local gone = Renderer.destroyComponent(prev.comp)
        log.info("static: replacing the component a previous attach put on this actor"
            .. (gone and "" or " (K2_DestroyComponent did not fire, so the old one may still "
                .. "be on the pawn - core.signature has logged why)"))
    end

    local comp
    local ok, aerr = pcall(function()
        local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        assert(smcClass and smcClass:IsValid(), "StaticMeshComponent class not found")
        -- AddComponentByClass(TSubclassOf<UActorComponent> Class, bool bManualAttachment,
        -- const FTransform& RelativeTransform, bool bDeferredFinish) — Engine.hpp:8056.
        -- Four arguments, which is what the proven procedural chain already passes.
        comp = actor:AddComponentByClass(smcClass, false, {}, false)
        assert(comp and comp:IsValid(), "AddComponentByClass failed")
        -- bool SetStaticMesh(UStaticMesh* NewMesh) — Engine.hpp:21720. Through
        -- core.signature so the live class is asked before the argument is marshalled;
        -- the declared bool return says whether the engine accepted the mesh.
        local set, took = sig.call(comp, "SetStaticMesh", SET_STATIC_MESH_PARAMS, asset)
        assert(set, "SetStaticMesh did not fire (core.signature refused it, or it raised)")
        -- prove the setter took before anything downstream assumes it did: the bool it
        -- returns is the engine's opinion, the property is the fact.
        assert(meshOn(comp), "SetStaticMesh returned " .. tostring(took)
            .. " and the component's StaticMesh property is still empty")
        -- ECollisionEnabled::NoCollision = 0 (dumps/cxx/Engine_enums.hpp:777), passed to
        -- SetCollisionEnabled(TEnumAsByte<ECollisionEnabled::Type>) — one argument,
        -- Engine.hpp:19786. This is the WHOLE of switching collision off; the
        -- SetCollisionProfileName("NoCollision") that used to follow it has been removed,
        -- because Engine.hpp:19784 declares it SetCollisionProfileName(FName, bool) — two
        -- arguments, and an FName rather than a string. The one-argument call could never
        -- have run, and making it run correctly would mean marshalling a bare Lua string
        -- into an FName parameter, which is the shape that has killed this process before.
        pcall(function() comp:SetCollisionEnabled(0) end)
        -- SetWorldScale3D(FVector NewScale) — Engine.hpp:20408, one argument. Mandatory
        -- (the empty {} FTransform above zero-initialized the relative scale).
        local s = spec.scale or 1.0
        comp:SetWorldScale3D({ X = s, Y = s, Z = s })
        -- K2_SetRelativeLocation(FVector NewLocation, bool bSweep, FHitResult& SweepHitResult,
        -- bool bTeleport) — Engine.hpp:20428. Four arguments, which is what is passed here;
        -- the {} stands in for the out FHitResult.
        local o = spec.offset or {}
        comp:K2_SetRelativeLocation({ X = o.x or 0, Y = o.y or 0, Z = o.z or 0 }, false, {}, false)
    end)
    if not ok then
        destroyComponent(comp)   -- never leave a half-dressed component behind
        local why = "static: attach failed: " .. tostring(aerr)
        log.err(why)
        return false, why
    end
    -- File the component under the actor's NAME. A nil key means the actor would not answer
    -- GetFullName, which is not a reason to refuse an attach that has already succeeded — it
    -- only means detach and setColor will have no record to find, and the log line says so
    -- rather than leaving that a surprise.
    local k = uo.key(actor)
    if k then
        byActor[k] = { actor = actor, comp = comp }
    else
        log.warn("static: the mesh is attached but this actor would not answer GetFullName, "
            .. "so nothing was recorded - detach and setColor will find no record for it")
    end
    -- Material layer, AFTER the mesh is confirmed: fail-soft and never able to undo the
    -- attach, but no longer silently dropped the way it was when only the procedural
    -- backend could paint. `always` is off — the mesh's authored materials stay as they
    -- are unless the spec asked for something.
    local st = self:dressMaterial(comp, actor, spec, {})
    -- ALWAYS logged, not only when a material was written. Two questions used to be
    -- indistinguishable in a log — "did the path resolve" and "did the component take it" —
    -- and the read-back above has already answered the second by the time this runs, so one
    -- line naming the resolved object closes both. assets.describe prints the class, which is
    -- what makes a wrong-kind declaration obvious on sight.
    log.info(string.format("static: %s on a new UStaticMeshComponent%s",
        assets.describe(asset), st ~= "none" and (" material [" .. st .. "]") or ""))
    return true
end

-- Attach once per actor (guards against re-stacking). The global ENABLED kill-switch
-- lives on the facade (core.mesh); this backend only owns the per-actor guard.
--
-- The guard reads the record, whose liveness recordFor has just re-checked, so "already
-- dressed" means "a component this backend created is still on this actor" rather than "a
-- flag was set once". The separate `dressed` boolean table this used to keep is gone: it was
-- keyed on the actor handle like everything else here, so it missed on every second call and
-- the stacking it existed to prevent happened anyway.
function StaticMesh:attachOnce(actor, spec)
    if not (actor and spec) then return false, "static: no actor or no spec" end
    if recordFor(actor) then return true end
    return self:attach(actor, spec)
end

-- Destroy the component this backend added to `actor`, so attach can dress it again.
-- Returns false when we added nothing, and when the destroy call did not execute — in
-- that second case the bookkeeping is deliberately LEFT in place, because the component
-- is still on the actor and the once-guard is the only thing stopping a second one.
function StaticMesh:detach(actor)
    if not actor then return false, "static: no actor" end
    -- recordFor drops a record whose component is already gone, so the two cases the old
    -- code spelled separately — "no record" and "the record's component was torn down under
    -- us" — arrive here as one, and both are an honest "this call removed nothing". The
    -- material bookkeeping is still cleared in the second case, which is why forgetMaterial
    -- runs on the miss too.
    local rec, k = recordFor(actor)
    if not rec then
        if k then self:forgetMaterial(actor) end
        return false, "static: nothing of PalForge's is recorded on this actor to remove"
    end
    if not destroyComponent(rec.comp) then
        local why = "static: detach failed (K2_DestroyComponent did not fire - core.signature "
            .. "has logged whether it was refused or raised)"
        log.warn(why)
        -- the bookkeeping is deliberately LEFT in place: the component is still on the actor
        -- and the once-guard is the only thing stopping a second one
        return false, why
    end
    -- the whole component goes with it, so there is no material to put back
    self:forgetMaterial(actor)
    byActor[k] = nil
    return true
end

return StaticMesh
