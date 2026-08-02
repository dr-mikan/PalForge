-- palforge/test/cases/events.lua — core/event as a bus, driven entirely by hand.
--
-- Almost everything here is pure: the suite subscribes and emits itself rather than waiting
-- for the game's heartbeat, so the file is as green at the title screen as it is in a save and
-- takes the same wall-clock time either way. Only two claims lean on a world at all — the ready
-- gate (which opens after the ready-watch has seen a player pawn five times, so with no pawn it
-- must still be shut) and the building-instance views, which simply have nothing to show until
-- something is placed. Private channel names come from support.id(), so a handler that an
-- aborted run left attached is unreachable by the next one; the real channels are borrowed for
-- a single emit and released inside the same test. world.ready and world.left are the
-- exception: their dispatch fires a lifecycle hook on every live building, and lying to
-- someone's save about the world unloading is not this suite's business — in a loaded world
-- they get the structural check only.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local event   = require("palforge.core.event")

local s = T.suite("events")

-- Channels whose DISPATCH reaches live player content on any payload at all. Everything else
-- resolves through ctx.key / ctx.actor / ctx.itemId / ctx.buildId / ctx.skillId, so an inert
-- marker payload dispatches to nothing — including the four skill.* channels added in
-- 2026-07, which key on ctx.skillId and no-op without one. (tick is deliberately NOT in here:
-- one extra heartbeat is indistinguishable from the 500 ms one the game already sends, and
-- event.every can only be exercised through it.)
local LIVE_HOOKS = { ["world.ready"] = true, ["world.left"] = true }

-- Emit `n` heartbeats. pcall'd because a live session has other subscribers on this channel and
-- one of them throwing is not what the test under way is measuring; rx fans out
-- newest-subscriber-first, so ours has already been served by then.
local function ticks(n)
    for i = 1, n do pcall(event.emit, "tick", { count = i, now = 0 }) end
end

s:test("every name in event.CHANNELS has a pre-created subject that delivers subscribe-before-emit", function(t)
    t:assert(#event.CHANNELS > 0, "the channel list must not be empty")

    -- Results are collected and asserted after the loop so a broken channel cannot leave the
    -- next one's subscription attached to a live game.
    local missing, undelivered = {}, {}
    for _, name in ipairs(event.CHANNELS) do
        local subj = event.observable(name)
        if type(subj) ~= "table" or type(subj.observers) ~= "table" or event.channel(name) ~= subj then
            missing[#missing + 1] = name
        else
            local payload, got = { marker = name }, nil
            local sub = event.on(name, function(ctx) got = ctx end)
            if not (LIVE_HOOKS[name] and support.worldReady()) then
                pcall(event.emit, name, payload)
                if got ~= payload then undelivered[#undelivered + 1] = name end
            end
            sub:unsubscribe()
        end
    end

    t:eq(#missing, 0, "channels with no shared subject: " .. table.concat(missing, ", "))
    t:eq(#undelivered, 0, "channels that dropped a subscribe-before-emit: " .. table.concat(undelivered, ", "))
end)

s:test("on() receives exactly the payload emit() sent, by reference", function(t)
    local ch = support.id("chan")
    local got, calls = "unset", 0
    local sub = event.on(ch, function(ctx) got, calls = ctx, calls + 1 end)

    local payload = { n = 1 }
    event.emit(ch, payload)
    t:eq(calls, 1, "one emit, one call")
    t:eq(got, payload, "the ctx is the very table emit was handed, not a copy of it")

    -- world.left and world.ready are emitted with no payload at all; the handler still runs.
    got = "unset"
    event.emit(ch)
    t:eq(calls, 2, "a payload-less emit still notifies")
    t:eq(got, nil, "…with nil")

    sub:unsubscribe()
end)

s:test("unsubscribing the returned subscription stops delivery, and doing it twice is harmless", function(t)
    local ch = support.id("chan")
    local seen = {}
    local sub = event.on(ch, function(v) seen[#seen + 1] = v end)

    event.emit(ch, "one")
    t:eq(#seen, 1, "delivered while subscribed")

    sub:unsubscribe()
    event.emit(ch, "two")
    t:eq(#seen, 1, "nothing arrives after unsubscribe")

    sub:unsubscribe()
    event.emit(ch, "three")
    t:eq(#seen, 1, "a second unsubscribe is a no-op, not a resubscribe or an error")
end)

s:test("channel() and observable() are one and the same subject, operators included", function(t)
    local ch = support.id("chan")
    local subj = event.channel(ch)
    t:eq(event.observable(ch), subj, "observable() is a read-side alias, not a second subject")

    local seen = {}
    local sub = event.observable(ch)
        :filter(function(ctx) return ctx.keep end)
        :subscribe(function(ctx) seen[#seen + 1] = ctx.n end)

    event.emit(ch, { n = 1, keep = false })
    event.emit(ch, { n = 2, keep = true })
    t:eq(#seen, 1, "the chain is fed by emit(), and the filter is what decides")
    t:eq(seen[1], 2, "the kept payload is the one that arrived")

    sub:unsubscribe()
    event.emit(ch, { n = 3, keep = true })
    t:eq(#seen, 1, "disposing the chain detaches it from the subject")
end)

s:test("a channel name is required — an empty or non-string name is a hard error", function(t)
    t:errors(function() event.channel("") end, "event: channel name required")
    t:errors(function() event.on(nil, function() end) end, "event: channel name required")
    t:errors(function() event.emit(42, {}) end, "event: channel name required")
end)

s:test("the heartbeat interval is 500 ms", function(t)
    t:eq(event.TICK_MS, 500, "every() counts in whole TICK_MS steps, so this number is load-bearing")
end)

s:test("every(ms) returns a disposer that fires once per ms of accumulated tick time", function(t)
    local fired, mark = 0, {}
    local off = event.every(event.TICK_MS * 2, function() fired = fired + 1 end)
    local disposable = type(off) == "table" and type(off.unsubscribe) == "function"

    ticks(1); mark[1] = fired
    ticks(1); mark[2] = fired
    ticks(2); mark[3] = fired
    if disposable then off:unsubscribe() end
    ticks(4); mark[4] = fired

    -- Assert only once the tick channel is ours-free again: a failure here must not leave a
    -- handler running in someone's game.
    t:truthy(disposable, "every() returns a subscription with :unsubscribe()")
    t:eq(mark[1], 0, "one heartbeat is only half of a 1000 ms interval")
    t:eq(mark[2], 1, "the second heartbeat completes it")
    t:eq(mark[3], 2, "the accumulator resets, so the next call takes two more")
    t:eq(mark[4], 2, "a disposed every() stops counting entirely")
end)

s:test("every() is quantized to the heartbeat — a sub-tick interval still fires once per tick", function(t)
    local fired, mark = 0, {}
    local off = event.every(1, function() fired = fired + 1 end)   -- 1 ms: far below TICK_MS

    ticks(3); mark[1] = fired
    off:unsubscribe()
    ticks(3); mark[2] = fired

    t:eq(mark[1], 3, "three heartbeats, three calls — never more, whatever the interval asks for")
    t:eq(mark[2], 3, "and none after disposal")
end)

s:test("every() rejects a non-positive interval and a missing callback", function(t)
    t:errors(function() event.every(0, function() end) end, "event.every(ms>0, fn)")
    t:errors(function() event.every(-500, function() end) end, "event.every(ms>0, fn)")
    t:errors(function() event.every("500", function() end) end, "event.every(ms>0, fn)")
    t:errors(function() event.every(500) end, "event.every(ms>0, fn)")
end)

s:test("a throwing every() callback is contained and leaves the tick channel working", function(t)
    local seen = 0
    -- ORDER MATTERS: rx fans out newest-subscriber-first, so the plain observer has to be
    -- attached BEFORE the throwing every() for this to prove anything at all.
    local observer = event.on("tick", function() seen = seen + 1 end)
    local bad = event.every(event.TICK_MS, function() error("every() callback exploded") end)

    local ok = pcall(event.emit, "tick", { count = 1, now = 0 })
    bad:unsubscribe(); observer:unsubscribe()

    t:truthy(ok, "every() pcalls its callback, so the emit itself survives it")
    t:eq(seen, 1, "and the subscriber sitting behind it still got the heartbeat")
end)

s:test("a handler that throws escapes emit() but does not break the channel", function(t)
    local ch = support.id("chan")
    local seen = {}
    local quiet = event.on(ch, function(v) seen[#seen + 1] = v end)
    local boom  = event.on(ch, function() error("handler exploded") end)

    -- The bus does NOT sandbox its handlers: rx's Subject calls them straight, so the error
    -- comes back out of emit() and the observers below the thrower (subscribed earlier — the
    -- fan-out is newest-first) are skipped for that one emit. Asserted as it behaves today; a
    -- pcall around the fan-out would change both of these lines.
    local ok = pcall(event.emit, ch, "one")
    t:falsy(ok, "the handler's error propagates to whoever called emit()")
    t:eq(#seen, 0, "the subscriber underneath it never saw that emit")

    boom:unsubscribe()
    event.emit(ch, "two")
    t:eq(#seen, 1, "the subject was not stopped: the channel keeps delivering afterwards")
    t:eq(seen[1], "two", "…and delivers the new payload, not a replay")

    quiet:unsubscribe()
end)

s:test("isWorldReady() answers with a boolean and is safe to ask at any time", function(t)
    local ok, ready = pcall(event.isWorldReady)
    t:truthy(ok, "the gate must be readable before, during and after a world")
    t:type(ready, "boolean", "it is the raw gate flag, not a truthy proxy")
end)

s:test("the ready gate is shut while there is no player pawn", function(t)
    -- The gate only opens after five consecutive polls that found a pawn, so its being open
    -- with no pawn at all would mean the ready-watch failed open (LoopAsync unavailable).
    --
    -- INVERSE-GATED: this needs NO world, where almost everything else in the suite needs one.
    -- The skip reason says which DIRECTION it skipped in, because the summary line counts
    -- skips without saying so and "N skipped" reads as "N things are broken" when it actually
    -- means "run this suite once at the title screen as well". This is one of TEN such checks
    -- (it read "nine" until the tenth was counted), and it goes through skipNeedsNoWorld rather
    -- than the bare t:skip so the summary's bucket agrees with the sentence above.
    if support.player() then
        t:skipNeedsNoWorld("a world IS loaded, so a SHUT ready gate cannot be observed — run "
            .. "the suite once at the title screen to cover this direction")
    end
    -- AND it needs a ready-watch that could arm. core/event's installWorldSource fails OPEN
    -- when LoopAsync is absent — it says so in a log line and sets gate.ready = true, so
    -- dispatch keeps working at the cost of the load-storm guard (core/event.lua, "fail OPEN
    -- but loudly"). test/support.lua records the measurement: in a plain lua5.4 process
    -- event.start() reports isWorldReady() == true with no pawn anywhere. test/cases/item.lua
    -- calls event.start() to get the item dispatch it needs, so in a headless run of the whole
    -- suite this assertion was reading the fail-open flag rather than the gate, and failing —
    -- for a reason that says nothing about the gate. With no LoopAsync there is no ready-watch
    -- and therefore no shut gate to observe, which is UNANSWERABLE this session rather than a
    -- direction another keypress could cover. In game LoopAsync exists, the watch really polls,
    -- and this runs for real at the title screen.
    support.needGlobal(t, "LoopAsync")
    t:eq(event.isWorldReady(), false, "no pawn, no dispatch")
end)

s:test("instances() and instanceOfActor() are callable with no world and return an empty view", function(t)
    local all = event.instances()
    t:type(all, "table", "instances() always answers with a list")
    for _, inst in ipairs(all) do
        t:truthy(inst.key, "every live instance carries the key it is tracked under")
    end

    -- A namespaced id from this run: nothing has ever been placed under it, in any save.
    t:eq(#event.instances(support.id("building")), 0, "an id with nothing placed has no instances")
    t:eq(event.instanceOfActor(nil), nil, "no actor, no instance")
    t:eq(event.instanceOfActor({}), nil, "a table that was never a tracked actor resolves to nil")
end)

return s
