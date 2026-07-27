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
    if widget.owner() then
        t:skip("an owner exists — building a real tree from a test is what this file refuses to do")
    end
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
    if widget.owner() then t:skip("an owner exists — host \"screen\" would really draw") end
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

s:test("a Frame wraps ONE child and takes only a FALLBACK colour", function(t)
    local f = UI.Frame{ UI.Label{ text = "inside" } }
    t:eq(f.kind, "frame", "it is a frame")
    t:eq(#f.children, 1, "with its one child")
    t:errors(function() UI.Frame{ UI.Label{}, UI.Label{} } end, "UI.Frame holds ONE child, 2 given")
    -- The distinction that matters: a Border's colour IS the border, a Frame's colour is only
    -- what is used when the game's own window class turns out not to be loaded.
    t:truthy(schema.get("UI.Node.Frame"):field("color").doc:find("FALLBACK", 1, true),
        "the colour field says it is the fallback's, not the frame's")
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

--=============================================================================
-- `input` — how much of the player's mouse an element takes
--
-- Every case here is pure: the field is validated in api/ui and the engine calls live in
-- _widget, so what an element DECLARES and what the lifecycle does with it are both provable
-- with no game. Whether SetInputMode_GameAndUIEx lands is not — that is the in-game run.
--=============================================================================

s:test("`input` defaults to none: an element takes nothing unless it asked", function(t)
    local El = UI{ id = support.id("ui_input_default") }
    t:eq(El:state().inputMode, "none", "the default is the SAFE one — nobody's mouse is touched")
    local Grab = UI{ id = support.id("ui_input_clicks"), input = "clicks" }
    t:eq(Grab:state().inputMode, "clicks", "and an element that wants clicks says so")
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
    if widget.owner() then t:skip("an owner exists — this would really move the player's cursor") end
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
        t:skip("another UI element is already mounted, and this asserts against a stack it owns")
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

s:test("UI.report prints the stack and what the key binds are doing", function(t)
    ownStack(t)
    local el = mountAt{ what = "z_report", z = 9070, keys = { "INS" }, onKey = function() end }
    local lines = table.concat(UI.report(), "\n")
    t:truthy(lines:find(tostring(el:state().id), 1, true), "the mounted element is listed")
    t:truthy(lines:find("z=9070", 1, true), "with its z")
    t:truthy(lines:find("keys=INS", 1, true), "and the keys it asked for")
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

local keymap = require("palforge.core.keyboard.base.keymap")
local reg    = require("palforge.core.keyboard.base.registory")

-- Install a synthetic keymap reading for the body of one test, and put the real state back
-- afterwards whatever happens. Everything the status logic reads lives on keymap.state, so this
-- is an honest substitution rather than a mock of the thing under test: the same code path runs,
-- over an index somebody else filled in.
local function withKeymap(index, fn)
    local st = keymap.state
    local saved = { index = st.index, actions = st.actions, read = st.read, at = st.at,
                    dirty = st.dirty }
    st.index, st.actions, st.read, st.at, st.dirty = index, {}, true, os.clock(), false
    local ok, err = pcall(fn)
    st.index, st.actions, st.read, st.at, st.dirty =
        saved.index, saved.actions, saved.read, saved.at, saved.dirty
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

s:test("the name map covers every key UE4SS can actually bind", function(t)
    -- The live check, and the only one that can catch UE4SS growing its table underneath us: a
    -- name UE4SS will bind and this map has never heard of is a name PalForge would answer
    -- "unknown" for forever. Headless there is no Key table, so this skips rather than passing
    -- vacuously.
    local n = 0
    if type(Key) == "table" then for _ in pairs(Key) do n = n + 1 end end
    if n == 0 then t:skip("no UE4SS Key table in this session") end
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
    local saved = { read = st.read, at = st.at, dirty = st.dirty, index = st.index }
    st.read, st.at, st.dirty, st.index = false, os.clock(), false, {}
    local ok, err = pcall(function()
        local s1 = keymap.status("INS")
        t:eq(s1.state, "unknown", "no reading means no answer")
        t:eq(s1.fkey, "Insert", "though the name still translates")
        t:truthy(s1.why:find("loaded world", 1, true), "and the reason names what is missing")
    end)
    st.read, st.at, st.dirty, st.index = saved.read, saved.at, saved.dirty, saved.index
    if not ok then error(err, 0) end
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
    local K = native.keys.keys
    local names = { "PALFORGE_TEST_GAME", "PALFORGE_TEST_FREE", "PALFORGE_TEST_UNMAPPED" }
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
                "with the whole-route verdict first, because it outranks every per-key reading")
        end)
    end)

    keymap.FKEY[names[1]], keymap.FKEY[names[2]] = savedMap[1], savedMap[2]
    for _, n in ipairs(names) do K[n] = nil end
    if not ok then error(err, 0) end
end)

s:test("the lookup table has a row for every bindable name and counts the four cases",
function(t)
    withKeymap({
        insert = { key = "Insert", actions = { { action = "OpenInventory", via = "config/main" } } },
    }, function()
        local lines = keymap.lookup({ F1 = "tests: all suites" }, reg.FORBIDDEN)
        -- One header, one row per UE4SS key name, one summary.
        local rows = 0
        for name in pairs(keymap.FKEY) do rows = rows + 1; local _ = name end
        t:eq(#lines, rows + 2, "a header, a row per bindable name, and the counts")
        local text = table.concat(lines, "\n")
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
    -- A refresh attempted at the title screen must not destroy a reading taken inside a world:
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
