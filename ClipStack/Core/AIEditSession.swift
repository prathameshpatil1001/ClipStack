//
//  AIEditSession.swift
//  ClipStack
//
//  One ⌘↩ session in the ⌥Space panel: a piece of text (the clipboard, or a
//  saved text) being changed one instruction at a time.
//
//  Every instruction produces edits, never a rewrite (see TemplateFill.swift).
//  Each accepted version goes straight onto the clipboard, so closing the panel
//  at any point leaves the latest result ready to paste. ⌘Z steps back.
//

import Foundation
import Combine

@MainActor
final class AIEditSession: ObservableObject {

    enum Status: Equatable {
        case info(String)
        case working(String)
        case done(String)
        case problem(String)

        var message: String {
            switch self {
            case .info(let text), .working(let text), .done(let text), .problem(let text): return text
            }
        }
    }

    /// What is being edited, for the chip in the field: "Clipboard", or the
    /// saved text's title.
    let sourceTitle: String

    /// What the user is typing: an instruction, or the value for a ⟦gap⟧.
    @Published var instruction = ""

    @Published private(set) var text: String
    /// The last step's changes, for highlighting. Just `.same(text)` when
    /// nothing has changed yet.
    @Published private(set) var segments: [DiffSegment]
    @Published private(set) var status: Status
    @Published private(set) var isWorking = false
    /// Details the model asked for, still shown as ⟦gaps⟧.
    @Published private(set) var pendingGaps: [String] = []
    @Published private(set) var placeholderCount = 0
    /// Highlight the last step's changes, or show the plain result.
    @Published var showsChanges = true

    private struct Version {
        let text: String
        let segments: [DiffSegment]
    }
    private var history: [Version] = []

    private let profile: ProfileStore
    private let clipboard: ClipboardManager
    private var task: Task<Void, Never>?

    init(text: String, sourceTitle: String, profile: ProfileStore, clipboard: ClipboardManager) {
        self.text = text
        self.sourceTitle = sourceTitle
        self.segments = [.same(text)]
        self.profile = profile
        self.clipboard = clipboard
        self.status = .info("")
        refreshDerivedState()
        status = .info(openingMessage())
    }

    var hasChanges: Bool { !history.isEmpty }

    var looksLikeCode: Bool { TemplateText.looksLikeCode(text) }

    /// The field's prompt: asking for a missing detail first, otherwise for
    /// an instruction.
    var fieldPrompt: String {
        if let gap = pendingGaps.first {
            return "Your \(gap) — ↩ fill and remember · ⇧↩ just fill"
        }
        return hasChanges ? "Anything else to change?" : "What should change? e.g. fill in my details"
    }

    private func openingMessage() -> String {
        var parts: [String] = []
        if placeholderCount > 0 {
            parts.append("\(placeholderCount) placeholder\(placeholderCount == 1 ? "" : "s") found")
        }
        if let reason = OnDeviceAI.unavailableReason {
            parts.append(reason)
        } else {
            parts.append("Say what to change, or ⌥↩ to Quick fill from your profile")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// ↩ — fills the first ⟦gap⟧ with what was typed when one is waiting,
    /// otherwise sends the instruction to the model.
    /// - Parameter remember: save a filled-in detail to the profile.
    func submit(remember: Bool) {
        let input = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isWorking else { return }

        if let gap = pendingGaps.first {
            fillGap(gap, with: input, remember: remember)
        } else {
            runModel(request: input)
        }
    }

    /// ⌥↩ — fills the placeholders that plainly name one profile detail. No AI.
    func quickFill() {
        guard !isWorking else { return }
        let numbered = EditPrompt.numbered(profile.facts)
        let edits = QuickFill.edits(for: text, facts: numbered)
        guard !edits.isEmpty else {
            status = .info(placeholderCount == 0
                ? "No placeholders to fill"
                : "No placeholder matched exactly one detail in your profile. Say what to fill instead.")
            return
        }
        apply(edits, numbered: numbered, describing: "Quick fill")
    }

    /// ⌘Z — back one step.
    func undo() {
        guard !isWorking, let previous = history.popLast() else { return }
        text = previous.text
        segments = previous.segments
        refreshDerivedState()
        clipboard.write(text)
        status = .info(history.isEmpty ? "Back to the original" : "Undone")
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    // MARK: - The model

    private func runModel(request: String) {
        let selected = FactRelevance.select(profile.facts, text: text, request: request)
        let numbered = EditPrompt.numbered(selected)
        let prompt = EditPrompt.prompt(
            text: text,
            request: request,
            facts: numbered,
            placeholders: PlaceholderDetector.find(in: text)
        )

        instruction = ""
        isWorking = true
        status = .working("Working on “\(request)”…")

        task = Task { [weak self] in
            do {
                let edits = try await OnDeviceAI.proposeEdits(prompt: prompt)
                guard let self, !Task.isCancelled else { return }
                self.isWorking = false
                self.apply(edits, numbered: numbered, describing: nil)
            } catch is CancellationError {
                self?.isWorking = false
            } catch {
                guard let self else { return }
                self.isWorking = false
                self.instruction = request   // give the words back to try again
                self.status = .problem((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Applying

    /// Resolves fact tokens, applies what can be applied, and reports.
    private func apply(_ edits: [ProposedEdit], numbered: [Int: ProfileFact], describing source: String?) {
        var resolved: [ProposedEdit] = []
        var unknownDetails = 0
        for edit in edits {
            let replacement = FactTokens.resolve(edit.replace) { number in
                numbered[number].map { profile.value(of: $0) }
            }
            if replacement.unknownFacts.isEmpty {
                resolved.append(ProposedEdit(find: edit.find, replace: replacement.text))
            } else {
                unknownDetails += 1
            }
        }

        let outcome = EditApplier.apply(resolved, to: text)
        let refused = outcome.rejected.count + unknownDetails

        guard outcome.appliedCount > 0 else {
            status = refused > 0
                ? .problem("The model's changes didn't match the text, so nothing was changed. Try saying it differently.")
                : .info("Nothing to change for that.")
            return
        }

        history.append(Version(text: text, segments: segments))
        text = outcome.text
        segments = outcome.segments
        showsChanges = true
        refreshDerivedState()
        clipboard.write(text)

        var message = "\(source.map { "\($0): " } ?? "")\(outcome.appliedCount) change\(outcome.appliedCount == 1 ? "" : "s") · copied"
        if refused > 0 {
            message += " · \(refused) couldn't be placed and \(refused == 1 ? "was" : "were") skipped"
        }
        if let gap = pendingGaps.first {
            message += " · needs your \(gap)"
        }
        status = .done(message)
    }

    private func fillGap(_ gap: String, with value: String, remember: Bool) {
        let outcome = EditApplier.apply([ProposedEdit(find: FactTokens.gap(gap), replace: value)], to: text)
        guard outcome.appliedCount > 0 else {
            pendingGaps.removeAll { $0 == gap }
            return
        }

        history.append(Version(text: text, segments: segments))
        text = outcome.text
        segments = outcome.segments
        instruction = ""
        refreshDerivedState()
        clipboard.write(text)

        if remember {
            profile.upsert(
                group: ProfileFact.personalGroup,
                label: gap,
                value: value,
                isSecret: ProfileFact.looksSensitive(gap)
            )
            status = .done("Filled your \(gap) · saved to your profile · copied")
        } else {
            status = .done("Filled your \(gap) · copied")
        }
    }

    private func refreshDerivedState() {
        pendingGaps = FactTokens.pendingGaps(in: text)
        placeholderCount = PlaceholderDetector.ranges(in: text).count
    }
}
