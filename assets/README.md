# Artwork

Two SVGs, and the commands that turn them into the raster sizes each place wants. They are the
source; the PNGs are build output and are not committed.

| file | what it is |
| --- | --- |
| `logo.svg` | 512×512 square mark — an anvil under a rising spark, ringed like a socket. The forge is the anvil; the ring is a pack plugging into it. Concept **A**. |
| `banner.svg` | 1280×640 wide mark with the name, the one-line description and the measured game build. |
| `concepts/` | **six alternative marks and a contact sheet.** `concepts/_sheet.svg` shows all six at once and is self-contained. `concepts/README.md` says what each one is trying to say and which survive at 32 px. The shipped mark is A until someone picks another. |

The palette is three colours and they mean something rather than decorating: heated steel
(`#e2621d` → `#ffd978`) for anything that fires, cold steel (`#9fb0c4`) for the framework itself,
and near-black (`#12171f`) behind both so a light and a dark page both hold it.

## Making the PNGs

`rsvg-convert` gives the cleanest text; ImageMagick is the fallback and needs a font that can
render the sans stack.

```sh
# Nexus Mods: main image, 1280x640 is the size their header crops cleanly
rsvg-convert -w 1280 -h 640 assets/banner.svg -o palforge-banner.png

# Nexus Mods: thumbnail. Theirs is shown small — the square mark reads better than the banner
rsvg-convert -w 512 -h 512 assets/logo.svg -o palforge-thumb.png

# GitHub: social preview is 1280x640, the same banner
rsvg-convert -w 1280 -h 640 assets/banner.svg -o github-social.png

# Favicon / docs site
rsvg-convert -w 256 -h 256 assets/logo.svg -o palforge-256.png
```

ImageMagick equivalent, if `rsvg-convert` is not installed:

```sh
magick -background none -density 300 assets/logo.svg -resize 512x512 palforge-thumb.png
```

## Two things worth knowing before editing them

**The text is real text, not paths.** That keeps the files small and editable, and it means a
machine without the font substitutes something else. Convert on a machine that has a normal sans
(Segoe UI, Inter, Helvetica and Arial are all listed, in that order) or convert the text to paths
first — `inkscape --export-text-to-path` — if the exact letterforms matter.

**The build string in `banner.svg` is a claim.** It reads *measured against Palworld
v1.0.2.101103*, which is `env.gameBuild`. If that value moves, this file moves with it, or the
banner starts telling people something the framework does not.
