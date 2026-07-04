- In `beanbeaver-ios/`, bumping the `bb-receipt-ffi` tag in `Cargo.toml` is not enough —
  always rerun `./build-xcframework.sh` afterward, or the app compiles against stale
  generated Swift bindings and fails with confusing "extra arguments"/type errors.
