import AVFoundation
import Foundation
import Overlays
import Timeline

/// Plays the recording under the playhead while somebody drags it.
///
/// **Dragging in silence is the difference between finding a word and hunting for one.** The
/// picture at 3.2 seconds looks like the picture at 3.4; the sentence does not.
///
/// Each move plays one short grain — see `ScrubGrain`, which owns the arithmetic and the reasons
/// for every number. Held still, the same grain repeats and reads as a held note; dragged,
/// successive grains walk through the recording at whatever speed the hand is moving.
///
/// **Silent by construction when there is nothing to play.** A recording with no audio, a file
/// that will not open, an engine that will not start: each leaves this doing nothing rather than
/// failing. Scrub audio is a convenience, and a convenience that can break a drag is worse than
/// one that is absent.
@MainActor
final class ScrubAudio {
    /// The window that is currently in memory, and where it starts.
    private var windowStart = 0
    private var windowSamples: [Float] = []
    /// Where the last grain was played, so a drag can tell which way it is going.
    private var lastSample: Int?

    private var asset: AVURLAsset?
    private var sampleRate = 48_000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var isRunning = false

    /// Whether a person wants this at all. **Off is a real answer** — somebody editing next to a
    /// sleeping child, or with the recording's own audio already playing elsewhere.
    var isEnabled = true

    init() {
        engine.attach(player)
    }

    /// Points this at a recording. Cheap: nothing is read until the first scrub.
    ///
    /// **Mono at the file's own rate.** A scrub is navigation rather than listening, and one
    /// channel is half the reading for an answer nobody is judging the stereo image of.
    func open(_ url: URL) {
        stop()
        asset = AVURLAsset(url: url)
        windowSamples = []
        lastSample = nil
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)
        guard let format else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Plays the grain under `time`, which is in the RECORDING's own clock.
    ///
    /// **Called on every playhead move, including a tap.** A single grain where somebody clicked
    /// is a useful answer to "what is here", and a drag is the same call sixty times a second.
    func scrub(to time: Nanoseconds) {
        guard isEnabled, let asset, let format else { return }
        let seconds = Double(time.rawValue) / 1_000_000_000
        guard seconds.isFinite, seconds >= 0 else { return }

        let start = ScrubGrain.startSample(atSeconds: seconds, sampleRate: sampleRate)
        let length = ScrubGrain.length(sampleRate: sampleRate)
        // **Backwards when the hand is moving left.** Speech reversed is unintelligible and that
        // is not the point: what it carries is the rhythm, which is what somebody navigates by.
        let backwards = lastSample.map { start < $0 } ?? false
        lastSample = start

        guard let samples = window(containing: start, of: asset) else { return }
        guard let grain = ScrubGrain.cut(from: samples, windowStart: windowStart,
                                         startSample: start, length: length,
                                         sampleRate: sampleRate, backwards: backwards) else {
            return
        }
        play(grain, format: format)
    }

    /// Stops the engine and forgets where it was.
    func stop() {
        if isRunning {
            player.stop()
            engine.stop()
            isRunning = false
        }
        lastSample = nil
    }

    // MARK: - Reading

    /// The window holding `sample`, read if it is not the one already in memory.
    ///
    /// **One window, not a cache of many.** A drag is monotonic almost all of the time, so the
    /// window it wants next is the one after this — a second entry would be hit on the frames
    /// where somebody reverses, which is a small share of a small cost. Reading is a few
    /// milliseconds and a drag crosses a window every two seconds.
    private func window(containing sample: Int, of asset: AVURLAsset) -> [Float]? {
        let wanted = ScrubGrain.window(atSeconds: Double(sample) / sampleRate,
                                       sampleRate: sampleRate)
        if !windowSamples.isEmpty, wanted.start == windowStart { return windowSamples }
        guard let read = read(from: asset, start: wanted.start, length: wanted.length) else {
            return nil
        }
        windowStart = wanted.start
        windowSamples = read
        return read
    }

    /// PCM for one window, mono float, at `sampleRate`.
    ///
    /// **`AVAssetReader` with a time range, not `AVAudioFile`.** A recording is a `.mov` with a
    /// video track; `AVAudioFile` opens audio files and this is not one.
    private func read(from asset: AVURLAsset, start: Int, length: Int) -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            duration: CMTime(value: CMTimeValue(length), timescale: CMTimeScale(sampleRate)))
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var samples: [Float] = []
        samples.reserveCapacity(length)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var size = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &size,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let count = size / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        return samples.isEmpty ? nil : samples
    }

    // MARK: - Playing

    /// Schedules one grain, starting the engine on the first.
    ///
    /// **The engine starts lazily and stays running.** Starting it costs tens of milliseconds,
    /// which is most of a drag frame; stopping it between grains would put that cost on every
    /// one. `stop()` is called when the editor closes.
    private func play(_ grain: [Float], format: AVAudioFormat) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(grain.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(grain.count)
        grain.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: grain.count) }

        if !isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else { return }
            player.play()
            isRunning = true
        }
        // **Interrupting rather than queueing.** A queue would play every grain a fast drag asked
        // for, which is a second of audio for a tenth of a second of dragging — the sound would
        // trail the hand and keep going after it stopped.
        player.stop()
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
    }
}
