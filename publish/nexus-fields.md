# Nexus Mods — the short fields

The description is `nexus-description.bbcode`. These are everything else on the form.

## Name

```
PalForge — add new pals, items and buildings (UE4SS/Lua framework)
```

**This changed on 2026-08-07 and the reason is worth keeping.** It used to read *content framework
for Palworld*, which is what the thing IS — but nobody searches for a category they have never
heard of. Five comparable frameworks were read before rewriting it (SMAPI, UE4SS, Fabric, Harmony,
BepInEx) and every one leads with the same shape: **`<what it does> for <the game>`**, then the
category in second position. So the outcome leads and *framework* follows, where it stops the
wrong download instead of preventing the right one.

## Summary (the one line under the title)

```
Add new pals, items and buildings to Palworld in a few lines of Lua — and react to what the
game does. Single-player only.
```

One sentence, not two: Fabric gets by on *"a modular, lightweight mod loader for Minecraft"* and
the density is the point. *Add* is the promise, *react to what the game does* is the second half
of it, and *single-player only* stops the first bug report.

⚠️ **Do not shorten it to "add new content" and stop there.** See the warning under Images.

## Category

**Modders Resources** — not Utilities, not Gameplay. It ships no content and changes nothing on
its own; a player who installs it sees exactly no difference.

## Tags

```
modders resources · lua · ue4ss · framework · api · library · scripting · single player
```

## Version

`0.3.0` — must match `package.json` and the git tag. `release.yml` refuses a tag that disagrees
with `package.json`, so if the workflow passed, these agree.

## Requirements (the "Requirements" tab)

| mod | why |
| --- | --- |
| UE4SS (RE-UE4SS) | the Lua loader PalForge runs on. **Not optional.** |
| PalSchema | **required to add NEW content**, optional to extend what the game already has. Lua cannot write a row into the game's data tables; PalSchema can, and PalForge's ids are spelled to match what it writes. |
| CheatManagerEnablerMod | **optional.** Only improves the item helpers; spawning does not need it. |

## Permissions

MIT, so set every permission to allowed: upload to other sites, convert, use assets, modify. The
licence already says so and a Nexus permission that contradicts the shipped LICENSE file is worse
than no statement.

## The images

| slot | file | size |
| --- | --- | --- |
| main image | `palforge-banner.png` | 1280×640 |
| thumbnail | `palforge-thumb.png` | 512×512 — the square mark (concept A, the anvil), because the thumbnail renders small and the banner's text will not survive it |
| gallery | `assets/gallery/*.png` | 1280×720, **three of them** |

Build them with the commands in `assets/README.md` and `assets/gallery/README.md`.

**Three, in this order, and the order is the argument:**

1. `G1-new-entity` — *what can I add*, and the honest pairing that makes it possible
2. `G2-what-you-can-add` — *how many kinds of thing*, at a glance
3. `G3-events` — *and it already reacts to the game*

**Not one of the five frameworks read before this used a single diagram** (SMAPI, UE4SS, Fabric,
Harmony, BepInEx). Nine on a mod page would read as effort spent on the page rather than on the
code. Three is the smallest number that answers the three questions a stranger actually has —
`assets/gallery/README.md` has the reasoning.

## ⚠️ The claim that must not drift

**PalForge alone cannot add a row to the game's data tables.** Lua cannot write one. A genuinely
new item, creature or build object needs **PalSchema** for the row; PalForge's namespaced ids are
built to be exactly what PalSchema writes (`mypack:Potion` → `mypack_Potion`).

So *"add new pals, items and buildings"* is true of the two together, and the page has to say so
where a reader will actually meet it — which is why card G1 draws the pairing instead of putting
it in a footnote, and why PalSchema is listed under Requirements as **required for new content,
optional for extending what the game already has**.

Nothing on the page may say PalForge adds content on its own. That is the one sentence that would
turn this into a page that lies.

## Two things NOT to put on the page

**No gameplay screenshots.** There is nothing to show — the mod is invisible by design, and a
screenshot of a campfire implies content that is not there.

**No performance claim without the number.** If the description's 2.2 ms figure is quoted
anywhere else, quote the base size with it (623 structures). A bare "it's fast" is the kind of
claim this project spent a day proving it could not make from arithmetic alone.
