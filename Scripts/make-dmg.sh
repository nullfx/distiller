#!/usr/bin/env bash
# Packs an app into a compressed disk image with an Applications shortcut, for drag-to-install.
# Usage: Scripts/make-dmg.sh <path to .app> <output .dmg> [signing identity]
# With an identity, the image is signed with a secure timestamp (for notarization).
set -euo pipefail

APP="$1"
DMG="$2"
IDENTITY="${3:-}"
NAME="$(basename "$APP" .app)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# ditto keeps the app's signature, extended attributes and any stapled ticket intact.
ditto "$APP" "$STAGING/$NAME.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
echo "Made $DMG ($(du -h "$DMG" | cut -f1))"
