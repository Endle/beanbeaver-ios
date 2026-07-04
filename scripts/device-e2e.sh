#!/usr/bin/env bash
#
# On-DEVICE E2E / perf: run receipt fixtures through the app's real scan pipeline
# on a physically connected iPhone (via devicectl) and report per-stage latency.
# The devicectl twin of sim-e2e.sh — needed because performance does NOT transfer
# from the Mac/simulator to the phone (fewer cores, different per-op costs), so
# the phone is the only valid perf signal.
#
# Builds + installs the app for the device, pushes the selected <stem>.jpg into
# the app container's Documents/batch_in/, launches with -autoRunBatch (see
# BatchRunner in ReceiptPipeline.swift), pulls Documents/batch_out.json, then
# prints mean/worst per-stage timings (and runs compare-e2e.py if a manifest of
# expected.json exists).
#
#   scripts/device-e2e.sh <receipts_e2e-dir>          # pilot: one case per merchant
#   scripts/device-e2e.sh <receipts_e2e-dir> --all    # every <stem>.jpg with expected
#
# Requires: a connected, unlocked, trusted device; code signing set up for the
# app; the xcframework already built (with a device slice).
set -euo pipefail

FIXTURES="${1:?usage: device-e2e.sh <receipts_e2e-dir> [--all]}"
MODE="${2:-pilot}"
BID="com.beanbeaver.BeanBeaverScan"
SCHEME="BeanBeaverScan"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-${TMPDIR:-/tmp}/bb-device-e2e}"
SEL="$WORK/batch_in"
rm -rf "$WORK"; mkdir -p "$SEL"
: > "$WORK/manifest.txt"

# Resolve the connected device UDID (first available device).
DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null \
  | awk 'NR>2 && /available/ {print $3; exit}')}"
[ -n "$DEVICE_ID" ] || { echo "no connected device found (xcrun devicectl list devices)"; exit 1; }
echo "device: $DEVICE_ID"

select_case() {  # $1 = jpg path; keep only if a sibling expected.json exists
  local jpg="$1" dir stem exp
  dir="$(dirname "$jpg")"; stem="$(basename "$jpg" .jpg)"; exp="$dir/$stem.expected.json"
  [ -f "$exp" ] || return 1
  cp "$jpg" "$SEL/$stem.jpg"
  printf '%s|%s\n' "$stem" "$exp" >> "$WORK/manifest.txt"
}

if [ "$MODE" = "--all" ] || [ "$MODE" = "all" ]; then
  while IFS= read -r jpg; do select_case "$jpg" || true; done \
    < <(find "$FIXTURES" -name '*.jpg' | sort)
else
  for d in "$FIXTURES"/*/; do
    while IFS= read -r jpg; do select_case "$jpg" && break; done \
      < <(find "$d" -maxdepth 1 -name '*.jpg' | sort)
  done
fi
count=$(find "$SEL" -name '*.jpg' | wc -l | tr -d ' ')
echo "selected $count case(s) [$MODE]"
[ "$count" -gt 0 ] || { echo "no cases with expected.json found under $FIXTURES"; exit 1; }

python3 - "$WORK/manifest.txt" "$WORK/manifest.json" <<'PY'
import json, sys
m = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line:
        stem, exp = line.split("|", 1); m[stem] = exp
json.dump(m, open(sys.argv[2], "w"), indent=2)
PY

echo "── build & install (device) ──"
( cd "$HERE/../BeanBeaverScan" && xcodebuild -scheme "$SCHEME" -sdk iphoneos \
    -destination "platform=iOS,id=$DEVICE_ID" -configuration Debug \
    -allowProvisioningUpdates build | tail -3 )
APP=$(cd "$HERE/../BeanBeaverScan" && xcodebuild -scheme "$SCHEME" -sdk iphoneos \
    -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}')
echo "app: $APP"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null
echo "installed."

echo "── push corpus into container ──"
# Directory copy lands $SEL (named batch_in) under Documents on the device.
xcrun devicectl device copy to --device "$DEVICE_ID" \
  --domain-type appDataContainer --domain-identifier "$BID" \
  --source "$SEL" --destination "Documents/batch_in" \
  --remove-existing-content true >/dev/null
echo "pushed $count image(s)."

echo "── launch -autoRunBatch ($count scans) ──"
# `--` separates the app's launch args from devicectl's own options; without it
# devicectl parses `-autoRunBatch` as bundled short flags (-a -u -t …).
xcrun devicectl device process launch --device "$DEVICE_ID" \
  --terminate-existing "$BID" -- -autoRunBatch >/dev/null

echo "── waiting for batch_out.json ──"
OUT="$WORK/batch_out.json"
sleep 6   # grace: let the app launch and clear the prior batch_out.json
ok=0
for _ in $(seq 1 120); do
  if xcrun devicectl device copy from --device "$DEVICE_ID" \
       --domain-type appDataContainer --domain-identifier "$BID" \
       --source "Documents/batch_out.json" --destination "$OUT" \
       >/dev/null 2>&1 && [ -s "$OUT" ]; then ok=1; break; fi
  sleep 3
done
[ "$ok" = 1 ] || { echo "timed out waiting for batch_out.json"; exit 1; }
echo "got results."

echo "── per-stage latency (device) ──"
python3 "$HERE/device-latency.py" "$OUT"

if [ -s "$WORK/manifest.json" ]; then
  echo "── quality compare ──"
  python3 "$HERE/compare-e2e.py" --results "$OUT" --manifest "$WORK/manifest.json" || true
fi
