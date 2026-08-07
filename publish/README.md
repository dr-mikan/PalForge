# Publishing

Everything a release needs that is not the code. Nothing here is read at runtime.

| file | for |
| --- | --- |
| `nexus-full-description.md` | **the Full description field.** Markdown, no images, every link verified live. Paste this one. |
| `nexus-full-description.bbcode` | the same text in BBCode, generated from the Markdown, for when Nexus's editor will not take Markdown |
| `nexus-short-description.md` | the 350-character description, with the reasoning per sentence and two alternatives |
| `nexus-fields.md` | the short fields on the upload form — name, summary, category, tags, permissions |
| `../assets/*.svg` | the mark, the banner, and four gallery cards (see `assets/README.md`) |

**No images are in the description any more.** They were pulled on 2026-08-07: the four gallery
cards can still go on the **Images** tab, where Nexus shows them as a gallery in their own right,
but the description is text and links. That removes the whole fiddly step where a URL only exists
after an upload — and it is what SMAPI, UE4SS, Fabric, Harmony and BepInEx all do, none of which
puts a diagram in its prose.

## The order that works

1. **Tag.** `git tag v0.3.0 && git push origin v0.3.0`. `.github/workflows/release.yml` runs the
   gate, builds `PalForge-v0.3.0.zip` with `tools/deploy.sh --package` and publishes it as a
   GitHub Release. The gate asserts the archive contains no `palforge/test/` and no
   `palforge_dev.lua`, and that the shipped `env.lua` still reads `dev = false` / `debug = false` —
   because that is the one defect in this build whose blast radius is somebody else's save file.
2. **Check the zip.** Download it from the Release and open it. One folder, named `PalForge`. That
   shape IS the install instruction, so if it is wrong the instruction is wrong.
3. **Rasterise the images** — `assets/README.md` has the commands.
4. **Nexus.** Upload the zip, paste `nexus-full-description.md` into Full description,
   `nexus-short-description.md`'s chosen line into the short one, and fill the rest from
   `nexus-fields.md`. Optionally add the four gallery PNGs on the Images tab — the description
   does not reference them, so their order and presence are free.

## ⚠️ Nexus has no upload API

Their acceptable-use policy makes the public API read-only, so step 4 is a human dragging the zip
from the GitHub Release into the Nexus form. Nothing automates it and nothing here should pretend
to. Upload the **GitHub Release artifact**, not a locally built zip: the one that passed the gate
is the one people should get.

## The links in the description are checked, and the trailing slash matters

Every URL in `nexus-full-description.md` was verified with `curl` before it was written down. The
docs site redirects a path without a trailing slash:

```
200  https://dr-mikan.github.io/PalForge/en/docs/getting-started/
301  https://dr-mikan.github.io/PalForge/en/docs/getting-started
```

Both work in a browser, but only one is what we should hand out. Re-check them after any docs
restructure with:

```sh
grep -oE 'https://[^)]+' publish/nexus-full-description.md | sed 's/[.,]$//' | sort -u \
  | while read -r u; do printf '%s  %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -L "$u")" "$u"; done
```

## What to say in the release notes

The tag's own notes should answer one question — *what changed for someone who already installed
this* — and link the rest. Not a changelog of commits: a reader who wants those has the compare
view. See the previous release's notes for the shape, and keep the two claims a user acts on:
the Palworld build it was measured against, and whether anything about their existing state
changed.
