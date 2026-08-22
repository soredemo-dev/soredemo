import Foundation

/// How loud each recorded audio source is in the export.
///
/// **Two sources, named rather than indexed.** A master carries system audio and the
/// microphone as separate tracks, and which is which is decided by the order
/// `LegacyMasterWriter` adds its inputs — video, system audio, microphone. That order is an
/// assumption every consumer of the master makes, and `theMasterAddsItsTracksInAKnownOrder`
/// is what stops it from changing silently. This type is the place a person's decision about
/// those two lives; the mapping from a name to a track index belongs to whoever reads the
/// file, not here.
///
/// **Gain, not "volume".** The value is a linear multiplier applied to the samples, which is
/// what `AVAudioMix` takes; a UI showing it as a percentage or as decibels is converting, and
/// naming the field for the conversion would make the unit ambiguous at the one place it must
/// not be.
public struct AudioMix: Hashable, Sendable, Codable {
    /// Which recorded source a setting applies to.
    public enum Source: String, Hashable, Sendable, Codable, CaseIterable {
        /// What the machine was playing.
        case systemAudio
        /// What the person said.
        case microphone

        public var displayName: String {
            switch self {
            case .systemAudio: "System audio"
            case .microphone: "Microphone"
            }
        }
    }

    /// Linear gain per source, 1 being the recorded level. Absent means 1 — a mix that has
    /// never been touched is the recording.
    public let gains: [Source: Double]
    /// Sources silenced outright. **Separate from a zero gain**, because they answer different
    /// questions: a muted track can be unmuted back to the level it had, and a person who
    /// dragged a slider to zero did not necessarily mean "off".
    public let muted: Set<Source>

    public init(gains: [Source: Double] = [:], muted: Set<Source> = []) {
        // Clamped here rather than at every read: a negative gain inverts the waveform and a
        // caller that produced one has a bug, but the export is not the place to discover it.
        self.gains = gains.mapValues { min(max($0, 0), Self.maximumGain) }
        self.muted = muted
    }

    /// The recording as it was captured.
    public static let unchanged = AudioMix()

    /// **4× is the ceiling.** Past it a recording quiet enough to need the boost is mostly
    /// amplified noise floor, and the honest fix is to record again rather than to keep
    /// turning it up. Uncalibrated; a measurement should move it.
    public static let maximumGain: Double = 4

    /// What the exporter applies: the gain after muting, so a caller has one number to use and
    /// cannot apply the two rules in the wrong order.
    public func effectiveGain(for source: Source) -> Double {
        muted.contains(source) ? 0 : (gains[source] ?? 1)
    }

    public func gain(for source: Source) -> Double { gains[source] ?? 1 }
    public func isMuted(_ source: Source) -> Bool { muted.contains(source) }

    /// `source` set to `gain`. Returns a new mix; nothing here mutates.
    public func setting(_ source: Source, gain: Double) -> AudioMix {
        var updated = gains
        updated[source] = gain
        return AudioMix(gains: updated, muted: muted)
    }

    public func setting(_ source: Source, muted isMuted: Bool) -> AudioMix {
        var updated = muted
        if isMuted { updated.insert(source) } else { updated.remove(source) }
        return AudioMix(gains: gains, muted: updated)
    }

    /// True when the mix would change what the recording sounds like — what a UI uses to
    /// decide whether to offer a reset, and what an exporter uses to skip building a mix at
    /// all.
    public var changesAnything: Bool {
        !muted.isEmpty || gains.contains { $0.value != 1 }
    }

    // MARK: - coding

    /// **A dictionary keyed by an enum does not round-trip through JSON by default** — Swift
    /// encodes it as an array of alternating keys and values, which is legal and unreadable in
    /// a project file a person may open. Encoded as an object keyed by the raw values instead,
    /// and validated on the way back in for the same reason every other type here is (D6 rule
    /// 8): the synthesised decoder would never call the clamping initialiser.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawGains = try container.decodeIfPresent([String: Double].self, forKey: .gains) ?? [:]
        let rawMuted = try container.decodeIfPresent([String].self, forKey: .muted) ?? []

        var gains: [Source: Double] = [:]
        for (key, value) in rawGains {
            guard let source = Source(rawValue: key) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown audio source \"\(key)\""))
            }
            guard value.isFinite, value >= 0 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "gain \(value) for \(key) is not a level"))
            }
            gains[source] = value
        }
        var muted: Set<Source> = []
        for key in rawMuted {
            guard let source = Source(rawValue: key) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown audio source \"\(key)\""))
            }
            muted.insert(source)
        }
        self.init(gains: gains, muted: muted)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: gains.map { ($0.key.rawValue, $0.value) }),
                             forKey: .gains)
        try container.encode(muted.map(\.rawValue).sorted(), forKey: .muted)
    }

    private enum CodingKeys: String, CodingKey { case gains, muted }
}
