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

    static func open(_ website: Website) async throws {
        guard let url = website.url else {
            throw BrowserLaunchError.invalidAddress(website.address)
        }

        guard let identifier = website.browser.bundleIdentifier else {
            guard NSWorkspace.shared.open(url) else {
                throw BrowserLaunchError.couldNotOpen("no default browser")
            }
            return
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            throw BrowserLaunchError.browserNotInstalled(website.browser.browserName ?? identifier)
        }

        let kind = BrowserProfileKind(bundleIdentifier: identifier)
        guard website.browser.hasProfile, let profile = website.browser.profileID else {
            try await open([url], withApplicationAt: appURL)
            return
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
            try await SafariProfiles.open(url, inProfile: profile, bundleIdentifier: identifier, appURL: appURL)
        }
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

/// Safari profiles, driven through its File menu.
///
/// Uses the Accessibility permission ClipStack already asks for (to read and
/// press menu items), plus Automation for Safari (macOS asks the first time)
/// to point the new window at the URL.
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

    static func open(_ url: URL, inProfile profile: String, bundleIdentifier: String, appURL: URL) async throws {
        guard AXIsProcessTrusted() else { throw BrowserLaunchError.needsAccessibility }

        let safari = try await launchIfNeeded(bundleIdentifier: bundleIdentifier, appURL: appURL)
        let application = AXUIElementCreateApplication(safari.processIdentifier)

        // A Safari that has only just launched takes a moment to build its menus.
        guard let menuItem = await poll(timeout: .seconds(6), { profileMenuItem(in: application, profile: profile) }) else {
            throw BrowserLaunchError.safariProfileNotFound(profile)
        }

        let windowsBefore = windowCount(of: application)
        safari.activate(options: [])
        guard AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success else {
            throw BrowserLaunchError.couldNotOpen("Safari did not open a \(profile) window")
        }

        // Wait for the new window, so the URL lands in it and not in whatever
        // window was in front before.
        _ = await poll(timeout: .seconds(3)) { () -> Bool? in windowCount(of: application) > windowsBefore ? true : nil }
        try? await Task.sleep(for: .milliseconds(150))

        if !pointFrontWindow(at: url, bundleIdentifier: bundleIdentifier) {
            // Automation for Safari was refused. The new profile window is in
            // front, so handing Safari the URL normally still opens it there in
            // most setups — better than not opening it at all.
            try await BrowserLauncher.open([url], withApplicationAt: appURL)
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

    /// `set URL of current tab of front window`. Returns false if macOS refused
    /// (Automation not granted) or Safari had no window.
    private static func pointFrontWindow(at url: URL, bundleIdentifier: String) -> Bool {
        let address = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(bundleIdentifier)"
            set URL of current tab of front window to "\(address)"
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
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

    private static func windowCount(of application: AXUIElement) -> Int {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return 0 }
        return windows.count
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
