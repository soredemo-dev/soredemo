import Foundation
import Framing
import Geometry
import Project
import Surface
import Testing
import Timeline
@testable import Compositing

// A real `.soredemo` package read for the surface: manifest, join-field log, trailer length.
// The log is deliberately called `segment-03.jsonl` for `master-00.mov`, so a reader that found
// it by naming convention instead of by its header would miss it.

private let epoch = BootEpoch(id: UUID(uuidString: "9AC4A6E0-0000-4000-8000-0000000000C1")!)
private let revision = GeometryRevision(id: 8)
private let second: Int64 = 1_000_000_000
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)

private func at(_ seconds: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(seconds * second)) }

private func line<T: Encodable>(_ record: T) throws -> String {
    String(decoding: try ObservationLog.encode(record), as: UTF8.self)
}

private func element(_ role: String, _ title: String?) -> AXElementRecord {
    AXElementRecord(role: role, title: title,
                    frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                           size: NormalizedSize(width: 0.1, height: 0.05), revision: revision),
                    readInterval: HostRange(epoch: epoch, start: Nanoseconds(1_000), duration: Nanoseconds(500)))
}

private func press(_ seconds: Int64, _ title: String) -> AXChainRecord {
    AXChainRecord(instant: at(seconds), clickPosition: NormalizedPoint(x: 0.45, y: 0.42),
                  clickRevision: revision, hitTestGlobalX: 100, hitTestGlobalY: 200,
                  hitTestInterval: HostRange(epoch: epoch, start: at(seconds).hostTime, duration: Nanoseconds(2_000_000)),
                  hit: element("AXButton", title),
                  ancestors: [element("AXWindow", nil), element("AXApplication", "Keynote")], children: [],
                  truncation: .reachedRoot, axCalls: 5, depthCap: 30, walkBudgetNanos: 35_000_000)
}

/// A package with a twenty-second recording from 100 s, presses at 104 s and 115 s, and — when
/// asked — a saved dismissal and a trailer.
private func makePackage(trailer: Bool = true, log: Bool = true, dismissed: [CutProposal.Key] = []) throws -> URL {
    let fm = FileManager.default
    let package = fm.temporaryDirectory.appending(path: "surface-reader-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
    var snapshot = ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                                   geometries: GeometryRegistry(), mediaFilenames: ["master-00.mov"])
    if !dismissed.isEmpty { snapshot.edit = EditState(dismissedCutData: try EditState.encoding(dismissed)) }
    try ProjectPackageIO.save(snapshot, to: package)
    guard log else { return package }
    let observations = package.appending(path: "observations", directoryHint: .isDirectory)
    try fm.createDirectory(at: observations, withIntermediateDirectories: true)
    var lines = [
        try line(ObservationLogHeader(anchor: anchor, segmentIndex: 0, mediaFilename: "master-00.mov",
                                      revision: revision, blindness: [])),
        try line(press(104, "Export")),
        try line(press(115, "Done")),
    ]
    if trailer {
        lines.append(try line(ObservationLogTrailer(
            segmentIndex: 0, hostRange: HostRange(epoch: epoch, start: Nanoseconds(100 * second), duration: Nanoseconds(20 * second)),
            endedBy: .stopped, recordCounts: ["axChain": 2],
            gapWatches: GapSite.allCases.map { GapWatch(site: $0, looks: 1, watchedSpanNanos: 1, gapsFound: 0, lost: 0) })))
    }
    try (lines.joined(separator: "\n") + "\n").write(to: observations.appending(path: "segment-03.jsonl"),
                                                     atomically: true, encoding: .utf8)
    return package
}

private struct Deaf: Hearing {
    func heard(in project: OpenedProject) async -> Heard { .nothing("test") }
}

@Suite struct PackageProjectReaderTests {
    @Test func theLogIsFoundByItsHeaderAndItsLengthReadFromItsTrailer() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let opened = try PackageProjectReader().open(package.path)
        #expect(opened.mediaFilename == "master-00.mov")
        #expect(opened.log?.url.lastPathComponent == "segment-03.jsonl")
        #expect(opened.log?.anchor == anchor)
        #expect(opened.log?.duration == Nanoseconds(20 * second), "120 s less the anchor's 100 s")
    }

    @Test func aRecordingWithoutALogOpensWithNone() throws {
        let package = try makePackage(log: false)
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(try PackageProjectReader().open(package.path).log == nil)
    }

    /// No trailer is no length, and a made-up one would be a plausible wrong number.
    @Test func aLogWithoutATrailerIsRefusedByName() throws {
        let package = try makePackage(trailer: false)
        defer { try? FileManager.default.removeItem(at: package) }
        #expect {
            try PackageProjectReader().open(package.path)
        } throws: { error in
            (error as? Failure)?.code == .unreadableObservationLog
                && (error as? Failure)?.message.contains("no trailer") == true
        }
    }

    @Test func aSavedDismissalIsReadFromTheManifest() throws {
        let key = CutProposal.Key(reason: .deadAir, quietStart: at(104))
        let package = try makePackage(dismissed: [key])
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(try PackageProjectReader().open(package.path).dismissed == [key])
    }

    /// End to end through the command, on a real package: what a terminal would print.
    @Test func stepsFromARealPackageReachTheTerminal() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let output = await SurfaceCommand.run(["steps", package.path], reader: PackageProjectReader(), hearing: Deaf())
        #expect(output.exitCode == 0)
        #expect(output.stdout == "1\t4.0s–15.0s\tExport\tKeynote\n2\t15.0s–20.0s\tDone\tKeynote\n")
    }

    @Test func aPathThatIsNotAPackageExits66() async {
        let output = await SurfaceCommand.run(["status", "/nonexistent/x.soredemo"], reader: PackageProjectReader(), hearing: Deaf())
        #expect(output.exitCode == 66)
        #expect(output.stderr.hasPrefix("Could not open /nonexistent/x.soredemo"))
    }

    // MARK: - what was heard

    /// Nothing to measure against is nothing heard, said with its reason.
    @Test func aProjectWithoutALogHearsNothing() async throws {
        let package = try makePackage(log: false)
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(await WaveformHearing().heard(in: try PackageProjectReader().open(package.path))
                == .nothing("no observation log"))
    }

    /// The fixture has a log and no media file: the audio cannot be read, and the reason says so
    /// rather than reporting silence — which would propose every narrated pause.
    @Test func mediaThatCannotBeReadIsNothingHeardWithTheReason() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let heard = await WaveformHearing().heard(in: try PackageProjectReader().open(package.path))
        guard case .nothing(let why) = heard else {
            Issue.record("heard \(heard) from a package with no media file")
            return
        }
        #expect(why.hasPrefix("the audio could not be read"))
    }
}
