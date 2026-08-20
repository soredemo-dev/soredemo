#!/usr/bin/env swift
// Measures the cursor-position error a recording shows, so a report can carry a NUMBER
// instead of "still has some error".
//
// The chain from a mouse event to a drawn pixel has five links, and each is checked here
// against the one before it. A discrepancy names the link rather than the symptom:
//
//   1. CGEventGetLocation          global points, top-left origin
//   2. SCWindow.frame              the rect the capture is cropped to
//   3. sourceRect                  that rect rebased onto its display
//   4. CaptureViewport.normalise   global point -> 0…1, bottom-left
//   5. the drawn pixel             normalised -> output pixels
//
// Run it, put the pointer somewhere identifiable inside the window you record — a corner,
// the centre of a button — and read the reported normalised position. If step 4 says
// (0.5, 0.5) while the pointer is visibly at the window's centre, the geometry is right and
// the error is downstream in rendering. If it does not, the offset it prints is the bug.
//
//     xcrun swift -target arm64-apple-macos26.0 scripts/measure-cursor-offset.swift
import AppKit
import CoreGraphics
import ScreenCaptureKit

// **Not `DispatchSemaphore` plus `Task { @MainActor }`.** That deadlocks: waiting on the
// semaphore blocks the main thread, and the MainActor task needs the main thread to run.
// The first draft of this file hung for exactly that reason. `RunLoop` keeps the main
// thread serving the actor while the work proceeds.
var finished = false

Task { @MainActor in
    defer { finished = true }
    let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                      onScreenWindowsOnly: true)
    let mouse = CGEvent(source: nil)?.location ?? .zero
    print("pointer (CGEvent, global top-left points): (\(mouse.x), \(mouse.y))\n")

    // The window under the pointer — the one a person would have picked.
    guard let window = content.windows.first(where: {
        $0.frame.contains(mouse) && $0.frame.width > 100 && $0.title?.isEmpty == false
    }) else {
        print("no titled window under the pointer — move it over the window you record")
        return
    }
    let frame = window.frame
    print("window: \(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "")")
    print("  frame (global points): \(frame)")

    guard let display = content.displays.first(where: {
        CGDisplayBounds($0.displayID).contains(CGPoint(x: frame.midX, y: frame.midY))
    }) else {
        print("the window's centre is on no display"); return
    }
    let bounds = CGDisplayBounds(display.displayID)
    print("  on display \(display.displayID), bounds \(bounds)")

    let sourceRect = CGRect(x: frame.origin.x - bounds.origin.x,
                            y: frame.origin.y - bounds.origin.y,
                            width: frame.width, height: frame.height)
    print("  sourceRect (display-local points): \(sourceRect)\n")

    // Step 4, the arithmetic `CaptureViewport.normalise` performs.
    let localX = mouse.x - frame.origin.x
    let localY = mouse.y - frame.origin.y
    let normalisedX = localX / frame.width
    let normalisedY = 1 - (localY / frame.height)
    print("pointer inside the window:")
    print("  local points        : (\(localX), \(localY))")
    print("  NORMALISED (0…1)    : (\(normalisedX), \(normalisedY))")
    print("    - x = 0 is the window's left edge, 1 its right")
    print("    - y = 0 is the window's BOTTOM edge, 1 its top\n")

    // The hotspot, which is where inside the drawn art the pointer actually is.
    if let cursor = NSCursor.currentSystem ?? NSCursor.current as NSCursor? {
        let size = cursor.image.size
        if size.width > 0 {
            let h = cursor.hotSpot
            print("cursor: image \(size), hotspot \(h) = "
                  + "(\(h.x / size.width), \(h.y / size.height)) of the image")
            print("  art drawn with its own origin at the recorded position is correct")
            print("  ONLY if that origin is the hotspot.")
        } else {
            print("cursor: no image — classification is impossible, hotspot unknown")
        }
    }
}

while !finished && RunLoop.current.run(mode: .default, before: .distantFuture) {}
