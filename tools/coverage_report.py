#!/usr/bin/env python3
"""
Toggle / FSM coverage report for LIBELLULA Core v22.
Parses a VCD produced by tb_coverage_full and reports per-module toggle coverage.

Usage:
    python3 coverage_report.py <vcd_file> [output_report.txt]

Exit code:
    0  coverage >= TOGGLE_PASS_PCT (default 70 %)
    1  coverage below threshold or VCD unreadable
"""

import sys, re, os
from collections import defaultdict, OrderedDict

TOGGLE_PASS_PCT = 70   # minimum acceptable toggle coverage %

# Signals to skip (test-infrastructure, clocks, resets — not RTL logic signals)
SKIP_NAMES = {'clk', 'rst', 'clk_i', 'rst_n'}

def parse_vcd(path):
    """Return (signals, toggles, last_vals).
    signals  : OrderedDict  id -> {name, width, scope}
    toggles  : dict         id -> int (number of value changes)
    last_vals: dict         id -> last value string (for toggle detection)
    """
    signals   = OrderedDict()
    toggles   = defaultdict(int)
    last_val  = {}
    scope     = []
    in_header = True

    with open(path, 'r', errors='replace') as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue

            if in_header:
                # $scope module <name> $end
                m = re.match(r'\$scope\s+\w+\s+(\S+)\s+\$end', line)
                if m:
                    scope.append(m.group(1))
                    continue

                # multi-token $scope across lines (rare, handle partially)
                if '$upscope' in line and '$end' in line:
                    if scope:
                        scope.pop()
                    continue

                # $var <type> <width> <id> <name> [<range>] $end
                m = re.match(r'\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)', line)
                if m:
                    width = int(m.group(1))
                    vid   = m.group(2)
                    name  = re.sub(r'\[.*\]$', '', m.group(3))  # strip bit-range suffix
                    if name not in SKIP_NAMES:
                        signals[vid] = {
                            'name' : name,
                            'width': width,
                            'scope': '.'.join(scope),
                        }
                    continue

                if '$enddefinitions' in line:
                    in_header = False
                continue

            # --- value section ---
            if line.startswith('#'):
                continue  # timestamp — ignore

            # Single-bit change: 0! or 1" etc.
            if line and line[0] in '01xzXZUuWwHL-':
                val = line[0]
                vid = line[1:].strip()
                if vid in signals:
                    prev = last_val.get(vid)
                    if prev is not None and prev != val:
                        toggles[vid] += 1
                    last_val[vid] = val
                continue

            # Bus change: b<val> <id>
            m = re.match(r'b([01xzXZUuWwHL]+)\s+(\S+)', line)
            if m:
                val = m.group(1)
                vid = m.group(2)
                if vid in signals:
                    prev = last_val.get(vid)
                    if prev is not None and prev != val:
                        toggles[vid] += 1
                    last_val[vid] = val

    return signals, toggles


def module_short(scope):
    """Return the last component of a dotted scope path."""
    return scope.split('.')[-1] if scope else '(top)'


def report(signals, toggles, vcd_path):
    lines = []
    lines.append("=" * 70)
    lines.append("  LIBELLULA Core v22 — Toggle Coverage Report")
    lines.append(f"  VCD source : {vcd_path}")
    lines.append("=" * 70)
    lines.append("")

    # Group by scope
    by_scope = defaultdict(list)
    for vid, info in signals.items():
        by_scope[info['scope']].append((vid, info, toggles.get(vid, 0)))

    total_sigs    = 0
    total_covered = 0

    for scope in sorted(by_scope.keys()):
        entries = by_scope[scope]
        covered = sum(1 for _, _, t in entries if t > 0)
        pct     = 100 * covered // max(len(entries), 1)
        lines.append(f"Module: {scope}  ({covered}/{len(entries)} = {pct}%)")
        lines.append(f"  {'Signal':<38} {'W':>3}  {'Toggles':>8}  Status")
        lines.append(f"  {'-'*38}  {'-'*3}  {'-'*8}  ------")
        for _, info, tog in sorted(entries, key=lambda x: x[1]['name']):
            status = "COVERED" if tog > 0 else "UNCOVERED"
            lines.append(f"  {info['name']:<38} {info['width']:>3}b  {tog:>8}  {status}")
        lines.append("")
        total_sigs    += len(entries)
        total_covered += covered

    overall_pct = 100 * total_covered // max(total_sigs, 1)
    lines.append("=" * 70)
    lines.append(f"SUMMARY: {total_covered}/{total_sigs} signals toggled  "
                 f"({overall_pct}% toggle coverage)")
    if total_sigs == 0:
        lines.append("WARNING: No signals found — check $dumpvars scope in VCD.")

    # FSM-like boolean signals of interest
    fsm_signals = {
        'initialized': "ab_predictor cold-start flag  (0=uninit → 1=tracking)",
        'gate_state':  "burst_gate hysteresis latch    (0=closed → 1=open)",
        'out_valid_int':"pipeline valid internal reg   (0→1 means spike propagated)",
    }
    lines.append("")
    lines.append("Key boolean / FSM-like state coverage:")
    for name, desc in fsm_signals.items():
        found = [(vid, tog) for vid, info, tog in
                 [(v, i, toggles.get(v, 0)) for v, i in signals.items()]
                 if signals[vid]['name'] == name]
        status = f"seen {len(found)} instance(s), toggled" if any(t > 0 for _, t in found) \
                 else "NOT TOGGLED (check stimulus)"
        lines.append(f"  {name:<20} {desc}")
        lines.append(f"    → {status}")
    lines.append("")

    result = '\n'.join(lines)
    threshold_ok = (overall_pct >= TOGGLE_PASS_PCT)
    verdict = "PASS" if threshold_ok else f"FAIL (below {TOGGLE_PASS_PCT}% threshold)"
    lines_final = result + f"\nVERDICT: {verdict}\n"
    return lines_final, threshold_ok


def main():
    if len(sys.argv) < 2:
        print("usage: coverage_report.py <vcd_file> [report.txt]", file=sys.stderr)
        sys.exit(1)

    vcd_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.exists(vcd_path):
        print(f"ERROR: VCD not found: {vcd_path}", file=sys.stderr)
        sys.exit(1)

    signals, toggles = parse_vcd(vcd_path)
    text, ok = report(signals, toggles, vcd_path)

    print(text)

    if out_path:
        with open(out_path, 'w') as f:
            f.write(text)
        print(f"Report written to {out_path}", file=sys.stderr)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
