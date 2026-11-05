//
//  BrowserProfiles.swift
//  ClipStack
//
//  Which browsers have profiles ClipStack can target, and how to read them.
//
//  Each browser family does profiles differently, so each is handled on its
//  own terms:
//
//   • Chromium (Chrome, Brave, Edge, Vivaldi, Chromium) lists profiles in a
//     "Local State" JSON file and opens a URL in one with
//     `--profile-directory=<dir>`.
//   • Firefox lists them in profiles.ini and takes `-P <name>`.
//   • Safari (17 and later) has no command line or URL scheme for profiles at
//     all. Its profiles only exist as "New <Profile> Window" items in its File
//     menu, so that is both where they are discovered and how one is opened.
//
//  The parsing lives here, free of AppKit, so the logic tests cover it.
//

import Foundation

struct BrowserProfile: Identifiable, Hashable {
    /// What the browser is told (see `BrowserTarget.profileID`).
    let id: String
    /// What the user sees.
    let name: String
}

enum BrowserProfileKind: Equatable {
    /// No profile support ClipStack knows how to drive.
    case unsupported
    /// `supportPath` is relative to ~/Library/Application Support.
    case chromium(supportPath: String)
    case firefox(supportPath: String)
    case safari

    init(bundleIdentifier: String) {
        self = Self.known[bundleIdentifier.lowercased()] ?? .unsupported
    }

    var supportsProfiles: Bool { self != .unsupported }

    private static let known: [String: BrowserProfileKind] = [
        "com.google.chrome":            .chromium(supportPath: "Google/Chrome"),
        "com.google.chrome.beta":       .chromium(supportPath: "Google/Chrome Beta"),
        "com.google.chrome.dev":        .chromium(supportPath: "Google/Chrome Dev"),
        "com.google.chrome.canary":     .chromium(supportPath: "Google/Chrome Canary"),
        "org.chromium.chromium":        .chromium(supportPath: "Chromium"),
        "com.brave.browser":            .chromium(supportPath: "BraveSoftware/Brave-Browser"),
        "com.brave.browser.beta":       .chromium(supportPath: "BraveSoftware/Brave-Browser-Beta"),
        "com.brave.browser.nightly":    .chromium(supportPath: "BraveSoftware/Brave-Browser-Nightly"),
        "com.microsoft.edgemac":        .chromium(supportPath: "Microsoft Edge"),
        "com.microsoft.edgemac.beta":   .chromium(supportPath: "Microsoft Edge Beta"),
        "com.microsoft.edgemac.dev":    .chromium(supportPath: "Microsoft Edge Dev"),
        "com.vivaldi.vivaldi":          .chromium(supportPath: "Vivaldi"),
        "org.mozilla.firefox":          .firefox(supportPath: "Firefox"),
        "org.mozilla.firefoxdeveloperedition": .firefox(supportPath: "Firefox"),
        "org.mozilla.nightly":          .firefox(supportPath: "Firefox"),
        "com.apple.safari":             .safari,
        "com.apple.safaritechnologypreview": .safari,
    ]
}

enum BrowserProfileParser {

    /// Profiles from a Chromium "Local State" file, in the browser's own order.
    ///
    /// The id is the profile *directory* ("Default", "Profile 1"), because that
    /// is what `--profile-directory` takes; the name is what the browser shows.
    static func chromiumProfiles(localState: Data) -> [BrowserProfile] {
        guard let root = (try? JSONSerialization.jsonObject(with: localState)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }

        let order = profile["profiles_order"] as? [String] ?? []

        let profiles: [BrowserProfile] = cache.map { directory, value in
            let info = value as? [String: Any] ?? [:]
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
            // The signed-in account tells two "Person 1"s apart.
            let account = (info["user_name"] as? String) ?? ""
            let label = account.isEmpty || account == name ? name : "\(name) (\(account))"
            return BrowserProfile(id: directory, name: label)
        }

        return profiles.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.id) ?? Int.max
            let right = order.firstIndex(of: rhs.id) ?? Int.max
            if left != right { return left < right }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    /// Profiles from Firefox's profiles.ini, in file order.
    static func firefoxProfiles(profilesINI: String) -> [BrowserProfile] {
        var names: [String] = []
        var inProfileSection = false

        for rawLine in profilesINI.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                // Only [Profile0], [Profile1] … — not [General] or [Install…].
                let header = line.dropFirst().dropLast()
                let suffix = header.dropFirst("Profile".count)
                inProfileSection = header.hasPrefix("Profile")
                    && !suffix.isEmpty
                    && suffix.allSatisfy(\.isNumber)
                continue
            }
            guard inProfileSection, line.hasPrefix("Name=") else { continue }
            let name = line.dropFirst("Name=".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        return names.map { BrowserProfile(id: $0, name: $0) }
    }

    /// Safari profile names from the titles in its File menu.
    ///
    /// With profiles set up, Safari offers "New <Profile> Window" for each one
    /// ("New Personal Window", "New Work Window"). Plain "New Window" and
    /// "New Private Window" are not profiles.
    static func safariProfileNames(menuTitles: [String]) -> [String] {
        var names: [String] = []
        for title in menuTitles {
            guard let name = safariProfileName(fromMenuTitle: title), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    static func safariProfileName(fromMenuTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let prefix = "New ", suffix = " Window"
        guard trimmed.count > prefix.count + suffix.count,
              trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix)
        else { return nil }

        let name = trimmed.dropFirst(prefix.count).dropLast(suffix.count)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.caseInsensitiveCompare("Private") != .orderedSame else { return nil }
        return name
    }

    /// The File-menu title that opens a window in `profile`.
    static func safariMenuTitle(forProfile profile: String) -> String {
        "New \(profile) Window"
    }
}
