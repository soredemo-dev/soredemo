#!/usr/bin/env python3
"""How often does a click land on something the accessibility API can NAME?

The whole "a recording is a semantic trajectory, not pixels" argument rests on this number, and
nobody has published it. A hit test that returns nothing, or an element with no title, is a click
this project can draw a zoom for and cannot describe.

**Read from real recordings rather than probed from outside, and that is not a preference.**
Three external probes were written first and each was wrong in its own way: one counted a failed
attribute read as an absent title, one hit-tested the screen and attributed another app's window
to the app being measured, and one walked a Chromium stub tree without asking for the real one.
The numbers moved 0% -> 32% -> 15% across those attempts.

Soredemo's own recorder has none of those failure modes: it hit-tests at the point a person
actually clicked, with the target app frontmost, and records why a chain was truncated. So the
honest way to get this number is to record for five minutes and read the log.

    scripts/ax-coverage.py <recording.soredemo | directory of them>

Titles are REDACTED by `redact-observation-log.swift`, so run this on an unredacted log — on
your own machine, against your own recording. Nothing here uploads anything.
"""

import collections
import json
import pathlib
import sys


def records(root: pathlib.Path):
    for path in sorted(root.rglob("*.jsonl")):
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield path, number, json.loads(line)
            except json.JSONDecodeError:
                continue


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = pathlib.Path(sys.argv[1]).expanduser()
    if not root.exists():
        print(f"no such path: {root}")
        return 2

    chains = [r for _, _, r in records(root) if r.get("kind") == "axChain"]
    if not chains:
        print(f"no axChain records under {root}")
        print("A recording made before the observation log existed has none, and a recording")
        print("made without the Accessibility grant has none either — which is a different")
        print("thing and worth telling apart before reading anything into a zero.")
        return 1

    truncation = collections.Counter(c.get("truncation", "—") for c in chains)
    roles = collections.Counter()
    named = 0
    anonymous = 0
    nothing = 0
    ancestors = []

    for chain in chains:
        hit = chain.get("hit")
        if not hit:
            nothing += 1
            continue
        roles[hit.get("role") or "—"] += 1
        ancestors.append(len(chain.get("ancestors") or []))
        if hit.get("title"):
            named += 1
        else:
            anonymous += 1

    total = len(chains)

    def share(part):
        return f"{part / total * 100:.0f}%" if total else "—"

    print(f"{total} clicks with an AX chain, from {root}\n")
    print(f"  hit nothing at all      {nothing:5d}  {share(nothing)}")
    print(f"  hit something, no title {anonymous:5d}  {share(anonymous)}")
    print(f"  hit something NAMED     {named:5d}  {share(named)}   <- the number that matters")
    if ancestors:
        print(f"\n  ancestors per chain: median {sorted(ancestors)[len(ancestors) // 2]}, "
              f"max {max(ancestors)}")

    print("\nwhy the walk stopped:")
    for reason, count in truncation.most_common():
        print(f"  {reason:24s} {count:5d}  {share(count)}")

    print("\nwhat was under the click:")
    for role, count in roles.most_common(12):
        print(f"  {role:24s} {count:5d}  {share(count)}")

    # A container is not a control. Named or not, `AXGroup` does not say what was pressed, and a
    # trajectory made of anonymous groups is a trajectory only in the sense that a list of
    # coordinates is one.
    containers = sum(count for role, count in roles.items()
                     if role in {"AXGroup", "AXScrollArea", "AXSplitGroup", "AXUnknown", "—"})
    print(f"\n  of what was hit, {share(containers)} was a container rather than a control")
    return 0


if __name__ == "__main__":
    sys.exit(main())
