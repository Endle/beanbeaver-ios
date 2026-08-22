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

- **Entry / shell** — `BeanBeaverApp.swift` (entry); `ContentView.swift` (the tab shell — it owns the app's state, every sheet, the export alert and the DEBUG deep links, and is still a **grab-bag** that also defines `SettingsView`, `ReceiptResultView`, `ReceiptCard`, `AccountingDetailsCard`, `OriginReceiptView`, `ScanTimingsView`); `RootTab.swift` (the three tabs, the raised Scan button, `BBLayout`); `HomeView.swift` (the home screen).
- **Scan pipeline** — `ReceiptPipeline.swift` (`BatchRunner`, `-autoRunBatch`), `ReceiptCaptureStore.swift`, `ReceiptBatch.swift`, `DocumentScanner.swift`, `BatchImportView.swift`.
- **Export / sync** — `LedgerExport.swift` (exporter seam), `LedgerSettingsView.swift` (the "Sync" page), backends `GitHubLedger.swift` / `GitHubDeviceFlow.swift` / `FilesLedgerInbox.swift`, and `MoneyManagerExport.swift` / `MoneyManagerWorkbook.swift`.
- **Support** — `Entitlements.swift` (`isPremium` seam); `DebugInfoStore.swift` (+`DebugInfoListView`) and `DataDump.swift` (+`DataDumpView`) = in-app debug capture; `ReceiptSlip.swift` (the header slip, `TornEdge`, `AmountPrivacyEye`, `DisplayAmount`); others self-named (`Keychain`, `Theme`, `ZoomableImageView`, `PhotoSaver`, `LaunchTiming`).

**New files must be added to `project.pbxproj` by hand.** The project uses
explicit file references with a hand-rolled id scheme (`1B…NN` =
`PBXFileReference`, `1C…NN` = `PBXBuildFile`), not Xcode 16's
`PBXFileSystemSynchronizedRootGroup`, so a `.swift` file dropped in the folder
is invisible to the build until it is listed in four places: the two sections
above, the group listing, and the compile phase. Ids are 24 hex characters —
a short one parses but Xcode will not open the project.

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

## The app opts out of iOS 26's design language

**`UIDesignRequiresCompatibility` is `true`** in `BeanBeaver/BeanBeaver/Info.plist`,
which makes the whole app render with the pre-iOS-26 look. It is there for one
reason: the tab bar.

The design calls for a **flat, full-width, opaque bar flush to the screen edge**
with a raised Scan circle sitting on it. On iOS 26 the system tab bar is a
floating inset glass capsule, and it is not configurable — this was established
by screenshot, not by reading documentation:

| Attempt | Result under iOS 26 |
|---|---|
| `UITabBarAppearance` + `configureWithOpaqueBackground` + `backgroundColor` | **pixel-identical output**, silently ignored |
| `UITabBar.appearance().unselectedItemTintColor` | ignored; the unselected item stays near-black instead of the design's grey |
| the flag | flat full-width bar, outlined icons, grey unselected item, no selection pill |

So there were three options: accept iOS 26's capsule and the four visual
differences it brings; hand-roll a bar and lose `TabView`'s accessibility,
selection semantics and safe-area handling; or set the flag. The flag was chosen
because it keeps the real `TabView` and every platform behaviour with it.

**Two things follow, and both are load-bearing.**

**1. The flag and `TabBarAppearance` are a pair.** The flag restores the flat bar
*and* restores the appearance proxy's authority over it. The flag alone gives a
correctly-shaped bar with **no fill at all**, transparent over the canvas with
nothing separating it from the content — which looks like a bug and is easy to
misdiagnose as a palette problem. `TabBarAppearance.apply()` (called from
`BeanBeaverApp.init`, before any window exists) is what paints it.

**2. This flag has an expiry date.** Apple ships it as a transitional aid for
apps that need a release cycle to adapt, and documents it as going away in a
future SDK. When it does, the app will silently start rendering with iOS 26's
design — nothing errors, nothing fails to build. What breaks, in order:

- the tab bar becomes a floating capsule and `RootTabBarAction`'s 15pt offset no
  longer fits it;
- `TabBarAppearance` becomes inert, so the bar loses the receipt palette;
- **`BBLayout.scanButtonClearance` becomes wrong by ~59pt.** The floating bar is
  *not* in the safe area and covers what is beneath it, so 24pt of clearance
  leaves the privacy footnote and both pinned export footers underneath the
  glass. It was 83pt for exactly that reason before the flag.

If a build ever comes back looking like the screenshots in the redesign PR
(#79) rather than the design, check this flag first.

## The tab shell

Home · Scan · Settings, in a real `TabView`. Three things are not obvious from
the code:

- **Scan is an action wearing a tab item.** Selecting it opens the document
  camera and leaves you on the tab you were already on — see
  `ContentView.tabSelection`. So there is no scan screen to restore, and
  Spending, Receipts and Import stay pushes *inside* Home rather than becoming
  tabs of their own. Its tab item is a **label with no icon**: the raised circle
  covers that slot, and `camera.viewfinder`'s lower brackets poked out from under
  it, which reads as a rendering fault.
- **The raised Scan circle is drawn, not configured.** `UITabBar` has no raised
  centre item, so `RootTabBarAction` overlays one on the middle slot. The tab
  item underneath stays live and does the same thing, so a metrics change
  mispositions a circle over a control that still works rather than breaking
  navigation.
- **Only the raised button needs bottom clearance, not the bar.** The bar is in
  the safe area, so the platform already stops content above it; the circle,
  drawn over the bar, is what a pinned export footer collides with. That is all
  `BBLayout.scanButtonClearance` is for — see the flag section above for what it
  has to become if the flag goes.

**The scan result is a full-screen modal over the whole shell**, bound to "the
pipeline is not idle" so scanning, failure and result are one presentation
rather than three. `Done` is withheld while scanning: `ReceiptPipeline.reset()`
clears the status but does not cancel the running task, so dismissing mid-scan
would have the finished result present itself again a second later.

**`Info.plist` is a partial, merged with the generated one.** The target keeps
`GENERATE_INFOPLIST_FILE = YES`; the checked-in file supplies only the keys the
`INFOPLIST_KEY_*` mechanism will not accept, and Xcode merges the generated keys
on top. Verified rather than assumed — the built `Info.plist` carries the flag
*and* `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`,
`UILaunchStoryboardName` and the rest. If that merge ever stopped happening the
app would lose its camera usage description and die on the first scan.

## The warm palette is light-mode only, on purpose

`Theme.swift`'s `bbCanvas` / `bbCardFill` / `bbInk` / `bbInkSecondary` /
`bbInkTertiary` / `bbHairline` are **pairs**, and the dark half of each is the
system colour the app used before. Dark mode was not designed, and inventing a
warm dark palette here would be a guess that ships; this way a dark build is
unchanged and a light build is the redesign. Anything derived from these — the
torn edge, the hairlines, the bar fills — follows automatically.

Two rules that came from contrast measurement, not taste:

- **`bbInkSecondary` (68%) is the floor for text under 18pt.** It clears 4.5:1
  on the card and the lighter values tried first did not.
- **`bbInkTertiary` (45%) is non-text only** — rules, chevrons, bar fills. Don't
  reach for it to quieten a label.

Scope: the redesigned surfaces (Home, Spending, Receipts, the scan result and
their pushes). `Form`-based pages — Settings, Sync — stay platform-standard.

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

`BudgetPrefs` keeps its `UserDefaults` storage, but **nothing reads it any
more** — the monthly budget was removed from this app with the tracker shift
(see `SpendingView`). It and the three `spend_*_budget_root` functions behind it
are deliberately left in place until `beanbeaver-android` drops its own budget
UI; android pins its own `bb-mobile-ffi` tag, so nothing there breaks meanwhile,
and whoever does that catch-up removes both sides together.

**The two figures under the slip's total are `spend_month_facts`** — the daily
average, what the same stretch of last month came to, and the two windows so the
view can name them ("Aug 1–21", "Jul 1–21") without re-deriving a month boundary
in Foundation. A separate call rather than fields on `spend_month`, which takes
no date and is pure over records; the cost is a third FFI crossing on the one
screen that needs all three.

**The weekly trend is `spend_trend`**, one call per screen returning the six
weekly points, the mean, the week-over-week delta and the rolling 30-day figure,
for all spending or one category. Both screens draw it as **bars** (`TrendBars`),
not the line `TrendChart` still provides: six weekly buckets are discrete totals,
and a line both implies readable values between them and hides that the newest
bucket is a partial week. Two things about it are easy to get wrong:

- `firstWeekday` is ICU numbering (`1 = Sunday`), which
  `Calendar.current.firstWeekday` gives directly. Kotlin's `DayOfWeek` is
  `MONDAY = 1` and must be converted — silent when wrong.
- The delta is **week-to-date against the same span last week**, not the newest
  bucket minus the one before. The newest bucket is a partial week six days out
  of seven, so the naive comparison reads as a steep fall every Monday.

**Masking hides the charts, not just the figures.** `hideAmounts` is on by
default and a line whose height encodes dollars leaks the shape of a month even
with every figure replaced by `$•••`. `TrendChart.masked()` is the placeholder
that keeps the card from jumping when the eye is tapped.

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
