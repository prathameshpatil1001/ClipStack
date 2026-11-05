//
//  RegionSelectionOverlay.swift
//  ClipStack
//
//  The "drag a box" step of screen-text capture: one borderless window per
//  display showing the frozen snapshot, dimmed, with the selection shown at
//  full brightness. Esc cancels. Holding ⌥ when releasing the mouse asks for
//  raw text, with no formatting.
//

import AppKit

struct RegionSelection {
    let snapshot: ScreenSnapshot
    /// The selected pixels, cut from the snapshot.
    let image: CGImage
    /// ⌥ was held: the user wants the recognised text exactly as read.
    let wantsRawText: Bool
}

@MainActor
final class RegionSelectionOverlay {

    private var windows: [NSWindow] = []
    private var completion: ((RegionSelection?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func begin(with snapshots: [ScreenSnapshot], completion: @escaping (RegionSelection?) -> Void) {
        finish(nil)
        self.completion = completion

        for snapshot in snapshots {
            let window = OverlayWindow(
                contentRect: snapshot.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrame(snapshot.screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.hasShadow = false
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true

            let view = SelectionView(snapshot: snapshot) { [weak self] selection in
                self?.finish(selection)
            }
            view.frame = NSRect(origin: .zero, size: snapshot.screen.frame.size)
            window.contentView = view
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        // The screen under the pointer takes the keyboard, for Esc.
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ selection: RegionSelection?) {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        let completion = self.completion
        self.completion = nil
        completion?(selection)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {

    private let snapshot: ScreenSnapshot
    private let onFinish: (RegionSelection?) -> Void
    private var anchor: NSPoint?
    private var current: NSPoint?

    init(snapshot: ScreenSnapshot, onFinish: @escaping (RegionSelection?) -> Void) {
        self.snapshot = snapshot
        self.onFinish = onFinish
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: NSRect? {
        guard let anchor, let current else { return nil }
        return NSRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(snapshot.image, in: bounds)

        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()

        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else {
            drawHint()
            return
        }

        // The selection at full brightness, outlined, with its size.
        context.saveGState()
        context.clip(to: rect)
        context.draw(snapshot.image, in: bounds)
        context.restoreGState()

        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()

        let scale = snapshot.screen.backingScaleFactor
        let label = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let labelOrigin = NSPoint(x: rect.minX, y: max(rect.minY - size.height - 6, 4))
        let background = NSRect(origin: labelOrigin, size: size).insetBy(dx: -5, dy: -2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        label.draw(at: labelOrigin, withAttributes: attributes)
    }

    private func drawHint() {
        let hint = "Drag over the text to capture · ⌥ for raw text · Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 80)
        let background = NSRect(origin: origin, size: size).insetBy(dx: -14, dy: -8)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: background, xRadius: background.height / 2, yRadius: background.height / 2).fill()
        hint.draw(at: origin, withAttributes: attributes)
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width >= 6, rect.height >= 6 else {
            // A click, not a drag: start again.
            anchor = nil
            current = nil
            needsDisplay = true
            return
        }
        guard let cropped = crop(rect) else {
            onFinish(nil)
            return
        }
        onFinish(RegionSelection(
            snapshot: snapshot,
            image: cropped,
            wantsRawText: event.modifierFlags.contains(.option)
        ))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onFinish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish(nil)
    }

    /// The selection in the snapshot's pixels (whose origin is top-left).
    private func crop(_ rect: NSRect) -> CGImage? {
        let image = snapshot.image
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let pixels = CGRect(
            x: rect.minX * scaleX,
            y: (bounds.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral
        return image.cropping(to: pixels)
    }
}
