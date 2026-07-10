#!/usr/bin/env bash
#
# Vendors the Dark Reader standalone API build (darkreader.js) into the app
# bundle. Dark Reader is MIT-licensed, so unlike the GPLv3 blocklist converter
# this artifact is bundled and executed directly — MIT permits that. Keep the
# copyright header in the file, and the attribution shows in the About pane.
#
# Run this to bump the bundled version, then commit the regenerated file.

set -euo pipefail

DARKREADER_REF="${DARKREADER_REF:-4.9.128}"   # pinned; bump deliberately
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Chorus/Resources/darkreader.js"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "==> Fetching Dark Reader @ ${DARKREADER_REF}"
curl -fsSL "https://cdn.jsdelivr.net/npm/darkreader@${DARKREADER_REF}/darkreader.js" -o "$TMP"

# Validate before overwriting: non-empty and actually the library.
[ -s "$TMP" ] || { echo "ERROR: downloaded file is empty" >&2; exit 1; }
grep -q "DarkReader" "$TMP" || { echo "ERROR: file doesn't look like Dark Reader" >&2; exit 1; }

cp "$TMP" "$OUT"
echo "==> Wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "    Remember to commit the regenerated file."
