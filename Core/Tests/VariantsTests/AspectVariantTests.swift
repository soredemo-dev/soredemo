import Foundation
import Testing
@testable import Variants

/// **The row asks for "16:9, 9:16, 1:1 — re-framed against each variant's coverage, not
/// cropped. Even dimensions inside encoder limits."** Each clause is checked here.
@Suite struct AspectVariantTests {
    @Test func theThreeNamedVariantsHaveTheirStatedShapes() {
        #expect(AspectVariant.landscape.aspect == 16.0 / 9.0)
        #expect(AspectVariant.portrait.aspect == 9.0 / 16.0)
        #expect(AspectVariant.square.aspect == 1.0)
        #expect(AspectVariant.all.count == 3)
    }

    /// **Even, because H.264 in 4:2:0 subsamples chroma by two in each direction.** An odd
    /// edge has no defined chroma plane; VideoToolbox either refuses or silently rounds, and
    /// a silent round is how an export ends up a pixel off from everything downstream.
    @Test func everyDimensionIsEven() {
        for variant in AspectVariant.all {
            for edge in [1080, 1281, 1920, 999, 4001] {
                let size = variant.dimensions(longestEdge: edge)
                #expect(size.width % 2 == 0, "\(variant.name) at \(edge): width \(size.width) is odd")
                #expect(size.height % 2 == 0, "\(variant.name) at \(edge): height \(size.height) is odd")
            }
        }
    }

    /// Rounding is DOWN, so a variant never exceeds the edge it was asked for.
    @Test func noDimensionExceedsTheRequestedEdge() {
        for variant in AspectVariant.all {
            let size = variant.dimensions(longestEdge: 1081)
            #expect(max(size.width, size.height) <= 1081)
        }
    }

    /// Familiar numbers, so a wrong formula is visible rather than merely even.
    @Test func theFamiliarSizesComeOutRight() {
        #expect(AspectVariant.landscape.dimensions(longestEdge: 1920) == (width: 1920, height: 1080))
        #expect(AspectVariant.portrait.dimensions(longestEdge: 1920) == (width: 1080, height: 1920))
        #expect(AspectVariant.square.dimensions(longestEdge: 1080) == (width: 1080, height: 1080))
    }

    /// A caller asking past the cap gets the cap, not a throw. An export at 3840 is a usable
    /// answer; an error at the last step of a render is not.
    @Test func anOversizedRequestIsCappedRatherThanRefused() {
        let size = AspectVariant.landscape.dimensions(longestEdge: 8000)
        #expect(max(size.width, size.height) == 3840)
        #expect(size == (width: 3840, height: 2160))
    }

    // MARK: - coverage

    /// A recording in its own shape fills the frame; the same recording in portrait does not.
    /// **That number is the row's whole argument**: a control legible at full coverage is a
    /// third of the size at 0.32, so a framing decision made in landscape cannot be inherited.
    @Test func coverageFallsWhenTheShapeDisagrees() {
        let sixteenNine = 16.0 / 9.0
        #expect(AspectVariant.landscape.coverage(ofSourceAspect: sixteenNine) == 1.0)

        let inPortrait = AspectVariant.portrait.coverage(ofSourceAspect: sixteenNine)
        #expect(inPortrait > 0.3 && inPortrait < 0.35,
                "a 16:9 recording in a 9:16 frame should cover about a third, got \(inPortrait)")

        let inSquare = AspectVariant.square.coverage(ofSourceAspect: sixteenNine)
        #expect(inSquare > inPortrait && inSquare < 1.0)
    }

    /// Coverage is never above 1: the card FITS, so it cannot overflow the frame. A value
    /// past 1 would mean the planner had started cropping, which is the thing the row forbids.
    @Test func coverageNeverExceedsTheFrame() {
        for variant in AspectVariant.all {
            for sourceAspect in [0.5, 1.0, 4.0 / 3.0, 16.0 / 9.0, 21.0 / 9.0, 3.0] {
                let coverage = variant.coverage(ofSourceAspect: sourceAspect)
                #expect(coverage > 0 && coverage <= 1.0,
                        "\(variant.name) at aspect \(sourceAspect) covered \(coverage)")
            }
        }
    }

    /// A source and a variant of the same shape cover the frame exactly, whatever the shape.
    @Test func aMatchingShapeAlwaysCoversTheWholeFrame() {
        for variant in AspectVariant.all {
            #expect(abs(variant.coverage(ofSourceAspect: variant.aspect) - 1.0) < 1e-12)
        }
    }

    // MARK: - decoding

    /// D6 rule 8: the synthesised decoder bypasses the initialiser, so a corrupt file has to
    /// be rejected explicitly. A `precondition` there would turn it into a crash.
    @Test func aCorruptRatioIsAnErrorAndNotACrash() throws {
        let json = Data(#"{"name":"Broken","widthRatio":0,"heightRatio":9}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AspectVariant.self, from: json)
        }
    }

    @Test func aValidVariantSurvivesCoding() throws {
        let data = try JSONEncoder().encode(AspectVariant.portrait)
        #expect(try JSONDecoder().decode(AspectVariant.self, from: data) == AspectVariant.portrait)
    }
}
