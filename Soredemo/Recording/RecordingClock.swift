import Foundation

/// **The take's clock, owned by the recording rather than by whatever shows it.**
///
/// It was the floating bar's timer: the bar ticked the coordinator, which was right while the
/// bar was the only surface a take had. When the notch took over the controls the bar was never
/// shown, so nothing ticked and the notch read 0:00 for a whole recording (2026-09-28). A clock
/// a view has to keep alive is a clock that stops when the view is not there.
///
/// **Counted in intervals, not read off a wall clock**, because this target reads no ambient time
/// (architecture rule 3, `noAppSourceReadsAnAmbientValueAtAll`); a late wake-up makes it run
/// slightly slow, never jump. `RecordingClockTests`.
@MainActor
final class RecordingClock {
    let interval: Double
    private var task: Task<Void, Never>?

    init(interval: Double) { self.interval = interval }

    var isRunning: Bool { task != nil }

    /// Starts ticking, replacing any clock already running — two would count double.
    func start(_ onTick: @escaping @MainActor (Double) -> Void) {
        stop()
        let interval = interval
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                onTick(interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
