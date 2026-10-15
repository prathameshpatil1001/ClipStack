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
//  ── Where the files live ────────────────────────────────────────────────────
//  Both backends keep their files in ~/Library/Application Support/ClipStack/.
//  ClipStack is not sandboxed, so Application Support is shared with every other
//  unsandboxed process on the Mac, and a generic file name written straight into
//  it can belong to someone else too. That is exactly how saved texts were lost
//  before — see LegacyDefaultStoreReader.swift.
//

import Foundation

@MainActor
protocol SnippetPersistence: AnyObject {
    func load() throws -> [Snippet]
    func save(_ snippets: [Snippet]) throws
}

enum SnippetStorageLocation {
    /// ~/Library/Application Support/ClipStack
    nonisolated static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipStack", isDirectory: true)
    }
}

// MARK: - Unavailable backend

/// Stands in when the real backend could not be opened. Every call reports the
/// original error, which puts `SnippetStore` into its read-only state — rather
/// than quietly swapping in a different, empty backend, which makes a storage
/// problem look exactly like the library having been wiped.
@MainActor
final class UnavailableSnippetPersistence: SnippetPersistence {

    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func load() throws -> [Snippet] { throw error }
    func save(_ snippets: [Snippet]) throws { throw error }
}

// MARK: - JSON fallback (macOS 13)

/// Flat-file store used on macOS 13. Snippet counts here are small (hundreds at
/// most), so rewriting the whole file on change is simpler and safer than
/// incremental updates.
@MainActor
final class JSONSnippetPersistence: SnippetPersistence {

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? SnippetStorageLocation.directory

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
