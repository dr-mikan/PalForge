-- palforge/test/cases/ui.lua — the UI element lifecycle, proved without a single widget.
--
-- api/ui owns the WHEN (mount / refresh / unmount / autoRefresh) and a definition fills the
-- WHAT (render / update / destroy). That split is what makes this suite cheap: every case
-- here defines an element whose seams are plain Lua counters, so render-once, refresh-only-
-- while-mounted, destroy-on-unmount and per-instance state are all observable with no game
-- at all. The heartbeat is driven by emitting "tick" on core/event rather than waiting for
-- one, so the polling cases are deterministic too.
--
-- Only three cases need anything real, and none of them draws: _widget.owner() must not
-- throw with a world loaded, and _widget.screen() / the native Button are exercised ONLY
-- when there is no owner to build with — mounting a real widget on someone's screen from a
-- test is exactly the thing this file refuses to do. TitleMenu is mounted with an EMPTY
-- entry list, which can never inject anything even standing on the title screen.
local T       = require("palforge.core.unittests")
local support = require("palforge.test.support")
local UI      = require("palforge.api.ui")
local schema  = require("palforge.core.schema")
local event   = require("palforge.core.event")
local widget  = require("palforge.native.ui._widget")
local native  = require("palforge.native.ui")

local s = T.suite("ui")

-- A stand-in for a host panel. mount() only stores the root and hands it to render(), so a
-- table is as good as a VerticalBox everywhere the lifecycle itself is under test.
local function fakeRoot(name) return { __root = name or "root" } end

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
    if widget.findFirst("PalPlayerController") then
        t:skip("a PalPlayerController exists — this would build a real widget")
    end
    local btn = native.Button:new{ label = "test", onClick = function() end }
    t:eq(btn:mount(fakeRoot()), false, "no controller means nothing was built")
    t:eq(btn:isMounted(), false, "so the mount does not latch")
    t:eq(btn:state().widget, nil, "and no widget was left behind on the instance")
end)

s:test("_widget's fail-soft helpers never throw, with or without a game", function(t)
    t:type(widget.screen, "function", "screen() is reachable from the toolkit")
    t:type(widget.owner, "function", "so is owner()")
    t:eq(widget.alive(nil), false, "alive(nil) is false, not an error")
    t:eq(widget.alive({}), false, "alive of a plain table is false too")
    t:eq(widget.findFirst("NoSuchClassAnywhere"), nil, "findFirst of a missing class is nil")
    t:eq(widget.show(nil), false, "show(nil) fails soft")
    t:eq(widget.hide(nil), false, "hide(nil) fails soft")
end)

s:test("_widget.screen returns nil and a reason when there is no owner to build under", function(t)
    -- Only run this where screen() cannot succeed: with a real owner it would construct a
    -- UserWidget and put it on the player's viewport, which no test may do.
    if widget.owner() then t:skip("an owner exists — screen() would really draw") end
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

return s
