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
        /// How long after one event before another may be recognised. A tap produces change over
        /// several frames; without this, one tap becomes a burst of five.
        public var quietSeconds: Double
        /// How many frames the baseline averages over.
        public var baselineFrames: Int

        /// **Uncalibrated.** Chosen to read as deliberate on a phone demo at 60 fps and not
        /// measured against anyone: three times the recent average, a floor of 1% of a tile's
        /// range, and a third of a second between events.
        public static let `default` = Settings(burstRatio: 3, floor: 0.01,
                                               quietSeconds: 0.34, baselineFrames: 30)

        public init(burstRatio: Double, floor: Double, quietSeconds: Double,
                    baselineFrames: Int) {
            // Clamped rather than trapped: these arrive from a slider and from a decoder, and
            // D6 rule 8 forbids trapping on an untrusted input.
            self.burstRatio = Swift.min(Swift.max(burstRatio.isFinite ? burstRatio : 3, 1.1), 20)
            self.floor = Swift.min(Swift.max(floor.isFinite ? floor : 0.01, 0.0001), 1)
            self.quietSeconds = Swift.min(Swift.max(quietSeconds.isFinite ? quietSeconds : 0.34,
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
                      quietSeconds: try c.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? 0.34,
                      baselineFrames: try c.decodeIfPresent(Int.self, forKey: .baselineFrames) ?? 30)
        }
    }

    /// How much of the frame one event's target covers, at least. A tap changes a few tiles; a
    /// target that small would be a zoom nobody can follow, so the frame is grown around the
    /// centroid to at least this fraction of the shorter edge. **Uncalibrated.**
    public static let minimumTargetFraction: Double = 0.28

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

            let target = target(of: change, revision: revision, baseline: baseline)
            found.append(FramedClick(instant: change.instant, target: target))
        }
        return found
    }

    /// Where in the frame the change was, and how big to make the target.
    ///
    /// **The centroid of the tiles that exceeded the baseline, weighted by how much they did.**
    /// A plain centroid over every tile drifts to the middle of the picture whenever anything at
    /// all is moving elsewhere — which on a phone is a status-bar clock, every minute.
    static func target(of change: Change, revision: GeometryRevision,
                       baseline: Double) -> FramingTarget {
        let perTileBaseline = baseline / Double(change.tiles.count)
        var weightSum = 0.0, x = 0.0, y = 0.0
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity

        for (index, value) in change.tiles.enumerated() {
            let excess = value - perTileBaseline
            guard excess > 0 else { continue }
            let column = Double(index % change.columns)
            let row = Double(index / change.columns)
            // Tile centres, in 0…1.
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
        // Nothing exceeded the baseline — possible when the total cleared the floor through many
        // tiny tiles. The middle of the picture is the honest answer to "where", and the caller
        // gets a target it can delete.
        guard weightSum > 0 else {
            return FramingTarget(frame: frame(centreX: 0.5, centreY: 0.5,
                                              width: minimumTargetFraction,
                                              height: minimumTargetFraction, revision: revision),
                                 role: nil)
        }
        let centreX = x / weightSum
        let centreY = y / weightSum
        let width = Swift.max(maxX - minX, minimumTargetFraction)
        let height = Swift.max(maxY - minY, minimumTargetFraction)
        return FramingTarget(frame: frame(centreX: centreX, centreY: centreY,
                                          width: width, height: height, revision: revision),
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
