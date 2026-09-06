//
//  PasteSimulator.swift
//  ClipStack
//
//  Synthesizes ⌘V into whatever app is frontmost. Requires the same
//  Accessibility permission as the ⌘C event tap — posting keyboard events into
//  another process is exactly what that permission gates.
//

import AppKit
import Carbon.HIToolbox

enum PasteSimulator {

    /// Stamped into every event we post, and checked by StackModeController's
    /// event tap so ClipStack never treats its own synthetic keystrokes as user
    /// input. (Without this, a synthetic ⌘C-like event could feed the stack in a
    /// loop.)
    nonisolated static let syntheticEventMarker: Int64 = 0x43_4C_49_50 // 'CLIP'

    /// Posts ⌘V to the frontmost app.
    ///
    /// - Parameter targetApp: when given, wait for this app to actually be
    ///   frontmost before pasting. The recall panel needs this: it has to give
    ///   focus back to the app the user came from, and activation is asynchronous
    ///   — pasting too early sends ⌘V to whatever is still in front.
    /// - Returns: `false` if we are not trusted for Accessibility, or the event
    ///   could not be created — the caller then leaves the text on the clipboard
    ///   and tells the user to paste manually.
    @discardableResult
    @MainActor
    static func pasteIntoFrontmostApp(afterActivating targetApp: NSRunningApplication? = nil) async -> Bool {
        guard AXIsProcessTrusted() else { return false }

        if let targetApp {
            await waitUntilFrontmost(targetApp)
        }

        // The user very likely still has ⌥ and ⌘ held down from the ⌥⌘V hotkey.
        // Physical modifier state is merged into synthetic events by the window
        // server, so posting immediately can deliver ⌥⌘V to the target app
        // instead of a plain ⌘V. Wait briefly for the modifiers to come up.
        await waitForModifiersToClear()

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Suppress local keyboard/mouse events for 0s so our post is not delayed.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }

        for event in [keyDown, keyUp] {
            // Force exactly ⌘ — no leftovers from whatever is physically held.
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        }

        // .cghidEventTap posts at the lowest level, so the event travels the same
        // path a real keypress would and is seen by apps that ignore
        // higher-level posts.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Waits for `app` to become frontmost after we asked it to activate, so the
    /// synthetic ⌘V lands in the right place. Capped, because activation can be
    /// refused (the app quit, or a modal is up elsewhere).
    private static func waitUntilFrontmost(
        _ app: NSRunningApplication,
        timeout: Duration = .milliseconds(800)
    ) async {
        // Nothing to wait for if we are pasting into ourselves.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                // Let the app finish becoming key before typing into it.
                try? await Task.sleep(for: .milliseconds(40))
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Polls the *current* physical modifier state (not an event stream) until
    /// the user lets go of the hotkey, capped so a stuck key cannot hang us.
    private static func waitForModifiersToClear(
        timeout: Duration = .milliseconds(600)
    ) async {
        let watched: NSEvent.ModifierFlags = [.option, .command, .control, .shift]
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            let held = NSEvent.modifierFlags.intersection(watched)
            if held.isEmpty {
                // Small settle so the target app processes the modifier key-ups
                // before our ⌘V arrives.
                try? await Task.sleep(for: .milliseconds(30))
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
