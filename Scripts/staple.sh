#!/usr/bin/env bash
# Staples a notarization ticket to an app or disk image, retrying while the ticket propagates
# or the connection to Apple's ticket service drops (stapler error 68 and the like).
# Usage: Scripts/staple.sh <file> [attempts]
set -euo pipefail

FILE="$1"
ATTEMPTS="${2:-6}"
for attempt in $(seq 1 "$ATTEMPTS"); do
  if xcrun stapler staple "$FILE"; then
    xcrun stapler validate "$FILE"
    exit 0
  fi
  if [[ "$attempt" -lt "$ATTEMPTS" ]]; then
    wait=$((attempt * 20))
    echo "Stapling $(basename "$FILE") failed (attempt $attempt of $ATTEMPTS); trying again in ${wait}s." >&2
    sleep "$wait"
  fi
done
echo "Couldn't staple $(basename "$FILE") after $ATTEMPTS attempts." >&2
exit 1
