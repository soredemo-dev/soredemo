import Capture
import SwiftUI

/// What to capture: the cards a person chooses between before pressing Record or Screenshot.
struct MenuBarTargets: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        targets
    }

    /// **Chosen, not pressed.** Pressing a card used to start, which made the panel's three cards
    /// and its Start button four ways in that looked like two kinds of thing; now a card is the
    /// choice and Record or Screenshot is the act, as in Apple's capture toolbar.
    @ViewBuilder private var targets: some View {
        HStack(spacing: Space.snug) {
            TargetCard(icon: "display", title: "Screen", detail: "A whole display",
                       isSelected: coordinator.isChosen(.screen), isBusy: coordinator.pendingMode == .displaysOnly) {
                coordinator.choose(.screen)
            }
            TargetCard(icon: "macwindow", title: "Window", detail: "Point at it",
                       isSelected: coordinator.isChosen(.window), isBusy: coordinator.pendingMode == .windowsOnly) {
                coordinator.choose(.window)
            }
            // **The third thing a recorder has to be able to point at.** A display capture of a
            // demo living in a small panel spends most of its pixels on desktop, and a window
            // capture cannot do it at all when the subject is part of a window rather than all
            // of it.
            TargetCard(icon: "rectangle.dashed", title: "Area", detail: "Drag it out",
                       isSelected: coordinator.isChosen(.area), isBusy: coordinator.pendingMode == .region) {
                coordinator.choose(.area)
            }
        }
        // **The fourth card exists only while a device does.** A card that is always there and
        // usually disabled is a permanent reminder of a thing somebody is not doing; this row
        // appears when a phone is plugged in and disappears when it is unplugged, which is the
        // same moment they stop caring about it. It is worth shipping
        // phone recording; none of the seven open-source projects beside this repo does.
        // A phone is recorded through a different stack with no screenshot path; its card is a
        // take's only.
        if !coordinator.availableMobileScreens.isEmpty {
            VStack(alignment: .leading, spacing: Space.snug) {
                ForEach(coordinator.availableMobileScreens) { device in
                    TargetCard(icon: device.symbolName, title: "",
                               verbatimTitle: device.displayName, detail: "Its screen",
                               isSelected: coordinator.isChosen(device: device),
                               isBusy: false) {
                        coordinator.choose(device: device)
                    }
                }
                // **Said before the recording, not after it.** iOS does not send touch
                // coordinates to a Mac — measured, and documented by others —
                // so there is nothing to derive an automatic zoom from. Somebody expecting the
                // zooms they get on a Mac is owed that in advance, along with the one thing that
                // does work: a Bluetooth mouse paired to the device puts a real cursor in the
                // recording, and everything that follows a cursor then has one to follow.
                Text("Zooms are manual here \u{2014} iOS does not share where you tap. A Bluetooth mouse paired to the device gives it a cursor to follow.")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
            .padding(.top, Space.snug)
        } else if !coordinator.mobileScreensWaiting.isEmpty {
            // **What to do, not what is wrong.** A device on the bus that is not offering its
            // screen is almost always locked; trust is asked once and remembered, so a person
            // who has plugged this iPad in before will never see that prompt again and has no
            // way to guess. Developer Mode has nothing to do with it — that is for running your
            // own builds from Xcode — and saying so here saves the search.
            // **One interpolated sentence, not two `Text`s added together.** `Text + Text` is
            // deprecated, and it was also the wrong shape: a translator handed a fragment
            // beginning " is connected." cannot move the device's name to where their language
            // puts it.
            Label("\(coordinator.mobileScreensWaiting.joined(separator: ", ")) is connected. Unlock it \u{2014} and tap Trust if it asks \u{2014} to record its screen.",
                  systemImage: "lock.iphone")
            .font(Type.detail)
            .foregroundStyle(Signal.paused)
            .padding(.top, Space.snug)
        }
    }
}

/// One choice of target: a screen, a window, an area, or a connected device.
private struct TargetCard: View {
    let icon: String
    // **`LocalizedStringKey`, not `String`, and that is the whole translation bug.** Every one
    // of these words was already in `zh-Hant.lproj/Localizable.strings` — "Screen" = "螢幕" has
    // been there since the file was written. SwiftUI only looks a string up when it arrives as
    // a `LocalizedStringKey`; a `String` passed through a parameter is drawn verbatim. So the
    // panel showed 開始錄製 and 倒數, which are literals in this file, beside Screen and Window,
    // which are not — and it read as a half-finished translation rather than a type mistake.
    let title: LocalizedStringKey
    /// A name that came from the machine rather than from this file — a connected device's own
    /// name. **It must not be looked up in the string table**, for the exact reason `title` must
    /// be: SwiftUI translates a `LocalizedStringKey`, and translating "iPhone 15 Pro" would
    /// either miss (drawing it verbatim anyway) or, on the day somebody adds a key that happens
    /// to match a device name, silently rename the device. Two parameters because they are two
    /// different kinds of string, not one parameter with a flag.
    var verbatimTitle: String? = nil
    let detail: LocalizedStringKey
    /// The chosen card — what Record and Screenshot will capture.
    let isSelected: Bool
    /// True while the picker for this card is up, so the card reads as the thing that is
    /// happening rather than staying inert behind a picker a person may not connect to it.
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                (verbatimTitle.map(Text.init(verbatim:)) ?? Text(title))
                    .font(.system(size: 13, weight: .semibold))
                // **Two lines, not one.** "A whole display" was cut to "A whole d…" in a third of
                // the panel, and every language longer than English cut all three.
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .padding(Space.regular)
            .background { card }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The system's own fill, with corners concentric to the popover's; the chosen card wears the
    /// ink accent's edge. Busy — its picker is up — is the same edge, not a new colour.
    @ViewBuilder private var card: some View {
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(Glass.controlRadius)),
                                        isUniform: true)
        if isSelected || isBusy {
            shape.fill(Theme.accent.opacity(0.10))
                .overlay(shape.stroke(Theme.accent, lineWidth: 1.5))
        } else {
            shape.fill(isHovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary))
        }
    }
}
