import Capture

/// The one place this app asks the system for a permission.
///
/// **`theScreenRecordingRequestIsCalledExactlyOnceAndWiredBeforeThePicker` requires exactly one
/// call site**, and its reasoning is right: a second site is a second policy about when to ask.
/// Three surfaces now want to ask — the system picker path, this app's own window overlay, and
/// the permission page's Allow button — and all three want the same thing at the same moment,
/// which is what makes one wrapper correct rather than a way around the rule.
///
/// Neither `SCContentSharingPicker` nor `SCShareableContent` prompts on its own, so without this
/// a first-run person is told "the user declined" by an API that never asked them.
enum PermissionRequests {
    static func screenRecording() {
        _ = CapturePermissions.requestScreenRecordingAccess()
    }

    // **No `accessibility()` here, deliberately.** `CaptureSession` asks for it at the moment it
    // needs it, which is the only moment the prompt can appear: `AXIsProcessTrustedWithOptions`
    // shows its dialog once per app and never again, so a second caller would show nothing and
    // would be a second policy for a prompt that has already happened. The permission page opens
    // the settings pane instead, which is where the answer actually lives after the first time.
}
