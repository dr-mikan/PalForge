# PalForge agent skill

Teaches a coding agent to write PalForge content packs: the Lua files that add items,
buildings, pals, skills, effects, sounds, meshes and UI to Palworld through PalForge.

An agent with this loaded can:

- write a pack using the real call shape (`Item{ ... }`, `Item.get(id)`, `Item.get_all()`)
  instead of guessing at an API,
- use only fields that exist — an unknown field is a hard error that stops the whole
  definition, so guessing breaks the pack at load time,
- avoid the hooks that are declarable but never fire (`onCraft`, `onDiscard`,
  `onLeftClick`, `onBreak`, and everything on `Skill`),
- say how to load the pack from `main.lua`, and what log line proves it ran.

```text
skills/
├── palforge/               the Claude Code skill
│   ├── SKILL.md
│   └── reference/          api.md, recipes.md, pitfalls.md — loaded on demand
├── codex/
│   ├── AGENTS.md           the same knowledge, for a Codex AGENTS.md
│   └── prompts/
│       └── palforge-pack.md    the /palforge-pack slash command
├── install.sh
└── install.ps1
```

## Install

Both scripts run from anywhere, need no network and no sudo, and refuse to overwrite an
existing install unless you pass `--force` / `-Force`. Run with no target flag and they
install for every tool they find (the `claude` and `codex` commands, `~/.claude`,
`~/.codex`); pass `--claude` / `--codex` to pick one.

### Claude Code

**Project install (default)** copies `skills/palforge/` into `.claude/skills/palforge/`
under the directory you run it from — the skill is then available in that project only.

```sh
bash /path/to/PalForge/skills/install.sh --claude
```

**User install** copies the same folder into `~/.claude/skills/palforge/`, making it
available in every project on the machine.

```sh
bash /path/to/PalForge/skills/install.sh --claude --user
```

On Windows PowerShell, `.\install.ps1 -Claude` and `.\install.ps1 -Claude -User`.

The skill loads itself when you ask for something PalForge-shaped; `reference/api.md` is
read only when the agent needs a field.

### Codex

Copies `skills/codex/prompts/palforge-pack.md` into `~/.codex/prompts/palforge-pack.md`,
where it becomes the `/palforge-pack` slash command. It touches nothing else — AGENTS.md
is yours, so the script prints the block to add rather than appending it.

```sh
bash /path/to/PalForge/skills/install.sh --codex
```

On Windows PowerShell, `.\install.ps1 -Codex`.

Then paste `skills/codex/AGENTS.md` into the `AGENTS.md` of the project you are modding,
or into `~/.codex/AGENTS.md` to have it everywhere. Codex reads AGENTS.md on every turn, so
that file — not the prompt — is what makes it write correct PalForge code unprompted.

## Doing it by hand

Nothing here is magic; both installs are a copy.

```sh
mkdir -p ~/.claude/skills ~/.codex/prompts
cp -R skills/palforge              ~/.claude/skills/palforge
cp skills/codex/prompts/palforge-pack.md ~/.codex/prompts/palforge-pack.md
cat skills/codex/AGENTS.md >> ./AGENTS.md
```

## Keeping it current

`palforge/reference/api.md` is generated from PalForge's own schema registry. Regenerate it
after an API change, then re-run the installer with `--force`:

```sh
lua5.4 tools/gen-skill-reference.lua .
```
