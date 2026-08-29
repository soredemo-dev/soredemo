# Surviving a stopped stream

*Written 2026-08-30. Code: `Core/Sources/Capture/StreamStopReason.swift`,
`CaptureSession.handleStreamStop(_:)`.*

ScreenCaptureKit reports every stop through one delegate callback. The person pressing stop in
the system's capture control, the display going to sleep under a closed lid, a missing
entitlement, and the capture daemon dying all arrive as `stream(_:didStopWithError:)`.

Until this change the session treated them alike: close the segment with `.failed`, and the
recording is over. A lid closed for ten seconds ended a forty-minute session, silently, and the
only trace was an error string in `project.json`.

## The codes, and which of them are worth outliving

Read from `SCError.h` in the macOS 26.5 SDK and confirmed at runtime against
`SCStreamError.Code` before anything was written against them.

| code | name | verdict |
| --- | --- | --- |
| -3817 | `userStopped` | the person did this; reopening fights them |
| -3821 | `systemStoppedStream` | the display was taken away and comes back |
| -3804 | `failedApplicationConnectionInvalid` | the daemon connection died, not the capture |
| -3805 | `failedApplicationConnectionInterrupted` | same |
| -3811 | `internalError` | **not** restarted — see below |
| everything else in the domain | permissions, entitlements, parameters, missing sources | rebuilding reproduces it |
| any other domain | not ScreenCaptureKit's verdict at all | refuse |

`-3811` is the one judgement call. Its documented meaning is "video/audio capture failure", which
covers faults that reproduce on the next attempt as readily as ones that do not. A restart loop
over a reproducing fault spends the entire budget in the time it takes to fail five times, and
ends in the same place having wasted ten seconds. It stays a refusal until a real recording is
observed recovering from it — at which point the evidence, not the guess, moves it.

An error the type cannot place still gets a case. `.unrecognised(domain:code:)` carries what was
actually seen and refuses to restart. A restart decision made from an unrecognised error is a
decision made from nothing.

## The recovery is the pause mechanism

ScreenCaptureKit has no pause, so `pause()`/`resume()` already means *close this segment, open the
next one over the saved geometry*. A survived interruption is exactly that, so it reuses exactly
that. The shape on disk is the shape a pause produces — two segments with a stated boundary
between them — and everything downstream that already handles a paused recording handles this one
without knowing it exists.

Geometry is the **saved** geometry, never re-derived. A display that slept and woke is the same
display, and re-deriving would mint a new `GeometryRevision` for a change that did not happen. A
display that genuinely changed while the stream was down arrives on its own, through the
reconfiguration observer, which stays registered across all of this.

The segment is closed *before* the first attempt, not after the last. The bytes already written
are worth keeping whether or not the restart works, and a writer held open across a two-second
wait is a writer holding a stream that is already gone.

## The budget

Five attempts, two seconds apart.

Five rather than three: each attempt is a whole stream rebuild against a source that has just been
disturbed, and the first attempt after a display wakes is the one most likely to lose a race with
the window server. Five consecutive failures is no longer a race.

Two seconds rather than something shorter: a closed lid is not open again in a hundred
milliseconds, and an attempt made into a display that has not returned is an attempt spent for
nothing. Ten seconds of total absence is survived; a daemon restart, which is over almost at once,
costs one gap of two seconds.

Neither number is measured, because neither is measurable without an apparatus that closes a real
lid. They are bounds with stated reasons, and `theRestartBudgetSpansTenSecondsOfAbsence` pins them
so that changing one is a decision rather than a drift.

When the budget runs out nothing is torn down: `isRunning` stays true and the observer stays
registered, so `stop()` still reaches its no-segment-open branch and still returns the table for
what *was* recorded. That is the state a `.failed` boundary has always left behind, so the
give-up path is the path that was already tested.

## `.interrupted` is not `.failed`

They describe different recordings. `.failed` is the last segment there will ever be.
`.interrupted` is a gap in the middle of one that continued. A table that read one back as the
other would claim a continued recording ended, or an ended one continued, so the distinction
survives the round trip to disk and a test says so.

## Why `.interrupted` carries no user data

`SegmentBoundary.failed` is adjudicated REDACT in `FixtureRedactionTests`: it carries
`String(describing: error)`, and AVFoundation and ScreenCaptureKit error descriptions routinely
embed a file URL — home directory, username, package name.

`.interrupted` is adjudicated **keep**, and the reason is a closure rather than a hope. It is only
ever given `StreamStopReason.description`, which is fixed English the type builds from its own
case, plus an integer code, plus — in `.unrecognised` alone — an `NSError` domain.

That last one was a hole, and the test found it before the fixture did. A domain is chosen by
whichever subsystem raised the error; nothing stops one being built from a path. So the domain
reaches disk only when it looks like an identifier — letters, digits, dots, hyphens, underscores,
at most 200 characters — and otherwise the description says a domain was withheld and how long it
was. Every domain Apple ships is a reverse-DNS identifier, so the rule costs nothing on any error
expected here; it exists for the one that is not expected.

The refusal states its cost rather than hiding it: a support log can still tell an empty domain
from a domain too strange to repeat.

Both halves are pinned. `theInterruptedBoundaryCarriesNoUserData` asks every case for its
description against an error whose own description is nothing but a home path, and
`ordinaryErrorDomainsSurviveTheIdentifierRule` checks that real domains still come through —
without which a rule that withheld everything would pass the first test and be useless.

## What is counted

`Diagnostics` records every stop as `StreamStopReason` read it, in order, whether or not a restart
followed; attempts made; attempts that opened a segment; and, if the budget ran out, why. A
session that recovered twice and a session that stopped once are different sessions, and only the
list can tell them apart.

A rebuild that throws after the ledger opened its segment leaves that segment open, so it is
closed through the ordinary path before the next attempt — which routes it into
`discardedSegments` with its writer status and retained scratch path. That is the per-attempt
record, and it is why the catch block does not write one of its own.
