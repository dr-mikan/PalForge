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
-- :new{ label = "OK", onClick = fn } and read it as `self` inside render/update/destroy.
-- Use `data` for defaults every instance should share.
--=============================================================================

---What you pass to UI{ ... }. `id` is required; `render` is what makes it useful.
local Spec = schema.define("UI.Spec", {
    { "id",          type = "string", required = true, check = schema.nonEmpty,
                     doc = "element id, e.g. \"pack:Panel\"" },
    { "name",        type = "string",   doc = "human label (defaults to id)" },
    { "description", type = "string",   doc = "one-line description, for UI and tooling" },
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

-- ---- lifecycle (the "WHEN") ----

-- Mount: render once under `root`. Idempotent — a second call while mounted is a no-op,
-- so re-invoking mount() can never stack duplicate widgets. Returns true if the render
-- reported success.
--
-- The element is latched as mounted on WHAT render REPORTED, not on the fact that it ran:
-- an element whose host UI was absent returns false and stays unmounted, so mounting it
-- again later retries. nil counts as success — a declarative render need not return
-- anything.
function Class:mount(root)
    if self._mounted then return false end
    self._root = root
    if self:render(root) == false then
        self._root = nil
        return false
    end
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

-- Take the element down: run destroy() (the element removes its own widgets) and forget
-- the rendered state, so a later mount() renders afresh instead of stacking a second
-- copy. A throwing destroy() cannot leave the element stuck mounted.
function Class:unmount()
    if self._mounted then pcall(function() self:destroy() end) end
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
    if spec.destroy then cls.destroy = spec.destroy end
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
