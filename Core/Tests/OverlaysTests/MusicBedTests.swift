import Testing
import Foundation
import Timeline
@testable import Overlays

// The bed's own model: what travels with the project, and what a corrupt file may not do.

/// A name is joined to a directory by whoever reads it, so one carrying a separator would
/// reach outside the package. Refused by the initialiser AND by the decoder, because the
/// synthesised one would never call the initialiser — the same pairing `StageBackground` has.
@Test func aFilenameThatCouldEscapeThePackageIsRefused() throws {
    #expect(MusicBed(filename: "../../etc/passwd").filename == nil)
    #expect(MusicBed(filename: ".hidden").filename == nil)
    #expect(MusicBed(filename: "").filename == nil)
    #expect(MusicBed(filename: "bed.m4a").filename == "bed.m4a")

    let escaping = Data(#"{"filename":"../elsewhere.mp3"}"#.utf8)
    do {
        _ = try JSONDecoder().decode(MusicBed.self, from: escaping)
        Issue.record("a filename with a separator decoded")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted, got \(error)"); return
        }
    }
}

/// A file and a switch are different facts: switching the bed off keeps the piece and the
/// level it had, which is the same distinction `AudioMix` draws between muted and zero gain.
@Test func aSwitchedOffBedKeepsItsFile() {
    let bed = MusicBed(filename: "bed.m4a").changing(isEnabled: false)
    #expect(bed.filename == "bed.m4a")
    #expect(!bed.isAudible)
    #expect(bed.changing(isEnabled: true).isAudible)
    #expect(!MusicBed.none.isAudible, "a bed with no file cannot be audible")
}

/// It round-trips, and a project that never had music writes nothing about it.
@Test func theBedRoundTripsAndTheDefaultIsQuiet() throws {
    let bed = MusicBed(filename: "loop.wav", isEnabled: true,
                       ducking: MusicDucking.Settings(bedGain: 0.4, duckedGain: 0.1,
                                                      attack: Nanoseconds(120_000_000),
                                                      release: Nanoseconds(700_000_000),
                                                      hold: Nanoseconds(300_000_000)),
                       ducks: true)
    let data = try JSONEncoder().encode(bed)
    #expect(try JSONDecoder().decode(MusicBed.self, from: data) == bed)

    // Every field absent is the default bed, so a file written before a field existed opens.
    let empty = Data("{}".utf8)
    #expect(try JSONDecoder().decode(MusicBed.self, from: empty) == MusicBed.none)
}
