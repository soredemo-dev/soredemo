import AppKit
import Capture
import Compositing
import Foundation
import Observation
import SwiftUI
import Timeline

/// Exports waiting their turn.
///
/// **One export at a time was also one export at all.** Pressing Export replaced the button with
/// a progress readout and a Cancel, so a person who wanted a 4K master and a small copy to send
/// had to sit through the first, then set the second up by hand — and a person who wanted both
/// plus a GIF had to do it three times. A queue is the answer and this
/// follows its shape: FIFO, one running, cancel per job, finished jobs cleared.
///
/// **The compositor's statics are why each job carries a `Settings`.** They are process-global,
/// because AVFoundation owns compositor instances; a job queued now and run in two minutes would
/// otherwise draw whatever a person had edited in between. `StageCompositor.settings()` is
/// captured when the job is enqueued and applied before it runs.
@MainActor
@Observable
final class ExportQueue {
    static let shared = ExportQueue()

    private(set) var jobs: [ExportJob] = []
    private var work: [Int: @MainActor () async -> Void] = [:]
    private var running: Int?
    private var runningTask: Task<Void, Never>?
    /// **A counter, not a UUID.** This project mints identifiers from a counter everywhere for
    /// the same reason: an identifier a test cannot predict is a test that has to work around it.
    private var nextID = 1

    private init() {}

    var isBusy: Bool { jobs.contains { !$0.status.isFinished } }

    /// Whether an export to this path is already waiting or running.
    ///
    /// **Two exports to one path is a race for one file**, and the second one's first act is to
    /// delete the file the first is still writing. The enqueue is refused for this
    /// reason and names the file in the refusal, which is the only way somebody works out which
    /// of their jobs they collided with.
    func isReserved(_ url: URL) -> Bool {
        jobs.contains { !$0.status.isFinished
            && $0.destination.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// Adds a job. Returns `nil` when the destination is already spoken for.
    @discardableResult
    func enqueue(destination: URL,
                 run: @escaping @MainActor (@escaping @MainActor (ExportProgress) -> Void)
                     async -> String?) -> Int? {
        guard !isReserved(destination) else { return nil }
        let id = nextID
        nextID += 1
        jobs.append(ExportJob(id: id, destination: destination, status: .waiting, progress: nil))
        work[id] = { [weak self] in
            let failure = await run { progress in
                self?.update(id) { job in
                    job.progress = progress
                    // **Folded here rather than in the view**, because a view is rebuilt for
                    // reasons that have nothing to do with progress and an estimate that
                    // advanced on every redraw would be measuring SwiftUI rather than the export.
                    if let fraction = progress.fraction, let startedAt = job.startedAt {
                        let now = Double(Minting.continuousNow().rawValue) / 1_000_000_000
                        job.eta.update(fraction: fraction, elapsed: now - startedAt)
                    }
                }
            }
            self?.update(id) {
                $0.status = failure == nil ? .finished : .failed
                $0.failure = failure
                $0.progress = nil
            }
        }
        startNext()
        return id
    }

    /// **Cancelling depends on which state the job is in.** A waiting job
    /// is simply dropped; a running one has its task cancelled and reports itself cancelled when
    /// the export notices — the exporter's own cooperative cancellation deletes its partial file,
    /// so nothing here has to.
    func cancel(_ id: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .waiting:
            work[id] = nil
            jobs[index].status = .cancelled
        case .running:
            runningTask?.cancel()
            jobs[index].status = .cancelled
        case .finished, .failed, .cancelled:
            break
        }
    }

    /// Only finished jobs, so a list cannot be emptied of the one still running.
    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    private func update(_ id: Int, _ change: (inout ExportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func startNext() {
        guard running == nil,
              let index = jobs.firstIndex(where: { $0.status == .waiting && work[$0.id] != nil })
        else { return }
        let id = jobs[index].id
        jobs[index].status = .running
        jobs[index].startedAt = Double(Minting.continuousNow().rawValue) / 1_000_000_000
        running = id
        let operation = work[id]
        work[id] = nil
        runningTask = Task { @MainActor [weak self] in
            await operation?()
            self?.running = nil
            self?.runningTask = nil
            self?.startNext()
        }
    }
}

/// One queued export.
struct ExportJob: Identifiable, Sendable {
    let id: Int
    let destination: URL
    var status: Status
    var progress: ExportProgress?
    var failure: String?

    /// When this job started writing, by the monotonic clock.
    ///
    /// **`Minting.continuousNow`, not a wall clock.** An export can outlive a clock adjustment,
    /// and a wall clock that steps backwards during one turns "two minutes left" into a negative
    /// number. `continuousNow` keeps counting across sleep, which a long export can also outlive.
    /// Set when the job goes to `.running` and never after.
    var startedAt: Double?

    /// How long is left, smoothed. Folded on every progress report; see `ExportETA`.
    var eta = ExportETA()

    /// What to tell somebody about the time, or `nil` while nothing is worth claiming.
    var timeReading: ExportETA.Reading? { ExportETA.reading(eta.secondsRemaining) }

    var filename: String { destination.lastPathComponent }

    /// One reading, in the reader's own language.
    ///
    /// **Six keys, one per case, and the numbers interpolated here rather than in `Core`.** The
    /// first version built the sentence in the package — `"about 3 minutes left"` — which cannot
    /// be a string-table key: there is one key per number. Interpolating on this side turns
    /// `\(value)` into `%lld`, which the tables carry as a single entry.
    static func timeText(_ reading: ExportETA.Reading) -> Text {
        switch reading {
        case .aFewSeconds: Text("a few seconds left")
        case .seconds(let value): Text("about \(value) seconds left")
        case .aMinute: Text("about a minute left")
        case .minutes(let value): Text("about \(value) minutes left")
        case .anHour: Text("about an hour left")
        case .hours(let value): Text("about \(value) hours left")
        }
    }


    enum Status: Sendable {
        case waiting, running, finished, failed, cancelled

        var isFinished: Bool {
            switch self {
            case .finished, .failed, .cancelled: true
            case .waiting, .running: false
            }
        }
    }
}

/// The queue, as a toolbar button that only exists when there is something in it.
///
/// **Present only while it has content.** A permanently visible export queue in a window whose
/// usual state is "nothing exporting" is a control people learn to ignore — and this app's
/// toolbar is already carrying the shape, the crop and the inspector.
struct ExportQueueButton: View {
    @State private var queue = ExportQueue.shared

    var body: some View {
        if !queue.jobs.isEmpty {
            // **One running export is said out loud, not filed in a menu.**
            //
            // The menu below is right for a queue — several jobs, each with its own state. It is
            // wrong for the ordinary case, which is one export running, because everything a
            // person wants then (which file, how far, how do I stop it) was behind a click on a
            // chevron that looks like a disclosure control for the Export button beside it.
            // Reported as "the UI for export is terrible, it's hidden if the user didn't click",
            // and that is what it was: the app knew the filename, the percentage and how to
            // cancel, and showed none of the three until asked.
            //
            // The menu stays for two or more, where a row per job is the only way to show them.
            if queue.jobs.count == 1, let job = queue.jobs.first, job.status == .running {
                running(job)
            } else {
                Menu {
                ForEach(queue.jobs) { job in
                    ExportJobRow(job: job)
                }
                if queue.jobs.contains(where: { $0.status.isFinished }) {
                    Divider()
                    Button("Clear Finished") { queue.clearFinished() }
                }
            } label: {
                HStack(spacing: Space.tight) {
                    if let running = queue.jobs.first(where: { $0.status == .running }) {
                        // A determinate bar while writing, an indeterminate one while finishing:
                        // `finishWriting` reports nothing, and a bar pinned at 100% reads as
                        // stopped.
                        if let fraction = running.progress?.fraction {
                            ProgressView(value: fraction).frame(width: 60)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    // The waiting count, because a queue whose length is invisible is a queue
                    // somebody adds a fourth job to without meaning to.
                    let waiting = queue.jobs.filter { $0.status == .waiting }.count
                    if waiting > 0 { Text(verbatim: "\(waiting)").font(.caption) }
                }
                }
                .help("Exports")
            }
        }
    }

    /// The single running export, in the toolbar: what it is, how far, and Stop.
    ///
    /// **A button that says Stop rather than an ✕.** Cancelling an export throws away minutes of
    /// work, and a glyph does not say that; the word does. It is not confirmed beyond that,
    /// because the alternative — a sheet over a running export — is worse for the far more
    /// common case of somebody who meant it.
    @ViewBuilder private func running(_ job: ExportJob) -> some View {
        HStack(spacing: Space.snug) {
            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            Text(verbatim: job.filename)
                .font(Type.detail)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
            if let fraction = job.progress?.fraction {
                ProgressView(value: fraction).frame(width: 70)
                Text(verbatim: "\(Int(fraction * 100))%")
                    .font(Type.readout)
                    .foregroundStyle(.secondary)
                    // Fixed width, or the row twitches sideways at every percent — see
                    // `ExportETA` for the same reason the time is smoothed.
                    .frame(width: 34, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
                // **`finishWriting` reports nothing**, and a bar pinned at 100% reads as stopped
                // rather than as nearly done. The word says which it is.
                Text("Finishing\u{2026}").font(Type.readout).foregroundStyle(.secondary)
            }
            Button("Stop") { ExportQueue.shared.cancel(job.id) }
                .buttonStyle(.borderless)
                .font(Type.detail)
        }
        .padding(.horizontal, Space.snug)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
            .fill(.quaternary))
        .help("Exporting \(job.filename)")
    }
}

/// One row of the queue's menu: what it is doing, and the one thing you can do about it.
private struct ExportJobRow: View {
    let job: ExportJob

    var body: some View {
        switch job.status {
        case .waiting, .running:
            // **The time is the answer to the only question anybody has while an export runs.**
            // A fraction says where it is; whether to wait or to go and do something else is a
            // different question, and it was the one this menu could not answer.
            if let reading = job.timeReading {
                Button {
                    ExportQueue.shared.cancel(job.id)
                } label: {
                    // **Two `Text` views in a stack, not `Text + Text`.** Concatenation is
                    // deprecated in macOS 26, and interpolating a localised `Text` into another
                    // string would flatten it back into English — the six keys exist precisely
                    // so the reading is looked up rather than built.
                    HStack(spacing: Space.tight) {
                        Text(verbatim: "\(job.filename) \u{2014} \(Self.label(job))")
                        Text("\u{00B7}").foregroundStyle(.secondary)
                        ExportJob.timeText(reading).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    ExportQueue.shared.cancel(job.id)
                } label: {
                    Text(verbatim: "\(job.filename) \u{2014} \(Self.label(job))")
                }
            }
        case .finished:
            // **A submenu, because there are now two things to do with a finished export and
            // one of them must not be the accident.** Reveal is first and is what the row did
            // before: an export is usually one of several files a person is collecting, and the
            // Finder window is what they want next.
            Menu("\(job.filename) \u{2014} Done") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([job.destination])
                }
                Button("Copy") { Self.copy(job.destination) }
            }
        case .failed, .cancelled:
            Text(verbatim: "\(job.filename) \u{2014} \(Self.label(job))")
        }
    }


    /// **Puts the FILE on the pasteboard, not its path.** Pasting into Mail, Slack or Messages
    /// then attaches the video, which is what "copy" means for a thing somebody just exported.
    /// A string of the path would paste as text everywhere and attach nowhere.
    ///
    /// `clearContents()` first, because `NSPasteboard` accumulates otherwise and a paste would
    /// carry whatever was copied before this alongside it.
    static func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // `as NSURL`: `URL` is not an `NSPasteboardWriting`, and the bridged type is what
        // carries the file-URL flavour a receiving app looks for.
        pasteboard.writeObjects([url as NSURL])
    }

    static func label(_ job: ExportJob) -> String {
        switch job.status {
        case .waiting: NSLocalizedString("Waiting \u{2014} cancel", comment: "")
        case .running:
            switch job.progress {
            case .writing(let fraction, _): String(localized: "\(Int(fraction * 100))% \u{2014} cancel")
            case .finishing: NSLocalizedString("Finishing\u{2026}", comment: "")
            case .preparing, nil: NSLocalizedString("Preparing\u{2026}", comment: "")
            }
        case .finished: NSLocalizedString("Done", comment: "")
        case .failed: job.failure ?? NSLocalizedString("Failed", comment: "")
        case .cancelled: NSLocalizedString("Cancelled", comment: "")
        }
    }
}
