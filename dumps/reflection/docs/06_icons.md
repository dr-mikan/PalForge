# 06 — Icons (`iconOf`)

Fills the **icons** part of **`dump_targets.md` §9.4** (the four `iconOf` seams), using the
plan in **§4 (Icons)**.

Each domain base class has an `iconOf()` that returns `self.icon` but leaves the **resolve**
step as a `-- TODO:`. Each icon is a texture soft-object path carried by the domain's DataTable
row; the job is to turn `self.icon` (an author-supplied path/handle) into a live texture the
menus can show.

**Where to look:** `01_datatables.txt` — the icon column of the relevant row is a soft
`Texture2D` path. Cross-check by enumerating loaded textures with `FindAllOf("Texture2D")` and
matching by name. `02_reflection.txt` can confirm the icon **property name** on the row struct
(grep the row/param class for `Icon`).

**Shared recipe shape** (identical for all four; the base+field differ only):

```lua
function <Base>:iconOf()
    if not self.icon then return nil end
    -- resolve a soft/object path into a live UTexture2D (fail-soft):
    local ok, tex = pcall(function() return StaticFindObject(self.icon) end)  -- or LoadObject
    if ok and tex and tex:IsValid() then return tex end
    return self.icon  -- fall back to the raw path
end
```

> The exact resolve call (`StaticFindObject` for already-loaded vs a `LoadObject`/soft-object
> resolve for on-demand) is what the dump confirms — do not assume; observe whether the icon
> texture is already loaded when the menu is open.

---

## 6.1 `base/item.lua : Item:iconOf`

1. **Target** — `base/item.lua : Item:iconOf` (returns `self.icon`, TODO resolve). `self.icon`
   comes from the item's data (set via `Item.define{ ... }` or a subclass field).
2. **Dump source** — `01_datatables.txt` → the `ItemDataTable` row's icon column (soft
   `Texture2D` path); `FindAllOf("Texture2D")` cross-check.
3. **Extract** — the icon soft-object path shape for an item row + the property name (grep
   `Icon` in `02_reflection.txt` on the item row struct).
4. **Implement** — replace the TODO in `Item:iconOf` with the shared resolve shape above.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- item icon column property + example path (01_datatables.txt / 02_reflection.txt):
--   ____________ / ____________
-- resolve call that works (StaticFindObject vs LoadObject): ____________
-- final code (base/item.lua : Item:iconOf):
--
```

---

## 6.2 `base/pal.lua : Pal:iconOf`

1. **Target** — `base/pal.lua : Pal:iconOf` (returns `self.icon`, TODO resolve).
2. **Dump source** — `01_datatables.txt` → the `MonsterParameter`-family row's icon/paldeck
   field; `FindAllOf("Texture2D")` cross-check.
3. **Extract** — the paldeck/icon path shape + property name for a pal row.
4. **Implement** — replace the TODO in `Pal:iconOf` with the shared resolve shape.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- pal icon/paldeck property + example path: ____________ / ____________
-- final code (base/pal.lua : Pal:iconOf):
--
```

---

## 6.3 `base/skill.lua : Skill:iconOf`

1. **Target** — `base/skill.lua : Skill:iconOf` (returns `self.icon`, TODO resolve).
2. **Dump source** — `01_datatables.txt` → the skill/`WazaData` table row's icon field (the
   same table discovered for the skill id in [02](02_content_ids.md#24-skillfireballlua--id--element)).
3. **Extract** — the skill-icon path shape + property name.
4. **Implement** — replace the TODO in `Skill:iconOf` with the shared resolve shape.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- skill icon property + example path: ____________ / ____________
-- final code (base/skill.lua : Skill:iconOf):
--
```

---

## 6.4 `base/effect.lua : Effect:iconOf`

1. **Target** — `base/effect.lua : Effect:iconOf` (returns `self.icon`, TODO resolve).
2. **Dump source** — `01_datatables.txt` → the status/state table row's icon field (same table
   as the `nativeStatus` discovery in
   [02](02_content_ids.md#25-effectburnfreezepoisonlua--nativestatus)).
3. **Extract** — the status-icon path shape + property name.
4. **Implement** — replace the TODO in `Effect:iconOf` with the shared resolve shape.
5. **FILL**

```lua
-- FILL FROM LOG  (leave empty until ps_dump has run)
-- effect icon property + example path: ____________ / ____________
-- final code (base/effect.lua : Effect:iconOf):
--
```

---

## Coverage — this doc

| Checklist item | Section |
|---|---|
| §9.4 `base/item.lua : Item:iconOf` | §6.1 |
| §9.4 `base/pal.lua : Pal:iconOf` | §6.2 |
| §9.4 `base/skill.lua : Skill:iconOf` | §6.3 |
| §9.4 `base/effect.lua : Effect:iconOf` | §6.4 |
