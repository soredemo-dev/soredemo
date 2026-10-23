import Foundation

/// The speeds and fades a clip can be given, and how a speed is written.
///
/// Read by the toolbar that offers them, the strip that labels a clip with its speed, and the
/// model that names the undo step — **here rather than on the toolbar** so the model does not
/// reach into a view for a string.
enum ClipChoices {
    /// Not a slider: a demo is sped up to a ROUND number a viewer can feel — half, twice — and a
    /// slider invites 1.37×, which is a number nobody chose on purpose.
    static let speeds: [Double] = [0.5, 1, 1.5, 2, 4]

    /// In seconds. **Round numbers rather than a slider**, for `speeds`' reason: a fade is felt,
    /// not measured, and a slider invites 0.37 s — a number nobody chose. Half a second is a
    /// beat, one second is a breath, two is a scene ending.
    static let fades: [Double] = [0, 0.25, 0.5, 1, 2]

    /// `2×`, `0.5×` — trailing zeroes dropped, as the transport's rate label does.
    static func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))\u{00D7}" : String(format: "%.2g\u{00D7}", value)
    }
}
