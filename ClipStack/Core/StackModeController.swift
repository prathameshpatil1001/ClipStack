//
//  StackModeController.swift
//  ClipStack
//
//  ── Stack Mode ──────────────────────────────────────────────────────────────
//  While Stack Mode is on, every ⌘C appends the newly copied text to an ordered
//  in-memory stack. ⌥⌘V joins the stack with the configured separator and puts
//  it on the clipboard (optionally auto-pasting); ⌥⌘X empties it.
//
//  ── How ⌘C is observed, and why it cannot break copying ─────────────────────
//  Preferred route: a CGEventTap created with `CGEventTapOptions.listenOnly`.
//  That flag is the whole safety story — a listen-only tap is handed a *copy* of
//  each event and its return value is ignored by the window server, so ClipStack
//  physically cannot swallow, alter or delay a ⌘C. Normal copying keeps working
//  byte-for-byte even if this code hangs or crashes. (A `.defaultTap` could
//  modify events, which would put this code in the critical path of every
//  keystroke on the system. We never want that.)
//
//  The tap is attached at `.cgSessionEventTap` so it sees keystrokes across every
//  app in the login session, which is the point of a global stack.
//
//  ── Two permissions, two routes ─────────────────────────────────────────────
//  A listen-only tap needs **Input Monitoring**, not Accessibility (see
//  SystemPermissions). Asking only for Accessibility is the classic failure
//  here: the tap is created successfully and then silently receives nothing.
//
//  So there is a fallback. When Input Monitoring is unavailable but Accessibility
//  is, ⌘C is observed with `NSEvent.addGlobalMonitorForEvents` instead, which
//  runs off Accessibility trust. A global NSEvent monitor is also passive — it
//  cannot consume or alter the event — so the safety property holds either way.
//  The practical result: granting Accessibility alone makes the whole app work.
//
//  ── Copies that never press ⌘C ──────────────────────────────────────────────
//  Plenty of copies happen without the keystroke: screenshot-to-text tools such
//  as Shottr, Edit ▸ Copy, right-click ▸ Copy, "Copy" buttons in web pages. A
//  keystroke-only design misses them, and worse, leaves them sitting newer than
//  the watermark, so the *next* ⌘C picks up the stale one alongside its own.
//  A clipboard watcher therefore polls the pasteboard's change count a few
//  times a second while Stack Mode is on (reading a counter is free), and takes
//  anything new through the same watermark as the keystroke routes, so a copy
//  is stacked exactly once whichever path sees it first.
//

import AppKit
import Carbon.HIToolbox
import Combine

/// One captured clipboard entry. The spec models the stack as `[String]`, and
/// `stackItems` below exposes exactly that; this wrapper only adds the stable
/// identity SwiftUI needs to animate, delete and drag-reorder rows.
struct StackEntry: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var capturedAt: Date = Date()
}

@MainActor
final class StackModeController: ObservableObject {

    // MARK: - State

    @Published private(set) var entries: [StackEntry] = []

    /// Whether capture is armed. Setting this installs or tears down it.
    @Published private(set) var isEnabled = false

    /// Which routes are currently observing ⌘C. Surfaced in Settings, because
    /// "which permission is actually doing the work" is the first thing worth
    /// knowing when this feature misbehaves.
    ///
    /// Both run at once when both are permitted. They are redundant on purpose:
    /// exactly which mechanism a given macOS version delivers keyboard events to
    /// depends on privacy settings that are easy to get subtly wrong, and a
    /// duplicate capture is cheap to discard (see `handleCopyKeystroke`) while a
    /// missed copy is invisible and infuriating.
    struct CaptureRoutes: OptionSet {
        let rawValue: Int
        static let eventTap      = CaptureRoutes(rawValue: 1 << 0)  // Input Monitoring
        static let globalMonitor = CaptureRoutes(rawValue: 1 << 1)  // Accessibility

        var description: String {
            switch (contains(.eventTap), contains(.globalMonitor)) {
            case (true, true):   return "Event tap + global monitor"
            case (true, false):  return "Event tap (Input Monitoring)"
            case (false, true):  return "Global monitor (Accessibility)"
            case (false, false): return "Not capturing"
            }
        }
    }

    @Published private(set) var captureRoutes: CaptureRoutes = []

    /// The ordered stack as plain strings — the canonical `stackItems: [String]`.
    var stackItems: [String] { entries.map(\.text) }

    var count: Int { entries.count }

    // MARK: - Collaborators

    private let preferences: Preferences
    private let clipboard: ClipboardManager
    private let permissions: SystemPermissions

    /// UI hooks, wired up by the app delegate.
    var onHUD: ((String, String) -> Void)?           // (message, SF Symbol name)
    var onStackChanged: (() -> Void)?

    // MARK: - Event tap

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalKeyMonitor: Any?
    private var autoClearTimer: Timer?
    private var clipboardWatchTimer: Timer?

    /// Changes the clipboard watcher has decided to leave alone (private items,
    /// non-text copies). Kept apart from `consumedChangeCount` on purpose: the
    /// watcher skipping something must not stop an explicit ⌘C from taking it.
    private var watcherSkippedThrough = 0
    private var unreadableChangeCount = 0
    private var unreadablePolls = 0

    /// The highest pasteboard change count ClipStack has already taken.
    ///
    /// Everything about capture is expressed relative to this rather than to a
    /// baseline sampled when the key was pressed, because the two capture routes
    /// deliver at opposite moments (see `ClipboardManager.awaitCopy`). It also
    /// de-duplicates: when both routes see the same ⌘C, the first to consume
    /// raises the watermark and the second finds nothing new.
    ///
    /// It is raised on ClipStack's own writes too, so pasting the stack cannot
    /// be mistaken for the user copying something.
    private var consumedChangeCount = 0

    init(preferences: Preferences, clipboard: ClipboardManager, permissions: SystemPermissions) {
        self.preferences = preferences
        self.clipboard = clipboard
        self.permissions = permissions
    }

    deinit {
        // CFMachPort / CFRunLoopSource are not ARC-managed in the way we need;
        // tear the tap down explicitly. (deinit cannot touch main-actor state,
        // so this mirrors uninstallTap() with only the Core Foundation calls.)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        clipboardWatchTimer?.invalidate()
    }

    // MARK: - Enabling

    /// Turns Stack Mode on or off, installing/removing the tap to match.
    /// - Returns: the state actually reached (turning on fails without permission).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled else { return isEnabled }

        if enabled {
            guard startCapturing() else {
                // No permission, or it was revoked: stay off and explain.
                isEnabled = false
                preferences.stackModeEnabled = false
                if permissions.canObserveCopyKeystroke {
                    // We believe we are allowed, yet both routes refused —
                    // almost always a stale permission entry from an older build.
                    permissions.presentCaptureUnavailableGuidance()
                } else {
                    permissions.presentExplainer(isFirstLaunch: false)
                }
                return false
            }
            isEnabled = true
            preferences.stackModeEnabled = true
            scheduleAutoClearIfNeeded()
            onHUD?("Stack Mode on", "square.3.layers.3d.top.filled")
        } else {
            stopCapturing()
            isEnabled = false
            preferences.stackModeEnabled = false
            autoClearTimer?.invalidate()
            autoClearTimer = nil
            onHUD?("Stack Mode off", "square.3.layers.3d.slash")
        }
        return isEnabled
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Called after the user grants Accessibility mid-session: silently arm the
    /// tap if Stack Mode was left on.
    func rearmIfNeeded() {
        guard preferences.stackModeEnabled, !isEnabled else { return }
        if startCapturing() {
            isEnabled = true
            scheduleAutoClearIfNeeded()
        }
    }

    // MARK: - Stack operations

    /// ⌥⌘V — join everything and put it on the clipboard.
    func pasteStack() {
        guard !entries.isEmpty else {
            onHUD?("Stack is empty", "tray")
            return
        }

        let joined = stackItems.joined(separator: preferences.separatorString)
        guard clipboard.write(joined) else {
            onHUD?("Could not write clipboard", "exclamationmark.triangle")
            return
        }
        // Our own write moves the counter; claim it so an in-flight capture
        // cannot stack the joined text straight back onto the stack.
        consumedChangeCount = clipboard.changeCount

        let itemCount = entries.count

        guard preferences.autoPasteEnabled else {
            onHUD?("Stack copied (\(itemCount)) — press ⌘V", "doc.on.clipboard")
            finishPaste()
            return
        }

        Task { @MainActor in
            let pasted = await PasteSimulator.pasteIntoFrontmostApp()
            if pasted {
                onHUD?("Pasted stack (\(itemCount))", "checkmark.circle.fill")
            } else {
                // Auto-paste needs Accessibility; the text is still on the
                // clipboard, so degrade to a manual paste rather than losing it.
                onHUD?("Stack copied (\(itemCount)) — press ⌘V", "doc.on.clipboard")
            }
            finishPaste()
        }
    }

    private func finishPaste() {
        if preferences.clearStackAfterPaste {
            entries.removeAll()
            onStackChanged?()
        }
        scheduleAutoClearIfNeeded()
    }

    /// ⌥⌘X — empty the stack.
    func resetStack(silent: Bool = false) {
        let had = entries.count
        entries.removeAll()
        onStackChanged?()
        autoClearTimer?.invalidate()
        autoClearTimer = nil
        if !silent {
            onHUD?(had == 0 ? "Stack already empty" : "Stack cleared (\(had))", "trash")
        }
    }

    func remove(_ entry: StackEntry) {
        entries.removeAll { $0.id == entry.id }
        onStackChanged?()
    }

    /// Deletes the rows at `offsets`. Implemented directly rather than via
    /// SwiftUI's collection helpers so this controller stays UI-framework free.
    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where entries.indices.contains(index) {
            entries.remove(at: index)
        }
        onStackChanged?()
    }

    /// Drag-to-reorder from the menu bar list. `destination` is an insertion
    /// point in the *original* array, which is why the target index is shifted
    /// back by however many moved rows sat before it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !moving.isEmpty else { return }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        var reordered = entries
        for index in source.sorted(by: >) where reordered.indices.contains(index) {
            reordered.remove(at: index)
        }

        let insertionIndex = max(0, min(reordered.count, destination - removedBeforeDestination))
        reordered.insert(contentsOf: moving, at: insertionIndex)
        entries = reordered
        onStackChanged?()
    }

    /// Lets the user stack something without a ⌘C (used by the menu bar item).
    func appendCurrentClipboard() {
        guard let text = clipboard.readString(), !text.isEmpty else {
            onHUD?("Clipboard has no text", "doc.on.clipboard")
            return
        }
        consumedChangeCount = clipboard.changeCount
        append(text)
    }

    /// Adds text that didn't come from a copy — a screen capture.
    func addCaptured(_ text: String) {
        append(text)
    }

    private func append(_ text: String) {
        entries.append(StackEntry(text: text))
        onStackChanged?()
        onHUD?("Added to stack (\(entries.count))", "square.3.layers.3d.top.filled")
        scheduleAutoClearIfNeeded()
    }

    // MARK: - Auto-clear

    /// Restarts the inactivity countdown. `autoClearTimeout == 0` means off,
    /// which is the default.
    private func scheduleAutoClearIfNeeded() {
        autoClearTimer?.invalidate()
        autoClearTimer = nil

        let timeout = preferences.autoClearTimeout
        guard timeout > 0, !entries.isEmpty else { return }

        autoClearTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.entries.isEmpty else { return }
                let cleared = self.entries.count
                self.entries.removeAll()
                self.onStackChanged?()
                self.onHUD?("Stack auto-cleared (\(cleared))", "clock.arrow.circlepath")
            }
        }
    }

    /// Called when the timeout preference changes so the running timer follows it.
    func autoClearSettingChanged() {
        scheduleAutoClearIfNeeded()
    }

    // MARK: - Event tap lifecycle

    /// Starts observing ⌘C by whichever route the granted permissions allow.
    ///
    /// The event tap is preferred: it is lower level and unaffected by ClipStack's
    /// own activation state. The NSEvent monitor is the fallback so that granting
    /// Accessibility alone — which auto-paste needs anyway — is enough.
    private func startCapturing() -> Bool {
        permissions.refresh()

        var routes: CaptureRoutes = []

        // Attempted unconditionally rather than gated on the preflight: the
        // preflight answer is cached per process and can lag behind a permission
        // the user granted a moment ago. A refused tap simply returns nil.
        if installEventTap() {
            routes.insert(.eventTap)
        }

        // Only meaningful with Accessibility trust — untrusted, this returns a
        // token that never fires, which would look like success.
        if permissions.isAccessibilityTrusted, installGlobalMonitor() {
            routes.insert(.globalMonitor)
        }

        captureRoutes = routes
        if !routes.isEmpty {
            // Start from whatever is on the clipboard now, so the first ⌘C
            // captures that copy rather than something copied before arming.
            consumedChangeCount = clipboard.changeCount
            watcherSkippedThrough = consumedChangeCount
            startWatchingClipboard()
        }
        return !routes.isEmpty
    }

    private func stopCapturing() {
        uninstallEventTap()
        uninstallGlobalMonitor()
        stopWatchingClipboard()
        captureRoutes = []
    }

    // MARK: Clipboard watcher (no permission needed)

    /// How often the watcher looks. Only the change count is read on a quiet
    /// tick, which costs nothing; text is read only when it has moved.
    private static let clipboardWatchInterval: TimeInterval = 0.25

    /// Polls for a change this many times before deciding it holds no text.
    /// The counter can move a beat before the writer finishes, so one empty
    /// read is not proof of an image or file.
    private static let unreadablePollLimit = 4

    private func startWatchingClipboard() {
        guard clipboardWatchTimer == nil else { return }
        let timer = Timer(timeInterval: Self.clipboardWatchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
        timer.tolerance = 0.05
        // Common modes, so copies still register while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        clipboardWatchTimer = timer
    }

    private func stopWatchingClipboard() {
        clipboardWatchTimer?.invalidate()
        clipboardWatchTimer = nil
    }

    /// One watcher tick: take any new text the keystroke routes have not.
    private func pollClipboard() {
        guard isEnabled, preferences.captureCopiesWithoutShortcut else { return }

        let watermark = max(consumedChangeCount, watcherSkippedThrough)
        switch clipboard.inspectChange(after: watermark) {
        case .unchanged:
            return

        case .text(let text, let changeCount):
            consumedChangeCount = changeCount
            append(text)

        case .ignored(let changeCount):
            watcherSkippedThrough = changeCount

        case .notText(let changeCount):
            if changeCount != unreadableChangeCount {
                unreadableChangeCount = changeCount
                unreadablePolls = 0
            }
            unreadablePolls += 1
            if unreadablePolls >= Self.unreadablePollLimit {
                watcherSkippedThrough = changeCount
            }
        }
    }

    // MARK: Event tap (Input Monitoring)

    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }

        // We ask only for keyDown plus the two "your tap was turned off" notices.
        // Narrow masks matter: the callback runs for every matching event in the
        // session, so we keep it as small as possible.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,      // every app in this login session
            place: .headInsertEventTap,
            options: .listenOnly,          // ← cannot alter or block the user's ⌘C
            eventsOfInterest: CGEventMask(mask),
            callback: stackModeEventTapCallback,
            userInfo: context
        ) else {
            // Returns nil when Input Monitoring has not been granted.
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    private func uninstallEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: Global monitor (Accessibility)

    /// `addGlobalMonitorForEvents` observes events destined for *other* apps and
    /// requires Accessibility trust. Like the listen-only tap it is passive: the
    /// handler has no way to consume or modify the keystroke.
    ///
    /// It returns a non-nil token even when untrusted (it simply never fires), so
    /// the caller checks trust before choosing this route.
    private func installGlobalMonitor() -> Bool {
        guard globalKeyMonitor == nil else { return true }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            guard isCopyKeystroke(keyCode: Int64(event.keyCode), flags: event.modifierFlags) else { return }
            // Note this fires *after* the event was dispatched to the frontmost
            // app, so the copy may already have landed. `handleCopyKeystroke`
            // is written to be correct either way.
            self.handleCopyKeystroke()
        }
        return globalKeyMonitor != nil
    }

    private func uninstallGlobalMonitor() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        globalKeyMonitor = nil
    }

    /// macOS disables a tap that misbehaves (or when certain secure-input
    /// transitions happen). Re-enabling is the documented recovery.
    fileprivate func reenableTapAfterSystemDisable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Entry point for an observed ⌘C, from either capture route.
    ///
    /// Takes no baseline on purpose: the caller cannot know whether the copy has
    /// already landed, because that depends on which route saw the keystroke.
    /// `awaitCopy` resolves it by waiting for anything newer than what we have
    /// already consumed, which is true in both orderings.
    fileprivate func handleCopyKeystroke() {
        guard isEnabled else { return }

        Task { @MainActor in
            guard let captured = await clipboard.awaitCopy(
                consumedThrough: { [weak self] in self?.consumedChangeCount ?? 0 }
            ) else {
                // Nothing new within the window: a non-text copy, an empty
                // selection, or the other route already took this one.
                return
            }

            consumedChangeCount = captured.changeCount
            append(captured.text)
        }
    }

}

// MARK: - Keystroke classification

/// Is this a bare ⌘C?
///
/// With ⌥, ⌃ or ⇧ added it is a different command in most apps (⇧⌘C, ⌥⌘C …) and
/// must not be treated as a copy. Shared by both capture routes so they can
/// never disagree about what counts as a copy.
private nonisolated func isCopyKeystroke(keyCode: Int64, flags: NSEvent.ModifierFlags) -> Bool {
    guard keyCode == Int64(kVK_ANSI_C) else { return false }
    return flags.contains(.command)
        && !flags.contains(.option)
        && !flags.contains(.control)
        && !flags.contains(.shift)
}

private nonisolated func isCopyKeystroke(keyCode: Int64, cgFlags: CGEventFlags) -> Bool {
    guard keyCode == Int64(kVK_ANSI_C) else { return false }
    return cgFlags.contains(.maskCommand)
        && !cgFlags.contains(.maskAlternate)
        && !cgFlags.contains(.maskControl)
        && !cgFlags.contains(.maskShift)
}

// MARK: - C callback

/// The window server calls this on the main run loop as a plain C function
/// pointer, so it must be a free `nonisolated` function that does as little work
/// as possible. All it does is classify the event and hand off to the main actor.
private nonisolated func stackModeEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<StackModeController>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // The tap has been switched off by the system; turn it back on.
        Task { @MainActor in controller.reenableTapAfterSystemDisable() }
        return Unmanaged.passUnretained(event)

    case .keyDown:
        // Ignore anything ClipStack itself posted (auto-paste), so synthetic
        // keystrokes can never feed the stack.
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard marker != PasteSimulator.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard isCopyKeystroke(keyCode: keyCode, cgFlags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        Task { @MainActor in controller.handleCopyKeystroke() }

    default:
        break
    }

    // Listen-only taps have their return value ignored, but returning the event
    // unmodified is the correct, explicit thing to do.
    return Unmanaged.passUnretained(event)
}
