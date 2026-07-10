#!/usr/bin/env bash
#
# Regenerates the bundled content-blocking lists from pinned upstream sources,
# using AdGuard's SafariConverterLib to convert filter lists into the
# WKContentRuleList JSON the app compiles at launch:
#   - Chorus/Resources/hagezi-light.json   (HaGezi "Light" ad/tracker domains)
#   - Chorus/Resources/fanboy-annoyance.json (Fanboy annoyances, from EasyList)
#
# IMPORTANT: SafariConverterLib is GPLv3. It is used here ONLY as an offline
# build tool — its JSON *output* is bundled, the library is never linked into
# the app. Do NOT add it as a Swift Package dependency in project.yml, or Chorus
# (MIT) becomes a GPL derivative. See the content-blocker design notes.
#
# Run this to bump the bundled lists, then commit the regenerated JSON.
# Pin the refs below for reproducible builds; bump them deliberately.

set -euo pipefail

HAGEZI_REF="${HAGEZI_REF:-37522026.190.70475}"   # HaGezi release tag
CONVERTER_REF="${CONVERTER_REF:-v4.3.0}"          # SafariConverterLib tag
SAFARI_VERSION="${SAFARI_VERSION:-14}"            # matches app deployment target
CAP=150000                                        # WKContentRuleList per-list rule cap

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building SafariConverterLib ConverterTool @ ${CONVERTER_REF} (build-only, GPLv3)"
git clone --quiet --depth 1 --branch "$CONVERTER_REF" \
  https://github.com/AdguardTeam/SafariConverterLib "$WORK/scl"
( cd "$WORK/scl" && swift build -c release --product ConverterTool )
TOOL="$WORK/scl/.build/release/ConverterTool"

# convert <url> <output-path> <label>
convert() {
  local url="$1" out="$2" label="$3"
  echo "==> Downloading ${label}"
  curl -fsSL "$url" -o "$WORK/src.txt"
  echo "==> Converting ${label} to WKContentRuleList JSON"
  "$TOOL" convert \
    --safari-version "$SAFARI_VERSION" \
    --advanced-blocking false \
    --input-path "$WORK/src.txt" \
    --safari-rules-json-path "$WORK/rules.json"
  jq -e 'type == "array" and length > 0' "$WORK/rules.json" > /dev/null \
    || { echo "ERROR: ${label} produced no rules — refusing to write an empty list" >&2; exit 1; }
  local n; n=$(jq 'length' "$WORK/rules.json")
  echo "    ${n} rules converted"
  if [ "$n" -gt "$CAP" ]; then
    echo "NOTE: ${n} rules exceeds the ${CAP} per-list cap; the app splits into chunks at runtime."
  fi
  cp "$WORK/rules.json" "$out"
  echo "==> Wrote $out (${n} rules)"
}

convert \
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/${HAGEZI_REF}/adblock/light.txt" \
  "$REPO_ROOT/Chorus/Resources/hagezi-light.json" \
  "HaGezi Light @ ${HAGEZI_REF}"

convert \
  "https://easylist-downloads.adblockplus.org/fanboy-annoyance.txt" \
  "$REPO_ROOT/Chorus/Resources/fanboy-annoyance.json" \
  "Fanboy Annoyance List (EasyList)"

echo "==> Done. Remember to commit the regenerated JSON."
