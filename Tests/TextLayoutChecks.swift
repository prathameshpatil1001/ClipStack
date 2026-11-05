//
//  TextLayoutChecks.swift
//  ClipStack tests
//
//  Screen-text layout from synthetic recognised lines: bullets (including the
//  ones recognition misses), nesting, wrapped items, two-column MCQs read
//  across, newspaper columns read down, questions with options, paragraphs,
//  and the check on the on-device model's arrangement.
//

import Foundation

@MainActor
enum TextLayoutChecks {

    static func line(_ text: String, x: Double, y: Double, w: Double, h: Double = 20, mark: Bool = false) -> OCRLine {
        OCRLine(text: text, minX: x, minY: y, width: w, height: h, hasBulletMark: mark)
    }

    static func words(_ text: String, ignoring markers: Set<String>) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !markers.contains($0) }
            .sorted()
    }

    static func run() -> Int {
        let runner = CheckRunner(suite: "Screen text layout")

        // ── A bulleted list with a heading, a wrapped item and a nested one ──
        let list = [
            line("Shopping", x: 0, y: 0, w: 100, h: 30),
            line("• Milk", x: 0, y: 40, w: 60),
            line("• Eggs from the farm shop near", x: 0, y: 64, w: 400),
            line("the station", x: 24, y: 88, w: 150),
            line("◦ Organic", x: 40, y: 112, w: 120),
        ]
        let listLayout = TextLayoutEngine.layout(list)
        runner.check("bullets, wrap and nesting (plain)",
                     LayoutRenderer.text(listLayout.blocks, style: .plain),
                     equals: "Shopping\n\n• Milk\n• Eggs from the farm shop near the station\n  • Organic")
        runner.check("bullets, wrap and nesting (Markdown)",
                     LayoutRenderer.text(listLayout.blocks, style: .markdown),
                     equals: "## Shopping\n\n- Milk\n- Eggs from the farm shop near the station\n  - Organic")
        runner.check("a plain list is not complex", !listLayout.isComplex)
        runner.check("no words gained or lost",
                     words(LayoutRenderer.text(listLayout.blocks, style: .plain), ignoring: ["•"]),
                     equals: words(list.map(\.text).joined(separator: " "), ignoring: ["•", "◦"]))
        let html = LayoutRenderer.html(listLayout.blocks)
        runner.check("HTML has real, nested lists",
                     html.contains("<ul><li>Milk</li>") && html.contains("<ul><li>Organic</li></ul></ul>"))

        // ── Bullets the image shows but recognition missed or misread ──────
        let unseen = [
            line("e Apples", x: 30, y: 0, w: 120, mark: true),
            line("Pears", x: 30, y: 24, w: 80, mark: true),
        ]
        runner.check("bullets found in the image become real bullets",
                     LayoutRenderer.text(TextLayoutEngine.layout(unseen).blocks, style: .plain),
                     equals: "• Apples\n• Pears")
        var keepMisread = LayoutOptions()
        keepMisread.fixMisreadBullets = false
        runner.check("…and the misread “e” can be kept",
                     LayoutRenderer.text(TextLayoutEngine.layout(unseen, options: keepMisread).blocks, style: .plain),
                     equals: "• e Apples\n• Pears")

        // ── MCQ answers in a second column: read across ────────────────────
        let mcq = [
            line("1. Capital of France?", x: 0, y: 0, w: 300),
            line("B", x: 500, y: 0, w: 40),
            line("2. Largest planet?", x: 0, y: 30, w: 300),
            line("C", x: 500, y: 30, w: 40),
            line("3. Fastest animal?", x: 0, y: 60, w: 300),
            line("A", x: 500, y: 60, w: 40),
        ]
        let mcqLayout = TextLayoutEngine.layout(mcq)
        runner.check("each question stays with its answer",
                     LayoutRenderer.text(mcqLayout.blocks, style: .plain),
                     equals: "1. Capital of France?\tB\n2. Largest planet?\tC\n3. Fastest animal?\tA")
        runner.check("…as a Markdown table",
                     LayoutRenderer.text(mcqLayout.blocks, style: .markdown),
                     equals: "| 1. Capital of France? | B |\n| --- | --- |\n| 2. Largest planet? | C |\n| 3. Fastest animal? | A |")
        runner.check("side-by-side text is complex", mcqLayout.isComplex && mcqLayout.sideBySideRows == 3)
        runner.check("HTML table", LayoutRenderer.html(mcqLayout.blocks).contains("<td>Fastest animal?</td>") == false
                     && LayoutRenderer.html(mcqLayout.blocks).contains("<td>3. Fastest animal?</td><td>A</td>"))

        // ── Newspaper columns: read down, then across ──────────────────────
        let columns = [
            line("Left one", x: 0, y: 0, w: 200),
            line("Right one", x: 300, y: 12, w: 200),
            line("Left two", x: 0, y: 24, w: 200),
            line("Right two", x: 300, y: 36, w: 200),
            line("Left three", x: 0, y: 48, w: 200),
            line("Right three", x: 300, y: 60, w: 200),
            line("Left four", x: 0, y: 72, w: 200),
        ]
        let columnLayout = TextLayoutEngine.layout(columns)
        runner.check("each column read top to bottom, left column first",
                     LayoutRenderer.text(columnLayout.blocks, style: .plain),
                     equals: "Left one Left two Left three Left four\n\nRight one Right two Right three")
        runner.check("newspaper columns are complex", columnLayout.newspaperColumnRuns == 1)
        runner.check("plain recognition would have interleaved them",
                     TextLayoutEngine.rawText(columns).hasPrefix("Left one\nRight one\nLeft two"))

        // ── Questions with their options ───────────────────────────────────
        let questions = [
            line("1. Which is a prime?", x: 0, y: 0, w: 300),
            line("(a) 4", x: 0, y: 24, w: 60),
            line("(b) 7", x: 0, y: 48, w: 60),
            line("2. Pick a vowel", x: 0, y: 74, w: 250),
            line("a) k", x: 0, y: 98, w: 50),
        ]
        runner.check("options sit under their question",
                     LayoutRenderer.text(TextLayoutEngine.layout(questions).blocks, style: .plain),
                     equals: "1. Which is a prime?\n  (a) 4\n  (b) 7\n2. Pick a vowel\n  a) k")

        // ── Paragraphs, hyphenation, and lines that must stay apart ────────
        let letter = [
            line("The quick brown fox jumps over the exam-", x: 0, y: 0, w: 400),
            line("ple fence and runs", x: 0, y: 24, w: 200),
            line("Regards,", x: 0, y: 70, w: 80),
            line("Prathamesh", x: 0, y: 94, w: 100),
        ]
        runner.check("wrapped lines join; a sign-off keeps its line breaks",
                     LayoutRenderer.text(TextLayoutEngine.layout(letter).blocks, style: .plain),
                     equals: "The quick brown fox jumps over the example fence and runs\n\nRegards,\nPrathamesh")
        var keepHyphens = LayoutOptions()
        keepHyphens.joinHyphenatedWords = false
        runner.check("hyphen joining can be turned off",
                     LayoutRenderer.text(TextLayoutEngine.layout(letter, options: keepHyphens).blocks, style: .plain)
                        .hasPrefix("The quick brown fox jumps over the exam- ple fence"))

        let formRow = [
            line("Name: John", x: 0, y: 0, w: 100),
            line("Date: 5 May", x: 400, y: 0, w: 100),
        ]
        let formLayout = TextLayoutEngine.layout(formRow)
        runner.check("one row with a gap stays one line",
                     LayoutRenderer.text(formLayout.blocks, style: .plain), equals: "Name: John\tDate: 5 May")
        runner.check("…and is not complex", !formLayout.isComplex)

        runner.check("dash with no space is not a bullet",
                     ListMarker.parse("-5 °C outside", hasBulletMark: false, fixMisread: true) == nil)
        runner.check("“e.g.” is not a numbered item",
                     ListMarker.parse("e.g. this one", hasBulletMark: false, fixMisread: true) == nil)

        // ── The on-device model's arrangement is checked, not trusted ──────
        let segments = TextLayoutEngine.rows(mcq).flatMap { $0 }
        runner.check("segments for the model", segments.map(\.text),
                     equals: ["1. Capital of France?", "B", "2. Largest planet?", "C", "3. Fastest animal?", "A"])
        let good = [
            ProposedLayoutBlock(kind: "row", level: 0, lines: [1, 2]),
            ProposedLayoutBlock(kind: "row", level: 0, lines: [3, 4]),
            ProposedLayoutBlock(kind: "row", level: 0, lines: [5, 6]),
        ]
        let arranged = LayoutArrangement.blocks(from: good, lines: segments, options: LayoutOptions())
        runner.check("a complete arrangement is used",
                     arranged.map { LayoutRenderer.text($0, style: .plain) } ?? "nil",
                     equals: "1. Capital of France?\tB\n2. Largest planet?\tC\n3. Fastest animal?\tA")
        runner.check("a line left out → rejected",
                     LayoutArrangement.blocks(from: Array(good.dropLast()), lines: segments, options: LayoutOptions()) == nil)
        runner.check("a line used twice → rejected",
                     LayoutArrangement.blocks(from: good + [ProposedLayoutBlock(kind: "paragraph", level: 0, lines: [1])],
                                              lines: segments, options: LayoutOptions()) == nil)
        runner.check("a line that doesn't exist → rejected",
                     LayoutArrangement.blocks(from: [ProposedLayoutBlock(kind: "paragraph", level: 0, lines: Array(1...6) + [7])],
                                              lines: segments, options: LayoutOptions()) == nil)

        let prompt = LayoutArrangement.prompt(for: segments)
        runner.check("the model sees numbered, positioned lines",
                     prompt.contains("1. x=0 y=0") && prompt.contains("2. x=93") && prompt.contains("Fastest animal?"))

        // ── Spotting a bullet in pixels ────────────────────────────────────
        func strip(background: UInt8, ink: UInt8, width: Int = 24, height: Int = 20,
                   mark: (x: ClosedRange<Int>, y: ClosedRange<Int>)?) -> [UInt8] {
            var pixels = [UInt8](repeating: background, count: width * height)
            if let mark {
                for y in mark.y { for x in mark.x { pixels[y * width + x] = ink } }
            }
            return pixels
        }
        runner.check("a dot is a bullet",
                     BulletProbe.looksLikeBullet(gray: strip(background: 255, ink: 0, mark: (x: 14...19, y: 7...12)), width: 24, height: 20))
        runner.check("…in dark mode too",
                     BulletProbe.looksLikeBullet(gray: strip(background: 30, ink: 230, mark: (x: 14...19, y: 7...12)), width: 24, height: 20))
        runner.check("an empty strip is not",
                     !BulletProbe.looksLikeBullet(gray: strip(background: 255, ink: 0, mark: nil), width: 24, height: 20))
        runner.check("a dash is not",
                     !BulletProbe.looksLikeBullet(gray: strip(background: 255, ink: 0, mark: (x: 4...19, y: 9...10)), width: 24, height: 20))
        runner.check("a letter-sized block is not",
                     !BulletProbe.looksLikeBullet(gray: strip(background: 255, ink: 0, mark: (x: 8...20, y: 1...18)), width: 24, height: 20))

        return runner.failures
    }
}
