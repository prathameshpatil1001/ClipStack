//
//  Website.swift
//  ClipStack
//
//  A saved website the user can open from the menu bar, in a browser (and
//  browser profile) of their choosing.
//
//  Pure Foundation, so it compiles straight into the logic tests.
//

import Foundation

/// Which browser, and which of its profiles, a website opens in.
struct BrowserTarget: Codable, Hashable {
    /// `nil` means "whatever the system default browser is when it is opened",
    /// so changing the default browser later is followed automatically.
    var bundleIdentifier: String? = nil

    /// The browser's name when it was chosen, so a website can still be labelled
    /// (and the error explained) if that browser is later uninstalled.
    var browserName: String? = nil

    /// What the browser is told: a Chromium profile *directory* ("Profile 1"),
    /// a Firefox profile name, or a Safari profile name. `nil` means the
    /// browser's own default.
    var profileID: String? = nil

    /// What the user sees for that profile ("Work"). Stored so the menu can
    /// label a website without reading the browser's files every time.
    var profileName: String? = nil

    static let systemDefault = BrowserTarget()

    var hasProfile: Bool {
        guard let profileID else { return false }
        return !profileID.isEmpty
    }
}

struct Website: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// As the user typed it; `url` normalises it.
    var address: String
    var browser: BrowserTarget = .systemDefault
    var createdAt: Date = Date()

    /// The address as an openable URL, or `nil` if it is not a web address.
    var url: URL? { Website.normalizedURL(from: address) }

    /// The name, or the host when no name was given.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url?.host ?? address
    }

    /// Accepts what people actually type into an address bar — `github.com`,
    /// `www.example.com/path`, `http://localhost:3000` — and turns it into an
    /// http(s) URL. Anything else (`javascript:`, `file:`, plain words with
    /// spaces) is refused: these are websites, and opening arbitrary schemes
    /// from a menu bar click is not something to do silently.
    static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let candidate: String
        if trimmed.range(of: "://") != nil {
            candidate = trimmed
        } else if Self.startsWithBareScheme(trimmed), !Self.looksLikeHostAndPort(trimmed) {
            // "mailto:x", "javascript:…" — a scheme without slashes.
            return nil
        } else {
            candidate = "https://" + trimmed
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// `mailto:`, `javascript:` — letters before the first colon and nothing
    /// host-like (no dot, no slash). `example.com/a:b` is not one.
    private static func startsWithBareScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let head = text[..<colon]
        guard let first = head.first, first.isLetter else { return false }
        return head.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
    }

    /// `localhost:3000`, `example.com:8080/path` — a colon that is a port.
    private static func looksLikeHostAndPort(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let host = text[..<colon]
        let rest = text[text.index(after: colon)...]
        let port = rest.prefix { $0.isNumber }
        guard !host.isEmpty, !port.isEmpty else { return false }
        let afterPort = rest.dropFirst(port.count)
        return afterPort.isEmpty || afterPort.hasPrefix("/") || afterPort.hasPrefix("?") || afterPort.hasPrefix("#")
    }
}
