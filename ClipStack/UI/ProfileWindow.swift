//
//  ProfileWindow.swift
//  ClipStack
//
//  Your details — the facts ⌘↩ edit mode and Quick fill can put into emails,
//  forms and commands. Add them by hand, by telling ClipStack in your own
//  words (the on-device model sorts them, you approve each one), or as JSON.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @ObservedObject var store: ProfileStore

    @State private var editorTarget: EditorTarget?
    @State private var selection: Set<UUID> = []
    @State private var revealed: Set<UUID> = []

    @State private var aboutMe = ""
    @State private var isReading = false
    @State private var proposals: ProposalBatch?
    @State private var showingJSON = false
    @State private var notice: String?

    private enum EditorTarget: Identifiable {
        case new
        case existing(ProfileFact)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let fact): return fact.id.uuidString
            }
        }
    }

    struct ProposalBatch: Identifiable {
        let id = UUID()
        var items: [ProposedFact]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            tellClipStack
            Divider()

            if let message = notice ?? store.lastErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
            }

            if store.facts.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 600, minHeight: 460)
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                FactEditorView(fact: nil, value: "", groups: store.groups) { group, label, value, secret in
                    store.upsert(group: group, label: label, value: value, isSecret: secret)
                }
            case .existing(let fact):
                FactEditorView(fact: fact, value: store.value(of: fact), groups: store.groups) { group, label, value, secret in
                    store.update(fact, group: group, label: label, value: value, isSecret: secret)
                }
            }
        }
        .sheet(item: $proposals) { batch in
            ProposalReviewView(batch: batch, existing: store.facts) { accepted in
                for fact in accepted {
                    store.upsert(group: fact.group, label: fact.label, value: fact.value, isSecret: fact.isSecret)
                }
                if !accepted.isEmpty { aboutMe = "" }
                notice = accepted.isEmpty ? nil : "Saved \(accepted.count) detail\(accepted.count == 1 ? "" : "s")."
            }
        }
        .sheet(isPresented: $showingJSON) {
            ProfileJSONEditor(store: store)
        }
    }

    // MARK: Sections

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                editorTarget = .new
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a detail")

            Button("Edit as JSON\u{2026}") { showingJSON = true }

            Menu("Import / Export") {
                Button("Import JSON\u{2026}") { importFile() }
                Divider()
                Button("Export JSON\u{2026}") { exportFile(includingSecrets: false) }
                Button("Export Including Secrets\u{2026}") { exportFile(includingSecrets: true) }
            }
            .fixedSize()

            Spacer()

            Text("Stored only on this Mac · 🔒 values live in the Keychain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    /// "I have a GCloud server, IP …" → details to approve.
    private var tellClipStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tell ClipStack about you")
                .font(.system(size: 12, weight: .semibold))
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $aboutMe)
                    .font(.system(size: 12))
                    .frame(height: 54)
                    .padding(4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if aboutMe.isEmpty {
                            Text("e.g. I have a G Cloud server, its IP is 34.131.129.112 and the user is google-cloud. My project silver_algo lives at /home/google-cloud/silver_algo/ on it.")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }

                Button {
                    readDetails()
                } label: {
                    if isReading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add Details")
                    }
                }
                .disabled(isReading || aboutMe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(OnDeviceAI.unavailableReason
                 ?? "Apple's on-device model sorts what you wrote into details. You check each one before it's saved; values are only ever copied from your words.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.groups, id: \.self) { group in
                Section(group) {
                    ForEach(store.facts(in: group)) { fact in
                        FactRow(
                            fact: fact,
                            value: displayedValue(of: fact),
                            isRevealed: revealed.contains(fact.id),
                            toggleReveal: { toggleReveal(fact) }
                        )
                        .tag(fact.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editorTarget = .existing(fact) }
                        .contextMenu {
                            Button("Edit\u{2026}") { editorTarget = .existing(fact) }
                            Button("Copy Value") { ClipboardManager.shared.write(store.value(of: fact)) }
                            Divider()
                            Button("Delete", role: .destructive) { store.delete(ids: [fact.id]) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            store.delete(ids: selection)
            selection = []
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No details yet")
                .font(.headline)
            Text("Add your name, IDs, servers and project paths. Then copy a template, press ⌥Space, ⌘↩, and say “fill in my details”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func displayedValue(of fact: ProfileFact) -> String {
        guard fact.isSecret else { return fact.value }
        return revealed.contains(fact.id) ? store.value(of: fact) : "••••••••"
    }

    private func toggleReveal(_ fact: ProfileFact) {
        if revealed.contains(fact.id) {
            revealed.remove(fact.id)
        } else {
            revealed.insert(fact.id)
        }
    }

    private func readDetails() {
        let source = aboutMe
        isReading = true
        notice = nil
        Task { @MainActor in
            defer { isReading = false }
            do {
                let raw = try await OnDeviceAI.extractFacts(from: source)
                let checked = FactExtraction.verified(raw, source: source)
                if checked.isEmpty {
                    notice = "No details found in that. Try “my PRN is …” or “the server's IP is …”."
                } else {
                    proposals = ProposalBatch(items: checked)
                }
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            try store.importJSON(text, replacingAll: false)
            notice = "Imported \(url.lastPathComponent)."
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func exportFile(includingSecrets: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ClipStack Profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportJSON(includingSecrets: includingSecrets).write(to: url, atomically: true, encoding: .utf8)
            notice = includingSecrets
                ? "Exported, including secrets — keep that file somewhere safe."
                : "Exported. Secret values were left out."
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct FactRow: View {
    let fact: ProfileFact
    let value: String
    let isRevealed: Bool
    let toggleReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(fact.label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)

            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            if fact.isSecret {
                Button(action: toggleReveal) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide" : "Show")

                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Kept in the Keychain")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

private struct FactEditorView: View {
    let fact: ProfileFact?
    let groups: [String]
    let onSave: (_ group: String, _ label: String, _ value: String, _ isSecret: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var group: String
    @State private var label: String
    @State private var value: String
    @State private var isSecret: Bool
    /// A new detail's lock follows its name until the user sets it.
    @State private var secretWasChosen: Bool

    init(
        fact: ProfileFact?,
        value: String,
        groups: [String],
        onSave: @escaping (String, String, String, Bool) -> Void
    ) {
        self.fact = fact
        self.groups = groups
        self.onSave = onSave
        _group = State(initialValue: fact?.group ?? ProfileFact.personalGroup)
        _label = State(initialValue: fact?.label ?? "")
        _value = State(initialValue: value)
        _isSecret = State(initialValue: fact?.isSecret ?? false)
        _secretWasChosen = State(initialValue: fact != nil)
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(fact == nil ? "New Detail" : "Edit Detail")
                .font(.headline)

            field("Group") {
                HStack(spacing: 6) {
                    TextField("Me", text: $group)
                        .textFieldStyle(.roundedBorder)
                    if !groups.isEmpty {
                        Menu("Choose") {
                            ForEach(groups, id: \.self) { name in
                                Button(name) { group = name }
                            }
                        }
                        .fixedSize()
                    }
                }
                Text("What it belongs to: Me, a server, a project, a college…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            field("Name") {
                TextField("e.g. PRN, Host, Server path (on GCloud server)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: label) { newLabel in
                        if !secretWasChosen { isSecret = ProfileFact.looksSensitive(newLabel) }
                    }
            }

            field("Value") {
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            Toggle(isOn: Binding(
                get: { isSecret },
                set: { isSecret = $0; secretWasChosen = true }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Secret")
                    Text("Kept in the Keychain and hidden in this list. The AI never sees any value, secret or not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(group, label, value, isSecret)
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

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Reviewing what the model read

private struct ProposalReviewView: View {
    let batch: ProfileView.ProposalBatch
    let existing: [ProfileFact]
    let onSave: ([ProposedFact]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ProposedFact]
    @State private var accepted: Set<UUID>

    init(batch: ProfileView.ProposalBatch, existing: [ProfileFact], onSave: @escaping ([ProposedFact]) -> Void) {
        self.batch = batch
        self.existing = existing
        self.onSave = onSave
        _items = State(initialValue: batch.items)
        _accepted = State(initialValue: Set(batch.items.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save these details?")
                .font(.headline)
            Text("Each value was copied from what you wrote. Untick anything that's wrong; you can rename a group or a name here too.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($items) { $item in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { accepted.contains(item.id) },
                                set: { isOn in
                                    if isOn { accepted.insert(item.id) } else { accepted.remove(item.id) }
                                }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    TextField("Group", text: $item.group)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 150)
                                    Text("▸").foregroundStyle(.secondary)
                                    TextField("Name", text: $item.label)
                                        .textFieldStyle(.roundedBorder)
                                }
                                HStack(spacing: 6) {
                                    Text(item.value)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                    if item.isSecret {
                                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                    }
                                    if replacesExisting(item) {
                                        Text("updates an existing detail")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 360)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save \(accepted.count)") {
                    onSave(items.filter { accepted.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(accepted.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func replacesExisting(_ item: ProposedFact) -> Bool {
        let key = ProfileFact(group: item.group, label: item.label, value: "").identityKey
        return existing.contains { $0.identityKey == key }
    }
}

// MARK: - JSON

private struct ProfileJSONEditor: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile as JSON")
                .font(.headline)
            Text("Edit freely. A 🔒 secret appears without its value; leave it that way to keep the value, or add \"value\" to change it. Removing an entry deletes that detail.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try store.importJSON(text, replacingAll: true)
                        dismiss()
                    } catch {
                        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear { text = store.exportJSON(includingSecrets: false) }
    }
}
