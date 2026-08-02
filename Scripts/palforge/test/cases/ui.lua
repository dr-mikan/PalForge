-- palforge/test/cases/ui.lua — the UI element lifecycle, proved without a single widget.
--
-- api/ui owns the WHEN (mount / refresh / unmount / autoRefresh) and a definition fills the
-- WHAT (render / update / destroy). That split is what makes this suite cheap: every case
-- here defines an element whose seams are plain Lua counters, so render-once, refresh-only-
-- while-mounted, destroy-on-unmount and per-instance state are all observable with no game
-- at all. The heartbeat is driven by emitting "tick" on core/event rather than waiting for
-- one, so the polling cases are deterministic too.
--
-- Only one case needs anything real and it draws nothing: _widget.owner() must not throw with a
-- world loaded. Every other engine-shaped case is gated the other way — _widget.screen(), the
-- native Button, a declared tree that cannot build, a "screen" host, an input grab and
-- :autoMount's lastError are exercised ONLY when there is no owner to build with, because
-- mounting a real widget on someone's screen from a test is exactly the thing this file refuses
-- to do. TitleMenu is mounted with an EMPTY entry list, which can never inject anything even
-- standing on the title screen.
--
-- ⚠️ AND "NO OWNER TO BUILD WITH" MEANS NO ENGINE, NOT NO WORLD. An owner is a
-- PalPlayerController or, failing that, a GameInstance, and both are up on the title screen —
-- measured 2026-08-02 16:39:05, where all six of those cases skipped in the very state they had
-- been written to run in. They carry NEEDS.NOENGINE now and only a headless lua5.4 run measures
-- them; the world-gated cases still need a save. THREE RUNS COVER THIS FILE, not two, and the
-- summary line names all three environments the same way (core/unittests: ENVIRONMENT).
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local UI      = require("palforge.api.ui")
local schema  = require("palforge.core.schema")
local event   = require("palforge.core.event")
local widget  = require("palforge.native.ui._widget")
local native  = require("palforge.native.ui")
-- The registry itself, for the three cases that are about REGISTRATION rather than about the
-- element: whether a definition went in at all (`register = false`), and who owns the id it went
-- in under. Everything else here reaches the registry through UI.get / UI.get_all.
local om      = require("palforge.core.object_manager")

local s = T.suite("ui")

-- A stand-in for a host panel. mount() only stores the root and hands it to render(), so a
-- table is as good as a VerticalBox everywhere the lifecycle itself is under test.
local function fakeRoot(name) return { __root = name or "root" } end

-- ⚠️ WHICH ENVIRONMENT A SKIP WENT TO, SAID IN THE SKIP ITSELF — AND "NO GAME" MEANT THE ENGINE
-- ALL ALONG.
--
-- No single F1 press can run every check in this tree. Most gated cases are WORLD-GATED — they
-- need a save loaded and skip at the title screen. The six below are the opposite, and for a
-- long time they were called INVERSE-gated and counted as "need no world", which was WRONG in a
-- way no headless run could show: every one of them asks whether there is an OWNER, a
-- PlayerController or a viewport to build under, and all three of those are up the moment the
-- game process is, save or no save.
--
-- MEASURED 2026-08-02 AT THE TITLE SCREEN, 16:39:05. That run was made specifically to cover
-- this direction, and all six skipped anyway. The Button case gates on
-- `widget.findFirst("PalPlayerController")` and it skipped, so a PalPlayerController is up on
-- the TITLE SCREEN — which also settles `widget.owner()`, whose first branch is that same
-- lookup and whose last is a GameInstance that exists from process start
-- (native/ui/_widget.lua:595-598). No world loaded, no pawn anywhere, and the run still
-- reported "6 need no world" while standing in the exact state "no world" names. Both
-- directions were closed at once because the two gates were asking different questions:
-- support.needWorld asks for a PAWN, this helper was asking for an OWNER, and an owner is not a
-- world — it is an ENGINE.
--
-- So these six are NEEDS.NOENGINE now (core/unittests: skipNeedsNoEngine), which is the honest
-- statement: they can only run in a headless lua5.4 process, no key press in any session state
-- reaches them, and the summary says so instead of implying a title-screen run would help. The
-- four checks that really are world-inverse — cases/player.lua, cases/building.lua,
-- cases/events.lua, cases/audio.lua — all gate on support.player() and all four DID run at the
-- title screen on that same press, which is what a correctly-typed no-world skip looks like.
--
-- The gate is also the SAFETY interlock and stays at least as tight as it was: with no engine
-- there is no owner and no controller, so nothing here can construct a widget or take the
-- player's cursor. support.needNoEngine skips a strict superset of what `if widget.owner()`
-- skipped, and it skips FIRST — the old spelling sat after the setup in one case, so an
-- :autoMount had already been armed and beaten before the gate was reached.
--
-- There is no local wrapper any more. The call is support.needNoEngine(t, what) at the top of
-- the case, spelled the same way the other four case files spell support.needNoWorld, because a
-- wrapper is where the direction and the prose got to disagree in the first place.

--=============================================================================
-- define / get / get_all
--=============================================================================

s:test("UI{...} registers the element and UI.get returns it by id", function(t)
    local id = support.id("ui_define")
    local El = UI{ id = id, name = "Defined", description = "a test element" }

    t:eq(El.id, id, "the handle carries the id it was defined with")
    t:eq(El:name(), "Defined", "name comes from the spec")
    t:eq(El:description(), "a test element", "description comes from the spec")

    local got = UI.get(id)
    t:eq(got.id, id, "UI.get finds the registered element")
    t:eq(got:name(), "Defined", "and resolves its class fields")
end)

s:test("name defaults to the id when the spec does not give one", function(t)
    local id = support.id("ui_noname")
    local El = UI{ id = id }
    t:eq(El:name(), id, "an element without a name is named after itself")
    t:eq(El:description(), nil, "description stays nil rather than being invented")
end)

s:test("UI.get of an id that was never defined returns a handle, never nil", function(t)
    local id = "palforge_test:never_defined_at_all"
    local El = UI.get(id)
    t:type(El, "table", "get always returns a handle")
    t:eq(El.id, id, "which remembers the id asked for")
    t:eq(El:name(), id, "and names itself after that id")
    t:type(El:state(), "table", "it even carries a state instance")
    -- What is NOT claimed here: mounting it. The fallback class is built without an
    -- __index of its own, so UI.Class's methods do not resolve on that state and the
    -- whole lifecycle raises on a never-defined id. Asserted nowhere on purpose — that
    -- is a defect to fix, not a contract to lock in.
end)

s:test("UI.get rejects an empty id instead of handing back a nameless element", function(t)
    t:errors(function() UI.get("") end, "id (string) is required")
    t:errors(function() UI.get(nil) end, "id (string) is required")
end)

s:test("get_all lists every registered element, including one just defined", function(t)
    local id = support.id("ui_listed")
    UI{ id = id }
    local seen, mine = 0, false
    for _, h in ipairs(UI.get_all()) do
        seen = seen + 1
        if h.id == id then mine = true end
    end
    t:truthy(mine, "the element defined in this test is in get_all")
    t:truthy(seen >= 2, "and it is listed alongside the natives, not on its own")
end)

s:test("re-defining an id replaces the registered class: the last definition wins", function(t)
    local id = support.id("ui_redefine")
    UI{ id = id, name = "first" }
    UI{ id = id, name = "second" }
    t:eq(UI.get(id):name(), "second", "the registry keeps the newest class for an id")
end)

s:test("the native Button and TitleMenu are registered under their own ids", function(t)
    t:eq(native.Button.id, "palforge:Button", "button.lua defines palforge:Button")
    t:eq(UI.get("palforge:Button"):name(), "Button", "and it is reachable through UI.get")
    t:eq(native.TitleMenu.id, "palforge:TitleMenu", "title_menu.lua defines palforge:TitleMenu")
    t:eq(UI.get("palforge:TitleMenu"):name(), "Title Menu", "with its display name")
end)

s:test("the framework's own two elements declare the pack that owns them", function(t)
    -- ⚠️ WHY THIS MATTERS AT ALL: there is ONE registry bucket per object type, and a pack's
    -- UI{ id = ... } writes into the same ("ui", id) map native/ui/button.lua does, under the
    -- same last-wins rule. A pack that defines "palforge:Button" REPLACES the framework's, and
    -- until the owner was recorded the replacement was silent. Last-wins stays; what the pack id
    -- buys is that object_manager's warning can name who held the id before and who has it now.
    if type(om.owner) ~= "function" then
        t:skip("core/object_manager has no owner() yet — the pack-ownership half of contract C3 "
            .. "is not in this tree, so what button.lua and title_menu.lua now pass as "
            .. "{ pack = \"palforge\" } cannot be read back. The definitions carry it either way; "
            .. "an older register() simply ignores the fourth argument.")
    end
    t:eq(om.owner("ui", "palforge:Button"), "palforge",
        "palforge:Button is owned by the framework, by name")
    t:eq(om.owner("ui", "palforge:TitleMenu"), "palforge",
        "and so is palforge:TitleMenu")
end)

s:test("a definition may decline to register, and may name the pack it registers under",
function(t)
    -- Contract C2: the optional second argument every domain constructor takes. `register =
    -- false` is what a catalog accessor needs — a READ that fabricates a handle must not take the
    -- id away from a pack that has not defined it yet, which is the whole defect that shape
    -- exists to fix.
    local id = support.id("ui_noregister")
    local El = UI({ id = id, name = "Unregistered" }, { register = false })
    t:eq(El.id, id, "the handle is built and returned as usual")
    t:eq(El:name(), "Unregistered", "with everything the spec declared")
    t:eq(om.get("ui", id), nil, "and NOTHING went into the registry")
    -- UI.get still answers, because it fabricates an inert element for an unknown id — the point
    -- is that the id is still FREE, not that it is unreachable.
    t:eq(UI.get(id):name(), id, "so UI.get falls back to an inert element named after the id")

    -- And the pack half: it is passed through to om.register, which is where a collision becomes
    -- attributable. Whether it can be read back depends on C3 landing; the call is the same
    -- either way, and an older three-argument register() ignores the extra table.
    local packed = support.id("ui_packed")
    t:truthy(UI({ id = packed }, { pack = "palforge_test" }), "a pack-scoped definition is built")
    t:truthy(om.get("ui", packed), "and it IS registered — only the owner differs")
    if type(om.owner) == "function" then
        t:eq(om.owner("ui", packed), "palforge_test", "under the pack id it was given")
    end
end)

s:test("an id that om.resolve could never resolve is refused at DEFINE time", function(t)
    -- Contract C4. An id with a colon whose halves are not [%w_]+ resolves to nothing at every
    -- engine boundary, so before this it registered, looked completely healthy in UI.get_all(),
    -- and was silently dead. The shape rule has exactly ONE owner — om.validId — and api/ui
    -- deliberately keeps no second copy of it, so this asserts the seam is wired rather than
    -- re-asserting the rule itself (core/keyboard's own suite owns that).
    t:errors(function() UI{ id = "my-pack:Panel" } end, "my-pack:Panel")
    t:errors(function() UI{ id = "pack:has space" } end, "pack:has space")
    -- A literal game id — no colon at all — stays legal: that is the "this is a vanilla id"
    -- case, and rejecting it would break every native catalog definition in the tree.
    t:truthy(UI{ id = support.id("ui_literal_ok") }, "a well-shaped namespaced id is accepted")
end)

--=============================================================================
-- the spec is strict, and readable at runtime
--=============================================================================

s:test("an unknown field is a hard error with a did-you-mean", function(t)
    t:errors(function()
        UI{ id = support.id("ui_typo"), renderer = function() end }
    end, "did you mean \"render\"?")
end)

s:test("id is required, and an empty id is rejected by its check", function(t)
    t:errors(function() UI{ name = "no id" } end, "field \"id\" is required")
    t:errors(function() UI{ id = "" } end, "must be a non-empty string")
end)

s:test("a seam of the wrong type is refused at define time", function(t)
    t:errors(function()
        UI{ id = support.id("ui_badrender"), render = "not a function" }
    end, "expects function, got string")
end)

s:test("UI.Spec is readable through the schema registry, not off the module", function(t)
    t:eq(UI.Spec, nil, "the spec stays a local; the module is not a namespace to browse")
    local spec = schema.get("UI.Spec")
    t:truthy(spec, "but it is registered under its name")
    local want = { id = false, name = false, description = false,
                   render = false, update = false, destroy = false, data = false }
    for _, f in ipairs(spec.fields) do
        if want[f.name] ~= nil then want[f.name] = true end
    end
    for name, found in pairs(want) do
        t:truthy(found, "UI.Spec declares " .. name)
    end
    t:truthy(spec:field("id").required, "id is declared required")
    t:truthy(schema.help("UI.Spec"):find("render", 1, true), "help() prints the seams")
end)

--=============================================================================
-- instances: :new, and `data` as shared defaults
--=============================================================================

s:test(":new gives each instance its own state while data supplies shared defaults", function(t)
    local El = UI{ id = support.id("ui_state"), data = { label = "shared", tries = 0 } }

    local a = El:new{}
    local b = El:new{ label = "b" }

    t:eq(a:state().label, "shared", "an instance reads data through the class")
    t:eq(b:state().label, "b", "unless it was handed its own value")
    t:eq(El:state().label, "shared", "the define handle is itself an instance with the defaults")

    a:state().label = "a"
    t:eq(a:state().label, "a", "writing a field writes it on the instance")
    t:eq(b:state().label, "b", "which the sibling instance never sees")
    t:eq(El:state().label, "shared", "and which does not rewrite the shared default")
    t:eq(a:state().tries, 0, "other defaults keep coming from data")
end)

s:test(":new adopts the table you pass as the instance itself", function(t)
    local El = UI{ id = support.id("ui_adopt") }
    local given = { label = "given" }
    local inst = El:new(given)
    t:eq(inst:state(), given, "state() IS the table handed to :new (it is not copied)")
    t:eq(inst:state().label, "given", "so its fields are the instance's fields")
end)

s:test("instances mount independently of each other and of the define handle", function(t)
    local rendered = 0
    local El = UI{ id = support.id("ui_indep"),
                   render = function() rendered = rendered + 1 end }
    local a, b = El:new{}, El:new{}

    t:eq(a:mount(fakeRoot()), true, "one instance mounts")
    t:eq(a:isMounted(), true, "and knows it")
    t:eq(b:isMounted(), false, "the sibling is untouched")
    t:eq(El:isMounted(), false, "so is the define handle")
    t:eq(rendered, 1, "exactly one render ran")

    a:unmount()
    t:eq(rendered, 1, "unmounting renders nothing")
end)

--=============================================================================
-- lifecycle: mount / refresh / unmount
--=============================================================================

s:test("isMounted is false before a mount and true after it", function(t)
    local El = UI{ id = support.id("ui_flag") }
    local el = El:new{}
    t:eq(el:isMounted(), false, "a fresh instance is not mounted")
    t:eq(el:mount(fakeRoot()), true, "an element with no render at all still mounts: the base seam is inert")
    t:eq(el:isMounted(), true, "mount latches the flag")
    el:unmount()
    t:eq(el:isMounted(), false, "unmount clears it")
end)

s:test(":mount calls render exactly once and is idempotent", function(t)
    local rendered = 0
    local El = UI{ id = support.id("ui_once"),
                   render = function() rendered = rendered + 1 end }
    local el = El:new{}

    t:eq(el:mount(fakeRoot()), true, "the first mount reports the render succeeded")
    t:eq(rendered, 1, "render ran once")
    t:eq(el:mount(fakeRoot()), false, "a second mount reports false — already mounted, not a failure")
    t:eq(rendered, 1, "and cannot stack a second render")
    t:eq(el:isMounted(), true, "the element is still mounted after the no-op")

    el:unmount()
    t:eq(el:mount(fakeRoot()), true, "after unmounting it renders afresh")
    t:eq(rendered, 2, "which is the second render, not a third")
    el:unmount()
end)

s:test("render receives the instance and the root that mount was given", function(t)
    local seenSelf, seenRoot
    local El = UI{ id = support.id("ui_args"),
                   render = function(self, root) seenSelf, seenRoot = self, root end }
    local el = El:new{ label = "mine" }
    local root = fakeRoot("host")

    el:mount(root)
    t:eq(seenRoot, root, "render is handed the root mount was called with")
    t:eq(seenSelf, el:state(), "and `self` is the instance, not the handle")
    t:eq(seenSelf.label, "mine", "so instance state is readable from inside render")
    t:eq(el:state()._root, root, "the lifecycle remembers the root while mounted")
    el:unmount()
    t:eq(el:state()._root, nil, "and forgets it on the way down")
end)

s:test("a render that returns false leaves the element unmounted so mounting can retry", function(t)
    local attempts = 0
    local El = UI{ id = support.id("ui_retry"), render = function()
        attempts = attempts + 1
        if attempts < 3 then return false end   -- "the host UI was not there yet"
    end }
    local el = El:new{}

    t:eq(el:mount(fakeRoot()), false, "a render that could not build reports failure")
    t:eq(el:isMounted(), false, "so the element does not latch")
    t:eq(el:state()._root, nil, "and the root it could not use is dropped")
    t:eq(el:mount(fakeRoot()), false, "mounting again retries rather than no-opping")
    t:eq(attempts, 2, "each attempt really re-ran render")
    t:eq(el:mount(fakeRoot()), true, "the attempt that builds finally latches")
    t:eq(el:isMounted(), true, "mounted at last")
    el:unmount()
end)

s:test("only an explicit false is a failure — a render returning nothing counts as built", function(t)
    local El = UI{ id = support.id("ui_nilret"), render = function() return nil end }
    local el = El:new{}
    t:eq(el:mount(fakeRoot()), true, "a declarative render need not return anything")
    t:eq(el:isMounted(), true, "and the element is mounted")
    el:unmount()

    local El2 = UI{ id = support.id("ui_truthy"), render = function() return "built" end }
    local el2 = El2:new{}
    t:eq(el2:mount(fakeRoot()), true, "any non-false return is success too")
    el2:unmount()
end)

s:test("a render that raises propagates out of :mount and the element stays unmounted", function(t)
    local El = UI{ id = support.id("ui_throw"),
                   render = function() error("no host panel", 0) end }
    local el = El:new{}
    -- mount() does NOT pcall render: a broken element is the author's bug and must be loud.
    t:errors(function() el:mount(fakeRoot()) end, "no host panel")
    t:eq(el:isMounted(), false, "a render that blew up never latches the element")
end)

s:test(":refresh calls update only while mounted", function(t)
    local updated = 0
    local El = UI{ id = support.id("ui_refresh"),
                   update = function() updated = updated + 1 end }
    local el = El:new{}

    t:eq(el:refresh(), false, "refresh before mount is a no-op")
    t:eq(updated, 0, "update did not run")

    el:mount(fakeRoot())
    t:eq(el:refresh(), true, "refresh runs once mounted")
    t:eq(updated, 1, "update ran once")
    t:eq(el:refresh(), true, "and again on the next refresh")
    t:eq(updated, 2, "update is NOT once-per-mount the way render is")

    el:unmount()
    t:eq(el:refresh(), false, "refresh after unmount is a no-op again")
    t:eq(updated, 2, "update did not run on the dead element")
end)

s:test(":unmount runs destroy once, clears the flag, and is quiet when called again", function(t)
    local destroyed = 0
    local El = UI{ id = support.id("ui_destroy"),
                   destroy = function() destroyed = destroyed + 1 end }
    local el = El:new{}

    el:unmount()
    t:eq(destroyed, 0, "unmounting something that was never mounted destroys nothing")

    el:mount(fakeRoot())
    el:unmount()
    t:eq(destroyed, 1, "destroy runs on the way down")
    t:eq(el:isMounted(), false, "and the flag is cleared")
    el:unmount()
    t:eq(destroyed, 1, "a second unmount does not destroy twice")
end)

s:test("a destroy that raises cannot leave the element stuck mounted", function(t)
    local El = UI{ id = support.id("ui_baddestroy"),
                   destroy = function() error("widget already gone", 0) end }
    local el = El:new{}
    el:mount(fakeRoot())
    -- unmount pcalls destroy: taking an element down must always succeed, because the
    -- alternative is an element nobody can ever mount again.
    el:unmount()
    t:eq(el:isMounted(), false, "the element came down despite the throwing destroy")
    t:eq(el:mount(fakeRoot()), true, "and it can be mounted again afterwards")
    el:unmount()
end)

--=============================================================================
-- autoRefresh — polling off core/event's heartbeat, driven by hand
--=============================================================================

-- Emit one heartbeat. In game this is one extra pass of a loop that already runs every
-- TICK_MS, and it is pcall'd because another subscriber's failure is not this suite's.
local function beat(n)
    pcall(function() event.emit("tick", { count = n or 1, now = 0 }) end)
end

s:test(":autoRefresh returns true and parks the disposer on the instance", function(t)
    local updated = 0
    local El = UI{ id = support.id("ui_poll"),
                   update = function() updated = updated + 1 end }
    local el = El:new{}
    el:mount(fakeRoot())

    -- NOTE: it returns a BOOLEAN, not the disposer — the subscription is kept on the
    -- instance so :unmount() can cancel it, and is not the caller's to hold.
    t:eq(el:autoRefresh(event.TICK_MS), true, "the subscription went in")
    t:truthy(el:state()._refreshSub, "and lives on the instance")
    t:type(el:state()._refreshSub.unsubscribe, "function", "as something unsubscribable")

    beat(1)
    t:eq(updated, 1, "one heartbeat drives exactly one update")
    beat(2)
    t:eq(updated, 2, "and the next one drives the next")

    el:unmount()
    beat(3)
    t:eq(updated, 2, "unmount cancelled the poll")
    t:eq(el:state()._refreshSub, nil, "and dropped the subscription it held")
end)

s:test(":autoRefresh is idempotent: a second call keeps the one subscription", function(t)
    local updated = 0
    local El = UI{ id = support.id("ui_poll2"),
                   update = function() updated = updated + 1 end }
    local el = El:new{}
    el:mount(fakeRoot())

    t:eq(el:autoRefresh(event.TICK_MS), true, "installed")
    local sub = el:state()._refreshSub
    t:eq(el:autoRefresh(event.TICK_MS), true, "a second call still reports success")
    t:eq(el:state()._refreshSub, sub, "but reuses the subscription it already had")

    beat(1)
    t:eq(updated, 1, "so a heartbeat refreshes once, not twice")
    el:unmount()
end)

s:test("a poll installed before mounting fires nothing until the element is mounted", function(t)
    local updated = 0
    local El = UI{ id = support.id("ui_poll3"),
                   update = function() updated = updated + 1 end }
    local el = El:new{}

    t:eq(el:autoRefresh(event.TICK_MS), true, "autoRefresh does not require a mount")
    beat(1)
    t:eq(updated, 0, "but refresh() is a no-op while unmounted, so update never ran")

    el:mount(fakeRoot())
    beat(2)
    t:eq(updated, 1, "once mounted the same poll starts driving update")

    -- unmount is the only cancel there is; it clears the subscription either way.
    el:unmount()
    beat(3)
    t:eq(updated, 1, "cancelled")
    t:eq(el:state()._refreshSub, nil, "with nothing left subscribed to the heartbeat")
end)

s:test("a slower poll skips heartbeats instead of firing on every one", function(t)
    local updated = 0
    local El = UI{ id = support.id("ui_poll4"),
                   update = function() updated = updated + 1 end }
    local el = El:new{}
    el:mount(fakeRoot())
    -- event.every quantizes to TICK_MS, so twice the tick interval means every other beat.
    t:eq(el:autoRefresh(event.TICK_MS * 2), true, "installed at twice the heartbeat")

    beat(1)
    t:eq(updated, 0, "one beat is not enough")
    beat(2)
    t:eq(updated, 1, "two beats are")
    beat(3)
    t:eq(updated, 1, "and the accumulator starts over")
    beat(4)
    t:eq(updated, 2, "firing again on the next pair")

    el:unmount()
    beat(5)
    t:eq(updated, 2, "cancelled")
end)

--=============================================================================
-- autoMount — the retry loop, and the mount path every live PalForge UI takes
--
-- ⚠️ THIS SECTION DID NOT EXIST AND THAT WAS THE LARGEST HOLE IN THIS FILE. :autoMount is what
-- native/ui/title_menu.lua's own header tells a pack to call, what test/init.lua's pf_uiz mounts
-- all three of its panels with, and what every element whose host is not up at load has to use —
-- and not one check anywhere touched it. autoRefresh was covered four ways over; the thing that
-- actually gets a panel on screen was covered zero.
--
-- It is decidable headlessly for the same reason autoRefresh is: the whole of it is one
-- event.every subscription whose body branches on `_mounted`, so a render that counts its own
-- calls and a hand-driven heartbeat prove the branch, the retry, the latch and the cancel.
--=============================================================================

s:test(":autoMount installs the poll and RETRIES mount while the element is down", function(t)
    -- The shape a title-screen element is in at load: the host is not there, render says so, and
    -- the element must keep trying rather than giving up on the first answer.
    local attempts, host = 0, nil
    local El = UI{ id = support.id("ui_automount"),
                   render = function(_, root) attempts = attempts + 1; host = root
                       return attempts >= 3 end }
    local el = El:new{}
    local root = fakeRoot("late-host")

    t:eq(el:autoMount(root, event.TICK_MS), true, "the subscription went in")
    t:truthy(el:state()._refreshSub, "and lives on the instance, exactly as autoRefresh's does")
    t:eq(attempts, 0, "installing it does not mount — the first attempt is the first beat")

    beat(1)
    t:eq(attempts, 1, "one beat is one mount attempt")
    t:eq(el:isMounted(), false, "the render reported it could not build, so nothing latched")
    beat(2)
    t:eq(attempts, 2, "and the next beat tries again rather than giving up")
    t:eq(el:isMounted(), false, "still down")

    beat(3)
    t:eq(attempts, 3, "the third attempt is the one that builds")
    t:eq(el:isMounted(), true, "and THAT is what latches the mount")
    t:eq(host, root, "every attempt was handed the root autoMount was given")

    -- Once it is up the same subscription stops mounting and starts refreshing: render must never
    -- run a second time for one mount, which is the guarantee the whole lifecycle rests on.
    beat(4)
    beat(5)
    t:eq(attempts, 3, "a mounted element is refreshed by the beat, never re-rendered")
    el:unmount()
end)

s:test(":autoMount drives update() once the element is up, like autoRefresh does", function(t)
    local updated = 0
    local El = UI{ id = support.id("ui_automount_up"),
                   render = function() end,
                   update = function() updated = updated + 1 end }
    local el = El:new{}
    t:eq(el:autoMount(fakeRoot(), event.TICK_MS), true, "installed")
    beat(1)
    t:eq(el:isMounted(), true, "the first beat mounted it (this render always succeeds)")
    t:eq(updated, 0, "the beat that mounts does not also refresh")
    beat(2)
    t:eq(updated, 1, "the next one refreshes")
    beat(3)
    t:eq(updated, 2, "and keeps refreshing")
    el:unmount()
end)

s:test(":unmount is the only cancel :autoMount has, and it stops the retrying too", function(t)
    -- Worth asserting separately from the mounted case: an element that is DOWN is exactly the
    -- state autoMount exists for, so "unmount stops it" has to hold for a loop that has never
    -- succeeded — otherwise a pack could never stop an element that cannot find its host.
    local attempts = 0
    local El = UI{ id = support.id("ui_automount_cancel"),
                   render = function() attempts = attempts + 1; return false end }
    local el = El:new{}
    el:autoMount(fakeRoot(), event.TICK_MS)
    beat(1)
    beat(2)
    t:eq(attempts, 2, "two beats, two failed attempts")
    t:eq(el:isMounted(), false, "and it never got up")

    el:unmount()
    t:eq(el:state()._refreshSub, nil, "unmount dropped the subscription")
    beat(3)
    beat(4)
    t:eq(attempts, 2, "so the retrying stopped, on an element that was never mounted")
end)

s:test(":autoMount and :autoRefresh share the one subscription slot, either way round",
function(t)
    -- They are two policies over one timer, not two timers. A second call of either kind must
    -- reuse the slot: two subscriptions would double every refresh and, worse, leave one behind
    -- that :unmount could not cancel.
    local El = UI{ id = support.id("ui_automount_share"), render = function() end }
    local el = El:new{}
    t:eq(el:autoMount(fakeRoot(), event.TICK_MS), true, "autoMount first")
    local sub = el:state()._refreshSub
    t:eq(el:autoRefresh(event.TICK_MS), true, "then autoRefresh reports success")
    t:eq(el:state()._refreshSub, sub, "and reuses the subscription that is already there")
    el:unmount()

    local other = El:new{}
    t:eq(other:autoRefresh(event.TICK_MS), true, "and the other way round: autoRefresh first")
    local sub2 = other:state()._refreshSub
    t:eq(other:autoMount(fakeRoot(), event.TICK_MS), true, "then autoMount")
    t:eq(other:state()._refreshSub, sub2, "same slot")
    -- ⚠️ AND THE POLICY IS WHICHEVER ONE INSTALLED THE SLOT. The second call does not upgrade a
    -- refresh-only poll into a retrying one, because poll() returns early on the existing
    -- subscription. Asserted rather than left as a surprise: an element that called autoRefresh
    -- first does NOT start mounting itself.
    beat(1)
    t:eq(other:isMounted(), false,
        "an autoRefresh-installed poll stays refresh-only; the later autoMount did not take over")
    other:unmount()
end)

s:test(":autoMount keeps the reason the last attempt gave up, for a loop that never gets in",
function(t)
    -- With an engine there is an owner, so host = "screen" resolves and really draws, which is
    -- the one thing this file will not do. The gate is FIRST now: it used to sit after the
    -- autoMount and one beat, so in a live session the retry loop was armed and run once before
    -- the case decided it should not have been.
    support.needNoEngine(t, "an owner exists, so host = \"screen\" would resolve and put a real "
        .. "viewport layer on the player's screen instead of failing to")

    -- The half that makes a silent retry loop debuggable: :lastError() is what tells an author
    -- why the panel is not up, and it has to survive every beat rather than being reset by the
    -- next attempt.
    local El = UI{ id = support.id("ui_automount_why"), host = "screen" }
    local el = El:new{}
    t:eq(el:lastError(), nil, "nothing has failed yet")
    el:autoMount(nil, event.TICK_MS)
    beat(1)
    t:type(el:lastError(), "string", "a failed attempt records why: " .. tostring(el:lastError()))
    local first = el:lastError()
    beat(2)
    beat(3)
    t:eq(el:lastError(), first, "and the reason survives the beats that follow it")
    t:eq(el:isMounted(), false, "with the element still down, still retrying")
    el:unmount()
end)

--=============================================================================
-- the native elements + the widget toolkit — fail-soft, and never drawing
--=============================================================================

s:test("TitleMenu with no entries reports it injected nothing and never latches", function(t)
    -- Deliberately entry-less: this is the one shape that is safe to mount even while
    -- standing on the real title screen, because there is nothing to inject.
    local menu = native.TitleMenu:new{ entries = {} }
    t:eq(menu:mount(), false, "render returns false when no entry went in")
    t:eq(menu:isMounted(), false, "so the element stays unmounted and can be retried")
    t:eq(menu:refresh(), false, "and refresh is a no-op on an unmounted element")
    menu:unmount()
end)

s:test("Button's render reports false rather than throwing when there is no controller", function(t)
    -- A PalPlayerController is up on the title screen too (measured 2026-08-02 16:39:05), so the
    -- question is whether there is an ENGINE, not whether there is a world.
    support.needNoEngine(t, "a PalPlayerController exists, so Button's render would build a real "
        .. "widget instead of reporting that it could not")
    local btn = native.Button:new{ label = "test", onClick = function() end }
    t:eq(btn:mount(fakeRoot()), false, "no controller means nothing was built")
    t:eq(btn:isMounted(), false, "so the mount does not latch")
    t:eq(btn:state().widget, nil, "and no widget was left behind on the instance")
end)

s:test("_widget's fail-soft helpers never throw, with or without a game", function(t)
    t:type(widget.screen, "function", "screen() is reachable from the toolkit")
    t:type(widget.owner, "function", "so is owner()")
    t:type(widget.gameUIRoot, "function", "and so is gameUIRoot(), the game's own host")
    t:eq(widget.alive(nil), false, "alive(nil) is false, not an error")
    t:eq(widget.alive({}), false, "alive of a plain table is false too")
    t:eq(widget.findFirst("NoSuchClassAnywhere"), nil, "findFirst of a missing class is nil")
    t:eq(widget.show(nil), false, "show(nil) fails soft")
    t:eq(widget.hide(nil), false, "hide(nil) fails soft")
end)

s:test("_widget.gameUIRoot names the game's in-game UI host and fails soft when it is not up",
function(t)
    -- The two names are the whole answer to ui-host-paths and they are asserted here so a
    -- rename cannot pass silently: they are read straight off the dump — the layout's native
    -- base class (dumps/cxx/Pal.hpp:27311) and its root canvas member
    -- (dumps/cxx/WBP_PalOverallUILayout.hpp:9).
    t:eq(widget.PATHS.gameUILayout, "PalPrimaryGameLayoutBase", "the layout is found by its NATIVE class")
    t:eq(widget.PATHS.gameUIRoot, "CanvasPanel_Root", "and the host panel by its declared member name")

    -- Read-only either way: this only ever does a FindFirstOf and one property read, so it is
    -- safe to run in a live session — it adds nothing to anybody's screen.
    local host, why = widget.gameUIRoot()
    if host then
        t:truthy(widget.alive(host), "with a world up, the host that came back is a live widget")
    else
        t:type(why, "string", "and with no in-game UI it is nil plus a reason, never a raise")
        t:truthy(why:find(widget.PATHS.gameUILayout, 1, true),
            "which names what was missing: " .. tostring(why))
    end
end)

s:test("_widget.screen returns nil and a reason when there is no owner to build under", function(t)
    -- Only run this where screen() cannot succeed: with a real owner it would construct a
    -- UserWidget and put it on the player's viewport, which no test may do. widget.owner() falls
    -- back to the GameInstance (native/ui/_widget.lua:595-598), which exists from process start,
    -- so "there is no owner" is a statement about the ENGINE and only a headless run satisfies it.
    support.needNoEngine(t, "an owner exists, so screen() would really construct a UserWidget and "
        .. "put it on the player's viewport")
    local screen, why = widget.screen()
    t:eq(screen, nil, "no screen without an owner")
    t:type(why, "string", "and a reason rather than a raised error")
    t:truthy(why:find("no owner", 1, true), "which names the missing owner: " .. tostring(why))
end)

s:test("with a world loaded there is an owner for our widgets", function(t)
    support.needWorld(t)
    -- Read-only: FindFirstOf on the controller/game instance, nothing constructed.
    t:truthy(widget.owner(), "a PlayerController or GameInstance is findable in a live world")
end)

--=============================================================================
-- the DECLARATIVE tree: nodes are data, and every mistake is caught at the call site
--
-- Not one case here touches the engine, which is the property the split exists for: the node
-- constructors live in api/ui and hold no widget code, so a whole panel can be declared,
-- nested, mis-declared and inspected with no game running. The cases that would BUILD one skip
-- themselves in a live session, exactly as the screen and Button cases above do.
--=============================================================================

local VBox, HBox, Label, Button = UI.VBox, UI.HBox, UI.Label, UI.Button
local Border, SizeBox = UI.Border, UI.SizeBox

s:test("a node carries its kind and its validated fields, and nothing else", function(t)
    local n = Label{ text = "Supplies", size = 18, name = "title" }
    t:eq(n.kind, "label", "the node knows which widget it becomes")
    t:eq(n.text, "Supplies", "declared fields are on the node")
    t:eq(n.size, 18, "all of them")
    t:eq(n.name, "title", "including the name find() will use")
    t:eq(n.children, nil, "a leaf has no children key at all, not an empty one")
    t:eq(tostring(UI.VBox), "UI.VBox", "a constructor names itself")
    t:eq(UI.VBox.kind, "vbox", "and says what it builds without being called")
end)

s:test("positional entries ARE the children, in the order they were written", function(t)
    local n = VBox{
        Label{ text = "one" },
        Label{ text = "two" },
        Button{ text = "three" },
    }
    t:eq(n.kind, "vbox", "the container is a vbox")
    t:eq(#n.children, 3, "three children went in")
    t:eq(n.children[1].text, "one", "in source order")
    t:eq(n.children[3].kind, "button", "whatever kind each one is")
end)

s:test("children nest arbitrarily and stay plain data", function(t)
    local n = VBox{ padding = 8,
        Border{ color = { 0.1, 0.1, 0.1, 1 },
            HBox{
                Label{ text = "left" },
                SizeBox{ width = 120, Label{ text = "right" } },
            },
        },
    }
    t:eq(n.padding, 8, "a named field sits beside the positional children")
    local hbox = n.children[1].children[1]
    t:eq(hbox.kind, "hbox", "the border's one child is the row")
    t:eq(hbox.children[2].children[1].text, "right", "and the tree reads to the bottom")
end)

s:test("`children = { ... }` says the same thing, for a tree built by a loop", function(t)
    local kids = {}
    for i = 1, 3 do kids[i] = Label{ text = "row " .. i } end
    local n = VBox{ children = kids }
    t:eq(#n.children, 3, "an explicit children list is accepted")
    t:eq(n.children[2].text, "row 2", "with the same contents")
end)

s:test("writing children BOTH ways at once is refused rather than merged", function(t)
    t:errors(function() VBox{ Label{}, children = { Label{} } } end,
        "children given BOTH positionally and as `children`")
end)

s:test("how many children a node holds is enforced where it is written", function(t)
    t:errors(function() Label{ Button{ text = "x" } } end, "UI.Label holds no children")
    t:errors(function() Button{ Label{} } end, "UI.Button holds no children")
    t:errors(function() Border{ Label{}, Label{} } end, "UI.Border holds ONE child, 2 given")
    t:errors(function() SizeBox{ Label{}, Label{} } end, "UI.SizeBox holds ONE child")
    -- and the shapes that ARE legal raise nothing
    t:truthy(Border{ Label{} }, "one child in a border is fine")
    t:truthy(VBox{}, "an empty container is fine — it is a panel with nothing in it yet")
end)

s:test("an unknown field on a node is a hard error with a did-you-mean", function(t)
    t:errors(function() Label{ tetx = "Supplies" } end, "did you mean \"text\"?")
    t:errors(function() VBox{ colour = {} } end, "unknown field \"colour\"")
    t:errors(function() Button{ onclick = function() end } end, "did you mean \"onClick\"?")
end)

s:test("a field of the wrong type, and a value outside its list, are both refused", function(t)
    t:errors(function() Label{ size = "big" } end, "expects number, got string")
    t:errors(function() Label{ hAlign = "sideways" } end, "must be one of")
    t:errors(function() UI.GameWidget{} end, "field \"class\" is required")
end)

s:test("a child that is not a node is refused, and the message names what builds one", function(t)
    t:errors(function() VBox{ { kind = "label", text = "hand-rolled" } } end,
        "child 1 is a table, not a node")
    t:errors(function() VBox{ "just a string" } end, "child 1 is a string, not a node")
    t:errors(function() UI{ id = support.id("ui_badroot"), root = { kind = "vbox" } } end,
        "must be a node built by one of")
end)

s:test("every node kind api/ui publishes has a builder in native/ui/tree", function(t)
    -- The two halves are declared in different files on purpose (one is pure data, one is the
    -- only place that touches UMG), so this is the seam where "I added a spec and forgot the
    -- maker" would otherwise show up as a runtime failure on someone's screen.
    local makers = native.tree.kinds()
    local n = 0
    for name, ctor in pairs(UI) do
        if type(ctor) == "table" and ctor.kind then
            n = n + 1
            t:truthy(makers[ctor.kind], "native/ui/tree can build UI." .. name)
        end
    end
    t:truthy(n >= 9, "and every published constructor was checked (" .. n .. ")")
end)

s:test("every node spec is in the schema registry, so the type generator emits it", function(t)
    for _, name in ipairs({ "UI.Node.VBox", "UI.Node.Label", "UI.Node.Button",
                            "UI.Node.GameWidget", "UI.Spec.Host" }) do
        t:truthy(schema.get(name), name .. " is declared through core/schema")
    end
    local label = schema.get("UI.Node.Label")
    t:truthy(label:field("text"), "a Label declares text")
    t:truthy(label:field("hAlign").values, "and hAlign carries its allowed values, so the editor lists them")
end)

--=============================================================================
-- declared ELEMENTS: root, host, and the seams they fill
--=============================================================================

s:test("`root` installs the declarative seams in place of a hand-written render", function(t)
    local El = UI{ id = support.id("ui_decl"), root = VBox{ Label{ text = "hi" } } }
    local el = El:new{}
    t:eq(el:state().render, UI.Class.renderTree, "render is the tree renderer")
    t:eq(el:state().update, UI.Class.updateTree, "update re-evaluates the bindings")
    t:eq(el:state().destroy, UI.Class.destroyTree, "destroy takes the tree back down")
    t:eq(el:state().rootNode.kind, "vbox", "and the declared tree is on the class")
end)

s:test("declaring both `root` and `render` is refused at define time", function(t)
    t:errors(function()
        UI{ id = support.id("ui_both"), root = VBox{}, render = function() end }
    end, "declares BOTH `root` and `render`")
end)

s:test("update and destroy COMPOSE with the tree instead of replacing it", function(t)
    local updated, destroyed = 0, 0
    local El = UI{ id = support.id("ui_compose"),
                   root    = VBox{ Label{ text = "x" } },
                   update  = function() updated = updated + 1 end,
                   destroy = function() destroyed = destroyed + 1 end }
    local el = El:new{}
    -- Called directly: with nothing built, the tree half is a no-op and what is under test is
    -- that the author's half still runs — a declared tree must not silently eat it.
    el:state():update()
    t:eq(updated, 1, "the author's update ran alongside the binding pass")
    el:state():destroy()
    t:eq(destroyed, 1, "and the author's destroy ran alongside the teardown")
end)

s:test("a declared element that cannot build reports false and says why", function(t)
    support.needNoEngine(t, "an owner exists, and building a real tree from a test is what this "
        .. "file refuses to do")
    local El = UI{ id = support.id("ui_nobuild"), root = VBox{ Label{ text = "hi" } } }
    local el = El:new{}
    t:eq(el:lastError(), nil, "nothing has failed yet")
    t:eq(el:mount(fakeRoot()), false, "with no UMG to construct from, nothing was built")
    t:eq(el:isMounted(), false, "so the element stays unmounted and :autoMount can retry")
    t:type(el:lastError(), "string", "and the reason is kept rather than swallowed")
    t:truthy(el:lastError():find("vbox", 1, true),
        "naming the node that failed: " .. tostring(el:lastError()))
    t:eq(el:find("anything"), nil, "find() answers nil on an element with no live tree")
end)

s:test("`host` is resolved by mount, and a host that is not up leaves render unreached", function(t)
    support.needNoEngine(t, "an owner exists, so host = \"screen\" would resolve and really draw "
        .. "a viewport layer instead of leaving render unreached")
    local rendered = 0
    local El = UI{ id = support.id("ui_host"), host = "screen",
                   render = function() rendered = rendered + 1 end }
    local el = El:new{}
    t:eq(el:mount(), false, "no owner, so there is no viewport layer to make")
    t:eq(rendered, 0, "and render was never reached — the host is resolved first")
    t:truthy(el:lastError():find("no owner", 1, true),
        "with the reason the toolkit gave: " .. tostring(el:lastError()))
end)

s:test("the game's own UI is a host name, and a junk one is refused at define time", function(t)
    -- "game" is CanvasPanel_Root inside WBP_PalOverallUILayout — the same two names
    -- widget.gameUIRoot() resolves, asserted against the dump further up this file.
    t:truthy(UI{ id = support.id("ui_hostgame"), host = "game" }, "\"game\" is a host")
    t:truthy(UI{ id = support.id("ui_hostscreen"), host = "screen" }, "so is \"screen\"")
    t:truthy(UI{ id = support.id("ui_hosttbl"),
                 host = { widget = "PalUITitleBase", panel = "VerticalBox_0" } },
             "and so is any widget class plus the panel inside it")
    t:errors(function() UI{ id = support.id("ui_hostbad"), host = "hud" } end,
        "is not a host name")
    t:errors(function() UI{ id = support.id("ui_hostbad2"), host = { panel = "VerticalBox_0" } } end,
        "field \"widget\" is required")
end)

s:test("a bound field is a function of the INSTANCE, which is what makes one tree reusable",
function(t)
    -- The binding contract, checked where it is decided rather than through a live widget:
    -- native/ui/tree.valueOf is what build() and update() both call.
    local text = function(self) return "Wood x" .. self.wood end
    t:eq(native.tree.valueOf(text, { wood = 3 }), "Wood x3", "a binding reads the instance")
    t:eq(native.tree.valueOf(text, { wood = 4 }), "Wood x4", "a second instance sees its own state")
    t:eq(native.tree.valueOf("static", { wood = 1 }), "static", "a plain value is passed through")

    local v, err = native.tree.valueOf(function() error("bad binding", 0) end, {})
    t:eq(v, nil, "a binding that raises yields nil")
    t:type(err, "string", "plus the error, so the refresh can carry on with the others")
end)

--=============================================================================
-- the nodes added for "the button does nothing": Sprite, Frame, a native Label
--=============================================================================

s:test("a Sprite takes an asset path or a vanilla id, and fills the rest in", function(t)
    local byPath = UI.Sprite{ path = "/Game/Pal/Texture/UI/T_x.T_x" }
    t:eq(byPath.kind, "sprite", "it is a sprite")
    t:eq(byPath.from, "item", "`from` defaults to the item icon table")
    t:eq(byPath.matchSize, true, "and matchSize defaults to taking the texture's own size")

    local byIcon = UI.Sprite{ icon = "Sheepball", from = "pal", matchSize = false }
    t:eq(byIcon.icon, "Sheepball", "a content id is carried as declared")
    t:eq(byIcon.from, "pal", "in the catalog that was named")
    t:eq(byIcon.matchSize, false, "and matchSize can be turned off for a laid-out sprite")

    t:errors(function() UI.Sprite{ from = "weapons" } end, "must be one of")
    t:errors(function() UI.Sprite{ icon = "" } end, "must be a non-empty string")
    t:errors(function() UI.Sprite{ UI.Label{} } end, "UI.Sprite holds no children")
end)

s:test("a Frame wraps ONE child and REFUSES a colour, naming Border instead", function(t)
    local f = UI.Frame{ UI.Label{ text = "inside" } }
    t:eq(f.kind, "frame", "it is a frame")
    t:eq(#f.children, 1, "with its one child")
    t:errors(function() UI.Frame{ UI.Label{}, UI.Label{} } end, "UI.Frame holds ONE child, 2 given")

    -- ⚠️ THE CORRECTION A LIVE RUN PAID FOR. `color` used to be declared here as "the FALLBACK
    -- Border's tint", i.e. a field that did something in the rare case and nothing in the
    -- ordinary one — and a run duly reported a Frame that drew black with a colour on it. A
    -- field that silently does nothing is the defect class this vocabulary exists to prevent, so
    -- it is refused with a sentence that names the node that DOES take a colour.
    t:errors(function() UI.Frame{ color = { 1, 0, 0, 1 }, UI.Label{} } end, "takes no colour")
    t:errors(function() UI.Frame{ color = { 1, 0, 0, 1 }, UI.Label{} } end, "Border{ color =")
    t:truthy(schema.get("UI.Node.Frame"):field("color").doc:find("REFUSED", 1, true),
        "and the field's own doc says so, so an editor shows it before the call is made")
    -- A Border still takes one, which is the whole point of the redirection.
    t:eq(UI.Border{ color = { 1, 0, 0, 1 } }.color[1], 1, "a Border's colour IS the border")
end)

s:test("a Label can ask for the game's OWN label widget", function(t)
    local n = UI.Label{ text = "hi", native = true }
    t:eq(n.native, true, "`native` is carried on the node")
    t:eq(UI.Label{ text = "hi" }.native, nil, "and is absent, not false, when not asked for")
    t:errors(function() UI.Label{ native = "yes" } end, "expects boolean, got string")
end)

s:test("native/ui/tree can build both new kinds, and api/ui publishes both", function(t)
    local makers = native.tree.kinds()
    t:truthy(makers.sprite, "tree builds a sprite")
    t:truthy(makers.frame, "tree builds a frame")
    t:eq(UI.Sprite.kind, "sprite", "UI.Sprite says what it builds without being called")
    t:eq(UI.Frame.kind, "frame", "so does UI.Frame")
end)

s:test("a Button may ask for a LEFT-aligned label, which is a second construction", function(t)
    -- ⚠️ READ THE CLOSED ITEM BEFORE READING THIS AS A REOPENING. `ui-menubutton-inner-slot`
    -- established, by reading WBP_Title_MenuButton's own template tree, that the game button's
    -- inner HorizontalBox_0 sits in a CanvasPanelSlot — the one slot class of the six that
    -- declares no SetHorizontalAlignment (UMG.hpp:350-374) — so the label cannot be moved through
    -- the button's own slot, ever. That is still true and that item stays closed.
    --
    -- `labelAlign = "left"` does not touch the button's inside at all: native/ui/tree builds
    -- _widget.clickableRow instead, which is an Overlay holding the same game button stretched to
    -- FILL with a TextBlock of ours over the top at ESlateVisibility HitTestInvisible, so the
    -- clicks pass through and the alignment happens on an OverlaySlot — a slot class that DOES
    -- declare it. That row is not new code; it is what the shipped two-pane Mod Manager was built
    -- out of. What is new is that a DECLARED tree can reach it, which is what gave clickableRow
    -- its first live caller.
    t:eq(UI.Button{ text = "x" }.labelAlign, "center",
        "the default is the game button alone, which is what every existing tree gets")
    local left = UI.Button{ text = "Refresh", labelAlign = "left" }
    t:eq(left.labelAlign, "left", "and an author may ask for the overlay row instead")
    t:errors(function() UI.Button{ text = "x", labelAlign = "right" } end, "must be one of")
    -- The doc string is what the generated types and the docs site reproduce, so the cost of the
    -- opt-in has to be IN it rather than only in this file's prose.
    local doc = schema.get("UI.Node.Button"):field("labelAlign").doc
    t:truthy(doc:find("CanvasPanelSlot", 1, true),
        "the doc names why the button's own slot cannot do it")
    t:truthy(doc:find("hit-test-invisible", 1, true) or doc:find("Overlay", 1, true),
        "and what the alternative actually builds")
end)

--=============================================================================
-- `input` — how much of the player's mouse an element takes
--
-- Every case here is pure: the field is validated in api/ui and the engine calls live in
-- _widget, so what an element DECLARES and what the lifecycle does with it are both provable
-- with no game. Whether Palworld's CommonUI action router actually reads a declaration off a
-- widget of ours is not — that is the in-game run (pf_uiroute, then pf_uiz).
--=============================================================================

s:test("`input` defaults to none: an element takes nothing unless it asked", function(t)
    local El = UI{ id = support.id("ui_input_default") }
    t:eq(El:state().inputMode, "none", "the default is the SAFE one — nobody's mouse is touched")
    local Grab = UI{ id = support.id("ui_input_clicks"),
                     input = "clicks", root = UI.Frame{ UI.Label{ text = "x" } } }
    t:eq(Grab:state().inputMode, "clicks", "and an element that wants clicks says so")
end)

-- ⚠️ THE FINDING THIS WHOLE SESSION TURNED ON. Palworld never calls SetInputMode when a menu
-- opens: every screen is a UPalActivatableWidget and DECLARES the mode it wants as a byte on
-- itself (InputConfig, Pal.hpp:13369), and CommonUI's action router applies it on activation and
-- puts it back on deactivation. Writing the mode onto the player controller instead broke Esc in
-- two live runs. So the modes that need the router need an activatable — and UI.Frame is the one
-- node here that builds one (WBP_PalCommonWindow_C is a UPalUserWidget).
s:test("`input` modes that need the game's router are refused without a Frame root", function(t)
    for _, mode in ipairs({ "clicks", "exclusive" }) do
        t:errors(function()
            UI{ id = support.id("ui_input_noframe"), input = mode,
                root = UI.VBox{ UI.Label{ text = "x" } } }
        end, "ACTIVATABLE WIDGET")
        t:errors(function()
            UI{ id = support.id("ui_input_noframe2"), input = mode,
                root = UI.Border{ UI.Label{ text = "x" } } }
        end, "UI.Frame")
    end
    -- With a Frame it is accepted, and so is `backHandler`, which lands on the same widget.
    local ok = UI{ id = support.id("ui_input_frame"), input = "exclusive", backHandler = true,
                   root = UI.Frame{ UI.Label{ text = "x" } } }
    t:eq(ok:state().inputMode, "exclusive", "a Frame-rooted element may declare the modal mode")
    t:eq(ok:state().backHandler, true, "and may claim the CommonUI back action")
    -- The two vocabularies — api/ui's declared names and _widget's translation of them into what
    -- a Palworld screen declares — are separate on purpose (api/ui makes no engine call), so the
    -- one thing that can drift is the NAME LIST. Assert it here rather than discovering it live.
    for _, name in ipairs(schema.get("UI.Spec"):field("input").values) do
        t:truthy(widget.INPUT_MODES[name],
            string.format("_widget knows what %q means to the game", name))
    end
end)

s:test("`backHandler` without a Frame root is refused, and says which flag it needs", function(t)
    t:errors(function()
        UI{ id = support.id("ui_back_noframe"), backHandler = true,
            root = UI.VBox{ UI.Label{ text = "x" } } }
    end, "bIsBackHandler")
end)

s:test("\"layer\" is a host name, and an unknown one names it in the complaint", function(t)
    local El = UI{ id = support.id("ui_host_layer"), host = "layer",
                   root = UI.Frame{ UI.Label{ text = "x" } } }
    t:eq(El:state().hostSpec, "layer", "the game's own CommonUI-layer route is declarable")
    t:errors(function() UI{ id = support.id("ui_host_bad"), host = "canvas" } end, "\"layer\"")
end)

s:test("host = \"layer\" needs a Frame root, and is refused at define time without one",
function(t)
    -- ⚠️ THE RULE WAS DOCUMENTED IN TWO PLACES AND ENFORCED IN NEITHER. Both UI.Spec's `host`
    -- doc and native/ui/tree.host's own comment said a layer requires a Frame root "and says so
    -- rather than half-working"; until 2026-08-02 nothing said so. A VBox-rooted host = "layer"
    -- passed define, resolved a host with no panel, and failed at MOUNT with a message about the
    -- host not accepting the tree's root — which names the symptom and not the rule, and only
    -- ever in a session with the in-game layout up. It now joins `input` and `backHandler` in the
    -- one define-time check, because all three want the same thing for the same reason: only a
    -- UI.Frame builds a Palworld activatable, and a CommonUI layer takes nothing else.
    for _, bad in ipairs({ UI.VBox{ UI.Label{ text = "x" } }, UI.Border{ UI.Label{ text = "x" } } }) do
        t:errors(function()
            UI{ id = support.id("ui_layer_noframe"), host = "layer", root = bad }
        end, "ACTIVATABLE WIDGET")
    end
    -- And the refusal tells the author the rest of it: satisfying the rule is not yet known to
    -- buy anything, and it names the runs that would settle that.
    local _, err = pcall(function()
        UI{ id = support.id("ui_layer_noframe2"), host = "layer",
            root = UI.VBox{ UI.Label{ text = "x" } } }
    end)
    err = tostring(err)
    t:truthy(err:find("NEVER ONCE BEEN OBSERVED WORKING", 1, true),
        "the refusal says the capability is unmeasured, not merely mis-declared")
    t:truthy(err:find("pf_uiz", 1, true) and err:find("pf_uiroute", 1, true),
        "and names the two runs that would settle it")
    t:truthy(err:find("test/hooks/ui-host-layer", 1, true)
             and err:find("test/hooks/ui-backhandler", 1, true),
        "and the hook ids that record the answer, so a grep finds the pair")

    -- An element with NO declared root is not refused: the check is about what a DECLARED tree
    -- builds, and an imperative render is responsible for its own widgets. Same shape as the
    -- `input` check beside it, and asserted so the asymmetry is deliberate rather than a hole.
    t:truthy(UI{ id = support.id("ui_layer_imperative"), host = "layer",
                 render = function() end },
        "an imperative element may declare a layer host; nothing here can vet what it builds")
end)

s:test("an input mode outside the list is refused at define time", function(t)
    t:errors(function() UI{ id = support.id("ui_input_bad"), input = "mouse" } end, "must be one of")
    t:errors(function() UI{ id = support.id("ui_input_bad2"), input = true } end,
        "expects string, got boolean")
end)

s:test("mounting with input = none never reaches the engine, and unmount is still clean",
function(t)
    local El = UI{ id = support.id("ui_input_none"), render = function() end }
    local el = El:new{}
    t:eq(el:mount(fakeRoot()), true, "it mounts")
    t:eq(el:state()._input, nil, "and holds no input grab at all")
    t:eq(el:state():releaseInput(), false, "releasing nothing is a false, not an error")
    el:unmount()
    t:eq(el:isMounted(), false, "and it comes down as usual")
end)

s:test("an element that asks for the mouse and cannot get it says so and stays clean",
function(t)
    support.needNoEngine(t, "an owner exists, so the grab would succeed and really move the "
        .. "player's cursor rather than reporting that it could not be taken")
    local El = UI{ id = support.id("ui_input_nogame"), input = "clicks",
                   render = function() end }
    local el = El:new{}
    t:eq(el:mount(fakeRoot()), true, "the render succeeded, so the element is mounted")
    t:eq(el:state()._input, nil, "but with no PlayerController there is no grab to hold")
    -- The point: a mount that could not take the mouse is still a mount. Failing to grab is
    -- never allowed to unmount a panel that drew.
    t:eq(el:isMounted(), true, "and the element is NOT taken down over it")
    el:unmount()
end)

s:test("a render that reports failure gives the mouse back on the way out", function(t)
    local El = UI{ id = support.id("ui_input_failrender"), input = "clicks",
                   render = function() return false end }
    local el = El:new{}
    t:eq(el:mount(fakeRoot()), false, "the render could not build")
    t:eq(el:state()._input, nil, "so nothing is left holding the player's input")
    t:eq(el:isMounted(), false, "and the element stays unmounted, so mount() retries")
end)

--=============================================================================
-- `z` and the EVENT ROUTING RULE — two overlapping panels, with no game and no keyboard
--
-- The whole point of putting the stack in api/ui rather than in the engine seam is that the
-- rule is decidable without either: a list of tables, a number each, and two walks over it.
-- So every case below asserts the rule ITSELF — who gets the press — by routing through the
-- same entry point an arriving key uses (UI.routeKey / UI.routeMouse), rather than by pressing
-- anything. Whether a key can arrive at all is a different question and is not answerable here;
-- native/ui/keys.lua owns it and says so in words.
--
-- The elements mount onto FAKE roots at absurd z values (9000+), so they are the top of any
-- stack they find themselves in — and the cases that need to own the whole stack say so and
-- skip rather than assert against somebody else's mounted panel.
--=============================================================================

-- The routing rule is about WHO IS TOP, so a case that asserts it needs the stack to itself.
-- In a headless run this is always true; in a live session with a panel already up it is not,
-- and a skip is the honest answer rather than a failure about somebody else's element.
local function ownStack(t)
    if #UI.stack() > 0 then
        t:skip("SKIPPED THE EMPTY-STACK DIRECTION — " .. #UI.stack() .. " UI element(s) are "
            .. "already mounted and this case asserts against a stack it owns. It is INVERSE-"
            .. "gated on state rather than on a world: headless the stack is always empty, and in "
            .. "a live session with a panel up (pf_uiz leaves three) it is not. Unmount them, or "
            .. "run F1 in a session where nothing has mounted, to cover this half.")
    end
end

-- Mount `n` declared-nothing elements with the given z values and handlers, and hand back the
-- instances plus a teardown. Every case unmounts, because a leaked mounted element would sit at
-- the top of the stack for every case after it.
local function mountAt(spec)
    local El = UI{ id = support.id(spec.what or "z"), z = spec.z,
                   keys = spec.keys, onKeyPressed = spec.onKey,
                   buttons = spec.buttons, onMousePressed = spec.onMouse,
                   render = function() end }
    local el = El:new{ hits = 0 }
    el:mount(fakeRoot())
    return el
end

s:test("`z` defaults to 0, is carried on the class, and is refused when it is not a number",
function(t)
    local El = UI{ id = support.id("ui_z_default") }
    t:eq(El:state().zOrder, 0, "an element that did not ask sits at 0")
    local Up = UI{ id = support.id("ui_z_up"), z = 40 }
    t:eq(Up:state().zOrder, 40, "and one that did carries what it declared")
    t:errors(function() UI{ id = support.id("ui_z_bad"), z = "top" } end,
        "expects number, got string")
end)

s:test("a handler and the names it listens to are ONE declaration: half of one is refused",
function(t)
    local f = function() end
    t:errors(function() UI{ id = support.id("ui_k1"), onKeyPressed = f } end,
        "declares onKeyPressed but no `keys`")
    t:errors(function() UI{ id = support.id("ui_k2"), keys = { "INS" } } end,
        "declares `keys` but no onKeyPressed")
    t:errors(function() UI{ id = support.id("ui_k3"), onMousePressed = f } end,
        "declares onMousePressed but no `buttons`")
    t:errors(function() UI{ id = support.id("ui_k4"), buttons = { "left" } } end,
        "declares `buttons` but no onMousePressed")
end)

s:test("a key list and a button list are checked where they are written", function(t)
    local f = function() end
    t:errors(function() UI{ id = support.id("ui_k5"), keys = {}, onKeyPressed = f } end,
        "is empty")
    t:errors(function() UI{ id = support.id("ui_k6"), keys = { 4 }, onKeyPressed = f } end,
        "entry 1 is a number")
    t:errors(function()
        UI{ id = support.id("ui_k7"), buttons = { "scroll" }, onMousePressed = f }
    end, "the buttons are \"left\", \"right\" and \"middle\"")
    -- Names are normalised once, at define time, so neither router does string work per press.
    local El = UI{ id = support.id("ui_k8"), keys = { "ins" }, onKeyPressed = f,
                   buttons = { "MIDDLE" }, onMousePressed = f }
    t:eq(El:state().keySet.INS, true, "a key name is upper-cased the way UE4SS spells one")
    t:eq(El:state().buttonSet.middle, true, "and a button name is lower-cased the way a pack writes one")
end)

s:test("the stack is ordered by z, and by mount order among equals", function(t)
    ownStack(t)
    local low  = mountAt{ what = "z_low",  z = 9001 }
    local high = mountAt{ what = "z_high", z = 9003 }
    local mid  = mountAt{ what = "z_mid",  z = 9002 }
    local tie  = mountAt{ what = "z_tie",  z = 9003 }   -- same z as `high`, mounted later

    local rows = UI.stack()
    t:eq(#rows, 4, "every mounted element is in the stack")
    t:eq(rows[1].id, tie:state().id, "equal z: the most recently mounted is on top, as a canvas draws it")
    t:eq(rows[2].id, high:state().id, "then the earlier one at that same z")
    t:eq(rows[3].id, mid:state().id, "then the next z down")
    t:eq(rows[4].id, low:state().id, "and the lowest z last")

    tie:unmount(); high:unmount(); mid:unmount(); low:unmount()
    t:eq(#UI.stack(), 0, "unmounting takes an element out of the stack")
end)

s:test("a KEY reaches only the topmost element — a covered panel does not get it", function(t)
    ownStack(t)
    local bottomHits, topHits = 0, 0
    local bottom = mountAt{ what = "z_kb", z = 9010, keys = { "INS" },
                            onKey = function() bottomHits = bottomHits + 1 end }
    local top    = mountAt{ what = "z_kt", z = 9020, keys = { "INS" },
                            onKey = function() topHits = topHits + 1 end }

    local who, why = UI.routeKey("INS")
    t:eq(who, top:state().id, "the top element took it")
    t:eq(topHits, 1, "its handler ran once")
    t:eq(bottomHits, 0, "and the one underneath never saw the key")
    t:truthy(why:find("->", 1, true), "the reason says where it went: " .. tostring(why))

    top:unmount()
    who = UI.routeKey("INS")
    t:eq(who, bottom:state().id, "with the top one gone the key falls to what is now topmost")
    t:eq(bottomHits, 1, "and its handler runs")
    bottom:unmount()
end)

s:test("a key is BLOCKED by a higher panel that does not want it, rather than falling through",
function(t)
    ownStack(t)
    local hits = 0
    local wants = mountAt{ what = "z_kw", z = 9010, keys = { "INS" },
                           onKey = function() hits = hits + 1 end }
    -- Declares no keys at all: it is not listening, and it still covers what is underneath.
    local cover = mountAt{ what = "z_kc", z = 9020 }

    local who, why = UI.routeKey("INS")
    t:eq(who, nil, "nothing took the key")
    t:eq(hits, 0, "the element that wanted it is covered, so it did not run")
    t:truthy(why:find("blocked by", 1, true), "and the reason names the blocker: " .. tostring(why))
    t:truthy(why:find(tostring(cover:state().id), 1, true), "by id, so it is actionable")

    cover:unmount()
    t:eq(UI.routeKey("INS"), wants:state().id, "uncovered, the same key now arrives")
    t:eq(hits, 1, "and the handler runs")
    wants:unmount()
end)

s:test("a MOUSE press goes to the topmost element that WANTS it, and stops there", function(t)
    ownStack(t)
    local bottomHits, midHits = 0, 0
    local bottom = mountAt{ what = "z_mb", z = 9010, buttons = { "middle" },
                            onMouse = function() bottomHits = bottomHits + 1 end }
    local mid    = mountAt{ what = "z_mm", z = 9020, buttons = { "middle" },
                            onMouse = function() midHits = midHits + 1 end }
    -- The difference from the key rule, in one element: this one is on top and declares no
    -- interest in the mouse, so it is TRANSPARENT to a press where it would BLOCK a key.
    local top    = mountAt{ what = "z_mt", z = 9030, keys = { "INS" }, onKey = function() end }

    local who, why = UI.routeMouse("middle")
    t:eq(who, mid:state().id, "the topmost element that declared the button took it")
    t:eq(midHits, 1, "its handler ran")
    t:eq(bottomHits, 0, "and the press stopped there rather than carrying on down")

    -- ...while a key at the same moment is blocked by the very element the press ignored.
    local keyWho = UI.routeKey("INS")
    t:eq(keyWho, top:state().id, "the same stack routes a key to the top element instead")
    t:truthy(why:find("->", 1, true), "the mouse reason says where it went: " .. tostring(why))

    top:unmount(); mid:unmount(); bottom:unmount()
end)

s:test("a press that nobody declared is reported, not swallowed", function(t)
    ownStack(t)
    local who, why = UI.routeMouse("left")
    t:eq(who, nil, "with nothing mounted, nothing takes it")
    t:truthy(why:find("no PalForge element is mounted", 1, true), tostring(why))

    local el = mountAt{ what = "z_none", z = 9040, keys = { "INS" }, onKey = function() end }
    who, why = UI.routeMouse("right")
    t:eq(who, nil, "and an element that wants a key does not thereby want a button")
    t:truthy(why:find("none of them declared onMousePressed", 1, true), tostring(why))
    el:unmount()
end)

s:test("the handler is called (self, ctx) with the instance and what was pressed", function(t)
    ownStack(t)
    local seenSelf, seenCtx
    local el = mountAt{ what = "z_ctx", z = 9050, keys = { "END" },
                        onKey = function(self, ctx) seenSelf, seenCtx = self, ctx end }
    UI.routeKey("end")   -- routed in whatever case it arrives; the router normalises
    t:eq(seenSelf, el:state(), "`self` is the element INSTANCE, as everywhere else in this tree")
    t:eq(seenCtx.key, "END", "ctx names the key")
    t:eq(seenCtx.z, 9050, "and the z it was routed at")
    t:eq(seenCtx.id, el:state().id, "and which element is being told")
    el:unmount()
end)

s:test("a handler that raises is reported and does not break the next press", function(t)
    ownStack(t)
    local after = 0
    local bad = mountAt{ what = "z_bad", z = 9060, keys = { "INS" },
                         onKey = function() error("handler is broken", 0) end }
    local who, why = UI.routeKey("INS")
    t:eq(who, nil, "a raising handler did not take the press")
    t:truthy(why:find("raised", 1, true), "and the reason says so: " .. tostring(why))
    bad:unmount()

    local good = mountAt{ what = "z_good", z = 9060, keys = { "INS" },
                          onKey = function() after = after + 1 end }
    t:eq(UI.routeKey("INS"), good:state().id, "the router is still working afterwards")
    t:eq(after, 1, "and the next element's handler ran")
    good:unmount()
end)

s:test("UI.report prints the stack, the key binds, the grabs AND the keymap it read", function(t)
    ownStack(t)
    local el = mountAt{ what = "z_report", z = 9070, keys = { "INS" }, onKey = function() end }
    local lines = table.concat(UI.report(), "\n")
    t:truthy(lines:find(tostring(el:state().id), 1, true), "the mounted element is listed")
    t:truthy(lines:find("z=9070", 1, true), "with its z")
    t:truthy(lines:find("keys=INS", 1, true), "and the keys it asked for")

    -- ⚠️ THE FOURTH BLOCK, WHICH WAS MISSING. native/ui/tree.keymapReport was written alongside
    -- keyReport and grabReport and left out of api/ui's list of sources, so the one report an
    -- operator is told to paste stated a conclusion ("never arrived AND THE GAME HAS AN ACTION ON
    -- IT") with no sign of the reading it came from. Asserted by its own prefix rather than by a
    -- key name, because headless there is nothing to read and the keymap's honest answer is the
    -- source lines plus "NOTHING HAS BEEN READ" — which is exactly the block that has to be there.
    t:truthy(lines:find("keys: ", 1, true), "the key-bind block is in the report")
    t:truthy(lines:find("keymap: ", 1, true),
        "and so is the keymap block the attribution is drawn from")

    el:unmount()
    t:truthy(table.concat(UI.report(), "\n"):find("no element is mounted", 1, true),
        "and an empty stack says so rather than printing nothing")
end)

s:test("Esc is refused by name: nothing here goes between the player and the game's menu",
function(t)
    -- The one hard rule the whole input design exists for. A UI element may ask for Esc; the
    -- engine seam refuses it, and the refusal carries the reason rather than a silent no-bind.
    t:type(native.keys.FORBIDDEN.ESCAPE, "string", "the refusal is declared with its reason")
    local recs = native.keys.arm({ keys = { "ESCAPE" }, onKey = function() end })
    t:eq(#recs, 1, "one record came back for the one name")
    t:eq(recs[1].state, "refused", "and it was refused rather than armed")
    t:truthy(recs[1].why:find("close", 1, true) or recs[1].why:find("Esc", 1, true),
        "with the mandate as the reason: " .. tostring(recs[1].why))
    t:truthy(table.concat(native.keys.report(), "\n"):find("ESCAPE", 1, true),
        "and it is visible in the report rather than only in this test")
end)

s:test("setZ says which hosts have a z and which do not, without touching a game", function(t)
    local ok, why = native.tree.setZ(nil, 10)
    t:eq(ok, false, "there is nothing to order when the host handed back no slot")
    t:type(why, "string", "and the reason is a sentence: " .. tostring(why))
    t:eq(native.tree.SCREEN_BASE_Z, 1000,
        "a screen host still sits where every shipped PalForge screen sat, with z added to it")
end)

--=============================================================================
-- IS THIS KEY FREE — the keymap, the three cases, and the deliberate override
--
-- WHY THESE CASES ARE IN THE UI FILE. The keyboard is reached from exactly one declarative
-- surface (UI.Spec's `keys` / `overrideKeys`), it is the surface that pays for a wrong answer,
-- and this file is where the rest of that surface is already proved. The modules under test are
-- core/keyboard/base/{keymap,registory}.lua.
--
-- WHAT IS PROVABLE WITH NO GAME, WHICH IS MORE THAN IT LOOKS:
--   * the NAME TRANSLATION, in full. UE4SS binds by Microsoft virtual-key name ("INS") and
--     Unreal names the same key "Insert"; a lookup that forgets this finds nothing and reports
--     every key free, which is worse than reporting nothing. That map is pure data.
--   * the REFUSAL RULES: Esc always, our own keys always, the game's keys unless overridden.
--   * the ATTRIBUTION, by installing a synthetic reading. The whole point of the rewrite is that
--     `arrived = 0` now says something different depending on what the game has on the key, and
--     "different" is exactly what a test can assert.
--
-- What is NOT provable here: that any of it reads a real Palworld. That needs a loaded world and
-- it is what the pf_keys action exists for.
--=============================================================================

local keymap      = require("palforge.core.keyboard.base.keymap")
local reg         = require("palforge.core.keyboard.base.registory")
local actionNames = require("palforge.core.keyboard.base.actions")

-- Install a synthetic keymap reading for the body of one test, and put the real state back
-- afterwards whatever happens. Everything the status logic reads lives on keymap.state, so this
-- is an honest substitution rather than a mock of the thing under test: the same code path runs,
-- over an index somebody else filled in.
local function withKeymap(index, fn)
    local st = keymap.state
    local saved = { index = st.index, actions = st.actions, read = st.read, at = st.at,
                    dirty = st.dirty, tried = st.tried }
    -- `tried` as well as `at`: the staleness bound is on the last ATTEMPT now (keymap.snapshot's
    -- header says why — a failed read used to be re-attempted on every single question, so
    -- keymap.lookup's 156 questions were 156 full refreshes). Leaving it nil here would make
    -- every status() inside the body re-read the game, which headless is harmless and in a live
    -- run would not be.
    st.index, st.actions, st.read, st.dirty = index, {}, true, false
    st.at, st.tried = os.clock(), os.clock()
    local ok, err = pcall(fn)
    st.index, st.actions, st.read, st.at, st.dirty, st.tried =
        saved.index, saved.actions, saved.read, saved.at, saved.dirty, saved.tried
    if not ok then error(err, 0) end
end

-- ⚠️ SYNTHETIC KEY NAMES, AND THEY ARE NOT A SHORTCUT. Every case below that ARMS something runs
-- in a live game too — F1 is the test runner — and UE4SS has no unregister, so a case that armed
-- a real key would take it for the rest of the session and leave a dead record pointing at a
-- torn-down element. These names are not in UE4SS's Key table, so the bind is refused in EVERY
-- environment for the same reason and the case reads identically headless and in game. Routing
-- does not care: api/ui routes on the declared name, never on an engine code.
local FAKE_TAKEN, FAKE_A, FAKE_B = "PALFORGE_TEST_TAKEN", "PALFORGE_TEST_KEY_A", "PALFORGE_TEST_KEY_B"

-- Give a synthetic name an FKey spelling for the length of one test, so it is answerable at all
-- (a name the map cannot translate is "unknown", which is a different case from "the game has
-- it"). Restores whatever was there, which is nil.
local function withFakeName(name, fkey, fn)
    local saved = keymap.FKEY[name]
    keymap.FKEY[name] = fkey
    local ok, err = pcall(fn)
    keymap.FKEY[name] = saved
    if not ok then error(err, 0) end
end

s:test("every UE4SS key name translates to an Unreal FKey name, or says it cannot", function(t)
    -- The two spellings, on the keys where they disagree. Each of these was a silent miss
    -- waiting to happen: "SPACE" is never found in a keymap that spells it "SpaceBar".
    local pairsOf = {
        { "INS", "Insert" }, { "DEL", "Delete" }, { "SPACE", "SpaceBar" },
        { "RETURN", "Enter" }, { "BACKSPACE", "BackSpace" }, { "LEFT_ARROW", "Left" },
        { "NUM_ZERO", "NumPadZero" }, { "ZERO", "Zero" }, { "PAGE_UP", "PageUp" },
        { "LEFT_MOUSE_BUTTON", "LeftMouseButton" }, { "XBUTTON_ONE", "ThumbMouseButton" },
    }
    for _, p in ipairs(pairsOf) do
        local fkey, how = keymap.translate(p[1])
        t:eq(fkey, p[2], p[1] .. " is Unreal's " .. p[2])
        t:eq(how, "known", "and that is a fact about the naming, not an assumption")
    end
    -- The families that agree letter for letter still have to be present, or they fall into the
    -- unknown bucket and every letter key becomes unanswerable.
    t:eq(keymap.translate("A"), "A", "a letter key is spelled the same in both")
    t:eq(keymap.translate("F5"), "F5", "and so is a function key up to F12")

    -- The OEM punctuation keys name a POSITION, not a character, so the mapping is a
    -- layout assumption and is reported as one rather than as a measurement.
    local comma, how = keymap.translate("OEM_COMMA")
    t:eq(comma, "Comma", "OEM_COMMA is the comma on a US layout")
    t:eq(how, "layout", "and the answer says it is assuming a layout")

    -- Absence is an answer too, and it must never degrade into the identity: "VOLUME_UP" is a
    -- real UE4SS key with no Unreal FKey at all, and a fallback that returned "VOLUME_UP" would
    -- look it up, miss, and report the key free on the strength of a name nobody uses.
    t:eq(keymap.translate("VOLUME_UP"), nil, "a key Unreal has no FKey for translates to nothing")
    t:eq(keymap.translate("F13"), nil, "Unreal's EKeys stops at F12, so F13 is unanswerable")
    t:eq(keymap.translate("NOT_A_KEY_AT_ALL"), nil, "and so is a name that is not a key")
    t:eq(select(2, keymap.translate("NOT_A_KEY_AT_ALL")), "none", "with 'none' as the confidence")
end)

s:test("the name map is internally consistent, and covers every key UE4SS can bind", function(t)
    -- ⚠️ THIS CASE HAD TWO HALVES AND ONLY ONE OF THEM EXISTED. The coverage assertion below
    -- needs UE4SS's `Key` table, so headless the whole case skipped — and this is the ONLY guard
    -- against keymap.FKEY drifting from that table (keymap.lookup iterates FKEY while its own doc
    -- at keymap.lua:1191 says "one row per entry in UE4SS's Key table", so a Key name absent from
    -- FKEY is missing from the operator's report entirely rather than shown as unknown). An
    -- invariant asserted only in-game is an invariant nobody runs.
    --
    -- So the SHAPE half now runs everywhere. It cannot know what UE4SS ships — nothing headless
    -- can — but every one of these is a way FKEY has actually been wrong or could silently become
    -- wrong, and each is decidable from the table alone.
    local names, blank, dupeTarget = {}, 0, {}
    local byFKey = {}
    for name, fkey in pairs(keymap.FKEY) do
        names[#names + 1] = name
        if type(name) ~= "string" or #name == 0 then blank = blank + 1 end
        -- A value may be `false` — that is the DELIBERATE "UE4SS binds this name and Unreal has
        -- no FKey for it" row (VOLUME_UP), which is a different answer from a missing row and
        -- must stay expressible. Anything that is neither a non-empty string nor false is a typo.
        if fkey ~= false and (type(fkey) ~= "string" or #fkey == 0) then
            blank = blank + 1
        end
        if type(fkey) == "string" then
            byFKey[fkey] = byFKey[fkey] or {}
            table.insert(byFKey[fkey], name)
        end
    end
    t:truthy(#names > 100, "the map is populated at all: " .. #names .. " row(s)")
    t:eq(blank, 0, "every row is a non-empty name mapped to an FKey name or an explicit false")

    -- TWO UE4SS NAMES POINTING AT ONE FKEY is the shape of a copy-paste slip, and it is not
    -- harmless: keymap.status builds its index by FKey, so the second name would answer with the
    -- first one's action and report a free key as taken (or the reverse). Collected rather than
    -- counted, so the failure names the pair.
    for fkey, owners in pairs(byFKey) do
        if #owners > 1 then
            table.sort(owners)
            dupeTarget[#dupeTarget + 1] = fkey .. " <- " .. table.concat(owners, " and ")
        end
    end
    t:eq(#dupeTarget, 0, "no two UE4SS names claim the same Unreal FKey: "
        .. table.concat(dupeTarget, "; "))

    -- Every row has to be ANSWERABLE through the public route, not merely present in the table:
    -- translate() is what status() calls, and a row it disagrees with is a row that reads fine
    -- here and does nothing in the report.
    local disagree = {}
    for name, fkey in pairs(keymap.FKEY) do
        local got = keymap.translate(name)
        if got ~= (fkey or nil) then
            disagree[#disagree + 1] = string.format("%s: FKEY says %s, translate says %s",
                name, tostring(fkey), tostring(got))
        end
    end
    t:eq(#disagree, 0, "translate() agrees with the table for every row: "
        .. table.concat(disagree, "; "))

    -- The names this tree binds by hand must each be a row, or the check "is this key free"
    -- answers "unknown" for a key PalForge itself is using. Esc is here because it is refused BY
    -- NAME and the refusal has to have a name to match.
    for _, name in ipairs({ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
                            "ESCAPE", "INS", "DEL", "END", "LEFT_MOUSE_BUTTON",
                            "RIGHT_MOUSE_BUTTON", "MIDDLE_MOUSE_BUTTON" }) do
        t:truthy(keymap.FKEY[name] ~= nil, name .. " has a row in the name map")
    end

    -- The COVERAGE half, which is the one that needs the engine: only UE4SS knows what UE4SS will
    -- bind, and a name it grows that this map has never heard of is a name PalForge answers
    -- "unknown" for forever. It stays gated, and now it says which direction it went.
    local n = 0
    if type(Key) == "table" then for _ in pairs(Key) do n = n + 1 end end
    if n == 0 then
        -- skipUnanswerable, not a bare t:skip: the missing thing is UE4SS's own `Key` table, a
        -- native global, so no state the tester can put the GAME in would open this — which is
        -- what M.NEEDS.SESSION means and what separates it from the world/no-world pair. A bare
        -- skip lands in the "did not say which" bucket and the comment above would have been
        -- claiming a direction the summary could not print.
        t:skipUnanswerable("SKIPPED THE IN-GAME DIRECTION — the shape and self-consistency of keymap.FKEY "
            .. "were just asserted, which is everything decidable with no engine. What is left is "
            .. "COVERAGE against UE4SS's own Key table, and there is no Key table in this "
            .. "session, so it can only be checked from inside the game. Run F1 in a session with "
            .. "UE4SS loaded to close the other half.")
    end
    local missing = {}
    for name in pairs(Key) do
        if keymap.FKEY[name] == nil then missing[#missing + 1] = name end
    end
    t:eq(#missing, 0, "every UE4SS key name has a row: missing " .. table.concat(missing, ", "))
end)

s:test("with no reading, a key is 'unknown' and never 'free'", function(t)
    -- The failure this whole module exists to prevent, in one assertion. At the title screen the
    -- config cannot be read; answering "free" there would be a guess wearing a measurement's
    -- clothes, and the arm that trusted it would be the F7 story again.
    local st = keymap.state
    local saved = { read = st.read, at = st.at, dirty = st.dirty, index = st.index,
                    tried = st.tried }
    st.read, st.at, st.dirty, st.index = false, os.clock(), false, {}
    st.tried = os.clock()
    local ok, err = pcall(function()
        local s1 = keymap.status("INS")
        t:eq(s1.state, "unknown", "no reading means no answer")
        t:eq(s1.fkey, "Insert", "though the name still translates")
        t:truthy(s1.why:find("loaded world", 1, true), "and the reason names what is missing")
    end)
    st.read, st.at, st.dirty, st.index = saved.read, saved.at, saved.dirty, saved.index
    st.tried = saved.tried
    if not ok then error(err, 0) end
end)

s:test("a failed reading is cached for MAX_AGE, so one question is not one whole re-read",
function(t)
    -- ⚠️ THE REGRESSION THIS LOCKS DOWN COST A LIVE RUN 156 FULL REFRESHES AND SAID NOTHING.
    -- snapshot() used to call a reading stale whenever `state.read` was false — and `read` stays
    -- false for the whole of a session where the game is not readable (the title screen, or the
    -- first run of this module, which is exactly when it happened). keymap.lookup() asks
    -- status() once per bindable name, so a session that could read nothing re-read the game once
    -- per row. With the name look-up route now in that path it would be hundreds of engine calls
    -- per row. The bound is on the last ATTEMPT.
    local st = keymap.state
    local saved = { read = st.read, at = st.at, dirty = st.dirty, index = st.index,
                    tried = st.tried }
    local calls, realRefresh = 0, keymap.refresh
    keymap.refresh = function() calls = calls + 1; return realRefresh() end
    local ok, err = pcall(function()
        st.read, st.at, st.index, st.dirty = false, nil, {}, false
        st.tried = os.clock()
        for _ = 1, 20 do keymap.snapshot() end
        t:eq(calls, 0, "a fresh failure is not re-attempted on every question")

        st.tried = os.clock() - (keymap.MAX_AGE + 1)
        keymap.snapshot()
        t:eq(calls, 1, "and once it is older than MAX_AGE seconds it is attempted again")

        -- The flag the change hooks set still forces one immediately, whatever the clock says.
        calls, st.dirty = 0, true
        keymap.snapshot()
        t:eq(calls, 1, "a config change re-reads at once rather than waiting out the bound")
    end)
    keymap.refresh = realRefresh
    st.read, st.at, st.dirty, st.index, st.tried =
        saved.read, saved.at, saved.dirty, saved.index, saved.tried
    if not ok then error(err, 0) end
end)

s:test("the FKey names are cross-checked against Palworld's own key-icon table", function(t)
    -- INDEPENDENT EVIDENCE, and the only kind available headless. keymap.M.FKEY's right-hand
    -- column is Unreal's spelling of each key, and a typo there is invisible until it silently
    -- reports a taken key as free. DT_PalRichTextControlKeyIcon's 117 row names are the same
    -- namespace written by the GAME (dumps/catalog/datatables/DT_PalRichTextControlKeyIcon.json),
    -- so anything we spell that the game also spells has to match exactly.
    --
    -- ⚠️ ABSENCE PROVES NOTHING HERE. It is a KEYBOARD icon table: it has no LeftMouseButton, no
    -- ThumbMouseButton, and nothing for a key Palworld never draws. So the assertion is only over
    -- names the table DOES carry, and the rest are counted rather than failed.
    local shipped = {}
    for _, n in ipairs(actionNames.KEY_NAMES) do shipped[n] = true end
    -- Case-insensitive index, so a mis-CASED spelling is caught rather than passing as "absent".
    local byLower = {}
    for n in pairs(shipped) do byLower[n:lower()] = n end

    local checked, uncovered, wrong = 0, 0, {}
    for ue4ss, fkey in pairs(keymap.FKEY) do
        if type(fkey) == "string" then
            if shipped[fkey] then
                checked = checked + 1
            elseif byLower[fkey:lower()] then
                wrong[#wrong + 1] = string.format("%s -> %q, and the game spells it %q",
                    ue4ss, fkey, byLower[fkey:lower()])
            else
                uncovered = uncovered + 1
            end
        end
    end
    t:eq(#wrong, 0, "every FKey name the game also names is spelled the game's way: "
        .. table.concat(wrong, "; "))
    t:truthy(checked > 80, string.format("and the cross-check is worth something: %d name(s) "
        .. "matched the game's own table, %d are outside it (mouse buttons and keys Palworld "
        .. "draws no icon for, which proves nothing either way)", checked, uncovered))
end)

s:test("the candidate action names are Palworld's own, and every one of them is usable",
function(t)
    -- The look-up route can only ask about names it has. This asserts the shipped half is intact
    -- — 244 row names of DT_UIInputAction, non-empty, unique — because a truncated or duplicated
    -- list would quietly narrow what the keymap can ever find and nothing would say so.
    local names, rec = actionNames.names()
    t:truthy(#names >= 244, "at least the 244 shipped UI action names are available: " .. #names)
    t:type(rec.source, "string", "and the record says which copy answered: " .. tostring(rec.source))

    -- ⚠️ THE SOURCE IS AN ENVIRONMENT READING, AND THIS CASE IS NOT GATED ON IT. This was the
    -- third of the four checks that failed in both game states on 2026-08-02 — the assertion was
    -- the bare `t:eq(rec.source, "shipped", "headless there is no live table...")`, which is a
    -- claim about the ENGINE and is false the moment DT_UIInputAction can be resolved, save or
    -- no save. Everything ELSE this case asserts (non-empty, unique, really Palworld's actions)
    -- holds of whichever list answered and is worth MORE against the live one, so the case is
    -- not skipped in game: only the source claim is asked per environment, which is what
    -- _widget.gameUIRoot's case a few hundred lines up already does with its host.
    if support.engine() then
        t:truthy(rec.source == "live" or rec.source == "shipped",
            "with an engine either copy may answer, and the record says which: "
            .. tostring(rec.source) .. " — " .. tostring(rec.why))
    else
        t:eq(rec.source, "shipped",
            "with no engine there is no live table to resolve, so the shipped copy answers")
    end

    local seen, dupes, blank = {}, 0, 0
    for _, n in ipairs(names) do
        if type(n) ~= "string" or #n == 0 then blank = blank + 1 end
        if seen[n] then dupes = dupes + 1 end
        seen[n] = true
    end
    t:eq(blank, 0, "no empty name, which would be a Contains() call that asks nothing")
    t:eq(dupes, 0, "and no duplicate, which would be a look-up paid for twice")
    t:truthy(seen.OpenWorldMap and seen.UICancel and seen.Interact_1,
        "and they really are Palworld's UI actions, not a placeholder")
end)

s:test("a reading splits keys into taken-by-the-game and free, and names the action", function(t)
    withKeymap({
        insert = { key = "Insert", actions = { { action = "OpenInventory", via = "config/main" } } },
        w      = { key = "W",      actions = { { action = "MoveForward",   via = "config/axis" } } },
    }, function()
        local ins = keymap.status("INS")
        t:eq(ins.state, "game", "a key the config has an action on is the game's")
        t:eq(ins.actions[1].action, "OpenInventory", "and the action is named, not merely counted")
        t:truthy(ins.why:find("does not consume", 1, true),
            "with the sentence that says taking it does not stop the game's own action")

        t:eq(keymap.status("W").state, "game", "movement is an AXIS mapping and counts the same")

        local free = keymap.status("END")
        t:eq(free.state, "free", "a key nothing uses is free")
        t:truthy(free.why:find("not a promise", 1, true),
            "and 'free' still refuses to promise the press arrives: " .. tostring(free.why))
    end)
end)

s:test("Esc is refused by the keyboard registry itself, and an override does not unlock it",
function(t)
    -- ⚠️ THE ONE RULE THAT OUTRANKS EVERY OTHER LINE IN THIS TREE. `override` exists to take a
    -- key Palworld uses; if it also took Esc it would be a one-word route back to the failure
    -- the whole input design is built around.
    t:eq(reg.status("ESCAPE").state, "forbidden", "Esc is refused before anything else is asked")
    local ok, st = reg.claim("ESCAPE", function() end, { override = true })
    t:eq(ok, false, "claiming it fails")
    t:eq(st.state, "forbidden", "with the same reason, override or not")
    t:falsy(reg.isBound("ESCAPE"), "and nothing was bound")
end)

s:test("a key PalForge already holds is refused, and the refusal names the holder", function(t)
    -- F1 runs the test suite. The old registry replaced a callback in place and said nothing,
    -- so a panel asking for F1 would have swallowed the runner — which is the one collision this
    -- tree can actually do something about, so it is checked BEFORE the game's.
    if not reg.isBound("F1") then t:skip("F1 is not bound in this session") end
    local st = reg.status("F1")
    t:eq(st.state, "palforge", "our own binding is the answer")
    t:truthy(st.why:find("REPLACE", 1, true), "and the reason says what registering again does")
    local ok, refused = reg.claim("F1", function() end)
    t:eq(ok, false, "claim refuses rather than replacing")
    t:truthy(refused.why:find("never steals", 1, true),
        "and points at reg.register for the case where the replacement is meant")
    t:eq(reg.bound.F1.opts.desc, "tests: all suites", "the original binding is untouched")
end)

s:test("a key the GAME uses is refused unless the caller said override", function(t)
    withFakeName(FAKE_TAKEN, "PalForgeTestTaken", function()
        withKeymap({
            palforgetesttaken = { key = "PalForgeTestTaken",
                                  actions = { { action = "VolumeUp", via = "config/main" } } },
        }, function()
            local ok, st = reg.claim(FAKE_TAKEN, function() end)
            t:eq(ok, false, "the game has it, so it is not taken by accident")
            t:eq(st.state, "game", "and the refusal says which case it was")
            t:truthy(st.why:find("VolumeUp", 1, true),
                "naming the action it would collide with")
            t:truthy(st.why:find("overrideKeys", 1, true),
                "and the exact field that would take it anyway: " .. tostring(st.why))

            -- With the override the GAME check no longer refuses. The bind itself still fails —
            -- this is a name no Key table has — and that is a DIFFERENT refusal with a different
            -- sentence, which is the point: the two are distinguishable in the log.
            local ok2, st2 = reg.claim(FAKE_TAKEN, function() end, { override = true })
            t:eq(ok2, false, "there is no such engine key to bind to")
            t:truthy(st2.why:find("RegisterKeyBind", 1, true),
                "but the refusal is now about the ENGINE, not the game: " .. tostring(st2.why))
            t:falsy(st2.why:find("PalForge refused it", 1, true), "the game refusal is gone")
            t:falsy(reg.isBound(FAKE_TAKEN), "and a bind that did not take leaves no record")
        end)
    end)
end)

s:test("`overrideKeys` is a declaration of its own, checked where it is written", function(t)
    local f = function() end
    -- Half a declaration is refused exactly as `keys` alone is: an overridden key with no
    -- handler would bind a key of the player's, permanently, and route it to nothing.
    t:errors(function() UI{ id = support.id("ui_ov1"), overrideKeys = { "F7" } } end,
        "declares `keys` but no onKeyPressed")
    -- ...and a handler with ONLY overrideKeys is complete, because the override list arms too.
    local El = UI{ id = support.id("ui_ov2"), overrideKeys = { FAKE_A:lower() }, onKeyPressed = f }
    t:eq(El:state().keySet[FAKE_A], true,
        "an overridden key is upper-cased and routable like any other")
    t:eq(El:state().overrideList[1], FAKE_A,
        "and is kept apart, because that difference IS the override")
    t:eq(#El:state().keyList, 0, "it is not in the ordinary list")

    -- Naming one key in both lists is two opposite instructions about the same key.
    t:errors(function()
        UI{ id = support.id("ui_ov3"), keys = { "INS" }, overrideKeys = { "INS" },
            onKeyPressed = f }
    end, "BOTH `keys` and `overrideKeys`")
end)

s:test("an overridden key routes exactly like a declared one, and shows up in the stack",
function(t)
    ownStack(t)
    local got
    local El = UI{ id = support.id("z_ov"), z = 9080,
                   keys = { FAKE_A }, overrideKeys = { FAKE_B },
                   onKeyPressed = function(_, ctx) got = ctx.key end,
                   render = function() end }
    local el = El:new{}
    el:mount(fakeRoot())

    t:eq(UI.routeKey(FAKE_B), el:state().id, "the overridden key routes to the element")
    t:eq(got, FAKE_B, "and the handler is the same one")
    t:eq(UI.routeKey(FAKE_A), el:state().id, "the ordinary key still routes")

    local row = UI.stack()[1]
    t:eq(table.concat(row.keys, ","), FAKE_A .. "," .. FAKE_B,
        "the stack row lists both, declared order first")
    t:eq(row.overrideKeys[1], FAKE_B, "and says which of them was overridden")
    el:unmount()
    native.keys.keys[FAKE_A], native.keys.keys[FAKE_B] = nil, nil
end)

-- ⚠️ THE MOUSE HALF OF AN OVERRIDE, AND WHY IT IS A FIELD OF ITS OWN. On a default Palworld
-- install ALL THREE mouse buttons are bound by the game (a live run reported MIDDLE_MOUSE_BUTTON
-- -> DirectAttackOrder), so `buttons` alone can never arm one and the mouse half of the routing
-- design was never exercised. The obvious workaround — naming MIDDLE_MOUSE_BUTTON in
-- `overrideKeys` — half-works in the worst way: keys.arm would arm it as a KEY, mark the name
-- seen, skip the buttons pass, and deliver a middle-click to the key router where nothing wants
-- it. Silence, from a declaration that reads correct. Hence `overrideButtons`, in button names.
s:test("`overrideButtons` is the mouse half of an override, and stays out of the key router",
function(t)
    local f = function() end
    t:errors(function() UI{ id = support.id("ui_ob1"), overrideButtons = { "middle" } } end,
        "declares `buttons` but no onMousePressed")
    t:errors(function()
        UI{ id = support.id("ui_ob2"), buttons = { "middle" }, overrideButtons = { "middle" },
            onMousePressed = f }
    end, "BOTH `buttons` and `overrideButtons`")

    local El = UI{ id = support.id("ui_ob3"), overrideButtons = { "MIDDLE" },
                   onMousePressed = f }
    t:eq(El:state().buttonSet.middle, true, "the name is lower-cased and routable like any other")
    t:eq(El:state().overrideButtonList[1], "middle", "and kept apart, because that IS the override")
    t:eq(#El:state().buttonList, 0, "it is not in the ordinary list")

    -- The engine seam: one record, on the MOUSE name, flagged as an override — and the record's
    -- `button` field is what proves it went to the mouse dispatcher and not the key one.
    --
    -- The record is cleared FIRST because a bind is for the life of the session and so is its
    -- record: an earlier case in this file already arms MIDDLE_MOUSE_BUTTON, install() returns
    -- the existing record untouched, and this case would then be asserting that one's history.
    native.keys.keys.MIDDLE_MOUSE_BUTTON = nil
    local recs = native.keys.arm({ overrideButtons = { "middle" }, onMouse = f })
    t:eq(#recs, 1, "one record")
    t:eq(recs[1].key, "MIDDLE_MOUSE_BUTTON", "under the engine's name for it")
    t:eq(recs[1].button, "middle", "carrying the BUTTON, so a press routes through routeMouse")
    t:eq(recs[1].override, true, "and the override is recorded rather than inferred")
    native.keys.keys.MIDDLE_MOUSE_BUTTON = nil
end)

s:test("a mounted element's overridden button routes and appears in the stack row", function(t)
    ownStack(t)
    local got
    local El = UI{ id = support.id("z_obr"), z = 9090, overrideButtons = { "middle" },
                   onMousePressed = function(_, ctx) got = ctx.button end,
                   render = function() end }
    local el = El:new{}
    el:mount(fakeRoot())
    t:eq(UI.routeMouse("middle"), el:state().id, "the overridden button routes to the element")
    t:eq(got, "middle", "through the mouse handler, with the button in the context")
    local row = UI.stack()[1]
    t:eq(table.concat(row.buttons, ","), "middle", "the stack row lists it")
    t:eq(row.overrideButtons[1], "middle", "and says it was taken from the game on purpose")
    el:unmount()
    native.keys.keys.MIDDLE_MOUSE_BUTTON = nil
end)

s:test("arm() returns one record per name, including the overridden ones", function(t)
    local recs = native.keys.arm({ keys = { FAKE_A }, overrideKeys = { FAKE_B },
                                   onKey = function() end })
    t:eq(#recs, 2, "one record per declared name")
    t:eq(recs[1].key, FAKE_A, "keys first, in declared order")
    t:eq(recs[2].key, FAKE_B, "then the overrides")
    t:eq(recs[2].override, true, "and the override is recorded on the record, not inferred")
    t:eq(recs[1].state, "refused", "neither is a real engine key, so neither arms")
    t:truthy(recs[1].why:find("RegisterKeyBind", 1, true),
        "and the record carries the reason rather than an empty state: " .. tostring(recs[1].why))
    native.keys.keys[FAKE_A], native.keys.keys[FAKE_B] = nil, nil
end)

s:test("the report ATTRIBUTES a silent key instead of shrugging at it", function(t)
    -- The whole point of the rewrite, asserted. Three armed keys that have never been pressed,
    -- and the reading says something different about each — so the report has to say three
    -- different things rather than one sentence about all of them.
    --
    -- ⚠️ THE KEY TABLE IS SWAPPED, NOT ADDED TO, AND THAT IS THE FIX FOR A REAL FAILURE. This
    -- case failed in BOTH game states on 2026-08-02 on "NOT ONE of the 3 armed key" — and unlike
    -- the other three failures that day it is NOT an environment-gating bug and must not be
    -- gated away. native.keys.report() computes its whole-route verdict over the WHOLE of
    -- native.keys.keys (native/ui/keys.lua:259-311), and this case used to write its three
    -- synthetic records INTO the live table. In a real session that table already holds every
    -- key PalForge armed — the same run reported END, F1..F10, INS and MIDDLE_MOUSE_BUTTON — so
    -- the count was never 3, and F1 had just been pressed to start the run, so `arrived == 0`
    -- was false and the verdict line was not emitted at all. The report was right both times;
    -- the case was measuring the session instead of its own fixture.
    --
    -- Swapping the table makes the fixture the whole population, so the verdict is about exactly
    -- these three in every environment. Nothing is lost by it: a real key's callback closes over
    -- its RECORD (keys.lua's `fire(r)` is bound at arm time), so a press arriving during the swap
    -- still counts on the original record and reappears when the table is put back.
    local names = { "PALFORGE_TEST_GAME", "PALFORGE_TEST_FREE", "PALFORGE_TEST_UNMAPPED" }
    local savedKeys = native.keys.keys
    local K = {}
    native.keys.keys = K
    K[names[1]] = { key = names[1], state = "armed", arrivals = 0, routed = 0, blocked = 0 }
    K[names[2]] = { key = names[2], state = "armed", arrivals = 0, routed = 0, blocked = 0 }
    K[names[3]] = { key = names[3], state = "armed", arrivals = 0, routed = 0, blocked = 0 }
    -- The first two have to translate to an FKey to be answerable at all, so they borrow two
    -- real names for the length of this case.
    local savedMap = { keymap.FKEY[names[1]], keymap.FKEY[names[2]] }
    keymap.FKEY[names[1]], keymap.FKEY[names[2]] = "TestGameKey", "TestFreeKey"

    local ok, err = pcall(function()
        withKeymap({
            testgamekey = { key = "TestGameKey",
                            actions = { { action = "Crouch", via = "config/main" } } },
        }, function()
            local text = table.concat(native.keys.report(), "\n")
            t:truthy(text:find("Crouch", 1, true),
                "the key the game uses is reported WITH the action it collides with")
            t:truthy(text:find(names[1] .. " never arrived AND THE GAME HAS AN ACTION", 1, true),
                "and its silence is attributed to the game")
            t:truthy(text:find(names[2] .. " never arrived AND THE GAME'S KEY CONFIG HAS NOTHING",
                               1, true),
                "a free key's silence is explicitly NOT the game's fault")
            t:truthy(text:find(names[3] .. " never arrived AND THE GAME'S KEY CONFIG COULD NOT BE READ",
                               1, true),
                "and an unanswerable key keeps the old, honest 'cannot tell' answer")
            t:truthy(text:find("NOT ONE of the 3 armed key", 1, true),
                "and the whole-route verdict counts every armed key, this fixture's three: "
                .. text)
            -- ORDERING, asserted rather than implied by the sentence above. The verdict outranks
            -- every per-key reading — if nothing has ever arrived, no per-key answer means
            -- anything — so it has to come out FIRST of the four trailing lines, and until now
            -- nothing in this file checked that it did.
            t:truthy(text:find("NOT ONE of the", 1, true) < text:find(names[1] .. " never", 1, true),
                "with the whole-route verdict BEFORE the per-key ones, because it outranks them")
        end)
    end)

    keymap.FKEY[names[1]], keymap.FKEY[names[2]] = savedMap[1], savedMap[2]
    native.keys.keys = savedKeys
    if not ok then error(err, 0) end
end)

s:test("the lookup table has a row for every bindable name and counts the four cases",
function(t)
    withKeymap({
        insert = { key = "Insert", actions = { { action = "OpenInventory", via = "config/main" } } },
    }, function()
        -- ⚠️ THE ROWS ARE A UNION NOW, AND THIS CASE USED TO ASSERT #M.FKEY + 2. keymap.lookup
        -- was rewritten to walk the union of four sources — M.FKEY, UE4SS's live `Key` table,
        -- the binds PalForge holds and the names it refuses — precisely so that a name UE4SS will
        -- bind and M.FKEY has never heard of appears as `unknown` instead of being absent from
        -- the report. Counting M.FKEY here would re-assert the old shape and would fail the
        -- moment the drift it exists to catch actually happened. So the union is rebuilt from the
        -- same four inputs and THAT is what the row count is checked against.
        local owned = {
            F1 = "tests: all suites",
            -- A name PalForge holds that M.FKEY cannot translate: the drift row, included on
            -- purpose so the union is doing something in a headless run too (there is no live
            -- `Key` table here, so that source contributes nothing).
            PALFORGE_TEST_UNTRANSLATED = "a bind this table has never heard of",
        }
        local lines = keymap.lookup(owned, reg.FORBIDDEN)

        local union = {}
        local function addAll(src)
            for name in pairs(src or {}) do
                if type(name) == "string" and #name > 0 then union[name:upper()] = true end
            end
        end
        addAll(keymap.FKEY)
        if type(Key) == "table" then pcall(function() addAll(Key) end) end
        addAll(owned)
        addAll(reg.FORBIDDEN)
        local rows = 0
        for _ in pairs(union) do rows = rows + 1 end
        -- One header, one row per name in the union, then TWO summary lines: the four-case counts
        -- and the union/drift line.
        t:eq(#lines, rows + 3,
            "a header, a row per bindable name, and the two summary lines")
        local text = table.concat(lines, "\n")
        t:truthy(text:find("PALFORGE_TEST_UNTRANSLATED", 1, true),
            "a name PalForge holds is a row even when M.FKEY cannot translate it")
        t:truthy(text:find("M.FKEY HAS NO ROW FOR IT", 1, true),
            "and that row SAYS the answer is missing because of this table, not because of the game")
        t:truthy(text:find("INS  ", 1, true) and text:find("OpenInventory", 1, true),
            "a taken key names what has it")
        t:truthy(text:find("F1  ", 1, true) and text:find("tests: all suites", 1, true),
            "a key PalForge holds is the third case and appears as such")
        t:truthy(text:find("no Unreal FKey name is known", 1, true),
            "and an unanswerable name says which kind of unanswerable it is")
        -- Esc is a row of its own in the operator's reference table, because whatever the game
        -- has on it is beside the point: PalForge will not take it either way.
        t:truthy(text:find("ESCAPE", 1, true) and text:find("refused", 1, true),
            "Esc reads as refused outright, not as free or as the game's")
    end)
end)

s:test("keymap.refresh with no game reads nothing and blanks nothing", function(t)
    -- ⚠️ NEEDS NO ENGINE. This was the fourth of the four checks that failed identically in BOTH
    -- game states on 2026-08-02 ("nothing is readable with no game", 16:39:05 and 16:40:17), and
    -- the name was already telling the truth — "with no game" means with no ENGINE. In game the
    -- refresh SUCCEEDS: the same run reported 107 bindings read, so `n` is 107 rather than 0, the
    -- real index is swapped in over the stub this case installed, and the surviving-reading half
    -- has nothing left to assert. It is not a title-screen check either; a title-screen refresh
    -- still reaches UPalOptionSubsystem through the engine.
    --
    -- Gating it also stops the suite paying for a full key-config re-read in the middle of a run.
    support.needNoEngine(t, "the refresh really reads the game's key config — the same run "
        .. "measured 107 bindings — so nothing about a FAILED refresh can be observed")

    -- A refresh attempted with nothing to read must not destroy a reading taken inside a world:
    -- the index is built into a fresh table and only swapped in if something landed.
    withKeymap({ insert = { key = "Insert", actions = { { action = "Keep", via = "config/main" } } } },
    function()
        local n, note = keymap.refresh()
        t:eq(n, 0, "nothing is readable with no game")
        t:type(note, "string", "and the note names every source's state: " .. tostring(note))
        t:eq(keymap.status("INS").state, "game", "the earlier reading survived the failed refresh")
    end)
end)

s:test("slot padding is expanded to the four sides UMG names", function(t)
    local m = native.tree.margin(6)
    t:eq(m.Left, 6, "one number pads every side")
    t:eq(m.Bottom, 6, "including the bottom")
    m = native.tree.margin({ left = 1, top = 2 })
    t:eq(m.Left, 1, "a table names the sides it wants")
    t:eq(m.Right, 0, "and the ones it does not are zero, never nil")
    t:eq(native.tree.margin(nil), nil, "no padding declared means no call to make")
end)

return s
