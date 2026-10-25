import AppKit
import AVFoundation
import Capture
import Combine
import SwiftUI

/// What this app needs before it can record, and how to give it.
///
/// **A first run that fails silently is the commonest way a recorder gets deleted.** Without a
/// grant, `SCStream` reports that the user declined — from an API that never asked them — and a
/// person's first recording is a black rectangle. Opening with a permission page is right for
/// this reason: it is the one screen an application like this cannot do without.
///
/// **Required and optional are separated, and the optional ones say what they cost.** Screen
/// Recording and Accessibility are what the product is; a microphone and a camera are choices,
/// and a person recording a silent UI demo should not be asked to hand over a microphone to get
/// started. `Degradation` already carries which is which, so the split is derived rather than
/// listed twice.
struct PermissionsWindow: View {
    @State private var statuses: [CapturePermission: PermissionStatus] = [:]
    @State private var cameraStatus = CameraRecorder.authorization
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppIconChoice.defaultsKey) private var appIcon = AppIconChoice.black

    /// Permissions the product cannot work without — derived from `Degradation`, so a change to
    /// that mapping moves this list rather than leaving two lists to disagree.
    private var required: [CapturePermission] {
        CapturePermission.allCases.filter {
            CapturePermissions.degradation(for: $0) == .blocksRecording
        }
    }

    private var optional: [CapturePermission] {
        CapturePermission.allCases.filter {
            CapturePermissions.degradation(for: $0) != .blocksRecording
        }
    }

    private var everythingRequiredIsGranted: Bool {
        required.allSatisfy { statuses[$0] == .granted }
    }

    var body: some View {
        VStack(spacing: Space.section) {
            header
            VStack(spacing: Space.regular) {
                ForEach(required, id: \.self) { PermissionRow(permission: $0,
                                                             status: statuses[$0],
                                                             refresh: refresh) }
            }
            VStack(spacing: Space.regular) {
                ForEach(optional, id: \.self) { PermissionRow(permission: $0,
                                                             status: statuses[$0],
                                                             refresh: refresh) }
                CameraRow(status: cameraStatus, refresh: refresh)
            }
            // **The accessibility helper, and only when it is needed.** macOS cannot be told to
            // grant Accessibility; the API opens System Settings and the person does the rest —
            // and if this app is not already listed there, the only way to add it is to drag it
            // in. A floating panel that does exactly this is the one
            // step of the whole flow nobody works out unaided.
            if statuses[.accessibility] != .granted {
                AccessibilityDragHelper()
            }
            Spacer(minLength: 0)
            HStack {
                // **Two `Text`s, not one with a ternary.** `Text(cond ? "a" : "b")` is
                // `Text(String)` — the branches are concatenated into a `String` before the
                // initialiser sees them, so neither is ever a key. This line was English on a
                // Chinese system for that reason alone.
                Group {
                    if everythingRequiredIsGranted {
                        Text("Ready to record.")
                    } else {
                        Text("Soredemo cannot record until the two above are allowed.")
                    }
                }
                    .font(Type.detail)
                    .foregroundStyle(everythingRequiredIsGranted
                                     ? Theme.Ink.secondary : Signal.paused)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!everythingRequiredIsGranted)
            }
        }
        .padding(Space.section)
        .frame(width: 520, height: 620)
        .background(Theme.Surface.panel)
        .onAppear(perform: refresh)
        // **Polled, because a grant happens in another application.** There is no notification
        // for a TCC change; System Settings does not tell anyone. A second is fast enough that
        // the row ticks over while a person is still looking at it.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    @ViewBuilder private var header: some View {
        VStack(spacing: Space.snug) {
            // **One eye per permission the product needs.** The record eye fills when Screen
            // Recording is granted and the waiting eye is painted when Accessibility is, so the
            // mark finishes as the page does — the daruma's own custom, a wish granted.
            DarumaView(pose: .permissions(screenRecording: statuses[.screenRecording] == .granted,
                                          accessibility: statuses[.accessibility] == .granted),
                       icon: appIcon)
                .frame(width: 56, height: 56)
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
                           value: statuses)
            Text("Welcome to Soredemo")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Ink.primary)
            Text("A screen recorder whose camera follows what you click.")
                .font(Type.detail)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: CapturePermission.allCases.map {
            ($0, CapturePermissions.status(of: $0))
        })
        cameraStatus = CameraRecorder.authorization
    }
}

/// One permission: what it is for, what it is doing now, and the button that asks.
private struct PermissionRow: View {
    let permission: CapturePermission
    let status: PermissionStatus?
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.regular) {
            Image(systemName: Self.icon(permission))
                .font(.system(size: 16))
                .foregroundStyle(status == .granted ? Theme.accent : Theme.Ink.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                // `LocalizedStringKey`, because `title` and `reason` hand back a `String` and
                // SwiftUI only looks a string up when it arrives as a key. This is why the four
                // rows stayed English beside a Camera row written as a literal — see
                // `TargetCard` in `MenuBarRecorder.swift`, which had it too.
                Text(LocalizedStringKey(Self.title(permission)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Ink.primary)
                Text(LocalizedStringKey(Self.reason(permission)))
                    .font(Type.detail)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.snug)
            statusControl
        }
        .padding(Space.regular)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.Fill.rest))
    }

    @ViewBuilder private var statusControl: some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(Type.detail)
                .foregroundStyle(Theme.Ink.accent)
                .labelStyle(.titleAndIcon)
        case .restricted:
            // **Not offered a button.** Restricted means an administrator or a profile decided,
            // and a button that cannot work is worse than a sentence that explains.
            Text("Blocked by this Mac's settings")
                .font(Type.detail)
                .foregroundStyle(Signal.paused)
        default:
            Button("Allow\u{2026}") {
                Self.ask(permission)
                refresh()
            }
            .controlSize(.small)
        }
    }

    /// **The request API where one exists, System Settings where it does not.** Screen Recording
    /// and Accessibility both prompt once and never again; after that the only route is the
    /// settings pane, and sending a person there is more use than a button that does nothing on
    /// the second press.
    static func ask(_ permission: CapturePermission) {
        switch permission {
        case .screenRecording:
            PermissionRequests.screenRecording()
            open("Privacy_ScreenCapture")
        case .accessibility:
            // **Settings only, no request call.** `AXIsProcessTrustedWithOptions` shows its
            // dialog once per app and never again — `CaptureSession` makes that one call at the
            // moment it needs the grant. A second caller here would show nothing and would be a
            // second policy for a prompt that has already happened.
            open("Privacy_Accessibility")
        case .microphone:
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        case .inputMonitoring:
            open("Privacy_ListenEvent")
        }
    }

    static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func icon(_ permission: CapturePermission) -> String {
        switch permission {
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .microphone: "mic"
        case .inputMonitoring: "cursorarrow.motionlines"
        case .accessibility: "accessibility"
        }
    }

    static func title(_ permission: CapturePermission) -> String {
        switch permission {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }

    /// **What it is for, in terms of what this app does with it** — not "Soredemo would like
    /// access". A person deciding whether to hand over Accessibility is owed the reason, and
    /// ours is unusually narrow: it reads the SHAPE of what was clicked and never its contents.
    static func reason(_ permission: CapturePermission) -> String {
        switch permission {
        case .screenRecording:
            "To record the screen at all. Nothing is captured until you start a recording."
        case .microphone:
            "To record your narration as its own track, which you can mute afterwards."
        case .inputMonitoring:
            "To know when you click, so the camera can move there. Key CODES only \u{2014} this app cannot read what you type."
        case .accessibility:
            "To ask what you clicked ON, so a zoom frames the button rather than the pointer. It reads the element's position and role, never its contents."
        }
    }
}

/// The camera, which is not a `CapturePermission` because it is not one of the four this app's
/// capture tier tracks — it belongs to `AVCaptureDevice`.
private struct CameraRow: View {
    let status: PermissionStatus
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.regular) {
            Image(systemName: "video")
                .font(.system(size: 16))
                .foregroundStyle(status == .granted ? Theme.accent : Theme.Ink.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Camera").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Ink.primary)
                Text("To record you as a small overlay, when you choose a camera.")
                    .font(Type.detail).foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.snug)
            control
        }
        .padding(Space.regular)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.Fill.rest))
    }

    /// **Asking is only correct once.** `AVCaptureDevice.requestAccess` prompts in exactly one
    /// state; in the other three it returns the stored answer with no UI at all, which is a
    /// button that visibly does nothing. Measured from inside this bundle: it can even move a
    /// camera from `.notDetermined` straight to `.denied` without a prompt, and from there the
    /// only route back is System Settings. So a refused camera is offered System Settings, and
    /// the button says which one it is.
    @ViewBuilder private var control: some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(Type.detail).foregroundStyle(Theme.Ink.accent)
        case .restricted:
            Text("Blocked by this Mac's settings")
                .font(Type.detail).foregroundStyle(Signal.paused)
        case .denied, .notGrantedIndeterminate:
            Button("Open Settings\u{2026}") {
                PermissionRow.open("Privacy_Camera")
            }
            .controlSize(.small)
        case .notDetermined:
            Button("Allow\u{2026}") {
                Task {
                    _ = await CameraRecorder.requestAccess()
                    refresh()
                }
            }
            .controlSize(.small)
        }
    }
}

/// The one step nobody works out unaided.
///
/// **Accessibility cannot be granted by an API.** `AXIsProcessTrustedWithOptions` opens System
/// Settings and stops there; if this app is not already listed in the Accessibility pane, the
/// only way to add it is to drag it in from the Finder. A floating panel that
/// says "drag this app to the list above" with the app sitting in it is the whole
/// idea: put the thing to be dragged in front of the person, next to the list it goes in.
private struct AccessibilityDragHelper: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Ink.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("If Soredemo is not in the Accessibility list, drag it there")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Ink.primary)
                    Text("Drop it anywhere in the list. macOS has no way for an app to add itself.")
                        .font(Type.detail).foregroundStyle(Theme.Ink.secondary)
                }
            }
            HStack(spacing: Space.snug) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 26, height: 26)
                Text(verbatim: Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Ink.primary)
                Spacer()
                Image(systemName: "hand.draw")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(Space.snug)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Fill.hover)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(
                            lineWidth: 1, dash: [4, 3]))
                })
            // The app's own bundle URL is the payload, which is what the Accessibility list
            // accepts — the same thing dragging it out of the Applications folder would give.
            .draggable(Bundle.main.bundleURL)

            Button("Open Accessibility settings") {
                PermissionRow.open("Privacy_Accessibility")
            }
            .controlSize(.small)
        }
        .padding(Space.regular)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.accent.opacity(0.08)))
    }
}
