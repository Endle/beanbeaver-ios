#!/usr/bin/env python3
"""Diff on-device batch results against ground-truth expected.json fixtures.

Consumes the `batch_out.json` produced by the app's `-autoRunBatch` harness
(see ReceiptPipeline.swift / BatchRunner) plus a manifest mapping each result
`name` to its `<stem>.expected.json`, and applies the same assertions as the
desktop pytest suite (test_e2e_receipts.py): fuzzy merchant, exact date/total,
and critical-item description/price/category checks, honoring `known_failures`.

Usage:
  compare-e2e.py --results batch_out.json --manifest manifest.json
"""
import argparse
import json
import sys
from decimal import Decimal, InvalidOperation
from difflib import SequenceMatcher


def norm_merchant(v: str) -> str:
    return "".join(ch for ch in (v or "").upper() if ch.isalnum())


def merchant_matches(expected: str, actual: str, any_of) -> bool:
    e, a = norm_merchant(expected), norm_merchant(actual)
    if not e or not a:
        return False
    if e in a or a in e:
        return True
    for alt in any_of or []:
        n = norm_merchant(alt)
        if n and (n in a or a in n):
            return True
    return SequenceMatcher(None, e, a).ratio() >= 0.85


def dec(v):
    try:
        return Decimal(str(v))
    except (InvalidOperation, TypeError):
        return None


def check_merchant(res, exp):
    if "merchant" not in exp:
        return None
    if exp.get("merchant_optional"):
        return True
    return merchant_matches(exp["merchant"], res.get("merchant", ""), exp.get("merchant_any_of"))


def check_date(res, exp):
    if "date" not in exp:
        return None
    return res.get("date") == exp["date"]


def check_total(res, exp):
    if "total" not in exp:
        return None
    return dec(res.get("total")) is not None and dec(res.get("total")) == dec(exp["total"])


def check_items(res, exp):
    crit = exp.get("critical_items")
    if not crit:
        return None
    by_desc = {}
    for it in res.get("items", []):
        by_desc.setdefault((it.get("description") or "").upper(), []).append(it)
    for c in crit:
        pat = c["description"].upper()
        want_price = dec(c["price"])
        matches = [it for d, its in by_desc.items() if pat in d or d in pat for it in its]
        if not matches:
            return False
        prices = [dec(it.get("price")) for it in matches]
        if want_price not in prices:
            return False
        want_cat = c.get("category")
        if want_cat and not c.get("category_optional"):
            cats = [it.get("category") or "" for it in matches if dec(it.get("price")) == want_price]
            if not any(want_cat in cat for cat in cats):
                return False
    return True


CHECKS = [("merchant", check_merchant), ("date", check_date),
          ("total", check_total), ("critical_items", check_items)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()

    results = {r["name"]: r for r in json.load(open(args.results))["results"]}
    manifest = json.load(open(args.manifest))

    rows, total_fail = [], 0
    for name in sorted(manifest):
        exp = json.load(open(manifest[name]))
        res = results.get(name)
        known = set(exp.get("known_failures", []))
        if res is None:
            rows.append((name, "NO RESULT", {}, "—"))
            total_fail += 1
            continue
        if res.get("error"):
            rows.append((name, "SCAN ERROR", {}, res["error"][:40]))
            total_fail += 1
            continue
        outcomes = {}
        case_bad = 0
        for field, fn in CHECKS:
            ok = fn(res, exp)
            if ok is None:
                continue
            if ok:
                outcomes[field] = "PASS" if field not in known else "PASS!"  # unexpected pass
            else:
                outcomes[field] = "pass" if field in known else "FAIL"       # tolerated / real
                if field not in known:
                    case_bad += 1
        verdict = "ok" if case_bad == 0 else f"{case_bad} FAIL"
        total_fail += case_bad
        detail = f"{res.get('merchant','')[:16]} {res.get('date','?')} ${res.get('total','?')} ({len(res.get('items',[]))} items, {int(res.get('wallMs',0))}ms)"
        rows.append((name, verdict, outcomes, detail))

    w = max((len(r[0]) for r in rows), default=10)
    print(f"\n{'case':<{w}}  {'verdict':<8}  {'m/d/t/items':<16}  detail")
    print("-" * (w + 60))
    for name, verdict, outcomes, detail in rows:
        flags = "/".join(outcomes.get(f, "-")[:4] for f, _ in CHECKS)
        print(f"{name:<{w}}  {verdict:<8}  {flags:<16}  {detail}")
    passed = sum(1 for r in rows if r[1] in ("ok",))
    print(f"\n{passed}/{len(rows)} cases fully pass; {total_fail} field assertion(s) failed.")
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
