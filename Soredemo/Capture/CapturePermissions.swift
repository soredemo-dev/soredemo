// `@preconcurrency`: `kAXTrustedCheckOptionPrompt` (used by `requestAccessibilityAccess()` below)
// imports from this framework as a `var` Swift 6 strict concurrency reads as unchecked shared
// mutable state — the same reasoning `CaptureSession.swift`/`ContentView.swift` already carry for
// `@preconcurrency import ScreenCaptureKit`, applied to the one ApplicationServices global this
// file newly reads.
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import IOKit.hid

/// The four TCC-gated permissions capture depends on. `ROADMAP.md`'s
/// `capture-permissions` row: each one's absence must degrade the product
/// *precisely* — a stated, distinct consequence that is what actually
/// happens, not an inference drawn later from a gap.
public enum CapturePermission: String, CaseIterable, Sendable {
    case screenRecording, microphone, inputMonitoring, accessibility
}

/// What one of the four permission APIs can say about its own permission,
/// modelled from what each API can actually distinguish rather than from a
/// flat granted/denied guess.
///
/// TCC's real state space, per the design doc's F2-4/carried-forward TCC
/// section and Apple's own headers, has at least: never asked (the only
/// state where prompting is appropriate), granted, denied by the user, and
/// restricted by MDM or parental controls (which the user cannot fix, unlike
/// a plain denial). A fifth state — granted in TCC while the *running*
/// process still behaves as though it is not (Spike B; see the note on
/// `CapturePermissions` below) — is not a TCC state at all and cannot be
/// reported by any of these four functions; it is documented, not modelled
/// as a case here, because no query this file can make distinguishes it.
///
/// Not every permission's API can report all four TCC-level cases. Where an
/// API answers only "granted" or "not granted" (Screen Recording,
/// Accessibility — both `Bool`), collapsing that into `.denied` would be
/// exactly `AGENTS.md`'s "measurement with a safe default": `.denied` is a
/// legal answer, it would look plausible, and it would be wrong whenever the
/// true state was `.notDetermined` — the one case where prompting, rather
/// than telling the user to go to System Settings, is the right move.
/// `.notGrantedIndeterminate` exists so that ambiguity is never silently
/// resolved into a specific wrong answer; it is a value outside the range of
/// "here is what TCC recorded", which is the honest thing to report when the
/// API cannot say. `CapturePermissions.distinguishableStates(for:)` states,
/// per permission, which of these cases its API can actually produce.
public enum PermissionStatus: String, Codable, Sendable {
    /// Never asked. Reachable only where the API reports it as a distinct
    /// case (microphone, input monitoring) — the only state in which calling
    /// the permission's request API is the correct move.
    case notDetermined
    case granted
    /// The user was asked and explicitly refused. For input monitoring this
    /// also covers "denied for a reason `IOHIDAccessType` does not further
    /// distinguish" — see the per-permission note in `status(of:)`.
    case denied
    /// Denied by MDM or parental controls, not by the user — the user
    /// cannot fix this by clicking anything. Reachable only where the API
    /// reports it as a distinct case (microphone, today the only one).
    case restricted
    /// The API answered only "granted" or "not granted", with nothing more.
    /// The true TCC state could be `.notDetermined`, `.denied`, or
    /// `.restricted` — this code cannot tell which, and does not guess.
    case notGrantedIndeterminate
}

/// What the product still does when a `CapturePermission` is absent. Every
/// case is a state meant to be written into the observation log once
/// `observation-log` exists, so a project produced without a permission is
/// **distinguishable on disk** from one produced with it, rather than
/// inferred later from an empty log — the same "silence is not a value"
/// discipline the design doc applies to `SCFrameStatusIdle` and chain
/// truncation (D2-6, D2-2). `Codable` is what makes that possible: this type
/// is data ready to be persisted, not merely reasoned about in memory.
///
/// **Not recorded in any recording, and reached only by a diagnostic.** No
/// `.soredemo` package and no observation log carries a degradation. The one
/// path that reaches `degradation(for:)` at all is
/// `observations()` → `dumpText()` → `SoredemoApp.swift`'s `--present-picker`
/// print: a developer command, not the first-run behaviour this models.
/// `blockingFailures()`, the other consumer, has **zero callers anywhere**.
///
/// This comment previously said "the code with no caller yet". That was
/// materially wrong once the diagnostic chain existed — "no caller" and "one
/// caller, and it is a debug print" answer differently the only question a
/// reader asks here, which is whether this modelling has ever been exercised.
/// It has, by a `print`, and by nothing that records or refuses anything.
///
/// The reason to model it once rather than re-derive it per caller still
/// holds. The intended callers remain `capture-stream` — refusing to start on
/// `.blocksRecording` — and `observation-log`, writing the other three into
/// every recording they apply to.
public enum Degradation: String, Codable, Sendable {
    case blocksRecording
    /// **Never produced, and the reason is a measurement, not a preference.**
    /// This case claimed a milder consequence for a denied microphone — video
    /// and system audio keep recording, just without a microphone track. That
    /// is not what happens: `SCStreamConfiguration` asks for the microphone as
    /// one INSEPARABLE request alongside video and system audio, and denying
    /// any part of that request fails the whole stream. So a denied microphone
    /// is `.blocksRecording`, like screen recording, and `degradation(for:)`
    /// returns exactly that. `Tests/AppSourceTests/ProductionCallerTests.swift`
    /// pins the mapping so it cannot drift back.
    ///
    /// **An enum case with no producer is an unverified capability claim** —
    /// the same category as `blockingFailures()` (zero callers) and
    /// `Sources/Timeline/TimeRange.swift` (no caller in `Sources/`). It is kept
    /// rather than deleted: it is a `String` raw value that could already be
    /// on disk nowhere today (`Degradation` is "not yet recorded anywhere",
    /// below) but removing a case is exactly the wire-breaking edit
    /// `ObservationLog.schemaVersion`'s doc comment warns about one type over,
    /// for a saving of one case this type does not need.
    case noMicrophoneTrack
    case observationBlind
    case noElementIdentity
}

/// One permission's status, degradation, and the API's confidence in that
/// status, together — what `CapturePermissions.dumpText()` reports one row
/// of.
public struct PermissionObservation: Sendable {
    public let permission: CapturePermission
    public let status: PermissionStatus
    public let degradation: Degradation
}

public enum CapturePermissions {
    /// Reads each permission's own API directly — no caching, no derived
    /// state. `AGENTS.md`'s "the instrument can have state" warns that a
    /// cached read can make a correct implementation look broken; this
    /// function has no cache to go stale, at the cost of re-touching all
    /// four APIs on each call, which for a background TCC query is cheap.
    ///
    /// **Screen Recording — `CGPreflightScreenCaptureAccess()`.** `Bool`
    /// only. Per the design doc's TCC section: a revoked grant produces
    /// black frames rather than an error, so this check is a start-of-run
    /// gate, not a guarantee — `capture-stream` (Task 8) must detect
    /// revocation *during* recording, which this function structurally
    /// cannot do because it is a point-in-time read.
    ///
    /// **Microphone — `AVCaptureDevice.authorizationStatus(for: .audio)`.**
    /// The one permission of the four whose API distinguishes all of
    /// `.notDetermined`, `.restricted`, `.denied` and `.authorized` as
    /// named, separate cases (verified against `AVCaptureDevice.h`:
    /// `AVAuthorizationStatus` is `NS_ENUM` with exactly those four raw
    /// values 0–3). Full fidelity, mapped straight across.
    ///
    /// **Input Monitoring — `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.**
    /// `IOHIDAccessType` has three cases — `Granted`, `Denied`, `Unknown` —
    /// verified against `IOKit/hidsystem/IOHIDLib.h` (the header lives under
    /// the `hidsystem` submodule; `import IOKit.hid` still resolves it,
    /// checked by compiling a standalone probe against this SDK). `Unknown`
    /// is the never-asked case, mapped to `.notDetermined`. There is no
    /// fourth case for MDM restriction — `Denied` is IOHID's only "not
    /// granted, and someone made that decision" bucket, so it may contain
    /// what a finer API would call `.restricted`; that collapse is real and
    /// is recorded in `distinguishableStates(for:)`, not hidden by minting a
    /// `.restricted` value this API never actually returns.
    ///
    /// **Accessibility — `AXIsProcessTrusted()`.** `Bool` only, exactly like
    /// Screen Recording, and exactly as collapsible: this cannot tell "never
    /// asked" from "denied" from "restricted", so `false` maps to
    /// `.notGrantedIndeterminate`, never to `.denied`.
    ///
    /// **`nonisolated`, added in Task 10, and the same annotation for the same
    /// reason `Minting` and `CGGeometryBridge` both carry.** Unannotated, this
    /// function is implicitly `@MainActor` under this target's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — harmless while every
    /// caller was itself MainActor, which stopped being true once `AXObserver`
    /// (Task 10) needed to say *why* a hit-test returned nothing from inside a
    /// `nonisolated` walk reached from `InputObserver`'s tap callback, a bare C
    /// function pointer with no isolation to inherit. Measured, not assumed:
    /// `xcodebuild` rejected the call with "call to main actor-isolated static
    /// method 'status(of:)' in a synchronous nonisolated context", the same
    /// shape both of those files record hitting.
    ///
    /// The four APIs underneath are thread-safe point-in-time reads —
    /// `CGPreflightScreenCaptureAccess`, `AVCaptureDevice.authorizationStatus
    /// (for:)` (a class method over TCC's own state), `IOHIDCheckAccess` and
    /// `AXIsProcessTrusted` — and none of them touches AppKit or UI state, so
    /// `nonisolated` states what was already true of the implementation rather
    /// than working around the compiler. Only this function is annotated: the
    /// dump and its subject block read `Bundle.main` and belong on the main
    /// actor.
    public nonisolated static func status(of p: CapturePermission) -> PermissionStatus {
        switch p {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGrantedIndeterminate

        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return .notDetermined
            case .restricted:    return .restricted
            case .denied:        return .denied
            case .authorized:    return .granted
            @unknown default:
                preconditionFailure(
                    "AVAuthorizationStatus produced a case this project's mapping does not name")
            }

        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied:  return .denied
            case kIOHIDAccessTypeUnknown: return .notDetermined
            default:
                // IOHIDAccessType is a plain C enum, not `NS_ENUM` — Swift
                // gives no `@unknown default` exhaustiveness check for it,
                // so an unrecognised raw value falls here. Trap rather than
                // guess which of the three named cases it must have meant;
                // `AGENTS.md`: failure must land outside the value range.
                preconditionFailure(
                    "IOHIDCheckAccess returned a value this project's IOHIDAccessType mapping does not name")
            }

        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGrantedIndeterminate
        }
    }

    /// Asks for Screen Recording — Task 5.5's Step 3.
    ///
    /// **`CGRequestScreenCaptureAccess` occurred zero times in this repository
    /// before this function.** `SCStream` and `SCContentSharingPicker` do not
    /// prompt on their own, so without a call to this, a first-run user is
    /// told "the user declined" by an API that never asked them.
    ///
    /// **Do not guard the call site with `status(of: .screenRecording) !=
    /// .granted`** — measured (D6b row 18): `CGPreflightScreenCaptureAccess()`
    /// read `.granted` immediately after `tccutil reset ScreenCapture
    /// video.soredemo.Soredemo`, and the very next `SCStream.startCapture()`
    /// refused with `-3801`. That guard would never fire on this machine, so
    /// a call behind it is dead code that reads like protection. The call
    /// below is idempotent on its own terms instead: it prompts only in the
    /// never-asked state, and returns `true` immediately when already
    /// granted — so it costs nothing to call every time.
    ///
    /// Called from `RecordingCoordinator.beginOpenRecording()`, before the
    /// picker opens.
    @discardableResult
    public static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Asks for Accessibility — Task 5.5's Step 4, the same absence as Step 3
    /// one permission over. `AXIsProcessTrustedWithOptions` with the prompt
    /// option occurred zero times in this repository before this function;
    /// `status(of: .accessibility)` above only ever reads `AXIsProcessTrusted()`,
    /// which never asks.
    ///
    /// Returns the trust state at the moment of the call — `true` if already
    /// granted, `false` in the never-asked state (which also triggers the
    /// system prompt) and in the denied state. `CaptureSession` uses this
    /// return value directly to decide whether this segment's observation log
    /// header should carry `.accessibilityUnavailable`, rather than making a
    /// second, separate read of the trust state afterwards —
    /// `Tests/AppSourceTests/AppSourceAllowListTests.swift`'s
    /// `theAccessibilityPredicateIsReadOnceAndOnlyInTheObserverThatInjectsIt`
    /// pins `CapturePermissions.status(of: .accessibility)` (a **different**
    /// call, `AXIsProcessTrusted()` with no prompt) to exactly one call site —
    /// `AXObserver`'s own injection point — so this function deliberately
    /// does not call it either.
    ///
    /// Called from `CaptureSession` before the AX walk's first use.
    @discardableResult
    public static func requestAccessibilityAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Which `PermissionStatus` cases a given permission's API can actually
    /// produce — the answer to "which of these can this API not tell
    /// apart", made queryable rather than left in prose alone.
    ///
    /// `.notGrantedIndeterminate` appearing here is the honest marker that
    /// `.notDetermined`, `.denied` and `.restricted` are *not* individually
    /// reachable for that permission — not that they cannot occur in TCC,
    /// only that this API cannot report which one did.
    public static func distinguishableStates(for p: CapturePermission) -> Set<PermissionStatus> {
        switch p {
        case .screenRecording, .accessibility:
            // Bool-only APIs: granted vs. everything else, undivided.
            return [.granted, .notGrantedIndeterminate]
        case .microphone:
            // AVAuthorizationStatus names all four.
            return [.notDetermined, .granted, .denied, .restricted]
        case .inputMonitoring:
            // IOHIDAccessType names three: never-asked, granted, and one
            // "not granted" bucket with no MDM/user split.
            return [.notDetermined, .granted, .denied]
        }
    }

    /// What the product still does without `p` — see `Degradation`'s doc
    /// comment for where this is meant to be recorded.
    ///
    /// **`.microphone` maps to `.blocksRecording`, not `.noMicrophoneTrack` —
    /// corrected in Task 5.5 to match a measurement rather than an
    /// assumption.** Measured at the Task 4 human step:
    /// `CaptureSession.beginSegment` sets `configuration.captureMicrophone =
    /// true` unconditionally, and with the entitlement missing (the state
    /// Task 5.5's Step 1 fixed) `tccd` refused the process the capability
    /// outright —
    ///
    /// ```
    /// service: kTCCServiceMicrophone requires entitlement
    /// com.apple.security.device.audio-input but it is missing
    /// Policy disallows prompt
    /// access to kTCCServiceMicrophone denied
    /// ```
    ///
    /// — and the **whole recording** failed to start, not merely the
    /// microphone track. `.noMicrophoneTrack` claimed a distinct, milder
    /// consequence — system audio and video keep recording, just without a
    /// microphone track — that this file's own doc comment (line 9) demands
    /// be "what actually happens", and it was not: `SCStreamConfiguration`
    /// asks for a microphone as one inseparable request alongside video and
    /// system audio, and denying any part of that request fails the whole
    /// stream. `Tests/AppSourceTests/ProductionCallerTests.swift` pins this
    /// row against the measurement above.
    public static func degradation(for p: CapturePermission) -> Degradation {
        switch p {
        case .screenRecording: return .blocksRecording
        case .microphone:      return .blocksRecording
        case .inputMonitoring: return .observationBlind
        case .accessibility:   return .noElementIdentity
        }
    }

    /// Permissions whose absence stops a recording rather than degrading it.
    /// **Two now, `.screenRecording` and `.microphone`**, since Task 5.5
    /// corrected the second's mapping above — this was written as a filter
    /// over all four rather than a literal pair specifically so a change like
    /// that one would be picked up without this function itself changing, and
    /// it was.
    public static func blockingFailures() -> [CapturePermission] {
        CapturePermission.allCases.filter {
            degradation(for: $0) == .blocksRecording && status(of: $0) != .granted
        }
    }

    /// All four permissions, read once, paired with their degradation.
    public static func observations() -> [PermissionObservation] {
        CapturePermission.allCases.map {
            PermissionObservation(permission: $0, status: status(of: $0), degradation: degradation(for: $0))
        }
    }

    /// Flat text, subject first, OS version second — the repeatable check
    /// `AGENTS.md`'s completion rule and the design doc's TCC section both
    /// ask for. TCC's behaviour has already changed inside one macOS point
    /// release, 26.0.1 to 26.1 (carried-forward doc), so a claim about what
    /// one of these four functions reports is only as good as the OS
    /// version it was read under, printed beside it rather than assumed
    /// stable.
    ///
    /// **The subject block exists because moving this dump inside
    /// `Soredemo.app` fixed one occurrence and not the category.** The bare
    /// probe was wrong because TCC attributed its reads to its responsible
    /// process rather than to it — a fact invisible in its output, which
    /// read as four confident answers with nothing to flag them as being
    /// about the wrong thing. Running the app itself narrows how that can
    /// happen again, but does not remove it: launched from Xcode, from
    /// Finder, or execed directly from a shell, a process can still end up
    /// answering for something other than `dev.soredemo.mac` — and
    /// the failure shape is identical, four plausible-looking values with
    /// nothing about them that looks wrong. So every dump names its own
    /// subject, in the same output, rather than asking whoever reads it to
    /// already know what a responsible process is:
    ///
    /// - `bundle identifier` — `Bundle.main.bundleIdentifier`. `nil` here is
    ///   the single-line tell that whatever ran has no bundle identity at
    ///   all (the bare probe's failure mode) and the four values below
    ///   cannot be about `Soredemo`, no System Settings pane required to
    ///   notice it.
    /// - `executable path` — `Bundle.main.executablePath`, so a stale or
    ///   unexpected build (wrong `DerivedData`, wrong scheme) is visible
    ///   rather than assumed.
    /// - `inside a .app` — whether `Bundle.main.bundlePath` ends in `.app`.
    ///   Redundant with the bundle identifier on paper; kept anyway,
    ///   because it is a second, differently-computed signal for the same
    ///   claim, and a mismatch between the two (a `.app` path with a `nil`
    ///   identifier, say) would itself be a finding.
    /// - `pid` — `ProcessInfo.processInfo.processIdentifier`, for whoever is
    ///   correlating this output against `Console.app` or a `log show`
    ///   query for the same moment.
    ///
    /// Deliberately plain text, not JSON: the reader is a person standing at
    /// System Settings comparing two short lists, not another program.
    /// Invoked from `Soredemo/App/SoredemoApp.swift`'s `init()` via
    /// `--dump-permissions`, run as the app's own executable — see that
    /// file for why, and why it is not the probe.
    ///
    /// **Extended in Task 7's fix round 3, not duplicated.** `--present-picker`
    /// (also in `SoredemoApp.swift`) needs the identical "which build, which
    /// process" preamble for the identical reason — a stale `.app` at a
    /// remembered path answers just as confidently and just as wrongly as
    /// the misattributed TCC reads this block was built to catch. Both entry
    /// points call `subjectBlockLines()` below rather than each formatting
    /// their own, so the two cannot drift apart on what "the subject" means.
    public static func dumpText() -> String {
        var lines = subjectBlockLines()
        lines.append("──")
        for o in observations() {
            lines.append(
                "\(o.permission.rawValue): \(o.status.rawValue)"
                + "  [distinguishable: \(distinguishableStates(for: o.permission).map(\.rawValue).sorted().joined(separator: ", "))]"
                + "  (absence -> \(o.degradation.rawValue))")
        }
        return lines.joined(separator: "\n")
    }

    /// The "which build, which process" preamble shared by every diagnostic
    /// dump in this app. Two families of fact, and both were added only
    /// after a wrong answer without them was actually observed, not out of
    /// caution:
    ///
    /// - **`build`/`commit`** (`BuildProvenance`, Task 7 fix round 3) — a
    ///   diagnosis built from a stale binary looks identical to one built
    ///   from the code actually on disk, because both are confident and
    ///   inside the legal range of a real answer. See that file's doc
    ///   comment for why these two fields are baked in at build time rather
    ///   than read at launch.
    /// - **`bundle identifier`/`executable path`/`inside a .app`/`pid`**
    ///   (Task 6) — TCC attributes a permission read to the *responsible
    ///   process*, not to whoever asked, so a bare probe with no bundle
    ///   identity reported the terminal's grants as though they were
    ///   `Soredemo`'s. `bundle identifier: nil` is the single-line tell.
    ///
    /// Both are the same shape one level apart: a confident, in-range answer
    /// to the wrong question, and a subject line that makes the question
    /// visible instead of assumed.
    public static func subjectBlockLines() -> [String] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let bundle = Bundle.main
        return [
            "build             : \(BuildProvenance.builtAt)",
            "commit            : \(BuildProvenance.commit)",
            "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "bundle identifier : \(bundle.bundleIdentifier ?? "nil")",
            "executable path   : \(bundle.executablePath ?? "nil")",
            "inside a .app     : \(bundle.bundlePath.hasSuffix(".app") ? "yes" : "no")",
            "pid               : \(ProcessInfo.processInfo.processIdentifier)",
        ]
    }
}

// MARK: - the state `status(of:)` cannot see

/// Documented rather than coded, deliberately — see the task-6 report for
/// why building this now is out of order.
///
/// Spike B (design doc, § Spike B / F2-4) measured a fifth state that is not
/// a TCC state at all: **granted while the process is already running**, the
/// switch flipped ON in System Settings for a process that was already
/// launched before the grant, which keeps failing until it relaunches. This
/// is the dangerous case named in the task brief, because
/// `CGPreflightScreenCaptureAccess()` reads the TCC database directly —
/// nothing in `status(of:)` caches — so the moment a human flips the switch,
/// `status(of: .screenRecording)` is expected to read `.granted`
/// immediately, before any relaunch, while the running process's actual
/// capture capability has not caught up. The interface says permission is
/// fine; nothing downstream is fine yet.
///
/// This cannot be folded into `PermissionStatus` as a case, because no query
/// available to this file distinguishes it from ordinary `.granted` — the
/// whole finding is that the two read identically through this API. It can
/// only be produced empirically, by an experiment that changes machine
/// state, which is why it is not implemented here.
///
/// What that experiment needs, so it does not have to be re-derived when it
/// is finally run (`capture-stream`, Task 8, per this row's `ROADMAP.md`
/// dependent):
///
/// 1. Start from a process with Screen Recording **not** granted —
///    `status(of: .screenRecording)` reading `.notGrantedIndeterminate`.
/// 2. A human flips Screen Recording ON for that running process in System
///    Settings, without relaunching it.
/// 3. Re-read `status(of: .screenRecording)` in the same process. Predicted
///    `.granted`, per the reasoning above — this step confirms the
///    prediction rather than assumes it.
/// 4. Attempt an actual `SCStream` capture in that same, unrelaunched
///    process, and record which of three distinct symptoms shows up:
///    `SCStream.startCapture` throwing, frames simply not arriving, or
///    frames arriving black (the separate, already-measured failure mode
///    for a *revoked* grant, F2-4/TCC section — capture succeeding
///    structurally while producing black frames). These are three different
///    bugs with three different fixes, and only a live run distinguishes
///    them.
/// 5. Relaunch and repeat step 4, to confirm the same permission now works —
///    isolating the variable to "already running" rather than something
///    else being wrong with the harness.
///
/// Must run **last**, after this task's Step 3 blind comparison: it is the
/// one measurement in this row that changes the machine's permission state,
/// and every other measurement here depends on that state staying untouched
/// until the comparison is recorded.
