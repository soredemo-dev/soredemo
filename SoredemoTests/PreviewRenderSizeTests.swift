import Testing
import Compositing
import Variants
@testable import Soredemo

// What the PREVIEW composites at, which stopped being what the export writes on 2026-09-22.
//
// A `.matchRecording` project put the recording's own size through `AVVideoCompositing` sixty
// times a second: for a 3492 x 1964 recording that is 6.86 Mpixels a frame — background, shadow,
// rounded card, cursor, captions, annotations, redactions, camera — to fill a pane about 900
// points wide. `AVVideoCompositing` drops a frame that misses its deadline and signals -12784,
// which is the stutter and the console line beside it.

@Test func aRecordingLargerThanThePreviewPaneIsComposedSmaller() {
    // The measured case: the user's own recording.
    let full = EditorViewModel.size(for: .landscape, resolution: .matchRecording,
                                recordingShortSide: 1964)
    let preview = EditorViewModel.previewSize(for: .landscape, resolution: .matchRecording,
                                          recordingShortSide: 1964)
    #expect(min(full.width, full.height) == 1964)
    #expect(min(preview.width, preview.height) == EditorViewModel.previewShortSideCap)
    // The pixels actually saved, which is the whole point of the change.
    let before = Double(full.width * full.height)
    let after = Double(preview.width * preview.height)
    #expect(after < before / 3, """
            composing \(preview.width)x\(preview.height) instead of \(full.width)x\(full.height) \
            should be less than a third of the pixels
            """)
}

/// **A cap, never an increase.** A recording smaller than the cap previews at its own size;
/// upscaling it would cost pixels to show detail the recording does not have.
@Test func aRecordingSmallerThanTheCapIsNotEnlarged() {
    for shortSide in [480, 720, 1080] {
        let full = EditorViewModel.size(for: .landscape, resolution: .matchRecording,
                                    recordingShortSide: shortSide)
        let preview = EditorViewModel.previewSize(for: .landscape, resolution: .matchRecording,
                                              recordingShortSide: shortSide)
        #expect(preview.width == full.width && preview.height == full.height,
                "a \(shortSide)p recording should preview at its own size")
    }
}

/// The aspect is what the card is fitted to, so a preview that changed it would compose a
/// differently-shaped video from the one being exported.
@Test func theShapeSurvivesTheCap() {
    for variant in [AspectVariant.landscape, .portrait, .square] {
        let full = EditorViewModel.size(for: variant, resolution: .matchRecording,
                                    recordingShortSide: 2160)
        let preview = EditorViewModel.previewSize(for: variant, resolution: .matchRecording,
                                              recordingShortSide: 2160)
        let fullAspect = Double(full.width) / Double(full.height)
        let previewAspect = Double(preview.width) / Double(preview.height)
        #expect(abs(fullAspect - previewAspect) < 0.01,
                "\(variant): \(full) became \(preview), which is a different shape")
    }
}

/// Odd buffer dimensions are where a stray column of green comes from — the rule the export
/// already keeps, kept here too.
@Test func everyPreviewDimensionIsEven() {
    for shortSide in [1964, 2160, 1440, 1234, 999] {
        for variant in [AspectVariant.landscape, .portrait, .square] {
            let preview = EditorViewModel.previewSize(for: variant, resolution: .matchRecording,
                                                  recordingShortSide: shortSide)
            #expect(preview.width % 2 == 0 && preview.height % 2 == 0,
                    "\(shortSide) \(variant) gave \(preview)")
            #expect(preview.width >= 2 && preview.height >= 2)
        }
    }
}

/// An explicit export resolution is capped for the preview too — somebody exporting 4K should
/// not pay 4K on every preview frame either.
@Test func anExplicitlyLargeExportResolutionIsAlsoCappedForThePreview() {
    let preview = EditorViewModel.previewSize(for: .landscape, resolution: .p2160,
                                          recordingShortSide: 1080)
    #expect(min(preview.width, preview.height) == EditorViewModel.previewShortSideCap)
}
