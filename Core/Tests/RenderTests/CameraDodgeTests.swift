import Foundation
import Testing
import Timeline
@testable import Render

/// The dodge schedule: when the camera moves, where it goes, when it comes back, and how it
/// gets there. Every input is a synthetic cursor path in output pixels, so each rule is tested
/// in isolation and the numbers are exact.
@Suite struct CameraDodgeTests {
    private let width = 1920
    private let height = 1080
    private let second: Int64 = 1_000_000_000

    /// Bottom-right, the corner almost every camera lives in.
    private let home = CameraOverlayStyle.default.placed(at: .bottomRight)

    /// A sample every 1/30 s over `seconds`, with the cursor wherever `at` says.
    private func path(seconds: Double, at cursor: (Double) -> (x: Double, y: Double)?)
    -> [CameraDodge.Sample] {
        stride(from: 0.0, through: seconds, by: 1.0 / 30).map { t in
            let point = cursor(t)
            return CameraDodge.Sample(offset: Nanoseconds(Int64(t * 1e9)), x: point?.x, y: point?.y)
        }
    }

    private func schedule(_ samples: [CameraDodge.Sample],
                          style: CameraOverlayStyle? = nil) -> CameraDodge.Schedule {
        CameraDodge.schedule(samples: samples, style: style ?? home,
                             outputWidth: width, outputHeight: height, sourceAspect: 1)
    }

    /// The centre of the camera when placed at `position`, in output pixels.
    private func centre(of position: CameraOverlayStyle.Position) -> (x: Double, y: Double) {
        let box = home.placed(at: position).rect(inOutputWidth: width, outputHeight: height,
                                                 sourceAspect: 1)
        return (box.x + box.width / 2, box.y + box.height / 2)
    }

    // MARK: - when it moves

    @Test func aCursorThatNeverComesNearLeavesTheCameraHome() {
        let far = schedule(path(seconds: 10) { _ in (x: 200, y: 900) })
        #expect(far.isStill)
        let placed = far.placement(at: Nanoseconds(5 * second))
        let homeX = home.placed(at: .bottomRight).x
        #expect(placed.x == homeX)
    }

    /// A cursor that is not drawn is not in anybody's way.
    @Test func aHiddenCursorOverTheCameraDoesNotMoveIt() {
        let hidden = schedule(path(seconds: 10) { _ in nil })
        #expect(hidden.isStill)
    }

    @Test func aCursorArrivingOnTheCameraMovesItAtOnce() throws {
        let onCamera = centre(of: .bottomRight)
        let moved = schedule(path(seconds: 6) { t in t < 2 ? (x: 200, y: 900) : onCamera })
        #expect(moved.segments.count >= 2)
        let move = try #require(moved.segments.dropFirst().first)
        // Within one sample of the arrival: "at once" for a schedule sampled at 30 Hz.
        let movedAt = Double(move.start.rawValue) / 1e9
        let oneSample = 1.0 / 30 + 1e-9
        #expect(abs(movedAt - 2) < oneSample)
        let stayedPut = move.x == 1 && move.y == 0
        #expect(!stayedPut, "the camera moved to where it already was")
    }

    /// **Same edge first.** A camera that lives at the bottom stays at the bottom, which is
    /// where the person put it; the top corners are for when the bottom is taken.
    @Test func theCameraPrefersACornerOnItsOwnEdge() throws {
        let onCamera = centre(of: .bottomRight)
        let moved = schedule(path(seconds: 6) { t in t < 1 ? (x: 900, y: 900) : onCamera })
        let move = try #require(moved.segments.dropFirst().first)
        let wentBottomLeft = move.x == 0 && move.y == 0
        #expect(wentBottomLeft, "expected bottom-left, got (\(move.x), \(move.y))")
    }

    /// When the cursor is over BOTH bottom corners' zones — impossible for one point, so this
    /// puts it on the bottom-left while the camera is bottom-right and the cursor's release zone
    /// covers the left — the camera takes a top corner rather than moving under the cursor.
    @Test func theCameraDoesNotMoveToACornerTheCursorIsAlreadyOn() throws {
        // A cursor exactly at the bottom-right camera's inner edge AND within the release band
        // of bottom-left is not possible on a 1920 frame, so instead: cursor sits on the
        // bottom-left corner first, then jumps onto the camera at bottom-right.
        let left = centre(of: .bottomLeft)
        let right = centre(of: .bottomRight)
        // Alternate every sample between the two bottom corners: whichever corner the camera
        // is on, the cursor is on it within a sample, and the other bottom corner is occupied
        // within the release band at the same instant only if the sample says so — so the
        // schedule must end up using a TOP corner at some point.
        var flip = false
        let harassed = schedule(path(seconds: 8) { _ in flip.toggle(); return flip ? left : right })
        let usedTop = harassed.segments.contains { $0.y == 1 }
        #expect(usedTop, "the camera never left the bottom edge while both bottom corners were in use")
    }

    // MARK: - hysteresis and dwell

    /// **A cursor resting on the zone's edge must not send the camera back and forth.** The
    /// approach and release bands differ, and this is the test that the gap between them does
    /// its job: the cursor sits exactly on the approach boundary and jitters by one pixel.
    @Test func aCursorJitteringOnTheZoneEdgeCausesOneMoveNotMany() {
        let box = home.rect(inOutputWidth: width, outputHeight: height, sourceAspect: 1)
        let edgeX = box.x - Double(width) * CameraDodge.approachFraction
        var flip = false
        let jitter = schedule(path(seconds: 10) { t in
            guard t >= 1 else { return (x: 200, y: 900) }
            flip.toggle()
            return (x: edgeX + (flip ? 0.5 : -0.5), y: box.y + box.height / 2)
        })
        // One move away, and no return while the cursor is still inside the release band.
        #expect(jitter.segments.count == 2,
                "\(jitter.segments.count - 1) moves for a cursor jittering on one edge")
    }

    /// The camera comes home only after the cursor has been clear of home for `dwellSeconds`
    /// — a cursor crossing the corner on its way elsewhere is not a reason to move.
    @Test func theCameraComesHomeAfterTheCursorHasBeenClearForTheDwell() throws {
        let onCamera = centre(of: .bottomRight)
        let visit = schedule(path(seconds: 10) { t in (t >= 2 && t < 2.2) ? onCamera : (x: 200, y: 900) })
        #expect(visit.segments.count == 3, "expected away and back, got \(visit.segments.count - 1) moves")
        let back = try #require(visit.segments.last)
        let backHome = back.x == 1 && back.y == 0
        #expect(backHome)
        // Not before the stay AND the dwell are both satisfied: the move was at 2.0 s, the stay
        // is 1.5 s, the cursor left at 2.2 s and the dwell is 0.6 s — so 3.5 s, the stay,
        // is the binding one.
        let returnedAt = Double(back.start.rawValue) / 1e9
        let earliest = 2 + CameraDodge.minimumStaySeconds - 1e-9
        let latest = 2 + CameraDodge.minimumStaySeconds + 1.0 / 30 + 1e-9
        #expect(returnedAt >= earliest)
        #expect(returnedAt < latest)
    }

    /// While the cursor keeps returning to home's release band, the camera stays away — the
    /// dwell clock restarts on every return.
    @Test func theCameraStaysAwayWhileTheCursorKeepsComingBack() {
        let onCamera = centre(of: .bottomRight)
        // On the camera at 2 s; then every 0.4 s a brief return to home's band, forever.
        let pestered = schedule(path(seconds: 12) { t in
            guard t >= 2 else { return (x: 200, y: 900) }
            let phase = (t - 2).truncatingRemainder(dividingBy: 0.4)
            return phase < 0.05 ? onCamera : (x: 200, y: 900)
        })
        // Exactly one move: away. Never home, because the dwell never completes.
        #expect(pestered.segments.count == 2,
                "expected the camera to stay away, got \(pestered.segments.count - 1) moves")
    }

    // MARK: - the glide

    @Test func thePlacementGlidesRatherThanJumpsAndArrivesExactly() throws {
        let onCamera = centre(of: .bottomRight)
        let moved = schedule(path(seconds: 6) { t in t < 2 ? (x: 900, y: 900) : onCamera })
        let move = try #require(moved.segments.dropFirst().first)
        let start = move.start
        let before = moved.placement(at: Nanoseconds(start.rawValue - 1))
        let beforeIsHome = before.x == 1 && before.y == 0
        #expect(beforeIsHome, "moved before the segment began")
        let halfway = Nanoseconds(start.rawValue + Int64(CameraDodge.transitionSeconds * 0.5e9))
        let midway = moved.placement(at: halfway)
        let midwayIsBetween = midway.x > 0 && midway.x < 1
        #expect(midwayIsBetween, "no glide — the camera jumped")
        let end = Nanoseconds(start.rawValue + Int64(CameraDodge.transitionSeconds * 1e9))
        let arrived = moved.placement(at: end)
        let arrivedExactly = arrived.x == move.x && arrived.y == move.y
        #expect(arrivedExactly, "did not arrive exactly")
        // Frame to frame the camera never leaps: the largest step over a 60 Hz frame is a
        // fraction of the whole distance.
        var largestStep = 0.0
        var previous = before
        let frames = Int(CameraDodge.transitionSeconds * 60 + 2)
        for frame in 0...frames {
            let offsetNanos = Int64(Double(frame) / 60 * 1e9)
            let at = Nanoseconds(start.rawValue + offsetNanos)
            let now = moved.placement(at: at)
            largestStep = max(largestStep, abs(now.x - previous.x))
            previous = now
        }
        #expect(largestStep < 0.12, "a single frame moved the camera \(largestStep) of the width")
    }

    /// A home that is not a preset — a dragged coordinate — still dodges, and still comes back
    /// to exactly those coordinates.
    @Test func aDraggedCameraComesBackToItsDraggedPlace() throws {
        let dragged = CameraOverlayStyle.default.changing(x: 0.7, y: 0.3)
        let box = dragged.rect(inOutputWidth: width, outputHeight: height, sourceAspect: 1)
        let onCamera = (x: box.x + box.width / 2, y: box.y + box.height / 2)
        let moved = schedule(path(seconds: 10) { t in (t >= 1 && t < 1.3) ? onCamera : (x: 100, y: 1000) },
                             style: dragged)
        let back = try #require(moved.segments.last)
        #expect(moved.segments.count == 3)
        let backExactly = back.x == 0.7 && back.y == 0.3
        #expect(backExactly)
    }

    // MARK: - the style

    @Test func aStyleSavedBeforeTheDodgeExistedDecodesWithItOff() throws {
        let decoded = try JSONDecoder().decode(CameraOverlayStyle.self, from: Data("{}".utf8))
        #expect(decoded.avoidsCursor == false)
        let on = CameraOverlayStyle.default.changing(avoidsCursor: true)
        let round = try JSONDecoder().decode(CameraOverlayStyle.self,
                                             from: JSONEncoder().encode(on))
        #expect(round.avoidsCursor == true)
        // And `placed(at:)` carries it, so choosing a corner does not silently switch it off.
        #expect(on.placed(at: .topLeft).avoidsCursor == true)
    }
}
