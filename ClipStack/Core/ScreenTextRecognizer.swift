//
//  ScreenTextRecognizer.swift
//  ClipStack
//
//  Apple's on-device text recognition (Vision) over a captured image, giving
//  each line with its position, plus whether a bullet mark sits just left of
//  it (see BulletProbe). Runs off the main thread: accurate recognition takes
//  a moment on a large capture.
//
//  On macOS 26 it uses document recognition (RecognizeDocumentsRequest),
//  which understands lists, tables and titles itself:
//
//   • tables come back cell by cell, and go into the layout as they are;
//   • each list item's marker is applied to its first line — a bullet the
//     pixels didn't show, or a "1." / "a." the line's text left out;
//   • lines recognised as a title become headings.
//
//  Reading order, columns, nesting and paragraphs are still worked out by
//  TextLayout. Anywhere else, or if document recognition finds nothing, it
//  falls back to line recognition.
//

import CoreGraphics
import Foundation
import Vision

nonisolated enum ScreenTextRecognizer {

    /// Everything in `image`: document recognition on macOS 26 when
    /// `preferDocument` is on, line recognition otherwise.
    static func recognizePage(_ image: CGImage, preferDocument: Bool) async throws -> RecognizedPage {
        #if compiler(>=6.2)
        if preferDocument {
            if #available(macOS 26.0, *) {
                if let page = try? await recognizeDocument(image), !page.lines.isEmpty {
                    return page
                }
            }
        }
        #endif
        return RecognizedPage(lines: try recognize(image), tables: [], usedDocumentRecognition: false)
    }

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

    // MARK: - macOS 26 document recognition

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func recognizeDocument(_ image: CGImage) async throws -> RecognizedPage {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: image, orientation: nil)
        guard let document = observations.first?.document else {
            return RecognizedPage(lines: [], tables: [], usedDocumentRecognition: true)
        }

        let size = CGSize(width: image.width, height: image.height)
        func rect(_ region: NormalizedRegion) -> CGRect {
            region.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        }

        var lines: [OCRLine] = document.text.lines.compactMap { observation in
            let text = observation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = rect(observation.boundingRegion)
            var line = OCRLine(
                text: text,
                minX: Double(box.minX),
                minY: Double(box.minY),
                width: Double(box.width),
                height: Double(box.height)
            )
            line.isTitle = observation.isTitle
            line.hasBulletMark = !startsWithBulletGlyph(text) && hasBulletMark(leftOf: line, in: image)
            return line
        }

        applyListMarkers(from: document, to: &lines, rect: rect)

        let tables: [DetectedTable] = document.tables.compactMap { table in
            detectedTable(table, box: rect(table.boundingRegion))
        }
        return RecognizedPage(lines: lines, tables: tables, usedDocumentRecognition: true)
    }

    /// Gives each list item's first line its marker, nested lists included.
    @available(macOS 26.0, *)
    private static func applyListMarkers(
        from container: DocumentObservation.Container,
        to lines: inout [OCRLine],
        rect: (NormalizedRegion) -> CGRect
    ) {
        for list in container.lists {
            for item in list.items {
                let itemBox = rect(item.content.text.boundingRegion)
                if let index = firstLine(of: itemBox, in: lines) {
                    let marker = item.markerString.trimmingCharacters(in: .whitespaces)
                    var line = lines[index]
                    let alreadyMarked = line.hasBulletMark || startsWithBulletGlyph(line.text)
                        || (!marker.isEmpty && line.text.hasPrefix(marker))
                    if !alreadyMarked {
                        switch item.markerType {
                        case .decimal?, .compositeDecimal?, .decorativeDecimal?, .lowercaseLatin?, .uppercaseLatin?:
                            // The number or letter is in the document; put it back.
                            if !marker.isEmpty { line.text = marker + " " + line.text }
                        default:
                            line.hasBulletMark = true
                        }
                        lines[index] = line
                    }
                }
                applyListMarkers(from: item.content, to: &lines, rect: rect)
            }
        }
    }

    /// The top line inside an item's box.
    private static func firstLine(of box: CGRect, in lines: [OCRLine]) -> Int? {
        let slack = 2.0
        let candidates = lines.indices.filter { index in
            let line = lines[index]
            return line.midY >= Double(box.minY) - slack && line.midY <= Double(box.maxY) + slack
                && line.maxX > Double(box.minX) - line.height * 2 && line.minX < Double(box.maxX)
        }
        return candidates.min { lines[$0].minY < lines[$1].minY }
    }

    /// A recognised table as rows of cell text. A cell spanning rows is put in
    /// its first row only, so no text is repeated.
    @available(macOS 26.0, *)
    private static func detectedTable(_ table: DocumentObservation.Container.Table, box: CGRect) -> DetectedTable? {
        let allCells = table.rows.flatMap { $0 }
        let columnCount = (allCells.map(\.columnRange.upperBound).max() ?? -1) + 1
        guard table.rows.count >= 2, columnCount >= 2 else { return nil }

        // Whether each row lists its cells by their own row index; if not,
        // spans can't be told apart and every cell is taken as it comes.
        let indicesMatch = table.rows.enumerated().allSatisfy { index, cells in
            cells.allSatisfy { $0.rowRange.contains(index) }
        }

        let rows: [[String]] = table.rows.enumerated().map { index, cells in
            var row = Array(repeating: "", count: columnCount)
            for cell in cells where !indicesMatch || cell.rowRange.lowerBound == index {
                let column = cell.columnRange.lowerBound
                guard row.indices.contains(column) else { continue }
                row[column] = cell.content.text.transcript
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            return row
        }
        return DetectedTable(
            minX: Double(box.minX),
            minY: Double(box.minY),
            width: Double(box.width),
            height: Double(box.height),
            rows: rows
        )
    }
    #endif

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
