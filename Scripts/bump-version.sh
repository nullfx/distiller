#!/usr/bin/env bash
# Starts a new major or minor version by changing VERSION (the revision goes back to 0).
# Revisions aren't set here: each Release run releases the next one (Scripts/next-version.sh).
# Usage: Scripts/bump-version.sh minor     1.0.x → 1.1.0
#        Scripts/bump-version.sh major     1.4.x → 2.0.0
#        Scripts/bump-version.sh 2.1.0     an exact major.minor.revision
set -euo pipefail
cd "$(dirname "$0")/.."

current="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION holds '$current'; it should be major.minor.revision, such as 1.0.0." >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"

case "${1:-}" in
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
  patch|revision) echo "Revisions aren't set by hand: each Release run releases the next one." >&2; exit 1 ;;
  "") echo "Usage: Scripts/bump-version.sh minor|major|<major.minor.revision>" >&2; exit 1 ;;
  *)
    next="$1"
    if [[ ! "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "'$next' isn't a version like 1.2.0." >&2
      exit 1
    fi
    ;;
esac

printf '%s\n' "$next" > VERSION
echo "VERSION: $current → $next. Merge it in a pull request; the next Release run releases $next."
