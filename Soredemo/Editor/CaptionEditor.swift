import AppKit
import Compositing
import Foundation
import Overlays
import SwiftUI
import Timeline

/// The whole window, given over to captions.
///
/// **Why this exists at all, when the inspector already has every control.** The gap table in
/// docs/design/what-a-caption-editor-is.md is nearly all filled in — seek on click, follow the
/// playhead, search, per-cue measurements, split and merge, retiming, snapping. What it could
/// not fill in is room. `InspectorWidth` carries the measurement: a caption row needs about
/// 437pt and the inspector opens at 300, so by default the line a person is being asked to fix
/// is truncated, and the red "too long" beside it is an accusation they cannot act on. Widening
/// the inspector was rejected once already, for a good reason — it takes the width from the
/// picture, for one tab.
///
/// So the answer is not a wider inspector. It is that **an hour of caption work is not inspector
/// work**: it has its own transport, its own selection, its own keymap, and it wants the window.
/// The inspector stays exactly as it is, for the correction you make while looking at the shot.
///
/// **Three panes that stay in step**, which is what both surveyed subtitle editors are and what
/// this project's own research concluded a caption editor *is*: the picture with the caption
/// burnt in as it will look, a waveform with a block per cue underneath it, and the cue list at
/// full width beside them. One playhead drives all three.
struct CaptionEditor: View {
    let model: CaptionsModel
    let playhead: Nanoseconds
    let duration: Nanoseconds?
    let waveform: WaveformEnvelope?
    let pauses: [SilenceFinder.Span]
    let onSeek: (Nanoseconds) -> Void
    let onChange: () -> Void
    let onClose: () -> Void
    /// The picture, supplied by the host. **Passed in rather than built here** so this view owns
    /// no video plumbing: the editor window already has a player, and a second one would be a
    /// second thing to keep at the same time as the first.
    @ViewBuilder let picture: () -> AnyView

    /// How much of the recording the waveform shows, as a fraction of the whole. **Not the
    /// timeline's zoom**: the timeline is zoomed to look at cuts and this is zoomed to look at
    /// a sentence, and sharing one number would make each of them fight the other.
    @State private var visibleFraction: Double = 1
    /// What the cue list remembers — held here, not inside the list, for `CaptionListState`'s
    /// reason.
    @State private var listState = CaptionListState()
    @FocusState private var focused: Int?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                picture()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Surface.preview)
                Divider().overlay(Theme.Line.hairline)
                CaptionWaveform(model: model, playhead: playhead, duration: duration,
                                waveform: waveform, visibleFraction: $visibleFraction,
                                onSeek: onSeek, onChange: onChange)
                    .frame(height: 96)
            }
            .frame(minWidth: 420)

            VStack(spacing: 0) {
                CaptionLines(model: model, onChange: onChange, playhead: playhead,
                             onSeek: onSeek, pauses: pauses,
                             state: listState, focused: $focused)
                Divider().overlay(Theme.Line.hairline)
                keys
            }
            // **The measured width, as a floor.** `InspectorWidth.maximum` is 440 because that
            // is what one row needs; this is the same number with the list's own insets, and it
            // is a minimum here rather than a maximum because taking the room is the point.
            .frame(minWidth: 460, idealWidth: 520)
        }
        .background(Theme.Surface.panel)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onClose).keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    /// The keymap, said out loud.
    ///
    /// **Because none of these keys is discoverable.** Return splitting a cue at the caret and
    /// Backspace merging it into the one before are the two operations most caption work is made
    /// of, and both are invisible: nothing in the interface suggests a text field would do that.
    /// Two independent editors converged on this keymap — see the design note — which makes it
    /// worth teaching rather than worth replacing with buttons.
    @ViewBuilder private var keys: some View {
        HStack(spacing: Space.regular) {
            key("return", "split here")
            key("delete.left", "merge with the line above")
            key("arrow.up.arrow.down", "between lines")
            Spacer(minLength: Space.snug)
            Text("\(model.track.cues.count) caption(s)")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 28)
        .background(Theme.Surface.raised)
    }

    @ViewBuilder private func key(_ symbol: String, _ says: LocalizedStringKey) -> some View {
        HStack(spacing: Space.hairline) {
            Image(systemName: symbol).font(Type.detail)
            Text(says).font(Type.detail)
        }
        .foregroundStyle(.secondary)
    }
}
