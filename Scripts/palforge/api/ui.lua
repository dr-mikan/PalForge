-- palforge/api/ui.lua — PUBLIC UI API + implementation (SELF-CONTAINED).
--
-- A UI element is something drawn on screen out of Palworld's own native UMG kit. Same
-- shape as every other api module (define / get / get_all + a Handle object), with one
-- difference: a UI element is INSTANTIATED (each mounted copy has its own widgets and
-- state), so the Handle doubles as that instance — :new{...} gives you a fresh one.
--
-- RESPONSIBILITY SPLIT (owned here, not in the concrete elements):
--   * render(root) / update() / destroy()  — the WHAT: an element builds, refreshes and
--     tears down its own widgets.
--   * mount / refresh / unmount    — the WHEN: the lifecycle. render() runs exactly ONCE
--     per successful mount (idempotent, so re-mounting can never stack duplicate
--     widgets); update() runs on each refresh; destroy() runs on unmount. A concrete
--     element never writes its own render-once guard.
--   * A render that returns false means "I could not build" (the host UI was not there
--     yet): the element stays unmounted, so mounting again later retries.
--
-- HOW IT INTEGRATES: UI{ ... } registers the element class in object_manager under
-- ("ui", id), so tooling and other mods can look it up. The native elements in
-- palforge/native/ui/ (Button, TitleMenu) are defined exactly this way and build their
-- widgets through native/ui/_widget.lua — that part is LIVE and injects into the real
-- game UI.
--
-- REFRESH DRIVING: no native "the UI updated" event has been confirmed FIRING, so nothing
-- calls refresh() for you. Two honest options: call :refresh() yourself when your state
-- changes, or opt into polling with :autoRefresh(ms) (built on core/event's heartbeat).
-- No async policy is imposed by default. dumps/cxx has since named four candidate signals
-- and eliminated a fifth — see the note on :autoRefresh for the four and for the two things
-- that still have to be measured before any of them is hooked.
--
-- WHERE TO MOUNT: native/ui/_widget.lua gives three roots — widget.screen() for a viewport
-- layer of your own, TitleMenu for the title screen, and widget.gameUIRoot() for the game's
-- OWN in-game UI root canvas.
--
-- MOUNTING WHEN THE HOST UI IS NOT UP YET: an element whose host is absent returns false
-- from render and stays unmounted — and :autoRefresh does NOT get it in, because
-- refresh() is a no-op while unmounted. That is what :autoMount(root, ms) is for: the
-- same heartbeat poll, but it retries mount() while the element is down and refreshes it
-- once it is up. It is the whole retry loop a title-screen element needs, since the title
-- screen does not exist yet when a pack's files load.
--
--   local Panel = UI{
--       id = "example:Panel",
--       render  = function(self, root) --[[ build widgets under root ]] end,
--       update  = function(self) --[[ reflect changed state into the live widgets ]] end,
--       destroy = function(self) --[[ remove the widgets render built ]] end,
--   }
--   Panel:new{ title = "Hello" }:mount(root)
--
-- DECLARING A SCREEN INSTEAD OF BUILDING ONE. Everything above is the IMPERATIVE seam:
-- render(self, root) is handed a host and a free hand. That is the right shape for an element
-- that has to negotiate with the game's own widget tree (TitleMenu does, and has to), and the
-- wrong shape for the ordinary case — "in this frame, a label, then a button" — where the code
-- that builds a panel says nothing about what the panel looks like. So an element can also be
-- declared as a TREE, and then the nesting in the source IS the nesting on screen:
--
--   local UI = require("palforge.api.ui")
--   local VBox, Label, Button = UI.VBox, UI.Label, UI.Button   -- the vocabulary, unpacked once
--
--   local Supplies = UI{
--       id   = "example:Supplies",
--       host = "screen",                              -- a viewport layer of its own
--       root = VBox{ padding = 12,
--           Label{ text = "Supplies" },
--           Label{ name = "count", text = function(self) return "Wood x" .. self.wood end },
--           Button{ text = "Take one",
--                   onClick = function(self, ctx) self.wood = self.wood - 1 end },
--       },
--   }
--   Supplies:new{ wood = 10 }:autoMount(nil, 500)
--
-- WHY CONSTRUCTORS AND NOT PLAIN TABLES. `VBox{ ... }` is the one shape every other PalForge
-- definition has: a module called with a declarative table, validated by core/schema, where an
-- unknown field is a hard error with a did-you-mean and Scripts/palforge/types.lua is GENERATED
-- from the declaration so an editor completes every field. A bare `{ kind = "vbox", ... }` would
-- be none of that — `tetx = "Supplies"` would be silently dropped and the mistake would surface
-- as a label that never says anything. Validation runs inner-to-outer, at each call site, so the
-- complaint names the node you got wrong rather than the panel that contains it.
--
-- WHY A FIELD MAY BE A FUNCTION. `text = function(self) ... end` is a BINDING: evaluated with
-- the element instance when the tree is built, re-evaluated on every :refresh(), and written
-- back only when the value CHANGED. Without it a declared tree could only ever say what it said
-- at build time, and :refresh() would be dead weight for every declarative element — you would
-- have to tear a panel down to show a new number. Two fields are bindable, `text` and `visible`,
-- because those are the two a live panel actually changes; everything else is written once, so a
-- heartbeat refresh over an idle panel costs comparisons rather than a native call per node.
--
-- WHY `root` AND `render` CANNOT BOTH BE DECLARED. They are two answers to one question ("what
-- does this element build?"), and render() runs exactly once per mount: there is no ordering of
-- the two that is not a surprise to somebody. Declaring both is a hard error at define time.
-- `update` and `destroy` DO compose, because they are not in competition: on a refresh the
-- tree's bindings run first and your update() second (so it can override what a binding wrote),
-- and on the way down your destroy() runs first and the tree is taken apart after it (so it can
-- still touch the widgets).
--
-- WHERE IT MOUNTS: `host`. A declarative element can find its own host, which is what makes
-- `:autoMount(nil, ms)` the whole story for a screen that does not exist yet:
--
--   host = "screen"   a viewport layer of our own — nothing of the game's is in the way
--   host = "game"     the game's OWN in-game UI root canvas: CanvasPanel_Root inside
--                     WBP_PalOverallUILayout, a UCanvasPanel and therefore a UPanelWidget
--                     (dumps/cxx/WBP_PalOverallUILayout.hpp:9), live under BP_PalGameInstance
--                     (dumps/reflection/03_widgets.txt:54)
--   host = { widget = "PalUITitleBase", panel = "VerticalBox_0" }
--                     any live widget class and the panel inside it — which is how a pack
--                     EXTENDS a screen the game already draws, without owning it
--
-- mount(root) still takes an explicit root and it wins over `host`, so nothing about the older
-- surface changes. An element with neither mounts nowhere and SAYS SO: :lastError() carries the
-- reason the last attempt gave up, because a retry loop that fails silently is indistinguishable
-- from one that never ran — which is the failure this tree has paid for more than once.

local om     = require("palforge.core.object_manager")
local schema = require("palforge.core.schema")
local log    = require("palforge.utils.log").scope("ui")

-- Raise the way core/schema does: level 0, "PalForge: " in front, so a definition error reads
-- the same whether the schema rejected it or this file did.
local function fail(msg) error("PalForge: " .. msg, 0) end

--=============================================================================
-- NODES — the declarative widget vocabulary (UI.VBox, UI.Label, UI.Button, ...)
--
-- Each constructor is a callable module of its own, exactly like Pal / Item / UI themselves:
-- call it with a declarative table, get back a NODE. A node is inert data — no engine call
-- happens until something mounts the tree it belongs to — which is what keeps this whole file
-- provable with no game running, and what lets native/ui/tree.lua own every widget call.
--
--   UI.VBox / UI.HBox / UI.Overlay / UI.ScrollBox    hold any number of children
--   UI.Border / UI.SizeBox                           hold exactly one
--   UI.Label / UI.Button / UI.GameWidget             hold none
--
-- CHILDREN ARE POSITIONAL, which is the entire point: the array part of the table is the
-- children, the named part is the fields, and that is what makes the source read like the
-- screen. `children = { ... }` is accepted too (a generated tree has no other way to say it),
-- and writing both is a hard error rather than a merge.
--=============================================================================

-- Every node handle carries this metatable and nothing else does, so `isNode` is an exact test
-- rather than a duck-type: a node is what a node constructor returned. A hand-rolled table that
-- merely looks like one is rejected where it would have been nested, with the list of
-- constructors that would have built it properly.
local NodeMeta = {
    __name = "UI.Node",
    __tostring = function(n)
        return "UI.Node<" .. tostring(n.kind) .. (n.name and (" " .. n.name) or "") .. ">"
    end,
}

local function isNode(v)
    return type(v) == "table" and getmetatable(v) == NodeMeta
end

local BUILDERS = "UI.VBox / UI.HBox / UI.Overlay / UI.ScrollBox / UI.Border / UI.SizeBox / "
    .. "UI.Label / UI.Button / UI.GameWidget"

local function nodeCheck(v)
    if isNode(v) then return true end
    return false, "must be a node built by one of " .. BUILDERS
end

local function childrenCheck(v)
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n ~= #v then
        return false, "must be a plain array of nodes (a named key got in among the children)"
    end
    for i, child in ipairs(v) do
        if not isNode(child) then
            return false, string.format("child %d is a %s, not a node — build it with one of %s",
                i, type(child), BUILDERS)
        end
    end
    return true
end

-- The fields EVERY node has, appended AFTER the kind's own so that `text` leads a Label in
-- :help() and in the generated types. Four of the five are the parent's half of the layout: a
-- slot belongs to the parent panel in UMG, but it is declared on the CHILD here, because "put
-- this one on the left" is a fact about the child and because a list of children is the only
-- place it can be written at all.
local function nodeFields(own)
    local out = {}
    for _, f in ipairs(own or {}) do out[#out + 1] = f end
    out[#out + 1] = { "name", type = "string",
        doc = "look the built widget up later with UI.Handle:find(\"<name>\")" }
    out[#out + 1] = { "visible", type = "boolean|function",
        sig = "boolean|fun(self: UI.Handle): boolean",
        doc = "BINDABLE - false COLLAPSES it, so it stops taking layout space too" }
    out[#out + 1] = { "hAlign", type = "string", values = { "fill", "left", "center", "right" },
        doc = "horizontal alignment in the parent's slot" }
    out[#out + 1] = { "vAlign", type = "string", values = { "fill", "top", "center", "bottom" },
        doc = "vertical alignment in the parent's slot" }
    out[#out + 1] = { "padding", type = "number|table", sig = "number|table",
        doc = "slot padding: one number for all four sides, or { left =, top =, right =, bottom = }" }
    return out
end

local CHILDREN = { "children", type = "table", sig = "UI.Node[]", check = childrenCheck,
    doc = "the nodes inside this one; normally written positionally — VBox{ Label{...}, Button{...} }" }

local TEXT = { "text", type = "string|number|function",
    sig = "string|number|fun(self: UI.Handle): any",
    doc = "BINDABLE - what it says" }

local ON_CLICK = { "onClick", type = "function", sig = "fun(self: UI.Handle, ctx: table)",
    doc = "clicked: (self = the element INSTANCE, ctx.node / ctx.name / ctx.widget)" }

-- kind -> { ctor, kind, holds, spec }. `holds` is how many children the node can take, and it
-- is enforced at the call site rather than at build time: UI.Label{ UI.Button{...} } is a
-- mistake about what a label IS, and the moment to say so is while the author is writing it.
local KINDS = {}
local function kind(ctor, name, holds, own)
    KINDS[#KINDS + 1] = { ctor = ctor, kind = name, holds = holds,
                          spec = schema.define("UI.Node." .. ctor, nodeFields(own)) }
end

kind("VBox",      "vbox",     "many", { CHILDREN })
kind("HBox",      "hbox",     "many", { CHILDREN })
kind("Overlay",   "overlay",  "many", { CHILDREN })
kind("ScrollBox", "scroll",   "many", { CHILDREN })
kind("Border",    "border",   "one",  { CHILDREN,
    { "color", type = "table", doc = "background tint { r, g, b, a } in 0..1" } })
kind("SizeBox",   "sizebox",  "one",  { CHILDREN,
    { "width",  type = "number", doc = "fixed width in slate units" },
    { "height", type = "number", doc = "fixed height in slate units" } })
kind("Label",     "label",    "none", { TEXT,
    { "size",  type = "number", doc = "font size (default 16)" },
    { "color", type = "table",  doc = "text colour { r, g, b, a } in 0..1" } })
-- A Button is the GAME's own WBP_Title_MenuButton wired through the shared click router —
-- the same widget and the same route as the imperative native/ui/button.lua, so there is one
-- button in this tree rather than two that drift apart.
kind("Button",    "button",   "none", { TEXT, ON_CLICK })
-- The escape hatch for "use the game's own component": any Blueprint widget by class path.
-- The three child names have to be given because they differ per widget and nothing can guess
-- them — WBP_Title_MenuButton's are Test_Content and WBP_PalInvisibleButton
-- (dumps/cxx/WBP_Title_MenuButton.hpp:14-15).
kind("GameWidget", "gamewidget", "none", {
    { "class", type = "string", required = true, check = schema.nonEmpty,
      doc = "Blueprint widget class path, e.g. \"/Game/Pal/Blueprint/UI/.../WBP_Foo.WBP_Foo_C\"" },
    TEXT,
    { "textChild",  type = "string", doc = "name of the child widget that carries the text" },
    { "clickChild", type = "string", doc = "name of the child widget that receives clicks" },
    ON_CLICK })

-- Split a call's positional children from its named fields, validate the fields against this
-- kind's spec, and hand back the node. Everything that can be wrong is wrong HERE, at the call
-- site, with the kind's own name in the message.
local function construct(k, t)
    if t == nil then t = {} end
    if type(t) ~= "table" then
        fail(string.format("UI.%s: expected a table, got %s", k.ctor, type(t)))
    end

    local kids, props, top = {}, {}, 0
    for key, v in pairs(t) do
        if type(key) == "number" then
            if key < 1 or key ~= math.floor(key) then
                fail(string.format("UI.%s: %s is not a child position", k.ctor, tostring(key)))
            end
            kids[key] = v
            if key > top then top = key end
        elseif type(key) == "string" then
            props[key] = v
        else
            fail(string.format("UI.%s: keys are field names or child positions, got a %s key",
                k.ctor, type(key)))
        end
    end
    for i = 1, top do
        if kids[i] == nil then
            fail(string.format("UI.%s: child %d is nil — a hole in the middle of the children",
                k.ctor, i))
        end
    end

    if top > 0 then
        if props.children ~= nil then
            fail(string.format("UI.%s: children given BOTH positionally and as `children` — "
                .. "pick one", k.ctor))
        end
        if k.holds == "none" then
            fail(string.format("UI.%s holds no children (%d given). The nodes that do: VBox, "
                .. "HBox, Overlay, ScrollBox (any number), Border, SizeBox (one)", k.ctor, top))
        end
        props.children = kids
    end

    local node = k.spec:validate(props, "UI." .. k.ctor)
    local n = #(node.children or {})
    if n > 1 and k.holds == "one" then
        fail(string.format("UI.%s holds ONE child, %d given — put them in a VBox or an HBox "
            .. "and give it that", k.ctor, n))
    end
    node.kind = k.kind
    return setmetatable(node, NodeMeta)
end

-- The constructors themselves, by the name they are published under. Each is callable and
-- carries its own kind, so `UI.VBox.kind` answers what it builds without calling it.
local NODES = {}
for _, k in ipairs(KINDS) do
    NODES[k.ctor] = setmetatable({ kind = k.kind }, {
        __name     = "UI.NodeConstructor",
        __call     = function(_, t) return construct(k, t) end,
        __tostring = function() return "UI." .. k.ctor end,
    })
end

--=============================================================================
-- HOSTS — where a declarative element puts itself when mount() is given no root
--=============================================================================

---A panel the game already draws: the widget CLASS to find, and the panel inside it.
local Host = schema.define("UI.Spec.Host", {
    { "widget", type = "string", required = true, check = schema.nonEmpty,
      doc = "the host widget's CLASS name. FindFirstOf matches subclasses, so name the native base (\"PalPrimaryGameLayoutBase\", not \"WBP_PalOverallUILayout_C\")" },
    { "panel",  type = "string",
      doc = "the panel inside it that takes our children: a declared member (read as a property), else a widget of that name in its tree. Omitted: the widget itself is the panel" },
})

local HOST_NAMES = { screen = true, game = true }

local function hostCheck(v)
    if type(v) == "string" then
        if HOST_NAMES[v] then return true end
        return false, string.format("%q is not a host name — use \"screen\", \"game\", or "
            .. "{ widget = <class>, panel = <member> }", v)
    end
    -- The nested spec does the real work and raises the real message; check() reports by
    -- RETURNING, so the raise is turned back into a rejection here. Its "PalForge: " prefix is
    -- stripped because the outer failure is about to add one of its own.
    local ok, err = pcall(function() Host:validate(v, "UI.Spec.Host") end)
    if ok then return true end
    return false, (tostring(err):gsub("^PalForge: ", ""))
end

-- native/ui/tree.lua is required LAZILY and inside a pcall, never at load: it requires
-- native/ui/_widget, which is engine-facing, and api/ui must stay loadable (and testable) with
-- no UE4SS at all. api/building.lua takes the same route to core/event, and for a second reason
-- that applies here too — native/ui/button.lua requires THIS module, so a top-level require the
-- other way would be a cycle.
local function uiTree()
    local ok, tree = pcall(require, "palforge.native.ui.tree")
    if ok and type(tree) == "table" then return tree end
    return nil, "palforge.native.ui.tree is unavailable: " .. tostring(tree)
end

-- Record why a mount did not happen, and log it the FIRST time that reason appears. A
-- :autoMount retry runs every couple of seconds; logging every attempt would bury the log, and
-- logging none of them is how "the host is not up yet" and "the host is up and rejected us"
-- became indistinguishable. So: once per distinct reason, per instance.
local function refuse(st, why)
    why = tostring(why or "no reason given")
    st._mountError = why
    if st._loggedError ~= why then
        st._loggedError = why
        log.warn(string.format("%s did not mount: %s", tostring(st.id or "ui element"), why))
    end
    return false
end

--=============================================================================
-- SPEC — the shape of UI{ ... }, declared as data so it is enforced on every call and so
-- the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("UI.Spec")         -- every field, its type, default and meaning
--   schema.get("UI.Spec").fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
-- Per-element state does NOT go here — it belongs to an instance, so pass it to
-- :new{ label = "OK", onClick = fn } and read it as `self` inside render/update/destroy.
-- Use `data` for defaults every instance should share.
--=============================================================================

---What you pass to UI{ ... }. `id` is required; `root` (a declared tree) or `render` (build it
---yourself) is what makes it useful — one or the other, never both.
local Spec = schema.define("UI.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "element id, e.g. \"pack:Panel\"" },
    { "name",        type = "string",   doc = "human label (defaults to id)" },
    { "description", type = "string",   doc = "one-line description, for UI and tooling" },
    { "root",        type = "table", sig = "UI.Node", check = nodeCheck,
                     doc = "the widget tree, DECLARED: UI.VBox{ UI.Label{ text = ... }, UI.Button{ ... } }. Mutually exclusive with `render` — they are two answers to one question" },
    { "host",        type = "string|table", sig = "UI.Spec.Host|\"screen\"|\"game\"",
                     check = hostCheck,
                     doc = "where to mount when mount() is given no root: \"screen\" (a viewport layer of our own), \"game\" (the game's own in-game UI root canvas), or { widget = <class>, panel = <member> } for a panel the game already draws" },
    { "render",      type = "function", sig = "fun(self: UI.Handle, root: any): boolean?",
                     doc = "build the widget tree under `root` (self, root); runs once per mount. Return false if it could not build — the element then stays unmounted" },
    { "update",      type = "function", sig = "fun(self: UI.Handle)",
                     doc = "refresh the already-built widgets (self); runs on each :refresh()" },
    { "destroy",     type = "function", sig = "fun(self: UI.Handle)",
                     doc = "remove the widgets render() built (self); runs on :unmount()" },
    { "data",        type = "table",    doc = "default fields shared by every instance of this element" },
})

--=============================================================================
-- the registered UI element class. render/update/destroy are the seams a definition
-- fills; mount/refresh/unmount are the lifecycle, owned here.
--=============================================================================

local Class = {}
Class.__index = Class

-- ---- seams a definition fills (the "WHAT") ----

-- Build this element's widgets under `root`. Called exactly ONCE per mount, by mount();
-- never call it directly. Return false to report that nothing was built (see mount).
-- Default is inert so an element can be declaration-only.
function Class:render(root) end

-- Refresh already-built widgets from current state. Called by refresh(); never call it
-- directly.
function Class:update() end

-- Remove the widgets render() built. Called by unmount(); never call it directly. Default
-- is inert — an element that builds nothing has nothing to take down.
function Class:destroy() end

-- ---- the DECLARATIVE seams (installed by define() when the spec declared `root`) ----
--
-- These are the same three seams, filled from `root` instead of by hand. They are ordinary
-- methods rather than closures so that an element can still call them from its own code, and
-- so that `cls.render == Class.renderTree` is a readable answer to "is this one declared?".

-- Build the declared tree under `root` and put it there. False — never a raise — for every
-- game-shaped reason: no tree module, no player controller for a button, a host that would not
-- take the root. That leaves the element unmounted, which is what makes :autoMount a retry.
function Class:renderTree(root)
    local tree, why = uiTree()
    if not tree then return refuse(self, why) end
    local built, reason
    local ok, err = pcall(function()
        built, reason = tree.mount(self.rootNode, {
            host  = root,
            outer = (self._host and self._host.outer) or root,
            self  = self,
        })
    end)
    if not ok then return refuse(self, err) end
    if not built then return refuse(self, reason) end
    self._tree = built
    return true
end

-- Re-evaluate the tree's bindings and write back the ones whose value moved.
function Class:updateTree()
    if not self._tree then return false end
    local tree = uiTree()
    if not tree then return false end
    local ok = pcall(function() tree.update(self._tree, self) end)
    return ok
end

-- Take the built tree back off screen and forget it, so a later mount() builds afresh.
function Class:destroyTree()
    local built = self._tree
    self._tree = nil
    if not built then return false end
    local tree = uiTree()
    if not tree then return false end
    local removed = false
    pcall(function() removed = tree.destroy(built) end)
    return removed
end

-- The live widget a node declared `name = "..."` for; nil before the tree is built, after it is
-- taken down, and for a name no node claimed. The imperative escape hatch out of a declared
-- tree: everything a binding cannot express is `self:find("count")` and then whatever UMG call
-- you need — at which point you are responsible for the same thing render() always was.
function Class:find(name)
    local built = self._tree
    if not (built and type(name) == "string") then return nil end
    return built.byName[name]
end

-- ---- lifecycle (the "WHEN") ----

-- Mount: render once under `root`. Idempotent — a second call while mounted is a no-op,
-- so re-invoking mount() can never stack duplicate widgets. Returns true if the render
-- reported success.
--
-- The element is latched as mounted on WHAT render REPORTED, not on the fact that it ran:
-- an element whose host UI was absent returns false and stays unmounted, so mounting it
-- again later retries. nil counts as success — a declarative render need not return
-- anything.
--
-- WITH NO ROOT AND A DECLARED `host`, mount resolves the host first and renders into that.
-- The resolution is part of MOUNTING rather than of rendering because it can fail for exactly
-- the reason a mount is allowed to fail — the host is not up yet — and because it then has to
-- be UNDONE: a "screen" host is a viewport layer this element created, and an element that
-- could not render must not leave one behind.
function Class:mount(root)
    if self._mounted then return false end
    if root == nil and self.hostSpec ~= nil then
        local tree, why = uiTree()
        if not tree then return refuse(self, why) end
        local host, reason
        local ok, err = pcall(function() host, reason = tree.host(self.hostSpec) end)
        if not ok then return refuse(self, err) end
        if not host then return refuse(self, reason) end
        self._host, root = host, host.panel
    end
    self._root = root
    if self:render(root) == false then
        self._root = nil
        self:releaseHost()
        return false
    end
    self._mounted = true
    self._mountError, self._loggedError = nil, nil
    return true
end

-- Give back a host this element CREATED (today: the "screen" viewport layer). A host that was
-- FOUND — the game's own panels — is not ours to take down; the element removed its own widgets
-- from it in destroy(), and that is the whole of its footprint there.
function Class:releaseHost()
    local host = self._host
    self._host = nil
    if not host then return false end
    local tree = uiTree()
    if not tree then return false end
    local released = false
    pcall(function() released = tree.releaseHost(host) end)
    return released
end

-- Refresh the live element (runs update()). No-op until mounted.
function Class:refresh()
    if not self._mounted then return false end
    self:update()
    return true
end

function Class:isMounted() return self._mounted == true end

-- Take the element down: run destroy() (the element removes its own widgets) and forget
-- the rendered state, so a later mount() renders afresh instead of stacking a second
-- copy. A throwing destroy() cannot leave the element stuck mounted.
function Class:unmount()
    if self._mounted then pcall(function() self:destroy() end) end
    self._mounted = false
    self._root = nil
    self:releaseHost()
    if self._refreshSub then
        pcall(function() self._refreshSub:unsubscribe() end)
        self._refreshSub = nil
    end
end

--=============================================================================
-- TOP — the module surface: UI{ ... } / UI.get / UI.get_all
--=============================================================================

---The UI domain. CALL it to define an element; the two named functions look existing ones up.
---The capitalised members are the NODE constructors — the declarative vocabulary, published
---here rather than as globals of their own so that one require brings the whole kit and a pack
---can unpack exactly the nodes it uses:
---
---    local VBox, Label, Button = UI.VBox, UI.Label, UI.Button
---
---@class palforge.ui
---@overload fun(spec: UI.Spec): UI.Handle
---@field VBox      fun(spec: UI.Node.VBox): UI.Node        # a column
---@field HBox      fun(spec: UI.Node.HBox): UI.Node        # a row
---@field Overlay   fun(spec: UI.Node.Overlay): UI.Node     # children stacked on top of each other
---@field ScrollBox fun(spec: UI.Node.ScrollBox): UI.Node   # a scrolling column
---@field Border    fun(spec: UI.Node.Border): UI.Node      # a tinted frame around ONE child
---@field SizeBox   fun(spec: UI.Node.SizeBox): UI.Node     # a fixed size around ONE child
---@field Label     fun(spec: UI.Node.Label): UI.Node       # text
---@field Button    fun(spec: UI.Node.Button): UI.Node      # the game's own menu button, clickable
---@field GameWidget fun(spec: UI.Node.GameWidget): UI.Node # any Blueprint widget the game ships
local UI = {}

-- Publish the node constructors on the module. They are not a namespace to browse: each one is
-- a thing you CALL, exactly like the domain modules themselves.
for ctor, node in pairs(NODES) do UI[ctor] = node end

local wrap  -- forward decl; the UI.Handle wrapper is defined in the BOTTOM section

---Define a UI element and register it. Returns a Handle that is itself mountable (a
---default instance); use :new{...} for independent copies with their own state.
---`spec` is validated against UI.Spec: `id` is required, unknown fields are an error.
---@param spec UI.Spec
---@return UI.Handle
local function define(spec)
    spec = Spec:validate(spec, "UI")
    local cls = setmetatable({ id = spec.id, name = spec.name or spec.id,
                               description = spec.description }, Class)
    cls.__index = cls
    if spec.render then cls.render = spec.render end
    if spec.update then cls.update = spec.update end
    if spec.destroy then cls.destroy = spec.destroy end
    -- `data` becomes per-element defaults: an instance reads them through the class
    -- metatable unless it sets its own field of the same name.
    if spec.data then
        for k, v in pairs(spec.data) do cls[k] = v end
    end
    cls.hostSpec = spec.host   -- read by mount() when it is given no root

    -- A DECLARED tree fills the three seams itself. render is replaced outright (declaring
    -- both is refused above the assignment, not silently resolved); update and destroy are
    -- COMPOSED, in the order each one's job needs:
    --   refresh -> bindings first, then yours, so yours can override what a binding wrote;
    --   unmount -> yours first, then the teardown, so yours can still touch the widgets.
    if spec.root then
        if spec.render then
            fail(string.format("UI %q declares BOTH `root` and `render`, and they are two "
                .. "answers to the same question — a declared tree builds the widgets, and so "
                .. "does render(). Keep the tree and drop render (self:find(\"<name>\") reaches "
                .. "any node that declared a name), or keep render and drop the tree.", spec.id))
        end
        cls.rootNode = spec.root
        cls.render   = Class.renderTree
        local userUpdate, userDestroy = spec.update, spec.destroy
        cls.update  = userUpdate and function(self)
            local ok = Class.updateTree(self)
            userUpdate(self)
            return ok
        end or Class.updateTree
        cls.destroy = userDestroy and function(self)
            pcall(userDestroy, self)
            return Class.destroyTree(self)
        end or Class.destroyTree
    end

    pcall(function() om.register("ui", spec.id, cls) end)
    return wrap(cls)
end

-- Calling the module IS defining:  UI{ id = "example:Panel", render = ... }
setmetatable(UI, { __call = function(_, spec) return define(spec) end })

---Get an EXISTING element by id: a previously-defined one, else a thin (inert) element.
---Never nil.
---@param id string
---@return UI.Handle
function UI.get(id)
    assert(type(id) == "string" and #id > 0, "UI.get: id (string) is required")
    local cls = om.get("ui", id)
    if not cls then
        -- Never defined: hand back an INERT element rather than nil. It needs an __index
        -- of its OWN, exactly as define() gives one: an instance's metatable is the class,
        -- and Lua reads __index off a metatable RAW, so without this line every lifecycle
        -- call (mount/refresh/unmount/isMounted) resolves to nil on the instance and
        -- raises instead of quietly doing nothing.
        cls = setmetatable({ id = id }, Class)
        cls.__index = cls
    end
    return wrap(cls)
end

---Every PalForge-registered UI element, as a list of handles.
---@return UI.Handle[]
function UI.get_all()
    local out = {}
    for _, cls in pairs(om.all("ui")) do out[#out + 1] = wrap(cls) end
    return out
end

--=============================================================================
-- BOTTOM — the UI OBJECT (UI.Handle): an instance you mount, refresh and unmount
--=============================================================================

---One node of a declared widget tree — what a node constructor returns. It is inert data
---(kind + validated fields + children), so it can be built, nested and passed around with no
---game running; native/ui/tree.lua is the only thing that turns one into a widget.
---@class UI.Node
---@field kind string  # which widget it becomes ("vbox", "label", "button", ...)

---A mountable UI element. Obtain one from UI{ ... } / UI.get, or :new{...} for a fresh
---instance. Inside render/update/destroy, `self` is this instance — set fields on it
---freely (self.widget = ..., read self.label, ...).
---@class UI.Handle
---@field id string   # the element's id
local Handle = {}
Handle.__index = Handle

-- The one heartbeat subscription behind autoRefresh/autoMount. Kept on the INSTANCE (not on
-- the handle) so :unmount() can cancel it and a second call cannot install a duplicate. A
-- raising render is swallowed here on purpose: event.every already pcalls its body, and a
-- retry loop that dies on the first bad frame is worse than one that keeps trying.
local function poll(st, ms, remount, root)
    if st._refreshSub then return true end
    local ok = pcall(function()
        local event = require("palforge.core.event")
        st._refreshSub = event.every(ms, function()
            if st._mounted then st:refresh()
            elseif remount then pcall(function() st:mount(root) end) end
        end)
    end)
    return ok and st._refreshSub ~= nil
end

-- An instance is a table with the definition class as its metatable, so render/update and
-- the lifecycle resolve on it while its own fields stay per-instance. The handle carries
-- that instance in _st and forwards to it.
wrap = function(cls, state)
    state = setmetatable(state or {}, cls)
    return setmetatable({ id = cls.id, _cls = cls, _st = state }, Handle)
end

---A fresh, independently-mountable instance of this element. `spec` becomes its state.
---@param spec table?
---@return UI.Handle
function Handle:new(spec) return wrap(self._cls, spec) end

-- ---- actions ----

---Mount this element under `root` (render once). Returns true if the render succeeded;
---false both when it is already mounted and when render reported it could not build — in
---the latter case the element stays unmounted, so calling mount() again retries.
---@param root any?
---@return boolean rendered
function Handle:mount(root) return self._st:mount(root) end

---Run update() on the live element. No-op until mounted.
---@return boolean ok
function Handle:refresh() return self._st:refresh() end

---Take the element down: runs destroy() so it removes its own widgets, then forgets the
---rendered state so a later mount() renders afresh. Also cancels autoRefresh/autoMount.
function Handle:unmount() return self._st:unmount() end

---@return boolean
function Handle:isMounted() return self._st:isMounted() end

---The live widget a node in the declared tree claimed with `name = "..."` — the imperative
---escape hatch out of a declarative element. nil until it is mounted, and nil again once it
---is not: a widget outlives neither.
---@param name string
---@return userdata?
function Handle:find(name) return self._st:find(name) end

---Why the last mount attempt gave up, as a sentence, or nil if the last one succeeded.
---
---This exists because a :autoMount retry that fails silently is indistinguishable from one
---that never ran, which is a confusion this tree has paid for repeatedly (a probe on a key the
---game had claimed; a console command registered into a window that was switched off). The same
---reason is logged ONCE per distinct message, so a loop retrying every 2 s does not bury it.
---@return string?
function Handle:lastError() return self._st._mountError end

---Poll refresh() every `ms` milliseconds off core/event's heartbeat (opt-in; there is no
---confirmed native UI-update event to hook). No-op while the element is unmounted — use
---:autoMount when the host UI may not be up yet. Cancelled by :unmount(). Returns true if
---the subscription was installed.
---@param ms integer?  # default 500
---@return boolean ok
function Handle:autoRefresh(ms)
    -- The old question here was "does Palworld raise a catchable UFunction when a UI is
    -- (re)built". dumps/cxx answers YES and names four, so that half is no longer unknown:
    --
    --   /Script/Pal.PalUserWidget:OnSetup            Pal.hpp:31902   } on the base class EVERY
    --   /Script/Pal.PalUserWidget:OnClosed           Pal.hpp:31903   } Palworld screen derives
    --     from, PalUITitleBase included (:31652 -> :31927 -> :31910 -> :31888).
    --   /Script/Pal.PalUIHUDLayoutBase:AddHUD        Pal.hpp:30714   the HUD adding a widget.
    --   /Script/CommonUI.CommonActivatableWidget:ActivateWidget   CommonUI.hpp:177 — the same
    --     module as CommonButtonBase:HandleButtonClicked (CommonUI.hpp:346), which is the hook
    --     native/ui/_widget.lua's click router already installs, so hooks DO take in this module.
    --
    -- It also eliminated the recipe's first target: UPalUIManagerSubsystem (Pal.hpp:30988)
    -- declares zero functions. Do not enumerate it again.
    --
    -- TODO(ui-update-event): what is unknown is now narrower and is about HOOKING, not existence.
    -- (a) OnSetup / OnClosed / AddHUD read as BlueprintImplementableEvents, and a blueprint that
    --     implements one gets its OWN UFunction of that name — a hook on the base never sees the
    --     override, so it is unmeasured which screens such a hook would actually catch.
    -- (b) whether arming a UI-wide hook is SAFE here: core/event.lua records a shared-dispatch
    --     wedge from a hook armed during the world-load storm, and a UI hook fires hardest
    --     exactly then. Nothing is hooked from this module until one probe run says which of the
    --     four fires, how often, and at what moment. Until then polling is the driver, and it is
    --     a deliberate choice rather than the only option left.
    --
    -- NARROWED, 2026-07-26: (a) and (b) are both COUNTING questions now, and test/probes/
    -- uievents.lua takes the count — four hooks whose entire body is one integer increment, plus
    -- a report on core/poll's heartbeat. (a) falls out of the totals: a candidate that stays at
    -- zero while menus open and close is one whose base UFunction nothing calls. (b) needs the
    -- storm, and a hook armed at world.ready misses ITS OWN world's storm by definition — so the
    -- measurement is taken across a SECOND load: core/event.lua:779-782 records that UE4SS has no
    -- unregister and a hook stays armed into the next world load, which turns that warning into
    -- the instrument. Autorun `pf_uievents`, then quit to the title and load a save again; the
    -- window between world.left and world.ready IS the storm.
    return poll(self._st, tonumber(ms) or 500, false, nil)
end

---Poll every `ms` milliseconds off the same heartbeat, but drive the WHOLE lifecycle: while
---the element is down this retries mount(root) — so an element whose host UI does not exist
---yet (the title screen at load) gets in the moment it appears — and once it is up this
---refreshes it. Cancelled by :unmount(), which is therefore also how you stop it retrying.
---Idempotent, and shares the one subscription slot with :autoRefresh.
---@param root any?      # the root handed to each mount attempt (nil for elements that find their own)
---@param ms integer?    # default 2000 — a retry loop wants a slower beat than a refresh
---@return boolean ok
function Handle:autoMount(root, ms)
    return poll(self._st, tonumber(ms) or 2000, true, root)
end

-- ---- queries ----

---The element's own state instance — what `self` is inside render/update/destroy.
---@return table
function Handle:state() return self._st end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end

UI.Class = Class   -- the base class every element extends (lifecycle + the three seams)
return UI
