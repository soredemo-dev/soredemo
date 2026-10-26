import Foundation
import CoreMedia
import Overlays

/// **Chapters as a 3GPP text track, because that is the form that is read back.** A
/// timed-metadata track with the same `chap` association is written without complaint and
/// comes back as zero chapters; a `tx3g` track comes back whole, through AVFoundation and
/// through ffprobe — measured, `docs/design/2026-09-27-chapters.md`, D6b-28.
enum ChapterSamples {
    /// Ticks per second for chapter times. 1000 fits 49 days in the format's 32 bits.
    static let timescale: CMTimeScale = 1000

    /// Why a chapter list cannot be written as given.
    static func refusal(_ chapters: [PlacedChapter]) -> String? {
        for (index, chapter) in chapters.enumerated() {
            if chapter.start.rawValue < 0 { return "chapter \(chapter.id) starts before the output" }
            if chapter.duration.rawValue < 1_000_000 { return "chapter \(chapter.id) lasts under a millisecond" }
            if index > 0, chapter.start.rawValue < chapters[index - 1].start.rawValue
                + chapters[index - 1].duration.rawValue {
                return "chapter \(chapter.id) starts before chapter \(chapters[index - 1].id) ends"
            }
        }
        return nil
    }

    /// The description every chapter sample shares. The style keys are what the format
    /// requires, not a look: the track is disabled and never drawn.
    static func format() throws -> CMFormatDescription {
        let white: [CFString: Int] = [kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                                      kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: white.mapValues { _ in 0 },
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor: white,
                kCMTextFormatDescriptionStyle_FontSize: 12] as [CFString: Any],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: 0,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var description: CMFormatDescription?
        let status = unsafe CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw MP4Exporter.ExportError.chaptersUnwritable("text format description failed: \(status)")
        }
        return description
    }

    /// One chapter title as a sample: a big-endian length, then the UTF-8 bytes. **No `encd`
    /// box** — written without one, `錄影` and `✓` came back intact through AVFoundation and
    /// ffprobe, so it had no measured job.
    static func sample(_ chapter: PlacedChapter, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(chapter.name.utf8.prefix(Int(UInt16.max)))
        let bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8
        var block: CMBlockBuffer?
        var status = unsafe CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else {
            throw MP4Exporter.ExportError.chaptersUnwritable("block for chapter \(chapter.id): \(status)")
        }
        status = bytes.withUnsafeBytes { raw in
            unsafe CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else {
            throw MP4Exporter.ExportError.chaptersUnwritable("bytes for chapter \(chapter.id): \(status)")
        }
        // **Milliseconds, not the nanoseconds everything else here uses.** The track takes its
        // timescale from its samples and MP4 stores times in 32 bits: at 1e9 a chapter starting
        // past 4.29 s overflowed and the writer refused it (-17771), measured on a 10 s export.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: chapter.duration.rawValue / 1_000_000, timescale: timescale),
            presentationTimeStamp: CMTime(value: chapter.start.rawValue / 1_000_000, timescale: timescale),
            decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = unsafe CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw MP4Exporter.ExportError.chaptersUnwritable("sample for chapter \(chapter.id): \(status)")
        }
        return sample
    }
}
