import CoreMedia
import Foundation
import Framing
import Geometry
import Project
import Render
import Testing
import Timeline
@testable import Compositing

private let epoch = BootEpoch(id: UUID(uuidString: "7A7A7A7A-1B1B-4C4C-8D8D-9E9E9E9E9E9E")!)
private let revision = GeometryRevision(id: 1)
private let second: Int64 = 1_000_000_000

/// One refused click at 3 s — no element under it — so the pointer fallback frames a zoom there,
/// with the pointer resting at the click. Written line by line, for `RecordedContentCropTests`'
/// reason: this is the wire format, not today's writer.
private func writeZoomingLog(at url: URL) throws {
    let header = ObservationLogHeader(
        anchor: EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0),
        segmentIndex: 0, mediaFilename: "master-00.mov", revision: revision, blindness: [])
    var lines: [Data] = [try ObservationLog.encode(header)]
    for tenth in 0..<80 {
        lines.append(try ObservationLog.encode(PointerSample(
            instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(tenth) * second / 10)),
            position: NormalizedPoint(x: 0.3, y: 0.3), revision: revision)))
    }
    let click = 3 * second
    lines.append(try ObservationLog.encode(AXChainRecord(
        instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(click)),
        clickPosition: NormalizedPoint(x: 0.3, y: 0.3), clickRevision: revision,
        hitTestGlobalX: 300, hitTestGlobalY: 300,
        hitTestInterval: HostRange(epoch: epoch, start: Nanoseconds(click), duration: Nanoseconds(100_000)),
        hit: nil, ancestors: [], children: nil,
        truncation: .hitTestReturnedNothing, axCalls: 1, depthCap: 12, walkBudgetNanos: 8_000_000)))
    lines.append(try ObservationLog.encode(ObservationLogTrailer(
        segmentIndex: 0,
        hostRange: HostRange(epoch: epoch, start: Nanoseconds(0), duration: Nanoseconds(8 * second)),
        endedBy: SegmentBoundary.stopped,
        recordCounts: ["pointer": 80, "axChain": 1],
        gapWatches: GapSite.allCases.map {
            GapWatch(site: $0, looks: 0, watchedSpanNanos: 0, gapsFound: 0, lost: 0)
        })))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var bytes = Data()
    for line in lines { bytes.append(line); bytes.append(0x0A) }
    try bytes.write(to: url)
}

/// Extends `StageCompositorTests` for its `.serialized`: these write the process-global seams.
extension StageCompositorTests {
    private func plan() -> RenderPlan {
        let base = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                     sourceWidth: 640, sourceHeight: 360, style: .default)
        return RenderPlan(outputWidth: 640, outputHeight: 360, card: base.card,
                          cornerRadius: base.cornerRadius, style: base.style, pointer: nil)
    }

    /// **Changing the pace re-bakes the camera the compositor already built** — the invalidation
    /// half, on the same instance, because the tracks are built once per compositor and a pace
    /// that waited for the next composition would be a control that works on some later action.
    /// The hit half beside it: an unchanged pace gives the identical answer.
    @Test func changingThePaceReBakesTheCameraAndKeepingItDoesNot() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pace-\(UUID())", directoryHint: .isDirectory).appending(path: "segment-00.jsonl")
        try writeZoomingLog(at: url)
        defer {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            unsafe StageCompositor.observationLogURL = nil
            StageCompositor.cameraPace = .standard
        }
        unsafe StageCompositor.observationLogURL = url
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.framingOverrides = []
        unsafe StageCompositor.zoomAdjustments = []
        unsafe StageCompositor.editTimeline = nil
        StageCompositor.cameraPace = .standard

        // Mid-move: the block starts at the click less its pre-roll, so 2.8 s is partway in.
        let during = CMTime(value: 28, timescale: 10)
        let compositor = StageCompositor()
        let standard = compositor.cameraPlan(plan(), at: during).contentZoom
        #expect(standard > 1.01, "control: the fixture zooms at all — \(standard)")
        #expect(compositor.cameraPlan(plan(), at: during).contentZoom == standard,
                "the same pace, asked again, is the same camera")

        StageCompositor.cameraPace = .snappy
        let snappy = compositor.cameraPlan(plan(), at: during).contentZoom
        #expect(snappy > standard + 0.01, "snappy is further along mid-move: \(snappy) against \(standard)")
    }

    /// **A queued export keeps the zoom it was queued with.** `Settings` is what an export
    /// captures when it is asked for, because it runs later; the amount and pace were missing
    /// from it, so an export queued at one amount rendered at whatever was set when it ran.
    @Test func theSettingsAnExportCapturesIncludeTheZoomsAmountAndPace() {
        defer { StageCompositor.zoomIntensity = FramingDepth.neutralIntensity; StageCompositor.cameraPace = .standard }
        StageCompositor.zoomIntensity = 0.4
        StageCompositor.cameraPace = .snappy
        let captured = StageCompositor.settings()
        StageCompositor.zoomIntensity = 1.7
        StageCompositor.cameraPace = .gentle
        StageCompositor.apply(captured)
        #expect(StageCompositor.zoomIntensity == 0.4)
        #expect(StageCompositor.cameraPace == .snappy)
    }
}
