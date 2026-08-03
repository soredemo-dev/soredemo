#!/usr/bin/env python3
"""Freeze the probe's checks as an ordered enumeration, so an index means one thing.

Why the enumeration is stored and not just the sample. The checks are sampled to
estimate how much of the suite is decoration, and a sample is only re-checkable
if "number 47" still names the same check next week. Execution order is not a
stable key: sections get reordered, a helper moves, and the 47th check to RUN
changes without anyone touching a check. Sorting by (file, line) and writing the
whole list down makes the index a property of the source rather than of a run.

Usage:
    scripts/enumerate-probe-checks.py            print the enumeration
    scripts/enumerate-probe-checks.py --sample N --seed S    draw a sample

The sample is drawn from the frozen list by index, with the seed printed, so the
draw is reproducible and — the point — is made BEFORE anyone looks at what the
checks say. Picking as you go drifts toward the checks you can bring to mind,
which are the better-written ones, and that bias runs one way: it makes the
suite look less decorative than it is.
"""
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "scripts" / "cross-boundary-digest-probe.swift",
]

# A `check(` call site. The probe's own helper is `check(_:_:actual:expected:)`,
# and `step.check(` in the spikes is a different thing counted elsewhere.
CALL = re.compile(r"(?<![.\w])check\s*\(")


def enumerate_checks():
    rows = []
    for path in SOURCES:
        text = path.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            if stripped.startswith("func check") or "func check(" in stripped:
                continue
            if CALL.search(line):
                rows.append((str(path.relative_to(ROOT)), lineno, stripped[:110]))
    rows.sort(key=lambda r: (r[0], r[1]))
    return rows


def main():
    rows = enumerate_checks()
    args = sys.argv[1:]

    if "--sample" not in args:
        for i, (f, ln, text) in enumerate(rows, start=1):
            print(f"{i:4d}  {f}:{ln}  {text}")
        refusal = sum(1 for _, _, t in rows if t.replace(" ", "").startswith("check(false"))
        print(f"\n{len(rows)} check call sites, ordered by (file, line).")
        print(f"  of which {refusal} are `check(false, …)` — refusal branches a PASSING run never takes.")
        print()
        print("This does not match the probe's own reported count, and neither number is wrong: they")
        print("are different populations. The probe counts checks that RAN on one pass; this counts")
        print("checks that are WRITTEN. Loops make some sites run more than once, and refusal branches")
        print("make some sites run not at all.")
        print()
        print("The sample frame is this one — the written checks — because a check that never executes")
        print("is the strongest form of decoration there is, and dropping it from the frame biases the")
        print("estimate in exactly the direction that flatters the suite.")
        return

    n = int(args[args.index("--sample") + 1])
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 20260803
    if n > len(rows):
        print(f"asked for {n} of {len(rows)} — refusing rather than sampling with replacement",
              file=sys.stderr)
        sys.exit(2)

    rng = random.Random(seed)
    picks = sorted(rng.sample(range(1, len(rows) + 1), n))
    print(f"seed {seed}, {n} drawn from {len(rows)} by index, before reading any of them\n")
    for i in picks:
        f, ln, text = rows[i - 1]
        print(f"{i:4d}  {f}:{ln}\n      {text}")
    print(f"\nReport the result as a count out of {n}, never as a percentage: {n} is far too few to")
    print("carry one, and a percentage travels away from its denominator. D2-17's 1321 is how.")


if __name__ == "__main__":
    main()
