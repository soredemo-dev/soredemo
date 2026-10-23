import Foundation
import Overlays
import SwiftUI
import Timeline

/// The timeline: one lane per track, stacked and aligned, with the playhead over all of them.
///
/// **Each lane is its own view and reads only what it draws** — see
/// `docs/design/2026-10-23-splitting-the-timeline.md`. This file's history is a run of fixes for
/// a body that read the playhead and so rebuilt every lane ten times a second (`AtPlayhead`);
/// lanes observed separately cannot drag each other through a rebuild.
struct TimelineEditor: View {
    let model: TimelineEditorModel
    /// Called after any edit, so the host rebuilds the composition and the preview follows.
    let onChange: () -> Void
    /// The frames drawn along the video track. Owned by the host so it survives a rebuild of
    /// this view — a cache discarded on every edit would re-decode the whole strip per keystroke.
    var filmstrip: Filmstrip?
    /// **The other tracks, drawn but not edited here.** Text, captions and redactions were
    /// invisible on the timeline: a person could add a title and see nothing on the one surface
    /// that says WHEN things happen. Their own panels still own the editing — this shows where
    /// they are, which is what a timeline is for.
    var texts = TextTrack()
    var captions = CaptionTrack()
    var redactions = RedactionTrack()
    var chapters = ChapterTrack()

    var body: some View {
        if let duration = model.duration, duration.rawValue > 0 {
            VStack(alignment: .leading, spacing: 2) {
                TimelineLane(nil, nil, height: 16) { TimelineRuler(model: model) }
                // Directly under the ruler, because a chapter is a point in time like a tick is,
                // and only while there are any — `Silence`'s reason.
                if !chapters.isEmpty {
                    TimelineLane("Chapters", "list.bullet.rectangle", height: 14) {
                        TimelineChapterMarks(model: model, chapters: chapters)
                    }
                }
                TimelineLane("Video", "film", height: 44) {
                    TimelineClipStrip(model: model, filmstrip: filmstrip, onChange: onChange)
                }
                // One lane per recorded track, named for the source it came from. A single
                // "Audio" lane over both answered "is there sound here" and could not answer
                // "is that me or the machine" — which is the question someone deciding whether
                // to keep their narration is asking.
                if model.trackWaveforms.isEmpty {
                    TimelineLane("Audio", "waveform", height: 30) {
                        TimelineAudioLane(model: model, envelope: nil)
                    }
                } else {
                    ForEach(Array(model.trackWaveforms.enumerated()), id: \.offset) { index, envelope in
                        TimelineLane(TimelineAudioLane.trackName(index),
                                     TimelineAudioLane.trackIcon(index), height: 26) {
                            TimelineAudioLane(model: model, envelope: envelope,
                                              tint: TimelineAudioLane.tint(index))
                        }
                    }
                }
                // Same glyph as the Zooms tab and the review sheet, and deliberately NOT
                // the toolbar's magnifier, which zooms the timeline rather than the camera.
                TimelineLane("Zooms", "dot.viewfinder", height: 18) {
                    TimelineZoomLane(model: model, onChange: onChange)
                }
                // Only while there is something to show. A permanently empty lane is a lane a
                // person learns to ignore, and this one is empty until they ask.
                if !model.silences.isEmpty {
                    TimelineLane("Silence", "waveform.slash", height: 12) {
                        TimelineBlocks(model: model, spans: model.silences.map { ($0.start, $0.end) },
                                       tint: Theme.Ink.secondary)
                    }
                }
                if !texts.isEmpty {
                    TimelineLane("Text", "textformat", height: 14) {
                        TimelineBlocks(model: model, spans: texts.items.map { ($0.start, $0.end) },
                                       tint: Theme.Lane.text)
                    }
                }
                if !captions.isEmpty {
                    TimelineLane("Captions", "captions.bubble", height: 14) {
                        // **Clicking a block moves the playhead to that cue**, which is the one
                        // connection the two surfaces were missing: the caption panel already
                        // lights and scrolls to the cue the playhead is in, so selecting follows
                        // from seeking rather than being a second kind of selection to keep in
                        // step with the first.
                        TimelineBlocks(model: model, spans: captions.cues.map { ($0.start, $0.end) },
                                       tint: Theme.Lane.caption,
                                       onTap: { index in
                                           guard captions.cues.indices.contains(index) else { return }
                                           model.movePlayhead(to: captions.cues[index].start)
                                       })
                    }
                }
                if !redactions.isEmpty {
                    TimelineLane("Hide", "eye.slash", height: 14) {
                        TimelineBlocks(model: model, spans: redactions.items.map { item in
                            // A region covering the whole recording is drawn as one block
                            // spanning it, rather than as nothing — which is what an
                            // unset start and end would otherwise render as.
                            item.coversEverything ? (Nanoseconds(0), duration)
                                                  : (item.start, item.end)
                        }, tint: Theme.Lane.hide)
                    }
                }
                readout(duration: duration)
                shortcutLayer
            }
            // An overlay rather than a row in the stack: each has to cross the lane gaps, and
            // must not take a hit test away from the strip underneath. The shade goes under the
            // playhead, which must stay readable over it.
            .overlay(alignment: .topLeading) { TimelineExportRangeShade(model: model) }
            .overlay(alignment: .topLeading) { TimelinePlayheadLine(model: model) }
            // The editor's unmodified keys. Asked at the moment the key arrives, so a caption
            // field that has the caret keeps every one of them — see `BareKeys`.
            .bareKeys([.nudgeLeft, .nudgeRight, .coarseLeft, .coarseRight,
                       .split, .deleteClip, .markIn, .markOut]) {
                perform($0, duration: duration)
            }
        } else {
            Text("Loading the recording…").foregroundStyle(.secondary).font(Type.detail)
        }
    }

    /// Runs one of the editor's unmodified keys.
    ///
    /// **These were zero-opacity `Button`s with `.keyboardShortcut`, and that was measured
    /// wrong.** The comment on them said a `Button`'s shortcut is the only thing that respects
    /// the responder chain. Driven with synthesised events against a caption field that had the
    /// caret, all six were taken and none reached the field: a caption could not take the
    /// letter `s`, its caret could not be moved, and backspace deleted nothing. `unlessTyping`
    /// only stopped the action, so the key did nothing at all rather than the wrong thing —
    /// which is what "the arrow keys sometimes stop working" was. See `BareKeys`.
    private func perform(_ action: BareKeys.Action, duration: Nanoseconds) {
        switch action {
        case .nudgeLeft: nudge(by: -Self.frameStep, duration: duration)
        case .nudgeRight: nudge(by: Self.frameStep, duration: duration)
        case .coarseLeft: nudge(by: -Self.secondStep, duration: duration)
        case .coarseRight: nudge(by: Self.secondStep, duration: duration)
        case .split:
            guard model.canSplitAtPlayhead else { return }
            model.splitAtPlayhead()
            onChange()
        case .deleteClip:
            guard model.selectedClip != nil else { return }
            model.deleteSelectedClip()
            onChange()
        case .markIn: model.markIn()
        case .markOut: model.markOut()
        // Not this view's: the player is the transport bar's. Listed so a case added to
        // `BareKeys.Action` cannot be forgotten here — the handler above declines it anyway.
        case .togglePlay: break
        }
    }

    /// One frame at 60 fps — the rate the export is resampled to, so a nudge moves the
    /// playhead by exactly one frame of the video a person will get.
    static let frameStep: Int64 = 16_666_667
    static let secondStep: Int64 = 1_000_000_000

    /// Where the playhead sits across the strip, clamped — a keyboard zoom anchors here, and
    /// a playhead scrolled off the edge would otherwise anchor outside the view.
    private var playheadAnchor: Double {
        min(max(model.window.fraction(of: model.playhead), 0), 1)
    }

    private func nudge(by delta: Int64, duration: Nanoseconds) {
        let moved = min(max(model.playhead.rawValue + delta, 0), duration.rawValue)
        model.movePlayhead(to: Nanoseconds(moved))
        // The clip under the playhead follows it, so ← / → walk the clips as well as the time.
        model.selectClip(atSource: model.playhead)
        // …and the view follows the playhead off the edge, but only when it has gone off.
        model.revealPlayhead()
    }

    @ViewBuilder private func readout(duration: Nanoseconds) -> some View {
        HStack {
            // **The timecode is the whole reason this timeline used to rebuild during playback.**
            // Reading `model.playhead` in a `@ViewBuilder` method of this struct is a read by
            // THIS body, so one `Text` dragged every lane, every clip, every caption block and
            // the waveform through a fresh layout ten times a second. See `AtPlayhead`.
            AtPlayhead(model: model) { Text(verbatim: Self.stamp($0)) }
            Spacer()
            if let selection = model.selection {
                Text("selected \(Self.stamp(Nanoseconds(Int64(selection.count))))")
            } else if let selected = model.selectedClip,
                      let clip = model.edit.clips.first(where: { $0.id == selected }) {
                Text("clip \(Self.stamp(clip.duration)) of \(model.edit.clips.count)")
            } else {
                Text("\(Self.stamp(model.edit.outputDuration)) of \(Self.stamp(duration))")
            }
        }
        .font(Type.readout).foregroundStyle(Theme.Ink.secondary)
    }

    /// **The keyboard shortcuts, with no buttons on them.**
    ///
    /// This used to be two rows of `.link`-styled buttons under the strip — which is where the
    /// last of the system's blue in this window was living, and which duplicated every control
    /// `EditorToolbar` now shows. What could not be deleted with them is the shortcuts: a
    /// `.keyboardShortcut` has to be attached to a live view, and these are the keys an editing
    /// session is actually driven by. Zero-sized and hidden from accessibility, because the
    /// toolbar's buttons are the ones a reader should find.
    @ViewBuilder private var shortcutLayer: some View {
        Group {
            // **`canSplitAtPlayhead` reads the playhead**, so `.disabled` on it is a read by
            // this body — the last one in this file, and the one that kept the whole timeline
            // rebuilding after the other four were moved. Found with `Self._printChanges()`,
            // not by reading: four rounds of "surely that is the last one" had already been
            // wrong. See `AtPlayhead`.
            // **`S`, `Delete`, `I` and `O` are not here any more, and could not be.** They are
            // unmodified — the spelling every editor uses for split, delete, mark in and mark
            // out — and a `.keyboardShortcut` on an unmodified key is taken from a caption
            // field that has the caret. They live in `BareKeys` now, which is asked at the
            // moment the key arrives and declines while somebody is typing. What stays here is
            // everything carrying ⌘ or ⌥, which SwiftUI does exempt.
            Button("Clear range") { model.clearExportRange() }
                .disabled(model.inPoint == nil && model.outPoint == nil)
                .keyboardShortcut("i", modifiers: [.option])
            Button("Undo") { model.undo(); onChange() }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { model.redo(); onChange() }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            // Zoom anchored on the PLAYHEAD for a keyboard zoom: it keeps what a person is
            // looking at where they are looking. The toolbar's buttons anchor at the middle,
            // because a click has no position — see `EditorToolbar.zoom`.
            Button("Zoom in") { model.zoomStrip(by: 2, anchoredAtFraction: playheadAnchor) }
                .disabled(!model.window.canZoomIn)
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom out") { model.zoomStrip(by: 0.5, anchoredAtFraction: playheadAnchor) }
                .disabled(!model.window.canZoomOut)
                .keyboardShortcut("-", modifiers: .command)
            Button("Fit") { model.showWholeRecording() }
                .disabled(!model.window.canZoomOut)
                .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    static func stamp(_ time: Nanoseconds) -> String {
        let seconds = Double(time.rawValue) / 1_000_000_000
        return String(format: "%d:%05.2f", Int(seconds) / 60,
                      seconds.truncatingRemainder(dividingBy: 60))
    }
}
