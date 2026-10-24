import Carbon.HIToolbox
import Testing
@testable import Soredemo

/// The start-and-stop key is stated twice — once to the system, once to a person — and the two
/// must name the same keys.
@Test @MainActor func theRecordingKeyIsSpelledAsItIsRegistered() {
    #expect(GlobalHotkey.toggleRecordingKeyCode == UInt32(kVK_ANSI_R))
    #expect(GlobalHotkey.toggleRecordingModifiers == UInt32(cmdKey | shiftKey),
            "shift and command, and nothing else")
    // The system's order is ⌃⌥⇧⌘, so shift comes before command.
    #expect(GlobalHotkey.toggleRecordingSpelling == "\u{21E7}\u{2318}R")
}
