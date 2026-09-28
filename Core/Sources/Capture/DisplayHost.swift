import Foundation
import Geometry

/// **Which display a window or a dragged region belongs to — the one rule for it.**
///
/// It was written three times until 2026-09-28, and the three disagreed whenever a rectangle's
/// centre sat on no display: the system picker fell back to a display the rectangle overlapped,
/// pointing at a window fell back to the FIRST display whether it overlapped or not — a recording
/// of a screen the window was never on — and a dragged region gave up. Two derivations of one
/// fact that disagree is a defect waiting for the arrangement that exposes it (AGENTS.md).
///
/// Pure over `PointRect`s so it can be tested: an `SCDisplay` cannot be constructed in a unit
/// test, and this is where the decision lives. `DisplayHostTests`.
public enum DisplayHost {
    /// The index in `displays` of the one that hosts `frame`, all in global top-left points.
    ///
    /// **The display the centre is on, then any display the rectangle overlaps, then none.**
    /// Centre first because a rectangle straddling two displays belongs to the one showing most of
    /// it; overlap second because a window dragged so its middle is past an edge — into the gap
    /// under a shorter display — still has a display it can be cropped out of. A right or bottom
    /// edge is not inside a display, so a centre on the seam belongs to the display starting there.
    public nonisolated static func index(for frame: PointRect, among displays: [PointRect]) -> Int? {
        let centreX = frame.x + frame.width / 2
        let centreY = frame.y + frame.height / 2
        if let centred = displays.firstIndex(where: { bounds in
            centreX >= bounds.x && centreX < bounds.x + bounds.width
                && centreY >= bounds.y && centreY < bounds.y + bounds.height
        }) {
            return centred
        }
        return displays.firstIndex { bounds in
            frame.x < bounds.x + bounds.width && frame.x + frame.width > bounds.x
                && frame.y < bounds.y + bounds.height && frame.y + frame.height > bounds.y
        }
    }
}
