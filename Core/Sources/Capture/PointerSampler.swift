import CoreGraphics
import Dispatch
import Foundation
import Geometry
import Timeline

/// A fixed-cadence tick for reading where the pointer is **right now**, independent of
/// whether the pointer is doing anything.
///
/// **Why this exists at all.** `InputObserver`'s tap is the only source of pointer
/// positions, and a tap is a stream of *events*: `.mouseMoved` fires when the pointer
/// moves and never otherwise. Three consequences, all of them visible in a real recording:
///
/// * a pointer held still emits nothing, so the track has a hole exactly as long as the
///   pause — and `PointerTrack.maxInterpolationGap` then refuses to interpolate across it,
///   which is correct but leaves the render stepping rather than moving;
/// * a tap the system disables for taking too long produces a blind window, and the pointer
///   stops being drawn where it actually is;
/// * the tap delivers on the main run loop, so a busy main thread delays every sample.
///
/// A cadence fixes all three the same way: there is always a sample no older than one
/// interval, whatever the pointer and the tap are doing. `../opensource/a Swift recorder`
/// (Apache 2.0) samples this way rather than from a tap, and its position track is uniform
/// as a result — the approach is theirs, the code below is not.
///
/// **Separate from `InputObserver` on purpose.** A tap observes *discrete* input: clicks,
/// keys, the fact that motion happened. A cadence observes *continuous* state. Those are
/// two responsibilities with two different failure modes, and the tap's — being disabled
/// by the system — is precisely the one the cadence has to survive. Keeping them in one
/// type would let a single teardown path take out both.
///
/// The reader is injected so this is testable without Input Monitoring, and because the
/// same seam lets a caller drive it from a fixture.
public final class PointerSampler: @unchecked Sendable {
    /// Where the pointer is, in **global top-left display coordinates** — the same space
    /// `CGEvent.location` reports, deliberately, so the sample takes exactly the conversion
    /// path a tap sample takes and cannot pick up an offset of its own.
    public typealias LocationReader = @Sendable () -> (x: Double, y: Double)?

    /// The default reader. `CGEvent(source: nil)?.location` is the current pointer position
    /// as CoreGraphics sees it — top-left origin, global across displays. **Not**
    /// `NSEvent.mouseLocation`, which is AppKit (banned in this tier by `HeadlessCheck`)
    /// and bottom-left, and would need a flip that is one more place to get wrong.
    public static let systemLocationReader: LocationReader = {
        guard let event = CGEvent(source: nil) else { return nil }
        let point = CGGeometryBridge.location(from: event.location)
        return (x: point.x, y: point.y)
    }

    /// 60 Hz. Matches the common capture rate, so there is a sample per output frame, and
    /// is well under `PointerTrack.maxInterpolationGap` (50 ms) so the render path's lerp
    /// always has a bracket to work with. Not 120: the tap already supplies fine-grained
    /// motion while the pointer is moving, and the cadence's job is the floor, not the
    /// resolution.
    public static let defaultInterval = Nanoseconds(16_666_667)

    private let interval: Nanoseconds
    private let read: LocationReader
    private let queue: DispatchQueue
    private let lock = NSLock()
    private nonisolated(unsafe) var timer: (any DispatchSourceTimer)?

    public init(interval: Nanoseconds = PointerSampler.defaultInterval,
                read: @escaping LocationReader = PointerSampler.systemLocationReader,
                queue: DispatchQueue? = nil) {
        self.interval = interval
        self.read = read
        // Its own queue by default, not the tap-poll queue: the poll holds its lock across
        // CoreGraphics work, and a cadence that had to queue behind it would not be one.
        self.queue = queue ?? DispatchQueue(label: "video.soredemo.pointer-sampler",
                                            qos: .userInitiated)
    }

    deinit {
        unsafe timer?.cancel()
    }

    /// Starts ticking. `onSample` is called on this sampler's queue with the reading and
    /// the instant it was taken — **not** an instant derived from the timer's schedule,
    /// which drifts.
    ///
    /// A tick whose read returns `nil` emits nothing. That is a pointer CoreGraphics would
    /// not report, not a pointer at the origin.
    public func start(epoch: BootEpoch,
                      onSample: @escaping @Sendable (HostInstant, (x: Double, y: Double)) -> Void) {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .nanoseconds(Int(interval.rawValue)),
                        repeating: .nanoseconds(Int(interval.rawValue)),
                        // A tenth of the interval: the cadence is a floor on sample age,
                        // so letting the system slide ticks by more than that would defeat
                        // the guarantee it exists to make.
                        leeway: .nanoseconds(Int(interval.rawValue / 10)))
        source.setEventHandler { [weak self] in
            guard let self, let location = self.read() else { return }
            onSample(HostInstant(epoch: epoch, hostTime: Minting.hostNow()), location)
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
}
