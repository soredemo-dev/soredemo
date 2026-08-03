#!/usr/bin/env python3
"""Enumerate the deprecations on the SDK surface this project actually imports.

WHY A SCAN AND NOT A LIST. `AVMutableVideoComposition` was deprecated in macOS **26.0** — this
project's own floor — so it was dead before Phase 2B started, and nothing in the repository said
so. A hand-kept list of "APIs to avoid" answers that question once and then rots; this answers it
on every run, against the SDK the build is actually using.

WHAT IT DOES NOT DO: it changes nothing. It enumerates. Acting on a row is a separate decision
with a separate diff.

    scripts/scan-sdk-deprecations.py                 scan, with the SwiftPM cross-check
    scripts/scan-sdk-deprecations.py --no-verify     skip the cross-check (faster, weaker subject)
    scripts/scan-sdk-deprecations.py --control       run the positive control and exit
    scripts/scan-sdk-deprecations.py --certify       run the two red certificates and exit
    scripts/scan-sdk-deprecations.py --floor         typecheck the successor stack at the 26.0 floor
    scripts/scan-sdk-deprecations.py --in-use        also ask the compiler what WE call
    scripts/scan-sdk-deprecations.py --out FILE      where the full table is written

FOUR THINGS THIS GETS RIGHT ON PURPOSE, EACH BECAUSE THE OBVIOUS VERSION FAILS QUIETLY.

1. THE MODULE LIST IS DERIVED, NOT WRITTEN. It comes from the `import` lines in `Sources/` and the
   app target. A hand-written include-list decays by omission, which this project has already
   rejected twice — and the first draft of THIS scan proved the point: its import regex required an
   underscore-prefixed attribute, so `@preconcurrency import ScreenCaptureKit` did not match and the
   framework this whole phase depends on was silently absent. So the derivation carries its own
   control: **every line containing `import` must yield a module or be reported**. Unparsed import
   lines are a failure, not a filter.

2. THE SUBJECT IS PRINTED, AND IT IS THE RIGHT SDK. This machine has two, and they disagree:
   `xcrun --show-sdk-path` answers with CommandLineTools (26.5) while `xcrun --sdk macosx` answers
   with Xcode-beta (27.0), and `swift build -v` passes the latter. Scanning the wrong one produces
   a clean-looking, wrong answer — the same failure mode that made `run-cross-boundary-probe.sh`
   fail nineteen runs identically by inheriting SDKROOT. Both paths are printed, the one used is
   named, and unless `--no-verify` the choice is cross-checked against what SwiftPM actually passes.
   Two instruments answering one question, with their agreement checked: the definite-singular
   audit's row 3, which had no mechanism anywhere until here.

3. BOTH SURFACES ARE READ. Deprecations live in ObjC headers (`API_DEPRECATED` and relatives) and
   in `.swiftinterface` files, and neither is a superset. Measured on this SDK: all four AVFoundation
   rows of the positive control are in headers — inside `#if __swift__`, so they bind Swift callers
   and not ObjC ones — while AVFoundation ships no `.swiftinterface` at all; ScreenCaptureKit ships
   one, 64 lines long, with no deprecations in it; and other frameworks carry deprecations only in
   the interface. Reading one surface under-reports, and under-reporting looks like a clean SDK.
   `API_DEPRECATED` spans lines, so headers are read whole and matched across newlines.

4. ZERO IS NOT THE SAME AS NOT-LOOKED. A module with neither headers nor an interface is reported
   NOT SCANNED and is excluded from every count. Reporting it as "0 deprecations" would be a number
   with nothing behind it — the rule this project wrote into `GapWatch` at Task 11, applied here to
   the instrument itself.

THE BUCKETS ARE SEPARATE BECAUSE THE CONSEQUENCES ARE.

    <= 26.0   dead at the floor — this project could never have used it
    == 27.0   usable today, already condemned — a D6b row, triggered by an SDK or floor bump
    other     deprecated somewhere between the floor and the next major: neither of the above
    unknown   the version could not be parsed — never folded into a bucket that reads as a fact

THE POSITIVE CONTROL RUNS FIRST AND THE SCAN REFUSES WITHOUT IT. Five rows were measured by hand
from the headers before this file existed. If they do not come back, with those versions, the scan
is wrong and any new row it reports is unearned. `--control` runs just that.

Its red certificates are two mutations against two different dimensions, because one covers only
one: drop AVFoundation from the derived module list (attacks the DERIVATION — the control's five
rows vanish), and edit a known version string in a copy of the header (attacks the PARSER — a row
moves bucket). A scan that passes both has been checked for finding the right things in the right
places, not merely for finding something.
"""
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLOOR = (26, 0)          # ARCHITECTURE.md D2 — macOS 26, Apple Silicon
NEXT_MAJOR = (27, 0)

# The five rows measured by hand from AVVideoComposition.h before this scan existed.
# symbol -> deprecated-in version. A control, not a filter: nothing is selected by it.
POSITIVE_CONTROL = {
    "AVMutableVideoComposition": "26.0",
    "AVMutableVideoCompositionInstruction": "26.0",
    "AVMutableVideoCompositionLayerInstruction": "26.0",
    "videoCompositionCoreAnimationToolWithPostProcessingAsVideoLayer": "27.0",
    "videoCompositionCoreAnimationToolWithPostProcessingAsVideoLayers": "27.0",
}


# ---------------------------------------------------------------- the subject

def resolve_sdk(verify: bool):
    """The SDK `swift build` uses, with the one it does NOT use printed beside it."""
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}

    def xcrun(*args):
        r = subprocess.run(["xcrun", *args], capture_output=True, text=True, env=env)
        return r.stdout.strip() if r.returncode == 0 else ""

    chosen = xcrun("--sdk", "macosx", "--show-sdk-path")
    version = xcrun("--sdk", "macosx", "--show-sdk-version")
    bare = xcrun("--show-sdk-path")

    print(f"SDK SCANNED:  {chosen}")
    print(f"      version {version}   (`xcrun --sdk macosx`, which is what SwiftPM passes)")
    if bare and bare != chosen:
        print(f"NOT SCANNED:  {bare}")
        print("      `xcrun --show-sdk-path` answers with a DIFFERENT SDK on this machine. Scanning")
        print("      it would produce a clean-looking answer about the wrong platform.")

    if verify:
        r = subprocess.run(["swift", "build", "-v"], cwd=ROOT, capture_output=True,
                           text=True, env=env, timeout=900)
        passed = sorted(set(re.findall(r"-sdk\s+(\S+)", r.stdout + r.stderr)))
        if not passed:
            print("VERIFY:       could not read an -sdk flag from `swift build -v` — UNVERIFIED")
        elif passed == [chosen]:
            print(f"VERIFY:       `swift build -v` passes the same path. Agreed.")
        else:
            sys.exit(f"VERIFY FAILED: SwiftPM passes {passed}, this scan resolved {chosen}. "
                     "Two instruments, one question, no agreement — fix that before reading rows.")
    else:
        print("VERIFY:       SKIPPED. The subject rests on xcrun alone.")
    print()
    return Path(chosen), version


# ------------------------------------------------------- the derived module list

# `import` is a question about grammatical POSITION, not about which characters appear — the same
# distinction `architecture-checker` draws between its rule 1 and its rule 2. Answering it textually
# matched this repository's own lexer source, where `== "import"` is a string comparison; the audit
# below reported those two lines rather than silently counting them, which is how they were found.
# So: blank string contents first, then require `import` to open the statement.
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
IMPORT_LINE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
                         r"(?:public|internal|private|fileprivate|package)?\s*import\b")
IMPORT_MODULE = re.compile(r"import\s+(?:struct|class|enum|protocol|func|var|let|typealias"
                           r"|actor|macro)?\s*([A-Za-z_][A-Za-z0-9_]*)")


def first_party_modules() -> set:
    """Target names from Package.swift, plus the app target's own directories."""
    manifest = (ROOT / "Package.swift").read_text(encoding="utf-8")
    names = set(re.findall(r'\.(?:executableTarget|target|testTarget)\(\s*name:\s*"([^"]+)"', manifest))
    names |= set(re.findall(r'\.library\(\s*name:\s*"([^"]+)"', manifest))
    return names


def derive_modules():
    """Every module imported by this repository's own Swift, with the parse audited."""
    sources = []
    for base in ("Sources", "Soredemo"):
        sources += sorted((ROOT / base).rglob("*.swift"))
    if not sources:
        sys.exit("no Swift sources found — this scan would derive an empty module list and "
                 "then report zero deprecations, which is a vacuous pass.")

    modules, unparsed = set(), []
    for path in sources:
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            code = STRING_LITERAL.sub('""', line).split("//")[0]
            if not IMPORT_LINE.search(code):
                continue
            m = IMPORT_MODULE.search(code)
            if m:
                modules.add(m.group(1))
            else:
                unparsed.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")

    if unparsed:
        print("IMPORT LINES THIS SCAN COULD NOT PARSE — the module list is incomplete, and an")
        print("incomplete list under-reports in the direction that flatters the SDK:")
        for u in unparsed:
            print(f"  {u}")
        sys.exit(1)

    first_party = first_party_modules()
    return sorted(modules - first_party), sorted(modules & first_party), len(sources)


# ------------------------------------------------------------- locating a module

def locate(sdk: Path, module: str):
    """Header files, swiftinterface files and apinotes for one module. Any may be empty."""
    roots = [
        sdk / "System/Library/Frameworks" / f"{module}.framework",
        sdk / "System/Library/PrivateFrameworks" / f"{module}.framework",
    ]
    headers, interfaces, apinotes = [], [], []
    for root in roots:
        if not root.is_dir():
            continue
        headers += [p for p in root.rglob("*.h") if p.is_file()]
        apinotes += [p for p in root.rglob("*.apinotes") if p.is_file()]
        found = sorted(p for p in root.rglob("*.swiftinterface") if p.is_file())
        # Apple Silicon only (D2). Prefer arm64e, then arm64, then whatever exists —
        # and never take two architectures of the same module, which double-counts.
        for want in ("arm64e-apple-macos", "arm64-apple-macos"):
            picked = [p for p in found if p.stem == want]
            if picked:
                interfaces += picked[:1]
                break
        else:
            interfaces += found[:1]

    # Clang-module headers that are not frameworks (Darwin, Synchronization, …)
    if not headers and not interfaces:
        for d in (sdk / "usr/include" / module, sdk / "usr/lib/swift" / f"{module}.swiftmodule"):
            if d.is_dir():
                headers += [p for p in d.rglob("*.h") if p.is_file()]
                interfaces += sorted(p for p in d.rglob("*.swiftinterface") if p.is_file())[:1]
    return headers, interfaces, apinotes


# ------------------------------------------------------------------- the parsers

# API_DEPRECATED spans lines; read whole files and match with DOTALL.
OBJC_MACROS = re.compile(
    r"\b(API_DEPRECATED_WITH_REPLACEMENT|API_DEPRECATED|NS_DEPRECATED_MAC|"
    r"API_DEPRECATED_BEGIN|DEPRECATED_ATTRIBUTE|__deprecated)\b"
    r"(\s*\((?P<args>[^()]*(?:\([^()]*\)[^()]*)*)\))?",
    re.DOTALL)
MACOS_RANGE = re.compile(r"\bmacos(?:x)?\s*\(\s*([0-9][0-9_.]*)\s*,\s*([0-9][0-9_.]*)\s*\)")
NS_DEPRECATED_ARGS = re.compile(r"^\s*([0-9][0-9_.]*)\s*,\s*([0-9][0-9_.]*)")

SWIFT_AVAILABLE = re.compile(
    r"@available\s*\(\s*(?P<platform>macOS|OSX|\*)\s*,(?P<body>[^)]*)\)", re.DOTALL)
SWIFT_DEPRECATED_VERSION = re.compile(r"\bdeprecated\s*:\s*([0-9][0-9_.]*)")
# Swift's "deprecated, version unspecified" sentinels. This SDK uses at least two spellings —
# `deprecated: 100000` and `deprecated: 10000` — and neither is a macOS version. They are real
# deprecations with no schedule, so they get their own bucket rather than being read as a release:
# left in `other`, the 10000 spelling put twenty CoreGraphics set operations in the bucket that
# means "deprecated between the floor and the next major", which is a sentence about a release
# that will never happen. Anything with a major of 1000 or more is a sentinel, not a version.
SENTINEL_MAJOR = 1000



LINE_COMMENT = re.compile(r"//[^\n]*")
IN_LINE_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def paren_view(text: str) -> str:
    """`text` with string CONTENTS blanked to the same length, so offsets stay aligned.

    WHY: the macro matcher counts parentheses, and a message may contain an unbalanced one —
    `API_DEPRECATED("Use [NSURLSession dataTaskWithRequest:completionHandler:] (see NSURLSession.h",
    macos(10.3,10.11), ...)` opens a paren inside the string and never closes it. That threw the
    argument capture off and left `macos(10.3,10.11)` unread: two rows filed as "version unknown"
    that had a version all along. Third instance in this file of one mistake — match structure on a
    view with strings blanked, never on raw text; it cost the `import` derivation first and the
    swiftinterface symbol extraction second.

    WHY PER LINE: the first version of this ran one quote-state machine over the whole file, and a
    stray `"` in a comment inverted it — NSError.h came back with its CODE blanked and its strings
    intact, and both of its real 27.0 rows silently disappeared from the table. A per-line pass
    cannot propagate that past the line it happens on. Line comments are stripped first for the
    same reason. Blanking is same-length, so every index into the view indexes the original and the
    message can still be sliced out of the real text.
    """
    out = []
    for line in text.split("\n"):
        stripped = LINE_COMMENT.sub(lambda m: " " * len(m.group(0)), line)
        out.append(IN_LINE_STRING.sub(
            lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', stripped))
    return "\n".join(out)


def parse_version(text):
    parts = text.replace("_", ".").split(".")
    try:
        nums = tuple(int(p) for p in parts[:2])
    except ValueError:
        return None
    return nums if len(nums) == 2 else (nums[0], 0)


# No `\b` before `@`: a word boundary needs a word character on one side, and both a space and an
# `@` are non-word — so `\b@interface` never matches a declaration that begins a line, which is
# every one of them. With that leading `\b` in place the forward search silently never fired, every
# lookup fell through to the backward walk, and three of the five control rows came back named
# `__swift__` after the `#if` above them. The control is what caught it.
DECL_AFTER = re.compile(r"@(?:interface|protocol|class)\s+(\w+)")
DECL_METHOD = re.compile(r"[-+]\s*\([^)]*\)\s*(\w+)")
DECL_TRAILING_IDENT = re.compile(r"(\w+)\s*(?:NS_\w+|API_\w+|\([^)]*\))*\s*$")
# Preprocessor lines are not declarations, and the backward walk otherwise reads `#if __swift__`
# as the deprecated symbol's name.
PREPROCESSOR = re.compile(r"^\s*#\s*\w+.*$", re.MULTILINE)


def symbol_near(text: str, start: int, end: int) -> str:
    """The declaration a deprecation attaches to. Reported as `?` rather than guessed."""
    # Forward first, but only as far as the statement the macro sits in. A type's deprecation is
    # written BEFORE `@interface`; a method's is written AFTER the selector and before its `;`.
    # Searching forward without that bound gave the plural
    # `…PostProcessingAsVideoLayers` the name of the `@interface AVAsset` category seven lines
    # below it — a wrong answer that looks exactly like a right one, and the fifth control row is
    # the only reason it was not reported as fact.
    after = text[end:end + 400]
    after = re.split(r"[;{]", after, maxsplit=1)[0]
    m = DECL_AFTER.search(after)
    if m:
        return m.group(1)
    # Walk back to the start of the statement.
    cut = max(text.rfind(";", 0, start), text.rfind("{", 0, start),
              text.rfind("}", 0, start), text.rfind("\n\n", 0, start))
    before = PREPROCESSOR.sub("", text[cut + 1:start])
    m = DECL_AFTER.search(before)
    if m:
        return m.group(1)
    m = DECL_METHOD.search(before)
    if m:
        return m.group(1)
    m = DECL_TRAILING_IDENT.search(before.strip())
    if m:
        return m.group(1)
    return "?"


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def scan_headers(paths):
    rows = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "DEPRECAT" not in text.upper():
            continue
        view = paren_view(text)
        for m in OBJC_MACROS.finditer(view):
            macro, args = m.group(1), m.group("args") or ""
            if macro == "API_DEPRECATED_BEGIN":
                continue                        # a region marker, not a declaration
            version = None
            r = MACOS_RANGE.search(args)
            if r:
                version = r.group(2)
            elif macro == "NS_DEPRECATED_MAC":
                n = NS_DEPRECATED_ARGS.match(args)
                if n:
                    version = n.group(2)
            elif "macos" not in args and args:
                continue                        # deprecated on another platform only
            rows.append((symbol_near(text, m.start(), m.end()), version,
                         path, line_of(text, m.start()), macro))
    return rows


def scan_interfaces(paths):
    rows = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "deprecated" not in text:
            continue
        # `message:` and `renamed:` carry prose, and the declaration search below reads any
        # `let`/`var`/`func` inside one as the deprecated symbol's name — which is where symbols
        # called "instead" and "accessibility" came from. Blank string contents first, exactly as
        # `CheckerLexer.codeViewLines` does for this repository's own scans.
        text = STRING_LITERAL.sub('""', text)
        for m in SWIFT_AVAILABLE.finditer(text):
            body = m.group("body")
            if "deprecated" not in body:
                continue
            v = SWIFT_DEPRECATED_VERSION.search(body)
            version = v.group(1) if v else None
            after = text[m.end():m.end() + 400]
            d = re.search(r"\b(?:func|var|let|class|struct|enum|protocol|typealias|init|case)\s+"
                          r"([A-Za-z_][A-Za-z0-9_]*)", after)
            rows.append((d.group(1) if d else "?", version,
                         path, line_of(text, m.start()), "@available"))
    return rows


# ---------------------------------------------------------------------- buckets

def bucket_of(version_text):
    if version_text is None:
        return "unknown"
    v = parse_version(version_text)
    if v is None:
        return "unknown"
    if v[0] >= SENTINEL_MAJOR:
        return "unspecified"
    if v <= FLOOR:
        return "<= 26.0"
    if v == NEXT_MAJOR:
        return "== 27.0"
    return "other"


BUCKET_ORDER = ["<= 26.0", "== 27.0", "other", "unspecified", "unknown"]
BUCKET_MEANING = {
    "<= 26.0": "dead at the floor — this project could never have used it",
    "== 27.0": "usable today, already condemned — each of these is a D6b row",
    "other":   "deprecated between the floor and the next major — neither of the above, "
               "and not folded into one",
    "unspecified": "Swift's `deprecated: 100000` sentinel: deprecated, no version stated. "
                   "Real, and unschedulable — not evidence about any release",
    "unknown": "the version could not be parsed — NOT counted as anything else",
}



# --------------------------------------------------- the replacement, and where it lives

# The replacement is already in the string this scan parsed: the first argument of
# API_DEPRECATED_WITH_REPLACEMENT, Swift's `renamed:`, or — for 74 of the 78 rows at 27.0 — the
# prose message of a plain API_DEPRECATED. Reading it costs nothing extra and it is the column the
# decision actually turns on, because the three cases have nothing in common:
#
#   replacement introduced <= 26.0   migrate now, question closed
#   replacement introduced == 27.0   unreachable at the floor: two implementations, or move it
#   no replacement named             a direction signal, not a migration path
REPLACEMENT_ARG = re.compile(r'API_DEPRECATED_WITH_REPLACEMENT\s*\(\s*"([^"]*)"')
DEPRECATED_MSG = re.compile(r'API_DEPRECATED\s*\(\s*"([^"]*)"')
SWIFT_RENAMED = re.compile(r'renamed\s*:\s*"([^"]*)"')

# A candidate symbol inside a prose message. Dotted or parenthesised names only: the messages are
# sentences, and any word-shaped heuristic returns "Use", "instead" and "the".
CANDIDATE = re.compile(r"\b([A-Z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+|[a-zA-Z][A-Za-z0-9]*\([a-zA-Z_:]*\))")


def replacement_for(sdk: Path, rel: str, line: int):
    """(raw replacement text, best candidate symbol) for one deprecation site."""
    try:
        lines = (sdk / rel).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return "", ""
    chunk = "\n".join(lines[line - 1:line + 3])
    m = (REPLACEMENT_ARG.search(chunk) or SWIFT_RENAMED.search(chunk)
         or DEPRECATED_MSG.search(chunk))
    raw = m.group(1) if m else ""
    if not raw:
        return "", ""
    cands = CANDIDATE.findall(raw)
    return raw, (cands[0] if cands else "")


def introduced_at_floor(symbol: str) -> str:
    """Is `symbol` reachable at the 26.0 floor? Asked of the compiler, by TYPE REFERENCE only.

    Type reference and not a call, deliberately. Three call-site probes written from the
    deprecation messages produced three "blocked at 26.0" readings that were all wrong — they were
    signature mistakes, and one of the messages names an API that does not exist: it says
    `finish(withComposedVideoFrame:)` and the shipped selector is `finish(withComposedPixelBuffer:)`.
    A reference to a type needs no signature, so it cannot fail for a reason that is not
    availability. Methods, which cannot be referenced this way, are reported as not determined
    rather than guessed at.
    """
    if "(" in symbol or "." not in symbol or not symbol[0].isupper():
        return "not determined (not a type reference)"
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    import tempfile
    src = ("import AVFoundation\nimport CoreMedia\nimport CoreVideo\nimport ScreenCaptureKit\n"
           f"func probe(_ x: {symbol}) {{}}\n")
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / "probe.swift"
        f.write_text(src, encoding="utf-8")

        def errors(target):
            r = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-target", target,
                                "-typecheck", str(f)], capture_output=True, text=True, env=env)
            return [l for l in (r.stdout + r.stderr).splitlines() if ".swift:" in l and "error:" in l]

        at26, at27 = errors("arm64-apple-macos26.0"), errors("arm64-apple-macos27.0")
    if not at26:
        return "<= 26.0  MIGRATE NOW"
    if not at27:
        return "== 27.0  UNREACHABLE AT THE FLOOR"
    return "not determined (probe failed at both targets)"


# --------------------------------------------------------------- collecting rows

def collect(sdk: Path, modules, report: bool = False):
    """Every deprecation on `modules`' surface, bucketed. Shared by the scan and its certificates,
    so the certificates exercise the code the scan runs rather than a second copy of it."""
    findings, not_scanned, scanned = defaultdict(list), [], []
    for module in modules:
        headers, interfaces, apinotes = locate(sdk, module)
        if not headers and not interfaces:
            not_scanned.append(module)
            continue
        scanned.append((module, len(headers), len(interfaces), len(apinotes)))
        seen = set()
        for symbol, version, path, lineno, macro in scan_headers(headers) + scan_interfaces(interfaces):
            key = (module, symbol, version)
            if key in seen:
                continue
            seen.add(key)
            findings[bucket_of(version)].append(
                (module, symbol, version or "\u2014", str(path.relative_to(sdk)), lineno, macro))
    return (findings, not_scanned, scanned) if report else findings


# ------------------------------------------------------------- the red certificates

def certify(sdk: Path) -> int:
    """Two mutations against two dimensions, because one covers only one.

    The control proves the scan finds five known rows. It does not prove the scan would NOTICE if
    it stopped finding them for the two different reasons it could: a module missing from the
    derivation, and a version misread by the parser. One mutation each, and a scan that passes the
    first and fails the second has been certified for half of what the control is for.
    """
    ok = True

    # Dimension 1 — the DERIVATION. Take AVFoundation out of the module list and the five control
    # rows must disappear. This is the `@preconcurrency import ScreenCaptureKit` failure, forced.
    findings = collect(sdk, [m for m in derive_modules()[0] if m != "AVFoundation"])
    found = {s for rows in findings.values() for (_, s, *_ ) in rows}
    survivors = sorted(set(POSITIVE_CONTROL) & found)
    if survivors:
        print(f"  FAIL  derivation: dropped AVFoundation, yet {survivors} still reported — the "
              "control is not reading the module list it claims to")
        ok = False
    else:
        print("  ok    derivation: with AVFoundation out of the module list, all five control "
              "rows vanish")

    # Dimension 2 — the PARSER. The SDK is read-only, so the header is copied and the version
    # edited in the copy. A scan that reports 26.0 for a header that now says 28.0 is reading
    # something other than the text in front of it.
    import shutil, tempfile
    header = sdk / "System/Library/Frameworks/AVFoundation.framework/Headers/AVVideoComposition.h"
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "AVVideoComposition.h"
        shutil.copyfile(header, copy)
        copy.write_text(copy.read_text(encoding="utf-8").replace(
            'API_DEPRECATED("Use AVVideoComposition.Configuration instead", macos(10.7, 26.0)',
            'API_DEPRECATED("Use AVVideoComposition.Configuration instead", macos(10.7, 28.0)'),
            encoding="utf-8")
        versions = {s: v for s, v, *_ in scan_headers([copy])}
        got = versions.get("AVMutableVideoComposition")
        if got == "28.0":
            print("  ok    parser: an edited version string moves the row — 26.0 → 28.0 read back")
        else:
            print(f"  FAIL  parser: the header now says 28.0 and the scan says {got!r}. The version "
                  "is not coming from the text.")
            ok = False

    print("\nBoth dimensions, because a control that only ever fails one way certifies one way.")
    return 0 if ok else 1


# ------------------------------------------------- what this repository actually uses

def report_use(run_it: bool):
    """Whether THIS repository calls anything deprecated — asked of the compiler, not of grep.

    The first version of this section matched deprecated symbol NAMES against the repository's own
    source text, and reported `error`, `status`, `title`, `window` and `value` as findings. Those
    are ordinary words; a bare-identifier grep cannot tell `AVAssetWriter.status` from any other
    `status`, and every one of those rows was noise wearing the shape of a result.

    The compiler already answers this question exactly, with types resolved, and it answers it for
    the whole surface at once. It needs a CLEAN build to answer it: a warm build recompiles nothing
    and prints nothing, which reads identically to a clean bill of health. Both halves are built —
    the package with `swift build`, the app target with `xcodebuild`, because the package is
    Foundation-only and every AVFoundation, ScreenCaptureKit and AppKit call lives in the app.
    """
    print("── IN USE HERE: does this repository call anything deprecated?")
    if not run_it:
        print("   NOT MEASURED. Pass --in-use to build both halves clean and read the compiler's")
        print("   own deprecation warnings. This is deliberately not defaulted (two clean builds)")
        print("   and deliberately not approximated by grepping symbol names, which reported")
        print("   `error`, `status` and `title` as findings when it was tried.\n")
        return

    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    import tempfile
    counts, logs = {}, {}
    with tempfile.TemporaryDirectory() as tmp:
        pkg = subprocess.run(["swift", "build", "--scratch-path", f"{tmp}/pkg"],
                             cwd=ROOT, capture_output=True, text=True, env=env, timeout=1800)
        logs["package (swift build)"] = pkg.stdout + pkg.stderr
        app = subprocess.run(["xcodebuild", "-scheme", "Soredemo", "-configuration", "Debug",
                              "-derivedDataPath", f"{tmp}/app", "clean", "build"],
                             cwd=ROOT, capture_output=True, text=True, env=env, timeout=1800)
        logs["app target (xcodebuild)"] = app.stdout + app.stderr

    for half, log in logs.items():
        if "BUILD SUCCEEDED" not in log and "Build complete" not in log:
            print(f"   {half}: BUILD FAILED — NOT MEASURED. A failed build emits no deprecation")
            print(f"   warnings, which is not the same as having none.")
            continue
        hits = sorted(set(re.findall(r"^.*?warning: '([^']+)' was deprecated in macOS ([0-9.]+).*$",
                                     log, re.MULTILINE)))
        counts[half] = len(hits)
        print(f"   {half}: {len(hits)} deprecated call site(s), on a CLEAN build")
        for symbol, version in hits[:60]:
            print(f"      {symbol}  (deprecated {version})")
    print()



# A SECOND control, for the parser rather than for the scan. Both rows are bugs this file actually
# shipped: `NSURLConnection.h` hides `macos(10.3,10.11)` behind a message containing an unbalanced
# `(`, and `NSError.h` is the file a whole-file quote-state machine inverted — it came back with its
# CODE blanked and its strings intact, and both of its real 27.0 rows vanished from the table with
# no other symptom. Keyed by (header, symbol) because line numbers move between SDKs.
PARSER_CONTROL = {
    ("NSError.h", "new"): "27.0",
    ("NSURLConnection.h", "initWithRequest"): "10.11",
}


def parser_control(sdk: Path) -> bool:
    ok = True
    for (header, symbol), want in sorted(PARSER_CONTROL.items()):
        found = None
        for path in (sdk / "System/Library/Frameworks/Foundation.framework/Headers").rglob(header):
            for sym, ver, *_ in scan_headers([path]):
                if sym == symbol:
                    found = ver
                    break
        mark = "ok  " if found == want else "MISS"
        if found != want:
            ok = False
        print(f"  {mark}  {header} {symbol}  expected {want}, scan says {found or 'ABSENT'}")
    return ok


# ------------------------------------------- the successor stack, probed at the floor

# The automated column answers TYPES. It cannot answer METHODS, because a method probe is a call
# and a call needs a signature — and signatures cannot be read off the deprecation messages: three
# call probes written from those messages failed at 26.0 for signature reasons and looked exactly
# like unavailability, and one message names `finish(withComposedVideoFrame:)` for a selector that
# actually ships as `finish(withComposedPixelBuffer:)`.
#
# So the methods Phase 2B depends on are probed by hand, with signatures read from the module's own
# API surface, and the probes are committed rather than described. Each must TYPECHECK at
# `arm64-apple-macos26.0`. If one stops, the floor can no longer reach the successor stack and the
# D6b-27 row that says otherwise is wrong.
FLOOR_PROBES = {
    "AVAssetWriter → PixelBufferReceiver (the export path)": """
        import AVFoundation
        import CoreVideo
        func probe(w: AVAssetWriter, i: AVAssetWriterInput) throws {
            let r: AVAssetWriterInput.PixelBufferReceiver =
                try w.inputPixelBufferReceiver(for: i, pixelBufferAttributes: nil)
            let s: AVAssetWriterInput.SampleBufferReceiver = try w.inputReceiver(for: i)
            _ = (r, s)
        }
    """,
    "PixelBufferReceiver.append (async, replaces adaptor append)": """
        import AVFoundation
        import CoreVideo
        func probe(r: AVAssetWriterInput.PixelBufferReceiver,
                   b: CVReadOnlyPixelBuffer, t: CMTime) async throws {
            try await r.append(b, with: t)
        }
    """,
    "AVVideoCompositing request finish (D8's compositor)": """
        import AVFoundation
        import CoreVideo
        func probe(req: AVAsynchronousVideoCompositionRequest, b: CVReadOnlyPixelBuffer) {
            req.finish(withComposedPixelBuffer: b)
            _ = req.sourceReadOnlyPixelBuffer(byTrackID: 1)
            _ = req.sourceReadySampleBuffer(byTrackID: 1)
        }
    """,
    "AVVideoComposition.Configuration (replaces AVMutableVideoComposition)": """
        import AVFoundation
        func probe(c: AVVideoComposition.Configuration) {
            let composition = AVVideoComposition(configuration: c)
            _ = composition.customVideoCompositorClass
        }
    """,
    "AVAssetReader → outputProvider (the read path)": """
        import AVFoundation
        func probe(r: AVAssetReader, o: AVAssetReaderOutput) throws {
            _ = try r.outputProvider(for: o)
        }
    """,
    "AVAssetExportSession.export(to:as:) async": """
        import AVFoundation
        func probe(s: AVAssetExportSession, url: URL) async throws {
            try await s.export(to: url, as: .mp4)
        }
    """,
}


def floor_probes() -> int:
    """Every successor Phase 2B needs, typechecked at the 26.0 floor."""
    import tempfile
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    ok = True
    print("SUCCESSOR STACK AT THE 26.0 FLOOR — each must typecheck at arm64-apple-macos26.0:")
    with tempfile.TemporaryDirectory() as tmp:
        for label, src in FLOOR_PROBES.items():
            f = Path(tmp) / "probe.swift"
            f.write_text("\n".join(l[8:] if l.startswith(" " * 8) else l
                                    for l in src.strip("\n").splitlines()) + "\n",
                         encoding="utf-8")
            r = subprocess.run(["xcrun", "swiftc", "-swift-version", "6",
                                "-target", "arm64-apple-macos26.0", "-typecheck", str(f)],
                               capture_output=True, text=True, env=env)
            errs = [l for l in (r.stdout + r.stderr).splitlines()
                    if "probe.swift:" in l and "error:" in l]
            if errs:
                ok = False
                print(f"  FAIL  {label}")
                for e in errs[:2]:
                    print(f"        {e.split('probe.swift:')[-1].strip()}")
            else:
                print(f"  ok    {label}")
    print("\nA FAIL here means the floor can no longer reach the successor stack, and D6b-27's "
          "reading of it is wrong.")
    return 0 if ok else 1


def report_replacements(sdk: Path, rows):
    """The 27.0 bucket, with what each names as its successor and whether the floor can reach it."""
    print("── REPLACEMENTS for the 27.0 bucket, and whether the 26.0 floor can reach them")
    named, unnamed, cells = {}, [], defaultdict(list)
    for module, symbol, version, rel, lineno, macro in sorted(rows):
        raw, candidate = replacement_for(sdk, rel, lineno)
        if candidate:
            named.setdefault(candidate, []).append(f"{module}.{symbol}")
        else:
            unnamed.append((f"{module}.{symbol}", raw))

    for candidate in sorted(named):
        cells[introduced_at_floor(candidate).split("  ")[0]].append((candidate, named[candidate]))

    for cell, label in (("<= 26.0", "REACHABLE AT THE FLOOR — migrate now, question closed"),
                        ("== 27.0", "UNREACHABLE AT THE FLOOR — two implementations, or move the floor"),
                        ("not", "NOT DETERMINED — a method, or a name that resolves at neither "
                                "target; NOT counted as either")):
        group = [(c, u) for k, g in cells.items() if k.startswith(cell) for c, u in g]
        if not group:
            continue
        print(f"   {cell} · {label}   ({len(group)})")
        for candidate, users in sorted(group):
            print(f"      {candidate:<50} ← {', '.join(sorted(users)[:3])}"
                  + (f" +{len(users) - 3}" if len(users) > 3 else ""))
    print(f"   {len(unnamed)} of {len(rows)} row(s) name no replacement symbol at all — a direction "
          "signal, not a migration path.")
    print()


def main():
    args = sys.argv[1:]
    verify = "--no-verify" not in args
    control_only = "--control" in args

    sdk, sdk_version = resolve_sdk(verify and not control_only
                                   and "--certify" not in args and "--floor" not in args)
    if "--floor" in args:
        return floor_probes()
    if "--certify" in args:
        print("RED CERTIFICATES — two mutations, two dimensions:")
        return certify(sdk)
    modules, first_party, file_count = derive_modules()
    print(f"MODULES:      {len(modules)} imported by {file_count} of this repository's Swift files "
          f"(first-party skipped: {', '.join(first_party)})")
    print(f"              {', '.join(modules)}\n")

    findings, not_scanned, scanned = collect(sdk, modules, report=True)

    # ---- the positive control, before anything else is believed
    found = {s: v for rows in findings.values() for (_, s, v, *_ ) in rows}
    missing = {s: want for s, want in POSITIVE_CONTROL.items()
               if found.get(s) != want}
    print("POSITIVE CONTROL — five rows measured by hand from AVVideoComposition.h:")
    for symbol, want in POSITIVE_CONTROL.items():
        got = found.get(symbol)
        mark = "ok  " if got == want else "MISS"
        print(f"  {mark}  {symbol}  expected {want}, scan says {got or 'ABSENT'}")
    print("PARSER CONTROL — two rows this file has actually got wrong:")
    parser_ok = parser_control(sdk)
    if missing or not parser_ok:
        print("\nTHE CONTROL FAILED. The scan is wrong, not the SDK. Every row below is unearned "
              "until this passes — do not read them.")
        return 1
    print("  all controls reproduced.\n")
    if control_only:
        return 0

    total = sum(len(v) for v in findings.values())
    print(f"{total} deprecated declarations across {len(scanned)} scanned module(s).\n")

    # The whole table goes to a file, and only the small buckets are printed. `<= 26.0` is every
    # deprecation since 10.0 and would bury the two buckets that carry a decision — but suppressing
    # a bucket from the console is not the same as not producing it, so it is written out in full.
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv \
        else Path(os.environ.get("SCRATCH", "/tmp")) / "sdk-deprecations.tsv"
    with out.open("w", encoding="utf-8") as fh:
        fh.write("bucket\tmodule\tsymbol\tdeprecated_in\tfile\tline\tmacro\n")
        for bucket in BUCKET_ORDER:
            for module, symbol, version, rel, lineno, macro in sorted(findings[bucket]):
                fh.write(f"{bucket}\t{module}\t{symbol}\t{version}\t{rel}\t{lineno}\t{macro}\n")
    print(f"FULL TABLE:   {out}  ({total} rows, every bucket, nothing suppressed)\n")

    for bucket in BUCKET_ORDER:
        rows = findings[bucket]
        print(f"── {bucket}: {len(rows)} / {total} — {BUCKET_MEANING[bucket]}")
        if bucket == "<= 26.0" and len(rows) > 40:
            by_module = defaultdict(int)
            for module, *_ in rows:
                by_module[module] += 1
            print("   console listing suppressed at this size; per module, from the file above:")
            for module, n in sorted(by_module.items(), key=lambda kv: -kv[1]):
                print(f"      {module:<20} {n}")
            print()
            continue
        for module, symbol, version, rel, lineno, macro in sorted(rows):
            print(f"   {module:<20} {symbol:<52} {version:<7} {rel}:{lineno}")
        print()

    report_replacements(sdk, findings["== 27.0"])
    report_use("--in-use" in args)

    if not_scanned:
        print(f"── NOT SCANNED: {len(not_scanned)} module(s) with neither headers nor a "
              ".swiftinterface in this SDK.")
        print(f"   {', '.join(not_scanned)}")
        print("   Reported as not scanned, NOT as zero deprecations, and excluded from every "
              "count above.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
