import Foundation
import Testing
@testable import Render

/// **The rebuild rule, walked with a `Mirror` so the next field is covered before it is written.**
///
/// `CameraOverlayStyle.changing(...)` and `.placed(at:)` both reconstruct the whole value field by
/// field. A field added to the type and not to those two is silently reset to its default the
/// moment anybody drags a slider: somebody's camera background comes back, or their corner
/// rounding does, with nothing to see and nothing logged. `StageStylePicker.apply` shipped with
/// exactly this defect, and it was found by a scan rather than by anybody using the app.
///
/// So this does not name the fields. It builds a value in which EVERY field differs from the
/// default, rebuilds it, and compares the two through reflection — which means the field somebody
/// adds next month is checked without them remembering to check it.
@Suite("Camera overlay style")
struct CameraOverlayStyleTests {
    /// Every field set away from `CameraOverlayStyle.default`, so a field that is dropped by a
    /// rebuild changes value rather than landing back on the same number by luck.
    static let unusual = CameraOverlayStyle(
        widthFraction: 0.31, x: 0.22, y: 0.71, position: nil, isHidden: true,
        scaleDuringZoom: 0.42, shape: .rounded, cornerFraction: 0.29, isMirrored: false,
        borderOpacity: 0.11, shadowOpacity: 0.13, avoidsCursor: true, background: .removed)

    /// The fields of a style, by name, as reflection sees them.
    static func fields(of style: CameraOverlayStyle) -> [String: String] {
        var found: [String: String] = [:]
        for child in Mirror(reflecting: style).children {
            guard let label = child.label else { continue }
            found[label] = String(describing: child.value)
        }
        return found
    }

    /// The check that would have caught the `background` field being dropped, and that will catch
    /// the next one.
    @Test("every field survives a rebuild that changes nothing")
    func everyCameraStyleFieldSurvivesARebuild() {
        let rebuilt = Self.unusual.changing()
        #expect(Self.fields(of: rebuilt) == Self.fields(of: Self.unusual))
        // A guard on the guard: reflection that saw no fields would pass the line above while
        // checking nothing at all.
        #expect(Self.fields(of: Self.unusual).count >= 13)
    }

    /// `placed(at:)` is allowed to move the camera and to set the preset. It is not allowed to
    /// touch anything else, and it rebuilds every other field by hand to do it.
    @Test("moving to a preset changes where the camera is and nothing else about it")
    func placingAtAPresetCarriesEveryOtherField() {
        let placed = Self.unusual.placed(at: .topLeft)
        let moved = Set(["x", "y", "position"])
        let before = Self.fields(of: Self.unusual).filter { !moved.contains($0.key) }
        let after = Self.fields(of: placed).filter { !moved.contains($0.key) }
        #expect(before == after)
        #expect(placed.position == .topLeft)
    }

    /// **A project written before the background field existed keeps its room.** Reading it as
    /// `.removed` would cut somebody out of a video they have already exported and published.
    @Test("a project written before the background field decodes as keeping the background")
    func anOlderProjectKeepsItsBackground() throws {
        let json = Data("""
        {"widthFraction":0.16,"x":0.87,"y":0.16,"shape":"circle","cornerFraction":0.18,
         "isMirrored":true,"borderOpacity":0.35,"shadowOpacity":0.45}
        """.utf8)
        let decoded = try JSONDecoder().decode(CameraOverlayStyle.self, from: json)
        #expect(decoded.background == .keep)
    }

    @Test("the background survives a round trip")
    func theBackgroundRoundTrips() throws {
        for background in CameraOverlayStyle.Background.allCases {
            let style = Self.unusual.changing(background: background)
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(CameraOverlayStyle.self, from: data)
            #expect(decoded.background == background)
        }
    }

    /// A stored value this build does not know — a downgrade, or a hand-edited project — is
    /// refused rather than read as one of the cases it happens to sort near.
    @Test("a background this build does not know is refused")
    func anUnknownBackgroundIsRefused() {
        let json = Data("""
        {"widthFraction":0.16,"x":0.87,"y":0.16,"shape":"circle","cornerFraction":0.18,
         "isMirrored":true,"borderOpacity":0.35,"shadowOpacity":0.45,
         "background":"replacedWithABeach"}
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CameraOverlayStyle.self, from: json)
        }
    }

    /// Both cases are named for a person, not spelled as their raw values.
    @Test("both backgrounds have a name a person can read")
    func bothBackgroundsAreNamed() {
        for background in CameraOverlayStyle.Background.allCases {
            #expect(!background.displayName.isEmpty)
            #expect(background.displayName != background.rawValue)
        }
    }
}

// MARK: - where the camera can be put

/// **The clamp and the handle have to agree, and they did not.** `rect` keeps the camera
/// `edgeMarginFraction` from every edge; the editor's drag handle clamped its own fraction to
/// 0...1 and had no idea where that margin was, so it accepted travel the camera could not make
/// and the last part of a drag toward an edge did nothing — reported as the camera refusing to
/// move before it had reached the edge. `placementRange` is the one answer both now use.
@Suite struct CameraPlacementRangeTests {
    private let style = CameraOverlayStyle.default
    private let aspect = 16.0 / 9

    /// A centre at either end of the range puts the camera exactly on the margin — asserted
    /// against the function that does the clamping rather than against a number, so the two
    /// cannot drift apart.
    @Test func theEndsOfTheRangeAreExactlyTheMargin() {
        let width = 1920, height = 1080
        let reach = style.placementRange(inOutputWidth: width, outputHeight: height,
                                         sourceAspect: aspect)
        let margin = Double(width) * CameraOverlayStyle.edgeMarginFraction
        let atLeft = style.changing(x: reach.x.lowerBound, y: 0.5)
            .rect(inOutputWidth: width, outputHeight: height, sourceAspect: aspect)
        #expect(abs(atLeft.x - margin) < 0.001,
                "a centre at \(reach.x.lowerBound) put the camera at \(atLeft.x), not \(margin)")
        let atRight = style.changing(x: reach.x.upperBound, y: 0.5)
            .rect(inOutputWidth: width, outputHeight: height, sourceAspect: aspect)
        #expect(abs((Double(width) - atRight.x - atRight.width) - margin) < 0.001,
                "a centre at the top of the range did not land on the right margin")
    }

    /// **Nothing outside the range moves the camera**, which is what makes the handle's clamp
    /// honest: travel it refuses is travel the camera could not have made.
    @Test func pushingPastTheRangeChangesNothing() {
        let width = 1920, height = 1080
        let reach = style.placementRange(inOutputWidth: width, outputHeight: height,
                                         sourceAspect: aspect)
        let atEdge = style.changing(x: reach.x.lowerBound, y: 0.5)
            .rect(inOutputWidth: width, outputHeight: height, sourceAspect: aspect)
        let pastEdge = style.changing(x: 0, y: 0.5)
            .rect(inOutputWidth: width, outputHeight: height, sourceAspect: aspect)
        #expect(abs(atEdge.x - pastEdge.x) < 0.001)
    }

    /// The range is inside the frame on every side, and never inverted — on a portrait output
    /// and a square one as well as the usual landscape.
    @Test func theRangeIsInsideTheFrameAndOrdered() {
        for (width, height) in [(1920, 1080), (3492, 1964), (1080, 1920), (640, 640)] {
            let reach = style.placementRange(inOutputWidth: width, outputHeight: height,
                                             sourceAspect: aspect)
            #expect(reach.x.lowerBound <= reach.x.upperBound, "\(width)x\(height)")
            #expect(reach.y.lowerBound <= reach.y.upperBound, "\(width)x\(height)")
            #expect(reach.x.lowerBound >= 0 && reach.x.upperBound <= 1, "\(width)x\(height)")
            #expect(reach.y.lowerBound >= 0 && reach.y.upperBound <= 1, "\(width)x\(height)")
        }
    }

    /// **A camera that cannot fit between the margins has ONE place it can be**, and the range
    /// says so rather than inverting — `rect` answers that case by centring, and a range that
    /// disagreed would let the handle wander while the picture stood still.
    ///
    /// **On the Y axis, because the X one cannot happen.** `init` clamps `widthFraction` to
    /// 0.6, and 0.6 plus two 0.025 margins is 0.65 of the width — there is always room across.
    /// A very short output is a different matter: the camera's height comes from the source's
    /// aspect and nothing clamps it against the frame. Written after asserting the X case and
    /// watching it fail, which is how the clamp in `init` came into it.
    @Test func aCameraThatCannotFitHasASinglePlace() {
        // The widest a camera is allowed to be, on a very short frame: 0.6 of 400 is 240
        // across, and nothing clamps the height that comes from it against a 100-point frame.
        let reach = style.changing(widthFraction: 0.6)
            .placementRange(inOutputWidth: 400, outputHeight: 100, sourceAspect: aspect)
        #expect(reach.y == 0.5...0.5)
        // And across, where there is always room, it is a real range.
        #expect(reach.x.lowerBound < reach.x.upperBound)
    }

    /// The X axis cannot degenerate, and this says why in a form that would notice if the clamp
    /// in `init` were widened — an assertion whose reachability is stated rather than implied.
    @Test func thereIsAlwaysRoomAcrossTheFrame() {
        let widest = style.changing(widthFraction: 10)
        #expect(widest.widthFraction <= 0.6, "the width clamp moved; the X range can now degenerate")
        let reach = widest.placementRange(inOutputWidth: 400, outputHeight: 400,
                                          sourceAspect: aspect)
        #expect(reach.x.lowerBound < reach.x.upperBound)
    }
}
