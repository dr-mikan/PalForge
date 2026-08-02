#!/usr/bin/env bash
# Copy this working tree into a Palworld install so the game runs what you just edited.
#
#   tools/deploy.sh                          # DEV deploy into the default install below
#   tools/deploy.sh "/path/to/Palworld"      # dev deploy somewhere else
#   tools/deploy.sh --release                # what a player gets: no dev overlay, no keys
#   tools/deploy.sh --release "/path/to/Palworld"
#
# THE TWO MODES DIFFER BY ONE FILE, and that file is the whole dev/release switch.
#
#   dev (default)  writes Scripts/palforge_dev.lua into the DEPLOYED tree. main.lua requires
#                  that module immediately before registry.initialize() and ignores it when it
#                  is absent; it sets env.dev = true and env.debug = true, which is what arms
#                  the nine dev keybinds (F4 unlocks every technology), the F1 API suite, F9
#                  reload, the ps_catalog dumper, the headless unit bundle and the test hooks.
#   --release      does not write it, and DELETES any copy it finds under the deployed mod —
#                  a stale one from an earlier dev deploy would silently arm all of the above
#                  in a copy that is supposed to be a player's.
#
# THIS SCRIPT NEVER EDITS Scripts/palforge/env.lua. The shipped defaults there are dev = false
# and debug = false, and they stay that way in the source tree and in every deployed copy: a
# release toggle that some tool flips on is a release toggle that eventually ships on, which is
# exactly how `dev = true` came to be the shipped default in the first place. The overlay file
# is additive, is gitignored, and cannot reach a player through the repository.
#
# The mod folder is REPLACED, not merged: a file you deleted here has to disappear there too,
# or the game keeps loading it. deprecated/ and tmp/ are reference-only and are left behind.
#
# Lua is read at mod load, so a fresh deploy needs a game restart the first time. After that,
# deploy again and press F9 in game — the framework reloads without a restart (dev mode only:
# F9 is one of the keys env.dev arms).
set -euo pipefail

MODE="dev"
GAME=""
for arg in "$@"; do
    case "$arg" in
        --release) MODE="release" ;;
        --dev)     MODE="dev" ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        -*)
            echo "unknown option: $arg (expected --release, --dev or a Palworld path)" >&2
            exit 2 ;;
        *)
            GAME="$arg" ;;
    esac
done

GAME="${GAME:-/mnt/e/SteamLibrary/steamapps/common/Palworld}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$GAME/Pal/Binaries/Win64/ue4ss/Mods/PalForge"

[ -d "$SRC/Scripts/palforge" ] || { echo "not a PalForge tree: $SRC" >&2; exit 1; }
[ -d "$GAME/Pal/Binaries/Win64/ue4ss/Mods" ] || {
    echo "no UE4SS Mods directory under $GAME" >&2; exit 1; }

echo "mode:   $MODE"
echo "source: $SRC/Scripts"
echo "target: $DEST/Scripts"

# STAGE, THEN SWAP. Deleting Scripts/ and re-copying leaves a window of a second or two in
# which the mod directory is incomplete, and pressing F9 during that window fails the reload
# with "module 'palforge.core.registry' not found" — which has happened, and which reads like a
# code error rather than a race. Everything is built alongside the live copy and moved into
# place with a rename, so the game never sees a half-populated tree.
STAGE="$DEST/.Scripts.staging"
OLD="$DEST/.Scripts.previous"
rm -rf "$STAGE" "$OLD"
mkdir -p "$STAGE"

# autorun.txt is a DEV QUEUE and is copied like any other file. It runs named pf_* actions on
# world.ready and needs no key and no console — which matters because all three input routes
# have failed in turn on this machine (a key the game claimed, a second key, and a console UE4SS
# ships switched off). Edit it in the source tree, deploy, load a save.
#
# Everything the mod needs at runtime. Both test directories stay, and neither is optional:
# palforge/test/ is what binds F1, and palforge/tests/ is the headless bundle core/registry runs
# at startup under dev plus the body of the ps_catalog console command. This comment used to say
# tests/ was gitignored and therefore "exists only in a working tree" — it WAS listed in
# .gitignore, and that was the defect: the kernel required a directory a clone did not carry.
# The line is gone and both ship. Only deprecated/ and tmp/ are dropped below, and they are
# reference trees nothing requires.
cp -r "$SRC/Scripts/main.lua" "$STAGE/main.lua"
cp -r "$SRC/Scripts/palforge" "$STAGE/palforge"
rm -rf "$STAGE/palforge/deprecated" "$STAGE/palforge/tmp"

# A BUILD STAMP, so a stale run is obvious in the log instead of being diagnosed for an hour.
# Lua that is already loaded stays loaded: copying files here changes nothing in a running game
# until F9 (reload) or a restart. Every run of the suite prints this stamp, so if the log shows
# an older one than the deploy that just happened, F9 was not pressed and nothing in that log is
# evidence about the current code. This has cost a full debugging round more than once.
{
    echo '-- GENERATED by tools/deploy.sh. The suite prints this so a stale run is visible.'
    echo "return \"$(date '+%Y-%m-%d %H:%M:%S')\""
} > "$STAGE/palforge/build.lua"

# THE DEV OVERLAY. Written into the staged tree in dev mode only, so it lands with the same
# atomic swap as everything else. It sits next to main.lua because main.lua's package.path puts
# its own Scripts dir first — `require("palforge_dev")` resolves to Scripts/palforge_dev.lua and
# to nothing at all when the file is not there.
if [ "$MODE" = "dev" ]; then
    cat > "$STAGE/palforge_dev.lua" <<'LUA'
-- GENERATED by tools/deploy.sh (default, dev mode). NOT part of the repository — it is
-- gitignored, and `tools/deploy.sh --release` deletes it instead of writing it.
--
-- main.lua requires this module immediately before registry.initialize() and ignores it when
-- it is missing, which is the whole dev/release switch: env.lua ships dev = false and nothing
-- in the framework ever turns it on. Delete this file (or re-deploy with --release) and the
-- next game start is a player's start.
--
--   dev   = the nine dev keybinds (F4 unlocks EVERY technology in the loaded save), the F1
--           API suite, F9 reload, the ps_catalog dumper and the headless unit bundle at boot.
--   debug = additionally loads palforge/test/hooks — the measurements that cannot run without
--           a running game. Declared, never auto-run: ask for one by name (pf_hook <id>), and
--           a hook that WRITES into a save needs env.debugHooks[id] = true as well.
local env   = require("palforge.env")
env.dev     = true
env.debug   = true
-- Per-hook opt-in for the hooks that write into a real save. Uncomment deliberately, on a
-- throwaway save — pal-skills-equip is the one whose single run so far was followed 1.4
-- seconds later by Palworld closing.
-- env.debugHooks["pal-skills-equip"] = true
LUA
fi

# The swap. Two renames, so the only moment Scripts/ does not exist is between them.
[ -d "$DEST/Scripts" ] && mv "$DEST/Scripts" "$OLD"
mv "$STAGE" "$DEST/Scripts"
rm -rf "$OLD"

# RELEASE: hunt down any overlay left behind by an earlier dev deploy. The swap above already
# replaced Scripts/ wholesale, so the normal case finds nothing; this exists for the copy that
# was placed by hand, or written into a path this script does not own. Each deletion is printed
# by name — a file that arms F4 disappearing silently is not a thing to do quietly.
if [ "$MODE" = "release" ]; then
    while IFS= read -r stale; do
        rm -f "$stale"
        echo "removed stale dev overlay: $stale"
    done < <(find "$DEST" -name 'palforge_dev.lua' -type f 2>/dev/null || true)
fi

# UE4SS starts a mod only when this file is present.
: > "$DEST/enabled.txt"

files=$(find "$DEST/Scripts" -type f | wc -l)
echo "deployed $files file(s) in $MODE mode"

if [ "$MODE" = "dev" ]; then
    echo "wrote Scripts/palforge_dev.lua (env.dev = true, env.debug = true)"
    echo
    echo "keys once the game is running:"
    echo "  F1  run the API test suite        F5  reflection probe"
    echo "  F9  reload without restarting     F6/F8  the other probes"
    echo "  F4  UNLOCK ALL TECHNOLOGIES       F2/F3/F10  the UI probes"
else
    echo "no dev overlay written: env.dev stays false, so F1-F10 (including F4, unlock all"
    echo "technologies), the F9 reload, ps_catalog and both test bundles all stay off."
    echo "The startup line in UE4SS.log will read dev=false debug=false."
fi
