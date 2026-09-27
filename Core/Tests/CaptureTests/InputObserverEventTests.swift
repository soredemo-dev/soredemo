import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Capture

/// **Keys, clicks, secure input and a switched-off tap, driven through `handle(type:event:)`** —
/// the tap callback's own body — with synthetic `CGEvent`s, so no Input Monitoring grant is
/// needed. `ObserverTests` drives pointer motion the same way; nothing drove these before.
///
/// **Secure input is injected, never read.** The real reader answers "on" whenever the screen is
/// locked, and a test that asked it would pass or fail on whether somebody's Mac had locked
/// itself — `aRefreshedShapeStillReachesTheSamples` records exactly that happening.
///
/// The viewport sits at a non-zero origin and the click is off-centre, so neither the
/// translation nor the Y-flip can be skipped and still pass.

private let epoch = BootEpoch(id: UUID(uuidString: "0B7E3F2A-5C19-4D6E-8A21-9F4C7D3B6E10")!)

private func viewport() -> CaptureViewport {
    CaptureViewport(geometry: DisplayGeometry(displayUUID: UUID(uuidString: "3C5E7A91-2B4D-4F68-9E1A-7D2C5B8F4A63")!,
                                              pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
                    globalOriginX: 200, globalOriginY: 100,
                    widthInPoints: 1000, heightInPoints: 500)
}

/// Collects what an observer emits. Delivery for keys, buttons and intervals is synchronous.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [InputObserver.Observation] = []
    func record(_ observation: InputObserver.Observation) { lock.withLock { seen.append(observation) } }
    var all: [InputObserver.Observation] { lock.withLock { seen } }
}

/// A switch a test flips to say whether secure input is on.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private func observer(secureInput: Switch = Switch(), tapIsEnabled: (@Sendable () -> Bool)? = nil)
-> (InputObserver, Sink) {
    let observer = InputObserver(viewport: viewport(), epoch: epoch,
                                 secureInputIsEnabled: { secureInput.isOn },
                                 tapIsEnabledOverride: tapIsEnabled)
    let sink = Sink()
    observer.setObservationSink { sink.record($0) }
    return (observer, sink)
}

private func key(_ code: Int, flags: CGEventFlags = []) throws -> CGEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
    event.flags = flags
    return event
}

private func click(_ type: CGEventType, x: Double, y: Double) throws -> CGEvent {
    try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
}

@Suite struct InputObserverEventTests {
    /// An approved shortcut is recorded by its identifier; plain typing is refused and never
    /// reaches the log, and every keyDown is accounted for one way or the other.
    @Test func aShortcutIsRecordedAndTypingIsNot() throws {
        let (observer, sink) = observer()
        observer.handle(type: .keyDown, event: try key(kVK_ANSI_C, flags: .maskCommand))
        observer.handle(type: .keyDown, event: try key(kVK_ANSI_A))
        observer.handle(type: .keyDown, event: try key(kVK_ANSI_S))
        let keys = sink.all.compactMap { if case .key(let sample) = $0 { sample.shortcut } else { nil } }
        #expect(keys == ["cmd+c"])
        let diagnostics = observer.diagnostics
        #expect(diagnostics.keyDownsSeen == 3)
        #expect(diagnostics.keySamples == 1 && diagnostics.keyDownsRefused == 2)
        #expect(diagnostics.everyKeyDownIsAccountedFor)
        #expect(diagnostics.keyAccounting.contains("balances"))
    }

    /// Global top-left (400, 150) on a viewport at (200, 100) that is 1000 × 500 points is
    /// 0.2 across and — bottom-left out — 0.9 up.
    @Test func aClickIsAButtonEventWhereItHappened() throws {
        let (observer, sink) = observer()
        observer.handle(type: .leftMouseDown, event: try click(.leftMouseDown, x: 400, y: 150))
        observer.handle(type: .leftMouseUp, event: try click(.leftMouseUp, x: 400, y: 150))
        let buttons = sink.all.compactMap { if case .button(let event) = $0 { event } else { nil } }
        try #require(buttons.count == 2)
        #expect(buttons.map(\.phase) == [.down, .up])
        #expect(buttons.allSatisfy { $0.button == .left })
        #expect(abs(buttons[0].position.x - 0.2) < 0.001)
        #expect(abs(buttons[0].position.y - 0.9) < 0.001)
        #expect(observer.diagnostics.buttonEvents == 2)
    }

    /// A click on no display is not recorded at a clamped edge — it is not recorded.
    @Test func aClickOffEveryDisplayIsNotRecorded() throws {
        let (observer, sink) = observer()
        observer.handle(type: .leftMouseDown, event: try click(.leftMouseDown, x: 50_000, y: 50_000))
        #expect(sink.all.isEmpty)
    }

    /// While secure input is on nothing is emitted — not a redacted sample, nothing — and the
    /// span is recorded as an interval when it ends.
    @Test func secureInputSuppressesEverythingAndIsRecordedAsAnInterval() throws {
        let secure = Switch()
        let (observer, sink) = observer(secureInput: secure)
        secure.isOn = true
        observer.handle(type: .keyDown, event: try key(kVK_ANSI_C, flags: .maskCommand))
        observer.handle(type: .leftMouseDown, event: try click(.leftMouseDown, x: 400, y: 150))
        #expect(sink.all.isEmpty)
        #expect(observer.diagnostics.eventsSuppressedBySecureInput == 2)
        secure.isOn = false
        observer.handle(type: .leftMouseDown, event: try click(.leftMouseDown, x: 400, y: 150))
        let intervals = sink.all.compactMap { if case .secureInput(let interval) = $0 { interval } else { nil } }
        #expect(intervals.map(\.endedBy) == [.secureInputDisabled])
        #expect(observer.diagnostics.secureInputIntervals == 1)
        #expect(!observer.diagnostics.secureInputAccounting.contains("NOTHING WAS LOOKING"))
    }

    /// A summary of zero checks says so, rather than reading like a clean result.
    @Test func anAccountingWithNothingBehindItSaysSo() {
        let (observer, _) = observer()
        #expect(observer.diagnostics.secureInputAccounting.contains("NOTHING WAS LOOKING"))
        #expect(observer.diagnostics.tapAccounting.contains("NOTHING WAS LOOKING"))
    }

    /// The system saying it switched the tap off is counted as a blind window, even before any
    /// event gave it a lower bound.
    @Test func aTapSwitchedOffBySystemIsCountedAsBlind() throws {
        let (observer, _) = observer()
        let event = try key(kVK_ANSI_A)
        observer.handle(type: .tapDisabledByTimeout, event: event)
        #expect(observer.diagnostics.tapDisabledIntervals == 1)
    }

    /// A poll that finds the tap off closes a blind window starting at the last event seen, and
    /// says it found it by polling — with no reason, because nothing told it one.
    @Test func aPollThatFindsTheTapOffReportsTheWindowSinceTheLastEvent() throws {
        let (observer, sink) = observer(tapIsEnabled: { false })
        observer.handle(type: .leftMouseDown, event: try click(.leftMouseDown, x: 400, y: 150))
        observer.pollTapEnabled()
        let windows = sink.all.compactMap { if case .tapDisabled(let window) = $0 { window } else { nil } }
        try #require(windows.count == 1)
        #expect(windows[0].disabledBy == nil)
        #expect(windows[0].detectedBy == .enabledPoll)
        #expect(observer.diagnostics.tapDisabledIntervalsFoundByPolling == 1)
        #expect(observer.diagnostics.tapEnabledPolls == 1)
        #expect(!observer.diagnostics.tapAccounting.contains("NOTHING WAS LOOKING"))
    }

    @Test func aPollThatFindsTheTapOnReportsNothing() {
        let (observer, sink) = observer(tapIsEnabled: { true })
        observer.pollTapEnabled()
        #expect(sink.all.isEmpty)
        #expect(observer.diagnostics.tapEnabledPolls == 1)
        #expect(observer.diagnostics.tapDisabledIntervals == 0)
    }

    /// The mask's types map to what they are; a type the mask never asks for maps to nothing.
    @Test func everyEventTypeInTheMaskHasACategory() {
        for type in InputObserver.eventTypes {
            #expect(InputObserver.category(of: type) != nil, "\(type.rawValue) has no category")
        }
        #expect(InputObserver.category(of: .scrollWheel) == nil)
    }
}
