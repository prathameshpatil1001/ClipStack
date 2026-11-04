//
//  WebsiteChecks.swift
//  ClipStack tests
//
//  Saved websites: turning typed addresses into URLs, reading each browser
//  family's profile list, and the store's persistence.
//

import Foundation

@MainActor
enum WebsiteChecks {

    static func run() -> Int {
        let runner = CheckRunner(suite: "Websites")

        // ── Addresses ───────────────────────────────────────────────────────
        func normalized(_ raw: String) -> String {
            Website.normalizedURL(from: raw)?.absoluteString ?? "nil"
        }
        runner.check("bare domain gets https", normalized("github.com"), equals: "https://github.com")
        runner.check("path is kept", normalized("www.example.com/a/b?q=1"), equals: "https://www.example.com/a/b?q=1")
        runner.check("explicit http is kept", normalized("http://example.com"), equals: "http://example.com")
        runner.check("host and port", normalized("localhost:3000"), equals: "https://localhost:3000")
        runner.check("colon later in the path is fine", normalized("example.com/a:b"), equals: "https://example.com/a:b")
        runner.check("surrounding whitespace is trimmed", normalized("  example.com \n"), equals: "https://example.com")
        runner.check("javascript: is refused", normalized("javascript:alert(1)"), equals: "nil")
        runner.check("mailto: is refused", normalized("mailto:someone@example.com"), equals: "nil")
        runner.check("file URLs are refused", normalized("file:///etc/hosts"), equals: "nil")
        runner.check("words with spaces are refused", normalized("not a url"), equals: "nil")
        runner.check("empty is refused", normalized(""), equals: "nil")

        runner.check("display name falls back to host",
                     Website(name: " ", address: "news.ycombinator.com").displayName,
                     equals: "news.ycombinator.com")

        // ── Browser families ────────────────────────────────────────────────
        runner.check("Chrome is Chromium",
                     BrowserProfileKind(bundleIdentifier: "com.google.Chrome"),
                     equals: .chromium(supportPath: "Google/Chrome"))
        runner.check("Edge is matched case-insensitively",
                     BrowserProfileKind(bundleIdentifier: "com.microsoft.edgemac.Beta"),
                     equals: .chromium(supportPath: "Microsoft Edge Beta"))
        runner.check("Safari", BrowserProfileKind(bundleIdentifier: "com.apple.Safari"), equals: .safari)
        runner.check("unknown browsers have no profiles",
                     BrowserProfileKind(bundleIdentifier: "com.example.browser").supportsProfiles == false)

        // ── Chromium Local State ────────────────────────────────────────────
        let localState = Data("""
        {"profile": {
            "profiles_order": ["Default", "Profile 2", "Profile 1"],
            "info_cache": {
                "Profile 1": {"name": "Work", "user_name": "me@work.example"},
                "Default":   {"name": "Personal", "user_name": ""},
                "Profile 2": {"name": ""}
            }
        }}
        """.utf8)
        let chromium = BrowserProfileParser.chromiumProfiles(localState: localState)
        runner.check("chromium: directories are the ids, in browser order",
                     chromium.map(\.id), equals: ["Default", "Profile 2", "Profile 1"])
        runner.check("chromium: names, with the account when signed in",
                     chromium.map(\.name), equals: ["Personal", "Profile 2", "Work (me@work.example)"])
        runner.check("chromium: garbage reads as no profiles",
                     BrowserProfileParser.chromiumProfiles(localState: Data("nope".utf8)).isEmpty)

        // ── Firefox profiles.ini ────────────────────────────────────────────
        let ini = """
        [Install4F96D1932A9F858E]
        Default=Profiles/abc.default-release
        Locked=1

        [Profile1]
        Name=Work
        IsRelative=1
        Path=Profiles/def.Work

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abc.default-release
        Default=1

        [General]
        StartWithLastProfile=1
        Version=2
        """
        runner.check("firefox: profile sections only, in file order",
                     BrowserProfileParser.firefoxProfiles(profilesINI: ini).map(\.name),
                     equals: ["Work", "default-release"])

        // ── Safari File menu ────────────────────────────────────────────────
        let menu = [
            "New Window", "New Personal Window", "New Work Window", "New Private Window",
            "New Tab", "Open File…", "New Work Window",
        ]
        runner.check("safari: profiles from the File menu",
                     BrowserProfileParser.safariProfileNames(menuTitles: menu),
                     equals: ["Personal", "Work"])
        runner.check("safari: menu title for a profile",
                     BrowserProfileParser.safariMenuTitle(forProfile: "Work"),
                     equals: "New Work Window")
        runner.check("safari: multi-word profile names",
                     BrowserProfileParser.safariProfileName(fromMenuTitle: "New Side Project Window") ?? "nil",
                     equals: "Side Project")

        // ── Store ───────────────────────────────────────────────────────────
        let suite = "ClipStackWebsiteChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WebsiteStore(defaults: defaults)
        var work = Website(name: "Mail", address: "mail.example.com")
        work.browser = BrowserTarget(
            bundleIdentifier: "com.apple.Safari",
            browserName: "Safari",
            profileID: "Work",
            profileName: "Work"
        )
        store.add(work)
        store.add(Website(name: "Docs", address: "docs.example.com"))
        store.add(Website(name: "News", address: "news.example.com"))
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        runner.check("store: move puts the row where it was dropped",
                     store.websites.map(\.name), equals: ["News", "Mail", "Docs"])

        let reloaded = WebsiteStore(defaults: defaults)
        runner.check("store: order survives a relaunch",
                     reloaded.websites.map(\.name), equals: ["News", "Mail", "Docs"])
        runner.check("store: browser and profile survive a relaunch",
                     reloaded.websites.first { $0.name == "Mail" }?.browser ?? .systemDefault,
                     equals: work.browser)

        reloaded.delete(ids: Set(reloaded.websites.filter { $0.name != "Docs" }.map(\.id)))
        runner.check("store: delete", WebsiteStore(defaults: defaults).websites.map(\.name), equals: ["Docs"])

        return runner.failures
    }
}
