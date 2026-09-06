//
//  SystemPermissions.swift
//  ClipStack
//
//  ── The two permissions, and why it is two ──────────────────────────────────
//  This is the part of a menu bar clipboard app that most often "just doesn't
//  work", because macOS splits what looks like one capability across two
//  separate privacy controls:
//
//    • Input Monitoring  (Privacy & Security ▸ Input Monitoring)
//      Required to *observe* keystrokes with a listen-only CGEventTap — that is,
//      to notice ⌘C. Since macOS 10.15, a tap created with
//      `CGEventTapOptions.listenOnly` needs this, NOT Accessibility. It is
//      checked with `CGPreflightListenEventAccess()`.
//
//    • Accessibility     (Privacy & Security ▸ Accessibility)
//      Required to *post* keystrokes into another app — auto-pasting ⌘V — and to
//      observe keys through `NSEvent.addGlobalMonitorForEvents`. Checked with
//      `AXIsProcessTrusted()`.
//
//  Asking only for Accessibility (the obvious thing to do, and what most
//  tutorials show) produces the worst possible failure: the tap is created
//  successfully and then silently receives no key events at all.
//
//  ClipStack therefore tracks both, and `StackModeController` can capture ⌘C
//  through *either* — the event tap when Input Monitoring is granted, or a
//  global NSEvent monitor when only Accessibility is. Granting Accessibility
//  alone is enough for the whole app to work.
//
//  ── One more thing that catches everyone ────────────────────────────────────
//  Both permissions are keyed to the binary's code signature *and path*. A
//  rebuild into a fresh DerivedData folder, or moving the app to /Applications,
//  reads as a different app: the old entry keeps its switch on while the copy
//  actually running has nothing. `refresh()` is polled so the app notices the
//  moment the user fixes it, without needing a restart.
//

import ApplicationServices
import AppKit
import CoreGraphics
import Combine

@MainActor
final class SystemPermissions: ObservableObject {

    /// Can post ⌘V into other apps (auto-paste), and observe keys via NSEvent.
    @Published private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

    /// Can observe keys with a listen-only CGEventTap.
    @Published private(set) var isInputMonitoringGranted: Bool = CGPreflightListenEventAccess()

    /// True once we have shown our own explainer, so we do not nag repeatedly.
    @Published private(set) var hasPromptedThisLaunch = false

    private var pollTimer: Timer?

    /// Fired when either permission flips from denied to granted, so ⌘C capture
    /// can be armed without the user restarting the app.
    var onPermissionGranted: (() -> Void)?

    init() {
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - State

    /// ⌘C can be observed one way or the other.
    var canObserveCopyKeystroke: Bool { isInputMonitoringGranted || isAccessibilityTrusted }

    /// Auto-paste needs to synthesize a keystroke into another process.
    var canAutoPaste: Bool { isAccessibilityTrusted }

    /// Nothing works: used to decide whether to show the banner in the menu.
    var needsAnyPermission: Bool { !canObserveCopyKeystroke || !canAutoPaste }

    /// Re-reads the real system state. Cheap — both calls are cached lookups.
    @discardableResult
    func refresh() -> Bool {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()

        let gainedSomething = (accessibility && !isAccessibilityTrusted)
            || (inputMonitoring && !isInputMonitoringGranted)

        isAccessibilityTrusted = accessibility
        isInputMonitoringGranted = inputMonitoring

        if gainedSomething { onPermissionGranted?() }
        return canObserveCopyKeystroke
    }

    // MARK: - Requesting

    /// Triggers the system's Accessibility prompt. It is only shown the *first*
    /// time a given app asks; afterwards this silently returns the cached answer,
    /// which is why the explainer also opens System Settings directly.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        isAccessibilityTrusted = trusted
        hasPromptedThisLaunch = true
        return trusted
    }

    /// Triggers the system's Input Monitoring prompt. Same one-shot behaviour.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        let granted = CGRequestListenEventAccess()
        isInputMonitoringGranted = granted
        hasPromptedThisLaunch = true
        return granted
    }

    /// ClipStack's own explanation, shown before macOS's terse prompts so the
    /// user understands why a clipboard utility wants keyboard access.
    func presentExplainer(isFirstLaunch: Bool) {
        refresh()
        guard needsAnyPermission else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "ClipStack needs permission to see ⌘C"
        alert.informativeText = """
        Stack Mode works by noticing when you press ⌘C and reading what landed on \
        the clipboard. macOS keeps that behind a privacy setting.

        Grant Accessibility and everything works — capturing ⌘C and pasting the \
        stack for you. (Input Monitoring also enables ⌘C capture, but not \
        auto-paste, so Accessibility is the one to turn on.)

        ClipStack never records what you type. It looks only for the ⌘C keystroke \
        itself, and only while Stack Mode is switched on.

        Your saved texts and the ⌥Space search panel work without any of this.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")

        // As an LSUIElement app we are not frontmost; without this the alert can
        // open behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            hasPromptedThisLaunch = true
            return
        }

        // Ask macOS to prompt. This matters for more than convenience: the
        // prompt registers ClipStack with the privacy system under the identity
        // of the binary actually running, which is far more reliable than hoping
        // the user picks the right row out of a list — especially when several
        // builds of the app have existed at different paths.
        //
        // Both are requested because either one enables ⌘C capture, and macOS
        // shows each prompt at most once per record, so this is not repeatedly
        // noisy. It is also a silent no-op when a record already exists, which
        // is exactly the "switch is on but nothing works" case — hence the
        // reset guidance in Settings.
        requestAccessibility()
        requestInputMonitoring()

        if !(isFirstLaunch && !hasPromptedThisLaunch) {
            openAccessibilitySettings()
        }
    }

    /// Shown when ⌘C capture could not be started at all.
    func presentCaptureUnavailableGuidance() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipStack can't watch for ⌘C"
        alert.informativeText = """
        macOS refused both ways of observing the copy keystroke.

        Turn ClipStack on in System Settings ▸ Privacy & Security ▸ Accessibility. \
        If it is already listed, remove the entry with the “–” button and add this \
        copy again — a rebuilt or moved app counts as a different app and has to \
        be re-approved.

        Stack Mode has been switched off. Saved texts and ⌥Space still work.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    // MARK: - Deep links

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Polling

    /// macOS posts no notification when a privacy switch is flipped, and the
    /// answer is cached per process, so a low-frequency poll is the only reliable
    /// way to notice. Two seconds is cheap and feels immediate.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        pollTimer?.tolerance = 1.0
    }
}
