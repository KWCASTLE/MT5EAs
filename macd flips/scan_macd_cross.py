#!/usr/bin/env python3
"""
scan_macd_cross.py

Scans a Wavecrest debug log for MACD ordering swaps.

This version auto-detects file encoding via BOM and falls back to common encodings
if no BOM is present. You can override detection with --encoding.

Usage:
  py -3 .\scan_macd_cross.py .\wavecrest_debug_raw.txt
  py -3 .\scan_macd_cross.py .\wavecrest_debug_raw.txt --encoding utf-16
  py -3 .\scan_macd_cross.py .\wavecrest_debug_raw.txt --no-abs
"""
import re
import sys
import argparse
from math import fabs

macd_re = re.compile(r"^(?P<ts>[^,]+),MACD_DEBUG,(?P<body>.*)$")
sig_prev_re = re.compile(r"signal_prev=([+\-0-9.eE]+)")
sig_now_re  = re.compile(r"signal_now=([+\-0-9.eE]+)")
main_prev_re= re.compile(r"main_prev=([+\-0-9.eE]+)")
main_now_re = re.compile(r"main_now=([+\-0-9.eE]+)")

def detect_encoding_from_bom(b):
    # b is bytes (at least first 4 bytes)
    if b.startswith(b'\xef\xbb\xbf'):
        return 'utf-8-sig'
    if b.startswith(b'\xff\xfe\x00\x00') or b.startswith(b'\x00\x00\xfe\xff'):
        return 'utf-32'
    if b.startswith(b'\xff\xfe') or b.startswith(b'\xfe\xff'):
        return 'utf-16'
    return None

def read_text_file_with_auto_encoding(path, override_encoding=None):
    raw = open(path, 'rb').read()
    if override_encoding:
        enc = override_encoding
    else:
        enc = detect_encoding_from_bom(raw[:4])
        if not enc:
            # try utf-8 first, then common Windows cp1252
            for try_enc in ('utf-8', 'utf-16', 'cp1252'):
                try:
                    raw.decode(try_enc)
                    enc = try_enc
                    break
                except Exception:
                    continue
            if not enc:
                # last resort
                enc = 'latin-1'
    try:
        text = raw.decode(enc, errors='replace')
    except Exception:
        # extremely defensive fallback
        text = raw.decode('latin-1', errors='replace')
        enc = 'latin-1'
    return text.splitlines(), enc

def float_or_none(m):
    try:
        return float(m)
    except Exception:
        return None

def parse_args():
    p = argparse.ArgumentParser(description="Scan wavecrest debug for MACD ordering swaps")
    p.add_argument('fname', nargs='?', default='wavecrest_debug_raw.txt', help='debug log file')
    p.add_argument('--no-abs', dest='no_abs', action='store_true', help='use signed comparisons instead of absolute')
    p.add_argument('--encoding', dest='encoding', default=None, help='force file encoding (e.g. utf-8, utf-16, cp1252)')
    return p.parse_args()

def main():
    args = parse_args()
    fname = args.fname
    use_abs = not args.no_abs

    try:
        lines, chosen_enc = read_text_file_with_auto_encoding(fname, override_encoding=args.encoding)
    except FileNotFoundError:
        print(f"File not found: {fname}", file=sys.stderr)
        sys.exit(2)

    print(f"Reading '{fname}' using encoding: {chosen_enc}")

    matches = []
    for i, line in enumerate(lines, start=1):
        s = line.rstrip("\n")
        m = macd_re.match(s)
        if not m:
            continue
        ts = m.group("ts")
        body = m.group("body")
        sp_m = sig_prev_re.search(body)
        sn_m = sig_now_re.search(body)
        mp_m = main_prev_re.search(body)
        mn_m = main_now_re.search(body)
        if not (sp_m and sn_m and mp_m and mn_m):
            continue
        spv = float_or_none(sp_m.group(1))
        snv = float_or_none(sn_m.group(1))
        mpv = float_or_none(mp_m.group(1))
        mnv = float_or_none(mn_m.group(1))
        if None in (spv, snv, mpv, mnv):
            continue

        if use_abs:
            cond = (fabs(mpv) > fabs(spv)) and (fabs(snv) > fabs(mnv))
        else:
            cond = (spv < mpv) and (snv > mnv)

        if cond:
            matches.append((i, ts, spv, mpv, snv, mnv, s))

    if not matches:
        print("No MACD_DEBUG lines matched the ordering condition.")
        return

    print(f"Found {len(matches)} matching MACD_DEBUG lines:\n")
    print(f"{'Line':>6} {'Timestamp':20} {'signal_prev':>12} {'main_prev':>12} {'signal_now':>12} {'main_now':>12}")
    for idx, ts, spv, mpv, snv, mnv, full in matches:
        print(f"{idx:6} {ts:20} {spv:12.8f} {mpv:12.8f} {snv:12.8f} {mnv:12.8f}")
    print("\nDetailed lines follow:\n")
    for idx, ts, spv, mpv, snv, mnv, full in matches:
        print(f"Line {idx}  Timestamp: {ts}")
        print(f"  signal_prev = {spv}    main_prev = {mpv}")
        print(f"  signal_now  = {snv}    main_now  = {mnv}")
        print(f"  Full line: {full}")
        print("-"*80)

if __name__ == "__main__":
    main()