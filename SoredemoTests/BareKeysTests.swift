import Testing
@testable import Soredemo

// Which unmodified keys the editor takes, and which it must let through.
//
// **Measured before it was written.** Driven with synthesised events against a SwiftUI
// `TextField` holding the caret, every bare key `TimelineEditor` bound — ←, →, Delete, s, i, o
// — was taken by its `.keyboardShortcut` and never reached the field. The comment above those
// bindings said a `Button`'s shortcut "respects the responder chain"; it does not. The first
// run of that probe reported the letters as reaching the field and was void: the app had not
// finished activating and those keys went to whatever was frontmost. A positive control — an
// unbound key that must change the field's text — is what separated the two readings.
//
// **Key CODES, not characters, and that was a gate's decision rather than a preference.** The
// first version matched `charactersIgnoringModifiers` and `noAppSourceReadsKeystrokeText`
// refused it: nothing in this app may learn what was typed, including in order to discard it.
// What that costs is in `BareKeys.Code` — a position is not a letter on a layout that is not
// ANSI — and it is the same price `InputObserver.approvedShortcuts` already pays.

@Suite struct BareKeysTests {

    private func typing(_ code: Int, _ modifiers: BareKeys.Modifiers = .none)
        -> BareKeys.Action? {
        BareKeys.action(keyCode: code, modifiers: modifiers, isTyping: true)
    }

    private func editing(_ code: Int, _ modifiers: BareKeys.Modifiers = .none)
        -> BareKeys.Action? {
        BareKeys.action(keyCode: code, modifiers: modifiers, isTyping: false)
    }

    // MARK: - what it takes when nothing is being typed

    @Test @MainActor func theArrowsNudgeThePlayhead() {
        #expect(editing(BareKeys.Code.leftArrow.rawValue) == .nudgeLeft)
        #expect(editing(BareKeys.Code.rightArrow.rawValue) == .nudgeRight)
    }

    /// Shift is the coarse step, matching how a modifier scales a nudge everywhere on the
    /// system.
    @Test @MainActor func shiftIsTheCoarseStep() {
        #expect(editing(BareKeys.Code.leftArrow.rawValue, .init(shift: true)) == .coarseLeft)
        #expect(editing(BareKeys.Code.rightArrow.rawValue, .init(shift: true)) == .coarseRight)
    }

    @Test @MainActor func theSessionLettersAreTaken() {
        #expect(editing(BareKeys.Code.s.rawValue) == .split)
        #expect(editing(BareKeys.Code.i.rawValue) == .markIn)
        #expect(editing(BareKeys.Code.o.rawValue) == .markOut)
        #expect(editing(BareKeys.Code.backspace.rawValue) == .deleteClip)
    }

    /// **Shift belongs to the text field on the letters, and to the editor on the arrows.**
    /// ⇧← is the coarse nudge; ⇧S is a capital somebody is typing, and taking it would be the
    /// same defect one modifier along.
    @Test @MainActor func shiftIsBoundOnTheArrowsAndNowhereElse() {
        #expect(editing(BareKeys.Code.s.rawValue, .init(shift: true)) == nil)
        #expect(editing(BareKeys.Code.i.rawValue, .init(shift: true)) == nil)
        #expect(editing(BareKeys.Code.o.rawValue, .init(shift: true)) == nil)
        #expect(editing(BareKeys.Code.backspace.rawValue, .init(shift: true)) == nil)
    }

    // MARK: - what it must let through

    /// **The defect, as an assertion.** Every one of these was measured being taken from a text
    /// field that had the caret.
    @Test @MainActor func nothingIsTakenWhileSomebodyIsTyping() {
        for code in BareKeys.Code.allCases {
            #expect(typing(code.rawValue) == nil, "\(code) was taken from a text field")
            #expect(typing(code.rawValue, .init(shift: true)) == nil,
                    "shifted \(code) was taken from a text field")
        }
    }

    /// **Command and option belong to SwiftUI's own shortcuts**, which are menu-shaped and do
    /// exempt an editing field. ⌘Z must not be answered here as well, or undo would happen
    /// twice.
    @Test @MainActor func modifiedKeysAreNotThisTypesBusiness() {
        for modifiers in [BareKeys.Modifiers(command: true), .init(option: true),
                          .init(control: true), .init(command: true, shift: true)] {
            for code in BareKeys.Code.allCases {
                #expect(editing(code.rawValue, modifiers) == nil, "\(code) with \(modifiers)")
            }
        }
    }

    /// A key the editor does not bind is not the editor's, typing or not. `0` is A, `49` is
    /// space, `126` and `125` are the up and down arrows — all positions this leaves alone.
    @Test @MainActor func anUnboundKeyIsLeftAlone() {
        for code in [0, 49, 126, 125, 36, 53] {
            #expect(editing(code) == nil, "key code \(code) was claimed")
            #expect(typing(code) == nil)
        }
    }

    /// **Forward delete is `kVK_ForwardDelete`, 117, and this does not bind it.** Deleting a
    /// clip with it would be a destructive act on a key nobody aimed at the timeline.
    @Test @MainActor func forwardDeleteIsNotBackspace() {
        #expect(editing(117) == nil)
        #expect(BareKeys.Code.backspace.rawValue == 51)
    }

    /// **The positions, pinned.** These are `kVK_*` constants and a wrong one is a key that
    /// silently does nothing — which is exactly how the first version of this file failed, with
    /// backspace written as the wrong value and then declined by its own decision.
    @Test @MainActor func thePositionsAreTheCarbonOnes() {
        #expect(BareKeys.Code.leftArrow.rawValue == 123)
        #expect(BareKeys.Code.rightArrow.rawValue == 124)
        #expect(BareKeys.Code.s.rawValue == 1)
        #expect(BareKeys.Code.i.rawValue == 34)
        #expect(BareKeys.Code.o.rawValue == 31)
    }

    /// No two keys share a position, and every one maps to an action — a table where two rows
    /// collided would silently drop a command.
    @Test @MainActor func everyPositionIsDistinctAndReachable() {
        let codes = BareKeys.Code.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
        let actions = BareKeys.Code.allCases.compactMap { editing($0.rawValue) }
        #expect(actions.count == codes.count, "a bound position produced no action")
    }

    /// Every action has its own spelling — the monitor keys off these and two sharing one
    /// would silently collapse into the wrong command.
    @Test @MainActor func everyActionIsSpelledDifferently() {
        let spellings = BareKeys.Action.allCases.map(\.rawValue)
        #expect(Set(spellings).count == spellings.count)
    }
}
