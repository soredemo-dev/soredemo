import Foundation
import ScreenCaptureKit

/// The last few seconds, kept in case somebody wants them.
///
/// **The one recording you cannot get by pressing record**, because the thing has already
/// happened: an app misdrew, a crash flashed a dialog, a gesture did the wrong thing. Pressing
/// record afterwards captures the aftermath. `SCClipBufferingOutput` — macOS 27 — keeps a
/// rolling buffer on a live stream and writes the most recent stretch of it to a file on
/// demand, without interrupting the buffering.
///
/// **Fifteen seconds, and that is the system's ceiling rather than a choice made here.** It is
/// short for a demo and about right for a repro, which is the case this is for.
///
/// **macOS 26 is still supported.** This whole type is gated: on 26 `isAvailable` is false, the
/// control that offers it is absent, and nothing else in the app changes. A feature that
/// required raising the floor would cost every person on the older system a working recorder
/// to give some people a convenience.
@available(macOS 27.0, *)
public final class ClipBuffer: NSObject, @unchecked Sendable {

    /// Why a clip was not written. **A named value, never `nil`** — "no clip" and "the disk is
    /// full" send a person to different places.
    public enum Refusal: Equatable, Sendable {
        /// Buffering was never started, so there is nothing behind the moment.
        case nothingHasBeenBuffered
        /// The stream refused the output. Carries what it said.
        case theStreamRefusedIt(String)
        /// The export itself failed. Carries what the system reported.
        case theSystemCouldNotWriteIt(String)
        /// Asked for a length this cannot deliver. Carries the ceiling, so the caller can say it.
        case longerThanTheBuffer(ceilingSeconds: Double)
    }

    public enum Outcome: Equatable, Sendable {
        case wrote(URL)
        case refused(Refusal)
    }

    /// The most a clip may be, set by `SCClipBufferingOutput` and not by this project.
    public static let ceilingSeconds: Double = 15

    /// Whether this system has the API at all. **Read through the type rather than by version
    /// number at every call site**, so the answer is in one place.
    public static var isAvailable: Bool { true }

    private let lock = NSLock()
    private var output: SCClipBufferingOutput?
    /// Whether the system has told us buffering is actually running. **Not "we asked for it"**:
    /// `didStartBuffering` is the only thing that says samples are being kept, and offering a
    /// Save Clip button before that is offering an empty file.
    private var buffering = false
    private var failure: String?

    public override init() { super.init() }

    /// Whether a clip could be written right now.
    public var isBuffering: Bool { lock.withLock { buffering } }

    /// Attaches to a live stream and starts keeping samples.
    ///
    /// Idempotent: attaching twice would keep two buffers of the same stream, which is twice the
    /// memory for the same fifteen seconds.
    public func attach(to stream: SCStream) -> Refusal? {
        let existing = lock.withLock { output }
        if existing != nil { return nil }
        let created = SCClipBufferingOutput(delegate: self)
        do {
            try stream.addClipBufferingOutput(created)
        } catch {
            return .theStreamRefusedIt(String(describing: error))
        }
        lock.withLock { output = created }
        return nil
    }

    /// Stops keeping samples and releases the buffer.
    ///
    /// **Called when the recording stops**, because a buffer nobody can export from is fifteen
    /// seconds of frames held for nothing.
    public func detach(from stream: SCStream) {
        let existing = lock.withLock { () -> SCClipBufferingOutput? in
            let value = output
            output = nil
            buffering = false
            return value
        }
        guard let existing else { return }
        try? stream.removeClipBufferingOutput(existing)
    }

    /// Writes the most recent `seconds` to `url`.
    ///
    /// **The buffering keeps running.** That is the system's guarantee and it is the one that
    /// matters: somebody who saves a clip because something went wrong is often about to save
    /// a second one.
    public func save(lastSeconds seconds: Double, to url: URL) async -> Outcome {
        guard seconds <= Self.ceilingSeconds else {
            return .refused(.longerThanTheBuffer(ceilingSeconds: Self.ceilingSeconds))
        }
        let (existing, started, reported) = lock.withLock { (output, buffering, failure) }
        if let reported { return .refused(.theSystemCouldNotWriteIt(reported)) }
        guard let existing, started else { return .refused(.nothingHasBeenBuffered) }

        return await withCheckedContinuation { continuation in
            existing.exportClip(to: url, duration: seconds) { error in
                if let error {
                    continuation.resume(returning:
                        .refused(.theSystemCouldNotWriteIt(String(describing: error))))
                } else {
                    continuation.resume(returning: .wrote(url))
                }
            }
        }
    }
}

@available(macOS 27.0, *)
extension ClipBuffer: SCClipBufferingOutputDelegate {
    public func clipBufferingOutputDidStartBuffering(_ clipBufferingOutput: SCClipBufferingOutput) {
        lock.withLock { buffering = true; failure = nil }
    }

    public func clipBufferingOutput(_ clipBufferingOutput: SCClipBufferingOutput,
                                    didFailWithError error: any Error) {
        // **Kept rather than logged.** The next `save` can then say what went wrong instead of
        // reporting an empty buffer, which is a fact about the READ dressed as a fact about the
        // recording — the shape this project keeps finding.
        lock.withLock { buffering = false; failure = String(describing: error) }
    }
}
