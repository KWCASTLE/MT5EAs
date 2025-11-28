#!/usr/bin/env python3
"""
Scan wavecrest_debug_raw.txt for MACD "swap" cases where the relative ordering
of absolute values trades places between prev and now.

Usage:
    python3 scan_macd_flips.py wavecrest_debug_raw.txt

Output:
    Lines containing timestamp, type (BUY/SELL candidate), main_prev, signal_prev,
    main_now, signal_now, hist_prev, hist_now, and the DECISION_SUMMARY line (if present).
"""
import sys
import re
from pathlib import Path

MACD_RE = re.compile(r'^(?P<ts>\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}),MACD_DEBUG,(.+)$|^(?P<ts2>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),MACD_DEBUG,(.+)$')
KV_RE = re.compile(r'([a-zA-Z_]+)=(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)')
DECISION_RE = re.compile(r'^(?P<ts>\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}),DECISION_SUMMARY,(?P<body>.*)$|^(?P<ts2>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),DECISION_SUMMARY,(?P<body2>.*)$')

def parse_kv(body):
    d = {}
    for m in KV_RE.finditer(body):
        key = m.group(1)
        val = float(m.group(2))
        d[key] = val
    return d

def normalize_ts(match):
    if not match:
        return None, None
    if match.group('ts'):
        return match.group('ts'), match.group(2)
    return match.group('ts2'), match.group(4)

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scan_macd_flips.py wavecrest_debug_raw.txt")
        return
    path = Path(sys.argv[1])
    if not path.exists():
        print("File not found:", path)
        return

    decision_map = {}
    macd_hits = []

    with path.open('r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip("\n")
            # DECISION_SUMMARY
            dm = DECISION_RE.match(line)
            if dm:
                ts = dm.group('ts') or dm.group('ts2')
                body = dm.group('body') or dm.group('body2') or ''
                decision_map[ts] = body
                continue
            # MACD_DEBUG
            mm = MACD_RE.match(line)
            if not mm:
                continue
            ts = mm.group('ts') or mm.group('ts2')
            body = mm.group(2) or mm.group(4) or ''
            kv = parse_kv(body)
            # required keys
            required = ('main_prev','main_now','signal_prev','signal_now','hist_prev','hist_now')
            if not all(k in kv for k in required):
                continue
            mp = kv['main_prev']; mn = kv['main_now']
            sp = kv['signal_prev']; sn = kv['signal_now']
            histp = kv['hist_prev']; histn = kv['hist_now']

            # BUY candidate: |main_prev| > |signal_prev|  AND  |signal_now| > |main_now|
            if abs(mp) > abs(sp) and abs(sn) > abs(mn):
                macd_hits.append((ts, 'BUY_CANDIDATE', mp, sp, mn, sn, histp, histn, decision_map.get(ts,'')))
                continue
            # SELL candidate
            if abs(sp) > abs(mp) and abs(mn) > abs(sn):
                macd_hits.append((ts, 'SELL_CANDIDATE', mp, sp, mn, sn, histp, histn, decision_map.get(ts,'')))
                continue

    if not macd_hits:
        print("No candidate flips found.")
        return

    for hit in macd_hits:
        ts, kind, mp, sp, mn, sn, histp, histn, decision = hit
        print("-----")
        print(f"{ts}  {kind}")
        print(f"  main_prev = {mp:.8f}, signal_prev = {sp:.8f}, hist_prev = {histp:.8f}")
        print(f"  main_now  = {mn:.8f}, signal_now  = {sn:.8f}, hist_now  = {histn:.8f}")
        if decision:
            print("  DECISION_SUMMARY:", decision)
        else:
            print("  DECISION_SUMMARY: <none logged for this exact timestamp>")
    print("-----")
    print(f"Total candidates: {len(macd_hits)}")

if __name__ == '__main__':
    main()