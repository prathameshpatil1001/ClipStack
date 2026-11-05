//
//  BulletProbe.swift
//  ClipStack
//
//  Text recognition reads words, not symbols: a "•" in front of a line is
//  often dropped, or read as "e" or "o". So the image itself is checked: the
//  strip just left of each recognised line is looked at for a small, solid,
//  roughly round mark sitting on the line's middle — what a bullet looks like
//  in any font, light or dark.
//
//  Works on a plain grayscale buffer, so it is covered by the logic tests.
//

import Foundation

nonisolated enum BulletProbe {

    /// - Parameters:
    ///   - gray: luminance 0…255, row by row, `width × height`. The strip
    ///     left of a line of text, as tall as the line.
    /// - Returns: whether that strip holds one bullet-like mark.
    static func looksLikeBullet(gray: [UInt8], width: Int, height: Int) -> Bool {
        guard width >= 3, height >= 4, gray.count >= width * height else { return false }

        // The background is whatever most of the strip is.
        let background = Int(gray.sorted()[gray.count / 2])
        func isInk(_ value: UInt8) -> Bool { abs(Int(value) - background) > 60 }

        var minX = width, maxX = -1, minY = height, maxY = -1, count = 0
        for y in 0..<height {
            for x in 0..<width where isInk(gray[y * width + x]) {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count >= 3, maxX >= minX, maxY >= minY else { return false }

        let markWidth = Double(maxX - minX + 1)
        let markHeight = Double(maxY - minY + 1)
        let lineHeight = Double(height)

        // Small relative to the line: not a letter, not a word.
        guard markHeight >= 0.12 * lineHeight, markHeight <= 0.6 * lineHeight,
              markWidth >= 0.12 * lineHeight, markWidth <= 0.75 * lineHeight
        else { return false }

        // Roughly round or square: not a dash, not a bar.
        let aspect = markWidth / markHeight
        guard aspect >= 0.55, aspect <= 1.8 else { return false }

        // Mostly filled (•, ■), or at least a clear outline (◦, □).
        let fill = Double(count) / (markWidth * markHeight)
        guard fill >= 0.3 else { return false }

        // Sitting on the middle of the line, not hanging off its top or bottom.
        let centre = (Double(minY) + Double(maxY)) / 2 / lineHeight
        return centre >= 0.25 && centre <= 0.8
    }
}
