//
//  ScreenTextRecognizer.swift
//  ClipStack
//
//  Apple's on-device text recognition (Vision) over a captured image, giving
//  each line with its position, plus whether a bullet mark sits just left of
//  it (see BulletProbe). Runs off the main thread: accurate recognition takes
//  a moment on a large capture.
//
//  The lines always come from line recognition (VNRecognizeTextRequest): one
//  observation per visual line, which the layout rules depend on. Document
//  recognition's own "lines" are not reliably visual lines — it can fold an
//  answer column's letters away and run several options into one line.
//
//  On macOS 26, document recognition (RecognizeDocumentsRequest) then adds
//  what it understands on top, matched to those lines by position:
//
//   • tables, cell by cell, which go into the layout as they are;
//   • list items' markers, applied to each item's first line — a bullet the
//     pixels didn't show, or a "1." / "a." the line's text left out — unless
//     the marker is already there as text or as its own piece of the row;
//   • titles, which become headings.
//
//  Reading order, columns, nesting and paragraphs are worked out by TextLayout.
//

import CoreGraphics
import Foundation
import Vision

/// What document recognition adds to the recognised lines.
nonisolated struct DocumentStructure {
    nonisolated struct ListItemHint {
        /// The item's text, not including its marker, in image pixels.
        var box: CGRect
        var marker: String
        /// A number or letter (put back as text) rather than a bullet.
        var isOrdered: Bool
    }

    var tables: [DetectedTable] = []
    var listItems: [ListItemHint] = []
    var titleBoxes: [CGRect] = []
}

nonisolated enum ScreenTextRecognizer {

    /// Everything in `image`: its lines, plus on macOS 26 (when
    /// `preferDocument` is on) the tables, list markers and titles document
    /// recognition finds.
    static func recognizePage(_ image: CGImage, preferDocument: Bool) async throws -> RecognizedPage {
        var lines = recoverMarkers(in: try recognize(image), image: image)
        var tables: [DetectedTable] = []
        var usedDocumentRecognition = false

        #if compiler(>=6.2)
        if preferDocument, !lines.isEmpty {
            if #available(macOS 26.0, *) {
                if let structure = try? await documentStructure(of: image) {
                    apply(structure, to: &lines)
                    tables = structure.tables
                    usedDocumentRecognition = true
                }
            }
        }
        #endif

        return RecognizedPage(lines: lines, tables: tables, usedDocumentRecognition: usedDocumentRecognition)
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

    // MARK: - Recovering markers recognition missed

    /// Option letters (and numbers) recognition didn't read, found where a
    /// marker column says they should be — see MarkerRecovery — and added as
    /// pieces of their rows, which the layout joins to the text.
    static func recoverMarkers(in lines: [OCRLine], image: CGImage) -> [OCRLine] {
        let columns = MarkerRecovery.columns(in: lines)
        guard !columns.isEmpty else { return lines }
        let slots = MarkerRecovery.slots(in: lines, columns: columns)
        guard !slots.isEmpty else { return lines }
        let h = MarkerRecovery.lineHeight(lines)

        // Look at each slot: a mark there is a marker; none, a wrapped line.
        var inked: [Int: (values: [UInt8], width: Int, height: Int)] = [:]
        for (index, slot) in slots.enumerated() {
            let rect = CGRect(x: slot.minX, y: slot.minY, width: slot.width, height: slot.height).integral
            guard let pixels = grayPixels(of: image, in: rect),
                  MarkerRecovery.hasInk(gray: pixels.values, width: pixels.width, height: pixels.height)
            else { continue }
            inked[index] = pixels
        }
        guard !inked.isEmpty else { return lines }

        func resolve(reading read: [Int: String]) -> [Int: String] {
            var recovered: [Int: String] = [:]
            for (columnIndex, column) in columns.enumerated() {
                var rows: [MarkerRecovery.ColumnRow] = lines
                    .filter { MarkerRecovery.isBareMarker($0.text) && $0.minX >= column.minX - h && $0.maxX <= column.maxX + h }
                    .map { MarkerRecovery.ColumnRow(y: $0.midY, known: $0.text, slot: nil) }
                for (index, slot) in slots.enumerated() where slot.column == columnIndex && inked[index] != nil {
                    rows.append(MarkerRecovery.ColumnRow(y: slot.minY + slot.height / 2, known: read[index], slot: index))
                }
                for (slot, text) in MarkerRecovery.resolve(rows, column: column, lineHeight: h) {
                    recovered[slot] = text
                }
            }
            return recovered
        }

        // The sequence of the markers that were read settles most slots. Only
        // the rest are read again — two recognition passes each, so not cheap.
        var recovered = resolve(reading: [:])
        var read: [Int: String] = [:]
        for (index, pixels) in inked where recovered[index] == nil {
            let slot = slots[index]
            let rect = CGRect(x: slot.minX, y: slot.minY, width: slot.width, height: slot.height).integral
            if let text = readMarker(in: image, rect: rect, pixels: pixels), MarkerRecovery.isBareMarker(text) {
                read[index] = text
            }
        }
        if !read.isEmpty {
            recovered = resolve(reading: read)
        }

        var result = lines
        for (index, text) in recovered {
            let slot = slots[index]
            let column = columns[slot.column]
            let line = lines[slot.line]
            result.append(OCRLine(
                text: text,
                minX: column.minX,
                minY: line.minY,
                width: max(column.maxX - column.minX, 1),
                height: line.height
            ))
        }
        return result
    }

    /// Reads one marker cell again, enlarged and padded: recognition does much
    /// better with a lone character when it fills a small, clean image.
    private static func readMarker(
        in image: CGImage,
        rect: CGRect,
        pixels: (values: [UInt8], width: Int, height: Int)
    ) -> String? {
        guard let cropped = image.cropping(to: rect), cropped.height > 0 else { return nil }
        let background = CGFloat(pixels.values.sorted()[pixels.values.count / 2]) / 255
        let scale = max(1, 64 / CGFloat(cropped.height))
        let padding: CGFloat = 24
        let width = Int(CGFloat(cropped.width) * scale + padding * 2)
        let height = Int(CGFloat(cropped.height) * scale + padding * 2)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(
            x: padding,
            y: padding,
            width: CGFloat(cropped.width) * scale,
            height: CGFloat(cropped.height) * scale
        ))
        guard let enlarged = context.makeImage() else { return nil }

        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: enlarged, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if MarkerRecovery.isBareMarker(text) { return text }
        }
        return nil
    }

    // MARK: - Applying document structure

    /// Titles, then list markers, onto the recognised lines.
    static func apply(_ structure: DocumentStructure, to lines: inout [OCRLine]) {
        for index in lines.indices {
            let line = lines[index]
            if structure.titleBoxes.contains(where: { $0.contains(CGPoint(x: line.midX, y: line.midY)) }) {
                lines[index].isTitle = true
            }
        }

        for item in structure.listItems {
            guard let index = firstLine(of: item.box, in: lines) else { continue }
            var line = lines[index]
            let marker = item.marker.trimmingCharacters(in: .whitespaces)

            let alreadyMarked = line.hasBulletMark
                || startsWithBulletGlyph(line.text)
                || (!marker.isEmpty && line.text.hasPrefix(marker))
                || hasMarkerPiece(marker, leftOf: line, in: lines)
            guard !alreadyMarked else { continue }

            if item.isOrdered {
                // The number or letter is in the document; put it back.
                guard !marker.isEmpty else { continue }
                line.text = marker + " " + line.text
            } else {
                line.hasBulletMark = true
            }
            lines[index] = line
        }
    }

    /// The top line inside an item's box.
    private static func firstLine(of box: CGRect, in lines: [OCRLine]) -> Int? {
        let slack = 2.0
        let candidates = lines.indices.filter { index in
            let line = lines[index]
            return line.midY >= Double(box.minY) - slack && line.midY <= Double(box.maxY) + slack
                && line.maxX > Double(box.minX) && line.minX < Double(box.maxX)
        }
        return candidates.min { lines[$0].minY < lines[$1].minY }
    }

    /// Whether the marker was recognised as its own piece of the same row,
    /// left of the line (an answer-letter column) — the layout joins those.
    private static func hasMarkerPiece(_ marker: String, leftOf line: OCRLine, in lines: [OCRLine]) -> Bool {
        let bare = marker.trimmingCharacters(in: CharacterSet(charactersIn: ".):( "))
        guard !bare.isEmpty else { return false }
        return lines.contains { other in
            other.maxX <= line.minX + 1
                && abs(other.midY - line.midY) <= line.height * 0.5
                && other.text.trimmingCharacters(in: CharacterSet(charactersIn: ".):( ")) == bare
        }
    }

    // MARK: - macOS 26 document recognition

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func documentStructure(of image: CGImage) async throws -> DocumentStructure {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: image, orientation: nil)
        var structure = DocumentStructure()
        guard let document = observations.first?.document else { return structure }

        let size = CGSize(width: image.width, height: image.height)
        func rect(_ region: NormalizedRegion) -> CGRect {
            region.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        }

        if let title = document.title {
            structure.titleBoxes.append(rect(title.boundingRegion))
        }
        collectListItems(from: document, into: &structure, rect: rect)
        structure.tables = document.tables.compactMap { table in
            detectedTable(table, box: rect(table.boundingRegion))
        }
        return structure
    }

    /// Every list item, nested lists included.
    @available(macOS 26.0, *)
    private static func collectListItems(
        from container: DocumentObservation.Container,
        into structure: inout DocumentStructure,
        rect: (NormalizedRegion) -> CGRect
    ) {
        for list in container.lists {
            for item in list.items {
                let isOrdered: Bool
                switch item.markerType {
                case .decimal?, .compositeDecimal?, .decorativeDecimal?, .lowercaseLatin?, .uppercaseLatin?:
                    isOrdered = true
                default:
                    isOrdered = false
                }
                structure.listItems.append(DocumentStructure.ListItemHint(
                    box: rect(item.content.text.boundingRegion),
                    marker: item.markerString,
                    isOrdered: isOrdered
                ))
                collectListItems(from: item.content, into: &structure, rect: rect)
            }
        }
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
