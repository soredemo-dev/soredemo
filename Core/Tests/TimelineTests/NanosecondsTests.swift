import Testing
import Foundation
@testable import Timeline

// MARK: - Nanoseconds — Comparable, Hashable, Codable

@Test func equalNanosecondsCompareEqual() {
    #expect(Nanoseconds(1_000) == Nanoseconds(1_000))
}

@Test func differentNanosecondsCompareUnequal() {
    #expect(Nanoseconds(1_000) != Nanoseconds(2_000))
}

@Test func nanosecondsOrderingIsComparable() {
    #expect(Nanoseconds(1) < Nanoseconds(2))
    #expect(!(Nanoseconds(2) < Nanoseconds(1)))
    #expect(Nanoseconds(2) > Nanoseconds(1))
    #expect(Nanoseconds(1) <= Nanoseconds(1))
    #expect(Nanoseconds(1) >= Nanoseconds(1))
}

@Test func nanosecondsSortCorrectly() {
    let unsorted: [Nanoseconds] = [Nanoseconds(300), Nanoseconds(100), Nanoseconds(200)]
    #expect(unsorted.sorted() == [Nanoseconds(100), Nanoseconds(200), Nanoseconds(300)])
}

@Test func nanosecondsRoundTripsThroughCodable() throws {
    let n = Nanoseconds(1_234_567_890)
    let decoded = try JSONDecoder().decode(Nanoseconds.self, from: JSONEncoder().encode(n))
    #expect(decoded == n)
}

@Test func nanosecondsExposesRawValue() {
    #expect(Nanoseconds(42).rawValue == 42)
}
