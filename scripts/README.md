# E2E / perf scripts

Harnesses that push receipt fixtures through the app's **real** scan pipeline
(Rust `ocr-paddle` → parse), instead of feeding the parser pre-recorded OCR the
way the desktop `cargo`/pytest suites do. This is the only place the on-device
OCR layer is exercised — where OCR-shaped bugs (skew, column misalignment) that
cached `.ocr.json` snapshots can't reproduce actually show up.

| Script | What it drives | Use for |
|---|---|---|
| `sim-e2e.sh <dir> [pilot\|--all]` | booted **simulator**, live OCR, diff vs `expected.json` | correctness / parse quality |
| `sim-e2e-private.sh [dir] [mode]` | `sim-e2e.sh` pointed at the **private** corpus | correctness on PII cases (manual) |
| `device-e2e.sh <dir> [--all]` | a connected **iPhone** (`devicectl`) | performance (perf doesn't transfer sim→phone) |
| `compare-e2e.py` | diffs `batch_out.json` vs `expected.json` | shared by the above; same asserts as the desktop pytest |
| `launch-timing.sh`, `device-latency.py` | launch / per-stage timings | perf profiling |

A case is any `<stem>.jpg` with a sibling `<stem>.expected.json`. The harness
copies selected images into the app container's `Documents/batch_in/`, launches
`-autoRunBatch` (see `BatchRunner` in `ReceiptPipeline.swift`), waits for
`Documents/batch_out.json`, then runs `compare-e2e.py`.

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

`sim-e2e-private.sh` passes that file to `compare-e2e.py --private-rules`, which
**tolerates** exactly those items' category assertions (their expected
description contains a private keyword). Everything else stays enforced —
description, price, and every public-rule category — so a genuine public-rule
category **regression** still fails. Because the tolerated set is derived from
`private_rules.toml` (itself a debt list meant to trend to empty), the sim path
tightens automatically as that debt is burned down. No separate override file to
maintain.

This is complementary to — not a replacement for — the fast desktop cached suite;
keep using that for the tight loop, and this for the occasional high-fidelity pass.
