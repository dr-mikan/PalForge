# Nexus — Full description

Paste the block below into Nexus's **Full description** field. It is Markdown, no images, and
every link was checked with `curl` before it was written down.

**Nexus's editor is BBCode.** If it does not accept Markdown, use
`nexus-full-description.bbcode` instead — same text, same links, BBCode tags. The `[img]` tags in
that file can simply be deleted; every section reads without them.

## ⚠️ Two things that must not drift

**The docs URLs need the trailing slash.** Without it every one of them answers `301` and only
then `200`. Verified:

```
200  https://dr-mikan.github.io/PalForge/
200  https://dr-mikan.github.io/PalForge/en/docs/getting-started/
200  https://dr-mikan.github.io/PalForge/en/docs/guides/first-content-pack/
301  https://dr-mikan.github.io/PalForge/en/docs/getting-started      <- no slash
```

**PalForge alone cannot add a row to Palworld's data tables.** A genuinely new item, creature or
build object needs PalSchema for the row. Nothing in this text may say otherwise — it is the one
sentence that would make the page a lie.

---

## The text

```markdown
## PalForge — add new pals, items and buildings to Palworld

**This is a modder's tool. It adds no content on its own** — install it by itself and nothing in
your game changes. What it does is let someone *write* content in a few lines of Lua instead of a
few hundred.

If you came here to play, you want a mod *built on* PalForge, not PalForge.

---

### Description

Modding Palworld means two separate problems. The first is getting a new thing into the game's
data — a row for an item, a creature, a build object. The second, and the one that eats the
weekend, is making it *do* something: finding which internal function fires when a structure is
placed, hooking it without crashing, working out which of the fifty arguments is the id you
wanted, and keeping whatever you remembered alive across a save and reload.

**PalForge is the second half, done.**

You declare a thing and its behaviour in one block. PalForge registers it, connects it to the
events Palworld already emits, and gives it somewhere to keep its state that survives a reload.

    require("palforge.api")

    Building{
        id = "CampFire",                        -- the game's own campfire
        events = {
            onRightClick = function(self, ctx)  -- fires in a real save
                Item.get("Wood"):give(5)
            end,
        },
    }

That is a complete, working mod. Right-click any campfire in your base, get five wood.

**Every event PalForge exposes was found by hooking the running game and watching it fire** — not
by guessing at a plausible function name. Where a channel has no source behind it on this build,
PalForge says so in the log instead of staying quiet, and the documentation names it. That
distinction is the reason to trust the rest.

**Start here → [Building a content pack](https://dr-mikan.github.io/PalForge/en/docs/guides/first-content-pack/)** — a
complete walkthrough that builds a working mod from an empty folder: a structure that reacts, a
sound, an effect, a creature, saved state, and how to debug it when it does not fire.

---

### Main features

**Eight kinds of content, one shape.** Every domain is called the same way — call it to declare,
get a handle back, act on the handle:

* **Pal** — creatures, with a mesh, a material, skills and a lifecycle
* **Item** — things, with what they restore and what happens when they are used
* **Building** — structures, with per-structure state
* **Skill** — active moves and passives
* **Effect** — status ailments, including the game's own 38
* **Audio** — from a 1957-entry catalog of the game's own sounds
* **Mesh** — models and materials
* **UI** — panels mounted inside Palworld's own interface

Every field is checked where you typed it. An undeclared field is an error with a did-you-mean,
never a silent no-op — and an id that could never reach a row in the game's data is refused at the
line you wrote it, not three hours later when nothing appears.

**How a genuinely new entity works.** Read this before you plan a mod around PalForge. Lua cannot
write a row into Palworld's data tables. A brand-new item, creature or build object therefore
needs **PalSchema** to create the row — and PalForge's namespaced ids are spelled to be exactly
what PalSchema writes: `mypack:Potion` becomes the data row `mypack_Potion`, automatically, at
every point where the id crosses into the game.

So the two work as a pair. PalSchema makes the game aware the thing exists; PalForge gives it
behaviour, events and saved state. **Giving something the game already has new behaviour needs
PalForge alone** — the campfire above uses no other mod.
→ [What a pack can ship](https://dr-mikan.github.io/PalForge/en/docs/guides/what-a-pack-can-ship/)

**The events are already wired.** Twenty-one channels, fed by twenty-two hooks into the game
itself. You declare a handler; it fires. There is no polling loop to write and no hook to register.

* **Buildings** — placed, right-clicked, loaded, ticked, removed, built, world-ready
* **Items** — crafted, obtained, used, discarded
* **Pals** — spawned, damaged, killed, captured
* **Skills** — activated, passive equipped and unequipped
* **World** — ready, left, and a shared heartbeat

The building runtime does not poll for structures either. It watches the game's own placement
events and only enumerates the world when something happened that could have changed it. In a
base of 623 structures that is **2.2 ms per sweep, with 4 of 120 sweeps doing any work at all** —
and a session with no building mod installed pays nothing, because the scan declines to run.
→ [Lifecycle and channels](https://dr-mikan.github.io/PalForge/en/docs/concepts/lifecycle/)

**State that survives a reload.** Each placed structure gets its own state table, and your mod
gets a store with its id baked into the handle — there is no way to reach another mod's data
through it.

**PalForge never writes to Palworld's save file.** Its own state is plain JSON under
`ue4ss/Mods/PalForge/state/`, one folder per save and one file per mod. Delete the mod folder and
every trace of it goes with it, with no effect on your world. A crash mid-write leaves the
previous version readable; a file that will not parse is quarantined verbatim rather than
overwritten; a mod that is not loaded this session keeps every byte and gets it all back next time.
→ [Saved state](https://dr-mikan.github.io/PalForge/en/docs/concepts/saved-state/)

**Editor completion, out of the box.** PalForge ships a generated `types.lua`, so a Lua language
server knows every field of every declaration and every method of every handle — including which
events are live and which are declared-but-unsourced. Nothing to configure.
→ [Editor setup](https://dr-mikan.github.io/PalForge/en/docs/concepts/editor-setup/)

---

### ⚠️ Single-player only

**PalForge targets single-player Palworld. Dedicated servers and co-op guests are not supported
and are not tested.** There is no replication layer, and the item, spawn and event routes are all
client-authoritative. A mod may appear to work for the host and do nothing for anyone else.

This is a deliberate scope decision, not an oversight or a to-do. Please do not report multiplayer
behaviour as a bug — the answer is this paragraph.

---

### Requirements

* **Palworld** — measured against **v1.0.2.101103** (Steam, Win64). Other builds will very likely
  work. The startup line prints both the build PalForge was tested against and the build you are
  running, so a mismatch is something you can see rather than something you deduce from a mod that
  stopped working.
* **UE4SS**, with the Lua mod loader. If you already run other Palworld Lua mods you have it.
  *Not optional.*
* **PalSchema** — *required to add NEW content*; not needed to give existing content new
  behaviour. See "How a genuinely new entity works" above.
* **CheatManagerEnablerMod** — *optional.* PalForge builds a cheat manager itself for spawning, so
  it is not needed for that; it only improves the item helpers (`give` / `take` / `unlockTech`).

---

### Installation instructions

1. Install **UE4SS** if you have not already.
2. Download the zip from the Files tab.
3. Open it. Inside is a folder named **PalForge**, plus the licence and readme.
4. Drop the **PalForge** folder into `Palworld/Pal/Binaries/Win64/ue4ss/Mods/`.
5. Start the game.

The **PalForge** folder goes in as-is — its shape *is* the install instruction. There is nothing
to configure and nothing to enable.

**To check it worked**, open `ue4ss/UE4SS.log` and look for:

    PalForge v0.3.0 starting | game build: declared v1.0.2.101103, ... | dev=false debug=false

That is all you will see, and it is all you should see. PalForge ships with its developer tooling
off — no keybinds, no test suite, nothing running in the background. A player installing a mod
built on PalForge should never know it is there.

**To uninstall**, delete the `PalForge` folder. That removes its saved state with it. Your
Palworld save is untouched either way.

→ [Getting started](https://dr-mikan.github.io/PalForge/en/docs/getting-started/)

---

### What is not here, said plainly

A framework that oversells is worse than one that is small, so:

* **A mod cannot ship its own mesh, texture, sound or material** as a game asset. It can reference
  any of the thousands the game already has, and it can load geometry from an `.obj` file on disk.
  Custom textures are wired with the right signature but have never been confirmed working.
* **Some things the engine does not expose at all.** There is no "structure was destroyed" event
  and no "skill hit something" event on this build — both were searched for by reading every
  function of every class that could plausibly own one. PalForge reports their absence rather than
  pretending, and a structure disappearing still surfaces as a removal with the reason "missing".
* **One capability is shipped but unconfirmed:** setting a sound's volume reaches the engine and
  reports success, but nobody has confirmed by ear that anything got quieter. It is tracked as an
  open issue rather than described as working.

---

### Documentation

Full documentation in **English, Japanese and Chinese** — every domain, every event, every honest
limit:

* **[Tutorial: build a content pack](https://dr-mikan.github.io/PalForge/en/docs/guides/first-content-pack/)** — start here
* [Getting started](https://dr-mikan.github.io/PalForge/en/docs/getting-started/) — install, first definition, editor setup
* [Lifecycle and channels](https://dr-mikan.github.io/PalForge/en/docs/concepts/lifecycle/) — every event, and which are live
* [Saved state](https://dr-mikan.github.io/PalForge/en/docs/concepts/saved-state/) — where it goes and what happens on uninstall
* [What a pack can ship](https://dr-mikan.github.io/PalForge/en/docs/guides/what-a-pack-can-ship/) — the honest asset table
* API reference — [Pal](https://dr-mikan.github.io/PalForge/en/docs/api/pal/) ·
  [Item](https://dr-mikan.github.io/PalForge/en/docs/api/item/) ·
  [Building](https://dr-mikan.github.io/PalForge/en/docs/api/building/) ·
  [Skill](https://dr-mikan.github.io/PalForge/en/docs/api/skill/) ·
  [Effect](https://dr-mikan.github.io/PalForge/en/docs/api/effect/) ·
  [Audio](https://dr-mikan.github.io/PalForge/en/docs/api/audio/) ·
  [Mesh](https://dr-mikan.github.io/PalForge/en/docs/api/mesh/) ·
  [UI](https://dr-mikan.github.io/PalForge/en/docs/api/ui/)

日本語: [チュートリアル](https://dr-mikan.github.io/PalForge/ja/docs/guides/first-content-pack/) ·
中文: [教程](https://dr-mikan.github.io/PalForge/zh/docs/guides/first-content-pack/)

**Source, issues and the complete engineering record** — including what was measured, what was
tried and failed, and what was deliberately not built:
[github.com/dr-mikan/PalForge](https://github.com/dr-mikan/PalForge)

**MIT licensed.** Build on it, fork it, ship it, sell it. No attribution required, though it is
appreciated. If you build something with it, I would genuinely like to see it.

---

### Shout outs

* **The UE4SS team** — [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). None of this exists
  without it. Its header dumper answered questions that would otherwise have cost weeks of
  guessing, and its Lua layer is what PalForge is built on.
* **Okaetsu, for [PalSchema](https://github.com/Okaetsu/PalSchema)** — the other half of adding
  content to this game. PalForge's id convention follows what PalSchema writes, deliberately, so
  the two compose instead of competing.
* **Pocketpair**, for a game worth spending this long inside.
```
