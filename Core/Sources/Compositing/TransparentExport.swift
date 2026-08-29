import Foundation
import Render

/// **The one pairing in the export that fails silently, made to fail loudly instead.**
///
/// A transparent background is a property of the picture; whether it survives is a property of
/// the codec. Nothing connects the two, and the failure has no symptom at the moment it happens:
/// `AVAssetWriter` accepts a transparent frame for H.264 without a word, encodes the alpha away,
/// and hands back a video with a black rectangle where somebody asked for nothing. They find out
/// when they drop it onto a landing page or into an editor — after the export, after the upload,
/// and with no way to tell it from a bug in the tool they are dropping it into.
///
/// Measured, one codec at a time, by writing a frame that is opaque on one half and fully
/// transparent on the other and reading the alpha back out of the file:
///
///     ProRes 4444        left 255  right   0   ← carries it
///     HEVC with Alpha    left 255  right   0   ← carries it
///     ProRes 422         left 255  right 255   ← silently opaque
///     HEVC               left 255  right 255   ← silently opaque
///
/// Nothing was reported for either of the bottom two. That silence is what this type exists to
/// break.
///
/// **A refusal rather than a substitution.** The tempting alternative is to quietly switch the
/// codec to one that works, and it is wrong for the same reason every silent correction in this
/// project is: somebody who chose H.264 chose it because of where the file is going, and handing
/// them a `.mov` they did not ask for trades one surprise for another. The refusal names both
/// halves of the mismatch, so the person can change whichever one they meant.
public enum TransparentExport {
    /// What the pairing of a background and a codec amounts to.
    ///
    /// **Three cases rather than a `Bool`**, because "this export has no transparency to carry"
    /// and "this export carries it" are both fine and are not the same fact — and a caller that
    /// could not tell them apart could not explain itself to anybody.
    public enum Outcome: Equatable, Sendable {
        /// The background is transparent and the codec keeps it.
        case transparencyIsCarried
        /// The background is not transparent, so there is nothing for the codec to carry. Every
        /// codec is fine here, including the two that could have carried it.
        case nothingToCarry
        /// The background is transparent and the codec would throw it away.
        case refused(Refusal)
    }

    /// Why an export was refused. One case today, named for the thing that is wrong rather than
    /// for the check that caught it.
    public enum Refusal: String, Sendable, Equatable, Hashable {
        /// A transparent background asked of a codec that cannot carry an alpha channel.
        case theCodecCannotCarryTransparency
    }

    /// Whether `codec` can be handed a picture drawn on `background`.
    ///
    /// Pure, and over the two values that actually decide it, so it can be checked without an
    /// asset, a writer or a file. The exporter calls it in the same breath as its edit-timeline
    /// check and for the same reason: both are process-global state that cannot be passed as an
    /// argument, so they are compared instead.
    public static func outcome(background: StageBackground,
                               codec: ExportCodec) -> Outcome {
        guard background == .transparent else { return .nothingToCarry }
        return codec.carriesTransparency
            ? .transparencyIsCarried
            : .refused(.theCodecCannotCarryTransparency)
    }

    /// The codecs to offer somebody who has chosen a transparent background.
    ///
    /// **Ordered cheapest first, which is the opposite of what every article on transparent video
    /// says.** ProRes 4444 is the name everybody knows; measured on sixty frames of 640x360 it is
    /// 14,563,749 bytes against HEVC with Alpha's 135,432 — **107 times larger for the same
    /// picture**. So the one that should be reached for first is listed first, and ProRes 4444
    /// stays on the list because an editor asking for ProRes is asking for ProRes.
    public static let codecsThatCarryIt: [ExportCodec] = [.hevcWithAlpha, .proRes4444]
}
