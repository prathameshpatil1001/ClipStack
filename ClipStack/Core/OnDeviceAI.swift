//
//  OnDeviceAI.swift
//  ClipStack
//
//  Apple's on-device language model (the Foundation Models framework, macOS 26
//  with Apple Intelligence turned on). Nothing here goes over the network.
//
//  The model is only ever asked for *structured* answers — a list of edits, a
//  list of details — through guided generation, so it cannot reply with free
//  text that ClipStack would then have to trust. What it proposes is checked
//  by the rules in TemplateFill.swift before anything is applied.
//
//  Everything that touches the framework sits behind `canImport`, so ClipStack
//  still builds with an older SDK; there, AI features report themselves
//  unavailable and Quick fill keeps working.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum OnDeviceAIError: LocalizedError {
    case unavailable(String)
    case tooLong
    case declined
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .tooLong: return "That's too long for the on-device model. Try a shorter piece."
        case .declined: return "Apple's on-device model declined this request."
        case .failed(let detail): return "The on-device model failed: \(detail)"
        }
    }
}

@MainActor
enum OnDeviceAI {

    /// A generous bound on what is sent in one request. The on-device model's
    /// context window is a few thousand tokens, shared by instructions, the
    /// text, and the answer.
    static let maximumCharacters = 8_000

    /// Why AI features can't run right now, or nil when they can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This Mac can't run Apple Intelligence, so AI edits are off. Quick fill (⌥↩) still works."
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in System Settings to use AI edits. Quick fill (⌥↩) still works."
                case .modelNotReady:
                    return "Apple Intelligence is still getting ready. Try again in a little while."
                @unknown default:
                    return "Apple Intelligence isn't available right now."
                }
            }
        }
        return "AI edits need macOS 26 with Apple Intelligence. Quick fill (⌥↩) still works."
        #else
        return "This copy of ClipStack was built without Apple Intelligence support. Quick fill (⌥↩) still works."
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    // MARK: - Edits

    /// Asks the model for edits to the text described by `prompt`.
    static func proposeEdits(prompt: String) async throws -> [ProposedEdit] {
        if let reason = unavailableReason { throw OnDeviceAIError.unavailable(reason) }
        guard prompt.count <= maximumCharacters else { throw OnDeviceAIError.tooLong }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: EditPrompt.instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedEditPlan.self
                )
                return response.content.edits.map { ProposedEdit(find: $0.find, replace: $0.replace) }
            } catch {
                throw describe(error)
            }
        }
        #endif
        throw OnDeviceAIError.unavailable(unavailableReason ?? "Apple Intelligence isn't available.")
    }

    // MARK: - Details from the user's own words

    /// Reads the details out of what the user wrote about themselves. The
    /// caller still checks each value against `text` before offering it.
    static func extractFacts(from text: String) async throws -> [ProposedFact] {
        if let reason = unavailableReason { throw OnDeviceAIError.unavailable(reason) }
        guard text.count <= maximumCharacters else { throw OnDeviceAIError.tooLong }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: FactExtraction.instructions)
                let response = try await session.respond(
                    to: "WHAT THE USER WROTE:\n<<<\n\(text)\n>>>",
                    generating: GeneratedFactList.self
                )
                return response.content.facts.map {
                    ProposedFact(group: $0.group, label: $0.label, value: $0.value, isSecret: $0.isSecret)
                }
            } catch {
                throw describe(error)
            }
        }
        #endif
        throw OnDeviceAIError.unavailable(unavailableReason ?? "Apple Intelligence isn't available.")
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> Error {
        if error is CancellationError { return error }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return OnDeviceAIError.tooLong
            case .guardrailViolation:
                return OnDeviceAIError.declined
            default:
                return OnDeviceAIError.failed(generationError.localizedDescription)
            }
        }
        #endif
        return OnDeviceAIError.failed(error.localizedDescription)
    }
}

// MARK: - Guided generation types

#if canImport(FoundationModels)

@available(macOS 26.0, *)
@Generable
nonisolated struct GeneratedEditPlan {
    @Guide(description: "The replacements to make. Empty when nothing should change.")
    var edits: [GeneratedEdit]
}

@available(macOS 26.0, *)
@Generable
nonisolated struct GeneratedEdit {
    @Guide(description: "An exact excerpt of CURRENT TEXT, copied character for character, as short as possible. Empty to add at the very end.")
    var find: String

    @Guide(description: "What goes in its place. Use {{fact:N}} tokens for the user's details and {{ask:Name of the detail}} for details that are not known.")
    var replace: String
}

@available(macOS 26.0, *)
@Generable
nonisolated struct GeneratedFactList {
    @Guide(description: "Every separate detail the user gave.")
    var facts: [GeneratedFact]
}

@available(macOS 26.0, *)
@Generable
nonisolated struct GeneratedFact {
    @Guide(description: "What the detail belongs to: Me, or a short name such as GCloud server or silver_algo project.")
    var group: String

    @Guide(description: "What the detail is, in a few words, naming any group it relates to.")
    var label: String

    @Guide(description: "The value copied exactly from what the user wrote.")
    var value: String

    @Guide(description: "True for passwords, tokens, keys, ID numbers and other private details.")
    var isSecret: Bool
}

#endif
