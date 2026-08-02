# Phase 2A — Record: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use a skill chain:subagent-driven-development (recommended) or a skill chain:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A build that records the screen to an immutable master and writes an observation log beside it, with every timestamp on one clock and every judgement deferred to derivation.

**Architecture:** `AVAssetWriter` writes the master from three `SCStream` outputs (screen, system audio, microphone) because `SCRecordingOutput` mixes the microphone in at our floor (F2-4). The master is a *sequence* of segments, because ScreenCaptureKit has no pause (D2-9). Observations carry host time stamped with a boot epoch (D2-11), record the whole AX chain without choosing an element (D2-1), and store truncation and gaps as records rather than absences.

**Tech Stack:** ScreenCaptureKit · AVFoundation · CoreGraphics event taps · ApplicationServices (AX) · Swift Testing · Swift 6 language mode

**Design doc:** `docs/design/2026-08-02-phase-2-record-design.md`. Decisions are cited as D2-n and measurements as F2-n; this plan does not repeat their reasoning. Read D2-1, D2-2, D2-2a, D2-8, D2-9, D2-11, D2-12 before Task 1.

**Scope.** This is the first of two plans for Phase 2. It covers `capture-source`, `capture-stream`, `capture-permissions`, `one-clock`, `audio-tracks`, `input-observation`, `ax-observation` and `observation-log`. The render half — `render-core`, `cursor-render`, `export-basic`, `app-shell`, `preview-playback`, `render-parity` — is a separate plan, written after this one lands so it can be written against the log format as built rather than as designed.

## Global Constraints

- **App Sandbox is already off** (D2-0, applied at `f5fb652` and merged). `ENABLE_APP_SANDBOX = NO` in both configurations, hardened runtime on. Nothing in this plan turns it on, and `ax-observation` cannot work if anything does — the sandbox blocks the Accessibility API against other processes in a layer *in front of* TCC.
- **Package targets import Foundation only.** No AppKit, ScreenCaptureKit, AVFoundation, SwiftUI, CryptoKit, CoreGraphics. `Plugins/ArchitectureCheck` fails the build on violation; do not detach it.
- **No `CGPoint`, `CGRect`, `CGSize`, `CGFloat` in package sources.** In the app they may appear **only** in `Soredemo/Capture/CGGeometryBridge.swift`, enforced by `Tests/AppSourceTests`.
- **No ambient time or randomness in package library targets** — no `Date()`, `UUID()`, `.random(in:)`, `ContinuousClock`, `arc4random`. Checked at link time over object files by `Tests/DeterminismTests`. In the app they may appear **only** in `Soredemo/Support/Minting.swift`, enforced by `Tests/AppSourceTests`.
- **No type may share its module's name.** `Timeline.Timeline` is the failure being avoided.
- **Swift Testing** (`@Test`, `#expect`, `#require`), never XCTest.
- `swiftSettings: [.swiftLanguageMode(.v6), .strictMemorySafety()]` on every target — copy the existing `strict` array in `Package.swift`, do not write a new one.
- App chrome is standard SwiftUI. Never `.glassEffect()`, never `NSGlassEffectView`.
- **Stage explicit paths.** Never `git add -A` — subagents run in this checkout and it has already once swallowed another task's files.
- Count tests with `grep -oE "^✔ Test run with ([0-9]+) tests?"` — a hardcoded plural drops single-test targets and has already put a wrong number into a committed document here.

## Progress — read this, not the step checkboxes

**The per-step `- [ ]` checkboxes below were never maintained.** All 86 sit unchecked while seven
tasks are done, so anything reading them as progress reads 0%. This happened in Phase 1's plan too,
was found and fixed there, and then recurred here — which is why the table is the first thing in the
document rather than a footnote.

| Task | | Landed at | Note |
| --- | --- | --- | --- |
| 1 · `BootEpoch` and epoch-stamped time | ☑ | `0f270ca` + `16747f8` | `GeometryRevision` on the time axis; two preconditions covered out of process |
| 2 · `EvidenceRef` carries the epoch | ☑ | `4489514` … `f6581a1` | first change to move bytes Phase 8's approval gate rests on |
| 3 · observation records and the log's schema | ☑ | `67d3eb0` + `1ea6771` | `.sortedKeys` proven by a deterministic assertion, not a 24-way sample |
| 4 · segment table | ☑ | `0648e4d` + `795f06c` | decode bypassed the validating initialiser; found by review, not by tests |
| 4.5 · decode validation on the live path | ☑ | `bd7d480` | two types, not the seven first scoped — reachability traced rather than asserted |
| 5 · `Minting` gains epoch and host clock | ☑ | `f999630` + `8e37617` | sleep gap 59.68 h against 176 h uptime |
| 5.5 · determinism list gaps | ☑ | `8e7aa6a` | and four more found, deferred to 11.5 |
| 6 · `capture-permissions` | ☑ | `0cde8bb` + `75d8e54` | the blind ordering caught a dump measuring the terminal |
| 7 · `capture-source` | ☑ | `ed86e48` … `52b3763` | buffer is display-sized, proven on two windows; picker restriction proven with a red first |
| 8 · `capture-stream` + `audio-tracks` | ☐ | — | in flight |
| 9 · `input-observation` | ☐ | — | |
| 10 · `ax-observation` | ☐ | — | |
| 11 · `observation-log` | ☐ | — | |
| 11.5 · architecture rule 8 | ☐ | — | plus the four gaps from 5.5 |
| 12 · close out | ☐ | — | |

**324 tests green** across nine targets; cross-boundary probe **28/28**. Count with
`swift test 2>&1 | grep -oE "^✔ Test run with ([0-9]+) tests?" | grep -oE '[0-9]+' | paste -sd+ - | bc`.

---

## Three things Phase 1 did not have

Phase 1 ran nineteen tasks through subagents with one objective gate each: `swift test`. **Phase 2
does not have that gate**, and the same process will fail in the same three places unless these are
constraints rather than notes.

### 1 · A third completion state: *implemented, awaiting human verification*

A subagent cannot grant a permission, move a mouse, or confirm that a picture reached a file. So
"done" and "not done" are not enough, and a task that reports the machine-checkable half as the
whole is the exact failure this project has caught five times.

**Every task carries the split below. A task is `complete` only when both columns are satisfied**;
with only the left column it is `awaiting-human`, and it says so in the ledger.

| Task | Machine-checkable, by the subagent | Needs a human at the machine |
| --- | --- | --- |
| 1 `BootEpoch` | everything — `swift test` | — |
| 2 `EvidenceRef` | everything | — |
| 3 observation records | everything | — |
| 4 `SegmentTable` | everything | — |
| 5 `Minting` epoch | `bootEpoch` stability, `hostNow` monotonicity, `continuousNow >= hostNow` | — |
| 6 permissions | the status functions return *a* value | **yes** — that each value is *correct* against System Settings, and one degradation toggled end to end |
| 7 `capture-source` | `geometry()` is pure: a dragged window yields the same revision | **yes** — the system picker; the scale-to-fill vs letterbox measurement |
| 8 `capture-stream` | segment lifecycle against a fake frame source; boundary reasons | **yes** — a real recording, two audio tracks with both tones live, reconfiguration |
| 9 `input-observation` | the conversion, against fixture points | **yes** — the tap needs Input Monitoring and a moving mouse |
| 10 `ax-observation` | the record types; truncation encoding | **yes** — the walk against three target classes, clicking during animations |
| 11 `observation-log` | the writer against a temp directory | **yes** — end to end, with pauses |
| 12 close out | `swift test`, `xcodebuild`, clean build | **yes** — five negative cases, and the app launching |

### 2 · Mutation checks have no target in code that touches the OS

There is no mutation of "the stream really captured the screen" — not headlessly. Marking it N/A is
a silent gap, and this project's rule is that mutation checks are the *only* mechanism producing a
behavioural red.

So the structure carries the weight: **every task states where the line between the pure core and
the untestable shell falls**, and the shell is kept thin enough that one human verification covers
it. `SegmentTable`, `ObservationLog`, `AXChainRecord`, `EpochAnchor` and the coordinate routing are
all pure, testable and mutable. `SCStream`, the event tap and the AX calls are the shell.

**A task whose line cannot be drawn has a shell that is too thick.** Report that rather than
proceeding — it is a design signal, not an inconvenience.

### 3 · Two kinds of state that outlive a task

**A TCC grant is bound to the signing identity and the bundle identifier.** Any subagent that
rebuilds the app with a different signature orphans every existing grant — and the *next* subagent
sees a failure it cannot diagnose, because the checkbox in System Settings still looks correct.

- The app is `video.soredemo.Soredemo`, signed `Apple Development`, team `GJRVCWA2U3`. **Do not change any of the three.**
- Spikes use their own identifiers (`video.soredemo.SpikeA`, `.SpikeB`) so that `capture-permissions`' first-run flow stays testable. Never run a spike under the product's identifier.
- Between tasks, the review checks that these did not change.
- If a grant appears present but the API says otherwise: re-signing invalidated it.
  `tccutil reset ListenEvent video.soredemo.Soredemo`, then grant again.

**A capture test writes a video of the owner's screen.** This has already cost twice by hand — a
click log carrying real window titles, and a 32 MB recording left in the home directory.

- Capture tests write to a temporary directory only, and delete on completion. **Never to `$HOME`.**
- No recording, log or frame dump is ever committed. `.gitignore` already excludes `*.mov` and `*.mp4` outside `Tests/`; that exception exists for golden fixtures and is not a licence to commit a real capture.
- A report quotes measurements, never window titles or file contents.

---

## The rules this phase keeps re-deriving

Every one of these was reached independently more than once in the design, in different subsystems. They are constraints on implementation, not commentary:

1. **Capture records; it does not judge.** Whole AX chain, whole pointer track, no thinning, no element choice. Producers decide later, because re-recording a demo is expensive and a producer's version number is meaningless over evidence that discarded the alternatives. (D2-1, D2-7)
2. **Silence is not a value.** "Nothing changed", "we were not told", "the chain ended", "I stopped asking" must be different bytes on disk. This is `SCFrameStatusIdle`, chain truncation, segment gaps, and `JSONLReader`'s truncated tail — the same rule four times. (D2-2, D2-6, D2-10, D2-12)
3. **A measurement has no safe default.** Failure lands outside the value range: `precondition`, `nil`, or `throw`. Never a plausible number. (`AGENTS.md`, and F2-4 where the author of the rule broke it)
4. **Preconditions are measured, not requested.** A precondition asked of a human is one that silently did not happen, and its absence looks exactly like a finding. (F2-4)

---

## File structure

**Package — `Sources/Timeline/` (Foundation only, leaf module)**

| File | Responsibility |
| --- | --- |
| `BootEpoch.swift` | the epoch identity; `GeometryRevision`'s counterpart on the time axis |
| `HostInstant.swift` | an epoch-stamped instant, comparison across epochs is a precondition failure |
| `HostRange.swift` | an epoch-stamped interval; replaces `TimeRange?` in `EvidenceRef` |
| `EpochAnchor.swift` | `(epoch, host time, wall clock)`; wall clock explicitly not authoritative for order |

**Package — `Sources/Project/`**

| File | Responsibility |
| --- | --- |
| `ObservationRecord.swift` | the record union written to the log — pointer, click, key, AX, boundary |
| `AXChainRecord.swift` | one AX observation: hit element, bounded ancestors, one level of children, per-item intervals, truncation |
| `ObservationLog.swift` | schema version, encode/decode a record to and from one JSONL line |
| `SegmentTable.swift` | the ordered list of master segments with their epochs and boundaries |

**Package — modified**

| File | Change |
| --- | --- |
| `Sources/Graph/EvidenceRef.swift` | `sourceInterval: TimeRange?` → `HostRange?` |
| `Sources/Project/ProjectSnapshot.swift` | gains `segments: SegmentTable` |
| `Package.swift` | `Project` and `Graph` already depend on `Timeline`; no target changes expected |

**App — `Soredemo/Capture/` (frameworks allowed)**

| File | Responsibility |
| --- | --- |
| `CapturePermissions.swift` | the four permissions, each with a measured status and a named degradation |
| `CaptureSource.swift` | `SCShareableContent`, `SCContentSharingPicker`, and the intrinsic/extrinsic split for windows |
| `CaptureSession.swift` | `SCStream` + `AVAssetWriter`, segment lifecycle, `SCFrameStatusIdle`, reconfiguration callback |
| `InputObserver.swift` | the `CGEvent` tap: full pointer track and clicks |
| `AXObserver.swift` | the bounded walk with per-item intervals and truncation |
| `ObservationWriter.swift` | one JSONL file per segment, append-only |

**App — modified**

| File | Change |
| --- | --- |
| `Soredemo/Support/Minting.swift` | gains `bootEpoch()`, `epochAnchor()`, `hostNow()` |

---

## Task 1: `BootEpoch` and epoch-stamped time

**Files:**
- Create: `Sources/Timeline/BootEpoch.swift`, `Sources/Timeline/HostInstant.swift`, `Sources/Timeline/HostRange.swift`, `Sources/Timeline/EpochAnchor.swift`
- Test: `Tests/TimelineTests/EpochTests.swift`

**Interfaces:**
- Consumes: `Nanoseconds` (`Sources/Timeline/Nanoseconds.swift`) — `init(_ rawValue: Int64)`, `rawValue`, `+`, `-`, `<`.
- Produces: `BootEpoch(id: UUID)`, `HostInstant(epoch:hostTime:)`, `HostRange(epoch:start:duration:)`, `EpochAnchor(epoch:hostTime:wallClockUnixNanos:)`.

Read D2-11 first. This is `GeometryRevision` moved to the time axis, deliberately — the same guard against comparing two values that are not in the same reference frame. Keep the shapes parallel; a reader who knows one should recognise the other.

The epoch is minted in the app from `kern.bootsessionuuid` (Task 5). The package never reads it — no ambient values here.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Timeline

private let epochA = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let epochB = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

@Test func instantsInTheSameEpochCompare() {
    let early = HostInstant(epoch: epochA, hostTime: Nanoseconds(100))
    let late  = HostInstant(epoch: epochA, hostTime: Nanoseconds(200))
    #expect(early < late)
    #expect(!(late < early))
}

@Test func rangeContainsAnInstantOfItsOwnEpoch() {
    let r = HostRange(epoch: epochA, start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(HostInstant(epoch: epochA, hostTime: Nanoseconds(120))))
    #expect(!r.contains(HostInstant(epoch: epochA, hostTime: Nanoseconds(150))))  // half-open
    #expect(r.end == Nanoseconds(150))
}

/// The point of the type. Two boots produce overlapping host times, and without
/// this guard a comparison between them succeeds and is wrong.
@Test func aRangeRejectsAnInstantFromAnotherEpoch() {
    let r = HostRange(epoch: epochA, start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(HostInstant(epoch: epochB, hostTime: Nanoseconds(120))) == false)
    #expect(r.isComparable(with: HostInstant(epoch: epochB, hostTime: Nanoseconds(120))) == false)
}

/// Codable round trip, because these travel to disk in the observation log.
@Test func epochStampedValuesRoundTrip() throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let r = HostRange(epoch: epochA, start: Nanoseconds(7), duration: Nanoseconds(11))
    let back = try JSONDecoder().decode(HostRange.self, from: try enc.encode(r))
    #expect(back == r)
    let a = EpochAnchor(epoch: epochA, hostTime: Nanoseconds(42), wallClockUnixNanos: 1_785_018_171_184_367_000)
    let backA = try JSONDecoder().decode(EpochAnchor.self, from: try enc.encode(a))
    #expect(backA == a)
}

/// Wall clock runs backwards under NTP correction, so it is not an ordering key.
/// Anchors are unordered by construction: there is no Comparable conformance to
/// reach for, which is the enforcement — a comment would not be.
@Test func anchorsCarryTheirEpochAndAreNotOrdered() {
    let a = EpochAnchor(epoch: epochA, hostTime: Nanoseconds(1), wallClockUnixNanos: 100)
    #expect(a.epoch == epochA)
    // There is deliberately no Comparable conformance, so there is nothing to
    // sort by. That is the enforcement — a runtime assertion could not express
    // it, and a comment would not hold. If someone adds Comparable later, this
    // test still passes and the doc comment on EpochAnchor is what stops them;
    // recorded here as a known limit rather than a check that looks like one.
}
```

- [ ] **Step 2: Run and observe the failure**

Run: `swift test --filter TimelineTests`
Expected: FAIL to compile — `cannot find 'BootEpoch' in scope`. Note in the report that this is a **compile-level** failure and therefore not a RED in this project's sense (`AGENTS.md`); the behavioural check is Step 6.

- [ ] **Step 3: Write `BootEpoch.swift`**

```swift
import Foundation

/// Identifies the boot session a host timestamp belongs to.
///
/// `mach_absolute_time()` restarts at boot, and `CMClockGetHostTimeClock()` is
/// that clock, so every timestamp this project stores is meaningless without
/// knowing which boot produced it. Two recordings made in different boots carry
/// overlapping, incomparable values and nothing raises an error — which is
/// precisely where Phase 4's `selective-rerecord` splices footage together.
///
/// This is `GeometryRevision` on the time axis and the parallel is deliberate:
/// both answer "are these two values in the same reference frame", and in both
/// cases the absence of the guard produces a wrong answer rather than an error.
///
/// Minted in the app from `kern.bootsessionuuid` and passed in — never read
/// here, because this module may not touch ambient values.
public struct BootEpoch: Hashable, Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}
```

- [ ] **Step 4: Write `HostInstant.swift`, `HostRange.swift`, `EpochAnchor.swift`**

```swift
// HostInstant.swift
import Foundation

/// A host-clock instant, stamped with the boot session it came from.
public struct HostInstant: Hashable, Codable, Sendable, Comparable {
    public let epoch: BootEpoch
    public let hostTime: Nanoseconds

    public init(epoch: BootEpoch, hostTime: Nanoseconds) {
        self.epoch = epoch
        self.hostTime = hostTime
    }

    /// Ordering is only defined within an epoch. Comparing across one is a
    /// programming error, not a runtime condition to recover from — the same
    /// stance `NormalizedFrame` takes on `geometryRevision`.
    public static func < (lhs: HostInstant, rhs: HostInstant) -> Bool {
        precondition(lhs.epoch == rhs.epoch,
                     "comparing host instants across boot epochs: \(lhs.epoch.id) vs \(rhs.epoch.id)")
        return lhs.hostTime < rhs.hostTime
    }
}
```

```swift
// HostRange.swift
import Foundation

/// A half-open host-clock interval, stamped with its boot epoch.
///
/// Replaces `TimeRange` wherever a value crosses a session boundary — notably
/// `EvidenceRef.sourceInterval`, which is host time by D2-12 Q1.
public struct HostRange: Hashable, Codable, Sendable {
    public let epoch: BootEpoch
    public let start: Nanoseconds
    public let duration: Nanoseconds

    public init(epoch: BootEpoch, start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0, "a negative duration is not a range")
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public var end: Nanoseconds { start + duration }

    /// Whether this range can be reasoned about together with `instant` at all.
    /// Separate from `contains` on purpose: a caller that wants to know *why* a
    /// containment test failed can ask, instead of inferring it from `false`.
    public func isComparable(with instant: HostInstant) -> Bool { instant.epoch == epoch }

    /// `false` for an instant from another epoch. Not a precondition failure,
    /// because a reverse index legitimately asks this of everything it holds —
    /// the same reason `ReverseIndex.dependents(of:)` returns empty rather than
    /// trapping when it is stale.
    public func contains(_ instant: HostInstant) -> Bool {
        guard isComparable(with: instant) else { return false }
        return instant.hostTime >= start && instant.hostTime < end
    }
}
```

```swift
// EpochAnchor.swift
import Foundation

/// Ties one boot epoch to a wall-clock reading, for display and rough placement.
///
/// **The wall clock is not an ordering key.** It runs backwards under NTP
/// correction and can be set by hand. Segment order is recorded explicitly in
/// `SegmentTable`; anything that sorts by `wallClockUnixNanos` is wrong.
///
/// Deliberately not `Comparable`, so there is nothing to reach for. `kern.boottime`
/// is *not* the epoch identity for the same reason — it is computed as now-minus-uptime
/// and moves when the clock is corrected, which would make one boot look like two.
public struct EpochAnchor: Hashable, Codable, Sendable {
    public let epoch: BootEpoch
    public let hostTime: Nanoseconds
    public let wallClockUnixNanos: Int64

    public init(epoch: BootEpoch, hostTime: Nanoseconds, wallClockUnixNanos: Int64) {
        self.epoch = epoch
        self.hostTime = hostTime
        self.wallClockUnixNanos = wallClockUnixNanos
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter TimelineTests`
Expected: PASS, and the Timeline target rises from 18 tests to 23.

- [ ] **Step 6: Mutation checks — the only behavioural RED available here**

Run each, record which tests turn red and how many, and revert:

1. Make `HostRange.contains` ignore the epoch (drop the `guard`). Expect `aRangeRejectsAnInstantFromAnotherEpoch` red. **If nothing else turns red, say so** — a single-angle invariant is a finding about coverage, not a pass.
2. Make `HostRange.contains` inclusive at `end` (`<=`). Expect `rangeContainsAnInstantOfItsOwnEpoch` red.
3. Remove the `precondition` from `HostInstant.<`. Nothing will turn red — Swift Testing has no crash expectation, so this guard is uncoverable in process, exactly as `NormalizedFrame`'s cross-revision guard was in Phase 1. **Record it as a known in-process blind spot rather than reporting a clean mutation.**

- [ ] **Step 7: Commit**

```bash
git add Sources/Timeline/BootEpoch.swift Sources/Timeline/HostInstant.swift \
        Sources/Timeline/HostRange.swift Sources/Timeline/EpochAnchor.swift \
        Tests/TimelineTests/EpochTests.swift
git commit -m "Add BootEpoch: a host timestamp is meaningless without one"
```

---

## Task 2: `EvidenceRef` carries the epoch

**Files:**
- Modify: `Sources/Graph/EvidenceRef.swift`
- Test: `Tests/GraphTests/EvidenceTests.swift` (existing — update), `Tests/GraphTests/DerivedTests.swift` (existing — update if it constructs `EvidenceRef`)

**Interfaces:**
- Consumes: `HostRange` from Task 1.
- Produces: `EvidenceRef(kind:id:contentDigest:sourceInterval: HostRange?)`.

`EvidenceRef.sourceInterval` is host time (D2-12 Q1), and host time without an epoch is meaningless (D2-11). The alternative — letting it inherit the epoch from the observation its `id` points at — makes it a convenience copy that can silently disagree, which is what D-P4 rejected side tables for.

**This type has zero non-test callers today.** Verified by grep across `Sources/`, `Soredemo/` and `scripts/`. That is why it is changed now: in Phase 4, with producers writing citations, the same change is a migration.

- [ ] **Step 1: Confirm the claim before relying on it**

```bash
grep -rn "EvidenceRef(" Sources/ Soredemo/ scripts/ --include="*.swift" | grep -v "Sources/Graph/EvidenceRef.swift"
```
Expected: no output. **If there is output, stop and report** — the cheapness argument for this task is false and the plan needs revisiting.

- [ ] **Step 2: Update the existing tests first, and watch them fail**

In `Tests/GraphTests/`, change every `sourceInterval: TimeRange(...)` to
`sourceInterval: HostRange(epoch: testEpoch, start: ..., duration: ...)`, adding at the top of the file:

```swift
let testEpoch = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
```

Run: `swift test --filter GraphTests`
Expected: FAIL to compile.

- [ ] **Step 3: Change the type**

```swift
public struct EvidenceRef: Hashable, Codable, Sendable {
    public let kind: EvidenceKind
    public let id: UUID
    public let contentDigest: ContentDigest
    /// Host time, stamped with its boot epoch. `TimeRange` was not enough:
    /// `mach_absolute_time()` restarts at boot, so a bare interval from one
    /// session compares silently and wrongly against another (D2-11).
    public let sourceInterval: HostRange?

    public init(kind: EvidenceKind, id: UUID, contentDigest: ContentDigest,
                sourceInterval: HostRange? = nil) {
        self.kind = kind
        self.id = id
        self.contentDigest = contentDigest
        self.sourceInterval = sourceInterval
    }
}
```

- [ ] **Step 4: Run the whole suite, not just GraphTests**

Run: `swift test`
Expected: PASS. `EvidenceRef` is `Codable` and appears inside `Derived.approvalBytes`, so a change to its encoded shape can move a pinned digest. **If any pinned vector in `GraphTests` or `GeometryTests` moves, stop and report** — that is a real signal about approval stability, not a test to update.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graph/EvidenceRef.swift Tests/GraphTests/
git commit -m "EvidenceRef's source interval carries its boot epoch"
```

---

## Task 3: Observation records and the log's schema

**Files:**
- Create: `Sources/Project/ObservationRecord.swift`, `Sources/Project/ObservationLog.swift`
- Test: `Tests/ProjectTests/ObservationLogTests.swift`

**Interfaces:**
- Consumes: `HostInstant`, `BootEpoch` (Task 1); `NormalizedPoint`, `GeometryRevision` (`Sources/Geometry/`); `JSONLReader` (`Sources/Project/JSONLReader.swift`).
- Produces: `ObservationLog.schemaVersion`, `ObservationLog.kind(of:)`, `PointerSample`, `ButtonEvent`, `KeySample`.

The log is JSONL, append-only, one file per segment (D2-12 Q3). Reading a line's *kind* must not require decoding the whole line, for the same reason `SchemaProbe` exists: a v1 build must be able to skip a record type a v2 build wrote, instead of failing to parse the file.

`ObservationLog.schemaVersion` is a **fourth, independent version line**. It does not move with `ProjectSnapshot.currentSchemaVersion` or `CanonicalEncoding.version`. The table in D2-12 Q4 is the one place that says so; do not restate it in a doc comment, point at it.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

private let ep = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let rev = GeometryRevision(id: 0xbcf4_9ed7_dcb4_2be0)
private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: ep, hostTime: Nanoseconds(ns)) }

@Test func aPointerSampleRoundTripsThroughOneJSONLLine() throws {
    let s = PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.25, y: 0.75), revision: rev)
    let line = try ObservationLog.encode(s)
    #expect(!line.contains(UInt8(ascii: "\n")), "a record must occupy exactly one JSONL line")
    let back: PointerSample = try ObservationLog.decode(line)
    #expect(back == s)
}

/// The reason kind() exists: a v1 build meets a record type it does not know.
@Test func kindIsReadableWithoutDecodingTheRecord() throws {
    let future = Data(#"{"kind":"somethingFromAFutureBuild","instant":{},"extra":42}"#.utf8)
    #expect(try ObservationLog.kind(of: future) == "somethingFromAFutureBuild")
}

@Test func decodingAsTheWrongTypeThrowsRatherThanReturningAnEmptyValue() throws {
    let s = PointerSample(instant: at(1), position: NormalizedPoint(x: 0, y: 0), revision: rev)
    let line = try ObservationLog.encode(s)
    #expect(throws: (any Error).self) { let _: KeySample = try ObservationLog.decode(line) }
}

/// Fixture rule: a click at (0,0) with button 0 is the identity of every field
/// here, so the fixture carries a non-identity value for each.
@Test func aButtonEventCarriesItsButtonAndPhase() throws {
    let e = ButtonEvent(instant: at(2_000), position: NormalizedPoint(x: 0.4, y: 0.6),
                        revision: rev, button: .right, phase: .up)
    let back: ButtonEvent = try ObservationLog.decode(try ObservationLog.encode(e))
    #expect(back.button == .right)
    #expect(back.phase == .up)
    #expect(back.position.x == 0.4)
}

@Test func theLogsSchemaVersionIsItsOwnNumber() {
    #expect(ObservationLog.schemaVersion == 1)
    #expect(ProjectSnapshot.currentSchemaVersion == 1)
    // Pinned as two separate literals. This test cannot detect a coincidental
    // derivation of one from the other and its name does not claim to — see
    // the equivalent note in UpgradeTests.
}

@Test func recordsSurviveJSONLReaderIncludingATruncatedTail() throws {
    var data = Data()
    for i in 0..<3 {
        data.append(try ObservationLog.encode(
            PointerSample(instant: at(Int64(i)), position: NormalizedPoint(x: 0.1, y: 0.2), revision: rev)))
        data.append(UInt8(ascii: "\n"))
    }
    data.append(Data(#"{"kind":"pointer","inst"#.utf8))   // a crash mid-write
    let r = JSONLReader.lines(from: data)
    #expect(r.lines.count == 3)
    #expect(r.droppedBytes == 21)
}
```

- [ ] **Step 2: Run and observe the failure**

Run: `swift test --filter ProjectTests`
Expected: FAIL to compile. Compile-level, so not a RED — the behavioural check is Step 5.

- [ ] **Step 3: Write `ObservationRecord.swift`**

```swift
import Foundation
import Geometry
import Timeline

/// A pointer position sample. The whole track is kept, never thinned — how
/// dense is dense enough is a property of `cursor-render`'s spring, which will
/// be tuned, and a thinned track cannot be re-tuned (D2-7).
public struct PointerSample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision) {
        self.kind = "pointer"
        self.instant = instant
        self.position = position
        self.revision = revision
    }
}

public enum PointerButton: String, Codable, Sendable { case left, right, other }
public enum ButtonPhase: String, Codable, Sendable { case down, up }

/// A mouse button transition. The verb half of "click the Save button" — the
/// object half is the AX chain recorded against the same instant (D2-1).
public struct ButtonEvent: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision
    public let button: PointerButton
    public let phase: ButtonPhase

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision,
                button: PointerButton, phase: ButtonPhase) {
        self.kind = "button"
        self.instant = instant
        self.position = position
        self.revision = revision
        self.button = button
        self.phase = phase
    }
}

/// A keystroke, already filtered to approved shortcuts by the observer — the
/// package never sees an unfiltered keystroke, so there is nothing here to
/// redact later.
public struct KeySample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let shortcut: String

    public init(instant: HostInstant, shortcut: String) {
        self.kind = "key"
        self.instant = instant
        self.shortcut = shortcut
    }
}
```

- [ ] **Step 4: Write `ObservationLog.swift`**

```swift
import Foundation

/// The on-disk observation log: JSONL, append-only, one file per master segment.
public enum ObservationLog {
    /// A version line of its own. It does not move with
    /// `ProjectSnapshot.currentSchemaVersion` or `CanonicalEncoding.version`;
    /// the table in the Phase 2 design doc (D2-12 Q4) is where that is stated.
    public static let schemaVersion: Int = 1

    private struct KindOnly: Decodable { let kind: String }

    /// Reads a record's kind **without decoding the record**, so a build that
    /// does not know a record type can skip it rather than fail the file. Same
    /// reasoning as `SchemaProbe.version(of:)` one layer up.
    public static func kind(of line: Data) throws -> String {
        do { return try JSONDecoder().decode(KindOnly.self, from: line).kind }
        catch { throw ProjectFormatError.malformed(String(describing: error)) }
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // measured: without it, five processes produce five byte sequences
        return try e.encode(value)
    }

    public static func decode<T: Decodable>(_ line: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: line)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ProjectTests`
Expected: PASS.

- [ ] **Step 6: Mutation checks**

1. Make `ObservationLog.kind(of:)` decode a full `PointerSample` and read `.kind` off it — expect `kindIsReadableWithoutDecodingTheRecord` red, and **only** that one.
2. Drop `.sortedKeys` from `encode` — expect nothing red, because a round trip is key-order-insensitive. **Report that as a gap rather than a pass**: determinism of the encoded bytes is not covered by any test here, and the one test that would cover it is a cross-process comparison, which is the shape `GeometryRegistry`'s determinism test already uses.
3. Make `decode` return a default-initialised value instead of throwing — expect `decodingAsTheWrongTypeThrowsRatherThanReturningAnEmptyValue` red.

- [ ] **Step 7: Commit**

```bash
git add Sources/Project/ObservationRecord.swift Sources/Project/ObservationLog.swift \
        Tests/ProjectTests/ObservationLogTests.swift
git commit -m "Add observation records and the log's own schema version"
```

---

## Task 4: The segment table and boundary records

**Files:**
- Create: `Sources/Project/SegmentTable.swift`
- Modify: `Sources/Project/ProjectSnapshot.swift`
- Test: `Tests/ProjectTests/SegmentTableTests.swift`, `Tests/ProjectTests/UpgradeTests.swift` (existing — the snapshot gains a field)

**Interfaces:**
- Consumes: `BootEpoch`, `HostRange` (Task 1), `GeometryRevision`.
- Produces: `MasterSegment`, `SegmentTable`, `SegmentBoundary`, and `ProjectSnapshot.segments`.

The master is a sequence, because ScreenCaptureKit has no pause (D2-9). The segment table is what makes that sequence a timeline: it is the only authority on order, and it carries the reason each segment ended.

**A gap is a record, not an absence.** Without a stated reason, "the user paused" and "the recorder died" are the same hole in the timeline — the fourth appearance of the rule that silence is not a value.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

private let ep = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let revA = GeometryRevision(id: 0xAAAA_0000_0000_0001)
private let revB = GeometryRevision(id: 0xBBBB_0000_0000_0002)

private func seg(_ i: Int, _ start: Int64, _ dur: Int64, _ rev: GeometryRevision,
                 _ end: SegmentBoundary) -> MasterSegment {
    MasterSegment(index: i, mediaFilename: "master-\(i).mov",
                  hostRange: HostRange(epoch: ep, start: Nanoseconds(start), duration: Nanoseconds(dur)),
                  revision: rev, endedBy: end)
}

@Test func contentTimeIsTheGaplessConcatenation() throws {
    // Real gaps: 1000..2000, then 5000..6500. Wall time between them is not content time.
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 1_000, revA, .paused),
        seg(1, 5_000, 1_500, revA, .stopped),
    ])
    #expect(t.contentDuration == Nanoseconds(2_500))
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(1_500))) == Nanoseconds(500))
    // The first instant of segment 1 lands immediately after segment 0's content.
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(5_000))) == Nanoseconds(1_000))
}

/// An instant inside the gap belongs to no segment. Returning zero, or the
/// nearest edge, would be a plausible number for a question with no answer.
@Test func anInstantInsideAGapHasNoContentTime() throws {
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .paused),
                                        seg(1, 5_000, 1_500, revA, .stopped)])
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(3_000))) == nil)
}

@Test func anInstantFromAnotherEpochHasNoContentTime() throws {
    let other = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .stopped)])
    #expect(t.contentTime(of: HostInstant(epoch: other, hostTime: Nanoseconds(1_500))) == nil)
}

@Test func aBoundaryCarriesWhyItHappened() throws {
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 1_000, revA, .displayReconfigured(newRevision: revB)),
        seg(1, 3_000, 1_000, revB, .stopped),
    ])
    guard case .displayReconfigured(let newRev) = t.segments[0].endedBy else {
        Issue.record("expected a reconfiguration boundary"); return
    }
    #expect(newRev == revB)
    #expect(t.segments[1].revision == revB)
}

@Test func outOfOrderOrOverlappingSegmentsAreRejected() {
    #expect(throws: (any Error).self) {
        try SegmentTable(segments: [seg(1, 5_000, 100, revA, .stopped), seg(0, 1_000, 100, revA, .paused)])
    }
    #expect(throws: (any Error).self) {   // overlap
        try SegmentTable(segments: [seg(0, 1_000, 2_000, revA, .paused), seg(1, 2_000, 100, revA, .stopped)])
    }
}

@Test func aSnapshotWithSegmentsRoundTrips() throws {
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .stopped)])
    let s = ProjectSnapshot(schemaVersion: 1, geometries: GeometryRegistry(),
                            mediaFilenames: ["master-0.mov"], segments: t)
    let back = try JSONDecoder().decode(ProjectSnapshot.self,
                                        from: try ProjectSnapshot.makeEncoder().encode(s))
    #expect(back == s)
}
```

- [ ] **Step 2: Run and observe the failure**

Run: `swift test --filter ProjectTests`
Expected: FAIL to compile.

- [ ] **Step 3: Write `SegmentTable.swift`**

```swift
import Foundation
import Geometry
import Timeline

/// Why a master segment ended. A gap with no reason is indistinguishable from a
/// crash, which is the rule this project keeps re-deriving: silence is not a value.
public enum SegmentBoundary: Hashable, Codable, Sendable {
    case paused
    case displayReconfigured(newRevision: GeometryRevision)
    case stopped
    case failed(reason: String)
}

public struct MasterSegment: Hashable, Codable, Sendable {
    public let index: Int
    public let mediaFilename: String        // relative, never absolute
    public let hostRange: HostRange
    public let revision: GeometryRevision
    public let endedBy: SegmentBoundary

    public init(index: Int, mediaFilename: String, hostRange: HostRange,
                revision: GeometryRevision, endedBy: SegmentBoundary) {
        self.index = index
        self.mediaFilename = mediaFilename
        self.hostRange = hostRange
        self.revision = revision
        self.endedBy = endedBy
    }
}

public enum SegmentTableError: Error, Equatable {
    case outOfOrder(Int)
    case overlapping(Int)
    case mixedEpochs
}

/// The ordered master segments. **The only authority on order** — wall clock is
/// not, because it runs backwards under NTP correction (see `EpochAnchor`).
public struct SegmentTable: Hashable, Codable, Sendable {
    public let segments: [MasterSegment]

    public init(segments: [MasterSegment]) throws {
        for (i, s) in segments.enumerated() {
            if s.index != i { throw SegmentTableError.outOfOrder(i) }
            if i > 0 {
                let prev = segments[i - 1]
                if prev.hostRange.epoch != s.hostRange.epoch { throw SegmentTableError.mixedEpochs }
                if s.hostRange.start < prev.hostRange.end { throw SegmentTableError.overlapping(i) }
            }
        }
        self.segments = segments
    }

    public var contentDuration: Nanoseconds {
        segments.reduce(Nanoseconds(0)) { $0 + $1.hostRange.duration }
    }

    /// Host time to content time. `nil` when the instant falls in a gap or in
    /// another epoch — both are questions with no answer, and a nearest-edge or
    /// zero would be a plausible number for one (`AGENTS.md`).
    public func contentTime(of instant: HostInstant) -> Nanoseconds? {
        var offset = Nanoseconds(0)
        for s in segments {
            if s.hostRange.contains(instant) {
                return offset + (instant.hostTime - s.hostRange.start)
            }
            offset = offset + s.hostRange.duration
        }
        return nil
    }
}
```

- [ ] **Step 4: Add `segments` to `ProjectSnapshot`**

Add `public var segments: SegmentTable` as a fourth stored property and extend the initialiser.

`SegmentTable.init` throws, so an empty default needs a non-throwing path: add `public static let empty = SegmentTable(unchecked: [])` with a private non-validating initialiser, and a comment saying the empty table is the one case that cannot violate the invariants. Do **not** reach for `try!`. Update `ProjectUpgrade`'s v0 migration to insert an empty table, and add a test that a v1 document written **before** this field still loads.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS. **`UpgradeTests` will need attention** — the round-trip fixture must gain a non-empty segment table, per the fixture rule.

- [ ] **Step 6: Mutation checks**

1. Make `contentTime` return `Nanoseconds(0)` instead of `nil` for a gap — expect `anInstantInsideAGapHasNoContentTime` red.
2. Make `contentTime` ignore the epoch — expect `anInstantFromAnotherEpochHasNoContentTime` red. Trace whether `HostRange.contains`'s own guard is what catches it; if so, say so, because then this test is exercising Task 1's code and not Task 4's.
3. Drop the overlap check from `init` — expect `outOfOrderOrOverlappingSegmentsAreRejected` red.
4. Make `contentDuration` sum the *host* span including gaps — expect `contentTimeIsTheGaplessConcatenation` red. This is the mutation that matters: it is the difference between the exported video's timeline and wall time.

- [ ] **Step 7: Commit**

```bash
git add Sources/Project/SegmentTable.swift Sources/Project/ProjectSnapshot.swift \
        Sources/Project/ProjectUpgrade.swift Tests/ProjectTests/
git commit -m "Add the segment table: the master is a sequence, and gaps are records"
```

---

## Task 4.5: Close decode validation on the two types that have a decode path

**Files:**
- Modify: `Sources/Geometry/DisplayGeometry.swift`, `Sources/Timeline/HostRange.swift`
- Test: `Tests/GeometryTests/DigestTests.swift`, `Tests/TimelineTests/EpochTests.swift`

Read D2-14 first, and note that its grouping was corrected before this task was written.

**Two types, not seven.** Traced structurally from `ProjectSnapshot` through stored properties and
enum payloads: `DisplayGeometry` is reachable via `GeometryRegistry`, and `HostRange` via
`SegmentTable` → `MasterSegment`. `NormalizedPoint`, `NormalizedSize`, `NormalizedFrame`,
`PixelRect`, `PointRect`, `Authorship`, `HostInstant` and `TimeRange` are **not reachable from a
document today** — `Derived` is not in `ProjectSnapshot`, and `ROADMAP.md`'s `derivation-graph` row
says so: *"no graph is persisted or read."*

Those eight stay in rule 8's exemption list (Task 11.5) until something decodes them. Closing them
now would be designing error handling with no caller, which is what left `project-format` at ◐.

**The grouping criterion is the type's invariant, not the reader.** A type's `init(from:)` always
throws; whether that becomes a fatal document error or a discarded record counted in `droppedBytes`
is the **reader's** policy, not the type's:

```
manifest reader → let it propagate → the document does not open
log reader      → catch, droppedBytes += 1, continue
```

So what waits for Task 11 is the log reader's catch policy, which does not exist yet — not the
types. And what makes a type ready *now* is that its invariant is settled. `DisplayGeometry`'s and
`HostRange`'s are: finite positive scale, non-negative duration, both already stated as
`precondition`s and both already verified out of process.

**`throw`, never `precondition`.** A `precondition` on decoded input is the wrong instrument whether
or not it runs — it turns a corrupt document into a crash instead of an error.

- [ ] **Step 1: `HostRange` first**, because its invariant is one line. Explicit `init(from:)` that
      decodes, checks `duration >= 0`, and throws `DecodingError.dataCorrupted`. Test with a
      hand-built JSON literal carrying a negative duration.
- [ ] **Step 2: Check the encoded shape did not change.** `SegmentTable`'s fix changed its wire form
      from a keyed container to a bare array, which was harmless only because nothing depended on
      it. `HostRange` **is** inside `ProjectSnapshot` via `SegmentTable`, and it is inside
      `EvidenceRef`'s canonical encoding. Round-trip a document fixture before and after, and
      re-run `DerivedTests`' pinned vectors. **If a pinned vector moves, stop and report** — the
      canonical encoding is hand-written and separate from `Codable`, so it should not move, and if
      it does that is a finding about the two encodings having drifted together.
- [ ] **Step 3: `DisplayGeometry`**, same shape. Its invariant is a finite `scale > 0`.
- [ ] **Step 4: Verify by reversion, not by inspection.** For each, revert the validation while
      keeping the wire shape identical, and confirm the test reddens for the right reason. Task 4's
      first attempt at this passed under a fuller revert for an unrelated reason, and that was found
      by running it rather than reading it.
- [ ] **Step 5: Commit.**

---

## Task 5: `Minting` gains the epoch and the host clock

**Files:**
- Modify: `Soredemo/Support/Minting.swift`
- Modify: `scripts/cross-boundary-digest-probe.swift` (add the epoch checks)

**Interfaces:**
- Produces: `Minting.bootEpoch() -> BootEpoch`, `Minting.hostNow() -> Nanoseconds`, `Minting.continuousNow() -> Nanoseconds`, `Minting.epochAnchor() -> EpochAnchor`.

`Minting` is the app's licence to do what the package cannot. Everything here is a pure mapping from an ambient reading to a package type; nothing that could live in the package belongs here.

**This is the file `Tests/AppSourceTests` allow-lists.** After this task it must still be the only file under `Soredemo/` naming `UUID(`, `Date(`, `SHA256` or `.random(`.

- [ ] **Step 1: Add the epoch and clock functions**

```swift
import Darwin
import Timeline

extension Minting {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    /// The current boot session, from `kern.bootsessionuuid`.
    ///
    /// **Not `kern.boottime`.** That is computed as now-minus-uptime and moves
    /// when the system clock is corrected by NTP or by hand, so two reads within
    /// one boot can disagree and a single boot would look like two (D2-11).
    /// Verified on this machine: `bootsessionuuid` is stable across reads.
    public static func bootEpoch() -> BootEpoch {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        precondition(size > 0, "kern.bootsessionuuid is unavailable; there is no honest fallback")
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0)
        let s = String(cString: buf)
        guard let id = UUID(uuidString: s) else {
            preconditionFailure("kern.bootsessionuuid is not a UUID: \(s)")
        }
        return BootEpoch(id: id)
    }

    /// The host clock, in nanoseconds — the same base as
    /// `CMClockGetHostTimeClock()` and `CGEventTimestamp`, measured (F2-1).
    public static func hostNow() -> Nanoseconds {
        Nanoseconds(Int64(mach_absolute_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)))
    }

    /// For display and rough placement only. The wall clock is **not** an
    /// ordering key — `SegmentTable` is.
    public static func epochAnchor() -> EpochAnchor {
        EpochAnchor(epoch: bootEpoch(), hostTime: hostNow(),
                    wallClockUnixNanos: Int64(Date().timeIntervalSince1970 * 1e9))
    }

    /// How long the system slept between two `continuousNow()` / `hostNow()` pairs.
    /// `mach_absolute_time` stops during sleep and `mach_continuous_time` does not,
    /// so the divergence *is* the sleep (D2-4). Measured on this machine at 59.68 h
    /// against 172.57 h of uptime — 35%, not a corner case.
    public static func continuousNow() -> Nanoseconds {
        Nanoseconds(Int64(mach_continuous_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)))
    }
}
```

- [ ] **Step 2: Extend the probe**

Add to `scripts/cross-boundary-digest-probe.swift`:

```swift
check("bootEpoch is stable across reads",
      Minting.bootEpoch() == Minting.bootEpoch())
check("hostNow advances",
      { let a = Minting.hostNow(); usleep(1000); return Minting.hostNow() > a }())
check("continuousNow is at or ahead of hostNow",
      Minting.continuousNow().rawValue >= Minting.hostNow().rawValue)
```

The third is the sleep divergence: it can only be `>=`, never `<`, and a run on a machine that has slept shows a large gap.

- [ ] **Step 3: Run the probe and record the numbers**

Run: `scripts/run-cross-boundary-probe.sh`
Expected: all checks pass, and the probe's own count line rises by three. Quote the observed `continuousNow - hostNow` in the report.

- [ ] **Step 4: Confirm the allow-list still holds**

Run: `swift test --filter AppSourceTests`
Expected: PASS. If it fails, an ambient value has leaked outside `Minting.swift` and the row's claim is false.

- [ ] **Step 5: Commit**

```bash
git add Soredemo/Support/Minting.swift scripts/cross-boundary-digest-probe.swift
git commit -m "Mint the boot epoch from kern.bootsessionuuid, not kern.boottime"
```

---

## Task 5.5: Close two live gaps in the determinism lists

**Files:**
- Modify: `Tests/DeterminismTests/SymbolDeterminismTests.swift`, `Tests/AppSourceTests/AppSourceAllowListTests.swift`
- Test: the same two files

Both gaps were found by a re-review asking not "was the fix applied" but "what else is the list
missing" — the enumeration-goes-stale shape, twice.

**Gap 1 — `SecRandomCopyBytes` is banned by neither list.** It compiles and links from Swift and is
exactly `Minting`-shaped ambient randomness, the same category as `arc4random`. Verified by
compiling: the undefined symbols are `_SecRandomCopyBytes` and `_kSecRandomDefault`, both plain C,
no mangling.

**Gap 2 — the two lists are no longer a clean subset of each other.** Task 5 added
`mach_continuous_time` to the app-side list and not to the package-side symbol table. `sysctlbyname`
is legitimately app-only — no package module reads `sysctl` — but `mach_continuous_time` is not. If
`Timeline` ever called it, architecture rule 3's **purpose** (no library module references an
ambient clock) would be violated while its **mechanism** stayed silent. Its symbol is
`_mach_continuous_time`.

**The constraint that makes this more than three string literals:** `SymbolDeterminismTests` asserts
one call site per `bannedSymbols` entry and nothing else, so each new entry needs a corresponding
line in the construct fixture. That invariant is what stops the table becoming a list of names
nobody has checked.

- [ ] **Step 1: Derive the symbols rather than copying them from this brief.** `nm -u` on a scratch
      module that calls each one. The three above are what I measured; confirm them, and say so if
      they differ.
- [ ] **Step 2: Add the fixture call sites and the table entries together**, so the one-to-one
      assertion never goes red for a bookkeeping reason.
- [ ] **Step 3: Add `SecRandomCopyBytes` to the app-side banned list** with a comment saying why
      it is a distinct source and not a spelling of `arc4random`.
- [ ] **Step 4: Verify each new entry actually catches something.** Add a call to each in a scratch
      module inside a package library target, confirm `swift test --filter DeterminismTests` reddens,
      and revert. A banned symbol that no probe has ever seen fire is a name in a list.
- [ ] **Step 5: Say what is still missing.** The re-review checked seven candidates and found one
      real gap. Do the same sweep once more and record the result — including the candidates that
      turned out to be unreachable from Swift, like `getentropy`, so nobody re-checks them.
- [ ] **Step 6: Commit.**

---

## Task 6: `capture-permissions` — four permissions, four named degradations

**Files:**
- Create: `Soredemo/Capture/CapturePermissions.swift`
- Modify: `scripts/cross-boundary-digest-probe.swift`

**Interfaces:**
- Produces: `CapturePermission` (enum of the four), `CapturePermissions.status(of:)`, `CapturePermissions.degradation(for:)`, `CapturePermissions.blockingFailures()`.

The row's completion criterion is that **each permission degrades precisely**. Not that the app survives — that each absence has a stated, distinct consequence, and that the consequence is what actually happens.

| Permission | Absent means | Degradation |
| --- | --- | --- |
| Screen Recording | nothing can be recorded | **blocking** — refuse to start, say which permission and how to grant it |
| Microphone | one audio track instead of two | record, mark the segment as having no microphone track |
| Input Monitoring | no pointer track, no clicks | record, **mark the recording as observation-blind** |
| Accessibility | clicks without element identity | record, mark observations as having no AX chain |

The two middle rows are the dangerous pair: capture succeeds and produces a project that looks normal and derives nothing. That must be a recorded state, not something inferred later from an empty log.

**Known, measured behaviours that shape this (F2-4 and the TCC section of the carried-forward doc):**
- **Screen Recording does not apply to a running process.** Granting it requires a relaunch, and the app only appears in the list after attempting a capture once.
- **Screen Recording re-confirms monthly**, keyed on the executable's path. Not disableable.
- **A revoked Screen Recording grant produces black frames, not an error.** So a status check at start is not sufficient; `capture-stream` must detect this during recording (Task 8).
- **Accessibility persists until revoked or the bundle identifier changes.**

- [ ] **Step 1: Write the type**

```swift
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hid          // IOHIDCheckAccess

public enum CapturePermission: String, CaseIterable, Sendable {
    case screenRecording, microphone, inputMonitoring, accessibility
}

public enum PermissionStatus: String, Sendable { case granted, denied, undetermined }

/// What the product still does without a given permission. Every case is a
/// state the observation log records, so that a project produced without a
/// permission is distinguishable from one produced with it — rather than being
/// inferred later from an empty log.
public enum Degradation: String, Codable, Sendable {
    case blocksRecording
    case noMicrophoneTrack
    case observationBlind
    case noElementIdentity
}

public enum CapturePermissions {
    public static func status(of p: CapturePermission) -> PermissionStatus {
        switch p {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .undetermined
            default: return .denied
            }
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypGranted
                ? .granted : .denied
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        }
    }

    public static func degradation(for p: CapturePermission) -> Degradation {
        switch p {
        case .screenRecording: .blocksRecording
        case .microphone:      .noMicrophoneTrack
        case .inputMonitoring: .observationBlind
        case .accessibility:   .noElementIdentity
        }
    }

    /// Permissions whose absence stops a recording rather than degrading it.
    public static func blockingFailures() -> [CapturePermission] {
        CapturePermission.allCases.filter {
            degradation(for: $0) == .blocksRecording && status(of: $0) != .granted
        }
    }
}
```

- [ ] **Step 2: A dump the check can be repeated from**

Before any verification, build the thing that stops this green light rotting. The app needs one
place — a debug menu item, a command-line flag, a line printed at launch — that **dumps all four
statuses as this code understands them**, with the OS version beside them.

Without it, every future check has to re-derive what to look at, where, and what to expect, and that
cost is high enough that nobody pays it twice. With it, the check is: run it, open System Settings,
compare. Thirty seconds.

This matters more than the four values themselves. TCC's behaviour changes between macOS releases —
it already changed inside a point release, 26.0.1 to 26.1 — so permission detection can go quietly
wrong while the row's claim that each permission degrades precisely goes unre-examined.

- [ ] **Step 3: Verify BLIND, and in this order**

The one measurement in Phase 2 that cannot be automated, and confirmation bias is free to remove
here: a person told what the program expects will find it in the Settings pane.

So: **the human reports the four switch states first, from System Settings, without seeing any
program output.** Only then is the dump run and compared. Not the other way round.

Record disagreements as findings. A status function that disagrees with the pane is the bug this
step exists for, and it cannot be seen once the answer has been supplied.

- [ ] **Step 4: The state space is bigger than on and off**

Four permissions × two states is not the space. TCC has at least:

| State | Distinguishable? |
| --- | --- |
| never asked (`notDetermined`) | must be — it is the only state where prompting is appropriate |
| authorised | |
| denied | |
| restricted by MDM or parental controls | **different from denied** — the user cannot fix it themselves |
| **granted while the process is already running** | **the dangerous one** |

The last is measured, not hypothetical: Spike B hit it. **The switch is on and the running process
still fails; only a relaunch takes effect.** That is where "degrades precisely" is most likely to be
wrong — the app reports having permission and can do nothing, so the interface says everything is
fine while nothing happens.

It can only be produced in front of a real machine: start recording, turn the switch on mid-run, and
see what the code says. **Do this experiment last**, because it changes state and invalidates the
comparison in Step 3.

- [ ] **Step 5: Do not touch any switch** except the deliberate experiment above.

- [ ] **Step 6: Commit**

```bash
git add Soredemo/Capture/CapturePermissions.swift scripts/cross-boundary-digest-probe.swift
git commit -m "Name what each permission's absence costs, and record it as a state"
```

---

## Task 7: `capture-source` — picking what to record, and what its geometry is

**Files:**
- Create: `Soredemo/Capture/CaptureSource.swift`
- Modify: `scripts/cross-boundary-digest-probe.swift`

**Interfaces:**
- Consumes: `DisplayGeometry`, `GeometryRevision` (`Sources/Geometry/`); `CGGeometryBridge` (`Soredemo/Capture/`).
- Produces: `CaptureSource` (enum: `.display`, `.window`), `CaptureSource.geometry() -> DisplayGeometry`, `CaptureSource.filter() -> SCContentFilter`.

Use **`SCContentSharingPicker`**, not a custom picker. The ROADMAP says so and the reason is that the system picker carries permission affordances and Presenter Overlay for free.

**Window capture's geometry is the D2-13 split**, and getting it wrong mints a revision on every drag:

| | Intrinsic — in the digest, defines the revision | Extrinsic — never digested, applied at the boundary |
| --- | --- | --- |
| Display | `displayUUID`, pixel size, `scale` | the global origin, via `DisplayArrangement` |
| Window | source identity + **output buffer size** + `scale` | the window's current screen frame |

The output buffer's size is fixed for the whole recording — it must be, because a QuickTime track cannot change dimensions mid-track. So normalisation is against the *captured image*, not the window's frame on screen.

- [ ] **Step 1: Write the type**

```swift
import ScreenCaptureKit
import Geometry

public enum CaptureSource: Sendable {
    case display(SCDisplay)
    /// `bufferSize` is fixed at start and never changes — see above.
    case window(SCWindow, bufferSize: (width: Int, height: Int))

    /// The intrinsic geometry, which is what the revision is a digest of.
    ///
    /// For a window, the frame on screen is deliberately absent: a moving
    /// window is a moving display arrangement, and D-P2 already ruled that a
    /// changing arrangement must not enter the digest, because it would
    /// invalidate footage on every change (D2-13).
    public func geometry(scale: Double, displayUUID: UUID) -> DisplayGeometry {
        switch self {
        case .display(let d):
            return DisplayGeometry(displayUUID: displayUUID,
                                   pixelWidth: d.width * Int(scale),
                                   pixelHeight: d.height * Int(scale),
                                   scale: scale)
        case .window(_, let size):
            return DisplayGeometry(displayUUID: displayUUID,
                                   pixelWidth: size.width, pixelHeight: size.height, scale: scale)
        }
    }
}
```

`displayUUID` for a window is the identity of the window's source, obtained in the app and passed in — see the open item below.

- [ ] **Step 2: Wire `SCContentSharingPicker`**

Present the system picker, take its `SCContentFilter`, and derive a `CaptureSource` from `filter.style`. Do not construct a filter by hand except in the probe.

- [ ] **Step 3: ~~Measure the resize question~~ — settled from the header, see D2-13a**

No recording needed. `scalesToFit` and `preservesAspectRatio` are documented flags with documented
defaults, and the decision is a display-sized buffer with `scalesToFit = false`. The window's rect
within the surface arrives per frame as `SCStreamFrameInfoContentRect`, and
`SCStreamFrameInfoContentScale` makes "this frame was not resampled" checkable rather than assumed.

Left here rather than deleted, because the reason it was scheduled — and why it did not need to be —
is the point: two of this phase's questions were answered by reading a header, and one of them had a
four-run recording spent on it first.

- [ ] **Step 3b (superseded, do not run): Measure the resize question**

Record a window with the spike from `spikes/2026-08-02-capture-master/`, change the window's **aspect ratio** mid-recording, and inspect whether content shifts within the frame:

- **scale-to-fill** → `(0.5, 0.5)` is still the window's centre; normalised coordinates stay comparable; no new revision needed
- **letterbox** → the bars move when the aspect ratio changes, so `(0.5, 0.5)` points at something else, and a resize must mint a new revision

Record which one it is, with the evidence. This determines whether `SegmentBoundary` needs a `windowResized` case.

- [ ] **Step 4: Record the open item rather than inventing an answer**

A window has no stable identity: `SCWindow.windowID` does not survive a restart of the target application, and bundle identifier plus title is no better. D-P2's second property — *two sessions that shared a display agree without coordination* — is one window capture cannot currently provide.

Write into `ROADMAP.md`'s `capture-source` row that **a window-capture revision is session-scoped**, as an explicit limitation. Do not attempt to solve it here: it is only load-bearing for Phase 4's `selective-rerecord`, and that row's actual requirement has not been read yet.

- [ ] **Step 5: Commit**

```bash
git add Soredemo/Capture/CaptureSource.swift scripts/cross-boundary-digest-probe.swift ROADMAP.md
git commit -m "capture-source: a window's frame is extrinsic, like the display arrangement"
```

---

## Task 8: `capture-stream` and `audio-tracks` — the master, written by `AVAssetWriter`

**Files:**
- Create: `Soredemo/Capture/CaptureSession.swift`
- Modify: `scripts/cross-boundary-digest-probe.swift`

**Interfaces:**
- Consumes: `CaptureSource` (Task 7), `MasterSegment`, `SegmentBoundary`, `SegmentTable` (Task 4), `Minting.hostNow()` (Task 5), `ProjectPackageIO.writeSidecar(_:named:into:)` (`Sources/Project/`).
- Produces: `CaptureSession.start()`, `.pause()`, `.resume()`, `.stop() -> SegmentTable`.

These two rows are one task because they are one object: the writer that takes three streams and produces a segment. Splitting them would mean a reviewer approving a video writer that cannot yet be tested against its audio requirement.

**`SCRecordingOutput` is not usable.** Measured (F2-4): at our floor it mixes the microphone into the system-audio track — one track carrying both a 440 Hz system tone and a 1 kHz microphone tone, with the microphone verified live by instrument before recording. `mixesAudioWithMicrophone` is macOS 27 only. `audio-tracks` requires independent tracks, so the master is written by `AVAssetWriter` taking `SCStreamOutputTypeScreen`, `.audio` and `.microphone` as three separate inputs.

**Four measured behaviours this must handle:**

1. **`SCFrameStatusIdle` is 42–84% of callbacks** (F2-4), tracking how much the screen is changing. A callback is not a frame. Check `SCStreamFrameInfo.status` and append only `.complete`.
2. **`minimumFrameInterval` is a floor, not a cadence.** Observed 9–37 fps against a requested 60. Take presentation times from the sample buffers; never assume a rate.
3. **PTS → callback has an unstable tail.** p50 ~2 ms, p90 ~9 ms, and one run at **175 ms** against 29 ms in three others. Size buffers for the tail, not the median.
4. **A revoked Screen Recording grant produces black frames, not an error.** A status check at start does not cover this.

- [ ] **Step 0: `showsCursor = false`, and know why**

The master is unprocessed evidence (D2-8), and the cursor is a derived value drawn at composite time from the pointer track. Burning it into the master would put a producer's output into the evidence layer — the same rule as D2-1, and the single ROADMAP rule that the whole principle was generalised from.

- [ ] **Step 1: Segment lifecycle**

`start()` opens segment 0. `pause()` finalises the current segment with `.paused` and stops the stream; `resume()` opens the next. `stop()` finalises with `.stopped` and returns the `SegmentTable`. Each segment gets its own `AVAssetWriter` and its own media filename, written through `ProjectPackageIO.writeSidecar` so the write-once refusal applies.

There is no pause in ScreenCaptureKit — `pause` and `resume` appear zero times in its headers — which is why the master is a sequence and why this shape is forced rather than chosen (D2-9).

- [ ] **Step 2: Display reconfiguration as an observed event**

```swift
CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
    guard !flags.contains(.beginConfigurationFlag) else { return }
    // Close the current segment deliberately, with the reason and the new
    // revision, and open the next. Registered so that reconfiguration is an
    // OBSERVED event: unregistered, it is inferred from frames stopping or
    // sizes not matching, after the file is already wrong (D2-10).
}, nil)
```

This is also **what mints a new `geometryRevision`** — Phase 1 built the type and made cross-revision comparison a precondition failure without ever saying which event produces a new one.

- [ ] **Step 3: Detect black frames**

A revoked grant yields frames, not an error. Sample the luminance of a small fixed grid on every Nth complete frame; if every sample is at floor for more than a threshold of consecutive frames, finalise the segment with `.failed(reason: "frames are uniformly black; screen recording may have been revoked")`.

**The threshold is a placeholder and must be labelled as one.** A genuinely black screen exists — a screensaver, a full-screen dark video — and D4 applies: this is fitted to measured recordings, not chosen. Until then, log the detection rather than aborting on it.

- [ ] **Step 4: Verify with the spike, not by inspection**

Extend `spikes/2026-08-02-capture-master/main.swift` to drive `CaptureSession` instead of `SCRecordingOutput`, and assert on the output:

```
check("two audio tracks", audioTracks.count == 2)
check("system tone in track 0 only", has440(track0) && !has440(track1))
check("microphone tone in track 1 only", has1k(track1) && !has1k(track0))
check("segment count matches pause count", table.segments.count == 3)
check("no gap is unexplained", table.segments.allSatisfy { $0.endedBy != nil })
```

The tone check is the whole point and it needs both tones playing. **The spike measures that precondition before recording** — microphone authorisation via `AVCaptureDevice.authorizationStatus(for:)` and eight seconds of live mic RMS, aborting rather than producing a result that cannot be read. Three earlier runs were wasted on preconditions that were requested rather than measured; do not remove those guards.

- [ ] **Step 5: Commit**

```bash
git add Soredemo/Capture/CaptureSession.swift spikes/2026-08-02-capture-master/main.swift
git commit -m "Write the master with AVAssetWriter: SCRecordingOutput mixes the microphone in"
```

---

## Task 9: `input-observation` — the tap, and the first real caller of the conversion boundary

**Files:**
- Create: `Soredemo/Capture/InputObserver.swift`, `Soredemo/Capture/CaptureError.swift`
- Modify: `Soredemo/Capture/CGGeometryBridge.swift` if a conversion is missing
- Modify: `scripts/cross-boundary-digest-probe.swift`

**Interfaces:**
- Consumes: `NormalizationContext`, `PointRect`, `NormalizedPoint` (`Sources/Geometry/`); `CGGeometryBridge`; `PointerSample`, `ButtonEvent`, `KeySample` (Task 3); `Minting.hostNow()`.
- Produces: `InputObserver.start(onSample:)`, `.stop()`.

**This row carries a claim moved off `geometry-types`.** `NormalizationContext` and `CGGeometryBridge` both have **zero callers** today; this is where "all conversion in one place" stops being a pure function nobody calls. If the conversion ends up happening anywhere else in this task, the claim is false again and the row should say so instead.

**`CGEventTimestamp` is in nanoseconds**, measured (F2-1): the ratio to `mach_absolute_time()` was 41.6667 = 125/3 across three samples, on Apple Silicon where the timebase is not 1/1. Guessing this wrong places every click at 1/24 of its true offset with no error and no crash. Do not convert; it is already the same base as `hostNow()`.

**Keep the whole pointer track.** ~24 bytes a sample, 120 Hz for five minutes is about 1 MB against several GB of video. Thinning bakes "dense enough for this spring" into the evidence, and `camera-motion`'s settling behaviour is a calibration that will be tuned (D2-7).

**Keyboard is filtered to approved shortcuts, and secure input suppresses capture entirely.** The package must never receive an unfiltered keystroke — there is then nothing to redact later.

- [ ] **Step 1: Create the tap**

```swift
let mask = (1 << CGEventType.mouseMoved.rawValue)
         | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
         | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
         | (1 << CGEventType.leftMouseDragged.rawValue)
         | (1 << CGEventType.keyDown.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                  callback: handler, userInfo: ctx)
else {
    // Not "no events happened". Input Monitoring is not granted, and the
    // recording is observation-blind — a state the log records (Task 6).
    throw CaptureError.inputMonitoringUnavailable
}
```

`.listenOnly` — the tap never modifies or drops an event.

- [ ] **Step 2: Convert exactly once, through the bridge**

`CGEventGetLocation` returns points in the global, top-left-origin space. `NormalizationContext` converts to `NormalizedPoint` in the bottom-left-origin unit space, and the sample carries the `GeometryRevision` it was normalised against. The `CGPoint` must not survive past `CGGeometryBridge` — `Tests/AppSourceTests` fails the build if it appears elsewhere under `Soredemo/`.

- [ ] **Step 3: Handle secure input**

`IsSecureEventInputEnabled()` is true while a password field has focus. While it is, **emit nothing at all** — not a redacted sample, not a placeholder. And record a `secureInput` interval in the log, because an interval with no samples is otherwise indistinguishable from an interval where nothing happened, which is the rule this phase keeps re-deriving.

- [ ] **Step 4: Verify with the probe**

```
check("pointer samples arrive at display rate", samples.count > 60 after 1s of movement)
check("a click produces down and up", ...)
check("no CGPoint escapes the bridge", <the AppSourceTests run>)
check("secure input produces an interval, not silence", ...)
check("normalised coordinates are in [0,1]", samples.allSatisfy { 0...1 ~= $0.position.x })
```

The last one has a trap worth stating: a sample on a **second display** will fail it, because normalisation is per-display and the global point must be routed first by `DisplayArrangement`. If it fails, that is the routing bug Phase 1's Task 10.5 was written for, not a bad assertion.

- [ ] **Step 5: Commit**

```bash
git add Soredemo/Capture/InputObserver.swift scripts/cross-boundary-digest-probe.swift
git commit -m "input-observation: the tap, and the conversion boundary's first caller"
```

---

## Task 10: `ax-observation` — the bounded walk that records and does not judge

**Files:**
- Create: `Soredemo/Capture/AXObserver.swift`, `Sources/Project/AXChainRecord.swift`
- Test: `Tests/ProjectTests/AXChainRecordTests.swift`

**Interfaces:**
- Consumes: `HostInstant`, `HostRange` (Task 1); `ObservationLog` (Task 3).
- Produces: `AXChainRecord`, `AXElementRecord`, `ChainTruncation`; `AXObserver.chain(at:)`.

Read D2-1, D2-2, D2-2a and D2-3 first. The whole chain is recorded and **no element is chosen** — the preference for well-bounded descendants is a gate with thresholds, and `ARCHITECTURE.md` D4 requires thresholds to be fitted to measured distributions that do not exist yet. Choosing at capture time would make `producerVersion` meaningless for that decision, because the alternatives would be gone.

**Measured, from Spike A (F2-2, 118 clicks):**

```
hit-test interval    p50 1.05 ms   p90 21.25 ms   max 125.47 ms
whole walk           p50 5.10 ms   p90 32.22 ms   max 173.53 ms
AX calls per click   p50 41        p90 106        max 131
chain depth          p50 3         p90 12         max 20
chain-inconsistency  p50 0.2       p90 1.8        max 6.6   60 fps frames
```

- [ ] **Step 1: The record types, in the package**

```swift
/// One element in an AX observation. Each carries its **own** interval, not one
/// for the chain: the levels are read at different moments, and at p95 the UI
/// has three frames to move between the top and bottom of what is stored as a
/// single observation (F2-2). The interval's width is the uncertainty (D2-2a).
public struct AXElementRecord: Hashable, Codable, Sendable {
    public let role: String?
    public let title: String?
    public let frame: NormalizedFrame?
    public let readInterval: HostRange
}

/// Why the walk stopped. "There were no more ancestors" and "I stopped asking"
/// are otherwise the same bytes on disk.
public enum ChainTruncation: String, Codable, Sendable {
    case reachedRoot, depthCapReached, budgetExceeded, hitTestReturnedNothing
}

public struct AXChainRecord: Hashable, Codable, Sendable {
    public let kind: String            // "axChain"
    public let instant: HostInstant    // the click this is the object half of
    public let hitTestInterval: HostRange
    public let hit: AXElementRecord?
    public let ancestors: [AXElementRecord]   // innermost first
    public let children: [AXElementRecord]    // one level, D2-3
    public let truncation: ChainTruncation
    public let axCalls: Int
}
```

- [ ] **Step 2: Test the record types**

Test that `truncation` survives a round trip, that an empty `ancestors` with `.depthCapReached` decodes differently from an empty one with `.reachedRoot`, and that `children` being empty is distinguishable from absent. Those three are the whole point of the type.

- [ ] **Step 3: The walk, in the app**

Bounded by **depth 30** and a wall-clock budget. Depth 30 is fixed now and not a placeholder: 25 covered every sample in F2-2 and the walks that hit a cap of 20 completed in 4–13 ms, because deep means web content — cheap per level, simply tall (D2-5).

**The budget is the one genuine placeholder.** It has no knee: 20 ms truncates 15%, 35 ms 9%, 50 ms 7%, and the tail never reaches zero. Start at **35 ms**, label it as awaiting D4 calibration everywhere it appears, and expect it to move on a slower machine.

Frame costs **two** IPC round trips, not one: `kAXFrameAttribute` is not exposed to Swift, so position and size are read separately.

- [ ] **Step 4: Truncation degrades gracefully (F2-3) — record why, so nobody raises the budget**

The hit-test returns the deepest element and the walk goes **up**, so truncation drops the **outermost** ancestors — the ones least likely to be the camera's target. Verified in Spike A: all 107 complete walks topped out at `AXApplication`, while the 11 truncated ones stopped at `AXGroup`, `AXWebArea` or `AXWindow`. So 7% truncated is not 7% of clicks lost.

Put that in a comment beside the budget constant. Someone will otherwise read 7% and raise it, and the tail does not converge.

- [ ] **Step 5: Verify with Spike A, re-run against the real observer**

Point `spikes/2026-08-02-pairing-latency/main.swift` at `AXObserver` instead of its own inline walk, re-run on the three target classes — native AppKit, Electron, and something known to be slow — **clicking during animations**, and confirm the distributions match F2-2 within an order of magnitude. A large divergence means the observer is doing more work than the spike measured.

- [ ] **Step 6: Commit**

```bash
git add Sources/Project/AXChainRecord.swift Soredemo/Capture/AXObserver.swift \
        Tests/ProjectTests/AXChainRecordTests.swift spikes/2026-08-02-pairing-latency/main.swift
git commit -m "ax-observation: record the whole chain, choose nothing"
```

---

## Task 11: `observation-log` — one file per segment, written as it happens

**Files:**
- Create: `Soredemo/Capture/ObservationWriter.swift`
- Modify: `Soredemo/UI/ProjectDocument.swift`
- Modify: `scripts/cross-boundary-digest-probe.swift`

**Interfaces:**
- Consumes: everything from Tasks 3, 4, 9, 10; `ProjectPackageIO` (`Sources/Project/`).
- Produces: `ObservationWriter.open(segment:in:)`, `.append(_:)`, `.close(endedBy:)`.

One JSONL file per segment (D2-12 Q3), append-only, under `observations/`. A crash then damages only the current segment's log, and `JSONLReader`'s truncated-tail rule has exactly one file it can apply to.

**An observation that straddles a boundary belongs to the segment its click happened in** — the click is the anchor and the chain is its attribute. Because each chain item carries its own timestamp, a chain extending past the boundary is *detectable*, which is one more real input for `framing-gates`' `observation stale`.

**This task also gives Phase 1's five dead symbols their first caller.** `ProjectDocument.addMedia`, `.unreferencedMedia`, `.compactMedia`, `MediaError` and `Minting.now()` have zero callers today; `project-format` sits at ◐ for exactly that. Route the master segments through `addMedia` rather than calling `ProjectPackageIO` directly, and that row can move.

- [ ] **Step 1: Write the writer**

Open a `FileHandle` per segment, append one JSON object plus `\n` per record, `close()` on boundary. Do not buffer records in memory across a segment: the point of append-only is that a crash costs the tail, not the segment.

- [ ] **Step 2: Route media through the document, not around it**

```swift
// In CaptureSession, on finalising a segment:
try document.addMedia(segmentURL, named: "master-\(index).mov")
```

Then confirm the row's claim by grep:

```bash
grep -rn "addMedia\|unreferencedMedia\|compactMedia\|Minting.now" Soredemo/ scripts/ --include="*.swift" \
  | grep -v "ProjectDocument.swift:\|Minting.swift:"
```
Expected: at least one hit each for `addMedia` and `Minting.now`. **If `unreferencedMedia` and `compactMedia` still have none, say so** — they stay uncalled and `project-format` stays ◐ for a smaller reason than before.

- [ ] **Step 3: End-to-end through the probe**

Record 20 seconds with two pauses, clicking throughout, then assert:

```
check("one log per segment", logURLs.count == table.segments.count)
check("every record's instant lies inside its segment's host range", ...)
check("a click and its AX chain share an instant", ...)
check("the log survives a truncated tail", <append a partial line, re-read>)
check("segment boundaries carry a reason", table.segments.allSatisfy { ... })
check("pointer samples are not thinned", samples.count ≈ duration × observed rate)
```

The last one is the one that catches a well-meant optimisation later.

- [ ] **Step 4: Commit**

```bash
git add Soredemo/Capture/ObservationWriter.swift Soredemo/UI/ProjectDocument.swift \
        scripts/cross-boundary-digest-probe.swift
git commit -m "observation-log: one file per segment, and Phase 1's dead symbols get callers"
```

---

## Task 11.5: Architecture rule 8 — validating initialiser plus synthesised `Codable`

**Files:**
- Modify: `Sources/architecture-checker/main.swift`, `Sources/CheckerLexer/SwiftSourceLexer.swift` if the scan needs a lexer capability it lacks
- Test: `Tests/GeometryTests/ArchitectureCheckTests.swift`

Read D2-14 first. Ten types currently violate this and they are the rule's negative fixtures — no
fixture needs inventing.

**The rule:** a type with an initialiser that `throws` or contains a `precondition`, **and** a
`Codable`/`Decodable` conformance, **and** no explicit `init(from decoder:)`, is a violation.

**Two things the first hand-written scan got wrong**, both of which the plugin must not repeat: the
conformance may be declared on an **extension**, and so may `init(from:)`. Scan the whole file for
the type. A scan keyed on the declaration line misses `GeometryRegistry`, `ContentDigest` and
`Evidence` — all closed, so the mistake was invisible.

- [ ] **Step 1: Write the rule against the ten known violators as fixtures**, and against the eight
      known-closed types as negative controls. Both lists are in D2-14.
- [ ] **Step 2: Observe it red on the real package**, listing exactly the ten. A list that is short
      or long is the finding, not the count.
- [ ] **Step 3: Exempt the ten explicitly, by name**, in the same shape as `pluginExemptTargets` —
      one literal list, so an eleventh added later still fails. Do not exempt by predicate.
- [ ] **Step 4: Confirm the build fails** when a new violating type is added, and passes when it is
      given an explicit `init(from:)`.
- [ ] **Step 4.5: Consider replacing the ban list with a pinned baseline (D2-17)** — read it before
      doing Step 5. If the baseline is built, Step 5's four names are caught by it automatically and
      the ban list keeps only its *explanatory* role: a baseline says "this symbol is new", a ban
      list says "this symbol is ambient time". Report which you built and why.
- [ ] **Step 5: Close the four verified gaps Task 5.5 found and did not fix** — `NSUUID` (both
      lists, `_OBJC_CLASS_$_NSUUID`), `CCRandomGenerateBytes` (app side; the package side is already
      blocked by rule 1's import allow-list), `clock()` (package side, `_clock`, distinct from the
      already-banned `_clock_gettime`), and `drand48()` (package side, lower confidence — it is
      deterministic unseeded and the risk is shared process-global state; say whether you agree).
      Each needs a fixture call site, and each must be **observed reddening by name** before it is
      kept. See D2-16 for why a pattern scan is not the fix.
- [ ] **Step 6: Commit.**

The exemption list is the remaining work, in a form that cannot rot: closing a type means deleting
its line, and the plugin says so on every build.

---

## Task 12: Close out Phase 2A

- [ ] **Step 1: Run everything, from nothing as well as warm**

```bash
swift test 2>&1 | grep -E "^✔ Test run with"
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build 2>&1 | tail -2
rm -rf /tmp/soredemo-p2 && swift build --build-tests --scratch-path /tmp/soredemo-p2 2>&1 | tail -3
scripts/run-cross-boundary-probe.sh
```

`--build-tests` is not optional: plain `swift build` does not build test targets, and a warm `.build` resolves undeclared imports anyway (F2a).

- [ ] **Step 2: Re-run all five architecture rules' negative cases**

Five rules, five reds, five greens. Rule 1 under **both** `swift build` and `xcodebuild`. This is the phase's real acceptance test and it is observed at the end, not remembered from the middle.

- [ ] **Step 3: Update `ROADMAP.md` honestly**

Mark only what is observable. Specifically:

- `geometry-types` keeps its ☑ **only if** `NormalizationContext` now has a real caller (Task 9). If Task 9 converted somewhere else, rename the row again.
- `project-format` moves off ◐ **only if** the five dead symbols have callers (Task 11), and only for the ones that actually do.
- `capture-permissions` is ☑ only if each degradation was **exercised**, not just defined. Task 6 exercises one of four; say which three were not and why.
- The render half is not in this plan. Do not mark `render-*`, `export-*`, `app-shell` or `preview-playback`.

- [ ] **Step 4: Write `docs/design/2026-08-02-phase-2a-carried-forward.md`**

Per `AGENTS.md`, with its four required parts: code with no caller yet and its intended first caller; rules held by convention rather than enforcement; **defaults this phase depended on and never decided**; and the next merge point named rather than left to drift.

Known entries already: the AX walk's wall-clock budget is a placeholder awaiting D4 calibration; the black-frame threshold likewise; a window-capture revision is session-scoped; three of four permission degradations are defined but unexercised.

- [ ] **Step 5: Commit**

---

## Verification summary

| Row | Verified by |
| --- | --- |
| `one-clock` | every timestamp derives from `Minting.hostNow()`; epoch comparison traps; sleep is detected as the divergence between the two clocks |
| `capture-source` | the system picker yields a filter; a window's revision does not change when the window is dragged |
| `capture-stream` | a segment is a file; idle callbacks produce no frames; reconfiguration closes a segment with a reason |
| `audio-tracks` | **two** audio tracks, with the system tone in one and the microphone tone in the other, both verified live before recording |
| `capture-permissions` | each of four has a distinct named degradation; one exercised end to end, three stated as unexercised |
| `input-observation` | pointer track unthinned; conversion happens only in `CGGeometryBridge`; secure input produces an interval rather than silence |
| `ax-observation` | whole chain recorded with per-item intervals; truncation is a value; distributions match F2-2 within an order of magnitude |
| `observation-log` | one file per segment; boundaries carry reasons; a truncated tail loses the tail and reports the byte count |

---

## Open items

**The wall-clock budget for the AX walk is the only genuinely uncalibrated number.** Depth is fixed at 30 on measured evidence. The budget has no knee and trades coverage against latency with no natural stopping point — 35 ms is a starting value, not a finding, and D4 applies to it.

**Three of four permission degradations will be defined but not exercised.** Screen Recording needs a relaunch cycle; revoking Accessibility or Input Monitoring mid-session disrupts the machine being worked on. The row must not read as though four were tested.

**The black-frame detector's threshold is a placeholder**, and a genuinely black screen exists. Until it is calibrated it logs rather than aborts.

**A window-capture revision is session-scoped**, because a window has no identity that survives a restart of its application. Load-bearing only for Phase 4's `selective-rerecord`, whose actual requirement has not been read.

**`SegmentBoundary` may need a `windowResized` case**, depending on Task 7 Step 3's measurement of whether ScreenCaptureKit scales-to-fill or letterboxes.
