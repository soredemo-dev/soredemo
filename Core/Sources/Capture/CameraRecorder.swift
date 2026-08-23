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
    public func start(camera: CameraSource, to url: URL) throws {
        guard let uniqueID = camera.uniqueID,
              let device = AVCaptureDevice(uniqueID: uniqueID) else {
            throw RecorderError.noCamera(camera.displayName)
        }
        session.beginConfiguration()
        session.sessionPreset = .medium
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.sessionRefusedInput
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.sessionRefusedOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        destination = url
        try? FileManager.default.removeItem(at: url)
        session.startRunning()
        output.startRecording(to: url, recordingDelegate: self)
    }

    /// Stops and waits for the file to be written. `nil` when nothing was recorded.
    ///
    /// **Awaited rather than fire-and-forget.** `AVCaptureMovieFileOutput` finishes writing on
    /// its own queue after `stopRecording` returns, and a caller that read the file immediately
    /// would read a partial one — which is the same shape as the export's `finishWriting`.
    public func stop() async -> URL? {
        guard output.isRecording else {
            session.stopRunning()
            return nil
        }
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            finished = continuation
            output.stopRecording()
        }
        session.stopRunning()
        return url
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
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
