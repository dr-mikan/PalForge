#!/usr/bin/env bash
# Copy this working tree into a Palworld install so the game runs what you just edited.
#
#   tools/deploy.sh                       # the default install below
#   tools/deploy.sh "/path/to/Palworld"   # somewhere else
#
# The mod folder is REPLACED, not merged: a file you deleted here has to disappear there too,
# or the game keeps loading it. deprecated/ and tmp/ are reference-only and are left behind.
#
# Lua is read at mod load, so a fresh deploy needs a game restart the first time. After that,
# deploy again and press F9 in game — the framework reloads without a restart.
set -euo pipefail

GAME="${1:-/mnt/e/SteamLibrary/steamapps/common/Palworld}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$GAME/Pal/Binaries/Win64/ue4ss/Mods/PalForge"

[ -d "$SRC/Scripts/palforge" ] || { echo "not a PalForge tree: $SRC" >&2; exit 1; }
[ -d "$GAME/Pal/Binaries/Win64/ue4ss/Mods" ] || {
    echo "no UE4SS Mods directory under $GAME" >&2; exit 1; }

echo "source: $SRC/Scripts"
echo "target: $DEST/Scripts"

rm -rf "$DEST/Scripts"
mkdir -p "$DEST/Scripts"

# Everything the mod needs at runtime. tests/ stays: the kernel runs it at startup in dev.
cp -r "$SRC/Scripts/main.lua" "$DEST/Scripts/main.lua"
cp -r "$SRC/Scripts/palforge" "$DEST/Scripts/palforge"
rm -rf "$DEST/Scripts/palforge/deprecated" "$DEST/Scripts/palforge/tmp"

# UE4SS starts a mod only when this file is present.
: > "$DEST/enabled.txt"

files=$(find "$DEST/Scripts" -type f | wc -l)
echo "deployed $files file(s)"
echo
echo "keys once the game is running:"
echo "  F1  run the API test suite        F5  reflection probe"
echo "  F9  reload without restarting     F6/F7/F8  the other probes"
