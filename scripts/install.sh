#!/bin/sh
# Installs the built plugin into the shared Adobe MediaCore plugin folder.
# Premiere Pro scans this folder at launch; restart Premiere after installing.
# Usage: install.sh [build_dir]     (default: build)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
. "$BUILD/edition.sh"

PLUGIN="$BUILD/$BUNDLE_BASE.plugin"
DEST="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"

if [ ! -d "$PLUGIN" ]; then
	echo "Build the plugin first: cmake -B build && cmake --build build" >&2
	exit 1
fi

echo "Installing to $DEST (may prompt for your password)"
sudo mkdir -p "$DEST"
sudo rm -rf "$DEST/$BUNDLE_BASE.plugin"
sudo cp -R "$PLUGIN" "$DEST/"
echo "Installed. Restart Premiere Pro."
