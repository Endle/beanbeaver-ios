- In `beanbeaver-ios/`, bumping the `bb-receipt-ffi` tag in `Cargo.toml` is not enough —
  always rerun `./build-xcframework.sh` afterward, or the app compiles against stale
  generated Swift bindings and fails with confusing "extra arguments"/type errors.

- We always develop on an Apple-silicon (M-chip) MacBook, so the **x86_64 simulator
  slice is never needed** — don't build it (`INCLUDE_X86_SIM` stays off) and don't
  expect it in the xcframework. A plain `-destination 'generic/platform=iOS Simulator'`
  build fails to link x86_64; build the simulator with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
  (or target a specific arm64 simulator). Device builds are arm64 and unaffected.

- The **"Sync" page (`LedgerSettingsView`, reached from the home screen's "Sync:"
  button) is the single place to choose a downstream *exporter* and configure it** —
  where scanned data goes: the beancount ledger destinations (GitHub PR, Files inbox)
  and the Money Manager Excel export today, plus any ledger/format added later. It uses
  a **"select one exporter" picker with only the chosen exporter's detail below**, so
  the page stays short as targets grow — add a new exporter as another `SyncExporter`
  case (and a `switch` arm), not another always-stacked section. Per-exporter
  configuration goes here, and the result-screen/batch "Sync Settings…" actions open
  this page.
- General `SettingsView` holds app/device preferences and **cross-cutting output
  preferences that span services** — e.g. the "Save details file" `.json` sidecar
  toggle, which applies to every file-based backend (Files/Dropbox/GitHub). Keep those
  in Settings; only a single exporter's own target config belongs on the Sync page.

- Avoid using macro #if DEBUG - think twice that if it's necessary
