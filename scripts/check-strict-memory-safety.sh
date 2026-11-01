#!/bin/bash
# Fails if a full compile of every target — library AND test — emits any
# `StrictMemorySafety` warning. Reports in SITES: distinct file:line:column.
#
# **Clean-per-run, at a dedicated scratch path.** This gate's previous design ran an
# incremental `swift build --build-tests` and tried to detect, from log line shapes,
# whether anything had actually compiled. That design was retired for the reason its
# own header ended up documenting: a warm build does not recompile files it considers
# up to date, so a warning in an unchanged file cannot reach the log at all, and no
# log shape on this toolchain distinguishes "compiled nothing" from "compiled
# something" (a no-op build DOES print a `[N / M]` progress line for a link task;
# `Compiling ` never appears). Four consecutive runs on identical state exited
# 0, 3, 3, 0; this repair's own baseline measured 1, 0, 0. Something that answers
# differently on the same input is not a gate.
#
# Here every run cleans the gate's own scratch path and compiles everything, so
# every warning is emitted on every run. The warm/cold distinction — the exact place
# the old design failed — is eliminated by construction rather than detected by
# heuristic. The trade that justified incrementality was re-measured and had
# expired: a from-nothing `swift build --build-tests` here is ~23 seconds
# (2026-08-12, this machine), and the package has no external dependencies, so the
# scratch path needs no network. Full argument and the alternatives considered:
# `docs/design/2026-08-12-strict-memory-safety-gate-repair.md`.
#
# `.build-strict-gate` is deliberately not `.build`: the gate can neither corrupt
# the development cache nor be corrupted by its warmth. It is gitignored.
#
# **Compile evidence is artifacts, not log shapes.** After `clean` the scratch path
# must hold zero `.o` files; after the build, more than zero. That is evidence of
# the thing itself, immune to output-format drift across toolchains. The empty-log
# and missing-`Build complete!` guards below catch a different failure — a build
# whose output never arrived — and are kept from the old design, which they were
# never the broken part of.
#
# **SITES, and the unit is load-bearing** (ROADMAP, 3A-2). A site is a distinct
# file:line:column. The EMISSION count is higher — a module compiled for more than
# one product re-emits every warning it has — and the (file, line) count is lower,
# because one line can carry two sites in different columns. A macro-buffer warning
# (`macro expansion #require:L:C: …`) has no real position of its own and is
# resolved through the `note: expanded code originates here` line immediately
# following it, so no emission is silently dropped for lacking a file:line.
#
# Zero, not a maintained count: this script keeps no number to let drift. It prints
# the sites it measured on THIS run and fails if there are any.
#
# Exit codes, so a caller can tell which failure fired without re-reading the log:
#   0  full compile, zero StrictMemorySafety sites
#   1  full compile, sites found — the finding this gate exists to catch
#   2  the run cannot be trusted: empty log, no "Build complete!", or the clean
#      left objects behind (nothing this run says would mean anything)
#   3  build reported success but produced no object files — nothing was compiled,
#      an unobserved pass, not a clean one
#
# Nothing runs this automatically — same position `run-cross-boundary-probe.sh`
# takes and for the same reason (no CI in this repo yet). Run it wherever
# `swift build` is one of the gates.
set -euo pipefail
cd "$(dirname "$0")/.."

# Matches `run-cross-boundary-probe.sh`'s own reasoning: `swift build` resolves its
# SDK through xcrun, and an inherited SDKROOT can point it at a different one than
# xcrun's default, so unset it here rather than assume the caller's shell already has.
unset SDKROOT

SCRATCH=".build-strict-gate"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

swift package --package-path Core clean --scratch-path "$SCRATCH"

# Precondition: the clean actually cleaned. A clean that leaves objects behind
# would quietly reintroduce the incremental blindness this design exists to remove.
# **`|| true`, because `find` on a directory that does not exist EXITS 1** — and with
# `set -euo pipefail` that aborts the script before it prints anything. `2>/dev/null` silenced
# the message and left the exit status, which is why this looked like a gate that ran and
# produced nothing rather than one that never ran. It only showed up when the scratch directory
# was deleted: on any machine that had run this before, the directory existed and `find`
# succeeded. A gate that cannot run on a fresh checkout is a gate nobody new can use.
LEFTOVER=$( { find "$SCRATCH" -name '*.o' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$LEFTOVER" != "0" ]; then
    echo "FAILED: 'swift package clean' left $LEFTOVER object file(s) under $SCRATCH." >&2
    echo "A build over leftover objects is incremental, and an incremental build" >&2
    echo "cannot re-emit warnings from files it skips. Delete $SCRATCH and re-run." >&2
    exit 2
fi

# `--package-path Core`: the package moved out of the repository root so the Xcode
# navigator would stop showing `dist/`, `docs/` and the app target inside the package node.
swift build --package-path Core --build-tests --scratch-path "$SCRATCH" 2>&1 | tee "$LOG"

# Verified round-trip on the old design (kept because the failure it guards is
# unchanged): `true | tee "$LOG"` in place of the real build left the log empty and
# the pre-guard script printed a clean pass having verified nothing.
if [ ! -s "$LOG" ]; then
    echo "FAILED: swift build's log is empty — nothing was measured, and an empty" >&2
    echo "log reads as a clean pass unless something refuses it outright. This is" >&2
    echo "not a clean build; it is an unobserved one." >&2
    exit 2
fi

if ! grep -q 'Build complete!' "$LOG"; then
    echo "FAILED: swift build produced output but no 'Build complete!' marker — a" >&2
    echo "clean pass was never confirmed, only the absence of the warning tag in" >&2
    echo "whatever output there was. Treat this as unverified, not as clean." >&2
    exit 2
fi

# Postcondition: the build did real work. Object files are the build's own product,
# so this cannot be satisfied by a log line that says nothing about compilation —
# the hole the old progress-line guard died of.
COMPILED=$( { find "$SCRATCH" -name '*.o' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$COMPILED" = "0" ]; then
    echo "FAILED: swift build reported success but produced no object files under" >&2
    echo "$SCRATCH — nothing was compiled, so nothing was scanned. This is an" >&2
    echo "unobserved pass, not a clean one." >&2
    exit 3
fi

# **The compiler's colours and links come out first.** Swift now writes diagnostics with ANSI
# colour codes and OSC 8 hyperlinks round the tag (`[#<ESC>]8;;https://…<ESC>\StrictMemorySafety…]`)
# even into a pipe, and the patterns below, written for plain text, then matched nothing: this
# gate printed "zero sites" over a real one (2026-10-27, CGGeometryBridge.swift:268).
PLAIN=$(mktemp)
trap 'rm -f "$LOG" "$PLAIN"' EXIT
perl -pe 's/\e\][^\e\a]*(?:\e\\|\a)//g; s/\e\[[0-9;]*[A-Za-z]//g' "$LOG" > "$PLAIN"

# Distinct sites. Rule 1: a primary warning line contributes its own position —
# gutter-art repeats ('|- warning:') and the '[#StrictMemorySafety]:' footnote line
# do not match the leading-path shape. Rule 2: a macro-buffer warning resolves
# through the 'expanded code originates here' note immediately following it.
SITES=$(awk '
    /^\/[^ ]+:[0-9]+:[0-9]+: warning: .*\[#StrictMemorySafety\]/ {
        split($0, a, ": warning"); print a[1]; next
    }
    /^macro expansion .*: warning: .*\[#StrictMemorySafety\]/ { pend = 1; next }
    pend && /note: expanded code originates here/ {
        if (match($0, /\/[^ ]+:[0-9]+:[0-9]+/)) print substr($0, RSTART, RLENGTH)
        pend = 0; next
    }
    { pend = 0 }
' "$PLAIN" | sed "s|^$PWD/||" | sort -u)

# The instrument checks itself: the tag anywhere in the log with no site parsed means the
# patterns no longer fit the compiler's output — unmeasured, not clean.
if [ -z "$SITES" ] && grep -q 'StrictMemorySafety' "$PLAIN"; then
    echo "FAILED: the log names StrictMemorySafety but no site was parsed from it — the" >&2
    echo "compiler's output has changed shape. Unverified, not clean:" >&2
    grep -m3 'StrictMemorySafety' "$PLAIN" | sed 's/^/  /' >&2
    exit 2
fi

# **And the other way: an `unsafe` with nothing unsafe in it.** The owner's Xcode reports these
# too (ChapterSamples.swift:70, 2026-10-26); left, they pile up — 220 were found in the tests the
# day this check was added — and hide the one that matters.
# Parsed as the sites are: a macro's own expansion resolves through the note that follows it.
NEEDLESS=$(awk '
    /^\/[^ ]+:[0-9]+:[0-9]+: warning: .*UnnecessaryUnsafe\]/ { split($0, a, ": warning"); print a[1]; next }
    /^macro expansion .*: warning: .*UnnecessaryUnsafe\]/ { pend = 1; next }
    pend && /note: expanded code originates here/ {
        if (match($0, /\/[^ ]+:[0-9]+:[0-9]+/)) print substr($0, RSTART, RLENGTH)
        pend = 0; next
    }
    { pend = 0 }
' "$PLAIN" | sed "s|^$PWD/||" | sort -u)
if [ -z "$NEEDLESS" ] && grep -q 'UnnecessaryUnsafe\]' "$PLAIN"; then
    echo "FAILED: the log names UnnecessaryUnsafe but no site was parsed from it. Unverified." >&2
    exit 2
fi
if [ -n "$NEEDLESS" ]; then
    echo "FAILED: $(printf '%s\n' "$NEEDLESS" | wc -l | tr -d ' ') 'unsafe' marker(s) with no unsafe operation inside:" >&2
    printf '%s\n' "$NEEDLESS" | sed 's/^/  /' >&2
    exit 1
fi

if [ -n "$SITES" ]; then
    COUNT=$(printf '%s\n' "$SITES" | wc -l | tr -d ' ')
    echo
    echo "FAILED: $COUNT unmarked unsafe site(s) — distinct file:line:column — in a" >&2
    echo "full compile of every target, library and test:" >&2
    echo >&2
    printf '%s\n' "$SITES" | sed 's/^/  /' >&2
    echo >&2
    echo "Every unsafe construct must be marked 'unsafe' at its own expression —" >&2
    echo "with a comment at the site saying why it is safe here, if it is — not" >&2
    echo "left as an unmarked warning for the next reader to not read." >&2
    exit 1
fi

echo "STRICT MEMORY SAFETY: zero StrictMemorySafety sites and no needless 'unsafe' in a full compile of"
echo "every target, library and test ($COMPILED object files produced this run)."
echo "Clean-per-run: this verdict is about the whole tree as it stands, not about"
echo "whichever files happened to be stale."
