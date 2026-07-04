#!/usr/bin/env python3
"""Summarize per-stage on-device scan latency from batch_out.json.

The on-device counterpart of ocr-paddle's `print_latency`: reads the BatchRunner
output (which now carries per-stage ScanTimings), and prints mean / p50 / worst
for each stage plus the Swift-observed wall time. This is the serial baseline the
recognition-loop parallelism work is judged against.

Usage: device-latency.py <batch_out.json>
"""
import json
import sys
from statistics import mean, median

STAGES = [
    ("prep", "prepMs"),
    ("detect", "detectMs"),
    ("classify", "classifyMs"),
    ("recognize", "recognizeMs"),
    ("parse", "parseMs"),
    ("rust total", "totalMs"),
]


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "batch_out.json"
    data = json.load(open(path))
    results = data.get("results", [])
    scans = [r for r in results if r.get("timings") and not r.get("error")]
    failed = [r for r in results if r.get("error")]

    if not scans:
        print("no successful scans with timings found")
        return 1

    n = len(scans)
    print(f"{n} scan(s)" + (f", {len(failed)} failed" if failed else ""))
    print(f"{'stage':<12}{'mean':>9}{'p50':>9}{'worst':>9}   (ms)")
    print("-" * 48)

    def col(key, src):
        vals = [float(src(r)) for r in scans]
        return mean(vals), median(vals), max(vals)

    for label, key in STAGES:
        m, p, w = col(key, lambda r, k=key: r["timings"][k])
        print(f"{label:<12}{m:>9.1f}{p:>9.1f}{w:>9.1f}")

    m, p, w = col("wallMs", lambda r: r["wallMs"])
    print(f"{'wall':<12}{m:>9.1f}{p:>9.1f}{w:>9.1f}   (incl. decode + FFI)")

    # The headline for the parallelism decision: recognize as a share of the
    # Rust pipeline. If this isn't dominant, inter-crop parallelism won't pay.
    rec = mean(r["timings"]["recognizeMs"] for r in scans)
    tot = mean(r["timings"]["totalMs"] for r in scans)
    if tot > 0:
        print(f"\nrecognize = {rec / tot * 100:.0f}% of rust total (mean)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
