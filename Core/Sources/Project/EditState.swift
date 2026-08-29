import Foundation
import Timeline

/// Everything a person decided about a recording, as one value.
///
/// **Only authored values live here** — not the framing plan, not the derived zoom
/// blocks, not the pointer track, which are read from the observation log every
/// time. The producer-value rule made into a file format.
///
/// **Every field is absence-tolerant**, so the format grows without a migration
/// per field and absent means off. `ProjectSnapshot.schemaVersion` still moves when
/// an existing key changes MEANING. See
/// `docs/design/what-a-project-file-remembers.md`.
public struct EditState: Codable, Sendable, Equatable {
    /// What survives cutting. Absent means the whole recording.
    public var timeline: EditTimeline?
    /// Per-source levels and mutes. Absent means the recording as captured.
    public var audioMix: AudioMix
    /// Which zooms were moved, resized or turned off. Keyed on the click, so they still apply
    /// after the plan is re-derived on open — see `ZoomAdjustment`.
    public var zoomAdjustmentData: Data?
    /// Reviewer decisions about which clicks frame what. Same reasoning as the adjustments;
    /// carried as encoded bytes for the reason `zoomAdjustmentData` gives.
    public var framingOverrideData: Data?
    /// The stage's look, as encoded bytes.
    public var styleData: Data?
    /// The output shape's name — `AspectVariant`'s, resolved on open rather than stored as
    /// dimensions, so a project made before a shape was retuned gets the current one.
    public var outputShapeName: String?
    /// The caption track, as encoded bytes for the reason `zoomAdjustmentData` gives.
    ///
    /// **The one derived value this format stores, deliberately.** Transcription is
    /// neither cheap nor stable, and re-deriving on open would apply a person's text
    /// corrections to text that had changed underneath them.
    public var captionTrackData: Data?
    /// How a burnt-in caption looks, as encoded bytes. Authored.
    public var captionStyleData: Data?
    /// Whether captions are drawn into the picture. Absent means not.
    public var burnsInCaptions: Bool?
    /// Titles and notes drawn over the picture, as encoded bytes. Authored in full — unlike the
    /// caption track above, there is nothing here a recogniser produced.
    public var textTrackData: Data?
    /// Parts of the recording to hide, as encoded bytes. Authored.
    public var redactionTrackData: Data?
    /// Arrows, lines, boxes and ellipses drawn over the recording, as encoded bytes. Authored in
    /// full: nothing here was derived from anything, so there is no producer for a re-derivation
    /// to disagree with — unlike the framing overrides above, which sit beside a gate's opinion.
    ///
    /// `Data` for the reason the block below gives: `AnnotationTrack` lives in `Overlays` and
    /// `Project` depends on neither `Overlays` nor `Render`.
    public var annotationTrackData: Data?
    /// How the drawn cursor looks, as encoded bytes. Authored.
    public var cursorStyleData: Data?
    /// Where the camera sits on the stage, as encoded bytes. Authored. Absent for a recording
    /// with no camera — the placement of a track that does not exist is not a decision anyone
    /// made.
    public var cameraStyleData: Data?
    /// The part of the recording used at all, as encoded bytes. Authored. Absent means the whole
    /// recording, which is what an uncropped project has always meant.
    public var cropData: Data?
    /// Whether pressed shortcuts are NOT drawn as badges. Absent means they are — the default
    /// since the badges landed (2026-08-25) — so only turning them off is a decision to keep.
    public var hidesKeystrokes: Bool?
    /// The music bed under the recording, as encoded bytes. Authored. Absent means none — a
    /// project with no music has nothing to say about it.
    public var musicData: Data?
    /// How much of the derived zoom to use, over the whole recording. Authored. **Absent means
    /// neutral** — a project nobody dialled has nothing to say about it, and writing 1 would
    /// make every untouched project claim a decision.
    public var zoomIntensity: Double?
    /// Noise removal on the microphone track — an encoded `NoiseReduction.Settings`.
    /// Authored. `Data?` because the settings type lives in `Overlays`, which
    /// `Project` cannot see. **Absent means off.**
    public var noiseReductionData: Data?

    public init(timeline: EditTimeline? = nil,
                audioMix: AudioMix = .unchanged,
                zoomAdjustmentData: Data? = nil,
                framingOverrideData: Data? = nil,
                styleData: Data? = nil,
                outputShapeName: String? = nil,
                captionTrackData: Data? = nil,
                captionStyleData: Data? = nil,
                burnsInCaptions: Bool? = nil,
                textTrackData: Data? = nil,
                redactionTrackData: Data? = nil,
                annotationTrackData: Data? = nil,
                cursorStyleData: Data? = nil,
                cameraStyleData: Data? = nil,
                cropData: Data? = nil,
                hidesKeystrokes: Bool? = nil,
                musicData: Data? = nil,
                zoomIntensity: Double? = nil,
                noiseReductionData: Data? = nil) {
        self.timeline = timeline
        self.audioMix = audioMix
        self.zoomAdjustmentData = zoomAdjustmentData
        self.framingOverrideData = framingOverrideData
        self.styleData = styleData
        self.outputShapeName = outputShapeName
        self.captionTrackData = captionTrackData
        self.captionStyleData = captionStyleData
        self.burnsInCaptions = burnsInCaptions
        self.textTrackData = textTrackData
        self.redactionTrackData = redactionTrackData
        self.annotationTrackData = annotationTrackData
        self.cursorStyleData = cursorStyleData
        self.cameraStyleData = cameraStyleData
        self.cropData = cropData
        self.hidesKeystrokes = hidesKeystrokes
        self.musicData = musicData
        self.zoomIntensity = zoomIntensity
        self.noiseReductionData = noiseReductionData
    }

    /// A recording nobody has edited.
    public static let untouched = EditState()

    /// **True when opening this project would change what the recording looks like.** What a
    /// dirty-state check compares against, and what decides whether closing needs to ask.
    public var changesAnything: Bool {
        timeline != nil || audioMix.changesAnything
            || zoomAdjustmentData != nil || framingOverrideData != nil
            || styleData != nil || outputShapeName != nil
            || captionTrackData != nil || captionStyleData != nil
            // `false` is not a change: it is the default, and a project that only ever had
            // captions turned off has nothing to save.
            || burnsInCaptions == true || textTrackData != nil || redactionTrackData != nil || annotationTrackData != nil || cursorStyleData != nil || cameraStyleData != nil || cropData != nil
            || hidesKeystrokes == true || musicData != nil
            // Neutral is not a change, the same way `burnsInCaptions == false` is not: a
            // person who moved the dial and moved it back has an untouched project.
            || (zoomIntensity.map { $0 != 1 } ?? false)
            // Present at all IS a change here, unlike `burnsInCaptions` above: absent means off,
            // and the type has no "off" value of its own — turning the feature off removes the
            // field rather than writing a disabled one.
            || noiseReductionData != nil
    }

    // MARK: - the tiers that own these values

    /// Why several fields are `Data` rather than their own types: those types live
    /// in tiers `Project` does not depend on and must not, or a persisted-format
    /// change would require rebuilding the render tier. These two are the seam, so
    /// no caller writes an encoder by hand and gets different bytes.
    /// See `docs/design/what-a-project-file-remembers.md`.
    public static func encoding<Value: Encodable>(_ value: Value) throws -> Data {
        try ProjectSnapshot.makeEncoder().encode(value)
    }

    /// `nil` in, `nil` out — an absent field is "unedited", never an error.
    ///
    /// **A field that fails to decode is an error, though.** A project whose zoom adjustments
    /// are corrupt should say so rather than opening with them silently gone: a person would
    /// re-do the work and save over the file that still had it.
    public static func decoding<Value: Decodable>(_ data: Data?, as type: Value.Type) throws -> Value? {
        guard let data else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
