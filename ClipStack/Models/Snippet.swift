//
//  Snippet.swift
//  ClipStack
//
//  The value type the whole app works with. Persistence (SwiftData on macOS 14+,
//  a JSON file on macOS 13) converts to and from this struct, so no view or
//  controller ever has to care which storage backend is live.
//

import Foundation

struct Snippet: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var body: String
    var tags: [String]
    var createdAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var isPinned: Bool
    /// Last local edit. Drives last-writer-wins when the same snippet is changed
    /// on two Macs before iCloud reconciles them. Bumped by `SnippetStore` on
    /// every mutation, including a recall that only touches `useCount`.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String,
        tags: [String] = [],
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        isPinned: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.updatedAt = updatedAt
    }

    /// Decoded by hand so snippet files written before `updatedAt` existed still
    /// load: an absent value falls back to the creation date rather than failing
    /// the whole decode and emptying the user's library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// What to show when a snippet has no title of its own: the first non-empty
    /// line of the body, so the recall panel never renders a blank row.
    nonisolated var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// One-line preview for list rows: newlines and runs of whitespace collapsed.
    nonisolated var preview: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// The haystack the fuzzy engine scores against.
    nonisolated var searchableText: String { "\(title) \(body) \(tags.joined(separator: " "))" }
}

extension String {
    /// Shortens a string for menu rows / previews without slicing a grapheme apart.
    nonisolated func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
