#!/usr/bin/env swift
//
//  generate-app-icon.swift
//  ClipStack
//
//  Draws the app icon at every size macOS asks for and writes it into
//  Assets.xcassets, so the artwork is reproducible from source rather than a
//  set of binaries nobody can edit.
//
//  The glyph is drawn by hand on purpose: SF Symbols are licensed for use in
//  an app's interface, not in its icon.
//
//  Usage:  swift Scripts/generate-app-icon.swift
//

import AppKit
import Foundation

let iconSet = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("ClipStack/Assets.xcassets/AppIcon.appiconset")

/// (filename, pixel size) for the macOS icon set.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",     32),
    ("icon_32x32",      32), ("icon_32x32@2x",     64),
    ("icon_128x128",   128), ("icon_128x128@2x",  256),
    ("icon_256x256",   256), ("icon_256x256@2x",  512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

/// Draws the icon into the current CG context at `size` × `size` points.
func drawIcon(size: CGFloat, context: CGContext) {
    // macOS icons do not fill their canvas: the rounded body sits inside a
    // margin, which is what makes an icon look right next to Apple's own.
    let bodyInset = size * 0.0975
    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: size - bodyInset * 2, height: size - bodyInset * 2)
    // Apple's continuous-corner radius is close to 22.37% of the body width.
    let cornerRadius = body.width * 0.2237

    // Soft drop shadow, skipped at small sizes where it would just add mud.
    if size >= 128 {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                          blur: size * 0.03,
                          color: NSColor.black.withAlphaComponent(0.28).cgColor)
    }

    let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)
    context.addPath(bodyPath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()

    if size >= 128 { context.restoreGState() }

    // Indigo→blue gradient, lighter at the top like macOS system icons.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(srgbRed: 0.42, green: 0.53, blue: 0.99, alpha: 1).cgColor,
            NSColor(srgbRed: 0.30, green: 0.33, blue: 0.90, alpha: 1).cgColor,
            NSColor(srgbRed: 0.36, green: 0.20, blue: 0.78, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )

    // A faint top highlight so the surface reads as slightly convex.
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY + body.height * 0.08),
        options: []
    )
    context.restoreGState()

    // The glyph: three stacked cards, the front one brightest — a stack of
    // copied things, which is the whole idea of the app.
    let cardWidth = body.width * 0.50
    let cardHeight = body.height * 0.135
    let cardRadius = cardHeight * 0.34
    let step = body.height * 0.152

    let layers: [(offset: CGFloat, scale: CGFloat, alpha: CGFloat)] = [
        (step, 0.78, 0.42),      // back card, narrowest and dimmest
        (0, 0.89, 0.68),         // middle
        (-step, 1.0, 1.0),       // front card, full width and opaque
    ]

    for layer in layers {
        let width = cardWidth * layer.scale
        let rect = CGRect(
            x: body.midX - width / 2,
            y: body.midY + layer.offset - cardHeight / 2,
            width: width,
            height: cardHeight
        )
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cardRadius,
                               cornerHeight: cardRadius, transform: nil))
        context.setFillColor(NSColor.white.withAlphaComponent(layer.alpha).cgColor)
        context.fillPath()
    }
}

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    nsContext.cgContext.setAllowsAntialiasing(true)
    nsContext.cgContext.interpolationQuality = .high
    drawIcon(size: CGFloat(pixels), context: nsContext.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

var images: [[String: String]] = []
for variant in variants {
    guard let data = renderPNG(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("Failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    let filename = "\(variant.name).png"
    try data.write(to: iconSet.appendingPathComponent(filename))

    let points = variant.name.hasSuffix("@2x") ? variant.pixels / 2 : variant.pixels
    images.append([
        "filename": filename,
        "idiom": "mac",
        "scale": variant.name.hasSuffix("@2x") ? "2x" : "1x",
        "size": "\(points)x\(points)",
    ])
    print("wrote \(filename) (\(variant.pixels)px, \(data.count) bytes)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "clipstack-generate-app-icon", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
