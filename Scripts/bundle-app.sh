#!/usr/bin/env bash
# Wraps the SwiftPM build of DistillerApp into dist/Distiller.app, signed for local use.
# Usage: Scripts/bundle-app.sh [debug|release]
#
# Signing: macOS ties privacy permissions (Screen Recording for community-check screenshots)
# to the app's signature. An ad-hoc signature changes with every build, so permissions given
# to one build don't apply to the next. The script therefore signs with a real identity:
# DISTILLER_SIGN_IDENTITY (a name or SHA-1 from `security find-identity -v -p codesigning`),
# else the first "Apple Development" identity in the keychain, else ad hoc as a last resort.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product DistillerApp
swift build -c "$CONFIG" --product distiller
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/Distiller.app"
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
  <key>CFBundleIdentifier</key><string>com.example.distiller</string>
  <key>CFBundleExecutable</key><string>Distiller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${DISTILLER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # By SHA-1, since a keychain can hold several certificates with the same name.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with $(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1) (permissions such as Screen Recording carry over between builds)"
else
  codesign --force --deep --sign - "$APP"
  echo "No signing identity found: signed ad hoc, so macOS may ask for Screen Recording again after each build."
fi
echo "Built $APP"
