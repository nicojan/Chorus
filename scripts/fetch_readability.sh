#!/usr/bin/env bash
#
# Vendors Mozilla's standalone Readability.js (Apache-2.0) into the app bundle.
# It runs entirely on the page DOM to extract article content for reader mode —
# no network, no external service. Apache-2.0 permits bundling; keep the license
# header in the file, and the attribution shows in the About pane.
#
# Run this to bump the bundled version, then commit the regenerated file.

set -euo pipefail

READABILITY_REF="${READABILITY_REF:-0.6.0}"   # pinned; bump deliberately
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Chorus/Resources/readability.js"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "==> Fetching Readability @ ${READABILITY_REF}"
curl -fsSL "https://cdn.jsdelivr.net/npm/@mozilla/readability@${READABILITY_REF}/Readability.js" -o "$TMP"

[ -s "$TMP" ] || { echo "ERROR: downloaded file is empty" >&2; exit 1; }
grep -q "function Readability" "$TMP" || { echo "ERROR: file doesn't look like Readability" >&2; exit 1; }

cp "$TMP" "$OUT"
echo "==> Wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "    Remember to commit the regenerated file."
