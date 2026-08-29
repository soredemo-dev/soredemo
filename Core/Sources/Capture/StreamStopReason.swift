import Foundation
import ScreenCaptureKit

/// Why ScreenCaptureKit stopped a running stream, and whether opening a new one
/// is worth trying.
///
/// `SCStream` reports every stop through the same delegate callback: the user
/// pressing the system's own stop control, the display going to sleep, and a
/// missing entitlement all arrive as `didStopWithError`. Treating them alike
/// costs a recording — a lid closed for ten seconds ends a forty-minute session
/// — so the code is read and named here before anything acts on it.
///
/// The verdict is a value, never `nil`: an error this type cannot place still
/// gets a case that says so, carrying the domain and code that were actually
/// seen. A restart decision made from an unrecognised error is a decision made
/// from nothing, and `.unrecognised` refuses on purpose rather than guessing.
public enum StreamStopReason: Sendable, Equatable {
    /// `SCStreamErrorUserStopped` (-3817). The person clicked stop in the
    /// system's capture control. Reopening the stream would fight them.
    case theUserStoppedIt

    /// `SCStreamErrorSystemStoppedStream` (-3821). macOS took the display away
    /// — a closed lid, a sleeping display, a fast user switch. The display comes
    /// back and so can the stream.
    case theSystemTookTheDisplayAway

    /// `SCStreamErrorFailedApplicationConnectionInvalid` (-3804) or
    /// `…Interrupted` (-3805). The connection to the capture daemon died rather
    /// than the capture itself failing. A new stream gets a new connection.
    case theConnectionToTheCaptureDaemonDied(code: Int)

    /// A ScreenCaptureKit error that says something about this recording's
    /// setup, not about a passing condition: a declined or missing permission,
    /// an entitlement, an invalid parameter, a source that no longer exists.
    /// Rebuilding the same stream reproduces it.
    case itWillFailTheSameWayAgain(code: Int)

    /// Not `SCStreamErrorDomain` at all. Named rather than folded into the case
    /// above, because "some other subsystem failed" is a different fact from
    /// "ScreenCaptureKit refused", and only one of them is documented here.
    case unrecognised(domain: String, code: Int)

    /// Codes that name a connection to the capture daemon rather than a fault in
    /// the capture. Listed here so the two members of the pair are visibly the
    /// same decision.
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
        case let code:
            self = .itWillFailTheSameWayAgain(code: code)
        }
    }

    /// Whether a fresh stream over the same source is worth opening.
    ///
    /// `SCStreamErrorInternalError` (-3811) is deliberately NOT here even though
    /// it is sometimes transient: its documented meaning is "video/audio capture
    /// failure", which covers faults a restart reproduces immediately, and a
    /// restart loop over a reproducing fault burns the whole budget in the time
    /// it takes to fail three times. It is left in `.itWillFailTheSameWayAgain`
    /// until a real recording is seen recovering from it.
    public var isWorthRestarting: Bool {
        switch self {
        case .theSystemTookTheDisplayAway, .theConnectionToTheCaptureDaemonDied:
            return true
        case .theUserStoppedIt, .itWillFailTheSameWayAgain, .unrecognised:
            return false
        }
    }

    /// What goes in the segment boundary, and into a support log. Deliberately
    /// includes the raw code: the name is this project's reading of the code,
    /// and a reader who disagrees needs the number to check it against.
    public var description: String {
        switch self {
        case .theUserStoppedIt:
            return "the user stopped the capture (SCStreamErrorUserStopped, -3817)"
        case .theSystemTookTheDisplayAway:
            return "the system stopped the stream (SCStreamErrorSystemStoppedStream, -3821)"
        case .theConnectionToTheCaptureDaemonDied(let code):
            return "the capture daemon connection died (SCStreamErrorDomain, \(code))"
        case .itWillFailTheSameWayAgain(let code):
            return "ScreenCaptureKit refused and will refuse again (SCStreamErrorDomain, \(code))"
        case .unrecognised(let domain, let code):
            return "an error outside ScreenCaptureKit (\(Self.identifierOnly(domain)), \(code))"
        }
    }

    /// A domain, or a refusal naming its length — never the domain's own text
    /// when that text is not an identifier.
    ///
    /// `description` is the only part of this type that reaches disk, through
    /// `SegmentBoundary.interrupted` and into `project.json`. Every other case
    /// puts a closed vocabulary there, and that closure is why the boundary is
    /// adjudicated as carrying no user data. `.unrecognised` is the one case
    /// holding a string this project did not write: `NSError.domain`, chosen by
    /// whichever subsystem raised the error.
    ///
    /// Every domain Apple ships is a reverse-DNS identifier —
    /// `NSPOSIXErrorDomain`, `com.apple.ScreenCaptureKit.SCStreamErrorDomain` —
    /// so this rule costs nothing on any error actually expected here. It exists
    /// for the one that is not expected: a domain built from a path or a message
    /// would otherwise put a home directory in a saved project. The cost is
    /// stated rather than hidden — the refusal says how long the withheld value
    /// was, so a support log still distinguishes "empty domain" from "a domain
    /// too strange to repeat".
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

    /// How many times a stream is rebuilt before a restartable stop is treated as
    /// a stopped recording.
    ///
    /// Five, not three: each attempt is a whole stream rebuild against a source
    /// that has just been disturbed, and the first attempt after a display wakes
    /// is the one most likely to lose a race with the window server. Five failed
    /// rebuilds in a row is no longer a race.
    public static let restartAttempts = 5

    /// The wait before each rebuild.
    ///
    /// A closed lid is not open again in a hundred milliseconds, and a rebuild
    /// attempted into a display that has not returned is an attempt spent for
    /// nothing. Two seconds is long enough that five attempts span ten seconds
    /// of absence, and short enough that a daemon restart — which is over almost
    /// at once — costs the recording only one gap of that length.
    public static let restartDelay = Duration.seconds(2)
}
