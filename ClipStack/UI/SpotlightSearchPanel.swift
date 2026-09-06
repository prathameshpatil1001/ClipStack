//
//  SpotlightSearchPanel.swift
//  ClipStack
//
//  The ⌥Space recall panel: a floating, centred, borderless, always-on-top
//  window with one text field and a live-ranked result list.
//
//  Two AppKit details make this work:
//
//   • A borderless NSWindow cannot become key by default, so the text field
//     would never accept typing. `SpotlightPanel` overrides `canBecomeKey`.
//   • ClipStack is an LSUIElement app and is not frontmost when the hotkey
//     fires, so we must activate explicitly — and hand focus back to the app the
//     user came from when the panel closes, or they are left staring at a
//     desktop with no active app.
//

import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine

// MARK: - Panel

final class SpotlightPanel: NSPanel {
    /// Borderless panels return false by default; without this the search field
    /// can never receive keystrokes.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View model

@MainActor
final class RecallViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { refreshResults() }
    }
    @Published private(set) var results: [SnippetSearchResult] = []
    @Published var selectedIndex: Int = 0

    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
        refreshResults()
    }

    var selectedSnippet: Snippet? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex].snippet
    }

    func refreshResults() {
        results = store.search(query)
        // Any change to the result set puts the highlight back on the best match.
        selectedIndex = results.isEmpty ? 0 : 0
    }

    /// Reloads from the store and clears the field — called each time the panel
    /// opens so it never shows a stale query or a since-deleted snippet.
    func reset() {
        query = ""
        refreshResults()
    }

    // Wrap-around navigation: at the bottom, ↓ returns to the top.
    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        selectedIndex = ((selectedIndex + offset) % count + count) % count
    }

    func markUsed(_ snippet: Snippet) {
        store.markUsed(snippet)
    }
}

// MARK: - Controller

@MainActor
final class SpotlightSearchPanelController: NSObject, NSWindowDelegate {

    private var panel: SpotlightPanel?
    private let viewModel: RecallViewModel
    private let clipboard: ClipboardManager
    private let preferences: Preferences
    private var keyMonitor: Any?

    /// The app that was frontmost when the panel opened, so focus can go back.
    private var previouslyActiveApp: NSRunningApplication?

    /// Shows the "Copied ✓" confirmation.
    var onHUD: ((String, String) -> Void)?

    private let panelWidth: CGFloat = 620

    init(store: SnippetStore, clipboard: ClipboardManager, preferences: Preferences) {
        self.viewModel = RecallViewModel(store: store)
        self.clipboard = clipboard
        self.preferences = preferences
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Show / hide

    func toggle() {
        isVisible ? close(restoringFocus: true) : show()
    }

    func show() {
        // Remember who had focus before we steal it.
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        viewModel.reset()

        let panel = existingOrNewPanel()
        positionOnActiveScreen(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installKeyMonitor()
    }

    func close(restoringFocus: Bool) {
        removeKeyMonitor()
        panel?.orderOut(nil)

        guard restoringFocus else { return }
        // Return the user to whatever they were doing. Without this, closing the
        // panel leaves ClipStack "active" with no window, which reads as broken.
        if let previouslyActiveApp, previouslyActiveApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previouslyActiveApp.activate()
        } else {
            NSApp.hide(nil)
        }
        previouslyActiveApp = nil
    }

    /// Enter on the highlighted result: copy it and, if auto-paste is on, put it
    /// straight into the app the user came from.
    private func activateSelection() {
        guard let snippet = viewModel.selectedSnippet else { return }

        clipboard.write(snippet.body)
        viewModel.markUsed(snippet)      // feeds the useCount / recency boosts

        // Captured before closing, which clears it.
        let targetApp = previouslyActiveApp
        close(restoringFocus: true)

        guard preferences.recallAutoPaste else {
            onHUD?("Copied ✓", "checkmark.circle.fill")
            return
        }

        Task { @MainActor in
            // Waits for `targetApp` to be frontmost again before typing, since
            // closing the panel hands focus back asynchronously.
            let pasted = await PasteSimulator.pasteIntoFrontmostApp(afterActivating: targetApp)
            if pasted {
                onHUD?("Pasted ✓", "checkmark.circle.fill")
            } else {
                // Auto-paste needs Accessibility. The text is on the clipboard
                // either way, so degrade to a manual paste rather than failing.
                onHUD?("Copied ✓ — press ⌘V", "doc.on.clipboard")
            }
        }
    }

    // MARK: Window

    private func existingOrNewPanel() -> SpotlightPanel {
        if let panel { return panel }

        let panel = SpotlightPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 88),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        let root = SpotlightSearchView(
            viewModel: viewModel,
            onActivate: { [weak self] in self?.activateSelection() },
            onCancel: { [weak self] in self?.close(restoringFocus: true) }
        )
        let hostingView = NSHostingView(rootView: root)
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    /// Centred horizontally, sitting in the upper third — where Spotlight puts
    /// itself — on whichever screen has the mouse.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let height = panel.frame.height
        let origin = NSPoint(
            x: visible.midX - panelWidth / 2,
            y: visible.maxY - height - visible.height * 0.20
        )
        panel.setFrameOrigin(origin)
    }

    /// Clicking somewhere else dismisses the panel, matching Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        close(restoringFocus: false)
    }

    // MARK: Keyboard

    /// Arrow keys, Return and Escape are intercepted before the text field sees
    /// them — otherwise ↑/↓ would just move the insertion point inside the field.
    /// A *local* monitor only sees events already routed to ClipStack, so it
    /// needs no special permission and cannot observe other apps.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }

            switch Int(event.keyCode) {
            case kVK_DownArrow:
                self.viewModel.moveSelection(by: 1)
                return nil
            case kVK_UpArrow:
                self.viewModel.moveSelection(by: -1)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.activateSelection()
                return nil
            case kVK_Escape:
                self.close(restoringFocus: true)
                return nil
            // ⌃N / ⌃P as emacs-style alternatives to the arrows.
            case kVK_ANSI_N where event.modifierFlags.contains(.control):
                self.viewModel.moveSelection(by: 1)
                return nil
            case kVK_ANSI_P where event.modifierFlags.contains(.control):
                self.viewModel.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

// MARK: - View

struct SpotlightSearchView: View {
    @ObservedObject var viewModel: RecallViewModel
    let onActivate: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFieldFocused: Bool

    private let rowHeight: CGFloat = 52
    private let maximumVisibleRows = 7

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if !viewModel.results.isEmpty {
                Divider()
                resultList
            } else if !viewModel.query.isEmpty {
                Divider()
                emptyState
            }
        }
        .background(.regularMaterial)   // follows Dark/Light Mode automatically
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            // The window must be key before a SwiftUI field can take focus, and
            // that happens a beat after the view is built.
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)

            TextField("Search saved texts\u{2026}", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .light))
                .focused($isFieldFocused)
                .onSubmit(onActivate)

            if !viewModel.results.isEmpty {
                Text("\(viewModel.selectedIndex + 1) of \(viewModel.results.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        SpotlightResultRow(
                            snippet: result.snippet,
                            isSelected: index == viewModel.selectedIndex
                        )
                        .id(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture { 
                            viewModel.selectedIndex = index
                            onActivate()
                        }
                        // Hovering moves the highlight, so mouse and keyboard
                        // never disagree about what Return will do.
                        .onHover { hovering in
                            if hovering { viewModel.selectedIndex = index }
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(viewModel.results.count), CGFloat(maximumVisibleRows)) * rowHeight)
            .onChange(of: viewModel.selectedIndex) { newValue in
                guard viewModel.results.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.results[newValue].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
            Text("No saved text matches “\(viewModel.query)”")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 18)
        .frame(height: 52)
    }
}

private struct SpotlightResultRow: View {
    let snippet: Snippet
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: snippet.isPinned ? "pin.fill" : "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.displayTitle.truncated(to: 70))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(snippet.preview.truncated(to: 90))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !snippet.tags.isEmpty {
                Text(snippet.tags.prefix(2).joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }

            if isSelected {
                Text("↩")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(isSelected ? Color.accentColor : .clear)
    }
}
