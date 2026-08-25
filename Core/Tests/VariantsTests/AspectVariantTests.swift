import Foundation
import Framing
import Geometry
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

// MARK: - the recording's own shape (the pillarbox a laptop recording always had)

/// **A 14-inch Mac records 3024 × 1964, and none of the three presets is that shape.** Fitted
/// into 16:9 it is pillarboxed by about 6% of the width on each side — correct behaviour from
/// `StagePlanner`, which fits and never crops, and still the wrong output for somebody who
/// wants their recording back looking like their screen. Reduced to lowest terms so the ratio
/// is a shape rather than a pair of pixel counts.
@Test func theRecordingsOwnShapeIsOfferedInLowestTerms() throws {
    let own = try #require(AspectVariant.matching(width: 3024, height: 1964))
    #expect(own.widthRatio == 756 && own.heightRatio == 491, "got \(own.widthRatio):\(own.heightRatio)")
    #expect(abs(own.aspect - 3024.0 / 1964.0) < 1e-12)
    #expect(own.name == AspectVariant.matchRecordingName)

    // And it is the shape that removes the bars: the card fills the frame's width entirely.
    #expect(abs(own.coverage(ofSourceAspect: 3024.0 / 1964.0) - 1.0) < 1e-9)
    let landscapeCoverage = AspectVariant.landscape.coverage(ofSourceAspect: 3024.0 / 1964.0)
    #expect(landscapeCoverage < 0.9, """
        a 1.539 recording covers \(landscapeCoverage) of a 16:9 frame; if that is near 1 the \
        pillarbox this variant exists to remove is not there and this test proves nothing
        """)
}

/// A degenerate size has no shape, rather than one that divides by zero in `aspect`.
@Test func aDegenerateRecordingSizeHasNoMatchingShape() {
    #expect(AspectVariant.matching(width: 0, height: 1080) == nil)
    #expect(AspectVariant.matching(width: 1920, height: 0) == nil)
    #expect(AspectVariant.matching(width: -1920, height: 1080) == nil)
}

/// **A recording that is already one of the presets does not get a second entry.** A 16:9
/// display recorded whole gives a Match Recording that is Landscape under another name, and
/// two picker entries that do the same thing is a choice a person has to work out is not one.
@Test func aRecordingAlreadyInAPresetShapeAddsNothingToThePicker() throws {
    #expect(AspectVariant.available(recordingWidth: 1920, recordingHeight: 1080)
            == AspectVariant.all)
    #expect(AspectVariant.available(recordingWidth: 1080, recordingHeight: 1080)
            == AspectVariant.all)

    let offered = AspectVariant.available(recordingWidth: 3024, recordingHeight: 1964)
    #expect(offered.count == AspectVariant.all.count + 1)
    #expect(offered.first?.name == AspectVariant.matchRecordingName,
            "the recording's own shape is not offered first")
    #expect(Array(offered.dropFirst()) == AspectVariant.all)
}

/// The reduction is a real gcd, not a special case for one screen size.
@Test func theRatioIsReducedByTheGreatestCommonDivisor() throws {
    #expect(AspectVariant.greatestCommonDivisor(3024, 1964) == 4)
    #expect(AspectVariant.greatestCommonDivisor(1920, 1080) == 120)
    #expect(AspectVariant.greatestCommonDivisor(7, 13) == 1)
    let coprime = try #require(AspectVariant.matching(width: 7, height: 13))
    #expect(coprime.widthRatio == 7 && coprime.heightRatio == 13)
}

/// It survives the round trip a saved project puts it through, so a person who chose it gets
/// it back — the picker rebuilds it from the recording, and the name is how it is recognised.
@Test func theMatchingShapeRoundTripsThroughItsName() throws {
    let own = try #require(AspectVariant.matching(width: 3024, height: 1964))
    let data = try JSONEncoder().encode(own)
    #expect(try JSONDecoder().decode(AspectVariant.self, from: data) == own)
    #expect(!AspectVariant.all.contains(own), """
        the matching shape is in `all`, so restoring it would find it there and stop depending \
        on the recording's size — which is the thing that makes it match
        """)
}

// MARK: - the clause the row has been carrying: re-framed, not inherited

/// **`coverage(ofSourceAspect:)` had no production consumer until 2026-08-26, and the
/// row said so.** The number is what the whole "re-framed against each variant's
/// coverage, not cropped" claim rests on, and computing it while nothing read it meant a
/// portrait export inherited landscape's zoom depths unchanged. This is the join: the
/// variant's own coverage, fed to the depth curve, for one real control.
///
/// A 28 px toolbar button on a 1080-tall recording. In landscape it is what it is; in
/// portrait the recording is a strip covering 0.316 of the frame and the button is
/// 0.5625 of the length it had — so it needs a deeper zoom to read the same.
@Test func aPortraitExportReFramesRatherThanInheritingLandscapesDepth() {
    let sixteenNine = 16.0 / 9.0
    let button = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                               size: NormalizedSize(width: 28.0 / 1920, height: 28.0 / 1080),
                               revision: GeometryRevision(id: 1)),
        role: "AXButton")

    let inLandscape = FramingDepth.zoom(
        for: button, coverage: AspectVariant.landscape.coverage(ofSourceAspect: sixteenNine))
    let inPortrait = FramingDepth.zoom(
        for: button, coverage: AspectVariant.portrait.coverage(ofSourceAspect: sixteenNine))
    let inSquare = FramingDepth.zoom(
        for: button, coverage: AspectVariant.square.coverage(ofSourceAspect: sixteenNine))

    #expect(inPortrait > inLandscape, """
            the button got depth \(inPortrait) in portrait against \(inLandscape) in \
            landscape — the variant is still being inherited rather than re-framed
            """)
    // Square loses less of the frame than portrait does, so it sits between them —
    // **inclusively**, and that is worth stating because a strict ordering was the first
    // draft and it was wrong. Two things deliberately collapse neighbouring depths:
    // `quantisationStep` rounds to 0.25 so two similar controls give the camera nothing to
    // animate between, and `maximumZoom` caps the curve. At 28 px both square and portrait
    // are already AT the 3.0 ceiling — the ceiling doing its job, not the coverage failing
    // to arrive.
    #expect(inSquare >= inLandscape && inSquare <= inPortrait,
            "square came out at \(inSquare), outside landscape \(inLandscape) and portrait \(inPortrait)")

    // A control large enough that neither the ceiling nor a quantisation tie can explain
    // the result, so the claim does not rest on a control pinned at the top of the curve.
    let toolbar = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.2, y: 0.4),
                               size: NormalizedSize(width: 500.0 / 1920, height: 60.0 / 1080),
                               revision: GeometryRevision(id: 1)),
        role: "AXToolbar")
    let wideLandscape = FramingDepth.zoom(
        for: toolbar, coverage: AspectVariant.landscape.coverage(ofSourceAspect: sixteenNine))
    let widePortrait = FramingDepth.zoom(
        for: toolbar, coverage: AspectVariant.portrait.coverage(ofSourceAspect: sixteenNine))
    #expect(wideLandscape < FramingDepth.maximumZoom, "this control is meant to sit off the ceiling")
    #expect(widePortrait > wideLandscape,
            "a 500 px toolbar got \(widePortrait) in portrait against \(wideLandscape) in landscape")
}

/// The recording's own shape is the identity, and that is what makes this change safe
/// for every landscape export that already exists: `Match Recording` covers the frame
/// completely, so its depth is the depth the app produced before coverage was a
/// parameter.
@Test func matchRecordingLeavesTheDepthWhereItWas() throws {
    let own = try #require(AspectVariant.matching(width: 3024, height: 1964))
    #expect(abs(own.coverage(ofSourceAspect: 3024.0 / 1964.0) - 1.0) < 1e-12)
    let target = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.3, y: 0.3),
                               size: NormalizedSize(width: 0.05, height: 0.05),
                               revision: GeometryRevision(id: 1)),
        role: nil)
    #expect(FramingDepth.zoom(for: target, coverage: own.coverage(ofSourceAspect: 3024.0 / 1964.0))
            == FramingDepth.zoom(for: target, coverage: 1))
}
