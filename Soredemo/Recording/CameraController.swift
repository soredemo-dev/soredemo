import AppKit
import Capture
import Foundation
import Observation
import Render

/// The camera a take may carry: which one, whether this Mac allows it, the self-view a person
/// frames themselves in before the take, and how it is recorded and placed.
///
/// **Extracted from `RecordingCoordinator`** — step 2 of
/// `docs/design/2026-10-23-splitting-the-recording-coordinator.md`. It owns the CHOICE and the
/// PREVIEW; the coordinator owns the take, and asks for the recorder when one starts
/// (`startRecording(to:)`), so the picture somebody framed is the picture that records.
/// `defaults` is passed in for `RecordingPreferences`' reason.
@Observable
final class CameraController {
    private let defaults: UserDefaults
    /// Whether a take is running — the coordinator's to answer. The self-view is not SHOWN once
    /// one has started (see `showOrHideSelfView`).
    var isTakeRunning: () -> Bool = { false }
    /// Where a problem is said — the coordinator's status line.
    var onProblem: (String) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A shape stored from a previous run, or the bottom-right circle `default` is.
        quality = (defaults.string(forKey: Self.qualityKey))
            .flatMap(CameraRecorder.Quality.init(rawValue:)) ?? .best
        style = (defaults.data(forKey: Self.styleKey))
            .flatMap { try? JSONDecoder().decode(CameraOverlayStyle.self, from: $0) }
            ?? .default
    }

    /// Whether the next take records a camera at all.
    var wantsRecording: Bool {
        if case .device = source { return true }
        return false
    }

    /// **Hands the preview over to the take**: the session already showing the person's face is
    /// the one that records, so the framing they checked is the framing in the file — and there
    /// is one client on the device, not two. Throws what the recorder throws; the take goes on
    /// without a camera and the coordinator says why.
    func startRecording(to url: URL) throws -> CameraRecorder {
        let recorder = previewRecorder ?? CameraRecorder()
        previewRecorder = nil
        try recorder.start(camera: source, to: url, quality: quality)
        // Already on screen since the camera was chosen — this only makes sure of it for
        // the path where a recording starts without the panel having been opened.
        CameraSelfView.shared.onStyleChange = { [weak self] style in self?.style = style }
        CameraSelfView.shared.show(recorder: recorder, style: style)
        return recorder
    }

    /// Which camera the next recording uses, or `.off`. Held across recordings for the reason
    /// `microphone` is.
    var source: CameraSource = .off {
        // **The self-view follows the choice, not the recording.** Choosing a camera and only
        // seeing it once the countdown has begun is being asked to check your framing in the
        // take. See `CameraSelfView` and `CameraRecorder.startPreview`.
        didSet { showOrHideSelfView() }
    }

    /// The camera that is only being SHOWN — no file, no recording. Handed to
    /// `CameraSelfView`, and handed on to the recording when one starts so the picture somebody
    /// framed is the picture that records.
    private var previewRecorder: CameraRecorder?

    /// How much of the camera to record. Persisted like the frame rate, because it is a
    /// preference rather than a per-recording decision.
    var quality: CameraRecorder.Quality {
        didSet {
            defaults.set(quality.rawValue, forKey: Self.qualityKey)
            showOrHideSelfView()
        }
    }
    static let qualityKey = "cameraQuality"

    /// **Asymmetric about a recording on purpose: showing is refused, hiding never is.**
    /// A self-view that appeared once the countdown had begun would be a face arriving in the
    /// middle of the take. But a self-view that stays on screen after something set `camera` to
    /// `.off` is the app saying "No camera" while a camera is plainly on — which is what the
    /// menu bar panel used to do, because this guard sat above both branches and returned
    /// before the hide. The panel now refuses the change during a recording (`cameraRow`), and
    /// this is the second lock on the same door.
    private func showOrHideSelfView() {
        guard case .device = source else {
            CameraSelfView.shared.hide()
            // Only the preview session is released here. Once a recording has taken it over the
            // property is `nil` and the file belongs to `stopRecording`, which has to await the
            // writer rather than drop it.
            previewRecorder?.stopPreview()
            previewRecorder = nil
            return
        }
        guard !isTakeRunning() else { return }
        let recorder = previewRecorder ?? CameraRecorder()
        do {
            try recorder.startPreview(camera: source, quality: quality)
        } catch {
            onProblem(String(localized: "The camera could not be shown: \(String(describing: error))"))
            return
        }
        previewRecorder = recorder
        CameraSelfView.shared.onStyleChange = { [weak self] style in self?.style = style }
        CameraSelfView.shared.show(recorder: recorder, style: style)
    }

    /// The cameras this Mac offers, refreshed when a panel opens and when one is connected.
    private(set) var available: [CameraSource] = []

    func refresh() {
        available = CameraRecorder.available()
        source = CameraSource.resolve(source, against: available)
        activeEffects = CameraEffects.active()
        isBusy = CameraRecorder.isInUseByAnotherApplication(source)
    }

    /// Where the camera sits, chosen while recording and carried into the editor.
    ///
    /// **Held here so it is placed once.** The self-view is dragged during the recording and the
    /// stage composites the camera afterwards; if the two kept separate positions, a person who
    /// moved their face out of the way of the Dock would find it back over the Dock the moment
    /// the editor opened. Persisted for the reason `frameRate` is — it is a preference, not a
    /// per-recording decision.
    var style: CameraOverlayStyle {
        didSet {
            guard let data = try? JSONEncoder().encode(style) else { return }
            defaults.set(data, forKey: Self.styleKey)
        }
    }
    static let styleKey = "cameraOverlayStyle"

    /// True when the chosen camera is already held by another application — a video call in a
    /// browser, most often. See `CameraRecorder.isInUseByAnotherApplication`.
    private(set) var isBusy = false

    /// True once this Mac has refused the source, so the panel can say so.
    ///
    /// **A refusal has to be visible.** Choosing a camera used to be one `guard` — ask for
    /// access, and on `false` put the selection back to `.off` and return. Which meant that on a
    /// Mac where the camera had already been denied, picking one did nothing at all: no prompt,
    /// no message, the row still reading "No camera". Silence is the worst answer to a
    /// permission question, because the only thing it teaches is that the button is broken.
    private(set) var wasRefused = false

    /// The effects macOS is applying to every camera on this Mac. Re-read with the device list,
    /// because they are switched on in a panel this app does not own — see `CameraEffects`.
    private(set) var activeEffects: [CameraEffects.Effect] = []

    /// Chooses a camera, asking this Mac first.
    ///
    /// **Activated before asking.** This is an accessory app with no Dock icon, and a TCC
    /// prompt raised by one that is not frontmost can come up behind whatever the person is
    /// looking at. The prompt is the whole interaction; it has to be in front of them.
    func choose(_ choice: CameraSource) {
        guard case .device = choice else {
            source = choice
            wasRefused = false
            return
        }
        Task { @MainActor in
            if CameraRecorder.needsAsking { NSApp.activate(ignoringOtherApps: true) }
            guard await CameraRecorder.requestAccess() else {
                source = .off
                wasRefused = true
                return
            }
            wasRefused = false
            source = choice
        }
    }

    /// Opens the pane of System Settings that holds the switch, because "grant it in System
    /// Settings" is not an instruction anyone should have to follow by hand.
    func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}
