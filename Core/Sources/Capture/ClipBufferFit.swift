import Foundation

/// Whether this machine can afford the rolling clip buffer at a given load, learned from what it
/// has already measured rather than guessed from a constant.
///
/// **Why it has to be decided before attaching.** `SCClipBufferingOutput` has no configuration —
/// its header offers `initWithDelegate:` and an export, nothing else — so its second encode cannot
/// be made cheaper. Measured 2026-09-22 through the real `CaptureSession` at 3492 x 1964, within
/// one run: 58 fps before it attached, 28-34 while it was attached, 58 again the instant the
/// watchdog dropped it. Attaching and then judging always leaves a stutter somewhere in the video.
///
/// **Why it is learned rather than a threshold.** A Mpixel-per-second ceiling would be this Mac's
/// number, and a Mac two years newer would refuse a buffer it could afford. So the only number
/// stored is one this machine produced: the smallest load at which the watchdog had to drop the
/// buffer. Everything below it is tried; everything at or above it is not, until a recording
/// keeps the buffer at that load and so disproves it.
public struct ClipBufferFit: Sendable, Equatable {
    /// The smallest load, in pixels per second, at which the buffer was dropped — `nil` when
    /// nothing has ever been dropped, which is the fresh-install state.
    public let smallestLoadThatDidNotFit: Int?

    public init(smallestLoadThatDidNotFit: Int?) {
        self.smallestLoadThatDidNotFit = smallestLoadThatDidNotFit
    }

    /// Nothing measured. Every recording tries the buffer, because the feature's value is that
    /// nobody had to decide in advance to want it.
    public static let unmeasured = ClipBufferFit(smallestLoadThatDidNotFit: nil)

    /// Pixels per second: what the master's encode and the clip buffer's encode share.
    public static func load(width: Int, height: Int, frameRate: Int) -> Int {
        max(0, width) * max(0, height) * max(0, frameRate)
    }

    /// Whether a recording at `load` should carry the clip buffer.
    public func attaches(atLoad load: Int) -> Bool {
        guard let limit = smallestLoadThatDidNotFit else { return true }
        return load < limit
    }

    /// What this machine knows after a recording at `load` either dropped the buffer or kept it.
    ///
    /// A drop can only LOWER the threshold. A keep at or above it disproves it and clears it —
    /// otherwise one loaded afternoon would switch the feature off at that size for good.
    public func learning(load: Int, wasDropped: Bool) -> ClipBufferFit {
        if wasDropped {
            return ClipBufferFit(smallestLoadThatDidNotFit:
                                    min(smallestLoadThatDidNotFit ?? load, load))
        }
        guard let limit = smallestLoadThatDidNotFit, load >= limit else { return self }
        return .unmeasured
    }
}
