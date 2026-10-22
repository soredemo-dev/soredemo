//
//  ContentView.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AVFoundation
import CoreGraphics
import Foundation
// `Capture` since Phase 3A-4 — the session, the source, permissions and `Minting`.
import Capture
import Geometry
import Observation
import Project
import Render
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Timeline

/// A window with a rendered frame in it. Shows `StageWindow` once a recording exists; until then a
/// placeholder plus the "Open Recording…"/"Stop Recording" command wired in `SoredemoApp.body`.
/// Not document-bound: this is a scratch `WindowGroup`, so recording goes to a
/// `TemporaryFileMediaSink` rather than into a `.soredemo` package.
struct ContentView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Group {
            if let mediaURL = coordinator.mediaURL {
                StageWindow(initialCameraStyle: coordinator.cameraStyle,
                            cameraStartOffsetNanos: coordinator.cameraStartOffsetNanos,
                            mediaURL: mediaURL, pendingEdit: coordinator.takePendingEdit(),
                            cameraURL: coordinator.cameraURL,
                            scrubAudioIsOn: coordinator.preferences.scrubAudio)
                    // `StageWindow` carries no `.id(mediaURL)`, so `.onDisappear` fires only
                    // because `beginOpenRecording()` sets `mediaURL = nil` first, swapping this
                    // `Group`'s branch out and giving old and new `StageWindow` distinct view
                    // identities. Without it the scratch directory leaks; the launch sweep bounds it.
                    .onDisappear { coordinator.previewWasDismissed() }
            } else {
                // **Reachable only if the window is opened with nothing loaded**, which the
                // scene's `.defaultLaunchBehavior(.suppressed)` and the one call site of
                // `openWindow` are between them meant to prevent. Kept as a plain statement of
                // fact rather than a welcome screen: the welcome screen WAS this window, and it
                // was the thing covering the screen a person came to record.
                ContentUnavailableView("Nothing open",
                                       systemImage: "record.circle",
                                       description: Text("Start a recording from the menu bar."))
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        // **Dropping a video onto the window opens it**, which is the first thing anybody tries
        // and which did nothing at all until now — `openVideo(at:)` existed and nothing could
        // reach it.
        //
        // On the whole window rather than on the stage: an editor with nothing in it is exactly
        // where somebody drops a file, and a target that only existed once a recording was open
        // would be missing at the only moment it is wanted.
        //
        // **`onDrop` with a file URL, not `dropDestination(for: URL.self)`.** The typed version
        // is shorter and hands back a URL that may be SwiftUI's own copy of a Finder file
        // PROMISE — a temporary the system is still writing. A ten-second recording arrived as
        // roughly one second through that path while the same file opened through
        // `openVideo(at:)` was whole, measured every step from the timeline model to the
        // composed asset. Resolving the item provider's `public.file-url` gives the file where
        // it actually lives.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            // **One file.** Several videos are several recordings and this window holds one;
            // taking the first is better than opening whichever finished loading last.
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in coordinator.openVideo(at: url) }
            }
            return true
        }
        // **The window's own configuration belongs at the window's root, not on `StageWindow`.**
        //
        // It was attached inside `StageWindow`, which this view only builds once a recording
        // exists — so an editor opened with nothing in it never ran it at all, and one opened
        // with a recording ran it whenever that branch appeared rather than when the window
        // did. Measured 2026-08-27: a launch straight to an empty editor logged nothing from
        // the configurator, because the view holding it was never in the hierarchy.
        //
        // What it sets — miniaturisable, resizable, full-screen capable, follows the active
        // Space, sized generously on first open — are all properties of the WINDOW, true
        // whether or not there is a recording in it.
        .background(WindowConfigurator())
        // Asks before the window closes, and lets the recording go once it has — see
        // `EditorCloseGuard`.
        .background(EditorCloseHook(shouldClose: { UnsavedWorkGuard.shared.mayCloseEditor() },
                                    didClose: { coordinator.editorClosed() }))
    }
}

#Preview {
    ContentView(coordinator: RecordingCoordinator())
}
