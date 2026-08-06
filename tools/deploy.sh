#!/usr/bin/env bash
# Copy this working tree into a Palworld install so the game runs what you just edited.
#
#   tools/deploy.sh                          # DEV deploy into the default install below
#   tools/deploy.sh "/path/to/Palworld"      # dev deploy somewhere else
#   tools/deploy.sh --writes-safe            # + the four hooks that only touch PalForge state
#   tools/deploy.sh --release                # what a player gets: no dev overlay, no keys
#   tools/deploy.sh --release "/path/to/Palworld"
#   tools/deploy.sh --package                # build dist/PalForge.zip — no game required
#   tools/deploy.sh --package "/some/outdir"
#
# --package is --release into a directory instead of an install, plus a zip. It is what the
# release workflow runs, so the archive people download is built by the same script that builds
# the copy this machine tests — not by a file list re-typed into YAML.
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
WRITES=0
PACKAGE=0
GAME=""
for arg in "$@"; do
    case "$arg" in
        --release) MODE="release" ;;
        --dev)     MODE="dev" ;;
        --writes)  WRITES=1 ;;
        --writes-safe) WRITES=safe ;;
        --package) MODE="release"; PACKAGE=1 ;;
        -h|--help)
            sed -n '2,36p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        -*)
            echo "unknown option: $arg (expected --release, --dev, --writes, --writes-safe, --package or a path)" >&2
            exit 2 ;;
        *)
            GAME="$arg" ;;
    esac
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$SRC/Scripts/palforge" ] || { echo "not a PalForge tree: $SRC" >&2; exit 1; }

# --package BUILDS THE SAME TREE WITHOUT A GAME. Everything below this line is shared with a
# real deploy: same copy, same drops, same --release overlay hunt, so the zip a release publishes
# is not a second definition of "what ships" that can drift from the one people actually run.
# The only differences are where DEST points and the zip step at the end.
#
# It exists because CI has no Palworld install, and because the alternative — a workflow that
# re-implements the file list in YAML — is exactly how a release starts shipping a file the
# deploy script stopped copying three commits ago.
if [ "$PACKAGE" = "1" ]; then
    OUT="${GAME:-$SRC/dist}"
    DEST="$OUT/PalForge"
    rm -rf "$DEST"
    mkdir -p "$DEST"
else
    GAME="${GAME:-/mnt/e/SteamLibrary/steamapps/common/Palworld}"
    DEST="$GAME/Pal/Binaries/Win64/ue4ss/Mods/PalForge"
    [ -d "$GAME/Pal/Binaries/Win64/ue4ss/Mods" ] || {
        echo "no UE4SS Mods directory under $GAME" >&2; exit 1; }
fi

echo "mode:   $MODE$([ "$PACKAGE" = "1" ] && echo " (package)")"
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
# Everything the mod needs at runtime. ONE test tree now: palforge/test/ holds the in-game F1
# suite (cases/), the headless boot bundle (units/), the game-required measurements (hooks/), the
# discovery dumps (probes/) and the dev instruments (tools/). There used to be two — palforge/test
# and palforge/tests, one character apart, with production code reaching into both — and this
# comment used to explain which was which. It does not have to any more.
#
# Only deprecated/ and tmp/ are dropped unconditionally below; they are reference trees nothing
# requires. palforge/test/ is dropped for --release only, a few lines further down.
cp -r "$SRC/Scripts/main.lua" "$STAGE/main.lua"
cp -r "$SRC/Scripts/palforge" "$STAGE/palforge"
rm -rf "$STAGE/palforge/deprecated" "$STAGE/palforge/tmp"

# THE TEST TREE IS NOT PART OF A RELEASE. palforge/test/ is ~50 files of suites, probes, hooks
# and dev instruments; a player runs none of them and env.dev = false means none of them is even
# required. Dropping it under --release makes that structural instead of conditional: there is no
# F1 suite to arm because the files are not there, and core/registry's single
# requireState("palforge.test") answers "absent", which its own comment names as the CORRECT
# state for a release rather than an incomplete install.
#
# It stays in a DEV deploy, where it is the whole point. Note the asymmetry with deprecated/ and
# tmp/ above: those are dropped from BOTH modes because nothing requires them in either.
if [ "$MODE" = "release" ]; then
    rm -rf "$STAGE/palforge/test"
fi

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
-- PER-HOOK OPT-IN FOR THE TEN HOOKS THAT WRITE. env.debug alone loads them and lets
-- `pf_hooks` list them; it does not let one run. Each line below is a separate decision.
--
-- ⚠️ ON A THROWAWAY SAVE. Every one of these changes something in the world or on disk, and
-- three of them cannot be undone at all: a spawned pal has no per-individual removal, an
-- unlocked technology has no lock (UPalCheatManager declares four unlock entries and no
-- reverse), and a taught active move is the one write in this tree that has ever correlated
-- with the game closing — 1.4 seconds after the only run that did it, which is why it is last.
--
-- Uncomment ONE at a time and read its block before the next, or uncomment the lot if the save
-- is genuinely disposable and you want `pf_hooks_all` to sweep them.
--
-- The four that only touch PalForge's own files under <Mods>/PalForge/state/ — they create,
-- corrupt and rewrite them on purpose — and never Palworld's save:
-- env.debugHooks["store-save-roundtrip"]        = true
-- env.debugHooks["store-crash-recovery"]        = true
-- env.debugHooks["save-survives-pack-removal"]  = true
-- env.debugHooks["building-actor-streaming"]    = true  -- publishes the ids standing near you
--
-- These change the running world or the player, and each says in its own header what it
-- restores and what it cannot:
-- env.debugHooks["mesh-color-change"]     = true   -- tints a pal, then puts the material back
-- env.debugHooks["item-satiety-write"]    = true   -- writes satiety, then the value it read
-- env.debugHooks["skill-projectile-spawn"] = true  -- fires one bullet; refuses any struct arg
-- env.debugHooks["building-unlock"]       = true   -- ⚠️ NO LOCK EXISTS. One-way.
-- env.debugHooks["pal-spawn-persisted"]   = true   -- ⚠️ the pal STAYS. No per-individual removal.
-- env.debugHooks["pal-skills-equip"]      = true   -- ⚠️ LAST. See the 1.4 s note above.
LUA
fi

# --writes: TURN ON EVERY PER-HOOK WRITE OPT-IN. The overlay above lists all ten commented out,
# one decision per line, which is right for a normal dev session. This flag is for the one session
# that is deliberately sweeping them — a throwaway save and `pf_hooks_all` — and it is a separate
# flag rather than the default precisely because three of the ten cannot be undone: a spawned pal
# has no per-individual removal, an unlocked technology has no lock, and the waza write is the one
# call in this tree that has ever correlated with the game closing.
# --writes-safe: THE FOUR THAT CANNOT REACH PALWORLD'S SAVE. store-save-roundtrip,
# store-crash-recovery, save-survives-pack-removal and building-actor-streaming create, corrupt
# and rewrite files under <Mods>/PalForge/state/ and nothing else — deleting that directory undoes
# every one of them. They are separated from --writes because the reason --writes is guarded does
# not apply to them: nothing here is irreversible, so leaving them off has a cost (a queued hook
# refuses by name and the session measures nothing) and no benefit.
if [ "$MODE" = "dev" ] && [ "$WRITES" = "safe" ]; then
    sed -i 's/^-- \(env\.debugHooks\["store-save-roundtrip"\]\)/\1/;
            s/^-- \(env\.debugHooks\["store-crash-recovery"\]\)/\1/;
            s/^-- \(env\.debugHooks\["save-survives-pack-removal"\]\)/\1/;
            s/^-- \(env\.debugHooks\["building-actor-streaming"\]\)/\1/' "$STAGE/palforge_dev.lua"
    echo "--writes-safe: the four state-only hook opt-ins are ON (store-save-roundtrip,"
    echo "               store-crash-recovery, save-survives-pack-removal, building-actor-streaming)."
    echo "               They touch <Mods>/PalForge/state/ only — never Palworld's save."
fi

if [ "$MODE" = "dev" ] && [ "$WRITES" = "1" ]; then
    sed -i 's/^-- env\.debugHooks/env.debugHooks/' "$STAGE/palforge_dev.lua"
    echo "⚠️  --writes: all ten env.debugHooks opt-ins are ON in this deploy. THROWAWAY SAVE ONLY."
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

# THE ZIP. One folder named PalForge at the root, which is what a player drags into
# ue4ss/Mods — so the archive's shape IS the install instruction and there is nothing to
# explain. LICENSE and README ride along at the root beside it, not inside the mod folder,
# where UE4SS would try to make sense of them.
#
# -X drops the extended attributes; without it, the archive built on one runner differs from
# the same tree zipped on another and "is this the build I tested" stops being answerable.
if [ "$PACKAGE" = "1" ]; then
    for extra in LICENSE README.md; do
        [ -f "$SRC/$extra" ] && cp "$SRC/$extra" "$OUT/$extra"
    done
    # No zip binary is not an error worth failing the staged tree over — the tree in $OUT is
    # complete and inspectable either way, and that is what a person checking the build wants.
    # CI has zip; a WSL shell often does not.
    if ! command -v zip >/dev/null 2>&1; then
        echo "staged $DEST — no 'zip' on PATH, so no archive was written"
        exit 0
    fi
    ZIP="$OUT/PalForge.zip"
    rm -f "$ZIP"
    (cd "$OUT" && zip -qrX "PalForge.zip" PalForge $(cd "$OUT" && ls LICENSE README.md 2>/dev/null))
    echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
    exit 0
fi

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
