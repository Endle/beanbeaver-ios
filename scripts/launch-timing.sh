#!/usr/bin/env bash
#
# Real-device launch-latency measurement: build the app in a given configuration
# (Debug or Release), install it on a connected iPhone, cold-launch it N times
# with `-logLaunchTiming`, and pull the per-launch process-start→first-frame
# timings the app wrote to Documents/launch_timing.json (see LaunchTiming.swift).
#
# This is the "why is the launch screen up for a few seconds" measurement — it
# captures the whole pre-main window (dyld map + code-sign validation + ONNX
# static initializers), which does NOT transfer from the Mac/simulator, so the
# phone is the only valid signal. Run it for both configs to compare:
#
#   scripts/launch-timing.sh Release        # 5 cold launches, Release
#   scripts/launch-timing.sh Debug 8        # 8 cold launches, Debug
#   RUNS=6 scripts/launch-timing.sh Release
#
# The first launch after install is reported separately: it pays one-time
# first-launch costs (fresh-binary signature validation) that later cold
# launches don't, and it's the worst case a user hits right after updating.
#
# Requires: a connected, unlocked, trusted device; code signing set up.
set -euo pipefail

CONFIG="${1:-Release}"
RUNS="${2:-${RUNS:-5}}"
BID="com.beanbeaver.BeanBeaver"
SCHEME="BeanBeaver"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-${TMPDIR:-/tmp}/bb-launch-timing}"
mkdir -p "$WORK"
OUT="$WORK/launch_timing.$CONFIG.json"
rm -f "$OUT"

case "$CONFIG" in Debug|Release) ;; *) echo "config must be Debug or Release"; exit 2 ;; esac

DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null \
  | awk 'NR>2 && /connected|available/ {print $3; exit}')}"
[ -n "$DEVICE_ID" ] || { echo "no connected device (xcrun devicectl list devices)"; exit 1; }
echo "device: $DEVICE_ID   config: $CONFIG   runs: $RUNS"

echo "── build & install ($CONFIG) ──"
( cd "$HERE/../BeanBeaver" && xcodebuild -scheme "$SCHEME" -sdk iphoneos \
    -destination "platform=iOS,id=$DEVICE_ID" -configuration "$CONFIG" \
    -allowProvisioningUpdates build | tail -2 )
APP=$(cd "$HERE/../BeanBeaver" && xcodebuild -scheme "$SCHEME" -sdk iphoneos \
    -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}')
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null
echo "installed: $APP"

# Clear any prior run's timing file so we only collect this session's launches.
printf '[]' > "$WORK/empty.json"
xcrun devicectl device copy to --device "$DEVICE_ID" \
  --domain-type appDataContainer --domain-identifier "$BID" \
  --source "$WORK/empty.json" --destination "Documents/launch_timing.json" \
  --remove-existing-content true >/dev/null 2>&1 || true

echo "── $RUNS cold launches ──"
for i in $(seq 1 "$RUNS"); do
  xcrun devicectl device process launch --device "$DEVICE_ID" \
    --terminate-existing "$BID" -- -logLaunchTiming >/dev/null 2>&1
  sleep 6                     # let it reach first frame + write the record
  xcrun devicectl device process terminate --device "$DEVICE_ID" "$BID" >/dev/null 2>&1 || true
  sleep 2                     # settle before the next cold launch
  printf '  launch %d/%d done\n' "$i" "$RUNS"
done

echo "── pull results ──"
xcrun devicectl device copy from --device "$DEVICE_ID" \
  --domain-type appDataContainer --domain-identifier "$BID" \
  --source "Documents/launch_timing.json" --destination "$OUT" >/dev/null
echo "wrote $OUT"

python3 - "$OUT" "$CONFIG" <<'PY'
import json, sys, statistics as st
recs = json.load(open(sys.argv[1]))
ms = [r["ms"] for r in recs]
cfg = sys.argv[2]
print(f"\n=== {cfg}: process-start → first-frame (ms) ===")
print(f"  launches:   {len(ms)}")
if not ms: sys.exit(0)
print(f"  first (cold-after-install): {ms[0]:.0f}")
rest = ms[1:] or ms
print(f"  steady cold  min / median / max: {min(rest):.0f} / {st.median(rest):.0f} / {max(rest):.0f}")
print(f"  all: " + ", ".join(f"{x:.0f}" for x in ms))
PY
