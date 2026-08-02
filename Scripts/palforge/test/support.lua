-- palforge/test/support.lua — the shared helpers every case file uses.
--
-- These tests run INSIDE the game, so two things matter that a headless suite never
-- has to think about:
--
--   * Most of the api needs a loaded world. A case that touches the world calls
--     support.needWorld(t) first, which SKIPS the test (not fails it) when there is no
--     player pawn — so the same suite is green at the title screen and meaningful in a
--     save. Nothing here throws on a missing engine global.
--   * Some cases are the INVERSE: they verify a refusal path that a loaded world would turn
--     into a real action (a widget that would really draw, an offset from a pawn that would
--     really exist), so they need NO world. There are TEN of them across the suite and they
--     reach the gate two ways: support.needNoWorld(t) here (cases/player.lua), and a direct
--     t:skipNeedsNoWorld where the case wants to say something specific about what a loaded
--     world would have DONE (cases/ui.lua's skipNeedsNoGame covers six; building, events and
--     audio one each). Either spelling lands in the same summary bucket — what does not is the
--     bare t:skip, which is what those nine used to call, and which is why a run inside a save
--     once reported "1 need no world, 9 did not say which" for ten checks of one kind. The two
--     sets cannot both run in one press, which is why every skip carries a direction and the
--     summary says so (core/unittests: t:skipNeedsWorld / t:skipNeedsNoWorld).
--   * A run must not leave content behind. Ids come from support.id(), which mixes in a
--     per-run counter, so running the suite ten times never collides with itself, and
--     support.sweepAfter(s) hands the suite back its own teardown so the throwaway
--     definitions go out as soon as that suite finishes rather than at the end of the run.
local log = require("palforge.utils.log").scope("test")
local uo  = require("palforge.core.uobject")

local M = {}

--=============================================================================
-- reporting
--=============================================================================

-- Put a line on the player's screen as well as in UE4SS.log — an in-game test you have
-- to alt-tab to read is an in-game test you stop running. Silent no-op with no world.
function M.announce(msg)
    pcall(function()
        local util   = StaticFindObject("/Script/Pal.Default__PalUtility")
        local player = FindFirstOf("PalPlayerCharacter")
        if util and util:IsValid() and player and player:IsValid() then
            util:SendSystemAnnounce(player, "[PalForge] " .. tostring(msg))
        end
    end)
end

function M.log(msg) log.info(msg) end

--=============================================================================
-- world access
--=============================================================================

-- The local player pawn, or nil. Never throws, even with no engine at all.
function M.player()
    local pawn
    pcall(function() pawn = FindFirstOf("PalPlayerCharacter") end)
    if pawn and pawn.IsValid and pawn:IsValid() then return pawn end
    return nil
end

-- Is there a world to act on? core/event's gate is the authority once it is running;
-- the pawn check covers the moment before the ready watch has settled.
function M.worldReady()
    local ok, ready = pcall(function() return require("palforge.core.event").isWorldReady() end)
    if ok and ready then return true end
    return M.player() ~= nil
end

-- Skip the current test unless a world is loaded. Returns the player pawn so a case can
-- write `local pawn = support.needWorld(t)`. The skip is directed (NEEDS.WORLD), so the
-- summary can say how many checks are waiting on a save rather than just "N skipped".
function M.needWorld(t)
    local pawn = M.player()
    if not pawn then t:skipNeedsWorld("no world loaded") end
    return pawn
end

-- The inverse gate: skip when a world IS loaded. A case calls this when what it verifies is
-- a REFUSAL — the path taken because there is no pawn, no controller, no owner — and a loaded
-- world would replace that refusal with a real action against the player's session. These are
-- the checks that never run in the state a tester is usually in, which is exactly why they
-- have to be counted separately.
--
-- It asks M.player(), the same question needWorld asks, so a gated PAIR is exactly
-- complementary: one of the two halves always runs and it is never both. Deliberately NOT
-- worldReady(): core/event's gate fails OPEN when LoopAsync is absent (core/event.lua:1188-
-- 1196 — "fail OPEN but loudly"), and a session with no engine at all is precisely the one
-- where the no-world half is the only half that can run. Measured 2026-08-02 in a plain lua5.4
-- process: event.start() reports isWorldReady() == true with no pawn anywhere, so a worldReady
-- gate would have skipped both halves and measured nothing.
function M.needNoWorld(t)
    if M.player() then
        t:skipNeedsNoWorld("a world is loaded; this asserts the no-world path")
    end
end

-- Skip unless the named engine global exists (LoopAsync, FindAllOf, ...). Some sessions
-- and some hosts do not expose all of them. Directed as SESSION: pressing the key again in
-- another state will not conjure the global, so the skip text is itself the finding.
function M.needGlobal(t, name)
    if type(_G[name]) ~= "function" then
        t:skipUnanswerable(name .. " unavailable this session")
    end
end

-- An actor's world location as { x, y, z }, or nil.
function M.location(actor)
    if not (actor and actor.IsValid and actor:IsValid()) then return nil end
    local ok, loc = pcall(function()
        return (actor.K2_GetActorLocation and actor:K2_GetActorLocation()) or actor:GetActorLocation()
    end)
    if ok and loc then return { x = loc.X, y = loc.Y, z = loc.Z } end
    return nil
end

-- A point `dist` cm in front of the player and `up` cm above it — where a spawn test puts
-- things so they are visibly not on top of you. nil with no world.
function M.inFront(dist, up)
    local pawn = M.player()
    if not pawn then return nil end
    local here = M.location(pawn)
    if not here then return nil end

    local fwd; pcall(function() fwd = pawn:GetActorForwardVector() end)
    local fx, fy = (fwd and fwd.X) or 1.0, (fwd and fwd.Y) or 0.0
    local mag = math.sqrt(fx * fx + fy * fy)
    if mag < 0.01 then fx, fy, mag = 1.0, 0.0, 1.0 end

    return { x = here.x + (fx / mag) * (dist or 600.0),
             y = here.y + (fy / mag) * (dist or 600.0),
             z = here.z + (up or 50.0) }
end

-- The PalCharacter closest to a coordinate, with its distance: { actor, pos, dist, count }.
-- Used to prove a spawn really landed where it was asked to. nil when nothing is findable.
function M.nearestPal(coord)
    local ok, all = pcall(FindAllOf, "PalCharacter")
    if not (ok and type(all) == "table") then return nil end

    local best, bestDist, count = nil, nil, 0
    for _, actor in ipairs(all) do
        local pos = M.location(actor)
        if pos then
            count = count + 1
            local dx, dy, dz = pos.x - coord.x, pos.y - coord.y, pos.z - coord.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if not bestDist or d < bestDist then best, bestDist = { actor = actor, pos = pos }, d end
        end
    end
    if not best then return nil end
    best.dist, best.count = bestDist, count
    return best
end

-- The nearest live PAL, or nil when there is none nearby. Returns the actor and its class name,
-- because which class it is turns out to matter.
--
-- ⚠️ NOT FindAllOf("PalCharacter"). That was the first attempt and it is too wide: the hierarchy
-- is APalMonsterCharacter : APalNPC : APalCharacter (dumps/cxx/Pal.hpp:10167, 10195, 8956), so
-- "PalCharacter" also matches villagers, merchants and every other NPC — none of which has an
-- equipped move. A run against one of those reports zero moves and looks exactly like a broken
-- read; that is what "0 active, 0 passive, 0 equipable, 0 mastered" almost certainly was.
-- PalMonsterCharacter is the pal itself and is what a move question has to be asked of.
function M.nearbyPal()
    local pawn = M.player()
    if not pawn then return nil end
    local here = M.location(pawn)
    if not here then return nil end

    local ok, all = pcall(FindAllOf, "PalMonsterCharacter")
    if not (ok and type(all) == "table") then return nil end

    local best, bestDist
    for _, actor in ipairs(all) do
        -- uo.same, never `actor ~= pawn` (contract C1). UE4SS mints a fresh userdata wrapper
        -- per lookup, so the player pawn read by M.player() and the same pawn arriving in this
        -- FindAllOf list are two different Lua values and `~=` is true for both of them. The
        -- exclusion is defensive rather than load-bearing — APalPlayerCharacter does not
        -- derive from APalMonsterCharacter, so the player should not be in this list at all —
        -- but a guard that cannot fire is worse than no guard, because it reads as one.
        if not uo.same(actor, pawn) then
            local pos = M.location(actor)
            if pos then
                local dx, dy, dz = pos.x - here.x, pos.y - here.y, pos.z - here.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if not bestDist or d < bestDist then best, bestDist = actor, d end
            end
        end
    end
    if not best then return nil end
    local cls; pcall(function() cls = best:GetClass():GetFName():ToString() end)
    return best, cls or "?"
end

--=============================================================================
-- test data
--=============================================================================

local counter = 0

-- A definition id that is unique across every run in this session, so re-running the
-- suite never re-registers over its own previous content.
--   support.id("pal")  -->  "palforge_test:pal_1"
function M.id(name)
    counter = counter + 1
    return string.format("palforge_test:%s_%d", name or "obj", counter)
end

-- The prefix every id from M.id() carries, for callers that want to sweep them up.
M.NAMESPACE = "palforge_test"

-- Is this id one of ours? Ids are namespaced, so nothing here can touch real content.
function M.isTestId(id)
    return type(id) == "string" and id:sub(1, #M.NAMESPACE + 1) == M.NAMESPACE .. ":"
end

-- Un-register everything this suite defined. Defining is permanent — object_manager has
-- no expiry — so without this, pressing the key ten times would leave ten runs' worth of
-- throwaway definitions in the live registry that core/event then walks on every scan.
-- Only ids in our own namespace are touched, so real content can never be swept.
--
-- REMOVAL IS om.unregister(otype, id), which now exists and reports whether anything was
-- there. Until it did, the only way to take an id back out was to spell the removal as a
-- registration of nil — register(otype, id, nil) writes nil into the bucket, which does
-- delete the entry, but it reads as a definition call and it answers nil the same way an
-- ERROR return does, so a real failure was indistinguishable from success. The explicit call
-- is what this sweep asks for; the old spelling is kept as a fallback because this file is
-- also the harness a content pack copies, and it should not break against an older tree.
---@return integer removed
function M.sweep()
    local om = require("palforge.core.object_manager")
    local removed = 0
    for _, otype in ipairs(om.TYPES) do
        for id in pairs(om.all(otype)) do          -- all() is a snapshot, safe to mutate under
            if M.isTestId(id) then
                pcall(function()
                    if type(om.unregister) == "function" then om.unregister(otype, id)
                    else om.register(otype, id, nil) end
                end)
                removed = removed + 1
            end
        end
    end
    return removed
end

-- Give a suite its own teardown, so it hands back what it registered the moment IT finishes
-- instead of leaving every id in the registry until the whole run ends.
--
-- Why per-suite and not just once at the end: the API suite defines on the order of two
-- hundred throwaway ids per press (test/init.lua's own log line has read "swept 217 test
-- definition(s)"), and every one of them sits in the bucket that namespaced dispatch walks
-- per missed lookup while the REST of the run is still executing. Sweeping per suite keeps
-- that population to one suite's worth.
--
-- The sweep is namespace-wide rather than per-suite because ids carry no suite tag; that is
-- safe in run order — a suite that has finished cannot need its ids again, and no case file
-- defines content at module scope (checked 2026-08-02: every support.id() call in
-- test/cases/ is inside a test body).
---@param s table   # the suite returned by T.suite(name)
---@return table s
function M.sweepAfter(s)
    s:after(function(suite)
        local removed = M.sweep()
        if removed > 0 then
            log.info(string.format("swept %d test definition(s) after [%s]", removed, suite.name))
        end
    end)
    return s
end

--=============================================================================
-- game ids the suites lean on
--
-- Real rows from the native catalogs, so a live check exercises content the game
-- actually has rather than something invented here.
--=============================================================================

M.GAME = {
    pal      = "ChickenPal",
    pal2     = "SheepBall",
    item     = "Wood",
    consume  = "Berries",
    building = "WorkBench",
    palbox   = "PalBoxV2",
    bgm      = "AKE_BGM_Title",
}

return M
