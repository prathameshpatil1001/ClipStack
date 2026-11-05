//
//  ProfileStore.swift
//  ClipStack
//
//  The user's profile: details ClipStack can fill into templates and commands.
//
//  Stored locally and nowhere else — never synced to iCloud. Ordinary details
//  live in ~/Library/Application Support/ClipStack/Profile.json; a secret's
//  value lives in the Keychain (see KeychainSecretStore), and the file holds
//  only its name.
//

import Foundation
import Combine

/// Where secret values are kept. The Keychain in the app; memory in tests.
protocol SecretStore {
    func read(_ id: UUID) -> String?
    @discardableResult func write(_ value: String, for id: UUID) -> Bool
    func delete(_ id: UUID)
}

@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var facts: [ProfileFact] = []
    @Published private(set) var lastErrorMessage: String?

    private let fileURL: URL
    private let secrets: SecretStore

    /// Nonisolated because it is a default argument, which Swift evaluates
    /// outside the main actor. It only asks FileManager for a path.
    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("ClipStack", isDirectory: true)
            .appendingPathComponent("Profile.json")
    }

    init(fileURL: URL = ProfileStore.defaultFileURL, secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        load()
    }

    // MARK: - Reading

    /// The real value: from the Keychain for a secret, from the file otherwise.
    func value(of fact: ProfileFact) -> String {
        fact.isSecret ? (secrets.read(fact.id) ?? "") : fact.value
    }

    /// Group names in the order they first appear, "Me" first.
    var groups: [String] {
        var ordered: [String] = []
        for fact in facts where !ordered.contains(fact.group) {
            ordered.append(fact.group)
        }
        if let me = ordered.firstIndex(of: ProfileFact.personalGroup), me > 0 {
            ordered.insert(ordered.remove(at: me), at: 0)
        }
        return ordered
    }

    func facts(in group: String) -> [ProfileFact] {
        facts.filter { $0.group == group }
    }

    // MARK: - Editing

    /// Adds a detail, or updates the one with the same group and label.
    @discardableResult
    func upsert(group: String, label: String, value: String, isSecret: Bool) -> ProfileFact {
        let cleanGroup = Self.clean(group).isEmpty ? ProfileFact.personalGroup : Self.clean(group)
        let cleanLabel = Self.clean(label)
        let probe = ProfileFact(group: cleanGroup, label: cleanLabel, value: "")

        if let existing = facts.first(where: { $0.identityKey == probe.identityKey }) {
            // Same detail: keep the names it already has, change the value.
            return update(existing, group: existing.group, label: existing.label, value: value, isSecret: isSecret)
        }

        var fact = ProfileFact(group: cleanGroup, label: cleanLabel, value: "", isSecret: isSecret)
        store(value, in: &fact)
        facts.append(fact)
        save()
        return fact
    }

    /// Changes a detail. `value: nil` keeps the current value, even when the
    /// detail moves between the file and the Keychain.
    @discardableResult
    func update(_ fact: ProfileFact, group: String, label: String, value: String?, isSecret: Bool) -> ProfileFact {
        guard let index = facts.firstIndex(where: { $0.id == fact.id }) else { return fact }
        let current = facts[index]
        let newValue = value ?? self.value(of: current)

        var updated = current
        updated.group = Self.clean(group).isEmpty ? ProfileFact.personalGroup : Self.clean(group)
        updated.label = Self.clean(label)
        updated.isSecret = isSecret
        updated.updatedAt = Date()

        if current.isSecret && !isSecret {
            secrets.delete(current.id)
        }
        store(newValue, in: &updated)

        facts[index] = updated
        save()
        return updated
    }

    func delete(ids: Set<UUID>) {
        for fact in facts where ids.contains(fact.id) && fact.isSecret {
            secrets.delete(fact.id)
        }
        facts.removeAll { ids.contains($0.id) }
        save()
    }

    /// Writes a value where it belongs: the Keychain for a secret (leaving the
    /// file entry empty), the fact itself otherwise.
    private func store(_ value: String, in fact: inout ProfileFact) {
        if fact.isSecret {
            if secrets.write(value, for: fact.id) {
                fact.value = ""
            } else {
                lastErrorMessage = "Couldn't save “\(fact.label)” to the Keychain."
                fact.value = ""
            }
        } else {
            fact.value = value
        }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON

    /// The profile as editable JSON. A secret's value is included only when
    /// asked for; otherwise its entry has no value, which on import means
    /// "keep what the Keychain has".
    func exportJSON(includingSecrets: Bool) -> String {
        let document = ProfileDocument(facts: facts.map { fact in
            ProfileDocument.Entry(
                group: fact.group,
                label: fact.label,
                value: fact.isSecret ? (includingSecrets ? value(of: fact) : nil) : fact.value,
                secret: fact.isSecret ? true : nil
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document), let text = String(data: data, encoding: .utf8) else {
            return #"{ "facts": [] }"#
        }
        return text
    }

    enum ImportError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "That isn't profile JSON: \(detail)"
            }
        }
    }

    /// Reads profile JSON.
    /// - Parameter replacingAll: true for the JSON editor, where removing an
    ///   entry means deleting that detail; false for importing a file, which
    ///   only adds and updates.
    func importJSON(_ text: String, replacingAll: Bool) throws {
        let document: ProfileDocument
        do {
            document = try JSONDecoder().decode(ProfileDocument.self, from: Data(text.utf8))
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }

        var keep = Set<UUID>()
        for entry in document.facts {
            let label = Self.clean(entry.label)
            guard !label.isEmpty else { continue }
            let isSecret = entry.secret ?? false
            let probe = ProfileFact(group: entry.group, label: label, value: "")

            if let existing = facts.first(where: { $0.identityKey == probe.identityKey }) {
                let updated = update(existing, group: entry.group, label: label, value: entry.value, isSecret: isSecret)
                keep.insert(updated.id)
            } else {
                let added = upsert(group: entry.group, label: label, value: entry.value ?? "", isSecret: isSecret)
                keep.insert(added.id)
            }
        }

        if replacingAll {
            delete(ids: Set(facts.map(\.id)).subtracting(keep))
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            facts = try JSONDecoder().decode([ProfileFact].self, from: data)
        } catch {
            // Set the unreadable file aside rather than overwrite it with an
            // empty profile on the next save.
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            lastErrorMessage = "Your profile file couldn't be read. It was kept as \(aside.lastPathComponent)."
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(facts).write(to: fileURL, options: [.atomic])
        } catch {
            lastErrorMessage = "Couldn't save your profile: \(error.localizedDescription)"
        }
    }
}

/// Secrets kept in memory, for tests.
final class InMemorySecretStore: SecretStore {
    private var values: [UUID: String] = [:]

    func read(_ id: UUID) -> String? { values[id] }

    @discardableResult
    func write(_ value: String, for id: UUID) -> Bool {
        values[id] = value
        return true
    }

    func delete(_ id: UUID) { values[id] = nil }

    var count: Int { values.count }
}
