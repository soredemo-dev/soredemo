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
