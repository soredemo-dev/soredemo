import CoreMedia
import Foundation

/// Audio waiting for a writer input that is momentarily refusing it.
///
/// **Holding rather than dropping is the whole point, and dropping was a real defect.**
/// `AVAssetWriter` reports an input not-ready while it waits for the OTHER inputs to advance
/// past the point being written. Dropping the sample means that input never advances, so the
/// writer's interleaving never gets past it, so it stays not-ready — permanently. Two user
/// recordings measured 23 and 26 seconds of video against 0.07 and 0.08 seconds of audio:
/// about four buffers each, which is the writer's initial allowance before it first needs the
/// others to catch up.
///
/// `../opensource/a Swift recorder` never meets this because it gives each audio source its own
/// `AVAssetWriter` and its own sidecar file — one input per writer has nothing to interleave
/// against. A master with three tracks in one `.mov` is the right container for evidence, and
/// it is what makes holding mandatory rather than optional.
///
/// Its own type rather than two arrays on `CaptureSession`: the rule is "hold, drain oldest
/// first, stop at the first refusal, bound the backlog", and that rule is testable without a
/// capture — which a real not-ready writer cannot be made to reproduce on demand.
// `MasterTrackWriting` is internal, so this is too: widening that protocol to make a
// queue public would export the writer seam for no caller's benefit.
final class HeldAudioQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []
    private var _dropped = 0
    private let limit: Int

    /// `limit` is a count of buffers, not of seconds: ScreenCaptureKit's buffer size is its
    /// own business and a count is what bounds the memory. 400 is roughly eight seconds at the
    /// sizes it delivers — deep enough to ride out a writer that is momentarily behind, and
    /// shallow enough that a stuck one is reported rather than growing until the process dies.
    init(limit: Int = 400) {
        precondition(limit > 0, "a queue that can hold nothing is not a queue")
        self.limit = limit
    }

    var count: Int { lock.withLock { buffers.count } }
    /// Buffers discarded because the queue was full — a writer stuck rather than behind. A real
    /// loss, counted rather than absorbed.
    var dropped: Int { lock.withLock { _dropped } }

    /// **Drops the NEWEST when full, not the oldest.** The held buffers already have their
    /// place in a timeline the writer is partway through; discarding the oldest would leave a
    /// hole in the middle of what has been committed, while discarding the newest truncates
    /// the tail — which is what a stuck writer is going to produce anyway.
    func enqueue(_ buffer: CMSampleBuffer) {
        lock.withLock {
            guard buffers.count < limit else {
                _dropped += 1
                return
            }
            buffers.append(buffer)
        }
    }

    /// Appends as much as `track` will take, oldest first, stopping at the first refusal.
    ///
    /// Stopping matters: an input that has just said no will say no to the next buffer too, and
    /// a loop that kept trying would spin on a real-time callback's thread. The refused buffer
    /// is put back at the head, so nothing is consumed by an attempt that failed.
    @discardableResult
    func drain(into track: any MasterTrackWriting) -> Int {
        var written = 0
        while track.isReadyForMoreMediaData {
            let next = lock.withLock { () -> CMSampleBuffer? in
                buffers.isEmpty ? nil : buffers.removeFirst()
            }
            guard let next else { break }
            guard track.append(next) else {
                lock.withLock { buffers.insert(next, at: 0) }
                break
            }
            written += 1
        }
        return written
    }

    func removeAll() {
        lock.withLock {
            buffers.removeAll()
            _dropped = 0
        }
    }
}
