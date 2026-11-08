#!/usr/bin/env bash
# Renders Design/social-card.svg into site/assets/social-card.png, the website's link preview
# (og:image, 1200 x 630). The pictures it shows are embedded first, since rsvg-convert only
# loads images from the SVG's own folder. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - Design/social-card.svg "$work/card.svg" <<'PY'
import base64, pathlib, re, sys
source = pathlib.Path(sys.argv[1])
def inline(match):
    path = (source.parent / match.group(1)).resolve()
    return 'xlink:href="data:image/png;base64,' + base64.b64encode(path.read_bytes()).decode() + '"'
pathlib.Path(sys.argv[2]).write_text(re.sub(r'xlink:href="([^"]+\.png)"', inline, source.read_text()))
PY
rsvg-convert -w 1200 -h 630 "$work/card.svg" -o site/assets/social-card.png
echo "Wrote site/assets/social-card.png"
