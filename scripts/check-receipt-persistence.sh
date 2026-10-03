#!/usr/bin/env bash
# Run the installed simulator app's synthetic native persistence/FFI checks.
# Build/install the current app first (scripts/sim-e2e.sh does both).
# Does not add synthetic records to the user's spending store or import batch.
set -euo pipefail
simulator="${SIMULATOR:-booted}"
bundle_id=com.beanbeaver.BeanBeaver
container="$(xcrun simctl get_app_container "$simulator" "$bundle_id" data)"
report="$container/Documents/receipt-persistence-check.txt"
run_check() {
    rm -f "$report"
    xcrun simctl terminate "$simulator" "$bundle_id" 2>/dev/null || true
    xcrun simctl launch "$simulator" "$bundle_id" "$1"
    for ((attempt = 0; attempt < 30; attempt++)); do
        if [[ -f "$report" ]]; then
            cat "$report"
            grep -q '^PASS:' "$report"
            return $?
        fi
        sleep 1
    done
    echo "Persistence check did not produce a report within 30 seconds" >&2
    return 1
}
run_check -checkReceiptPersistence
run_check -checkReceiptPersistenceReload
