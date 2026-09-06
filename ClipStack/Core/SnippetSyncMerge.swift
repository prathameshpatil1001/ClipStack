//
//  SnippetSyncMerge.swift
//  ClipStack
//
//  The reconciliation rules for iCloud sync, kept pure and free of any store or
//  iCloud dependency so they can be reasoned about — and tested — on their own.
//
//  Two Macs edit the same library offline; when they meet, the merge has to
//  answer three questions:
//
//    • Same snippet edited in both places?  Later `updatedAt` wins.
//    • Deleted here, still present there?   The tombstone wins, unless the other
//      side edited it *after* the deletion — then the edit resurrects it, on the
//      grounds that losing a deliberate edit is worse than an unwanted revival.
//    • When can a tombstone be forgotten?   After `tombstoneLifetime`, long
//      enough that a Mac offline for weeks cannot resurrect a deleted snippet.
//

import Foundation

/// A remembered deletion. Without these, deleting on one Mac would simply be
/// undone by the next sync from a Mac that still has the snippet.
struct SnippetTombstone: Codable, Hashable, Identifiable {
    var id: UUID
    var deletedAt: Date
}

/// The whole synced library, as written to iCloud.
struct SnippetSyncPayload: Codable, Equatable {
    var formatVersion: Int
    var snippets: [Snippet]
    var tombstones: [SnippetTombstone]
    var writtenAt: Date

    static let currentFormatVersion = 1

    init(
        snippets: [Snippet],
        tombstones: [SnippetTombstone],
        writtenAt: Date = Date(),
        formatVersion: Int = SnippetSyncPayload.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.snippets = snippets
        self.tombstones = tombstones
        self.writtenAt = writtenAt
    }

    /// Would writing this produce the same bytes as that? Used both to skip
    /// redundant writes and to recognise our own write echoing back from iCloud.
    ///
    /// This compares *encoded* forms rather than the values themselves, which
    /// matters more than it looks. A `Date` in memory carries far more precision
    /// than ISO-8601 preserves, so a payload compared against its own round-trip
    /// through iCloud would report a difference that does not exist — each Mac
    /// would read the other's write as a change, merge, write back, and the two
    /// would rewrite each other indefinitely. Comparing the bytes that actually
    /// travel removes the question entirely.
    func hasSameContent(as other: SnippetSyncPayload) -> Bool {
        guard let mine = contentFingerprint(), let theirs = other.contentFingerprint() else {
            return false
        }
        return mine == theirs
    }

    /// Canonical encoding: `writtenAt` zeroed and both lists ordered by id, so
    /// neither the write time nor the order records happen to sit in can make
    /// two identical libraries look different.
    private func contentFingerprint() -> Data? {
        var canonical = self
        canonical.writtenAt = Date(timeIntervalSince1970: 0)
        canonical.snippets.sort { $0.id.uuidString < $1.id.uuidString }
        canonical.tombstones.sort { $0.id.uuidString < $1.id.uuidString }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(canonical)
    }
}

enum SnippetSyncMerge {

    /// Sixty days: comfortably longer than a Mac is realistically offline, while
    /// still keeping the payload from growing forever.
    static let tombstoneLifetime: TimeInterval = 60 * 86_400

    /// Reconciles two libraries into one. Commutative — merging A into B gives
    /// the same result as B into A, which is what makes it safe to run on both
    /// Macs independently.
    static func merge(
        _ local: SnippetSyncPayload,
        _ remote: SnippetSyncPayload,
        now: Date = Date(),
        tombstoneLifetime: TimeInterval = SnippetSyncMerge.tombstoneLifetime
    ) -> SnippetSyncPayload {

        // 1. Tombstones: union by id, keeping the most recent deletion, and
        //    forgetting any that have aged out.
        var tombstonesByID: [UUID: SnippetTombstone] = [:]
        for tombstone in local.tombstones + remote.tombstones {
            guard now.timeIntervalSince(tombstone.deletedAt) < tombstoneLifetime else { continue }
            if let existing = tombstonesByID[tombstone.id], existing.deletedAt >= tombstone.deletedAt {
                continue
            }
            tombstonesByID[tombstone.id] = tombstone
        }

        // 2. Snippets: union by id, keeping whichever side was edited last.
        var snippetsByID: [UUID: Snippet] = [:]
        for snippet in local.snippets + remote.snippets {
            if let existing = snippetsByID[snippet.id] {
                snippetsByID[snippet.id] = winner(existing, snippet)
            } else {
                snippetsByID[snippet.id] = snippet
            }
        }

        // 3. Apply deletions — except where the surviving copy was edited after
        //    the delete, in which case the edit wins and the tombstone is dropped.
        for (id, tombstone) in tombstonesByID {
            guard let snippet = snippetsByID[id] else { continue }
            if snippet.updatedAt > tombstone.deletedAt {
                tombstonesByID.removeValue(forKey: id)
            } else {
                snippetsByID.removeValue(forKey: id)
            }
        }

        // Stable order so both Macs converge on byte-identical payloads.
        let mergedSnippets = snippetsByID.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
        let mergedTombstones = tombstonesByID.values.sorted { $0.id.uuidString < $1.id.uuidString }

        return SnippetSyncPayload(snippets: mergedSnippets, tombstones: mergedTombstones, writtenAt: now)
    }

    /// Later edit wins; ties break on id so the choice is deterministic on both
    /// machines rather than depending on which side was iterated first.
    private static func winner(_ lhs: Snippet, _ rhs: Snippet) -> Snippet {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        return lhs.id.uuidString <= rhs.id.uuidString ? lhs : rhs
    }
}
