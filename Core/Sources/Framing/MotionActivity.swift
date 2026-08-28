import Foundation
import Geometry
import Timeline

/// **Where the action is, when there is no cursor to ask.**
///
/// A phone recording has no pointer, no accessibility tree and no clicks this Mac can see, so
/// the framing this app is built around — zoom to the control that was clicked — has nothing to
/// derive from. The picture still knows: a tap opens a menu, a keyboard slides up, a row
/// highlights. Whatever changed is where somebody was looking.
///
/// This turns a sequence of per-frame change grids into `FramedClick`s, which is the same value
/// a real click produces. **Everything downstream is then unchanged**: `ZoomBlock.blocks(for:)`
/// merges them, `FramingDepth` sizes them, the timeline draws them, and a person can drag or
/// delete any of them exactly as they would a zoom derived from a mouse. Building a second zoom
/// pipeline for phones would have been two things to keep in step, and they would not have
/// stayed in step.
///
/// **Deterministic, and therefore in the pure tier.** No clock, no randomness, no frames — the
/// caller has already reduced each frame to a small grid of numbers, which is the only part that
/// needs a decoder. Every rule below is exercised on grids written by hand.
///
/// ### What it cannot do, stated rather than discovered
///
/// It finds CHANGE, not intent. A video playing inside the recorded app changes every frame and
/// is not a tap; a progress spinner changes forever in one place. The rules below are about
/// telling a burst from a background — a tap is a sudden, brief, localised change against a
/// quiet baseline — and they will still be fooled by an app that animates constantly. That is
/// the honest limit of doing this from pixels, and the reason every block it produces is one a
/// person can delete.
public enum MotionActivity {
    /// One frame reduced to how much each tile of it changed since the frame before.
    ///
    /// **A grid, not a picture.** The caller decodes and downsamples; this decides. Keeping the
    /// decoding out means the whole decision is testable against grids somebody wrote by hand,
    /// which is how every rule below is pinned.
    public struct Change: Hashable, Sendable {
        public let instant: HostInstant
        public let columns: Int
        public let rows: Int
        /// Row-major, `columns * rows` values, each the mean absolute difference over that tile
        /// in 0…1. Anything else is refused rather than interpreted.
        public let tiles: [Double]

        public init(instant: HostInstant, columns: Int, rows: Int, tiles: [Double]) {
            self.instant = instant
            self.columns = columns
            self.rows = rows
            self.tiles = tiles
        }

        var isWellFormed: Bool {
            columns > 0 && rows > 0 && tiles.count == columns * rows
        }

        /// How much the whole frame changed.
        var total: Double { tiles.reduce(0, +) }
    }

    /// The rules for telling a tap from a background.
    public struct Settings: Hashable, Sendable, Codable {
        /// How much louder than the recent baseline a frame has to be before it counts as an
        /// event. **A multiple, not an absolute**: an app on a dark background changes by tiny
        /// amounts and an app playing video changes by large ones, and a fixed threshold would
        /// find everything in one and nothing in the other.
        public var burstRatio: Double
        /// The quietest a frame can be and still be an event, as a fraction of a tile's full
        /// range. Without it, a perfectly still recording turns its own sensor noise into taps —
        /// any noise is infinitely louder than a baseline of zero.
        public var floor: Double
        /// How long after one event before another may be recognised.
        ///
        /// **Longer than a zoom block, and that is what sets it.** A tap produces change over
        /// several frames, so some quiet period is needed at all — but `ZoomBlock` spans
        /// `[t-0.4, t+1.0]` and merges any two blocks that overlap, so two events closer than
        /// 1.4 s become one block whose target is the UNION of both. Measured: three taps spread
        /// across an iPad screen merged into a union covering 0.83 x 0.86 of the frame, and the
        /// depth for that is 1.0 — no zoom.
        ///
        /// Which is the right answer for the union and the wrong answer for the recording. A
        /// camera cannot usefully follow taps a third of a second apart anyway; it would never
        /// settle. So events are spaced beyond the merge window and each one gets its own block.
        public var quietSeconds: Double
        /// How many frames the baseline averages over.
        public var baselineFrames: Int

        /// **Uncalibrated.** Chosen to read as deliberate on a phone demo at 60 fps and not
        /// measured against anyone: three times the recent average, a floor of 1% of a tile's
        /// range, and a third of a second between events.
        public static let `default` = Settings(burstRatio: 3, floor: 0.01,
                                               quietSeconds: 1.5, baselineFrames: 30)

        public init(burstRatio: Double, floor: Double, quietSeconds: Double,
                    baselineFrames: Int) {
            // Clamped rather than trapped: these arrive from a slider and from a decoder, and
            // D6 rule 8 forbids trapping on an untrusted input.
            self.burstRatio = Swift.min(Swift.max(burstRatio.isFinite ? burstRatio : 3, 1.1), 20)
            self.floor = Swift.min(Swift.max(floor.isFinite ? floor : 0.01, 0.0001), 1)
            self.quietSeconds = Swift.min(Swift.max(quietSeconds.isFinite ? quietSeconds : 1.5,
                                                    0.05), 5)
            self.baselineFrames = Swift.min(Swift.max(baselineFrames, 2), 600)
        }

        /// **Validated on decode** (D6 rule 8): the synthesised `Decodable` assigns stored
        /// properties directly and would let a project file carry a ratio of zero, which turns
        /// every frame into an event.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(burstRatio: try c.decodeIfPresent(Double.self, forKey: .burstRatio) ?? 3,
                      floor: try c.decodeIfPresent(Double.self, forKey: .floor) ?? 0.01,
                      quietSeconds: try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? 1.5,
                      baselineFrames: try c.decodeIfPresent(Int.self, forKey: .baselineFrames) ?? 30)
        }
    }

    /// How much of the frame one event's target covers, at least. A tap changes a few tiles; a
    /// target that small would be a zoom nobody can follow, so the frame is grown around the
    /// centroid to at least this fraction of the shorter edge. **Uncalibrated.**
    public static let minimumTargetFraction: Double = 0.28

    /// How much of the frame an event may cover and still be treated as a place to zoom to.
    ///
    /// **A change across most of the screen is a transition, not a tap — and zooming to
    /// everything is not zooming.** Measured on a 4K iPad demo: five events, and the one at
    /// 3.93 s covered 0.688 of the frame. It was a page changing. Merged with the tap beside it
    /// its union was the whole picture, and `FramingDepth` correctly answered 1.000 — so the
    /// timeline drew two blocks reading "1×" over a video that never zoomed.
    ///
    /// Dropping it is not a loss: there was nothing to zoom to. Half the frame, **uncalibrated**,
    /// and it keeps the 0.26 event beside it.
    public static let maximumTargetArea: Double = 0.5

    /// Turns per-frame change into the same value a click produces.
    ///
    /// `revision` is the geometry revision every produced frame is stamped with — the caller's,
    /// because a `NormalizedFrame` compared across revisions is a programmer error and this type
    /// has no revision of its own to offer.
    public static func clicks(from changes: [Change], revision: GeometryRevision,
                              settings: Settings = .default) -> [FramedClick] {
        let usable = changes.filter(\.isWellFormed)
            .sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        guard usable.count > settings.baselineFrames else { return [] }

        var found: [FramedClick] = []
        var recent: [Double] = []
        var lastEventTime: Int64?
        let quietNanos = Int64(settings.quietSeconds * 1_000_000_000)

        for change in usable {
            let total = change.total
            defer {
                recent.append(total)
                if recent.count > settings.baselineFrames { recent.removeFirst() }
            }
            // **The baseline is what came BEFORE, never including this frame.** Including it
            // pulls the average up by exactly the thing being measured against it, so a large
            // enough event partly hides itself — worse the larger it is, which is the opposite
            // of what a detector should do.
            guard recent.count == settings.baselineFrames else { continue }
            let baseline = recent.reduce(0, +) / Double(recent.count)
            let tileFloor = settings.floor * Double(change.tiles.count)
            guard total >= tileFloor, total > baseline * settings.burstRatio else { continue }

            // **Epoch-aware, like `ripplePhase` and `CursorPress`.** Host times from two boot
            // sessions overlap, so a gap measured across them is meaningless.
            if let last = lastEventTime, let previous = found.last,
               previous.instant.epoch == change.instant.epoch,
               change.instant.hostTime.rawValue - last < quietNanos {
                continue
            }
            lastEventTime = change.instant.hostTime.rawValue

            // **A frame-wide change is a scene change, and it is dropped rather than framed.**
            // `lastEventTime` is still advanced above, so a transition also holds off the quiet
            // period — the frames right after a page turn are the page settling, not taps.
            //
            // **Measured on the SPREAD, not on the target.** The target is a fixed size now, so
            // its area is a constant and a check against it would pass everything — which is
            // exactly what happened when the target stopped being the bounding box, and what
            // `aChangeCoveringMostOfTheScreenIsNotATap` caught.
            guard spread(of: change) <= maximumTargetArea else { continue }
            let target = target(of: change, revision: revision, baseline: baseline)
            found.append(FramedClick(instant: change.instant, target: target))
        }
        return found
    }

    /// How loud a tile has to be, as a fraction of the loudest tile in the frame, to count as
    /// part of where the action is.
    ///
    /// **This number is the difference between a zoom and no zoom, and a real recording is how
    /// that was found.** The first version took every tile above the frame's average. Measured
    /// on a 4K iPad demo, that produced targets covering the whole picture:
    ///
    ///     click 3.09s  frame(0.104, 0.000, 0.875 x 0.917)  area=0.802
    ///     click 3.93s  frame(0.000, 0.000, 1.000 x 1.000)  area=1.000
    ///
    /// — and `FramingDepth` then correctly answered 1.000, no magnification, for every one of
    /// them. The timeline showed zoom blocks reading "1×" over a video that never zoomed.
    ///
    /// The average is the wrong bar because a real screen is never still: scrolling, animation
    /// and compression noise put a little change in almost every tile, so "above average" is
    /// almost every tile and its bounding box is the frame. Half the LOUDEST tile asks the
    /// question that was meant: where is this concentrated. **Uncalibrated** beyond that.
    public static let peakFraction: Double = 0.5

    /// How much of the frame the change is spread over, 0…1 by area.
    ///
    /// **Separate from `target(of:)` because they answer different questions.** The spread
    /// decides whether this is a tap at all; the centroid decides where it is. They were one
    /// function while the target WAS the bounding box, and separating them is what the change to
    /// a fixed target size required — not a tidy-up.
    static func spread(of change: Change) -> Double {
        let loudest = change.tiles.max() ?? 0
        guard loudest > 0 else { return 0 }
        let bar = loudest * peakFraction
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for (index, value) in change.tiles.enumerated() where value > bar {
            let column = index % change.columns, row = index / change.columns
            minX = Swift.min(minX, column); maxX = Swift.max(maxX, column)
            minY = Swift.min(minY, row); maxY = Swift.max(maxY, row)
        }
        guard minX <= maxX, minY <= maxY else { return 0 }
        let width = Double(maxX - minX + 1) / Double(change.columns)
        let height = Double(maxY - minY + 1) / Double(change.rows)
        return width * height
    }

    /// Where in the frame the change was, and how big to make the target.
    ///
    /// **Weighted by how far each tile exceeds the peak bar, not by its raw value.** A tile that
    /// only just clears the bar should barely move the centre; weighting by the raw value gives
    /// every qualifying tile most of a vote, because they are all loud by definition.
    static func target(of change: Change, revision: GeometryRevision,
                       baseline: Double) -> FramingTarget {
        let loudest = change.tiles.max() ?? 0
        // A frame where nothing changed at all: the middle is the honest answer to "where", and
        // the caller gets a target it can delete.
        guard loudest > 0 else {
            return FramingTarget(frame: frame(centreX: 0.5, centreY: 0.5,
                                              width: minimumTargetFraction,
                                              height: minimumTargetFraction, revision: revision),
                                 role: nil)
        }
        let bar = loudest * peakFraction
        var weightSum = 0.0, x = 0.0, y = 0.0
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity

        for (index, value) in change.tiles.enumerated() {
            let excess = value - bar
            guard excess > 0 else { continue }
            let column = Double(index % change.columns)
            let row = Double(index / change.columns)
            let cx = (column + 0.5) / Double(change.columns)
            let cy = (row + 0.5) / Double(change.rows)
            weightSum += excess
            x += cx * excess
            y += cy * excess
            minX = Swift.min(minX, column / Double(change.columns))
            maxX = Swift.max(maxX, (column + 1) / Double(change.columns))
            minY = Swift.min(minY, row / Double(change.rows))
            maxY = Swift.max(maxY, (row + 1) / Double(change.rows))
        }
        // Only the loudest tile itself cleared the bar, and it cleared it by nothing. Its
        // position is still known — `loudest` is somewhere — so the extent falls back to the
        // minimum around that tile rather than to the middle of the picture.
        guard weightSum > 0 else {
            let index = change.tiles.firstIndex(of: loudest) ?? 0
            let cx = (Double(index % change.columns) + 0.5) / Double(change.columns)
            let cy = (Double(index / change.columns) + 0.5) / Double(change.rows)
            return FramingTarget(frame: frame(centreX: cx, centreY: cy,
                                              width: minimumTargetFraction,
                                              height: minimumTargetFraction, revision: revision),
                                 role: nil)
        }
        // **A fixed size around the centroid, NOT the bounding box — motion says where, not how
        // big.** The bounding box was the first design and it is a claim this signal cannot
        // support. Measured on a 4K iPad demo, the qualifying tiles spanned half the picture at
        // every grid resolution tried:
        //
        //     8x12   extents [0.50, 0.62, 0.28, 0.50]
        //     16x24  extents [0.62, 0.56, 0.46, 0.50]
        //     24x32  extents [0.62, 0.54, 0.50, 0.50]
        //
        // A finer grid changed nothing, because the change really does span that much: tapping
        // a folder highlights it and reflows the grid around it. `FramingDepth` then answers 1.0
        // — correctly, since zooming to a target half the frame tall would crop it — and the
        // timeline showed blocks reading "1x" over a video that never zoomed.
        //
        // What a viewer wants is the place, with some of the surrounding change left outside the
        // frame. That is what a fixed extent gives, and it is honest about what was measured:
        // a centre, and no opinion about size.
        let centreX = x / weightSum
        let centreY = y / weightSum
        _ = (minX, maxX, minY, maxY)
        return FramingTarget(frame: frame(centreX: centreX, centreY: centreY,
                                          width: minimumTargetFraction,
                                          height: minimumTargetFraction, revision: revision),
                             role: nil)
    }

    /// A frame of the given size centred where asked, pushed inside 0…1 rather than clipped.
    ///
    /// **Moved, not shrunk.** Clipping a target that overhangs an edge makes it smaller, and a
    /// smaller target means a DEEPER zoom — so a tap in a corner would zoom further in than the
    /// same tap in the middle, which is the opposite of what anybody expects.
    static func frame(centreX: Double, centreY: Double, width: Double, height: Double,
                      revision: GeometryRevision) -> NormalizedFrame {
        let w = Swift.min(Swift.max(width, 0.01), 1)
        let h = Swift.min(Swift.max(height, 0.01), 1)
        let originX = Swift.min(Swift.max(centreX - w / 2, 0), 1 - w)
        let originY = Swift.min(Swift.max(centreY - h / 2, 0), 1 - h)
        return NormalizedFrame(origin: NormalizedPoint(x: originX, y: originY),
                               size: NormalizedSize(width: w, height: h),
                               revision: revision)
    }
}
