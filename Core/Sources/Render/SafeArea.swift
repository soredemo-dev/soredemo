import Foundation

/// The parts of an exported frame something else is likely to be sitting on.
///
/// **Two different kinds of claim, kept apart because one of them is citable and the other is
/// not.** A guide that mixed them would let a number nobody can check borrow the authority of
/// one everybody can.
public enum SafeArea {
    /// **Action safe: 90% of the frame.** The broadcast convention, and stable — it exists
    /// because a television overscans, and the figure has not moved in decades. Anything outside
    /// it may be cropped by something downstream.
    public static let actionSafeFraction = 0.9

    /// **Title safe: 80%.** The same convention's inner box: text outside it is legible on some
    /// screens and cut on others, which is the case captions care about.
    public static let titleSafeFraction = 0.8

    /// **How much of the bottom of a VERTICAL frame somebody else's interface covers.**
    ///
    /// **Uncalibrated, and it cannot be otherwise.** Every platform puts a different amount of
    /// its own chrome over the bottom of a short video, each changes it without notice, and none
    /// publishes a figure. So this is one number chosen by eye, offered as a guide to look at
    /// rather than a rule to obey — and it is the SAME number `CaptionStyle.presets`' Vertical
    /// entry sits clear of, so the overlay is a way of checking that preset by eye instead of a
    /// second opinion about it.
    public static let verticalChromeFraction = 0.22

    /// Whether a frame of this shape is one that gets platform chrome at the bottom. Taller than
    /// square is the whole of the question: a landscape export is watched in a player, and a
    /// player's controls fade.
    public static func hasPlatformChrome(width: Int, height: Int) -> Bool {
        height > width
    }

    /// The band across the bottom, as a fraction of the frame's height, or `nil` for a shape
    /// nothing covers.
    public static func chromeBand(width: Int, height: Int) -> Double? {
        hasPlatformChrome(width: width, height: height) ? verticalChromeFraction : nil
    }
}
