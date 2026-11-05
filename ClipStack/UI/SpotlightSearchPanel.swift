//
//  SpotlightSearchPanel.swift
//  ClipStack
//
//  The ⌥Space recall panel: a floating, centred search field with a live-ranked
//  list of saved texts and saved websites beneath it. ↩ on a text pastes it;
//  ↩ on a website opens it in its browser and profile. ⌘1…⌘9 pick a row directly.
//
//  ⌘↩ switches to AI edit mode: the clipboard (or the highlighted saved text)
//  becomes the text being edited, and the field takes instructions — "fill in
//  my details", "add my PRN at the end". See AIEditSession.
//
//  It is modelled on macOS Spotlight, including the parts that are easy to miss:
//
//   • It opens as a bare search field. `FuzzySearchEngine` answers an empty
//     query with the whole library — right for the management window's filter,
//     wrong here, where it would throw every saved text onto the screen of
//     whatever the user was doing the instant a hotkey is pressed.
//   • The field and the results are two separate glass shapes: a capsule, and
//     a rounded card that appears under it once there is something to show.
//   • Nothing moves except the card. The field stays exactly where it opened.
//
//  How that last point is achieved matters. An earlier version resized the
//  window to fit its results. The hosting view resized it too (it reports an
//  intrinsic size), from the bottom edge, so for a frame or two the panel
//  jumped up or down before the top-anchored resize put it back; and the window
//  shadow, recomputed from a frame in flux, flashed a rectangular outline. Now
//  the window is a fixed, fully transparent canvas sized for the largest list,
//  with no window shadow of its own; SwiftUI draws both shapes inside it and
//  animates only the card. A click on the empty part closes the panel, as a
//  click anywhere outside Spotlight does.
//
//  Two more AppKit details:
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

/// Shared by the view and the window controller, so the drawing and the window
/// it lives in can never disagree about where things are.
enum PanelMetrics {
    static let width: CGFloat = 640

    /// The search capsule.
    static let fieldHeight: CGFloat = 64

    /// Between the capsule and the results card.
    static let gap: CGFloat = 10

    static let rowHeight: CGFloat = 50
    static let emptyRowHeight: CGFloat = 50
    static let maximumVisibleRows = 7
    /// Inside the card, above the first row and below the last.
    static let cardPadding: CGFloat = 7
    static let cardCornerRadius: CGFloat = 26
    static let rowCornerRadius: CGFloat = 13

    /// Transparent margin around the shapes, so their shadows are not clipped
    /// by the window edge.
    static let shadowMargin: CGFloat = 36

    /// How far down the screen the field sits, as a fraction of the visible
    /// height — Spotlight's proportion, which reads as "upper third".
    static let topInsetFraction: CGFloat = 0.20

    static let resizeDuration: TimeInterval = 0.2
    static let revealDuration: TimeInterval = 0.14

    static var fieldShape: Capsule { Capsule(style: .continuous) }

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    /// Height of the results card for this many rows (0 = the "nothing
    /// matches" row).
    static func cardHeight(resultCount: Int) -> CGFloat {
        let rows = resultCount == 0
            ? emptyRowHeight
            : CGFloat(min(resultCount, maximumVisibleRows)) * rowHeight
        return rows + cardPadding * 2
    }

    /// The window never changes size: room for the field, the tallest card,
    /// and the shadow margin all round.
    static var windowSize: NSSize {
        NSSize(
            width: width + shadowMargin * 2,
            height: shadowMargin + fieldHeight + gap + cardHeight(resultCount: maximumVisibleRows) + shadowMargin
        )
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

    /// Drives the open and close animation of the panel's content.
    @Published var isRevealed = false

    /// Set while ⌘↩ edit mode is on; nil in ordinary search.
    @Published private(set) var editSession: AIEditSession?

    private let store: SnippetStore
    private let websites: WebsiteStore
    private let profile: ProfileStore
    private let clipboard: ClipboardManager

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

    init(store: SnippetStore, websites: WebsiteStore, profile: ProfileStore, clipboard: ClipboardManager) {
        self.store = store
        self.websites = websites
        self.profile = profile
        self.clipboard = clipboard
    }

    /// Starts editing `text` with AI. The search field becomes the
    /// instruction field.
    func beginEditing(_ text: String, title: String) {
        editSession?.cancel()
        query = ""
        editSession = AIEditSession(text: text, sourceTitle: title, profile: profile, clipboard: clipboard)
    }

    func endEditing() {
        editSession?.cancel()
        editSession = nil
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
    }

    /// Reloads from the store and clears the field — called each time the panel
    /// opens so it never shows a stale query or a since-deleted snippet.
    func reset() {
        endEditing()
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

    /// ⌘1…⌘9: the row whose shortcut was pressed, if there is one.
    func selectRow(withShortcutNumber number: Int) -> Bool {
        let index = number - 1
        guard results.indices.contains(index) else { return false }
        selectedIndex = index
        return true
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

    /// Tracked separately from `panel.isVisible`: the window stays visible for
    /// the length of its fade-out, and must not answer "yes" to the hotkey then.
    private var isPresented = false

    /// The app that was frontmost when the panel opened, so focus can go back.
    private var previouslyActiveApp: NSRunningApplication?

    /// Shows the "Copied ✓" confirmation.
    var onHUD: ((String, String) -> Void)?

    init(
        store: SnippetStore,
        websites: WebsiteStore,
        profile: ProfileStore,
        clipboard: ClipboardManager,
        preferences: Preferences
    ) {
        self.viewModel = RecallViewModel(store: store, websites: websites, profile: profile, clipboard: clipboard)
        self.clipboard = clipboard
        self.preferences = preferences
        super.init()
    }

    var isVisible: Bool { isPresented }

    // MARK: Show / hide

    func toggle() {
        isVisible ? close(restoringFocus: true) : show()
    }

    func show() {
        // Remember who had focus before we steal it.
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        // Before anything is on screen: empty field, no results.
        viewModel.reset()

        let panel = existingOrNewPanel()
        isPresented = true
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
        // Whatever the last step produced is already on the clipboard; a step
        // still running is abandoned.
        viewModel.editSession?.cancel()

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
            previouslyActiveApp.activate(options: [])
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
                if let notice = try await BrowserLauncher.open(website) {
                    onHUD?(notice, "info.circle.fill")
                }
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
        viewModel.markUsed(snippet)      // feeds the useCount / recency boosts
        paste(text: snippet.body, autoPaste: preferences.recallAutoPaste)
    }

    /// Puts `text` on the clipboard, closes, and (if `autoPaste`) types ⌘V
    /// into the app the user came from.
    private func paste(text: String, autoPaste: Bool) {
        clipboard.write(text)

        // Captured before closing, which clears it.
        let targetApp = previouslyActiveApp
        close(restoringFocus: true)

        guard autoPaste else {
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

    // MARK: AI edit mode

    /// ⌘↩ — edit what is in the field (pasted or typed), a saved text found by
    /// a short search, or, with an empty field, the clipboard. See EditSource.
    private func beginEditing() {
        var highlighted: (title: String, body: String)?
        if viewModel.hasQuery, case .snippet(let snippet)? = viewModel.selectedItem {
            highlighted = (snippet.displayTitle, snippet.body)
        }

        guard let choice = EditSource.choose(
            typed: viewModel.query,
            clipboard: clipboard.readString(),
            highlighted: highlighted
        ) else {
            onHUD?("Paste or type some text, then ⌘↩ to edit it", "doc.on.clipboard")
            return
        }
        viewModel.beginEditing(choice.text, title: choice.title)
    }

    /// Keys while editing. ↩ sends the instruction, ⌥↩ Quick fill, ⌘↩ pastes
    /// the result into the app the user came from, ⌘Z steps back, Esc closes
    /// (the result is already on the clipboard).
    private func handleEditKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, session: AIEditSession) -> NSEvent? {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if modifiers == .command {
                paste(text: session.text, autoPaste: true)
            } else if modifiers == .option {
                session.quickFill()
            } else if modifiers == .shift {
                session.submit(remember: false)
            } else if modifiers.isEmpty {
                session.submit(remember: true)
            } else {
                return event
            }
            return nil
        case kVK_Escape:
            close(restoringFocus: true)
            return nil
        case kVK_ANSI_Z where modifiers == .command && session.instruction.isEmpty:
            session.undo()
            return nil
        default:
            return event
        }
    }

    // MARK: Window

    private func existingOrNewPanel() -> SpotlightPanel {
        if let panel { return panel }

        let panel = SpotlightPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: the window is a fixed transparent canvas, and its
        // shadow would trace that rectangle (or, while the content changes, a
        // stale outline of it). The shapes draw their own shadows.
        panel.hasShadow = false
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
        // The window's size is ours, not the content's: never let the hosting
        // view resize it.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: PanelMetrics.windowSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    /// Centred horizontally, the field sitting in the upper third — where
    /// Spotlight puts itself — on whichever screen has the mouse.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let fieldTop = visible.maxY - visible.height * PanelMetrics.topInsetFraction
        panel.setFrame(NSRect(
            x: visible.midX - PanelMetrics.windowSize.width / 2,
            y: fieldTop + PanelMetrics.shadowMargin - PanelMetrics.windowSize.height,
            width: PanelMetrics.windowSize.width,
            height: PanelMetrics.windowSize.height
        ), display: false)
    }

    /// Clicking somewhere else dismisses the panel, matching Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        guard isPresented else { return }
        close(restoringFocus: false)
    }

    // MARK: Keyboard

    /// Arrow keys, Return, ⌘↩, Escape and ⌘1…⌘9 are intercepted before the
    /// text field sees them — otherwise ↑/↓ would just move the insertion point.
    /// A *local* monitor only sees events already routed to ClipStack, so it
    /// needs no special permission and cannot observe other apps.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }

            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])

            if let session = self.viewModel.editSession {
                return self.handleEditKey(event, modifiers: modifiers, session: session)
            }

            let keyCode = Int(event.keyCode)
            if modifiers == .command, keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
                self.beginEditing()
                return nil
            }

            if modifiers == .command,
               let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
               (1...9).contains(digit) {
                if self.viewModel.selectRow(withShortcutNumber: digit) {
                    self.activateSelection()
                }
                return nil
            }

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
        VStack(spacing: PanelMetrics.gap) {
            if let session = viewModel.editSession {
                EditInstructionField(session: session, isFocused: $isFieldFocused)
                AIEditCard(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                searchField

                if viewModel.hasQuery {
                    resultsCard
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        )
                }
            }
        }
        .frame(width: PanelMetrics.width)
        .animation(.easeOut(duration: PanelMetrics.resizeDuration), value: viewModel.hasQuery)
        .animation(.easeOut(duration: PanelMetrics.resizeDuration), value: viewModel.editSession == nil)
        // Opens the way Spotlight does: a short fade with the panel settling
        // into place from slightly small.
        .scaleEffect(viewModel.isRevealed ? 1 : 0.97, anchor: .top)
        .opacity(viewModel.isRevealed ? 1 : 0)
        .animation(.easeOut(duration: PanelMetrics.revealDuration), value: viewModel.isRevealed)
        .padding(PanelMetrics.shadowMargin)
        // Pinned to the top of the fixed window, so the field never moves.
        .frame(
            width: PanelMetrics.windowSize.width,
            height: PanelMetrics.windowSize.height,
            alignment: .top
        )
        // The rest of the window is invisible; clicking there means "elsewhere".
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
        }
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
        .onChange(of: viewModel.editSession == nil) { _ in
            // Switching mode swaps the text field; the new one needs focus.
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("Search — or paste text and ⌘↩ to edit it", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($isFieldFocused)
                .onSubmit(onActivate)
        }
        .padding(.horizontal, 26)
        .frame(height: PanelMetrics.fieldHeight)
        .frame(maxWidth: .infinity)
        .contentShape(PanelMetrics.fieldShape)
        .glassSurface(in: PanelMetrics.fieldShape)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    // MARK: Results

    private var resultsCard: some View {
        Group {
            if viewModel.results.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .padding(.vertical, PanelMetrics.cardPadding)
        .frame(height: PanelMetrics.cardHeight(resultCount: viewModel.results.count), alignment: .top)
        .frame(maxWidth: .infinity)
        .clipShape(PanelMetrics.cardShape)
        .contentShape(PanelMetrics.cardShape)
        .glassSurface(in: PanelMetrics.cardShape)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .animation(.easeOut(duration: PanelMetrics.resizeDuration), value: viewModel.results.count)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: viewModel.results.count > PanelMetrics.maximumVisibleRows) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        SpotlightResultRow(
                            item: result.item,
                            shortcutNumber: index < 9 ? index + 1 : nil,
                            isSelected: index == viewModel.selectedIndex,
                            namespace: selectionNamespace
                        )
                        .id(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            onActivate()
                        }
                        // Only a pointer that actually moved counts, or the
                        // keyboard would lose every argument with a resting mouse.
                        .onHover { hovering in
                            if hovering { viewModel.pointerEntered(row: index) }
                        }
                    }
                }
                .animation(.easeOut(duration: 0.12), value: viewModel.selectedIndex)
            }
            .onChange(of: viewModel.selectedIndex) { newValue in
                guard viewModel.results.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.results[newValue].id)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .frame(width: 26)
            Text("No results for \u{201C}\(viewModel.query)\u{201D}")
                .lineLimit(1)
            Spacer()
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .frame(height: PanelMetrics.emptyRowHeight)
    }
}

private struct SpotlightResultRow: View {
    let item: RecallItem
    let shortcutNumber: Int?
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.truncated(to: 70))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle.truncated(to: 90))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let shortcutNumber {
                Text("\u{2318}\(shortcutNumber)")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.rowHeight)
        .background {
            // A soft wash, as Spotlight does, rather than a solid accent bar.
            if isSelected {
                RoundedRectangle(cornerRadius: PanelMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .matchedGeometryEffect(id: "spotlight.selection", in: namespace)
            }
        }
        .padding(.horizontal, PanelMetrics.cardPadding)
    }

    private var symbolName: String {
        switch item {
        case .snippet(let snippet): return snippet.isPinned ? "pin" : "doc.text"
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
                ? nil
                : BrowserLauncher.label(for: website.browser)
        }
    }
}

// MARK: - AI edit mode

/// The field in edit mode: what is being edited, and the instruction.
struct EditInstructionField: View {
    @ObservedObject var session: AIEditSession
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.tint)

            Text(session.sourceTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.1)))
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            // Return is handled by the panel's key monitor, so no onSubmit here.
            TextField(session.fieldPrompt, text: $session.instruction)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused(isFocused)

            if session.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 26)
        .frame(height: PanelMetrics.fieldHeight)
        .frame(maxWidth: .infinity)
        .contentShape(PanelMetrics.fieldShape)
        .glassSurface(in: PanelMetrics.fieldShape)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

/// The text being edited, with the last step's changes marked: added text
/// in green, removed text struck through in red, placeholders still to fill
/// in orange, and details ClipStack is asking for in purple.
struct AIEditCard: View {
    @ObservedObject var session: AIEditSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Equatable, so typing an instruction (which republishes the
                // session) doesn't mark the whole text up again.
                MarkedEditText(
                    text: session.text,
                    segments: session.segments,
                    showsChanges: session.showsChanges && session.hasChanges,
                    looksLikeCode: session.looksLikeCode
                )
                .equatable()
            }

            Divider().opacity(0.5)

            footer
        }
        .frame(height: PanelMetrics.cardHeight(resultCount: PanelMetrics.maximumVisibleRows))
        .frame(maxWidth: .infinity)
        .clipShape(PanelMetrics.cardShape)
        .contentShape(PanelMetrics.cardShape)
        .glassSurface(in: PanelMetrics.cardShape)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 16)

            Text(session.status.message)
                .font(.system(size: 12))
                .foregroundStyle(statusStyle)
                .lineLimit(2)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if session.hasChanges {
                Button(session.showsChanges ? "Clean" : "Changes") {
                    session.showsChanges.toggle()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(session.showsChanges ? "Show the result without markings" : "Mark what the last step changed")
            }

            Text("⌥↩ Quick fill · ⌘↩ Paste · ⌘Z Undo · Esc Done")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info:
            Image(systemName: "sparkles").foregroundStyle(.secondary)
        }
    }

    private var statusStyle: AnyShapeStyle {
        if case .problem = session.status { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.secondary)
    }
}

/// The text being edited, marked up: added text in green, removed text struck
/// through in red, placeholders still to fill in orange, details ClipStack is
/// asking for in purple.
private struct MarkedEditText: View, Equatable {
    let text: String
    let segments: [DiffSegment]
    let showsChanges: Bool
    let looksLikeCode: Bool

    var body: some View {
        Text(attributedText)
            .font(looksLikeCode ? .system(size: 13, design: .monospaced) : .system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
    }

    private typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
    private typealias Foreground = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
    private typealias Strikethrough = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute

    private var attributedText: AttributedString {
        guard showsChanges else { return markingPlaceholders(text) }
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .same(let part):
                result += markingPlaceholders(part)
            case .inserted(let part):
                var run = AttributedString(part)
                run[Background.self] = Color.green.opacity(0.28)
                result += run
            case .removed(let part):
                var run = AttributedString(part)
                run[Strikethrough.self] = .single
                run[Foreground.self] = Color.red.opacity(0.85)
                run[Background.self] = Color.red.opacity(0.1)
                result += run
            }
        }
        return result
    }

    /// Placeholders in orange; ClipStack's own ⟦gaps⟧ in purple.
    private func markingPlaceholders(_ text: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for range in PlaceholderDetector.ranges(in: text) {
            result += AttributedString(String(text[cursor..<range.lowerBound]))
            let placeholder = String(text[range])
            var run = AttributedString(placeholder)
            let tint: Color = placeholder.hasPrefix("⟦") ? .purple : .orange
            run[Background.self] = tint.opacity(0.22)
            run[Foreground.self] = tint
            result += run
            cursor = range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }
}
