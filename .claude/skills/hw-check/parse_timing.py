#!/usr/bin/env python3
"""Parse the Gowin timing report for the hw-check skill.

Pulls the endpoint counts, per-clock Max Frequency Summary, per-clock Total
Negative Slack, the worst setup paths, and any negative-slack hold paths from
`camera_ov7670_tr_content.html`. Also runs the belt-and-braces scan of the
`*.timing_paths` critical-path file, and (when --prev is given) prints a
before/after delta for Fmax and the endpoint counts.

Usage:
    parse_timing.py [--report PATH] [--prev PATH] [--timing-paths PATH]

Defaults assume the cwd is the project root.
"""
import argparse
import html
import os
import re
import sys


def flatten(path):
    """Read an HTML report and collapse tags to '|' separators."""
    with open(path) as f:
        text = f.read()
    text = re.sub('<[^>]+>', '|', text)
    text = re.sub(r'\|+', '|', text)
    return html.unescape(text)


def grab_count(text, label):
    m = re.search(re.escape(label) + r'\|\s*\|(\d+)\|', text)
    return m.group(1) if m else "?"


def parse_counts(text):
    return {
        'analyzed': grab_count(text, 'Numbers of Endpoints Analyzed'),
        'setup_violated': grab_count(text, 'Numbers of Setup Violated Endpoints'),
        'hold_violated': grab_count(text, 'Numbers of Hold Violated Endpoints'),
    }


def parse_fmax(text):
    """Return {clock: (constraint, fmax, levels)}."""
    idx = text.find('Max Frequency Summary')
    end = text.find('Total Negative Slack', idx)
    block = text[idx:end]
    out = {}
    for m in re.finditer(
        r'\|\d+\|\s*\|([^|]+)\|\s*\|(Base|Generated)?\|?\s*\|?'
        r'([0-9.]+)\(MHz\)\|\s*\|([0-9.]+)\(MHz\)\|\s*\|(\d+)\|',
            block):
        clk, _, constraint, fmax, levels = m.groups()
        out[clk.strip()] = (float(constraint), float(fmax), int(levels))
    return out


def parse_tns(text):
    idx = text.find('Total Negative Slack Summary')
    end = text.find('Path Slacks Table', idx)
    block = text[idx:end]
    rows = []
    for m in re.finditer(
            r'\|([^|]+)\|\s*\|(Setup|Hold)\|\s*\|(-?[0-9.]+)\|\s*\|(\d+)\|', block):
        clk, kind, tns, n = m.groups()
        rows.append((clk.strip(), kind, float(tns), int(n)))
    return rows


def parse_setup_paths(text):
    idx = text.find('Setup Paths Table')
    end = text.find('Hold Paths Table', idx)
    block = text[idx:end]
    return re.findall(
        r'\|\d+\|\s*\|(-?\d+\.\d{3})\|\s*\|([^|]+)\|\s*\|([^|]+)\|\s*'
        r'\|([^|]+:\[[RF]\])\|\s*\|([^|]+:\[[RF]\])\|',
        block)


def parse_hold_paths(text):
    idx = text.find('Hold Paths Table')
    block = text[idx:idx + 8000]
    return re.findall(
        r'\|\d+\|\s*\|(-?\d+\.\d{3})\|\s*\|([^|]+)\|\s*\|([^|]+)\|', block)


def scan_timing_paths(path):
    """Belt-and-braces scan of the critical-path text file. Returns (setup<0, hold<0)."""
    if not os.path.isfile(path):
        return None
    setup = hold = 0
    mode = ""
    with open(path) as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip('\n')
        if line == '=====':
            mode = ""
        elif line in ('SETUP', 'HOLD'):
            i += 1
            if i < len(lines):
                try:
                    s = float(lines[i].strip())
                    if s < 0:
                        if line == 'SETUP':
                            setup += 1
                        else:
                            hold += 1
                except ValueError:
                    pass
        i += 1
    return setup, hold


def report(text, timing_paths_path):
    counts = parse_counts(text)
    print("=== Endpoint counts ===")
    print(f"  Analyzed:        {counts['analyzed']}")
    print(f"  Setup violated:  {counts['setup_violated']}")
    print(f"  Hold violated:   {counts['hold_violated']}")

    print("\n=== Max Frequency Summary ===")
    for clk, (cons, fmax, levels) in parse_fmax(text).items():
        margin = fmax / cons
        flag = "  OK" if margin > 1.05 else ("  TIGHT" if margin > 1.0 else "  *** FAIL ***")
        print(f"  {clk:40s} {cons:8.3f} -> {fmax:8.3f} MHz "
              f"(x{margin:.2f}, {levels} levels){flag}")

    print("\n=== Total Negative Slack ===")
    any_tns = False
    for clk, kind, tns, n in parse_tns(text):
        if tns != 0 or n > 0:
            any_tns = True
            print(f"  {clk:40s} {kind:5s} TNS={tns} ns over {n} endpoints  *** VIOLATION ***")
    print("  (entries with TNS=0 / 0 endpoints omitted)")

    print("\n=== Worst 3 setup paths ===")
    for slack, fn, tn, fc, tc in parse_setup_paths(text)[:3]:
        sign = " (VIOLATION)" if float(slack) < 0 else ""
        print(f"  slack={slack} ns  {fc.strip()} -> {tc.strip()}{sign}")
        print(f"    from: {fn.strip()}")
        print(f"    to:   {tn.strip()}")

    print("\n=== Negative-slack hold paths (worst 6) ===")
    neg_holds = [(s, fn, tn) for s, fn, tn in parse_hold_paths(text) if float(s) < 0]
    if neg_holds:
        for slack, fn, tn in neg_holds[:6]:
            print(f"  HOLD slack={slack}  to: {tn.strip()}")
        if len(neg_holds) > 6:
            print(f"  ... {len(neg_holds) - 6} more (trust the hold_violated count "
                  f"/ timing_paths scan; extras are unconstrained-reset residual)")
    else:
        print("  none")

    print("\n=== timing_paths critical-path file ===")
    scan = scan_timing_paths(timing_paths_path)
    if scan is None:
        print(f"  (file not found: {timing_paths_path})")
    else:
        print(f"  setup<0 = {scan[0]}, hold<0 = {scan[1]}")


def diff(cur_text, prev_text):
    print("\n=== Before/after delta ===")
    pc, cc = parse_counts(prev_text), parse_counts(cur_text)
    print("  Endpoint counts (prev -> cur):")
    for k in ('analyzed', 'setup_violated', 'hold_violated'):
        print(f"    {k:16s} {pc[k]} -> {cc[k]}")
    pf, cf = parse_fmax(prev_text), parse_fmax(cur_text)
    print("  Fmax (prev -> cur, delta MHz):")
    for clk in cf:
        cur = cf[clk][1]
        if clk in pf:
            prev = pf[clk][1]
            print(f"    {clk:15s} {prev:8.3f} -> {cur:8.3f}  ({cur - prev:+.3f})")
        else:
            print(f"    {clk:15s} (new) -> {cur:8.3f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--report', default='impl/pnr/camera_ov7670_tr_content.html')
    ap.add_argument('--prev', default=None,
                    help='previous report snapshot for before/after diff')
    ap.add_argument('--timing-paths', default='impl/pnr/camera_ov7670.timing_paths')
    args = ap.parse_args()

    if not os.path.isfile(args.report):
        sys.exit(f"timing report not found: {args.report}")

    text = flatten(args.report)
    report(text, args.timing_paths)

    if args.prev and os.path.isfile(args.prev):
        diff(text, flatten(args.prev))


if __name__ == '__main__':
    main()
