Build a PalForge content pack — one Lua file that adds content to Palworld through the
PalForge API.

The user's request, if they gave one on the command line: $ARGUMENTS

Follow these steps in order. Do not skip to writing code.

## 1. Find out what they want

If `$ARGUMENTS` is empty or vague, ask — in one message, not one question at a time:

- **What should it do in game?** One or two sentences of behaviour, not field names.
- **Which id does it hang on?** A game id the player already has (`Wood`, `Stone`,
  `PalBoxV2`, `ChickenPal`) or their own `"pack:name"`. Say plainly that Lua cannot add a
  new row to the game's DataTables — a brand-new id needs a matching PalSchema row, so
  building on an existing id is the path that works today.
- **What is the pack called?** It becomes the file name and the log scope.
- **Where does it go?** Next to `main.lua` in `ue4ss/Mods/PalForge/Scripts/` (simplest), or
  its own UE4SS mod folder using `_G.PalForge`.

If the answer to the first question needs a hook that does not fire — `onCraft`,
`onDiscard`, `onLeftClick`, `onBreak`, or anything on `Skill` firing by itself — say so now
and offer the live neighbour (`onObtain` / `onUse`, `onRightClick` / `onRemove`, or calling
`Skill.Handle:activate` yourself). Do not write a handler that will never run.

## 2. Pick the domain and check the fields

Map the behaviour onto one or more of `Pal`, `Item`, `Building`, `Skill`, `Effect`,
`Audio`, `Mesh`, `UI`, `Player`.

Before writing a field, confirm it exists. In order of preference:

- `reference/api.md` next to the PalForge skill, or `docs/content/docs/api/*.mdx` in the
  PalForge repository, if either is reachable from this workspace.
- `print(require("palforge.core.schema").help("Item.Spec"))` — tell the user to run it if
  you cannot read the reference yourself.

An unknown field is a hard error that stops the whole call, so a guessed field name breaks
the pack at load time rather than degrading quietly. Never invent one.

## 3. Write the file

Shape it like this, adjusted to what they asked for:

```lua
-- <pack name> — <one line of what it does>
local api = require("palforge.api")
local log = require("palforge.utils.log").scope("<pack>")

api.Item{
    id       = "Stone",
    name     = "Stone",
    category = "material",
    events   = {
        onObtain = function(self, ctx)
            log.info("picked up " .. tostring(ctx.count) .. " stone")
        end,
    },
}

log.info("<pack> loaded")
```

Rules to hold to:

- Define once at load; inside a handler use `X.get(id)`, never `X{ ... }` again.
- `Building` handlers get a live instance: `self.actor`, `self.pos`, `self.state`, and
  `self:save()` after you mutate `self.state`. `onBuild` is the exception — `self` is the
  definition there.
- Log something on every path you want to be able to see. `[PalForge.<scope>][info] ...` in
  `UE4SS.log` is the only proof the handler ran.
- Keep the pack self-contained in one file unless the user asked for more.

## 4. Say how to load it

Give the exact two lines that go at the **bottom** of `main.lua`, after
`registry.initialize()`:

```lua
local ok, err = pcall(require, "<pack>")
if not ok then print("[<pack>] load failed: " .. tostring(err) .. "\n") end
```

For a standalone mod, give the `_G.PalForge` form with the `if not PF then ... return end`
guard, and the `mods.txt` ordering (PalForge above the pack).

## 5. Verify before you hand it over

- Run `luac5.4 -p <file>.lua` (or `lua5.4 -e "assert(loadfile('<file>.lua'))"`) and show the
  result. A pack that does not parse is not finished.
- Re-read every field against the reference one more time.
- Tell the user exactly what to look for in game: the startup line
  `[PalForge.main][info] ready`, the world gate line
  `[PalForge.event][info] world ready - building dispatch enabled`, then the specific log
  line your handler prints and the action that triggers it. If it is a building, mention
  **F4** to unlock the technology so it appears in the build menu, and **F1** to run
  PalForge's own suite.

State plainly what you did and did not check. Syntax-checked and schema-checked is what an
offline edit can claim; whether it works in game is what the log lines above will tell them.
