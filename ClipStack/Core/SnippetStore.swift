//
//  SnippetStore.swift
//  ClipStack
//
//  The observable source of truth for saved texts. Holds them in memory (the
//  recall panel ranks the whole set on every keystroke, so they stay hot),
//  writes through to the local backend, and — when enabled — mirrors the library
//  to iCloud so it follows the user between Macs.
//

import Foundation
import Combine

@MainActor
final class SnippetStore: ObservableObject {

    @Published private(set) var snippets: [Snippet] = []

    /// Set when persistence failed, so the UI can warn instead of silently
    /// losing the user's data.
    @Published private(set) var lastErrorMessage: String?

    /// Which backend actually loaded — surfaced in Settings for support reasons.
    private(set) var backendDescription: String = "unknown"

    private let persistence: SnippetPersistence
    private let cloudSync: CloudSyncCoordinator?
    private let defaults: UserDefaults

    /// Remembered deletions, so deleting on one Mac is not undone by the next
    /// sync from a Mac that still has the snippet. Persisted separately from the
    /// snippets themselves because the local backends only model live records.
    private var tombstones: [SnippetTombstone] = []

    private let tombstoneDefaultsKey = "snippetTombstones"

    init(
        persistence: SnippetPersistence? = nil,
        cloudSync: CloudSyncCoordinator? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.cloudSync = cloudSync
        self.defaults = defaults

        if let persistence {
            self.persistence = persistence
            self.backendDescription = "injected"
        } else if #available(macOS 14, *), let swiftData = try? SwiftDataSnippetPersistence() {
            self.persistence = swiftData
            self.backendDescription = "SwiftData"
        } else {
            // macOS 13, or a SwiftData container that refused to open.
            self.persistence = JSONSnippetPersistence()
            self.backendDescription = "JSON file"
        }

        loadTombstones()
        reload()

        // Anything arriving from another Mac is merged, never applied blindly.
        cloudSync?.onRemotePayload = { [weak self] payload in
            self?.applyRemotePayload(payload)
        }
    }

    // MARK: - Loading

    func reload() {
        do {
            snippets = try persistence.load()
            lastErrorMessage = nil
        } catch {
            snippets = []
            lastErrorMessage = "Could not load saved texts: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    func add(title: String, body: String, tags: [String]) {
        let snippet = Snippet(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            tags: Self.cleanTags(tags)
        )
        snippets.append(snippet)
        persist()
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tags = Self.cleanTags(snippet.tags)
        updated.updatedAt = Date()
        snippets[index] = updated
        persist()
    }

    func delete(_ snippet: Snippet) {
        delete(ids: [snippet.id])
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let existing = Set(snippets.map(\.id)).intersection(ids)
        guard !existing.isEmpty else { return }

        snippets.removeAll { existing.contains($0.id) }

        // Record the deletion so iCloud can carry it to the user's other Macs.
        let deletedAt = Date()
        tombstones.removeAll { existing.contains($0.id) }
        tombstones.append(contentsOf: existing.map { SnippetTombstone(id: $0, deletedAt: deletedAt) })

        persist()
    }

    func togglePin(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].isPinned.toggle()
        snippets[index].updatedAt = Date()
        persist()
    }

    /// Called when a snippet is recalled: this is what feeds the frequency and
    /// recency boosts in `FuzzySearchEngine`.
    func markUsed(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].useCount += 1
        snippets[index].lastUsedAt = Date()
        snippets[index].updatedAt = Date()
        persist()
    }

    // MARK: - Queries

    func search(_ query: String, limit: Int = 50) -> [SnippetSearchResult] {
        FuzzySearchEngine.search(query, in: snippets, limit: limit)
    }

    /// Management-window ordering: pinned first, then newest.
    var sortedForManagement: [Snippet] {
        snippets.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - iCloud

    /// The library as it would be written to iCloud.
    var syncPayload: SnippetSyncPayload {
        SnippetSyncPayload(snippets: snippets, tombstones: tombstones)
    }

    /// Turns sync on or off, seeding iCloud with what is already here.
    func setCloudSyncEnabled(_ enabled: Bool) {
        guard let cloudSync else { return }
        if enabled {
            cloudSync.start()
            cloudSync.push(syncPayload)
        } else {
            cloudSync.stop()
        }
    }

    /// Reconciles a library that arrived from another Mac.
    ///
    /// The merge is deliberately symmetric (see `SnippetSyncMerge`), so both
    /// Macs reach the same answer without a designated leader. We write back only
    /// when the merge produced something iCloud does not already hold, which is
    /// what stops two Macs from echoing each other indefinitely.
    private func applyRemotePayload(_ remote: SnippetSyncPayload) {
        let local = syncPayload
        let merged = SnippetSyncMerge.merge(local, remote)

        if !merged.hasSameContent(as: local) {
            snippets = merged.snippets
            tombstones = merged.tombstones
            saveLocally()
            saveTombstones()
        }

        if !merged.hasSameContent(as: remote) {
            cloudSync?.push(merged)
        }
    }

    // MARK: - Persistence

    private func persist() {
        pruneTombstones()
        saveLocally()
        saveTombstones()
        cloudSync?.push(syncPayload)
    }

    private func saveLocally() {
        do {
            try persistence.save(snippets)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    private func loadTombstones() {
        guard let data = defaults.data(forKey: tombstoneDefaultsKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tombstones = (try? decoder.decode([SnippetTombstone].self, from: data)) ?? []
        pruneTombstones()
    }

    private func saveTombstones() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tombstones) else { return }
        defaults.set(data, forKey: tombstoneDefaultsKey)
    }

    /// Deletions are only worth remembering for as long as another Mac could
    /// still be carrying a stale copy.
    private func pruneTombstones() {
        let now = Date()
        tombstones.removeAll { now.timeIntervalSince($0.deletedAt) >= SnippetSyncMerge.tombstoneLifetime }
    }

    private static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}
