import Foundation
import Timeline

/// **The camera moves out of the cursor's way.**
///
/// The classic screen-recording flaw: a face in the corner, and the thing being demonstrated
/// is under it. Moving the camera is the answer, and it is rare enough that
/// there is nothing to copy and this is designed from the codebase's own pattern instead.
///
/// **A schedule baked once, not a decision made per frame.** AVFoundation composes frames out
/// of order when a person scrubs, so a per-frame state machine would answer differently for the
/// same frame depending on what was asked before it. `CameraMotion` bakes its path once per
/// composition for the same reason; this bakes a list of moves from a sampled cursor path, and
/// every frame is then a lookup. Preview and export read the same schedule and agree.
///
/// **What it refuses to do, and why.** It does not follow the cursor around the frame — a
/// camera that moved every time the cursor came near would be more distracting than the face it
/// was clearing. It moves to a CORNER, stays there at least `minimumStaySeconds`, and comes home
/// only after the cursor has been clear of home for `dwellSeconds`. Each of those is a named
/// value below and every one is **uncalibrated**: chosen to read as deliberate on a 1080p demo,
/// not measured against anyone.
///
/// **Output pixels in, fractions out.** The samples arrive already mapped into the frame — the
/// compositor is the only thing that can do that, since the cursor's place on screen depends on
/// the zoom in force — and the answer is a `(x, y)` in the style's own 0…1 placement space, so
/// `CameraOverlayStyle.rect` does exactly what it does for a dragged camera.
public enum CameraDodge {
    /// The cursor's place at one instant of OUTPUT time, in output pixels, or `nil` when it is
    /// not drawn there — hidden, blind, or before the first observation. A cursor that is not
    /// drawn is not in anybody's way.
    public struct Sample: Hashable, Sendable {
        public let offset: Nanoseconds
        public let x: Double?
        public let y: Double?

        public init(offset: Nanoseconds, x: Double?, y: Double?) {
            self.offset = offset
            self.x = x
            self.y = y
        }
    }

    /// From `start`, the camera is placed at `(x, y)` — style fractions, `CameraOverlayStyle`'s
    /// own — until the next segment. The first segment is always home at zero.
    public struct Segment: Hashable, Sendable {
        public let start: Nanoseconds
        public let x: Double
        public let y: Double
    }

    /// Where the camera is at every instant of the output.
    public struct Schedule: Hashable, Sendable {
        /// Sorted by `start`; the first is home at zero.
        public let segments: [Segment]

        /// True when the camera never leaves home — the common case, and the one a caller can
        /// short-circuit on.
        public var isStill: Bool { segments.count <= 1 }

        /// The camera's placement at `offset`, gliding from the previous segment's place to the
        /// current one over `transitionSeconds` from the segment's start.
        ///
        /// **The glide starts from the previous segment's TARGET, not from wherever the camera
        /// was mid-glide.** If a move begins before the last one finished, the camera would
        /// otherwise need the last glide's state, and a schedule is meant to be stateless. The
        /// kink this could produce cannot happen in practice: `minimumStaySeconds` keeps
        /// segments further apart than `transitionSeconds` except when the cursor arrives at the
        /// camera's new corner within the stay, which is the case where a kink is the lesser
        /// harm.
        public func placement(at offset: Nanoseconds) -> (x: Double, y: Double) {
            guard let index = segments.lastIndex(where: { $0.start.rawValue <= offset.rawValue })
            else { return (segments.first?.x ?? 0.5, segments.first?.y ?? 0.5) }
            let current = segments[index]
            guard index > 0 else { return (current.x, current.y) }
            let previous = segments[index - 1]
            let elapsed = Double(offset.rawValue - current.start.rawValue) / 1_000_000_000
            let p = min(max(elapsed / CameraDodge.transitionSeconds, 0), 1)
            let eased = p * p * (3 - 2 * p)
            // `(1 − e)·a + e·b`, for `CursorLoop.position`'s reason: exact at both ends.
            let stay = 1 - eased
            return (stay * previous.x + eased * current.x, stay * previous.y + eased * current.y)
        }
    }

    /// How far outside the camera's own rectangle the cursor may come before the camera moves,
    /// as a fraction of the output's width. A cursor that merely brushes the edge of the face is
    /// already in the way of whatever the face is over.
    public static let approachFraction: Double = 0.04
    /// How far the cursor must be from the camera's HOME rectangle before the camera may return,
    /// as a fraction of the output's width. Wider than `approachFraction` on purpose — that gap
    /// is the hysteresis, and without it a cursor resting on the zone's edge would send the
    /// camera back and forth every sample.
    public static let releaseFraction: Double = 0.09
    /// How long the cursor must stay clear of home before the camera comes back. A cursor that
    /// crosses the corner on its way somewhere else is not a reason to move.
    public static let dwellSeconds: Double = 0.6
    /// Once moved, how long the camera stays put before it may move again — except to get out of
    /// the way a second time, which is always allowed. This is what keeps the feature from
    /// reading as a camera that chases the cursor.
    public static let minimumStaySeconds: Double = 1.5
    /// How long a move takes.
    public static let transitionSeconds: Double = 0.4

    /// The four places a dodging camera may go. **Corners only**, whatever home is: a camera
    /// parked in the centre or on an edge is a choice a person made about their composition,
    /// and a dodge is a temporary evacuation, not a new composition. It goes to a corner and
    /// comes back.
    static let corners: [CameraOverlayStyle.Position] = [.bottomRight, .bottomLeft, .topRight, .topLeft]

    /// Bakes the schedule for `style` over `samples`.
    ///
    /// `sourceAspect` is the camera's own picture's aspect, because a rounded or square camera's
    /// rectangle is `width / aspect` tall and the zone has to be the rectangle actually drawn.
    /// A caller that does not know it yet passes 1, which for a landscape camera is a taller
    /// zone than the truth — conservative, so the camera moves a little early rather than a
    /// little late.
    public static func schedule(samples: [Sample], style: CameraOverlayStyle,
                                outputWidth: Int, outputHeight: Int,
                                sourceAspect: Double) -> Schedule {
        let homeFractions = style.position?.fractions ?? (x: style.x, y: style.y)
        let home = Segment(start: Nanoseconds(0), x: homeFractions.x, y: homeFractions.y)
        guard !samples.isEmpty, outputWidth > 0, outputHeight > 0 else {
            return Schedule(segments: [home])
        }

        let approach = Double(outputWidth) * approachFraction
        let release = Double(outputWidth) * releaseFraction

        /// The camera's rectangle when placed at `(x, y)`, unzoomed. Unzoomed on purpose: the
        /// camera shrinks during a zoom (`scaleDuringZoom`), and a zone computed from the
        /// shrunken rectangle would let the cursor sit over where the camera will be the moment
        /// the zoom ends.
        func box(x: Double, y: Double) -> (x: Double, y: Double, width: Double, height: Double) {
            style.changing(x: x, y: y).rect(inOutputWidth: outputWidth, outputHeight: outputHeight,
                                            sourceAspect: sourceAspect)
        }
        func contains(_ box: (x: Double, y: Double, width: Double, height: Double),
                      expandedBy margin: Double, _ sample: Sample) -> Bool {
            guard let cx = sample.x, let cy = sample.y else { return false }
            return cx >= box.x - margin && cx <= box.x + box.width + margin
                && cy >= box.y - margin && cy <= box.y + box.height + margin
        }

        let homeBox = box(x: home.x, y: home.y)
        let cornerBoxes = corners.map { corner -> (corner: CameraOverlayStyle.Position,
                                                   box: (x: Double, y: Double, width: Double, height: Double)) in
            (corner, box(x: corner.fractions.x, y: corner.fractions.y))
        }

        var segments = [home]
        var current = home
        var currentBox = homeBox
        var clearOfHomeSince: Nanoseconds?
        /// When the cursor was last inside each corner's release band. **The memory that stops
        /// a ping-pong.** Excluding only the corners the cursor is on RIGHT NOW let a cursor
        /// dragged back and forth between two corners bounce the camera between them at the
        /// sample rate — measured by `theCameraDoesNotMoveToACornerTheCursorIsAlreadyOn`, which
        /// alternated the cursor every sample and watched the camera never leave the bottom
        /// edge. A corner the cursor has been in within the dwell is treated as still taken.
        var lastSeen: [CameraOverlayStyle.Position: Nanoseconds] = [:]
        let dwellNanos = Int64(dwellSeconds * 1_000_000_000)

        for sample in samples.sorted(by: { $0.offset.rawValue < $1.offset.rawValue }) {
            let sinceMove = Double(sample.offset.rawValue - current.start.rawValue) / 1_000_000_000
            // By PLACE, not by segment: a segment carries its start, and a camera that has come
            // home in a later segment is home. Comparing segments made every return look like
            // a fresh dodge and the camera "returned" again every stay — seven segments where
            // three belonged, caught by `theCameraComesHomeAfterTheCursorHasBeenClearForTheDwell`.
            let atHome = current.x == home.x && current.y == home.y
            for candidate in cornerBoxes where contains(candidate.box, expandedBy: release, sample) {
                lastSeen[candidate.corner] = sample.offset
            }
            func recentlyTaken(_ corner: CameraOverlayStyle.Position) -> Bool {
                guard let seen = lastSeen[corner] else { return false }
                return sample.offset.rawValue - seen.rawValue <= dwellNanos
            }

            if contains(currentBox, expandedBy: approach, sample) {
                // **In the way. Move — now if at home, and always if already dodged.** A dodge
                // that had to wait out its stay while the cursor sat on the face would be a
                // dodge that failed at the one moment it was for.
                let candidates = cornerBoxes.filter { candidate in
                    !(candidate.corner.fractions.x == current.x && candidate.corner.fractions.y == current.y)
                        && !recentlyTaken(candidate.corner)
                }
                // Prefer a corner on home's own horizontal edge — a camera that lives at the
                // bottom stays at the bottom, which is where the person put it — then the one
                // nearest to where the camera is now, so the move is as small as it can be.
                let chosen = candidates.min { a, b in
                    let aSameEdge = a.corner.fractions.y == home.y
                    let bSameEdge = b.corner.fractions.y == home.y
                    if aSameEdge != bSameEdge { return aSameEdge }
                    return distance(a.box, from: currentBox) < distance(b.box, from: currentBox)
                }
                guard let chosen else { continue }   // every corner is occupied: stay put
                current = Segment(start: sample.offset, x: chosen.corner.fractions.x,
                                  y: chosen.corner.fractions.y)
                currentBox = chosen.box
                segments.append(current)
                clearOfHomeSince = nil
            } else if !atHome {
                // Dodged, and the cursor is not on the camera. Come home once it has been clear
                // of HOME long enough and the camera has stayed long enough.
                if contains(homeBox, expandedBy: release, sample) {
                    clearOfHomeSince = nil
                } else {
                    let since = clearOfHomeSince ?? sample.offset
                    clearOfHomeSince = since
                    let clearFor = Double(sample.offset.rawValue - since.rawValue) / 1_000_000_000
                    if clearFor >= dwellSeconds && sinceMove >= minimumStaySeconds {
                        current = Segment(start: sample.offset, x: home.x, y: home.y)
                        currentBox = homeBox
                        segments.append(current)
                        clearOfHomeSince = nil
                    }
                }
            }
        }
        return Schedule(segments: segments)
    }

    private static func distance(_ a: (x: Double, y: Double, width: Double, height: Double),
                                 from b: (x: Double, y: Double, width: Double, height: Double)) -> Double {
        let dx = (a.x + a.width / 2) - (b.x + b.width / 2)
        let dy = (a.y + a.height / 2) - (b.y + b.height / 2)
        return (dx * dx + dy * dy).squareRoot()
    }
}
