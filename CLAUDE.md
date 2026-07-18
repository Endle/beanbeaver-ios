- In `beanbeaver-ios/`, bumping the `bb-receipt-ffi` tag in `Cargo.toml` is not enough —
  always rerun `./build-xcframework.sh` afterward, or the app compiles against stale
  generated Swift bindings and fails with confusing "extra arguments"/type errors.

- We always develop on an Apple-silicon (M-chip) MacBook, so the **x86_64 simulator
  slice is never needed** — don't build it (`INCLUDE_X86_SIM` stays off) and don't
  expect it in the xcframework. A plain `-destination 'generic/platform=iOS Simulator'`
  build fails to link x86_64; build the simulator with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
  (or target a specific arm64 simulator). Device builds are arm64 and unaffected.

- The **"Sync" page (`LedgerSettingsView`, reached from the home screen's "Sync:"
  button) is the single, centralized place to manage every downstream data output** —
  where scanned data goes. That's the beancount ledger destinations (GitHub PR, Files
  inbox) and the Money Manager Excel export today, plus any ledger or export format we
  add later. **Put new export/destination configuration there, not in the general
  `SettingsView`.** General Settings is for app/device preferences (Photos copy,
  storage, debug) — never output targets. The result-screen and batch "Sync Settings…"
  menu actions therefore open this page.
