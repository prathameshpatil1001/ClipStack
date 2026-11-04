//
//  AppDelegate.swift
//  ClipStack
//
//  Composition root: builds the object graph, wires the hotkeys to their
//  actions, and owns every window the app can show.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment!
    private var statusItemController: StatusItemController!
    private var recallPanelController: SpotlightSearchPanelController!
    private let hud = HUDController()

    // Created lazily and reused; closing a window keeps the controller alive.
    private var savedTextsWindow: SwiftUIWindowController?
    private var settingsWindow: SwiftUIWindowController?
    private var websitesWindow: SwiftUIWindowController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement in Info.plist: no Dock icon, no
        // app switcher entry, but the app can still activate to take keyboard
        // focus for the recall panel.
        NSApp.setActivationPolicy(.accessory)

        environment = AppEnvironment()
        recallPanelController = SpotlightSearchPanelController(
            store: environment.snippets,
            websites: environment.websites,
            clipboard: environment.clipboard,
            preferences: environment.preferences
        )

        wireHUD()
        buildStatusItem()
        wireHotKeys()
        wirePermissionRecovery()

        environment.applyHotKeyBindings()
        environment.startCloudSyncIfEnabled()
        restoreStackModeIfPossible()
        presentFirstLaunchExplainerIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Removes the event tap and unregisters the Carbon hotkeys.
        environment?.stack.setEnabled(false)
    }

    /// Nothing to reopen — the menu bar icon is the app's only permanent UI.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Wiring

    private func wireHUD() {
        hud.anchorProvider = { [weak self] in self?.statusItemController?.statusItemFrame() }

        environment.stack.onHUD = { [weak self] message, symbol in
            self?.hud.show(message, symbol: symbol)
        }
        recallPanelController.onHUD = { [weak self] message, symbol in
            // "Copied ✓" is read at a glance; an explanation needs time.
            self?.hud.show(message, symbol: symbol, duration: message.count > 30 ? 5 : 1.4)
        }
    }

    private func buildStatusItem() {
        let actions = StatusItemController.Actions(
            openSavedTexts: { [weak self] in self?.showSavedTexts() },
            openSettings: { [weak self] in self?.showSettings() },
            openRecallPanel: { [weak self] in self?.showRecallPanel() },
            openWebsites: { [weak self] in self?.showWebsites() },
            openWebsite: { [weak self] website in
                self?.statusItemController?.closePopover()
                self?.openWebsite(website)
            },
            quit: { NSApp.terminate(nil) }
        )
        statusItemController = StatusItemController(environment: environment, actions: actions)
    }

    private func wireHotKeys() {
        let hotKeys = environment.hotKeys

        hotKeys.setHandler(for: .pasteStack) { [weak self] in
            self?.environment.stack.pasteStack()
        }

        hotKeys.setHandler(for: .resetStack) { [weak self] in
            self?.environment.stack.resetStack()
        }

        hotKeys.setHandler(for: .recall) { [weak self] in
            self?.recallPanelController.toggle()
        }

        hotKeys.setHandler(for: .toggleStackMode) { [weak self] in
            self?.environment.stack.toggle()
        }
    }

    /// The user can grant a permission while the app is already running. When
    /// that happens, arm ⌘C capture immediately instead of making them restart
    /// or re-toggle Stack Mode.
    private func wirePermissionRecovery() {
        environment.permissions.onPermissionGranted = { [weak self] in
            guard let self else { return }
            self.environment.stack.rearmIfNeeded()
            self.statusItemController?.refreshIcon()
        }
    }

    /// Stack Mode is remembered across launches, but can only be re-armed if the
    /// permission is still in place.
    private func restoreStackModeIfPossible() {
        guard environment.preferences.stackModeEnabled else { return }
        guard environment.permissions.refresh() else {
            // Leave the preference set: the menu bar shows a permission banner,
            // and `onTrustGranted` will arm the tap as soon as it is allowed.
            return
        }
        environment.stack.rearmIfNeeded()
        statusItemController?.refreshIcon()
    }

    /// On the very first run, explain why a clipboard utility wants keyboard
    /// access before macOS shows its own terse prompt. Slightly delayed so the
    /// menu bar icon is on screen first and the alert has visible context.
    private func presentFirstLaunchExplainerIfNeeded() {
        guard environment.preferences.isFirstLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.environment.permissions.presentExplainer(isFirstLaunch: true)
            self.hud.show("ClipStack is in your menu bar", symbol: "square.3.layers.3d.top.filled")
        }
    }

    // MARK: - Windows

    private func showRecallPanel() {
        statusItemController?.closePopover()
        recallPanelController.toggle()
    }

    private func showSavedTexts() {
        statusItemController?.closePopover()

        if savedTextsWindow == nil {
            let environment = self.environment!
            savedTextsWindow = SwiftUIWindowController(
                title: "Saved Texts",
                size: NSSize(width: 680, height: 480),
                minSize: NSSize(width: 560, height: 380)
            ) {
                SavedTextsView(store: environment.snippets)
                    .environmentObject(environment)
                    .environmentObject(environment.preferences)
            }
        }
        savedTextsWindow?.present()
    }

    private func showWebsites() {
        statusItemController?.closePopover()

        if websitesWindow == nil {
            let environment = self.environment!
            websitesWindow = SwiftUIWindowController(
                title: "Websites",
                size: NSSize(width: 640, height: 420),
                minSize: NSSize(width: 560, height: 360)
            ) {
                WebsitesView(store: environment.websites) { [weak self] website in
                    self?.openWebsite(website)
                }
                .environmentObject(environment)
            }
        }
        websitesWindow?.present()
    }

    /// Opens a saved website in its browser and profile, saying so if it can't.
    private func openWebsite(_ website: Website) {
        Task { @MainActor in
            do {
                if let notice = try await BrowserLauncher.open(website) {
                    hud.show(notice, symbol: "info.circle.fill", duration: 5)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                hud.show(message, symbol: "exclamationmark.triangle.fill", duration: 4)
            }
        }
    }

    /// Internal rather than private: the app menu's Settings… item calls it.
    func showSettings() {
        statusItemController?.closePopover()

        if settingsWindow == nil {
            let environment = self.environment!
            settingsWindow = SwiftUIWindowController(
                title: "ClipStack Settings",
                size: NSSize(width: 520, height: 400)
            ) {
                SettingsView(preferences: environment.preferences)
                    .environmentObject(environment)
            }
        }
        settingsWindow?.present()
    }
}

