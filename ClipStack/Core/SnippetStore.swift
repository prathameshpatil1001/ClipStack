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

    /// True while the library could not be loaded. Every write is refused in this
    /// state: `snippets` is then an empty list rather than the user's library, and
    /// the backends save by replacing what is on disk with the in-memory list —
    /// one keystroke would otherwise erase everything the load failed to read.
    @Published private(set) var isReadOnly = false

    /// Which backend actually loaded — surfaced in Settings for support reasons.
    let backendDescription: String

    private let persistence: SnippetPersistence
    private let cloudSync: CloudSyncCoordinator?
    private let defaults: UserDefaults

    /// Remembered deletions, so deleting on one Mac is not undone by the next
    /// sync from a Mac that still has the snippet. Persisted separately from the
    /// snippets themselves because the local backends only model live records.
    private var tombstones: [SnippetTombstone] = []

    private let tombstoneDefaultsKey = "snippetTombstones"

    /// - Parameter persistence: The backend to use. `AppEnvironment` picks it via
    ///   `SnippetPersistenceFactory`, which keeps SwiftData out of this file so
    ///   the store compiles into the logic tests.
    init(
        persistence: SnippetPersistence,
        backendDescription: String = "injected",
        cloudSync: CloudSyncCoordinator? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.backendDescription = backendDescription
        self.cloudSync = cloudSync
        self.defaults = defaults

        loadTombstones()
        reload()

        // Anything arriving from another Mac is merged, never applied blindly.
        cloudSync?.onRemotePayload = { [weak self] payload in
            self?.applyRemotePayload(payload)
        }
    }

    // MARK: - Loading

    /// Loads the library. Also the recovery path out of `isReadOnly`.
    func reload() {
        do {
            snippets = try persistence.load()
            lastErrorMessage = nil
            let wasReadOnly = isReadOnly
            isReadOnly = false
            // Anything iCloud delivered while we could not load was set aside.
            if wasReadOnly { cloudSync?.redeliverRemotePayload() }
        } catch {
            snippets = []
            isReadOnly = true
            lastErrorMessage = "Could not load saved texts: \(error.localizedDescription) Changes are paused so nothing on disk is overwritten."
        }
    }

    // MARK: - Mutations

    func add(title: String, body: String, tags: [String]) {
        guard !isReadOnly else { return }
        let snippet = Snippet(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            tags: Self.cleanTags(tags)
        )
        snippets.append(snippet)
        persist()
    }

    /// Applies an edit from the editor sheet. Takes only the edited fields, not a
    /// whole `Snippet`: the sheet's copy was captured when it opened, and writing
    /// it back would undo a recall, pin or iCloud change that landed meanwhile.
    func update(id: UUID, title: String, body: String, tags: [String]) {
        guard !isReadOnly, let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippets[index].body = body
        snippets[index].tags = Self.cleanTags(tags)
        snippets[index].updatedAt = Date()
        persist()
    }

    func delete(_ snippet: Snippet) {
        delete(ids: [snippet.id])
    }

    func delete(ids: Set<UUID>) {
        guard !isReadOnly, !ids.isEmpty else { return }
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
        guard !isReadOnly, let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].isPinned.toggle()
        snippets[index].updatedAt = Date()
        persist()
    }

    /// Called when a snippet is recalled: this is what feeds the frequency and
    /// recency boosts in `FuzzySearchEngine`.
    func markUsed(_ snippet: Snippet) {
        guard !isReadOnly, let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
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
            // An unloaded library has nothing real to seed iCloud with.
            guard !isReadOnly else { return }
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
        // Merging into a library that failed to load would save the remote copy
        // over the unread local one. `reload()` asks for a redelivery on recovery.
        guard !isReadOnly else { return }

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
