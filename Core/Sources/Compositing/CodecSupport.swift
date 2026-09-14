import AVFoundation
import CoreVideo
// For `kVTProfileLevel_HEVC_Main_AutoLevel`, which AVFoundation does not re-export.
import VideoToolbox
import Foundation

/// Which codecs keep a coloured edge **on the machine this is running on**.
///
/// **Measured, not tabulated, and that distinction is the whole file.** The bar test below was
/// first run on one M1 Pro, and the note it produced said "there is no HEVC 4:2:2 path on this
/// hardware" — a claim about one laptop, written as a claim about the product. Soredemo's users
/// are on M1 through M5 and on Intel; Apple's media engines have gained formats with every
/// generation, and a table written today is wrong for somebody by next autumn.
///
/// So the same rule the capture frame rate follows applies here: ask the hardware. A codec is
/// asked to encode a picture whose answer is known, and what comes back decides what the export
/// panel says about it.
///
/// **What the test is.** Eight-pixel red bars on black, encoded, decoded, and the last red column
/// read back. A text edge is exactly that — a sharp vertical transition between a saturated
/// colour and a dark ground, wide enough that luma is easy, so only the chroma resolution decides
/// whether it survives. Measured on an M1 Pro: H.264 145, HEVC 145, HEVC Main 4:2:2 143, ProRes
/// 422 144, ProRes 4444 234, against a reference of 255.
///
/// **Why a claim and not a filter.** Every codec here is offered whatever the answer: H.264 has
/// to be, and a person exporting a screenshot of prose does not care about chroma. What the
/// answer changes is what the panel is allowed to SAY — "keeps coloured edges" is a promise, and
/// on a machine where it is false it must not be made.
public enum CodecSupport {
    /// The bars, at a size small enough that the whole probe is a few milliseconds.
    static let probeWidth = 256
    static let probeHeight = 64
    /// How far the last column of a bar may drift before the edge counts as smeared. The two
    /// outcomes measured are 0 and ~101 out of 255 — with the writer's colour properties named,
    /// as the real export names them; without them the probe read ~21 and ~111, the 601-matrix
    /// inference `ExportQuality.colourProperties` describes. Anything between separates them;
    /// 60 is the middle of the gap rather than a threshold anybody tuned.
    static let edgeTolerance = 60

    /// Whether `codec` reproduces a saturated colour edge on this machine.
    ///
    /// `nil` when the probe could not run at all — no encoder, no buffer, no frame back. A `nil`
    /// is not a `false`: the caller says nothing rather than making the opposite promise.
    public nonisolated static func keepsColourEdges(_ codec: ExportCodec) async -> Bool? {
        guard let source = barsFrame() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-codec-probe-\(codec.rawValue).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard await write(source, codec: codec, to: url),
              let decoded = await firstFrame(of: url) else { return nil }
        return worstEdgeError(decoded) <= edgeTolerance
    }

    /// Whether `codec` keeps a transparent pixel transparent **on this machine**.
    ///
    /// The same rule as `keepsColourEdges`, applied to the other thing a codec can silently throw
    /// away. `ExportCodec.carriesTransparency` is a table, and a table is a claim about hardware
    /// written down somewhere else; this asks. `theTableMatchesWhatThisMachineActuallyDoes`
    /// compares the two, so the day an OS changes what a codec carries, the answer is a red check
    /// rather than somebody's landing page with a black rectangle on it.
    ///
    /// `nil` when the probe could not run at all. **Not `false`** — "we could not ask" and "the
    /// answer is no" would lead to opposite promises, and only one of them is safe to make.
    public nonisolated static func keepsTransparency(_ codec: ExportCodec) async -> Bool? {
        guard let source = holedFrame() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soredemo-alpha-probe-\(codec.rawValue).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard await write(source, codec: codec, to: url),
              let alphas = await firstFrameAlphaRow(of: url),
              alphas.count == probeWidth else { return nil }
        // **Both halves, not just the hole.** A decode that came back entirely transparent would
        // satisfy "the hole is a hole" while having lost the picture, and the two failures look
        // nothing alike from a person's side.
        return alphas[probeWidth / 4] > 200 && alphas[probeWidth * 3 / 4] < 32
    }

    /// Opaque red on the left half, fully transparent on the right — the shape a stage with no
    /// background actually has, reduced to the smallest frame that can show it.
    static func holedFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard unsafe CVPixelBufferCreate(nil, probeWidth, probeHeight,
                                         kCVPixelFormatType_32BGRA, attributes,
                                         &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<probeHeight {
            let row = unsafe base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<probeWidth {
                let pixel = unsafe row.advanced(by: x * 4)
                let isOpaque = x < probeWidth / 2
                unsafe pixel[0] = 0
                unsafe pixel[1] = 0
                unsafe pixel[2] = isOpaque ? 255 : 0
                unsafe pixel[3] = isOpaque ? 255 : 0
            }
        }
        return buffer
    }

    /// Eight-pixel red bars on black, in BGRA — the format the renderer produces.
    static func barsFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard unsafe CVPixelBufferCreate(nil, probeWidth, probeHeight,
                                         kCVPixelFormatType_32BGRA, attributes,
                                         &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // `unsafe`: the base address of a buffer this function created and holds locked, whose
        // extent is the one it asked `CVPixelBufferCreate` for.
        guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<probeHeight {
            // `unsafe`: writing a buffer this function just created and holds locked. The bounds
            // are the ones `CVPixelBufferCreate` was given and `bytesPerRow` reports.
            let row = unsafe base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<probeWidth {
                let pixel = unsafe row.advanced(by: x * 4)
                let isRed = (x / 8) % 2 == 0
                unsafe pixel[0] = 0
                unsafe pixel[1] = 0
                unsafe pixel[2] = isRed ? 255 : 0
                unsafe pixel[3] = 255
            }
        }
        return buffer
    }

    private nonisolated static func write(_ frame: sending CVPixelBuffer, codec: ExportCodec,
                                          to url: URL) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else { return false }
        var settings: [String: any Sendable] = [
            AVVideoCodecKey: codec.videoCodec,
            AVVideoWidthKey: probeWidth,
            AVVideoHeightKey: probeHeight,
            // The same colour properties the export writes with, or the probe measures a
            // different file from the one a person gets — see `ExportQuality.colourProperties`.
            AVVideoColorPropertiesKey: ExportQuality.colourProperties,
        ]
        // **`hevcWithAlpha` is excluded here as well as in `ExportQuality`, and leaving it in was
        // a real defect for the few minutes it existed.** This branch keyed on `takesBitRate`,
        // which is true for HEVC with Alpha, and the `else` hands out an H.264 profile — so the
        // probe would have configured an HEVC-alpha encoder with `AVVideoProfileLevelH264High`.
        // The rule is the one `ExportQuality` states: the alpha layer is a second layer, `Main`
        // describes only the first, and VideoToolbox chooses correctly when it is not told
        // wrongly.
        if codec.takesBitRate, codec != .hevcWithAlpha {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: codec == .hevc
                    ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                    : AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: any Sendable]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_32BGRA])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        // One frame. The probe is about the codec's chroma layout, which the first frame shows;
        // more frames would only measure this machine's rate control.
        var attempts = 0
        while !input.isReadyForMoreMediaData, attempts < 200 {
            try? await Task.sleep(for: .milliseconds(2))
            attempts += 1
        }
        guard adaptor.append(frame, withPresentationTime: .zero) else {
            writer.cancelWriting()
            return false
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    private nonisolated static func firstFrame(of url: URL) async -> [Int]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        defer { reader.cancelReading() }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        // `unsafe`: the base address of a decoded buffer held locked for reading, and only
        // within the width and stride it reports.
        guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // The middle row only. Every row is identical, and one is enough to read an edge.
        let y = probeHeight / 2
        // `unsafe`: reading a locked buffer within the bounds it reports.
        let row = unsafe base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        return (0..<min(probeWidth, CVPixelBufferGetWidth(buffer))).map {
            Int(unsafe row.advanced(by: $0 * 4)[2])
        }
    }

    /// The alpha channel of the decoded middle row.
    ///
    /// A near-copy of `firstFrame(of:)`, which reads the RED channel, and kept separate rather
    /// than generalised over a channel index: the two are read for different reasons, and a
    /// shared function taking `channel: Int` would make both call sites say less than they do.
    private nonisolated static func firstFrameAlphaRow(of url: URL) async -> [Int]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        defer { reader.cancelReading() }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        // `unsafe`: the base address of a decoded buffer held locked for reading, and only
        // within the width and stride it reports.
        guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let row = unsafe base.advanced(by: (probeHeight / 2) * stride)
            .assumingMemoryBound(to: UInt8.self)
        return (0..<min(probeWidth, CVPixelBufferGetWidth(buffer))).map {
            Int(unsafe row.advanced(by: $0 * 4)[3])
        }
    }

    /// How far the columns at a bar's edges drifted from what was drawn.
    ///
    /// Only columns 0 and 7 of each eight — the edges. A bar's middle is where every codec
    /// agrees, and including it would dilute the number this is trying to read.
    static func worstEdgeError(_ redChannel: [Int]) -> Int {
        var worst = 0
        for (x, value) in redChannel.enumerated() where x % 8 == 0 || x % 8 == 7 {
            let expected = (x / 8) % 2 == 0 ? 255 : 0
            worst = max(worst, abs(value - expected))
        }
        return worst
    }
}
