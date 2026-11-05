//
//  ScreenSnapshotter.swift
//  ClipStack
//
//  Freezes every display the moment the capture hotkey is pressed, using
//  ScreenCaptureKit (macOS 14+). The region picker then draws over these
//  frozen images, so menus, tooltips and hover states stay exactly as they
//  were — the way Shottr and the system screenshot tool behave.
//
//  Needs the Screen Recording permission. ClipStack's own windows (the HUD,
//  the recall panel) are left out of the image.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
}

enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to prompt (the first time) and returns the answer so far.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

@available(macOS 14.0, *)
enum ScreenSnapshotter {

    static func snapshotAllScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) })
            else { continue }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApp.map { [$0] } ?? [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            configuration.width = Int(screen.frame.width * scale)
            configuration.height = Int(screen.frame.height * scale)
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots.append(ScreenSnapshot(screen: screen, image: image))
        }
        return snapshots
    }
}
