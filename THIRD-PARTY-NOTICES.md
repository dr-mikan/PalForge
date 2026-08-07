# Third-party notices

PalForge is MIT (see `LICENSE`). It **redistributes** one piece of third-party code, and the MIT
licence that covers it requires its copyright and permission notice to travel with every copy —
including the zip on a mod page. That notice is reproduced in full below.

Everything else PalForge depends on is a **separate install the user provides**, not something
this archive contains. Depending on software creates no redistribution obligation; those are
listed after, for credit and so a reader knows what else has to be present.

---

## Redistributed in this archive

### RxLua

* **Where:** `Scripts/palforge/core/vendor/rx.lua`
* **Version:** 0.0.3
* **Upstream:** https://github.com/bjornbytes/RxLua
* **Used for:** the observable bus underneath PalForge's event channels (`core/event.lua`)
* **Licence:** MIT

```
MIT License

Copyright (c) 2015 Bjorn Swenson

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Depended on, not redistributed

Neither is contained in this archive. The user installs them; PalForge only requires that they be
present.

| | | |
| --- | --- | --- |
| **UE4SS** (RE-UE4SS) | https://github.com/UE4SS-RE/RE-UE4SS | The Lua loader PalForge runs on. Required. Its own bundled mods — `CheatManagerEnablerMod` among them — come with it. |
| **PalSchema** | https://github.com/Okaetsu/PalSchema | Writes the data rows a genuinely new item, creature or build object needs. PalForge's namespaced ids are spelled to match what it writes. Required only for new content. |

---

## Not third-party at all

The measurements this project is built on came from reading **Palworld's own shipping binary**
through UE4SS's header dumper and reflection tools. No Palworld asset, string table, model, sound
or code is contained in this archive. PalForge references the game's own content **by id** — the
ids are in `Scripts/palforge/native/`, which is a list of names the game already uses, not a copy
of anything it ships.

---

## If you add a dependency

Add it here **in the same commit**, on this rule: *does the archive contain it?*

* **Yes** → its licence's notice requirements apply to us. Reproduce them in full, under
  "Redistributed", the way RxLua is above. A link is not a substitute for the notice.
* **No** → it belongs under "Depended on", for credit and clarity, and imposes nothing.

And keep the Credits field on the Nexus page in step with this file — that page is where most
people will look, and Nexus states plainly that crediting is not the same as permission.
