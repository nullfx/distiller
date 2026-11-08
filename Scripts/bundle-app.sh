#!/usr/bin/env bash
# Wraps the SwiftPM build of DistillerApp into dist/Distiller.app, signed for local use.
# Usage: Scripts/bundle-app.sh [debug|release]
#
# Signing: macOS ties privacy permissions (Screen Recording for community-check screenshots)
# to the app's signature. An ad-hoc signature changes with every build, so permissions given
# to one build don't apply to the next. The script therefore signs with a real identity:
# DISTILLER_SIGN_IDENTITY (a name or SHA-1 from `security find-identity -v -p codesigning`),
# else the first "Apple Development" identity in the keychain, else ad hoc as a last resort.
#
# Release builds (.github/workflows/release.yml) also set:
#   DISTILLER_VERSION   CFBundleShortVersionString (default 0.1.0)
#   DISTILLER_BUILD     CFBundleVersion (default 1)
#   DISTILLER_OUT       the folder for Distiller.app (default dist)
#   DISTILLER_HARDENED=1  sign with the hardened runtime and a secure timestamp, as
#                         notarization requires (needs a Developer ID identity and network).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="${DISTILLER_VERSION:-0.1.0}"
BUILD="${DISTILLER_BUILD:-1}"
swift build -c "$CONFIG" --product DistillerApp
swift build -c "$CONFIG" --product distiller
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="${DISTILLER_OUT:-dist}/Distiller.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/DistillerApp" "$APP/Contents/MacOS/Distiller"
cp "$BIN/distiller" "$APP/Contents/Helpers/distiller"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# App icon, made from Design/AppIcon.svg by Scripts/make-icon.sh.
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Distiller</string>
  <key>CFBundleDisplayName</key><string>Distiller</string>
  <key>CFBundleIdentifier</key><string>com.nullfx.distiller</string>
  <key>CFBundleExecutable</key><string>Distiller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Distiller catalogue link</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>distiller</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

IDENTITY="${DISTILLER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # By SHA-1, since a keychain can hold several certificates with the same name.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')"
fi
# Inside out: the helper command first, then the app, whose signature seals it.
sign() {
  local options=(--force --sign "$1")
  if [ "${DISTILLER_HARDENED:-0}" = "1" ]; then options+=(--options runtime --timestamp); fi
  codesign "${options[@]}" --identifier com.nullfx.distiller.cli "$APP/Contents/Helpers/distiller"
  codesign "${options[@]}" "$APP"
}
if [ -n "$IDENTITY" ]; then
  sign "$IDENTITY"
  echo "Signed with $(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1) (permissions such as Screen Recording carry over between builds)"
else
  if [ "${DISTILLER_HARDENED:-0}" = "1" ]; then
    echo "DISTILLER_HARDENED=1 needs a signing identity (Developer ID Application)." >&2
    exit 1
  fi
  sign -
  echo "No signing identity found: signed ad hoc, so macOS may ask for Screen Recording again after each build."
fi
echo "Built $APP ($VERSION, build $BUILD)"
