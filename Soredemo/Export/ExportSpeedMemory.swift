import Compositing
import Foundation

/// How fast this Mac's last export of each kind ran, in pixels per second — what the export
/// sheet prices the next one with (`ExportThroughput`).
///
/// **Per kind**, because H.264 and HEVC share the media engine and ProRes has its own, and a GIF
/// is a different exporter altogether: one rate for all would price a ProRes export at H.264's.
/// **Kept across launches** in the defaults, because the number is a fact about this Mac, and
/// **never seeded**: before the first export there is no rate, and the sheet says so rather than
/// quoting another Mac's.
@MainActor
final class ExportSpeedMemory {
    static let shared = ExportSpeedMemory()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func key(_ codec: String) -> String { "exportPixelsPerSecond.\(codec)" }

    func pixelsPerSecond(for codec: String) -> Double? {
        let stored = defaults.double(forKey: Self.key(codec))
        // `double(forKey:)` answers 0 for a key never written; 0 is not a rate.
        return stored > 0 ? stored : nil
    }

    /// Records a finished export. One that measured nothing leaves the last good rate in place.
    func remember(frames: Int, width: Int, height: Int, seconds: Double, codec: String) {
        guard let rate = ExportThroughput.pixelsPerSecond(frames: frames, width: width, height: height,
                                                          seconds: seconds) else { return }
        defaults.set(rate, forKey: Self.key(codec))
    }
}
