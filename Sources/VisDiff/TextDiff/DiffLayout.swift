import AppKit
import DiffCore

enum Side: Int {
    case left = 0, right = 1
}

/// One vertical slice of the comparison: an unchanged line pair, a folded run, or a change block.
///
/// `t` and `h` are in the shared logical scroll space. Each side has its own position `y`,
/// the space it occupies `span` (equal to `h` in Blocks mode), and its content height.
struct LayoutSection {
    enum Kind: UInt8 { case equal, fold, change }

    var kind: Kind
    var block: Int
    var change: Int
    var leftLines: Range<Int>
    var rightLines: Range<Int>
    var t: CGFloat
    var h: CGFloat
    var leftY: CGFloat
    var rightY: CGFloat
    var leftSpan: CGFloat
    var rightSpan: CGFloat
    var leftHeight: CGFloat
    var rightHeight: CGFloat

    func lines(_ s: Side) -> Range<Int> { s == .left ? leftLines : rightLines }
    func y(_ s: Side) -> CGFloat { s == .left ? leftY : rightY }
    func span(_ s: Side) -> CGFloat { s == .left ? leftSpan : rightSpan }
    func height(_ s: Side) -> CGFloat { s == .left ? leftHeight : rightHeight }
}

/// Positions every line of a diff for a given width, font and layout mode.
@MainActor
final class DiffLayout {
    static let context = 3
    static let minimumFold = 4
    private static let singleRow = [0]

    let diff: TextDiff
    let metrics: TextMetrics
    let mode: LayoutMode
    let wrapColumns: Int?
    let expanded: Set<Int>
    let expandAll: Bool

    private(set) var sections: [LayoutSection] = []
    private var sectionT: [CGFloat] = []
    private var sectionY: [[CGFloat]] = [[], []]
    /// Top of each line in its side's coordinates; -1 for folded lines.
    private(set) var lineTop: [[CGFloat]]
    private var breaks: [[Int: [Int]]] = [[:], [:]]
    /// Section index of each change, by change ordinal.
    private(set) var changeSections: [Int] = []
    private(set) var totalT: CGFloat = 0
    private(set) var totals: [CGFloat] = [0, 0]

    init(diff: TextDiff, columns: [[Int32]], metrics: TextMetrics, mode: LayoutMode,
         wrapColumns: Int?, expanded: Set<Int>, expandAll: Bool) {
        self.diff = diff
        self.metrics = metrics
        self.mode = mode
        self.wrapColumns = wrapColumns
        self.expanded = expanded
        self.expandAll = expandAll
        lineTop = [
            [CGFloat](repeating: -1, count: diff.left.lines.count),
            [CGFloat](repeating: -1, count: diff.right.lines.count),
        ]
        if let wc = wrapColumns {
            for side in 0..<2 {
                let lines = side == 0 ? diff.left.lines : diff.right.lines
                let cols = columns[side]
                guard cols.count == lines.count else { continue }
                for i in 0..<cols.count where Int(cols[i]) > wc {
                    breaks[side][i] = Columns.wrap(lines[i], columns: wc)
                }
            }
        }
        build()
    }

    func lines(_ side: Side) -> [String] {
        side == .left ? diff.left.lines : diff.right.lines
    }

    func rowStarts(_ side: Side, _ line: Int) -> [Int] {
        breaks[side.rawValue][line] ?? Self.singleRow
    }

    func lineHeight(_ side: Side, _ line: Int) -> CGFloat {
        metrics.lineHeight(rows: breaks[side.rawValue][line]?.count ?? 1)
    }

    // MARK: Building

    private var t: CGFloat = 0
    private var yl: CGFloat = 0
    private var yr: CGFloat = 0

    private func build() {
        let blocks = diff.blocks
        let folding = !diff.isIdentical && !expandAll
        var changeOrdinal = 0
        for (bi, block) in blocks.enumerated() {
            switch block.kind {
            case .equal:
                let n = block.left.count
                let head = bi > 0 ? Self.context : 0
                let tail = bi < blocks.count - 1 ? Self.context : 0
                if folding && !expanded.contains(bi) && n - head - tail >= Self.minimumFold {
                    addEqual(block, 0..<head)
                    addFold(block, bi, head..<(n - tail))
                    addEqual(block, (n - tail)..<n)
                } else {
                    addEqual(block, 0..<n)
                }
            default:
                addChange(block, bi, changeOrdinal)
                changeOrdinal += 1
            }
        }
        totalT = t
        totals = [yl, yr]
        sectionT = sections.map(\.t)
        sectionY = [sections.map(\.leftY), sections.map(\.rightY)]
    }

    private func addEqual(_ block: DiffBlock, _ offsets: Range<Int>) {
        for k in offsets {
            let l = block.left.lowerBound + k, r = block.right.lowerBound + k
            let lh = lineHeight(.left, l), rh = lineHeight(.right, r)
            let h = max(lh, rh)
            let ls = mode == .blocks ? h : lh, rs = mode == .blocks ? h : rh
            lineTop[0][l] = yl
            lineTop[1][r] = yr
            sections.append(LayoutSection(
                kind: .equal, block: -1, change: -1, leftLines: l..<(l + 1), rightLines: r..<(r + 1),
                t: t, h: h, leftY: yl, rightY: yr, leftSpan: ls, rightSpan: rs, leftHeight: lh, rightHeight: rh))
            t += h; yl += ls; yr += rs
        }
    }

    private func addFold(_ block: DiffBlock, _ index: Int, _ offsets: Range<Int>) {
        let h = metrics.foldHeight
        let l = (block.left.lowerBound + offsets.lowerBound)..<(block.left.lowerBound + offsets.upperBound)
        let r = (block.right.lowerBound + offsets.lowerBound)..<(block.right.lowerBound + offsets.upperBound)
        sections.append(LayoutSection(
            kind: .fold, block: index, change: -1, leftLines: l, rightLines: r,
            t: t, h: h, leftY: yl, rightY: yr, leftSpan: h, rightSpan: h, leftHeight: h, rightHeight: h))
        t += h; yl += h; yr += h
    }

    private func addChange(_ block: DiffBlock, _ index: Int, _ ordinal: Int) {
        var lh: CGFloat = 0
        for l in block.left {
            lineTop[0][l] = yl + lh
            lh += lineHeight(.left, l)
        }
        var rh: CGFloat = 0
        for r in block.right {
            lineTop[1][r] = yr + rh
            rh += lineHeight(.right, r)
        }
        let h = max(lh, rh)
        let ls = mode == .blocks ? h : lh, rs = mode == .blocks ? h : rh
        changeSections.append(sections.count)
        sections.append(LayoutSection(
            kind: .change, block: index, change: ordinal, leftLines: block.left, rightLines: block.right,
            t: t, h: h, leftY: yl, rightY: yr, leftSpan: ls, rightSpan: rs, leftHeight: lh, rightHeight: rh))
        t += h; yl += ls; yr += rs
    }

    // MARK: Queries

    private static func lastIndex(_ a: [CGFloat], atMost v: CGFloat) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid] <= v { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    func sectionIndex(atT t: CGFloat) -> Int {
        Self.lastIndex(sectionT, atMost: t)
    }

    func sectionIndex(_ side: Side, atY y: CGFloat) -> Int {
        Self.lastIndex(sectionY[side.rawValue], atMost: y)
    }

    /// Maps a logical position to the matching position on one side.
    func sideY(forT t: CGFloat, _ side: Side) -> CGFloat {
        if sections.isEmpty || t <= 0 { return t }
        if t >= totalT { return totals[side.rawValue] + (t - totalT) }
        let s = sections[sectionIndex(atT: t)]
        let frac = s.h > 0 ? (t - s.t) / s.h : 0
        return s.y(side) + frac * s.span(side)
    }

    /// Inverse of `sideY(forT:)`.
    func t(forY y: CGFloat, _ side: Side) -> CGFloat {
        if sections.isEmpty || y <= 0 { return y }
        let total = totals[side.rawValue]
        if y >= total { return totalT + (y - total) }
        let s = sections[sectionIndex(side, atY: y)]
        let span = s.span(side)
        let frac = span > 0 ? min(1, (y - s.y(side)) / span) : 1
        return s.t + frac * s.h
    }

    /// The line of a section that contains `y`, or the last line above it.
    func line(in s: LayoutSection, _ side: Side, atY y: CGFloat) -> Int? {
        let r = s.lines(side)
        guard s.kind != .fold, !r.isEmpty else { return nil }
        let tops = lineTop[side.rawValue]
        var lo = r.lowerBound, hi = r.upperBound
        while lo < hi {
            let mid = (lo + hi) >> 1
            if tops[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        return max(r.lowerBound, lo - 1)
    }

    /// Index of the section containing a visible line.
    func section(containing line: Int, _ side: Side) -> Int? {
        let top = lineTop[side.rawValue][line]
        guard top >= 0 else { return nil }
        var i = sectionIndex(side, atY: top)
        while i >= 0 {
            if sections[i].lines(side).contains(line) { return i }
            if sections[i].y(side) < top { break }
            i -= 1
        }
        return nil
    }
}
