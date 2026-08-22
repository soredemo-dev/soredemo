import CoreGraphics
import Dispatch
import Foundation
import Geometry

/// Watches one window's frame while a recording is running, so a window moved or resized
/// mid-recording does not silently break the capture.
///
/// **What was wrong.** `CaptureSource.window` computes `sourceRect` once, when the segment
/// opens, from `SCWindow.frame`. That value is a snapshot taken when `SCShareableContent`
/// was queried and never updates — ScreenCaptureKit does not push frame changes, and the
/// stream keeps cropping the display at the original rectangle. Move the window and the
/// video shows whatever is now at the old spot; resize it and the video shows a slice.
/// Worse, `InputObserver` normalises the pointer against the same frozen rectangle, so the
/// drawn cursor drifts further off the more the window is moved. `CaptureSource.viewport`
/// even said so in a comment — "the recording is fixed to the rect the segment opened
/// with" — which described the behaviour accurately and called it a design.
///
/// **What the follower cannot fix, and does not pretend to.** The output buffer's
/// dimensions are fixed for the life of a track: D2-13's finding stands, a QuickTime track
/// cannot change dimensions mid-track. So a resize does not change the video's resolution
/// — ScreenCaptureKit scales the new source rect into the existing buffer. Enlarging a
/// window therefore costs sharpness and shrinking one wastes pixels, and an aspect-ratio
/// change letterboxes. All three are visibly better than cropping the wrong region, and
/// none of them is silent: `frameChanges` counts them.
///
/// The live frame comes from `CGWindowListCopyWindowInfo`, not from `SCWindow`, because
/// only the former re-reads. The reader is injected so this is testable without a window.
public final class WindowFollower: @unchecked Sendable {
    /// A window's current frame in **global top-left points** — the space `SCWindow.frame`
    /// and `CGEvent.location` both use. `nil` means the window is gone (closed, or moved to
    /// another Space), which is not the same as "unchanged".
    public typealias FrameReader = @Sendable (CGWindowID) -> PointRect?

    /// The real reader. The CoreGraphics call lives in `CGGeometryBridge.windowBounds` —
    /// two architecture rules put it there rather than here: geometry types are confined to
    /// that file, and the scoped `CGWindowListCopyWindowInfo` shape is an explicit, narrow
    /// exception to a privacy ban that is worth keeping in one auditable place. See the
    /// comment on `windowBounds` for the full argument.
    public static let systemFrameReader: FrameReader = { windowID in
        CGGeometryBridge.windowBounds(windowID)
    }

    /// 100 ms. A window drag is continuous, but the capture only needs to track it closely
    /// enough that the error is never visible for long; ten updates a second is well inside
    /// that and each one costs a `CGWindowListCopyWindowInfo` call, which is not free.
    public static let defaultInterval = DispatchTimeInterval.milliseconds(100)

    /// How much a frame must move before it counts as a change. Half a point: the reader
    /// returns integral device points in practice, so this is really "any change at all",
    /// written as a tolerance so that a fractional value from a scaled display cannot
    /// produce an update every tick.
    public static let tolerance = 0.5

    private let windowID: CGWindowID
    private let interval: DispatchTimeInterval
    private let read: FrameReader
    private let queue: DispatchQueue
    private let lock = NSLock()
    private nonisolated(unsafe) var timer: (any DispatchSourceTimer)?
    private nonisolated(unsafe) var lastFrame: PointRect?
    private nonisolated(unsafe) var _frameChanges = 0
    private nonisolated(unsafe) var _disappearances = 0

    /// How many times the window's frame changed during the recording, and how many ticks
    /// found no window at all. Both belong in the recording's diagnostics: a session with
    /// many changes is one where the scaling tradeoff above was exercised.
    public var frameChanges: Int { lock.withLock { unsafe _frameChanges } }
    public var disappearances: Int { lock.withLock { unsafe _disappearances } }

    public init(windowID: CGWindowID,
                initialFrame: PointRect,
                interval: DispatchTimeInterval = WindowFollower.defaultInterval,
                read: @escaping FrameReader = WindowFollower.systemFrameReader,
                queue: DispatchQueue? = nil) {
        self.windowID = windowID
        self.interval = interval
        self.read = read
        self.queue = queue ?? DispatchQueue(label: "video.soredemo.window-follower",
                                            qos: .userInitiated)
        // `unsafe`: same argument as every other `nonisolated(unsafe)` member here — the
        // write happens in `init`, before the follower is shared with its timer queue, so
        // there is no concurrent access for the lock to protect it from yet.
        unsafe self.lastFrame = initialFrame
    }

    deinit {
        unsafe timer?.cancel()
    }

    /// Starts watching. `onChange` is called on this follower's queue, only when the frame
    /// actually differs from the last one seen — **not** every tick, because every call
    /// reconfigures a live stream.
    ///
    /// A tick that finds no window emits nothing and counts a disappearance. The recording
    /// keeps the last known rectangle rather than jumping somewhere arbitrary; a window
    /// that is really gone is the stream's problem to report, not the follower's to guess.
    public func start(onChange: @escaping @Sendable (PointRect) -> Void) {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard let frame = self.read(self.windowID) else {
                self.lock.withLock { unsafe self._disappearances += 1 }
                return
            }
            let changed = self.lock.withLock { () -> Bool in
                guard let previous = unsafe self.lastFrame else {
                    unsafe self.lastFrame = frame
                    return true
                }
                guard Self.differs(previous, frame) else { return false }
                unsafe self.lastFrame = frame
                unsafe self._frameChanges += 1
                return true
            }
            if changed { onChange(frame) }
        }
        lock.withLock { unsafe timer = source }
        source.resume()
    }

    public func stop() {
        let existing = lock.withLock { () -> (any DispatchSourceTimer)? in
            let value = unsafe timer
            unsafe timer = nil
            return value
        }
        existing?.cancel()
    }

    /// All four edges, not just the origin: a resize anchored at the top-left moves no
    /// corner the origin would notice.
    static func differs(_ a: PointRect, _ b: PointRect) -> Bool {
        abs(a.x - b.x) >= tolerance || abs(a.y - b.y) >= tolerance
            || abs(a.width - b.width) >= tolerance || abs(a.height - b.height) >= tolerance
    }
}
