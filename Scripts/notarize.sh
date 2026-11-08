#!/usr/bin/env bash
# Submits a file (.zip, .dmg or .pkg) to Apple's notary service and waits for the verdict.
# Prints Apple's log and fails if it isn't accepted.
# Usage: Scripts/notarize.sh <file>
# Needs NOTARY_KEY (path to an App Store Connect API key .p8), KEY_ID and ISSUER_ID.
set -euo pipefail

FILE="$1"
: "${NOTARY_KEY:?path to the API key (.p8)}" "${KEY_ID:?the API key ID}" "${ISSUER_ID:?the issuer ID}"
auth=(--key "$NOTARY_KEY" --key-id "$KEY_ID" --issuer "$ISSUER_ID")

result="$(mktemp)"
trap 'rm -f "$result"' EXIT
echo "Submitting $(basename "$FILE") for notarization…"
xcrun notarytool submit "$FILE" "${auth[@]}" --wait --timeout 45m --output-format json > "$result" || true
cat "$result"; echo

id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
if [[ -n "$id" ]]; then
  # The log lists every problem, and any warnings even when accepted.
  xcrun notarytool log "$id" "${auth[@]}" || true
fi
if [[ "$status" != "Accepted" ]]; then
  echo "Notarization of $(basename "$FILE") ended with status: ${status:-unknown}" >&2
  exit 1
fi
echo "Notarized $(basename "$FILE")."
