-- palforge/api/init.lua — THE public API surface, in one place.
--
--   local api = require("palforge.api")      -- namespaced:  api.Pal, api.Item, ...
--   -- requiring it ALSO installs the globals below, so packs can just write:
--   Pal.get("ChickenPal"):spawn(Player.coordinate())
--   Item.get("Wood"):give(10)
--
-- Every module here has the SAME, THREE-MEMBER shape:
--   X{ id = ..., name = ..., description = ..., events = { onFoo = fn } } -> Handle
--   X.get(id) -> Handle          X.get_all() -> Handle[]
-- The module IS the constructor — calling it defines and registers. The Handle it returns
-- carries that domain's ACTIONS (:spawn, :give, :play, :mount, :apply, ...) plus forwarders
-- for its events. Each module's header states exactly which of its events are LIVE (a
-- confirmed native hook emits them) and which are declarable-but-not-yet-fired.
--
-- A DEFINITION READS AS ONE PIECE OF DATA. Everything is named, a nested definition is
-- passed as itself, and events are a plain map of handlers:
--
--   local pal = api.Pal{
--       id          = "test_pal",
--       name        = "Test Pal",
--       description = "A test pal for smoke testing.",
--       mesh        = api.Mesh{
--           id      = "test_pal_mesh",
--           model   = "/Game/Pal/Model/Character/Monster/ChickenPal/SK_ChickenPal",
--           texture = "palforge/test/textures/test_pal.png",
--       },
--       events = {
--           onSpawned = function(pal, ctx)
--               api.Audio.get("AKE_BGM_Title"):play()
--           end,
--       },
--   }
--   pal:spawn(api.Player.coordinate())
--
-- `X{ ... }` is Lua's call-with-a-table sugar for `X({ ... })` — the braces ARE the
-- argument list, which is as close to named arguments as the language gets.
--
-- DEFINE ONCE, ACT MANY TIMES. `X{ ... }` registers a definition; `X.get(id)` just hands
-- you a handle for one. A handler runs on every event, so reach for `get` inside one —
-- `Audio.get("AKE_BGM_Title"):play()` above is a play, where `Audio.bgm{ ... }:play()`
-- would re-declare and re-register the sound on every single spawn.
--
-- KNOWING WHAT TO PASS. Every domain's shape is declared as data (core/schema) and
-- enforced on every call. The declarations are PRIVATE to their module — a domain is a
-- thing you call, not a namespace to browse — but they stay readable through the registry:
--   schema.help("Pal.Spec")          -- every field, its type, default and meaning
--   schema.get("Pal.Spec").fields    -- the same as a table, for tooling
-- `id` is required everywhere, and an undeclared field is a hard error at define time
-- with a did-you-mean — a typo can never be silently ignored. In the editor, the same
-- information comes from Scripts/palforge/types.lua, which is GENERATED from those specs
-- (tools/gen-types.lua), so the completion can never drift from what a call accepts.
--
-- WHO IS DEFINING (F-6). A definition call is a plain Lua call and carries no evidence of
-- which mod made it, so the framework cannot attribute content — and cannot tell a pack
-- overwriting its own id from a pack overwriting SOMEONE ELSE'S — unless the pack says so.
-- `api.pack(packId)` is where it says so:
--
--   local api  = PalForge.pack("mypack")   -- or require("palforge.api").pack("mypack")
--   local Item = api.Item
--   Item{ id = "mypack:Potion" }           -- registered with pack = "mypack"
--
-- It returns the SAME nine members; the eight constructors are wrapped so the define runs
-- inside object_manager.withPack — and so are the two extra define routes a domain adds as
-- named functions (Audio.bgm / Audio.se), because those register too. Everything else
-- (X.get, X.get_all, Player) passes through untouched. Using it is optional and nothing
-- changes for a pack that does not — an unattributed definition registers with pack = nil,
-- exactly as before.
--
-- AND A TENTH MEMBER, `.store` — THE PACK'S OWN SAVED STATE:
--
--   local api = PalForge.pack("mypack", { version = "1.0.0" })
--   local db  = api.store
--   db.set("tutorialSeen", true)          -- validated NOW, at your call site
--   db.data().launches = (db.data().launches or 0) + 1
--   db.save()                             -- durable now, and it tells you if it wasn't
--   db.building(inst)                     -- that structure's persisted state table
--
-- It lands in ONE file that belongs to this pack alone: <Mods>/PalForge/state/<saveId>/mypack.json.
-- The pack id is baked into the handle, so there is no way to reach another pack's store through
-- it; an uninstalled pack costs zero reads and cannot be evicted by another pack's growth; and
-- deleting that one file is a complete uninstall of everything PalForge kept for it. None of it
-- is inside Palworld's .sav — the game's save is untouched and loads fine without PalForge (the
-- one thing that DOES reach it is what a pack asks the GAME to write: see core/ledger.lua).
--
-- `opts.version` is written into that file's header, so a state file can say which build of the
-- pack wrote it. Three pack ids are refused because the store owns those file names — see
-- RESERVED below.
--
-- The ---@type annotations make LuaLS auto-complete the bare globals.
-- (UE4SS gives each Lua mod its own state, so these globals are mod-local — no clash
--  with the game or other mods.)

local om       = require("palforge.core.object_manager")

local Pal      = require("palforge.api.pal")
local Item     = require("palforge.api.item")
local Building = require("palforge.api.building")
local Skill    = require("palforge.api.skill")
local Effect   = require("palforge.api.effect")
local Audio    = require("palforge.api.audio")
local Mesh     = require("palforge.api.mesh")
local UI       = require("palforge.api.ui")
local Player   = require("palforge.api.player")

-- Install the public globals (editor completion is driven by the ---@type below).
---@type palforge.pal
_G.Pal = Pal
---@type palforge.item
_G.Item = Item
---@type palforge.building
_G.Building = Building
---@type palforge.skill
_G.Skill = Skill
---@type palforge.effect
_G.Effect = Effect
---@type palforge.audio
_G.Audio = Audio
---@type palforge.mesh
_G.Mesh = Mesh
---@type palforge.ui
_G.UI = UI
---@type palforge.player
_G.Player = Player

---@class palforge.api
---@field Pal      palforge.pal
---@field Item     palforge.item
---@field Building palforge.building
---@field Skill    palforge.skill
---@field Effect   palforge.effect
---@field Audio    palforge.audio
---@field Mesh     palforge.mesh
---@field UI       palforge.ui
---@field Player   palforge.player
local api = {
    Pal      = Pal,
    Item     = Item,
    Building = Building,
    Skill    = Skill,
    Effect   = Effect,
    Audio    = Audio,
    Mesh     = Mesh,
    UI       = UI,
    Player   = Player,
}

-- ---- the scoped surface: api.pack(packId) ----

-- The eight callable domains. Player is the ninth member and is deliberately NOT wrapped:
-- it defines nothing, it acts on the local player, so there is no registration for a pack
-- id to attribute.
local CONSTRUCTORS = { "Pal", "Item", "Building", "Skill", "Effect", "Audio", "Mesh", "UI" }

-- MEMBERS THAT ARE ALSO CONSTRUCTORS. A domain's define call is normally the module itself
-- (`Item{ ... }`, reached through __call), but Audio has two more: Audio.bgm and Audio.se are
-- plain functions on the module that pin `kind` and then run the SAME define — registration
-- included. They are reached through __index, not __call, so a wrapper that only wraps __call
-- hands the raw function back and `PalForge.pack("mypack").Audio.bgm{ ... }` registers with
-- pack = nil: the one definition route the scoped surface did not cover, and the failure was
-- silent (the sound worked, only the attribution was lost). Named here rather than inferred,
-- because "every function member" would also wrap the accessors, and X.get / X.get_all are
-- specified to pass through unchanged.
local EXTRA_CONSTRUCTORS = {
    Audio = { "bgm", "se" },
}

-- A pack id is the first half of every id the pack will register, so it has to satisfy the
-- same rule `object_manager.resolve` applies to that half. Checked here, loudly, at the top
-- of a pack file, rather than turning into an unresolvable id per definition later.
local PACK_ID = "^[%w_]+$"

-- THREE IDS THE STORE OWNS. A pack id is no longer only an id: it is a FILE NAME. Persisted
-- state lives at <Mods>/PalForge/state/<saveId>/<packId>.json, one file per pack, and three
-- names in that directory already belong to PalForge itself —
--   _save         the per-save manifest (which world this folder is, which packs it holds)
--   _unowned      records no pack can be attributed to yet
--   _quarantine   the folder a file that would not parse is moved into, verbatim
-- All three match ^[%w_]+$, so all three were legal pack ids until this line existed, and a
-- pack called "_save" would have written its buildings straight over the manifest. Refused HERE,
-- at the one call that mints a pack id, rather than defended in the store: one validation beats
-- a "pack.<id>.json" naming convention that would cost legibility in every directory forever.
--
-- Neither half of the path can escape state/: spatial.saveId() gsubs [^%w_] to _ and prefixes
-- "w_", and a pack id is ^[%w_]+$ — so neither can contain /, \, . or :. Written down because
-- the store's key used to be a leaf name and is now a path.
-- ASKED OF core/state RATHER THAN RESTATED. The three names were a literal here and a second
-- literal at core/state's M.RESERVED, so a fourth reserved file name was a two-file edit whose
-- failure mode is a pack writing over the manifest — the exact thing this guard exists to stop.
-- The require is pcall'd and lazy for the same reason storeFor's is (see it, twenty lines
-- down): api/init must load even when core.state does not. When it does not, the shape check
-- above still runs and state.keyFor refuses the id later, so the degradation is a worse
-- message, never a hole.
local function reservedIds()
    local ok, state = pcall(require, "palforge.core.state")
    if ok and type(state) == "table" and type(state.RESERVED) == "table" then return state.RESERVED end
    return {}
end

-- One scoped table per pack id, so `api.pack("x").Item == api.pack("x").Item` and a pack
-- that calls it in ten files builds eight wrappers, not eighty.
local scopedApis = {}

-- The version a pack declared, by pack id. Recorded on the FIRST api.pack call that names one,
-- because the scoped table is memoized and the store handle is built with it — a later call
-- declaring a different version is noted and the first one stands, which is the same rule the
-- memoization has always had for everything else on the scoped table. Declared HERE, above
-- storeFor, because storeFor closes over it.
local declaredVersion = {}

-- ---- the store member ----

-- A store that ISN'T. core/state is what owns persistence; if it did not load, a pack must not
-- get a `store` that quietly accepts writes and drops them — that is the exact failure this whole
-- store redesign exists to remove.
--
-- THE SPLIT IS READS vs WRITES, and it is deliberate. A READ answers nil, exactly as db.get does
-- when a key was never set: a pack asking "have they seen the tutorial?" gets "no" and carries on,
-- which is the same answer it would get on a fresh save. A WRITE answers false plus a sentence
-- naming the pack and the cause, and `db.data()` hands back a table that RAISES on assignment —
-- because `db.data().launches = 1` has no return value to check, so a refusal it cannot see is a
-- silent loss. Nothing here silently succeeds, and a pack that never stores anything is unaffected.
local function deadStore(packId, why)
    local reason = string.format("PalForge.pack(%q).store is unavailable: %s", packId, why)
    local function refuse() return false, reason end
    local sealed = setmetatable({}, {
        __newindex = function() error(reason, 2) end,
    })
    return {
        get = function() return nil end,
        set = refuse, delete = refuse, save = refuse,
        keys = function() return {} end,
        data = function() return sealed end,
        building = function() return nil end,
        buildings = function() return {} end,
        ledger = function() return nil end,
        -- Same shape core/state's report has, so a caller that reads it does not have to know
        -- which of the two it got.
        reclaim = function() return { pack = packId, applied = false, entries = {},
                                      unreclaimable = {}, text = reason } end,
        saveId = function() return nil end,
        path = function() return nil end,
        stats = function() return { health = "unavailable", lastError = reason } end,
        diagnose = function() return reason end,
    }
end

-- This pack's store handle. core/state is required LAZILY and behind a pcall for the same reason
-- object_manager's logger is: the api must stay loadable by tooling outside the game, it must
-- survive F9 (core/reload wipes modules, and a reference captured at file scope would close over
-- a wiped one), and a store that failed to load must degrade to a named refusal rather than take
-- every definition call down with it.
--
-- `opts.version` is accepted and validated above, recorded in declaredVersion, and handed to
-- core/state as the SECOND ARGUMENT OF storeFor, where it becomes `palforge.packVer` in the
-- pack's own file header.
--
-- ⚠️ IT IS A STRING, NOT A TABLE, and that is the whole of a bug this used to have. Two slices
-- landed either side of this seam and each guessed a different shape: this file passed
-- `{ version = ... }` and core/state.lua declares `M.storeFor(packId, packVer)` and tests
-- `type(packVer) == "string"`. A table fails that test silently, so the declared version was
-- dropped on the floor and every file a pack wrote through api.pack carried no packVer at all
-- — while `state.storeFor(id, "2.3.0")` called directly worked, which is what made it look
-- like core/state's gap rather than this line's. Every other call site in the tree passes the
-- string. Do not "helpfully" wrap it in a table again.
local function storeFor(packId)
    local ok, state = pcall(require, "palforge.core.state")
    if not ok or type(state) ~= "table" or type(state.storeFor) ~= "function" then
        local why = "palforge.core.state did not load, so nothing this pack saves would survive "
                 .. "the session"
        require("palforge.utils.log").scope("api").warn(string.format(
            "pack '%s': %s. Definitions, events and every other api call are unaffected", packId, why))
        return deadStore(packId, why)
    end
    local built, store = pcall(state.storeFor, packId, declaredVersion[packId])
    if not built or type(store) ~= "table" then
        local why = "core.state.storeFor refused: " .. tostring(store)
        require("palforge.utils.log").scope("api").warn(
            string.format("pack '%s': %s", packId, why))
        return deadStore(packId, why)
    end
    return store
end

-- Wrap a domain module: calling it defines INSIDE withPack, so object_manager.register
-- attributes the entry to this pack; every other member (get, get_all, and whatever a
-- domain adds — Audio.bgm, UI's builders) reaches the real module through __index and is
-- unchanged. Varargs are forwarded whole, so the optional second argument of C2
-- (`X(spec, { register = false })`) keeps working through the scoped surface.
-- `extras` names the module's other constructors (see EXTRA_CONSTRUCTORS). Each is wrapped
-- ONCE, at scope-build time, so `p.Audio.bgm == p.Audio.bgm` the way `p.Audio == p.Audio`
-- already held, and so a per-call closure is not minted inside __index.
local function scopeModule(mod, packId, extras)
    local wrapped = nil
    for _, name in ipairs(extras or {}) do
        local fn = mod[name]
        if type(fn) == "function" then
            wrapped = wrapped or {}
            wrapped[name] = function(...) return om.withPack(packId, fn, ...) end
        end
    end
    return setmetatable({}, {
        __call  = function(_, ...) return om.withPack(packId, mod, ...) end,
        __index = wrapped and function(_, k)
            local w = wrapped[k]
            if w ~= nil then return w end
            return mod[k]
        end or mod,
        -- The wrapper is a view, not a copy: writing into it would silently diverge from
        -- the module every other caller sees.
        __newindex = function(_, k)
            error(string.format("PalForge: api.pack(%q) is a read-only view of the api; "
                .. "cannot assign %q on it", packId, tostring(k)), 0)
        end,
    })
end

-- The scoped api. `opts.depends` / `opts.recommends` (arrays of pack ids, or set-like
-- tables) are recorded with object_manager so checkImport can answer "may this pack
-- mention that id?" without every call site threading the set through. `opts.version` is
-- the pack's own version string; it is carried into the header of that pack's state file
-- (palforge.packVer) so a state file can say which build of the pack wrote it.
---@param packId string
---@param opts? { depends?: string[], recommends?: string[], version?: string }
---@return palforge.api
function api.pack(packId, opts)
    if type(packId) ~= "string" or not packId:match(PACK_ID) then
        error(string.format("PalForge: api.pack(%s): a pack id must be letters, digits or _ "
            .. "(it becomes the \"packid\" half of every \"packid:name\" this pack defines)",
            type(packId) == "string" and string.format("%q", packId) or type(packId)), 0)
    end
    if reservedIds()[packId] then
        error(string.format("PalForge: api.pack(%q): %q is RESERVED — a pack id is also the "
            .. "file name its saved state lives under (state/<save>/%s.json), and PalForge "
            .. "already owns _save, _unowned and _quarantine in that directory. Pick another id",
            packId, packId, packId), 0)
    end
    if opts ~= nil then
        if type(opts) ~= "table" then
            error(string.format("PalForge: api.pack(%q): the second argument must be a table "
                .. "of { depends = { ... }, recommends = { ... }, version = \"1.0.0\" }", packId), 0)
        end
        if opts.version ~= nil then
            if type(opts.version) ~= "string" then
                error(string.format("PalForge: api.pack(%q): opts.version must be a string "
                    .. "(got %s) — it is written verbatim into this pack's state file header",
                    packId, type(opts.version)), 0)
            end
            local had = declaredVersion[packId]
            if had == nil then
                declaredVersion[packId] = opts.version
            elseif had ~= opts.version then
                -- Not an error: two files of one pack disagreeing about their own version is a
                -- packaging mistake, not a reason to refuse to load. It is said once, because a
                -- state file stamped with the wrong version is exactly the kind of thing nobody
                -- notices until they are reading it at 2am.
                require("palforge.utils.log").scope("api").warn(string.format(
                    "pack '%s' declared version %q and then %q; the FIRST one is what its state "
                    .. "file header carries, because the scoped api is built once per pack id",
                    packId, tostring(had), tostring(opts.version)))
            end
        end
        -- Iterating the FIELD NAMES, not { opts.depends, opts.recommends }: a pack that
        -- declares only `recommends` would leave a hole at index 1 of that array and ipairs
        -- would stop before reaching it.
        local deps = {}
        for _, field in ipairs({ "depends", "recommends" }) do
            local list = opts[field]
            if type(list) == "table" then
                for k, v in pairs(list) do
                    if type(v) == "string" then deps[v] = true elseif v then deps[k] = true end
                end
            end
        end
        if next(deps) then om.declareDeps(packId, deps) end
    end

    local scoped = scopedApis[packId]
    if not scoped then
        -- `pack` rides along so the scoped table is a drop-in for the unscoped one: a pack
        -- that wrote `local api = PalForge.pack("mypack")` can still reach api.pack.
        scoped = { Player = Player, pack = api.pack }
        for _, name in ipairs(CONSTRUCTORS) do
            scoped[name] = scopeModule(api[name], packId, EXTRA_CONSTRUCTORS[name])
        end
        -- THE TENTH MEMBER: this pack's own saved state, `PalForge.pack("mypack").store`. The
        -- pack id is baked in, so there is no way to name another pack's store through it — the
        -- isolation is the surface, not a convention.
        --
        -- ⚠️ THIS TOUCHES NO DISK. storeFor is a handle, not a load: no file is opened, no
        -- directory is created, and a pack that registers no building definition and saves
        -- nothing still produces no file at all. That is F-8 and it was measured closed in game;
        -- a store that created its directory on the way past would silently reopen it.
        scoped.store = storeFor(packId)
        scopedApis[packId] = scoped
    end
    return scoped
end

--=============================================================================
-- reclaim drivers — the DOING half of db.reclaim, installed from this side
--=============================================================================
--
-- core/state knows WHAT a pack made the game record; it cannot know HOW to take it back,
-- because undoing an item goes through api/item and undoing a passive through core/character,
-- and core/state requires nothing from api/ — that acyclic graph is deliberate. So the drivers
-- are installed HERE, at the layer that already holds every domain, and core/state calls them
-- through M.RECLAIM_DRIVERS. Until this ran, `db.reclaim{ apply = true }` reported
-- "no reclaim driver on this build" for every reclaimable row and undid nothing.
--
-- ONLY THE TWO KINDS THAT CAN BE UNDONE ARE INSTALLED, and the other two stay absent rather
-- than getting a driver that fails: a technology unlock is IMPOSSIBLE to reverse on this build
-- (UPalCheatManager declares four unlock entries and no lock; LockTechnology /
-- RemoveTechnology / ResetTechnology / ForgetTechnology are zero hits in Pal.hpp) and a spawned
-- pal has no per-individual removal. core/state's RECLAIM table already says so in those words,
-- and a row it marks `impossible` never reaches a driver.
do
    local ok, state = pcall(require, "palforge.core.state")
    if ok and state and type(state.setReclaimDriver) == "function" then
        -- ITEM — spend it back out of the local player's bag. Handle:take answers how many it
        -- actually removed, which is exactly the partial result db.reclaim reports: an item the
        -- player moved into a chest is out of reach and the row says so instead of claiming it.
        state.setReclaimDriver("item", function(id, n)
            local h = Item.get(id)
            if not h then return 0, "no such item definition this session" end
            local taken = h:take(n)
            if taken == true then return n end
            if type(taken) == "number" then
                return taken, (taken < n) and "the rest is not in the local player's own bag" or nil
            end
            return 0, "take refused — no world, no player, or no weapon actor to spend through"
        end)

        -- PASSIVE — remove the skill from every actor this session can hold. core/character
        -- resolves the id at the engine boundary and reads the character back afterwards, so a
        -- true here means the pal really stopped carrying it rather than that the call ran.
        state.setReclaimDriver("passive", function(id, n)
            local character = require("palforge.core.character")
            if type(character.removeSkill) ~= "function" then
                return 0, "core/character exposes no removeSkill on this build"
            end
            local actors = {}
            pcall(function()
                for _, a in ipairs(FindAllOf("PalMonsterCharacter") or {}) do actors[#actors + 1] = a end
                local p = FindFirstOf("PalPlayerCharacter")
                if p then actors[#actors + 1] = p end
            end)
            if #actors == 0 then
                return 0, "no world loaded, so there is no character to take it off"
            end
            local done = 0
            for _, a in ipairs(actors) do
                local okRm = select(1, pcall(character.removeSkill, a, id))
                if okRm then done = done + 1 end
                if done >= n then break end
            end
            if done == 0 then return 0, "no held character carried it" end
            return math.min(done, n),
                (done < n) and "only the actors this session can reach were checked — a pal in "
                    .. "the box is not one of them" or nil
        end)
    end
end

return api
