#!/usr/bin/env bash
#
# Regenerates Chorus/Resources/hagezi-light.json from a pinned HaGezi "Light"
# release, using AdGuard's SafariConverterLib to convert the AdGuard-syntax
# filter list into the WKContentRuleList JSON the app compiles at launch.
#
# IMPORTANT: SafariConverterLib is GPLv3. It is used here ONLY as an offline
# build tool — its JSON *output* is bundled, the library is never linked into
# the app. Do NOT add it as a Swift Package dependency in project.yml, or Chorus
# (MIT) becomes a GPL derivative. See the content-blocker design notes.
#
# Run this when bumping the bundled blocklist, then commit the regenerated JSON.
# Pin the refs below for reproducible builds; bump them deliberately.

set -euo pipefail

HAGEZI_REF="${HAGEZI_REF:-37522026.190.70475}"   # HaGezi release tag
CONVERTER_REF="${CONVERTER_REF:-v4.3.0}"          # SafariConverterLib tag
SAFARI_VERSION="${SAFARI_VERSION:-14}"            # matches app deployment target
CAP=150000                                        # WKContentRuleList per-list rule cap

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Chorus/Resources/hagezi-light.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading HaGezi Light @ ${HAGEZI_REF}"
curl -fsSL "https://raw.githubusercontent.com/hagezi/dns-blocklists/${HAGEZI_REF}/adblock/light.txt" \
  -o "$WORK/light.txt"
RULE_LINES=$(grep -c '^||' "$WORK/light.txt" || true)
echo "    ${RULE_LINES} filter rules downloaded"

echo "==> Building SafariConverterLib ConverterTool @ ${CONVERTER_REF} (build-only, GPLv3)"
git clone --quiet --depth 1 --branch "$CONVERTER_REF" \
  https://github.com/AdguardTeam/SafariConverterLib "$WORK/scl"
( cd "$WORK/scl" && swift build -c release --product ConverterTool )
TOOL="$WORK/scl/.build/release/ConverterTool"

echo "==> Converting to WKContentRuleList JSON"
# The `convert` subcommand writes the Safari content-blocking rule array
# directly to the given path (a JSON array of trigger/action rules).
"$TOOL" convert \
  --safari-version "$SAFARI_VERSION" \
  --advanced-blocking false \
  --input-path "$WORK/light.txt" \
  --safari-rules-json-path "$WORK/rules.json"

# Validate it's a non-empty JSON array before writing, and guard the rule count.
jq -e 'type == "array" and length > 0' "$WORK/rules.json" > /dev/null \
  || { echo "ERROR: converter produced no rules — refusing to write an empty blocklist" >&2; exit 1; }
CONVERTED=$(jq 'length' "$WORK/rules.json")
echo "    ${CONVERTED} rules converted"
if [ "$CONVERTED" -gt "$CAP" ]; then
  echo "NOTE: ${CONVERTED} rules exceeds the ${CAP} per-list cap; the app splits into chunks at runtime."
fi

cp "$WORK/rules.json" "$OUT"
echo "==> Wrote $OUT (${CONVERTED} rules)"
echo "    Remember to commit the regenerated JSON."
