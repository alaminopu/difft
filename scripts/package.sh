#!/bin/bash
# Package Difft as a standalone macOS app bundle.
# Usage: scripts/package.sh [output-dir] [version]   (default: ./dist, 0.0.0-dev)
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="${1:-dist}"
# The bundle used to hardcode 1.0, so every release since 0.1.0 reported the
# wrong version in About Difft and to anything reading the plist.
VERSION="${2:-0.0.0-dev}"
APP="$OUT/Difft.app"

# Force a relink: SwiftPM sometimes rebuilds modules without relinking the
# executable (see memory: difft-build-pitfall).
rm -f .build/arm64-apple-macosx/release/Difft
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Difft "$APP/Contents/MacOS/Difft"
# Highlightr's syntax themes. The vendored copy looks here first — SwiftPM's
# own Bundle.module cannot, and macOS will not sign a bundle with anything
# loose at its root. See Vendor/Highlightr/PATCH.md.
cp -R .build/release/Highlightr_Highlightr.bundle "$APP/Contents/Resources/"
# The bundled code font (JetBrains Mono NL). CodeFont walks Contents/Resources
# for it, for the same reason Highlightr does.
cp -R .build/release/Difft_DifftUI.bundle "$APP/Contents/Resources/"

# App icon: rendered by scripts/make-icon.swift, packed into an .icns.
ICONSET="$OUT/Difft.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png" 1024
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz * 2))
  sips -z $dbl $dbl "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Difft.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Difft</string>
    <key>CFBundleIdentifier</key><string>dev.alaminopu.difft</string>
    <key>CFBundleName</key><string>Difft</string>
    <key>CFBundleDisplayName</key><string>Difft</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Difft</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
PLIST

# Sign with an Apple-issued identity when the keychain has one, preferring a
# Developer ID (the only kind Gatekeeper accepts on other people's Macs) over
# Apple Development. Picked by hash, not name: a renewed certificate keeps its
# name, so the expired one beside it makes the name ambiguous to codesign.
# Set DIFFT_SIGN_IDENTITY to choose one, or to "-" to force ad-hoc.
IDENTITY="${DIFFT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning)"
  for kind in "Developer ID Application" "Apple Development"; do
    IDENTITY="$(echo "$IDENTITIES" | awk -v kind="\"$kind:" 'index($0, kind) { print $2; exit }')"
    [ -n "$IDENTITY" ] && break
  done
fi

# Highlightr runs highlight.js in JavaScriptCore, which only gets its JIT with
# this entitlement, however the app is signed. A regex-heavy script measured
# 0.11s with it and 1.9s without.
ENTITLEMENTS="scripts/Difft.entitlements"

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  # Hardened runtime and a secure timestamp are what notarization asks for,
  # and cost nothing when the certificate cannot be notarized.
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
else
  # Ad-hoc signature so Gatekeeper runs it locally without complaints.
  IDENTITY="ad-hoc"
  codesign --force --deep --entitlements "$ENTITLEMENTS" -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "Packaged: $APP ($VERSION)"
echo "Signed:   $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 | grep . || echo "$IDENTITY")"
echo "Install:  cp -R $APP /Applications/"
