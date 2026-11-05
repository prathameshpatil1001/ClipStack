//
//  TextLayout.swift
//  ClipStack
//
//  Turns lines of text recognised in a screen capture back into structure:
//  columns read in the right order, bullets and numbered items with their
//  nesting, questions with their options, paragraphs, headings and tables.
//
//  ── The rule ────────────────────────────────────────────────────────────────
//  Only formatting changes. Every block is assembled from the recognised
//  lines' own text; nothing here invents, drops or rewords a word. The few
//  character-level fixes (a misread bullet, a word hyphenated across a line
//  break, joining wrapped lines) are in `LayoutOptions` and can be turned off.
//
//  ── How columns are told apart ──────────────────────────────────────────────
//  Lines are grouped into visual rows. A *gutter* is a vertical strip no line
//  crosses. Within a run of rows that share a gutter there are two ways to
//  read, and this is exactly where plain OCR goes wrong:
//
//   • side by side — most rows have text on both sides of the gutter (a
//     question with its answer next to it, a table). Read across: one row of
//     cells per row.
//   • newspaper    — the two sides don't line up row for row. Read down the
//     left column, then down the right.
//
//  Pure Foundation, so it is covered by the logic tests.
//

import Foundation

// MARK: - Input

/// One line of recognised text and where it sits in the capture: points or
/// pixels, origin top-left, y growing downwards. Only proportions matter.
nonisolated struct OCRLine: Hashable {
    var text: String
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
    /// A bullet-like mark was seen in the image just left of the text, which
    /// recognition itself often drops or misreads.
    var hasBulletMark: Bool = false
    /// Recognition marked it as a title (macOS 26 document recognition).
    var isTitle: Bool = false
    /// A question number or option letter that sat apart from the text, in
    /// its own column ("10", "A"), now joined to the front of this line.
    var columnMarker: String? = nil

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var midX: Double { minX + width / 2 }
    var midY: Double { minY + height / 2 }
}

/// A table recognition found as a table, positioned like `OCRLine`.
nonisolated struct DetectedTable: Hashable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
    /// Cell text, row by row; every row as wide as the widest.
    var rows: [[String]]

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }

    /// Whether a recognised line is part of this table.
    func contains(_ line: OCRLine) -> Bool {
        line.midX >= minX - 2 && line.midX <= maxX + 2
            && line.midY >= minY - 2 && line.midY <= maxY + 2
    }
}

/// Everything read from one capture.
nonisolated struct RecognizedPage {
    var lines: [OCRLine]
    var tables: [DetectedTable]
    /// Read with macOS 26 document recognition rather than line recognition.
    var usedDocumentRecognition: Bool
}

struct LayoutOptions: Equatable {
    /// A bullet the image shows but recognition read as "e" or "o" becomes •.
    var fixMisreadBullets = true
    /// "exam-" at the end of one line and "ple" on the next become "example".
    var joinHyphenatedWords = true
    /// Lines that wrap within one paragraph or item are joined into one line.
    var joinWrappedLines = true
}

// MARK: - Output

struct LayoutBlock: Hashable {
    enum Kind: String, Hashable {
        case paragraph, heading, bullet, numbered, tableRow
        /// Code or a command, kept verbatim, line breaks and indentation included.
        case code
    }

    var kind: Kind
    /// Nesting: 0 at the left margin.
    var level: Int = 0
    /// For a bullet, the text without its marker; otherwise all of it.
    var text: String = ""
    /// Table rows only.
    var cells: [String] = []
    /// There was a clear vertical gap before this block (a paragraph break).
    var startsAfterGap: Bool = false

    var isListItem: Bool { kind == .bullet || kind == .numbered }
}

struct TextLayout: Equatable {
    var blocks: [LayoutBlock]
    /// Runs of rows read column after column.
    var newspaperColumnRuns = 0
    /// Rows read across, side by side.
    var sideBySideRows = 0

    /// Worth showing the user before using: the reading order was a judgement.
    var isComplex: Bool { newspaperColumnRuns > 0 || sideBySideRows > 0 }

    var listItemCount: Int { blocks.filter(\.isListItem).count }
}

// MARK: - List markers

struct ListMarker: Equatable {
    enum Kind: Equatable { case bullet, number, letter }
    var kind: Kind
    /// The text after the marker (bullets); the whole line otherwise.
    var content: String

    private static let bulletGlyphs: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "►", "▸", "·", "–", "—", "-", "*",
    ]

    private static let numberPattern =
        #"^(?:Q\.?\s?\d{1,3}[.:)]?|\(?\d{1,3}[.)]|\(\d{1,3}\)|\(?[ivxIVX]{1,5}[.)]|\([ivxIVX]{1,5}\)|\(?[A-Za-z][.)]|\([A-Za-z]\))\s+\S"#

    private static let misreadBulletPattern = #"^[eoc©®°]\s+(\S.*)$"#

    private static let bareMarkerPattern = #"^(?:Q\.?\s?\d{1,3}|\d{1,3}|[A-Za-z]|[ivxIVX]{1,5}|\(\w{1,3}\))[.):]?$"#

    /// What a piece of text standing alone at the start of a row is, when it is
    /// nothing but a marker: "10", "Q3", "A", "(b)", "iv.".
    static func bareKind(_ token: String) -> Kind? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: bareMarkerPattern, options: .regularExpression) != nil else { return nil }
        let first = trimmed.first
        let isNumber = first?.isNumber == true || first == "Q"
            || (first == "(" && trimmed.dropFirst().first?.isNumber == true)
        return isNumber ? .number : .letter
    }

    static func parse(_ text: String, hasBulletMark: Bool, fixMisread: Bool) -> ListMarker? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }

        // A bullet glyph, then a space ("-5 °C" is not a bullet).
        if bulletGlyphs.contains(first) {
            let afterGlyph = trimmed.dropFirst()
            if afterGlyph.first?.isWhitespace == true {
                let content = afterGlyph.trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { return ListMarker(kind: .bullet, content: content) }
            }
        }

        if hasBulletMark {
            if fixMisread, let content = firstCapture(misreadBulletPattern, in: trimmed) {
                return ListMarker(kind: .bullet, content: content)
            }
            return ListMarker(kind: .bullet, content: trimmed)
        }

        if trimmed.range(of: numberPattern, options: .regularExpression) != nil {
            let isNumber = first.isNumber || first == "Q"
                || (first == "(" && trimmed.dropFirst().first?.isNumber == true)
            return ListMarker(kind: isNumber ? .number : .letter, content: trimmed)
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - Engine

enum TextLayoutEngine {

    /// The typical line height: every distance is judged relative to it.
    static func lineHeight(_ lines: [OCRLine]) -> Double {
        let heights = lines.map(\.height).sorted()
        guard !heights.isEmpty else { return 1 }
        return max(heights[heights.count / 2], 1)
    }

    /// Lines grouped into visual rows, top to bottom; within a row, pieces
    /// separated by no more than a word gap are joined, left to right.
    static func rows(_ input: [OCRLine]) -> [[OCRLine]] {
        let lines = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return [] }
        let h = lineHeight(lines)

        var grouped: [(minY: Double, maxY: Double, lines: [OCRLine])] = []
        for line in lines.sorted(by: { $0.midY < $1.midY }) {
            if let last = grouped.last {
                let overlap = min(last.maxY, line.maxY) - max(last.minY, line.minY)
                let smaller = min(last.maxY - last.minY, line.height)
                if smaller > 0, overlap >= 0.5 * smaller {
                    grouped[grouped.count - 1].lines.append(line)
                    grouped[grouped.count - 1].minY = min(last.minY, line.minY)
                    grouped[grouped.count - 1].maxY = max(last.maxY, line.maxY)
                    continue
                }
            }
            grouped.append((line.minY, line.maxY, [line]))
        }

        return grouped.map { row in
            var merged: [OCRLine] = []
            for line in row.lines.sorted(by: { $0.minX < $1.minX }) {
                if var last = merged.last, line.minX - last.maxX < 1.0 * h {
                    let right = max(last.maxX, line.maxX)
                    let top = min(last.minY, line.minY)
                    let bottom = max(last.maxY, line.maxY)
                    last.text += " " + line.text
                    last.width = right - last.minX
                    last.minY = top
                    last.height = bottom - top
                    merged[merged.count - 1] = last
                } else {
                    merged.append(line)
                }
            }
            return joiningColumnMarkers(merged, lineHeight: h)
        }
    }

    /// A question number or option letter in a column of its own ("10" …
    /// "Research completed", "A" … "reduced the productivity") is read as a
    /// separate piece of the row. It belongs to the text beside it: join them,
    /// keeping the marker exactly as written, and remember it was a marker.
    /// Only the first piece of a row: a letter at the end of a row is an
    /// answer column, read across as a table.
    static func joiningColumnMarkers(_ row: [OCRLine], lineHeight h: Double) -> [OCRLine] {
        guard row.count >= 2,
              ListMarker.bareKind(row[0].text) != nil,
              ListMarker.bareKind(row[1].text) == nil,
              row[1].minX - row[0].maxX < 12 * h
        else { return row }

        let marker = row[0].text.trimmingCharacters(in: .whitespaces)
        var joined = row[1]
        let right = joined.maxX
        let top = min(row[0].minY, joined.minY)
        let bottom = max(row[0].maxY, joined.maxY)
        joined.text = marker + " " + joined.text
        joined.minX = row[0].minX
        joined.width = right - joined.minX
        joined.minY = top
        joined.height = bottom - top
        joined.columnMarker = marker
        joined.hasBulletMark = false
        return [joined] + row.dropFirst(2)
    }

    /// The recognised text with no formatting: rows top to bottom.
    static func rawText(_ lines: [OCRLine]) -> String {
        rows(lines)
            .map { $0.map(\.text).joined(separator: "  ") }
            .joined(separator: "\n")
    }

    /// Vertical strips no line crosses, at least `minimum` wide.
    static func gutters(in lines: [OCRLine], minimum: Double) -> [(lower: Double, upper: Double)] {
        let spans = lines.map { (lower: $0.minX, upper: $0.maxX) }.sorted { $0.lower < $1.lower }
        guard var reach = spans.first?.upper else { return [] }
        var found: [(lower: Double, upper: Double)] = []
        for span in spans.dropFirst() {
            if span.lower - reach >= minimum {
                found.append((reach, span.lower))
            }
            reach = max(reach, span.upper)
        }
        return found
    }

    private enum Region {
        case flow([OCRLine])
        case table([[String]])
    }

    /// With tables that recognition already found (macOS 26 document
    /// recognition): their lines are taken out of the flow and the tables put
    /// back, cell by cell, where they sit; everything else is laid out by the
    /// rules as usual.
    static func layout(_ input: [OCRLine], tables: [DetectedTable], options: LayoutOptions) -> TextLayout {
        let usable = tables
            .filter { $0.rows.count >= 2 && ($0.rows.map(\.count).max() ?? 0) >= 2 }
            .sorted { $0.minY < $1.minY }
        guard !usable.isEmpty else { return layout(input, options: options) }

        var remaining = input.filter { line in !usable.contains { $0.contains(line) } }
        var blocks: [LayoutBlock] = []
        var newspaperRuns = 0
        var sideBySideRows = 0

        func add(_ more: [LayoutBlock]) {
            var more = more
            if !blocks.isEmpty, !more.isEmpty { more[0].startsAfterGap = true }
            blocks.append(contentsOf: more)
        }

        for table in usable {
            let above = remaining.filter { $0.midY < table.minY }
            remaining.removeAll { $0.midY < table.minY }
            let part = layout(above, options: options)
            add(part.blocks)
            newspaperRuns += part.newspaperColumnRuns
            sideBySideRows += part.sideBySideRows

            add(table.rows.map { LayoutBlock(kind: .tableRow, cells: $0) })
            sideBySideRows += table.rows.count
        }
        let rest = layout(remaining, options: options)
        add(rest.blocks)
        newspaperRuns += rest.newspaperColumnRuns
        sideBySideRows += rest.sideBySideRows

        return TextLayout(blocks: blocks, newspaperColumnRuns: newspaperRuns, sideBySideRows: sideBySideRows)
    }

    /// With the default options. (An overload rather than a default argument:
    /// default arguments are evaluated off the main actor, where the app's
    /// `LayoutOptions()` may not be called.)
    static func layout(_ input: [OCRLine]) -> TextLayout {
        layout(input, options: LayoutOptions())
    }

    static func layout(_ input: [OCRLine], options: LayoutOptions) -> TextLayout {
        let rows = self.rows(input)
        guard !rows.isEmpty else { return TextLayout(blocks: []) }

        let all = rows.flatMap { $0 }
        let h = lineHeight(all)
        let contentMinX = all.map(\.minX).min() ?? 0
        let contentMaxX = all.map(\.maxX).max() ?? 1
        let contentWidth = max(contentMaxX - contentMinX, 1)
        let gutterMinimum = max(1.5 * h, 0.03 * contentWidth)

        // Gutters suggested by lines that don't span the whole width. A row
        // with a line across one of them (a title, a full-width paragraph)
        // separates runs of rows, each analysed on its own.
        let candidates = gutters(in: all.filter { $0.width < 0.55 * contentWidth }, minimum: gutterMinimum)
        func crossesCandidate(_ row: [OCRLine]) -> Bool {
            row.contains { line in
                candidates.contains { line.minX < $0.upper && line.maxX > $0.lower }
            }
        }

        var runs: [[[OCRLine]]] = []
        var current: [[OCRLine]] = []
        for row in rows {
            if !candidates.isEmpty, crossesCandidate(row) {
                if !current.isEmpty { runs.append(current); current = [] }
                runs.append([row])
            } else {
                current.append(row)
            }
        }
        if !current.isEmpty { runs.append(current) }

        var regions: [Region] = []
        var flow: [OCRLine] = []
        var newspaperRuns = 0
        var sideBySideRows = 0

        func flushFlow() {
            if !flow.isEmpty { regions.append(.flow(flow)); flow = [] }
        }

        for run in runs {
            let lines = run.flatMap { $0 }
            let runGutters = gutters(in: lines, minimum: gutterMinimum)
            guard !runGutters.isEmpty else {
                flow.append(contentsOf: lines)
                continue
            }

            let boundaries = runGutters.map { ($0.lower + $0.upper) / 2 }
            let columnCount = boundaries.count + 1
            func column(of line: OCRLine) -> Int {
                boundaries.filter { line.midX > $0 }.count
            }

            // A single row with a gap in it: keep it as one line, gap and all.
            if run.count == 1 {
                let row = run[0]
                var line = row[0]
                line.text = row.map(\.text).joined(separator: "\t")
                line.width = (row.last?.maxX ?? line.maxX) - line.minX
                flow.append(line)
                continue
            }

            let rowsSpanningColumns = run.filter { row in Set(row.map(column(of:))).count >= 2 }.count
            flushFlow()

            if Double(rowsSpanningColumns) >= 0.5 * Double(run.count) {
                // Side by side: one row of cells per visual row. A row with
                // only some cells filled, close under the previous one and not
                // starting an item of its own, is that row's text wrapping.
                var table: [[String]] = []
                var previousBottom = -Double.infinity
                for row in run {
                    var cells = Array(repeating: "", count: columnCount)
                    for line in row {
                        let index = column(of: line)
                        cells[index] = cells[index].isEmpty ? line.text : cells[index] + " " + line.text
                    }
                    let top = row.map(\.minY).min() ?? 0
                    let filled = cells.filter { !$0.isEmpty }.count
                    let startsItem = cells.contains {
                        ListMarker.parse($0, hasBulletMark: false, fixMisread: false) != nil
                    }
                    if filled < columnCount, !table.isEmpty, top - previousBottom < 0.8 * h, !startsItem {
                        for index in cells.indices where !cells[index].isEmpty {
                            table[table.count - 1][index] = join(table[table.count - 1][index], cells[index], options: options)
                        }
                    } else {
                        table.append(cells)
                    }
                    previousBottom = row.map(\.maxY).max() ?? top
                }
                sideBySideRows += table.count
                regions.append(.table(table))
            } else {
                // Newspaper columns: each one read top to bottom, left to right.
                newspaperRuns += 1
                for index in 0..<columnCount {
                    let columnLines = lines.filter { column(of: $0) == index }
                    if !columnLines.isEmpty { regions.append(.flow(columnLines)) }
                }
            }
        }
        flushFlow()

        var blocks: [LayoutBlock] = []
        for region in regions {
            var regionBlocks: [LayoutBlock]
            switch region {
            case .flow(let lines):
                regionBlocks = self.blocks(from: lines, lineHeight: h, options: options)
            case .table(let table):
                regionBlocks = table.map { LayoutBlock(kind: .tableRow, cells: $0) }
            }
            // A new region always starts after a break.
            if !blocks.isEmpty, !regionBlocks.isEmpty {
                regionBlocks[0].startsAfterGap = true
            }
            blocks.append(contentsOf: regionBlocks)
        }

        return TextLayout(blocks: blocks, newspaperColumnRuns: newspaperRuns, sideBySideRows: sideBySideRows)
    }

    /// Lines in reading order → paragraphs, headings and list items.
    static func blocks(from lines: [OCRLine], lineHeight h: Double, options: LayoutOptions) -> [LayoutBlock] {
        guard let left = lines.map(\.minX).min(), let right = lines.map(\.maxX).max() else { return [] }
        let width = max(right - left, 1)

        var blocks: [LayoutBlock] = []
        var blockLeft: [Double] = []
        /// Whether each block's first line had a bullet mark outside its text.
        var blockMarked: [Bool] = []
        var previous: OCRLine?
        var questionLevel: Int?

        // Options written "A text", "B text" with no "." or ")": a capital or
        // small letter, a space, then text, on consecutive lines in alphabetical
        // sequence. One such line alone ("A man walked in.") is just a sentence.
        let leadingLetters: [UInt8?] = lines.map { line in
            let characters = Array(line.text)
            guard characters.count >= 3, characters[0].isLetter, let code = characters[0].asciiValue,
                  characters[1] == " "
            else { return nil }
            return code
        }
        var sequencedOptions = Set<Int>()
        for index in lines.indices.dropLast() {
            if let current = leadingLetters[index], let next = leadingLetters[index + 1], next == current + 1 {
                sequencedOptions.insert(index)
                sequencedOptions.insert(index + 1)
            }
        }

        for (index, line) in lines.enumerated() {
            var marker = ListMarker.parse(line.text, hasBulletMark: line.hasBulletMark, fixMisread: options.fixMisreadBullets)
            if marker == nil, let token = line.columnMarker, let kind = ListMarker.bareKind(token) {
                marker = ListMarker(kind: kind, content: line.text)
            }
            if marker == nil, sequencedOptions.contains(index) {
                marker = ListMarker(kind: .letter, content: line.text)
            }
            let indentLevel = min(4, max(0, Int(((line.minX - left) / h + 0.3) / 1.6)))
            let isHeading = marker == nil
                && ((line.height >= 1.35 * h && line.text.count <= 80) || (line.isTitle && line.text.count <= 120))
            let gap = previous.map { line.minY - $0.maxY } ?? 0

            // Does this line carry on the block before it?
            // A sentence that ends at the end of a line, followed by a line
            // starting in lowercase, is two items (options whose letters went
            // unread), not one sentence wrapping: prose doesn't start a
            // sentence in lowercase.
            let endsSentence = previous.map { [".", "?", "!"].contains($0.text.last ?? " ") } ?? false
            let startsLowercase = line.text.first?.isLowercase == true
            if marker == nil, !isHeading, options.joinWrappedLines,
               !(endsSentence && startsLowercase),
               let prev = previous, var last = blocks.last, let lastLeft = blockLeft.last,
               gap >= -0.3 * h, gap <= 0.8 * h,
               prev.maxX >= left + 0.6 * width {
                let continues: Bool
                switch last.kind {
                case .paragraph:
                    continues = abs(line.minX - lastLeft) <= 1.5 * h
                case .bullet, .numbered:
                    // Hanging indent under the item, or level with it when the
                    // bullet mark sits outside the recognised text.
                    continues = line.minX > lastLeft + 0.4 * h
                        || (blockMarked.last == true && abs(line.minX - lastLeft) <= 0.6 * h)
                case .heading, .tableRow, .code:
                    continues = false
                }
                if continues {
                    last.text = join(last.text, line.text, options: options)
                    blocks[blocks.count - 1] = last
                    previous = line
                    continue
                }
            }

            var block = LayoutBlock(kind: .paragraph, text: line.text)
            // Options sit a little apart from their question in many layouts;
            // that is not a paragraph break.
            let breakGap = marker?.kind == .letter && blocks.last?.isListItem == true ? 2.5 * h : 0.8 * h
            block.startsAfterGap = previous != nil && gap > breakGap

            if let marker {
                switch marker.kind {
                case .bullet:
                    block.kind = .bullet
                    block.text = marker.content
                    block.level = indentLevel
                case .number:
                    block.kind = .numbered
                    block.level = indentLevel
                    questionLevel = indentLevel
                case .letter:
                    block.kind = .numbered
                    // Options sit one level under the question they follow,
                    // however far across the page they are printed.
                    block.level = questionLevel.map { $0 + 1 } ?? indentLevel
                }
            } else if isHeading {
                block.kind = .heading
                questionLevel = nil
            }

            blocks.append(block)
            blockLeft.append(line.minX)
            blockMarked.append(line.hasBulletMark)
            previous = line
        }
        return blocks
    }

    /// Joins a wrapped line onto the text before it.
    static func join(_ head: String, _ tail: String, options: LayoutOptions) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        if options.joinHyphenatedWords, head.hasSuffix("-"),
           head.dropLast().last?.isLetter == true, tail.first?.isLowercase == true {
            return String(head.dropLast()) + tail
        }
        return head + " " + tail
    }
}

// MARK: - Rendering

enum LayoutRenderer {

    enum Style: String, CaseIterable, Identifiable {
        case plain, markdown
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plain: return "Plain text with • bullets"
            case .markdown: return "Markdown"
            }
        }
    }

    static func text(_ blocks: [LayoutBlock], style: Style) -> String {
        var output = ""
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if index > 0 {
                output += separator(before: block, after: blocks[index - 1])
            }

            if block.kind == .tableRow {
                // A run of rows renders as one table.
                var run: [LayoutBlock] = []
                while index < blocks.count, blocks[index].kind == .tableRow,
                      run.isEmpty || !blocks[index].startsAfterGap {
                    run.append(blocks[index])
                    index += 1
                }
                output += table(run.map(\.cells), style: style)
                continue
            }

            let indent = String(repeating: "  ", count: block.level)
            switch (block.kind, style) {
            case (.heading, .markdown): output += "## " + block.text
            case (.code, .markdown): output += "```\n" + block.text + "\n```"
            case (.bullet, .plain): output += indent + "• " + block.text
            case (.bullet, .markdown): output += indent + "- " + block.text
            case (.numbered, _): output += indent + block.text
            default: output += block.text
            }
            index += 1
        }
        return output
    }

    private static func separator(before block: LayoutBlock, after previous: LayoutBlock) -> String {
        block.startsAfterGap || block.kind == .heading || previous.kind == .heading
            || block.kind == .code || previous.kind == .code ? "\n\n" : "\n"
    }

    private static func table(_ rows: [[String]], style: Style) -> String {
        switch style {
        case .plain:
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .markdown:
            let width = rows.map(\.count).max() ?? 0
            func line(_ cells: [String]) -> String {
                let padded = cells + Array(repeating: "", count: max(0, width - cells.count))
                return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            guard let header = rows.first else { return "" }
            var lines = [line(header), "|" + Array(repeating: " --- |", count: width).joined()]
            lines += rows.dropFirst().map(line)
            return lines.joined(separator: "\n")
        }
    }

    /// The same structure as HTML, put on the clipboard alongside the text so
    /// Notes, Pages, Mail and Google Docs paste real bullets and tables.
    static func html(_ blocks: [LayoutBlock]) -> String {
        var html = "<meta charset=\"utf-8\">"
        var openLists = 0
        var tableOpen = false

        func closeLists(to depth: Int) {
            while openLists > depth { html += "</ul>"; openLists -= 1 }
        }
        func closeTable() {
            if tableOpen { html += "</table>"; tableOpen = false }
        }

        for block in blocks {
            if block.kind != .bullet { closeLists(to: 0) }
            if block.kind != .tableRow { closeTable() }

            switch block.kind {
            case .heading:
                html += "<h3>\(escape(block.text))</h3>"
            case .paragraph:
                html += "<p>\(escape(block.text))</p>"
            case .code:
                html += "<pre>\(escape(block.text))</pre>"
            case .numbered:
                let margin = block.level * 24
                html += "<p style=\"margin:0 0 0 \(margin)px\">\(escape(block.text))</p>"
            case .bullet:
                let depth = block.level + 1
                while openLists < depth { html += "<ul>"; openLists += 1 }
                closeLists(to: depth)
                html += "<li>\(escape(block.text))</li>"
            case .tableRow:
                if !tableOpen { html += "<table border=\"1\" cellpadding=\"4\" style=\"border-collapse:collapse\">"; tableOpen = true }
                html += "<tr>" + block.cells.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
            }
        }
        closeLists(to: 0)
        closeTable()
        return html
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Arrangement by the on-device model

/// One block as the model proposes it: a kind and the numbers of the lines in
/// it. Never text.
struct ProposedLayoutBlock: Equatable {
    var kind: String
    var level: Int
    var lines: [Int]
}

enum LayoutArrangement {

    static let instructions = """
    You arrange lines of text recognised from a screenshot. You never change, add or remove any words: you only decide the reading order and what each group of lines is.

    Each line has a number, its position as percentages of the capture (x and y of its top-left corner, then width and height) and its text.

    Return blocks in reading order. Every line number appears in exactly one block.
    Kinds:
    - heading: a title.
    - paragraph: running text. Lines that wrap belong in one block.
    - bullet: one bulleted item with its wrapped lines. Level 1 for an item nested under another.
    - numbered: one numbered or lettered item, such as a question "1." or an option "(a)". Options are one level below their question.
    - row: lines that sit side by side and belong together, such as a question and its answer in two columns, or a table row. List them left to right.
    Read columns of running text top to bottom, one column after the other. When lines pair up across columns, use rows instead.
    """

    /// The lines as the model sees them, numbered from 1.
    static func prompt(for lines: [OCRLine]) -> String {
        guard let minX = lines.map(\.minX).min(), let minY = lines.map(\.minY).min(),
              let maxX = lines.map(\.maxX).max(), let maxY = lines.map(\.maxY).max()
        else { return "LINES:\n(none)" }
        let width = max(maxX - minX, 1), height = max(maxY - minY, 1)
        func percent(_ value: Double, of total: Double) -> Int { Int((value / total * 100).rounded()) }

        var output = ["LINES (number, x, y, width, height, text):"]
        for (index, line) in lines.enumerated() {
            let text = line.text.count > 90 ? String(line.text.prefix(90)) + "…" : line.text
            output.append(
                "\(index + 1). x=\(percent(line.minX - minX, of: width)) y=\(percent(line.minY - minY, of: height)) "
                + "w=\(percent(line.width, of: width)) h=\(percent(line.height, of: height)) \(text)"
            )
        }
        return output.joined(separator: "\n")
    }

    /// Builds blocks from the model's arrangement — only if it used every line
    /// exactly once. Otherwise nil, and the layout rules' result stands.
    static func blocks(
        from proposal: [ProposedLayoutBlock],
        lines: [OCRLine],
        options: LayoutOptions
    ) -> [LayoutBlock]? {
        let used = proposal.flatMap(\.lines)
        guard !lines.isEmpty,
              used.count == lines.count,
              Set(used) == Set(1...lines.count)
        else { return nil }

        let h = TextLayoutEngine.lineHeight(lines)
        var blocks: [LayoutBlock] = []
        var previousBottom: Double?

        for proposed in proposal where !proposed.lines.isEmpty {
            let members = proposed.lines.map { lines[$0 - 1] }
            let level = min(4, max(0, proposed.level))
            var block: LayoutBlock

            switch proposed.kind.lowercased() {
            case "row":
                block = LayoutBlock(kind: .tableRow, cells: members.map(\.text))
            case "heading":
                block = LayoutBlock(kind: .heading, text: joinAll(members, options: options))
            case "bullet":
                var text = joinAll(members, options: options)
                if let marker = ListMarker.parse(text, hasBulletMark: false, fixMisread: false), marker.kind == .bullet {
                    text = marker.content
                } else if options.fixMisreadBullets, members.first?.hasBulletMark == true,
                          let marker = ListMarker.parse(text, hasBulletMark: true, fixMisread: true) {
                    text = marker.content
                }
                block = LayoutBlock(kind: .bullet, level: level, text: text)
            case "numbered":
                block = LayoutBlock(kind: .numbered, level: level, text: joinAll(members, options: options))
            default:
                block = LayoutBlock(kind: .paragraph, text: joinAll(members, options: options))
            }

            let top = members.map(\.minY).min() ?? 0
            if let previousBottom {
                block.startsAfterGap = top - previousBottom > 0.8 * h
                    || (block.kind == .tableRow) != (blocks.last?.kind == .tableRow)
            }
            previousBottom = members.map(\.maxY).max() ?? top
            blocks.append(block)
        }
        return blocks
    }

    private static func joinAll(_ lines: [OCRLine], options: LayoutOptions) -> String {
        guard options.joinWrappedLines else { return lines.map(\.text).joined(separator: "\n") }
        return lines.dropFirst().reduce(lines.first?.text ?? "") {
            TextLayoutEngine.join($0, $1.text, options: options)
        }
    }
}

// MARK: - Copied text

/// One non-blank line of copied text.
struct TextLine: Equatable {
    var text: String
    /// Leading spaces, a tab counting as four.
    var indent: Int
    /// A blank line came before it.
    var afterBlank: Bool
}

/// Layout for text that was copied rather than captured: there is no picture
/// to go on, but the text carries its own structure — blank lines, indentation,
/// bullet and number markers, Markdown headings and tables, tab-separated rows.
enum PlainTextLayout {

    static func lines(_ text: String) -> [TextLine] {
        var result: [TextLine] = []
        var sawBlank = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let content = raw.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else {
                sawBlank = !result.isEmpty
                continue
            }
            var indent = 0
            for character in raw {
                if character == " " { indent += 1 } else if character == "\t" { indent += 4 } else { break }
            }
            result.append(TextLine(text: content, indent: indent, afterBlank: sawBlank))
            sawBlank = false
        }
        return result
    }

    static func blocks(from text: String, options: LayoutOptions) -> [LayoutBlock] {
        // Code and commands keep every character, indentation included.
        if isCode(text) {
            let verbatim = text.trimmingCharacters(in: .newlines)
            return verbatim.isEmpty ? [] : [LayoutBlock(kind: .code, text: verbatim)]
        }

        let lines = self.lines(text)
        let markers = lines.map { ListMarker.parse($0.text, hasBulletMark: false, fixMisread: false) }
        // Nesting comes from the distinct indents list items use, in order.
        let listIndents = Array(Set(zip(lines, markers).compactMap { $1 == nil ? nil : $0.indent })).sorted()
        func level(for indent: Int) -> Int {
            min(4, listIndents.lastIndex { $0 <= indent } ?? 0)
        }

        var blocks: [LayoutBlock] = []
        var itemIndent: Int?
        var questionLevel: Int?

        for (index, line) in lines.enumerated() {
            var block: LayoutBlock

            if let heading = markdownHeading(line.text) {
                block = LayoutBlock(kind: .heading, text: heading)
                itemIndent = nil
                questionLevel = nil
            } else if let cells = tableCells(line.text) {
                if cells.isEmpty { continue }   // a Markdown |---| rule
                block = LayoutBlock(kind: .tableRow, cells: cells)
                itemIndent = nil
            } else if let marker = markers[index] {
                let level = level(for: line.indent)
                switch marker.kind {
                case .bullet:
                    block = LayoutBlock(kind: .bullet, level: level, text: marker.content)
                case .number:
                    block = LayoutBlock(kind: .numbered, level: level, text: marker.content)
                    questionLevel = level
                case .letter:
                    let nested = questionLevel.map { level <= $0 ? $0 + 1 : level } ?? level
                    block = LayoutBlock(kind: .numbered, level: nested, text: marker.content)
                }
                itemIndent = line.indent
            } else if options.joinWrappedLines, !line.afterBlank, let indent = itemIndent,
                      line.indent > indent, var last = blocks.last, last.isListItem {
                // Indented under a list item: that item's text carrying on.
                last.text = TextLayoutEngine.join(last.text, line.text, options: options)
                blocks[blocks.count - 1] = last
                continue
            } else {
                block = LayoutBlock(kind: .paragraph, text: line.text)
                itemIndent = nil
            }

            block.startsAfterGap = line.afterBlank
            blocks.append(block)
        }
        return blocks
    }

    /// Stricter than "starts with a command word": prose that happens to begin
    /// "go to…" or "make sure…" must still be formatted as prose.
    static func isCode(_ text: String) -> Bool {
        if text.contains(" \\\n") || text.contains("&&") || text.contains("```") { return true }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let commandWords = ["sudo", "scp", "ssh", "rsync", "git", "docker", "kubectl", "npm", "npx", "pnpm",
                            "yarn", "pip", "python", "python3", "curl", "wget", "export", "cd", "mkdir", "brew",
                            "gcloud", "aws", "terraform", "cargo", "chmod", "chown", "ls", "cp", "mv", "rm"]
        let codeLike = lines.filter { line in
            if line.hasPrefix("$ ") || line.hasPrefix("#!") || line.hasPrefix("//") { return true }
            if let last = line.last, ";{}".contains(last) { return true }
            let firstWord = line.split(separator: " ").first.map(String.init) ?? ""
            return commandWords.contains(firstWord)
                && (line.contains(" -") || line.contains("/") || line.contains("="))
        }
        return Double(codeLike.count) >= 0.6 * Double(lines.count)
    }

    /// "## Results" → "Results".
    private static func markdownHeading(_ text: String) -> String? {
        guard text.hasPrefix("#") else { return nil }
        let hashes = text.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = text.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
        return title.isEmpty ? nil : title
    }

    /// Cells of a Markdown table row or a tab-separated line; an empty array
    /// for a Markdown rule (`|---|---|`); nil when the line isn't a row.
    private static func tableCells(_ text: String) -> [String]? {
        if text.hasPrefix("|"), text.hasSuffix("|"), text.count > 2 {
            let cells = text.dropFirst().dropLast()
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let isRule = cells.allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
            }
            return isRule ? [] : cells
        }
        if text.contains("\t") {
            let cells = text.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.filter({ !$0.isEmpty }).count >= 2 { return cells }
        }
        return nil
    }
}

// MARK: - The whole stack

/// One stack item, as Format Stack sees it.
struct StackFormatItem {
    var text: String
    /// A screen capture's layout, when the item has one. Copied text has none.
    var blocks: [LayoutBlock]?
}

enum StackFormatter {

    /// Each item's own blocks, joined into one document. Items are separated
    /// by a paragraph break, except where one carries on from the last: bullets
    /// copied one at a time become one list, rows with the same columns one table.
    static func merge(_ parts: [[LayoutBlock]]) -> [LayoutBlock] {
        var merged: [LayoutBlock] = []
        for part in parts where !part.isEmpty {
            var part = part
            if let last = merged.last, let first = part.first {
                let carriesOn = (last.isListItem && first.isListItem && last.kind == first.kind)
                    || (last.kind == .tableRow && first.kind == .tableRow && last.cells.count == first.cells.count)
                part[0].startsAfterGap = !carriesOn
            } else {
                part[0].startsAfterGap = false
            }
            merged.append(contentsOf: part)
        }
        return merged
    }

    /// Items laid out by the rules: captures keep their layout, copied text
    /// is read by its own structure.
    static func blocks(for items: [StackFormatItem], options: LayoutOptions) -> [[LayoutBlock]] {
        items.map { item in
            if let blocks = item.blocks, !blocks.isEmpty { return blocks }
            return PlainTextLayout.blocks(from: item.text, options: options)
        }
    }

    /// Copied text that may have lost its structure on the way — a list copied
    /// from a web page arrives with no bullets — and is worth asking the
    /// on-device model about: several lines, all plain paragraphs.
    static func mightHaveLostStructure(_ blocks: [LayoutBlock], lineCount: Int) -> Bool {
        lineCount >= 3 && !blocks.isEmpty && blocks.allSatisfy { $0.kind == .paragraph }
    }
}

// MARK: - Labelling copied lines with the on-device model

enum TextArrangement {

    static let instructions = """
    You label lines of text the user copied, for example from a web page where list bullets were lost. You never change, add, remove or reorder anything: you only say what each group of consecutive lines is.

    Each line has a number, its indentation and its text.

    Return blocks covering every line exactly once, in the original order.
    Kinds:
    - heading: a title.
    - paragraph: running text. Consecutive lines of the same sentence belong in one block.
    - bullet: one list item. Level 1 for an item nested under another.
    - numbered: one numbered or lettered item, such as a question "1." or an option "(a)". Options are one level below their question.
    """

    static func prompt(for lines: [TextLine]) -> String {
        var output = ["LINES (number, indent, text):"]
        for (index, line) in lines.enumerated() {
            let text = line.text.count > 90 ? String(line.text.prefix(90)) + "…" : line.text
            output.append("\(index + 1). indent=\(line.indent)\(line.afterBlank ? " (after a blank line)" : "") \(text)")
        }
        return output.joined(separator: "\n")
    }

    /// Blocks from the model's labels — only if they cover every line once,
    /// in the original order. Otherwise nil, and the rules' result stands.
    static func blocks(from proposal: [ProposedLayoutBlock], lines: [TextLine], options: LayoutOptions) -> [LayoutBlock]? {
        guard !lines.isEmpty, proposal.flatMap(\.lines) == Array(1...lines.count) else { return nil }

        return proposal.filter { !$0.lines.isEmpty }.map { proposed in
            let members = proposed.lines.map { lines[$0 - 1] }
            let joined = members.dropFirst().reduce(members[0].text) {
                options.joinWrappedLines
                    ? TextLayoutEngine.join($0, $1.text, options: options)
                    : $0 + "\n" + $1.text
            }
            let level = min(4, max(0, proposed.level))
            var block: LayoutBlock
            switch proposed.kind.lowercased() {
            case "heading":
                block = LayoutBlock(kind: .heading, text: joined)
            case "bullet":
                let marker = ListMarker.parse(joined, hasBulletMark: false, fixMisread: false)
                block = LayoutBlock(kind: .bullet, level: level,
                                    text: marker?.kind == .bullet ? marker!.content : joined)
            case "numbered":
                block = LayoutBlock(kind: .numbered, level: level, text: joined)
            default:
                block = LayoutBlock(kind: .paragraph, text: joined)
            }
            block.startsAfterGap = members[0].afterBlank
            return block
        }
    }
}
