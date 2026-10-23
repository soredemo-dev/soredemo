import AppKit
import SwiftUI

/// The timeline's one horizontal measurement, shared by every lane and every overlay.
enum TimelineLayout {
    /// The header column's width. One number, because every lane's header and every lane's
    /// content have to start at the same x or the tracks do not line up — which is the single
    /// thing that makes a stack of strips read as a timeline.
    static let headerWidth: Double = 84

    /// Where a lane's content starts: **the header AND the gap after it.** `TimelineLane` is an
    /// `HStack(spacing: Space.snug)` with an 84-point header, so its content starts at 92 and is
    /// 92 narrower than the stack — not 84. Counting the header alone put the playhead 8 points
    /// left of the strip's own and stretched it across 8 points more, which is precisely how far
    /// apart the two playheads in the editor once were.
    static var contentOrigin: Double { headerWidth + Space.snug }

    /// ⌘ held during a drag: put it exactly where the hand is, without snapping.
    static var isExact: Bool { NSEvent.modifierFlags.contains(.command) }
}

/// One track: a labelled header cell and its content, both at the same height.
///
/// **Each lane carries its own header rather than there being two parallel columns.** Two
/// columns built from one list is the obvious shape and the one that drifts: a lane added to
/// the content side and not the header side misaligns every track below it, and nothing
/// catches that. This cannot misalign because there is one row.
struct TimelineLane<Content: View>: View {
    let title: LocalizedStringKey?
    let icon: String?
    let height: Double
    let content: Content

    init(_ title: LocalizedStringKey?, _ icon: String?, height: Double,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.height = height
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Space.snug) {
            HStack(spacing: Space.tight) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(width: 11)
                }
                if let title {
                    Text(title).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: TimelineLayout.headerWidth, height: height, alignment: .leading)
            content
                .frame(height: height)
        }
    }
}
