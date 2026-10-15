//
//  HUDController.swift
//  ClipStack
//
//  The small transient confirmation that appears under the menu bar icon
//  ("Added to stack (3)", "Copied ✓", …).
//
//  It is an NSPanel rather than a notification so it never steals focus: the
//  user is mid-⌘C in another app and must stay there. `.nonactivatingPanel`
//  plus `ignoresMouseEvents` means the HUD cannot take the keyboard or swallow
//  a click.
//

import AppKit
import SwiftUI

@MainActor
final class HUDController {

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    /// Where to put the HUD — supplied by StatusItemController so it hangs off
    /// the menu bar icon. Falls back to the top-right of the main screen if the
    /// status item has no window yet.
    var anchorProvider: (() -> NSRect?)?

    /// Shows `message` with an SF Symbol, replacing any HUD already on screen.
    func show(_ message: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.4) {
        dismissWorkItem?.cancel()

        let hostingView = NSHostingView(rootView: HUDView(message: message, symbol: symbol))
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize

        let panel = existingOrNewPanel()
        panel.contentView = hostingView
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(originPoint(for: size))

        panel.alphaValue = 0
        panel.orderFrontRegardless()   // no activation: we must not take focus
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let dismiss = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Above normal windows and visible on whichever Space the user is on,
        // including over a full-screen app.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        self.panel = panel
        return panel
    }

    /// Top-left point for the HUD, centred under the status item and kept on screen.
    private func originPoint(for size: NSSize) -> NSPoint {
        let anchor = anchorProvider?()
        let screen = NSScreen.screens.first { screen in
            guard let anchor else { return false }
            return screen.frame.intersects(anchor)
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let topY = (anchor?.minY ?? visible.maxY) - 6

        var x = (anchor.map { $0.midX - size.width / 2 }) ?? (visible.maxX - size.width - 16)
        // Never let the HUD hang off the edge of the display.
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        return NSPoint(x: x, y: topY)
    }
}

// MARK: - View

private struct HUDView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        // Glass (or the material below macOS 26) resolves against the system
        // appearance, so the HUD follows Dark/Light Mode with no code of our own.
        .glassSurface(in: Capsule(style: .continuous))
        .fixedSize()
    }
}
