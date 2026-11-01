import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Capture

/// `AudioInterleave` runs on every audio buffer a recording appends, and nothing tested it: a
/// `.mov` cannot store planar LPCM, so a conversion that dropped or swapped samples would be heard,
/// not seen, and only in a finished recording.
///
/// **The fixture is checked before anything is read off the result** — synthetic CoreMedia
/// buffers are easy to get subtly wrong, and a malformed one produces real-looking errors about
/// the input rather than the code (AGENTS.md, "every fixture set needs a positive control").

private let left: [Float] = [0.1, 0.2, 0.3, 0.4]
private let right: [Float] = [-0.5, -0.6, -0.7, -0.8]
/// Not zero: a timestamp at the origin cannot show whether it was carried across.
private let presentation = CMTime(value: 72_000, timescale: 48_000)

/// Two channels of Float32, PLANAR — each channel its own buffer, which is how the microphone
/// arrives from ScreenCaptureKit.
private func planarStereo() throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                            channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    // `unsafe`: the buffer's channel pointers, read while `buffer` is alive in this scope.
    let channels = try unsafe #require(unsafe buffer.floatChannelData)
    for i in 0..<4 {
        unsafe channels[0][i] = left[i]
        unsafe channels[1][i] = right[i]
    }
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                    presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
    try #require(unsafe CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
        sampleCount: 4, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let created = try #require(sample)
    try #require(unsafe CMSampleBufferSetDataBufferFromAudioBufferList(
        created, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
        bufferList: buffer.audioBufferList) == noErr)
    return created
}

/// The Float32 values of an interleaved buffer, in memory order.
private func floats(of sampleBuffer: CMSampleBuffer) throws -> [Float] {
    let block = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
    let length = CMBlockBufferGetDataLength(block)
    var values = [Float](repeating: 0, count: length / 4)
    try #require(values.withUnsafeMutableBytes { raw in
        unsafe CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                          destination: raw.baseAddress!)
    } == noErr)
    return values
}

@Suite struct AudioInterleaveTests {
    @Test func theFixtureIsPlanarStereoWithFourFrames() throws {
        let fixture = try planarStereo()
        #expect(AudioInterleave.layoutDescription(of: fixture).contains("PLANAR"))
        #expect(AudioInterleave.layoutDescription(of: fixture).hasPrefix("2ch 32-bit float @48000Hz"))
        #expect(CMSampleBufferGetNumSamples(fixture) == 4)
        // RMS reads interleaved Float32 only, so the planar input is refused rather than misread.
        #expect(AudioInterleave.rms(of: fixture) == nil)
    }

    /// The samples come out left, right, left, right — every value, in order, untouched.
    @Test func planarBecomesInterleavedWithTheSameSamples() throws {
        let result = try #require(AudioInterleave.interleaved(try planarStereo()))
        #expect(AudioInterleave.layoutDescription(of: result).contains("INTERLEAVED"))
        #expect(CMSampleBufferGetNumSamples(result) == 4)
        #expect(try floats(of: result) == zip(left, right).flatMap { [$0, $1] })
        #expect(CMSampleBufferGetPresentationTimeStamp(result) == presentation)
    }

    @Test func anInterleavedBufferIsReturnedAsItIs() throws {
        let once = try #require(AudioInterleave.interleaved(try planarStereo()))
        let twice = try #require(AudioInterleave.interleaved(once))
        #expect(once === twice)
    }

    /// Root-mean-square of the eight samples, computed here independently of the code.
    @Test func theLevelIsTheRootMeanSquareOfEverySample() throws {
        let result = try #require(AudioInterleave.interleaved(try planarStereo()))
        let all = (left + right).map(Double.init)
        let expected = (all.map { $0 * $0 }.reduce(0, +) / Double(all.count)).squareRoot()
        let level = try #require(AudioInterleave.rms(of: result))
        #expect(abs(level - expected) < 1e-6)
    }
}
