//
//  StackModeView.swift
//  ClipStack
//
//  The live stack list inside the menu bar dropdown: truncated previews, an
//  individual remove button per row, and drag-to-reorder.
//

import SwiftUI

struct StackModeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    /// Keeps the dropdown a sane height; the list scrolls beyond this.
    private let maximumListHeight: CGFloat = 220

    var body: some View {
        Group {
            if environment.stack.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .foregroundStyle(.secondary)
            Text("Press ⌘C anywhere to start stacking")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    private var list: some View {
        // `.onMove` on macOS gives rows native drag-to-reorder with no edit mode.
        List {
            ForEach(Array(environment.stack.entries.enumerated()), id: \.element.id) { index, entry in
                StackRow(
                    index: index + 1,
                    entry: entry,
                    onToggleVersion: { environment.stack.toggleCapturedVersion(entry) },
                    onRemove: { environment.stack.remove(entry) }
                )
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            }
            .onMove { source, destination in
                environment.stack.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                environment.stack.remove(atOffsets: offsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(maximumListHeight, CGFloat(environment.stack.entries.count) * 30 + 8))
    }
}

private struct StackRow: View {
    let index: Int
    let entry: StackEntry
    let onToggleVersion: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)

            if let capture = entry.capture {
                Image(systemName: capture.showsRaw ? "text.alignleft" : "text.viewfinder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(capture.showsRaw ? "Read from the screen — text as read" : "Read from the screen — formatted")
            }

            Text(entry.text.replacingOccurrences(of: "\n", with: " ").truncated(to: 46))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from stack")
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { isHovering = $0 }
        .help(entry.text.truncated(to: 300))
        .contextMenu {
            if let capture = entry.capture, capture.canSwitch {
                Button(capture.showsRaw ? "Use Formatted Text" : "Use Text As Read", action: onToggleVersion)
                Divider()
            }
            Button("Remove", action: onRemove)
        }
    }
}
