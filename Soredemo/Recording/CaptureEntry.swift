import Capture

/// What a person points the next capture at, from the panel's three cards. Remembered as a
/// preference (`RecordingPreferences.captureTarget`).
enum CaptureTarget: String, CaseIterable, Sendable {
    case screen, window, area
}

/// Which door a capture goes through: the display picker, pointing at a window, dragging an area,
/// or a connected device.
enum CaptureEntry: Equatable {
    case displayPicker
    case pointAtWindow
    case dragArea
    case device(MobileScreen.Source)

    /// The door for a press of Record or Screenshot. A chosen device outranks the remembered card
    /// — it was chosen more recently, and it disappears when unplugged — and `nil` is a picture of
    /// a device, which has no path: a phone is recorded through its own stack.
    static func `for`(target: CaptureTarget, device: MobileScreen.Source?,
                      purpose: RecordingCoordinator.CapturePurpose) -> CaptureEntry? {
        if let device { return purpose == .take ? .device(device) : nil }
        switch target {
        case .screen: return .displayPicker
        case .window: return .pointAtWindow
        case .area: return .dragArea
        }
    }
}

extension CaptureEntry {
    /// Whether choosing `target` abandons a start that is still picking: a picker is up for some
    /// other target. Choosing the card that is picking leaves it be. Without this the panel showed
    /// two chosen cards at once — the new choice, and the old one whose picker was still up.
    static func cancelsPending(_ pending: CaptureSourcePicker.Modes?, choosing target: CaptureTarget) -> Bool {
        guard let pending else { return false }
        let picking: CaptureTarget? = switch pending {
        case .displaysOnly: .screen
        case .windowsOnly: .window
        case .region: .area
        case .displaysAndWindows: nil
        }
        return picking != target
    }
}
