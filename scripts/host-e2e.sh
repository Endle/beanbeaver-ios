#!/usr/bin/env bash
#
# Host E2E: run receipt fixtures through the real core on this machine — no
# simulator, no Xcode, no app — and grade the results against ground truth.
#
# The host twin of sim-e2e.sh, and the Android twin of the "Host E2E" step in
# beanbeaver-android's CI. Same core, same models, same fixtures, same grader;
# what it *cannot* prove is the Swift/UniFFI seam and anything above it, which
# is exactly what sim-e2e.sh is for. Use this one for a fast parser check after
# bumping the core tag, and sim-e2e.sh before you believe the app works.
#
#   scripts/host-e2e.sh                          # tests/receipts_e2e/
#   scripts/host-e2e.sh /path/to/private/corpus  # any dir of <stem>.jpg
#   PRIVATE_RULES=…/private_rules.toml scripts/host-e2e.sh …
#
# batch_e2e's source lives in the shared/ submodule (beanbeaver-mobile-util) and
# is compiled into this repo's build-only crate — see Cargo.toml. If shared/ is
# empty, run `git submodule update --init`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIXTURES="${1:-$ROOT/tests/receipts_e2e}"
WORK="${WORK:-${TMPDIR:-/tmp}/bb-host-e2e}"
SEL="$WORK/selected"

[ -d "$FIXTURES" ] || { echo "no such fixtures dir: $FIXTURES" >&2; exit 1; }
[ -f "$ROOT/shared/scripts/compare-e2e.py" ] || {
  echo "shared/ is empty — run: git submodule update --init" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$SEL"
: > "$WORK/manifest.txt"

# Every <stem>.jpg that has a sibling <stem>.expected.json. A fixture without
# ground truth is skipped rather than scanned-and-ignored: batch_e2e reads the
# whole --in-dir, and an ungraded scan is just OCR time.
while IFS= read -r jpg; do
  stem="$(basename "$jpg" .jpg)"
  exp="$(dirname "$jpg")/$stem.expected.json"
  [ -f "$exp" ] || continue
  cp "$jpg" "$SEL/$stem.jpg"
  printf '%s|%s\n' "$stem" "$exp" >> "$WORK/manifest.txt"
done < <(find "$FIXTURES" -name '*.jpg' | sort)

count=$(find "$SEL" -name '*.jpg' | wc -l | tr -d ' ')
echo "selected $count case(s) from $FIXTURES"
[ "$count" -gt 0 ] || { echo "no *.jpg with a sibling *.expected.json found" >&2; exit 1; }

python3 - "$WORK/manifest.txt" "$WORK/manifest.json" <<'PY'
import json, sys
m = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line:
        stem, exp = line.split("|", 1); m[stem] = exp
json.dump(m, open(sys.argv[2], "w"), indent=2)
PY

echo "── scan ($count receipts, release profile) ──"
# Release: a debug build of the image/OCR path is minutes slower per scan, and
# the cargo cache makes this a rebuild of one crate.
( cd "$ROOT" && cargo run --release --quiet --bin batch_e2e -- \
    --models "$ROOT/models" --in-dir "$SEL" --out "$WORK/batch_out.json" )

echo "── compare ──"
# PRIVATE_RULES (optional): when set, categories the private suite gets from
# private_rules.toml are tolerated — this path runs public rules only, same as
# the shipping app. See sim-e2e-private.sh.
python3 "$ROOT/shared/scripts/compare-e2e.py" \
  --results "$WORK/batch_out.json" --manifest "$WORK/manifest.json" \
  ${PRIVATE_RULES:+--private-rules "$PRIVATE_RULES"}
