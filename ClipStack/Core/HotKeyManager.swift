//
//  HotKeyManager.swift
//  ClipStack
//
//  Global shortcuts via Carbon's RegisterEventHotKey.
//
//  Why Carbon and not a CGEventTap or NSEvent monitor:
//   • RegisterEventHotKey is the OS's own hotkey registry — it is event-driven,
//     survives app switches, and does NOT require Accessibility permission.
//     ⌥⌘V / ⌥⌘X / ⌥Space therefore keep working even if the user declines the
//     Accessibility prompt (only ⌘C capture and auto-paste need that).
//   • It also refuses registrations that clash with an existing system hotkey,
//     which lets the Settings UI tell the user their choice is taken instead of
//     silently doing nothing.
//
//  The API is deprecated-looking but is still the supported, non-sandboxed way
//  to do this on macOS 13–26; AppKit has no Swift replacement.
//

import AppKit
import Carbon.HIToolbox

/// Identifies a logical shortcut, independent of what keys it is bound to.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case pasteStack
    case resetStack
    case recall
    case toggleStackMode
    case captureText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteStack:      return "Paste Stack"
        case .resetStack:      return "Reset Stack"
        case .recall:          return "Recall Saved Text"
        case .toggleStackMode: return "Toggle Stack Mode"
        case .captureText:     return "Capture Text from Screen"
        }
    }

    var explanation: String {
        switch self {
        case .pasteStack:      return "Join every stacked item and put it on the clipboard."
        case .resetStack:      return "Empty the current stack."
        case .recall:          return "Open the saved-text search panel."
        case .toggleStackMode: return "Turn Stack Mode on or off from anywhere."
        case .captureText:     return "Drag over anything on screen to read its text into the stack."
        }
    }
}

@MainActor
final class HotKeyManager {

    /// Why a registration failed, so Settings can say something useful.
    enum RegistrationError: Error, LocalizedError {
        case invalidCombo
        case alreadyInUse(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidCombo:
                return "A shortcut needs at least one modifier key (⌘, ⌥, ⌃ or ⇧)."
            case .alreadyInUse:
                return "That shortcut is already claimed by macOS or another app."
            }
        }
    }

    /// Keyed by the Carbon hotkey id we hand out.
    ///
    /// `nonisolated(unsafe)` because `deinit` is not main-actor isolated and has
    /// to unregister these Carbon refs — they are not ARC-managed and would leak
    /// a live system-wide hotkey otherwise. Every other access is on the main
    /// actor, so there is no real concurrent use to guard against.
    private nonisolated(unsafe) var registrations: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?
    private var nextHotKeyID: UInt32 = 1

    /// Four-char signature Carbon uses to namespace our hotkey ids.
    private let signature: OSType = 0x43_4C_53_4B // 'CLSK'

    init() {
        installCarbonEventHandler()
    }

    deinit {
        // Carbon refs are not ARC-managed; unregister explicitly.
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Public API

    /// Sets the closure run when `action` fires. Independent of binding, so
    /// rebinding a key never loses the behaviour.
    func setHandler(for action: HotKeyAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Binds `combo` to `action`, replacing any previous binding for it.
    /// Passing `nil` just unbinds.
    func bind(_ combo: KeyCombo?, to action: HotKeyAction) throws {
        unbind(action)
        guard let combo else { return }
        guard combo.isValid else { throw RegistrationError.invalidCombo }

        let hotKeyID = nextHotKeyID
        nextHotKeyID += 1

        let carbonID = EventHotKeyID(signature: signature, id: hotKeyID)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            carbonID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            // eventHotKeyExistsErr (-9878) is the usual cause: something else owns it.
            throw RegistrationError.alreadyInUse(status)
        }

        registrations[hotKeyID] = (ref: ref, action: action)
    }

    func unbind(_ action: HotKeyAction) {
        for (id, registration) in registrations where registration.action == action {
            UnregisterEventHotKey(registration.ref)
            registrations.removeValue(forKey: id)
        }
    }

    /// Applies every shortcut in `preferences` at once.
    /// - Returns: the actions that could not be registered, for UI reporting.
    @discardableResult
    func applyBindings(from preferences: Preferences) -> [HotKeyAction: Error] {
        var failures: [HotKeyAction: Error] = [:]
        let desired: [HotKeyAction: KeyCombo?] = [
            .pasteStack: preferences.pasteStackHotKey,
            .resetStack: preferences.resetStackHotKey,
            .recall: preferences.recallHotKey,
            .toggleStackMode: preferences.toggleStackModeHotKey,
            .captureText: preferences.captureTextHotKey,
        ]

        for (action, combo) in desired {
            do {
                try bind(combo, to: action)
            } catch {
                failures[action] = error
            }
        }
        return failures
    }

    // MARK: - Carbon plumbing

    private func installCarbonEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // `self` is passed unretained: HotKeyManager outlives the handler because
        // the app delegate owns it for the whole process lifetime, and deinit
        // removes the handler.
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &spec,
            context,
            &eventHandler
        )
    }

    /// Called (on the main thread) from the C event handler below.
    fileprivate func handleHotKey(id: UInt32) {
        guard let registration = registrations[id],
              let handler = handlers[registration.action]
        else { return }
        handler()
    }
}

/// Carbon calls this as a plain C function pointer, so it must be a free
/// function and `nonisolated`. Carbon delivers hotkey events on the main run
/// loop already, so the hop to the main actor is just what the concurrency
/// checker needs, not a real thread change.
private nonisolated func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    Task { @MainActor in
        manager.handleHotKey(id: id)
    }
    return noErr
}
