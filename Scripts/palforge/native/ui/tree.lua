-- OBSERVED WORKING, 2026-07-27. A declared tree really does draw inside the game's own UI:
--
--   pf_uidecl: MOUNTED into PalPrimaryGameLayoutBase.CanvasPanel_Root | slot=CanvasPanelSlot
--     | root=Border ...WBP_PalOverallUILayout_C...CanvasPanel_Root.Border_2147458111
--
-- and the panel was visible on screen. That was the load-bearing gap: everything about hosting
-- inside the game's canvas was paper until this line — the class declares the panel, a
-- UCanvasPanel is a UPanelWidget, an instance was live in the widget dump — and none of that is
-- the same as watching a widget appear. It appears.
--
-- Two things that had to be right at once are therefore both right: a fresh CanvasPanelSlot
-- gives the tree a drawable size, and the button node builds from a class the world actually
-- has (see _widget.buttonClass — the title-menu class is not loaded in a world, which is what
-- the first attempt died on).
--
-- PalForge native.ui.tree: turn a DECLARED node tree into real widgets, and keep it in
-- step. api/ui declares the vocabulary (UI.VBox / UI.Label / UI.Button — pure data, no
-- engine anywhere in it); this file is the only place that data meets UMG.
--
-- THE SPLIT, AND WHY IT IS EXACTLY HERE. api/ui.lua has never made an engine call, which
-- is what lets test/cases/ui.lua prove the whole lifecycle with no game running. Putting
-- the node CONSTRUCTORS there and the widget CONSTRUCTION here keeps that property: a
-- declared tree can be built, validated, nested and inspected headlessly, and the first
-- thing that can fail for a game-shaped reason is `tree.mount`, which is reached through a
-- lazy require from api/ui and returns nil + a sentence rather than raising.
--
--   node (pure table, api/ui)  ->  tree.mount  ->  widgets (_widget.lua)  ->  a host panel
--
-- WHAT A "BUILT" TREE IS. One table, returned by mount and handed back to update/destroy:
--   root    the widget the tree's root node became (what was added to the host)
--   slot    the host's slot for it, when the host handed one back
--   byName  every node that declared `name`, as name -> live widget (UI.Handle:find)
--   binds   one record per DYNAMIC field: { get = fn, set = fn, widget = w, last = value }
--   clicks  the click-router keys this tree registered, so destroy can release exactly
--           its own and no other element's
--
-- BINDINGS, i.e. why a field may be a function. A declared tree is built once; if the only
-- way to change what it says were to rebuild it, :refresh() would be dead weight for every
-- declarative element and a panel would have to be torn down to show a new number. So a
-- bindable field (`text`, `visible`) accepts a function, it is called with the ELEMENT
-- INSTANCE as its argument, and update() re-calls it and writes the result only when it
-- CHANGED. That last part is the syncEntry discipline from title_menu.lua:77-99, for the
-- same reason: a heartbeat refresh over an unchanged panel should cost comparisons, not
-- native calls.
--
-- ALL OR NOTHING. A node that will not build fails the whole mount: everything already
-- built is dropped, the click keys are released, and mount returns nil + which node failed
-- and why. api/ui turns that into `render -> false`, which leaves the element UNMOUNTED so
-- :autoMount retries it — the shape a host that is not up yet needs (api/ui.lua:115-124).
-- A half-built panel that latched as mounted could never be repaired by retrying.
--
-- WHAT IS PROVEN AND WHAT IS NOT. Every widget call below is one this tree already makes
-- somewhere that shipped: the primitives are _widget.lua's (verified in-game 2026-07-17,
-- poc/V6-ui-native), the button is exactly native/ui/button.lua's route, and constructing a
-- native primitive with a GAME-OWNED panel as its outer is what title_menu.lua:112 does for
-- every entry it injects. What nobody has watched is a declared tree drawing inside
-- WBP_PalOverallUILayout's CanvasPanel_Root: the host is confirmed to EXIST and to be a
-- UPanelWidget (dumps/cxx/WBP_PalOverallUILayout.hpp:9, live instance at
-- dumps/reflection/03_widgets.txt:54), and nothing has yet been seen to appear in it.

local widget = require("palforge.native.ui._widget")
local keys   = require("palforge.native.ui.keys")
local sig    = require("palforge.core.signature")

local M = {}

local alive = widget.alive

-- Slate alignment, named as a pack author writes it. The integers are _widget.HALIGN /
-- VALIGN, which read them off SlateCore_enums.hpp:91-97.
local HALIGN = { fill = widget.HALIGN.FILL, left = widget.HALIGN.LEFT,
                 center = widget.HALIGN.CENTER, right = widget.HALIGN.RIGHT }
local VALIGN = { fill = widget.VALIGN.FILL, top = widget.VALIGN.TOP,
                 center = widget.VALIGN.CENTER, bottom = widget.VALIGN.BOTTOM }

-- ESlateVisibility (dumps/cxx/UMG_enums.hpp:48-55). COLLAPSED, not Hidden, for a false:
-- Hidden keeps the widget's space in the layout and Collapsed does not, and a row that
-- vanishes leaving a hole is not what `visible = false` reads as.
local VISIBLE, COLLAPSED = 0, 1

--=============================================================================
-- pure helpers — no engine call, so the suite can check them headlessly
--=============================================================================

---Resolve a possibly-BOUND value. A function is the binding form: it is called with the
---element instance and its return is the value. A raising binding yields nil plus the
---error text rather than taking the refresh down — it runs on every heartbeat, and one bad
---frame must not stop the other bindings in the same tree.
---@return any value, string? err
function M.valueOf(v, self)
    if type(v) ~= "function" then return v end
    local ok, r = pcall(v, self)
    if ok then return r end
    return nil, tostring(r)
end

---An FMargin-shaped table from a number (all four sides) or a { left =, top =, ... } table.
---nil for anything else, which is how a node with no padding skips the call entirely.
---
---This is the ONE struct-shaped argument this file passes, and it is deliberate rather than
---an oversight of the rule in core/signature.lua: SetPadding(FMargin) with exactly the four
---field names below is already in the shipped title-menu path (title_menu.lua:40-41,
---_widget.lua:574-575) and has run in game without incident, where SetAnchors(FAnchors) /
---SetAlignment(FVector2D) were removed from that same file for being unread struct calls.
---The difference that matters is that FMargin's four floats are named here in full, so
---UE4SS has a complete table to marshal rather than a partial one. It stays inside a pcall
---and it stays optional: a node that declares no padding makes no such call.
function M.margin(p)
    if type(p) == "number" then return { Left = p, Top = p, Right = p, Bottom = p } end
    if type(p) ~= "table" then return nil end
    return { Left   = tonumber(p.left   or p.Left)   or 0,
             Top    = tonumber(p.top    or p.Top)    or 0,
             Right  = tonumber(p.right  or p.Right)  or 0,
             Bottom = tonumber(p.bottom or p.Bottom) or 0 }
end

--=============================================================================
-- writers — one per bindable field, so update() and build() write the same way
--=============================================================================

local function setText(w, v)
    local s = (v == nil) and "" or tostring(v)
    return pcall(function() w:SetText(FText(s)) end) == true
end

local function setVisible(w, v)
    local mode = (v == false or v == nil) and COLLAPSED or VISIBLE
    return pcall(function() w:SetVisibility(mode) end) == true
end

-- A button's text is not its child's text: some button classes declare their own SetText and
-- some do not, and only _widget knows which. One writer for the build and for the refresh.
local function setButtonText(w, v)
    return widget.setButtonText(w, (v == nil) and "" or tostring(v))
end

--=============================================================================
-- slots — the parent's half of a child's layout
--=============================================================================

-- Alignment goes through core/signature, so a slot class that does not declare it logs a
-- named refusal instead of raising:
-- SetHorizontalAlignment / SetVerticalAlignment are declared by every box, overlay, border
-- and size slot (UMG.hpp:734, :1056, :287, :1328, :1800) and by NO canvas slot — a
-- UCanvasPanelSlot has SetAnchors/SetAlignment instead (:364-365), both struct calls. So a
-- node that asks for alignment inside the game's own canvas host gets a logged refusal
-- naming what the slot really declares, instead of a raise or a silent no-op.
-- ByteProperty covers both spellings: signature treats it and EnumProperty as equivalent.
local function applySlot(slot, node)
    if type(slot) ~= "userdata" then return false end   -- `true` = placed, no slot to style
    if node.hAlign then
        sig.call(slot, "SetHorizontalAlignment", { "ByteProperty" }, HALIGN[node.hAlign])
    end
    if node.vAlign then
        sig.call(slot, "SetVerticalAlignment", { "ByteProperty" }, VALIGN[node.vAlign])
    end
    local m = M.margin(node.padding)
    if m then
        -- Both forms, as every slot write in this tree does: UE4SS setters sometimes no-op
        -- where the property write lands, and vice versa (see _widget.sizeBox).
        pcall(function() slot:SetPadding(m) end)
        pcall(function() slot.Padding = m end)
    end
    return true
end

-- Which kinds hold their child through SetContent rather than AddChild. UBorder and USizeBox
-- are UContentWidgets (UMG.hpp:247, :1291 -> :505), and SetContent is what the shipped
-- screen frame and title-menu entry use (_widget.lua:384-386, title_menu.lua:113).
-- `frame` joins them because what it hands back as a parent is a UNamedSlot, which is a
-- UContentWidget too (UMG.hpp:1042 -> :505).
local CONTENT = { border = true, sizebox = true, frame = true }

-- Put `child` into `parent` and return something to style: the slot when one came back,
-- `true` when the child was placed but this build handed back no slot, nil when it was not
-- placed at all. SetContent is DECLARED to return a UPanelSlot (UMG.hpp:507) and the
-- shipped call sites ignore it, so no run has ever confirmed it answers here — hence the
-- middle case, which loses the styling and keeps the child.
local function attach(parentNode, parentWidget, childWidget)
    if CONTENT[parentNode.kind] then
        local ok, slot = pcall(function() return parentWidget:SetContent(childWidget) end)
        if not ok then return nil end
        return slot or true
    end
    return widget.addChild(parentWidget, childWidget)
end

--=============================================================================
-- makers — node kind -> one live widget
--
-- Each raises on failure (error, not a return): buildNode pcalls them, so a raise becomes
-- the reason string in mount's second return. `ctx` carries the construct outer, the
-- element instance the bindings read, and a lazily-found player controller.
--=============================================================================

local MAKE = {}

-- A note is something that WORKED but not the way the declaration asked for — a native frame
-- that fell back to a Border, a native label on a build where the class is not resident. It is
-- not a failure (the panel drew) and it must not be silence (the panel does not look like what
-- was written), so it is collected on the built tree and api/ui logs it once per mount.
local function note(built, msg)
    if type(built) ~= "table" then return end
    built.notes = built.notes or {}
    built.notes[#built.notes + 1] = tostring(msg)
end

MAKE.vbox    = function(_, ctx) return widget.vbox(ctx.outer) end
MAKE.hbox    = function(_, ctx) return widget.hbox(ctx.outer) end
MAKE.overlay = function(_, ctx) return widget.overlay(ctx.outer) end
MAKE.scroll  = function(_, ctx) return widget.scrollBox(ctx.outer) end
MAKE.border  = function(node, ctx) return widget.border(ctx.outer, node.color) end
MAKE.sizebox = function(node, ctx) return widget.sizeBox(ctx.outer, node.width, node.height) end

-- The player controller a Blueprint widget has to be created for. Found once per mount and
-- kept on ctx: WidgetBlueprintLibrary:Create needs one (_widget.create), and a tree with
-- five buttons should not do five FindFirstOf calls.
local function controller(ctx)
    if ctx.pc == nil then ctx.pc = widget.findFirst("PalPlayerController") or false end
    if not ctx.pc then error("no PalPlayerController to own a Blueprint widget", 0) end
    return ctx.pc
end

-- Record a binding when the field was declared as a function. `last` is what was just
-- written, so the first refresh only writes if the value has actually moved since.
local function bind(built, node, field, setter, w, current)
    if type(node[field]) ~= "function" then return end
    built.binds[#built.binds + 1] =
        { get = node[field], set = setter, widget = w, last = current, field = field }
end

MAKE.label = function(node, ctx, built)
    local text = M.valueOf(node.text, ctx.self)
    local s = (text == nil) and "" or tostring(text)
    local w
    -- `native = true` adopts the game's OWN label — BP_PalTextBlock_C, a UPalTextBlockBase, which
    -- is where Palworld's font scaling, UI-settings binding and localisation live
    -- (dumps/cxx/Pal.hpp:30039-30050). It is a fallback rather than a hard requirement because
    -- the class is resident in a world and not necessarily at the title screen, and a panel that
    -- refuses to draw is worse than one whose font is ours.
    if node.native then
        local t, why = widget.palText(ctx.outer, s, node.size)
        if t then w = t else note(built, "label native: " .. tostring(why)
            .. " — a plain UMG TextBlock was used instead") end
    end
    w = w or widget.text(ctx.outer, s, node.size, node.color)
    bind(built, node, "text", setText, w, text)
    return w
end

-- A SPRITE: one UImage with a texture in it, resolved either from an asset PATH or from a
-- vanilla content ID whose icon is looked up.
--
-- TWO WAYS IN, because there are two different things an author knows. `path` is for an asset
-- you have — a texture you shipped, or one of the four /Game/... textures core/mesh/assets has
-- verified. `icon` is for the far commoner case: the author knows a content id ("Wood",
-- "Sheepball", "Workbench") and wants whatever picture the game already draws for it.
-- core/icons answers that off the game's own DataTables and its coverage is measured — 674/674
-- pal rows, 1183/1207 item rows, 567/571 building rows, 311/311 partner-skill rows
-- (core/icons.lua:416-422) — so a missing icon is nearly always a MISSPELLED id, and the error
-- below says so rather than leaving a blank square.
--
-- BOTH REQUIRES ARE LAZY AND WRAPPED. This module is the only one that meets UMG, and it is
-- reached through a pcall'd require from api/ui; pulling core/icons and core/mesh/assets in at
-- the top would make a headless load of api/ui depend on two more engine-facing modules for a
-- node kind most trees do not use.
---@return userdata? texture, string? why
local function textureFor(node)
    local path = node.path
    if not path and node.icon then
        local ok, icons = pcall(require, "palforge.core.icons")
        if not ok then return nil, "core/icons is unavailable: " .. tostring(icons) end
        local from = node.from or "item"
        local spec = icons.TABLES[from]
        if not spec then
            return nil, string.format("%q is not an icon catalog (item / pal / skill / building)", from)
        end
        local ref = icons.resolve(spec, node.icon)
        if ref == nil then
            return nil, string.format("no %s icon for id %q — the row keys are the vanilla ids "
                .. "spelled exactly as the DataTable spells them, and the match is "
                .. "case-sensitive", from, tostring(node.icon))
        end
        -- resolve() answers with a string path on this build (the soft-object column read as
        -- text), but it is documented as "a string path OR an engine object", so take either.
        if type(ref) == "userdata" then return ref end
        path = tostring(ref)
    end
    if type(path) ~= "string" or #path == 0 then
        return nil, "a sprite needs `path` (a /Game/... texture) or `icon` (a vanilla content id)"
    end

    local ok, assets = pcall(require, "palforge.core.mesh.assets")
    if not ok then return nil, "core/mesh/assets is unavailable: " .. tostring(assets) end
    local tex, why = assets.load(path, { class = "Texture2D" })
    if not tex then return nil, tostring(why) end
    return tex
end

MAKE.sprite = function(node, ctx, built)
    local tex, why = textureFor(node)
    if not tex then error(tostring(why), 0) end
    return widget.image(ctx.outer, tex, {
        matchSize = node.matchSize, opacity = node.opacity, rgba = node.color,
    })
end

-- A FRAME: the game's own window chrome (WBP_PalCommonWindow_C) with our one child inside its
-- NamedSlot. Two widgets, so the maker hands back BOTH — the frame is what goes into the parent,
-- and the NamedSlot is what the child goes into (buildNode uses the second return as the parent
-- for the children, and CONTENT marks it as a SetContent host).
--
-- Falls back to a plain Border rather than failing the mount: the window class is resident in a
-- world and not necessarily at the title screen, and a declared panel that vanishes because its
-- chrome is missing is worse than one that draws in PalForge's own colours. The substitution is
-- NOTED, never silent.
-- ⚠️ A FRAME IS ALSO THE ELEMENT'S ONE ROUTE INTO PALWORLD'S OWN INPUT AND ACTIVATION SYSTEM,
-- which is why the element's `input` / `backHandler` / `layer` declarations are handed down to
-- it here rather than applied afterwards. WBP_PalCommonWindow_C is a UPalUserWidget and
-- therefore a UPalActivatableWidget, which is the class that CARRIES the input mode as data
-- (Pal.hpp:13369-13370); a VBox or a Border is not, and no amount of asking will make one. The
-- ⚠️⚠️ block in _widget.lua's "THE GAME'S OWN UI ROUTE" section is the one to read for why the
-- mode may only be written there and never on the player controller.
MAKE.frame = function(node, ctx, built)
    local okPc, pc = pcall(controller, ctx)
    if okPc then
        local frame, host, why, container = widget.gameFrame(pc, {
            input = ctx.input, backHandler = ctx.backHandler, layer = ctx.layer,
        })
        if frame then
            -- The game put it on a layer itself, so nothing else may parent it and only
            -- RemoveWidget may take it off. Recorded on the built tree, which is what mount and
            -- destroy read instead of guessing from the widget.
            if container then built.layer = { container = container, widget = frame } end
            return frame, host
        end
        note(built, "frame: " .. tostring(why) .. " — a PalForge Border was used instead")
    else
        note(built, "frame: " .. tostring(pc) .. " — a PalForge Border was used instead")
    end
    -- ⚠️ NO COLOUR HERE, AND THAT IS THE POINT OF THE REFUSAL IN api/ui. A Frame wears the game's
    -- own window art and takes no tint (UUserWidget::SetColorAndOpacity, UMG.hpp:1709, is a
    -- struct call AND would tint our content along with the chrome). The fallback is PalForge's
    -- default panel colour, and the note above says the substitution happened — so "my frame is
    -- the wrong colour" can never again mean "the field silently did nothing".
    return widget.border(ctx.outer, nil)
end

-- A button is one of the GAME'S OWN, wired through the shared click router — the identical
-- route native/ui/button.lua takes, so a declared button and an imperative one are the same
-- widget with the same click path and there is only one thing to reason about. WHICH of the
-- game's buttons is decided by _widget.buttonClass, which asks the world what it has loaded
-- rather than naming a path; it now leads with WBP_CommonButton_C, the button Palworld's own
-- Mod Menu is built from (dumps/cxx/WBP_Option_ModMenu.hpp:15-17).
--
-- The handler is called as onClick(self, ctx) — `self` is the ELEMENT INSTANCE, so a button
-- can read and write the same state its siblings' bindings display, and ctx names the node
-- and the widget that was clicked. That is the house shape for events (Pal / Building /
-- Item all pass (self, ctx)), and it is what makes one declared tree reusable across
-- instances: the node is shared, `self` is not.
-- ⚠️ `labelAlign = "left"` IS A SECOND CONSTRUCTION, NOT A SECOND SETTING, and the split is here
-- rather than inside _widget because the two shapes hand back different widgets and bind their
-- text to different things. `center` is the game button alone and its `text` is written through
-- _widget.setButtonText (the button's own label, its own font). `left` is _widget.clickableRow:
-- an Overlay holding the same game button stretched to fill, with a TextBlock of ours over the
-- top at HitTestInvisible so clicks pass through — and its `text` is written through SetText on
-- THAT TextBlock, because setButtonText would write the button's own hidden label and nothing
-- would change on screen. The header on _widget.clickableRow records why this is the only route
-- to a left-aligned button label on this build (and why `ui-menubutton-inner-slot` is still
-- correctly closed). What goes into the parent slot differs too — an Overlay, not a button — so
-- the maker's return is the thing that has to change, which is exactly why it is decided here.
MAKE.button = function(node, ctx, built)
    local pc = controller(ctx)
    local text = M.valueOf(node.text, ctx.self)
    local clickCtx = { node = node, name = node.name }
    local onClick = node.onClick and function()
        node.onClick(ctx.self, clickCtx)
    end or nil
    local label = (text == nil) and "" or tostring(text)

    if node.labelAlign == "left" then
        local row, inv, key, lbl = widget.clickableRow(ctx.outer, pc, label, onClick)
        if not row then error("clickableRow: " .. tostring(inv), 0) end
        clickCtx.widget = row
        if key then built.clicks[#built.clicks + 1] = key end
        -- The binding goes to OUR TextBlock. `lbl` is nil only if the row was built without one,
        -- which cannot happen today; guarded anyway, because a binding registered against nil
        -- would raise on the first heartbeat rather than at build time.
        if type(node.text) == "function" and alive(lbl) then
            bind(built, node, "text", setText, lbl, text)
        end
        return row
    end

    local btn, inv, key = widget.menuButton(ctx.outer, pc, label, onClick)
    if not btn then error("menuButton: " .. tostring(inv), 0) end
    clickCtx.widget = btn
    if key then built.clicks[#built.clicks + 1] = key end

    -- A dynamic label goes back through the SAME writer the build used, which is the whole point
    -- of _widget.setButtonText: it prefers the button's own SetText (WBP_CommonButton.hpp:30)
    -- and reaches for the label child only when the button declares no setter. The old code
    -- bound straight to a child named Test_Content, which is the TITLE button's name and is not
    -- in the button class a world actually has — so a dynamic label silently never updated.
    if type(node.text) == "function" then
        bind(built, node, "text", setButtonText, btn, text)
    end
    return btn
end

-- Any Blueprint widget the game already ships, cloned by class path. This is the escape
-- hatch for "use the game's own component": the node names the class, which child carries
-- the label, and which child is the clickable one, because those three names differ per
-- widget and nothing can guess them (WBP_Title_MenuButton's are Test_Content and
-- WBP_PalInvisibleButton — dumps/cxx/WBP_Title_MenuButton.hpp:14-15).
MAKE.gamewidget = function(node, ctx, built)
    local pc = controller(ctx)
    local clickCtx = { node = node, name = node.name }
    local text = M.valueOf(node.text, ctx.self)
    local w, key = widget.cloneGameWidget(ctx.outer, pc, node.class, {
        label      = (text ~= nil) and tostring(text) or nil,
        labelChild = node.textChild,
        clickChild = node.clickChild,
        onClick    = node.onClick and function() node.onClick(ctx.self, clickCtx) end or nil,
    })
    if not w then error("clone " .. tostring(node.class) .. ": " .. tostring(key), 0) end
    clickCtx.widget = w
    if key then built.clicks[#built.clicks + 1] = key end
    if type(node.text) == "function" and node.textChild then
        local lbl = widget.findByName(w, node.textChild)
        if alive(lbl) then bind(built, node, "text", setText, lbl, text) end
    end
    return w
end

---The node kinds this file can build. api/ui declares the same set as specs; this is the
---list a caller can check against without loading the engine half.
---@return table<string, boolean>
function M.kinds()
    local out = {}
    for k in pairs(MAKE) do out[k] = true end
    return out
end

--=============================================================================
-- build
--=============================================================================

-- Build one node and everything under it. Returns the widget, or nil + a reason that names
-- the node kind and the path it failed on.
local function buildNode(node, ctx, built)
    local maker = MAKE[node.kind]
    if not maker then return nil, "no builder for node kind " .. tostring(node.kind) end

    -- A maker may hand back TWO widgets: the one that goes into the parent, and — when they are
    -- not the same object — the one the CHILDREN go into. `frame` is the case that needs it: the
    -- game's window chrome is one widget and the slot our content occupies is another
    -- (WBP_PalCommonWindow.hpp:6), and conflating them is how a panel ends up drawn behind its
    -- own frame instead of inside it.
    local ok, w, contentHost = pcall(maker, node, ctx, built)
    if not ok then return nil, string.format("%s: %s", node.kind, tostring(w)) end
    if not alive(w) then return nil, node.kind .. ": built nothing" end
    if not alive(contentHost) then contentHost = w end
    if node.name then built.byName[node.name] = w end

    if node.visible ~= nil then
        local v = M.valueOf(node.visible, ctx.self)
        setVisible(w, v)
        bind(built, node, "visible", setVisible, w, v)
    end

    for i, child in ipairs(node.children or {}) do
        local cw, why = buildNode(child, ctx, built)
        if not cw then
            return nil, string.format("%s -> child %d: %s", node.kind, i, tostring(why))
        end
        local slot = attach(node, contentHost, cw)
        if not slot then
            return nil, string.format("%s did not accept child %d (a %s)", node.kind, i, child.kind)
        end
        applySlot(slot, child)
    end
    return w
end

---Build `node` and put it into `ctx.host`. Returns the built tree, or nil + a reason.
---
---ctx = { host  = the panel this tree hangs in (must answer AddChild),
---        outer = the UObject the primitives are constructed under (default: the host),
---        self  = the element instance handed to every binding and click handler,
---        input = the element's declared `input` mode, handed down to a Frame node so the
---                mode is written where Palworld keeps it (on the activatable, before it
---                activates) rather than onto the player controller,
---        backHandler = the element's declared `backHandler`, same route, same reason,
---        layer = push the Frame onto one of the game's own CommonUI layers instead of
---                parenting it by hand }
---
---ABOUT `outer`. Every native primitive needs a construct outer, and a UUserWidget of our
---own has a WidgetTree to be that (_widget.screen builds one — the crux recorded at
---_widget.lua:265-275). A panel belonging to the GAME has no such thing to hand us, so the
---outer is the host panel itself, which is what title_menu.lua:112 already does for every
---entry it injects into the title screen's own VerticalBox. The outer decides ownership and
---naming, not parenting: the widget is kept alive by the slot that holds it.
---@return table? built, string? reason
function M.mount(node, ctx)
    if type(node) ~= "table" or type(node.kind) ~= "string" then
        return nil, "no root node was declared"
    end
    ctx = ctx or {}
    if not ctx.host then return nil, "no host panel to mount into" end
    ctx.outer = ctx.outer or ctx.host

    local built = { byName = {}, binds = {}, clicks = {}, notes = {} }
    local w, why = buildNode(node, ctx, built)
    if not w then
        M.destroy(built)     -- release whatever the partial build already registered
        return nil, why
    end

    -- A root the GAME already placed is not ours to place again. BP_AddWidget parented it onto a
    -- CommonUI layer's activatable stack (widget.pushToLayer), which is the whole point of that
    -- route: the container owns the widget, the transition and the removal.
    if built.layer and built.layer.widget == w then
        built.root, built.slot = w, nil
        return built
    end

    local slot = widget.addChild(ctx.host, w)
    if not slot then
        built.root = w
        M.destroy(built)
        return nil, "the host did not accept the tree's root — is it a UPanelWidget?"
    end
    built.root, built.slot = w, slot
    applySlot(slot, node)
    return built
end

---Re-evaluate every binding and write the ones that changed. Returns true plus how many
---writes were made (0 is the normal case for an idle panel).
---@return boolean ok, integer written
function M.update(built, self)
    if type(built) ~= "table" then return false, 0 end
    local n = 0
    for _, b in ipairs(built.binds or {}) do
        if alive(b.widget) then
            local v = M.valueOf(b.get, self)
            if v ~= b.last then
                if b.set(b.widget, v) then b.last = v; n = n + 1 end
            end
        end
    end
    return true, n
end

---Take a built tree back off screen: release exactly the click-router keys it registered
---(never another element's — that is why the keys are recorded per tree) and remove its
---root, which takes every descendant with it. True when a live root was really removed.
function M.destroy(built)
    if type(built) ~= "table" then return false end
    if built.clicks and #built.clicks > 0 then
        pcall(function() widget.releaseClicks(built.clicks) end)
    end
    local w = built.root
    local layer = built.layer
    built.root, built.slot, built.layer = nil, nil, nil
    built.byName, built.binds, built.clicks, built.notes = {}, {}, {}, {}
    if not alive(w) then return false end

    -- ⚠️ A ROOT THE GAME PUT ON A LAYER COMES OFF THE GAME'S WAY, and that is not tidiness: it is
    -- the half of the input problem this tree could never do by hand. RemoveWidget
    -- (CommonUI.hpp:190) pops the activatable off the stack, which deactivates it, which is what
    -- makes the action router RESTORE the input config that was underneath. RemoveFromParent
    -- would leave the router holding a node for a widget that is no longer anywhere.
    if layer and layer.container then
        local removed = false
        pcall(function() removed = widget.removeFromLayer(layer.container, w) end)
        if removed then return true end
        -- Fall through rather than strand it: a widget still on screen is worse than an
        -- unregistered one, and widget.removeFromLayer has already logged the refusal.
    end

    -- A UI.Frame root built the direct way is a CommonUI activatable that mount() activated, and
    -- an activated widget is registered with the action router. Deactivate it before it leaves
    -- the tree; the call is a no-op for every other kind of root (widget.deactivate gates on the
    -- class).
    pcall(function() widget.deactivate(w) end)
    return pcall(function() w:RemoveFromParent() end) == true
end

--=============================================================================
-- hosts — where a declared tree goes
--=============================================================================

---Resolve a UI.Spec `host` declaration to something mountable. Returns
---{ panel, outer, screen?, what } or nil + a reason, and the reason is the thing worth
---reading: "no PalPrimaryGameLayoutBase live (title screen, or still loading)" is not a
---failure, it is an element waiting for its host, which is what :autoMount is for.
---
---  "screen"                      a viewport layer of our own (_widget.screen)
---  "game"                        the game's OWN in-game UI root canvas (_widget.gameUIRoot)
---  { widget = ..., panel = ... } any live widget class, and the panel inside it
---
---`"screen"` is built with dim = false ON PURPOSE: _widget.screen's default frame is a
---fullscreen dim plus an inset panel, and a frame the author did not declare is not
---composition. A declared tree that wants one writes it — UI.Border{ UI.SizeBox{ ... } } —
---and gets exactly the frame it can see in its own source.
---`opts.z` is the element's declared stacking order. Where it lands depends on the host, because
---the two hosts stack by different mechanisms and neither is a choice this file gets to make:
---a "screen" host is a widget on the VIEWPORT and stacks by AddToViewport's z (UMG.hpp:1781); a
---panel host stacks by its SLOT, which is M.setZ's job and only works on a canvas.
---
---SCREEN_BASE_Z is added rather than substituted so that the default (z = 0) is the 1000 every
---shipped PalForge screen has used, and a declared z reads as "relative to where PalForge sits",
---not as an absolute the author has to know the game's layers to choose.
---@return table? host, string? reason
function M.host(spec, opts)
    local z = tonumber(opts and opts.z) or 0
    if spec == "screen" then
        local screen, why = widget.screen(nil, { dim = false, zOrder = M.SCREEN_BASE_Z + z })
        if not screen then return nil, tostring(why) end
        return { panel = screen.root, outer = screen.tree, screen = screen, zApplied = "AddToViewport",
                 what = "a viewport layer of our own" }
    end
    if spec == "game" then
        local panel, why = widget.gameUIRoot()
        if not panel then return nil, tostring(why) end
        return { panel = panel, outer = panel,
                 what = widget.PATHS.gameUILayout .. "." .. widget.PATHS.gameUIRoot }
    end
    -- "layer" is not a panel at all, which is why it resolves to a host with `layer = true` and
    -- no panel: the tree's ROOT is placed by the game (BP_AddWidget on a CommonUI layer), not by
    -- us, so there is nothing to add a child to and the construct outer is the layout itself.
    -- Everything about it is in _widget's "THE GAME'S OWN UI ROUTE" block. It requires a Frame
    -- root — only a Palworld activatable can go on a layer — and says so rather than half-working.
    if spec == "layer" or (type(spec) == "table" and spec.layer) then
        local layout, why = widget.gameLayout()
        if not layout then return nil, tostring(why) end
        local layers, how = widget.uiLayers()
        if #layers == 0 then
            return nil, "the in-game layout registers no readable CommonUI layer (" .. tostring(how)
                .. "), so there is nothing to push onto"
        end
        return { panel = layout, outer = layout,
                 layer = (type(spec) == "table" and spec.layer) or true, zApplied = "the layer stack",
                 what = string.format("a CommonUI layer of %s (%s)", widget.PATHS.gameUILayout, how) }
    end
    if type(spec) == "table" then
        local panel, why = widget.hostPanel(spec.widget, spec.panel)
        if not panel then return nil, tostring(why) end
        return { panel = panel, outer = panel,
                 what = tostring(spec.widget) .. (spec.panel and ("." .. spec.panel) or "") }
    end
    return nil, "unknown host: " .. tostring(spec)
end

--=============================================================================
-- input — the other half of "the button does nothing"
--
-- api/ui owns WHEN this happens (after a successful render, undone on unmount) and declares WHAT
-- the author asked for (UI.Spec `input`); _widget owns the engine calls and the restore policy.
-- These two lines are the seam between them, and they exist so api/ui keeps its one defining
-- property: it makes no engine call, which is what lets the whole lifecycle be proved headlessly.
--=============================================================================

---Take what `mode` asks for. nil + a reason when nothing was touched — and "none", the default,
---is one of those reasons rather than a failure.
---
---⚠️ THE INPUT MODE IS NOT SET HERE AND IS NOT SET BY ANY CALL ON THE PLAYER CONTROLLER. Palworld
---keeps it on the ACTIVATABLE WIDGET (`UPalActivatableWidget.InputConfig`, Pal.hpp:13369) and its
---CommonUI action router applies it on activation and restores it on deactivation. A UI.Frame
---node is what carries the declaration there, which is why `input` and `Frame{}` are one story
---and not two. `owner` is the dead-man's answer to "is anyone still holding this".
---@return table? grab, string? reason
function M.grabInput(mode, focus, owner) return widget.grabInput(mode, focus, owner) end

---Hand a grab back: the cursor flag, restored exactly as it was found. The MODE goes back when
---the activatable deactivates — that is the router's job and it is the half no call here could do.
function M.releaseInput(grab) return widget.releaseInput(grab) end

---Release every grab nobody can answer for any more. The dead-man rides core/poll's one heartbeat
---inside _widget; this is the manual pull, for a probe or a console command.
---@return integer outstanding
function M.sweepGrabs() return widget.sweepGrabs() end

---What is outstanding, as printable lines.
---@return string[]
function M.grabReport() return widget.grabReport() end

---The game's own CommonUI layers, as printable lines: which tags this layout registers, what
---container class each is, and how many widgets are on it. This is the question `host = "layer"`
---turns on, and no header can answer it — the tags are registered at runtime
---(UPrimaryGameLayout::RegisterLayer, CommonGame.hpp:160).
---@return string[]
function M.layerReport() return widget.layerReport() end

---The base viewport z-order a "screen" host sits at, before the element's declared `z` is added.
---1000 is what every shipped PalForge screen used (_widget.show's own default), so a declared
---z of 0 changes nothing about where a screen has always been drawn.
M.SCREEN_BASE_Z = 1000

--=============================================================================
-- Z — the declared stacking order, echoed into the engine where the engine has one
--
-- THE DECLARED z IS THE SOURCE OF TRUTH FOR ROUTING, and this call is only the DRAWING half.
-- api/ui keeps the mounted elements in declared-z order and routes keys and mouse presses down
-- that order; nothing here is consulted for that. What this does is make what is DRAWN on top
-- agree with what is ROUTED to first, so a panel that receives the key is also the panel the
-- player can see. When it cannot (below), routing is still exactly right and only the drawing
-- order is the host's business — which is worth saying rather than leaving as a surprise.
--
-- IT ONLY WORKS ON A CANVAS, and that is a fact about UMG rather than a limitation here:
--   dumps/cxx/UMG.hpp:354   int32 ZOrder;                 } UCanvasPanelSlot, and ONLY that slot
--                     :356   void SetZOrder(int32 InZOrder); } class
-- A UVerticalBoxSlot / UOverlaySlot / UBorderSlot has no z at all — a box stacks by ORDER, not by
-- number. So a tree hosted in the game's CanvasPanel_Root (host = "game", which is what
-- _widget.gameUIRoot hands back — UMG.hpp:347) takes the z, and a tree injected into the title
-- screen's VerticalBox cannot, and says so once rather than logging a refusal per mount.
--
-- SetZOrder takes a plain int32, so it is one of the calls core/signature can verify outright.
-- The property is written as well as the setter, the way every slot write in this file is: UE4SS
-- setters sometimes no-op where the property write lands, and vice versa.
--=============================================================================

---Give a built tree's host slot the element's declared z. Returns false plus the reason when the
---slot has no such concept, which is normal and not a failure.
---@return boolean applied, string? why
function M.setZ(slot, z)
    z = tonumber(z) or 0
    if type(slot) ~= "userdata" then
        return false, "the host handed back no slot to order (the tree is placed, and drawn in "
            .. "the order its host stacks children)"
    end
    local cls
    pcall(function() cls = slot:GetClass():GetFName():ToString() end)
    if cls ~= "CanvasPanelSlot" then
        return false, string.format("a %s has no ZOrder — only a UCanvasPanelSlot does "
            .. "(UMG.hpp:354). This host stacks by child order, so the declared z still decides "
            .. "event routing and does not decide drawing here", tostring(cls or "?"))
    end
    local ok = sig.call(slot, "SetZOrder", { "IntProperty" }, math.floor(z))
    pcall(function() slot.ZOrder = math.floor(z) end)
    if not ok then
        return false, "SetZOrder was refused or raised (core/signature logged which); the "
            .. "ZOrder property was still written"
    end
    return true
end

--=============================================================================
-- keys — the seam api/ui reaches UE4SS's keyboard through
--
-- Re-exported here for one reason: api/ui talks to native/ui/tree and to nothing else. That is
-- what lets api/ui hold the routing RULE (pure, provable with no game) while every question about
-- whether a press can be heard at all lives on this side of the line. native/ui/keys.lua is where
-- the answers are, and its header is the one to read about keys the game has already claimed.
--=============================================================================

---Arm the keys and mouse buttons an element declared, pointing them at api/ui's router.
---`spec.keys` are refused if Palworld's live key config already uses them; `spec.overrideKeys`
---are taken anyway, deliberately. Returns one record per name; never raises, and never blocks a
---mount.
---@return table[] records
function M.armInput(spec) return keys.arm(spec) end

---What the UI key binds are doing, as printable lines — including, for every armed key that has
---never been pressed, which of the possible reasons applies.
---@return string[]
function M.keyReport() return keys.report() end

---The whole live keymap: what Palworld has an action on, per key. Re-exported for the same reason
---keyReport is — a probe or an autorun action should not have to reach past this seam to ask.
---
---⚠️ IT IS ALSO WHAT UI.report() READS LAST, which it did not until 2026-08-02. This function was
---written alongside keyReport and grabReport and left out of api/ui.lua's list of report sources,
---so the one report an operator is told to paste stated a CONCLUSION — "F7 never arrived AND THE
---GAME HAS AN ACTION ON IT" — with no sign of the reading that conclusion was drawn from, and the
---evidence had to be fetched by a second command nobody knew to run. It is the longest of the
---four blocks (a line per source, a line per container, then a line per key the game has an
---action on — 107 rows on the measured build), which is why it goes last and not first.
---@return string[]
function M.keymapReport()
    local out = {}
    for _, line in ipairs(keys.keymap.lines()) do out[#out + 1] = line end
    return out
end

---What the shared click router is doing, as printable lines — armed routes, their ids, and how
---many clicks each has SEEN across the whole game. Re-exported so a probe or an autorun action
---can print it without reaching into an underscore module.
---@return string[]
function M.clickReport() return widget.clickReport() end

---Give back a host that was CREATED for an element — today only the "screen" one, which is
---a viewport layer nobody else owns. A host that was FOUND (the game's own panels) is not
---ours to take down: the element removed its own widgets from it in destroy(), and that is
---the whole of its footprint.
function M.releaseHost(host)
    if type(host) ~= "table" or not host.screen then return false end
    local screen = host.screen
    host.screen = nil
    return widget.hide(screen)
end

return M
