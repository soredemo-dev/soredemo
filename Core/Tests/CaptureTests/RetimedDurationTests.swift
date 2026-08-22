import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Capture

/// **A single timing entry's `duration` is PER SAMPLE, and treating it as the buffer's total
/// inflated every audio track.**
///
/// The rebase built one `CMSampleTimingInfo` with `duration: CMSampleBufferGetDuration(buffer)`
/// and applied it to every sample. A video buffer holds one sample, so the two are equal and
/// that path was never affected; an audio buffer holds hundreds, so each claimed the whole
/// buffer's length. A `.mov` audio track's duration is the sum of its samples' declared
/// durations and `AVAsset.duration` is its longest track, so the editor showed a 16-second
/// recording as 38 — and, in a user's recording, 57.
///
/// Measured on a real master before the fix: video 16.113 s / 740 frames, system audio
/// 38.400 s, microphone 29.720 s. Measured on the OLD implementation by reverting it under
/// this test: a 1024-frame buffer's declared duration went from 0.0213 s to 21.845 s —
/// exactly 1024x, its own sample count.
@Suite struct RetimedDurationTests {
    /// LPCM, 48 kHz stereo, `frames` audio frames in one buffer — the shape ScreenCaptureKit
    /// delivers system audio in.
    private func audioBuffer(frames: Int, atSeconds seconds: Double) throws -> CMSampleBuffer {
        var format: CMFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        _ = unsafe CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let description = try #require(format)

        var block: CMBlockBuffer?
        _ = unsafe CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 8, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 8,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try #require(block)

        var buffer: CMSampleBuffer?
        // One entry whose duration is ONE FRAME — the convention CoreMedia actually uses, and
        // the one the old rebase broke.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid)
        _ = unsafe CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: description, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        return try #require(buffer)
    }

    /// The claim in one line: rebasing changes WHEN a buffer is presented, never how long it
    /// lasts.
    @Test func rebasingAnAudioBufferDoesNotChangeItsDuration() throws {
        let frames = 1024
        let source = try audioBuffer(frames: frames, atSeconds: 12.5)
        let before = CMSampleBufferGetDuration(source)
        // 1024 frames at 48 kHz.
        #expect(abs(before.seconds - Double(frames) / 48_000) < 1e-9,
                "the fixture itself is wrong: \(before.seconds)s for \(frames) frames")

        let moved = try #require(CaptureSession.retimedForTesting(source, to: .zero))
        let after = CMSampleBufferGetDuration(moved)
        #expect(abs(after.seconds - before.seconds) < 1e-9, """
                the rebase changed the buffer's duration from \(before.seconds)s to \
                \(after.seconds)s — \(after.seconds / max(before.seconds, 1e-12))x, which is \
                what inflated the audio tracks
                """)
    }

    @Test func rebasingMovesThePresentationTimeToWhereItWasAsked() throws {
        let source = try audioBuffer(frames: 512, atSeconds: 30)
        let moved = try #require(CaptureSession.retimedForTesting(source, to: .zero))
        #expect(CMSampleBufferGetPresentationTimeStamp(moved) == .zero)
    }

    /// A video buffer is one sample, which is why the old form never showed up there. Pinned
    /// so the fix is known not to have changed the path that was already right.
    @Test func aSingleSampleBufferIsUnaffected() throws {
        let source = try audioBuffer(frames: 1, atSeconds: 5)
        let before = CMSampleBufferGetDuration(source)
        let moved = try #require(CaptureSession.retimedForTesting(source, to: .zero))
        #expect(CMSampleBufferGetDuration(moved) == before)
    }
}
