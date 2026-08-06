# Publishing

Everything a release needs that is not the code. Nothing here is read at runtime.

| file | for |
| --- | --- |
| `nexus-description.bbcode` | the Nexus Mods description field, in their BBCode |
| `nexus-fields.md` | the short fields on the Nexus upload form — name, summary, category, tags |
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
4. **Nexus.** Upload the same zip. `nexus-description.bbcode` goes in the description,
   `nexus-fields.md` fills the rest.

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
