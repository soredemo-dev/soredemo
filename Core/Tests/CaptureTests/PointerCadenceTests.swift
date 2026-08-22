import Dispatch
import Foundation
import Geometry
import Testing
import Project
import Timeline
@testable import Capture

/// **The gap the tap cannot fill.** A `CGEventTap` reports events, and a pointer held still
/// produces no events — so the track had a hole exactly as long as any pause, and a tap the
/// system disabled produced a hole as long as the blind window. `PointerSampler` puts a
/// floor under both. These tests drive it with an injected reader, since a real tap needs
/// Input Monitoring and a real pointer cannot be held still on demand.
@Suite struct PointerSamplerTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [(x: Double, y: Double)] = []
        func note(_ location: (x: Double, y: Double)) { lock.withLock { samples.append(location) } }
        var count: Int { lock.withLock { samples.count } }
        var all: [(x: Double, y: Double)] { lock.withLock { samples } }
    }

    /// The point of the type in one assertion: the reader never changes its answer — a
    /// pointer that is not moving — and samples arrive anyway.
    @Test func aStationaryPointerStillProducesSamples() async {
        let counter = Counter()
        let sampler = PointerSampler(interval: Nanoseconds(2_000_000),
                                     read: { (x: 400, y: 300) })
        sampler.start(epoch: epoch) { _, location in counter.note(location) }
        try? await Task.sleep(for: .milliseconds(60))
        sampler.stop()

        #expect(counter.count >= 5,
                "a 2 ms cadence over 60 ms should tick many times, saw \(counter.count)")
        #expect(counter.all.allSatisfy { $0.x == 400 && $0.y == 300 })
    }

    /// A reader that cannot answer is not a pointer at the origin. `CGEvent(source:)`
    /// returns `nil` under conditions this code does not get to guess about.
    @Test func aReaderThatReturnsNilEmitsNothing() async {
        let counter = Counter()
        let sampler = PointerSampler(interval: Nanoseconds(2_000_000), read: { nil })
        sampler.start(epoch: epoch) { _, location in counter.note(location) }
        try? await Task.sleep(for: .milliseconds(30))
        sampler.stop()

        #expect(counter.count == 0)
    }

    /// `stop()` has to actually stop: the sampler outlives a segment and a timer still
    /// firing would append to a track that has been closed.
    @Test func stoppingEndsTheCadence() async {
        let counter = Counter()
        let sampler = PointerSampler(interval: Nanoseconds(2_000_000), read: { (x: 1, y: 1) })
        sampler.start(epoch: epoch) { _, location in counter.note(location) }
        try? await Task.sleep(for: .milliseconds(30))
        sampler.stop()
        let atStop = counter.count
        try? await Task.sleep(for: .milliseconds(30))

        #expect(counter.count == atStop, "ticks continued after stop()")
    }

    /// The instant is taken when the reading is taken, not derived from the timer's
    /// schedule. A `DispatchSourceTimer` with leeway does not fire on its nominal deadline,
    /// and a track stamped with intentions rather than measurements would drift.
    @Test func theInstantIsMeasuredNotScheduled() async {
        let instants = InstantBox()
        let sampler = PointerSampler(interval: Nanoseconds(3_000_000), read: { (x: 1, y: 1) })
        sampler.start(epoch: epoch) { instant, _ in instants.note(instant) }
        try? await Task.sleep(for: .milliseconds(40))
        sampler.stop()

        let seen = instants.all
        #expect(seen.count >= 3)
        // Strictly increasing, and every one inside the window the test was awake for.
        for (earlier, later) in zip(seen, seen.dropFirst()) {
            #expect(later.hostTime.rawValue > earlier.hostTime.rawValue)
        }
    }

    private final class InstantBox: @unchecked Sendable {
        private let lock = NSLock()
        private var instants: [HostInstant] = []
        func note(_ instant: HostInstant) { lock.withLock { instants.append(instant) } }
        var all: [HostInstant] { lock.withLock { instants } }
    }
}

/// The cadence and the tap are two sources for one track, and the rule between them is
/// "the cadence fills gaps, it does not duplicate". These drive `sampleCadence` directly:
/// the tap half needs Input Monitoring, but the arbitration between the two does not.
@Suite struct CadenceArbitrationTests {
    private let displayUUID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)

    private func viewport() -> CaptureViewport {
        CaptureViewport(geometry: DisplayGeometry(displayUUID: displayUUID,
                                                  pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
                        globalOriginX: 0, globalOriginY: 0,
                        widthInPoints: 1000, heightInPoints: 500)
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [PointerSample] = []
        func note(_ observation: InputObserver.Observation) {
            if case .pointer(let sample) = observation { lock.withLock { samples.append(sample) } }
        }
        var all: [PointerSample] { lock.withLock { samples } }
    }

    private func observer(_ sink: Sink) -> InputObserver {
        let observer = InputObserver(viewport: viewport(), epoch: epoch)
        observer.setObservationSink { sink.note($0) }
        return observer
    }

    @Test func aTickWithNoRecentSampleEmits() {
        let sink = Sink()
        let observer = observer(sink)
        observer.sampleCadence(at: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000_000_000)),
                               location: (x: 500, y: 250))
        #expect(sink.all.count == 1)
        #expect(sink.all.first?.position.x == 0.5)
    }

    /// The tap emits faster than the cadence while the pointer is moving. Emitting both
    /// would double the track for no extra information.
    @Test func aTickTheTapAlreadyCoveredIsSkipped() {
        let sink = Sink()
        let observer = observer(sink)
        let first = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000_000_000))
        observer.sampleCadence(at: first, location: (x: 500, y: 250))
        // One millisecond later — far inside the 16.7 ms cadence.
        observer.sampleCadence(at: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_001_000_000)),
                               location: (x: 600, y: 250))
        #expect(sink.all.count == 1, "the second tick should have deferred to the first")
    }

    /// One full interval later there is no fresh sample, so the floor applies. This is the
    /// case a still pointer or a disabled tap produces, and the whole reason the type exists.
    @Test func aTickAfterAFullIntervalEmits() {
        let sink = Sink()
        let observer = observer(sink)
        let first = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000_000_000))
        observer.sampleCadence(at: first, location: (x: 500, y: 250))
        let later = Nanoseconds(1_000_000_000 + InputObserver.cadenceInterval.rawValue)
        observer.sampleCadence(at: HostInstant(epoch: epoch, hostTime: later),
                               location: (x: 500, y: 250))
        #expect(sink.all.count == 2)
    }

    /// A location outside the recording has no position in it — the same refusal a tap
    /// sample gets, not a clamp to the edge.
    @Test func aLocationOutsideTheViewportEmitsNothing() {
        let sink = Sink()
        let observer = observer(sink)
        observer.sampleCadence(at: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000_000_000)),
                               location: (x: 5000, y: 250))
        #expect(sink.all.isEmpty)
        #expect(observer.diagnostics.unroutablePointerLocations == 1)
    }

    /// The cadence reads the CURRENT viewport, not the one the observer was built with.
    /// Without this a followed window would have its stream re-cropped while the cadence
    /// kept normalising against the opening rectangle — the drift, moved rather than fixed.
    @Test func theCadenceNormalisesAgainstTheUpdatedViewport() {
        let sink = Sink()
        let observer = observer(sink)
        observer.updateViewport(CaptureViewport(
            geometry: DisplayGeometry(displayUUID: displayUUID,
                                      pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
            globalOriginX: 400, globalOriginY: 0, widthInPoints: 1000, heightInPoints: 500))
        observer.sampleCadence(at: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000_000_000)),
                               location: (x: 500, y: 250))
        #expect(sink.all.first?.position.x == 0.1)
    }

    /// `cadenceSamples` is a share of `pointerSamples`, not a parallel count: a recording
    /// where they are equal is one where the tap contributed nothing, which is a fact worth
    /// being able to read off the diagnostics rather than infer.
    @Test func cadenceSamplesAreCountedWithinPointerSamples() {
        let sink = Sink()
        let observer = observer(sink)
        observer.sampleCadence(at: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000_000_000)),
                               location: (x: 500, y: 250))
        #expect(observer.diagnostics.pointerSamples == 1)
        #expect(observer.diagnostics.cadenceSamples == 1)
    }
}
