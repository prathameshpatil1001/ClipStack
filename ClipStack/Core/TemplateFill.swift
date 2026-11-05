//
//  TemplateFill.swift
//  ClipStack
//
//  The logic behind ⌥Space's AI edit mode, kept free of AppKit and of the AI
//  itself so every rule here is covered by the logic tests.
//
//  ── The rule everything follows ─────────────────────────────────────────────
//  Nothing rewrites the user's text. Changes arrive as *edits* — "replace this
//  exact excerpt with that" — from the on-device model or from Quick fill, and
//  `EditApplier` applies only the ones it can place unambiguously. Every
//  character outside an applied edit comes through byte for byte, and the
//  `DiffSegment`s it returns show precisely what changed.
//
//  ── Details by reference, not by value ──────────────────────────────────────
//  The model is never shown the user's details. It sees their names
//  ("{{fact:2}} — GCloud server ▸ Host") and writes those tokens into its
//  edits; `FactTokens` swaps the real values in afterwards. So a secret never
//  passes through the model, and an IP address cannot come back with a digit
//  wrong. A detail the profile does not have is asked for with
//  `{{ask:PRN}}`, which becomes a visible ⟦PRN⟧ gap for the user to fill.
//

import Foundation

// MARK: - Placeholders

/// A fill-me-in marker found in a template: `<YOUR_IP>`, `[Your Name]`, …
struct TemplatePlaceholder: Hashable {
    /// Exactly as it appears in the text.
    let text: String
    /// Plain words for what it wants, e.g. "ip" for `<YOUR_IP>`.
    let label: String
}

enum PlaceholderDetector {

    /// What a fill-me-in marker looks like in AI-written templates, commands
    /// and emails. Deliberately narrow: `Array<T>`, `[link](url)`, `[INFO]`
    /// and `__init__` must not count.
    private static let patterns: [String] = [
        // <USER>, <YOUR_IP>, <your-ip>, <my_password>
        #"<(?:[A-Z][A-Z0-9_ \-]{1,40}|[Yy]our[_\- ]?[A-Za-z0-9_ \-]{1,40}|[Mm]y[_\- ][A-Za-z0-9_ \-]{1,40})>"#,
        // [Your Name], [Company] — not [INFO]-style tags, not a [markdown](link)
        #"\[(?![A-Z0-9_]+\])[A-Z][A-Za-z0-9'’_\-./ ]{1,40}\](?!\()"#,
        // {{name}}
        #"\{\{\s*[A-Za-z_][A-Za-z0-9_ .\-]{0,40}\s*\}\}"#,
        // YOUR_API_KEY
        #"\bYOUR_[A-Z0-9_]+\b"#,
        // path/to/destination, /path/to/file
        #"(?<![A-Za-z0-9_.])/?path/to/[A-Za-z0-9_./\-]*"#,
        // xxx.xxx.xxx.xxx
        #"(?<![A-Za-z0-9.])(?:[xX]{1,3}\.){3}[xX]{1,3}(?![A-Za-z0-9.])"#,
        // ______
        #"_{3,}"#,
        // ClipStack's own gap for a detail the user still has to give.
        #"⟦[^⟧\n]{1,60}⟧"#,
    ]

    /// Every placeholder occurrence, in order, without overlaps.
    static func ranges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Range<String.Index>] = []

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text), !range.isEmpty {
                    found.append(range)
                }
            }
        }

        // Earliest first, longest first; drop anything inside one already kept.
        found.sort {
            $0.lowerBound != $1.lowerBound
                ? $0.lowerBound < $1.lowerBound
                : $0.upperBound > $1.upperBound
        }
        var kept: [Range<String.Index>] = []
        for range in found where kept.last.map({ range.lowerBound >= $0.upperBound }) ?? true {
            kept.append(range)
        }
        return kept
    }

    /// Distinct placeholders, in order of first appearance.
    static func find(in text: String) -> [TemplatePlaceholder] {
        var seen = Set<String>()
        var placeholders: [TemplatePlaceholder] = []
        for range in ranges(in: text) {
            let raw = String(text[range])
            guard seen.insert(raw).inserted else { continue }
            placeholders.append(TemplatePlaceholder(text: raw, label: label(for: raw)))
        }
        return placeholders
    }

    private static let fillerWords: Set<String> = [
        "your", "my", "the", "a", "an", "insert", "enter", "here", "to", "of", "put",
    ]

    /// `<YOUR_IP>` → "ip", `[Your Name]` → "name", `path/to/destination` →
    /// "path destination", `xxx.xxx.xxx.xxx` → "ip address".
    static func label(for placeholder: String) -> String {
        if placeholder.allSatisfy({ $0 == "x" || $0 == "X" || $0 == "." }) {
            return "ip address"
        }
        if placeholder.allSatisfy({ $0 == "_" }) {
            return "blank"
        }
        let words = TemplateWords.words(in: placeholder).filter { !fillerWords.contains($0) }
        return words.joined(separator: " ")
    }
}

// MARK: - Words

enum TemplateWords {
    /// Lower-cased alphanumeric runs: "silver_algo/UI-audit" → silver, algo, ui, audit.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func wordSet(_ text: String) -> Set<String> {
        Set(words(in: text))
    }
}

// MARK: - Edits

/// "Replace this exact excerpt with that." An empty `find` appends at the end.
struct ProposedEdit: Hashable {
    var find: String
    var replace: String
}

/// One run of the result, for showing what changed.
enum DiffSegment: Hashable {
    case same(String)
    case removed(String)
    case inserted(String)
}

struct RejectedEdit: Hashable {
    enum Reason: Hashable {
        /// `find` is not in the text.
        case notFound
        /// `find` appears more than once and is not a placeholder, so which
        /// one was meant is unknowable.
        case ambiguous
        /// It would change text another edit is already changing.
        case overlapping
        /// It names a detail the model was never given.
        case unknownDetail
    }
    var edit: ProposedEdit
    var reason: Reason
}

struct EditOutcome {
    var text: String
    var segments: [DiffSegment]
    /// Edits that actually changed something.
    var appliedCount: Int
    var rejected: [RejectedEdit]
}

enum EditApplier {

    /// Applies what can be applied safely and reports the rest.
    ///
    /// - An edit applies only where its `find` occurs. If it occurs more than
    ///   once it is applied everywhere when it is a placeholder (every `<USER>`
    ///   wants the same user) and refused otherwise.
    /// - Edits are placed against the original text, earliest first; one that
    ///   overlaps an edit already placed is refused.
    /// - Everything between applied edits is copied unchanged.
    static func apply(_ edits: [ProposedEdit], to text: String) -> EditOutcome {
        typealias Operation = (range: Range<String.Index>, replacement: String, edit: ProposedEdit, order: Int)

        let placeholders = Set(PlaceholderDetector.find(in: text).map(\.text))
        var operations: [Operation] = []
        var rejected: [RejectedEdit] = []
        var seen = Set<ProposedEdit>()

        for edit in edits where seen.insert(edit).inserted {
            let order = operations.count

            if edit.find.isEmpty {
                guard !edit.replace.isEmpty else { continue }
                operations.append((text.endIndex..<text.endIndex, appendable(edit.replace, after: text), edit, order))
                continue
            }

            var find = edit.find
            var replacement = edit.replace
            var ranges = occurrences(of: find, in: text)

            // Small models sometimes add or drop whitespace at the ends of an
            // excerpt. The core must still match exactly.
            if ranges.isEmpty {
                let trimmed = find.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != find {
                    find = trimmed
                    replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    ranges = occurrences(of: find, in: text)
                }
            }

            guard !ranges.isEmpty else {
                rejected.append(RejectedEdit(edit: edit, reason: .notFound))
                continue
            }
            guard ranges.count == 1 || placeholders.contains(find) else {
                rejected.append(RejectedEdit(edit: edit, reason: .ambiguous))
                continue
            }
            for range in ranges {
                operations.append((range, replacement, edit, order))
            }
        }

        operations.sort {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound
                : $0.order < $1.order
        }

        var accepted: [Operation] = []
        var placedUpTo = text.startIndex
        var overlapping = Set<ProposedEdit>()
        for operation in operations {
            guard operation.range.lowerBound >= placedUpTo else {
                if overlapping.insert(operation.edit).inserted {
                    rejected.append(RejectedEdit(edit: operation.edit, reason: .overlapping))
                }
                continue
            }
            accepted.append(operation)
            placedUpTo = operation.range.upperBound
        }

        var builder = SegmentBuilder()
        var applied = Set<ProposedEdit>()
        var cursor = text.startIndex
        for operation in accepted {
            builder.add(.same(String(text[cursor..<operation.range.lowerBound])))
            let old = String(text[operation.range])
            if old == operation.replacement {
                builder.add(.same(old))
            } else {
                builder.addChange(from: old, to: operation.replacement)
                applied.insert(operation.edit)
            }
            cursor = operation.range.upperBound
        }
        builder.add(.same(String(text[cursor...])))

        return EditOutcome(
            text: builder.resultText,
            segments: builder.segments,
            appliedCount: applied.count,
            rejected: rejected
        )
    }

    /// Non-overlapping, literal occurrences.
    static func occurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let range = text.range(of: needle, options: .literal, range: searchFrom..<text.endIndex) {
            ranges.append(range)
            searchFrom = range.upperBound
        }
        return ranges
    }

    /// Something added at the end starts on its own line, unless it is plainly
    /// meant to continue the last one.
    private static func appendable(_ addition: String, after text: String) -> String {
        guard let last = text.last, !last.isNewline,
              let first = addition.first, !first.isWhitespace
        else { return addition }
        return "\n" + addition
    }
}

/// Accumulates segments, merging neighbours and keeping each change minimal.
private struct SegmentBuilder {
    private(set) var segments: [DiffSegment] = []

    var resultText: String {
        segments.reduce(into: "") { text, segment in
            switch segment {
            case .same(let part), .inserted(let part): text += part
            case .removed: break
            }
        }
    }

    mutating func add(_ segment: DiffSegment) {
        switch (segments.last, segment) {
        case (_, .same("")), (_, .removed("")), (_, .inserted("")):
            return
        case (.same(let previous)?, .same(let next)):
            segments[segments.count - 1] = .same(previous + next)
        case (.removed(let previous)?, .removed(let next)):
            segments[segments.count - 1] = .removed(previous + next)
        case (.inserted(let previous)?, .inserted(let next)):
            segments[segments.count - 1] = .inserted(previous + next)
        default:
            segments.append(segment)
        }
    }

    /// "Hi [Name]," → "Hi Prathamesh," shows only [Name] → Prathamesh changing.
    mutating func addChange(from old: String, to new: String) {
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        add(.same(String(before[0..<prefix])))
        add(.removed(String(before[prefix..<(before.count - suffix)])))
        add(.inserted(String(after[prefix..<(after.count - suffix)])))
        add(.same(String(before[(before.count - suffix)...])))
    }
}

// MARK: - Fact tokens

enum FactTokens {

    /// `{{fact:3}}` and `{{ask:PRN}}`, tolerating the spacing and single
    /// braces a small model sometimes writes.
    private static let pattern = #"\{\{?\s*(fact|ask)\s*:\s*([^{}\n]{1,80}?)\s*\}\}?"#

    /// The token the model uses for the `number`th detail it was given.
    static func token(_ number: Int) -> String { "{{fact:\(number)}}" }

    /// The visible gap left for a detail the user still has to give.
    static func gap(_ label: String) -> String { "⟦\(label)⟧" }

    /// Swaps tokens for values: `{{fact:N}}` becomes `value(N)`, and
    /// `{{ask:X}}` becomes the gap ⟦X⟧.
    /// - Returns: the text, and any fact numbers `value` did not know.
    static func resolve(_ text: String, value: (Int) -> String?) -> (text: String, unknownFacts: [Int]) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (text, [])
        }
        let source = text as NSString
        var result = ""
        var unknown: [Int] = []
        var cursor = 0

        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let kind = source.substring(with: match.range(at: 1)).lowercased()
            let argument = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)

            if kind == "fact" {
                if let number = Int(argument), let resolved = value(number) {
                    result += resolved
                } else {
                    unknown.append(Int(argument) ?? -1)
                    result += source.substring(with: match.range)
                }
            } else {
                result += gap(argument)
            }
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return (result, unknown)
    }

    /// Labels of the ⟦…⟧ gaps still in `text`, in order, without repeats.
    static func pendingGaps(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"⟦([^⟧\n]{1,60})⟧"#) else { return [] }
        let source = text as NSString
        var labels: [String] = []
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let label = source.substring(with: match.range(at: 1))
            if !labels.contains(label) { labels.append(label) }
        }
        return labels
    }
}

// MARK: - Quick fill

/// Fills placeholders that obviously name one profile detail — `[Your Name]`
/// → Me ▸ Name — with no AI at all. Anything less than obvious is left alone.
enum QuickFill {

    /// What a placeholder word may be called in the profile.
    private static let synonyms: [String: Set<String>] = [
        // Not "server": group names like "GCloud server" would make every
        // detail of that server match.
        "ip": ["ip", "host", "address"],
        "host": ["host", "hostname", "ip", "address"],
        "hostname": ["host", "hostname", "ip", "address"],
        "address": ["address", "host", "ip"],
        "user": ["user", "username", "login"],
        "username": ["user", "username", "login"],
        "login": ["user", "username", "login"],
        "email": ["email", "mail"],
        "mail": ["email", "mail"],
        "phone": ["phone", "mobile", "number", "contact"],
        "mobile": ["phone", "mobile", "number", "contact"],
        "destination": ["destination", "dest", "remote", "target", "server"],
        "dest": ["destination", "dest", "remote", "target", "server"],
        "path": ["path", "folder", "directory", "dir"],
        "folder": ["path", "folder", "directory", "dir"],
        "directory": ["path", "folder", "directory", "dir"],
        "dir": ["path", "folder", "directory", "dir"],
        "password": ["password", "pass", "passcode"],
        "token": ["token", "key"],
        "key": ["key", "token"],
        "api": ["api", "token", "key"],
    ]

    private static let personalGroups: Set<String> = ["", "me", "personal", "myself"]

    /// Edits filling each placeholder that matches exactly one detail.
    /// - Parameter facts: the details on offer, by the token number they carry.
    static func edits(for text: String, facts: [Int: ProfileFact]) -> [ProposedEdit] {
        PlaceholderDetector.find(in: text).compactMap { placeholder in
            guard let number = bestFact(for: placeholder.label, among: facts) else { return nil }
            return ProposedEdit(find: placeholder.text, replace: FactTokens.token(number))
        }
    }

    /// The one detail a placeholder label names, or nil when none or several do.
    static func bestFact(for label: String, among facts: [Int: ProfileFact]) -> Int? {
        let wanted = TemplateWords.words(in: label)
        guard !wanted.isEmpty, wanted != ["blank"] else { return nil }

        let matches = facts.keys.sorted().filter { number in
            guard let fact = facts[number] else { return false }
            let available = TemplateWords.wordSet(fact.group + " " + fact.label)
            return wanted.allSatisfy { word in
                !(synonyms[word] ?? [word]).isDisjoint(with: available)
            }
        }

        if matches.count == 1 { return matches[0] }
        // "Name" fits Me ▸ Name and Project ▸ Name; the user's own wins.
        let personal = matches.filter {
            personalGroups.contains(ProfileFact.normalized(facts[$0]?.group ?? ""))
        }
        return personal.count == 1 ? personal[0] : nil
    }
}

// MARK: - Choosing details for the model

enum FactRelevance {

    /// The details worth showing the model for this text and request. The
    /// on-device model has a small context window, so a large profile is
    /// narrowed to the details that share words with the job — `silver_algo`
    /// in a path picks out the silver_algo project — plus the user's own.
    static func select(
        _ facts: [ProfileFact],
        text: String,
        request: String,
        limit: Int = 40
    ) -> [ProfileFact] {
        guard facts.count > limit else { return facts }

        let context = TemplateWords.wordSet(text + " " + request)
        let scored = facts.enumerated().map { index, fact -> (index: Int, score: Int) in
            // Values are compared locally only — they are never sent anywhere.
            let own = TemplateWords.wordSet(fact.group + " " + fact.label + " " + (fact.isSecret ? "" : fact.value))
            var score = own.intersection(context).count * 2
            if ["", "me", "personal"].contains(ProfileFact.normalized(fact.group)) { score += 1 }
            return (index, score)
        }
        let chosen = scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
            .map(\.index)
            .sorted()
        return chosen.map { facts[$0] }
    }
}

// MARK: - What the model is told

enum EditPrompt {

    static let instructions = """
    You edit a text for the user by proposing exact replacements. You never rewrite the text.

    Rules:
    1. Change only what the request asks for. Everything you do not replace stays exactly as it is.
    2. Each edit has `find` and `replace`. `find` is copied character for character from CURRENT TEXT and is as short as possible: only the placeholder or the words that change.
    3. To add something at the very end, leave `find` empty.
    4. Never type the user's personal details yourself. Write the token of a known detail instead, such as {{fact:2}}. Choose the detail whose description fits where it goes: a project's path on a server goes with that server's user and host.
    5. If the request needs a detail that is not among KNOWN DETAILS, write {{ask:Name of the detail}} instead. Never guess or make one up.
    6. If nothing should change, return no edits.
    """

    /// The request, with details listed by name only — never by value.
    static func prompt(
        text: String,
        request: String,
        facts: [Int: ProfileFact],
        placeholders: [TemplatePlaceholder]
    ) -> String {
        var lines: [String] = ["KNOWN DETAILS (token — what it is):"]
        if facts.isEmpty {
            lines.append("(none)")
        } else {
            for number in facts.keys.sorted() {
                guard let fact = facts[number] else { continue }
                lines.append("\(FactTokens.token(number)) — \(fact.path)")
            }
        }
        lines.append("")
        if !placeholders.isEmpty {
            lines.append("PLACEHOLDERS IN THE TEXT: " + placeholders.map(\.text).joined(separator: ", "))
            lines.append("")
        }
        lines.append("CURRENT TEXT:")
        lines.append("<<<")
        lines.append(text)
        lines.append(">>>")
        lines.append("")
        lines.append("REQUEST: \(request)")
        return lines.joined(separator: "\n")
    }

    /// The details as numbered tokens, 1-based, in profile order.
    static func numbered(_ facts: [ProfileFact]) -> [Int: ProfileFact] {
        Dictionary(uniqueKeysWithValues: facts.enumerated().map { ($0.offset + 1, $0.element) })
    }
}

// MARK: - Reading details out of the user's own words

enum FactExtraction {

    static let instructions = """
    You read what the user wrote about themselves and list every separate detail they gave.

    Rules:
    1. `value` is copied exactly from what the user wrote. Never invent, complete, correct or reformat a value.
    2. `group` says what the detail belongs to: "Me" for the user personally, otherwise a short name such as "GCloud server" or "silver_algo project".
    3. `label` says what the detail is in a few words, and names any other group it relates to, for example "Server path (on GCloud server)".
    4. `isSecret` is true for passwords, tokens, keys, ID numbers such as a PRN, and anything else private.
    5. Skip anything that is not a concrete detail.
    """

    /// Keeps only proposals whose value really is in what the user wrote, so
    /// the model cannot slip in a detail of its own.
    static func verified(_ proposals: [ProposedFact], source: String) -> [ProposedFact] {
        var seen = Set<String>()
        var kept: [ProposedFact] = []
        let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`“”‘’,;."))

        for proposal in proposals {
            var fact = proposal
            fact.value = proposal.value.trimmingCharacters(in: trimCharacters)
            fact.group = proposal.group.trimmingCharacters(in: .whitespacesAndNewlines)
            fact.label = proposal.label.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !fact.value.isEmpty, !fact.label.isEmpty,
                  source.range(of: fact.value, options: [.caseInsensitive]) != nil
            else { continue }

            if fact.group.isEmpty { fact.group = ProfileFact.personalGroup }
            if ProfileFact.looksSensitive(fact.label) { fact.isSecret = true }

            let key = ProfileFact(group: fact.group, label: fact.label, value: "").identityKey
            guard seen.insert(key).inserted else { continue }
            kept.append(fact)
        }
        return kept
    }
}

// MARK: - Presentation hints

enum TemplateText {

    private static let commandPrefixes = [
        "$ ", "sudo ", "scp ", "ssh ", "rsync ", "git ", "docker ", "kubectl ", "npm ", "npx ",
        "pnpm ", "yarn ", "pip ", "python ", "curl ", "wget ", "export ", "cd ", "mkdir ", "brew ",
        "gcloud ", "aws ", "az ", "terraform ", "make ", "cargo ", "go ", "chmod ", "chown ",
    ]

    /// Commands and code read better in a monospaced font.
    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains(" \\\n") || text.contains("&&") { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return commandPrefixes.contains { trimmed.hasPrefix($0) }
                || trimmed.hasSuffix(";") || trimmed == "{" || trimmed == "}"
        }
    }
}
