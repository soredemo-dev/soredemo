//
//  SoredemoApp.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AppKit
import SwiftUI

@main
struct SoredemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // `ProjectDocument` is an `NSDocument`, not a SwiftUI
            // `FileDocument`, so `DocumentGroup` cannot host it (design doc F3,
            // F4). Opening therefore goes through `NSDocumentController`, which
            // AppKit stands up on first use from `CFBundleDocumentTypes` in
            // `Soredemo-Info.plist` — the same declaration that registers the
            // `.soredemo` package type with LaunchServices.
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
            }
        }
    }
}
