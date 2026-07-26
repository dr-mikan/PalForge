-- PalSmith one-shot dump (client edition)  ==========================================
-- Acquires (in ONE run) everything in dump_targets.md (this folder) and writes it ONLY
-- into this dump/ directory. Standalone (no PalSmith deps). Run on the CLIENT (not the
-- dedicated server) so UI / animation / audio are available.
--
-- HOW TO RUN (throwaway world, AFTER the world has fully loaded):
--   UE4SS Lua console:   dofile([[<...>\ue4ss\Mods\PalSmith\dump\dump.lua]])
--   or the console cmd this registers:   ps_dump
--   OPEN the Build menu / Inventory / Paldeck BEFORE running to capture their widgets.
--
-- SAFETY: enumerating live DataTables/objects touches native memory; a stale pointer can
-- raise EXCEPTION_ACCESS_VIOLATION (pcall CANNOT catch it) — run DELIBERATELY in a
-- throwaway world. Every step is pcall-guarded; large sweeps are capped.
-- ====================================================================================

local thisDir = (debug.getinfo(1, "S").source:match("@?(.*[\\/])")) or ".\\"
local CAP = 800   -- max names per large asset sweep (keeps files sane)

-- ---- output helpers (write ONLY under thisDir) ----
local function writeFile(name, text)
    local ok, f = pcall(io.open, thisDir .. name, "w")
    if not ok or not f then return false end
    f:write(text); f:close(); return true
end
local Buf = {}
local function L(s) Buf[#Buf + 1] = s or "" end
local function flush(name) writeFile(name, table.concat(Buf, "\n") .. "\n"); Buf = {} end
local function fname(x)
    if x == nil then return "" end
    local ok, s = pcall(function() return x.ToString and x:ToString() or tostring(x) end)
    return ok and tostring(s) or tostring(x)
end
local function full(o) local ok, s = pcall(function() return o:GetFullName() end); return ok and tostring(s) or "?" end
local function clsName(o) local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end); return ok and tostring(s) or "?" end
local function valid(o) local ok, v = pcall(function() return o and o:IsValid() end); return ok and v end

-- =====================================================================================
-- 1. DataTables -> row names + RowStruct columns (schema). content ids + which columns
--    hold icon/mesh/params. Fills native/* ids + audio soundIds + iconOf/mesh + §4/§7.
-- =====================================================================================
local function dumpDataTables()
    Buf = {}
    L("# DataTable dump: rows (ids) + RowStruct columns (schema).")
    L("# grep tables for: Item / BuildObject|MapObject / Monster|Pal / Waza|Skill|ActiveSkill /")
    L("#                  Buff|Status|Passive / Technology / Sound|BGM|SE / Icon")
    L("")
    local dtfl = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
    local tables = {}
    pcall(function() tables = FindAllOf("DataTable") or {} end)
    L(("-- %d DataTable(s) --"):format(#tables)); L("")
    for _, dt in ipairs(tables) do
        pcall(function()
            if not valid(dt) then return end
            L("== " .. full(dt) .. " ==")
            -- columns (RowStruct properties)
            local cols = {}
            pcall(function()
                local rs = dt.RowStruct
                if valid(rs) then rs:ForEachProperty(function(p) pcall(function() cols[#cols + 1] = fname(p:GetFName()) end) end) end
            end)
            if #cols > 0 then table.sort(cols); L("  [columns] " .. table.concat(cols, ", ")) end
            -- rows
            local rows
            if valid(dtfl) then pcall(function() rows = dtfl:GetDataTableRowNames(dt) end) end
            if not rows then pcall(function() rows = dt:GetRowNames() end) end
            if rows then
                local n = 0; pcall(function() n = #rows end)
                for i = 1, (n or 0) do pcall(function() L("  " .. fname(rows[i])) end) end
                L(("  (%d rows)"):format(n or 0))
            else L("  <no row-name accessor>") end
            L("")
        end)
    end
    flush("01_datatables.txt")
end

-- =====================================================================================
-- 2. Class reflection -> functions (event hooks) + properties (icon/mesh/data fields).
--    Best-effort (UE4SS ForEachFunction/ForEachProperty). If unavailable, use UE4SS's
--    built-in Object/CXX dump or the installed ActorDumperMod (see 00_README).
-- =====================================================================================
local CANDIDATE_CLASSES = {
    "/Script/Pal.PalGameInstance", "/Script/Pal.PalPlayerController", "/Script/Pal.PalPlayerState",
    "/Script/Pal.PalPlayerCharacter", "/Script/Pal.PalCharacter", "/Script/Pal.PalNetworkPlayerComponent",
    "/Script/Pal.PalIndividualCharacterParameter", "/Script/Pal.PalCharacterParameterComponent",
    "/Script/Pal.PalCaptureManager", "/Script/Pal.PalMonsterParameterComponent",
    "/Script/Pal.PalBuildObject", "/Script/Pal.PalMapObjectModel", "/Script/Pal.PalMapObjectConcreteModelBase",
    "/Script/Pal.PalMapObjectItemContainerModule", "/Script/Pal.PalMapObjectItemChestModel",
    "/Script/Pal.PalItemUseProcessor", "/Script/Pal.PalPlayerInventoryData", "/Script/Pal.PalItemContainer",
    "/Script/Pal.PalItemSlot", "/Script/Pal.PalUtility", "/Script/Pal.PalSoundUtility",
}
local function dumpReflection()
    Buf = {}
    L("# Class reflection: [functions]=event hooks  [properties]=data fields")
    L("# grep functions: Spawn|BeginPlay Damage|Hit Death|Dead Capture Build|Complete Use|Consume|Add|Craft|Product|Discard|Remove World|Load|Begin|End")
    L("")
    local anyOk = false
    for _, path in ipairs(CANDIDATE_CLASSES) do
        pcall(function()
            local cls = StaticFindObject(path)
            L("================ " .. path .. (valid(cls) and "" or "   <NOT LOADED>") .. " ================")
            if not valid(cls) then L(""); return end
            local fns, props = {}, {}
            local okF = pcall(function() cls:ForEachFunction(function(fn) pcall(function() fns[#fns + 1] = fname(fn:GetFName()) end) end) end)
            local okP = pcall(function() cls:ForEachProperty(function(pr) pcall(function() props[#props + 1] = fname(pr:GetFName()) end) end) end)
            anyOk = anyOk or okF
            table.sort(fns); table.sort(props)
            L("  [functions] " .. (okF and (#fns .. "") or "ForEachFunction UNAVAILABLE"))
            for _, s in ipairs(fns) do L("    ." .. s) end
            L("  [properties] " .. (okP and (#props .. "") or "ForEachProperty UNAVAILABLE"))
            for _, s in ipairs(props) do L("    :" .. s) end
            L("")
        end)
    end
    if not anyOk then
        L("!! ForEachFunction/ForEachProperty unavailable in this UE4SS build.")
        L("!! Fallback: use UE4SS built-in dumper (GUI 'Dump Objects' / generate CXX headers),")
        L("!! or the installed ActorDumperMod / KismetDebuggerMod, to list class functions.")
    end
    flush("02_reflection.txt")
end

-- =====================================================================================
-- 3. Widget trees (client UI: title / HUD / build menu / inventory / paldeck — open them
--    before running). Fills native/ui + §5.
-- =====================================================================================
local function widgetName(w)
    local ok, n = pcall(function() return w:GetFName():ToString() end)
    if ok and n and #n > 0 then return tostring(n) end
    return (full(w):match("[%.:]([%w_]+)$")) or "?"
end
local function walk(w, depth)
    if not valid(w) or depth > 18 then return end
    L(("  "):rep(depth) .. widgetName(w) .. "  <" .. clsName(w) .. ">")
    pcall(function() local t = w.WidgetTree; if valid(t) and valid(t.RootWidget) then walk(t.RootWidget, depth + 1) end end)
    local n = 0; pcall(function() n = w:GetChildrenCount() end)
    for i = 0, (n or 0) - 1 do local c; pcall(function() c = w:GetChildAt(i) end); if c then walk(c, depth + 1) end end
    if (n or 0) == 0 then local ct; pcall(function() ct = w:GetContent() end); if valid(ct) then walk(ct, depth + 1) end end
end
local function dumpWidgets()
    Buf = {}
    L("# Live widget trees (OPEN Build menu / Inventory / Paldeck before running).")
    L("")
    for _, cn in ipairs({ "PalUITitleBase", "PalHUD", "PalHUDWidget", "PalUIBuildMenu",
                          "PalUIInventoryMain", "PalUIPalStorageBox", "PalUICommonUINavigationBase" }) do
        local w; pcall(function() w = FindFirstOf(cn) end)
        if valid(w) then L("### ROOT " .. cn .. " : " .. full(w)); walk(w, 0); L("") end
    end
    local all = {}; pcall(function() all = FindAllOf("UserWidget") or {} end)
    L(("### ALL live UserWidgets (%d) — name <class>"):format(#all))
    local seen, cnt = {}, 0
    for _, w in ipairs(all) do
        if cnt >= CAP then L("  ... capped at " .. CAP); break end
        pcall(function() local k = full(w); if not seen[k] then seen[k] = true; cnt = cnt + 1; L("  " .. widgetName(w) .. "  <" .. clsName(w) .. ">  " .. k) end end)
    end
    flush("03_widgets.txt")
end

-- =====================================================================================
-- 4. Live objects (real build ids from placed objects; live pals + their asset refs:
--    SkeletalMesh / AnimClass / mesh). Fills native/building ids + mesh/skeletal + §6.
-- =====================================================================================
local function assetRefsOf(o)
    local out = {}
    pcall(function() local m = o.Mesh; if valid(m) then
        out.meshComp = clsName(m)
        pcall(function() local sm = m.SkeletalMesh; if sm then out.skeletalMesh = full(sm) end end)
        pcall(function() local st = m.StaticMesh; if st then out.staticMesh = full(st) end end)
        pcall(function() local ac = m.AnimClass; if ac then out.animClass = full(ac) end end)
        pcall(function() local anim = m:GetAnimInstance(); if valid(anim) then out.animInstance = clsName(anim) end end)
    end end)
    return out
end
local function dumpLiveObjects()
    Buf = {}
    L("# Live objects — real ids + asset refs (mesh/anim) from what's in the world")
    L("")
    local function sweep(cn, label, withAssets)
        local arr = {}; pcall(function() arr = FindAllOf(cn) or {} end)
        L(("== %s : %d live =="):format(label or cn, #arr))
        local seenCls = {}
        for _, o in ipairs(arr) do
            pcall(function()
                local c = "?"; pcall(function() c = o:GetClass():GetFullName() end)
                if not seenCls[c] then
                    seenCls[c] = true
                    local id = tostring(c):match("BP_BuildObject_([%w_]+)_C") or tostring(c):match("BP_[%w]+_([%w_]+)_C")
                    L("  class " .. tostring(c) .. (id and ("   -> id: " .. id) or ""))
                    if withAssets then
                        local a = assetRefsOf(o)
                        for k, v in pairs(a) do L("      " .. k .. " = " .. tostring(v)) end
                    end
                end
            end)
        end
        L("")
    end
    sweep("PalBuildObject", "PalBuildObject (build ids + mesh)", true)
    sweep("PalCharacter",   "PalCharacter (pal/player + skeletal/anim)", true)
    sweep("PalMapObjectModel", "PalMapObjectModel", false)
    flush("04_live_objects.txt")
end

-- =====================================================================================
-- 5. Asset sweeps (capped): animation / mesh / audio / icon assets by name+path.
--    Fills animation, mesh render, Wwise audio, iconOf.
-- =====================================================================================
local function dumpAssets()
    Buf = {}
    L("# Asset sweeps (capped " .. CAP .. " each). grep by name for the pal/item/skill you want.")
    L("")
    local function sweep(cn, label, filter)
        local arr = {}; pcall(function() arr = FindAllOf(cn) or {} end)
        L(("== %s : %d loaded =="):format(label or cn, #arr))
        local cnt = 0
        for _, o in ipairs(arr) do
            if cnt >= CAP then L("  ... capped"); break end
            pcall(function()
                local fn = full(o)
                if (not filter) or tostring(fn):lower():find(filter) then cnt = cnt + 1; L("  " .. fn) end
            end)
        end
        L("")
    end
    -- animation
    sweep("AnimMontage",   "AnimMontage (montages)")
    sweep("AnimSequence",  "AnimSequence")
    sweep("AnimBlueprintGeneratedClass", "AnimBlueprint classes")
    -- mesh
    sweep("SkeletalMesh",  "SkeletalMesh")
    sweep("StaticMesh",    "StaticMesh")
    -- audio (Wwise + engine sound)
    sweep("AkAudioEvent",  "AkAudioEvent (Wwise events)")
    sweep("SoundBase",     "SoundBase")
    sweep("SoundWave",     "SoundWave")
    -- icons (filter Texture2D by name containing 'icon')
    sweep("Texture2D",     "Texture2D name~=icon", "ico")
    flush("05_assets.txt")
end

-- =====================================================================================
-- run everything (one shot) + index
-- =====================================================================================
local function runAll()
    local steps = {
        { "01_datatables",   dumpDataTables },
        { "02_reflection",   dumpReflection },
        { "03_widgets",      dumpWidgets },
        { "04_live_objects", dumpLiveObjects },
        { "05_assets",       dumpAssets },
    }
    local status = {}
    for _, s in ipairs(steps) do
        local ok, err = pcall(s[2])
        status[#status + 1] = (ok and "OK   " or "FAIL ") .. s[1] .. (ok and "" or (" : " .. tostring(err)))
    end
    Buf = {}
    L("# PalSmith dump index (client) — written into this dump/ folder only.")
    L("")
    L("Maps to dump_targets.md (this folder):")
    L("  01_datatables.txt   -> §4 content ids (item/build/pal/skill/status/tech) + column schema + §4(2e) SoundIDs")
    L("  02_reflection.txt   -> §3 life-event hooks + iconOf/mesh property fields")
    L("  03_widgets.txt      -> §5 native UI (open Build/Inventory/Paldeck before running)")
    L("  04_live_objects.txt -> §4 real build ids + §6 live pal skeletal/anim refs")
    L("  05_assets.txt       -> animation / mesh / Wwise audio / icon assets")
    L("")
    L("If 02_reflection says 'UNAVAILABLE', use UE4SS's built-in Object/CXX dump or ActorDumperMod for functions.")
    L("Re-run after opening each menu to capture more UI in 03.")
    L("")
    L("Run status:")
    for _, s in ipairs(status) do L("  " .. s) end
    flush("00_README.txt")
    pcall(function() print("[PalSmith.dump] done -> " .. thisDir .. " (see 00_README.txt)") end)
end

pcall(function()
    if type(RegisterConsoleCommandHandler) == "function" then
        RegisterConsoleCommandHandler("ps_dump", function()
            if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(function() pcall(runAll) end) else pcall(runAll) end
            return true
        end)
    end
end)
if type(ExecuteInGameThread) == "function" then ExecuteInGameThread(function() pcall(runAll) end) else pcall(runAll) end
return { run = runAll }
