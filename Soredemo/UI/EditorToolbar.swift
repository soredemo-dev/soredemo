import SwiftUI
import Timeline

/// The strip of controls above the timeline.
///
/// **Every action here already existed and was reachable only by keyboard.** Splitting, ripple
/// delete, keep-only-selection, revert, zoom — all of them shipped as shortcuts with nothing on
/// screen to say so, which is the same as not shipping them for anyone who has not read the
/// source. `../opensource/Screen Record Opensource/a native editor`'s `ToolbarView` puts undo,
/// the tool modes, split, the two trim-to-playhead brackets and the zoom control in one row above
/// its timeline for exactly this reason, and a Swift recorder does the same above its preview.
///
/// **The shortcut is in the tooltip, not on the button.** A label beside every icon would double
/// the strip's width for information a person needs once; a tooltip is where macOS puts it, and
/// the undo and redo tooltips name the actual edit — "Undo Split", not "Undo".
struct EditorToolbar: View {
    let model: TimelineEditorModel
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: Space.regular) {
            history
            separator
            cutting
            separator
            reverting
            Spacer(minLength: Space.regular)
            zoom
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 34)
        .background(Theme.Surface.raised)
    }

    @ViewBuilder private var history: some View {
        ToolbarAction(icon: "arrow.uturn.backward",
                      help: model.undoTitle ?? "Nothing to undo",
                      isEnabled: model.canUndo) {
            model.undo()
            onChange()
        }
        ToolbarAction(icon: "arrow.uturn.forward",
                      help: model.redoTitle ?? "Nothing to redo",
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
        // every editor in the reference set labels the pair.
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
    let help: String
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
