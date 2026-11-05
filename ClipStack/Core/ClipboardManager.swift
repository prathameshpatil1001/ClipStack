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

    /// The change count of ClipStack's own most recent write, so the clipboard
    /// watcher can tell "ClipStack put this here" (pasting the stack, recalling
    /// a saved text, Copy in a context menu) from the user copying something.
    private(set) var lastOwnWriteChangeCount = -1

    @discardableResult
    func write(_ string: String) -> Bool {
        pasteboard.clearContents()
        let written = pasteboard.setString(string, forType: .string)
        lastOwnWriteChangeCount = pasteboard.changeCount
        return written
    }

    /// Writes text plus a formatted copy (HTML, and RTF made from it), so apps
    /// that understand formatting paste real bullets and tables while plain
    /// text editors get the text.
    @discardableResult
    func write(_ string: String, html: String) -> Bool {
        pasteboard.clearContents()
        var written = pasteboard.setString(string, forType: .string)
        written = pasteboard.setString(html, forType: .html) && written
        if let attributed = try? NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ), let rtf = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        lastOwnWriteChangeCount = pasteboard.changeCount
        return written
    }

    // MARK: - Watching for copies made without ⌘C

    /// What the pasteboard holds compared with what the caller has consumed.
    enum PasteboardChange: Equatable {
        /// Nothing newer than the watermark.
        case unchanged
        /// New text, from any app.
        case text(text: String, changeCount: Int)
        /// Something new that should never be stacked: ClipStack's own write, or
        /// an item the writer marked private or transient (password managers).
        case ignored(changeCount: Int)
        /// Something new without text: an image or a file — or text whose data
        /// has not been written yet, which is why callers retry briefly.
        case notText(changeCount: Int)
    }

    /// Markers from the nspasteboard.org convention. Password managers set the
    /// concealed type on passwords; transient means "do not keep a history".
    static let privacyMarkerTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// Classifies the pasteboard without waiting. Used by Stack Mode's clipboard
    /// watcher, which catches copies that never press ⌘C — screenshot-to-text
    /// tools such as Shottr, Edit ▸ Copy, right-click ▸ Copy, "Copy" buttons.
    func inspectChange(after consumedThrough: Int) -> PasteboardChange {
        let current = pasteboard.changeCount
        guard current > consumedThrough else { return .unchanged }

        if current == lastOwnWriteChangeCount {
            return .ignored(changeCount: current)
        }
        let types = pasteboard.types ?? []
        if types.contains(where: { Self.privacyMarkerTypes.contains($0) }) {
            return .ignored(changeCount: current)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return .notText(changeCount: current)
        }
        return .text(text: text, changeCount: current)
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
