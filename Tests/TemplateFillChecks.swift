//
//  TemplateFillChecks.swift
//  ClipStack tests
//
//  The rules behind ⌘↩ edit mode: finding placeholders, applying only edits
//  that can be placed exactly, swapping fact tokens for values, Quick fill,
//  and what the model is (and is not) shown.
//

import Foundation

@MainActor
enum TemplateFillChecks {

    static let scpTemplate = """
    scp -r \\
      /Users/prathamesh/Work/silver_algo/UI_AUDIT.md \\
      /Users/prathamesh/Work/silver_algo/ui_audit_evidence \\
      <USER>@<YOUR_IP>:path/to/destination
    """

    static let scpFilled = """
    scp -r \\
      /Users/prathamesh/Work/silver_algo/UI_AUDIT.md \\
      /Users/prathamesh/Work/silver_algo/ui_audit_evidence \\
      google-cloud@34.131.129.112:/home/google-cloud/silver_algo/
    """

    static let serverFacts: [Int: ProfileFact] = [
        1: ProfileFact(group: "GCloud server", label: "Host", value: "34.131.129.112"),
        2: ProfileFact(group: "GCloud server", label: "User", value: "google-cloud"),
        3: ProfileFact(group: "silver_algo project", label: "Server path (on GCloud server)",
                       value: "/home/google-cloud/silver_algo/"),
    ]

    /// Resolves tokens against `facts`, then applies — what the session does.
    static func applyResolved(_ edits: [ProposedEdit], to text: String, facts: [Int: ProfileFact]) -> EditOutcome {
        let resolved = edits.map { edit in
            ProposedEdit(find: edit.find, replace: FactTokens.resolve(edit.replace) { facts[$0]?.value }.text)
        }
        return EditApplier.apply(resolved, to: text)
    }

    static func run() -> Int {
        let runner = CheckRunner(suite: "Template fill")

        // ── Placeholders ───────────────────────────────────────────────────
        runner.check("scp: the three placeholders",
                     PlaceholderDetector.find(in: scpTemplate).map(\.text),
                     equals: ["<USER>", "<YOUR_IP>", "path/to/destination"])
        runner.check("scp: what they ask for",
                     PlaceholderDetector.find(in: scpTemplate).map(\.label),
                     equals: ["user", "ip", "path destination"])
        runner.check("email placeholders",
                     PlaceholderDetector.find(in: "Dear [Recipient Name],\nI am [Your Name], PRN ______.\n{{signature}}").map(\.text),
                     equals: ["[Recipient Name]", "[Your Name]", "______", "{{signature}}"])
        runner.check("API key and IP stand-ins",
                     PlaceholderDetector.find(in: "export KEY=YOUR_API_KEY && ping xxx.xxx.xxx.xxx").map(\.label),
                     equals: ["api key", "ip address"])
        runner.check("not placeholders: generics, links, log tags, dunders, types",
                     PlaceholderDetector.find(in: "let a: Array<T> = []\n[docs](https://x.dev)\n[INFO] up\ndef __init__(self): <String>").isEmpty)

        // ── The scp example, as the model would answer it ──────────────────
        let modelEdits = [
            ProposedEdit(find: "<USER>", replace: "{{fact:2}}"),
            ProposedEdit(find: "<YOUR_IP>", replace: "{{fact:1}}"),
            ProposedEdit(find: "path/to/destination", replace: "{{fact:3}}"),
        ]
        let scp = applyResolved(modelEdits, to: scpTemplate, facts: serverFacts)
        runner.check("scp: filled exactly, nothing else touched", scp.text, equals: scpFilled)
        runner.check("scp: three changes", scp.appliedCount, equals: 3)
        runner.check("scp: nothing refused", scp.rejected.isEmpty)

        // ── …and with Quick fill, no AI at all ─────────────────────────────
        let quick = applyResolved(QuickFill.edits(for: scpTemplate, facts: serverFacts), to: scpTemplate, facts: serverFacts)
        runner.check("Quick fill completes the scp command on its own", quick.text, equals: scpFilled)

        // ── Applying edits safely ──────────────────────────────────────────
        let ambiguous = EditApplier.apply([ProposedEdit(find: "Sam", replace: "Ann")], to: "Hi Sam, Sam said")
        runner.check("ambiguous excerpt is refused", ambiguous.rejected.first?.reason == .ambiguous)
        runner.check("…and the text is untouched", ambiguous.text, equals: "Hi Sam, Sam said")

        let missing = EditApplier.apply([ProposedEdit(find: "Bob", replace: "Ann")], to: "Hi Sam")
        runner.check("excerpt not in the text is refused", missing.rejected.first?.reason == .notFound)

        let everyUser = EditApplier.apply([ProposedEdit(find: "<USER>", replace: "me")], to: "<USER>@a and <USER>@b")
        runner.check("a placeholder is filled everywhere it appears", everyUser.text, equals: "me@a and me@b")

        let overlap = EditApplier.apply([
            ProposedEdit(find: "Hello world", replace: "Hi there"),
            ProposedEdit(find: "world", replace: "earth"),
        ], to: "Hello world!")
        runner.check("overlapping edit is refused", overlap.text, equals: "Hi there!")
        runner.check("…and reported", overlap.rejected.map(\.reason), equals: [.overlapping])

        let appended = EditApplier.apply([ProposedEdit(find: "", replace: "PRN: 2021001")], to: "Regards,\nPrathamesh")
        runner.check("adding at the end starts a new line", appended.text, equals: "Regards,\nPrathamesh\nPRN: 2021001")

        let minimal = EditApplier.apply([ProposedEdit(find: "Hi [Name],", replace: "Hi Prathamesh,")], to: "Hi [Name],\nThanks")
        runner.check("changes are shown at their smallest", minimal.segments, equals: [
            .same("Hi "), .removed("[Name]"), .inserted("Prathamesh"), .same(",\nThanks"),
        ])

        let padded = EditApplier.apply([ProposedEdit(find: " <USER>\n", replace: " me\n")], to: "ssh <USER>@host")
        runner.check("stray whitespace around an excerpt is tolerated", padded.text, equals: "ssh me@host")

        let unchanged = EditApplier.apply([ProposedEdit(find: "same", replace: "same")], to: "the same")
        runner.check("an edit that changes nothing doesn't count", unchanged.appliedCount, equals: 0)

        // ── Tokens ─────────────────────────────────────────────────────────
        let tokens = FactTokens.resolve("{{fact:2}}@{{ fact: 1 }} {fact:3}") { serverFacts[$0]?.value }
        runner.check("fact tokens become values, spacing tolerated",
                     tokens.text, equals: "google-cloud@34.131.129.112 /home/google-cloud/silver_algo/")
        let unknown = FactTokens.resolve("{{fact:9}}") { serverFacts[$0]?.value }
        runner.check("an unknown fact is reported, not invented", unknown.unknownFacts, equals: [9])
        let asked = FactTokens.resolve("PRN: {{ask:PRN}}") { _ in nil }
        runner.check("a missing detail becomes a visible gap", asked.text, equals: "PRN: ⟦PRN⟧")
        runner.check("gaps are listed", FactTokens.pendingGaps(in: "⟦PRN⟧ and ⟦Roll number⟧ and ⟦PRN⟧"),
                     equals: ["PRN", "Roll number"])
        let gapFilled = EditApplier.apply([ProposedEdit(find: "⟦PRN⟧", replace: "2021001")], to: "PRN ⟦PRN⟧ (⟦PRN⟧)")
        runner.check("filling a gap fills every copy of it", gapFilled.text, equals: "PRN 2021001 (2021001)")

        // ── Quick fill choices ─────────────────────────────────────────────
        let named: [Int: ProfileFact] = [
            1: ProfileFact(group: "Me", label: "Name", value: "Prathamesh"),
            2: ProfileFact(group: "silver_algo project", label: "Project name", value: "Silver Algo"),
            3: ProfileFact(group: "AWS server", label: "User", value: "ubuntu"),
            4: ProfileFact(group: "GCloud server", label: "User", value: "google-cloud"),
        ]
        runner.check("[Your Name] prefers your own name over a project's",
                     QuickFill.bestFact(for: "name", among: named), equals: 1)
        runner.check("two servers' users: left for the AI to choose",
                     QuickFill.bestFact(for: "user", among: named) == nil)

        // ── What the model sees ────────────────────────────────────────────
        var secretFacts = serverFacts
        secretFacts[4] = ProfileFact(group: "Me", label: "PRN", value: "", isSecret: true)
        let prompt = EditPrompt.prompt(
            text: scpTemplate,
            request: "fill in my server details",
            facts: secretFacts,
            placeholders: PlaceholderDetector.find(in: scpTemplate)
        )
        runner.check("prompt names details by token", prompt.contains("{{fact:1}} — GCloud server ▸ Host"))
        runner.check("prompt never contains a detail's value",
                     !prompt.contains("34.131.129.112") && !prompt.contains("google-cloud@"))

        let many = (1...6).map { ProfileFact(group: "Project \($0)", label: "Path", value: "/srv/p\($0)") }
            + [ProfileFact(group: "silver_algo project", label: "Server path", value: "/home/x/silver_algo/")]
        let chosen = FactRelevance.select(many, text: scpTemplate, request: "fill it", limit: 2)
        runner.check("a large profile is narrowed to what the text is about",
                     chosen.contains { $0.group == "silver_algo project" })

        // ── Reading details out of the user's words ────────────────────────
        let said = "I have a G cloud server, its IP is 34.131.129.112 and the user is google-cloud. silver algo lives at /home/google-cloud/silver_algo/. My PRN is 2021001."
        let read = FactExtraction.verified([
            ProposedFact(group: "GCloud server", label: "IP", value: "34.131.129.112", isSecret: false),
            ProposedFact(group: "GCloud server", label: "Password", value: "hunter2", isSecret: true),
            ProposedFact(group: "silver_algo project", label: "Server path", value: "/home/google-cloud/silver_algo/.", isSecret: false),
            ProposedFact(group: "", label: "PRN", value: "2021001", isSecret: false),
        ], source: said)
        runner.check("only values really written are kept", read.map(\.value),
                     equals: ["34.131.129.112", "/home/google-cloud/silver_algo/", "2021001"])
        runner.check("a PRN is kept secret even if the model didn't say so", read.last?.isSecret == true)
        runner.check("no group means Me", read.last?.group ?? "", equals: "Me")

        runner.check("PRN looks sensitive", ProfileFact.looksSensitive("PRN"))
        runner.check("API key looks sensitive", ProfileFact.looksSensitive("OpenAI API key"))
        runner.check("keyboard layout does not", !ProfileFact.looksSensitive("Keyboard layout"))

        runner.check("commands read as code", TemplateText.looksLikeCode(scpTemplate))
        runner.check("an email does not", !TemplateText.looksLikeCode("Dear Professor,\n\nI am writing to ask about the deadline.\n\nRegards,\nPrathamesh"))

        return runner.failures
    }
}
