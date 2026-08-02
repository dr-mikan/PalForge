-- palforge/core/ledger.lua — THE GATE on "what did PalForge make the GAME write?".
--
-- READ THIS FIRST, because it is the half of the removal question that is actually real.
--
-- PalForge's own state is a SIDECAR: one JSON file per pack under <Mods>/PalForge/state/,
-- written by core/state.lua and by nothing else. Deleting the mod deletes the sidecar and
-- Palworld's own .sav is untouched — there is no SaveGame / RequestSave / WriteSave call
-- anywhere in Scripts/palforge, and never has been.
--
-- What DOES reach Palworld's save is what PalForge asks the GAME to do, and there are exactly
-- three such calls in the whole framework:
--
--     Item.get("mypack:Potion"):give(1)     -- an FName lands in an inventory container
--     Building.get("mypack:Bench"):unlock() -- an FName lands in the player's technology list
--     Skill.get("mypack:Legend"):teach(pal) -- an FName lands on a character's passive list
--
-- Those three names exist as DataTable rows only because PalSchema injected them. Remove the
-- pack and the save holds a name with no row behind it. Everything readable off the binary says
-- that shape is a MISSING LOOKUP rather than a broken file — the save stores plain FNames and
-- resolves rows through accessors built to fail (TryGetStaticItemData -> bool, the whole
-- BP_FindRow(row, bool&) family), and EPalSaveError { Success, NotFound, Unknown, Broken,
-- OutOfMemory } has no "unknown content" member. ⚠️ But NOBODY HAS YET LOADED A SAVE WHOSE PACK
-- WAS GONE, so that is well-founded, not proven — test/hooks/save-survives-pack-removal is the
-- only thing that can settle it, and the load path is unreflected C++ (FPalBinaryMemory) so
-- there is nothing to sig.describe: it is empirical or it is nothing.
--
-- WHAT THIS FILE IS, AND WHAT IT IS NOT. The ledger itself — the rows, the file section, the
-- reclaim rules, the report — lives in core/state.lua (state.ledgerAdd, store.ledger,
-- store.reclaim). This module is the GATE in front of it, and it exists because state.lua
-- deliberately requires nothing from api/ and therefore cannot be the place that knows which
-- api call is worth recording. Three lines in three files call M.record; everything they share
-- is here, once:
--
--     which object_manager TYPE a kind's ids are registered under,
--     the ownership test that decides whether a call is worth recording at all,
--     the resolve to the ROW spelling, which is the spelling the save holds.
--
-- THE GATE IS THE ID'S NAMESPACE, AND THAT IS A CORRECTION — measured 2026-08-02, headless.
-- The store specification says to gate on object_manager.owner ("more precise than a namespaced
-- test") with `Item.get("Wood"):give(1)` as the example that must write nothing. In THIS tree
-- that is false, and the example is the case it breaks on:
--
--     om.owner("item", "Wood")  ->  "palforge"
--
-- because native/_catalog.lua:161 registers the curated vanilla rows under the FRAMEWORK's own
-- pack id (contract C3, native/items.lua:532 — so that a pack redefining "Wood" replaces
-- something whose previous owner can be named). An owner-gated ledger would therefore record
-- every vanilla give in the game under pack "palforge", which is exactly the noise the rule
-- exists to keep out of the one report that has to be trustworthy.
--
-- The question the ledger actually answers is "which names in this save lose their DataTable row
-- when a pack goes?", and that is decided by the ROW, not by who called:
--   Item.get("Wood"):give(1)               -- "Wood" is a GAME row -> nothing is written
--   Item.get("mypack:Potion"):give(1)      -- "mypack_Potion" exists only because PalSchema
--                                          -- injected it -> a row is written
-- The namespaced test is right on both, and it is also right on the case owner MISSES: a pack
-- that declared its item as PalSchema JSON and never as a PalForge definition still has a row
-- that vanishes with it, and om.owner answers nil for that id.
--
-- om.owner is still asked — not as the gate, but for ATTRIBUTION, so a row lands in the file of
-- the pack that made the call. When nothing is registered it falls back to the id's own
-- namespace, which is the pack whose removal takes the row away.
--
-- THE KEY IS THE RESOLVED FORM ("mypack_Potion"), because that is the spelling the SAVE holds.
-- The source id ("mypack:Potion") is a PalForge-side spelling that never reaches a container.
--
-- IT IS AN INTENT LOG, NOT A MIRROR. It records that PalForge asked the game to write a name,
-- and when. It does NOT know whether the item is still in the bag: the inventory is
-- FPalWorldSaveData.ItemContainerSaveData (dumps/cxx/Pal.hpp:7927), a map of MANY containers the
-- game owns, and PalForge reaches exactly one of them. A mirror would be wrong the first time
-- the player used a chest. core/state.lua's ledger section says the same thing from the storage
-- side; both are true and neither is the other's copy.
--
-- A LEDGER APPEND MUST NEVER BREAK A GIVE. Every entry point here is fail-soft: it returns
-- false plus a reason and it never raises, because the player's item has already landed by the
-- time this is called and an error here would turn a working action into a broken one.
local om  = require("palforge.core.object_manager")
local log = require("palforge.utils.log").scope("ledger")

local M = {}

--=============================================================================
-- the four kinds
--=============================================================================

-- Each kind names the object_manager TYPE its ids are registered under — so the ownership gate
-- asks the right bucket — and what a successful call of that kind put into PALWORLD'S save.
-- WHAT CAN BE TAKEN BACK IS NOT DECLARED HERE: core/state.lua's RECLAIM table owns that, it is
-- what store.reclaim() reports out of, and a second copy able to disagree with the first is
-- exactly the failure class this whole redesign exists to remove.
--
-- ACTIVE skills are deliberately absent from this table and are never ledgered at all:
-- EPalWazaID is a fixed vanilla enum (core/character.lua:102), Lua cannot mint a value, so
-- nothing written through AddEquipWaza can ever stop being valid. `pal` is declared because the
-- format carries it, and is written by nothing today — Pal:spawn stays unledgered until
-- `pf_hook pal-spawn-persisted` says whether a spawned pal carries a per-individual id at all,
-- and whether that id reaches CharacterSaveParameterMap. That hook named nothing for a while:
-- this comment pointed at `test/hooks/pal-spawn-persisted` while no such file existed, which
-- reads as "someone is measuring it" and is a dead end. It exists now
-- (test/hooks/pal_spawn_persisted.lua) and it WRITES — a spawn cannot be taken back, which is
-- also why core/state.lua's RECLAIM records this kind as can = false.
-- A run of nils from it is a complete answer: `pal` then cannot be a ledger kind on this build
-- and this table should say that instead of pointing anywhere.
local KIND = {
    item    = { otype = "item",
                wrote = "a StaticItemId into an inventory container" },
    tech    = { otype = "building",
                wrote = "an FName into the player's unlocked-technology list" },
    passive = { otype = "skill",
                wrote = "an FName onto a character's passive-skill list" },
    pal     = { otype = "pal",
                wrote = "a character into the world's save data" },
}

-- Report order, so anything iterating the kinds reads the same way every time.
-- THE ROSTER LIVES IN core/state, as M.LEDGER_KINDS, and this used to be a second ordered copy
-- of it that nothing in the tree read. The two had already drifted — `item, tech, passive, pal`
-- here against `item, passive, tech, pal` in the report — so the one thing an ordered list is
-- for was not true of it. The table below is this module's own concern, the WRITE side: which
-- object_manager type a kind is attributed through and how the log line reads. Adding a fifth
-- kind means a line in state.M.LEDGER_KINDS, a rule in state's RECLAIM, and a row here.

---What a kind means: { otype, wrote }, as a copy, or nil for a name that is not one of the four.
---@param kind string
---@return table?
function M.kind(kind)
    local cfg = KIND[kind]
    if not cfg then return nil end
    return { otype = cfg.otype, wrote = cfg.wrote }
end

--=============================================================================
-- reaching the store
--=============================================================================

-- core/state.lua is required LAZILY and behind a pcall, for three reasons that have each cost a
-- session in this tree: it keeps this module loadable by tooling outside the game; it survives F9
-- (core/reload wipes modules, and a memoized reference would close over a wiped one — the exact
-- shape object_manager's lazy logger is written against); and a store that failed to load must
-- degrade to "no ledger this session", loudly, rather than take a working :give down with it.
-- The require is re-asked every call on purpose: after the first load it is a table lookup in
-- package.loaded, and an append happens a handful of times per player action.
local warnedNoStore = false

-- The pcall guards the REQUIRE, not the module's surface: core.state ships ledgerAdd, so a
-- `type(mod.ledgerAdd) == "function"` probe beside it was constant-true and only made the
-- refusal message describe a state that cannot occur. What CAN occur is the require failing —
-- a syntax error mid-edit, or a cycle during load — and that is what this degrades on.
local function state()
    local ok, mod = pcall(require, "palforge.core.state")
    if ok and type(mod) == "table" then return mod end
    if not warnedNoStore then
        warnedNoStore = true
        log.warn("no ledger this session: palforge.core.state did not load, so PalForge cannot "
            .. "record which pack-owned ids it asked the game to write. Giving, unlocking and "
            .. "teaching all still work — only the removal report for this session is lost")
    end
    return nil
end

--=============================================================================
-- writing
--=============================================================================

---Record that PalForge asked the game to write a PACK-INJECTED id, and that the call SUCCEEDED.
---
---Called from exactly three places, each behind that call's own success test: Item.Handle:give,
---Building.Handle:unlock and core/character.addSkill's PASSIVE branch. It is a no-op — false plus
---a reason, never an error, never a log line — for every LITERAL id, which is the common case and
---is what keeps `Item.get("Wood"):give(1)` writing nothing at all.
---
---`kind` is one of "item" | "tech" | "passive" | "pal"; `id` is the SOURCE id the caller used
---("mypack:Potion" or "Wood") and is resolved to the row spelling before it is stored, because
---the row spelling is what the save holds.
---@param kind string
---@param id string
---@param count integer?  # how many (default 1); accumulated into the row's `n`
---@return boolean recorded
---@return string? reason  # why nothing was recorded
function M.record(kind, id, count)
    local cfg = KIND[kind]
    if not cfg then return false, "unknown ledger kind '" .. tostring(kind) .. "'" end
    if type(id) ~= "string" or #id == 0 then return false, "id must be a non-empty string" end

    -- THE GATE (see the header): is the row this id resolves to one that only a pack's PalSchema
    -- JSON put there? A literal id is a game row and a game row cannot stop existing.
    -- `[^:]+` and not `[^:]*` on purpose: ":Potion" has no namespace, so it falls through here
    -- as a literal rather than being blamed on an empty pack id.
    local ns = id:match("^([^:]+):")
    if not ns then
        return false, string.format("'%s' is a literal game id — its DataTable row is the "
            .. "game's and cannot stop existing, so there is nothing to report on removal", id)
    end
    -- THE ROW SPELLING, and this is the one boundary in the tree where `resolve(x) or x` is NOT
    -- the rule. Everywhere else an unresolvable id falls back to the literal so the engine
    -- receives what the caller asked for; here there is no engine to ask. An id whose shape
    -- resolve refuses ("my-pack:Potion" — a hyphen) can never BE a DataTable row, so no container
    -- in the save can be holding it and there is nothing to report on removal. Refused, named.
    local resolved = om.resolve(id)
    if not resolved then
        return false, string.format("'%s' cannot resolve to a row spelling, so nothing in the "
            .. "save can be referring to it", id)
    end

    -- Attribution, not permission. The namespace is the fallback because it names the pack whose
    -- removal takes the row away, which is the question a removal report answers.
    local pack = om.owner(cfg.otype, id) or ns
    if not pack:match("^[%w_]+$") then
        -- A pack id is a FILE NAME under state/<save>/. object_manager.register does not check
        -- the shape of opts.pack, so this is asked here rather than handed to the store, whose
        -- keyFor would refuse it later with no call site left to name.
        return false, string.format("'%s' would be filed under pack '%s', which is not a legal "
            .. "file name (letters, digits or _)", id, pack)
    end

    local st = state()
    if not st then return false, "core.state is unavailable this session" end

    local n = math.floor(tonumber(count) or 1)
    if n < 1 then n = 1 end

    local ok, res, why = pcall(st.ledgerAdd, pack, kind, resolved, n)
    if not ok then
        -- The action itself already succeeded; this is bookkeeping and must not surface as one.
        log.warn(string.format("ledger append failed for %s '%s' (pack '%s'): %s",
            kind, resolved, pack, tostring(res)))
        return false, tostring(res)
    end
    if not res then
        log.warn(string.format("ledger refused %s '%s' (pack '%s'): %s — PalForge is writing a "
            .. "pack-owned name into this save and keeping no record of it",
            kind, resolved, pack, tostring(why)))
        return false, why
    end
    return true
end

--=============================================================================
-- reading — thin forwards, so there is one implementation and one place to fix it
--=============================================================================

---One pack's ledger for the current save: { item = {...}, tech = {...}, passive = {...},
---pal = {...} }, or nil when the store is unavailable. A COPY (store.ledger's own): writing to
---it changes nothing, and M.record is the only writer.
---@param packId string
---@return table?
function M.read(packId)
    if type(packId) ~= "string" or #packId == 0 then return nil end
    local st = state()
    if not st then return nil end
    local ok, led = pcall(function()
        local db = st.storeFor(packId)
        return type(db) == "table" and db.ledger() or nil
    end)
    return (ok and type(led) == "table") and led or nil
end

---What removing this pack would leave behind, and which of it can be taken back — store.reclaim's
---report, reached by pack id. See core/state.lua: the report NAMES what it could not undo, and a
---technology unlock is the one that can never be undone on this build.
---@param packId string
---@param opts table?
---@return table? report
function M.reclaim(packId, opts)
    if type(packId) ~= "string" or #packId == 0 then return nil end
    local st = state()
    if not st then return nil end
    local ok, rep = pcall(function()
        local db = st.storeFor(packId)
        return (type(db) == "table" and type(db.reclaim) == "function") and db.reclaim(opts) or nil
    end)
    return (ok and type(rep) == "table") and rep or nil
end

return M
