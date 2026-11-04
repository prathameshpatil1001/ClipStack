//
//  SpotlightSearchPanel.swift
//  ClipStack
//
//  The ⌥Space recall panel: a floating, centred, borderless, always-on-top
//  window with one text field and a live-ranked result list of saved texts and
//  saved websites. ↩ on a text pastes it; ↩ on a website opens it in its browser
//  and profile.
//
//  It is modelled on Spotlight, including the parts that are easy to miss:
//
//   • It opens as a bare search field. `FuzzySearchEngine` answers an empty
//     query with the whole library — right for the management window's filter,
//     wrong here, where it would throw every saved text onto the screen of
//     whatever the user was doing the instant a hotkey is pressed.
//   • It grows downwards into results only once there is something to show, with
//     the top edge staying exactly where it was.
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
import QuartzCore

// MARK: - Metrics

/// Shared by the view and the window controller, so the SwiftUI content and the
/// window it lives in can never disagree about how tall the panel is.
enum PanelMetrics {
    static let width: CGFloat = 640
    static let fieldHeight: CGFloat = 62
    static let rowHeight: CGFloat = 56
    static let emptyRowHeight: CGFloat = 54
    static let separatorHeight: CGFloat = 1
    static let maximumVisibleRows = 7
    static let cornerRadius: CGFloat = 26

    /// How far down the screen the panel sits, as a fraction of the visible
    /// height — Spotlight's proportion, which reads as "upper third".
    static let topInsetFraction: CGFloat = 0.20

    /// One duration for the window resize and the SwiftUI layout that rides
    /// along with it; if these drift apart the glass edge lags the content.
    static let resizeDuration: TimeInterval = 0.18
    static let revealDuration: TimeInterval = 0.14

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    static func height(resultCount: Int, hasQuery: Bool) -> CGFloat {
        guard hasQuery else { return fieldHeight }
        guard resultCount > 0 else { return fieldHeight + separatorHeight + emptyRowHeight }
        return fieldHeight + separatorHeight + CGFloat(min(resultCount, maximumVisibleRows)) * rowHeight
    }
}

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
    @Published private(set) var results: [RecallResult] = []
    @Published var selectedIndex: Int = 0

    /// Whether the field holds anything worth searching for. Everything below
    /// the field is hidden until it does.
    @Published private(set) var hasQuery: Bool = false

    /// The height the panel should have for what is on screen right now.
    @Published private(set) var panelHeight: CGFloat = PanelMetrics.fieldHeight

    /// Drives the open and close animation of the panel's content.
    @Published var isRevealed = false

    private let store: SnippetStore
    private let websites: WebsiteStore

    /// Where the pointer was the last time the selection moved for any reason
    /// other than the mouse: an arrow key, or the results changing.
    ///
    /// SwiftUI's hover callback fires whenever a row *arrives* under the
    /// pointer, not only when the pointer moves onto a row. The panel growing as
    /// results come in, the list scrolling to keep the selection visible, or the
    /// rows simply re-rendering all slide a row under a pointer that has not
    /// moved, and the hover then snatched the highlight back to that row. With
    /// the pointer resting over the results, ↑/↓ appeared to be locked. A hover
    /// now only counts once the pointer has really moved since then.
    private var pointerLocationAtLastKeyboardChange: NSPoint?

    init(store: SnippetStore, websites: WebsiteStore) {
        self.store = store
        self.websites = websites
    }

    var selectedItem: RecallItem? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex].item
    }

    func refreshResults() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hasQuery = !trimmed.isEmpty
        // An empty field shows nothing at all — see the note at the top.
        results = hasQuery
            ? FuzzySearchEngine.merge(
                snippets: store.search(trimmed),
                websites: FuzzySearchEngine.search(trimmed, in: websites.websites)
            )
            : []
        // Any change to the result set puts the highlight back on the best match.
        selectedIndex = 0
        pointerLocationAtLastKeyboardChange = NSEvent.mouseLocation
        panelHeight = PanelMetrics.height(resultCount: results.count, hasQuery: hasQuery)
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
        pointerLocationAtLastKeyboardChange = NSEvent.mouseLocation
    }

    /// The pointer entered row `index`. Ignored unless the pointer itself moved
    /// there — see `pointerLocationAtLastKeyboardChange`.
    func pointerEntered(row index: Int) {
        let pointer = NSEvent.mouseLocation
        if let anchor = pointerLocationAtLastKeyboardChange, anchor == pointer {
            return
        }
        pointerLocationAtLastKeyboardChange = nil
        guard results.indices.contains(index) else { return }
        selectedIndex = index
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
    private var cancellables = Set<AnyCancellable>()

    /// Tracked separately from `panel.isVisible`: the window stays visible for
    /// the length of its fade-out, and must not answer "yes" to the hotkey then.
    private var isPresented = false

    /// The app that was frontmost when the panel opened, so focus can go back.
    private var previouslyActiveApp: NSRunningApplication?

    /// Shows the "Copied ✓" confirmation.
    var onHUD: ((String, String) -> Void)?

    init(store: SnippetStore, websites: WebsiteStore, clipboard: ClipboardManager, preferences: Preferences) {
        self.viewModel = RecallViewModel(store: store, websites: websites)
        self.clipboard = clipboard
        self.preferences = preferences
        super.init()

        // One place decides the height, and the window follows it.
        viewModel.$panelHeight
            .removeDuplicates()
            .sink { [weak self] height in
                self?.setPanelHeight(height, animated: true)
            }
            .store(in: &cancellables)
    }

    var isVisible: Bool { isPresented }

    // MARK: Show / hide

    func toggle() {
        isVisible ? close(restoringFocus: true) : show()
    }

    func show() {
        // Remember who had focus before we steal it.
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        // Before anything is on screen: empty field, no results, collapsed.
        viewModel.reset()

        let panel = existingOrNewPanel()
        isPresented = true
        setPanelHeight(viewModel.panelHeight, animated: false)
        positionOnActiveScreen(panel)

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        viewModel.isRevealed = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMetrics.revealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installKeyMonitor()
    }

    func close(restoringFocus: Bool) {
        removeKeyMonitor()
        isPresented = false
        viewModel.isRevealed = false

        if let panel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = PanelMetrics.revealDuration * 0.8
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak panel] in
                // Skip if the panel was reopened while it was fading out.
                guard let panel, panel.alphaValue < 0.01 else { return }
                panel.orderOut(nil)
            })
        }

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

    /// Enter on the highlighted result: a website opens; a saved text is copied
    /// and, if auto-paste is on, put straight into the app the user came from.
    private func activateSelection() {
        guard let item = viewModel.selectedItem else { return }
        switch item {
        case .website(let website):
            open(website)
        case .snippet(let snippet):
            paste(snippet)
        }
    }

    /// Opens the website in its browser and profile. Focus is not handed back to
    /// the previous app first — the browser is about to take it — unless
    /// opening fails, so the user is never left in a ClipStack with no window.
    private func open(_ website: Website) {
        let returnTo = previouslyActiveApp
        close(restoringFocus: false)
        previouslyActiveApp = nil

        Task { @MainActor in
            do {
                try await BrowserLauncher.open(website)
            } catch {
                if let returnTo, returnTo.bundleIdentifier != Bundle.main.bundleIdentifier {
                    returnTo.activate(options: [])
                } else {
                    NSApp.hide(nil)
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                onHUD?(message, "exclamationmark.triangle.fill")
            }
        }
    }

    private func paste(_ snippet: Snippet) {
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
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.fieldHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws the panel's edge and shadow; a second window shadow
        // under a translucent surface reads as a grey halo.
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none   // we run the fade ourselves
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        let root = SpotlightSearchView(
            viewModel: viewModel,
            onActivate: { [weak self] in self?.activateSelection() },
            onCancel: { [weak self] in self?.close(restoringFocus: true) }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    /// Grows and shrinks from the top edge, the way Spotlight does: the field
    /// stays under the user's eyes and the results unroll beneath it.
    private func setPanelHeight(_ height: CGFloat, animated: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height

        guard animated, isPresented else {
            panel.setFrame(frame, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMetrics.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Centred horizontally, sitting in the upper third — where Spotlight puts
    /// itself — on whichever screen has the mouse.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        // Positioned by its top-left corner, so a panel that later grows taller
        // keeps this exact top edge.
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.midX - PanelMetrics.width / 2,
            y: visible.maxY - visible.height * PanelMetrics.topInsetFraction
        ))
    }

    /// Clicking somewhere else dismisses the panel, matching Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        guard isPresented else { return }
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
    /// Lets the highlight slide between rows instead of blinking from one to the
    /// next as the selection moves.
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if viewModel.hasQuery {
                Divider().opacity(0.6)
                if viewModel.results.isEmpty {
                    emptyState
                } else {
                    resultList
                }
            }
        }
        .frame(width: PanelMetrics.width, height: viewModel.panelHeight, alignment: .top)
        .clipShape(PanelMetrics.shape)
        .glassSurface(in: PanelMetrics.shape)
        // Opens the way Spotlight does: a short fade with the panel settling
        // into place from slightly small.
        .scaleEffect(viewModel.isRevealed ? 1 : 0.97, anchor: .top)
        .opacity(viewModel.isRevealed ? 1 : 0)
        .animation(.easeOut(duration: PanelMetrics.revealDuration), value: viewModel.isRevealed)
        // Matches the window's own resize, so content and glass edge move together.
        .animation(.easeOut(duration: PanelMetrics.resizeDuration), value: viewModel.panelHeight)
        .onAppear {
            // The window must be key before a SwiftUI field can take focus, and
            // that happens a beat after the view is built.
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onChange(of: viewModel.isRevealed) { revealed in
            // The panel is reused, so focus has to be taken again on each open.
            guard revealed else { return }
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("Search saved texts and websites\u{2026}", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .light))
                .focused($isFieldFocused)
                .onSubmit(onActivate)

            if !viewModel.results.isEmpty {
                Text("\(viewModel.selectedIndex + 1) of \(viewModel.results.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.fieldHeight)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        SpotlightResultRow(
                            item: result.item,
                            isSelected: index == viewModel.selectedIndex,
                            namespace: selectionNamespace
                        )
                        .id(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            onActivate()
                        }
                        // Hovering moves the highlight, so mouse and keyboard
                        // never disagree about what Return will do.
                        // Only a pointer that actually moved counts, or the
                        // keyboard would lose every argument with a resting mouse.
                        .onHover { hovering in
                            if hovering { viewModel.pointerEntered(row: index) }
                        }
                    }
                }
                .animation(.easeOut(duration: 0.13), value: viewModel.selectedIndex)
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(viewModel.results.count), CGFloat(PanelMetrics.maximumVisibleRows)) * PanelMetrics.rowHeight)
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
            Text("Nothing matches \u{201C}\(viewModel.query)\u{201D}")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.emptyRowHeight)
    }
}

private struct SpotlightResultRow: View {
    let item: RecallItem
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbolName)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.truncated(to: 70))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle.truncated(to: 90))
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }

            if isSelected {
                Text("\u{21A9}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor)
                    .matchedGeometryEffect(id: "spotlight.selection", in: namespace)
            }
        }
        .padding(.horizontal, 8)
    }

    private var symbolName: String {
        switch item {
        case .snippet(let snippet): return snippet.isPinned ? "pin.fill" : "doc.text"
        case .website: return "globe"
        }
    }

    /// The text's first line, or the website's address without the scheme.
    private var subtitle: String {
        switch item {
        case .snippet(let snippet):
            return snippet.preview
        case .website(let website):
            guard let url = website.url else { return website.address }
            let address = url.absoluteString
            if let range = address.range(of: "://") {
                return String(address[range.upperBound...])
            }
            return address
        }
    }

    /// Tags for a text; where a website opens ("Safari · Work") for a website.
    private var detail: String? {
        switch item {
        case .snippet(let snippet):
            return snippet.tags.isEmpty ? nil : snippet.tags.prefix(2).joined(separator: " · ")
        case .website(let website):
            return website.browser.bundleIdentifier == nil
                ? "Website"
                : BrowserLauncher.label(for: website.browser)
        }
    }
}
