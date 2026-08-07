# Artwork

The source art, and the commands that turn it into the raster sizes each place wants. The PNGs are
build output and are not committed.

| file | what it is |
| --- | --- |
| `header.svg` | **1300×372**, the Nexus page header. A different composition from the banner, not the banner squashed — at 3.5:1 there is room for the mark, the name and one line, and nothing else fits. |
| `logo.svg` | **512×512** square mark — the anvil under a rising spark, ringed like a socket. |
| `banner.svg` | **1280×640** wide mark, for the GitHub social preview. |
| `gallery/` | **four 1280×720 cards**, rendered at 1920×1080 for the Nexus gallery. `gallery/README.md` carries the design language. |

**Every one of these is generated.** `tools/gen-cards.py` writes all of them, so the anvil, the
three colours and the dashed-means-declared rule have ONE definition. Editing an SVG here is
editing build output.

## Making the PNGs

```sh
npm run art      # regenerate the SVGs, then render every PNG at its target size
npm run images   # just the render
```

`tools/rasterise.mjs` holds the sizes and reads each PNG's dimensions back out of its header
rather than trusting the request, so a wrong one fails the run instead of reaching a mod page.
Output goes to `publish/images/`, which is gitignored: the SVGs are the source.



## Two things worth knowing before editing them

**The text is real text, not paths.** That keeps the files small and editable, and it means a
machine without the font substitutes something else. Convert on a machine that has a normal sans
(Segoe UI, Inter, Helvetica and Arial are all listed, in that order) or convert the text to paths
first — `inkscape --export-text-to-path` — if the exact letterforms matter.

**The build string in `banner.svg` is a claim.** It reads *measured against Palworld
v1.0.2.101103*, which is `env.gameBuild`. If that value moves, this file moves with it, or the
banner starts telling people something the framework does not.
