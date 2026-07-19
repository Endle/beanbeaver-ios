#!/usr/bin/env bash
#
# Assemble BBReceiptFFI.xcframework from the bb-receipt-ffi crate, for use by the
# SwiftUI app. Produces, under target/ios/:
#   - BBReceiptFFI.xcframework   (device + simulator static slices)
#   - bb_receipt_ffi.swift       (generated Swift glue; add to the app's sources)
#
# Each xcframework slice is the Rust staticlib libtool-merged with the prebuilt
# libonnxruntime.a that `ort` downloads (the Rust .a only *references* ORT
# symbols; it doesn't embed them), so the app links a single .a per platform.
#
# Usage:  ./build-xcframework.sh
#   PROFILE=debug          ./...   # faster, fat binaries (default: release)
#   INCLUDE_X86_SIM=1      ./...   # also build x86_64 simulator slice (Intel Macs)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
export CARGO_TARGET_DIR="$REPO_ROOT/target"

CRATE=bb-receipt-ffi
LIB=libbb_receipt_ffi.a
PROFILE="${PROFILE:-release}"
# Output into the committed local SPM package (the xcframework + generated glue
# themselves are git-ignored and rebuilt by this script).
PKG="$REPO_ROOT/BBReceiptKit"
WORK="$REPO_ROOT/target/ios/.work"
ORT_CACHE="$HOME/Library/Caches/ort.pyke.io"

DEVICE_TARGET=aarch64-apple-ios
SIM_TARGETS=(aarch64-apple-ios-sim)
[ "${INCLUDE_X86_SIM:-0}" = "1" ] && SIM_TARGETS+=(x86_64-apple-ios)

cargo_flags=(--lib -p "$CRATE")
[ "$PROFILE" = "release" ] && cargo_flags+=(--release)
# OCR runs on CPU only (no coreml feature): on the shipped dynamic-shape mobile
# models, CPU beats CoreML/ANE on both speed and accuracy on real hardware, so the
# Neural Engine path isn't worth building.
profile_dir="$PROFILE"; [ "$PROFILE" = "debug" ] && profile_dir=debug

rm -rf "$WORK"; mkdir -p "$WORK"

# Locate the prebuilt libonnxruntime.a that `ort` cached for a given target.
ort_lib() {
  find "$ORT_CACHE" -type f -name libonnxruntime.a -path "*/$1/*" 2>/dev/null | head -1
}

# Build + (rust .a ⊕ ort .a) -> one combined static lib for a single target.
combine_target() {
  local target="$1" out_a="$2"
  echo ">> building $CRATE for $target ($PROFILE)"
  cargo build "${cargo_flags[@]}" --target "$target" >/dev/null
  local rust_a="$REPO_ROOT/target/$target/$profile_dir/$LIB"
  local ort_a; ort_a="$(ort_lib "$target")"
  [ -f "$rust_a" ] || { echo "missing $rust_a" >&2; exit 1; }
  [ -n "$ort_a" ] || { echo "no cached libonnxruntime.a for $target" >&2; exit 1; }
  echo "   ort: $ort_a"
  xcrun libtool -static -o "$out_a" "$rust_a" "$ort_a"
}

# --- device slice ---------------------------------------------------------
combine_target "$DEVICE_TARGET" "$WORK/device.a"

# --- simulator slice (lipo the per-arch combined libs) --------------------
sim_libs=()
for t in "${SIM_TARGETS[@]}"; do
  combine_target "$t" "$WORK/sim-$t.a"
  sim_libs+=("$WORK/sim-$t.a")
done
if [ "${#sim_libs[@]}" -gt 1 ]; then
  xcrun lipo -create "${sim_libs[@]}" -output "$WORK/sim.a"
else
  cp "${sim_libs[0]}" "$WORK/sim.a"
fi

# --- generate Swift bindings (platform-agnostic; from a host build) --------
echo ">> generating Swift bindings"
cargo build --lib -p "$CRATE" >/dev/null
HOST_DYLIB="$REPO_ROOT/target/debug/libbb_receipt_ffi.dylib"
GEN="$WORK/gen"; mkdir -p "$GEN"
# Run the bindgen bin hosted by this shim package (bb-receipt-ffi is a git dep,
# so `cargo run -p bb-receipt-ffi` can't reach its copy — see src/bin/uniffi-bindgen.rs).
cargo run -q -p beanbeaver-ios-ffi-build --bin uniffi-bindgen -- \
  generate --library "$HOST_DYLIB" --language swift --out-dir "$GEN"

# Headers dir for the xcframework: C header + modulemap (named module.modulemap).
HDR="$WORK/headers"; mkdir -p "$HDR"
cp "$GEN/bb_receipt_ffiFFI.h" "$HDR/"
cp "$GEN/bb_receipt_ffiFFI.modulemap" "$HDR/module.modulemap"

# --- assemble the xcframework ---------------------------------------------
echo ">> creating BBReceiptFFI.xcframework"
FRAMEWORKS="$PKG/Frameworks"; mkdir -p "$FRAMEWORKS"
rm -rf "$FRAMEWORKS/BBReceiptFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/device.a" -headers "$HDR" \
  -library "$WORK/sim.a"    -headers "$HDR" \
  -output "$FRAMEWORKS/BBReceiptFFI.xcframework" >/dev/null

# The Swift glue is a *source* file the package target compiles (git-ignored).
GENERATED="$PKG/Sources/BBReceiptKit/Generated"; mkdir -p "$GENERATED"
cp "$GEN/bb_receipt_ffi.swift" "$GENERATED/"

# --- generated beanbeaver-core version constant ---------------------------
# Surface the exact bb-receipt-ffi pin (git tag + resolved short SHA) the app
# was built against, so Settings can show it. Sourced from Cargo.lock's resolved
# `source = "git+…?tag=vX.Y.Z#<sha>"` line — NOT the crate's own semver (still
# 0.1.0), which is not the release identifier. Regenerated here so it can never
# drift from the framework: rebuilding the xcframework is already mandatory after
# any pin bump.
core_src="$(grep -A2 '^name = "bb-receipt-ffi"' "$REPO_ROOT/Cargo.lock" | grep '^source = ' | head -1)"
core_tag="$(printf '%s' "$core_src" | sed -n 's/.*[?&]tag=\([^#"&]*\).*/\1/p')"
core_rev="$(printf '%s' "$core_src" | sed -n 's/.*[?&]rev=\([^#"&]*\).*/\1/p')"
core_commit="$(printf '%s' "$core_src" | sed -n 's/.*#\([0-9a-f]\{7,\}\).*/\1/p')"
core_version="${core_tag:-${core_rev:-unknown}}"
core_commit_short="${core_commit:0:7}"
cat > "$GENERATED/CoreVersion.swift" <<SWIFT
// Generated by build-xcframework.sh from the bb-receipt-ffi pin in Cargo.lock.
// Do NOT edit — overwritten on every framework rebuild, git-ignored like the
// rest of Generated/. \`version\` is the beanbeaver-core git tag this framework
// was built from; \`commit\` is the short SHA it resolved to (support triage).
public enum BBReceiptCore {
    public static let version = "${core_version}"
    public static let commit = "${core_commit_short}"
}
SWIFT

rm -rf "$WORK"

cat <<EOF

✅ Done. Wrote into BBReceiptKit/ (git-ignored, rebuildable):
   Frameworks/BBReceiptFFI.xcframework
   Sources/BBReceiptKit/Generated/bb_receipt_ffi.swift
   Sources/BBReceiptKit/Generated/CoreVersion.swift   (core ${core_version})
EOF
