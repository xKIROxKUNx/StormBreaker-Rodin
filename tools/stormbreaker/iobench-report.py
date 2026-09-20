#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Summarise iobench runs into a scheduler comparison.

Input: the file written by the on-device driver, one run per line:

    <rep> <sched> <bg> <n> <iops> <avg> <p50> <p95> <p99> <p999> <max>

Reports the median across repetitions -- not the mean, because a single
thermal-throttling or background-app excursion would drag a mean around while
the median ignores it. Percentiles matter more than IOPS here: what a user
feels when an app launches is the tail, not the average.

Usage: iobench-report.py <bench.txt>
"""

import statistics
import sys
from collections import defaultdict

FIELDS = ["n", "iops", "avg", "p50", "p95", "p99", "p999", "max"]


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2

    runs = defaultdict(list)
    meta = []
    for line in open(argv[1], encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line == "DONE":
            continue
        if line.startswith("#"):
            meta.append(line.lstrip("# ").rstrip())
            continue
        parts = line.split()
        if len(parts) != 3 + len(FIELDS):
            print(f"skipping malformed line: {line}", file=sys.stderr)
            continue
        _rep, sched, bg = parts[0], parts[1], int(parts[2])
        try:
            vals = [int(x) for x in parts[3:]]
        except ValueError:
            print(f"skipping unparsable line: {line}", file=sys.stderr)
            continue
        runs[(bg, sched)].append(dict(zip(FIELDS, vals)))

    for m in meta:
        print(f"  {m}")
    print()

    if not runs:
        print("no usable runs", file=sys.stderr)
        return 1

    bgs = sorted({bg for bg, _ in runs})
    scheds = sorted({s for _, s in runs})

    for bg in bgs:
        label = "ocioso" if bg == 0 else f"{bg} leitores de fundo"
        print(f"=== concorrencia: {label} ===")
        print(f"  {'scheduler':<12} {'iops':>7} {'p50':>6} {'p95':>6} "
              f"{'p99':>7} {'p99.9':>7} {'max':>8}")
        rows = {}
        for s in scheds:
            rr = runs.get((bg, s))
            if not rr:
                continue
            med = {f: int(statistics.median(r[f] for r in rr)) for f in FIELDS}
            rows[s] = med
            print(f"  {s:<12} {med['iops']:>7} {med['p50']:>6} {med['p95']:>6} "
                  f"{med['p99']:>7} {med['p999']:>7} {med['max']:>8}")

        # The decision is adios vs the vendor's choice; state it in percent so
        # the size of the effect is visible, not just its direction.
        if "adios" in rows and "mq-deadline" in rows:
            a, d = rows["adios"], rows["mq-deadline"]
            print()
            print("  adios vs mq-deadline (negativo = adios melhor):")
            for f in ("iops", "p50", "p95", "p99", "p999"):
                if not d[f]:
                    continue
                delta = (a[f] - d[f]) / d[f] * 100.0
                better = (delta > 0) if f == "iops" else (delta < 0)
                mark = "  <-- adios melhor" if better and abs(delta) >= 5 else ""
                print(f"    {f:<6} {delta:+6.1f}%{mark}")
        print()

    print("Leitura: p99 e p99.9 sao o que o usuario sente na abertura de app.")
    print("Diferenca abaixo de ~5% em percentis esta dentro do ruido desta")
    print("medicao e nao justifica sobrepor a escolha do fabricante.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
