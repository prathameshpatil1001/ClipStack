//
//  ShortcutRecorderView.swift
//  ClipStack
//
//  Click-to-record control for remapping a global shortcut.
//
//  While recording it installs a *local* NSEvent monitor: local monitors only
//  see events already delivered to ClipStack's own key window, so recording
//  needs no Accessibility permission and cannot observe other apps. Returning
//  `nil` swallows the keystroke so the Settings window does not also act on it.
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorderView: View {
    let combo: KeyCombo?
    /// `nil` means the user cleared the shortcut.
    let onChange: (KeyCombo?) -> Void
    var allowsClearing: Bool = true

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording
                                  ? Color.accentColor.opacity(0.22)
                                  : Color.primary.opacity(isHovering ? 0.12 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to record a shortcut")

            if allowsClearing && combo != nil && !isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press keys\u{2026}" }
        return combo?.displayString ?? "Not set"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Modifier presses on their own just update the preview; wait for a
            // real key.
            guard event.type == .keyDown else { return nil }

            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)

            // A modifier-less global hotkey would hijack a plain key system-wide.
            guard candidate.isValid else { return nil }

            onChange(candidate)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
