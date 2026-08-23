import Foundation
import Timeline

/// Everything a person decided about a recording, as one value.
///
/// **Only authored values live here.** Not the framing plan, not the derived zoom blocks, not
/// the pointer track — those are read from the observation log every time and would be a
/// second, staler copy of a fact the recording already carries. What a person cannot get back
/// by re-deriving is what has to be saved: the cuts, the levels, the corrections to the
/// automatic zooms, the look, the shape.
///
/// That split is the producer-value rule made into a file format. A saved project that stored
/// derived values would silently keep an old answer when the derivation improved; one that
/// stored only authored values re-derives on open and applies the same corrections on top.
///
/// **Every field is absence-tolerant.** A project written before a field existed has no such
/// key and opens with that part unedited, which is the one behaviour that lets the format grow
/// without a migration per field. `ProjectSnapshot.schemaVersion` still moves when an existing
/// key changes MEANING — that is what it is for.
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
    /// **The one derived value this format stores, deliberately.** Everything else here is
    /// authored, because deriving is cheap and a stored derived value goes stale when the
    /// derivation improves. Transcription is neither cheap nor stable: it costs a minute of
    /// compute and a several-hundred-megabyte model download, and two model versions do not
    /// agree word for word. Re-deriving on open would apply a person's text corrections to text
    /// that had changed underneath them — so the corrected text is what is saved, corrections
    /// included, and there is nothing left to reconcile.
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
    /// How the drawn cursor looks, as encoded bytes. Authored.
    public var cursorStyleData: Data?
    /// Where the camera sits on the stage, as encoded bytes. Authored. Absent for a recording
    /// with no camera — the placement of a track that does not exist is not a decision anyone
    /// made.
    public var cameraStyleData: Data?

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
                cursorStyleData: Data? = nil,
                cameraStyleData: Data? = nil) {
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
        self.cursorStyleData = cursorStyleData
        self.cameraStyleData = cameraStyleData
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
            || burnsInCaptions == true || textTrackData != nil || redactionTrackData != nil || cursorStyleData != nil || cameraStyleData != nil
    }

    // MARK: - the tiers that own these values

    /// **Why several fields are `Data` rather than their own types.**
    ///
    /// `ZoomAdjustment` lives in `Framing`, `StageStyle` in `Render`, `AspectVariant` in
    /// `Variants`. `Project` depends on none of them and must not: the architecture plugin
    /// enforces the dependency graph, and making the file format depend on every tier that has
    /// something to save would invert it — a persisted-format change would then require
    /// rebuilding the render tier.
    ///
    /// So this holds their encoded bytes and each tier's own type does the decoding. The
    /// format is still one file and still one version; what changes is which tier is allowed
    /// to read which part of it. `encoding(_:)` and `decoding(_:as:)` are the seam, so no
    /// caller writes an encoder by hand and gets different bytes.
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
