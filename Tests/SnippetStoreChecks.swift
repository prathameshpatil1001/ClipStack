//
//  SnippetStoreChecks.swift
//  ClipStack tests
//
//  Guards the saved-text library against being overwritten. A store that could
//  not load must never write — what it holds is an empty list, not the user's
//  library — and the rescue from the old shared `default.store` must only read.
//

import Foundation
import SQLite3

@MainActor
enum SnippetStoreChecks {

    static func run() async -> Int {
        let runner = CheckRunner(suite: "SnippetStore")
        let defaults = UserDefaults(suiteName: "ClipStackChecks-\(UUID().uuidString)")!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipStackChecks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A library that cannot be read is left byte-for-byte alone.
        let fileURL = directory.appendingPathComponent("snippets.json")
        let unreadable = Data("not json".utf8)
        try? unreadable.write(to: fileURL)
        let blocked = SnippetStore(persistence: JSONSnippetPersistence(directory: directory), defaults: defaults)
        runner.check("unreadable library opens read-only", blocked.isReadOnly)
        runner.check("load failure is reported", blocked.lastErrorMessage != nil)
        blocked.add(title: "new", body: "typed while broken", tags: [])
        runner.check("add is refused while read-only", blocked.snippets.isEmpty)
        runner.check("unreadable file is not overwritten", (try? Data(contentsOf: fileURL)) == unreadable)

        // Once the file is readable again, Retry recovers.
        try? JSONSnippetPersistence(directory: directory).save([Snippet(title: "kept", body: "kept body")])
        blocked.reload()
        runner.check("reload recovers once readable", !blocked.isReadOnly)
        runner.check("recovered library is loaded", blocked.snippets.map(\.title), equals: ["kept"])

        // An edit applies only the edited fields to the live snippet.
        let store = SnippetStore(persistence: InMemoryPersistence(), defaults: defaults)
        store.add(title: "greeting", body: "hello", tags: [])
        let opened = store.snippets[0]          // what the editor sheet captured
        store.markUsed(opened)                  // recalled while the sheet was open
        store.togglePin(opened)
        store.update(id: opened.id, title: "greeting", body: "hello there", tags: [])
        let edited = store.snippets[0]
        runner.check("edit keeps a recall made meanwhile", edited.useCount, equals: 1)
        runner.check("edit keeps a pin made meanwhile", edited.isPinned)
        runner.check("edit applies the new body", edited.body, equals: "hello there")

        // Legacy import reads SwiftData's layout without touching the file.
        let legacyURL = directory.appendingPathComponent("default.store")
        let id = UUID()
        runner.check("legacy fixture builds", makeLegacyStore(at: legacyURL, id: id, tags: ["work", "email"]))
        let before = try? Data(contentsOf: legacyURL)
        let imported = LegacyDefaultStoreReader.readSnippets(at: legacyURL)
        runner.check("legacy snippet is read", imported.map(\.id), equals: [id])
        runner.check("legacy fields decode", imported.first.map { "\($0.title)|\($0.body)|\($0.useCount)|\($0.isPinned)" } ?? "", equals: "title|body|3|true")
        runner.check("legacy tags decode", imported.first?.tags ?? [], equals: ["work", "email"])
        runner.check("legacy store is not modified", (try? Data(contentsOf: legacyURL)) == before)

        let foreignURL = directory.appendingPathComponent("foreign.store")
        runner.check("foreign fixture builds", execute(at: foreignURL, "CREATE TABLE ZMAILACCOUNT (Z_PK INTEGER PRIMARY KEY);"))
        runner.check("another app's schema yields nothing", LegacyDefaultStoreReader.readSnippets(at: foreignURL).isEmpty)
        runner.check("absent legacy store yields nothing",
                     LegacyDefaultStoreReader.readSnippets(at: directory.appendingPathComponent("absent.store")).isEmpty)

        return runner.failures
    }

    /// A `default.store` shaped the way SwiftData wrote `SnippetRecord`.
    private static func makeLegacyStore(at url: URL, id: UUID, tags: [String]) -> Bool {
        guard let archive = try? NSKeyedArchiver.archivedData(withRootObject: tags as NSArray, requiringSecureCoding: true) else {
            return false
        }
        func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        let idHex = withUnsafeBytes(of: id.uuid) { hex($0) }
        return execute(at: url, """
            CREATE TABLE ZSNIPPETRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
                ZISPINNED INTEGER, ZUSECOUNT INTEGER, ZCREATEDAT TIMESTAMP, ZLASTUSEDAT TIMESTAMP,
                ZUPDATEDAT TIMESTAMP, ZTEXT VARCHAR, ZTITLE VARCHAR, ZID BLOB, ZTAGS BLOB);
            INSERT INTO ZSNIPPETRECORD VALUES (1, 1, 1, 1, 3, 800000000, NULL, 800000100,
                'body', 'title', X'\(idHex)', X'\(hex(archive))');
            """)
    }

    private static func execute(at url: URL, _ sql: String) -> Bool {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }
}

@MainActor
private final class InMemoryPersistence: SnippetPersistence {
    private var stored: [Snippet] = []
    func load() throws -> [Snippet] { stored }
    func save(_ snippets: [Snippet]) throws { stored = snippets }
}
