//
//  LegacyDefaultStoreReader.swift
//  ClipStack
//
//  One-time rescue of saved texts from where earlier builds kept them.
//
//  Those builds opened SwiftData with no configuration. In an unsandboxed app
//  that resolves to ~/Library/Application Support/default.store — the same path
//  every other unsandboxed process using SwiftData that way gets. At least one
//  system agent (icloudmailagent) does. Whenever either side opened the file it
//  migrated the schema to its own model, dropping the other's tables, and that
//  is how saved texts disappeared.
//
//  The file is read here with SQLite directly and strictly read-only. Opening it
//  through SwiftData would migrate it once more and destroy the other process's
//  data; it is not ClipStack's to delete either, so it is left exactly as found.
//

import Foundation
import SQLite3

enum LegacyDefaultStoreReader {

    // Nonisolated so it can serve as a default argument.
    nonisolated static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store")
    }

    /// The snippets in a legacy store — none when the file is absent, unreadable,
    /// or currently holds another process's schema.
    static func readSnippets(at url: URL = defaultURL) -> [Snippet] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }

        // Core Data's column mapping for `SnippetRecord`. When another process
        // has migrated the file the table is gone, and preparing simply fails.
        let query = """
            SELECT ZID, ZTITLE, ZTEXT, ZTAGS, ZCREATEDAT, ZLASTUSEDAT, ZUSECOUNT, ZISPINNED, ZUPDATEDAT
            FROM ZSNIPPETRECORD
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }

        var snippets: [Snippet] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuid(statement, 0), let body = text(statement, 2) else { continue }
            let createdAt = date(statement, 4) ?? Date()
            snippets.append(Snippet(
                id: id,
                title: text(statement, 1) ?? "",
                body: body,
                tags: tags(statement, 3),
                createdAt: createdAt,
                lastUsedAt: date(statement, 5),
                useCount: Int(sqlite3_column_int64(statement, 6)),
                isPinned: sqlite3_column_int64(statement, 7) != 0,
                updatedAt: date(statement, 8) ?? createdAt
            ))
        }
        return snippets
    }

    // MARK: - Column decoding

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func uuid(_ statement: OpaquePointer?, _ column: Int32) -> UUID? {
        guard let data = blob(statement, column), data.count == 16 else { return nil }
        return data.withUnsafeBytes { raw in
            NSUUID(uuidBytes: raw.bindMemory(to: UInt8.self).baseAddress) as UUID
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let characters = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: characters, count: count), as: UTF8.self)
    }

    /// Core Data stores dates as seconds since the 2001 reference date.
    private static func date(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }

    /// `[String]` attributes are written as a keyed archive.
    private static func tags(_ statement: OpaquePointer?, _ column: Int32) -> [String] {
        guard let data = blob(statement, column) else { return [] }
        let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSString.self], from: data)
        return decoded as? [String] ?? []
    }
}
