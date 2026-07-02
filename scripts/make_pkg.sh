#!/bin/sh
# Builds a macOS installer package (.pkg) containing the Premiere Pro,
# DaVinci Resolve (OFX), and Final Cut Pro (FxPlug) plugins.
#
# Usage: make_pkg.sh [build_dir]     (default: build)
# Names and identifiers come from <build_dir>/edition.sh, written by CMake
# according to -DANON_EDITION (see editions/*.cmake).
#
# Optional signing for distribution outside your own machine:
#   SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" ./scripts/make_pkg.sh
# (unsigned packages work locally but are flagged by Gatekeeper when downloaded)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
BUILD="$(cd "$BUILD" && pwd)"
. "$BUILD/edition.sh"

PLUGIN="$BUILD/$BUNDLE_BASE.plugin"
OFX_BUNDLE="$BUILD/$BUNDLE_BASE.ofx.bundle"
FCP_APP="$BUILD/$APP_NAME.app"
INSTALL_LOCATION="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"
OFX_INSTALL_LOCATION="/Library/OFX/Plugins"
OUT="$BUILD/$PKG_BASENAME-$VERSION.pkg"

if [ ! -d "$PLUGIN" ] || [ ! -d "$OFX_BUNDLE" ]; then
	echo "Build the plugins first: cmake --build $BUILD" >&2
	exit 1
fi

PKGROOT="$BUILD/pkg"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/payload" "$PKGROOT/payload-ofx"
cp -R "$PLUGIN" "$PKGROOT/payload/"
cp -R "$OFX_BUNDLE" "$PKGROOT/payload-ofx/"
if [ -d "$FCP_APP" ]; then
	mkdir -p "$PKGROOT/payload-fcp"
	cp -R "$FCP_APP" "$PKGROOT/payload-fcp/"
fi
# Strip removable extended attributes (quarantine, Finder info). The
# SIP-managed com.apple.provenance attribute survives this and shows up as
# AppleDouble (._*) entries inside the package payload - that is harmless:
# Installer restores it as an invisible xattr, no ._ files land on disk.
xattr -rc "$PKGROOT/payload" "$PKGROOT/payload-ofx" "$PKGROOT/payload-fcp" 2>/dev/null || true

# Component packages, one per host plugin format.
pkgbuild \
	--root "$PKGROOT/payload" \
	--install-location "$INSTALL_LOCATION" \
	--identifier "$ID_PREMIERE" \
	--version "$VERSION" \
	"$PKGROOT/component-premiere.pkg"

pkgbuild \
	--root "$PKGROOT/payload-ofx" \
	--install-location "$OFX_INSTALL_LOCATION" \
	--identifier "$ID_OFX" \
	--version "$VERSION" \
	"$PKGROOT/component-ofx.pkg"

FCP_CHOICE_OUTLINE=""
FCP_CHOICE=""
FCP_PKGREF=""
if [ -d "$FCP_APP" ]; then
	pkgbuild \
		--root "$PKGROOT/payload-fcp" \
		--install-location "/Applications" \
		--identifier "$ID_FCP" \
		--version "$VERSION" \
		"$PKGROOT/component-fcp.pkg"
	FCP_CHOICE_OUTLINE='<line choice="finalcut"/>'
	FCP_CHOICE='<choice id="finalcut" title="Final Cut Pro plugin (FxPlug)"
		description="Installs the '$APP_NAME' app into /Applications. Launch it once after installing to register the effect with Final Cut Pro and Motion.">
		<pkg-ref id="'$ID_FCP'"/>
	</choice>'
	FCP_PKGREF='<pkg-ref id="'$ID_FCP'" version="'$VERSION'" onConclusion="none">component-fcp.pkg</pkg-ref>'
fi

# Distribution package: proper title, per-host selectable choices.
cat > "$PKGROOT/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
	<title>$PKG_TITLE</title>
	<options customize="always" require-scripts="false" hostArchitectures="arm64,x86_64"/>
	<volume-check>
		<allowed-os-versions>
			<os-version min="11.0"/>
		</allowed-os-versions>
	</volume-check>
	<choices-outline>
		<line choice="premiere"/>
		<line choice="resolve"/>
		$FCP_CHOICE_OUTLINE
	</choices-outline>
	<choice id="premiere" title="Premiere Pro plugin"
		description="Installs $BUNDLE_BASE.plugin into the Adobe MediaCore folder.">
		<pkg-ref id="$ID_PREMIERE"/>
	</choice>
	<choice id="resolve" title="DaVinci Resolve plugin (OpenFX)"
		description="Installs $BUNDLE_BASE.ofx.bundle into /Library/OFX/Plugins.">
		<pkg-ref id="$ID_OFX"/>
	</choice>
	$FCP_CHOICE
	<pkg-ref id="$ID_PREMIERE" version="$VERSION" onConclusion="none">component-premiere.pkg</pkg-ref>
	<pkg-ref id="$ID_OFX" version="$VERSION" onConclusion="none">component-ofx.pkg</pkg-ref>
	$FCP_PKGREF
</installer-gui-script>
XML

if [ -n "$SIGN_IDENTITY" ]; then
	productbuild \
		--distribution "$PKGROOT/distribution.xml" \
		--package-path "$PKGROOT" \
		--sign "$SIGN_IDENTITY" \
		"$OUT"
else
	productbuild \
		--distribution "$PKGROOT/distribution.xml" \
		--package-path "$PKGROOT" \
		"$OUT"
fi

rm -rf "$PKGROOT"
echo "Created $OUT"
