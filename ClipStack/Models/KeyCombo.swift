//
//  KeyCombo.swift
//  ClipStack
//
//  A codable key + modifier pair. Shortcuts are stored in UserDefaults as this
//  type so every hotkey in the app is user-remappable.
//

import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Hashable {
    /// Virtual key code (kVK_* constants from Carbon.HIToolbox).
    var keyCode: UInt32
    /// Raw value of the NSEvent.ModifierFlags device-independent mask.
    var modifierFlagsRawValue: UInt

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue).intersection(.deviceIndependentFlagsMask)
    }

    /// Carbon's `RegisterEventHotKey` takes its own modifier bitfield, not Cocoa's.
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option)  { carbon |= UInt32(optionKey) }
        if modifiers.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// A hotkey with no modifier would swallow a plain keystroke system-wide.
    var isValid: Bool {
        !modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// Human-readable form, e.g. "⌥⌘V".
    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option)  { out += "⌥" }
        if modifiers.contains(.shift)   { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += Self.keyName(for: keyCode)
        return out
    }

    // MARK: - Defaults

    static let defaultPasteStack = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: [.option, .command])
    static let defaultResetStack = KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: [.option, .command])
    static let defaultRecall     = KeyCombo(keyCode: UInt32(kVK_Space),  modifiers: [.option])
    static let defaultToggleStackMode = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.option, .command])

    // MARK: - Key naming

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(for keyCode: UInt32) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }
        if let translated = translateToCharacter(keyCode) { return translated.uppercased() }
        return "Key \(keyCode)"
    }

    /// Ask the current keyboard layout what character a virtual key produces, so
    /// the UI shows the right letter on non-US layouts (AZERTY, Dvorak, …).
    private static func translateToCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers: we want the bare key legend
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
