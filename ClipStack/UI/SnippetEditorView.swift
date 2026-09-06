//
//  SnippetEditorView.swift
//  ClipStack
//
//  Add / edit form for a saved text. Title and tags are optional; the body is
//  required, which is what gates the Save button.
//

import SwiftUI

struct SnippetEditorView: View {
    /// `nil` when creating a new snippet.
    let snippet: Snippet?
    let onSave: (_ title: String, _ body: String, _ tags: [String]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var bodyText: String
    @State private var tagText: String

    init(snippet: Snippet?, onSave: @escaping (String, String, [String]) -> Void) {
        self.snippet = snippet
        self.onSave = onSave
        _title = State(initialValue: snippet?.title ?? "")
        _bodyText = State(initialValue: snippet?.body ?? "")
        _tagText = State(initialValue: (snippet?.tags ?? []).joined(separator: ", "))
    }

    private var canSave: Bool {
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet == nil ? "New Saved Text" : "Edit Saved Text")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Optional", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Text").font(.caption).foregroundStyle(.secondary)
                    Text("Required").font(.caption2).foregroundStyle(.tertiary)
                }
                TextEditor(text: $bodyText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                TextField("Optional, comma separated", text: $tagText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(title, bodyText, Self.parseTags(tagText))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private static func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
