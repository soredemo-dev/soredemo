import Dispatch
import Foundation
import Geometry
import Testing
import Timeline
@testable import Capture

private let displayUUID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)

/// **A window moved mid-recording used to be silently wrong.** `sourceRect` was computed
/// once from `SCWindow.frame`, a snapshot that never updates, so the stream kept cropping
/// the display at the opening rectangle and the observer kept normalising the pointer
/// against it. These pin the two halves of the repair.
@Suite struct WindowFollowerTests {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PointRect
        private var reported: [PointRect] = []
        init(_ initial: PointRect) { value = initial }
        var current: PointRect { lock.withLock { value } }
        func set(_ rect: PointRect) { lock.withLock { value = rect } }
        func report(_ rect: PointRect) { lock.withLock { reported.append(rect) } }
        var all: [PointRect] { lock.withLock { reported } }
    }

    /// The follower reports **changes**, not ticks. Every call reconfigures a live stream,
    /// so a follower that fired every 100 ms whether or not the window had moved would be
    /// reconfiguring a running capture ten times a second for nothing.
    @Test func anUnmovedWindowReportsNothing() async {
        let frames = Frames(PointRect(x: 100, y: 100, width: 800, height: 600))
        let follower = WindowFollower(windowID: 1,
                                      initialFrame: frames.current,
                                      interval: .milliseconds(2),
                                      read: { _ in frames.current })
        follower.start { frames.report($0) }
        try? await Task.sleep(for: .milliseconds(40))
        follower.stop()

        #expect(frames.all.isEmpty, "reported \(frames.all.count) changes for a still window")
        #expect(follower.frameChanges == 0)
    }

    @Test func aMovedWindowIsReportedOnce() async {
        let frames = Frames(PointRect(x: 100, y: 100, width: 800, height: 600))
        let follower = WindowFollower(windowID: 1,
                                      initialFrame: frames.current,
                                      interval: .milliseconds(2),
                                      read: { _ in frames.current })
        follower.start { frames.report($0) }
        try? await Task.sleep(for: .milliseconds(20))
        frames.set(PointRect(x: 300, y: 250, width: 800, height: 600))
        // **Polled for the report, then held for twenty more ticks**, not slept a fixed 40 ms: a
        // loaded CI runner can miss the window (the pointer-cadence test did, 2026-11-08). The
        // hold after the first report is what tests "once" — a second report would land in it.
        var waited = 0
        while frames.all.isEmpty, waited < 2_000 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        try? await Task.sleep(for: .milliseconds(40))
        follower.stop()

        #expect(frames.all.count == 1, "expected one report, got \(frames.all.count) after about \(waited) ms")
        #expect(frames.all.first?.x == 300)
        #expect(follower.frameChanges == 1)
    }

    /// A resize anchored at the top-left moves no corner the origin would notice, which is
    /// why `differs` compares all four edges rather than the origin alone.
    @Test func aResizeThatDoesNotMoveTheOriginIsStillAChange() {
        let before = PointRect(x: 100, y: 100, width: 800, height: 600)
        let after = PointRect(x: 100, y: 100, width: 1200, height: 900)
        #expect(WindowFollower.differs(before, after))
        #expect(!WindowFollower.differs(before, before))
    }

    /// A window that cannot be read is not a window at the origin. The recording keeps the
    /// last known rectangle; a window that is really gone is the stream's error to report.
    @Test func aWindowThatCannotBeReadReportsNoChange() async {
        let frames = Frames(PointRect(x: 100, y: 100, width: 800, height: 600))
        let follower = WindowFollower(windowID: 1,
                                      initialFrame: frames.current,
                                      interval: .milliseconds(2),
                                      read: { _ in nil })
        follower.start { frames.report($0) }
        try? await Task.sleep(for: .milliseconds(30))
        follower.stop()

        #expect(frames.all.isEmpty)
        #expect(follower.disappearances > 0, "a missing window should be counted, not ignored")
    }
}

/// The observer's half: the viewport it normalises against has to be replaceable, or a
/// followed window still lands every sample in the wrong rectangle.
@Suite struct ObserverViewportUpdateTests {
    private func viewport(originX: Double, width: Double) -> CaptureViewport {
        CaptureViewport(geometry: DisplayGeometry(displayUUID: displayUUID,
                                                  pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
                        globalOriginX: originX, globalOriginY: 0,
                        widthInPoints: width, heightInPoints: 500)
    }

    @Test func updatingTheViewportChangesWhereLaterSamplesNormaliseTo() {
        let observer = InputObserver(viewport: viewport(originX: 0, width: 1000), epoch: epoch)
        // Global (500, 250) is the centre of a viewport at the origin…
        let before = InputObserver.normalizedPosition(globalTopLeftX: 500, globalTopLeftY: 250,
                                                      in: observer.currentViewport)
        #expect(before?.position.x == 0.5)

        observer.updateViewport(viewport(originX: 400, width: 1000))
        // …and a quarter of the way across the same-sized viewport moved 400 points right.
        let after = InputObserver.normalizedPosition(globalTopLeftX: 500, globalTopLeftY: 250,
                                                     in: observer.currentViewport)
        #expect(after?.position.x == 0.1)
    }

    /// A point outside the moved viewport has no position in the recording — the update
    /// must not leave the old rectangle answering for coordinates the video no longer shows.
    @Test func aPointOutsideTheMovedViewportHasNoPosition() {
        let observer = InputObserver(viewport: viewport(originX: 0, width: 1000), epoch: epoch)
        observer.updateViewport(viewport(originX: 900, width: 1000))
        #expect(InputObserver.normalizedPosition(globalTopLeftX: 100, globalTopLeftY: 250,
                                                 in: observer.currentViewport) == nil)
    }
}
