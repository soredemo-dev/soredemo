import Foundation
import Geometry
import Testing
@testable import Soredemo

// Where the editor's opening animation starts and ends, checked on every Mac shape rather than
// on the one it was designed on.
//
// **The design's first draft was one machine's numbers.** A 14-inch MacBook Pro at 1512 x 982,
// notch 185 x 32, full screen 949, "one point apart" — all true, none of it a property of "the
// notch". That panel alone offers eleven scaled modes between 960 x 600 and 1800 x 1169 points,
// and the notch is a fixed number of pixels, so its size in points moves with every one of them.
// macOS also offers each mode twice, with and without the notch strip, so a notched MacBook can
// report no notch at all.
//
// What is asserted here is therefore PROPERTIES — the shape starts inside its screen, ends on
// the window, never inverts, never has a negative side — across a table of real geometries,
// rather than a golden rectangle from one of them.

/// The point sizes Macs actually report, and the modes this design has to survive.
///
/// The notched rows carry a `safeAreaTop` and auxiliary widths scaled from the measured 14-inch
/// (185 of 1512 wide, 32 tall) by each screen's width, which is how a fixed-pixel notch behaves
/// under a scaled mode. They are plausible rather than measured on that hardware, and the
/// assertions below are written so that being slightly wrong about them cannot make a test pass
/// that should fail: nothing checks a specific width.
private struct Mac {
    let name: String
    let width: Double
    let height: Double
    let safeAreaTop: Double
    let menubarHeight: Double
    let aux: (left: Double, right: Double)?

    var metrics: ScreenMetrics {
        ScreenMetrics(frame: PointRect(x: 0, y: 0, width: width, height: height),
                      safeAreaTop: safeAreaTop, menubarHeight: menubarHeight,
                      auxiliaryLeftWidth: aux?.left, auxiliaryRightWidth: aux?.right)
    }

    /// What a native full-screen window becomes on this screen: the whole width, and the height
    /// less the menu bar.
    var fullScreen: PointRect {
        PointRect(x: 0, y: menubarHeight, width: width, height: height - menubarHeight)
    }
}

/// A notch `fraction` of the screen wide and `top` tall, expressed as the two auxiliary areas.
private func notched(_ name: String, _ width: Double, _ height: Double,
                     top: Double, menubar: Double, fraction: Double = 185.0 / 1512.0) -> Mac {
    let notchWidth = width * fraction
    let side = (width - notchWidth) / 2
    return Mac(name: name, width: width, height: height, safeAreaTop: top,
               menubarHeight: menubar, aux: (side, side))
}

private func plain(_ name: String, _ width: Double, _ height: Double, menubar: Double = 24) -> Mac {
    Mac(name: name, width: width, height: height, safeAreaTop: 0,
        menubarHeight: menubar, aux: nil)
}

private let macs: [Mac] = [
    // Measured on the machine this was designed on.
    notched("MacBook Pro 14 (1512x982)", 1512, 982, top: 32, menubar: 33),
    // Every other scaled mode the same panel offers, notch size following the scale.
    notched("…scaled 960x600", 960, 600, top: 20, menubar: 21),
    notched("…scaled 1147x716", 1147, 716, top: 24, menubar: 25),
    notched("…scaled 1280x800", 1280, 800, top: 27, menubar: 28),
    notched("…scaled 1800x1169", 1800, 1169, top: 38, menubar: 39),
    // Other notched Macs, at their default point sizes.
    notched("MacBook Pro 16 (1728x1117)", 1728, 1117, top: 32, menubar: 33),
    notched("MacBook Air 13 M2 (1470x956)", 1470, 956, top: 32, menubar: 33),
    notched("MacBook Air 15 (1710x1112)", 1710, 1112, top: 32, menubar: 33),
    // The same 14-inch panel in the mode that EXCLUDES the notch strip. A notched Mac that
    // reports no notch — the case a model-name check would get wrong.
    plain("MacBook Pro 14, notch excluded (1512x945)", 1512, 945),
    // No notch at all.
    plain("external 1920x1080", 1920, 1080),
    plain("external 3440x1440 ultrawide", 3440, 1440),
    plain("external 2560x1440", 2560, 1440),
    plain("MacBook Air 2020 (1440x900)", 1440, 900),
]

// MARK: - properties that must hold on every one of them

@Test @MainActor func theShapeStartsInsideItsOwnScreen() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        let start = geometry.start
        #expect(start.x >= mac.metrics.frame.x, "\(mac.name): starts left of the screen")
        #expect(start.x + start.width <= mac.metrics.frame.x + mac.metrics.frame.width + 0.001,
                "\(mac.name): starts wider than the screen")
        #expect(start.y >= mac.metrics.frame.y, "\(mac.name): starts above the screen")
        #expect(start.width > 0 && start.height > 0, "\(mac.name): starts at \(start)")
    }
}

/// **Centred on every screen**, which is the one thing the fallback strip and the real notch
/// have to agree about: the gesture comes out of the middle of the top edge either way.
@Test @MainActor func theShapeStartsCentred() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        let middle = mac.metrics.frame.x + mac.metrics.frame.width / 2
        let startMiddle = geometry.start.x + geometry.start.width / 2
        #expect(abs(startMiddle - middle) < 0.001,
                "\(mac.name): starts at \(startMiddle), screen's middle is \(middle)")
    }
}

/// It ends on the window, whatever the window turned out to be — never on a predicted rectangle.
@Test @MainActor func theShapeEndsOnTheWindowItWasGiven() {
    for mac in macs {
        let odd = PointRect(x: 100, y: 120, width: 800, height: 500)
        #expect(NotchGeometry.opening(into: odd, on: mac.metrics).end == odd,
                "\(mac.name): the end was not the frame it was handed")
    }
}

/// **The growth is downward and outward on every Mac.** A screen where the notch came out wider
/// than the window, or below it, would play the animation backwards.
@Test @MainActor func theShapeAlwaysGrows() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        #expect(geometry.end.width > geometry.start.width, "\(mac.name): does not widen")
        #expect(geometry.end.height > geometry.start.height, "\(mac.name): does not deepen")
        #expect(geometry.end.y >= geometry.start.y, "\(mac.name): ends above where it started")
    }
}

/// **The one-point gap is this machine's, and the type must not assume it.** Every notched mode
/// here is flush; the test that matters is that a screen where it is NOT flush is still handled,
/// which the next one checks.
@Test @MainActor func aNotchedScreenGrowsStraightOutOfTheNotch() {
    for mac in macs where mac.aux != nil {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        #expect(geometry.isNotch, "\(mac.name): has auxiliary areas but was not treated as notched")
        #expect(geometry.startsFlush,
                "\(mac.name): gap of \(geometry.gap) points between the notch and the window")
    }
}

/// **A menu bar taller than the safe area is not a bug to hide.** If some Mac, or some future
/// release, leaves more room between the notch and a full-screen window, the shape must report
/// it rather than pretend — `startsFlush` is what the animation asks before it decides whether
/// to grow straight out or travel first.
@Test @MainActor func aScreenWithRoomBetweenTheNotchAndTheWindowSaysSo() {
    let roomy = ScreenMetrics(frame: PointRect(x: 0, y: 0, width: 1512, height: 982),
                              safeAreaTop: 32, menubarHeight: 44,
                              auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5)
    let geometry = NotchGeometry.opening(
        into: PointRect(x: 0, y: 44, width: 1512, height: 938), on: roomy)
    #expect(geometry.gap == 12)
    #expect(!geometry.startsFlush, "twelve points of gap was reported as flush")
}

// MARK: - the case a model-name check would get wrong

/// A notched panel in a mode that excludes the notch strip reports no auxiliary areas and no
/// safe-area inset. Asking the SCREEN is what gets this right; asking which Mac it is does not.
@Test @MainActor func aNotchedPanelInANotchlessModeUsesTheFallback() {
    let excluded = plain("1512x945", 1512, 945).metrics
    #expect(!excluded.hasNotch)
    #expect(excluded.notch == nil)
    let geometry = NotchGeometry.opening(into: plain("x", 1512, 945).fullScreen, on: excluded)
    #expect(!geometry.isNotch, "a notchless mode was animated as though it had a notch")
}

/// Auxiliary areas without a safe-area inset is not a notch — it is a screen answering half the
/// question, and half an answer must not produce a zero-height shape.
@Test @MainActor func halfAnAnswerIsNotANotch() {
    let half = ScreenMetrics(frame: PointRect(x: 0, y: 0, width: 1512, height: 982),
                             safeAreaTop: 0, menubarHeight: 33,
                             auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5)
    #expect(!half.hasNotch)
    let geometry = NotchGeometry.opening(into: PointRect(x: 0, y: 33, width: 1512, height: 949),
                                         on: half)
    #expect(!geometry.isNotch)
    #expect(geometry.start.height > 0, "a zero-height shape animates from nothing")
}

/// One auxiliary area and not the other, which is what a screen mid-reconfiguration can report.
@Test @MainActor func oneAuxiliaryAreaIsNotANotch() {
    let partial = ScreenMetrics(frame: PointRect(x: 0, y: 0, width: 1512, height: 982),
                                safeAreaTop: 32, menubarHeight: 33,
                                auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: nil)
    #expect(!partial.hasNotch)
    #expect(partial.notch == nil)
}

/// **The fallback is a fraction of the screen, not a number of points.** Three hundred points is
/// a third of a small external display and a sixth of an ultrawide; the same fraction reads the
/// same on both, which is the whole reason it is not a constant.
@Test @MainActor func theFallbackIsTheSameShareOfEveryScreen() {
    var shares: [Double] = []
    for mac in macs where mac.aux == nil {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        shares.append(geometry.start.width / mac.width)
    }
    #expect(shares.count >= 3)
    #expect(Set(shares.map { ($0 * 10_000).rounded() }).count == 1,
            "the fallback was a different share of different screens: \(shares)")
}

// MARK: - the shape at a moment, over the same matrix

/// **It starts on the notch.** A first frame that was anything else would be the shape
/// appearing rather than the notch becoming something.
@Test @MainActor func theFirstFrameIsTheNotchItself() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        let first = geometry.rect(atProgress: 0)
        #expect(abs(first.x - geometry.start.x) < 0.001, "\(mac.name): \(first)")
        #expect(abs(first.y - geometry.start.y) < 0.001, "\(mac.name): \(first)")
        #expect(abs(first.width - geometry.start.width) < 0.001, "\(mac.name): \(first)")
        #expect(abs(first.height - geometry.start.height) < 0.001, "\(mac.name): \(first)")
    }
}

/// **It ends on the window, exactly.** A last frame short of it hands over with a jump, which
/// is the defect the whole "read the frame from the window" ordering exists to prevent.
@Test @MainActor func theLastFrameIsTheWindow() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        let last = geometry.rect(atProgress: 1)
        #expect(abs(last.x - geometry.end.x) < 0.001, "\(mac.name): \(last)")
        #expect(abs(last.y - geometry.end.y) < 0.001, "\(mac.name): \(last)")
        #expect(abs(last.width - geometry.end.width) < 0.001, "\(mac.name): \(last)")
        #expect(abs(last.height - geometry.end.height) < 0.001, "\(mac.name): \(last)")
    }
}

/// **It only ever gets bigger.** A frame narrower or shorter than the one before would be the
/// shape breathing, which no amount of easing should produce.
@Test @MainActor func itNeverShrinksOnAnyMac() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        var previous = geometry.rect(atProgress: 0)
        for step in 1...60 {
            let next = geometry.rect(atProgress: Double(step) / 60)
            #expect(next.width >= previous.width - 0.001,
                    "\(mac.name) narrowed at \(step): \(previous) -> \(next)")
            #expect(next.height >= previous.height - 0.001,
                    "\(mac.name) shortened at \(step): \(previous) -> \(next)")
            previous = next
        }
    }
}

/// **The bottom edge leads.** It travels far further than the sides — 918 points against 663
/// each on the machine this was designed on — and arriving slightly ahead is what makes the
/// shape read as pulled down rather than inflated from its middle.
@Test @MainActor func theBottomEdgeIsAheadOfTheRestThroughout() {
    for mac in macs {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        let start = geometry.start, end = geometry.end
        var sawALead = false
        for step in 1..<60 {
            let p = Double(step) / 60
            let rect = geometry.rect(atProgress: p)
            let bottomShare = ((rect.y + rect.height) - (start.y + start.height))
                / ((end.y + end.height) - (start.y + start.height))
            let sideShare = (start.x - rect.x) / (start.x - end.x)
            #expect(bottomShare >= sideShare - 0.001,
                    "\(mac.name) at \(p): bottom \(bottomShare) behind sides \(sideShare)")
            if bottomShare > sideShare + 0.01 { sawALead = true }
        }
        #expect(sawALead, "\(mac.name): the bottom never led at all, so the lead does nothing")
    }
}

/// **A screen with room between the notch and the window travels before it grows**, so the
/// shape reads as coming out from behind the notch rather than detaching from it. Every Mac in
/// the matrix is flush, so this is the one case the matrix cannot pose.
@Test @MainActor func aGapIsCoveredBeforeAnythingGrows() {
    let roomy = ScreenMetrics(frame: PointRect(x: 0, y: 0, width: 1512, height: 982),
                              safeAreaTop: 32, menubarHeight: 60,
                              auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5)
    let geometry = NotchGeometry.opening(
        into: PointRect(x: 0, y: 60, width: 1512, height: 922), on: roomy)
    #expect(geometry.gap == 28)
    #expect(geometry.travelShare > 0, "a 28-point gap was treated as flush")
    // Halfway through the travel: still notch-sized, and moved.
    let midTravel = geometry.rect(atProgress: geometry.travelShare / 2)
    #expect(abs(midTravel.width - geometry.start.width) < 0.001, "it grew while travelling")
    #expect(midTravel.y > geometry.start.y, "it did not move while travelling")
    #expect(midTravel.y < geometry.start.y + geometry.gap)
}

/// A flush screen — every notched Mac measured — spends none of the animation travelling.
@Test @MainActor func aFlushScreenTravelsNotAtAll() {
    for mac in macs where mac.aux != nil {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        #expect(geometry.travelShare == 0, "\(mac.name) travels \(geometry.travelShare)")
    }
}

/// **A notch has square top corners and a flare, not rounded ones.** The first version of this
/// held the notch's radius on the top two, and photographed at the first frame that is a
/// rounded-topped pill hanging under the menu bar — attached to nothing. The hardware's sides
/// run straight up and curl outward where they meet the menu bar.
@Test @MainActor func aNotchHasSquareTopCornersAndAFlare() {
    let mac = macs[0]
    let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
    #expect(geometry.isNotch)
    #expect(geometry.topRadius(atProgress: 0) == 0)
    #expect(geometry.topRadius(atProgress: 1) == 0)
    #expect(geometry.topFlare(atProgress: 0) > 0, "there is no curl at all")
    #expect(geometry.bottomRadius(atProgress: 0) == geometry.startRadius)
    #expect(geometry.bottomRadius(atProgress: 1) == 0)
}

/// **The flare closes faster than the shape grows, and is gone at the end.** A full-screen
/// rectangle with two wedges at the top is not a shape anything has.
@Test @MainActor func theFlareIsGoneBeforeTheShapeLands() {
    let mac = macs[0]
    let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
    #expect(geometry.topFlare(atProgress: 1) == 0)
    // Squared, so it is a quarter of the way at halfway rather than half.
    let start = geometry.topFlare(atProgress: 0)
    #expect(abs(geometry.topFlare(atProgress: 0.5) - start * 0.25) < 0.001)
    var previous = start
    for step in 1...20 {
        let next = geometry.topFlare(atProgress: Double(step) / 20)
        #expect(next <= previous + 0.001, "the flare grew at \(step)")
        previous = next
    }
}

/// **No notch, no flare.** There is no hardware shape to echo on an external display, and two
/// wedges over the menu bar of a screen that has none would be an invention.
@Test @MainActor func aScreenWithNoNotchGetsNoFlare() {
    for mac in macs where mac.aux == nil {
        let geometry = NotchGeometry.opening(into: mac.fullScreen, on: mac.metrics)
        for step in 0...10 {
            #expect(geometry.topFlare(atProgress: Double(step) / 10) == 0, "\(mac.name)")
        }
    }
}

/// **Where there is no notch there is nothing to stay attached to**, so all four corners are
/// equal at every moment. The same gesture, without a shape to pretend it came out of.
@Test @MainActor func theFallbackIsRoundedEquallyAtEveryMoment() {
    let plainMac = plain("external 1920x1080", 1920, 1080)
    let geometry = NotchGeometry.opening(into: plainMac.fullScreen, on: plainMac.metrics)
    #expect(!geometry.isNotch)
    for step in 0...10 {
        let p = Double(step) / 10
        #expect(geometry.topRadius(atProgress: p) == geometry.bottomRadius(atProgress: p),
                "the fallback's corners differed at \(p)")
    }
}

/// A screen that is not at the origin — every display but the primary one. The shape must be
/// centred on ITS screen, not on the global origin.
@Test @MainActor func aScreenLeftOfThePrimaryOneIsHandled() {
    let left = ScreenMetrics(frame: PointRect(x: -1920, y: -63, width: 1920, height: 1080),
                             safeAreaTop: 0, menubarHeight: 24,
                             auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
    let geometry = NotchGeometry.opening(
        into: PointRect(x: -1920, y: -39, width: 1920, height: 1056), on: left)
    #expect(geometry.start.x > -1920, "the shape started at the screen's left edge")
    #expect(abs((geometry.start.x + geometry.start.width / 2) - (-960)) < 0.001,
            "the shape was centred on the global origin rather than on its own screen")
    #expect(geometry.start.y == -63, "the shape did not start at the top of ITS screen")
}
