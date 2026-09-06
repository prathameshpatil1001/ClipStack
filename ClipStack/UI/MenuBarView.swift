//
//  MenuBarView.swift
//  ClipStack
//
//  Contents of the menu bar dropdown.
//

import SwiftUI

struct MenuBarView: View {
    let actions: StatusItemController.Actions

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.vertical, 4)

            if environment.permissions.needsAnyPermission {
                permissionBanner
                Divider().padding(.vertical, 4)
            }

            stackModeToggle

            if environment.stack.isEnabled {
                StackModeView()
                    .padding(.top, 2)
                stackActions
            }

            Divider().padding(.vertical, 4)

            MenuRow(
                title: "Search Saved Texts",
                systemImage: "magnifyingglass",
                shortcut: preferences.recallHotKey.displayString,
                action: actions.openRecallPanel
            )
            MenuRow(
                title: "Saved Texts\u{2026}",
                systemImage: "text.book.closed",
                action: actions.openSavedTexts
            )

            Divider().padding(.vertical, 4)

            MenuRow(title: "Settings\u{2026}", systemImage: "gearshape", action: actions.openSettings)
            MenuRow(title: "Quit ClipStack", systemImage: "power", shortcut: "⌘Q", action: actions.quit)
        }
        .padding(8)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.3.layers.3d.top.filled")
                .foregroundStyle(.tint)
            Text("ClipStack")
                .font(.headline)
            Spacer()
            if environment.stack.isEnabled {
                Text("\(environment.stack.count) item\(environment.stack.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    /// Shown when Accessibility is off: Stack Mode's ⌘C capture cannot work, but
    /// the rest of the app still can, so this informs rather than blocks.
    private var permissionBanner: some View {
        Button(action: {
            environment.permissions.presentExplainer(isFirstLaunch: false)
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permissionBannerTitle)
                        .font(.system(size: 12, weight: .semibold))
                    Text(permissionBannerDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    /// Says what is actually missing, rather than a generic "grant access".
    private var permissionBannerTitle: String {
        environment.permissions.canObserveCopyKeystroke
            ? "Auto-paste needs Accessibility"
            : "ClipStack can't see ⌘C yet"
    }

    private var permissionBannerDetail: String {
        environment.permissions.canObserveCopyKeystroke
            ? "⌘C capture works. Grant Accessibility to let ClipStack paste for you."
            : "Grant Accessibility so ⌘C can be added to the stack. Click to open Settings."
    }

    private var stackModeToggle: some View {
        Toggle(isOn: Binding(
            get: { environment.stack.isEnabled },
            set: { environment.stack.setEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Stack Mode")
                        .font(.system(size: 13, weight: .medium))
                    if let toggleShortcut = preferences.toggleStackModeHotKey {
                        Text(toggleShortcut.displayString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(environment.stack.isEnabled
                     ? "Every ⌘C is added to the stack"
                     : "⌘C behaves normally")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var stackActions: some View {
        VStack(spacing: 0) {
            MenuRow(
                title: preferences.autoPasteEnabled ? "Paste Stack" : "Copy Stack",
                systemImage: "doc.on.clipboard",
                shortcut: preferences.pasteStackHotKey.displayString,
                isEnabled: !environment.stack.entries.isEmpty
            ) {
                environment.stack.pasteStack()
            }

            MenuRow(
                title: "Add Current Clipboard",
                systemImage: "plus.rectangle.on.rectangle",
                action: { environment.stack.appendCurrentClipboard() }
            )

            MenuRow(
                title: "Reset Stack",
                systemImage: "trash",
                shortcut: preferences.resetStackHotKey.displayString,
                isEnabled: !environment.stack.entries.isEmpty
            ) {
                environment.stack.resetStack()
            }
        }
    }
}

// MARK: - Row

/// A menu-style row: full-width hit target, hover highlight, optional shortcut.
struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering && isEnabled ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }
}
