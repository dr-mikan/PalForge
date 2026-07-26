# PalForge recipes

Twelve complete content files. Each one is copy-pasteable as-is, uses only real game ids from
`Scripts/palforge/native/*.lua`, and validates against the specs in `api.md`. Paths assume a
pack in its own UE4SS mod folder (`recipe 11` is the skeleton); inside PalForge itself, swap
`_G.PalForge.api` for `require("palforge.api")` and drop the `_G.PalForge` guard.

---

## 1. A chest that hands out an item

`ItemChest` is a real `BuildObjectId`. Interacting with a placed one pays out wood, plays a
sound, and keeps a lifetime total in the save file.

```lua title="Scripts/mypack/chest.lua"
-- mypack.chest — a supply chest: interact for wood, rate-limited, total persisted.
local api      = _G.PalForge.api
local log      = _G.PalForge.utils.log.scope("mypack.chest")
local Building = api.Building
local Item     = api.Item
local Audio    = api.Audio

local COOLDOWN_S = 30

return Building{
    id          = "ItemChest",
    name        = "Supply Chest",
    description = "Interact for five wood, once every 30 seconds.",
    gridCm      = 100,
    -- A FACTORY. A plain table would be handed to every chest as the SAME table.
    state       = function() return { given = 0 } end,
    events = {
        onRightClick = function(self, ctx)
            -- os.clock() resets each session on purpose: the cooldown is per session,
            -- the total is what survives in state.
            local now  = os.clock()
            local last = self._lastGave or -math.huge
            if now - last < COOLDOWN_S then
                log.info(string.format("%s: %.0fs left", self.key, COOLDOWN_S - (now - last)))
                return
            end
            -- give() is false when the count was READ and did not rise (bad id, no room).
            if not Item.get("Wood"):give(5) then
                log.warn("nothing entered the inventory")
                return
            end
            Audio.get("AKE_GrabItem"):play(ctx.player)
            self._lastGave    = now              -- not in state: session-only, not saved
            self.state.given  = self.state.given + 5
            self:save()                          -- marks dirty AND writes the world file
            log.info(string.format("%s has given %d wood", self.key, self.state.given))
        end,
    },
}
```

---

## 2. A pal that plays a sound when caught

`onCaptured` is one of the confirmed pal hooks. Defining `ChickenPal` REPLACES the demo
definition PalForge ships for that id.

```lua title="Scripts/mypack/pals.lua"
-- mypack.pals — a fanfare on capture, plus a sphere refund.
local api    = _G.PalForge.api
local log    = _G.PalForge.utils.log.scope("mypack.pals")
local Pal    = api.Pal
local Item   = api.Item
local Audio  = api.Audio
local Player = api.Player

local M = {}

M.Chicken = Pal{
    id          = "ChickenPal",
    name        = "Chicken Pal",
    description = "Plays a fanfare and refunds a sphere when caught.",
    events = {
        onCaptured = function(pal, ctx)
            -- ctx.actor = the caught pawn, ctx.comp = its parameter component.
            -- Play on the PLAYER, not on the pal: the pal is mid-despawn.
            Audio.get("AKE_Arena_Victory_01"):play(Player.character())
            Item.get("PalSphere"):give(1)
            log.info(pal:name() .. " caught: " .. tostring(ctx.actor))
        end,
        onDeath = function(pal, ctx)
            Audio.get("AKE_General_Explosion"):play(ctx.actor)
        end,
    },
}

return M
```

---

## 3. A building that counts uses across sessions

The only domain with per-structure persisted state. Two benches in two places have two
counters, and both come back on the next load.

```lua title="Scripts/mypack/bench.lua"
-- mypack.bench — a use counter that survives a reload.
local api      = _G.PalForge.api
local log      = _G.PalForge.utils.log.scope("mypack.bench")
local Building = api.Building

return Building{
    id          = "WorkBench",         -- note the capital B: the live BP id, not the DT row
    name        = "Counted Bench",
    description = "Counts every interaction, for as long as the structure exists.",
    gridCm      = 100,
    state       = function() return { uses = 0, loads = 0 } end,
    events = {
        onPlace = function(self, ctx)
            -- Fresh placement only. ctx.player is who built it; the mesh is NOT attached yet.
            log.info(string.format("placed %s at %.0f/%.0f/%.0f",
                self.key, self.pos.x, self.pos.y, self.pos.z))
            self:save()
        end,
        onLoad = function(self, ctx)
            -- Fires for EVERY newly tracked structure, fresh or restored. Per-structure
            -- startup work belongs here, not in onWorldReady.
            self.state.loads = (self.state.loads or 0) + 1
            self:save()
            log.info(string.format("%s tracked %s: %d use(s), load #%d", self.key,
                ctx.reconstructed and "from the save" or "fresh",
                self.state.uses, self.state.loads))
        end,
        onRightClick = function(self, ctx)
            self.state.uses = self.state.uses + 1
            self:save()                       -- an interaction is worth a disk write
            log.info(self.key .. " used " .. tostring(self.state.uses) .. " time(s)")
        end,
        onRemove = function(self, ctx)
            -- ctx.reason is "missing" — the scan stopped seeing the actor. The saved
            -- record is dropped right after this returns.
            log.info(string.format("%s gone [%s] after %d use(s)",
                self.key, tostring(ctx.reason), self.state.uses))
        end,
        onWorldLeft = function(self, ctx)
            -- Last look at the instance. The RECORD survives; onLoad restores it.
            self:setDirty()
        end,
    },
}
```

---

## 4. A structure that grows on a timer and pays out

`tickInterval` counts 500 ms heartbeats. A definition with no `onTick` never joins the tick
list at all.

```lua title="Scripts/mypack/bush.lua"
-- mypack.bush — grows a berry every ~20 s, harvested by interacting.
local api      = _G.PalForge.api
local log      = _G.PalForge.utils.log.scope("mypack.bush")
local Building = api.Building
local Item     = api.Item

local MAX = 10

return Building{
    id           = "FlowerBed",
    name         = "Berry Bush",
    description  = "Grows one berry every twenty seconds, up to ten.",
    gridCm       = 100,
    tickInterval = 40,                  -- 40 heartbeats x 500 ms = 20 s
    state        = function() return { grown = 0 } end,
    events = {
        onTick = function(self, ctx)
            -- ctx.count is the heartbeat number. Raise five times without a success and
            -- THIS instance's tick is switched off for the session.
            if self.state.grown >= MAX then return end
            self.state.grown = self.state.grown + 1
            self:setDirty()             -- cheap: mark only, the next save() flushes it
        end,
        onRightClick = function(self, ctx)
            local n = self.state.grown or 0
            if n <= 0 then
                log.info(self.key .. " has nothing ready")
                return
            end
            if Item.get("Berries"):give(n) then
                self.state.grown = 0
                self:save()
                log.info(string.format("%s harvested x%d", self.key, n))
            end
        end,
    },
}
```

---

## 5. A timed healing effect, applied by an item

An effect's schedule is real and driven by PalForge's heartbeat; what it DOES is entirely your
handlers. There is no native HP or ailment call, so "healing" means handing out the game's own
healing item on each tick.

```lua title="Scripts/mypack/regen.lua"
-- mypack.regen — 30 s regeneration, ticking every 5 s, stacking to 3, hung off an item use.
local api    = _G.PalForge.api
local log    = _G.PalForge.utils.log.scope("mypack.regen")
local Effect = api.Effect
local Item   = api.Item
local Audio  = api.Audio
local Player = api.Player

local M = {}

M.Regen = Effect{
    id          = "mypack:FieldRegen",
    name        = "Field Regeneration",
    description = "Hands out a berry every five seconds for half a minute.",
    duration    = 30.0,          -- omit for an effect that runs until :remove()
    interval    = 5.0,           -- omit for no periodic tick
    stackable   = true,
    maxStacks   = 3,
    -- nativeStatus is metadata ONLY: no game ailment is toggled and no status icon appears.
    events = {
        onApply = function(effect, target, ctx)
            -- ctx carries effect, stacks, plus whatever was passed to :apply(target, ctx).
            Audio.get("AKE_BuffAura"):play(target)
            log.info("regen on, source=" .. tostring(ctx.source))
        end,
        onStack = function(effect, target, ctx)
            -- Re-applying never calls onApply again; it refreshes the timer to full.
            log.info("regen refreshed, stacks=" .. tostring(ctx.stacks))
        end,
        onTick = function(effect, target, ctx)
            -- ctx.elapsed = seconds since apply, ctx.stacks = current stacks.
            Item.get("Berries"):give(ctx.stacks)
        end,
        onExpire = function(effect, target, ctx)
            -- ctx.reason is "duration" | "removed" | "target_gone" | "world_left".
            log.info("regen ended: " .. tostring(ctx.reason))
        end,
    },
}

-- "Medicines" is a real ItemId. onUse is one of the two confirmed item hooks.
M.Medicine = Item{
    id       = "Medicines",
    name     = "Medicine",
    category = "consumable",
    maxStack = 99,
    events = {
        onUse = function(item, ctx)
            -- ctx.actor on item.use is NOT reliably the player pawn. Ask Player directly.
            local me = Player.character()
            if me then M.Regen:apply(me, { source = "Medicines" }) end
        end,
    },
}

return M
```

---

## 6. A cooldown-gated skill, fired from a structure

Nothing in the game fires a skill. `:activate` runs the handler now and refuses while cooling
down — which is exactly the rate limit an interactive structure wants.

```lua title="Scripts/mypack/flare.lua"
-- mypack.flare — an altar that calls a guardian, once every 30 s per player.
local api      = _G.PalForge.api
local log      = _G.PalForge.utils.log.scope("mypack.flare")
local Skill    = api.Skill
local Building = api.Building
local Pal      = api.Pal
local Audio    = api.Audio

local M = {}

M.Flare = Skill{
    id          = "mypack:Flare",
    name        = "Signal Flare",
    description = "Calls a guardian to the beacon.",
    kind        = "active",              -- "passive" makes :activate always return false
    element     = "fire",
    cooldown    = 30.0,                  -- seconds, counted in Lua, per owner and skill id
    power       = 25,
    events = {
        onActivate = function(skill, owner, ctx)
            Audio.get("AKE_BuffAura"):play(owner)
            -- true = the spawn call was ACCEPTED, not that a pal is standing there.
            Pal.get("Kitsunebi"):spawn{ at = ctx.at, level = 5 }
            log.info("flare fired from " .. tostring(ctx.beacon))
        end,
    },
}

M.Beacon = Building{
    id          = "Altar",
    name        = "Signal Beacon",
    description = "Interact to call a guardian.",
    gridCm      = 100,
    state       = function() return { fired = 0 } end,
    events = {
        onRightClick = function(self, ctx)
            -- ctx.player is the interacting character; ctx.actor is the structure.
            local ok = M.Flare:activate(ctx.player, { beacon = self.key, at = self.pos })
            if not ok then
                log.info(string.format("cooling down: %.0fs left",
                    M.Flare:cooldownLeft(ctx.player)))
                return
            end
            self.state.fired = self.state.fired + 1
            self:save()
        end,
    },
}

return M
```

---

## 7. Re-skinning a pal with a named mesh

A named `Mesh{ ... }` is checked against `Mesh.Spec` on its own, whose `kind` defaults to
`"skeletal"` — pin `kind` explicitly whenever the mesh is meant for a structure.

```lua title="Scripts/mypack/meshes.lua"
-- mypack.meshes — one visual, declared once, worn by a pal and a structure.
local api  = _G.PalForge.api
local Mesh = api.Mesh
local Pal  = api.Pal

local M = {}

-- A pal wears a SKELETAL mesh (the default kind), with its animation blueprint.
M.ChickenBody = Mesh{
    id        = "mypack:ChickenBody",
    kind      = "skeletal",
    model     = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal.SK_ChickenPal",
    animClass = "/Game/Pal/Blueprint/Character/Monster/PalActorBP/ChickenPal/ABP_ChickenPal.ABP_ChickenPal_C",
    scale     = 1.4,
    color     = { r = 1.0, g = 0.4, b = 0.2, a = 1.0 },
}

-- A structure wears a STATIC mesh. kind must be pinned here: a NAMED mesh carries the
-- Mesh.Spec default ("skeletal") with it, and only an INLINE building mesh defaults to static.
M.BoxBody = Mesh{
    id    = "mypack:BoxBody",
    kind  = "static",
    model = "/Game/Pal/Model/Other/PalBox/SM_PalBox.SM_PalBox",
    scale = 1.0,
}

M.EmberChicken = Pal{
    id          = "SheepBall",        -- capital B: the live BP id, not the DT row "Sheepball"
    name        = "Ember Ball",
    description = "A sheepball wearing a chicken.",
    mesh        = M.ChickenBody,      -- a handle, or an inline table: checked identically
    events = {
        onSpawned = function(pal, ctx)
            -- Pals get no scan, so YOU attach the mesh. This hook is wired but has never
            -- been observed firing, so renderOn is also called from onTick below. Both are
            -- safe: core.mesh guards against re-stacking.
            pal:renderOn(ctx.actor)
        end,
        onTick = function(pal, ctx)
            -- The pal sweep, once per live pawn every ~3 s. ctx.actor / ctx.count / ctx.now.
            pal:renderOn(ctx.actor)
        end,
    },
}

return M
```

---

## 8. Per-pal bookkeeping on the sweep

One handle serves every pawn of the same id, so key anything per-creature by `ctx.actor`
yourself, in a weak table so a despawned pawn is collected.

```lua title="Scripts/mypack/watch.lua"
-- mypack.watch — count how long each live chicken has been around, and buff the old ones.
local api    = _G.PalForge.api
local log    = _G.PalForge.utils.log.scope("mypack.watch")
local Pal    = api.Pal
local Effect = api.Effect

local M = {}

M.Veteran = Effect{
    id        = "mypack:Veteran",
    name      = "Veteran",
    duration  = 15.0,
    interval  = 5.0,
    events = {
        onTick = function(effect, target, ctx)
            log.info("veteran tick at " .. tostring(ctx.elapsed))
        end,
    },
}

-- Weak keys: never keep a pawn alive just because this table mentions it.
local seen = setmetatable({}, { __mode = "k" })

M.Chicken = Pal{
    id   = "ChickenPal",
    name = "Watched Chicken",
    events = {
        onTick = function(pal, ctx)
            local a = ctx.actor
            if not a then return end
            local n = (seen[a] or 0) + 1
            seen[a] = n
            -- ~3 s per sweep, so 10 sweeps is roughly half a minute.
            if n == 10 and not M.Veteran:isActive(a) then
                M.Veteran:apply(a, { source = "watch" })
                log.info("veteran: " .. tostring(a))
            end
        end,
        onDeath = function(pal, ctx)
            if ctx.actor then
                seen[ctx.actor] = nil
                M.Veteran:remove(ctx.actor)
            end
        end,
    },
}

return M
```

---

## 9. An entry in the title menu

`TitleMenu` is a shipped UI element. `autoMount` is the call that both waits for the title
screen to exist and re-injects after it rebuilds itself.

```lua title="Scripts/mypack/menu.lua"
-- mypack.menu — one extra entry on Palworld's own title screen.
local forge = _G.PalForge
local log   = forge.utils.log.scope("mypack.menu")
local ui    = forge.native.ui

local M = {}

M.entries = {
    { label = "MyPack: hello", onClick = function() log.info("menu entry clicked") end },
    { label = "MyPack: version", onClick = function()
        log.info("PalForge v" .. tostring(forge.env.version))
    end },
}

-- :new{...} gives an independently-mountable instance; the table becomes its state.
M.menu = ui.TitleMenu:new{ entries = M.entries }

-- Not mount(): at load time there is no title screen, so render() returns false and the
-- element stays down. autoMount polls the heartbeat, retries mount while down, and
-- refreshes once up — which is also how it survives the title screen rebuilding itself.
M.menu:autoMount(nil, 2000)

-- Editing an entry and refreshing is a real edit: the live button is rewritten.
--   M.entries[1].label = "MyPack: changed"; M.menu:refresh()
--   M.menu:unmount()   -- takes the entries back out and cancels the poll

return M
```

---

## 10. A panel of your own, refreshed on a timer

Nothing tells a UI element that the game redrew. Call `:refresh()` when your state changes, or
poll with `:autoRefresh(ms)`.

```lua title="Scripts/mypack/panel.lua"
-- mypack.panel — a viewport panel showing the player's wood count.
local forge  = _G.PalForge
local api    = forge.api
local UI     = api.UI
local Item   = api.Item
local widget = forge.native.ui.widget

local M = {}

M.Panel = UI{
    id          = "mypack:StatusPanel",
    name        = "Status Panel",
    description = "Shows how much wood the local player is carrying.",
    render = function(self, root)
        -- self is the INSTANCE (what :new{...} returned); self.screen is its state.
        local screen = self.screen
        if not (screen and root) then return false end   -- false = could not build, stay down
        self.line = widget.text(screen.tree, "Wood: ?", 20)
        return widget.addV(root, self.line, 8) ~= nil
    end,
    update = function(self)
        if not widget.alive(self.line) then return false end
        local n = Item.get("Wood"):count()   -- nil means UNKNOWN, never zero
        local line = self.line
        pcall(function() line:SetText(FText("Wood: " .. tostring(n or "?"))) end)
        return true
    end,
    destroy = function(self)
        if widget.alive(self.line) then pcall(function() self.line:RemoveFromParent() end) end
        self.line = nil
        return true
    end,
}

-- A root to mount into: widget.screen() builds our own viewport layer and shows it.
function M.open()
    local screen, why = widget.screen()
    if not screen then return nil, why end
    local panel = M.Panel:new{ screen = screen }
    if not panel:mount(screen.root) then
        widget.hide(screen)
        return nil, "mount failed"
    end
    panel:autoRefresh(1000)
    M.screen, M.instance = screen, panel
    return panel
end

function M.close()
    if M.instance then M.instance:unmount() end     -- runs destroy(), cancels autoRefresh
    if M.screen then widget.hide(M.screen) end
    M.instance, M.screen = nil, nil
end

return M
```

---

## 11. The pack skeleton

Two files. `main.lua` is what UE4SS runs; `init.lua` is the one require per module, in
dependency order. Requiring a module IS registering its content.

```lua title="ue4ss/Mods/MyPack/Scripts/main.lua"
-- MyPack — a PalForge content pack, running as its own UE4SS Lua mod.
--   ue4ss/Mods/MyPack/enabled.txt        <- or a "MyPack : 1" line in mods.txt
--   ue4ss/Mods/MyPack/Scripts/main.lua   <- this file
--   ue4ss/Mods/MyPack/Scripts/mypack/    <- the pack's modules

-- Make require() resolve mypack.* relative to this Scripts dir.
local thisDir = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""
package.path = thisDir .. "?.lua;" .. thisDir .. "?\\init.lua;" .. package.path

-- PalForge publishes itself on _G.PalForge at the end of its own main.lua. It exists only
-- after PalForge has loaded, and only inside the same Lua state.
local forge = _G.PalForge
if not forge then
    pcall(print, "[MyPack] PalForge is not loaded - this pack does nothing this session")
    return
end

local log = forge.utils.log.scope("mypack")
log.info("loading against PalForge v" .. tostring(forge.env.version))

-- A bad field in a definition is a hard error. Guard the require so one broken module
-- does not take the rest of the pack with it.
local ok, err = pcall(function() require("mypack") end)
if not ok then log.err("load failed: " .. tostring(err)) else log.info("loaded") end
```

```lua title="ue4ss/Mods/MyPack/Scripts/mypack/init.lua"
-- mypack — every module, in dependency order. Each X{ ... } inside them runs on require
-- and writes its definition into PalForge's object_manager.
local M = {}

M.meshes    = require("mypack.meshes")     -- visuals first: buildings and pals wear them
M.regen     = require("mypack.regen")      -- the effect, and the item that applies it
M.flare     = require("mypack.flare")      -- the skill, and the beacon that fires it
M.chest     = require("mypack.chest")
M.bench     = require("mypack.bench")
M.bush      = require("mypack.bush")
M.pals      = require("mypack.pals")
M.watch     = require("mypack.watch")
M.menu      = require("mypack.menu")
M.panel     = require("mypack.panel")
M.trace     = require("mypack.trace")      -- drop this line in a release build

return M
```

---

## 12. A trace module for development

The event bus is public. Subscribing costs nothing and every channel exists before anything is
sent on it, so subscribing while the pack loads misses nothing.

```lua title="Scripts/mypack/trace.lua"
-- mypack.trace — diagnostics. Require it from init.lua while developing.
local forge    = _G.PalForge
local log      = forge.utils.log.scope("mypack.trace")
local event    = forge.core.event
local Building = forge.api.Building
local Effect   = forge.api.Effect
local Player   = forge.api.Player

local M = { subs = {} }

-- Every lifecycle channel except the heartbeat (two emits a second drowns everything).
for _, name in ipairs(event.CHANNELS) do
    if name ~= "tick" then
        M.subs[#M.subs + 1] = event.on(name, function(ctx)
            -- A plain event.on subscriber is NOT pcall'd by the bus: a raise here can stop
            -- the remaining subscribers on that emit, silently. Keep it defensive.
            local bits = {}
            if type(ctx) == "table" then
                for _, k in ipairs({ "buildId", "itemId", "count", "key", "reason" }) do
                    if ctx[k] ~= nil then bits[#bits + 1] = k .. "=" .. tostring(ctx[k]) end
                end
            end
            log.info(name .. " " .. table.concat(bits, " "))
        end)
    end
end

-- One-shot world-load work. By the time this runs the first scan has already tracked the
-- structures around the player, so :instances() is populated.
M.subs[#M.subs + 1] = event.on("world.ready", function()
    log.info(tostring(#event.instances()) .. " structure(s) tracked")
    -- Modded buildings get a DT_TechnologyRecipeUnlock row named after the resolved id;
    -- this unlocks exactly that row so it appears in the build menu. Needs PalCheatManager.
    pcall(function() Building.get("Altar"):unlock() end)
end)

-- A periodic report, rounded up to the 500 ms heartbeat.
M.report = event.every(5000, function()
    local chests = Building.get("ItemChest"):instances()
    local active = Effect.activeOn(Player.character())
    log.info(string.format("%d chest(s) live, %d effect(s) on the player", #chests, #active))
end)

-- Stop everything:
--   for _, s in ipairs(M.subs) do s:unsubscribe() end
--   M.report:unsubscribe()
return M
```
