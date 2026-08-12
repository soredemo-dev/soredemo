// `@preconcurrency`: `kAXTrustedCheckOptionPrompt` imports as a `var`, which Swift 6 strict
// concurrency rejects as unchecked shared mutable state.
// `@unsafe` as well as `@preconcurrency`: the suppressed checking is what
// `.strictMemorySafety()` wants named. Safe here — the only ApplicationServices value
// this file touches is the immutable `kAXTrustedCheckOptionPrompt` constant below.
@unsafe @preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import IOKit.hid

/// The four TCC-gated permissions capture depends on.
public enum CapturePermission: String, CaseIterable, Sendable {
    case screenRecording, microphone, inputMonitoring, accessibility
}

/// What one of the four permission APIs can say about its own permission.
/// Not every API distinguishes all four TCC states; `.notGrantedIndeterminate`
/// is the answer when an API reports only granted/not-granted. See
/// `CapturePermissions.distinguishableStates(for:)` for which cases each
/// permission can actually produce.
public enum PermissionStatus: String, Codable, Sendable {
    /// Never asked — the only state in which calling the request API is correct.
    /// Reported only by microphone and input monitoring.
    case notDetermined
    case granted
    /// Explicitly refused. For input monitoring this also absorbs denials
    /// `IOHIDAccessType` does not further distinguish.
    case denied
    /// Denied by MDM or parental controls, not fixable by the user. Reported
    /// only by microphone.
    case restricted
    /// The API said only "not granted"; the true TCC state is unknowable here.
    case notGrantedIndeterminate
}

/// What the product still does when a `CapturePermission` is absent.
/// `Codable` so it can be persisted into the observation log rather than
/// inferred from an absent entry. Today it is only read by diagnostics; the
/// intended consumers are capture start-up (refusing on `.blocksRecording`)
/// and the observation log.
public enum Degradation: String, Codable, Sendable {
    case blocksRecording
    /// Never produced: `SCStreamConfiguration` requests microphone, video and
    /// system audio as one inseparable request, so a denied microphone fails
    /// the whole stream and maps to `.blocksRecording`. Kept because removing
    /// a raw-value case is a wire-breaking change.
    case noMicrophoneTrack
    case observationBlind
    case noElementIdentity
}

/// One permission's status and degradation — one row of `dumpText()`.
public struct PermissionObservation: Sendable {
    public let permission: CapturePermission
    public let status: PermissionStatus
    public let degradation: Degradation
}

public enum CapturePermissions {
    /// Reads each permission's own API directly, uncached — a point-in-time
    /// read only. A Screen Recording grant revoked mid-recording yields black
    /// frames rather than an error, so this is a start-of-run gate, not a
    /// guarantee; revocation during capture must be detected elsewhere.
    ///
    /// Fidelity per API: microphone (`AVAuthorizationStatus`) names all four
    /// states; input monitoring (`IOHIDAccessType`) names three, with `Denied`
    /// absorbing MDM restriction; Screen Recording and Accessibility are `Bool`
    /// only, so `false` maps to `.notGrantedIndeterminate`, never `.denied`.
    ///
    /// `nonisolated` is required: the target defaults to `@MainActor` isolation
    /// and this is called from nonisolated contexts. All four underlying APIs
    /// are thread-safe and touch no UI state. Only this function is annotated:
    /// the dump and its subject block read `Bundle.main` and stay main-actor.
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
                // IOHIDAccessType is a plain C enum, so Swift offers no
                // `@unknown default` check; trap rather than guess.
                preconditionFailure(
                    "IOHIDCheckAccess returned a value this project's IOHIDAccessType mapping does not name")
            }

        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGrantedIndeterminate
        }
    }

    /// Asks for Screen Recording. `SCStream` and `SCContentSharingPicker` never
    /// prompt on their own, so this is the only path that asks the user.
    /// Call it unguarded: `CGPreflightScreenCaptureAccess()` can read `.granted`
    /// while capture still fails, and this call is idempotent — it prompts only
    /// in the never-asked state and returns `true` when already granted.
    /// Called from `RecordingCoordinator.beginOpenRecording()` before the
    /// picker opens.
    @discardableResult
    public static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Asks for Accessibility — the only prompting call in the repo;
    /// `status(of: .accessibility)` uses `AXIsProcessTrusted()`, which never asks.
    /// Returns the trust state at the moment of the call: `false` in both the
    /// never-asked state (which also raises the prompt) and the denied state.
    /// Callers must use this return value rather than re-reading trust after.
    /// Called from `CaptureSession` before the AX walk's first use.
    @discardableResult
    public static func requestAccessibilityAccess() -> Bool {
        // Safe here: `takeUnretainedValue()` is correct for a constant the framework owns
        // and never releases — it is not a `Create`/`Copy` result to take ownership of.
        let promptKey = unsafe kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Which `PermissionStatus` cases a given permission's API can actually
    /// produce. `.notGrantedIndeterminate` in the set means that API cannot
    /// separate `.notDetermined`, `.denied` and `.restricted`.
    public static func distinguishableStates(for p: CapturePermission) -> Set<PermissionStatus> {
        switch p {
        case .screenRecording, .accessibility:
            // Bool-only APIs: granted vs. everything else, undivided.
            return [.granted, .notGrantedIndeterminate]
        case .microphone:
            // AVAuthorizationStatus names all four.
            return [.notDetermined, .granted, .denied, .restricted]
        case .inputMonitoring:
            // IOHIDAccessType names three; no MDM/user split.
            return [.notDetermined, .granted, .denied]
        }
    }

    /// What the product still does without `p`. `.microphone` maps to
    /// `.blocksRecording`, not `.noMicrophoneTrack`: a denied microphone fails
    /// the whole `SCStream`, not just the microphone track.
    public static func degradation(for p: CapturePermission) -> Degradation {
        switch p {
        case .screenRecording: return .blocksRecording
        case .microphone:      return .blocksRecording
        case .inputMonitoring: return .observationBlind
        case .accessibility:   return .noElementIdentity
        }
    }

    /// Permissions whose absence stops a recording rather than degrading it.
    /// Derived from `degradation(for:)` so a mapping change is picked up here.
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

    /// Plain-text permission dump for a human, subject block first. TCC
    /// behaviour changes across macOS point releases, so the OS version is
    /// printed alongside the readings. Must run as the app's own bundled
    /// executable: TCC attributes reads to the responsible process, so a bare
    /// binary reports the terminal's grants instead. Output is plain text for a
    /// person comparing it against System Settings, not JSON for a program.
    public static func dumpText(build: String, commit: String) -> String {
        var lines = subjectBlockLines(build: build, commit: commit)
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
    /// dump; `--dump-permissions` and `--present-picker` both call it so the
    /// two cannot drift. `bundle identifier: nil` is the tell that the reading
    /// came from a process with no bundle identity, whose TCC grants are not
    /// Soredemo's. `build`/`commit` come from `BuildProvenance`, baked in at
    /// build time, so a diagnosis from a stale binary is visible.
    ///
    /// **`build` and `commit` are PARAMETERS since Phase 3A-3, not a read of
    /// `BuildProvenance`.** That type is generated into the app target by
    /// `scripts/build-app-for-verification.sh` immediately before `xcodebuild`
    /// compiles it, and it is a fact about the app BINARY — so it stays in the app
    /// tier, and this file, now in a package target, is handed the two strings
    /// rather than reaching for a generated file the package does not own. The
    /// alternative — moving the generated file into `Sources/` — would point a
    /// build script at a package target to bake in an app fact, which is the
    /// dependency this extraction exists to remove.
    public static func subjectBlockLines(build: String, commit: String) -> [String] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let bundle = Bundle.main
        return [
            "build             : \(build)",
            "commit            : \(commit)",
            "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "bundle identifier : \(bundle.bundleIdentifier ?? "nil")",
            "executable path   : \(bundle.executablePath ?? "nil")",
            "inside a .app     : \(bundle.bundlePath.hasSuffix(".app") ? "yes" : "no")",
            "pid               : \(ProcessInfo.processInfo.processIdentifier)",
        ]
    }
}

// MARK: - the state `status(of:)` cannot see

/// A grant flipped ON for an already-running process reads as `.granted`
/// immediately while that process still cannot capture until it relaunches.
/// This is indistinguishable from ordinary `.granted` through any API here, so
/// it is documented rather than modelled as a `PermissionStatus` case.
