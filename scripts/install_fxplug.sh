#!/bin/sh
# Installs the FxPlug wrapper app into /Applications and registers the
# plugin with PluginKit. Restart Final Cut Pro / Motion after installing.
# Usage: install_fxplug.sh [build_dir]     (default: build)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
. "$BUILD/edition.sh"

APP="$BUILD/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

if [ ! -d "$APP" ]; then
	echo "Build the plugin first: cmake -B build && cmake --build build" >&2
	exit 1
fi

rm -rf "$DEST"
cp -R "$APP" "$DEST"
# Launching the wrapper app once is what actually registers the plugin;
# pluginkit -a alone is not sufficient.
open "$DEST"
sleep 3
echo "Installed and registered. Verification:"
pluginkit -m -v -i "$ID_FCP_SERVICE" || true
echo "Restart Final Cut Pro or Motion; the effect is under Effects > $EFFECT_NAME."
