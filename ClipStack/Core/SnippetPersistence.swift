//
//  SnippetPersistence.swift
//  ClipStack
//
//  ── A note on SwiftData and the macOS 13 deployment target ──────────────────
//  SwiftData is macOS 14+. ClipStack targets macOS 13, so it cannot be the only
//  storage path. The app therefore stores snippets behind this small protocol:
//
//    • macOS 14 and later → SwiftData (`SwiftDataSnippetPersistence`)
//    • macOS 13          → a JSON file (`JSONSnippetPersistence`)
//
//  Both produce plain `Snippet` values, so `SnippetStore` and every view are
//  identical on both systems. SwiftData.framework is weak-linked (see
//  OTHER_LDFLAGS in the project) so the app still launches on macOS 13, where
//  the framework is simply never touched.
//

import Foundation

@MainActor
protocol SnippetPersistence: AnyObject {
    func load() throws -> [Snippet]
    func save(_ snippets: [Snippet]) throws
}

// MARK: - JSON fallback (macOS 13)

/// Flat-file store used on macOS 13. Snippet counts here are small (hundreds at
/// most), so rewriting the whole file on change is simpler and safer than
/// incremental updates.
@MainActor
final class JSONSnippetPersistence: SnippetPersistence {

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipStack", isDirectory: true)

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("snippets.json")
    }

    func load() throws -> [Snippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Snippet].self, from: data)
    }

    func save(_ snippets: [Snippet]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snippets)
        // Atomic: a crash mid-write must not truncate the user's snippets.
        try data.write(to: fileURL, options: .atomic)
    }
}
