//
//  BrowserLauncher.swift
//  ClipStack
//
//  Finds the installed browsers and their profiles, and opens a saved website
//  in the browser and profile it was set up with.
//
//  How each kind of browser is driven (see BrowserProfiles.swift for why):
//
//   • No browser chosen — `NSWorkspace.open(url)`, i.e. the system default.
//   • A browser, no profile — `NSWorkspace.open(_:withApplicationAt:…)`.
//   • Chromium / Firefox profile — the browser is launched as a new instance
//     with the profile on its command line (the same as `open -na … --args`).
//     If it is already running, that instance hands the URL to the running one
//     and exits, which is how these browsers implement "open in profile".
//   • Safari profile — Safari's File ▸ "New <Profile> Window" menu item is
//     pressed through the Accessibility API, and the new window is pointed at
//     the URL with AppleScript. Safari offers no other way in.
//

import AppKit
import ApplicationServices

struct InstalledBrowser: Identifiable, Hashable {
    let bundleIdentifier: String
    let name: String
    let appURL: URL

    var id: String { bundleIdentifier }
    var profileKind: BrowserProfileKind { BrowserProfileKind(bundleIdentifier: bundleIdentifier) }

    /// Menu-sized app icon.
    var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

enum BrowserLaunchError: LocalizedError {
    case invalidAddress(String)
    case browserNotInstalled(String)
    case needsAccessibility
    case safariProfileNotFound(String)
    case couldNotOpen(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "“\(address)” is not a web address"
        case .browserNotInstalled(let name):
            return "\(name) is not installed"
        case .needsAccessibility:
            return "Opening a Safari profile needs Accessibility"
        case .safariProfileNotFound(let profile):
            return "Safari has no profile named “\(profile)”"
        case .couldNotOpen(let detail):
            return "Could not open: \(detail)"
        }
    }
}

@MainActor
enum BrowserLauncher {

    /// Any http URL: used to ask Launch Services which apps open web pages.
    private static let probeURL = URL(string: "https://example.com")!

    // MARK: - Discovery

    /// Safari profiles are read from, and opened through, Safari's File menu,
    /// which needs Accessibility.
    static var canUseSafariMenus: Bool { AXIsProcessTrusted() }

    /// Every installed app that can open web pages, by name.
    static func installedBrowsers() -> [InstalledBrowser] {
        var seen = Set<String>()
        var browsers: [InstalledBrowser] = []

        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probeURL) {
            guard let bundle = Bundle(url: appURL),
                  let identifier = bundle.bundleIdentifier,
                  seen.insert(identifier.lowercased()).inserted
            else { continue }
            browsers.append(InstalledBrowser(
                bundleIdentifier: identifier,
                name: displayName(of: bundle, at: appURL),
                appURL: appURL
            ))
        }
        return browsers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The name of the system default browser, for "System default (Safari)".
    static func defaultBrowserName() -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else { return nil }
        guard let bundle = Bundle(url: appURL) else { return appURL.deletingPathExtension().lastPathComponent }
        return displayName(of: bundle, at: appURL)
    }

    static func browserName(forBundleIdentifier identifier: String, fallback: String? = nil) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return fallback ?? identifier
        }
        guard let bundle = Bundle(url: appURL) else { return appURL.deletingPathExtension().lastPathComponent }
        return displayName(of: bundle, at: appURL)
    }

    private static func displayName(of bundle: Bundle, at appURL: URL) -> String {
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
            return name
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    /// The profiles a browser has right now.
    ///
    /// For Safari this reads its File menu, so Safari has to be running and
    /// ClipStack needs Accessibility; otherwise the list is empty and the user
    /// can type the profile's name instead.
    static func profiles(forBundleIdentifier identifier: String) -> [BrowserProfile] {
        switch BrowserProfileKind(bundleIdentifier: identifier) {
        case .unsupported:
            return []

        case .chromium(let supportPath):
            guard let file = applicationSupport(supportPath, "Local State"),
                  let data = try? Data(contentsOf: file)
            else { return [] }
            return BrowserProfileParser.chromiumProfiles(localState: data)

        case .firefox(let supportPath):
            guard let file = applicationSupport(supportPath, "profiles.ini"),
                  let text = try? String(contentsOf: file, encoding: .utf8)
            else { return [] }
            return BrowserProfileParser.firefoxProfiles(profilesINI: text)

        case .safari:
            return SafariProfiles.detect(bundleIdentifier: identifier)
                .map { BrowserProfile(id: $0, name: $0) }
        }
    }

    private static func applicationSupport(_ components: String...) -> URL? {
        guard var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        for component in components {
            url.appendPathComponent(component)
        }
        return url
    }

    // MARK: - Opening

    /// Opens `website` in its browser and profile.
    ///
    /// - Returns: a notice for the user when it opened, but not quite as asked
    ///   (Safari would not take the address directly, so it went in another
    ///   tab), or `nil` when it all went to plan.
    /// - Throws: when it could not be opened at all.
    @discardableResult
    static func open(_ website: Website) async throws -> String? {
        guard let url = website.url else {
            throw BrowserLaunchError.invalidAddress(website.address)
        }

        guard let identifier = website.browser.bundleIdentifier else {
            guard NSWorkspace.shared.open(url) else {
                throw BrowserLaunchError.couldNotOpen("no default browser")
            }
            return nil
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            throw BrowserLaunchError.browserNotInstalled(website.browser.browserName ?? identifier)
        }

        let kind = BrowserProfileKind(bundleIdentifier: identifier)
        guard website.browser.hasProfile, let profile = website.browser.profileID else {
            try await open([url], withApplicationAt: appURL)
            return nil
        }

        switch kind {
        case .unsupported:
            try await open([url], withApplicationAt: appURL)

        case .chromium:
            try await launchNewInstance(of: appURL, arguments: [
                "--profile-directory=\(profile)",
                url.absoluteString,
            ])

        case .firefox:
            try await launchNewInstance(of: appURL, arguments: ["-P", profile, url.absoluteString])

        case .safari:
            return try await SafariProfiles.open(url, inProfile: profile, bundleIdentifier: identifier, appURL: appURL)
        }
        return nil
    }

    static func open(_ urls: [URL], withApplicationAt appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// `open -n -a <app> --args …`: a new instance with these arguments. A
    /// browser that is already running receives them from that instance.
    private static func launchNewInstance(of appURL: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// "Safari · Work", "System default", "Chrome" — for menus and lists.
    static func label(for target: BrowserTarget) -> String {
        guard let identifier = target.bundleIdentifier else { return "Default browser" }
        let name = browserName(forBundleIdentifier: identifier, fallback: target.browserName)
        guard target.hasProfile else { return name }
        return "\(name) · \(target.profileName ?? target.profileID ?? "")"
    }
}

// MARK: - Safari

/// Safari profiles, driven through its windows and its File menu.
///
/// Uses the Accessibility permission ClipStack already asks for (to find a
/// profile's window, bring it forward, and press menu items), plus Automation
/// for Safari (macOS asks the first time) to put the address in a tab.
///
/// The address always lands in a window of the right profile:
///
///   1. If one is open, the frontmost such window comes forward and gets a new
///      tab with the address — the way a link opens.
///   2. If none is, File ▸ New <Profile> Window opens one, and the address goes
///      into its first tab, rather than beside an empty one.
@MainActor
enum SafariProfiles {

    /// Profile names from Safari's File menu, or `[]` when Safari is not running
    /// or ClipStack lacks Accessibility.
    static func detect(bundleIdentifier: String) -> [String] {
        guard AXIsProcessTrusted(), let safari = runningApp(bundleIdentifier) else { return [] }
        let application = AXUIElementCreateApplication(safari.processIdentifier)
        let titles = fileMenuItems(of: application).compactMap { title(of: $0) }
        return BrowserProfileParser.safariProfileNames(menuTitles: titles)
    }

    static func open(_ url: URL, inProfile profile: String, bundleIdentifier: String, appURL: URL) async throws -> String? {
        guard AXIsProcessTrusted() else { throw BrowserLaunchError.needsAccessibility }

        let safari = try await launchIfNeeded(bundleIdentifier: bundleIdentifier, appURL: appURL)
        let application = AXUIElementCreateApplication(safari.processIdentifier)

        // 1. A window of this profile is already open: a new tab in it.
        if let window = frontmostWindow(in: application, showingProfile: profile) {
            await bringForward(window, of: application, app: safari)
            if let failure = runScript(newTabInFrontWindow(url), bundleIdentifier: bundleIdentifier) {
                // The window is in front, so Safari's own way of opening an
                // address from another app — a new tab there — is the same thing.
                try await BrowserLauncher.open([url], withApplicationAt: appURL)
                return failure
            }
            return nil
        }

        // 2. None open: a new window of this profile, from Safari's File menu.
        // A Safari that has only just launched takes a moment to build its menus.
        guard let menuItem = await poll(timeout: .seconds(6), { profileMenuItem(in: application, profile: profile) }) else {
            throw BrowserLaunchError.safariProfileNotFound(profile)
        }

        let windowsBefore = windows(of: application).count
        safari.activate(options: [])
        guard AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success else {
            throw BrowserLaunchError.couldNotOpen("Safari did not open a \(profile) window")
        }

        // Wait for the new window to exist and be in front, so the address goes
        // into it and not into whatever window was in front before.
        _ = await poll(timeout: .seconds(3)) { () -> Bool? in
            windows(of: application).count > windowsBefore ? true : nil
        }
        try? await Task.sleep(for: .milliseconds(200))

        if let failure = runScript(addressInFrontTab(url), bundleIdentifier: bundleIdentifier) {
            try await BrowserLauncher.open([url], withApplicationAt: appURL)
            return failure
        }
        return nil
    }

    // MARK: Finding a profile's window

    /// The frontmost open, unminimised Safari window that belongs to `profile`.
    ///
    /// Safari does not say which profile a window belongs to in its scripting
    /// dictionary, but it shows it: a window of a non-default profile carries
    /// the profile's name in its toolbar. That label is what is looked for, in
    /// the toolbar only (never the page, never the tab titles, never the address
    /// field), so a page that happens to mention "Work" cannot match.
    private static func frontmostWindow(in application: AXUIElement, showingProfile profile: String) -> AXUIElement? {
        // AX lists windows front to back.
        windows(of: application).first { window in
            stringValue(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
                && boolValue(window, kAXMinimizedAttribute) != true
                && windowShowsProfile(window, profile)
        }
    }

    private static func windowShowsProfile(_ window: AXUIElement, _ profile: String) -> Bool {
        // Window titles of the form "Work — Page title".
        if let title = stringValue(window, kAXTitleAttribute) {
            for separator in [" \u{2014} ", " \u{2013} ", " - "] where title.hasPrefix(profile + separator) {
                return true
            }
        }

        // The profile label in the toolbar, searched breadth-first and bounded.
        var queue = elements(window, kAXChildrenAttribute)
            .filter { stringValue($0, kAXRoleAttribute) == (kAXToolbarRole as String) }
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst()
            visited += 1

            let role = stringValue(element, kAXRoleAttribute) ?? ""
            // Tab titles and the address field show page content, not chrome.
            if role == (kAXTabGroupRole as String) || role == (kAXTextFieldRole as String)
                || role == (kAXRadioButtonRole as String) || role == "AXWebArea" {
                continue
            }

            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if let text = stringValue(element, attribute), labelNamesProfile(text, profile) {
                    return true
                }
            }
            queue.append(contentsOf: elements(element, kAXChildrenAttribute))
        }
        return false
    }

    /// "Work", or a label that calls itself a profile and names it
    /// ("Work profile", "Profile: Work").
    private static func labelNamesProfile(_ label: String, _ profile: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare(profile) == .orderedSame { return true }
        guard text.range(of: "profile", options: .caseInsensitive) != nil else { return false }
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let profileWords = profile.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return !profileWords.isEmpty && profileWords.allSatisfy { word in
            words.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
        }
    }

    /// Raises `window` and waits until Safari reports it as its main window, so
    /// "front window" in the script that follows means this one.
    private static func bringForward(_ window: AXUIElement, of application: AXUIElement, app: NSRunningApplication) async {
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
        _ = await poll(timeout: .seconds(1)) { () -> Bool? in
            guard let main = element(application, kAXMainWindowAttribute) else { return nil }
            return CFEqual(main, window) ? true : nil
        }
    }

        // MARK: Safari process

    private static func runningApp(_ bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }
    }

    private static func launchIfNeeded(bundleIdentifier: String, appURL: URL) async throws -> NSRunningApplication {
        if let running = runningApp(bundleIdentifier) { return running }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        guard let launched = await poll(timeout: .seconds(5), { runningApp(bundleIdentifier) }) else {
            throw BrowserLaunchError.couldNotOpen("Safari did not start")
        }
        return launched
    }

    // MARK: AppleScript

    private static func quoted(_ url: URL) -> String {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A new tab at the end of the front window, made current.
    private static func newTabInFrontWindow(_ url: URL) -> String {
        """
        tell front window
            set current tab to (make new tab at end of tabs with properties {URL:\(quoted(url))})
        end tell
        """
    }

    /// The address in the front window's current tab — a fresh window's only tab.
    private static func addressInFrontTab(_ url: URL) -> String {
        "set URL of current tab of front window to \(quoted(url))"
    }

    /// Runs `body` inside `tell application id …`.
    /// - Returns: `nil` on success, otherwise what to tell the user.
    private static func runScript(_ body: String, bundleIdentifier: String) -> String? {
        let source = """
        tell application id "\(bundleIdentifier)"
        \(body)
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return "Opened in a new tab"
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return nil }

        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -1743 {
            // errAEEventNotPermitted: Automation for Safari is off for ClipStack.
            return "Allow ClipStack to control Safari: Settings ▸ Privacy ▸ Automation"
        }
        return "Safari script error \(code) — opened in a new tab"
    }

    // MARK: Accessibility

    /// The File menu's items, plus those of its submenus (newer Safari groups
    /// the "New … Window" items under File ▸ New Window).
    private static func fileMenuItems(of application: AXUIElement) -> [AXUIElement] {
        guard let menuBar = element(application, kAXMenuBarAttribute) else { return [] }
        let barItems = children(of: menuBar)

        // Matched by title in English, by position otherwise (Apple, Safari, File).
        let fileItem = barItems.first { title(of: $0) == "File" }
            ?? (barItems.count > 2 ? barItems[2] : nil)
        guard let fileItem else { return [] }

        var items: [AXUIElement] = []
        for item in menuItems(under: fileItem) {
            items.append(item)
            items.append(contentsOf: menuItems(under: item))
        }
        return items
    }

    private static func profileMenuItem(in application: AXUIElement, profile: String) -> AXUIElement? {
        let items = fileMenuItems(of: application)
        let wanted = BrowserProfileParser.safariMenuTitle(forProfile: profile)
        if let exact = items.first(where: { title(of: $0) == wanted }) {
            return exact
        }
        // Tolerate a profile renamed only in case.
        return items.first { item in
            guard let title = title(of: item),
                  let name = BrowserProfileParser.safariProfileName(fromMenuTitle: title)
            else { return false }
            return name.caseInsensitiveCompare(profile) == .orderedSame
        }
    }

    /// A menu bar item or menu item holds its menu as its only child.
    private static func menuItems(under item: AXUIElement) -> [AXUIElement] {
        children(of: item)
            .filter { role(of: $0) == (kAXMenuRole as String) }
            .flatMap { children(of: $0) }
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        elements(application, kAXWindowsAttribute)
    }

    private static func elements(_ parent: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return [] }
        return elements
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of parent: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: Waiting

    private static func poll<T>(
        timeout: Duration,
        interval: Duration = .milliseconds(100),
        _ probe: () -> T?
    ) async -> T? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let value = probe() { return value }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: interval)
        }
    }
}
