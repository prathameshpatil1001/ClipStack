//
//  WebsitesWindow.swift
//  ClipStack
//
//  Manage saved websites: add, edit, reorder, delete, and choose the browser
//  (and browser profile) each one opens in.
//

import AppKit
import SwiftUI

struct WebsitesView: View {
    @ObservedObject var store: WebsiteStore
    /// Opens a website the same way the menu bar does, with its error reporting.
    let open: (Website) -> Void

    @State private var selection: Set<UUID> = []
    @State private var editorTarget: EditorTarget?

    private enum EditorTarget: Identifiable {
        case new
        case existing(Website)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let website): return website.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.websites.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                WebsiteEditorView(website: nil) { store.add($0) }
            case .existing(let website):
                WebsiteEditorView(website: website) { store.update($0) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                editorTarget = .new
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("Add a website")

            Spacer()

            Text("\(store.websites.count) website\(store.websites.count == 1 ? "" : "s") · open them from the menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.websites) { website in
                WebsiteRow(website: website, open: { open(website) })
                    .tag(website.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editorTarget = .existing(website) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.delete(website)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Open") { open(website) }
                        Button("Edit\u{2026}") { editorTarget = .existing(website) }
                        Button("Copy Address") {
                            ClipboardManager.shared.write(website.url?.absoluteString ?? website.address)
                        }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(website) }
                    }
            }
            .onMove { source, destination in
                store.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            store.delete(ids: selection)
            selection = []
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No websites yet")
                .font(.headline)
            Text("Add the sites you open all the time, and pick the browser — and profile — each one belongs in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Add Website") { editorTarget = .new }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct WebsiteRow: View {
    let website: Website
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(website.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(website.url?.absoluteString ?? website.address)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(BrowserLauncher.label(for: website.browser))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button("Open", action: open)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor

struct WebsiteEditorView: View {
    let website: Website?
    let onSave: (Website) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var address: String
    /// "" means the system default browser.
    @State private var browserID: String
    /// "" means the browser's own default profile.
    @State private var profileID: String
    @State private var profileName: String

    @State private var browsers: [InstalledBrowser] = []
    @State private var detectedProfiles: [BrowserProfile] = []
    @State private var defaultBrowserName: String?
    @State private var hasLoaded = false

    init(website: Website?, onSave: @escaping (Website) -> Void) {
        self.website = website
        self.onSave = onSave
        _name = State(initialValue: website?.name ?? "")
        _address = State(initialValue: website?.address ?? "")
        _browserID = State(initialValue: website?.browser.bundleIdentifier ?? "")
        _profileID = State(initialValue: website?.browser.profileID ?? "")
        _profileName = State(initialValue: website?.browser.profileName ?? "")
    }

    private var normalizedURL: URL? { Website.normalizedURL(from: address) }

    private var canSave: Bool { normalizedURL != nil }

    private var profileKind: BrowserProfileKind {
        browserID.isEmpty ? .unsupported : BrowserProfileKind(bundleIdentifier: browserID)
    }

    private var selectedBrowser: InstalledBrowser? {
        browsers.first { $0.bundleIdentifier == browserID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(website == nil ? "New Website" : "Edit Website")
                .font(.headline)

            field("Name") {
                TextField("Optional", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Address") {
                TextField("example.com", text: $address)
                    .textFieldStyle(.roundedBorder)
                if !address.trimmingCharacters(in: .whitespaces).isEmpty && normalizedURL == nil {
                    Text("Enter a web address, like github.com or https://example.com/page")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            field("Open in") {
                Picker("Browser", selection: $browserID) {
                    Text(defaultBrowserName.map { "Default browser (\($0))" } ?? "Default browser").tag("")
                    if !browsers.isEmpty { Divider() }
                    ForEach(browsers) { browser in
                        Label {
                            Text(browser.name)
                        } icon: {
                            Image(nsImage: browser.icon)
                        }
                        .tag(browser.bundleIdentifier)
                    }
                    // A browser chosen earlier and since uninstalled stays visible.
                    if !browserID.isEmpty && selectedBrowser == nil && hasLoaded {
                        Text(website?.browser.browserName ?? browserID).tag(browserID)
                    }
                }
                .labelsHidden()
                .onChange(of: browserID) { _ in
                    profileID = ""
                    profileName = ""
                    reloadProfiles()
                }
            }

            if profileKind.supportsProfiles {
                profileSection
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard !hasLoaded else { return }
            browsers = BrowserLauncher.installedBrowsers()
            defaultBrowserName = BrowserLauncher.defaultBrowserName()
            reloadProfiles()
            hasLoaded = true
        }
    }

    // MARK: Profile

    @ViewBuilder
    private var profileSection: some View {
        if profileKind == .safari {
            field("Safari profile") {
                HStack(spacing: 6) {
                    TextField("Default profile", text: Binding(
                        get: { profileName },
                        set: { newValue in
                            profileName = newValue
                            profileID = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Menu("Detected") {
                        if detectedProfiles.isEmpty {
                            Text("Open Safari, then press Refresh")
                        }
                        ForEach(detectedProfiles) { profile in
                            Button(profile.name) {
                                profileID = profile.id
                                profileName = profile.name
                            }
                        }
                        Divider()
                        Button("Refresh") { reloadProfiles() }
                    }
                    .fixedSize()
                }
                Text(safariProfileHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            field("Profile") {
                HStack(spacing: 6) {
                    Picker("Profile", selection: Binding(
                        get: { profileID },
                        set: { newValue in
                            profileID = newValue
                            profileName = detectedProfiles.first(where: { $0.id == newValue })?.name ?? ""
                        }
                    )) {
                        Text("Browser's default").tag("")
                        ForEach(detectedProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                        // A saved profile the browser no longer lists.
                        if !profileID.isEmpty && !detectedProfiles.contains(where: { $0.id == profileID }) {
                            Text(profileName.isEmpty ? profileID : profileName).tag(profileID)
                        }
                    }
                    .labelsHidden()

                    Button {
                        reloadProfiles()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Read the profiles again")
                }
                if detectedProfiles.isEmpty {
                    Text("No profiles found. Open the browser once, then refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var safariProfileHelp: String {
        var help = "Type the name exactly as Safari shows it in File ▸ New Window (for “New Work Window”, type Work). Leave empty for Safari's own default."
        if !BrowserLauncher.canUseSafariMenus {
            help += " Needs Accessibility, so ClipStack can use that menu."
        } else {
            help += " The first time, macOS asks to let ClipStack control Safari."
        }
        return help
    }

    private func reloadProfiles() {
        detectedProfiles = browserID.isEmpty ? [] : BrowserLauncher.profiles(forBundleIdentifier: browserID)
    }

    private func save() {
        var target = BrowserTarget()
        if !browserID.isEmpty {
            target.bundleIdentifier = browserID
            target.browserName = selectedBrowser?.name ?? website?.browser.browserName
            let trimmedProfile = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
            if profileKind.supportsProfiles && !trimmedProfile.isEmpty {
                target.profileID = trimmedProfile
                let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                target.profileName = trimmedName.isEmpty ? trimmedProfile : trimmedName
            }
        }

        var saved = website ?? Website(name: "", address: "")
        saved.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.browser = target
        onSave(saved)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
