# Publishing

Everything a release needs that is not the code. Nothing here is read at runtime.

| file | for |
| --- | --- |
| `nexus-full-description.bbcode` | **the Full description field**, in their BBCode, with four explanatory images placed in it. This is the one to paste. |
| `nexus-description.bbcode` | an earlier, shorter description with no images. Kept as the fallback if the image workflow is more trouble than it is worth. |
| `nexus-short-description.md` | the 350-character description, with the reasoning per sentence |
| `nexus-fields.md` | the short fields on the Nexus upload form — name, summary, category, tags |
| `nexus-short-description.md` | the 350-character description, with the reasoning per sentence and two alternatives |
| `../assets/*.svg` | the images, plus the commands that rasterise them (see `assets/README.md`) |

## The order that works

1. **Tag.** `git tag v0.3.0 && git push origin v0.3.0`. `.github/workflows/release.yml` runs the
   gate, builds `PalForge-v0.3.0.zip` with `tools/deploy.sh --package` and publishes it as a
   GitHub Release. The gate asserts the archive contains no `palforge/test/` and no
   `palforge_dev.lua`, and that the shipped `env.lua` still reads `dev = false` / `debug = false` —
   because that is the one defect in this build whose blast radius is somebody else's save file.
2. **Check the zip.** Download it from the Release and open it. One folder, named `PalForge`. That
   shape IS the install instruction, so if it is wrong the instruction is wrong.
3. **Rasterise the images** — `assets/README.md` has the commands.
4. **Nexus.** Upload the same zip, then the images, then the text — in that order, because the
   description needs the image URLs and you only get those after uploading them.

### The image workflow, which is the fiddly part

`nexus-full-description.bbcode` has four `[img]` tags with placeholder URLs
(`IMG_URL_1` … `IMG_URL_4`). They cannot be filled in ahead of time: Nexus mints a URL when it
accepts an upload.

1. Rasterise the four gallery SVGs (`assets/gallery/README.md` has the commands).
2. Nexus mod page → **Images** tab → upload all four. Give each a caption; the caption is what a
   screen reader and a slow connection get.
3. Open each uploaded image, copy its **direct** URL — the one ending in `.png`, not the page URL.
4. Paste them into the description in place of the placeholders. The mapping is in the file, and
   the numbers are **not** the same as the file names:

   | placeholder | file | where it sits |
   | --- | --- | --- |
   | `IMG_URL_1` | `G1-new-entity.png` | under *How a genuinely new entity works* |
   | `IMG_URL_2` | `G2-what-you-can-add.png` | under *Eight kinds of content, one shape* |
   | `IMG_URL_3` | `G3-events.png` | under *The events are already wired* |
   | `IMG_URL_4` | `G4-saved-state.png` | under *State that survives a reload* |

5. **Delete the warning line at the top of the file** before saving. It is there to stop exactly
   the mistake of pasting the whole thing with `IMG_URL_1` still in it.

Each image sits under the heading it explains, not at the top as decoration. If an image will not
upload, the section still reads without it — none of them carries information the prose does not.

## ⚠️ Nexus has no upload API

Their acceptable-use policy makes the public API read-only, so step 4 is a human dragging the zip
from the GitHub Release into the Nexus form. Nothing automates it and nothing here should pretend
to. Upload the **GitHub Release artifact**, not a locally built zip: the one that passed the gate
is the one people should get.

## What to say in the release notes

The tag's own notes should answer one question — *what changed for someone who already installed
this* — and link the rest. Not a changelog of commits: a reader who wants those has the compare
view. See the previous release's notes for the shape, and keep the two claims a user acts on:
the Palworld build it was measured against, and whether anything about their existing state
changed.
