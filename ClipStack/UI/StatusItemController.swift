//
//  StatusItemController.swift
//  ClipStack
//
//  The menu bar icon and its dropdown.
//
//  SwiftUI's MenuBarExtra would cover most of this, but AppKit's NSStatusItem is
//  used instead for two reasons ClipStack actually needs: the icon has to carry
//  a live numeric badge drawn at runtime, and the HUD needs the icon's screen
//  rect to position itself under it.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let environment: AppEnvironment
    private var cancellables = Set<AnyCancellable>()

    /// Actions the dropdown triggers, owned by the app delegate.
    struct Actions {
        var openSavedTexts: () -> Void
        var openSettings: () -> Void
        var openRecallPanel: () -> Void
        var openWebsites: () -> Void
        var openWebsite: (Website) -> Void
        var quit: () -> Void
    }

    init(environment: AppEnvironment, actions: Actions) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        configurePopover(actions: actions)
        observeState()
        refreshIcon()
    }

    deinit {
        // Status items linger in the menu bar unless explicitly removed.
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Icon

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("ClipStack")
    }

    /// Screen rect of the menu bar icon, for anchoring the HUD.
    func statusItemFrame() -> NSRect? {
        guard let window = statusItem.button?.window else { return nil }
        return window.frame
    }

    /// Redraws the icon for the current Stack Mode state and item count.
    func refreshIcon() {
        guard let button = statusItem.button else { return }

        let isStacking = environment.stack.isEnabled
        let count = environment.stack.count
        let symbolName = isStacking ? "square.3.layers.3d.top.filled" : "square.3.layers.3d"

        button.image = Self.statusImage(symbolName: symbolName, badgeCount: isStacking ? count : 0)
        button.toolTip = isStacking
            ? "ClipStack — Stack Mode on, \(count) item\(count == 1 ? "" : "s")"
            : "ClipStack — Stack Mode off"
    }

    private func observeState() {
        // Any change to the stack or its on/off state redraws the badge.
        environment.stack.$entries
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshIcon() }
            }
            .store(in: &cancellables)

        environment.stack.$isEnabled
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshIcon() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Badge drawing

    /// Composes the SF Symbol with a small numeric badge in the top-right.
    ///
    /// The result is marked as a *template* image, which is what makes the icon
    /// handle Dark/Light Mode for free: macOS ignores the colours we draw and
    /// tints the shape to match the menu bar, including when the menu bar is
    /// inverted or the user has Increase Contrast on. To keep that working the
    /// number is *knocked out* of the badge (drawn with `.destinationOut`)
    /// rather than painted in a light colour — a hole stays legible under any
    /// tint, a white glyph would not.
    static func statusImage(symbolName: String, badgeCount: Int) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClipStack")?
            .withSymbolConfiguration(configuration)
        else { return nil }

        guard badgeCount > 0 else {
            symbol.isTemplate = true
            return symbol
        }

        let label = badgeCount > 99 ? "99+" : "\(badgeCount)"
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let labelSize = (label as NSString).size(withAttributes: [.font: font])

        let badgeHeight: CGFloat = 11
        let badgeWidth = max(badgeHeight, labelSize.width + 7)
        let symbolSize = symbol.size

        // Let the badge overhang the symbol slightly, as system badges do.
        let canvasSize = NSSize(
            width: symbolSize.width + badgeWidth - 5,
            height: max(symbolSize.height, badgeHeight + 3)
        )

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            let symbolOrigin = NSPoint(x: 0, y: (canvasSize.height - symbolSize.height) / 2)
            symbol.draw(
                at: symbolOrigin,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )

            let badgeRect = NSRect(
                x: canvasSize.width - badgeWidth,
                y: canvasSize.height - badgeHeight,
                width: badgeWidth,
                height: badgeHeight
            )

            NSColor.black.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

            // Punch the digits out of the badge so they read as a hole.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let labelOrigin = NSPoint(
                x: badgeRect.midX - labelSize.width / 2,
                y: badgeRect.midY - labelSize.height / 2
            )
            (label as NSString).draw(
                at: labelOrigin,
                withAttributes: [.font: font, .foregroundColor: NSColor.black]
            )
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            return true
        }

        image.isTemplate = true
        return image
    }

    // MARK: - Dropdown

    private func configurePopover(actions: Actions) {
        popover.behavior = .transient      // closes when the user clicks away
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(actions: actions)
                .environmentObject(environment)
                .environmentObject(environment.preferences)
        )
    }

    @objc private func statusItemClicked() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        // As an LSUIElement app we are not frontmost, so the popover's controls
        // would come up inactive without this.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover.performClose(nil)
    }
}
