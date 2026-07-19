## Project layout

Single Xcode app + a local Swift package wrapping the Rust core. (The cross-repo
license split and core-tag pinning live in `../CLAUDE.md` — not repeated here.)

| Path | Role |
|---|---|
| `BeanBeaver/BeanBeaver/` | The SwiftUI app (Xcode project `BeanBeaver/BeanBeaver.xcodeproj`). All app code. |
| `BBReceiptKit/` | Local Swift package over the Rust core. `Sources/BBReceiptKit/ReceiptScanner.swift` = thin Swift API; `Sources/.../Generated/` (uniffi bindings + `CoreVersion.swift`) and `Frameworks/*.xcframework` are git-ignored, produced by `build-xcframework.sh`. |
| `src/` + `Cargo.toml` | Root Rust crate `beanbeaver-ios-ffi-build`: **build-only**. `src/bin/uniffi-bindgen.rs` runs codegen; `lib.rs` is empty. Pins the `bb-receipt-ffi` tag → the real core. |
| `build-xcframework.sh` | Builds core → xcframework + regenerates the Swift glue & `CoreVersion.swift`. Rerun after bumping the tag. |
| `models/` | PP-OCRv5 ONNX (det/rec + textline orientation). |
| `scripts/` | E2E / perf harnesses — see `scripts/README.md`. |
| `tests/receipts_e2e/` | Fixtures: `<stem>.jpg` + `<stem>.expected.json`. |

App code under `BeanBeaver/BeanBeaver/`, by concern (open the file for detail):

- **Entry / home** — `BeanBeaverApp.swift` (entry); `ContentView.swift` (home screen, and a **grab-bag** that also defines `SettingsView`, `ReceiptResultView`, `ReceiptCard`, `OriginReceiptView`, `ScanTimingsView`).
- **Scan pipeline** — `ReceiptPipeline.swift` (`BatchRunner`, `-autoRunBatch`), `ReceiptCaptureStore.swift`, `ReceiptBatch.swift`, `DocumentScanner.swift`, `BatchImportView.swift`.
- **Export / sync** — `LedgerExport.swift` (exporter seam), `LedgerSettingsView.swift` (the "Sync" page), backends `GitHubLedger.swift` / `GitHubDeviceFlow.swift` / `FilesLedgerInbox.swift`, and `MoneyManagerExport.swift` / `MoneyManagerWorkbook.swift`.
- **Support** — `Entitlements.swift` (`isPremium` seam); `DebugInfoStore.swift` (+`DebugInfoListView`) and `DataDump.swift` (+`DataDumpView`) = in-app debug capture; others self-named (`Keychain`, `Theme`, `ZoomableImageView`, `PhotoSaver`, `LaunchTiming`).

## Working notes

- We always develop on an Apple-silicon (M-chip) MacBook, so the **x86_64 simulator
  slice is never needed** — don't build it (`INCLUDE_X86_SIM` stays off) and don't
  expect it in the xcframework. A plain `-destination 'generic/platform=iOS Simulator'`
  build fails to link x86_64; build the simulator with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
  (or target a specific arm64 simulator). Device builds are arm64 and unaffected.

- **Sync page vs. general Settings — where UI config lives.** The **Sync page**
  (`LedgerSettingsView`, opened from the home screen's "Sync:" button and the
  result/batch "Sync Settings…" action) is the single place to pick *and* configure the
  downstream exporter — beancount destinations (GitHub PR, Files inbox) and the Money
  Manager Excel export today. It's a **"select one exporter" picker showing only the
  chosen exporter's detail**, so it stays short as targets grow: add a target as a
  `SyncExporter` case + `switch` arm, not another stacked section. **General
  `SettingsView`** (app/device prefs) holds only *cross-cutting* output prefs that span
  services — e.g. the "Save details file" `.json` sidecar toggle (applies to every file
  backend: Files/Dropbox/GitHub). Rule: one exporter's own target config → Sync page;
  anything spanning services → Settings.

- Avoid using macro #if DEBUG - think twice that if it's necessary
