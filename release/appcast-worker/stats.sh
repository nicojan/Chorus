#!/usr/bin/env bash
# How many people are running Chorus. Reads the counts the appcast Worker keeps.
#
#   ./stats.sh          last 14 days
#   ./stats.sh 60       last 60 days
#   ./stats.sh --json   raw JSON, for piping somewhere else
#
# The bearer token lives in the login Keychain under "chorus-stats-token".
# Cloudflare stores secrets write-only, so if it is gone, make a new one:
#   TOKEN=$(openssl rand -hex 24)
#   printf '%s' "$TOKEN" | npx wrangler secret put STATS_TOKEN
#   security add-generic-password -U -a "$USER" -s chorus-stats-token -w "$TOKEN"

set -euo pipefail

ENDPOINT="https://updates.nicojan.com/chorus/stats.json"
DAYS="${1:-14}"

TOKEN="$(security find-generic-password -s chorus-stats-token -w 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
  echo "No token in the Keychain under 'chorus-stats-token'. See the header of this script." >&2
  exit 1
fi

RESPONSE="$(curl -sS -H "Authorization: Bearer $TOKEN" "$ENDPOINT")"

if [ "$RESPONSE" = "Unauthorized" ]; then
  echo "The Worker rejected the token. It may have been rotated; see the header of this script." >&2
  exit 1
fi

if [ "${1:-}" = "--json" ]; then
  echo "$RESPONSE"
  exit 0
fi

DAYS="$DAYS" python3 -c '
import json, os, sys

days = json.load(sys.stdin)["days"]
limit = int(os.environ["DAYS"])
shown = days[:limit]

if not shown:
    print("No days recorded yet. Nothing has checked for an update.")
    sys.exit(0)

versions = sorted({v for d in shown for v in d["byVersion"]}, reverse=True)
width = max(9, *(len(v) for v in versions))

print()
print(f"{"Day":<12}{"Total":>6}   versions")
print("-" * 12 + "-" * 6 + "   " + "-" * 40)
for d in shown:
    split = "  ".join(f"{v} {d["byVersion"][v]}" for v in versions if v in d["byVersion"])
    mark = "  (still counting)" if d.get("partial") else ""
    print(f"{d["day"]:<12}{d["total"]:>6}   {split}{mark}")

finals = [d for d in shown if not d.get("partial")]
if finals:
    peak = max(finals, key=lambda d: d["total"])
    mean = sum(d["total"] for d in finals) / len(finals)
    print()
    print(f"{len(finals)} full days: {mean:.0f} a day on average, peak {peak["total"]} on {peak["day"]}.")
print()
print("A day counts machines that checked for an update, which is close to but not")
print("the same as people who opened the app. Accurate to within a few percent:")
print("see the caveats in README.md.")
print()
' <<<"$RESPONSE"
