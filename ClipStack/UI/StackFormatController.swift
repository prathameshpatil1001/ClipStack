//
//  StackFormatController.swift
//  ClipStack
//
//  Format Stack (⌃⌥⌘V): the whole stack as one cleanly structured document.
//
//    • A screen capture keeps the layout it was given when captured.
//    • Copied text is laid out by its own structure (PlainTextLayout).
//    • In Smart mode, copied text that seems to have lost its structure on the
//      way — a web list arrives with no bullets — is labelled by Apple's
//      on-device model, which may only say what each run of lines is, in the
//      original order; anything else is refused.
//    • Items are joined, with lists and tables that carry on across items
//      merged into one.
//
//  Then it behaves like Paste Stack — onto the clipboard, pasted for you if
//  auto-paste is on — but with a formatted copy alongside the text, so Notes,
//  Pages, Mail and Docs get real bullets and tables. When the AI was involved
//  (or the preview setting asks for it), the result is shown first.
//

import AppKit

@MainActor
final class StackFormatController {

    var onHUD: ((String, String) -> Void)?

    private let preferences: Preferences
    private let stack: StackModeController
    private let preview = CapturePreviewController()
    private var isBusy = false

    init(preferences: Preferences, stack: StackModeController) {
        self.preferences = preferences
        self.stack = stack
    }

    func formatStack() {
        guard !isBusy else { return }
        let entries = stack.entries
        guard !entries.isEmpty else {
            onHUD?("Stack is empty", "tray")
            return
        }

        // Where the result is going, remembered before any preview takes focus.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let targetApp = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : frontmost

        let items = entries.map { entry -> StackFormatItem in
            let layout = entry.capture.flatMap { $0.showsRaw || $0.blocks.isEmpty ? nil : $0.blocks }
            return StackFormatItem(text: entry.text, blocks: layout)
        }
        let options = preferences.captureLayoutOptions
        let useAI = preferences.captureFormatting == .smart && OnDeviceAI.isAvailable
        let rawText = stack.stackItems.joined(separator: preferences.separatorString)
        let style = preferences.captureOutputStyle

        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }

            var parts = StackFormatter.blocks(for: items, options: options)
            var labelledByAI = false

            if useAI {
                for index in items.indices where items[index].blocks == nil {
                    let lines = PlainTextLayout.lines(items[index].text)
                    guard StackFormatter.mightHaveLostStructure(parts[index], lineCount: lines.count) else { continue }
                    if let proposal = try? await OnDeviceAI.arrangeLayout(
                        prompt: TextArrangement.prompt(for: lines),
                        instructions: TextArrangement.instructions
                    ), let blocks = TextArrangement.blocks(from: proposal, lines: lines, options: options) {
                        parts[index] = blocks
                        labelledByAI = true
                    }
                }
            }

            let merged = StackFormatter.merge(parts)
            let layout = TextLayout(
                blocks: merged,
                newspaperColumnRuns: 0,
                sideBySideRows: merged.filter { $0.kind == .tableRow }.count
            )
            let result = CaptureResult(
                rawText: rawText,
                layout: layout,
                arrangedByAI: labelledByAI,
                style: style,
                lineCount: items.count,
                isStack: true
            )
            route(result, itemCount: items.count, targetApp: targetApp)
        }
    }

    private func route(_ result: CaptureResult, itemCount: Int, targetApp: NSRunningApplication?) {
        let showPreview: Bool
        switch preferences.capturePreviewPolicy {
        case .always: showPreview = true
        case .never: showPreview = false
        // A table is not a judgement call for copied text; the AI's labels are.
        case .complexOnly: showPreview = result.arrangedByAI
        }

        guard showPreview else {
            stack.pasteFormatted(text: result.text, html: result.html, itemCount: itemCount, targetApp: targetApp)
            return
        }
        let title = preferences.autoPasteEnabled ? "Paste" : "Copy"
        preview.show(result, primaryTitle: title) { [weak self] text, html in
            self?.stack.pasteFormatted(text: text, html: html, itemCount: itemCount, targetApp: targetApp)
        }
    }
}
