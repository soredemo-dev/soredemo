import Testing
@testable import Soredemo

/// The take's elapsed time as every recording surface shows it.
@Suite struct ElapsedTimeTests {
    @Test func underAnHourIsMinutesAndSeconds() {
        #expect(ElapsedTime.text(59.9) == "0:59", "whole seconds, truncated rather than rounded")
        #expect(ElapsedTime.text(754) == "12:34")
    }

    /// No leading `00:` under an hour; an hour field over it.
    @Test func overAnHourGainsAnHourField() {
        #expect(ElapsedTime.text(3661) == "1:01:01")
    }

    /// A clock that ran slow by a tick before it started must not print a minus sign.
    @Test func aNegativeInputIsZero() {
        #expect(ElapsedTime.text(-3) == "0:00")
    }
}
