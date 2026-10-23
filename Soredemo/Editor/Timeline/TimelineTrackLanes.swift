import Compositing
import Overlays
import SwiftUI
import Timeline

/// One recorded audio track's waveform, on its own ground.
///
/// **Audio has its own lane, and until it did the waveform was invisible.** It was drawn inside
/// the video strip, underneath the clip rectangles — which are opaque, so it was covered on
/// every frame it existed. A waveform behind the picture track is a waveform nobody sees.
struct TimelineAudioLane: View {
    let model: TimelineEditorModel
    /// `nil` while the audio is still being read, or when there is no per-track envelope.
    let envelope: WaveformEnvelope?
    var tint: Color = Theme.Lane.audio

    var body: some View {
        GeometryReader { geometry in
            // `.topLeading`, matching the bars' own alignment: centred, the strip would sit
            // wherever its measured width put it rather than at time zero.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                if let envelope, !envelope.isEmpty {
                    waveform(envelope, width: geometry.size.width, height: geometry.size.height)
                } else if envelope == nil && model.waveform == nil {
                    // Said rather than left blank: an empty lane and a lane still reading the
                    // audio look the same, and one of them is worth waiting for.
                    Text("Reading the audio\u{2026}")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A track that exists and is silent says so, rather than looking like one
                    // still loading — a muted microphone and a microphone that failed produce
                    // the same empty lane otherwise.
                    Text("Silent")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The audio envelope as bars.
    ///
    /// **One bar per pixel, taking the MAXIMUM of the slices that fall in it.** The envelope is
    /// 200 slices a second and the strip is a few hundred points wide, so most pixels cover
    /// several slices. Averaging them would flatten a transient — a click, the start of a word
    /// — into the quiet around it, and those are exactly what a person is looking for when they
    /// scan a waveform for where to cut.
    @ViewBuilder private func waveform(_ envelope: WaveformEnvelope, width: Double,
                                       height: Double) -> some View {
        if width > 0 {
            // The window's span, not the recording's — a zoomed strip must show the audio it
            // is showing, and the offset comes from where the window starts.
            WaveformBars(
                heights: envelope.columnHeights(
                    columns: Int(width.rounded(.down)),
                    from: Double(model.window.start.rawValue) / 1_000_000_000,
                    spanningSeconds: Double(model.window.visible.rawValue) / 1_000_000_000),
                height: height, width: width, tint: tint)
                .equatable()
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// **The master writes system audio first and the microphone second.** That order is
    /// `AudioMixBuilder.trackOrder`, which the export mixes by and which has a test on it; an
    /// `AVAssetTrack` carries no name to match on, so the index IS the identity.
    static func trackName(_ index: Int) -> LocalizedStringKey {
        switch index {
        case 0: "System"
        case 1: "Mic"
        default: "Audio \(index + 1)"
        }
    }

    static func trackIcon(_ index: Int) -> String {
        switch index {
        case 0: "speaker.wave.2"
        case 1: "mic"
        default: "waveform"
        }
    }

    /// The two sources are two hues from the same family — the system's audio nearer the video
    /// track it belongs to, the microphone nearer the caption track it produces.
    static func tint(_ index: Int) -> Color {
        switch index {
        case 0: Theme.Lane.audio
        case 1: Theme.Lane.caption
        default: Theme.Ink.secondary
        }
    }
}

/// A lane of plain blocks. Read-only: the panel that owns each kind is where it is edited, and a
/// block here that could be dragged would be a second place to change the same value.
struct TimelineBlocks: View {
    let model: TimelineEditorModel
    let spans: [(Nanoseconds, Nanoseconds)]
    let tint: Color
    /// What to do when a block is clicked, given its index. **Given the BLOCK's index rather
    /// than the time under the pointer**: a lane of blocks is a list seen sideways, and clicking
    /// one means "that one" — landing the playhead a few milliseconds inside a caption would put
    /// it on the same cue but not at its start, which is where somebody clicking it wants to
    /// hear from.
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                ForEach(Array(spans.enumerated()), id: \.offset) { index, span in
                    let x = model.window.fraction(of: span.0) * width
                    let w = (model.window.fraction(of: span.1)
                             - model.window.fraction(of: span.0)) * width
                    RoundedRectangle(cornerRadius: Radius.block)
                        .fill(tint.opacity(0.75))
                        // **A hit target wider than the block when the block is a hairline.** At
                        // a whole-recording zoom a one-second caption is two points across, and
                        // a two-point target is one nobody can hit; the drawn width stays honest
                        // about the span while the tappable one does not go below a finger.
                        .frame(width: max(w, 2))
                        .contentShape(Rectangle().inset(by: -max(0, (8 - max(w, 2)) / 2)))
                        .offset(x: x)
                        .onTapGesture { onTap?(index) }
                }
            }
        }
    }
}

/// A flag per chapter with its name beside it; tapping one puts the playhead there. Names are
/// clipped rather than wrapped — the full name is in the Chapters tab.
struct TimelineChapterMarks: View {
    let model: TimelineEditorModel
    let chapters: ChapterTrack

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.block).fill(Theme.Fill.track)
                ForEach(chapters.chapters) { chapter in
                    let fraction = model.window.fraction(of: chapter.start)
                    if fraction >= 0, fraction <= 1 {
                        HStack(spacing: 2) {
                            Rectangle().fill(Theme.Lane.chapter).frame(width: 2)
                            Text(verbatim: chapter.title)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.Lane.chapter)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: max(24, (1 - fraction) * width), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .offset(x: fraction * width)
                        .onTapGesture { model.movePlayhead(to: chapter.start) }
                        .help(Text(verbatim: chapter.title))
                    }
                }
            }
        }
    }
}
