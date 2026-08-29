import CoreVideo
import Foundation
import Testing
@testable import Compositing
import Render

/// **The pairing that fails silently, and the only feature here whose absence looks exactly like
/// its presence.**
///
/// A transparent stage handed to H.264 does not error. `AVAssetWriter` accepts the frame, encodes
/// the alpha away, and returns a file with a black rectangle where somebody asked for nothing.
/// Measured, one codec at a time, by writing a frame that is opaque on one half and fully
/// transparent on the other and reading the alpha back out of the written file:
///
///     ProRes 4444        left 255  right   0   ← carries it
///     HEVC with Alpha    left 255  right   0   ← carries it
///     ProRes 422         left 255  right 255   ← silently opaque
///     HEVC               left 255  right 255   ← silently opaque
///
/// Those four numbers are what `carriesTransparency` encodes, and this file is what keeps them
/// from drifting away from the measurement.
@Suite("Transparent export")
struct TransparentExportTests {
    // MARK: - Which codecs carry it, measured

    @Test("the two codecs measured as carrying transparency are the two that claim to")
    func onlyTheMeasuredTwoCarryIt() {
        #expect(ExportCodec.proRes4444.carriesTransparency)
        #expect(ExportCodec.hevcWithAlpha.carriesTransparency)
        #expect(!ExportCodec.h264.carriesTransparency)
        #expect(!ExportCodec.hevc.carriesTransparency)
        #expect(!ExportCodec.proRes.carriesTransparency)
    }

    /// **The list and the property must not drift apart.** `codecsThatCarryIt` is what the export
    /// sheet offers; `carriesTransparency` is what the exporter refuses on. A codec added with
    /// alpha support and left off the list would be refused by an export nobody could reach the
    /// setting for.
    @Test("every codec that carries transparency is offered, and nothing else is")
    func theOfferedListIsExactlyTheCapableOnes() {
        let capable = Set(ExportCodec.allCases.filter(\.carriesTransparency))
        #expect(Set(TransparentExport.codecsThatCarryIt) == capable)
    }

    /// **Cheapest first, which is the opposite of what every article on transparent video says.**
    /// ProRes 4444 is the name everybody knows and, measured on sixty frames of 640x360, it is
    /// 14,563,749 bytes against HEVC with Alpha's 135,432 — 107 times larger for the same
    /// picture. The order is what somebody reads first, so it is part of the recommendation.
    @Test("the smallest format that works is offered first")
    func theSmallestIsFirst() {
        #expect(TransparentExport.codecsThatCarryIt.first == .hevcWithAlpha)
    }

    /// `.mov` is not a preference here — `AVAssetWriter.canAdd(_:)` returns false for this codec
    /// in an MP4 container. Measured, and pinned so a tidy-up that "unifies" the extensions
    /// produces a red test rather than a writer that refuses its own input.
    @Test("HEVC with Alpha is written into the one container that accepts it")
    func hevcWithAlphaIsQuickTimeOnly() {
        #expect(ExportCodec.hevcWithAlpha.fileExtension == "mov")
        #expect(ExportCodec.hevcWithAlpha.takesBitRate)
        #expect(!ExportCodec.hevcWithAlpha.displayName.isEmpty)
    }

    // MARK: - The verdict

    @Test("a transparent stage and a codec that carries it is a carried export")
    func aCarriedExport() {
        for codec in TransparentExport.codecsThatCarryIt {
            #expect(TransparentExport.outcome(background: .transparent, codec: codec)
                    == .transparencyIsCarried)
        }
    }

    @Test("a transparent stage and a codec that cannot carry it is refused by name")
    func aRefusedExport() {
        for codec in ExportCodec.allCases where !codec.carriesTransparency {
            #expect(TransparentExport.outcome(background: .transparent, codec: codec)
                    == .refused(.theCodecCannotCarryTransparency))
        }
    }

    /// **Every codec is fine when there is nothing to carry, including the two that could have.**
    /// A rule that refused ProRes 4444 for an opaque stage — or that reported `.transparencyIsCarried`
    /// for one — would be wrong in a way that reads as right.
    @Test("an opaque stage has nothing to carry, whatever the codec")
    func anOpaqueStageHasNothingToCarry() {
        let opaque: [StageBackground] = [
            .solid(red: 0, green: 0, blue: 0),
            .linearGradient(startRed: 1, startGreen: 0, startBlue: 0,
                            endRed: 0, endGreen: 0, endBlue: 1, angleDegrees: 45),
            .image(filename: "wall.jpg"),
        ]
        for background in opaque {
            for codec in ExportCodec.allCases {
                #expect(TransparentExport.outcome(background: background, codec: codec)
                        == .nothingToCarry)
            }
        }
    }

    // MARK: - The renderer actually leaves a hole

    /// **The check that the rest of this is built on.** Everything above is arithmetic over
    /// enums; none of it would notice a renderer that painted black where the background used to
    /// be, which is exactly what `CIImage.empty()` would have produced and what an
    /// `AVVideoCompositionRenderContext` buffer starts as.
    ///
    /// A frame is rendered with a transparent background and the corner is read: it must be fully
    /// transparent. The middle of the card is read too, because a renderer that produced an
    /// entirely empty frame would satisfy the first expectation and nothing else.
    @Test("a transparent background leaves the frame transparent outside the card")
    func aTransparentBackgroundLeavesAHole() throws {
        let width = 640, height = 360
        let source = try makePixelBuffer(width: width, height: height, fill: (200, 40, 60))
        // The destination starts fully OPAQUE white. If the renderer merely failed to draw, the
        // corner would come back at alpha 255 and this test would fail — which is the point:
        // starting it transparent would pass without the renderer doing anything at all.
        let destination = try makeOpaqueBuffer(width: width, height: height)

        let style = StageStyle(insetFraction: 0.12, cornerRadius: 24, shadowRadius: 0,
                               shadowOpacity: 0, background: .transparent, borderOpacity: 0)
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: style)
        let renderer: any FrameRendering
        do { renderer = try CoreImageFrameRenderer() }
        catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return
        }
        try renderer.render(plan, source: source, camera: nil, into: destination)

        let corner = try alpha(of: destination, x: 2, y: 2)
        let middle = try alpha(of: destination, x: width / 2, y: height / 2)
        #expect(corner == 0, "the corner should be a hole, and came back at alpha \(corner)")
        #expect(middle == 255, "the card should be solid, and came back at alpha \(middle)")
    }

    /// A buffer filled opaque white, so "the renderer wrote transparency" cannot be satisfied by
    /// the renderer writing nothing at all.
    private func makeOpaqueBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try makePixelBuffer(width: width, height: height, fill: (255, 255, 255))
        unsafe CVPixelBufferLockBaseAddress(buffer, [])
        defer { unsafe CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = unsafe CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width { unsafe base[y * rowBytes + x * 4 + 3] = 255 }
        }
        return buffer
    }

    /// The alpha at one pixel. `pixels(of:)` drops it, and alpha is the whole subject here.
    private func alpha(of buffer: CVPixelBuffer, x: Int, y: Int) throws -> UInt8 {
        unsafe CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { unsafe CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = unsafe CVPixelBufferGetBytesPerRow(buffer)
        return unsafe base[y * rowBytes + x * 4 + 3]
    }
}
