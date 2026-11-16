import Foundation

/// A run of lines that is either the same on both sides or changed.
public struct DiffBlock: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case equal, added, removed, modified
    }

    public var kind: Kind
    public var left: Range<Int>
    public var right: Range<Int>

    public init(kind: Kind, left: Range<Int>, right: Range<Int>) {
        self.kind = kind
        self.left = left
        self.right = right
    }
}

/// Number of change blocks of each kind.
public struct DiffStats: Sendable, Equatable {
    public var additions = 0
    public var deletions = 0
    public var changes = 0

    public init(additions: Int = 0, deletions: Int = 0, changes: Int = 0) {
        self.additions = additions
        self.deletions = deletions
        self.changes = changes
    }
}

/// The full comparison of two text documents.
public struct TextDiff: Sendable {
    public let left: TextDocument
    public let right: TextDocument
    public let blocks: [DiffBlock]
    /// Indices into `blocks` of every non-equal block, in order.
    public let changeBlocks: [Int]
    public let stats: DiffStats
    /// Changed character ranges (UTF-16 offsets) inside modified lines, keyed by line index.
    public let leftHighlights: [Int: [Range<Int>]]
    public let rightHighlights: [Int: [Range<Int>]]
    /// True when lines that differ only in whitespace were compared as equal. The two lines of an
    /// equal block can then differ in their spaces and tabs.
    public let ignoresWhitespace: Bool

    public var isIdentical: Bool { changeBlocks.isEmpty }

    public var lineEndingsDiffer: Bool {
        left.lineEnding != right.lineEnding && left.lineEnding != .none && right.lineEnding != .none
    }

    /// With `ignoreWhitespace`, indentation, trailing whitespace and the amount of whitespace between
    /// words do not count as differences. Whitespace that appears where the other side has none still does.
    public init(left: TextDocument, right: TextDocument, ignoreWhitespace: Bool = false, timeLimit: Double = 2.0) {
        var table: [String: Int32] = [:]
        table.reserveCapacity(left.lines.count + right.lines.count)
        func intern(_ lines: [String]) -> [Int32] {
            var out = [Int32]()
            out.reserveCapacity(lines.count)
            for line in lines {
                let s = ignoreWhitespace ? TextDiff.whitespaceKey(line) : line
                if let v = table[s] {
                    out.append(v)
                } else {
                    let v = Int32(table.count)
                    table[s] = v
                    out.append(v)
                }
            }
            return out
        }
        let a = intern(left.lines)
        let b = intern(right.lines)
        let (am, bm) = Myers.matches(a, b, timeLimit: timeLimit)
        self.init(left: left, right: right, blocks: TextDiff.splitModified(TextDiff.makeBlocks(am, bm), left.lines, right.lines),
                  ignoreWhitespace: ignoreWhitespace)
    }

    /// A line as it is compared when whitespace is ignored: without leading and trailing whitespace,
    /// and with every run of whitespace inside it as one space.
    public static func whitespaceKey(_ line: String) -> String {
        var out = String.UnicodeScalarView()
        var pending = false
        for sc in line.unicodeScalars {
            if sc == " " || sc == "\t" || (sc.value > 127 || sc.value < 32) && sc.properties.isWhitespace {
                pending = true
                continue
            }
            if pending && !out.isEmpty { out.append(" ") }
            pending = false
            out.append(sc)
        }
        return String(out)
    }

    /// A comparison whose blocks were worked out elsewhere, as a three-way merge does. The blocks must
    /// cover both documents in order.
    public init(left: TextDocument, right: TextDocument, blocks: [DiffBlock], ignoreWhitespace: Bool = false) {
        self.left = left
        self.right = right
        self.blocks = blocks
        ignoresWhitespace = ignoreWhitespace

        var changes: [Int] = []
        var stats = DiffStats()
        var lh: [Int: [Range<Int>]] = [:]
        var rh: [Int: [Range<Int>]] = [:]
        for (i, block) in blocks.enumerated() where block.kind != .equal {
            changes.append(i)
            switch block.kind {
            case .added: stats.additions += 1
            case .removed: stats.deletions += 1
            case .modified:
                stats.changes += 1
                InlineDiff.compute(left.lines, block.left, right.lines, block.right, &lh, &rh, ignoreWhitespace: ignoreWhitespace)
            case .equal: break
            }
        }
        changeBlocks = changes
        self.stats = stats
        leftHighlights = lh
        rightHighlights = rh
    }

    /// Turns match flags into blocks. A region with lines on both sides becomes a modified block.
    public static func makeBlocks(_ am: [Bool], _ bm: [Bool]) -> [DiffBlock] {
        var blocks: [DiffBlock] = []
        var i = 0, j = 0
        let n = am.count, m = bm.count
        while i < n || j < m {
            let si = i, sj = j
            if i < n && j < m && am[i] && bm[j] {
                while i < n && j < m && am[i] && bm[j] { i += 1; j += 1 }
                blocks.append(DiffBlock(kind: .equal, left: si..<i, right: sj..<j))
            } else {
                while i < n && !am[i] { i += 1 }
                while j < m && !bm[j] { j += 1 }
                let kind: DiffBlock.Kind = (i == si) ? .added : (j == sj ? .removed : .modified)
                blocks.append(DiffBlock(kind: kind, left: si..<i, right: sj..<j))
            }
        }
        return blocks
    }
}

extension TextDiff {
    static let similarityThreshold = 0.5
    static let maxSplitCells = 40_000

    /// Splits modified blocks with unequal line counts into similar line pairs (modified) and
    /// the unmatched lines between them (added or removed), so an edit next to a deletion
    /// shows as two changes rather than one.
    public static func splitModified(_ blocks: [DiffBlock], _ left: [String], _ right: [String]) -> [DiffBlock] {
        var out: [DiffBlock] = []
        out.reserveCapacity(blocks.count)
        for b in blocks {
            if b.kind == .modified && b.left.count != b.right.count && b.left.count * b.right.count <= maxSplitCells {
                out += split(b, left, right)
            } else {
                out.append(b)
            }
        }
        return out
    }

    static func tokens(_ s: String) -> [Substring: Int] {
        var counts: [Substring: Int] = [:]
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isLetter || c.isNumber || c == "_" {
                if start == nil { start = i }
            } else {
                if let st = start { counts[s[st..<i], default: 0] += 1; start = nil }
                if !c.isWhitespace { counts[s[i...i], default: 0] += 1 }
            }
            i = s.index(after: i)
        }
        if let st = start { counts[s[st...], default: 0] += 1 }
        return counts
    }

    /// Dice coefficient over word and punctuation tokens. Two blank lines are fully similar.
    static func similarity(_ a: [Substring: Int], _ b: [Substring: Int]) -> Double {
        let ta = a.values.reduce(0, +), tb = b.values.reduce(0, +)
        if ta + tb == 0 { return 1 }
        var common = 0
        for (k, v) in a { if let w = b[k] { common += min(v, w) } }
        return 2 * Double(common) / Double(ta + tb)
    }

    static func split(_ b: DiffBlock, _ left: [String], _ right: [String]) -> [DiffBlock] {
        let n = b.left.count, m = b.right.count
        let lt = b.left.map { tokens(left[$0]) }
        let rt = b.right.map { tokens(right[$0]) }
        var sim = [Double](repeating: 0, count: n * m)
        for i in 0..<n { for j in 0..<m { sim[i * m + j] = similarity(lt[i], rt[j]) } }
        // Weighted alignment: maximise total similarity of monotone pairs above the threshold.
        var dp = [Double](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in 1...n {
            for j in 1...m {
                var v = max(dp[(i - 1) * w + j], dp[i * w + j - 1])
                let s = sim[(i - 1) * m + j - 1]
                if s >= similarityThreshold { v = max(v, dp[(i - 1) * w + j - 1] + s) }
                dp[i * w + j] = v
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            let s = sim[(i - 1) * m + j - 1]
            if s >= similarityThreshold && dp[i * w + j] == dp[(i - 1) * w + j - 1] + s {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if dp[i * w + j] == dp[(i - 1) * w + j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        if pairs.isEmpty { return [b] }
        pairs.reverse()

        var out: [DiffBlock] = []
        let l0 = b.left.lowerBound, r0 = b.right.lowerBound
        func push(_ li: Range<Int>, _ ri: Range<Int>) {
            if li.isEmpty && ri.isEmpty { return }
            let kind: DiffBlock.Kind = li.isEmpty ? .added : (ri.isEmpty ? .removed : .modified)
            let block = DiffBlock(kind: kind, left: (l0 + li.lowerBound)..<(l0 + li.upperBound),
                                  right: (r0 + ri.lowerBound)..<(r0 + ri.upperBound))
            if let last = out.last, last.kind == kind {
                out[out.count - 1] = DiffBlock(kind: kind, left: last.left.lowerBound..<block.left.upperBound,
                                               right: last.right.lowerBound..<block.right.upperBound)
            } else {
                out.append(block)
            }
        }
        var li = 0, rj = 0
        for (pi, pj) in pairs {
            push(li..<pi, rj..<pj)
            push(pi..<(pi + 1), pj..<(pj + 1))
            li = pi + 1
            rj = pj + 1
        }
        push(li..<n, rj..<m)
        return out
    }
}

/// Word-level diff inside a modified block, refined to characters where a single word changed.
enum InlineDiff {
    static let maxTokens = 40_000

    struct Token {
        var line: Int
        var start: Int
        var end: Int
        var kind: UInt8 // 0 word, 1 space, 2 punctuation, 3 line break
        var text: String
    }

    static func tokenize(_ lines: [String], _ range: Range<Int>) -> [Token] {
        var tokens: [Token] = []
        for li in range {
            var off = 0
            var curKind: UInt8 = 255
            var curStart = 0
            var curText = String.UnicodeScalarView()
            func flush() {
                if curKind != 255 {
                    tokens.append(Token(line: li, start: curStart, end: off, kind: curKind, text: String(curText)))
                    curKind = 255
                    curText = String.UnicodeScalarView()
                }
            }
            for sc in lines[li].unicodeScalars {
                let p = sc.properties
                let kind: UInt8 = (p.isAlphabetic || p.numericType != nil || sc == "_") ? 0 : (p.isWhitespace ? 1 : 2)
                if kind == 2 || kind != curKind {
                    flush()
                    curKind = kind
                    curStart = off
                }
                curText.append(sc)
                off += sc.utf16.count
                if kind == 2 { flush() }
            }
            flush()
            tokens.append(Token(line: li, start: off, end: off, kind: 3, text: "\n"))
        }
        return tokens
    }

    static func compute(
        _ leftLines: [String], _ leftRange: Range<Int>,
        _ rightLines: [String], _ rightRange: Range<Int>,
        _ lh: inout [Int: [Range<Int>]], _ rh: inout [Int: [Range<Int>]], ignoreWhitespace: Bool = false
    ) {
        var tl = tokenize(leftLines, leftRange)
        var tr = tokenize(rightLines, rightRange)
        if tl.count + tr.count > maxTokens { return }
        var ids: [String: Int32] = [:]
        func id(_ s: String) -> Int32 {
            if let v = ids[s] { return v }
            let v = Int32(ids.count); ids[s] = v; return v
        }
        // When whitespace is ignored every run of it is the same token, and none is ever highlighted.
        let a = tl.map { id(ignoreWhitespace && $0.kind == 1 ? " " : $0.text) }
        let b = tr.map { id(ignoreWhitespace && $0.kind == 1 ? " " : $0.text) }
        var (am, bm) = Myers.matches(a, b, timeLimit: 0.2)

        // Refine a single changed word to the characters that differ.
        var i = 0, j = 0
        while i < tl.count || j < tr.count {
            if i < tl.count && j < tr.count && am[i] && bm[j] { i += 1; j += 1; continue }
            let i0 = i, j0 = j
            while i < tl.count && !am[i] { i += 1 }
            while j < tr.count && !bm[j] { j += 1 }
            if i - i0 == 1 && j - j0 == 1 && tl[i0].kind == 0 && tr[j0].kind == 0 {
                let x = Array(tl[i0].text.utf16), y = Array(tr[j0].text.utf16)
                var p = 0
                while p < x.count && p < y.count && x[p] == y[p] { p += 1 }
                var s = 0
                while s < x.count - p && s < y.count - p && x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
                // Only refine when a meaningful part of the word survived; otherwise highlight it whole.
                if p + s >= max(x.count, y.count) / 2 {
                    tl[i0].start += p; tl[i0].end -= s
                    tr[j0].start += p; tr[j0].end -= s
                }
            }
        }

        // Join changed words separated by a single unchanged space.
        func bridge(_ t: [Token], _ matched: inout [Bool]) {
            guard t.count > 2 else { return }
            for k in 1..<(t.count - 1) where t[k].kind == 1 && matched[k] {
                if !matched[k - 1] && !matched[k + 1] && t[k - 1].kind != 3 && t[k + 1].kind != 3 {
                    matched[k] = false
                }
            }
        }
        bridge(tl, &am)
        bridge(tr, &bm)

        func emit(_ t: [Token], _ matched: [Bool], _ out: inout [Int: [Range<Int>]]) {
            for (k, tok) in t.enumerated() where !matched[k] && tok.kind != 3 && tok.end > tok.start {
                if ignoreWhitespace && tok.kind == 1 { continue }
                var list = out[tok.line] ?? []
                if let last = list.last, last.upperBound >= tok.start {
                    list[list.count - 1] = last.lowerBound..<max(last.upperBound, tok.end)
                } else {
                    list.append(tok.start..<tok.end)
                }
                out[tok.line] = list
            }
        }
        emit(tl, am, &lh)
        emit(tr, bm, &rh)
    }
}
