#!/usr/bin/env bash
#
# On-device E2E: run receipt fixtures through the app's real scan pipeline on a
# booted simulator and diff the parsed results against ground-truth expected.json.
#
# Builds + installs the app, pushes the selected <stem>.jpg into the app
# container's Documents/batch_in/, launches with -autoRunBatch (see BatchRunner
# in ReceiptPipeline.swift), waits for Documents/batch_out.json, then runs
# compare-e2e.py. This is the "device sim live mode" the desktop pytest can't do.
#
#   scripts/sim-e2e.sh <receipts_e2e-dir>          # pilot: one case per merchant
#   scripts/sim-e2e.sh <receipts_e2e-dir> --all    # every <stem>.jpg with expected
#
# Requires a booted simulator (iPhone 17 Pro) and the xcframework already built.
set -euo pipefail

FIXTURES="${1:?usage: sim-e2e.sh <receipts_e2e-dir> [--all]}"
MODE="${2:-pilot}"
BID="com.beanbeaver.BeanBeaver"
SCHEME="BeanBeaver"
DEST='platform=iOS Simulator,name=iPhone 17 Pro'
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-${TMPDIR:-/tmp}/bb-sim-e2e}"
SEL="$WORK/selected"
rm -rf "$WORK"; mkdir -p "$SEL"
: > "$WORK/manifest.txt"

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

echo "── build & install ──"
( cd "$HERE/../BeanBeaver" && xcodebuild -scheme "$SCHEME" -sdk iphonesimulator \
    -destination "$DEST" -configuration Debug build | tail -2 )
APP=$(cd "$HERE/../BeanBeaver" && xcodebuild -scheme "$SCHEME" -sdk iphonesimulator \
    -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}')
xcrun simctl install booted "$APP"

CONT=$(xcrun simctl get_app_container booted "$BID" data)
IN="$CONT/Documents/batch_in"; OUT="$CONT/Documents/batch_out.json"
rm -rf "$IN"; mkdir -p "$IN"; cp "$SEL"/*.jpg "$IN/"; rm -f "$OUT"

echo "── launch -autoRunBatch ($count scans) ──"
xcrun simctl terminate booted "$BID" 2>/dev/null || true
xcrun simctl launch booted "$BID" -autoRunBatch >/dev/null

for _ in $(seq 1 180); do [ -f "$OUT" ] && break; sleep 2; done
[ -f "$OUT" ] || { echo "timed out waiting for batch_out.json"; exit 1; }
cp "$OUT" "$WORK/batch_out.json"

echo "── compare ──"
python3 "$HERE/compare-e2e.py" --results "$WORK/batch_out.json" --manifest "$WORK/manifest.json"
