import SwiftUI
import Framing

/// How far the derived zooms go, and how fast the camera moves between them.
///
/// Moved out of `StageWindow` — step 1 of `docs/design/2026-10-23-splitting-the-stage-window.md`.
struct ZoomAmountControls: View {
    @Bindable var editor: EditorViewModel
    /// Called when a drag ends or the pace changes, so a paused preview redraws.
    let onChange: () -> Void

    var body: some View {
        // **The one control that still commits on release, and it is not the camera's rule.**
        // Every other control in this window now refreshes on every change: publishing a static
        // and asking a paused player to redraw costs a seek, which AVPlayer coalesces. This one
        // is different in kind — `.task(id: zoomIntensity)` re-derives the zoom BLOCKS through
        // `refreshDerivedZooms`, which walks the framing plan and rebuilds the camera's baked
        // path, and doing that per pixel of slider travel is work rather than a redraw. The
        // lane's blocks move on release; the number under the thumb moves live.
        //
        // The comment here used to say "the same rule the camera sliders already use". That
        // stopped being true on 2026-08-26, when they stopped using it.
        Slider(value: $editor.zoomIntensity, in: 0...FramingDepth.maximumIntensity, step: 0.1,
               onEditingChanged: { if !$0 { onChange() } }) {
            Text("Amount")
        }
        Text(verbatim: zoomIntensityLabel)
            .font(Type.detail).foregroundStyle(.secondary)
        // The spring's damping stays at 1 whatever this says, so no pace overshoots.
        Picker("Speed", selection: $editor.cameraPace) {
            ForEach(CameraPace.allCases, id: \.self) { pace in
                Text(LocalizedStringKey(pace.displayName)).tag(pace)
            }
        }
        .onChange(of: editor.cameraPace) { onChange() }
    }

    /// Says what the dial does at the ends, because "0.0" and "2.0" do not.
    private var zoomIntensityLabel: String {
        let percent = Int((editor.zoomIntensity * 100).rounded())
        if percent == 0 { return String(localized: "No zoom anywhere. Every click is framed, none is magnified.") }
        if percent == 100 {
            return String(localized: "As derived. Adjustments you have made to single zooms still apply on top.")
        }
        return String(localized: "\(percent)% of the derived zoom. Adjustments to single zooms still apply on top.")
    }
}
