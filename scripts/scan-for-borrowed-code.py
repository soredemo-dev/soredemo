#!/usr/bin/env python3 -I
"""Is any of this project's Swift someone else's?

Compares every Swift file in this repository against every Swift file in the nearest opensource/
folder above it, twice:

  1. runs of EXACT lines (comments and whitespace removed) — catches a paste;
  2. runs of the same SHAPE, with every identifier, string and number erased — catches a paste with
     the names changed, which is how the one case this project has had was written
     (docs/design/2026-11-11-caption-line-breaking.md).

A shared run is printed with both paths and is a question for a person, not a verdict: an idiom
every Swift programmer writes the same way can match. Exit 1 when anything is shared, 2 when nothing
was read on either side — a scan that read nothing would otherwise report "clean".

Checkouts that must not be read are listed, one directory name per line, in opensource/.not-read.
Nothing here names a project.

    scripts/scan-for-borrowed-code.py [--exact 6] [--shape 8]
"""
import argparse
import collections
import pathlib
import re
import sys

KEEP = set("""let var func if else guard return for in while switch case default break continue struct
enum class extension private public static self Self true false nil init try await async throws some
any where Int Int64 Double String Bool Array Set Dictionary Character Range min max abs count isEmpty
append first last map filter compactMap reduce sorted enumerated contains joined split
trimmingCharacters whitespaces rounded""".split())
TRIVIAL = {"}", "{", "})", "default:", "return nil", "break"}


def exact(line):
    return re.sub(r"\s+", " ", re.sub(r"//.*", "", line).strip())


def shape(line):
    line = exact(line)
    line = re.sub(r'"[^"]*"', '"S"', line)
    line = re.sub(r"\b\d+(\.\d+)?\b", "N", line)
    return re.sub(r"\b[A-Za-z_][A-Za-z0-9_]*\b", lambda m: m.group(0) if m.group(0) in KEEP else "x", line)


def runs(path, k, normalise, minimum):
    lines = [normalise(l) for l in path.read_text(errors="replace").split("\n")]
    lines = [l for l in lines if len(l) >= minimum and l not in TRIVIAL]
    # A run of near-identical lines is boilerplate (a list of cases), not a shared construction.
    return {tuple(lines[i:i + k]) for i in range(len(lines) - k + 1) if len(set(lines[i:i + k])) > k // 2}


def swift_files(root, skip=()):
    return [p for p in root.rglob("*.swift")
            if not any(part in skip or part in (".build", "DerivedData", ".git") for part in p.parts)]


def compare(ours, theirs, k, normalise, minimum):
    index = collections.defaultdict(set)
    for path in theirs:
        for run in runs(path, k, normalise, minimum):
            index[run].add(path)
    shared = collections.Counter()
    for path in ours:
        for run in runs(path, k, normalise, minimum):
            for other in index.get(run, ()):
                shared[(path, other)] += 1
    return shared


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exact", type=int, default=6, help="lines in an exact run")
    parser.add_argument("--shape", type=int, default=8, help="lines in a shape run")
    arguments = parser.parse_args()

    repository = pathlib.Path(__file__).resolve().parent.parent
    # The nearest `opensource/` above the repository: beside its parent folder on the machine this
    # was written on, and wherever a contributor keeps theirs.
    references = next((parent / "opensource" for parent in repository.parents
                       if (parent / "opensource").is_dir()), repository.parent / "opensource")
    skip_file = references / ".not-read"
    skip = set(skip_file.read_text().split()) if skip_file.exists() else set()
    ours = swift_files(repository)
    checkouts = [d for d in sorted(references.iterdir()) if d.is_dir() and d.name not in skip] if references.is_dir() else []
    theirs = [p for d in checkouts for p in swift_files(d)]
    print(f"read {len(ours)} Swift files here and {len(theirs)} in {len(checkouts)} checkout(s) "
          f"under {references} ({len(skip)} not read)")
    if not ours or not theirs:
        print("REFUSED: one side read nothing, so no answer is possible", file=sys.stderr)
        return 2

    found = False
    for name, k, normalise, minimum in (("exact", arguments.exact, exact, 12), ("shape", arguments.shape, shape, 10)):
        shared = compare(ours, theirs, k, normalise, minimum)
        print(f"{name}: {len(shared)} file pair(s) share a {k}-line run")
        for (mine, other), count in shared.most_common(20):
            found = True
            print(f"  {count:3}  {mine.relative_to(repository)}  <->  {other.relative_to(references)}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
