## Project layout

Single Xcode app + a local Swift package wrapping the Rust core. (The cross-repo
license split and core-tag pinning live in `../CLAUDE.md` — not repeated here.)

| Path | Role |
|---|---|
| `BeanBeaver/BeanBeaver/` | The SwiftUI app (Xcode project `BeanBeaver/BeanBeaver.xcodeproj`). All app code. |
| `BBReceiptKit/` | Local Swift package over the Rust core. `Sources/BBReceiptKit/ReceiptScanner.swift` = thin Swift API; `Sources/.../Generated/` (uniffi bindings for **both** namespaces + `CoreVersion.swift`) and `Frameworks/*.xcframework` are git-ignored, produced by `build-xcframework.sh`. |
| `src/` + `Cargo.toml` | Root Rust crate `beanbeaver-ios-ffi-build`: **build-only**; `lib.rs` is empty. Pins **`bb-mobile-ffi`** (the library that ships — it carries the parse core inside it) *and* `bb-receipt-ffi` (for `batch_e2e.rs`) — **the two must agree on the core version**. Hosts two bins — `uniffi-bindgen` (codegen) and `batch_e2e` (host harness) — whose **sources live in `shared/`**, compiled here via `[[bin]] path`. |
| `shared/` | **Git submodule** — [`beanbeaver-mobile-util`](https://github.com/Endle/beanbeaver-mobile-util), the assets iOS and Android genuinely share: `scripts/compare-e2e.py`, `scripts/fetch-models.sh`, `src/bin/uniffi-bindgen.rs`, `src/bin/batch_e2e.rs`. See "The `shared/` submodule" below. |
| `build-xcframework.sh` | Builds core → xcframework + regenerates the Swift glue & `CoreVersion.swift`. Rerun after bumping the tag. |
| `models/` | PP-OCRv5 ONNX (det/rec + textline orientation). |
| `scripts/` | E2E / perf harnesses — see `scripts/README.md`. |
| `tests/receipts_e2e/` | Fixtures: `<stem>.jpg` + `<stem>.expected.json`. |

App code under `BeanBeaver/BeanBeaver/`, by concern (open the file for detail):

- **Entry / home** — `BeanBeaverApp.swift` (entry); `ContentView.swift` (home screen, and a **grab-bag** that also defines `SettingsView`, `ReceiptResultView`, `ReceiptCard`, `OriginReceiptView`, `ScanTimingsView`).
- **Scan pipeline** — `ReceiptPipeline.swift` (`BatchRunner`, `-autoRunBatch`), `ReceiptCaptureStore.swift`, `ReceiptBatch.swift`, `DocumentScanner.swift`, `BatchImportView.swift`.
- **Export / sync** — `LedgerExport.swift` (exporter seam), `LedgerSettingsView.swift` (the "Sync" page), backends `GitHubLedger.swift` / `GitHubDeviceFlow.swift` / `FilesLedgerInbox.swift`, and `MoneyManagerExport.swift` / `MoneyManagerWorkbook.swift`.
- **Support** — `Entitlements.swift` (`isPremium` seam); `DebugInfoStore.swift` (+`DebugInfoListView`) and `DataDump.swift` (+`DataDumpView`) = in-app debug capture; others self-named (`Keychain`, `Theme`, `ZoomableImageView`, `PhotoSaver`, `LaunchTiming`).

## The `shared/` submodule

Four build/test assets used to exist twice across this repo and
`beanbeaver-android` (or once, and should have existed twice). They now live in
[`beanbeaver-mobile-util`](https://github.com/Endle/beanbeaver-mobile-util) and
both apps consume them as a submodule at `shared/`.

**Clone with `--recurse-submodules`**, or run `git submodule update --init`. An
empty `shared/` is not a soft failure: the `[[bin]]` paths in `Cargo.toml` point
into it, so cargo dies on a missing manifest path and `build-xcframework.sh`
never reaches codegen. CI checks out with `submodules: true`.

The two `.rs` files are **source assets compiled into this package**, not a crate
dependency — deliberately. `batch_e2e.rs` imports `OcrSession`, `Phase`,
`ScanTimings` and `ReceiptWarningKind` from `bb-receipt-ffi`, so it builds
against *this* repo's pinned core tag and Android can sit on a different one.
Same reasoning for `uniffi-bindgen.rs` and the `uniffi` 0.28 pin.

So a breaking core FFI bump can require a change in `beanbeaver-mobile-util`.
Fix it there, push, then move this repo's pointer:

```bash
cd shared && git pull origin main && cd ..
git add shared && git commit -m "chore(shared): bump beanbeaver-mobile-util"
```

**This repo gained `batch_e2e` in the move** — a host harness it never had. It is
what `scripts/host-e2e.sh` drives, and CI type-checks it (`cargo check --bin
batch_e2e`) so a core bump here can't silently break Android's CI, which actually
runs it.

## Spending is computed in shared Rust

`SpendSummary.swift` no longer contains the arithmetic. It lives in
`spend-core` (beanbeaver-mobile-util), reached through the **`bb_mobile_ffi`**
UniFFI namespace, so this app and `beanbeaver-android` compute spending from one
implementation instead of two hand-synced ports. Its public Swift surface is
unchanged, so no view moved.

What stays here is genuinely this platform's:

- **the projection** — `SpendRecord` → `SpendInput` (`SpendRecord.spendInput`),
  including resolving `scannedAt` to a local calendar date. That needs a
  timezone database *and* the offset in force at that instant; `Calendar.current`
  has both and gets DST right, which is why Rust takes a resolved date rather
  than an epoch timestamp.
- **re-attachment** — Rust identifies a receipt by id (`UUID.uuidString`) and an
  item by index; the views want the app's own `SpendRecord` / `ReceiptItem`
  objects back (`SpendItemEntry.reattached(in:)`).

`BudgetPrefs` keeps its `UserDefaults` storage; only the resolution rule moved.

**Don't re-add arithmetic here** — a second implementation's opinion is the thing
that was just deleted. This app has no XCTest target, so `spend-core`'s 28 Rust
tests are the first automated coverage this logic has ever had on the iOS side;
before, it was checkable only by hand through `-dumpSpending`.

### Two pinned tags, and the pair matters

`Cargo.toml` pins `bb-mobile-ffi` (**what ships**) and `bb-receipt-ffi` (only for
`shared/src/bin/batch_e2e.rs`, which uses the core's Rust API). **They must agree
on the core version** — `bb-mobile-ffi` pins the core itself, and a mismatch
makes cargo resolve two copies, with the xcframework linking the wrong one.
`Cargo.lock` is committed, so a duplicate `bb-receipt-ffi` entry there is the
tell. `CoreVersion.swift` still reports the *core* tag, which is what governs
parse behaviour.

### One library, two namespaces

`build-xcframework.sh` builds `bb-mobile-ffi` into `libbb_mobile_ffi.a`, which
carries both crates' UniFFI scaffolding, so one bindgen run emits **two** Swift
files and **two** modulemaps — concatenated into a single `module.modulemap`,
since a modulemap file may declare several modules. Both `.swift` files compile
into the *same* Swift module, which is why every type `mobile-ffi` exports is
prefixed `Spend`: a name shared with the parse core (`ItemTag`, `ReceiptItem`,
`Phase`, …) would be a redeclaration. The script hard-fails if bindgen emits
only one namespace — see `use bb_receipt_ffi as _;` in beanbeaver-mobile-util,
which is load-bearing and silent when removed.

## Working notes

- We always develop on an Apple-silicon (M-chip) MacBook, so the **x86_64 simulator
  slice is never needed** — don't build it (`INCLUDE_X86_SIM` stays off) and don't
  expect it in the xcframework. A plain `-destination 'generic/platform=iOS Simulator'`
  build fails to link x86_64; build the simulator with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
  (or target a specific arm64 simulator). Device builds are arm64 and unaffected.

- **After `build-xcframework.sh`, do a `clean` build — Xcode will not relink on its
  own.** The script replaces `sim.a`/`device.a` in place and the xcframework path
  never changes, so the incremental build sees no dirty input: `xcodebuild … build`
  prints **BUILD SUCCEEDED** and keeps the *previous* core inside
  `BeanBeaver.debug.dylib`. Everything else lies convincingly — `CoreVersion.swift`,
  `Cargo.lock`, and the `.a` itself all report the new tag while the app runs the old
  one, so a core bump looks like it silently had no effect. Verify what actually got
  linked:

      strings <App>.app/BeanBeaver.debug.dylib | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'

  A stale build installs on a device perfectly happily, so check this before trusting
  any on-device or simulator result that is supposed to exercise a new core.

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
