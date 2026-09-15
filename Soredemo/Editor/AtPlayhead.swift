import SwiftUI
import Timeline

/// Reads the playhead so that whoever draws this does not.
///
/// **A value that changes ten times a second must not be read by a body that builds a window.**
/// `@Observable` registers the dependency on whichever body performed the read, and the body
/// performing it was `StageWindow`'s: seven `timeline.playhead` arguments handed down to the
/// inspector panels and the caption editor, plus `model.canSplitAtPlayhead` in the toolbar and
/// the timecode in the timeline's own readout. So every tick `TransportBar` publishes — 10 Hz,
/// the whole time a recording is playing — invalidated the preview, the inspector, the toolbar
/// and every lane of the timeline, all of which then had to lay out again.
///
/// Measured on a 3492x1964 recording, `sample` over six seconds of playback: 392 of 1551
/// main-thread samples (25%) inside `-[NSWindow layoutIfNeeded]`, in a `_layoutSubtreeWithOldSize:`
/// recursion eight levels deep, with `NSHostingView is being laid out reentrantly while rendering
/// its SwiftUI content. This is not supported and the current layout pass will be skipped.` in
/// the log beside it. A skipped layout pass is a dropped frame that no video code produced.
///
/// **It was not the compositor, and that was measured too rather than assumed.** The same
/// recording composites at 117.6 frames per second through `AVAssetReaderVideoCompositionOutput`
/// at full export resolution — nearly twice what 60 fps playback asks for — so lowering the
/// preview's render size would have bought a smoother number on a graph and changed nothing a
/// person could see.
///
/// **A view rather than a `Binding` or a captured value.** The read has to happen inside some
/// body for `@Observable` to attribute it there, and this is the smallest body that can own it.
/// The panels keep taking a plain `Nanoseconds` — they are pure in their inputs on purpose, and
/// handing them the model to dig the value out of themselves would trade this defect for a
/// wider one.
struct AtPlayhead<Content: View>: View {
    let model: TimelineEditorModel
    @ViewBuilder let content: (Nanoseconds) -> Content

    var body: some View { content(model.playhead) }
}
