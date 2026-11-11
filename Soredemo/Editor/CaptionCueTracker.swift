import SwiftUI
import Timeline

/// Keeps `CaptionsModel.currentCueIndex` in step with the playhead, and is the only view in the
/// editor that watches the playhead at the playhead's own rate.
///
/// **A view that draws nothing, because the watching has to happen inside some body.**
/// `onChange(of:)` reads `timeline.playhead`, and `@Observable` attributes that read to whatever
/// body performed it — so put the read anywhere else and that view rebuilds ten times a second.
/// Here, what rebuilds ten times a second is a zero-sized `Color.clear`.
///
/// **It writes an index, and the index is what everything downstream reads.** The caption list,
/// its highlight and its follow-the-playhead scroll all want "which cue is on screen", which
/// changes a few times a minute. Deriving that inside the list meant handing the list the
/// playhead, which changes ten times a second — measured at the main thread being 0.1% idle
/// during playback with the caption tab open, against 23% with it closed. See
/// `docs/design/why-the-editor-felt-slow.md`.
///
/// **Not folded into `AtPlayhead`.** That one hands a value down and writes nothing; this one
/// writes model state, which a body may not do — hence `onChange`, which runs after the update
/// rather than during it.
struct CaptionCueTracker: View {
    let timeline: TimelineEditorModel
    let captions: CaptionsModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // **`initial: true`, because a project opens with the playhead at zero and no
            // change follows.** Without it a recording whose first cue starts at zero would
            // open with nothing highlighted until somebody pressed play.
            .onChange(of: timeline.playhead, initial: true) { _, now in
                captions.noteCurrentCue(at: now.nanoseconds)
            }
            // A new track means every index means something else — a re-transcribe, an import,
            // or an opened project — so the answer is re-taken rather than left stale.
            .onChange(of: captions.track) {
                captions.noteCurrentCue(at: timeline.playhead.nanoseconds)
            }
    }
}
