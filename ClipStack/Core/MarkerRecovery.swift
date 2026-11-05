//
//  MarkerRecovery.swift
//  ClipStack
//
//  Text recognition reads words. A capital letter standing alone in a column
//  — the A B C D beside multiple-choice options — is often not read at all:
//  of four option letters, only "D" may come back. Without its letter, an
//  option is just a line of text, and the options run together.
//
//  This finds where those letters should be and recovers them:
//
//   1. A *marker column*: letters (or numbers) that were read, standing apart
//      from the text beside them, at the same x.
//   2. *Slots*: lines that start where that column's text starts but have no
//      marker beside them.
//   3. The recogniser checks each slot for ink and reads it again, enlarged
//      (see ScreenTextRecognizer). A slot with no ink is a wrapped line, not
//      an option, and is left alone.
//   4. Whatever still can't be read is filled in from the sequence: with "D"
//      read, the three inked slots above it in the same run are C, B and A.
//
//  Pure Foundation, so it is covered by the logic tests.
//

import Foundation

nonisolated struct MarkerColumn: Hashable {
    var minX: Double
    var maxX: Double
    /// Where the text after a marker starts.
    var textX: Double
    var isLetters: Bool
    var isLowercase: Bool
}

nonisolated struct MarkerSlot: Hashable {
    /// Index into the columns.
    var column: Int
    /// Index of the text line that lacks its marker.
    var line: Int
    /// Where the marker should be, in the capture's pixels.
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
}

nonisolated enum MarkerRecovery {

    private static let barePattern = #"^(?:\d{1,3}|[A-Za-z])[.):]?$"#

    /// A number or a single letter, alone: "10", "A", "b)".
    static func isBareMarker(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: barePattern, options: .regularExpression) != nil
    }

    static func lineHeight(_ lines: [OCRLine]) -> Double {
        let heights = lines.map(\.height).sorted()
        guard !heights.isEmpty else { return 1 }
        return max(heights[heights.count / 2], 1)
    }

    static func sameRow(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let smaller = min(a.height, b.height)
        return smaller > 0 && overlap >= 0.5 * smaller
    }

    private static func core(_ marker: String) -> String {
        marker.trimmingCharacters(in: CharacterSet(charactersIn: " .):("))
    }

    // MARK: - Columns and slots

    /// Markers that were read, standing apart from their text, grouped by x.
    static func columns(in lines: [OCRLine]) -> [MarkerColumn] {
        let h = lineHeight(lines)

        // (marker, the text beside it)
        let pairs: [(marker: OCRLine, text: OCRLine)] = lines.compactMap { marker in
            guard isBareMarker(marker.text) else { return nil }
            let partner = lines
                .filter { other in
                    sameRow(other, marker) && !isBareMarker(other.text)
                        && other.minX > marker.maxX && other.minX - marker.maxX < 12 * h
                }
                .min { $0.minX < $1.minX }
            return partner.map { (marker: marker, text: $0) }
        }

        var clusters: [[(marker: OCRLine, text: OCRLine)]] = []
        for pair in pairs.sorted(by: { $0.marker.minX < $1.marker.minX }) {
            if let last = clusters.last?.last, pair.marker.minX - last.marker.minX <= h {
                clusters[clusters.count - 1].append(pair)
            } else {
                clusters.append([pair])
            }
        }

        return clusters.map { cluster in
            let markers = cluster.map { $0.marker }
            let textStarts = cluster.map { $0.text.minX }.sorted()
            let letters = markers.filter { core($0.text).first?.isLetter == true }
            let minX = markers.map(\.minX).min() ?? 0
            return MarkerColumn(
                minX: minX,
                maxX: max(markers.map(\.maxX).max() ?? minX, minX + 0.6 * h),
                textX: textStarts[textStarts.count / 2],
                isLetters: letters.count * 2 >= markers.count,
                isLowercase: letters.filter { core($0.text).first?.isLowercase == true }.count * 2 > letters.count
            )
        }
    }

    /// Lines that start where a column's text starts but have nothing in the
    /// column beside them.
    static func slots(in lines: [OCRLine], columns: [MarkerColumn]) -> [MarkerSlot] {
        let h = lineHeight(lines)
        var slots: [MarkerSlot] = []
        for (columnIndex, column) in columns.enumerated() {
            for (lineIndex, line) in lines.enumerated() {
                guard !isBareMarker(line.text), abs(line.minX - column.textX) <= h else { continue }
                let occupied = lines.contains { other in
                    sameRow(other, line) && other.maxX <= line.minX + 1
                        && other.maxX > column.minX - 0.3 * h && other.minX < column.maxX + 0.3 * h
                }
                guard !occupied else { continue }
                slots.append(MarkerSlot(
                    column: columnIndex,
                    line: lineIndex,
                    minX: max(0, column.minX - 0.4 * h),
                    minY: max(0, line.minY - 0.1 * h),
                    width: (column.maxX - column.minX) + 0.8 * h,
                    height: line.height + 0.2 * h
                ))
            }
        }
        return slots
    }

    // MARK: - Ink

    /// Whether a slot's pixels hold a mark the size of a letter.
    static func hasInk(gray: [UInt8], width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, gray.count >= width * height else { return false }
        let background = Int(gray.sorted()[gray.count / 2])
        var count = 0, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where abs(Int(gray[y * width + x]) - background) > 60 {
                count += 1
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        return count >= 4 && Double(maxY - minY + 1) >= 0.3 * Double(height)
    }

    // MARK: - Sequence

    /// One row of a marker column, top to bottom.
    nonisolated struct ColumnRow {
        var y: Double
        /// What was read there, if anything.
        var known: String?
        /// The slot, for a row whose marker was missing.
        var slot: Int?
    }

    /// The marker for each slot in `rows`: what was read, when it fits the
    /// column (a letter in a column of letters); otherwise, from the sequence
    /// of the markers around it in the same run. Rows more than 2.5 line
    /// heights apart are different runs (different questions).
    static func resolve(_ rows: [ColumnRow], column: MarkerColumn, lineHeight h: Double) -> [Int: String] {
        func value(_ text: String?) -> Int? {
            guard let text else { return nil }
            let marker = core(text)
            if column.isLetters {
                guard marker.count == 1, let character = marker.first, character.isLetter,
                      let code = character.asciiValue else { return nil }
                return Int(code)
            }
            return Int(marker)
        }

        var runs: [[ColumnRow]] = []
        for row in rows.sorted(by: { $0.y < $1.y }) {
            if let last = runs.last?.last, row.y - last.y <= 2.5 * h {
                runs[runs.count - 1].append(row)
            } else {
                runs.append([row])
            }
        }

        // Each run's first value, where its read markers agree with each other.
        let bases: [Int?] = runs.map { run in
            let known = run.enumerated().compactMap { index, row in value(row.known).map { (index, $0) } }
            guard let first = known.first else { return nil }
            let base = first.1 - first.0
            return known.allSatisfy { $0.1 - $0.0 == base } ? base : nil
        }
        // Lettered runs that all start at A: a run with nothing read starts there too.
        let startLetter = Int((column.isLowercase ? Character("a") : Character("A")).asciiValue ?? 65)
        let decided = bases.compactMap { $0 }
        let alwaysStartsAtA = column.isLetters && !decided.isEmpty && decided.allSatisfy { $0 == startLetter }

        var result: [Int: String] = [:]
        for (run, base) in zip(runs, bases) {
            let start: Int
            if let base {
                start = base
            } else if alwaysStartsAtA, run.count >= 2, run.allSatisfy({ value($0.known) == nil }) {
                start = startLetter
            } else {
                // Nothing to go on: keep only what was read and fits.
                for row in run {
                    if let slot = row.slot, value(row.known) != nil, let known = row.known { result[slot] = known }
                }
                continue
            }
            for (index, row) in run.enumerated() {
                guard let slot = row.slot else { continue }
                let number = start + index
                if column.isLetters {
                    guard let scalar = UnicodeScalar(number), Character(scalar).isLetter,
                          Character(scalar).isASCII else { continue }
                    result[slot] = String(Character(scalar))
                } else {
                    result[slot] = String(number)
                }
            }
        }
        return result
    }
}
