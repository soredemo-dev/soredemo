import Capture
import Foundation

/// Whether the disk has room for a take, before it starts.
///
/// **An estimate, from the master's own arithmetic** (`MasterQuality.videoBitRate`) and the two
/// audio tracks at their widest (float stereo, 48 kHz — what `CaptureSession` asks the system
/// stream for; the microphone is passthrough and usually narrower). The take itself is watched
/// by measurement, in `DiskWatch`, so this only has to be good enough to warn.
///
/// **Twice the bytes**: when a segment ends, its scratch file is copied into the package before
/// the scratch is removed, so for a moment the segment exists twice. A disk that holds one copy
/// and not two loses the take at its very end. See `docs/design/2026-10-22-audit-and-how-to-stand-out.md` R3.
nonisolated enum DiskHeadroom {
    enum Verdict: Equatable {
        case plenty
        case low(minutes: Int)
        /// Not even a minute: refused before the take, because a take that cannot be saved is
        /// worse than one that did not start.
        case tooLittle
    }

    /// Warned below this many minutes.
    static let warningMinutes = 10.0

    static func bytesPerSecond(pixelWidth: Int, pixelHeight: Int, frameRate: Int) -> Double {
        let video = Double(MasterQuality.videoBitRate(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                                      frameRate: frameRate)) / 8
        let audio = 2.0 * 48_000 * 2 * 4
        return video + audio
    }

    static func minutes(available: Int64, bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return .infinity }
        return Double(available) / (2 * bytesPerSecond) / 60
    }

    /// `nil` free space — the volume would not say — is `.plenty`: not knowing is no reason to
    /// stop somebody recording.
    static func verdict(available: Int64?, bytesPerSecond: Double) -> Verdict {
        guard let available else { return .plenty }
        let left = minutes(available: available, bytesPerSecond: bytesPerSecond)
        if left < 1 { return .tooLittle }
        if left < warningMinutes { return .low(minutes: Int(left)) }
        return .plenty
    }

    /// Free space on the volume scratch recordings are written to, or `nil` if it will not say.
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Whether a running take must stop now to be saved — measured, not estimated.
///
/// **The free space falling is the rate**: this app's writer, the camera's file, and anything
/// else writing to the same disk, which no estimate could include. The take is stopped while the
/// disk still holds the segment's copy (everything written since the segment began) and one more
/// minute at the rate it is filling — so the take ends saved rather than failing at the edge.
nonisolated struct DiskWatch: Equatable {
    enum Verdict: Equatable { case fine, stopNow }

    private var segmentStartFree: Int64?
    private var lastFree: Int64?
    /// Bytes a second, smoothed so one other app's burst does not stop a take on its own.
    private var rate = 0.0

    /// A pause or a reconfiguration closed the segment and its copy was made: count again.
    mutating func segmentBegan() {
        segmentStartFree = nil
    }

    mutating func observe(free: Int64?, after seconds: Double) -> Verdict {
        guard let free else { return .fine }
        if segmentStartFree == nil { segmentStartFree = free }
        if let lastFree, seconds > 0 {
            let latest = max(0, Double(lastFree - free) / seconds)
            rate = rate == 0 ? latest : rate * 0.7 + latest * 0.3
        }
        lastFree = free
        let written = Double(max(0, (segmentStartFree ?? free) - free))
        return Double(free) < written + rate * 60 ? .stopNow : .fine
    }
}
