//
//  ClipboardChecks.swift
//  ClipStack tests
//
//  Covers the half of ⌘C capture that is not permission-gated: harvesting the
//  copy once the keystroke has been seen.
//
//  The cases that matter are the two delivery orderings. A CGEventTap sees the
//  keystroke *before* the frontmost app copies; a global NSEvent monitor sees it
//  *after* the event was dispatched, by which point the copy has often already
//  landed. An earlier version sampled a baseline at keystroke time, which is
//  correct only for the first ordering — under the second it waited for a change
//  that had already happened and silently dropped every copy.
//
//  A private pasteboard is used so the suite never touches the real clipboard.
//

import AppKit
import Foundation

enum ClipboardChecks {

    @MainActor
    static func run() async -> Int {
        let runner = CheckRunner(suite: "ClipboardManager")

        let pasteboard = NSPasteboard(name: .init("com.prathamesh.ClipStack.tests"))
        let clipboard = ClipboardManager(pasteboard: pasteboard)

        // The controller's watermark: everything is expressed relative to this.
        var consumed = clipboard.changeCount
        let watermark: @MainActor () -> Int = { consumed }

        // ORDERING 1 — event tap: keystroke seen first, copy lands afterwards.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            _ = clipboard.write("copied after the keystroke")
        }
        var captured = await clipboard.awaitCopy(consumedThrough: watermark)
        runner.check("tap ordering: copy arrives after the keystroke",
                     captured?.text ?? "nil", equals: "copied after the keystroke")
        consumed = captured?.changeCount ?? consumed

        // ORDERING 2 — global monitor: the copy already landed before we look.
        // This is the case the old baseline logic dropped entirely.
        _ = clipboard.write("copied before we looked")
        captured = await clipboard.awaitCopy(consumedThrough: watermark)
        runner.check("monitor ordering: copy already landed",
                     captured?.text ?? "nil", equals: "copied before we looked")
        consumed = captured?.changeCount ?? consumed

        // Nothing new: ⌘C on an empty selection must give up, not hang.
        let started = ContinuousClock.now
        captured = await clipboard.awaitCopy(consumedThrough: watermark, timeout: .milliseconds(150))
        let elapsed = ContinuousClock.now - started
        runner.check("gives up when nothing was copied", captured == nil, "got \(captured?.text ?? "nil")")
        runner.check("gives up within its timeout", elapsed < .milliseconds(600), "took \(elapsed)")

        // Both routes see the same ⌘C: the first consumes it, the second must
        // find nothing rather than stacking a duplicate.
        _ = clipboard.write("only once")
        let first = await clipboard.awaitCopy(consumedThrough: watermark)
        runner.check("first route captures", first?.text ?? "nil", equals: "only once")
        consumed = first?.changeCount ?? consumed
        let second = await clipboard.awaitCopy(consumedThrough: watermark, timeout: .milliseconds(120))
        runner.check("second route finds no duplicate", second == nil, "got \(second?.text ?? "nil")")

        // The same text copied twice still registers: the counter moves even
        // though the string is identical.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            _ = clipboard.write("only once")
        }
        captured = await clipboard.awaitCopy(consumedThrough: watermark)
        runner.check("re-copying identical text registers", captured?.text ?? "nil", equals: "only once")

        pasteboard.releaseGlobally()
        return runner.failures
    }
}
