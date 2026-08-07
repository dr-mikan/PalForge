# Capability cards

Nine 1280×720 images, one per thing a pack can extend. They are the Nexus gallery, and they double
as the hero images in the docs.

**They are generated.** `tools/gen-cards.py` holds the template and all nine card definitions;
editing an SVG here is editing build output. Run:

```sh
python3 tools/gen-cards.py
```

| | card | what it shows |
| --- | --- | --- |
| 01 | `01-buildings.svg` | The campfire that is already in your base gaining a right-click. No new model, no new build-menu entry. |
| 02 | `02-items.svg` | Craft · obtain · use · discard, plus give / take / count. |
| 03 | `03-pals.svg` | Spawn one, dress it with a declared mesh, teach it a move. |
| 04 | `04-skills-effects.svg` | Activation and passives, the 38 native ailments, and `skill.hit` drawn as the dashed box it is. |
| 05 | `05-ui.svg` | A panel mounted *inside* Palworld's own layout, with declared keys and buttons. |
| 06 | `06-audio-mesh.svg` | 1957 game sounds, vanilla meshes, an `.obj` off disk — and the two things a pack cannot ship, drawn dashed. |
| 07 | `07-state.svg` | Per-mod, per-save state that lives beside the mod and never inside Palworld's save. |
| 08 | `08-events.svg` | 22 native hooks → 21 channels → your handlers. Push, not poll. |
| 09 | `09-packs.svg` | Two mods, one game: namespaced ids, an attributable collision, an isolated store. |

## The design language, which is the point of the set

Every card is built from the same four things, so a reader who learns them on card 01 can read
card 09 without being told again:

| | means |
| --- | --- |
| **the anvil**, top right | the framework itself. It is the chosen mark (concept A) at 0.19 scale, defined once in the generator. |
| **heated steel** — a solid orange-outlined box, an arrow, a spark | something that **fires**. A live channel, a real call, an event that was observed. |
| **cold steel dashed** — a dashed grey box or arrow | **declared, callable, and with no native source behind it.** `skill.hit`, `building.break`, a custom sound. This is the one piece of vocabulary that matters most and the one the marks in `../concepts/` share. |
| **the code panel**, left | real, callable API. Never pseudocode — if the API changes, the card is wrong. |

Each card also carries one grey line along the bottom that says something true and slightly
awkward: what the measurement actually was, or what the capability does *not* promise. That is
deliberate. A gallery that only shows the good half is the kind of page that produces the first
bug report.

## Rasterising

```sh
# the whole set, at Nexus gallery size
for f in assets/cards/*.svg; do
  rsvg-convert -w 1280 -h 720 "$f" -o "${f%.svg}.png"
done
```

`assets/README.md` has the ImageMagick fallback and the note about fonts — the text on these is
real text, so convert on a machine with a normal sans and a monospace, or the code panels will
substitute.

## Order on the Nexus page

01 first: it is the shortest complete example and the one that answers *what would I even use this
for*. Then 08 (the event model, which explains why the rest works), then the domain cards, then 07
and 09 last — those answer questions a reader only has once they are convinced.
