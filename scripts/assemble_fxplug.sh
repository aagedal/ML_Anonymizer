#!/bin/sh
# Assembles and signs the FxPlug wrapper app + XPC service bundle.
# Usage: assemble_fxplug.sh <build_dir> <source_root> <app_binary> <service_binary>
# Names and identifiers come from <build_dir>/edition.sh (written by CMake).
# Signing identity: SIGN_IDENTITY, else Developer ID, else Apple Development,
# else ad-hoc.
set -e

BUILD="$1"
SRC="$2"
APP_BIN="$3"
SVC_BIN="$4"
. "$BUILD/edition.sh"

FXPLUG_FRAMEWORKS="/Library/Developer/Frameworks"

# Prefer an explicit SIGN_IDENTITY, then Developer ID, then Apple Development,
# then ad-hoc. PluginKit ignores ad-hoc-signed extensions on most systems.
if [ -n "$SIGN_IDENTITY" ]; then
	IDENTITY="$SIGN_IDENTITY"
else
	# Use the certificate SHA-1 to avoid ambiguity between same-named certs.
	IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
	IDENTITY=$(printf '%s\n' "$IDENTITIES" | grep "Developer ID Application" | head -1 | awk '{print $2}')
	[ -n "$IDENTITY" ] || IDENTITY=$(printf '%s\n' "$IDENTITIES" | grep "Apple Development" | head -1 | awk '{print $2}')
	[ -n "$IDENTITY" ] || IDENTITY="-"
fi
echo "Signing with: $IDENTITY"

APP="$BUILD/$APP_NAME.app"
SVC="$APP/Contents/PlugIns/$APP_NAME XPC Service.pluginkit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$SVC/Contents/MacOS" \
         "$SVC/Contents/Frameworks"

# XPC service bundle
cp "$SVC_BIN" "$SVC/Contents/MacOS/$APP_NAME XPC Service"
cp "$BUILD/fcp-plists/Info-Service.plist" "$SVC/Contents/Info.plist"
cp "$BUILD/fcp-plists/version.plist" "$SVC/Contents/version.plist"
mkdir -p "$SVC/Contents/Resources/en.lproj"
cp "$SRC/fcp/locversion.plist" "$SVC/Contents/Resources/en.lproj/locversion.plist"

# Embed the FxPlug runtime frameworks into the service (template pattern).
for FW in FxPlug PluginManager; do
	rsync --archive --links --whole-file --no-owner --no-group \
		--exclude='Headers' --exclude='Modules' \
		"$FXPLUG_FRAMEWORKS/$FW.framework/" "$SVC/Contents/Frameworks/$FW.framework/"
	codesign --force --sign "$IDENTITY" "$SVC/Contents/Frameworks/$FW.framework"
done

# Wrapper app
cp "$APP_BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD/fcp-plists/Info-App.plist" "$APP/Contents/Info.plist"

# Bundle the Motion templates for this edition; the app installs them into
# the user's ~/Movies/Motion Templates on first launch (FCP only shows
# FxPlug effects through a Motion template).
if [ -d "$SRC/fcp/templates/$EDITION/Effects" ]; then
	mkdir -p "$APP/Contents/Resources/Motion Templates"
	cp -R "$SRC/fcp/templates/$EDITION/Effects" "$APP/Contents/Resources/Motion Templates/"
	# Motion-authored files can carry Finder info / resource forks, which
	# codesign rejects ("detritus not allowed").
	xattr -rc "$APP/Contents/Resources/Motion Templates" 2>/dev/null || true
else
	echo "warning: no Motion templates at fcp/templates/$EDITION/Effects" >&2
fi

# Sign inside-out. Both the service and the app are sandboxed - PluginKit
# refuses to register extensions that are not (compare Apple's own
# InternalFiltersXPC.pluginkit inside Final Cut Pro).
codesign --force --sign "$IDENTITY" \
	--entitlements "$SRC/fcp/Sandbox.entitlements" "$SVC"
# The app additionally gets ~/Movies access for Motion template installation.
codesign --force --sign "$IDENTITY" \
	--entitlements "$SRC/fcp/SandboxApp.entitlements" "$APP"

echo "Assembled $APP"
