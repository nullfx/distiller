#!/usr/bin/env bash
# Prints the version the next release gets: major.minor.revision.
#
# The major.minor is the newer of VERSION's and the newest release tag's, so a release made with
# a new major or minor (from the Release run's Major and Minor fields) carries on without editing
# VERSION. --major and --minor choose one for this release instead: a changed major starts the
# minor at 0 unless --minor is given too; a major.minor older than one already released is refused.
# The revision is one past the newest released v<major>.<minor>.<revision> tag; until that
# major.minor has a release, it's VERSION's own revision when VERSION names the same major.minor
# (normally 0), else 0.
#
# Usage: Scripts/next-version.sh [--major <n>] [--minor <n>]                 reads the tags on origin
#        Scripts/next-version.sh --tags-file <file> [--major <n>] [--minor <n>]   tag names (v1.0.3), one per line
# VERSION_FILE overrides the VERSION file's path (for tests). With --explain, a description of
# where the version came from goes to standard error.
set -euo pipefail
cd "$(dirname "$0")/.."

tags_file="" want_major="" want_minor="" explain=false
while (( $# )); do
  case "$1" in
    --tags-file) tags_file="$2"; shift 2 ;;
    --major) want_major="$2"; shift 2 ;;
    --minor) want_minor="$2"; shift 2 ;;
    --explain) explain=true; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
for value in "$want_major" "$want_minor"; do
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "'$value' isn't a whole number; Major and Minor take numbers such as 1 or 2." >&2
    exit 1
  fi
done

base="$(tr -d '[:space:]' < "${VERSION_FILE:-VERSION}")"
if [[ ! "$base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION holds '$base'; it should be major.minor.revision, such as 1.0.0." >&2
  exit 1
fi
file_major=$((10#${BASH_REMATCH[1]})); file_minor=$((10#${BASH_REMATCH[2]})); file_revision=$((10#${BASH_REMATCH[3]}))

if [[ -n "$tags_file" ]]; then
  tags="$(cat "$tags_file")"
else
  tags="$(git ls-remote --tags --refs origin 'v*' | sed 's#.*refs/tags/##')"
fi

# The newest released major.minor.
tag_major=-1 tag_minor=-1
while IFS= read -r tag; do
  if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    if (( a > tag_major || (a == tag_major && b > tag_minor) )); then tag_major=$a tag_minor=$b; fi
  fi
done <<< "$tags"

newer() { (( $1 > $3 || ($1 == $3 && $2 > $4) )); }

if [[ -n "$want_major" || -n "$want_minor" ]]; then
  # Start from whichever is current (file or releases), then apply the fields.
  major=$file_major minor=$file_minor
  if newer "$tag_major" "$tag_minor" "$major" "$minor"; then major=$tag_major minor=$tag_minor; fi
  if [[ -n "$want_major" ]]; then
    new_major=$((10#$want_major))
    if (( new_major != major )) && [[ -z "$want_minor" ]]; then minor=0; fi
    major=$new_major
  fi
  if [[ -n "$want_minor" ]]; then minor=$((10#$want_minor)); fi
  if newer "$tag_major" "$tag_minor" "$major" "$minor"; then
    echo "Can't release $major.$minor: $tag_major.$tag_minor is already released. Choose $tag_major.$tag_minor or later." >&2
    exit 1
  fi
  source="the Major and Minor fields"
elif newer "$tag_major" "$tag_minor" "$file_major" "$file_minor"; then
  major=$tag_major minor=$tag_minor source="the newest release (VERSION says $file_major.$file_minor)"
else
  major=$file_major minor=$file_minor source="VERSION"
fi

# The revision: VERSION's when it names this major.minor, else 0; then one past the newest release.
next=0
if (( major == file_major && minor == file_minor )); then next=$file_revision; fi
while IFS= read -r tag; do
  if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
     && (( 10#${BASH_REMATCH[1]} == major && 10#${BASH_REMATCH[2]} == minor )); then
    released=$((10#${BASH_REMATCH[3]}))
    if (( released + 1 > next )); then next=$((released + 1)); fi
  fi
done <<< "$tags"

if $explain; then echo "major.minor from $source" >&2; fi
echo "$major.$minor.$next"
