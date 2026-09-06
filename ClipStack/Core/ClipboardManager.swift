//
//  ClipboardManager.swift
//  ClipStack
//
//  The single place that touches NSPasteboard.general. Everything else in the
//  app goes through here so reads/writes and change-count bookkeeping stay in
//  one spot.
//

import AppKit

@MainActor
final class ClipboardManager {
    static let shared = ClipboardManager()

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Monotonic counter macOS bumps on every write by any process. The only
    /// reliable way to tell "the clipboard actually changed" from "the same text
    /// was copied again".
    var changeCount: Int { pasteboard.changeCount }

    func readString() -> String? {
        pasteboard.string(forType: .string)
    }

    @discardableResult
    func write(_ string: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }

    /// The text a copy produced, plus the change count it arrived at.
    struct CapturedCopy {
        let text: String
        let changeCount: Int
    }

    /// Waits until the pasteboard holds something newer than what the caller has
    /// already consumed, then returns it.
    ///
    /// Phrased as "newer than what I've already taken" rather than "different
    /// from the value at keystroke time" on purpose, because the two ways
    /// ClipStack observes ⌘C deliver at opposite moments:
    ///
    ///   • A CGEventTap fires *before* the frontmost app handles the copy, so
    ///     the pasteboard has not moved yet and we genuinely have to wait.
    ///   • A global NSEvent monitor fires *after* the event was dispatched, so
    ///     the copy has often already landed by the time we look.
    ///
    /// A baseline sampled at keystroke time is correct for the first and wrong
    /// for the second — it would equal the post-copy value, and waiting for a
    /// further change would time out and silently drop the copy. Comparing
    /// against a consumption watermark is correct for both.
    ///
    /// - Parameter consumedThrough: re-read on every poll, not captured once, so
    ///   that when both routes race for the same keystroke the first to consume
    ///   moves the watermark and the loser simply finds nothing new and gives up.
    ///   That is what keeps one ⌘C from being stacked twice.
    func awaitCopy(
        consumedThrough: @escaping @MainActor () -> Int,
        timeout: Duration = .milliseconds(900),
        pollInterval: Duration = .milliseconds(20)
    ) async -> CapturedCopy? {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            let current = pasteboard.changeCount
            if current > consumedThrough() {
                // The counter can move a beat before the data is written, so an
                // empty read here means "not ready yet", not "not text".
                if let text = pasteboard.string(forType: .string), !text.isEmpty {
                    return CapturedCopy(text: text, changeCount: current)
                }
            }
            try? await Task.sleep(for: pollInterval)
        }

        // Timed out: a non-text copy (image, file), an empty selection, or the
        // other capture route got there first.
        return nil
    }
}
