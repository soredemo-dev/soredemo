import Foundation

/// One output shape — 16:9, 9:16, 1:1 — as a value rather than a pair of integers passed
/// around.
///
/// **The row this serves says "re-framed against each variant's coverage, not cropped", and
/// the distinction is the whole point.** The cheap way to make a portrait video from a
/// landscape recording is to render 16:9 and cut the sides off, which throws away the part
/// of the screen the demo was happening in about half the time. The honest way is to render
/// at the variant's own dimensions and let the stage re-plan: `StagePlanner` fits and never
/// fills, so nothing is ever cut, and what changes is how much of the frame the recording
/// occupies. `coverage(ofSourceAspect:)` is that number, and it is why the framing gates
/// need re-running per variant rather than being decided once in landscape.
public struct AspectVariant: Hashable, Sendable, Codable {
    public let name: String
    /// Width and height as a ratio in lowest terms. Integers, not a `Double`: 16:9 and 1.778
    /// are the same shape but only one of them can be compared for equality or printed back
    /// as the thing a person chose.
    public let widthRatio: Int
    public let heightRatio: Int

    public init(name: String, widthRatio: Int, heightRatio: Int) {
        precondition(widthRatio > 0 && heightRatio > 0,
                     "a ratio must be positive, got \(widthRatio):\(heightRatio)")
        self.name = name
        self.widthRatio = widthRatio
        self.heightRatio = heightRatio
    }

    /// **Validation on decode, not a `precondition`** (D6 rule 8 / D2-14). The synthesised
    /// `Decodable` assigns stored properties directly and never calls the initialiser above,
    /// so the invariant would hold everywhere except the one path carrying untrusted input.
    /// A `precondition` there is the wrong instrument anyway: it turns a corrupt project file
    /// into a crash instead of an error a caller can report.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let widthRatio = try container.decode(Int.self, forKey: .widthRatio)
        let heightRatio = try container.decode(Int.self, forKey: .heightRatio)
        guard widthRatio > 0, heightRatio > 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "a ratio must be positive, got \(widthRatio):\(heightRatio)"))
        }
        self.name = name
        self.widthRatio = widthRatio
        self.heightRatio = heightRatio
    }

    private enum CodingKeys: String, CodingKey {
        case name, widthRatio, heightRatio
    }

    public var aspect: Double { Double(widthRatio) / Double(heightRatio) }

    /// The three the row names. Ordered landscape, portrait, square — the order a person
    /// reads them in, not alphabetical.
    public static let landscape = AspectVariant(name: "Landscape", widthRatio: 16, heightRatio: 9)
    public static let portrait = AspectVariant(name: "Portrait", widthRatio: 9, heightRatio: 16)
    public static let square = AspectVariant(name: "Square", widthRatio: 1, heightRatio: 1)
    public static let all: [AspectVariant] = [.landscape, .portrait, .square]

    /// The name `matching(width:height:)` gives its variant. A constant because the saved
    /// project stores a shape by NAME (`EditState.outputShapeName`), and restoring one that is
    /// not in `all` means recognising this string and rebuilding it from the recording's size.
    public static let matchRecordingName = "Match Recording"

    /// **The recording's own shape, so the export has no bars.**
    ///
    /// The three presets above are the shapes a person posts to, and none of them is the shape
    /// a Mac records in: a 14-inch display is 3024 × 1964, which is 1.539, against 16:9's
    /// 1.778. `StagePlanner` fits and never crops — that is the whole point of it — so a
    /// laptop recording in a Landscape output is pillarboxed by about 6% of the width on each
    /// side, on top of the padding the style asks for. That is correct behaviour and it is
    /// also, for somebody who just wants their recording back looking like their screen, the
    /// wrong output. This variant is that output.
    ///
    /// **Reduced to lowest terms rather than stored as pixels**, because `widthRatio` and
    /// `heightRatio` are `Int` for a reason this file already gives: 16:9 and 1.778 are the
    /// same shape but only one of them can be compared for equality or printed back as the
    /// thing a person chose. 3024 × 1964 reduces to 756 × 491.
    ///
    /// `nil` for a degenerate size — a caller may be asking before a recording has loaded, and
    /// a variant with a zero side would divide by it in `aspect`.
    public static func matching(width: Int, height: Int) -> AspectVariant? {
        guard width > 0, height > 0 else { return nil }
        let divisor = greatestCommonDivisor(width, height)
        return AspectVariant(name: matchRecordingName,
                             widthRatio: width / divisor, heightRatio: height / divisor)
    }

    /// Euclid's, iteratively. Both arguments are already known positive by the one caller.
    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (larger, smaller) = (max(a, b), min(a, b))
        while smaller > 0 { (larger, smaller) = (smaller, larger % smaller) }
        return max(larger, 1)
    }

    /// **The shapes worth offering for a recording of this size**, with its own first.
    ///
    /// Its own is omitted when it IS one of the presets — a 16:9 display recorded whole gives
    /// a Match Recording that is Landscape under another name, and two entries in a picker
    /// that do the same thing is a choice a person has to work out is not one.
    public static func available(recordingWidth: Int, recordingHeight: Int) -> [AspectVariant] {
        guard let own = matching(width: recordingWidth, height: recordingHeight) else { return all }
        guard !all.contains(where: { abs($0.aspect - own.aspect) < 0.001 }) else { return all }
        return [own] + all
    }

    /// **Even dimensions, inside encoder limits** — the row's other clause, and both halves
    /// are real constraints rather than tidiness.
    ///
    /// H.264 in 4:2:0 subsamples chroma by two in each direction, so an odd width or height
    /// has no defined chroma plane; VideoToolbox either refuses or silently rounds, and a
    /// silent round is how an export ends up one pixel narrower than everything downstream
    /// expects. Rounding is DOWN to even so the result never exceeds the requested edge.
    ///
    /// `maxEdge` defaults to 3840: H.264 High profile at level 5.2 tops out around 4096 wide,
    /// and 4K is the largest edge any platform this targets accepts. A caller asking for more
    /// gets the cap rather than a failure — an export at 3840 is a usable answer and a thrown
    /// error at the last step of a render is not.
    public func dimensions(longestEdge: Int, maxEdge: Int = 3840) -> (width: Int, height: Int) {
        precondition(longestEdge > 0, "longestEdge must be positive, got \(longestEdge)")
        let edge = min(longestEdge, maxEdge)
        let width: Double
        let height: Double
        if aspect >= 1 {
            width = Double(edge)
            height = Double(edge) / aspect
        } else {
            height = Double(edge)
            width = Double(edge) * aspect
        }
        return (width: Self.evenFloor(width, floor: 2), height: Self.evenFloor(height, floor: 2))
    }

    /// **How much of the output the recording occupies, as a fraction of area** — the
    /// "coverage" the row frames its requirement in terms of.
    ///
    /// `StagePlanner` fits the source inside the padded frame and never fills it, so a 16:9
    /// recording in a 9:16 output is a thin strip: about 0.32 of the frame before padding,
    /// against 1.0 in its native shape. That number is not a defect to be cropped away — it
    /// is the reason a framing decision made in landscape cannot be reused in portrait. A
    /// control that reads clearly at 100% coverage is a third of the size at 32%, so the
    /// gates have to be re-run against the variant rather than inherited from it.
    ///
    /// Padding is excluded deliberately: it is a style choice that applies equally to every
    /// variant, and folding it in would make the comparison between two variants depend on
    /// a slider.
    public func coverage(ofSourceAspect sourceAspect: Double) -> Double {
        precondition(sourceAspect > 0, "a source aspect must be positive, got \(sourceAspect)")
        // The card fits, so its scale is limited by whichever dimension binds first.
        let cardWidth = min(1.0, aspect / sourceAspect)
        let cardHeight = cardWidth * (sourceAspect / aspect)
        return cardWidth * min(cardHeight, 1.0)
    }

    /// Largest even integer at or below `value`, never less than `floor`. A 2-pixel floor
    /// rather than 0: a zero-dimension buffer is not an encodable video.
    private static func evenFloor(_ value: Double, floor minimum: Int) -> Int {
        let rounded = Int(value.rounded(.down))
        return max(minimum, rounded - (rounded % 2))
    }
}
