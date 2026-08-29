# Contributing to Soredemo

Thank you for looking. This document is the short version of how work happens here; the long
version is [`AGENTS.md`](AGENTS.md), which governs everything and is worth reading before you
write code.

**The one-sentence summary of this project's standards: a claim in a comment is worth nothing
unless something checks it.** Most of what follows is a consequence of that.

---

## Before you start

| You want to | Do this |
| --- | --- |
| Report a bug | Open an issue. Say what you did, what happened, and what you expected — and give your macOS version, because this app is close to the OS |
| Suggest a feature | Open an issue. [`docs/research/competitors.md`](docs/research/competitors.md) has the ranked gap list; saying which row you mean, or why the list is wrong, saves a round trip |
| Report a vulnerability | Use GitHub's private vulnerability reporting on this repository rather than a public issue. This app records screens and microphones, so a defect that leaks either is worth handling quietly first |
| Send code | Read the rest of this file first |

---

## Getting it running

```bash
git clone https://github.com/soredemo-dev/soredemo.git
cd soredemo
open Soredemo.xcodeproj
```

⌘B builds, ⌘R runs. macOS 26 and Xcode 27 — [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md) explains why
the floor is where it is and why you do **not** need a macOS 27 volume.

If macOS stops trusting your development build's permissions — which happens after enough
rebuilds — reset them rather than fighting them:

```bash
tccutil reset ScreenCapture dev.soredemo.mac
tccutil reset Microphone dev.soredemo.mac
tccutil reset Camera dev.soredemo.mac
```

---

## The four gates

**Run them in this order, one at a time.** They are not independent: several of them clean and
rebuild `.build`, so running two at once makes them delete each other's work and look like a hang.

```bash
scripts/count-tests.sh --split              # 1. the whole suite, partition verified
scripts/check-strict-memory-safety.sh       # 2. zero unmarked unsafe sites, clean compile
scripts/run-cross-boundary-probe.sh         # 3. the checks that need a real display and files
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo   # 4. the app target
```

There is no CI in this repository yet, so these are gates a person runs. A pull request that has
not been through all four will be asked to go through all four.

**In zsh, `./script | tail -4` reports `tail`'s exit code, not the script's.** If you are checking
a gate's status in a pipeline, `$pipestatus[1]` is the one you want — `$PIPESTATUS[0]` is bash.

---

## How code is written here

These are not style preferences. Each one exists because its absence caused a specific bug that is
recorded in `git log`.

### Measure; do not infer

Four separate theories about why the editor would not go full screen were each killed by a
measurement rather than by an argument. If you are about to write "this is because…", check
whether you can print it instead.

**Never conclude that something is absent from one `grep`.** A search for `Soredemo/UI/` missed a
path built as `appending(path: "UI/…")` and a search with an unquoted `--include=*.swift` was
silently eaten by the shell. Read the whole block before claiming a thing is not there.

### A public option nothing tests is an unverified claim

`CameraOverlayStyle.borderOpacity` shipped, was configurable, and had never drawn a pixel. If you
add a knob, add the test that turns it and looks.

### Guards must be observed failing

A test that has never been red is not known to test anything. Break the code deliberately, watch
the test fail, put it back. Three checks written on this project passed while testing nothing —
one read the app's own constants instead of pinning literals, one scanned string content that the
source lexer blanks by design, and one compared whole segments where it meant to compare places.

### Comments say *why*, and there are fewer of them than you think

A comment that says *what* the code does is a sign the code should be rewritten. Name things well
and the reader needs no help; the only thing a reader cannot recover from the source is **why it
is this way and not the obvious way**.

So there are two kinds of comment here and they have different jobs.

**A doc comment** on a type or a function says what it is, how to use it and how it behaves. It is
for somebody deciding whether to call it. Keep it to a few lines.

**An inline comment** exists only where the code cannot speak: a constant that came from a
measurement, a constraint the compiler cannot express, or an alternative that will otherwise be
"fixed" back in six months. Those are worth their space —

    // `terminate()` sends a quit the system honours; measured, Finder did not come back.
    kill(application.processIdentifier, SIGTERM)

— because the next person deletes the line without them.

**Everything longer belongs in `docs/`.** A paragraph of reasoning is not less valuable there; it
is more findable, it can be read without a compiler, and it stops the file it came from being 40%
prose. Leave one line pointing at it. If the reasoning is worth 300 words, it is worth a heading.

**No competitor is named in the source.** Not as evidence, not as attribution. State the technical
fact — the fact is what the reader needs, it survives the other product changing, and a repository
does not audit its own reasoning by pointing at somebody else's. Comparisons live in
`docs/research/`.

### Comment budget

Roughly **one line of comment to five of code** across a file, and a file well past that is telling
you its reasoning wants to be a document. This is a smell to check, not a limit to enforce: a
tricky 40-line algorithm may be half comment and be right.

### Named values, never a silent default

A measurement has no safe default. Every refusal is a named value rather than `nil`, and every
`Decodable` type validates in `init(from:)` rather than trusting the synthesised initialiser.

### Authored values survive re-derivation

If a person set it, re-deriving must not replace it. Test that by supplying a value the deriving
code could not have produced.

### Where a new file goes

`docs/ARCHITECTURE.md` D1a decides the tier (package or app); D1b decides the group inside the app.
Groups are by feature — `Editor/`, `Recording/`, `Inspector/` — never by type. There is no
`Utilities/`, `Helpers/`, `Common/` or `Shared/`, and there will not be: a folder whose membership
rule is "nowhere else fits" has no membership rule.

---

## Commits and pull requests

- **Imperative mood, and say what changed rather than what you touched.** "The desktop's icons hide
  for a recording" beats "Update DesktopIcons.swift".
- **The body is where the reasoning goes.** What you measured, what you rejected, and what the
  change costs. If a gate count moved, say the numbers.
- **State what the change does not do.** A commit that says "this did not split the two large
  files, and here is why" is more useful than one that leaves it to be discovered.
- Reference an issue with `Fix #123` when there is one.

A pull request should say which of the four gates you ran and what they reported.

---

## What will be declined

Not because the code is bad — because they contradict a decision the project has already made in
writing.

- **Anything that uploads.** The publishing rule: nothing this app produces leaves the machine
  without a person sending it. No share links, no cloud storage, no telemetry, no "approve all".
  This removes a whole column of features other recorders have, on purpose.
- **`.glassEffect()` / `NSGlassEffectView`.** App chrome is standard SwiftUI; content surfaces are
  deliberately opaque.
- **Code copied from another recorder.** `../opensource/` is read for ideas. `NOTICE.md` records
  what was learned from where, and that is the form attribution takes here.
- **A feature with no test that exercises it.** See above.

---

## Licence

Contributions are under the [MIT licence](LICENSE), the same as the project.
