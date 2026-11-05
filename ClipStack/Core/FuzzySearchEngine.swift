//
//  FuzzySearchEngine.swift
//  ClipStack
//
//  Ranking for the ⌥Space recall panel, which searches saved texts and saved
//  websites together.
//
//  Match quality is tiered, strongest first:
//    1. prefix        — the field starts with the query
//    2. word prefix   — a word inside the field starts with the query
//    3. substring     — the query appears anywhere
//    4. subsequence   — the query's characters appear in order with gaps
//
//  A title hit always outranks the same tier of body hit. On top of the match
//  score we add usage and recency boosts, and pinned snippets are lifted above
//  everything else by sorting on `isPinned` first — a pin is a hard guarantee,
//  not a score nudge that a very good text match could overtake.
//

import Foundation

struct SnippetSearchResult: Identifiable, Hashable {
    let snippet: Snippet
    let score: Double
    var id: UUID { snippet.id }
}

struct WebsiteSearchResult: Identifiable, Hashable {
    let website: Website
    let score: Double
    var id: UUID { website.id }
}

/// One row of the recall panel: a saved text or a saved website.
enum RecallItem: Identifiable, Hashable {
    case snippet(Snippet)
    case website(Website)

    nonisolated var id: UUID {
        switch self {
        case .snippet(let snippet): return snippet.id
        case .website(let website): return website.id
        }
    }

    /// Pinned snippets stay on top of everything, websites included.
    nonisolated var isPinned: Bool {
        if case .snippet(let snippet) = self { return snippet.isPinned }
        return false
    }

    nonisolated var title: String {
        switch self {
        case .snippet(let snippet): return snippet.displayTitle
        case .website(let website): return website.displayName
        }
    }
}

struct RecallResult: Identifiable, Hashable {
    let item: RecallItem
    let score: Double
    var id: UUID { item.id }
}

enum FuzzySearchEngine {

    // Match tiers. The gaps are wide so a boost can reorder within a tier but
    // never promote a weak match past a strong one.
    private enum Tier {
        nonisolated static let prefix: Double     = 1000
        nonisolated static let wordPrefix: Double = 700
        nonisolated static let substring: Double  = 450
        nonisolated static let subsequence: Double = 200   // plus up to ~150 for match quality
    }

    /// A body hit counts for less than the same hit in the title.
    private nonisolated static let bodyWeight: Double = 0.55
    private nonisolated static let tagWeight: Double = 0.75

    /// Ranks `snippets` against `query`.
    /// An empty query returns the "resting" list: pinned, then most useful.
    nonisolated static func search(
        _ query: String,
        in snippets: [Snippet],
        limit: Int = 50,
        now: Date = Date()
    ) -> [SnippetSearchResult] {

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            let resting = snippets
                .map { SnippetSearchResult(snippet: $0, score: usefulnessBoost(for: $0, now: now)) }
                .sorted(by: ordering)
            return Array(resting.prefix(limit))
        }

        let needle = normalize(trimmed)
        let needleChars = Array(needle)

        let scored: [SnippetSearchResult] = snippets.compactMap { snippet in
            guard let match = matchScore(needle: needle, needleChars: needleChars, snippet: snippet) else {
                return nil
            }
            return SnippetSearchResult(
                snippet: snippet,
                score: match + usefulnessBoost(for: snippet, now: now)
            )
        }

        return Array(scored.sorted(by: ordering).prefix(limit))
    }

    /// Ranks `websites` against `query` by name, host, address and the
    /// profile it opens in, with the same tiers as snippets. An empty query
    /// matches nothing: websites only ever appear in answer to typing.
    nonisolated static func search(
        _ query: String,
        in websites: [Website],
        limit: Int = 50
    ) -> [WebsiteSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let needle = normalize(trimmed)
        let needleChars = Array(needle)

        let scored: [WebsiteSearchResult] = websites.compactMap { website in
            var best: Double?
            func consider(_ field: String?, weight: Double) {
                guard let field,
                      let value = fieldScore(needle: needle, needleChars: needleChars, field: field)
                else { return }
                let weighted = value * weight
                if best == nil || weighted > best! { best = weighted }
            }

            consider(website.name, weight: 1.0)
            // "git" should find github.com as a prefix, not via "www.".
            consider(website.url?.host.map(stripWWW), weight: hostWeight)
            consider(website.address, weight: bodyWeight)
            // "work" finds the sites that open in the Work profile.
            consider(website.browser.profileName, weight: tagWeight)

            guard let best else { return nil }
            return WebsiteSearchResult(website: website, score: best)
        }

        return Array(scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.website.displayName.localizedCaseInsensitiveCompare(rhs.website.displayName) == .orderedAscending
        }.prefix(limit))
    }

    /// The panel's list: snippets and websites in one ranking. Pinned snippets
    /// first, as always; after that the better match wins, whichever kind it is.
    nonisolated static func merge(
        snippets: [SnippetSearchResult],
        websites: [WebsiteSearchResult],
        limit: Int = 50
    ) -> [RecallResult] {
        let combined = snippets.map { RecallResult(item: .snippet($0.snippet), score: $0.score) }
            + websites.map { RecallResult(item: .website($0.website), score: $0.score) }

        return Array(combined.sorted { lhs, rhs in
            if lhs.item.isPinned != rhs.item.isPinned { return lhs.item.isPinned }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
        }.prefix(limit))
    }

    /// A host hit is nearly as telling as a name hit.
    private nonisolated static let hostWeight: Double = 0.9

    private nonisolated static func stripWWW(_ host: String) -> String {
        host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Ordering

    /// Pinned first (always), then score, then a stable alphabetical tiebreak so
    /// the list never shuffles between identical-scoring runs.
    private nonisolated static func ordering(_ lhs: SnippetSearchResult, _ rhs: SnippetSearchResult) -> Bool {
        if lhs.snippet.isPinned != rhs.snippet.isPinned { return lhs.snippet.isPinned }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.snippet.displayTitle.localizedCaseInsensitiveCompare(rhs.snippet.displayTitle) == .orderedAscending
    }

    // MARK: - Match scoring

    /// Best score across title, body and tags, or `nil` if nothing matched.
    private nonisolated static func matchScore(needle: String, needleChars: [Character], snippet: Snippet) -> Double? {
        var best: Double?

        func consider(_ value: Double?, weight: Double) {
            guard let value else { return }
            let weighted = value * weight
            if best == nil || weighted > best! { best = weighted }
        }

        consider(fieldScore(needle: needle, needleChars: needleChars, field: snippet.title), weight: 1.0)
        consider(fieldScore(needle: needle, needleChars: needleChars, field: snippet.body), weight: bodyWeight)

        for tag in snippet.tags {
            consider(fieldScore(needle: needle, needleChars: needleChars, field: tag), weight: tagWeight)
        }

        return best
    }

    /// Scores one field, strongest applicable tier wins.
    private nonisolated static func fieldScore(needle: String, needleChars: [Character], field: String) -> Double? {
        guard !field.isEmpty else { return nil }
        let haystack = normalize(field)
        guard !haystack.isEmpty else { return nil }

        // Shorter fields matching the same query are more specific, so a small
        // length bonus separates "Email" from a paragraph that mentions email.
        let brevityBonus = 60.0 / (1.0 + Double(haystack.count) / 40.0)

        if haystack.hasPrefix(needle) {
            return Tier.prefix + brevityBonus
        }

        if let range = haystack.range(of: needle) {
            let startsWord = range.lowerBound == haystack.startIndex
                || isWordBreak(haystack[haystack.index(before: range.lowerBound)])
            return (startsWord ? Tier.wordPrefix : Tier.substring) + brevityBonus
        }

        if let quality = subsequenceQuality(needleChars: needleChars, haystack: Array(haystack)) {
            return Tier.subsequence + quality * 150 + brevityBonus * 0.5
        }

        return nil
    }

    /// Do the query's characters appear in order inside `haystack`?
    ///
    /// Returns a 0…1 quality score: runs of consecutive matches and matches that
    /// start a word score high, scattered matches score low. `nil` means the
    /// characters are not all present in order, i.e. no match at all.
    private nonisolated static func subsequenceQuality(needleChars: [Character], haystack: [Character]) -> Double? {
        guard !needleChars.isEmpty, needleChars.count <= haystack.count else { return nil }

        var needleIndex = 0
        var earnedPoints = 0.0
        var previousMatchPosition = -1

        for (position, character) in haystack.enumerated() {
            guard needleIndex < needleChars.count else { break }
            guard character == needleChars[needleIndex] else { continue }

            var points = 1.0
            if position == previousMatchPosition + 1 {
                points += 1.0     // consecutive run: the strongest signal
            }
            if position == 0 || isWordBreak(haystack[position - 1]) {
                points += 0.75    // landed on a word start
            }
            earnedPoints += points
            previousMatchPosition = position
            needleIndex += 1
        }

        guard needleIndex == needleChars.count else { return nil }

        // Normalize against the best possible run of this length.
        let maximumPoints = Double(needleChars.count) * 2.75
        let quality = earnedPoints / maximumPoints

        // Matches packed near the start of the field read as more relevant.
        let spread = Double(previousMatchPosition + 1) / Double(haystack.count)
        return max(0, min(1, quality * (1.0 - 0.3 * spread)))
    }

    private nonisolated static func isWordBreak(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol || character == "_"
    }

    // MARK: - Boosts

    /// How much a snippet earns from being used often and recently. Bounded so
    /// it can reorder results inside a tier but never jump a tier.
    private nonisolated static func usefulnessBoost(for snippet: Snippet, now: Date) -> Double {
        // Diminishing returns: the 2nd use matters far more than the 40th.
        let frequency = min(120.0, 40.0 * log(1.0 + Double(snippet.useCount)))

        guard let lastUsedAt = snippet.lastUsedAt else { return frequency }

        // Half-life decay: full credit today, ~half after a week, ~nothing after
        // a couple of months.
        let daysAgo = max(0, now.timeIntervalSince(lastUsedAt) / 86_400)
        let recency = 120.0 * pow(0.5, daysAgo / 7.0)
        return frequency + recency
    }

    // MARK: - Normalization

    /// Case- and accent-insensitive so "resume" finds "Résumé".
    private nonisolated static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: .current)
    }
}
