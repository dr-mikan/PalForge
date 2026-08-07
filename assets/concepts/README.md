# Concept marks

Six directions for the icon, all 512×512, all on the same three-colour palette so they can be
compared on shape alone rather than on colour. **`_sheet.svg` is the contact sheet** — open that
one first; it holds all six inline, so it needs no other file.

The shipped mark today is **A**, which is what `assets/logo.svg` and the banner use. Nothing here
replaces it until someone says so.

| | mark | the idea | reads well at 32 px? |
| --- | --- | --- | --- |
| **A** | The anvil | The forge, plainly: an anvil under a rising spark, ringed like a socket. Says *tool*, says *making*, and the ring hints at the plug-in model without explaining it. | yes — the silhouette survives |
| **B** | The socket | The game is a closed ring, complete without you. Four sockets are cut into it; three carry a pack's declaration and **one is left open on purpose** — the framework never requires all of them. | yes, and it is the clearest of the six about *what PalForge is for* |
| **C** | The blueprint | The same shape twice: dashed and declared on the left, built and lit on the right, with an arrow between. This is literally what a `Building{ ... }` call does. | **no** — too much detail; it is a banner or docs image, not an icon |
| **D** | The channels | One emission on the left fans out to four listeners. Three are live, the fourth is dashed: a channel that is declared and has never fired, which this project is careful to distinguish. | at 32 px it becomes a smear; fine at 128 px+ |
| **E** | The wordmark | P and F sharing a stem — the pack and the framework are one object. The spark sits on the F's shoulder. The only one that is legible as *text* when it is tiny. | yes, and it is the only one that still says the NAME |
| **F** | The hearth | The game's world as a hex, warmed from inside by a flame that is not on the outside of it. Warmer and less technical than the rest; the one a player rather than a modder would like. | yes |

## The palette, and why it is only three colours

| | | means |
| --- | --- | --- |
| heated steel | `#c2490f` → `#e2621d` → `#f5a524` → `#ffd978` | anything that **fires**: an event, a spark, a live channel |
| cold steel | `#e9eef5` → `#9fb0c4` → `#5d6f85` | the framework itself, and the game's own structure |
| near-black | `#12171f`, `#1a2230`, `#243040` | background, so a light page and a dark page both hold the mark |

A dashed cold-steel outline means **declared but not firing** in B, D and C. That is a real
distinction in this codebase — a channel can exist, be declarable, and have no native source —
and it is the one piece of vocabulary the marks share.

## Rasterising

Same commands as `../README.md`. For a side-by-side to look at:

```sh
rsvg-convert -w 1152 assets/concepts/_sheet.svg -o concepts.png
```

Any single one, at icon sizes:

```sh
for n in A-anvil B-socket C-blueprint D-channels E-wordmark F-hearth; do
  rsvg-convert -w 128 -h 128 "assets/concepts/$n.svg" -o "/tmp/$n-128.png"
done
```

## If none of them is right

Say which half works. These were built so the parts recombine: A's anvil with B's socket ring, E's
wordmark on F's hex, C's dashed-to-solid idea applied to any of the others. The palette and the
dashed-means-declared rule stay whatever the shape becomes.
