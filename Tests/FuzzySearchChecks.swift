//
//  FuzzySearchChecks.swift
//  ClipStack tests
//
//  Locks in the ranking contract of FuzzySearchEngine: match tiers beat each
//  other in a fixed order, and the usage/recency boosts reorder within a tier
//  without ever promoting a weak match past a strong one.
//

import Foundation

enum FuzzySearchChecks {

    static func run() -> Int {
        let runner = CheckRunner(suite: "FuzzySearchEngine")
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

        let library = [
            Snippet(title: "Email signature", body: "Best regards,\nPrathamesh",
                    tags: ["work"], lastUsedAt: ago(1), useCount: 5),
            Snippet(title: "Meeting agenda", body: "1. Status\n2. Blockers", tags: ["work"]),
            Snippet(title: "Home address", body: "221B Baker Street, London", tags: ["personal"]),
            Snippet(title: "SSH public key", body: "ssh-ed25519 AAAAC3Nza email@example.com", tags: ["dev"]),
            Snippet(title: "Résumé blurb", body: "Senior engineer with ten years", tags: []),
        ]

        func top(_ query: String, in list: [Snippet] = library) -> String {
            FuzzySearchEngine.search(query, in: list, now: now).first?.snippet.displayTitle ?? "-"
        }

        runner.check("prefix match wins", top("em"), equals: "Email signature")
        runner.check("word-prefix match", top("sig"), equals: "Email signature")
        runner.check("body-only match is found", top("baker"), equals: "Home address")
        runner.check("character subsequence", top("sshk"), equals: "SSH public key")
        runner.check("tag match", top("personal"), equals: "Home address")
        runner.check("diacritics fold", top("resume"), equals: "Résumé blurb")
        runner.check("no match returns nothing",
                     FuzzySearchEngine.search("zzqq", in: library, now: now).count, equals: 0)

        // Pinned is a guarantee, not a nudge: it outranks a much better text match.
        var pinnedLibrary = library
        pinnedLibrary[2].isPinned = true      // "Home address", irrelevant to "e"
        runner.check("pinned always first", top("e", in: pinnedLibrary), equals: "Home address")

        // An empty query is the resting list: everything, most useful first.
        let resting = FuzzySearchEngine.search("", in: library, now: now)
        runner.check("empty query returns everything", resting.count, equals: library.count)
        runner.check("empty query is ordered by usefulness",
                     resting.first?.snippet.displayTitle ?? "-", equals: "Email signature")

        runner.check("useCount breaks a tie", top("report", in: [
            Snippet(title: "Report template", body: "x", useCount: 0),
            Snippet(title: "Report summary", body: "x", lastUsedAt: now, useCount: 30),
        ]), equals: "Report summary")

        runner.check("recency breaks a tie", top("notes", in: [
            Snippet(title: "Notes alpha", body: "x", lastUsedAt: ago(365), useCount: 4),
            Snippet(title: "Notes beta", body: "x", lastUsedAt: now, useCount: 4),
        ]), equals: "Notes beta")

        // The property that keeps ranking predictable as a library ages.
        runner.check("match tier beats any boost", top("email", in: [
            Snippet(title: "zzz contains an e late", body: "x", lastUsedAt: now, useCount: 999),
            Snippet(title: "Email", body: "x", useCount: 0),
        ]), equals: "Email")

        return runner.failures
    }
}
