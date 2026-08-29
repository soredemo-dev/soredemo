import Foundation
import Render

/// Whether a transparent background survives the codec it is handed to.
///
/// The pairing fails silently: `AVAssetWriter` accepts a transparent frame for
/// H.264 without a word and encodes the alpha away. Measured per codec, and the
/// reason this refuses rather than substituting a working one, are in
/// `docs/design/what-a-codec-keeps.md`.
public enum TransparentExport {
    /// What the pairing of a background and a codec amounts to.
    ///
    /// Three cases rather than a `Bool`: "nothing to carry" and "carried" are
    /// both fine and are not the same fact.
    public enum Outcome: Equatable, Sendable {
        /// The background is transparent and the codec keeps it.
        case transparencyIsCarried
        /// The background is not transparent, so there is nothing to carry.
        case nothingToCarry
        /// The background is transparent and the codec would throw it away.
        case refused(Refusal)
    }

    /// Why an export was refused. Named for the thing that is wrong rather than
    /// for the check that caught it.
    public enum Refusal: String, Sendable, Equatable, Hashable {
        case theCodecCannotCarryTransparency
    }

    /// Whether `codec` can be handed a picture drawn on `background`.
    ///
    /// Pure, and over the two values that decide it, so it can be checked
    /// without an asset, a writer or a file.
    public static func outcome(background: StageBackground,
                               codec: ExportCodec) -> Outcome {
        guard background == .transparent else { return .nothingToCarry }
        return codec.carriesTransparency
            ? .transparencyIsCarried
            : .refused(.theCodecCannotCarryTransparency)
    }

    /// The codecs to offer somebody who has chosen a transparent background.
    ///
    /// Cheapest first: measured on sixty frames of 640×360, ProRes 4444 is 107×
    /// the size of HEVC with Alpha for the same picture.
    public static let codecsThatCarryIt: [ExportCodec] = [.hevcWithAlpha, .proRes4444]
}
