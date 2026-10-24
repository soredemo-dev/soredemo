import Capture
import SwiftUI

/// What to capture, and the cards that start it.
struct MenuBarTargets: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        purposePicker
        targets
    }

    /// A take or a picture, chosen before the target. **Segmented, unlike the targets below**:
    /// this IS two settings of one thing, and choosing one starts nothing.
    @ViewBuilder private var purposePicker: some View {
        Picker("Capture", selection: Binding(get: { coordinator.capturePurpose },
                                             set: { coordinator.capturePurpose = $0 })) {
            Text("Record").tag(RecordingCoordinator.CapturePurpose.take)
            Text("Screenshot").tag(RecordingCoordinator.CapturePurpose.picture)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// The two ways to start. **Cards rather than a segmented control**, because they are not two
    /// settings of one thing — each opens the system picker narrowed to its own kind of target,
    /// and pressing one is the act of starting.
    @ViewBuilder private var targets: some View {
        HStack(spacing: Space.snug) {
            TargetCard(icon: "display", title: "Screen", detail: "A whole display",
                       isBusy: coordinator.pendingMode == .displaysOnly) {
                coordinator.beginRecording(.displaysOnly)
            }
            TargetCard(icon: "macwindow", title: "Window", detail: "Point at it",
                       isBusy: coordinator.pendingMode == .windowsOnly) {
                coordinator.beginWindowRecordingByPointing()
            }
            // **The third thing a recorder has to be able to point at.** A display capture of a
            // demo living in a small panel spends most of its pixels on desktop, and a window
            // capture cannot do it at all when the subject is part of a window rather than all
            // of it.
            TargetCard(icon: "rectangle.dashed", title: "Area", detail: "Drag it out",
                       isBusy: coordinator.pendingMode == .region) {
                coordinator.beginRegionRecording()
            }
        }
        // **The fourth card exists only while a device does.** A card that is always there and
        // usually disabled is a permanent reminder of a thing somebody is not doing; this row
        // appears when a phone is plugged in and disappears when it is unplugged, which is the
        // same moment they stop caring about it. It is worth shipping
        // phone recording; none of the seven open-source projects beside this repo does.
        // A phone is recorded through a different stack with no screenshot path; its card is a
        // take's only.
        if !coordinator.availableMobileScreens.isEmpty && coordinator.capturePurpose == .take {
            VStack(alignment: .leading, spacing: Space.snug) {
                ForEach(coordinator.availableMobileScreens) { device in
                    TargetCard(icon: device.symbolName, title: "",
                               verbatimTitle: device.displayName,
                               detail: "Its screen", isBusy: false) {
                        coordinator.beginMobileRecording(device)
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

/// One way to start: a screen, a window, an area, or a connected device.
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
    /// True while the system picker this card opened is up, so the card reads as the thing that
    /// is happening rather than staying inert behind a picker a person may not connect to it.
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isBusy ? Signal.record : .primary)
                    .frame(height: 20)
                (verbatimTitle.map(Text.init(verbatim:)) ?? Text(title))
                    .font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.regular)
            .background {
                RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .fill(.quaternary.opacity(isHovering || isBusy ? 0.9 : 0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .strokeBorder(Signal.record.opacity(isBusy ? 0.9 : 0), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
