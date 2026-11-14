import AppKit

/// Font measurements for the diff view. Everything is derived from one monospaced font,
/// so the position of any line is arithmetic.
@MainActor
final class TextMetrics {
    let size: CGFloat
    let font: NSFont
    let smallFont: NSFont
    let charWidth: CGFloat
    let smallCharWidth: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    /// Height of one wrapped text row.
    let rowHeight: CGFloat
    /// Space above and below each logical line.
    let linePad: CGFloat
    let foldHeight: CGFloat
    let paragraphStyle: NSParagraphStyle

    init(size: CGFloat) {
        self.size = size
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        smallFont = NSFont.monospacedSystemFont(ofSize: max(8, round(size * 0.9)), weight: .regular)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        smallCharWidth = ("0" as NSString).size(withAttributes: [.font: smallFont]).width
        ascent = ceil(font.ascender)
        descent = ceil(-font.descender)
        rowHeight = ceil(ascent + descent + max(1, size * 0.12))
        linePad = max(2, round(size * 0.22))
        foldHeight = round(rowHeight * 2 + linePad * 4)
        let ps = NSMutableParagraphStyle()
        ps.tabStops = []
        ps.defaultTabInterval = charWidth * CGFloat(Columns.tabWidth)
        paragraphStyle = ps
    }

    func lineHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + 2 * linePad
    }
}

/// Display-column arithmetic for a monospaced font.
enum Columns {
    static let tabWidth = 4

    @inline(__always)
    static func width(_ v: UInt32) -> Int {
        if v < 0x300 { return 1 }
        if (0x300...0x36F).contains(v) || (0x200B...0x200F).contains(v) || (0xFE00...0xFE0F).contains(v)
            || (0x1AB0...0x1AFF).contains(v) || (0x20D0...0x20FF).contains(v) {
            return 0
        }
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
    }

    static func count(_ s: String) -> Int {
        var col = 0
        for sc in s.unicodeScalars {
            col += sc.value == 9 ? tabWidth - col % tabWidth : width(sc.value)
        }
        return col
    }

    static func compute(_ lines: [String]) -> [Int32] {
        lines.map { Int32(clamping: count($0)) }
    }

    /// Greedy word wrap. Returns the UTF-16 offset at which each row starts; the first is always 0.
    static func wrap(_ s: String, columns: Int) -> [Int] {
        var starts = [0]
        var col = 0
        var off = 0
        var breakOff = -1
        var breakCol = 0
        for sc in s.unicodeScalars {
            let w = sc.value == 9 ? tabWidth - col % tabWidth : width(sc.value)
            if col + w > columns && col > 0 {
                if breakOff > starts[starts.count - 1] && breakOff < off + 1 {
                    starts.append(breakOff)
                    col -= breakCol
                } else {
                    starts.append(off)
                    col = 0
                }
                breakOff = -1
            }
            col += w
            off += sc.utf16.count
            if sc == " " || sc == "\t" {
                breakOff = off
                breakCol = col
            }
        }
        return starts
    }
}
