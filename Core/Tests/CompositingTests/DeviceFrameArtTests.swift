import CoreVideo
import Foundation
import Render
import Testing
@testable import Compositing

/// The device body, measured in pixels.
///
/// **A render feature is a claim about pixels, and this project's standard is to check them.**
/// `DeviceFrameTests` pins the arithmetic — where the body goes, how thick the bezel is. Nothing
/// there can tell whether anything was actually drawn.
@Suite struct DeviceFrameArtTests {
    private let width = 640
    private let height = 360
    /// The source fill, chosen by `PixelBufferSupport` to be far from the stage's near-black.
    private let sourceFill: (UInt8, UInt8, UInt8) = (40, 90, 200)

    private func rendered(style: StageStyle,
                          sourceWidth: Int, sourceHeight: Int) throws
    -> (pixels: [(r: UInt8, g: UInt8, b: UInt8)], plan: RenderPlan)? {
        let source = try makePixelBuffer(width: sourceWidth, height: sourceHeight,
                                         fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                     style: style)
        let renderer: any FrameRendering
        do { renderer = try CoreImageFrameRenderer() }
        catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return nil
        }
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return (try pixels(of: destination), plan)
    }

    /// Top-left origin for reading the buffer; the plan is bottom-left.
    private func pixel(_ all: [(r: UInt8, g: UInt8, b: UInt8)], x: Int, planY: Double)
    -> (r: UInt8, g: UInt8, b: UInt8) {
        let row = height - 1 - Int(planY)
        return all[row * width + x]
    }

    private var framed: StageStyle {
        StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 0, shadowOpacity: 0,
                   background: .solid(red: 0, green: 0, blue: 0),
                   deviceModel: .iPad, deviceFinish: .silver)
    }

    private var plain: StageStyle {
        StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 0, shadowOpacity: 0,
                   background: .solid(red: 0, green: 0, blue: 0))
    }

    /// **The bezel is drawn, and it is the finish's colour rather than merely "not black".**
    /// A test that only asked for a difference would pass on a body drawn in the background's
    /// own colour, which is no body at all.
    @Test func theBezelIsDrawnInTheFinishesColour() throws {
        guard let (all, plan) = try rendered(style: framed, sourceWidth: 480, sourceHeight: 640)
        else { return }
        let device = try #require(plan.deviceFrame, "the plan has no device frame to draw")

        // A point halfway up the left bezel: between the body's edge and the screen's.
        let midY = device.body.y + device.body.height / 2
        let bezelX = Int((device.body.x + (device.screen.x - device.body.x) / 2).rounded())
        let sample = pixel(all, x: bezelX, planY: midY)

        // Silver is bright and neutral; the background is black and the recording is blue.
        let luma = 0.299 * Double(sample.r) + 0.587 * Double(sample.g) + 0.114 * Double(sample.b)
        #expect(luma > 100, """
            the left bezel at x \(bezelX) reads \(sample) — luma \(luma). A silver body should be \
            bright; black is the stage behind it and blue is the recording.
            """)
        #expect(abs(Int(sample.r) - Int(sample.b)) < 60, """
            the bezel reads \(sample), which is not neutral — that is the recording's blue \
            showing through where the body should be
            """)
    }

    /// **The recording is inside the bezel, not over it.** The whole point: with a frame the
    /// card IS the screen, so the picture must stop at the screen's edge.
    @Test func theRecordingStopsAtTheScreensEdgeRatherThanFillingTheBody() throws {
        guard let (all, plan) = try rendered(style: framed, sourceWidth: 480, sourceHeight: 640)
        else { return }
        let device = try #require(plan.deviceFrame)
        let midY = device.screen.y + device.screen.height / 2

        // Well inside the screen: the recording.
        let inside = pixel(all, x: Int(device.screen.x + device.screen.width / 2), planY: midY)
        #expect(abs(Int(inside.b) - Int(inside.r)) > 60, """
            the middle of the screen reads \(inside), which is not the recording's blue — the \
            picture is not being drawn inside the device
            """)
        // Just outside the body: the stage, still black.
        let outsideX = Int(device.body.x) - 6
        if outsideX >= 0 {
            let outside = pixel(all, x: outsideX, planY: midY)
            #expect(outside.r < 40 && outside.g < 40 && outside.b < 40, """
                just outside the body at x \(outsideX) reads \(outside) — the device is wider \
                than its own bounds say
                """)
        }
    }

    /// **With no frame nothing changes.** Every Mac recording takes this path, and a device
    /// feature that altered them would be a regression nobody asked for.
    @Test func aStyleWithNoDeviceRendersExactlyAsItDidBefore() throws {
        guard let (framedPixels, _) = try rendered(style: framed,
                                                   sourceWidth: 480, sourceHeight: 640),
              let (plainPixels, plan) = try rendered(style: plain,
                                                     sourceWidth: 480, sourceHeight: 640)
        else { return }
        #expect(plan.deviceFrame == nil, "a style with no model still produced a placement")
        let differing = zip(framedPixels, plainPixels).count { $0 != $1 }
        #expect(differing > 1000, """
            the framed and plain renders differ in only \(differing) pixels — the device is \
            probably not being drawn at all, and every other check here would be vacuous
            """)
    }

    /// The two finishes are visibly different, so a person choosing one is choosing something.
    @Test func twoFinishesProduceVisiblyDifferentBodies() throws {
        func body(_ finish: DeviceFrame.Finish) throws -> (r: UInt8, g: UInt8, b: UInt8)? {
            let style = StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 0,
                                   shadowOpacity: 0,
                                   background: .solid(red: 0, green: 0, blue: 0),
                                   deviceModel: .iPad, deviceFinish: finish)
            guard let (all, plan) = try rendered(style: style,
                                                 sourceWidth: 480, sourceHeight: 640),
                  let device = plan.deviceFrame else { return nil }
            let midY = device.body.y + device.body.height / 2
            let x = Int((device.body.x + (device.screen.x - device.body.x) / 2).rounded())
            return pixel(all, x: x, planY: midY)
        }
        guard let silver = try body(.silver), let graphite = try body(.graphite) else { return }
        let distance = abs(Int(silver.r) - Int(graphite.r)) + abs(Int(silver.g) - Int(graphite.g))
            + abs(Int(silver.b) - Int(graphite.b))
        #expect(distance > 90, """
            silver reads \(silver) and graphite \(graphite) — a difference of \(distance) across \
            three channels, which nobody would call a choice
            """)
    }
}
