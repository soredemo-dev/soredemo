import AVFoundation
import Foundation

/// Records the built-in or an attached camera to its own file, beside the screen recording.
///
/// **A separate file, not a second track in the master.** a Rust recorder records its webcam this way and
/// the reason holds here: the screen capture is an `SCStream` writing through `MasterWriting`,
/// and threading a camera into it would mean a fourth input on a writer whose interleaving
/// rules this project has already been bitten by twice. A file the compositor reads at render
/// time can also be re-positioned, resized and turned off after the fact, which a burnt-in
/// second track cannot.
///
/// **`AVCaptureMovieFileOutput`, not a writer.** It is the one path that needs no sample
/// handling at all: no interleaving, no timing arithmetic, no held queues. Everything this
/// project got wrong about audio interleaving was in code this class does not have.
public final class CameraRecorder: NSObject, @unchecked Sendable {
    /// The cameras this machine offers.
    ///
    /// **`.external` alongside the built-ins**, for `MicrophoneInventory.available`'s reason: a
    /// USB camera or a capture card is exactly what someone recording a demo with a real setup
    /// is using, and a built-in-only query would not list it.
    public nonisolated static func available() -> [CameraSource] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
            .devices
            .map { CameraSource(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    /// Whether another application currently holds this camera.
    ///
    /// **macOS lets several apps read one camera, and several is not unlimited.** The built-in
    /// camera has one active format, and the first client fixes it; a second client asking for
    /// something the first has not configured is refused, which is what a video call in a
    /// browser and a recorder starting at the same time run into. Reported rather than
    /// discovered at `start()`, so the panel can say it while there is still a choice to make.
    ///
    /// A macOS-only property — there is no iOS equivalent, because iOS never shares a camera.
    public nonisolated static func isInUseByAnotherApplication(_ source: CameraSource) -> Bool {
        guard let uniqueID = source.uniqueID,
              let device = AVCaptureDevice(uniqueID: uniqueID) else { return false }
        return device.isInUseByAnotherApplication
    }

    /// What this Mac has decided about the camera, in the same four words the rest of the
    /// permissions are reported in.
    ///
    /// **`isAvailable` is not this question and was being used as though it were.** It answers
    /// "not refused, and a lens exists", which is true before anybody has been asked — so a
    /// first-run permission page reading it showed the camera as allowed when nothing had been
    /// granted at all.
    ///
    /// **And the difference decides whether asking is even legal.** Measured, with a probe run
    /// from inside this bundle: `requestAccess` on a `.notDetermined` camera can return false
    /// AND write `.denied` without ever putting a prompt on screen, if the process is in no
    /// state to present one. After that, every later press of an Allow button calls an API that
    /// is contractually obliged to say no in silence. A refused camera has exactly one route
    /// back — System Settings — and a button that does not know the difference sends people to
    /// press a dead control forever.
    public nonisolated static var authorization: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .notGrantedIndeterminate
        }
    }

    /// Whether a camera can be recorded at all — the permission plus a device.
    public nonisolated static var isAvailable: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) != .denied && !available().isEmpty
    }

    /// Asks for camera access. **Called before the picker opens**, for the same reason
    /// `CapturePermissions.requestScreenRecordingAccess` is: `AVCaptureSession` does not prompt
    /// on its own, so a first-run person would be told the camera failed by an API that never
    /// asked them.
    /// Whether asking will actually put a prompt on screen.
    ///
    /// **`.notDetermined` is the only state that prompts.** `requestAccess` returns the stored
    /// answer immediately for the other three, and a caller that cannot tell the difference
    /// cannot tell "they said no just now" from "this Mac said no months ago" — which is the
    /// difference between waiting for a person and telling them where the switch is.
    public nonisolated static var needsAsking: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }

    public nonisolated static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    /// Built during `start`'s configuration block — see `previewLayer()`.
    private var preview: AVCaptureVideoPreviewLayer?
    private var started: Int64?

    /// When this recorder's file begins, on the host clock — the thing that makes the camera
    /// line up with the screen.
    ///
    /// **Two captures started one after the other do not start at the same instant**, and until
    /// this existed the composition assumed they did. `CameraComposition` said so in its own
    /// doc comment and called it an approximation; a Rust recorder does not approximate it — every track in
    /// its recording carries a `start_time`, and `calculate_audio_offsets` aligns them all to
    /// whichever began LAST. an Electron recorder carries the same thing as `timeOffsetMs`.
    ///
    /// **`didStartRecordingTo`, which is when the OUTPUT began writing** — a frame or two before
    /// the first sample it actually wrote. That residual is stated rather than hidden: closing
    /// it needs the first sample's presentation time, which `AVCaptureMovieFileOutput` does not
    /// expose and which would cost a second `AVCaptureVideoDataOutput` on the session to
    /// observe. A frame or two beats the several hundred milliseconds a camera takes to wake.
    ///
    /// `nil` until the file starts.
    public nonisolated var firstFrameHostTimeNanos: Int64? { started }
    private var destination: URL?
    private var finished: CheckedContinuation<URL?, Never>?

    public enum RecorderError: Error, CustomStringConvertible, Equatable {
        case noCamera(String)
        case sessionRefusedInput
        case sessionRefusedOutput

        public var description: String {
            switch self {
            case .noCamera(let id): "no camera named \(id) is connected"
            case .sessionRefusedInput: "AVCaptureSession refused the camera"
            case .sessionRefusedOutput: "AVCaptureSession refused the movie output"
            }
        }
    }

    /// Starts recording `camera` to `url`.
    ///
    /// **`.medium` rather than the camera's best.** The overlay is drawn a few hundred pixels
    /// across in the finished video; recording 4K to shrink it costs disk and encode time for
    /// detail the export throws away. a native editor and a Rust recorder both cap their camera capture for the
    /// same reason.
    /// Which camera this session is already showing or recording, so a second request for the
    /// same one reuses it rather than opening a second client on one device.
    private var openedCamera: CameraSource?

    /// Starts the camera WITHOUT recording it, so a person can see their framing first.
    ///
    /// **A recorder that only shows the camera once recording has begun is asking you to check
    /// your framing in the take.** The self-view used to appear at `start`, which is after the
    /// target has been picked and the countdown has begun — the one moment it is too late to
    /// move the laptop.
    ///
    /// **One session, opened here and kept.** `start` adds the movie output to this same session
    /// rather than building another: two `AVCaptureSession`s on one camera is two clients, and
    /// the first client fixes the active format — the exact contention that stops a browser video
    /// call and this recorder starting together.
    public func startPreview(camera: CameraSource) throws {
        guard openedCamera != camera else { return }
        guard let uniqueID = camera.uniqueID,
              let device = AVCaptureDevice(uniqueID: uniqueID) else {
            throw RecorderError.noCamera(camera.displayName)
        }
        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        session.sessionPreset = Self.preset(for: device)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.sessionRefusedInput
        }
        session.addInput(input)
        if preview == nil {
            preview = AVCaptureVideoPreviewLayer(session: session)
            preview?.videoGravity = .resizeAspectFill
        }
        session.commitConfiguration()
        openedCamera = camera
        if !session.isRunning { session.startRunning() }
    }

    /// Stops a preview that is not recording. A no-op while recording, so hiding the self-view
    /// cannot take the camera away from a take in progress.
    public func stopPreview() {
        guard !output.isRecording else { return }
        session.stopRunning()
        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        session.commitConfiguration()
        preview = nil
        openedCamera = nil
    }

    /// **The best preset this device can do, not `.medium` for everything.**
    ///
    /// An external camera is exactly what somebody recording a demo with a real setup is using,
    /// and `.medium` is 480p — it threw away most of what a 1080p webcam or a capture card can
    /// produce. The presets are tried best-first and the device answers; nothing is assumed about
    /// what it supports, which is the same rule the capture frame rate follows for displays.
    ///
    /// Not the device's absolute best: the camera is drawn a few hundred pixels across in the
    /// finished video, and 4K to shrink to 300 points is disk and encode time for detail the
    /// export throws away. 1080p is the ceiling for that reason, and it is a ceiling rather than
    /// a demand — a 720p camera gets 720p.
    /// What this camera will actually be recorded at, for the panel to say.
    ///
    /// **Because "is my external camera being used properly" is a real question with a wrong
    /// answer available.** Every camera was recorded at `.medium` — 480p — whatever it could do,
    /// so a 1080p webcam or a capture card was throwing away most of itself and nothing said so.
    /// Measured on this Mac: the built-in FaceTime HD supports 1080p and was getting 480p.
    ///
    /// `nil` when the device is gone between the list and the question, which is a real gap: a
    /// USB camera can be unplugged in it.
    public nonisolated static func recordingSize(of camera: CameraSource) -> String? {
        guard let uniqueID = camera.uniqueID,
              let device = AVCaptureDevice(uniqueID: uniqueID) else { return nil }
        switch preset(for: device) {
        case .hd1920x1080: return "1920\u{00D7}1080"
        case .hd1280x720: return "1280\u{00D7}720"
        default: return "640\u{00D7}480"
        }
    }

    static func preset(for device: AVCaptureDevice) -> AVCaptureSession.Preset {
        for candidate: AVCaptureSession.Preset in [.hd1920x1080, .hd1280x720, .medium]
        where device.supportsSessionPreset(candidate) {
            return candidate
        }
        return .medium
    }

    public func start(camera: CameraSource, to url: URL) throws {
        // Reuses the preview's session when it is already showing this camera, so the picture a
        // person framed is the picture that records — and so the camera is not opened twice.
        try startPreview(camera: camera)
        session.beginConfiguration()
        guard session.outputs.contains(output) || session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.sessionRefusedOutput
        }
        if !session.outputs.contains(output) { session.addOutput(output) }
        // The preview layer is built by `startPreview` above, inside ITS configuration block.
        // `AVCaptureVideoPreviewLayer(session:)` adds a connection, and adding a connection is a
        // session configuration change — which `AVCaptureMovieFileOutput` responds to by ENDING
        // the recording it is in the middle of. Built after `startRecording`, as it once was, the
        // self-view appeared and the camera file was killed the instant it did.
        session.commitConfiguration()

        destination = url
        started = nil
        try? FileManager.default.removeItem(at: url)
        session.startRunning()
        output.startRecording(to: url, recordingDelegate: self)
    }

    /// A layer showing what this recorder is capturing, for a self-view during the recording.
    ///
    /// **From the recorder's own session, not a second one.** A preview built on its own
    /// `AVCaptureSession` would be a second client on the same camera, and the first client
    /// fixes the active format — the exact contention that makes a browser video call and a
    /// recorder refuse to start together, self-inflicted this time. One session feeds the file
    /// and the picture.
    ///
    /// Returns `nil` before `start`, because there is nothing to show until there is.
    public func previewLayer() -> AVCaptureVideoPreviewLayer? { preview }

    /// Stops and waits for the file to be written. `nil` when nothing was recorded.
    ///
    /// **Awaited rather than fire-and-forget.** `AVCaptureMovieFileOutput` finishes writing on
    /// its own queue after `stopRecording` returns, and a caller that read the file immediately
    /// would read a partial one — which is the same shape as the export's `finishWriting`.
    ///
    /// **A `nil` here means the recording had already ended**, which is a fact worth acting on
    /// rather than a quiet absence: the output stops itself when the session is reconfigured
    /// underneath it, and the only symptom the caller ever saw was an export with no camera in
    /// it. `RecordingCoordinator` says so now.
    public func stop() async -> URL? {
        guard output.isRecording else {
            session.stopRunning()
            preview = nil
            openedCamera = nil
            return nil
        }
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            finished = continuation
            output.stopRecording()
        }
        session.stopRunning()
        preview = nil
        openedCamera = nil
        return url
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    /// Stamps the moment the file began. See `firstFrameHostTimeNanos`.
    public func fileOutput(_ output: AVCaptureFileOutput,
                           didStartRecordingTo fileURL: URL,
                           from connections: [AVCaptureConnection]) {
        started = Minting.hostNow().rawValue
    }

    public func fileOutput(_ output: AVCaptureFileOutput,
                           didFinishRecordingTo outputFileURL: URL,
                           from connections: [AVCaptureConnection],
                           error: (any Error)?) {
        // **An error still resumes with the URL when the file exists.** AVFoundation reports a
        // "recording stopped" error for an ordinary stop on some configurations, and treating
        // every error as a failure would throw away a good file. The caller checks the file.
        let wrote = FileManager.default.fileExists(atPath: outputFileURL.path)
        finished?.resume(returning: wrote ? outputFileURL : nil)
        finished = nil
    }
}

/// Which camera a recording uses. The shape `MicrophoneSource` has, for the same reasons: the
/// name is carried so a project can say what it recorded from after the device is gone, and
/// there is an `off` case because not recording a camera is a choice rather than a failure.
public enum CameraSource: Hashable, Sendable, Codable {
    case off
    case device(uniqueID: String, name: String)

    public init(uniqueID: String, name: String) {
        self = .device(uniqueID: uniqueID, name: name)
    }

    public var uniqueID: String? {
        switch self {
        case .off: nil
        case .device(let id, _): id
        }
    }

    public var displayName: String {
        switch self {
        case .off: "No camera"
        case .device(_, let name): name
        }
    }

    /// The selection to use when a project asks for a camera that is no longer connected.
    ///
    /// **Falls back to `off`, not to whichever camera is present.** A microphone that fell back
    /// to the default still records the room; a camera that fell back would record a person's
    /// face when they had asked for a specific device — and `MicrophoneInventory.resolve`'s
    /// argument for falling back does not carry over to a lens.
    public static func resolve(_ requested: CameraSource,
                               against available: [CameraSource]) -> CameraSource {
        guard case .device(let id, _) = requested else { return .off }
        return available.contains { $0.uniqueID == id } ? requested : .off
    }
}
