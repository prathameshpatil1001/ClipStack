//
//  TextCaptureController.swift
//  ClipStack
//
//  Screen-text capture, start to finish:
//
//    hotkey → freeze the screens → drag a box → read the text (Vision)
//           → rebuild its layout (TextLayout) → for a capture with columns or
//             side-by-side text, let Apple's on-device model settle the order
//           → into the stack (or onto the clipboard when Stack Mode is off)
//
//  Simple captures go straight through. A complex one — columns, a table, or
//  an order the AI chose — is shown first, with the text exactly as read one
//  click away. Hold ⌥ while releasing the drag for raw text.
//

import AppKit
import SwiftUI

/// What a capture produced, in every form the preview can offer.
@MainActor
struct CaptureResult {
    /// Rows top to bottom, exactly as recognised.
    var rawText: String
    /// nil when raw text was asked for.
    var layout: TextLayout?
    var arrangedByAI: Bool
    var style: LayoutRenderer.Style
    /// Lines read, or for Format Stack, items in the stack.
    var lineCount: Int
    /// Format Stack's result rather than a screen capture.
    var isStack = false

    var text: String {
        guard let layout else { return rawText }
        return LayoutRenderer.text(layout.blocks, style: style)
    }

    var html: String? {
        layout.map { LayoutRenderer.html($0.blocks) }
    }

    var isComplex: Bool { arrangedByAI || (layout?.isComplex ?? false) }

    var summary: String {
        let unit = isStack ? "item" : "line"
        guard let layout else { return "\(lineCount) \(unit)\(lineCount == 1 ? "" : "s"), exactly as read" }
        var parts = ["\(lineCount) \(unit)\(lineCount == 1 ? "" : "s")"]
        if layout.newspaperColumnRuns > 0 { parts.append("columns read one after another") }
        if layout.sideBySideRows > 0 { parts.append("\(layout.sideBySideRows) side-by-side rows") }
        if layout.listItemCount > 0 { parts.append("\(layout.listItemCount) list items") }
        if arrangedByAI {
            parts.append(isStack ? "lost structure restored with Apple Intelligence" : "order checked with Apple Intelligence")
        }
        return parts.joined(separator: " · ")
    }

    /// Recognised lines → the result, using the on-device model only where the
    /// layout rules had to make a judgement about reading order.
    static func make(
        lines: [OCRLine],
        raw: Bool,
        formatting: CaptureFormatting,
        options: LayoutOptions,
        style: LayoutRenderer.Style
    ) async -> CaptureResult {
        let rawText = TextLayoutEngine.rawText(lines)
        guard !raw, formatting != .off else {
            return CaptureResult(rawText: rawText, layout: nil, arrangedByAI: false, style: style, lineCount: lines.count)
        }

        var layout = TextLayoutEngine.layout(lines, options: options)
        var arrangedByAI = false

        if formatting == .smart, layout.isComplex, OnDeviceAI.isAvailable {
            let segments = TextLayoutEngine.rows(lines).flatMap { $0 }
            if let proposal = try? await OnDeviceAI.arrangeLayout(
                prompt: LayoutArrangement.prompt(for: segments),
                instructions: LayoutArrangement.instructions
            ),
               let blocks = LayoutArrangement.blocks(from: proposal, lines: segments, options: options) {
                layout.blocks = blocks
                arrangedByAI = true
            }
        }

        return CaptureResult(rawText: rawText, layout: layout, arrangedByAI: arrangedByAI, style: style, lineCount: lines.count)
    }
}

@MainActor
final class TextCaptureController {

    /// Status for the user, shown in the HUD.
    var onHUD: ((String, String) -> Void)?

    private let preferences: Preferences
    private let stack: StackModeController
    private let clipboard: ClipboardManager
    private let overlay = RegionSelectionOverlay()
    private let preview = CapturePreviewController()

    private var isBusy = false
    private var previouslyActiveApp: NSRunningApplication?

    init(preferences: Preferences, stack: StackModeController, clipboard: ClipboardManager) {
        self.preferences = preferences
        self.stack = stack
        self.clipboard = clipboard
    }

    // MARK: - Starting

    func begin() {
        guard !isBusy, !overlay.isActive else { return }

        guard #available(macOS 14.0, *) else {
            onHUD?("Capturing screen text needs macOS 14 or later", "exclamationmark.triangle.fill")
            return
        }

        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            ScreenRecordingPermission.openSettings()
            onHUD?("Allow ClipStack under Screen Recording, then quit and reopen it", "lock.shield")
            return
        }

        isBusy = true
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor in
            do {
                let snapshots = try await ScreenSnapshotter.snapshotAllScreens()
                guard !snapshots.isEmpty else {
                    finishWithProblem("Couldn't capture the screen")
                    return
                }
                overlay.begin(with: snapshots) { [weak self] selection in
                    self?.selectionMade(selection)
                }
            } catch {
                finishWithProblem("Couldn't capture the screen: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - After the drag

    private func selectionMade(_ selection: RegionSelection?) {
        restoreFocus()
        guard let selection else {
            isBusy = false
            return
        }

        let image = selection.image
        let raw = selection.wantsRawText
        let formatting = preferences.captureFormatting
        let options = preferences.captureLayoutOptions
        let style = preferences.captureOutputStyle

        Task { @MainActor in
            defer { isBusy = false }

            let lines: [OCRLine]
            do {
                lines = try await Task.detached(priority: .userInitiated) {
                    try ScreenTextRecognizer.recognize(image)
                }.value
            } catch {
                onHUD?("Couldn't read text: \(error.localizedDescription)", "exclamationmark.triangle.fill")
                return
            }
            guard !lines.isEmpty else {
                onHUD?("No text found there", "text.viewfinder")
                return
            }

            let result = await CaptureResult.make(
                lines: lines,
                raw: raw,
                formatting: formatting,
                options: options,
                style: style
            )
            route(result)
        }
    }

    private func route(_ result: CaptureResult) {
        let showPreview: Bool
        switch preferences.capturePreviewPolicy {
        case .always: showPreview = true
        case .never: showPreview = false
        case .complexOnly: showPreview = result.isComplex
        }

        guard showPreview else {
            deliver(text: result.text, html: result.html, result: result)
            return
        }
        preview.show(result, primaryTitle: stack.isEnabled ? "Add to Stack" : "Copy") { [weak self] text, html in
            self?.deliver(text: text, html: html, result: result)
        }
    }

    /// Into the stack when Stack Mode is on — that is what it is for — and
    /// onto the clipboard otherwise, with formatting for apps that take it.
    private func deliver(text: String, html: String?, result: CaptureResult) {
        if stack.isEnabled {
            // Both versions go with it, so the stack row can switch between
            // them and Format Stack can reuse the layout.
            let showsRaw = result.layout == nil || text == result.rawText
            let capture = CapturedText(
                blocks: result.layout?.blocks ?? [],
                formattedText: showsRaw ? result.text : text,
                rawText: result.rawText,
                showsRaw: showsRaw
            )
            stack.addCaptured(text, capture: capture)
        } else {
            if let html {
                clipboard.write(text, html: html)
            } else {
                clipboard.write(text)
            }
            onHUD?("Text copied ✓", "doc.on.clipboard")
        }
    }

    private func finishWithProblem(_ message: String) {
        isBusy = false
        restoreFocus()
        onHUD?(message, "exclamationmark.triangle.fill")
    }

    private func restoreFocus() {
        if let app = previouslyActiveApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate(options: [])
        } else {
            NSApp.hide(nil)
        }
        previouslyActiveApp = nil
    }
}

// MARK: - Preview

@MainActor
final class CapturePreviewController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private var onDeliver: ((String, String?) -> Void)?

    func show(_ result: CaptureResult, primaryTitle: String, onDeliver: @escaping (String, String?) -> Void) {
        close()
        self.onDeliver = onDeliver

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = result.isStack ? "Formatted Stack" : "Captured Text"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CapturePreviewView(
            result: result,
            primaryTitle: primaryTitle,
            onDone: { [weak self] text, html in self?.deliver(text, html) },
            onCancel: { [weak self] in self?.close() }
        ))
        panel.center()

        // A window in front: become a regular app meanwhile, or the menu bar
        // vanishes (see WindowActivationPolicy).
        WindowActivationPolicy.windowWillAppear(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func deliver(_ text: String, _ html: String?) {
        let handler = onDeliver
        close()
        handler?(text, html)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        onDeliver = nil
        panel.delegate = nil
        panel.close()
        WindowActivationPolicy.windowDidClose(panel)
    }

    /// Closed with the title bar's close button.
    func windowWillClose(_ notification: Notification) {
        guard let panel else { return }
        self.panel = nil
        onDeliver = nil
        WindowActivationPolicy.windowDidClose(panel)
    }
}

private struct CapturePreviewView: View {
    let result: CaptureResult
    let primaryTitle: String
    let onDone: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var showsRaw = false
    @State private var style: LayoutRenderer.Style

    init(result: CaptureResult, primaryTitle: String, onDone: @escaping (String, String?) -> Void, onCancel: @escaping () -> Void) {
        self.result = result
        self.primaryTitle = primaryTitle
        self.onDone = onDone
        self.onCancel = onCancel
        _style = State(initialValue: result.style)
    }

    private var isFormatted: Bool { !showsRaw && result.layout != nil }

    private var text: String {
        guard isFormatted, let layout = result.layout else { return result.rawText }
        return LayoutRenderer.text(layout.blocks, style: style)
    }

    private var html: String? {
        guard isFormatted, let layout = result.layout else { return nil }
        return LayoutRenderer.html(layout.blocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(.tint)
                Text(result.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }

            if result.layout != nil {
                HStack(spacing: 12) {
                    Picker("Version", selection: $showsRaw) {
                        Text("Formatted").tag(false)
                        Text(result.isStack ? "As copied" : "As read").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)

                    if isFormatted {
                        Picker("Style", selection: $style) {
                            Text("Plain").tag(LayoutRenderer.Style.plain)
                            Text("Markdown").tag(LayoutRenderer.Style.markdown)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Spacer()
                }
            }

            ScrollView {
                Text(text)
                    .font(isFormatted && style == .markdown
                          ? .system(size: 12.5, design: .monospaced)
                          : .system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Text(isFormatted
                     ? (result.isStack
                        ? "Only the layout differs from what you copied, plus the fixes chosen in Settings."
                        : "Only the layout differs from what was read, plus the fixes chosen in Settings.")
                     : (result.isStack ? "Exactly as copied, as Paste Stack gives it." : "Exactly as recognised."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) {
                    onDone(text, html)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .padding(.top, 14)
        .frame(minWidth: 520, minHeight: 380)
    }
}
