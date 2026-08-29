import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Compositing

/// **The half of `PersonMask` that can be checked here. The other half is in the probe, and that
/// is a deadlock rather than a preference.**
///
/// `VNImageRequestHandler.perform` is synchronous and pulls in CoreML, Espresso and the Apple
/// Neural Engine. `swift test` runs every target in ONE process with Swift Testing running suites
/// concurrently, and calling Vision from here stalled the whole `CompositingTests` run at **0%
/// CPU** — a target that had been finishing in 14 seconds ran for over ten minutes.
///
/// Two fixes were tried and measured, and neither was enough:
///
///  1. `.serialized` on the suite. It fixed `--filter PersonMaskTests`, which runs this suite and
///     nothing else, and `--filter CompositingTests` hung all over again — serialising a suite
///     does not stop the twenty-one other suites in the target from holding the same threads.
///  2. Every Vision call hopped onto a `DispatchQueue` through `withCheckedContinuation`, so the
///     calling task suspends instead of blocking. Also not enough. A `sample` of the hung process
///     showed all eight cooperative threads in `_pthread_cond_wait` and thirteen unfinished
///     tests, **only one of which was a Vision test** — the other twelve were audio and codec
///     tests that had simply been starved.
///
/// So the rule is the one `MobileScreenTests` already states for CoreMediaIO: a framework that
/// takes the process hostage is exercised in a process that has nothing else to lose.
/// `scripts/cross-boundary-digest-probe.swift` § 22 runs the real segmentation — the mask landing
/// on the frame at four different shapes, both quality levels, and the readback that proves the
/// mask is applied rather than merely computed (an empty room comes back at a peak alpha of 1 out
/// of 255).
///
/// What is left here is the arithmetic, which needs no model and no thread: the level rule, the
/// measured mask widths it turns on, and the one refusal that answers before Vision is reached.
///
/// **Neither place can check whether a person is cut out WELL.** That needs a frame with somebody
/// in it, and a repository does not want a photograph of a human being committed to it to satisfy
/// a test. That judgement is made by looking at a recording.
@Suite("Person mask")
struct PersonMaskTests {
    // MARK: - The level rule

    /// **The rule is "do not upscale the mask".** A card narrower than the cheaper level's own
    /// mask is already served at or above 1:1, and 2.7x the time buys nothing a viewer can see.
    @Test("a camera narrower than the balanced mask is segmented at balanced")
    func aSmallCardIsBalanced() {
        #expect(PersonMask.quality(forCardWidthInPixels: 100) == .balanced)
        #expect(PersonMask.quality(forCardWidthInPixels: 384) == .balanced)
        // 512 is the balanced mask's own width — exactly 1:1, and still not worth 2.7x.
        #expect(PersonMask.quality(forCardWidthInPixels: 512) == .balanced)
    }

    @Test("a camera wider than the balanced mask earns the accurate one")
    func aBigCardIsAccurate() {
        #expect(PersonMask.quality(forCardWidthInPixels: 513) == .accurate)
        #expect(PersonMask.quality(forCardWidthInPixels: 1920) == .accurate)
    }

    /// A card with no width draws nothing, so the level chosen for it cannot be seen — and the
    /// cheaper answer is the safer one to be wrong with. Reachable: a slider mid-drag and a
    /// zero-sized output both arrive here.
    @Test("a width that is not a width answers with the cheaper level rather than trapping")
    func anImpossibleWidthDoesNotTrap() {
        #expect(PersonMask.quality(forCardWidthInPixels: 0) == .balanced)
        #expect(PersonMask.quality(forCardWidthInPixels: -1) == .balanced)
        #expect(PersonMask.quality(forCardWidthInPixels: .nan) == .balanced)
        // **Infinity is not a very wide card; it is not a width.** It reads as "wider than 512"
        // to anybody skimming, which is why it is written down here: it takes the same path as
        // NaN and zero, and answers with the cheaper level rather than committing 56 ms a frame
        // on the strength of a number that means the output size is broken.
        #expect(PersonMask.quality(forCardWidthInPixels: .infinity) == .balanced)
    }

    /// The mask widths are measured numbers — Vision publishes no such figure — and the level
    /// rule is built on them. If either changes, the rule above is choosing by a stale number,
    /// and § 22 of the probe is segmenting at a level nothing here describes.
    @Test("the mask widths are the ones the level rule was measured against")
    func theMaskWidthsAreTheMeasuredOnes() {
        #expect(PersonMask.Quality.balanced.maskWidth == 512)
        #expect(PersonMask.Quality.accurate.maskWidth == 2016)
    }

    // MARK: - The one refusal that answers before Vision is reached

    /// A camera that has been opened but has not produced a frame hands back exactly this. Safe
    /// here because the extent is checked first and the request is never built.
    @Test("a frame with no pixels is refused by name")
    func anEmptyFrameIsRefusedByName() {
        var created: CVPixelBuffer?
        _ = unsafe CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                       &created)
        guard let buffer = created else {
            Issue.record("the fixture buffer was not allocated")
            return
        }
        guard case .refused(let refusal) = PersonMask.cutOut(CIImage.empty(), from: buffer,
                                                             quality: .balanced) else {
            Issue.record("an image with no extent produced a cut-out")
            return
        }
        #expect(refusal == .theFrameHasNoPixels)
    }

    /// Every refusal is a named value with a distinct reason. A duplicate would mean two
    /// different causes reported as one, which is the failure the type exists to prevent.
    @Test("the refusals are distinct reasons rather than one reason spelled three ways")
    func theRefusalsAreDistinct() {
        let all: [PersonMask.Refusal] = [.theFrameHasNoPixels, .visionRefusedTheRequest,
                                         .visionReturnedNoMask]
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }
}
