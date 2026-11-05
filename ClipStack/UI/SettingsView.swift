//
//  SettingsView.swift
//  ClipStack
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var preferences: Preferences

    @State private var showingResetHelp = false

    var body: some View {
        TabView {
            stackTab
                .tabItem { Label("Stack", systemImage: "square.3.layers.3d") }
            savedTextsTab
                .tabItem { Label("Saved Texts", systemImage: "text.book.closed") }
            captureTab
                .tabItem { Label("Capture", systemImage: "text.viewfinder") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "command") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 440)
        .alert("Permission switch on, but ClipStack still can't see ⌘C?", isPresented: $showingResetHelp) {
            Button("Copy Command") {
                ClipboardManager.shared.write("tccutil reset All com.prathamesh.ClipStack")
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("""
            This happens when macOS is holding an old record for a previous copy of ClipStack — \
            a build at a different path, or one you have since deleted. They all share a bundle \
            identifier, so the switch you see may belong to a copy that no longer exists.

            Clear the old records by running this in Terminal, then quit and reopen ClipStack and \
            press “Request…”:

            tccutil reset All com.prathamesh.ClipStack
            """)
        }
    }

    // MARK: - Stack

    private var stackTab: some View {
        Form {
            Section("Paste Stack") {
                Picker("Join items with", selection: $preferences.separator) {
                    ForEach(StackSeparator.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                if preferences.separator == .custom {
                    TextField("Custom separator", text: $preferences.customSeparator)
                        .help("Use \\n for a line break.")
                }

                Toggle("Paste automatically into the frontmost app", isOn: $preferences.autoPasteEnabled)
                Text(preferences.autoPasteEnabled
                     ? "ClipStack presses ⌘V for you. Needs Accessibility access."
                     : "ClipStack only loads the clipboard — press ⌘V yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Empty the stack after pasting", isOn: $preferences.clearStackAfterPaste)
            }

            Section("Capture") {
                Toggle("Also add copies made without ⌘C", isOn: $preferences.captureCopiesWithoutShortcut)
                Text("""
                Screenshot-to-text tools like Shottr, Edit ▸ Copy and right-click ▸ Copy put text on the \
                clipboard without pressing ⌘C. With this on, ClipStack watches the clipboard while Stack \
                Mode is on and stacks those too. Items a password manager marks as private are skipped.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Auto-clear") {
                Picker("Clear the stack after", selection: Binding(
                    get: { preferences.autoClearTimeout },
                    set: { newValue in
                        preferences.autoClearTimeout = newValue
                        environment.stack.autoClearSettingChanged()
                    }
                )) {
                    Text("Off").tag(TimeInterval(0))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                    Text("1 hour").tag(TimeInterval(3600))
                }
                Text("Counts from the last item added. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - Saved texts

    private var savedTextsTab: some View {
        Form {
            Section("Storage") {
                LabeledContent("On this Mac") {
                    Text("\(environment.snippets.snippets.count) saved via \(environment.snippets.backendDescription)")
                        .foregroundStyle(.secondary)
                }

                if let error = environment.snippets.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Recall panel") {
                Toggle("Paste straight into the app on ↩", isOn: $preferences.recallAutoPaste)
                Text(preferences.recallAutoPaste
                     ? "↩ pastes the snippet into whatever you were working in. Needs Accessibility."
                     : "↩ copies the snippet to the clipboard so you can paste it yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.recallAutoPaste && !environment.permissions.canAutoPaste {
                    Label(
                        "Accessibility is not granted, so ↩ will copy instead of pasting.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("iCloud") {
                Toggle("Sync saved texts across my Macs", isOn: Binding(
                    get: { preferences.iCloudSyncEnabled },
                    set: { newValue in
                        preferences.iCloudSyncEnabled = newValue
                        environment.snippets.setCloudSyncEnabled(newValue)
                    }
                ))

                LabeledContent("Status") {
                    Text(environment.cloudSync.statusDescription)
                        .foregroundStyle(environment.cloudSync.status.isHealthy ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("""
                Saved texts sync through iCloud key-value storage, so they follow you between Macs \
                signed in to the same Apple Account. Edits merge per snippet — the most recent change \
                to a given snippet wins — and deletions carry across.

                Stack contents are never synced: a stack is a scratch buffer for what you are doing \
                right now on this Mac.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if case .unavailable = environment.cloudSync.status {
                    Label(
                        "Enable the iCloud capability for the ClipStack target in Xcode (Signing & Capabilities ▸ + Capability ▸ iCloud ▸ Key-value storage). See the README.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Capture

    private var captureTab: some View {
        Form {
            Section {
                Picker("Formatting", selection: $preferences.captureFormatting) {
                    ForEach(CaptureFormatting.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text(captureFormattingHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Use document recognition", isOn: $preferences.captureUsesDocumentRecognition)
                Text(documentRecognitionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Output", selection: $preferences.captureOutputStyle) {
                    ForEach(LayoutRenderer.Style.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("Show a preview", selection: $preferences.capturePreviewPolicy) {
                    ForEach(CapturePreviewPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            } header: {
                Text("Capture text from screen (\(preferences.captureTextHotKey?.displayString ?? "no shortcut"))")
            } footer: {
                Text("Captured text goes into the stack while Stack Mode is on, and onto the clipboard otherwise — with real bullets and tables for apps like Notes, Pages and Docs. Hold ⌥ when you let go of the drag for the text exactly as read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fixes to the recognised text") {
                Toggle("Turn a bullet read as “e” or “o” back into •", isOn: $preferences.captureFixMisreadBullets)
                Toggle("Join words hyphenated across a line break", isOn: $preferences.captureJoinHyphenatedWords)
                Toggle("Join lines that wrap within a paragraph or item", isOn: $preferences.captureJoinWrappedLines)
                Text("These are the only changes made to characters. Formatting never adds, drops or rewords anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permission") {
                permissionRow(
                    title: "Screen Recording",
                    granted: ScreenRecordingPermission.isGranted,
                    request: { ScreenRecordingPermission.request() },
                    open: { ScreenRecordingPermission.openSettings() }
                )
                Text("Needed to read the screen. macOS applies it after ClipStack is reopened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var documentRecognitionHelp: String {
        if #available(macOS 26, *) {
            return "macOS 26 reads lists, tables and titles as such — tables come out cell by cell even without clear gaps between columns. Off: line-by-line recognition only."
        }
        return "Needs macOS 26. Until then, captures use line-by-line recognition and the layout rules."
    }

    private var captureFormattingHelp: String {
        switch preferences.captureFormatting {
        case .off:
            return "Rows of text top to bottom, as Shottr or Live Text would give them."
        case .layout:
            return "Columns in the right order, bullets and numbering with their nesting, questions with their options, paragraphs, headings and tables."
        case .smart:
            return OnDeviceAI.isAvailable
                ? "Layout rules, plus Apple's on-device model to settle the reading order of captures with columns or side-by-side text. It can only reorder and group lines, never change them."
                : "Layout rules for now: \(OnDeviceAI.unavailableReason ?? "Apple Intelligence isn't available.")"
        }
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        Form {
            Section {
                shortcutRow(
                    action: .recall,
                    combo: preferences.recallHotKey,
                    allowsClearing: false
                ) { new in
                    if let new { preferences.recallHotKey = new }
                    environment.applyHotKeyBindings()
                }

                shortcutRow(
                    action: .pasteStack,
                    combo: preferences.pasteStackHotKey,
                    allowsClearing: false
                ) { new in
                    if let new { preferences.pasteStackHotKey = new }
                    environment.applyHotKeyBindings()
                }

                shortcutRow(
                    action: .resetStack,
                    combo: preferences.resetStackHotKey,
                    allowsClearing: false
                ) { new in
                    if let new { preferences.resetStackHotKey = new }
                    environment.applyHotKeyBindings()
                }

                shortcutRow(
                    action: .toggleStackMode,
                    combo: preferences.toggleStackModeHotKey,
                    allowsClearing: true
                ) { new in
                    preferences.toggleStackModeHotKey = new
                    environment.applyHotKeyBindings()
                }

                shortcutRow(
                    action: .captureText,
                    combo: preferences.captureTextHotKey,
                    allowsClearing: true
                ) { new in
                    preferences.captureTextHotKey = new
                    environment.applyHotKeyBindings()
                }

                shortcutRow(
                    action: .formatStack,
                    combo: preferences.formatStackHotKey,
                    allowsClearing: true
                ) { new in
                    preferences.formatStackHotKey = new
                    environment.applyHotKeyBindings()
                }
            } footer: {
                Text("⌘C is not a remappable shortcut: while Stack Mode is on ClipStack observes the system-wide copy keystroke without changing what it does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Default Shortcuts") {
                    preferences.resetShortcutsToDefaults()
                    environment.applyHotKeyBindings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(
        action: HotKeyAction,
        combo: KeyCombo?,
        allowsClearing: Bool,
        onChange: @escaping (KeyCombo?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                    Text(action.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ShortcutRecorderView(combo: combo, onChange: onChange, allowsClearing: allowsClearing)
            }

            // Carbon refuses shortcuts already owned by macOS or another app.
            if let failure = environment.hotKeyFailures[action] {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        Form {
            Section("Capturing ⌘C") {
                permissionRow(
                    title: "Accessibility",
                    granted: environment.permissions.isAccessibilityTrusted,
                    request: { environment.permissions.requestAccessibility() },
                    open: { environment.permissions.openAccessibilitySettings() }
                )
                permissionRow(
                    title: "Input Monitoring",
                    granted: environment.permissions.isInputMonitoringGranted,
                    request: { environment.permissions.requestInputMonitoring() },
                    open: { environment.permissions.openInputMonitoringSettings() }
                )

                LabeledContent("Currently using") {
                    Text(environment.stack.captureRoutes.description)
                        .foregroundStyle(.secondary)
                }

                Text("""
                macOS splits this across two settings, which is the usual reason a clipboard app \
                appears to do nothing. **Either one enables ⌘C capture** — Input Monitoring covers the \
                event tap, Accessibility covers the fallback monitor.

                **Accessibility is the one to grant**: it also lets ClipStack paste for you. Input \
                Monitoring alone cannot do that.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Re-check now") { environment.permissions.refresh() }
                    Button("Permission stuck?") { showingResetHelp = true }
                }
            }

            Section("Pasting for you") {
                LabeledContent("Auto-paste") {
                    Label(
                        environment.permissions.canAutoPaste ? "Available" : "Needs Accessibility",
                        systemImage: environment.permissions.canAutoPaste
                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(environment.permissions.canAutoPaste ? Color.green : Color.orange)
                }

                Text("""
                Used by Paste Stack and, if you turn it on, by the ⌥Space panel. Without it ClipStack \
                still puts the text on the clipboard for you to paste yourself.

                ClipStack only ever looks for the ⌘C keystroke, never what you type, and only while \
                Stack Mode is on. Saved texts and ⌥Space search need no permission at all.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("""
                Rebuilding or moving ClipStack makes macOS treat it as a new app. If it stops working \
                after a rebuild, remove the old entry with the “–” button and add the copy you are \
                running.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        request: @escaping () -> Void,
        open: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Label(
                    granted ? "Granted" : "Not granted",
                    systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(granted ? Color.green : Color.orange)

                if !granted {
                    // Asks macOS to prompt. This is the reliable route: it
                    // registers ClipStack with the privacy system under the
                    // identity of the binary that is actually running, rather
                    // than relying on the user finding the right row by hand.
                    // macOS only shows each prompt once per record, so it does
                    // nothing if a record already exists — hence "Reset" below.
                    Button("Request\u{2026}", action: request)
                    Button("Open\u{2026}", action: open)
                }
            }
        }
    }
}
