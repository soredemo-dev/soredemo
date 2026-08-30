import Compositing
import AppKit
import Overlays
import SwiftUI
import Timeline

/// The strip of controls above the timeline.
///
/// **Every action here already existed and was reachable only by keyboard.** Splitting, ripple
/// delete, keep-only-selection, revert, zoom — all of them shipped as shortcuts with nothing on
/// screen to say so, which is the same as not shipping them for anyone who has not read the
/// source. A toolbar wants undo,
/// the tool modes, split, the two trim-to-playhead brackets and the zoom control in one row above
/// its timeline for exactly this reason.
///
/// **The shortcut is in the tooltip, not on the button.** A label beside every icon would double
/// the strip's width for information a person needs once; a tooltip is where macOS puts it, and
/// the undo and redo tooltips name the actual edit — "Undo Split", not "Undo".
struct EditorToolbar: View {
    let model: TimelineEditorModel
    let onChange: () -> Void
    /// The recording being edited, which finding still stretches has to decode. `nil` leaves the
    /// control disabled rather than absent: a control that appears when a recording loads is one
    /// people do not find.
    var mediaURL: URL?
    /// The shared queue, observed so this row appears and disappears with a job.
    @State private var exportQueue = ExportQueue.shared
    /// True while the timeline below is collapsed, so the chevron points the right way.
    var isCollapsed = false
    /// `nil` leaves the collapse control out — the toolbar is useful without one.
    var onToggleCollapse: (() -> Void)?

    /// Its own height, exported because the host subtracts it from the split's height to size
    /// the strip. One number in one place; two would drift and the strip would be clipped.
    static let height: Double = 34

    var body: some View {
        HStack(spacing: Space.regular) {
            history
            separator
            cutting
            separator
            speed
            silence
            stillness
            reverting
            Spacer(minLength: Space.regular)
            exportProgress
            zoom
            if let onToggleCollapse {
                separator
                ToolbarAction(icon: isCollapsed ? "chevron.up" : "chevron.down",
                              help: isCollapsed ? "Show the timeline" : "Hide the timeline",
                              isEnabled: true, action: onToggleCollapse)
            }
        }
        .padding(.horizontal, Space.regular)
        .frame(height: Self.height)
        .background(Theme.Surface.raised)
    }

    /// How far the running export has got, and how long is left.
    ///
    /// **Here rather than only in the window's toolbar, because that toolbar is not on screen
    /// when it matters.** The export progress lives in an `ExportQueueButton` toolbar item,
    /// which is the right place for the queue — and the editor opens FULL SCREEN, where
    /// `NSApplicationPresentationOptions.autoHideToolbar` takes the whole toolbar away until
    /// somebody reaches for it. So the one moment a person wants to see how long an export has
    /// left is the one moment the answer is hidden, which is what was reported: "i dont see the
    /// 匯出進度條".
    ///
    /// This row is content, not chrome, so full screen does not touch it.
    ///
    /// **Only while something is running.** A bar that is always there, usually at zero, is a
    /// control people learn not to read — the same argument `ExportQueueButton` makes for not
    /// living in the toolbar permanently.
    ///
    /// The time is the words `ExportETA` already produces and the tables already carry; the
    /// fraction is the same one the queue draws. Nothing here is a second opinion about either.
    @ViewBuilder private var exportProgress: some View {
        if let job = exportQueue.jobs.first(where: { $0.status == .running }) {
            HStack(spacing: Space.snug) {
                if let fraction = job.progress?.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                        .controlSize(.small)
                } else {
                    // `finishWriting` reports nothing, and a bar pinned at 100% reads as
                    // stopped rather than as nearly done.
                    ProgressView().controlSize(.small)
                }
                if let reading = job.timeReading {
                    ExportJob.timeText(reading)
                        .font(Type.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            separator
        }
    }

    @ViewBuilder private var history: some View {
        // **The undo title is content, not a key.** It is the name an edit was given — "Cut
        // 3 words" — which is already in the reader's language because the thing that made it
        // was. Wrapped as a key it falls through to itself, which is right; the fallback beside
        // it IS a key.
        ToolbarAction(icon: "arrow.uturn.backward",
                      help: model.undoTitle.map { LocalizedStringKey($0) } ?? "Nothing to undo",
                      isEnabled: model.canUndo) {
            model.undo()
            onChange()
        }
        ToolbarAction(icon: "arrow.uturn.forward",
                      help: model.redoTitle.map { LocalizedStringKey($0) } ?? "Nothing to redo",
                      isEnabled: model.canRedo) {
            model.redo()
            onChange()
        }
    }

    @ViewBuilder private var cutting: some View {
        ToolbarAction(icon: "square.split.2x1", help: "Split at the playhead (S)",
                      isEnabled: model.canSplitAtPlayhead) {
            model.splitAtPlayhead()
            onChange()
        }
        ToolbarAction(icon: "trash", help: "Delete the selected clip (\u{232B})",
                      isEnabled: model.selectedClip != nil) {
            model.deleteSelectedClip()
            onChange()
        }
        // The two selection operations, which are the ones nothing on screen mentioned. "Remove"
        // is a ripple delete and "Keep" is its complement; naming them by what SURVIVES is how
        // the pair is always labelled.
        ToolbarAction(icon: "rectangle.badge.minus", help: "Remove the selected span",
                      isEnabled: model.selection != nil) {
            model.removeSelection()
            onChange()
        }
        ToolbarAction(icon: "rectangle.badge.checkmark", help: "Keep only the selected span",
                      isEnabled: model.selection != nil) {
            model.keepOnlySelection()
            onChange()
        }
    }

    /// How fast the selected clip plays.
    ///
    /// **Per clip, not per timeline.** The point of the control is that the boring middle of a
    /// walkthrough plays at 2× while the part being explained plays at 1 — a single rate for the
    /// whole video is a different feature, and a less useful one.
    @ViewBuilder private var speed: some View {
        Menu {
            ForEach(TimelineEditorModel.speedChoices, id: \.self) { value in
                Button(Self.speedLabel(value)) {
                    model.setSelectedSpeed(value)
                    onChange()
                }
            }
        } label: {
            Text(model.selectedSpeed.map(Self.speedLabel) ?? "1\u{00D7}")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle((model.selectedSpeed ?? 1) == 1
                                 ? Theme.Ink.secondary : Theme.accent)
                .frame(width: 34)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.selectedClip == nil)
        .opacity(model.selectedClip == nil ? 0.35 : 1)
        .help(model.selectedClip == nil ? "Select a clip to change its speed"
              : "How fast the selected clip plays")
    }

    /// `2×`, `0.5×` — trailing zeroes dropped, as the transport's rate label does.
    static func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))\u{00D7}" : String(format: "%.2g\u{00D7}", value)
    }

    /// Finding and cutting the pauses.
    ///
    /// **Two presses, not one.** Finding shows the spans on their own lane; cutting removes
    /// them. A single button that did both would make an irreversible-looking edit out of a
    /// threshold nobody had seen the effect of — and the whole difficulty of dead-air removal is
    /// that the right threshold is different for every room.
    @ViewBuilder private var silence: some View {
        if model.silences.isEmpty {
            ToolbarAction(icon: "waveform.badge.magnifyingglass",
                          help: "Find the silent stretches",
                          isEnabled: model.waveform != nil) {
                model.findSilences()
            }
        } else {
            ToolbarAction(icon: "waveform.slash",
                          // One interpolation, not a `+`: concatenation makes a `String`, and
                          // a `String` is drawn verbatim. Interpolated, the key is
                          // "Remove %lld silent stretch(es), %@ in all".
                          help: "Remove \(model.silences.count) silent stretch(es), \(EditorToolbar.seconds(SilenceFinder.total(model.silences))) in all",
                          isEnabled: true) {
                model.removeSilences()
                onChange()
            }
        }
    }

    /// Finding and cutting the stretches where the picture does not change.
    ///
    /// **The same two presses the silence pair uses, and for the same reason**: finding shows what
    /// would go, cutting removes it. A single button would make an irreversible-looking edit out
    /// of a threshold nobody had seen the effect of.
    ///
    /// **A third state the silence pair does not need: measuring.** Silence is read from a
    /// waveform the editor already has; stillness has to decode the recording, which takes long
    /// enough that a button doing nothing for four seconds reads as broken.
    @ViewBuilder private var stillness: some View {
        if let progress = model.stillnessProgress {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Looking for still stretches\u{2026}")
        } else if model.stillness.isEmpty {
            ToolbarAction(icon: "rectangle.on.rectangle.slash",
                          help: "Find the stretches where nothing moves",
                          isEnabled: mediaURL != nil) {
                if let mediaURL { model.findStillness(in: mediaURL) }
            }
        } else {
            ToolbarAction(icon: "scissors.badge.ellipsis",
                          help: "Remove \(model.stillness.count) still stretch(es), \(EditorToolbar.seconds(StillnessFinder.total(model.stillness))) in all",
                          isEnabled: true) {
                model.removeStillness()
                onChange()
            }
        }
    }

    /// Seconds, to one decimal — what a person compares against the length beside it.
    static func seconds(_ value: Nanoseconds) -> String {
        String(format: "%.1fs", Double(value.rawValue) / 1_000_000_000)
    }

    @ViewBuilder private var reverting: some View {
        ToolbarAction(icon: "arrow.counterclockwise", help: "Revert every edit",
                      isEnabled: model.hasEdits) {
            model.restore()
            onChange()
        }
    }

    /// Zooming the strip. **The anchor is the middle of the view, not the playhead**: a button
    /// press has no position, and zooming toward a playhead that may be off screen moves the
    /// view somewhere a person did not ask to go.
    @ViewBuilder private var zoom: some View {
        ToolbarAction(icon: "minus.magnifyingglass", help: "Zoom out (\u{2318}-)", isEnabled: true) {
            model.zoomStrip(by: 1 / 1.5, anchoredAtFraction: 0.5)
        }
        ToolbarAction(icon: "plus.magnifyingglass", help: "Zoom in (\u{2318}=)", isEnabled: true) {
            model.zoomStrip(by: 1.5, anchoredAtFraction: 0.5)
        }
        ToolbarAction(icon: "arrow.left.and.right", help: "Show the whole recording (\u{2318}0)",
                      isEnabled: true) {
            model.showWholeRecording()
        }
        Text(Self.span(model.window.visible))
            .font(Type.readout)
            .foregroundStyle(Theme.Ink.secondary)
            .frame(width: 54, alignment: .trailing)
            .help("How much of the recording the strip is showing")
    }

    @ViewBuilder private var separator: some View {
        Rectangle().fill(Theme.Line.hairline).frame(width: 1, height: 16)
    }

    /// The visible span, in the largest unit that keeps it readable — a strip zoomed into a
    /// third of a second should say "0.3s", not "0:00".
    static func span(_ visible: Nanoseconds) -> String {
        let seconds = Double(visible.rawValue) / 1_000_000_000
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// One icon button. Disabled rather than hidden when it cannot act: a strip whose controls come
/// and go is a strip a person cannot learn the shape of.
private struct ToolbarAction: View {
    let icon: String
    /// **`LocalizedStringKey`, not `String`, and the difference is the whole feature.**
    /// `.help(String)` binds to SwiftUI's `StringProtocol` overload, which draws the text
    /// verbatim — so every tooltip in this toolbar was English in every language, with nothing
    /// to see and no way for a table entry to reach it. A key is looked up.
    let help: LocalizedStringKey
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.Ink.primary : Theme.Ink.tertiary)
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering && isEnabled ? Theme.Fill.hover : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}


/// The draggable line between the preview and the timeline.
///
/// **Hand-rolled because `VSplitView` cannot do the two things that matter**: it cannot be
/// collapsed from code, and it forgets where it was left. Giving every one of the
/// five panels an `autosaveName` and a collapse; a timeline you have to re-drag every launch is
/// one you stop dragging.
///
/// The hit area is taller than the line. A one-pixel target is a target people miss, and
/// a divider's hit rect has to be wider than its line for the same reason
/// (`PaddedDividerSplitViewController`).
struct SplitHandle: View {
    /// The INCREMENT since the last callback, in points, positive downward.
    let onDrag: (Double) -> Void
    @State private var isHovering = false
    /// **`DragGesture.translation` is cumulative from where the drag began**, so handing it
    /// straight to a caller that adds it to a height moves that height by the whole distance on
    /// every callback — the strip jumps to a limit on the first few points of a drag. This is
    /// the running total, subtracted to get the step.
    @State private var applied: Double = 0

    var body: some View {
        Rectangle()
            .fill(isHovering ? Theme.Line.divider : Theme.Line.hairline)
            .frame(height: 1)
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let total = Double(value.translation.height)
                        onDrag(total - applied)
                        applied = total
                    }
                    .onEnded { _ in applied = 0 }
            )
            .accessibilityLabel("Resize the timeline")
    }
}
