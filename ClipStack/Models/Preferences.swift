//
//  Preferences.swift
//  ClipStack
//
//  Every user-facing setting, persisted in UserDefaults. Shortcuts live here too
//  so they are remappable rather than hard-coded.
//

import AppKit
import Combine

/// How much ClipStack does to the text it reads from a screen capture.
enum CaptureFormatting: String, CaseIterable, Identifiable {
    /// Exactly as recognised, row by row.
    case off
    /// Columns, bullets, numbering and paragraphs, by layout rules alone.
    case layout
    /// The layout rules, plus Apple's on-device model for the order of
    /// captures with columns or side-by-side text.
    case smart

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off — text exactly as read"
        case .layout: return "Layout rules"
        case .smart: return "Smart — rules + Apple Intelligence"
        }
    }
}

/// When a capture is shown before it goes to the stack or clipboard.
enum CapturePreviewPolicy: String, CaseIterable, Identifiable {
    case complexOnly
    case always
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .complexOnly: return "Only when columns, tables or AI were involved"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// How stacked items are glued together by Paste Stack.
enum StackSeparator: String, CaseIterable, Codable, Identifiable {
    case newline
    case doubleNewline
    case space
    case commaSpace
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newline:       return "New line"
        case .doubleNewline: return "Blank line between items"
        case .space:         return "Space"
        case .commaSpace:    return "Comma + space"
        case .custom:        return "Custom…"
        }
    }

    /// `customValue` is only consulted for `.custom`.
    func string(customValue: String) -> String {
        switch self {
        case .newline:       return "\n"
        case .doubleNewline: return "\n\n"
        case .space:         return " "
        case .commaSpace:    return ", "
        case .custom:        return customValue
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let stackModeEnabled   = "stackModeEnabled"
        static let separator          = "stackSeparator"
        static let customSeparator    = "stackCustomSeparator"
        static let autoClearTimeout   = "stackAutoClearTimeout"
        static let autoPaste          = "pasteStackAutoPaste"
        static let clearAfterPaste    = "pasteStackClearsAfterPaste"
        static let hotKeyPasteStack   = "hotKeyPasteStack"
        static let hotKeyResetStack   = "hotKeyResetStack"
        static let hotKeyRecall       = "hotKeyRecall"
        static let hotKeyToggleStack  = "hotKeyToggleStackMode"
        static let hasLaunchedBefore  = "hasLaunchedBefore"
        static let iCloudSync         = "iCloudSyncEnabled"
        static let recallAutoPaste    = "recallAutoPaste"
        static let captureWithoutKey  = "stackCapturesCopiesWithoutShortcut"
        static let hotKeyCaptureText  = "hotKeyCaptureText"
        static let hotKeyFormatStack  = "hotKeyFormatStack"
        static let captureFormatting  = "captureFormatting"
        static let captureStyle       = "captureOutputStyle"
        static let capturePreview     = "capturePreviewPolicy"
        static let captureFixBullets  = "captureFixMisreadBullets"
        static let captureHyphens     = "captureJoinHyphenatedWords"
        static let captureJoinLines   = "captureJoinWrappedLines"
        static let captureDocument    = "captureUsesDocumentRecognition"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        stackModeEnabled = defaults.bool(forKey: Key.stackModeEnabled)
        separator = defaults.string(forKey: Key.separator)
            .flatMap(StackSeparator.init(rawValue:)) ?? .newline
        customSeparator = defaults.string(forKey: Key.customSeparator) ?? ", "
        // 0 means "off", which is also the value a missing key decodes to — the
        // documented default for auto-clear.
        autoClearTimeout = defaults.double(forKey: Key.autoClearTimeout)
        autoPasteEnabled = defaults.object(forKey: Key.autoPaste) as? Bool ?? true
        // Opt-in: syncing a personal snippet library off the machine should be a
        // deliberate choice, and it needs the iCloud capability enabled anyway.
        iCloudSyncEnabled = defaults.object(forKey: Key.iCloudSync) as? Bool ?? false
        recallAutoPaste = defaults.object(forKey: Key.recallAutoPaste) as? Bool ?? true
        clearStackAfterPaste = defaults.object(forKey: Key.clearAfterPaste) as? Bool ?? false
        captureCopiesWithoutShortcut = defaults.object(forKey: Key.captureWithoutKey) as? Bool ?? true
        captureFormatting = defaults.string(forKey: Key.captureFormatting)
            .flatMap(CaptureFormatting.init(rawValue:)) ?? .smart
        captureOutputStyle = defaults.string(forKey: Key.captureStyle)
            .flatMap(LayoutRenderer.Style.init(rawValue:)) ?? .plain
        capturePreviewPolicy = defaults.string(forKey: Key.capturePreview)
            .flatMap(CapturePreviewPolicy.init(rawValue:)) ?? .complexOnly
        captureFixMisreadBullets = defaults.object(forKey: Key.captureFixBullets) as? Bool ?? true
        captureJoinHyphenatedWords = defaults.object(forKey: Key.captureHyphens) as? Bool ?? true
        captureJoinWrappedLines = defaults.object(forKey: Key.captureJoinLines) as? Bool ?? true
        captureUsesDocumentRecognition = defaults.object(forKey: Key.captureDocument) as? Bool ?? true

        pasteStackHotKey = Self.decode(defaults, Key.hotKeyPasteStack) ?? .defaultPasteStack
        resetStackHotKey = Self.decode(defaults, Key.hotKeyResetStack) ?? .defaultResetStack
        recallHotKey     = Self.decode(defaults, Key.hotKeyRecall)     ?? .defaultRecall

        // Optional, so "never configured" and "deliberately cleared" have to stay
        // distinguishable — otherwise clearing it would silently reinstate the
        // default on the next launch. An absent key means untouched; a stored
        // record holding `null` means the user removed it on purpose.
        switch Self.decodeOptional(defaults, Key.hotKeyToggleStack) {
        case .none:                  toggleStackModeHotKey = .defaultToggleStackMode
        case .some(let storedValue): toggleStackModeHotKey = storedValue
        }
        switch Self.decodeOptional(defaults, Key.hotKeyCaptureText) {
        case .none:                  captureTextHotKey = .defaultCaptureText
        case .some(let storedValue): captureTextHotKey = storedValue
        }
        switch Self.decodeOptional(defaults, Key.hotKeyFormatStack) {
        case .none:                  formatStackHotKey = .defaultFormatStack
        case .some(let storedValue): formatStackHotKey = storedValue
        }
    }

    // MARK: - Stack Mode

    @Published var stackModeEnabled: Bool {
        didSet { defaults.set(stackModeEnabled, forKey: Key.stackModeEnabled) }
    }

    @Published var separator: StackSeparator {
        didSet { defaults.set(separator.rawValue, forKey: Key.separator) }
    }

    @Published var customSeparator: String {
        didSet { defaults.set(customSeparator, forKey: Key.customSeparator) }
    }

    /// Seconds of inactivity before the stack empties itself. `0` disables it.
    @Published var autoClearTimeout: TimeInterval {
        didSet { defaults.set(autoClearTimeout, forKey: Key.autoClearTimeout) }
    }

    @Published var autoPasteEnabled: Bool {
        didSet { defaults.set(autoPasteEnabled, forKey: Key.autoPaste) }
    }

    @Published var clearStackAfterPaste: Bool {
        didSet { defaults.set(clearStackAfterPaste, forKey: Key.clearAfterPaste) }
    }

    /// Whether Stack Mode also takes copies that never pressed ⌘C — Shottr and
    /// other screenshot-to-text tools, Edit ▸ Copy, right-click ▸ Copy.
    @Published var captureCopiesWithoutShortcut: Bool {
        didSet { defaults.set(captureCopiesWithoutShortcut, forKey: Key.captureWithoutKey) }
    }

    /// The resolved separator string used when joining the stack.
    var separatorString: String { separator.string(customValue: customSeparator) }

    // MARK: - Saved texts

    @Published var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloudSync) }
    }

    /// Whether ↩ in the ⌥Space panel pastes straight into the app you came from,
    /// rather than only loading the clipboard.
    @Published var recallAutoPaste: Bool {
        didSet { defaults.set(recallAutoPaste, forKey: Key.recallAutoPaste) }
    }

    // MARK: - Screen text capture

    @Published var captureFormatting: CaptureFormatting {
        didSet { defaults.set(captureFormatting.rawValue, forKey: Key.captureFormatting) }
    }

    @Published var captureOutputStyle: LayoutRenderer.Style {
        didSet { defaults.set(captureOutputStyle.rawValue, forKey: Key.captureStyle) }
    }

    @Published var capturePreviewPolicy: CapturePreviewPolicy {
        didSet { defaults.set(capturePreviewPolicy.rawValue, forKey: Key.capturePreview) }
    }

    @Published var captureFixMisreadBullets: Bool {
        didSet { defaults.set(captureFixMisreadBullets, forKey: Key.captureFixBullets) }
    }

    @Published var captureJoinHyphenatedWords: Bool {
        didSet { defaults.set(captureJoinHyphenatedWords, forKey: Key.captureHyphens) }
    }

    @Published var captureJoinWrappedLines: Bool {
        didSet { defaults.set(captureJoinWrappedLines, forKey: Key.captureJoinLines) }
    }

    /// macOS 26 document recognition, which finds lists, tables and titles
    /// itself. Ignored on older macOS.
    @Published var captureUsesDocumentRecognition: Bool {
        didSet { defaults.set(captureUsesDocumentRecognition, forKey: Key.captureDocument) }
    }

    var captureLayoutOptions: LayoutOptions {
        LayoutOptions(
            fixMisreadBullets: captureFixMisreadBullets,
            joinHyphenatedWords: captureJoinHyphenatedWords,
            joinWrappedLines: captureJoinWrappedLines
        )
    }

    // MARK: - Shortcuts

    @Published var pasteStackHotKey: KeyCombo {
        didSet { Self.encode(defaults, pasteStackHotKey, Key.hotKeyPasteStack) }
    }

    @Published var resetStackHotKey: KeyCombo {
        didSet { Self.encode(defaults, resetStackHotKey, Key.hotKeyResetStack) }
    }

    @Published var recallHotKey: KeyCombo {
        didSet { Self.encode(defaults, recallHotKey, Key.hotKeyRecall) }
    }

    @Published var toggleStackModeHotKey: KeyCombo? {
        didSet { Self.encodeOptional(defaults, toggleStackModeHotKey, Key.hotKeyToggleStack) }
    }

    @Published var captureTextHotKey: KeyCombo? {
        didSet { Self.encodeOptional(defaults, captureTextHotKey, Key.hotKeyCaptureText) }
    }

    @Published var formatStackHotKey: KeyCombo? {
        didSet { Self.encodeOptional(defaults, formatStackHotKey, Key.hotKeyFormatStack) }
    }

    func resetShortcutsToDefaults() {
        pasteStackHotKey = .defaultPasteStack
        resetStackHotKey = .defaultResetStack
        recallHotKey = .defaultRecall
        toggleStackModeHotKey = .defaultToggleStackMode
        captureTextHotKey = .defaultCaptureText
        formatStackHotKey = .defaultFormatStack
    }

    // MARK: - First launch

    /// True exactly once, on the very first run — used to decide whether to show
    /// the Accessibility explainer before macOS shows its own system prompt.
    var isFirstLaunch: Bool {
        if defaults.bool(forKey: Key.hasLaunchedBefore) { return false }
        defaults.set(true, forKey: Key.hasLaunchedBefore)
        return true
    }

    // MARK: - Codable storage helpers

    private static func decode(_ defaults: UserDefaults, _ key: String) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    private static func encode(_ defaults: UserDefaults, _ combo: KeyCombo?, _ key: String) {
        guard let combo, let data = try? JSONEncoder().encode(combo) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    /// Wrapper so a cleared shortcut round-trips as a stored `null` rather than
    /// as an absent key. Top-level `null` is avoided deliberately — a keyed
    /// container is portable across every JSONDecoder configuration.
    private struct OptionalCombo: Codable {
        var combo: KeyCombo?
    }

    /// - Returns: `nil` when the key was never written, `.some(nil)` when the
    ///   user cleared the shortcut, `.some(combo)` when one is bound.
    private static func decodeOptional(_ defaults: UserDefaults, _ key: String) -> KeyCombo?? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let box = try? JSONDecoder().decode(OptionalCombo.self, from: data) else { return nil }
        return .some(box.combo)
    }

    private static func encodeOptional(_ defaults: UserDefaults, _ combo: KeyCombo?, _ key: String) {
        guard let data = try? JSONEncoder().encode(OptionalCombo(combo: combo)) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
