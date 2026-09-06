//
//  SyncMergeChecks.swift
//  ClipStack tests
//
//  Locks in the iCloud reconciliation rules. The three properties that matter
//  most are commutativity (both Macs reach the same answer with no leader),
//  idempotence (a merge does not create work for the next merge) and encoded
//  equality (a payload must equal its own round-trip through iCloud, or the two
//  Macs rewrite each other forever).
//

import Foundation

enum SyncMergeChecks {

    static func run() -> Int {
        let runner = CheckRunner(suite: "SnippetSyncMerge")
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        let idA = UUID(), idB = UUID(), idC = UUID()
        func snippet(_ id: UUID, _ title: String, updated: Date) -> Snippet {
            Snippet(id: id, title: title, body: "body of \(title)",
                    createdAt: ago(30), updatedAt: updated)
        }
        func titles(_ payload: SnippetSyncPayload) -> [String] {
            payload.snippets.map(\.title).sorted()
        }

        // Disjoint libraries simply combine.
        var merged = SnippetSyncMerge.merge(
            SnippetSyncPayload(snippets: [snippet(idA, "A", updated: ago(2))], tombstones: []),
            SnippetSyncPayload(snippets: [snippet(idB, "B", updated: ago(2))], tombstones: []),
            now: now
        )
        runner.check("disjoint libraries combine", titles(merged), equals: ["A", "B"])

        // Same snippet edited on both Macs: the later edit wins, once.
        merged = SnippetSyncMerge.merge(
            SnippetSyncPayload(snippets: [snippet(idA, "old", updated: ago(5))], tombstones: []),
            SnippetSyncPayload(snippets: [snippet(idA, "new", updated: ago(1))], tombstones: []),
            now: now
        )
        runner.check("later edit wins", titles(merged), equals: ["new"])
        runner.check("conflict does not duplicate", merged.snippets.count, equals: 1)

        // A deletion here must survive contact with a Mac that still has it.
        merged = SnippetSyncMerge.merge(
            SnippetSyncPayload(snippets: [], tombstones: [SnippetTombstone(id: idA, deletedAt: ago(1))]),
            SnippetSyncPayload(snippets: [snippet(idA, "A", updated: ago(5))], tombstones: []),
            now: now
        )
        runner.check("deletion propagates", merged.snippets.isEmpty, "\(titles(merged))")
        runner.check("tombstone is kept", merged.tombstones.count, equals: 1)

        // …but an edit made after the deletion resurrects it: losing a
        // deliberate edit is worse than an unwanted revival.
        merged = SnippetSyncMerge.merge(
            SnippetSyncPayload(snippets: [snippet(idA, "edited later", updated: ago(0.5))], tombstones: []),
            SnippetSyncPayload(snippets: [], tombstones: [SnippetTombstone(id: idA, deletedAt: ago(2))]),
            now: now
        )
        runner.check("later edit beats older delete", titles(merged), equals: ["edited later"])
        runner.check("superseded tombstone is dropped", merged.tombstones.isEmpty)

        // Tombstones are forgotten once no Mac could still be carrying the snippet.
        merged = SnippetSyncMerge.merge(
            SnippetSyncPayload(snippets: [], tombstones: [SnippetTombstone(id: idA, deletedAt: ago(90))]),
            SnippetSyncPayload(snippets: [], tombstones: []),
            now: now
        )
        runner.check("expired tombstone is pruned", merged.tombstones.isEmpty)

        // Commutativity and idempotence.
        let local = SnippetSyncPayload(
            snippets: [snippet(idA, "A local", updated: ago(1)), snippet(idC, "C", updated: ago(9))],
            tombstones: [SnippetTombstone(id: idB, deletedAt: ago(3))]
        )
        let remote = SnippetSyncPayload(
            snippets: [snippet(idA, "A remote", updated: ago(4)), snippet(idB, "B", updated: ago(8))],
            tombstones: []
        )
        let forward = SnippetSyncMerge.merge(local, remote, now: now)
        let backward = SnippetSyncMerge.merge(remote, local, now: now)
        runner.check("merge is commutative", forward.hasSameContent(as: backward),
                     "\(titles(forward)) vs \(titles(backward))")
        runner.check("merge result is correct", titles(forward), equals: ["A local", "C"])
        runner.check("merge is idempotent",
                     SnippetSyncMerge.merge(forward, remote, now: now).hasSameContent(as: forward))

        // Order must not affect the outcome, or two Macs would disagree.
        let reordered = SnippetSyncPayload(snippets: local.snippets.reversed(), tombstones: local.tombstones)
        runner.check("input order does not matter",
                     SnippetSyncMerge.merge(reordered, remote, now: now).hasSameContent(as: forward))

        // Content equality must ignore the write timestamp…
        runner.check("write time is not content",
                     SnippetSyncPayload(snippets: [snippet(idA, "A", updated: ago(1))],
                                        tombstones: [], writtenAt: ago(1))
                        .hasSameContent(as: SnippetSyncPayload(snippets: [snippet(idA, "A", updated: ago(1))],
                                                               tombstones: [], writtenAt: now)))

        // …and survive the exact encode/decode iCloud performs. A Date holds more
        // precision in memory than ISO-8601 keeps, so this is the check that
        // catches an endless write loop between two Macs.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? encoder.encode(forward),
           let restored = try? decoder.decode(SnippetSyncPayload.self, from: data) {
            runner.check("payload equals its own iCloud round-trip",
                         restored.hasSameContent(as: forward), "\(data.count) bytes")
        } else {
            runner.check("payload equals its own iCloud round-trip", false, "encode/decode failed")
        }

        // Snippet files written before `updatedAt` existed must still load.
        let legacy = """
        {"id":"\(idA.uuidString)","title":"Legacy","body":"x","tags":[],\
        "createdAt":751000000,"useCount":3,"isPinned":false}
        """
        if let old = try? JSONDecoder().decode(Snippet.self, from: Data(legacy.utf8)) {
            runner.check("pre-updatedAt snippet still decodes",
                         old.title == "Legacy" && old.updatedAt == old.createdAt)
        } else {
            runner.check("pre-updatedAt snippet still decodes", false, "decode threw")
        }

        return runner.failures
    }
}
