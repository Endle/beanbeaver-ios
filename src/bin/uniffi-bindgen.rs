//! Local `uniffi-bindgen` entry point (library mode), used by
//! build-xcframework.sh to emit the Swift glue from the compiled core:
//!   cargo run -p beanbeaver-ios-ffi-build --bin uniffi-bindgen -- \
//!     generate --library target/debug/libbb_receipt_ffi.dylib \
//!     --language swift --out-dir <dir>
//!
//! bb-receipt-ffi ships this same bin, but it's a git dependency (not a
//! workspace member), so `cargo run -p bb-receipt-ffi --bin uniffi-bindgen`
//! can't reach it ("not found in workspace"). We host our own here.
fn main() {
    uniffi::uniffi_bindgen_main()
}
