# 04 — Native UI

Fills **`dump_targets.md` §9.3** (native UI widget paths) and **§9.4** (`_installUpdateDriver`),
using the plan in **§5**.

The UI kit (`native/ui/_widget.lua`) builds live UMG from Palworld's **own** widgets — no
cooked WidgetBlueprints. Element **lifecycle** (mount-once / refresh / unmount) is owned by
`base/ui.lua : UIRenderer`; concrete elements only fill `render()`. The title-menu paths are
already verified (`native/ui/_widget.lua : M.PATHS`, **DONE** 2026-07-17); construction
primitives (`StaticConstructObject` on UMG boxes, `WidgetBlueprintLibrary:Create`) are proven.
What remains is **mapping unknown live trees** and choosing an update signal.

**Where to look for all of §9.3:** `03_widgets.txt` — it walks named roots (`PalUITitleBase`,
`PalHUD`, `PalHUDWidget`) logging `widgetName <class>` per node, then lists every live
`UserWidget` as `name <class> <fullName>`. **Open the Build menu / Inventory / Paldeck BEFORE
running `ps_dump`** — the UI dump only sees what is currently live.

---

## 4.1 Build-menu widget path — `native/ui/_widget.lua`

1. **Target** — a new `M.PATHS` entry (and injection element) for the build/HUD menu: the
   container that holds buildable rows + the row widget path. `native/ui/_widget.lua : M.PATHS`
   currently has title entries only.
2. **Dump source** — `03_widgets.txt`. Grep the live-`UserWidget` list and named-root trees
   for `Build` / `WBP_Build`.
3. **Extract** — the build-menu root class name, the list/scroll container it injects rows
   into (which `AddChildTo*` it accepts), and a representative row widget path.
4. **Implement** — add the confirmed paths to `M.PATHS` (mirroring the existing
   `menuButton`/`palTextBlock` entries), then build a build-menu injection element under
   `native/ui/` that extends `base/ui.lua : UIRenderer` and fills `render(root)` using
   `widget.create` / `widget.findByName` / the `addV`/`addH`/`addScroll` helpers.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- build-menu root class (03_widgets.txt): ____________
-- row container + AddChildTo* it accepts: ____________
-- row widget path: ____________
-- final code (M.PATHS additions):
--   buildMenuRoot = "____________",  buildMenuList = "____________",
```

---

## 4.2 Inventory widget path — `native/ui/_widget.lua`

1. **Target** — `M.PATHS` entries for the inventory UI: slot widget + list container (an
   inventory element).
2. **Dump source** — `03_widgets.txt`. Grep for `WBP_Inventory` / `Container` / `Inventory`.
3. **Extract** — the inventory widget root, the slot widget path, and the list container +
   its `AddChildTo*`.
4. **Implement** — add the paths to `M.PATHS`; build an inventory element under `native/ui/`
   the same way as §4.1.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- inventory root / slot widget / list container (03_widgets.txt):
--   ____________ / ____________ / ____________
-- final code (M.PATHS additions):
--
```

---

## 4.3 HUD widget path — `native/ui/_widget.lua`

1. **Target** — `M.PATHS` entry for the main HUD root: an anchor for a status-bar / overlays
   (e.g. the effect status bar for [07](07_registers.md) effects).
2. **Dump source** — `03_widgets.txt`. The `PalHUD` / `PalHUDWidget` named roots are walked at
   the top of the file; also grep `WBP_MainHUD` / `HUD`.
3. **Extract** — the HUD root class + the panel to anchor overlays into.
4. **Implement** — add the HUD anchor path to `M.PATHS`; a HUD/status-bar element extends
   `UIRenderer` and mounts under it.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- HUD root + overlay anchor (03_widgets.txt): ____________ / ____________
-- final code (M.PATHS additions):
--
```

---

## 4.4 `base/ui.lua` — `_installUpdateDriver`

1. **Target** — `base/ui.lua : UIRenderer:_installUpdateDriver()` — an inert TODO. It must
   bind `refresh()` (which runs `update()`) to whatever signals a UI update. Deliberately
   undecided so no async policy is baked in before testing.
2. **Dump source** — `02_reflection.txt` (a native/PalSchema UMG update event to hook, e.g. an
   `OnRefresh`/`NativeTick`/`OnPaint`-style UFunction on the HUD/widget class) **or** decide on
   the `LoopAsync` fallback if no catchable event is found.
3. **Extract** — the update-event `/Script/…:<Function>` path to hook (preferred), or confirm
   the async fallback interval.
4. **Implement** — in `base/ui.lua`, replace the TODO: either
   `pcall(RegisterHook, "<path>", function() self:refresh() end)` (event-driven, preferred), or
   a `LoopAsync(<ms>, …)` that calls `self:refresh()` (fallback only if events prove
   uncatchable). Mirror the pcall-guarding used by `core/event.lua : tryHook`.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- UI update event found (path) or "none — use LoopAsync(<ms>)":
--   ____________
-- final code (base/ui.lua : _installUpdateDriver):
--
```

---

## 4.5 `native/ui/title_menu.lua` — re-confirm `VerticalBox_0`

1. **Target** — `native/ui/title_menu.lua` matches the button column by literal name
   `"VerticalBox_0"` (in `TitleMenu:render` via `widget.findByName(base, "VerticalBox_0")`) and
   keeps `"WBP_Title_MenuButton_ExitGame"` last. Confirm these hold on the current game version.
2. **Dump source** — `03_widgets.txt` → the `PalUITitleBase` named-root tree (walked from the
   top). Confirm the `VerticalBox_0` node and the entry/slot shape (SizeBox → WBP_Title_MenuButton).
3. **Extract** — the button-column widget name (still `VerticalBox_0`?) and the exit-button name.
4. **Implement** — if the version renamed them, update the two literals in
   `native/ui/title_menu.lua` (`"VerticalBox_0"`, `"WBP_Title_MenuButton_ExitGame"`). If
   unchanged, mark verified — no code change.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- button-column node name: ____________   exit-button name: ____________
-- (unchanged -> verified; else patch the two literals in title_menu.lua)
```

---

## 4.6 `native/ui/button.lua` — host-panel `AddChildTo*`

1. **Target** — `native/ui/button.lua : Button:render(root)` attaches best-effort with
   `root:AddChildToVerticalBox(btn)` else `root:AddChild(btn)`. Confirm the real host panels a
   Button mounts into accept one of these (it is context-dependent per host).
2. **Dump source** — `03_widgets.txt`: the class of the panel a `Button` mounts into
   determines its `AddChildTo*` (VerticalBox → `AddChildToVerticalBox`, HorizontalBox →
   `AddChildToHorizontalBox`, ScrollBox → `AddChild`, Overlay → `AddChildToOverlay`).
3. **Extract** — for each host you inject into, the panel class + the correct add method.
4. **Implement** — extend the branch in `Button:render` (or pass the host kind in `spec`) so
   the correct `AddChildTo*` is chosen for each mapped host. Reuse the `widget.addV`/`addH`/
   `addScroll` helpers where they fit.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- host panel class -> add method (per host, from 03_widgets.txt):
--   ____________ -> ____________
-- final code (native/ui/button.lua : render branch):
--
```

---

## Already DONE (no dump)

- `native/ui/_widget.lua : M.PATHS` — title-menu paths verified 2026-07-17 (§9.3 `[x]`).
- Construction primitives (UMG boxes via `StaticConstructObject`, WBP_/BP_ via
  `WidgetBlueprintLibrary:Create`) — proven, no dump needed.

---

## Coverage — this doc

| Checklist item | Section |
|---|---|
| §9.3 `_widget.lua` — build-menu widget paths | §4.1 |
| §9.3 `_widget.lua` — inventory widget paths | §4.2 |
| §9.3 `_widget.lua` — HUD widget paths | §4.3 |
| §9.3 `title_menu.lua` — re-confirm `VerticalBox_0`/entry shape | §4.5 |
| §9.3 `button.lua` — host-panel `AddChildTo*` | §4.6 |
| §9.4 `base/ui.lua : UIRenderer:_installUpdateDriver` | §4.4 |
| §9.3 `_widget.lua : M.PATHS` (title) | **DONE** |
