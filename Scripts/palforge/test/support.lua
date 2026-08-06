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
--     into a real action (an offset from a pawn that would really exist, a cheat-manager write
--     into the player's own technology state), so they need NO world. There are FOUR of them
--     across the suite — cases/player.lua, cases/building.lua, cases/events.lua and
--     cases/audio.lua — and they all ask the SAME question support.needWorld asks, so a gated
--     pair always has exactly one half running. Either spelling lands in the same summary
--     bucket; what does not is the bare t:skip, which is why a run inside a save once reported
--     "1 need no world, 9 did not say which" for what were then ten checks of one kind.
--   * And some cases need NO ENGINE AT ALL, which is a THIRD environment and not a stronger
--     form of the second. They assert what a call does when the UE4SS globals are simply not
--     there, and UE4SS being loaded is enough to falsify them — no save required. That is
--     support.needNoEngine(t, what), and it is the gate the first real in-game run
--     (2026-08-02) proved was missing: nine such checks were split between "no gate at all"
--     (four FAILED identically at the title screen and in a save) and "gated on an OWNER"
--     (six SKIPPED at the title screen, which was the one state they were written for,
--     because a PalPlayerController and a GameInstance are both up there).
--
--     THE THREE ENVIRONMENTS, and the one predicate that decides each:
--       headless           M.engine() == nil                    -> needNoEngine runs
--       engine, no world   M.engine() and not M.worldLoaded()   -> needNoWorld runs
--       engine and world   M.worldLoaded()                      -> needWorld runs
--
--     No two of them are ever true at once, which is why every skip carries a direction and
--     the summary says so (core/unittests: t:skipNeedsWorld / t:skipNeedsNoWorld /
--     t:skipNeedsNoEngine).
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
-- the three environments
--=============================================================================

-- ⚠️ IS THERE AN ENGINE UNDER THIS RUN? Asked of UE4SS's OWN GLOBALS, never of a pawn, an
-- owner, a controller or a UI root — that distinction is the whole of this block.
--
-- A game object is evidence about the WORLD; a global that only UE4SS injects is evidence about
-- the ENGINE, and the two are different axes. Measured 2026-08-02 at the title screen (16:39:05):
-- FindFirstOf("PalPlayerController") answers, widget.owner() answers with a GameInstance, and
-- there is no player pawn — so anything gated on an owner is gated on the engine while reading
-- as though it were gated on the world.
--
-- Every name below is injected by UE4SS into the Lua state and none of them exists in a plain
-- lua5.4 process. Any ONE of them is enough: a session that has FindFirstOf but somehow lacks
-- LoopAsync is still emphatically not headless, and requiring all of them would misreport such
-- a session as having no engine, which is the failure mode this predicate exists to prevent.
M.ENGINE_GLOBALS = { "FindFirstOf", "FindAllOf", "StaticFindObject", "FindObject",
                     "RegisterHook", "RegisterKeyBind", "LoopAsync", "ExecuteInGameThread",
                     "StaticConstructObject" }

---The name of the first UE4SS global found, or nil when this really is a bare Lua process.
---Returning the NAME rather than a boolean is deliberate: it is the evidence, and a skip that
---says "FindFirstOf is defined" is auditable in a way that "engine = true" is not.
---@return string?
function M.engine()
    for _, name in ipairs(M.ENGINE_GLOBALS) do
        if type(_G[name]) == "function" then return name end
    end
    return nil
end

-- THE ONE DEFINITION OF "A WORLD", and there is deliberately only one. Both halves of a gated
-- pair go through this call, so t:skipNeedsNoWorld is the exact negation of t:skipNeedsWorld and
-- exactly one of the two always runs.
--
-- It is the PLAYER PAWN. Not worldReady() — core/event's gate fails OPEN when LoopAsync is
-- absent (core/event.lua:1188-1196, "fail OPEN but loudly"), and measured 2026-08-02 in a plain
-- lua5.4 process event.start() reports isWorldReady() == true with no pawn anywhere. Not an
-- owner, a controller or a UI root either: all three are up on the title screen, so a gate built
-- on one of them closes BOTH directions at once — which is exactly what the 16:39:05 title-screen
-- run did, reporting "6 need no world" for the six checks that title screen existed to measure.
--
-- Returns the pawn (truthy) or nil, so a caller can use it as both the question and the answer.
function M.worldLoaded()
    return M.player()
end

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
    local pawn = M.worldLoaded()
    if not pawn then t:skipNeedsWorld("no world loaded") end
    return pawn
end

-- The inverse gate: skip when a world IS loaded. A case calls this when what it verifies is
-- a REFUSAL that only a MISSING PAWN produces — an offset from a player who is not there, a
-- cheat-manager write with no character to write to — and a loaded world would replace that
-- refusal with a real action against the player's session.
--
-- It asks M.worldLoaded(), the same call needWorld asks, so a gated PAIR is exactly
-- complementary: one of the two halves always runs and it is never both. `why` is optional and
-- is what the summary prints; giving it lets a case say what a loaded world would have DONE
-- without spelling the direction a second time, which is what four call sites outside this file
-- currently open-code as `if support.player() then t:skipNeedsNoWorld(...) end`.
--
-- ⚠️ IF THE REFUSAL IS ABOUT A MISSING ENGINE RATHER THAN A MISSING PAWN, this is the wrong
-- gate — use M.needNoEngine. "There is no owner", "there is no PlayerController", "there is no
-- LoadAsset" are all still true of a loaded world AND of the title screen, so a check that
-- asserts one of them can only run headless and gating it here makes it invisible in every
-- session instead of one.
function M.needNoWorld(t, why)
    if M.worldLoaded() then
        t:skipNeedsNoWorld(why or "a world is loaded; this asserts the no-world path")
    end
end

-- The THIRD gate: skip when there is an ENGINE at all. A case calls this when what it verifies
-- is the refusal PalForge produces with no UE4SS under it — resolveTexture with no LoadAsset,
-- keymap.refresh with no world subsystem to read, _widget.screen with no owner to construct
-- under — and where the presence of the engine, with or without a save, is enough to make the
-- claim false.
--
-- The skip names the environment rather than the missing thing, because that is the actionable
-- half: no key press in any session state runs these, only a headless lua5.4 run does.
--
--   support.needNoEngine(t, "LoadAsset exists, so the asset route would really resolve a texture")
--
---@param t table    # the assertion context
---@param what string?  # what the engine would DO instead of refusing
function M.needNoEngine(t, what)
    local global = M.engine()
    if global then
        t:skipNeedsNoEngine(string.format("UE4SS is loaded (%s is defined)%s. This check asserts "
            .. "the NO-ENGINE refusal path, so neither game state runs it — a loaded save and "
            .. "the title screen are equally wrong. Run the suite headless under lua5.4 to "
            .. "measure it.", global, what and (", so " .. what) or ""))
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
                pcall(om.unregister, otype, id)
                removed = removed + 1
            end
        end
    end

    -- THE SPEC REGISTRY IS A SECOND POPULATION, and until schema grew an `undefine` this sweep
    -- could not reach it: test/cases/schema declares eight namespaced specs per press (Inner,
    -- Spec, Dup, Derived, ReqDefault, FnDefault, Untyped, Checked — measured across two
    -- consecutive run()s rather than counted off the call sites) and every one of them stayed in
    -- the list schema.all() walks, for the life of the session. Inert, unlike a stray definition,
    -- because nothing dispatches per lookup over the spec list — but a `schema.all()` that grows
    -- by eight every time someone presses F1 is a thing that reads as a leak to whoever finds it
    -- next, and the docs print that list as "exactly what the game prints".
    --
    -- Namespaced the same way and swept the same way, so nothing real can be reached: a spec
    -- named by support.id() carries the palforge_test: prefix and a declared spec cannot.
    local schema = require("palforge.core.schema")
    if type(schema.undefine) == "function" then
        for _, spec in ipairs(schema.all()) do
            local name = type(spec) == "table" and spec.name or spec
            if M.isTestId(name) then
                if schema.undefine(name) then removed = removed + 1 end
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
-- the store's I/O seam, faked once
--
-- core/state talks to disk through eleven functions and nothing else, which is what makes it
-- testable with no filesystem at all. Three suites needed that fake and each wrote its own:
-- store_api's `fakeIO`, store_state's `fakeIO` and store_runtime's `memIO` were the same eleven
-- names three times, differing in two things that turn out to be options rather than designs —
-- whether a value is JSON round-tripped on the way through (which is what makes a codec defect
-- visible) and whether writes are counted. So it is one factory with two options now, and a
-- change to the seam is one edit instead of three.
--
-- The two DISK suites (store_disk, store_codec) deliberately keep their own harness: their whole
-- subject is real files on a real filesystem — rotation, a partial .tmp, an unreadable byte
-- sequence — and a fake that cannot lose a write cannot test any of it.
--
--   local io_, files, raw = support.storeIO()               -- values stored as-is
--   local io_, files, raw = support.storeIO{ json = true }  -- values encoded/decoded per put/get
--   io_.failWrite = "disk full"                             -- make every put fail, with that reason
--   io_.writes[key] / io_.reads[key]                        -- call counts, per key
--
-- `files` is the backing store (key -> value, or key -> { text = ... } in json mode) and `raw`
-- is where writeRaw / moveAside put things, both handed back so a check can look at what
-- actually landed rather than only at what the store says it did.
--=============================================================================

---@param opts table?   # { json = boolean }
---@return table io_, table files, table raw
function M.storeIO(opts)
    local json    = require("palforge.utils.json")
    local asJson  = opts and opts.json == true
    local files, raw = {}, {}
    local io_ = { files = files, raw = raw, reads = {}, writes = {} }

    function io_.get(key)
        io_.reads[key] = (io_.reads[key] or 0) + 1
        local f = files[key]
        if f == nil then return nil, "absent" end
        if not asJson then return f end
        local v, err = json.decode(f.text)
        if type(v) ~= "table" then return nil, err or "not a JSON object" end
        return v
    end

    function io_.put(key, value)
        if io_.failWrite then return false, io_.failWrite end
        if asJson then
            local text, err = json.encode(value)
            if not text then return false, tostring(err) end
            files[key] = { text = text }
        else
            files[key] = value
        end
        io_.writes[key] = (io_.writes[key] or 0) + 1
        return true
    end

    function io_.forget() end
    function io_.exists(key) return files[key] ~= nil end
    function io_.path(key)   return "<fake>/" .. tostring(key) .. ".json" end

    function io_.bytes(key)
        local f = files[key]
        if f == nil then return nil end
        return asJson and #f.text or 1
    end

    -- The SAME value moves across, never re-encoded: quarantine must preserve bytes verbatim,
    -- and a fake that re-serialises on the way would hide a codec that does not.
    function io_.moveAside(key, destKey)
        local f = files[key]
        if f == nil then return false, "absent" end
        raw[destKey] = f
        files[destKey] = f
        files[key] = nil
        return true
    end

    function io_.writeRaw(rel, text) raw[rel] = text; return true end
    function io_.existsRaw(rel)      return raw[rel] ~= nil end

    function io_.remove(key)
        if files[key] == nil then return false, "absent" end
        files[key] = nil
        return true
    end

    return io_, files, raw
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
