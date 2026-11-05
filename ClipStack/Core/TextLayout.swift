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

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var midX: Double { minX + width / 2 }
    var midY: Double { minY + height / 2 }
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

struct LayoutBlock: Equatable {
    enum Kind: String, Equatable {
        case paragraph, heading, bullet, numbered, tableRow
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
            return merged
        }
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

        for line in lines {
            let marker = ListMarker.parse(line.text, hasBulletMark: line.hasBulletMark, fixMisread: options.fixMisreadBullets)
            let indentLevel = min(4, max(0, Int(((line.minX - left) / h + 0.3) / 1.6)))
            let isHeading = marker == nil && line.height >= 1.35 * h && line.text.count <= 80
            let gap = previous.map { line.minY - $0.maxY } ?? 0

            // Does this line carry on the block before it?
            if marker == nil, !isHeading, options.joinWrappedLines,
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
                case .heading, .tableRow:
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
            block.startsAfterGap = previous != nil && gap > 0.8 * h

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
                    // Options sit one level under the question they follow.
                    if let questionLevel, indentLevel <= questionLevel {
                        block.level = questionLevel + 1
                    } else {
                        block.level = indentLevel
                    }
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
        block.startsAfterGap || (block.kind == .heading) || (previous.kind == .heading) ? "\n\n" : "\n"
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
