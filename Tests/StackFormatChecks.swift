//
//  StackFormatChecks.swift
//  ClipStack tests
//
//  Format Stack: copied text laid out by its own structure, code kept
//  verbatim, items merged into one document, and the on-device model's labels
//  for copied lines checked rather than trusted.
//

import Foundation

@MainActor
enum StackFormatChecks {

    static func run() -> Int {
        let runner = CheckRunner(suite: "Format Stack")
        let options = LayoutOptions()

        func plain(_ blocks: [LayoutBlock]) -> String { LayoutRenderer.text(blocks, style: .plain) }

        // ── Copied text, by its own structure ──────────────────────────────
        let notes = "## Groceries\n\n- Milk\n- Eggs\n  - Organic\n    farm fresh\n\nPlain sentence.\n\n1. Question one?\n(a) yes\n(b) no"
        let noteBlocks = PlainTextLayout.blocks(from: notes, options: options)
        runner.check("headings, nested bullets, wrapped items, questions and options",
                     plain(noteBlocks),
                     equals: "Groceries\n\n• Milk\n• Eggs\n  • Organic farm fresh\n\nPlain sentence.\n\n1. Question one?\n  (a) yes\n  (b) no")
        runner.check("…and as Markdown",
                     LayoutRenderer.text(noteBlocks, style: .markdown),
                     equals: "## Groceries\n\n- Milk\n- Eggs\n  - Organic farm fresh\n\nPlain sentence.\n\n1. Question one?\n  (a) yes\n  (b) no")

        runner.check("a Markdown table becomes rows (the rule line dropped)",
                     plain(PlainTextLayout.blocks(from: "| Name | Score |\n|---|---|\n| Asha | 9 |", options: options)),
                     equals: "Name\tScore\nAsha\t9")
        runner.check("tab-separated lines are rows",
                     plain(PlainTextLayout.blocks(from: "a\tb\nc\td", options: options)),
                     equals: "a\tb\nc\td")

        let command = TemplateFillChecks.scpFilled
        let commandBlocks = PlainTextLayout.blocks(from: command, options: options)
        runner.check("a command is kept verbatim", plain(commandBlocks), equals: command)
        runner.check("…fenced in Markdown",
                     LayoutRenderer.text(commandBlocks, style: .markdown), equals: "```\n" + command + "\n```")
        runner.check("prose starting “go to…” is not code",
                     !PlainTextLayout.isCode("go to the store\nmake sure to buy milk\ncd players are old"))

        // ── Merging the stack ──────────────────────────────────────────────
        let items = [
            StackFormatItem(text: "• Milk", blocks: nil),
            StackFormatItem(text: "• Eggs", blocks: nil),
            StackFormatItem(text: "Done shopping", blocks: nil),
        ]
        runner.check("bullets copied one at a time become one list",
                     plain(StackFormatter.merge(StackFormatter.blocks(for: items, options: options))),
                     equals: "• Milk\n• Eggs\n\nDone shopping")

        let captured = [
            LayoutBlock(kind: .tableRow, cells: ["1. Capital of France?", "B"]),
            LayoutBlock(kind: .tableRow, cells: ["2. Largest planet?", "C"]),
        ]
        let mixed = [
            StackFormatItem(text: "1. Capital of France?  B\n2. Largest planet?  C", blocks: captured),
            StackFormatItem(text: "3. Fastest animal?\tA", blocks: nil),
        ]
        runner.check("a capture keeps its layout; matching rows join its table",
                     plain(StackFormatter.merge(StackFormatter.blocks(for: mixed, options: options))),
                     equals: "1. Capital of France?\tB\n2. Largest planet?\tC\n3. Fastest animal?\tA")

        // ── When the model is worth asking ─────────────────────────────────
        let webList = PlainTextLayout.blocks(from: "Apples\nPears\nPlums", options: options)
        runner.check("a list copied without its bullets may have lost structure",
                     StackFormatter.mightHaveLostStructure(webList, lineCount: 3))
        runner.check("text that already has bullets has not",
                     !StackFormatter.mightHaveLostStructure(PlainTextLayout.blocks(from: "• a\n• b\n• c", options: options), lineCount: 3))
        runner.check("two lines aren't worth asking about",
                     !StackFormatter.mightHaveLostStructure(PlainTextLayout.blocks(from: "Hi\nThere", options: options), lineCount: 2))

        // ── The model's labels are checked ─────────────────────────────────
        let lines = PlainTextLayout.lines("Fruits\nApples\nPears")
        let labels = [
            ProposedLayoutBlock(kind: "heading", level: 0, lines: [1]),
            ProposedLayoutBlock(kind: "bullet", level: 0, lines: [2]),
            ProposedLayoutBlock(kind: "bullet", level: 0, lines: [3]),
        ]
        runner.check("labels that cover every line in order are used",
                     TextArrangement.blocks(from: labels, lines: lines, options: options).map(plain) ?? "nil",
                     equals: "Fruits\n\n• Apples\n• Pears")
        runner.check("reordering lines is refused",
                     TextArrangement.blocks(from: [labels[1], labels[0], labels[2]], lines: lines, options: options) == nil)
        runner.check("leaving a line out is refused",
                     TextArrangement.blocks(from: Array(labels.prefix(2)), lines: lines, options: options) == nil)
        runner.check("the model sees numbered lines with their indent",
                     TextArrangement.prompt(for: lines).contains("1. indent=0 Fruits"))

        return runner.failures
    }
}
