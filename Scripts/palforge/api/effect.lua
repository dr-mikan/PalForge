-- palforge/api/effect.lua — PUBLIC effect API + implementation (SELF-CONTAINED).
--
-- An effect is a status applied to a character (a player or a Pal): buffs, debuffs,
-- damage-over-time, shields. Same shape as every other api module (call it to define,
-- plus get / get_all + a Handle object with actions and grouped `events`).
--
-- HOW IT INTEGRATES: Effect{ ... } registers the definition class in object_manager under
-- ("effect", id). The TIMING — duration, periodic interval, stacking, expiry — is owned
-- HERE, driven off core/event's "tick" channel (the shared ~500 ms heartbeat). That makes
-- this a REAL runtime, not a seam: :apply(target) starts a live application and the
-- handlers fire on schedule until it expires or is removed. The runtime also listens on
-- "world.left" and releases everything it is holding when the world unloads, so no
-- application survives a world reload (reason "world_left"); it is not persisted, so
-- nothing is re-applied on the next world.
--
-- What is NOT wired: the game's own ailments (EPalStatusEffectType — Poison / Burn /
-- Freeze) are a native enum, and no native call to apply one was confirmed, so a PalForge
-- effect does not toggle the game's status icon. The gameplay lives in YOUR handlers —
-- onTick is where you deal the damage / heal / buff through whatever call you have (e.g.
-- utils.items, an actor method). Native ailment application stays a `-- TODO:` in
-- native/effects.lua.
--
--   local Regen = Effect{
--       id = "example:Regen", name = "Regeneration",
--       duration = 10.0,   -- seconds; nil = until :remove()
--       interval = 1.0,    -- seconds between onTick calls
--       events = {
--           onApply  = function(effect, target, ctx) end,
--           onTick   = function(effect, target, ctx) --[[ heal target; ctx.elapsed ]] end,
--           onExpire = function(effect, target, ctx) end,
--       },
--   }
--   Regen:apply(Player.character())

local om     = require("palforge.core.object_manager")
local schema = require("palforge.core.schema")

--=============================================================================
-- SPEC — the shape of Effect{ ... }, declared as data so it is enforced on every call and
-- so the editor type definitions can be generated from it. It stays a LOCAL; read it at
-- runtime through the registry:
--
--   schema.help("Effect.Spec")         -- every field, its type, default and meaning
--   schema.get("Effect.Spec").fields   -- the same, as a table, for tooling
--
-- Anything not declared here is a hard error at define time, with a did-you-mean.
--=============================================================================

---The lifecycle handlers an effect can respond to. All optional. Each receives THIS
---effect's handle as its first argument, the `target` it is applied to, and a context
---`ctx`. An event this list does not name is a hard error, not a silent no-op.
local Events = schema.define("Effect.Spec.Events", {
    { "onApply",  type = "function", sig = "fun(self: Effect.Handle, target: any, ctx: table)",
                  doc = "LIVE - applied to a target" },
    { "onTick",   type = "function", sig = "fun(self: Effect.Handle, target: any, ctx: table)",
                  doc = "LIVE - every `interval` seconds while active" },
    { "onStack",  type = "function", sig = "fun(self: Effect.Handle, target: any, ctx: table)",
                  doc = "LIVE - re-applied to a target that already has it" },
    { "onExpire", type = "function", sig = "fun(self: Effect.Handle, target: any, ctx: table)",
                  doc = "LIVE - duration elapsed, removed, or target gone" },
})

---What you pass to Effect{ ... }. `id` is the only required field.
local Spec = schema.define("Effect.Spec", {
    { "id",           type = "string", required = true, check = schema.nonEmpty,
                      doc = "effect id: a name or \"pack:name\"" },
    { "name",         type = "string",  doc = "shown on the status bar (defaults to id)" },
    { "description",  type = "string",  doc = "one-line description, for UI and tooling" },
    { "duration",     type = "number",  doc = "total lifetime in seconds (omit = until :remove())" },
    { "interval",     type = "number",  doc = "seconds between onTick calls (omit = no periodic tick)" },
    { "stackable",    type = "boolean", default = false, doc = "may several copies coexist on one target?" },
    { "maxStacks",    type = "number",  default = 1, doc = "stack ceiling when stackable" },
    { "icon",         doc = "status-bar icon" },
    { "nativeStatus", type = "string",
                      doc = "the game's own EPalStatusEffectType this mirrors, when it has one" },
    { "events",       type = "table", of = Events, doc = "lifecycle handlers (grouped)" },
    { "data",         type = "table", doc = "free-form payload of your own, carried onto the definition" },
})

--=============================================================================
-- the registered effect DEFINITION class. Defaults are inert; define{ events = {...} }
-- overrides them per effect.
--=============================================================================

local Class = {}
Class.__index = Class
Class.duration  = nil
Class.interval  = nil
Class.stackable = false
Class.maxStacks = 1
Class.icon      = nil

function Class:onApply(target, ctx) end
function Class:onTick(target, ctx) end
function Class:onStack(target, ctx) end
function Class:onExpire(target, ctx) end

function Class:iconOf() return self.icon end

--=============================================================================
-- RUNTIME — the live applications, advanced by core/event's "tick" channel and released
-- wholesale on its "world.left" channel.
-- apps: target -> { [effectId] = app }. Weak-keyed: an application must never keep a
-- pawn alive, and a target that is garbage-collected takes its applications with it.
--=============================================================================

local GLOBAL = {}   -- sentinel target key for :apply() with no target
local apps   = setmetatable({}, { __mode = "k" })
local DT     = 0.5  -- seconds advanced per heartbeat (overwritten from event.TICK_MS)
local driverInstalled = false

-- Is `target` still usable? Engine objects go invalid when despawned; plain tables and
-- the GLOBAL sentinel are always fine.
local function targetAlive(target)
    if target == nil or target == GLOBAL then return true end
    local ok, valid = pcall(function()
        if type(target) == "userdata" and target.IsValid then return target:IsValid() end
        return true
    end)
    return ok and valid ~= false
end

-- End one application: fire onExpire and drop it from the table. `reason` is one of
-- "duration" / "removed" / "target_gone" / "world_left" and reaches the handler as ctx.reason.
local function expire(byId, id, app, reason)
    byId[id] = nil
    pcall(function()
        app.cls:onExpire(app.target, { effect = id, reason = reason, elapsed = app.elapsed,
                                       stacks = app.stacks })
    end)
end

-- One heartbeat: advance every live application (periodic tick, then expiry).
local function step()
    for key, byId in pairs(apps) do
        for id, app in pairs(byId) do
            if not targetAlive(app.target) then
                expire(byId, id, app, "target_gone")
            else
                app.elapsed = app.elapsed + DT
                local interval = tonumber(app.cls.interval)
                if interval and interval > 0 then
                    app.acc = app.acc + DT
                    while app.acc >= interval do
                        app.acc = app.acc - interval
                        pcall(function()
                            app.cls:onTick(app.target, { effect = id, elapsed = app.elapsed,
                                                         stacks = app.stacks })
                        end)
                    end
                end
                if app.remaining then
                    app.remaining = app.remaining - DT
                    if app.remaining <= 0 then expire(byId, id, app, "duration") end
                end
            end
        end
        -- an emptied bucket would otherwise sit in `apps` until its target is collected
        -- (and for ever, for GLOBAL and plain-table keys), so drop it here.
        if next(byId) == nil then apps[key] = nil end
    end
end

-- Release EVERY live application. The world is going away, so nothing that was applied
-- inside it can still be running — this is the effect-side counterpart of core/event's
-- dropAllInstances, which drops live building instances on the same signal. The reason is
-- its OWN value, "world_left", so a handler can tell a world unload apart from a duration
-- expiry, a :remove() or a despawned target.
local function dropAll()
    for key, byId in pairs(apps) do
        for id, app in pairs(byId) do expire(byId, id, app, "world_left") end
        -- same prune as step(); only when it really emptied, so an onExpire handler that
        -- re-applies something during the teardown does not lose it.
        if next(byId) == nil then apps[key] = nil end
    end
end

-- Subscribe to the heartbeat AND to the world-unload signal on FIRST use, so requiring
-- this module costs nothing and no subscriber exists until a pack actually applies an
-- effect. Lazy-requires core.event (which requires api.building) to keep module load
-- order free of cycles.
local function ensureDriver()
    if driverInstalled then return true end
    local ok = pcall(function()
        local event = require("palforge.core.event")
        DT = (tonumber(event.TICK_MS) or 500) / 1000
        event.on("tick", step)
        event.on("world.left", dropAll)
    end)
    driverInstalled = ok
    return ok
end

--=============================================================================
-- TOP — the module surface: Effect{ ... } / Effect.get / Effect.get_all
--=============================================================================

---The effect domain. CALL it to define one; the two named functions look existing ones up.
---@class palforge.effect
---@overload fun(spec: Effect.Spec): Effect.Handle
local Effect = {}

local wrap  -- forward decl; the Effect.Handle wrapper is defined in the BOTTOM section

---Define an effect and register it.
---`spec` is validated against Effect.Spec: `id` is required, unknown fields are an error.
---@param spec Effect.Spec
---@return Effect.Handle
local function define(spec)
    spec = Spec:validate(spec, "Effect")
    local cls = setmetatable({
        id           = spec.id,
        name         = spec.name or spec.id,
        description  = spec.description,
        duration     = spec.duration,
        interval     = spec.interval,
        stackable    = spec.stackable,
        maxStacks    = spec.maxStacks,
        icon         = spec.icon,
        nativeStatus = spec.nativeStatus,
        data         = spec.data,
    }, Class)
    cls.__index = cls
    local handle = wrap(cls)
    -- dispatch calls cls:onXxx(...) with the CLASS as self; a handler wants the HANDLE
    -- (what the call returned, and what carries :apply / :remove), so each declared
    -- handler goes in behind a forwarder that swaps it in.
    for name, handler in pairs(spec.events or {}) do           -- onApply, ...
        cls[name] = function(_, ...) return handler(handle, ...) end
    end
    pcall(function() om.register("effect", spec.id, cls) end)
    return handle
end

-- Calling the module IS defining:  Effect{ id = "example:Regen", ... }
setmetatable(Effect, { __call = function(_, spec) return define(spec) end })

---Get an EXISTING effect by id: a previously-defined one, else a thin definition. Never nil.
---@param id string
---@return Effect.Handle
function Effect.get(id)
    assert(type(id) == "string" and #id > 0, "Effect.get: id (string) is required")
    local cls = om.get("effect", id) or setmetatable({ id = id }, Class)
    return wrap(cls)
end

---Every PalForge-registered effect, as a list of handles.
---@return Effect.Handle[]
function Effect.get_all()
    local out = {}
    for _, cls in pairs(om.all("effect")) do out[#out + 1] = wrap(cls) end
    return out
end

---The ids of every effect currently active on `target`.
---@param target any?
---@return string[]
function Effect.activeOn(target)
    local byId = apps[target or GLOBAL]
    local out = {}
    if byId then for id in pairs(byId) do out[#out + 1] = id end end
    table.sort(out)
    return out
end

--=============================================================================
-- BOTTOM — the effect OBJECT (Effect.Handle): actions + lifecycle events
--=============================================================================

---A definable effect. Obtain one from Effect{ ... } / Effect.get / Effect.get_all.
---@class Effect.Handle
---@field id string   # the effect's id
local Handle = {}
Handle.__index = Handle

wrap = function(cls) return setmetatable({ id = cls.id, _cls = cls }, Handle) end

-- ---- actions (the live runtime) ----

---Apply this effect to `target`. Starts the timer: onApply now, onTick every `interval`
---seconds, onExpire after `duration` (or on :remove()). Re-applying a live effect stacks
---it when `stackable` and refreshes its duration, firing onStack instead of onApply.
---@param target any?  # the character to affect (nil = a world-global application)
---@param ctx table?   # extra context handed to onApply / onStack
---@return boolean ok
function Handle:apply(target, ctx)
    if not ensureDriver() then return false end
    local cls = self._cls
    local key = target or GLOBAL
    apps[key] = apps[key] or {}
    local byId = apps[key]
    local app  = byId[cls.id]

    if app then
        -- already active: stack (up to maxStacks) and refresh the duration.
        local max = tonumber(cls.maxStacks) or 1
        if cls.stackable and app.stacks < max then app.stacks = app.stacks + 1 end
        app.remaining = tonumber(cls.duration) or nil
        pcall(function()
            cls:onStack(target, setmetatable({ effect = cls.id, stacks = app.stacks },
                { __index = ctx }))
        end)
        return true
    end

    app = {
        cls       = cls,
        target    = target,
        elapsed   = 0,
        acc       = 0,
        stacks    = 1,
        remaining = tonumber(cls.duration) or nil,
    }
    byId[cls.id] = app
    pcall(function()
        cls:onApply(target, setmetatable({ effect = cls.id, stacks = 1 }, { __index = ctx }))
    end)
    return true
end

---End this effect on `target` early (fires onExpire with reason "removed").
---@param target any?
---@return boolean removed
function Handle:remove(target)
    local byId = apps[target or GLOBAL]
    local app = byId and byId[self.id]
    if not app then return false end
    expire(byId, self.id, app, "removed")
    return true
end

---Is this effect currently active on `target`?
---@param target any?
---@return boolean
function Handle:isActive(target)
    local byId = apps[target or GLOBAL]
    return (byId and byId[self.id]) ~= nil
end

---How many stacks of this effect are on `target` (0 when inactive).
---@param target any?
---@return integer
function Handle:stacksOn(target)
    local byId = apps[target or GLOBAL]
    local app = byId and byId[self.id]
    return app and app.stacks or 0
end

---Seconds left before this effect expires on `target`: nil when indefinite, 0 when inactive.
---@param target any?
---@return number?
function Handle:timeLeft(target)
    local byId = apps[target or GLOBAL]
    local app = byId and byId[self.id]
    if not app then return 0 end
    return app.remaining
end

-- ---- lifecycle events (fired by the runtime above; forward for manual use) ----

---@param target any
---@param ctx table
function Handle:onApply(target, ctx) if self._cls.onApply then return self._cls:onApply(target, ctx) end end
---@param target any
---@param ctx table
function Handle:onTick(target, ctx) if self._cls.onTick then return self._cls:onTick(target, ctx) end end
---@param target any
---@param ctx table
function Handle:onStack(target, ctx) if self._cls.onStack then return self._cls:onStack(target, ctx) end end
---@param target any
---@param ctx table
function Handle:onExpire(target, ctx) if self._cls.onExpire then return self._cls:onExpire(target, ctx) end end

-- ---- queries ----

---@return any?
function Handle:iconOf() return self._cls:iconOf() end
---@return string
function Handle:name() return self._cls.name or self.id end
---@return string?
function Handle:description() return self._cls.description end
---@return number?
function Handle:duration() return self._cls.duration end
---@return number?
function Handle:interval() return self._cls.interval end

Effect.Class = Class   -- the base hook table (used for override detection / subclassing)
return Effect
