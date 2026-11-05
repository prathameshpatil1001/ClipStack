//
//  ScreenTextRecognizer.swift
//  ClipStack
//
//  Apple's on-device text recognition (Vision) over a captured image, giving
//  each line with its position, plus whether a bullet mark sits just left of
//  it (see BulletProbe). Runs off the main thread: accurate recognition takes
//  a moment on a large capture.
//

import CoreGraphics
import Foundation
import Vision

nonisolated enum ScreenTextRecognizer {

    /// Lines in `image`, positioned in its pixels, origin top-left.
    static func recognize(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let width = Double(image.width)
        let height = Double(image.height)

        return (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            // Vision's boxes are normalised with the origin bottom-left.
            let box = observation.boundingBox
            var line = OCRLine(
                text: text,
                minX: Double(box.minX) * width,
                minY: (1 - Double(box.maxY)) * height,
                width: Double(box.width) * width,
                height: Double(box.height) * height
            )
            line.hasBulletMark = !startsWithBulletGlyph(text) && hasBulletMark(leftOf: line, in: image)
            return line
        }
    }

    private static func startsWithBulletGlyph(_ text: String) -> Bool {
        ListMarkerGlyphs.all.contains { text.hasPrefix($0) }
    }

    /// Looks at the strip just left of `line` for a bullet.
    private static func hasBulletMark(leftOf line: OCRLine, in image: CGImage) -> Bool {
        let stripWidth = line.height * 1.6
        let gapToText = line.height * 0.1
        let stripMinX = max(0, line.minX - stripWidth - gapToText)
        let stripMaxX = line.minX - gapToText
        guard stripMaxX - stripMinX >= line.height * 0.5 else { return false }

        let strip = CGRect(x: stripMinX, y: line.minY, width: stripMaxX - stripMinX, height: line.height).integral
        guard let pixels = grayPixels(of: image, in: strip) else { return false }

        // The strip is kept narrow (1.6 line heights): a bullet sits right
        // before the text, and a wider strip could reach another column.
        return BulletProbe.looksLikeBullet(gray: pixels.values, width: pixels.width, height: pixels.height)
    }

    private static func grayPixels(of image: CGImage, in rect: CGRect) -> (values: [UInt8], width: Int, height: Int)? {
        guard let cropped = image.cropping(to: rect) else { return nil }
        let width = cropped.width, height = cropped.height
        guard width > 0, height > 0 else { return nil }

        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (values, width, height) : nil
    }
}

/// Characters that already mark a recognised line as a list item.
nonisolated enum ListMarkerGlyphs {
    static let all = ["•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "►", "▸", "·"]
}
