# Two clocks, two types

**2026-11-09.** Why a moment on the recording and a moment in the edited video are no longer the
same type, and how far that goes today.

## The question

The editor has two clocks. The **recording's** — the source, what the observation log, the steps,
the notes and the playhead are on — and the **edit's** — the output, where a moment plays once cuts
and speed changes have moved everything after them. `EditTimeline.sourceTime(atOutput:)` and
`outputTime(atSource:)` convert between them.

Both were `Nanoseconds`. So a conversion done the wrong way round compiled, and it was done the
wrong way round four times in one feature (commit `bcec2e4`): the agent's seek, its status, the
context sent with each message, and the note layer. Every test passed because no fixture had
anything cut before the moment it asked about — the one place the two clocks agree. AGENTS.md's
identity-fixture rule describes the failure exactly, and a rule did not prevent it.

## Alternatives

| | What it costs | What it catches |
| --- | --- | --- |
| Name parameters better (`sourceNanos`, `outputNanos`) — what both open editors read here do | nothing | a careful reader. `NoteLayer` passed a correctly named value through the wrong function; one Rust editor read calls the same clock `frame_time` in one function and `output_time` in the next |
| A test with a cut before the moment, everywhere a time crosses | one test per site, and every new site has to remember | the sites somebody wrote a test for |
| **A type per clock** | a migration | every site, at compile time, including the ones nobody thought of |

**Decided: a type per clock.** `Moment<Clock>` with two phantom clocks, `RecordingClock` and
`EditClock`, spelled `SourceTime` and `OutputTime`. It is written here rather than taken from a
package: rule 4 admits no dependency outside apple, swiftlang and modelcontextprotocol, and the
type is forty lines.

**A length has no clock and stays `Nanoseconds`.** Two moments on one clock subtract to a length;
a moment plus a length is a moment on that clock; there is no operator that mixes clocks. The
encoding is the wrapped `Nanoseconds`' own, byte for byte, so a moment written to disk later reads
the same as a `Nanoseconds` would have.

## What was read first

Two open editors, read for this: a native macOS editor whose clips are `Int` frames, told apart by
name (`startFrame` on the timeline, `trimStartFrame` into the source), and a Rust editor whose times
are `f64` seconds told apart by name, mapping an output time to `Single`, `Hold` or `Transition` —
because across a transition one output moment shows **two** source moments. Neither types its
clocks. Two things taken: a clip's own clock is a third clock (below), and the conversions should
be checked as each other's inverse across every clip, which that editor's verification crate does
by sampling. When Soredemo gains transitions, `sourceTime(atOutput:)` stops being a function to one
moment and its return type changes with it.

## How far it goes

The migration is in phases, and each phase is the next set of signatures to change — not a list
of sites, which the compiler produces.

1. **Done 2026-11-09:** the two conversions, and the playhead (`TimelineEditorModel.playhead`,
   `movePlayhead(to:)`) — where the defect was.
2. **Open:** the rest of `EditTimeline`'s clock-bearing API — `clip(atOutput:)`,
   `clip(atSource:)`, `split(atOutput:)`, `outputStart(of:)`, `outputStarts`,
   `visibility(atOutput:)`, `restricted(toOutput:)`, `survival(ofSource:)`,
   `trimmed(toSource:)`, `removing(sourceRange:)` — and the `Range<Int64>` spans they take, which
   want a `Span<Clock>`.
3. **Open: a clip's own clock.** One native editor read keys its keyframes to a clip's start
   (`frame − startFrame`), a third clock spelled as a helper's name. Soredemo's fades are already
   on it (`visibility(atPlayOffsetSeconds:)`), as a `Double`.
4. **Open:** the recording's other instants — the observation log's host time, the steps, the
   notes — which are on the host's clock and reach the recording's through the epoch anchor, a
   fourth clock no type names yet.

**What the compiler checks**, measured 2026-11-11 against the package build with three files: a
same-clock control (`SourceTime − SourceTime` is a length, a moment plus a length is a moment)
compiles and runs; `SourceTime − OutputTime` fails with *cannot convert value of type
'OutputTime' to expected argument type 'Moment<RecordingClock>'*; and passing a `SourceTime` to
`sourceTime(atOutput:)` fails with *cannot convert value of type 'SourceTime' to expected argument
type 'OutputTime'*. That is a fact about the type, not a test: a test that compiles code to watch it
fail needs a compiler at test time, and the package's own build already is one.

## What the migration found

Phase 1 changed two signatures and the playhead, and the compiler then refused every site that
had to say which clock it meant. Three of those sites were defects, each with every test green:

| Site | What it did | After a cut before it |
| --- | --- | --- |
| an agent edit's "show me" (`AgentEditRecord.at`) | stored where the cut plays in the edit, then moved the playhead — which is on the recording's clock — there | the jump landed that much too early |
| a note's row in the panel, "go to" | converted the note's recording time to the edit's and moved the playhead to the result | the same |
| a cut proposal's row, "go to" | moved the playhead to the proposal's start in the edit | the same |

Together with the sites `bcec2e4` fixed and the scrub fixed on 2026-10-23, each was this one
confusion, and each was found only after it had shipped — which is the argument for the type rather
than for more care. None of the three above has a behavioural test: two are views, and
`AgentEditRecord.at` is now a `SourceTime`, which is the check.
