#!/usr/bin/env bash
#
# Regenerates the bundled content-blocking lists from pinned upstream sources,
# using AdGuard's SafariConverterLib to convert filter lists into the
# WKContentRuleList JSON the app compiles at launch:
#   - ChorusEngine/Sources/ChorusEngine/Resources/hagezi-light.json   (HaGezi "Light" ad/tracker domains)
#   - ChorusEngine/Sources/ChorusEngine/Resources/fanboy-annoyance.json (Fanboy annoyances, from EasyList)
#
# IMPORTANT: SafariConverterLib is GPLv3. It is used here ONLY as an offline
# build tool — its JSON *output* is bundled, the library is never linked into
# the app. Do NOT add it as a Swift Package dependency in project.yml, or Chorus
# (MIT) becomes a GPL derivative. See the content-blocker design notes.
#
# Run this to bump the bundled lists, then commit the regenerated JSON together
# with vendor/blocklists/, which it also rewrites. That folder keeps the exact
# source text each JSON file was converted from, plus a manifest of hashes.
# HaGezi's list is GPL-3.0, so the source of the file we ship has to stay
# available; upstream deletes its release tags, and the tag the first lists
# came from is already gone. So HaGezi is pinned by commit, not by tag.

set -euo pipefail

HAGEZI_REF="${HAGEZI_REF:?set HAGEZI_REF to a hagezi/dns-blocklists commit SHA}"
HAGEZI_URL="${HAGEZI_URL:-https://raw.githubusercontent.com/hagezi/dns-blocklists/${HAGEZI_REF}/adblock/light.txt}"
FANBOY_URL="${FANBOY_URL:-https://easylist-downloads.adblockplus.org/fanboy-annoyance.txt}"
CONVERTER_REF="${CONVERTER_REF:-v4.3.0}"          # SafariConverterLib tag
SAFARI_VERSION="${SAFARI_VERSION:-14}"            # rule format; 14 is older than any Safari Chorus runs on
CAP=150000                                        # WKContentRuleList per-list rule cap

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO_ROOT/vendor/blocklists"
mkdir -p "$VENDOR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building SafariConverterLib ConverterTool @ ${CONVERTER_REF} (build-only, GPLv3)"
git clone --quiet --depth 1 --branch "$CONVERTER_REF" \
  https://github.com/AdguardTeam/SafariConverterLib "$WORK/scl"
( cd "$WORK/scl" && swift build -c release --product ConverterTool )
CONVERTER_COMMIT="$(git -C "$WORK/scl" rev-parse HEAD)"
TOOL="$WORK/scl/.build/release/ConverterTool"

# convert <url> <output-path> <label> <snapshot-name>
convert() {
  local url="$1" out="$2" label="$3" snapshot="$4"
  echo "==> Downloading ${label}"
  curl -fsSL "$url" -o "$WORK/src.txt"
  cp "$WORK/src.txt" "$VENDOR/$snapshot"
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
  "$HAGEZI_URL" \
  "$REPO_ROOT/ChorusEngine/Sources/ChorusEngine/Resources/hagezi-light.json" \
  "HaGezi Light @ ${HAGEZI_REF}" \
  "hagezi-light.txt"

convert \
  "$FANBOY_URL" \
  "$REPO_ROOT/ChorusEngine/Sources/ChorusEngine/Resources/fanboy-annoyance.json" \
  "Fanboy Annoyance List (EasyList)" \
  "fanboy-annoyance.txt"

echo "==> Writing $VENDOR/manifest.json"
REPO_ROOT="$REPO_ROOT" HAGEZI_REF="$HAGEZI_REF" CONVERTER_REF="$CONVERTER_REF" CONVERTER_COMMIT="$CONVERTER_COMMIT" \
SAFARI_VERSION="$SAFARI_VERSION" python3 - <<'PY'
import datetime, hashlib, json, os, re
root = os.environ["REPO_ROOT"]
def sha(path):
    with open(os.path.join(root, path), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()
def header(path, key):
    with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("["):
                continue
            if not line.startswith("!"):
                break
            m = re.match(r"!\s*%s:\s*(.+)" % key, line)
            if m:
                return m.group(1).strip()
    return None
lists = [
    ("hagezi-light", "https://github.com/hagezi/dns-blocklists/blob/%s/adblock/light.txt" % os.environ["HAGEZI_REF"], "GPL-3.0"),
    ("fanboy-annoyance", "https://easylist-downloads.adblockplus.org/fanboy-annoyance.txt", "CC-BY-3.0"),
]
out = []
for name, source, license_id in lists:
    src = "vendor/blocklists/%s.txt" % name
    dst = "ChorusEngine/Sources/ChorusEngine/Resources/%s.json" % name
    with open(os.path.join(root, dst)) as f:
        count = len(json.load(f))
    out.append({
        "name": name,
        "source": source,
        "source_version": header(src, "Version"),
        "source_file": src,
        "source_sha256": sha(src),
        "output_file": dst,
        "output_sha256": sha(dst),
        "rule_count": count,
        "license": license_id,
    })
manifest = {
    "retrieved": datetime.date.today().isoformat(),
    "converter": "AdguardTeam/SafariConverterLib " + os.environ["CONVERTER_REF"],
    "converter_commit": os.environ["CONVERTER_COMMIT"],
    "safari_version": os.environ["SAFARI_VERSION"],
    "advanced_blocking": False,
    "lists": out,
}
with open(os.path.join(root, "vendor/blocklists/manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "==> Done. Commit the regenerated JSON together with vendor/blocklists/."
