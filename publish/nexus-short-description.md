# The 350-character description

Nexus's short description field. It is the only prose that follows the mod around — search
results, category listings, the tile on someone's tracking page — so it has one job: make a modder
stop scrolling, and make a player keep scrolling.

## Use this one

```
Add new pals, items and buildings to Palworld in a few lines of Lua. Declare it, and PalForge
wires it to the game's own events — placed, used, crafted, spawned, damaged — with saved state
that survives a reload. Eight kinds of content, one shape. Modder's framework, not a gameplay
mod. Single-player only. MIT.
```

**311 characters.** Under the limit with room for a word if you want one.

### Why each sentence is there

| sentence | doing what |
| --- | --- |
| *Add new pals, items and buildings to Palworld in a few lines of Lua.* | The promise, in the first eight words, in the reader's vocabulary. Not "content framework" — nobody searches for a category they have never heard of. |
| *Declare it, and PalForge wires it to the game's own events — placed, used, crafted, spawned, damaged — with saved state that survives a reload.* | The differentiator. Anyone can inject a row; the reason to use this is that the events are already found and wired. The five named channels are concrete evidence, not adjectives. |
| *Eight kinds of content, one shape.* | Scope and learning cost in five words. |
| *Modder's framework, not a gameplay mod.* | Stops the wrong download before it happens. |
| *Single-player only. MIT.* | The two facts most likely to be someone's dealbreaker, given first rather than discovered. |

## Alternatives, if the tone is wrong

**Shorter and blunter — 238 characters:**

```
Add new pals, items and buildings to Palworld in a few lines of Lua. Declare it; PalForge wires
it to the game's own events and keeps its state across reloads. Eight kinds of content, one
shape. A modder's framework, not a gameplay mod. Single-player only.
```

**Leading with the pain — 344 characters:**

```
Hooking Palworld yourself means reverse-engineering which UFunction fires when. PalForge already
did it: 21 channels from 22 native hooks, so a new pal, item or building is a few lines of Lua
with its events already wired and its state already saved. Eight kinds of content. A modder's
framework, single-player only. MIT.
```

That third one is the strongest to a reader who has already tried and failed to hook something,
and the weakest to everyone else. Pick it only if the Palworld modding scene is small enough that
most readers have.

## ⚠️ What none of them may say

**Do not shorten the promise to "add new content" and stop.** PalForge cannot write a row into
Palworld's data tables — Lua cannot — so a genuinely new item, creature or build object needs
**PalSchema** for the row. PalForge does everything after that, and its ids are spelled to match
what PalSchema writes.

At 350 characters there is no room to explain the pairing, which is fine: the full description and
gallery card G1 both do, and *"in a few lines of Lua"* is true either way. What must never happen
is a short description that implies PalForge alone creates content — that is the one sentence that
would make the page a lie, and the page is the first thing anyone reads.
