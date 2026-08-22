import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Capture

/// **Dropping a sample for a busy input is self-perpetuating, and it emptied every recording.**
///
/// `AVAssetWriter` reports an input not-ready while it waits for the OTHER inputs to advance
/// past the point being written. Dropping the sample means that input never advances, so the
/// writer's interleaving never gets past it, so it stays not-ready — permanently. Two user
/// recordings measured 23 and 26 seconds of video against 0.07 and 0.08 seconds of audio:
/// about four buffers each, which is the writer's initial allowance before it first needs the
/// others to catch up.
///
/// The fix is to hold rather than drop. These drive `MasterTrackWriting` directly with a track
/// that refuses for a while and then accepts, which is the shape the real writer presents and
/// the one a real capture cannot be made to reproduce on demand.
@Suite struct HeldAudioTests {
    /// A track that is not ready until `readyAfter` appends have been ATTEMPTED against a
    /// ready state — i.e. it simulates a writer that unblocks once something else advances.
    private final class GatedTrack: MasterTrackWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var ready: Bool
        private(set) var accepted: [CMTime] = []

        init(startsReady: Bool) { ready = startsReady }

        var isReadyForMoreMediaData: Bool { lock.withLock { ready } }
        func unblock() { lock.withLock { ready = true } }
        func block() { lock.withLock { ready = false } }

        func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
            lock.withLock {
                guard ready else { return false }
                accepted.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                return true
            }
        }
    }

    private func silentBuffer(atSeconds seconds: Double) throws -> CMSampleBuffer {
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

        let frames = 1024
        var block: CMBlockBuffer?
        // `unsafe`: a C constructor writing through an out-parameter. Safe here — `block` is a
        // local that outlives the call, and it is only used through `#require`, which fails the
        // test rather than reading an uninitialised handle if the call did not produce one.
        _ = unsafe CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 8, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 8,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try #require(block)

        var buffer: CMSampleBuffer?
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

    /// The whole claim in one case: buffers arriving while the input refuses are not lost, and
    /// arrive in order once it accepts.
    @Test func audioArrivingWhileTheInputRefusesIsHeldAndThenWritten() throws {
        let track = GatedTrack(startsReady: false)
        let queue = HeldAudioQueue(limit: 400)

        for step in 0..<10 {
            queue.enqueue(try silentBuffer(atSeconds: Double(step) * 0.02))
            queue.drain(into: track)
        }
        #expect(track.accepted.isEmpty, "the gated track accepted while refusing")
        #expect(queue.count == 10, "buffers were dropped instead of held")

        track.unblock()
        queue.drain(into: track)
        #expect(track.accepted.count == 10, "held audio did not reach the input")
        #expect(queue.count == 0)
        // Oldest first: audio written out of order is audio played out of order.
        let seconds = track.accepted.map { $0.seconds }
        #expect(seconds == seconds.sorted())
    }

    /// A queue that fills is a writer that is stuck rather than behind, and the loss is real.
    /// Bounded so a stuck writer cannot grow it until the process dies.
    @Test func aFullQueueDropsAndSaysSo() throws {
        let queue = HeldAudioQueue(limit: 3)
        for step in 0..<5 { queue.enqueue(try silentBuffer(atSeconds: Double(step) * 0.02)) }
        #expect(queue.count == 3)
        #expect(queue.dropped == 2)
    }

    /// Draining stops at the first refusal rather than spinning: an input that says no once
    /// will say no to the next buffer too, and the remaining ones stay held.
    @Test func drainingStopsAtTheFirstRefusalAndKeepsTheRest() throws {
        let track = GatedTrack(startsReady: true)
        let queue = HeldAudioQueue(limit: 400)
        for step in 0..<4 { queue.enqueue(try silentBuffer(atSeconds: Double(step) * 0.02)) }

        queue.drain(into: track)
        #expect(track.accepted.count == 4)

        track.block()
        for step in 4..<8 { queue.enqueue(try silentBuffer(atSeconds: Double(step) * 0.02)) }
        queue.drain(into: track)
        #expect(track.accepted.count == 4, "a blocked track accepted more")
        #expect(queue.count == 4, "the refused buffers were not kept")
    }
}
