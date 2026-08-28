import Foundation
import Testing
@testable import Render

/// A phone or tablet's body drawn around its screen.
///
/// **All arithmetic, which is the point of describing a device as proportions rather than as
/// artwork.** No bundled images means nothing to go stale in September, and every claim here is
/// a number with a known answer.
@Suite struct DeviceFrameTests {
    private func place(_ model: DeviceFrame.Model, aspect: Double,
                       width: Double = 1000, height: Double = 1000)
    -> DeviceFrame.Placement? {
        DeviceFrame.placement(model: model, finish: .graphite,
                              availableWidth: width, availableHeight: height,
                              centreX: width / 2, centreY: height / 2, sourceAspect: aspect)
    }

    // MARK: - the body contains the screen

    /// **The bezel is even on all four sides**, which is what makes it read as hardware. An
    /// uneven one reads as a mistake before anybody works out which side is wrong.
    @Test func theBezelIsTheSameThicknessAllTheWayRound() throws {
        for model in DeviceFrame.Model.allCases {
            for aspect in [0.75, 1.0, 4.0 / 3, 16.0 / 9] {
                let placed = try #require(place(model, aspect: aspect))
                let left = placed.screen.x - placed.body.x
                let right = (placed.body.x + placed.body.width)
                    - (placed.screen.x + placed.screen.width)
                let top = placed.screen.y - placed.body.y
                let bottom = (placed.body.y + placed.body.height)
                    - (placed.screen.y + placed.screen.height)
                // Within a pixel: every edge is snapped to whole output pixels.
                #expect(abs(left - right) <= 1, "\(model) at \(aspect): left \(left), right \(right)")
                #expect(abs(top - bottom) <= 1, "\(model) at \(aspect): top \(top), bottom \(bottom)")
                #expect(abs(left - top) <= 1, "\(model) at \(aspect): sides \(left), ends \(top)")
            }
        }
    }

    /// **The BODY is what is fitted, not the screen.** Fitting the screen and growing a body
    /// around it puts the body outside the space it was given — and on a stage with little
    /// padding, outside the frame.
    @Test func theBodyStaysInsideTheSpaceItWasGiven() throws {
        for model in DeviceFrame.Model.allCases {
            for aspect in [0.5, 0.75, 1.0, 1.5, 2.0] {
                let placed = try #require(place(model, aspect: aspect, width: 800, height: 600))
                #expect(placed.body.x >= -1, "\(model) at \(aspect) starts at \(placed.body.x)")
                #expect(placed.body.y >= -1)
                #expect(placed.body.x + placed.body.width <= 801)
                #expect(placed.body.y + placed.body.height <= 601)
            }
        }
    }

    /// The screen keeps the recording's aspect — a device that stretched the picture to fit its
    /// own body would be worse than no device at all.
    @Test func theScreenKeepsTheRecordingsAspect() throws {
        for aspect in [0.75, 4.0 / 3, 16.0 / 9, 9.0 / 16] {
            let placed = try #require(place(.iPad, aspect: aspect, width: 2000, height: 2000))
            let got = placed.screen.width / placed.screen.height
            #expect(abs(got - aspect) < 0.02, "asked for \(aspect), got \(got)")
        }
    }

    // MARK: - the corners

    /// **The body's radius is the screen's plus the bezel**, which is what a bezel of even
    /// thickness around a rounded screen produces. Anything else reads as a case rather than as
    /// a device.
    @Test func theBodysCornerIsTheScreensPlusTheBezel() throws {
        for model in DeviceFrame.Model.allCases {
            let placed = try #require(place(model, aspect: 0.75, width: 4000, height: 4000))
            let bezel = placed.screen.x - placed.body.x
            let expected = placed.screenCornerRadius + bezel
            #expect(abs(placed.bodyCornerRadius - expected) < 2, """
                \(model): body radius \(placed.bodyCornerRadius) against screen \
                \(placed.screenCornerRadius) plus bezel \(bezel)
                """)
        }
    }

    /// **A phone's corners are far rounder than a tablet's**, and getting that backwards is the
    /// most visible thing this file could get wrong.
    @Test func aPhoneIsRounderThanATablet() throws {
        let phone = try #require(place(.iPhone, aspect: 0.46, width: 2000, height: 2000))
        let tablet = try #require(place(.iPad, aspect: 0.75, width: 2000, height: 2000))
        let phoneRatio = phone.screenCornerRadius / min(phone.screen.width, phone.screen.height)
        let tabletRatio = tablet.screenCornerRadius / min(tablet.screen.width, tablet.screen.height)
        #expect(phoneRatio > tabletRatio * 3, """
            a phone's corner is \(phoneRatio) of its short side against a tablet's \(tabletRatio)
            """)
    }

    /// **Every published radius is well under half the screen's shorter side**, so the clamp in
    /// `placement` is defence rather than a step the arithmetic passes through.
    ///
    /// Said that way because it is what is true. A first version of this test tried to make the
    /// clamp fire — a twelve-to-one screen, a tiny stage — and could not: the radii are fractions
    /// of the SHORT side, and 0.023 and 0.140 are not near 0.5 at any aspect or size. A mutation
    /// removing the clamp left it green, correctly. What can be checked is the property that
    /// makes the clamp unreachable, which is the thing a new model could break.
    @Test func everyModelsRadiusIsWellUnderHalfItsShortSide() {
        for model in DeviceFrame.Model.allCases {
            let metrics = DeviceFrame.metrics(for: model)
            // The screen's short side is 1 unit by definition, so the radius fraction IS the
            // ratio to compare.
            #expect(metrics.screenCornerRadius < 0.5, """
                \(model)'s screen radius is \(metrics.screenCornerRadius) of its short side. \
                At 0.5 a rounded rectangle becomes a stadium, and beyond it undefined.
                """)
            // And the body's, which is larger by the bezel.
            let bodyShortSide = 1 + 2 * metrics.bezel
            #expect(metrics.bodyCornerRadius < bodyShortSide / 2, """
                \(model)'s body radius is \(metrics.bodyCornerRadius) against a short side of \
                \(bodyShortSide)
                """)
        }
    }

    /// And the clamp still holds for a shape the metrics cannot produce, because `placement` is
    /// public and somebody will one day add a model with a rounder screen than any that exists.
    @Test func aRadiusIsNeverMoreThanHalfTheShorterSideWhateverTheMetricsSay() throws {
        for model in DeviceFrame.Model.allCases {
            for aspect in [0.4, 1.0, 3.0, 12.0] {
                let placed = try #require(place(model, aspect: aspect, width: 2000, height: 2000))
                #expect(placed.screenCornerRadius
                        <= min(placed.screen.width, placed.screen.height) / 2 + 0.001)
                #expect(placed.bodyCornerRadius
                        <= min(placed.body.width, placed.body.height) / 2 + 0.001)
            }
        }
    }

    // MARK: - refusals

    /// **A space too small for a body gets none**, and the caller draws the recording plain. A
    /// device three pixels across is not a device.
    @Test func aSpaceTooSmallForABodyIsRefused() {
        #expect(place(.iPhone, aspect: 0.46, width: 6, height: 6) == nil)
        #expect(place(.iPad, aspect: 0.75, width: 0, height: 100) == nil)
        #expect(place(.iPad, aspect: 0.75, width: 100, height: 0) == nil)
    }

    @Test func anImpossibleAspectIsRefusedRatherThanDrawn() {
        #expect(place(.iPad, aspect: 0) == nil)
        #expect(place(.iPad, aspect: -1) == nil)
        #expect(place(.iPad, aspect: .nan) == nil)
        #expect(place(.iPad, aspect: .infinity) == nil)
    }

    // MARK: - the finish

    /// **Two tones, and the top is the lighter one.** A device is lit from above in every product
    /// photograph anybody has seen; a flat fill reads as a rectangle rather than as metal, and an
    /// inverted one reads as a photograph taken upside down.
    @Test func everyFinishIsLitFromAbove() {
        for finish in DeviceFrame.Finish.allCases {
            let top = finish.top, bottom = finish.bottom
            let topLuma = 0.299 * top.r + 0.587 * top.g + 0.114 * top.b
            let bottomLuma = 0.299 * bottom.r + 0.587 * bottom.g + 0.114 * bottom.b
            #expect(topLuma > bottomLuma, "\(finish) is lit from below")
            for channel in [top.r, top.g, top.b, bottom.r, bottom.g, bottom.b] {
                #expect(channel >= 0 && channel <= 1, "\(finish) has a channel at \(channel)")
            }
        }
    }

    @Test func everyFinishAndModelHasAName() {
        for finish in DeviceFrame.Finish.allCases { #expect(!finish.displayName.isEmpty) }
        for model in DeviceFrame.Model.allCases { #expect(!model.displayName.isEmpty) }
        #expect(Set(DeviceFrame.Finish.allCases.map(\.displayName)).count
                == DeviceFrame.Finish.allCases.count)
    }

    /// A saved project names its model and finish; both survive a round trip, and a file written
    /// before either existed decodes without them.
    @Test func aModelAndFinishSurviveARoundTrip() throws {
        for model in DeviceFrame.Model.allCases {
            let round = try JSONDecoder().decode(DeviceFrame.Model.self,
                                                 from: JSONEncoder().encode(model))
            #expect(round == model)
        }
        for finish in DeviceFrame.Finish.allCases {
            let round = try JSONDecoder().decode(DeviceFrame.Finish.self,
                                                 from: JSONEncoder().encode(finish))
            #expect(round == finish)
        }
    }
}

/// **Every field of `StageStyle` survives a change to any other one.**
///
/// The editor rebuilds the whole struct on every slider move, so a field the rebuild does not
/// mention is silently reset — for the person who had set it, and only for them. It was already
/// true of the device frame when it was added: dragging Padding would have removed the body,
/// with nothing to see but a device that vanished.
///
/// Written as a property of `StageStyle` rather than of the editor because it is the type that
/// keeps growing, and this is the test that has to be updated when it does.
@Suite struct StageStyleCompletenessTests {
    private let full = StageStyle(insetFraction: 0.11, cornerRadius: 25, shadowRadius: 30,
                                  shadowOpacity: 0.4,
                                  background: .solid(red: 0.2, green: 0.3, blue: 0.4),
                                  borderOpacity: 0.6,
                                  deviceModel: .iPhone, deviceFinish: .gold)

    /// The rebuild the editor performs, written out. If a field is added to `StageStyle` and not
    /// to this, the test fails — which is the point.
    private func rebuilt(_ style: StageStyle, insetFraction: Double? = nil) -> StageStyle {
        StageStyle(insetFraction: insetFraction ?? style.insetFraction,
                   cornerRadius: style.cornerRadius,
                   shadowRadius: style.shadowRadius,
                   shadowOpacity: style.shadowOpacity,
                   background: style.background,
                   borderOpacity: style.borderOpacity,
                   deviceModel: style.deviceModel,
                   deviceFinish: style.deviceFinish)
    }

    @Test func rebuildingWithOneFieldChangedKeepsEveryOther() {
        let moved = rebuilt(full, insetFraction: 0.2)
        #expect(moved.insetFraction == 0.2)
        #expect(moved.cornerRadius == full.cornerRadius)
        #expect(moved.shadowRadius == full.shadowRadius)
        #expect(moved.shadowOpacity == full.shadowOpacity)
        #expect(moved.background == full.background)
        #expect(moved.borderOpacity == full.borderOpacity)
        #expect(moved.deviceModel == full.deviceModel, """
            the device frame did not survive a change to the padding — the editor rebuilds this \
            struct on every slider move, so a field its rebuild does not mention is reset
            """)
        #expect(moved.deviceFinish == full.deviceFinish)
    }

    /// A rebuild that changes nothing changes nothing — the strongest form of the same claim,
    /// and the one that catches a field dropped rather than merely defaulted.
    @Test func rebuildingWithNothingChangedIsTheSameStyle() {
        #expect(rebuilt(full) == full)
    }

    /// A style with a device round-trips through a project file, and one written before the
    /// device existed opens without it.
    @Test func theDeviceFrameSurvivesTheProjectFile() throws {
        let round = try JSONDecoder().decode(StageStyle.self, from: JSONEncoder().encode(full))
        #expect(round == full)

        var object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(full)) as? [String: Any])
        object.removeValue(forKey: "deviceModel")
        object.removeValue(forKey: "deviceFinish")
        let older = try JSONDecoder().decode(
            StageStyle.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(older.deviceModel == nil)
        #expect(older.cornerRadius == full.cornerRadius, "the fixture decoded as a default")
    }

    /// **A model this build does not know opens as no frame, not as a failure.** A project
    /// written by a later version that has learned about another device must still open.
    @Test func aProjectNamingAnUnknownDeviceStillOpens() throws {
        var object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(full)) as? [String: Any])
        object["deviceModel"] = "visionPro"
        let decoded = try JSONDecoder().decode(
            StageStyle.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.deviceModel == nil)
        #expect(decoded.borderOpacity == full.borderOpacity, "the fixture decoded as a default")
    }
}
