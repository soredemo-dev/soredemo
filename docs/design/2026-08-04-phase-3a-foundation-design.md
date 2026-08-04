# Phase 3A-1 — `Headless`: the layer `swift test` can reach

**Status:** design, approved section by section 2026-08-04.
**Scope:** move `Soredemo/Render/` (5 files) and `Soredemo/Export/MP4Exporter.swift`
into a new SwiftPM target. 404 non-comment lines. `Soredemo/Capture/` (2,293 lines)
is 3A-2 and not in this design.

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

## 3. The entry rule, and the two layers it is written in

`Headless`'s most likely death is becoming a dumping ground: whatever is
inconvenient in the pure tier migrates over, and in three months it is the new
untested layer — wearing a name that sounds like the problem was solved.

**The rule:** every `public` type in `Headless` must have a test in `swift test`
that constructs and exercises it.

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

    swift test — deterministic   466 passed
    swift test — headless          N passed    (GPU / timing sensitive)
    cross-boundary probe         349 checks

## 5. The completion condition

A person can see this: **`swift test` contains a test that `import SoredemoHeadless`,
constructs a `StageCompositor`, feeds it a RECORDED observation log, and asserts
the drawn pointer's position at a given frame. Reverting `1a98402`'s one line turns
it red.**

That is the evidence that an automatic instrument now reaches the code only a
person reached today.

**Reachable in 3A-1 with no `Capture` code moved**, verified before this design was
written: `StageCompositor.buildTracks` reads the log entirely through
`JSONLReader` and `ObservationLog`, both already in `Sources/Project`.
`ObservationWriter` — which stays in `Capture` — is needed only for writing and for
`expectedLogURL`, and the completion condition needs neither.

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
