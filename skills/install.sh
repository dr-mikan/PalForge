#!/usr/bin/env bash
# Install the PalForge agent skill for whichever supported tools are on this machine.
# No network, no sudo. Copies files only into the directories it names below.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_SRC="$SCRIPT_DIR/palforge"
CODEX_PROMPT_SRC="$SCRIPT_DIR/codex/prompts/palforge-pack.md"
CODEX_AGENTS_SRC="$SCRIPT_DIR/codex/AGENTS.md"

SCOPE="project"          # or "user"
PROJECT_DIR="$PWD"
FORCE=0
WANT_CLAUDE=0
WANT_CODEX=0
EXPLICIT_TARGET=0

die() { printf '%s\n' "install.sh: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Installs the PalForge skill for whichever tools are detected.

Claude Code
  --project            install into <project>/.claude/skills/palforge/   (default)
  --user               install into ~/.claude/skills/palforge/
  --project-dir DIR    project root for --project (default: current directory)

Codex
  writes ~/.codex/prompts/palforge-pack.md, then PRINTS the block to add to
  your own AGENTS.md. It never edits AGENTS.md for you.

Targets
  --claude             install for Claude Code only
  --codex              install for Codex only
  (neither)            install for every tool detected on this machine

Other
  --force              replace an existing install (without it, an existing
                       destination is left alone and the script exits non-zero)
  -h, --help           this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project)     SCOPE="project" ;;
        --user)        SCOPE="user" ;;
        --project-dir) [ $# -ge 2 ] || die "--project-dir needs a directory"
                       PROJECT_DIR="$2"; SCOPE="project"; shift ;;
        --claude)      WANT_CLAUDE=1; EXPLICIT_TARGET=1 ;;
        --codex)       WANT_CODEX=1;  EXPLICIT_TARGET=1 ;;
        --force)       FORCE=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

[ -n "${HOME:-}" ] || die "HOME is not set"
[ -d "$SKILL_SRC" ] || die "missing source directory: $SKILL_SRC"
[ -f "$SKILL_SRC/SKILL.md" ] || die "missing $SKILL_SRC/SKILL.md — this is not a complete skill tree"
[ -f "$CODEX_PROMPT_SRC" ] || die "missing source file: $CODEX_PROMPT_SRC"
[ -f "$CODEX_AGENTS_SRC" ] || die "missing source file: $CODEX_AGENTS_SRC"

# Detect what is present, unless the caller named a target.
if [ "$EXPLICIT_TARGET" -eq 0 ]; then
    if command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; then WANT_CLAUDE=1; fi
    if command -v codex  >/dev/null 2>&1 || [ -d "$HOME/.codex"  ]; then WANT_CODEX=1;  fi
    if [ "$WANT_CLAUDE" -eq 0 ] && [ "$WANT_CODEX" -eq 0 ]; then
        die "no supported tool found (looked for the 'claude' and 'codex' commands, and for ~/.claude and ~/.codex). Pass --claude and/or --codex to install anyway."
    fi
fi

list_files() {   # list_files <dir> — print every installed file, indented
    find "$1" -type f | LC_ALL=C sort | while IFS= read -r f; do printf '    %s\n' "$f"; done
}

install_claude() {
    local dest
    if [ "$SCOPE" = "user" ]; then
        dest="$HOME/.claude/skills/palforge"
        printf 'Claude Code: user install (every project on this machine).\n'
    else
        [ -d "$PROJECT_DIR" ] || die "project directory does not exist: $PROJECT_DIR"
        PROJECT_DIR="$(cd -- "$PROJECT_DIR" && pwd -P)"
        dest="$PROJECT_DIR/.claude/skills/palforge"
        printf 'Claude Code: project install (this project only: %s).\n' "$PROJECT_DIR"
    fi

    if [ -e "$dest" ]; then
        if [ "$FORCE" -eq 1 ]; then
            rm -rf -- "$dest"
        else
            die "$dest already exists. Re-run with --force to replace it."
        fi
    fi

    mkdir -p -- "$(dirname -- "$dest")"
    cp -R -- "$SKILL_SRC" "$dest"
    printf '  copied %s -> %s\n' "$SKILL_SRC" "$dest"
    list_files "$dest"
}

install_codex() {
    local dest="$HOME/.codex/prompts/palforge-pack.md"
    printf 'Codex: user install (every project on this machine).\n'

    if [ -e "$dest" ]; then
        if [ "$FORCE" -eq 1 ]; then
            rm -f -- "$dest"
        else
            die "$dest already exists. Re-run with --force to replace it."
        fi
    fi

    mkdir -p -- "$HOME/.codex/prompts"
    cp -- "$CODEX_PROMPT_SRC" "$dest"
    printf '  copied %s -> %s\n' "$CODEX_PROMPT_SRC" "$dest"
    printf '    %s\n' "$dest"
    printf '  run it in Codex as: /palforge-pack\n'

    cat <<EOF

  AGENTS.md is yours, so this script does not touch it. To give Codex the
  PalForge knowledge in every turn, paste the contents of

    $CODEX_AGENTS_SRC

  into the AGENTS.md of the project you are modding, under a heading of your
  choosing. For every project on this machine, put it in ~/.codex/AGENTS.md
  instead. Copy it with:

    cat "$CODEX_AGENTS_SRC" >> ./AGENTS.md
EOF
}

if [ "$WANT_CLAUDE" -eq 1 ]; then install_claude; fi
if [ "$WANT_CODEX"  -eq 1 ]; then install_codex; fi

printf '\nDone.\n'
