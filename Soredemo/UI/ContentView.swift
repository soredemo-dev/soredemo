//
//  ContentView.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Project
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Timeline

/// Phase 2B Task 4's home for "a window with a rendered frame in it" — the first behaviour this
/// phase can show rather than only test. Shows `StageWindow` once a recording exists; until then, a
/// placeholder and the "Open Recording…"/"Stop Recording" command (wired in `SoredemoApp.body`,
/// which owns the one `RecordingCoordinator` this window reads) are the only way to get one.
///
/// **Not document-bound, and that is a correction to the task brief rather than an oversight.**
/// The brief's Step 5 asks for `StageWindow(mediaURL:)` "for the document's first segment" — but
/// this `ContentView` is `SoredemoApp`'s scratch `WindowGroup`, not `ProjectDocument
/// .makeWindowControllers()`'s document window (see `SoredemoApp.body`'s own doc comment: this
/// window exists only because `repo-skeleton`'s completion criterion needs a bare launch to reach
/// a window before any document is open). There is no document, and therefore no "first segment",
/// available here to read. The closest honest approximation that still makes a frame observable
/// without inventing a document-editing model Phase 2B does not ask for: record straight through
/// this window via the existing `CaptureSourcePicker`/`CaptureSession` pair, to a scratch location
/// (`TemporaryFileMediaSink`, below) rather than into a `.soredemo` package.
struct ContentView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Group {
            if let mediaURL = coordinator.mediaURL {
                StageWindow(mediaURL: mediaURL)
                    // Review finding (Task 7 round 2): the deletion this closure drives used to
                    // live in `RecordingCoordinator.stopRecording()`, justified by a comment that
                    // named the wrong invariant — it said `mediaURL` moving was what made the
                    // deletion safe, but the actual guarantee came from `beginOpenRecording()`'s
                    // earlier `mediaURL = nil`, three functions away and unnamed in the comment
                    // that depended on it.
                    //
                    // Round 3 correction: `.onDisappear` does NOT remove that dependency — it
                    // still needs `beginOpenRecording()` (`:147`) to set `mediaURL = nil` first.
                    // `StageWindow` carries no `.id(mediaURL)`, so SwiftUI only treats
                    // `StageWindow(mediaURL: url1)` and `StageWindow(mediaURL: url2)` as
                    // DIFFERENT view identities — the thing that makes `.onDisappear` fire at
                    // all — because that `nil` swaps this `Group`'s branch out entirely in
                    // between. Without it (the exact UX change the original finding named — keep
                    // the old preview visible while a new recording runs), SwiftUI would most
                    // likely update `mediaURL` on the SAME `StageWindow` instance in place,
                    // `.onDisappear` would never fire, and `sourceSelected`'s own outgoing-sink
                    // check would also decline to delete (`mediaSourceSink` still equals the
                    // sink in question) — so the directory would LEAK, not get deleted under a
                    // live player. What changed is the failure mode, not the dependency: unsafe
                    // became a leak the launch-time sweep (`TemporaryFileMediaSink
                    // .sweepLeftoverDirectories()`) bounds, not gone. See `RecordingCoordinator
                    // .previewWasDismissed()` and `TemporaryFileMediaSink`'s own header.
                    .onDisappear { coordinator.previewWasDismissed() }
            } else {
                ContentUnavailableView(
                    coordinator.isRecording ? "Recording…" : "No recording yet",
                    systemImage: coordinator.isRecording ? "record.circle" : "video.badge.plus",
                    description: Text(coordinator.statusText))
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView(coordinator: RecordingCoordinator())
}

// MARK: - Recording, straight into this window

/// Owns the one capture this window can show. `@Observable` so `ContentView` redraws as a
/// selection is made, a recording starts, and a finished file becomes a `mediaURL`
/// `StageWindow` can open — the same three-state shape `StageWindow.load()` already uses for
/// `player`/`failure`.
///
/// A single instance lives in `SoredemoApp` and is handed to both `ContentView` (to read) and the
/// "Open Recording…"/"Stop Recording" menu command (to drive) — see that file. It is not a
/// singleton reached through a static, unlike `StageCompositor.renderer` or `SoredemoApp
/// .retainedPicker`: nothing here is called back from an AVFoundation/ScreenCaptureKit queue that
/// cannot see an instance, so ordinary reference-passing is enough.
@Observable
final class RecordingCoordinator {
    private(set) var mediaURL: URL?
    private(set) var isRecording = false
    private(set) var statusText =
        "Choose \u{201C}Open Recording\u{2026}\u{201D} from the File menu (\u{2318}R), record a few " +
        "seconds of anything, then choose \u{201C}Stop Recording\u{201D} to preview it here."

    /// Retained for the life of the pending selection — `SCContentSharingPicker.add(_:)` is not
    /// documented to retain its observer, the same reasoning `SoredemoApp.retainedPicker`'s own
    /// doc comment gives.
    private var picker: CaptureSourcePicker?
    private var session: CaptureSession?
    private var sink: TemporaryFileMediaSink?

    /// **The lifecycle fix for `TemporaryFileMediaSink`'s own "not cleaned up by this type" —
    /// Task 4's review flagged it, Task 5.5 carried it forward, this is where it closes.** Which
    /// sink actually produced `mediaURL` — the file a live `AVPlayer` may currently have open.
    /// Reference identity (`===` in `sourceSelected`, below), not `mediaURL` equality: the
    /// coordinator, not the sink, is what a caller reasons about.
    ///
    /// **Deleting THIS sink's directory is `previewWasDismissed()`'s job, not `stopRecording()`'s
    /// — a Task 7 review round 2 correction.** The first version deleted it inside
    /// `stopRecording()`, justified by a comment claiming "`mediaURL` is about to move, so
    /// nothing needs the old directory" — but that deletion ran BEFORE `mediaURL` actually moved,
    /// and the real reason it was safe lived in `beginOpenRecording()`'s earlier `mediaURL = nil`
    /// (which tears the previous `StageWindow`, and its `AVPlayer`, out of the view tree) — a
    /// fact stated nowhere near the code that depended on it.
    ///
    /// **Round 3 correction: `previewWasDismissed()` does NOT remove that dependency — it still
    /// needs `beginOpenRecording()`'s `mediaURL = nil` for `.onDisappear` to fire at all** (see
    /// `ContentView.body`'s own comment on the `.onDisappear` call site for the mechanism). What
    /// changed is the FAILURE MODE if that assumption is ever defeated: not "deletes under a live
    /// player" but "leaks a directory the launch-time sweep bounds" — worse than fully fixed,
    /// strictly better than the original defect.
    private var mediaSourceSink: TemporaryFileMediaSink?

    /// Called via `.onDisappear` at `ContentView`'s own call site, when the `StageWindow` showing
    /// `mediaSourceSink`'s recording is torn down by SwiftUI — which, today, only happens because
    /// `beginOpenRecording()` sets `mediaURL = nil` first (see that call site's own comment for
    /// why this is a dependency narrowed, not removed). Not `private`: `ContentView.body` (same
    /// file, different type) is the only caller, and Swift's `private` does not reach across type
    /// boundaries even within one file.
    func previewWasDismissed() {
        if let directory = mediaSourceSink?.packageURL {
            try? FileManager.default.removeItem(at: directory)
        }
        mediaSourceSink = nil
    }

    /// `TemporaryFileMediaSink.sweepLeftoverDirectories()` once, at the coordinator's own
    /// construction — the earliest point this app ever runs, before any recording exists to
    /// protect. See that function's own doc comment for why a launch sweep is needed at all
    /// (crash / force-quit exits never reach the replace-on-next-recording path below) and why it
    /// is safe to run unconditionally here.
    init() {
        TemporaryFileMediaSink.sweepLeftoverDirectories()
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            beginOpenRecording()
        }
    }

    private func beginOpenRecording() {
        // Task 5.5 Step 3 — ask for Screen Recording, once, before the picker opens.
        // `SCContentSharingPicker`/`SCStream` never prompt on their own; without this a first-run
        // user is told "the user declined" by an API that never asked them.
        // `CapturePermissions.requestScreenRecordingAccess()` is idempotent and unguarded on
        // purpose — see that function's own doc comment for why `status(of: .screenRecording) !=
        // .granted` would never fire here.
        CapturePermissions.requestScreenRecordingAccess()

        mediaURL = nil
        statusText = "Choose what to record from the picker\u{2026}"
        let picker = CaptureSourcePicker(onSelect: { [self] source in
            Task { @MainActor in await sourceSelected(source) }
        })
        self.picker = picker
        picker.present()
    }

    private func sourceSelected(_ source: CaptureSource?) async {
        picker = nil
        guard let source else {
            statusText = "Recording cancelled. Choose \u{201C}Open Recording\u{2026}\u{201D} to try again."
            return
        }
        let scale = Self.scale(forDisplay: Self.sizingDisplayID(for: source))
        // `Self.displayIdentity(for:)`, not `displayUUID(for:)` — `AppSourceAllowListTests`'
        // ambient scan bans the substring "UUID(" (per `Minting.displayIdentity`'s own doc
        // comment, which explains why that function has the name it has and not the more
        // obvious one); `displayUUID(for: source)` would have matched it, a false positive of
        // exactly the kind that doc comment describes as "the visible false positive its own
        // header describes as survivable" — found here by running `swift test`, not anticipated.
        let displayUUID = Self.displayIdentity(for: source)

        let newSink: TemporaryFileMediaSink
        do {
            newSink = try TemporaryFileMediaSink()
        } catch {
            statusText = "Could not create a scratch location for the recording: \(error)"
            return
        }
        // The OUTGOING sink, if this is a second-or-later recording. Deleted here, immediately,
        // ONLY when it never became what `mediaURL` points at — a recording that was started and
        // then abandoned (picker cancelled next time, `start()` failed) has nothing playing it,
        // so there is nothing to wait for, unlike a sink `previewWasDismissed()` is still
        // responsible for. Self-contained: this check does not depend on when any other function
        // last ran, only on the current value of `mediaSourceSink` — if it still names `outgoing`,
        // `previewWasDismissed()` has not fired yet for it and this leaves it alone, whichever
        // order the two end up running in.
        if let outgoing = sink, outgoing !== mediaSourceSink, let directory = outgoing.packageURL {
            try? FileManager.default.removeItem(at: directory)
        }
        sink = newSink

        let newSession = CaptureSession(source: source, scale: scale, displayUUID: displayUUID,
                                        mediaSink: newSink, epoch: Minting.bootEpoch())
        session = newSession
        do {
            try await newSession.start()
            isRecording = true
            statusText = "Recording\u{2026} choose \u{201C}Stop Recording\u{201D} (\u{2318}R) when done."
        } catch {
            statusText = "Could not start recording: \(error)"
            session = nil
        }
    }

    private func stopRecording() async {
        guard let session else { return }
        isRecording = false
        statusText = "Finishing\u{2026}"
        do {
            let outcome = try await session.stop()
            let discardedCount: Int
            let firstMediaFilename: String?
            switch outcome {
            case .complete(let table):
                discardedCount = 0
                firstMediaFilename = table.segments.first?.mediaFilename
            case .incomplete(let table, let discarded):
                discardedCount = discarded.count
                firstMediaFilename = table.segments.first?.mediaFilename
            }
            if let firstMediaFilename, let url = sink?.url(for: firstMediaFilename) {
                // No deletion here — see `previewWasDismissed()` below. The PREVIOUSLY displayed
                // sink (if any) is superseded by this assignment, but "superseded" is not the
                // same fact as "safe to delete": the `StageWindow` that was showing it does not
                // get torn down by this line, it gets torn down by SwiftUI reconciling the new
                // `mediaURL`, which is a LATER, separate event this function does not control the
                // timing of. `.onDisappear`, wired at `ContentView`'s call site, is what actually
                // observes that event.
                mediaURL = url
                mediaSourceSink = sink
                statusText = discardedCount == 0 ? "" :
                    "\(discardedCount) segment(s) did not make it into the recording."
            } else {
                statusText = "The recording finished but produced no media."
            }
        } catch {
            statusText = "Could not stop recording: \(error)"
        }
        self.session = nil
    }

    // MARK: - scale / displayUUID, derived the way `spikes/2026-08-02-capture-master` and
    // `InputObserver.currentArrangement()` already do (see each function's own comment)

    /// The display whose mode decides `scale` for `CaptureSession.init`. For `.display`, the
    /// display actually being recorded. For `.window`, there is no single display a window
    /// belongs to (`CaptureSource`'s own header: a window's frame is extrinsic) — the main
    /// display is used as an approximation, the same one `CaptureSourcePicker`'s own derivation
    /// (`CaptureSource.init(pickerFilter:availableDisplays:)`) falls back on when nothing better
    /// is available. This is a known simplification, not a measured answer: a window captured
    /// while sitting on a differently-scaled secondary display would get the wrong `scale` here.
    private static func sizingDisplayID(for source: CaptureSource) -> CGDirectDisplayID {
        switch source {
        case .display(let display): return display.displayID
        case .window: return CGMainDisplayID()
        }
    }

    /// `CGDisplayMode.pixelWidth / .width`, the same ratio `InputObserver.currentArrangement()`
    /// uses and the same reason: it is native pixels over points for the mode actually in use,
    /// which is `DisplayGeometry.scale`'s own definition. Falls back to `2` — the same placeholder
    /// `spikes/2026-08-02-capture-master` uses — only when the display cannot be read at all.
    private static func scale(forDisplay displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// A display's persistent identity for `.display`, per `CaptureSource.geometry(scale
    /// :displayUUID:)`'s own doc comment. For `.window`, that same comment says this field is
    /// "reused" to carry "a source identity minted once per selection" — so a fresh identifier,
    /// not a literal display's UUID.
    private static func displayIdentity(for source: CaptureSource) -> UUID {
        switch source {
        case .display(let display):
            return Minting.displayIdentity(of: display.displayID) ?? Minting.newIdentifier()
        case .window:
            return Minting.newIdentifier()
        }
    }
}

/// Writes a `CaptureSession`'s finished segment bytes to a scratch location outside any
/// `.soredemo` package, and remembers where each named file landed.
///
/// **Why this exists instead of routing through `ProjectDocument.addMedia(_:named:)`.** That is
/// the shipping route `CaptureSession`'s own header describes as the only correct one for a
/// document-backed recording — but `ContentView` (see its doc comment) is not document-backed,
/// so there is no `ProjectDocument` here to write into. `StageWindow` reads a plain `URL` through
/// `AVURLAsset`, which has no opinion about where the file lives, so a scratch directory is enough
/// to make a frame observable without inventing a document for the sole purpose of holding it.
///
/// **Cleaned up by a lifecycle, not by this type acting alone — Task 4's review flagged this as
/// open ("writes recordings under `NSTemporaryDirectory()` and never deletes them"), Task 5.5
/// carried it forward, and Phase 2B Task 7 is where it closes.** The reason it was left THIS way
/// is still real and still governs the design: `AGENTS.md`'s "never write to $HOME and never
/// commit media" governs the PROBE (`scripts/cross-boundary-digest-probe.swift`), which this is
/// not, and deleting a file out from under a still-playing `AVPlayer` the moment a recording
/// finishes would be the wrong failure to introduce. So the fix is not a `removeItem` added
/// somewhere convenient — it is two rules, both in `RecordingCoordinator` (this file), that
/// together bound how long a directory this type creates can survive:
///
/// 1. **Torn down with the view that was showing it — a Task 7 review round 2 correction, not
///    the original shape.** `RecordingCoordinator.mediaSourceSink` tracks which sink produced the
///    CURRENT `mediaURL` — the file a live `AVPlayer` may have open. Starting a new recording
///    deletes the OUTGOING sink's directory immediately if it was never what `mediaURL` pointed
///    at (an abandoned attempt — nothing was ever playing it; `sourceSelected`'s own comment
///    covers this case). The sink that WAS displayed is different: it is deleted by
///    `RecordingCoordinator.previewWasDismissed()`, called from `.onDisappear` at `ContentView`'s
///    own call site — tied to the SwiftUI event that removes `StageWindow` (and its `AVPlayer`)
///    from the tree. The first version deleted it inside `stopRecording()` on the theory that
///    "`mediaURL` moving to a new file" was what made the old directory safe to delete; review
///    caught that the deletion ran BEFORE `mediaURL` actually moved, and that the real guarantee
///    lived in `beginOpenRecording()`'s earlier `mediaURL = nil` — a fact the comment never
///    named. **Round 3 correction, because the round-2 fix overstated itself the same way:**
///    tying the deletion to `.onDisappear` NARROWS the dependency on `beginOpenRecording()`, it
///    does not remove it — `StageWindow` carries no `.id(mediaURL)`, so `.onDisappear` fires at
///    all only because that earlier `mediaURL = nil` swaps `ContentView`'s `Group` branch out
///    entirely, which is what gives the old and new `StageWindow` calls distinct view identities.
///    See item 2's own account of what happens if that assumption is ever defeated.
/// 2. **Swept on launch**: `sweepLeftoverDirectories()`, below, called once from
///    `RecordingCoordinator.init()` — the backstop for exits rule 1 cannot reach (force-quit, a
///    crash, `killall`), none of which ever fire `.onDisappear`, **and now also the backstop for
///    rule 1 itself failing to fire.** If `beginOpenRecording()`'s early `mediaURL = nil` is ever
///    deferred or removed — the exact UX change review round 2's own finding named, keeping the
///    old preview visible while a new recording runs — SwiftUI would most likely update the same
///    `StageWindow` instance's `mediaURL` in place rather than tearing it down, `.onDisappear`
///    would never fire, and `sourceSelected`'s own outgoing-sink check would also decline to
///    delete (`mediaSourceSink` still names the sink in question). The directory would LEAK, not
///    get deleted under a live player — a real degradation from "always deleted promptly," but a
///    bounded one: this sweep still reclaims it on the next launch. Every directory this sink
///    ever creates is named `soredemo-preview-<uuid>`, a naming convention that did NOT change
///    when the layout below did — so a sweep keyed on that PREFIX deletes a leftover flat
///    `master-00.mov` directory (pre-Task-5.5) and a leftover `media/`+`observations/` package
///    directory (post-Task-5.5) identically, without needing to know which layout it is looking
///    at. A sweep that inspected the CONTENTS to decide what counts as this type's own directory
///    would need updating every time the layout changed again; this one does not, because it
///    never looks past the name Task 4's own `init()` already commits to.
///
/// **Media now lands under a `media/` subdirectory, not flatly — a correction from Task 5.5.**
/// `ObservationWriter.expectedLogURL(forMediaURL:)`'s own doc comment used to cite this type's flat
/// layout as the reason it correctly answers `nil` for every recording made through this window:
/// no `media/` parent meant no log could ever be found beside one. Task 5.5 gives `CaptureSession`
/// an `ObservationWriter` to write to, and it writes to exactly the sibling
/// `expectedLogURL(forMediaURL:)` derives from a `media/master-NN.mov` path — so this sink now
/// produces that shape, and `packageURL` (below) is the root both `media/` and `observations/`
/// sit under, which `CaptureSession` needs to open the observation log at all.
final class TemporaryFileMediaSink: MediaSink, @unchecked Sendable {
    /// The naming convention every directory this type ever creates carries, and the ONE thing
    /// `sweepLeftoverDirectories()` below trusts to identify "a directory this type made" — never
    /// the layout inside it, which has already changed once (Task 5.5) and could again.
    private static let directoryNamePrefix = "soredemo-preview-"

    /// The package root — parent of both `media/` (this type) and `observations/`
    /// (`ObservationWriter`, via `packageURL` below).
    private let directory: URL
    private var urlsByName: [String: URL] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "\(Self.directoryNamePrefix)\(Minting.newIdentifier().uuidString)",
                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "media", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }

    /// The launch-time backstop for the lifecycle this type's own header describes —
    /// `RecordingCoordinator.init()` calls this once. Deletes EVERY `soredemo-preview-*`
    /// directory under `NSTemporaryDirectory()`, regardless of what is inside it: a leftover flat
    /// `master-00.mov` from before Task 5.5, or a leftover `media/`+`observations/` package from
    /// after — both are covered by the same prefix check, because the prefix is what never
    /// changed. Safe to run unconditionally at launch: nothing has recorded anything yet, so no
    /// `mediaURL`/`AVPlayer` can be pointing into any directory this sweeps.
    ///
    /// `try?` on the removal, not `try`: one directory this process cannot delete (permissions, a
    /// concurrent Finder operation) must not stop the sweep from clearing every other one, and a
    /// launch-time cleanup failing silently for a single leftover temp directory is not a fact
    /// worth surfacing to the person trying to record something.
    static func sweepLeftoverDirectories() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(directoryNamePrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    @MainActor
    func acceptMedia(_ data: Data, named name: String) throws {
        let url = directory.appending(path: "media", directoryHint: .isDirectory).appending(path: name)
        try data.write(to: url)
        urlsByName[name] = url
    }

    @MainActor
    func url(for name: String) -> URL? { urlsByName[name] }

    /// The package root, for `CaptureSession` to open an `ObservationWriter` under — see
    /// `MediaSink.packageURL`'s own doc comment. Never `nil`: unlike `ProjectDocument`, a scratch
    /// sink always has somewhere to write the moment it exists.
    @MainActor
    var packageURL: URL? { directory }
}
