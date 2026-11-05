//
//  ProfileFact.swift
//  ClipStack
//
//  One thing ClipStack knows about the user — "Me ▸ Name", "GCloud ▸ Host",
//  "silver_algo ▸ Server path" — used to fill templates and commands.
//
//  Secret facts (a PRN, a token) keep their value in the Keychain, never in
//  the profile file; `value` is empty for them here.
//
//  Pure Foundation, so it compiles straight into the logic tests.
//

import Foundation

struct ProfileFact: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// What the fact belongs to: "Me", "GCloud server", "silver_algo project".
    var group: String
    /// What it is: "Name", "Host", "Server path".
    var label: String
    /// The value itself. Always empty for a secret: that lives in the Keychain.
    var value: String
    var isSecret: Bool = false
    var updatedAt: Date = Date()

    /// "Me ▸ Name": how the fact is shown, and how the AI refers to it.
    var path: String {
        let trimmedGroup = self.group.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedGroup.isEmpty ? label : "\(trimmedGroup) ▸ \(label)"
    }

    /// The default group for details about the user themself.
    static let personalGroup = "Me"

    /// Words that mark a detail as something to keep out of plain files.
    private static let sensitiveWords: Set<String> = [
        "password", "passcode", "passphrase", "pin", "prn", "token", "secret", "key", "apikey",
        "otp", "cvv", "ssn", "aadhaar", "aadhar", "pan", "passport", "iban", "card",
    ]

    /// A guess at whether a detail called `label` should be a Keychain secret.
    /// Only a default: the user can always change it.
    static func looksSensitive(_ label: String) -> Bool {
        let words = label.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { sensitiveWords.contains($0) }
    }

    /// Two facts are "the same detail" when group and label match, ignoring
    /// case and spacing. Used to update rather than duplicate.
    var identityKey: String {
        Self.normalized(group) + "\u{1F}" + Self.normalized(label)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// The profile as JSON, for the JSON editor and for import/export files.
///
/// A secret's value is left out unless asked for. On import, a secret entry
/// with no value keeps whatever the Keychain already holds for it.
struct ProfileDocument: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var group: String
        var label: String
        var value: String?
        var secret: Bool?
    }
    var facts: [Entry]
}

/// A detail the AI read out of something the user wrote, waiting for the
/// user to accept it.
struct ProposedFact: Identifiable, Hashable {
    var id = UUID()
    var group: String
    var label: String
    var value: String
    var isSecret: Bool
}
