#!/bin/sh
# Builds a macOS installer package (.pkg) containing the Premiere Pro,
# DaVinci Resolve (OFX), and Final Cut Pro (FxPlug) plugins.
#
# Usage: make_pkg.sh [build_dir]     (default: build)
# Names and identifiers come from <build_dir>/edition.sh, written by CMake
# according to -DANON_EDITION (see editions/*.cmake).
#
# Signing / notarization for distribution outside your own machine:
#   - Payload binaries are signed with the first "Developer ID Application"
#     identity in the keychain (override: APP_SIGN_IDENTITY), hardened
#     runtime + timestamp, as notarization requires.
#   - The pkg is signed with the first "Developer ID Installer" identity
#     (override: SIGN_IDENTITY). Without one, the pkg is unsigned and
#     Gatekeeper flags it when downloaded.
#   - Set NOTARY_PROFILE=<profile> to submit the signed pkg to Apple notary
#     service and staple the ticket. One-time setup:
#       xcrun notarytool store-credentials <profile> \
#           --apple-id <you@example.com> --team-id <TEAMID>
#     (password: an app-specific password from account.apple.com)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
BUILD="$(cd "$BUILD" && pwd)"
. "$BUILD/edition.sh"

PLUGIN="$BUILD/$BUNDLE_BASE.plugin"
OFX_BUNDLE="$BUILD/$BUNDLE_BASE.ofx.bundle"
FCP_APP="$BUILD/$APP_NAME.app"
PS_PLUGIN="$BUILD/${BUNDLE_BASE}PS.plugin"
INSTALL_LOCATION="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"
OFX_INSTALL_LOCATION="/Library/OFX/Plugins"
PS_INSTALL_LOCATION="/Library/Application Support/Adobe/Plug-Ins/CC"
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
if [ -d "$PS_PLUGIN" ]; then
	mkdir -p "$PKGROOT/payload-ps"
	cp -R "$PS_PLUGIN" "$PKGROOT/payload-ps/"
	if [ -f "$BUILD/${BUNDLE_BASE}Action.atn" ]; then
		cp "$BUILD/${BUNDLE_BASE}Action.atn" "$PKGROOT/payload-ps/"
	fi
fi
# Strip removable extended attributes (quarantine, Finder info). The
# SIP-managed com.apple.provenance attribute survives this and shows up as
# AppleDouble (._*) entries inside the package payload - that is harmless:
# Installer restores it as an invisible xattr, no ._ files land on disk.
xattr -rc "$PKGROOT/payload" "$PKGROOT/payload-ofx" "$PKGROOT/payload-fcp" "$PKGROOT/payload-ps" 2>/dev/null || true

# Developer ID-sign the Premiere and OFX payload bundles (the FxPlug app is
# already signed inside-out by assemble_fxplug.sh at build time). Hardened
# runtime + secure timestamp are notarization requirements.
if [ -z "$APP_SIGN_IDENTITY" ]; then
	APP_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
		| grep "Developer ID Application" | head -1 | awk '{print $2}')
fi
if [ -n "$APP_SIGN_IDENTITY" ]; then
	echo "Signing payload binaries with: $APP_SIGN_IDENTITY"
	codesign --force --options runtime --timestamp \
		--sign "$APP_SIGN_IDENTITY" "$PKGROOT/payload/$BUNDLE_BASE.plugin"
	codesign --force --options runtime --timestamp \
		--sign "$APP_SIGN_IDENTITY" "$PKGROOT/payload-ofx/$BUNDLE_BASE.ofx.bundle"
	if [ -d "$PKGROOT/payload-ps/${BUNDLE_BASE}PS.plugin" ]; then
		codesign --force --options runtime --timestamp \
			--sign "$APP_SIGN_IDENTITY" "$PKGROOT/payload-ps/${BUNDLE_BASE}PS.plugin"
	fi
else
	echo "warning: no Developer ID Application identity - payload binaries keep their build signatures" >&2
fi

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

PS_CHOICE_OUTLINE=""
PS_CHOICE=""
PS_PKGREF=""
if [ -d "$PKGROOT/payload-ps" ]; then
	PS_SCRIPTS="$PKGROOT/scripts-ps"
	mkdir -p "$PS_SCRIPTS"
	cat > "$PS_SCRIPTS/preinstall" <<PREINST
#!/bin/sh
rm -rf "${PS_INSTALL_LOCATION}/${BUNDLE_BASE}PS.plugin"
exit 0
PREINST
	chmod +x "$PS_SCRIPTS/preinstall"
	# Copy the bundled action into every installed Photoshop's Presets/Actions
	# folder (visible in the Classic Actions panel's flyout menu), then open
	# the .atn once as the logged-in user: that imports it straight into the
	# user's Actions palette, which is the only route the new (non-classic)
	# Actions panel offers besides a manual Import Actions...
	cat > "$PS_SCRIPTS/postinstall" <<POSTINSTALL
#!/bin/sh
for _presets in "/Applications/Adobe Photoshop "*/Presets/Actions; do
	[ -d "\$_presets" ] || continue
	cp -f "${PS_INSTALL_LOCATION}/${BUNDLE_BASE}Action.atn" "\$_presets/" 2>/dev/null || true
done
if ls -d "/Applications/Adobe Photoshop "* >/dev/null 2>&1; then
	LOGGED_IN_USER=\$(stat -f "%Su" /dev/console 2>/dev/null)
	if [ -n "\$LOGGED_IN_USER" ] && [ "\$LOGGED_IN_USER" != "root" ]; then
		sudo -u "\$LOGGED_IN_USER" /usr/bin/open "${PS_INSTALL_LOCATION}/${BUNDLE_BASE}Action.atn" 2>/dev/null || true
	fi
fi
exit 0
POSTINSTALL
	chmod +x "$PS_SCRIPTS/postinstall"
	build_component "$PKGROOT/payload-ps" "$PS_INSTALL_LOCATION" "$ID_PS" "$PKGROOT/component-ps.pkg" "$PS_SCRIPTS"
	PS_CHOICE_OUTLINE='<line choice="photoshop"/>'
	PS_CHOICE='<choice id="photoshop" title="Photoshop plugin"
		description="Installs '$BUNDLE_BASE'PS.plugin into the shared Creative Cloud plugin folder (all Photoshop versions), plus a ready-made action (mask-based selective anonymization) that is imported into Photoshop automatically at the end of installation.">
		<pkg-ref id="'$ID_PS'"/>
	</choice>'
	PS_PKGREF='<pkg-ref id="'$ID_PS'" version="'$VERSION'" onConclusion="none">component-ps.pkg</pkg-ref>'
fi

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
		$PS_CHOICE_OUTLINE
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
	$PS_CHOICE
	$FCP_CHOICE
	<pkg-ref id="$ID_PREMIERE" version="$VERSION" onConclusion="none">component-premiere.pkg</pkg-ref>
	<pkg-ref id="$ID_OFX" version="$VERSION" onConclusion="none">component-ofx.pkg</pkg-ref>
	$PS_PKGREF
	$FCP_PKGREF
</installer-gui-script>
XML

if [ -z "$SIGN_IDENTITY" ]; then
	SIGN_IDENTITY=$(security find-identity -v 2>/dev/null \
		| grep "Developer ID Installer" | head -1 | awk '{print $2}')
fi
if [ -n "$SIGN_IDENTITY" ]; then
	productbuild \
		--distribution "$PKGROOT/distribution.xml" \
		--package-path "$PKGROOT" \
		--sign "$SIGN_IDENTITY" \
		"$OUT"
else
	echo "warning: no Developer ID Installer identity - building UNSIGNED pkg" >&2
	productbuild \
		--distribution "$PKGROOT/distribution.xml" \
		--package-path "$PKGROOT" \
		"$OUT"
fi

rm -rf "$PKGROOT"
echo "Created $OUT"

# Notarize + staple so Gatekeeper accepts the pkg offline on first launch.
if [ -n "$NOTARY_PROFILE" ]; then
	if [ -z "$SIGN_IDENTITY" ]; then
		echo "error: refusing to notarize an unsigned pkg" >&2
		exit 1
	fi
	echo "Submitting to Apple notary service (waits for the verdict)..."
	xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$OUT"
	echo "Notarized and stapled $OUT"
fi
