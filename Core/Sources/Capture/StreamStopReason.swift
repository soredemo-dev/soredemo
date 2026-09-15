import Foundation
import ScreenCaptureKit

/// Why ScreenCaptureKit stopped a running stream, and whether opening a new one
/// is worth trying.
///
/// `SCStream` reports every stop through one delegate callback — the user
/// pressing stop, the display sleeping, a missing entitlement — and treating them
/// alike costs a recording. The verdict is a value, never `nil`: an error this
/// type cannot place still gets a case that says so.
///
/// The codes, the recovery, and both bounds are in
/// `docs/design/surviving-a-stopped-stream.md`.
public enum StreamStopReason: Sendable, Equatable {
    /// `SCStreamErrorUserStopped` (-3817). The person clicked stop in the
    /// system's capture control. Reopening the stream would fight them.
    case theUserStoppedIt

    /// `SCStreamErrorSystemStoppedStream` (-3821). A closed lid, a sleeping
    /// display, a fast user switch. The display comes back and so can the stream.
    case theSystemTookTheDisplayAway

    /// `SCStreamErrorFailedApplicationConnectionInvalid` (-3804) or
    /// `…Interrupted` (-3805). The connection to the capture daemon died rather
    /// than the capture itself failing. A new stream gets a new connection.
    case theConnectionToTheCaptureDaemonDied(code: Int)

    /// A ScreenCaptureKit error about this recording's SETUP rather than a
    /// passing condition — a permission, an entitlement, an invalid parameter, a
    /// missing source. Rebuilding the same stream reproduces it.
    /// `SCStreamErrorInsufficientStorage` (-3822), new in macOS 27. **Its own case rather than
    /// one more anonymous code**, because it is the only stop with an action attached: a person
    /// told "the recording stopped" looks for a bug in this app, and a person told the disk
    /// filled up goes and empties it. Restarting is pointless while it is still full, so it
    /// shares `itWillFailTheSameWayAgain`'s verdict and not its silence.
    case theDiskFilledUp
    /// `SCStreamErrorNotSupported` (-3823), new in macOS 27. What was asked for cannot be done
    /// on this machine or this source — a permanent no, distinct from a failure.
    case thisIsNotSupportedHere
    case itWillFailTheSameWayAgain(code: Int)

    /// Not `SCStreamErrorDomain` at all. Named rather than folded into the case
    /// above: "some other subsystem failed" is a different fact from
    /// "ScreenCaptureKit refused".
    case unrecognised(domain: String, code: Int)

    /// Codes that name a connection to the capture daemon rather than a fault in
    /// the capture. Listed here so the two members of the pair are visibly the
    /// same decision.
    /// `SCStreamErrorInsufficientStorage`, macOS 27.
    private static let insufficientStorageCode = -3822
    /// `SCStreamErrorNotSupported`, macOS 27.
    private static let notSupportedCode = -3823

    private static let daemonConnectionCodes: Set<Int> = [
        SCStreamError.Code.failedApplicationConnectionInvalid.rawValue,
        SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue,
    ]

    public init(_ error: any Error) {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain else {
            self = .unrecognised(domain: ns.domain, code: ns.code)
            return
        }
        switch ns.code {
        case SCStreamError.Code.userStopped.rawValue:
            self = .theUserStoppedIt
        case SCStreamError.Code.systemStoppedStream.rawValue:
            self = .theSystemTookTheDisplayAway
        case let code where Self.daemonConnectionCodes.contains(code):
            self = .theConnectionToTheCaptureDaemonDied(code: code)
        // **Matched on the raw values, not the enum cases.** `SCStreamError.Code` in the
        // macOS 27 SDK carries these, but this package's floor is what decides whether naming
        // them compiles; the numbers are stable and documented in the header, and a raw match
        // says what it matches.
        case Self.insufficientStorageCode:
            self = .theDiskFilledUp
        case Self.notSupportedCode:
            self = .thisIsNotSupportedHere
        case let code:
            self = .itWillFailTheSameWayAgain(code: code)
        }
    }

    /// Whether a fresh stream over the same source is worth opening.
    ///
    /// `-3811` is deliberately NOT here even though it is sometimes transient —
    /// see the design doc for why the safe direction is to refuse.
    public var isWorthRestarting: Bool {
        switch self {
        case .theSystemTookTheDisplayAway, .theConnectionToTheCaptureDaemonDied:
            return true
        case .theUserStoppedIt, .itWillFailTheSameWayAgain, .unrecognised,
             .theDiskFilledUp, .thisIsNotSupportedHere:
            return false
        }
    }

    /// What goes in the segment boundary, and into a support log. Includes the
    /// raw code: the name is this project's reading of it, and a reader who
    /// disagrees needs the number to check it against.
    public var description: String {
        switch self {
        case .theUserStoppedIt:
            return "the user stopped the capture (SCStreamErrorUserStopped, -3817)"
        case .theSystemTookTheDisplayAway:
            return "the system stopped the stream (SCStreamErrorSystemStoppedStream, -3821)"
        case .theConnectionToTheCaptureDaemonDied(let code):
            return "the capture daemon connection died (SCStreamErrorDomain, \(code))"
        case .theDiskFilledUp:
            return "the disk ran out of room (SCStreamErrorInsufficientStorage, -3822)"
        case .thisIsNotSupportedHere:
            return "the capture is not supported here (SCStreamErrorNotSupported, -3823)"
        case .itWillFailTheSameWayAgain(let code):
            return "ScreenCaptureKit refused and will refuse again (SCStreamErrorDomain, \(code))"
        case .unrecognised(let domain, let code):
            return "an error outside ScreenCaptureKit (\(Self.identifierOnly(domain)), \(code))"
        }
    }

    /// A domain, or a refusal naming its length — never the domain's own text
    /// when that text is not an identifier.
    ///
    /// `description` is the only part of this type that reaches disk, and
    /// `.unrecognised` is its one case holding a string this project did not
    /// write. A domain built from a path would otherwise put a home directory in
    /// a saved project; every domain Apple ships is a reverse-DNS identifier, so
    /// the rule costs nothing on any expected error.
    private static func identifierOnly(_ domain: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        // 200: longer than every domain Apple ships by an order of magnitude, and
        // shorter than any path worth worrying about. A bound, not a judgement.
        guard domain.count <= 200,
              domain.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "a domain withheld for not being an identifier, \(domain.count) characters"
        }
        return domain
    }

    /// How many rebuilds before a restartable stop becomes a stopped recording.
    /// Five, not three: the first attempt after a display wakes is the one most
    /// likely to lose a race with the window server. **Uncalibrated.**
    public static let restartAttempts = 5

    /// The wait before each rebuild. Five attempts two seconds apart span ten
    /// seconds of absence, and a daemon restart costs one gap of two seconds.
    /// **Uncalibrated.**
    public static let restartDelay = Duration.seconds(2)
}
