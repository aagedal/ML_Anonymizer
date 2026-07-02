#!/bin/sh
# Installs the built OpenFX plugin into the shared OFX plugin folder.
# DaVinci Resolve scans this folder at launch; restart Resolve after installing.
# Usage: install_ofx.sh [build_dir]     (default: build)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
. "$BUILD/edition.sh"

BUNDLE="$BUILD/$BUNDLE_BASE.ofx.bundle"
DEST="/Library/OFX/Plugins"

if [ ! -d "$BUNDLE" ]; then
	echo "Build the plugin first: cmake -B build && cmake --build build" >&2
	exit 1
fi

echo "Installing to $DEST (may prompt for your password)"
sudo mkdir -p "$DEST"
sudo rm -rf "$DEST/$BUNDLE_BASE.ofx.bundle"
sudo cp -R "$BUNDLE" "$DEST/"
echo "Installed. Restart DaVinci Resolve."
