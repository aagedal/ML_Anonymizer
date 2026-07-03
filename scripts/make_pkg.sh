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

# Builds one component package with bundle relocation disabled. Without
# this, macOS Installer "helpfully" installs onto any existing copy of the
# bundle Spotlight can find (e.g. a build directory) instead of the intended
# install location.
build_component() {
	_root="$1"; _location="$2"; _identifier="$3"; _out="$4"; _scripts="${5:-}"
	_plist="$PKGROOT/$(basename "$_out").components.plist"
	pkgbuild --analyze --root "$_root" "$_plist" > /dev/null
	_count=$(plutil -convert json -o - "$_plist" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
	_i=0
	while [ "$_i" -lt "$_count" ]; do
		plutil -replace "$_i.BundleIsRelocatable" -bool false "$_plist"
		_i=$((_i + 1))
	done
	if [ -n "$_scripts" ]; then
		pkgbuild \
			--root "$_root" \
			--component-plist "$_plist" \
			--install-location "$_location" \
			--identifier "$_identifier" \
			--version "$VERSION" \
			--scripts "$_scripts" \
			"$_out"
	else
		pkgbuild \
			--root "$_root" \
			--component-plist "$_plist" \
			--install-location "$_location" \
			--identifier "$_identifier" \
			--version "$VERSION" \
			"$_out"
	fi
}

# Component packages, one per host plugin format.
# Each gets a preinstall script that removes the old version first so stale
# binaries can never be loaded after an upgrade.
PREMIERE_SCRIPTS="$PKGROOT/scripts-premiere"
mkdir -p "$PREMIERE_SCRIPTS"
cat > "$PREMIERE_SCRIPTS/preinstall" <<PREINST
#!/bin/sh
rm -rf "${INSTALL_LOCATION}/${BUNDLE_BASE}.plugin"
exit 0
PREINST
chmod +x "$PREMIERE_SCRIPTS/preinstall"
build_component "$PKGROOT/payload" "$INSTALL_LOCATION" "$ID_PREMIERE" "$PKGROOT/component-premiere.pkg" "$PREMIERE_SCRIPTS"

OFX_SCRIPTS="$PKGROOT/scripts-ofx"
mkdir -p "$OFX_SCRIPTS"
cat > "$OFX_SCRIPTS/preinstall" <<PREINST
#!/bin/sh
rm -rf "${OFX_INSTALL_LOCATION}/${BUNDLE_BASE}.ofx.bundle"
exit 0
PREINST
chmod +x "$OFX_SCRIPTS/preinstall"
build_component "$PKGROOT/payload-ofx" "$OFX_INSTALL_LOCATION" "$ID_OFX" "$PKGROOT/component-ofx.pkg" "$OFX_SCRIPTS"

FCP_CHOICE_OUTLINE=""
FCP_CHOICE=""
FCP_PKGREF=""
if [ -d "$FCP_APP" ]; then
	FCP_SCRIPTS="$PKGROOT/scripts-fcp"
	mkdir -p "$FCP_SCRIPTS"
	cat > "$FCP_SCRIPTS/preinstall" <<PREINST
#!/bin/sh
rm -rf "/Applications/${APP_NAME}.app"
exit 0
PREINST
	chmod +x "$FCP_SCRIPTS/preinstall"
	cat > "$FCP_SCRIPTS/postinstall" <<POSTINSTALL
#!/bin/sh
# Launch the FxPlug app once as the logged-in user so it registers its XPC
# service and copies Motion templates to ~/Movies/Motion Templates.
LOGGED_IN_USER=\$(stat -f "%Su" /dev/console 2>/dev/null)
if [ -n "\$LOGGED_IN_USER" ] && [ "\$LOGGED_IN_USER" != "root" ]; then
	sudo -u "\$LOGGED_IN_USER" /usr/bin/open "/Applications/${APP_NAME}.app" &
fi
exit 0
POSTINSTALL
	chmod +x "$FCP_SCRIPTS/postinstall"
	build_component "$PKGROOT/payload-fcp" "/Applications" "$ID_FCP" "$PKGROOT/component-fcp.pkg" "$FCP_SCRIPTS"
	FCP_CHOICE_OUTLINE='<line choice="finalcut"/>'
	FCP_CHOICE='<choice id="finalcut" title="Final Cut Pro plugin (FxPlug)"
		description="Installs the '$APP_NAME' app into /Applications. The app launches automatically after installation to register the effect and copy the Motion template.">
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
			<os-version min="15.0"/>
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
