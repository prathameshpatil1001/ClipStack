//
//  SavedTextsWindow.swift
//  ClipStack
//
//  The saved-snippet management window, plus a small window controller shared
//  with Settings. ClipStack has no Dock icon and no main window, so windows are
//  created on demand and must explicitly activate the app to come to the front.
//

import AppKit
import SwiftUI

/// Hosts a SwiftUI root view in a normal, closable window.
///
/// The class is deliberately *not* generic — only its initializer is. A generic
/// NSObject subclass here made the Swift 6.3 SIL optimizer crash while compiling
/// the synthesized deinit under whole-module optimization (Release builds only).
/// Keeping the view type confined to the initializer sidesteps that and keeps
/// call sites free of AnyView wrappers.
@MainActor
final class SwiftUIWindowController: NSWindowController, NSWindowDelegate {

    private let onClose: (() -> Void)?

    init<Content: View>(
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        window.isReleasedWhenClosed = false   // we keep the controller alive and reuse it
        window.center()
        window.setFrameAutosaveName("ClipStack.\(title)")
        if let minSize { window.minSize = minSize }

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Brings the window forward, activating the app first — an LSUIElement app
    /// is never frontmost on its own.
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Root view

struct SavedTextsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: SnippetStore

    @State private var filter: String = ""
    @State private var selection: Set<UUID> = []
    @State private var editorTarget: EditorTarget?

    /// `nil` body means "new snippet"; otherwise we are editing an existing one.
    private enum EditorTarget: Identifiable {
        case new
        case existing(Snippet)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let snippet): return snippet.id.uuidString
            }
        }
    }

    private var visibleSnippets: [Snippet] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.sortedForManagement }
        // Same ranking engine as the recall panel, so filtering here behaves
        // exactly like ⌥Space.
        return store.search(trimmed).map(\.snippet)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = store.lastErrorMessage {
                errorBanner(error)
            }

            if store.isReadOnly {
                // Not "No saved texts yet": they may well exist, just unread.
                Spacer()
            } else if store.snippets.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                SnippetEditorView(snippet: nil) { title, body, tags in
                    store.add(title: title, body: body, tags: tags)
                }
            case .existing(let snippet):
                SnippetEditorView(snippet: snippet) { title, body, tags in
                    store.update(id: snippet.id, title: title, body: body, tags: tags)
                }
            }
        }
    }

    // MARK: Sections

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                editorTarget = .new
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("Add a saved text")
            .disabled(store.isReadOnly)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 260)

            Spacer()

            Text("\(store.snippets.count) saved · \(environment.preferences.recallHotKey.displayString) to recall")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(visibleSnippets) { snippet in
                SnippetRow(snippet: snippet)
                    .tag(snippet.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editorTarget = .existing(snippet) }
                    // Trackpad swipe to delete, as specified.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.delete(snippet)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(snippet.isPinned ? "Unpin" : "Pin") {
                            store.togglePin(snippet)
                        }
                        Button("Edit\u{2026}") { editorTarget = .existing(snippet) }
                        Button("Copy") { ClipboardManager.shared.write(snippet.body) }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(snippet) }
                    }
            }
        }
        .listStyle(.inset)
        // Delete key on the current selection — only the rows on screen. Rows
        // selected before the filter hid them must not be deleted unseen.
        .onDeleteCommand {
            store.delete(ids: selection.intersection(visibleSnippets.map(\.id)))
            selection = []
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.book.closed")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No saved texts yet")
                .font(.headline)
            Text("Add the things you retype often, then press \(environment.preferences.recallHotKey.displayString) anywhere to find them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Add Saved Text") { editorTarget = .new }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if store.isReadOnly {
                Button("Retry") { store.reload() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Row

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: snippet.isPinned ? "pin.fill" : "doc.text")
                .foregroundStyle(snippet.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.displayTitle.truncated(to: 80))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(snippet.preview.truncated(to: 120))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !snippet.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(snippet.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if snippet.useCount > 0 {
                    Text("used \(snippet.useCount)×")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(snippet.createdAt, style: .date)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
