-- palforge/api/ui.lua — PUBLIC UI API + implementation (SELF-CONTAINED).
--
-- A UI element is something drawn on screen out of Palworld's own native UMG kit. Same
-- shape as every other api module (define / get / get_all + a Handle object), with one
-- difference: a UI element is INSTANTIATED (each mounted copy has its own widgets and
-- state), so the Handle doubles as that instance — :new{...} gives you a fresh one.
--
-- RESPONSIBILITY SPLIT (owned here, not in the concrete elements):
--   * render(root) / update()      — the WHAT: an element builds / refreshes its widgets.
--   * mount / refresh / unmount    — the WHEN: the lifecycle. render() runs exactly ONCE
--     per mount (idempotent, so re-mounting can never stack duplicate widgets); update()
--     runs on each refresh. A concrete element never writes its own render-once guard.
--
-- HOW IT INTEGRATES: UI{ ... } registers the element class in object_manager under
-- ("ui", id), so tooling and other mods can look it up. The native elements in
-- palforge/native/ui/ (Button, TitleMenu) are defined exactly this way and build their
-- widgets through native/ui/_widget.lua — that part is LIVE and injects into the real
-- game UI.
--
-- REFRESH DRIVING: no native "the UI updated" event has been confirmed, so nothing calls
-- refresh() for you. Two honest options: call :refresh() yourself when your state
-- changes, or opt into polling with :autoRefresh(ms) (built on core/event's heartbeat).
-- No async policy is imposed by default.
--
--   local Panel = UI{
--       id = "example:Panel",
--       render = function(self, root) --[[ build widgets under root ]] end,
--       update = function(self) --[[ reflect changed state into the live widgets ]] end,
--   }
--   Panel:new{ title = "Hello" }:mount(root)

local om     = require("palforge.core.object_manager")
local schema = require("palforge.core.schema")

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
-- :new{ label = "OK", onClick = fn } and read it as `self` inside render/update.
-- Use `data` for defaults every instance should share.
--=============================================================================

---What you pass to UI{ ... }. `id` is required; `render` is what makes it useful.
local Spec = schema.define("UI.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "element id, e.g. \"pack:Panel\"" },
    { "name",        type = "string",   doc = "human label (defaults to id)" },
    { "description", type = "string",   doc = "one-line description, for UI and tooling" },
    { "render",      type = "function", sig = "fun(self: UI.Handle, root: any)",
                     doc = "build the widget tree under `root` (self, root); runs once per mount" },
    { "update",      type = "function", sig = "fun(self: UI.Handle)",
                     doc = "refresh the already-built widgets (self); runs on each :refresh()" },
    { "data",        type = "table",    doc = "default fields shared by every instance of this element" },
})

--=============================================================================
-- the registered UI element class. render/update are the seams a definition fills;
-- mount/refresh/unmount are the lifecycle, owned here.
--=============================================================================

local Class = {}
Class.__index = Class

-- ---- seams a definition fills (the "WHAT") ----

-- Build this element's widgets under `root`. Called exactly ONCE per mount, by mount();
-- never call it directly. Default is inert so an element can be declaration-only.
function Class:render(root) end

-- Refresh already-built widgets from current state. Called by refresh(); never call it
-- directly.
function Class:update() end

-- ---- lifecycle (the "WHEN") ----

-- Mount: render once under `root`. Idempotent — a second call while mounted is a no-op,
-- so re-invoking mount() can never stack duplicate widgets. Returns true if this call
-- performed the render.
function Class:mount(root)
    if self._mounted then return false end
    self._root = root
    self:render(root)
    self._mounted = true
    return true
end

-- Refresh the live element (runs update()). No-op until mounted.
function Class:refresh()
    if not self._mounted then return false end
    self:update()
    return true
end

function Class:isMounted() return self._mounted == true end

-- Forget the rendered state so a later mount() re-renders (e.g. after the game rebuilt
-- the host UI and dropped our widgets). Does not itself destroy widgets.
function Class:unmount()
    self._mounted = false
    self._root = nil
    if self._refreshSub then
        pcall(function() self._refreshSub:unsubscribe() end)
        self._refreshSub = nil
    end
end

--=============================================================================
-- TOP — the module surface: UI{ ... } / UI.get / UI.get_all
--=============================================================================

---The UI domain. CALL it to define an element; the two named functions look existing ones up.
---@class palforge.ui
---@overload fun(spec: UI.Spec): UI.Handle
local UI = {}

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
    -- `data` becomes per-element defaults: an instance reads them through the class
    -- metatable unless it sets its own field of the same name.
    if spec.data then
        for k, v in pairs(spec.data) do cls[k] = v end
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
    local cls = om.get("ui", id) or setmetatable({ id = id }, Class)
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

---A mountable UI element. Obtain one from UI{ ... } / UI.get, or :new{...} for a fresh
---instance. Inside render/update, `self` is this instance — set fields on it freely
---(self.widget = ..., read self.label, ...).
---@class UI.Handle
---@field id string   # the element's id
local Handle = {}
Handle.__index = Handle

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

---Mount this element under `root` (render once). Returns true if it rendered.
---@param root any?
---@return boolean rendered
function Handle:mount(root) return self._st:mount(root) end

---Run update() on the live element. No-op until mounted.
---@return boolean ok
function Handle:refresh() return self._st:refresh() end

---Forget the rendered state so a later mount() re-renders. Also cancels autoRefresh.
function Handle:unmount() return self._st:unmount() end

---@return boolean
function Handle:isMounted() return self._st:isMounted() end

---Poll refresh() every `ms` milliseconds off core/event's heartbeat (opt-in; there is no
---confirmed native UI-update event to hook). Cancelled by :unmount(). Returns true if the
---subscription was installed.
---@param ms integer?  # default 500
---@return boolean ok
function Handle:autoRefresh(ms)
    local st = self._st
    if st._refreshSub then return true end
    local ok = pcall(function()
        local event = require("palforge.core.event")
        st._refreshSub = event.every(tonumber(ms) or 500, function() st:refresh() end)
    end)
    return ok and st._refreshSub ~= nil
end

-- ---- queries ----

---The element's own state instance — what `self` is inside render/update.
---@return table
function Handle:state() return self._st end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end

UI.Class = Class   -- the base class every element extends (lifecycle + seams)
return UI
