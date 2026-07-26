-- palforge/test/cases/player.lua — the player facade: shape, arithmetic, live position.
--
-- Player is the one public module that is NOT a constructor: it defines nothing, so it is a
-- plain namespace of three readers over core/player. The structural half proves exactly that
-- (no __call, three functions, the Coord shape declared for the type generator) and pins the
-- offset arithmetic by standing in for core.location, so it is exact without a game. The rest
-- needs a world: coordinate/character only answer when a pawn exists, and the no-world case is
-- itself asserted — one of the two halves runs whichever state you are in, never neither.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local Player  = require("palforge.api.player")
local Pal     = require("palforge.api.pal")
local core    = require("palforge.core.player")
local schema  = require("palforge.core.schema")

local s = T.suite("player")

-- A live read can straddle a frame boundary, so a coordinate compared against a SECOND read
-- of the same pawn is only good to about a frame of travel (~33cm on a fast mount at 60fps).
-- Every live offset below is an order of magnitude larger than this window.
local EPS = 50.0

local function fieldOf(spec, name)
    for _, f in ipairs(spec.fields) do
        if f.name == name then return f end
    end
    return nil
end

--=============================================================================
-- structure — true with or without a game
--=============================================================================

s:test("the module is a plain namespace, not a callable constructor like every other domain", function(t)
    t:eq(getmetatable(Player), nil, "Player carries no metatable, so nothing can define through it")
    t:errors(function() return Player({ id = support.id("player") }) end,
        "attempt to call", "calling Player must be a Lua error, not a silent definition")

    -- The contrast that makes the claim worth asserting: the domain modules ARE constructors.
    local mt = getmetatable(Pal)
    t:type(mt and mt.__call, "function", "Pal{...} defines — Player deliberately does not")
end)

s:test("character, coordinate and coordinateOffset are its whole public surface", function(t)
    t:type(Player.character, "function", "Player.character must exist")
    t:type(Player.coordinate, "function", "Player.coordinate must exist")
    t:type(Player.coordinateOffset, "function", "Player.coordinateOffset must exist")

    local n = 0
    for k, v in pairs(Player) do
        n = n + 1
        t:type(v, "function", "Player." .. tostring(k) .. " should be a function")
    end
    t:eq(n, 3, "a fourth member means the facade grew and this suite has not caught up")
end)

s:test("the Coord shape is declared as three required numeric axes", function(t)
    local spec = schema.get("Coord")
    t:truthy(spec, "requiring api.player declares Coord for the type generator and schema.help")
    t:eq(spec.name, "Coord", "the shape is domain-less, so it is named without a prefix")
    t:eq(#spec.fields, 3, "Coord is exactly x, y, z")
    for _, axis in ipairs({ "x", "y", "z" }) do
        local f = fieldOf(spec, axis)
        t:truthy(f, "Coord declares " .. axis)
        t:eq(f and f.type, "number", "Coord." .. axis .. " is a number")
        t:eq(f and f.required, true, "Coord." .. axis .. " is required")
    end
    t:assert(not schema.help("Coord"):find("no spec named", 1, true),
        "schema.help('Coord') resolves rather than reporting an unknown name")
end)

s:test("coordinateOffset adds each requested delta to the player's position exactly", function(t)
    -- Stand in for the world read so the arithmetic is exact and testable at the title screen.
    -- Restore BEFORE asserting: a failed assertion raises, and a leaked stub would poison every
    -- later suite in the same run.
    local real = core.location
    core.location = function() return { x = 100.0, y = -250.0, z = 25.5,
                                        X = 100.0, Y = -250.0, Z = 25.5, 100.0, -250.0, 25.5 } end
    local ok, got = pcall(Player.coordinateOffset, 10.0, 20.0, -5.5)
    core.location = real

    t:assert(ok, "coordinateOffset must not raise: " .. tostring(got))
    t:type(got, "table", "an offset from a known point is a coordinate")
    t:near(got.x, 110.0, 0.001, "x is shifted by exactly dx")
    t:near(got.y, -230.0, 0.001, "y is shifted by exactly dy")
    t:near(got.z, 20.0, 0.001, "z is shifted by exactly dz")

    -- The aliases are not decoration: Pal:spawn reads `a.x or a[1]`, so both forms must survive
    -- the offset or spawning "near me" silently lands at the world origin.
    t:near(got.X, 110.0, 0.001, "the .X alias is offset too")
    t:near(got.Y, -230.0, 0.001, "the .Y alias is offset too")
    t:near(got.Z, 20.0, 0.001, "the .Z alias is offset too")
    t:near(got[1], 110.0, 0.001, "[1] is offset too")
    t:near(got[2], -230.0, 0.001, "[2] is offset too")
    t:near(got[3], 20.0, 0.001, "[3] is offset too")
end)

s:test("a missing delta counts as zero rather than raising", function(t)
    -- api/player.lua types dx/dy/dz as required, but core defaults them — fail-soft, and worth
    -- pinning because `coordinateOffset(0, 0, 200)` written as `coordinateOffset(nil, nil, 200)`
    -- by a generated call should still be a point and not an error.
    local real = core.location
    core.location = function() return { x = 1.0, y = 2.0, z = 3.0 } end
    local ok, got = pcall(Player.coordinateOffset)
    local ok2, up = pcall(Player.coordinateOffset, nil, nil, 200.0)
    core.location = real

    t:assert(ok, "coordinateOffset() with no arguments must not raise: " .. tostring(got))
    t:near(got.x, 1.0, 0.001, "no dx leaves x alone")
    t:near(got.y, 2.0, 0.001, "no dy leaves y alone")
    t:near(got.z, 3.0, 0.001, "no dz leaves z alone")
    t:assert(ok2, "a partial offset must not raise: " .. tostring(up))
    t:near(up.z, 203.0, 0.001, "the axis that was given still moves")
end)

s:test("with no world every entry point answers nil instead of raising", function(t)
    -- The mirror image of the live tests below: whichever state the run is in, one of the two
    -- halves is real coverage.
    if support.worldReady() then t:skip("a world is loaded; this asserts the no-world path") end

    t:eq(Player.character(), nil, "no pawn means no character")
    t:eq(Player.coordinate(), nil, "no pawn means no coordinate")
    t:eq(Player.coordinateOffset(10.0, 10.0, 10.0), nil, "an offset from nowhere is nowhere")
end)

--=============================================================================
-- live — needs a loaded world
--=============================================================================

s:test("coordinate returns the local player's position as numeric x, y, z", function(t)
    local pawn = support.needWorld(t)

    local c = Player.coordinate()
    t:type(c, "table", "a loaded world must yield a coordinate")
    t:type(c.x, "number", "x is a number")
    t:type(c.y, "number", "y is a number")
    t:type(c.z, "number", "z is a number")

    local here = support.location(pawn)
    t:truthy(here, "the pawn's location must be readable to compare against")
    if here then
        t:near(c.x, here.x, EPS, "it is the PLAYER's x, not some other actor's")
        t:near(c.y, here.y, EPS, "it is the PLAYER's y, not some other actor's")
        t:near(c.z, here.z, EPS, "it is the PLAYER's z, not some other actor's")
    end

    -- Each call builds a fresh table, so a caller that mutates one (spawn helpers do) cannot
    -- corrupt the next read.
    t:neq(Player.coordinate(), c, "every call returns a new table")
end)

s:test("a coordinate is also readable as X/Y/Z and [1],[2],[3], which is what Pal:spawn consumes", function(t)
    support.needWorld(t)

    local c = Player.coordinate()
    t:type(c, "table", "a loaded world must yield a coordinate")
    t:eq(c.X, c.x, "the .X alias mirrors x")
    t:eq(c.Y, c.y, "the .Y alias mirrors y")
    t:eq(c.Z, c.z, "the .Z alias mirrors z")
    t:eq(c[1], c.x, "[1] mirrors x")
    t:eq(c[2], c.y, "[2] mirrors y")
    t:eq(c[3], c.z, "[3] mirrors z")
end)

s:test("coordinateOffset shifts a live position by the amount asked for on every axis", function(t)
    support.needWorld(t)

    local base = Player.coordinate()
    local off  = Player.coordinateOffset(250.0, -750.0, 125.0)
    t:type(base, "table", "a loaded world must yield a coordinate")
    t:type(off, "table", "and an offset from it")

    -- Deltas, not absolutes: the two reads are microseconds apart but the pawn is free to move,
    -- and the offsets are far larger than a frame of travel.
    t:near(off.x - base.x, 250.0, EPS, "x moved by dx")
    t:near(off.y - base.y, -750.0, EPS, "y moved by dy")
    t:near(off.z - base.z, 125.0, EPS, "z moved by dz")
end)

s:test("character returns the valid local player pawn", function(t)
    support.needWorld(t)

    local actor = Player.character()
    t:truthy(actor, "a loaded world has a player character")
    t:assert(actor.IsValid and actor:IsValid(), "the returned actor must be live, not a stale UObject")

    -- Read the class name fail-soft: a session that will not hand it over is not a defect in
    -- this facade, so only assert when we actually got a name.
    local name
    pcall(function() name = actor:GetClass():GetFName():ToString() end)
    if type(name) == "string" and #name > 0 then
        t:assert(name:find("PalPlayerCharacter", 1, true) ~= nil,
            "character() must return a PalPlayerCharacter, got " .. name)
    end
end)

return s
