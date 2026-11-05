//
//  SwiftDataSnippetPersistence.swift
//  ClipStack
//
//  The SwiftData backend, used on macOS 14+. See SnippetPersistence.swift for
//  why there is a second, non-SwiftData path.
//
//  Everything here is gated on `@available(macOS 14, *)`; the framework is
//  weak-linked so macOS 13 never loads it.
//

import Foundation
import SwiftData

/// Persistent record. Mirrors `Snippet` one-to-one.
///
/// `text` rather than `body` avoids any confusion with SwiftUI's `body` when
/// reading the model alongside views; it maps to `Snippet.body`.
@available(macOS 14, *)
@Model
final class SnippetRecord {
    /// Unique so re-saving an existing snippet updates rather than duplicates.
    @Attribute(.unique) var id: UUID
    var title: String
    var text: String
    var tags: [String]
    var createdAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var isPinned: Bool
    /// Added after the first release. The default value lets SwiftData migrate
    /// an existing store without a schema migration plan.
    var updatedAt: Date = Date()

    init(
        id: UUID,
        title: String,
        text: String,
        tags: [String],
        createdAt: Date,
        lastUsedAt: Date?,
        useCount: Int,
        isPinned: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.tags = tags
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.updatedAt = updatedAt
    }

    convenience init(snippet: Snippet) {
        self.init(
            id: snippet.id,
            title: snippet.title,
            text: snippet.body,
            tags: snippet.tags,
            createdAt: snippet.createdAt,
            lastUsedAt: snippet.lastUsedAt,
            useCount: snippet.useCount,
            isPinned: snippet.isPinned,
            updatedAt: snippet.updatedAt
        )
    }

    var snippet: Snippet {
        Snippet(
            id: id,
            title: title,
            body: text,
            tags: tags,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            updatedAt: updatedAt
        )
    }

    func apply(_ snippet: Snippet) {
        title = snippet.title
        text = snippet.body
        tags = snippet.tags
        createdAt = snippet.createdAt
        lastUsedAt = snippet.lastUsedAt
        useCount = snippet.useCount
        isPinned = snippet.isPinned
        updatedAt = snippet.updatedAt
    }
}

@available(macOS 14, *)
@MainActor
final class SwiftDataSnippetPersistence: SnippetPersistence {

    /// ~/Library/Application Support/ClipStack/Snippets.store
    nonisolated static var defaultStoreURL: URL {
        SnippetStorageLocation.directory.appendingPathComponent("Snippets.store")
    }

    private let container: ModelContainer

    /// - Parameters:
    ///   - storeURL: Always explicit. With no URL, an unsandboxed app's store
    ///     lands on `Application Support/default.store`, which other processes
    ///     open as well (see LegacyDefaultStoreReader.swift).
    ///   - legacyStoreURL: Imported from once, when `storeURL` is first created.
    init(
        storeURL: URL = SwiftDataSnippetPersistence.defaultStoreURL,
        legacyStoreURL: URL? = LegacyDefaultStoreReader.defaultURL
    ) throws {
        let isNewStore = !FileManager.default.fileExists(atPath: storeURL.path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // `.none`: sync goes through iCloud key-value storage (CloudSyncCoordinator),
        // never CloudKit, whatever entitlements a build happens to carry.
        let configuration = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        container = try ModelContainer(for: SnippetRecord.self, configurations: configuration)

        if isNewStore, let legacyStoreURL {
            importLegacySnippets(from: legacyStoreURL)
        }
    }

    /// Best effort: the legacy file is only ever read, so a failure here loses
    /// nothing that was not already stranded there.
    private func importLegacySnippets(from url: URL) {
        let legacy = LegacyDefaultStoreReader.readSnippets(at: url)
        guard !legacy.isEmpty else { return }
        do {
            try save(legacy)
            NSLog("ClipStack: imported %d saved texts from %@", legacy.count, url.path)
        } catch {
            NSLog("ClipStack: could not import saved texts from %@: %@", url.path, error.localizedDescription)
        }
    }

    private var context: ModelContext { container.mainContext }

    func load() throws -> [Snippet] {
        let descriptor = FetchDescriptor<SnippetRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor).map(\.snippet)
    }

    /// Reconciles the store with `snippets`: update in place, insert what is new,
    /// delete what is gone. The whole-array shape keeps the protocol simple, and
    /// the record counts involved make the diff cost irrelevant.
    func save(_ snippets: [Snippet]) throws {
        let existing = try context.fetch(FetchDescriptor<SnippetRecord>())
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for snippet in snippets {
            if let record = byID.removeValue(forKey: snippet.id) {
                record.apply(snippet)
            } else {
                context.insert(SnippetRecord(snippet: snippet))
            }
        }

        // Anything still in `byID` was deleted by the user.
        for orphan in byID.values {
            context.delete(orphan)
        }

        try context.save()
    }
}

// MARK: - Backend selection

@MainActor
enum SnippetPersistenceFactory {

    /// SwiftData on macOS 14+, the JSON file on macOS 13.
    ///
    /// A SwiftData store that fails to open does *not* fall back to JSON: that
    /// would show an empty library, save new texts somewhere the next successful
    /// launch never reads, and look exactly like data loss. The store goes
    /// read-only and reports the error instead.
    static func makeDefault() -> (persistence: SnippetPersistence, description: String) {
        if #available(macOS 14, *) {
            do {
                return (try SwiftDataSnippetPersistence(), "SwiftData")
            } catch {
                return (UnavailableSnippetPersistence(error: error), "SwiftData (could not open)")
            }
        }
        return (JSONSnippetPersistence(), "JSON file")
    }
}
