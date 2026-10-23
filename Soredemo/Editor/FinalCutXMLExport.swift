import AVFoundation
import Foundation
import Capture
import Compositing
import Timeline

/// What `FinalCutXML` is told about a file, read from the file, and what a person is told when
/// it refuses.
///
/// Moved out of `StageWindow` — step 3 of `docs/design/2026-10-23-splitting-the-stage-window.md`.
/// The screen and the camera were read by two copies of the same lines; they are one function.
enum FinalCutXMLExport {
    /// A file's size, length and sound, as `FinalCutXML.Source`, and whether it has a picture at
    /// all. A file with none is described with a zero size — which `FinalCutXML` refuses for the
    /// screen by name, and which the camera's caller leaves out entirely.
    ///
    /// **The recording's own properties, read from the file rather than from view state.**
    /// `recordingShortSide` is the OUTPUT's short side and the variant may have changed it; what
    /// an editing application has to be told is the size of the media it is being pointed at.
    static func source(for url: URL, frameRate: Int) async -> (source: FinalCutXML.Source,
                                                               hasVideo: Bool) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let track = try? await asset.loadTracks(withMediaType: .video).first
        // **Converted at the bridge and rotated to what is actually seen.** A phone recording
        // is encoded landscape with a rotation in `preferredTransform`; describing a sequence
        // by the encoded size would turn it on its side and letterbox every clip in it.
        let natural = (try? await track?.load(.naturalSize)) ?? .zero
        let transform = (try? await track?.load(.preferredTransform)) ?? .identity
        let size = CGGeometryBridge.displayedPixelSize(of: natural, transform: transform)
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        let source = FinalCutXML.Source(
            url: url,
            duration: Nanoseconds(Int64((duration.seconds * 1_000_000_000).rounded())),
            width: size.width, height: size.height,
            frameRate: frameRate, hasAudio: hasAudio)
        return (source, track != nil)
    }

    /// Named rather than generic: the three reasons have three different fixes, and a person
    /// told only that it failed cannot act on any of them.
    static func message(for refusal: FinalCutXML.Refusal) -> String {
        switch refusal {
        case .theEditKeepsNothing:
            String(localized:
                "The edit removes the whole recording, so there is no cut to export.")
        case .theFrameRateIsNotAFrameRate:
            String(localized: "The recording reports no frame rate, and every time in the file has to be a whole frame.")
        case .theRecordingHasNoSize:
            String(localized:
                "The recording reports no size, so there is no sequence to describe.")
        }
    }
}
