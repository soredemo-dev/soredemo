import AVFoundation
import Capture
import Observation
import SwiftUI

/// Frames from the recording, drawn along the video track.
///
/// **A flat rectangle tells you a clip exists; a filmstrip tells you what is in it.** Finding the
/// moment a dialog opened means scrubbing until you see it, and scrubbing is the slow way to do
/// a thing the timeline could have shown. Every editor in
/// `../opensource/Screen Record Opensource/` draws thumbnails on its video track;
/// a native editor's `MediaVisualCache` is the shape this follows.
///
/// **Cached on a quantised time, so zooming reuses what is already drawn.** A cache keyed on the
/// exact time a column happens to land on would miss on every pixel of a zoom drag and generate
/// a new frame per redraw — which on a 60 fps drag is a decode per frame per column. Rounding to
/// a step means a small zoom change hits the same buckets.
@MainActor
@Observable
final class Filmstrip {
    /// Ready frames, keyed by `Key`. Published, so a view redraws as they arrive rather than
    /// waiting for the whole strip — a native editor publishes progressively for the same reason.
    private(set) var frames: [Key: CGImage] = [:]

    private var asset: AVAsset?
    private var generator: AVAssetImageGenerator?
    private var inFlight: Set<Key> = []

    /// A frame's identity: which step size it belongs to, and which bucket within it.
    struct Key: Hashable {
        let step: Double
        let bucket: Int

        var seconds: Double { Double(bucket) * step }
    }

    /// The steps a filmstrip may quantise to — powers of two seconds, plus a sub-second tier for
    /// a deeply zoomed strip. A continuous step would defeat the cache entirely.
    static let steps: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128]

    /// The step that puts roughly one frame every `spacing` points at this zoom.
    static func step(visibleSeconds: Double, width: Double, spacing: Double = 72) -> Double {
        guard width > 0 else { return steps[steps.count - 1] }
        let wanted = visibleSeconds * spacing / width
        return steps.first { $0 >= wanted } ?? steps[steps.count - 1]
    }

    /// **At most this many frames are requested for one view of the strip.** Without a cap, a
    /// window scrolled to a two-hour recording at the smallest step would ask for tens of
    /// thousands of decodes; the strip is a few hundred points wide and cannot show them.
    static let maximumPerPass = 40

    /// Ready frames for one step covering `start ..< end`, in time order — what a lane draws.
    func framesIn(step: Double, from start: Double, to end: Double) -> [(Key, CGImage)] {
        frames
            .filter { $0.key.step == step && $0.key.seconds >= start - step && $0.key.seconds < end }
            .sorted { $0.key.bucket < $1.key.bucket }
            .map { ($0.key, $0.value) }
    }

    func load(_ asset: AVAsset) {
        guard self.asset !== asset else { return }
        self.asset = asset
        frames.removeAll()
        inFlight.removeAll()
        let generator = AVAssetImageGenerator(asset: asset)
        // A thumbnail is 40 points tall on screen; 160×90 covers it at 2x with room for a
        // taller lane later, and asking for full frames would decode a 4K image to draw a
        // postage stamp.
        generator.maximumSize = CGGeometryBridge.thumbnailSize(width: 160, height: 90)
        generator.appliesPreferredTrackTransform = true
        // **A whole step of tolerance in each direction.** Exact-time extraction forces a decode
        // from the previous keyframe for every request; a filmstrip does not need the exact
        // frame, it needs a picture of roughly then, and the difference is seconds per strip.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        self.generator = generator
    }

    /// Asks for every bucket covering `start ..< start + visible` that is not already held.
    func request(step: Double, from start: Double, visibleSeconds: Double) {
        guard let generator, step > 0 else { return }
        let firstBucket = Int((start / step).rounded(.down))
        let lastBucket = Int(((start + visibleSeconds) / step).rounded(.up))
        var wanted: [Key] = []
        for bucket in firstBucket...max(firstBucket, lastBucket) where bucket >= 0 {
            let key = Key(step: step, bucket: bucket)
            if frames[key] == nil, !inFlight.contains(key) { wanted.append(key) }
            if wanted.count >= Self.maximumPerPass { break }
        }
        guard !wanted.isEmpty else { return }
        wanted.forEach { inFlight.insert($0) }

        let times = wanted.map { NSValue(time: CMTime(seconds: $0.seconds, preferredTimescale: 600)) }
        let keysBySecond = Dictionary(uniqueKeysWithValues: wanted.map { ($0.bucket, $0) })
        Task { [weak self] in
            for await result in generator.images(for: times.map { $0.timeValue }) {
                guard case .success(let requested, let image, _) = result else { continue }
                let bucket = Int((requested.seconds / step).rounded())
                guard let key = keysBySecond[bucket] else { continue }
                self?.frames[key] = image
                self?.inFlight.remove(key)
            }
            // Whatever did not arrive is released, so a later pass can try again rather than
            // the strip holding a permanent gap.
            for key in wanted { self?.inFlight.remove(key) }
        }
    }
}
