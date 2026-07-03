#!/bin/sh
# Installs the built Photoshop plugin into the shared Creative Cloud plugin
# folder, which every installed Photoshop version scans at launch.
# Usage: install_ps.sh [build_dir]     (default: build)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
. "$BUILD/edition.sh"

PLUGIN="$BUILD/${BUNDLE_BASE}PS.plugin"
DEST="/Library/Application Support/Adobe/Plug-Ins/CC"

if [ ! -d "$PLUGIN" ]; then
	echo "Build the plugin first: cmake -B build && cmake --build build" >&2
	exit 1
fi

echo "Installing to $DEST (may prompt for your password)"
sudo mkdir -p "$DEST"
sudo rm -rf "$DEST/${BUNDLE_BASE}PS.plugin"
sudo cp -R "$PLUGIN" "$DEST/"

# The bundled action: keep a canonical copy next to the plugin and offer it
# in every installed Photoshop's Actions panel flyout menu.
ACTION="$BUILD/${BUNDLE_BASE}Action.atn"
if [ -f "$ACTION" ]; then
	sudo cp -f "$ACTION" "$DEST/"
	for _presets in "/Applications/Adobe Photoshop "*/Presets/Actions; do
		[ -d "$_presets" ] || continue
		sudo cp -f "$ACTION" "$_presets/"
	done
fi
echo "Installed. Restart Photoshop."
