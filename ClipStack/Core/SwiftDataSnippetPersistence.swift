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

    private let container: ModelContainer

    init() throws {
        // Default on-disk store under Application Support. Throwing here is what
        // triggers SnippetStore's fallback to the JSON backend.
        container = try ModelContainer(for: SnippetRecord.self)
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
