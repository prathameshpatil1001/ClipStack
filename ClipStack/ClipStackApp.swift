//
//  ClipStackApp.swift
//  ClipStack
//

import SwiftUI

@main
struct ClipStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ClipStack lives in the menu bar: it has no document and no main
        // window, and LSUIElement keeps it out of the Dock. A SwiftUI `App` must
        // still declare at least one Scene, and `Settings` is the only one that
        // never puts a window on screen by itself. Every real window (Saved
        // Texts, Settings, the recall panel, the HUD) is created on demand by
        // AppDelegate so it can be positioned and focused the way a menu bar
        // utility needs.
        Settings { EmptyView() }
            .commands {
                // While a ClipStack window is open the app shows a regular menu
                // bar (see WindowActivationPolicy). Its "Settings…" item would
                // otherwise open the empty placeholder scene above.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings\u{2026}") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
