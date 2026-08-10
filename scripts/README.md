# E2E / perf scripts

Harnesses that push receipt fixtures through the app's **real** scan pipeline
(Rust `ocr-paddle` → parse), instead of feeding the parser pre-recorded OCR the
way the desktop `cargo`/pytest suites do. This is the only place the on-device
OCR layer is exercised — where OCR-shaped bugs (skew, column misalignment) that
cached `.ocr.json` snapshots can't reproduce actually show up.

| Script | What it drives | Use for |
|---|---|---|
| `host-e2e.sh [dir]` | **this Mac** — no sim, no Xcode, no app | fast parser check after a core bump |
| `sim-e2e.sh <dir> [pilot\|--all]` | booted **simulator**, live OCR, diff vs `expected.json` | correctness / parse quality |
| `sim-e2e-private.sh [dir] [mode]` | `sim-e2e.sh` pointed at the **private** corpus | correctness on PII cases (manual) |
| `device-e2e.sh <dir> [--all]` | a connected **iPhone** (`devicectl`) | performance (perf doesn't transfer sim→phone) |
| `../shared/scripts/compare-e2e.py` | diffs `batch_out.json` vs `expected.json` | shared by all of the above, **and by Android** — it lives in the `shared/` submodule |
| `launch-timing.sh`, `device-latency.py` | launch / per-stage timings | perf profiling |

A case is any `<stem>.jpg` with a sibling `<stem>.expected.json`. The on-device
harnesses copy selected images into the app container's `Documents/batch_in/`,
launch `-autoRunBatch` (see `BatchRunner` in `ReceiptPipeline.swift`), wait for
`Documents/batch_out.json`, then run `compare-e2e.py`.

## `host-e2e.sh` — and what it can't tell you

`host-e2e.sh` runs the same fixtures through the same core and the same grader
with **no simulator in the loop**: `batch_e2e` (a Rust bin whose source is shared
with Android, in `shared/src/bin/`) scans the images directly. It's seconds
rather than minutes, so it's the right first check after bumping the core tag.

What it does **not** exercise is everything above the Rust: the UniFFI Swift
bindings, `ReceiptScanner.swift`, `BatchRunner`, the app's ledger defaults. A
green `host-e2e.sh` and a broken app are entirely compatible — see the note in
`../CLAUDE.md` about Xcode not relinking after `build-xcframework.sh`. Use
`sim-e2e.sh` before you believe the app works.

It accepts any directory, so the private corpus works too:

```sh
PRIVATE_RULES=../beanbeaver-private-test/private_rules.toml \
  scripts/host-e2e.sh ../beanbeaver-private-test/receipts_e2e
```

## Private corpus (manual, macOS-only)

`sim-e2e-private.sh` runs the receipts that are too PII-sensitive to publish
through the sim in live mode. It's **slow** (real OCR over the whole corpus) and
needs fixtures that don't exist in CI, so it never runs in CI — start it by hand
and read the table.

```sh
# boot a sim + build once (see sim-e2e.sh header), then:
scripts/sim-e2e-private.sh                    # sibling ../beanbeaver-private-test
BB_PRIVATE_DIR=/path/to/beanbeaver-private-test scripts/sim-e2e-private.sh
```

**Firewall:** the PII fixtures (`receipts_e2e/`) and `private_rules.toml` stay in
the **private** repo (`beanbeaver-private-test`). This runner references them by
**path** only — nothing private is committed here.

### Categories are compared public-rules-only

The desktop suite resolves item categories from beanbeaver's **public** rules
**plus** the private suite's `private_rules.toml`. The shipping app bundles only
the public rules and can't inject private ones at runtime, so any expected
category that comes from `private_rules.toml` can't reproduce on-device.

`sim-e2e-private.sh` (and `host-e2e.sh`, via `PRIVATE_RULES`) passes that file to
`compare-e2e.py --private-rules`, which
**tolerates** exactly those items' category assertions (their expected
description contains a private keyword). Everything else stays enforced —
description, price, and every public-rule category — so a genuine public-rule
category **regression** still fails. Because the tolerated set is derived from
`private_rules.toml` (itself a debt list meant to trend to empty), the sim path
tightens automatically as that debt is burned down. No separate override file to
maintain.

This is complementary to — not a replacement for — the fast desktop cached suite;
keep using that for the tight loop, and this for the occasional high-fidelity pass.
