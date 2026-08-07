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

Nexus splits this into **Nexus requirements** (linked to a mod page) and **off-site requirements**
(a name and a URL). Only two things belong there at all:

| where | what | why |
| --- | --- | --- |
| off-site | **UE4SS (RE-UE4SS)** — https://github.com/UE4SS-RE/RE-UE4SS | the Lua loader PalForge runs on. **Not optional.** Primarily distributed on GitHub, so it is an off-site entry unless a current Nexus mirror is found. |
| Nexus, if it has a page — otherwise off-site | **PalSchema** — https://github.com/Okaetsu/PalSchema | **required to add NEW content**, not needed to extend what the game already has. Lua cannot write a row into the game's data tables; PalSchema can, and PalForge's ids are spelled to match what it writes. |

⚠️ **CheatManagerEnablerMod is NOT a requirement and must not be listed as one.** It **ships with
UE4SS** — it sits in UE4SS's own `Mods/` folder alongside ConsoleEnablerMod and BPModLoaderMod, and
is listed in the `mods.txt` UE4SS installs. Anyone with UE4SS already has it. Listing it would send
readers looking for a download that does not exist.

It is still worth a sentence in the description, because what it *does* is real: PalForge builds a
cheat manager itself for spawning and does not need it, but the item helpers (`give` / `take` /
`unlockTech`) find a cheat manager rather than constructing one, so without it those log
`no PalCheatManager` and return false.

**Palworld itself is not a Requirements entry** either — Nexus already knows which game the page
is under. The version it was measured against belongs in the description, where it is.

## Permissions

MIT, so set every permission to allowed: upload to other sites, convert, use assets, modify. The
licence already says so and a Nexus permission that contradicts the shipped LICENSE file is worse
than no statement.

## The images

Run `npm run art` — it regenerates every SVG and renders every PNG at exactly the size Nexus
wants, into `publish/images/`. The sizes are not decoration: Nexus crops a header that is not
1300×372 and downscales a gallery image that is not 1920×1080, and these images are mostly TEXT,
so a downscale is a blurry code panel.

| Nexus field | file | size |
| --- | --- | --- |
| **Header** — the banner across the top | `header.png` | 1300×372 |
| **Images** — the gallery | `G1` `G2` `G3` `G4`.png | 1920×1080 each |
| thumbnail, wherever one is asked for | `thumbnail.png` | 512×512 |
| GitHub social preview (not Nexus) | `banner.png` | 1280×640 |

**Gallery order is the argument, so upload them in it:**

1. `G1-new-entity` — *what can I add*, and the honest pairing that makes it possible
2. `G2-what-you-can-add` — *how many kinds of thing*, at a glance
3. `G3-events` — *and it already reacts to the game*
4. `G4-saved-state` — *does it touch my save* (no)

Give each a caption. The caption is what a screen reader and a slow connection get, and these
images carry real information — a caption of "screenshot" wastes it.

⚠️ **The description does not embed any of them.** They live on the Images tab as a gallery in
their own right, so their presence and order cost nothing to change.

## Two things NOT to put on the page

**No gameplay screenshots.** There is nothing to show — the mod is invisible by design, and a
screenshot of a campfire implies content that is not there.

**No performance claim without the number.** If the description's 2.2 ms figure is quoted
anywhere else, quote the base size with it (623 structures). A bare "it's fast" is the kind of
claim this project spent a day proving it could not make from arithmetic alone.
