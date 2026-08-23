import AVFoundation
import Foundation
import Testing
@testable import Compositing

/// Audio is invisible on a timeline strip without this, and a person cannot tell a silent
/// stretch from a spoken one. Follows a native editor's `WaveformExtractor` in shape — mono
/// float32, a fixed slice rate with a total cap, `vDSP_maxmgv` per hop, a dB floor.
extension StageCompositorTests {
    private static func fixtureWithAudio() -> AVURLAsset {
        AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/long-two-track-audio.mov"))
    }

    /// **The mapping is logarithmic, and this is the case that shows why it has to be.**
    /// Linear peak amplitude puts ordinary speech — around −20 dB, a tenth of full scale — at
    /// a tenth of the strip's height, where a person reads it as no audio. The dB mapping puts
    /// it at three fifths.
    @Test func theDecibelMappingLiftsSpeechOffTheFloor() {
        // Full scale is the top.
        #expect(abs(WaveformEnvelope.normalized(peak: 1.0) - 1.0) < 1e-6)
        // Digital silence is the bottom, and so is anything under the floor.
        #expect(WaveformEnvelope.normalized(peak: 0) == 0)
        #expect(WaveformEnvelope.normalized(peak: 0.001) == 0, "−60 dB is below a −50 dB floor")

        // −20 dB is 0.1 linear. Linear drawing would give 0.1 of the height.
        let speech = WaveformEnvelope.normalized(peak: 0.1)
        #expect(speech > 0.55 && speech < 0.65,
                "−20 dB mapped to \(speech); linear would have been 0.1")
        // Monotonic: louder is never drawn shorter.
        #expect(WaveformEnvelope.normalized(peak: 0.5) > speech)
    }

    /// An asset with no audio yields an EMPTY envelope, which is a real answer. Throwing would
    /// make "this recording has no narration" indistinguishable from "the file is broken".
    @Test func anAssetWithNoAudioYieldsAnEmptyEnvelope() async throws {
        let silent = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let envelope = try await WaveformEnvelope.read(from: silent)
        #expect(envelope.isEmpty)
        #expect(envelope.peak(atSeconds: 0) == nil)
    }

    /// The envelope covers the recording: slice count times slice duration is its length.
    @Test func theEnvelopeSpansTheWholeRecording() async throws {
        let asset = Self.fixtureWithAudio()
        let duration = try await asset.load(.duration).seconds
        let envelope = try await WaveformEnvelope.read(from: asset)

        #expect(!envelope.isEmpty)
        #expect(envelope.sliceDuration > 0)
        let covered = Double(envelope.peaks.count) * envelope.sliceDuration
        #expect(abs(covered - duration) < 0.2,
                "the envelope covers \(covered)s of a \(duration)s recording")
        // ~200 slices a second, the rate a native editor uses.
        #expect(abs(1 / envelope.sliceDuration - WaveformEnvelope.slicesPerSecond) < 5)
    }

    /// The fixture is a 440 Hz and an 880 Hz sine mixed — loud throughout — so the envelope
    /// must be high everywhere. A reader that produced zeros would pass a "not empty" check.
    @Test func aLoudRecordingProducesALoudEnvelope() async throws {
        let envelope = try await WaveformEnvelope.read(from: Self.fixtureWithAudio())
        let middle = envelope.peaks[(envelope.peaks.count / 4)..<(envelope.peaks.count * 3 / 4)]
        let average = middle.reduce(0, +) / Float(middle.count)
        #expect(average > 0.5, "a full-scale sine averaged \(average) — the reader found no signal")
        #expect(envelope.peaks.allSatisfy { $0 >= 0 && $0 <= 1 }, "a peak escaped 0…1")
    }

    /// Indexing is by time, not by slice, so a view can ask "how loud is it here" without
    /// knowing how the envelope was sampled.
    @Test func aPeakCanBeFoundByTime() async throws {
        let asset = Self.fixtureWithAudio()
        let duration = try await asset.load(.duration).seconds
        let envelope = try await WaveformEnvelope.read(from: asset)

        #expect(envelope.peak(atSeconds: 0) != nil)
        #expect(envelope.peak(atSeconds: duration / 2) != nil)
        // Past the end is nil, never the last value: a caller asking about a time that does
        // not exist has a bug, and clamping would hide it.
        #expect(envelope.peak(atSeconds: duration + 10) == nil)
        #expect(envelope.peak(atSeconds: -1) == nil)
    }

    /// The reduction to columns is where the envelope meets a strip, and the rule that matters
    /// is that a column takes the LOUDEST slice it covers. Averaging would flatten a click or
    /// the start of a word into the quiet around it — the things a person scans for.
    @Test func aColumnTakesTheLoudestSliceItCovers() {
        // Two seconds at one slice per second: quiet, then loud.
        let envelope = WaveformEnvelope(peaks: [0.0, 1.0], sliceDuration: 1.0)
        // One column covering both must be loud, not the 0.5 an average would give.
        #expect(envelope.columnHeights(columns: 1, spanningSeconds: 2) == [1.0])
        // Two columns keep them apart.
        #expect(envelope.columnHeights(columns: 2, spanningSeconds: 2) == [0.0, 1.0])
    }

    /// Degenerate inputs produce no bars rather than a crash or a division by zero — a strip
    /// laid out at zero width during a window resize is an ordinary event.
    @Test func aStripWithNoRoomProducesNoColumns() {
        let envelope = WaveformEnvelope(peaks: [1.0], sliceDuration: 1.0)
        #expect(envelope.columnHeights(columns: 0, spanningSeconds: 1).isEmpty)
        #expect(envelope.columnHeights(columns: 10, spanningSeconds: 0).isEmpty)
        #expect(WaveformEnvelope(peaks: [], sliceDuration: 0)
            .columnHeights(columns: 10, spanningSeconds: 1).isEmpty)
    }

    @Test func theWaveformErrorCasesDescribeThemselves() {
        #expect(WaveformError.readerRefusedOutput.description.contains("AVAssetReader"))
        #expect(WaveformError.readFailed("why").description.contains("why"))
    }
}

/// One envelope per track — the split that lets a person tell their own voice from the machine's.
@Suite struct PerTrackWaveformTests {
    /// **Two tracks give two envelopes**, which is the whole point: a recording carries system
    /// audio and a microphone, and one strip over both cannot say which is which.
    @Test func twoRecordedTracksGiveTwoEnvelopes() async throws {
        let perTrack = try await WaveformEnvelope.readPerTrack(from: Self.twoTrackFixture())
        #expect(perTrack.count == 2)
        for envelope in perTrack { #expect(!envelope.isEmpty) }
    }

    /// Every envelope shares the mixed read's slice rate. **Two envelopes drawn at different
    /// rates cannot be compared by eye**, which is what a second implementation would drift
    /// into — so both paths go through one function.
    @Test func everyTrackIsSlicedAtTheSameRateAsTheMixedRead() async throws {
        let asset = Self.twoTrackFixture()
        let mixed = try await WaveformEnvelope.read(from: asset)
        for envelope in try await WaveformEnvelope.readPerTrack(from: asset) {
            #expect(envelope.sliceDuration == mixed.sliceDuration)
        }
    }

    /// A recording with no audio gives no envelopes rather than one empty one — the caller draws
    /// a lane per element, and an empty lane for a track that does not exist is a lie.
    @Test func aSilentRecordingGivesNoTracks() async throws {
        let silent = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        #expect(try await WaveformEnvelope.readPerTrack(from: silent).isEmpty)
    }

    private static func twoTrackFixture() -> AVURLAsset {
        AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/long-two-track-audio.mov"))
    }
}
