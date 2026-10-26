import Testing
@testable import Soredemo

/// The countdown's daruma flying to where the take is shown: an arc from where it counted to the
/// notch's mark, shrinking to its size, fading as it lands.
/// `docs/design/2026-10-27-the-daruma-tips-flies-and-paints.md`.
@Suite struct CountdownFlightTests {
    // A panel in the middle of a screen and a mark up and to the left — off-centre and off-origin.
    let flight = CountdownFlight(from: (x: 760, y: 520), to: (x: 610, y: 16), endScale: 0.1)

    @Test func itLeavesFromWhereItCountedAndLandsOnTheMark() {
        let start = flight.frame(at: 0), end = flight.frame(at: 1)
        #expect(start.x == 760 && start.y == 520 && start.scale == 1 && start.opacity == 1)
        #expect(abs(end.x - 610) < 1e-9 && abs(end.y - 16) < 1e-9 && abs(end.scale - 0.1) < 1e-9)
        #expect(end.opacity == 0, "gone as the notch's own mark takes over")
    }

    /// A hop, not a slide: mid-flight it is above the straight line between the two places.
    @Test func itHopsOnTheWay() {
        let mid = flight.frame(at: 0.5)
        let lineY = 520 + (16 - 520) * (mid.x - 760) / (610 - 760)
        #expect(mid.y < lineY - 20, "\(mid.y) against the line's \(lineY)")
        #expect(flight.frame(at: 0.5).opacity == 1, "visible until it is nearly there")
    }

    @Test func itsProgressEasesAndStopsAtTheEnd() {
        #expect(CountdownFlight.progress(elapsed: 0) == 0)
        #expect(CountdownFlight.progress(elapsed: CountdownFlight.duration) == 1)
        #expect(CountdownFlight.progress(elapsed: 5) == 1)
        #expect(CountdownFlight.progress(elapsed: CountdownFlight.duration * 0.1) < 0.1, "it eases out of the panel")
    }
}
