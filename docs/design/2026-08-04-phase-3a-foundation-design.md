# Phase 3A-1 — `Headless`: the layer `swift test` can reach

**Status:** design, approved section by section 2026-08-04.
**Scope:** move `Soredemo/Render/` (5 files) and `Soredemo/Export/MP4Exporter.swift`
into a new SwiftPM target. 404 non-comment lines. `Soredemo/Capture/` (2,293 lines)
is not in this design.

> **This line originally read "`Soredemo/Capture/` (2,293 lines) is 3A-2".**
> Corrected 2026-08-05, after 3A-1 shipped: Capture extraction is **3A-3**. 3A-2 is
> the three things 3A-1 deferred — repair the strict-memory-safety gate, then clear
> the 11 sites it should have caught; make `1a98402`'s clock-domain confusion a
> compile error; narrow `MP4Exporter.swift`'s whole-file ambient-time permit to
> named functions. The reason is 3A-1's own outcome: it carried a code move AND the
> instruments that move needed, and the move is what finished — one instrument
> shipped structurally broken and three items were deferred. Attaching those three
> to a 2,293-line move repeats that arrangement with the same losing side, and they
> would be deferred to 3A-3 anyway. A phase name that claims a scope it does not
> have is the defect this project has now hit in a file, an identifier, a test file
> name, a probe heading and a git ref; this is it at phase level.

---

## 1. Why

The app target has **no automated executing instrument**. `swift test` cannot link
an `executableTarget`, so `Tests/AppSourceTests` reads `Soredemo/` **as text**
through `CheckerLexer` — it checks that code *says* the right things and cannot run
a line of it. The only things that execute app code are
`scripts/run-cross-boundary-probe.sh` and a person running the built `.app`.

`1a98402` lived in app code for a whole phase: `StageCompositor.pointerPlacement`
queried a track stamped in the absolute host clock using a composition time, so
`.noObservationYet` came back for every frame of every recording and **no build of
this app had ever drawn a pointer** — through 450 tests, 350 probe checks, eight
task reviews and fifteen fix rounds. A person found it, four seconds into a
recording.

That is structural, not a shortage of tests. This design makes the file that
contained it linkable.

## 2. The layer is defined by testability, not by a framework list

An allow-list of frameworks is a mechanism, not an invariant: define the boundary
that way and it has no principle, only a table that grows one row at a time. The
three tiers are defined by what can exercise them.

| Tier | Invariant | Contents |
| --- | --- | --- |
| `Sources/Geometry…Render` | **Deterministic**: same input, same output. No GPU, no clock, no window | the seven existing targets, unchanged |
| **`Sources/Headless`** | **Runnable under `swift test` on a developer machine**, even where not bit-deterministic — real pixel buffers, GPU, wall time are all allowed | `Soredemo/Render/`, `Soredemo/Export/`; later `Soredemo/Capture/` |
| `Soredemo/` | **Only a running app can reach it** | SwiftUI, `NSDocument`, app lifecycle |

**The name states the exclusion.** *Needs a window or a running app → does not
belong here.* SwiftUI is excluded by the name rather than by a rule written beside
it, and the invariant survives 3A-2: `Render` would expire when `Capture` moves in;
`Headless` does not.

**It is not called `SoredemoCore`.** That name is already the Foundation-only
product — `KICKOFF.md`'s D6 ("imports Foundation only. No AppKit, no
ScreenCaptureKit, no AVFoundation"), the completion criterion for
`architecture-plugin` ("adding `import AppKit` to `SoredemoCore` **fails the
build**"), `AGENTS.md`, and `Minting.swift`'s header ("the three things
`SoredemoCore` is forbidden to do"). Putting app logic under that name would make
five documents false. `Headless` gets its own product, `SoredemoHeadless`; adding
it to `SoredemoCore`'s `targets:` array would itself break D6.

### The architecture plugin is target-scoped, and `Headless` gets its own guard

**Measured before choosing the directory.** `ArchitectureCheck` passes
`--sources target.directory.string` and is attached per target in the manifest
(`plugins: archCheck`, on seven targets). It is not path-scoped to `Sources/`, so
`Sources/Headless` is a fine location and the Foundation-only guard needs **no
directory exception** — a guard with an exception is not a guard, and this project
has watched that fail twice this week.

**But omitting the plugin leaves `Headless` with no architecture check at all.** The
answer is not a hole in the pure guard; it is a second guard enforcing `Headless`'s
own invariant: **`import AppKit` or `import SwiftUI` in `Headless` fails the build.**
Two guards, two rules, no exceptions. There is precedent for a target carrying no
`archCheck` (`CheckerLexer`, for a dependency-cycle reason), and its consequences
are written down beside it rather than enforced — `Headless` is not to inherit that
arrangement, because it is the target most likely to drift.

## 3. The entry rule, and the two layers it is written in

`Headless`'s most likely death is becoming a dumping ground: whatever is
inconvenient in the pure tier migrates over, and in three months it is the new
untested layer — wearing a name that sounds like the problem was solved.

**The rule:** every `public` type in `Headless` must have a test in `swift test`
that constructs and exercises it.

*"Type" means every `public` `struct`, `class`, `actor` and `enum`. A `public`
protocol is exempt from CONSTRUCTION and not from exercise: some conforming type
must be exercised, which is what makes the protocol's existence load-bearing —
the `FrameRendering` / `MasterWriting` seams are the shape this is written for.
**The exercised conforming type may not be a test-only type.** A `struct`
declared in a test file satisfies the letter and inverts the meaning: the seam
would be verified entirely through a double while the production conformer
never runs — a mechanism validated only by test-only callers, which is the
failure these two seams are most exposed to.
A `public` function or property on an exercised type needs no separate entry.*

**The known gap, written down rather than argued away.** Type granularity means
a `public` method added to an already-admitted type enters free. That is a cost
trade, not a principle — "a type is the unit a test can hold" would be a weak
reason, since a test holds a method call perfectly well. It is recorded here to
the same standard § 6 records the redaction's reproducibility: an unwritten cost
reads as zero.

**The scanner's discriminating power falls as the type name gets more generic.**
`Frame`, `Track`, `Renderer` appear at a word boundary in almost any test file,
so for those the necessary condition is close to vacuous — and things in a
dumping ground are frequently named exactly that. The scanner's message must say
so at the point of passing, not only in this document.

**The rule is enforced at two levels, and they are deliberately not the same.**

- **The scanner enforces a NECESSARY condition**: the type's identifier appears,
  at a word boundary, in the code view (`SwiftSourceLexer` — comments and string
  literals blanked) of a test target. This catches the cheap violation: a public
  type nothing mentions.
- **Review enforces the rule itself**: that a test *constructs and exercises* it.
  A scanner cannot see that. A type annotation, a doc comment, or an unused import
  would satisfy the scanner.

Writing "the scanner enforces the rule" would be this project's own recurring
defect — the § 12 / D6a-N shape planted inside the gate built to prevent it. The
scanner's message says which of the two it is.

**Ex ante, not ex post.** D6a-V names dead API after the fact; this refuses entry.

## 4. Gate output keeps the two suites apart

`swift test` will hold two populations with different guarantees: the existing
deterministic tests, and `Headless` tests that may need a GPU, may be
time-sensitive, and may answer differently on another machine. Reporting one
`N tests pass` silently changes what that number means — one symbol for two things
is the shape this project has caught most often.

**Separated by the build graph, not by a rule.** Two counts are an assertion until
something prevents a test landing in the wrong population. **The deterministic test
targets must not depend on `SoredemoHeadless`**: a test that cannot link it cannot
be written against it, so the split is enforced by the manifest rather than by
anyone remembering. `Headless` tests live in their own target, which is the only
one that depends on the product.

    swift test — deterministic     N passed
    swift test — headless          N passed    (GPU / timing sensitive)
    cross-boundary probe         349 checks

## 5. The completion condition

A person can see this: **`swift test` contains a test that `import Headless`,
constructs a `StageCompositor`, feeds it a RECORDED observation log, and asserts
the drawn pointer's position at a given frame. Changing
`StageCompositor.pointerPlacement`'s `let time = anchor.hostTime + offset` back to
`let time = offset` turns it red.**

*(**`import Headless`, corrected in place when Phase 3A-1 Task 6 landed.** This line
read `import SoredemoHeadless` as drafted. `SoredemoHeadless` is the PRODUCT name —
still real, still what the Xcode app target links — but the importable module is the
TARGET, `Headless`, and `import SoredemoHeadless` does not compile. Nothing about the
decision changed, only the spelling; corrected here rather than left for the next
reader to copy. The test that satisfies this condition is
`Tests/HeadlessTests/RecordedPointerPositionTests.swift`.)*

**Red for the right reason, in two layers.** That mutation makes the lookup time a
small fraction while the records are mach absolute times (~5.2 × 10¹⁴), so nothing
matches and the compositor most likely draws **no pointer at all** rather than a
misplaced one. Both are red, but the capability this test claims is POSITION — and
a vanished pointer is what a person already catches; `1a98402` was caught that way.
So:

1. `aPointerIsDrawnAtAll` — some pixel differs from the unmodified source frame
2. `aPointerIsDrawnAtTheRecordedPosition` — it is at `p`

The `let time = offset` mutation must break (2) while (1) still holds is NOT
achievable, so it is not the calibrating mutation for (2). **A second mutation that
can only misplace** — swapping `placement.x`/`.y`, or adding a constant offset — is
required, and both observed reds go in the report. One mutation that reddens both
layers proves only that the pipeline noticed something.

That is the evidence that an automatic instrument now reaches the code only a
person reached today.

**Reachable in 3A-1 with no `Capture` code moved**, verified before this design was
written: `StageCompositor.buildTracks` reads the log entirely through
`JSONLReader` and `ObservationLog`, both already in `Sources/Project`.
`ObservationWriter` — which stays in `Capture` — is needed only for writing and for
`expectedLogURL`, and the completion condition needs neither.

### The observations are recorded; the source frame is constructed

The fixture carries no media — the 29 MB `.mov` is correctly excluded — so the test
synthesises the source frame it composes. That is fine and deliberate: the
assertion is about geometry, not about what the frame depicts. It is stated here
because § 6 spends a section establishing "recorded, not constructed" and a reader
would otherwise carry that over the whole input. **Observations recorded, source
frame constructed.**

One requirement follows: **the constructed frame must contrast with the cursor
art** (white fill, black stroke). A white or near-white frame makes "find the drawn
pointer" fail for a reason that has nothing to do with position — red for the wrong
reason, one more time.

## 6. The fixture: recorded, not constructed

The property that matters is not that the file is untouched. It is that **every
value the compositor consumes was recorded by the real writer through the real
capture path, and was written before this test existed.** That is the sole reason
it cannot repeat probe § 12, where a fixture's values were produced by the same
misunderstanding as the code under test.

Source: `~/soredemo-evidence/row14/…/observations/segment-00.jsonl`, 411 lines —
`251 pointer / 149 tapDisabled / 6 button / 3 axChain / 1 header / 1 trailer`.

**Half its value is that it is dirty.** 149 tap-disabled windows, an
`accessibilityUnavailable` in the header's `blindness`, a mid-recording
authorisation flip, two different blind rates across one session. Recording four
seconds against an empty desktop would produce a file with almost none of that:
a clean input is the easy case, and this fixture exists because it is not easy.

### Redaction, decided by schema and not by instance

Enumerating the string fields *present in this file* finds one piece of user data.
Enumerating the string fields **in the schema** finds two, and the second is
absent from this file:

| Field | Verdict |
| --- | --- |
| `AXElementRecord.title` | **redact** — user data, in `ancestors[]`, `children[]`, `hit` |
| `KeyRecord.shortcut` | **redact** — keystrokes. **Zero occurrences in this file**, so a scan of the instance can never find it, and the next fixture recorded by someone who used a shortcut carries their typing into git |
| `AXElementRecord.role` | keep — system AX role constant |
| `kind` (×6 types), `mediaFilename` (×2) | keep — program constants |
| every `epoch.id` | keep — program-minted UUID |
| `blindness[]`, `detectedBy`, `disabledBy`, `phase`, `button`, `truncation`, `lowerBoundFrom`, `gapWatches[].site`, `.lostUnit` | keep — closed enumerations |

Nothing the compositor consumes is touched: every timestamp, every coordinate, the
anchor and all 149 intervals are byte-for-byte the recorded values.

**The table above is machine-checked, not hand-read.** Its force comes from
"decided by schema, not by instance", and a hand enumeration of the schema is
itself a `[prose]` assertion — guarding user data reaching git. So a scan lists
every string-valued field in the observation-log schema and compares it against
the adjudicated set; **an unadjudicated field is red**. Verified today by hand
(`AXElementRecord` has exactly `role`, `title`, `frame`, `readInterval` — no
`identifier`), which is the reason the scan is needed rather than a reason it is
not: Phase 3 adds cursor shape, which will very likely carry a string, and the
gate must speak up then instead of waiting for someone to remember this table.

### Two gates, one for the file and one for the reader

1. **Content**: a test asserts that no `title` or `shortcut` in any committed
   fixture holds a value other than the placeholder. This exists for the future —
   a second fixture, or a re-redaction, when nobody re-checks that the script ran
   correctly. A leak is red before it is committed.
2. **Consumption**: a test asserts the render path never reads either field.

### Reproducibility, stated honestly

The redaction script is committed, but reproducing it needs the unredacted
original, and that exists only on the author's machine. **This redaction is
auditable by its author and not by its readers**: a future reader can verify the
negative (nothing remains) and cannot verify that the right things were removed.
This is a known cost of choosing a recorded fixture over a constructed one, and it
is written down because an unwritten cost reads as zero.

## 7. Two risks named before implementation

**The probe's visibility changes.** §§ 12/15/16 today compile
`Soredemo/Render/*.swift` as source and therefore see `internal`. Linking
`SoredemoHeadless` instead sees only `public`. **No declaration may be widened to
`public` to make the probe compile** — that would silently grow the public surface,
which the entry rule then requires tests for, which puts pressure on loosening the
scanner. Use `-enable-testing`, or move the check.

**`MP4Exporter` brings I6 with it.** Its readiness poll is uncapped, and this repo
has *measured* the stall it would spin on (Spike D). The entry rule forces a test
that exercises the exporter; an uncapped poll inside `swift test` is a hang with no
diagnosis. **Either cap the poll in 3A-1, or that test carries a timeout. Not
neither.**

**The pbxproj change is verified by a red, not by a parse.** Hand-edited pbxproj
has failed in this repo before. Remove the product dependency and confirm the build
fails; "it parses" is not verification.
