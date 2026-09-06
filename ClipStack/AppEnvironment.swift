//
//  AppEnvironment.swift
//  ClipStack
//
//  One object graph handed to every view, so nothing reaches for a singleton.
//

import Foundation
import Combine

@MainActor
final class AppEnvironment: ObservableObject {

    let preferences: Preferences
    let permissions: SystemPermissions
    let clipboard: ClipboardManager
    let stack: StackModeController
    let snippets: SnippetStore
    let hotKeys: HotKeyManager
    let cloudSync: CloudSyncCoordinator

    /// Shortcuts macOS refused to register (usually already taken), keyed by
    /// action, so Settings can show the problem next to the offending row.
    @Published var hotKeyFailures: [HotKeyAction: String] = [:]

    private var cancellables = Set<AnyCancellable>()

    init() {
        let preferences = Preferences.shared
        let permissions = SystemPermissions()
        let clipboard = ClipboardManager.shared

        self.preferences = preferences
        self.permissions = permissions
        self.clipboard = clipboard
        let cloudSync = CloudSyncCoordinator()
        self.cloudSync = cloudSync
        self.snippets = SnippetStore(cloudSync: cloudSync)
        self.hotKeys = HotKeyManager()
        self.stack = StackModeController(
            preferences: preferences,
            clipboard: clipboard,
            permissions: permissions
        )

        // SwiftUI only observes the object a view actually declares. Views bind to
        // AppEnvironment and then read `environment.stack`, `environment.snippets`
        // and so on, so a change *inside* one of those nested observables would
        // otherwise never invalidate the view — the menu bar list would sit on a
        // stale copy of the stack until something else forced a redraw. Forward
        // every nested objectWillChange so reading through AppEnvironment is
        // always safe.
        for nested in [
            preferences.objectWillChange,
            permissions.objectWillChange,
            self.stack.objectWillChange,
            self.snippets.objectWillChange,
            cloudSync.objectWillChange,
        ] {
            nested
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// Starts iCloud sync if the user has it switched on.
    func startCloudSyncIfEnabled() {
        guard preferences.iCloudSyncEnabled else { return }
        snippets.setCloudSyncEnabled(true)
    }

    /// Registers every shortcut from preferences and records any failures.
    func applyHotKeyBindings() {
        let failures = hotKeys.applyBindings(from: preferences)
        hotKeyFailures = failures.mapValues { error in
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
