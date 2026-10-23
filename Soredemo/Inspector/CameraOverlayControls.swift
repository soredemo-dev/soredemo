import SwiftUI
import Compositing
import Render

/// Where the camera sits. **Shown only when the recording HAS one** — controls for a track
/// that does not exist are controls a person changes and sees nothing happen.
///
/// **The nine-place grid is gone, because the camera can be dragged.** It was added when
/// the only alternative was two sliders, and that argument was sound then — almost every
/// camera goes in a corner, and finding a corner by aiming two sliders is a job. It stopped
/// being sound when the overlay became draggable: pointing at where the camera should go IS
/// the grid's whole justification, and dragging it there is the same gesture with none of
/// the chrome. Two controls for one decision is one more than the decision has.
///
/// Moved out of `StageWindow` — step 1 of `docs/design/2026-10-23-splitting-the-stage-window.md`.
struct CameraOverlayControls: View {
    @Bindable var editor: EditorViewModel
    /// Called after each change, so a paused preview redraws.
    let onChange: () -> Void

    var body: some View {
        Toggle("Show camera", isOn: Binding(
            get: { !editor.cameraStyle.isHidden },
            set: { editor.cameraStyle = editor.cameraStyle.changing(isHidden: !$0); onChange() }))
        // **The room behind the person, cut away or kept** — see `PersonMask`.
        //
        // Turning it on warms Vision's models on a detached task. The first segmentation of each
        // level costs one to two seconds loading the model and every one after it costs 21 ms;
        // paid here, seconds before anybody scrubs to a frame with a camera in it, it is never
        // paid on a frame somebody is waiting for. Detached because it is not the picker's job
        // to wait for it, and nothing about the answer is needed to draw the next frame.
        Picker("Background", selection: Binding(
            get: { editor.cameraStyle.background },
            set: { editor.cameraStyle = editor.cameraStyle.changing(background: $0)
                   if $0 == .removed { Task.detached(priority: .utility) { PersonMask.warmUp() } }
                   onChange() })) {
            ForEach(CameraOverlayStyle.Background.allCases, id: \.self) {
                Text(LocalizedStringKey($0.displayName)).tag($0)
            }
        }
        // **The system's own blur is one control away and is not reimplemented here.** Portrait
        // mode runs inside the camera pipeline for free; a hand-written blur would be slower and
        // worse. Said in the interface because somebody looking for "blur my background" will
        // look here first, and sending them two clicks away beats offering them a worse copy.
        if editor.cameraStyle.background == .keep {
            Text("To blur the background instead, turn on Portrait in the camera effects.")
                .font(Type.detail).foregroundStyle(.secondary)
        } else {
            // **The cost, on screen, before it is discovered.** Cutting a person out is 21 ms a
            // frame — measured — on top of everything else a frame costs, and somebody whose
            // preview has just become less smooth is owed the reason rather than left to
            // conclude the app got slower. Nothing is sent anywhere: this runs on this Mac.
            Text("Cut out on this Mac, frame by frame — around 21 ms each, so previews and exports take longer with this on.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        // **A cut-out person has no card**, so the controls that shape one are not offered while
        // the background is gone. They keep their values — switching back restores the card
        // exactly — they simply do nothing, and a control that does nothing is one people
        // conclude is broken. The same argument the corner slider already makes for a circle.
        if editor.cameraStyle.background == .keep {
            Picker("Shape", selection: Binding(
                get: { editor.cameraStyle.shape },
                set: { editor.cameraStyle = editor.cameraStyle.changing(shape: $0); onChange() })) {
                ForEach(CameraOverlayStyle.Shape.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.displayName)).tag($0)
                }
            }
        }
        // **Only for the shape that has corners.** A slider that does nothing on a circle and
        // nothing on a square is a slider people conclude is broken.
        if editor.cameraStyle.shape == .rounded, editor.cameraStyle.background == .keep {
            Slider(value: Binding(
                get: { editor.cameraStyle.cornerFraction },
                set: { editor.cameraStyle = editor.cameraStyle.changing(cornerFraction: $0)
                       onChange() }),
                   in: 0...0.5) { Text("Corner") }
        }
        Slider(value: Binding(get: { editor.cameraStyle.widthFraction },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(widthFraction: $0)
                                     onChange() }),
               in: 0.05...0.5) { Text("Size") }
        // **How much the camera shrinks while the stage is zoomed in.** A zoom makes the picture
        // bigger, and a camera that holds its width is covering a larger share of a smaller area
        // — which is exactly when it is most in the way. 1 holds the size, which is what this
        // did before the control existed.
        Slider(value: Binding(get: { editor.cameraStyle.scaleDuringZoom },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(scaleDuringZoom: $0)
                                     onChange() }),
               in: 0.3...1) { Text("Shrink on zoom") }
        Slider(value: Binding(get: { editor.cameraStyle.x },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(x: $0)
                                     onChange() }),
               in: 0...1) { Text("Across") }
        Slider(value: Binding(get: { editor.cameraStyle.y },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(y: $0)
                                     onChange() }),
               in: 0...1) { Text("Up from the bottom") }
        // **Out of the cursor's way.** The classic flaw is a face over the thing being shown.
        // The camera goes to a corner while the cursor is on it and comes back once the cursor
        // has been clear for a while; see `CameraDodge`.
        Toggle("Move out of the cursor's way", isOn: Binding(
            get: { editor.cameraStyle.avoidsCursor },
            set: { editor.cameraStyle = editor.cameraStyle.changing(avoidsCursor: $0); onChange() }))
            .font(Type.detail)
        Toggle("Mirror", isOn: Binding(
            get: { editor.cameraStyle.isMirrored },
            set: { editor.cameraStyle = editor.cameraStyle.changing(isMirrored: $0); onChange() }))
    }
}
