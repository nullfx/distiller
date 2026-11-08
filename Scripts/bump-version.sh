#!/usr/bin/env bash
# Changes VERSION, the single source of Distiller's version. Merging the change to main
# releases it (.github/workflows/release.yml tags v<version> and builds, after approval).
# Usage: Scripts/bump-version.sh patch|minor|major      0.1.0 → 0.1.1 | 0.2.0 | 1.0.0
#        Scripts/bump-version.sh 0.2.0-beta.1           an exact version (a suffix makes a pre-release)
set -euo pipefail
cd "$(dirname "$0")/.."

current="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.]+)?$ ]]; then
  echo "VERSION holds '$current', which isn't a version like 1.2.3 or 1.2.3-beta.1." >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"; suffix="${BASH_REMATCH[4]}"

case "${1:-}" in
  # A pre-release (1.2.0-beta.1) bumps to its own final version (1.2.0) for "patch".
  patch) next=$([[ -n "$suffix" ]] && echo "$major.$minor.$patch" || echo "$major.$minor.$((patch + 1))") ;;
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
  "") echo "Usage: Scripts/bump-version.sh patch|minor|major|<version>" >&2; exit 1 ;;
  *)
    next="$1"
    if [[ ! "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
      echo "'$next' isn't a version like 1.2.3 or 1.2.3-beta.1." >&2
      exit 1
    fi
    ;;
esac

printf '%s\n' "$next" > VERSION
echo "VERSION: $current → $next. Commit it in a pull request; merging it releases v$next."
