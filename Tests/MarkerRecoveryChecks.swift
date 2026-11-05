//
//  MarkerRecoveryChecks.swift
//  ClipStack tests
//
//  Option letters that recognition didn't read: finding where they belong,
//  telling an option from a wrapped line by ink, and filling the rest from
//  the sequence of the letters that were read.
//

import Foundation

@MainActor
enum MarkerRecoveryChecks {

    static func line(_ text: String, x: Double, y: Double, w: Double) -> OCRLine {
        OCRLine(text: text, minX: x, minY: y, width: w, height: 14)
    }

    static func run() -> Int {
        let runner = CheckRunner(suite: "Option letter recovery")

        // As recognition really returned the exam page: only "D" (question 10)
        // and "B" (question 11) of the option letters came back.
        let lines = [
            line("10", x: 20, y: 95, w: 16),
            line("Research completed in 1982 found that in the United States soil erosion", x: 65, y: 95, w: 470),
            line("reduced the productivity of farmland by 20 per cent.", x: 165, y: 125, w: 300),
            line("was almost as severe as in India and China.", x: 165, y: 141, w: 260),
            line("was causing significant damage to 20 per cent of farmland.", x: 165, y: 157, w: 330),
            line("D", x: 115, y: 173, w: 10),
            line("could be reduced by converting cultivated land to meadow or forest.", x: 165, y: 173, w: 400),
            line("11", x: 20, y: 208, w: 16),
            line("By the mid-1980s, farmers in Denmark", x: 65, y: 208, w: 250),
            line("used 50 per cent less fertiliser than Dutch farmers.", x: 165, y: 238, w: 290),
            line("B", x: 115, y: 254, w: 10),
            line("used twice as much fertiliser as they had in 1960.", x: 165, y: 254, w: 280),
        ]

        let columns = MarkerRecovery.columns(in: lines)
        runner.check("two marker columns: question numbers and option letters",
                     columns.map(\.isLetters).sorted { !$0 && $1 }, equals: [false, true])
        guard let letterIndex = columns.firstIndex(where: \.isLetters) else { return runner.failures + 1 }
        let letters = columns[letterIndex]
        runner.check("the letter column's text starts where the options do", letters.textX, equals: 165)

        let slots = MarkerRecovery.slots(in: lines, columns: columns).filter { $0.column == letterIndex }
        runner.check("the options missing a letter are found, and no others",
                     slots.map { lines[$0.line].text.prefix(12) }.map(String.init),
                     equals: ["reduced the ", "was almost a", "was causing ", "used 50 per "])

        // Every slot has ink (a letter is printed there); none could be read.
        var rows = lines
            .filter { MarkerRecovery.isBareMarker($0.text) && $0.minX >= letters.minX - 14 && $0.maxX <= letters.maxX + 14 }
            .map { MarkerRecovery.ColumnRow(y: $0.midY, known: $0.text, slot: nil) }
        for (index, slot) in slots.enumerated() {
            rows.append(MarkerRecovery.ColumnRow(y: slot.minY + slot.height / 2, known: nil, slot: index))
        }
        let resolved = MarkerRecovery.resolve(rows, column: letters, lineHeight: 14)
        runner.check("letters filled from the sequence, per question",
                     (0..<slots.count).map { resolved[$0] ?? "?" }, equals: ["A", "B", "C", "A"])

        // A misreading that doesn't fit the column ("4" for "B") gives way to
        // the sequence.
        var misread = rows
        if let index = misread.firstIndex(where: { $0.slot == 1 }) { misread[index].known = "4" }
        runner.check("a misread letter is corrected by the sequence",
                     MarkerRecovery.resolve(misread, column: letters, lineHeight: 14)[1] ?? "?", equals: "B")

        // A run where nothing was read, in a column whose runs start at A.
        let unread = [
            MarkerRecovery.ColumnRow(y: 100, known: "A", slot: nil),
            MarkerRecovery.ColumnRow(y: 116, known: "B", slot: nil),
            MarkerRecovery.ColumnRow(y: 200, known: nil, slot: 0),
            MarkerRecovery.ColumnRow(y: 216, known: nil, slot: 1),
        ]
        runner.check("a run with nothing read starts at A like the others",
                     MarkerRecovery.resolve(unread, column: letters, lineHeight: 14), equals: [0: "A", 1: "B"])

        // Ink: a wrapped line has none in the letter column, an option does.
        let blank = [UInt8](repeating: 250, count: 20 * 17)
        var letter = blank
        for y in 3...13 { for x in 6...13 where x == 6 || x == 13 || y == 8 { letter[y * 20 + x] = 20 } }
        runner.check("a blank slot has no ink", !MarkerRecovery.hasInk(gray: blank, width: 20, height: 17))
        runner.check("a letter-sized mark is ink", MarkerRecovery.hasInk(gray: letter, width: 20, height: 17))

        // Without their letters, options still don't run together.
        let unlettered = [
            line("reduced the productivity of farmland by 20 per cent.", x: 165, y: 125, w: 300),
            line("was almost as severe as in India and China.", x: 165, y: 141, w: 260),
        ]
        runner.check("a sentence ending “.” then one starting in lowercase stay apart",
                     LayoutRenderer.text(TextLayoutEngine.layout(unlettered).blocks, style: .plain),
                     equals: "reduced the productivity of farmland by 20 per cent.\nwas almost as severe as in India and China.")

        return runner.failures
    }
}
