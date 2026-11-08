#!/usr/bin/env bash
# Prints the version the next release gets: VERSION's major and minor, and a revision one past
# the newest released v<major>.<minor>.<revision> tag. Until that major.minor has a release, it's
# VERSION's own revision (normally 0), which is also the floor if VERSION names a higher one.
# The release tags are where revisions are kept; VERSION only changes for a new major or minor.
#
# Usage: Scripts/next-version.sh                      reads the tags on origin
#        Scripts/next-version.sh --tags-file <file>   reads tag names (v1.0.3), one per line
# VERSION_FILE overrides the VERSION file's path (for tests).
set -euo pipefail
cd "$(dirname "$0")/.."

base="$(tr -d '[:space:]' < "${VERSION_FILE:-VERSION}")"
if [[ ! "$base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION holds '$base'; it should be major.minor.revision, such as 1.0.0." >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; revision="${BASH_REMATCH[3]}"

if [[ "${1:-}" == "--tags-file" ]]; then
  tags="$(cat "$2")"
else
  tags="$(git ls-remote --tags --refs origin 'v*' | sed 's#.*refs/tags/##')"
fi

next="$revision"
while IFS= read -r tag; do
  if [[ "$tag" =~ ^v${major}\.${minor}\.([0-9]+)$ ]]; then
    released="${BASH_REMATCH[1]}"
    if (( released + 1 > next )); then next=$((released + 1)); fi
  fi
done <<< "$tags"

echo "$major.$minor.$next"
