#!/usr/bin/env bash
#
# Manual, macOS-only: run the PRIVATE receipt corpus through the app's real scan
# pipeline on a booted simulator in LIVE mode, and diff against expected.json.
#
# This is the "device sim live mode" check for cases too PII-sensitive to publish.
# It is SLOW (real on-device OCR over the whole corpus) and needs private fixtures
# that don't exist in CI, so it never runs in CI — start it by hand and read the
# table.
#
# Firewall: the PII fixtures (`receipts_e2e/`) and `private_rules.toml` live in the
# PRIVATE repo (beanbeaver-private-test). This runner only references them BY PATH,
# so nothing private is committed to this public repo.
#
# Categories are compared PUBLIC-RULES-ONLY: the shipping app can't inject the
# private suite's `private_rules.toml`, so categories that come from it are
# tolerated (see compare-e2e.py --private-rules). Description/price and every
# public-rule category are still enforced, so genuine public-rule regressions
# surface.
#
#   scripts/sim-e2e-private.sh [receipts_e2e-dir] [pilot|--all]
#
# Paths default to the sibling checkout in this umbrella; override via env:
#   BB_PRIVATE_DIR=/path/to/beanbeaver-private-test  scripts/sim-e2e-private.sh
#   PRIVATE_RULES=/path/to/private_rules.toml        (or empty to skip tolerance)
#
# Requires: a booted simulator (see sim-e2e.sh) and the xcframework already built.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PRIV="${BB_PRIVATE_DIR:-$HERE/../../beanbeaver-private-test}"
FIXTURES="${1:-$PRIV/receipts_e2e}"
MODE="${2:---all}"
RULES="${PRIVATE_RULES-$PRIV/private_rules.toml}"

[ -d "$FIXTURES" ] || {
  echo "private fixtures dir not found: $FIXTURES"
  echo "  set BB_PRIVATE_DIR=/path/to/beanbeaver-private-test, or pass the dir as arg 1."
  exit 1
}
if [ -n "$RULES" ] && [ ! -f "$RULES" ]; then
  echo "warning: private_rules.toml not found at $RULES — categories will be enforced against public rules only (may over-report). Set PRIVATE_RULES=... or PRIVATE_RULES= to silence."
  RULES=""
fi

echo "fixtures:      $FIXTURES"
echo "private rules: ${RULES:-<none>}"
echo "mode:          $MODE"
PRIVATE_RULES="$RULES" exec "$HERE/sim-e2e.sh" "$FIXTURES" "$MODE"
