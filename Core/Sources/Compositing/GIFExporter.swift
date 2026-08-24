import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Project
import Timeline
import UniformTypeIdentifiers

/// What a person chose about a GIF: how often it samples, how big it is, and whether it repeats.
///
/// **The frame rate is stored as the delay the FILE can actually hold.** A GIF's Graphic
/// Control Extension gives each frame a delay in an unsigned 16-bit field counted in
/// hundredths of a second, and that is the only timing the format has. So a rate that does not
/// divide 100 cannot be written: 15 fps is 6.67 cs and becomes 7, which plays 4.7% slow; 30 fps
/// is 3.33 cs and becomes 3, which plays 11% FAST. All three reference recorders ship a default
/// with this drift — `../opensource/Screen Record Opensource/a Swift recorder` defaults to 15,
/// `a Rust recorder` to 30, `an Electron recorder-main` offers 15/20/25/30 — because each treats the rate as a
/// sampling choice and lets ImageIO round the delay afterwards.
///
/// Ours derives BOTH from the delay: `frameDuration` samples the composition at exactly the
/// interval the file will play back at, so any rate a person picks produces a GIF whose length
/// matches the recording. `exactRates` is what the UI offers, and `plays(at:)` says what a rate
/// that is not on that list will really do.
public struct GIFSettings: Sendable, Equatable, Codable {
    /// Frames per second, as asked for. What gets WRITTEN is `delayCentiseconds`.
    public var frameRate: Int
    /// Repeat forever. False writes a GIF that plays once and stops on its last frame — which
    /// is the right default for a demo of something that ENDS, and the wrong one for a loop of
    /// a gesture. Neither is universal, so it is a choice rather than a constant.
    public var loops: Bool
    /// The longest edge, in pixels. A GIF is an indexed-colour format with one frame per
    /// screenful of pixels and no inter-frame motion compensation worth the name, so size is
    /// the dominant term in the file's weight — far more than the frame rate.
    public var maximumLongestEdge: Int

    public init(frameRate: Int = 20, loops: Bool = true, maximumLongestEdge: Int = 640) {
        self.frameRate = frameRate
        self.loops = loops
        self.maximumLongestEdge = maximumLongestEdge
    }

    /// The rates the format can hold exactly — 100 divided by a whole number of centiseconds.
    ///
    /// Stops at 50 because a delay below 2 cs is not honoured: every major browser clamps 0 and
    /// 1 cs to 10 cs, a rule inherited from Netscape's original decoder and kept because the
    /// web is full of GIFs written with a zero delay meaning "as fast as possible". A 100 fps
    /// GIF therefore plays at 10 fps, which is the opposite of what asking for 100 meant.
    public static let exactRates = [10, 20, 25, 50]

    /// The delay actually written, in the format's own unit. Clamped at 2 for the reason above.
    public var delayCentiseconds: Int {
        max(2, Int((100.0 / Double(max(1, frameRate))).rounded()))
    }

    /// The delay in seconds, which is what ImageIO's property takes.
    public var delaySeconds: Double { Double(delayCentiseconds) / 100 }

    /// What this GIF will really play at. Equal to `frameRate` exactly when the rate is on
    /// `exactRates`; a UI showing both is showing a person the cost of an off-list choice.
    public var playbackRate: Double { 100.0 / Double(delayCentiseconds) }

    /// True when nothing was lost to the format's timing grid.
    public var isExact: Bool { Double(frameRate) == playbackRate }

    /// How often the composition is sampled — the playback interval, not the asked-for one, so
    /// the GIF's length equals the recording's however the rate was rounded.
    public var frameDuration: CMTime {
        CMTime(value: CMTimeValue(delayCentiseconds), timescale: 100)
    }

    /// `0` means forever in the GIF loop-count extension; `1` means play through once.
    public var loopCount: Int { loops ? 0 : 1 }

    /// The output size, scaled down to fit `maximumLongestEdge` and never up — enlarging a
    /// recording adds bytes and no detail.
    ///
    /// Even on both edges. The GIF format does not require it; the composition pipeline does,
    /// and a `CVPixelBuffer` with an odd width is where a stray column of green comes from.
    public func size(fitting width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = Swift.max(width, height)
        guard longest > maximumLongestEdge, longest > 0 else {
            return (evenFloor(width), evenFloor(height))
        }
        let scale = Double(maximumLongestEdge) / Double(longest)
        return (evenFloor(Int((Double(width) * scale).rounded())),
                evenFloor(Int((Double(height) * scale).rounded())))
    }

    private func evenFloor(_ value: Int) -> Int { Swift.max(2, value - (value % 2)) }

    /// Presets, named for what a person is deciding between rather than for their numbers.
    /// A GIF is chosen when a video will not embed — a README, an issue, a chat — and all three
    /// of those have a size limit, so the axis a person actually cares about is weight.
    public static let compact = GIFSettings(frameRate: 10, maximumLongestEdge: 480)
    public static let balanced = GIFSettings(frameRate: 20, maximumLongestEdge: 640)
    public static let detailed = GIFSettings(frameRate: 25, maximumLongestEdge: 960)
}

/// One GIF export of a recorded master, through the same `AVVideoComposition` the preview and
/// the MP4 export use.
///
/// **Composed at the GIF's own size, not scaled afterwards.** a Swift recorder does the same thing and
/// the reason is worth saying: a GIF has 256 colours per frame, so every pixel is already a
/// compromise, and scaling after quantisation averages colours that were themselves chosen
/// from a palette — the result is dirtier than quantising an image that was scaled first. It
/// also means the cursor and the zoom framing are laid out for the size a person will see,
/// rather than being a shrunken picture of a layout meant for 1920 wide.
///
/// **No audio, and that is the format.** GIF has none. A person exporting one is choosing a
/// thing that can be pasted into a README; the UI has to say so rather than silently dropping
/// the microphone track a person spent the recording talking into.
public enum GIFExporter {
    public nonisolated static func export(
        asset: AVAsset, to outputURL: URL,
        outputWidth: Int, outputHeight: Int,
        edit: EditTimeline? = nil,
        assetIsAlreadyEdited: Bool = false,
        settings: GIFSettings = .balanced,
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws -> GIFReport {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        onProgress?(.preparing)
        if let edit, edit.isEmpty { throw ExportError.emptyTrim }
        // The same pairing check the MP4 path makes, for the same reason: `StageCompositor`
        // reads the observation log in source time and converts through this static, so an
        // export whose asset was cut one way while the static said another places every cursor
        // and every zoom by the difference. Process-global because AVFoundation owns compositor
        // instances, so it cannot be an argument — but it can be checked.
        if unsafe StageCompositor.editTimeline != edit {
            throw ExportError.editTimelineMismatch
        }

        var asset = asset
        // **`assetIsAlreadyEdited` separates two things `edit` was doing at once.** It said
        // "cut this for me" AND "this is the edit the compositor is mapping the observation log
        // through", and a caller who had already cut the asset could only opt out of the first
        // by lying about the second. The camera is why: `EditedAsset.make` takes the FIRST video
        // track and drops the rest, so a camera laid alongside must be combined AFTER the cut —
        // which means the caller does the cut. The compositor still has to be told the same
        // edit, and the check below still holds it to that.
        if let edit, !assetIsAlreadyEdited {
            asset = try await EditedAsset.make(from: asset, by: edit)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }

        let size = settings.size(fitting: outputWidth, height: outputHeight)
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: size.width, outputHeight: size.height,
            frameDuration: settings.frameDuration)

        let totalSeconds = (try? await asset.load(.duration).seconds) ?? 0
        let estimatedFrames = Swift.max(1, Int(totalSeconds / settings.delaySeconds))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        guard reader.canAdd(output) else { throw ExportError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "startReading() returned false")
        }

        do {
            let written = try write(settings: settings, size: size, output: output,
                                    estimatedFrames: estimatedFrames, totalSeconds: totalSeconds,
                                    to: outputURL, onProgress: onProgress)
            return GIFReport(outputURL: outputURL, framesWritten: written,
                             width: size.width, height: size.height,
                             delayCentiseconds: settings.delayCentiseconds)
        } catch {
            // A half-written GIF where a person asked for their demo is worse than no file,
            // because it opens and shows the first two seconds as if that were the export.
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private nonisolated static func write(
        settings: GIFSettings, size: (width: Int, height: Int),
        output: AVAssetReaderOutput, estimatedFrames: Int, totalSeconds: Double,
        to outputURL: URL, onProgress: (@Sendable (ExportProgress) -> Void)?
    ) throws -> Int {
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, estimatedFrames, nil)
        else { throw ExportError.destinationRefused(outputURL.lastPathComponent) }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: settings.loopCount,
            ],
        ] as CFDictionary)

        // Both keys, as a Swift recorder writes them. The unclamped one is what a decoder that honours
        // sub-2-centisecond delays reads; the clamped one is what everything else reads. Written
        // to the same value here because `delayCentiseconds` has already applied the clamp — so
        // the two cannot disagree about how fast this GIF is.
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: settings.delaySeconds,
                kCGImagePropertyGIFUnclampedDelayTime: settings.delaySeconds,
            ],
        ] as CFDictionary

        // sRGB explicitly. A GIF carries no colour profile at all, so whatever a viewer shows it
        // as IS sRGB; converting here means the palette is chosen from the colours a person will
        // actually see rather than from Display P3 values that get reinterpreted afterwards.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
        let canvas = HeadlessGeometryBridge.outputCanvas(width: size.width, height: size.height)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

        var resampler = MP4Exporter.ConstantRateResampler(
            output: output, frameDuration: settings.frameDuration, slot: .zero)
        var written = 0
        var lastReportedPercent = -1

        while let buffer = resampler.next() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            // Declared sRGB on the way in, for `CoreImageFrameRenderer.screenImage`'s
            // reason: the composed frame arrives from the composition carrying the master's
            // 709 tags over sRGB-rendered pixels, and honouring the tag would lighten every
            // mid tone a second time before the palette is chosen.
            let image = CoreImageFrameRenderer.screenImage(pixels)
            guard let frame = context.createCGImage(image, from: canvas,
                                                    format: .RGBA8, colorSpace: sRGB) else {
                throw ExportError.frameRenderFailed(written)
            }
            CGImageDestinationAddImage(destination, frame, frameProperties)
            written += 1

            // Per whole percent, not per frame — the MP4 path's reasoning, and a GIF has fewer
            // frames but the same main-actor cost per report.
            if let onProgress, estimatedFrames > 0 {
                let fraction = Swift.min(1, Double(written) / Double(estimatedFrames))
                let percent = Int(fraction * 100)
                if percent != lastReportedPercent {
                    lastReportedPercent = percent
                    onProgress(.writing(fraction: fraction, framesWritten: written))
                }
            }
        }

        guard written > 0 else { throw ExportError.noFrames }

        // **`finalize` is where the whole file is written**, not a flush of something already on
        // disk: ImageIO holds the frames and builds the palettes here. On a long recording it is
        // seconds of work reporting nothing, which is exactly the phase `ExportProgress` exists
        // to be able to name.
        onProgress?(.finishing)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.finalizeFailed }
        return written
    }

    public nonisolated enum ExportError: Error, CustomStringConvertible, Sendable, Equatable {
        case emptyTrim
        case editTimelineMismatch
        case noVideoTrack
        case readerRefusedOutput
        case readerFailed(String)
        case destinationRefused(String)
        case frameRenderFailed(Int)
        case noFrames
        case finalizeFailed

        public var description: String {
            switch self {
            case .emptyTrim:
                "the edit removes the whole recording, so there is nothing to export"
            case .editTimelineMismatch:
                "the compositor is set to a different edit than the one being exported"
            case .noVideoTrack:
                "the recording has no video track"
            case .readerRefusedOutput:
                "AVAssetReader refused the composition output"
            case .readerFailed(let reason):
                "could not read the recording: \(reason)"
            case .destinationRefused(let name):
                "could not create a GIF at \(name)"
            case .frameRenderFailed(let index):
                "could not render frame \(index) of the GIF"
            case .noFrames:
                "the composition produced no frames"
            case .finalizeFailed:
                "ImageIO could not finish writing the GIF"
            }
        }
    }
}

/// What a finished GIF export is, as a value — so a caller can say what it produced without
/// re-reading the file it just wrote.
public nonisolated struct GIFReport: Sendable, Equatable {
    public let outputURL: URL
    public let framesWritten: Int
    public let width: Int
    public let height: Int
    /// The delay written into every frame. Kept rather than the asked-for rate, because this is
    /// the number that decides how fast the file plays.
    public let delayCentiseconds: Int

    public var playbackRate: Double { 100.0 / Double(delayCentiseconds) }
    public var seconds: Double { Double(framesWritten) * Double(delayCentiseconds) / 100 }
}
