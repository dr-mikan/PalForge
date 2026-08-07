# Nexus Mods — the short fields

The description is `nexus-description.bbcode`. These are everything else on the form.

## Name

```
PalForge — content framework for Palworld (UE4SS/Lua)
```

The parenthetical is doing work: it tells a player scanning the list that this is not a mod for
them, before they download it and find nothing changed.

## Summary (the one line under the title)

```
A modder's framework: declare a building, item, pal, skill, effect, sound or UI panel in a few
lines of Lua and PalForge wires it to the game's own events. Single-player only.
```

Both halves are load-bearing. *A modder's framework* stops the wrong download; *single-player
only* stops the first bug report.

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
| UE4SS (RE-UE4SS) | the Lua loader PalForge runs on. Not optional. |
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
| gallery | `assets/cards/*.png` | 1280×720, nine of them |

Build them with the commands in `assets/README.md` and `assets/cards/README.md`.

**Gallery order matters more than the images do.** `01-buildings` first: it is the shortest
complete example and the one that answers *what would I even use this for*. Then `08-events`,
which explains why the rest works. Then the domain cards. Then `07-state` and `09-packs` last —
those answer questions a reader only has once they are already convinced.

## Two things NOT to put on the page

**No gameplay screenshots.** There is nothing to show — the mod is invisible by design, and a
screenshot of a campfire implies content that is not there.

**No performance claim without the number.** If the description's 2.2 ms figure is quoted
anywhere else, quote the base size with it (623 structures). A bare "it's fast" is the kind of
claim this project spent a day proving it could not make from arithmetic alone.
