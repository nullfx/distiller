#!/usr/bin/env bash
# Renders Design/AppIcon.svg into Design/AppIcon.icns (every size macOS uses, 1x and 2x).
# Usage: Scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Design/AppIcon.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
render() { arch -arm64 swift Scripts/render-svg.swift "$SVG" "$ICONSET/$1" "$2" "$2"; }

for size in 16 32 128 256 512; do
  render "icon_${size}x${size}.png" "$size"
  render "icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$ICONSET" -o Design/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Design/AppIcon.icns"
