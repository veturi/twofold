import Foundation

/// What a highlighted piece of source text is. The app maps each kind to a colour.
public enum SyntaxKind: UInt8, Sendable, CaseIterable {
    case keyword, string, number, comment, type, function, attribute, property, tag
}

/// A highlighted range within one line, in UTF-16 offsets.
public struct SyntaxSpan: Sendable, Hashable {
    public var start: Int32
    public var end: Int32
    public var kind: SyntaxKind

    public var range: Range<Int> { Int(start)..<Int(end) }
}

/// The spans of every line of a document, stored flat. Spans within a line are ordered and never overlap.
public struct SyntaxMap: Sendable {
    let spans: [SyntaxSpan]
    /// Index of each line's first span, plus one final entry.
    let lineStarts: [Int32]

    public var lineCount: Int { lineStarts.count - 1 }

    public subscript(line: Int) -> ArraySlice<SyntaxSpan> {
        guard line >= 0, line < lineCount else { return [] }
        return spans[Int(lineStarts[line])..<Int(lineStarts[line + 1])]
    }
}

/// A language Twofold can colour. Highlighting is lexical: tokens, not a parse tree.
public struct SyntaxLanguage: Sendable {
    public let name: String
    private let makeLexer: @Sendable () -> any SyntaxLexer

    init(_ name: String, _ makeLexer: @escaping @Sendable () -> any SyntaxLexer) {
        self.name = name
        self.makeLexer = makeLexer
    }

    /// Tokenizes a whole document. State such as an open block comment carries from line to line.
    public func highlight(_ lines: [String]) -> SyntaxMap {
        let lexer = makeLexer()
        var spans: [SyntaxSpan] = []
        var starts: [Int32] = []
        starts.reserveCapacity(lines.count + 1)
        var buffer: [UInt16] = []
        for line in lines {
            starts.append(Int32(spans.count))
            buffer.removeAll(keepingCapacity: true)
            buffer.append(contentsOf: line.utf16)
            buffer.withUnsafeBufferPointer { lexer.lex($0, 0..<$0.count, &spans) }
        }
        starts.append(Int32(spans.count))
        return SyntaxMap(spans: spans, lineStarts: starts)
    }

    /// Picks a language from the file name, or failing that from a `#!` first line.
    public static func detect(fileName: String, firstLine: String? = nil) -> SyntaxLanguage? {
        let lower = fileName.lowercased()
        if let id = Languages.byName[lower] { return Languages.make(id) }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return Languages.make("dockerfile") }
        if lower.hasPrefix("makefile") { return Languages.make("makefile") }
        let ext = (lower as NSString).pathExtension
        if let id = Languages.byExtension[ext] { return Languages.make(id) }
        if let first = firstLine, first.hasPrefix("#!") {
            for (needle, id) in Languages.shebangs where first.contains(needle) { return Languages.make(id) }
        }
        return nil
    }

    /// Looks a language up by its identifier, such as "swift" or "html".
    public static func named(_ id: String) -> SyntaxLanguage? { Languages.make(id) }
}

/// Tokenizes one stretch of a line at a time and remembers what is still open at its end.
protocol SyntaxLexer: AnyObject {
    func lex(_ b: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, _ out: inout [SyntaxSpan])
}

extension Array where Element == SyntaxSpan {
    @inline(__always)
    mutating func add(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
        if end > start { append(SyntaxSpan(start: Int32(start), end: Int32(end), kind: kind)) }
    }
}

// MARK: Character helpers

@inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
@inline(__always) private func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
@inline(__always) private func isLower(_ c: UInt16) -> Bool { c >= 97 && c <= 122 }
@inline(__always) private func isLetter(_ c: UInt16) -> Bool { isUpper(c) || isLower(c) }
@inline(__always) private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
/// Letters, digits, underscore and everything outside ASCII.
@inline(__always) private func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == 95 || c >= 128 }
@inline(__always) private func isHex(_ c: UInt16) -> Bool { isDigit(c) || ((c | 32) >= 97 && (c | 32) <= 102) }

private func units(_ s: String) -> [UInt16] { Array(s.utf16) }

@inline(__always)
private func matches(_ b: UnsafeBufferPointer<UInt16>, _ p: [UInt16], _ i: Int, _ n: Int) -> Bool {
    guard i + p.count <= n else { return false }
    for k in 0..<p.count where b[i + k] != p[k] { return false }
    return true
}

/// First position of an ASCII pattern at or after `i`, optionally ignoring case.
private func find(_ b: UnsafeBufferPointer<UInt16>, _ p: [UInt16], _ i: Int, _ n: Int, ignoreCase: Bool = false) -> Int? {
    guard !p.isEmpty, i + p.count <= n else { return nil }
    var j = i
    outer: while j + p.count <= n {
        for k in 0..<p.count {
            let c = ignoreCase && isUpper(b[j + k]) ? b[j + k] | 32 : b[j + k]
            if c != p[k] { j += 1; continue outer }
        }
        return j
    }
    return nil
}

private func word(_ b: UnsafeBufferPointer<UInt16>, _ s: Int, _ e: Int) -> String {
    String(decoding: UnsafeBufferPointer(rebasing: b[s..<e]), as: UTF16.self)
}

// MARK: Code

/// A quoted literal: how it opens and closes, and whether it may run over several lines.
struct StringRule: Sendable {
    var open: [UInt16]
    var close: [UInt16]
    var escape = true
    var multiline = false
    /// Only a literal when it closes after one character or one escape, like Rust's 'a' next to lifetimes.
    var charLike = false

    init(_ open: String, _ close: String? = nil, escape: Bool = true, multiline: Bool = false, charLike: Bool = false) {
        self.open = units(open)
        self.close = units(close ?? open)
        self.escape = escape
        self.multiline = multiline
        self.charLike = charLike
    }

    static let double = StringRule("\"")
    static let single = StringRule("'")
}

/// Describes a programming or configuration language to the general-purpose `CodeLexer`.
struct Grammar: Sendable {
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [[UInt16]] = []
    var blockComments: [(open: [UInt16], close: [UInt16])] = []
    var nestedComments = false
    /// A line comment must start the line or follow whitespace (shell's `$#`, INI's `a;b`).
    var commentNeedsSpace = false
    var strings: [StringRule] = [.double, .single]
    var caseInsensitive = false
    var identStart: [UInt16] = []
    var identPart: [UInt16] = []
    /// Identifiers that start with a capital and contain a lowercase letter are types.
    var capitalizedTypes = false
    /// With `capitalizedTypes`, all-capital names such as `URL` are types too rather than constants.
    var capitalsAreTypes = false
    /// An identifier directly followed by `(` is a function.
    var functionCalls = true
    /// Characters that turn the following identifier into an attribute: `@objc`, `#include`.
    var attributePrefixes: [UInt16] = []
    /// `#include <file>` colours the bracketed file as a string.
    var cInclude = false
    /// Rust's `#[derive(...)]`.
    var bracketAttributes = false
    /// Rust's `println!(...)`.
    var bangMacros = false
    /// `$name` and `${name}` are variables.
    var variables = false
    /// Make's `$(NAME)`.
    var variableParens = false
    /// JavaScript's `/pattern/flags`.
    var regex = false
    /// A string followed by `:` is a key (JSON).
    var keyStrings = false
    /// A line starting with `[` is a section header (TOML, INI).
    var sectionHeaders = false
    /// A name starting the line and followed by one of these is a key (`=` in TOML, `:` in Make).
    var lineKeys: [UInt16] = []

    var maxWord = 0
    var special = [Bool](repeating: false, count: 128)
    /// ASCII characters that can begin a keyword or type name, so most identifiers skip the set lookup.
    var wordStart = [Bool](repeating: false, count: 128)
    var startTable = [Bool](repeating: false, count: 128)
    var partTable = [Bool](repeating: false, count: 128)

    init(keywords: String = "", types: String = "", line: [String] = ["//"], block: [(String, String)] = [("/*", "*/")]) {
        self.keywords = Set(keywords.split(separator: " ").map(String.init))
        self.types = Set(types.split(separator: " ").map(String.init))
        lineComments = line.map(units)
        blockComments = block.map { (units($0.0), units($0.1)) }
    }

    /// Call after the last change: precomputes the lookups the lexer's inner loop uses.
    func finished() -> Grammar {
        var g = self
        g.maxWord = (keywords.map(\.utf16.count) + types.map(\.utf16.count)).max() ?? 0
        g.special = [Bool](repeating: false, count: 128)
        for first in lineComments.compactMap(\.first) + blockComments.compactMap(\.open.first) + strings.compactMap(\.open.first)
        where first < 128 {
            g.special[Int(first)] = true
        }
        for w in keywords.union(types) {
            guard let c = w.utf16.first, c < 128 else { continue }
            g.wordStart[Int(c)] = true
            if caseInsensitive && isLetter(c) { g.wordStart[Int(c ^ 32)] = true }
        }
        for c in UInt16(0)..<128 {
            g.startTable[Int(c)] = isLetter(c) || c == 95 || identStart.contains(c)
            g.partTable[Int(c)] = isWord(c) || identPart.contains(c)
        }
        return g
    }
}

/// Tokenizes C-like and scripting languages from a `Grammar`.
final class CodeLexer: SyntaxLexer {
    private let g: Grammar
    /// 0 in code, 1... inside block comment `mode - 1`, 100... inside string rule `mode - 100`.
    private var mode = 0
    private var depth = 0

    init(_ grammar: Grammar) { g = grammar }

    func reset() { mode = 0; depth = 0 }

    func lex(_ b: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, _ out: inout [SyntaxSpan]) {
        var i = range.lowerBound
        let n = range.upperBound
        var first = true
        /// The last significant character, to tell a regular expression from a division.
        var prev: UInt16 = 0

        func closeOf(_ r: StringRule, _ from: Int) -> Int? {
            var j = from
            while j < n {
                if r.escape && b[j] == 92 { j += 2; continue }
                if matches(b, r.close, j, n) { return j + r.close.count }
                j += 1
            }
            return nil
        }
        let startTable = g.startTable, partTable = g.partTable
        @inline(__always) func identStart(_ c: UInt16) -> Bool { c >= 128 || startTable[Int(c)] }
        @inline(__always) func identPart(_ c: UInt16) -> Bool { c >= 128 || partTable[Int(c)] }
        func skipSpaces(_ from: Int) -> Int {
            var j = from
            while j < n && isSpace(b[j]) { j += 1 }
            return j
        }

        while i < n {
            if mode >= 100 {
                let r = g.strings[mode - 100], s = i
                if let e = closeOf(r, i) { i = e; mode = 0 } else { i = n }
                out.add(s, i, .string)
                prev = 34
                first = false
                continue
            }
            if mode > 0 {
                let s = i
                scanBlockComment(b, &i, n)
                out.add(s, i, .comment)
                first = false
                continue
            }
            let c = b[i]
            if isSpace(c) { i += 1; continue }
            let wasFirst = first
            first = false

            if wasFirst {
                if g.sectionHeaders && c == 91 {
                    var e = n - 1
                    while e > i && b[e] != 93 { e -= 1 }
                    if e > i {
                        out.add(i, e + 1, .tag)
                        i = e + 1
                        continue
                    }
                }
                if !g.lineKeys.isEmpty {
                    var j = i
                    while j < n && (isWord(b[j]) || b[j] == 45 || b[j] == 46) { j += 1 }
                    let k = skipSpaces(j)
                    if j > i && k < n {
                        let t = b[k], next: UInt16 = k + 1 < n ? b[k + 1] : 0
                        let assigns = g.lineKeys.contains(61) && next == 61 && (t == 63 || t == 43 || t == 58 || t == 33)
                        if assigns || (g.lineKeys.contains(t) && next != t) {
                            out.add(i, j, .property)
                            i = j
                            prev = 97
                            continue
                        }
                    }
                }
            }

            if c < 128 && g.special[Int(c)] {
                var handled = false
                for (k, bc) in g.blockComments.enumerated() where matches(b, bc.open, i, n) {
                    let s = i
                    mode = k + 1
                    depth = 1
                    i += bc.open.count
                    scanBlockComment(b, &i, n)
                    out.add(s, i, .comment)
                    handled = true
                    break
                }
                if handled { continue }
                for lc in g.lineComments where matches(b, lc, i, n) {
                    if g.commentNeedsSpace && i > range.lowerBound && !isSpace(b[i - 1]) { continue }
                    out.add(i, n, .comment)
                    i = n
                    handled = true
                    break
                }
                if handled { continue }
                for (k, r) in g.strings.enumerated() where matches(b, r.open, i, n) {
                    let s = i
                    if r.charLike {
                        guard let e = charLiteralEnd(b, r, i, n) else { continue }
                        i = e
                    } else if let e = closeOf(r, i + r.open.count) {
                        i = e
                    } else {
                        i = n
                        if r.multiline { mode = 100 + k }
                    }
                    var kind = SyntaxKind.string
                    if g.keyStrings && mode == 0 {
                        let j = skipSpaces(i)
                        if j < n && b[j] == 58 { kind = .property }
                    }
                    out.add(s, i, kind)
                    prev = 34
                    handled = true
                    break
                }
                if handled { continue }
            }

            if isDigit(c) {
                let s = i
                let hex = c == 48 && i + 1 < n && (b[i + 1] | 32) == 120
                i += 1
                while i < n {
                    let d = b[i]
                    if isLetter(d) || isDigit(d) || d == 95 {
                        i += 1
                    } else if d == 46 && i + 1 < n && isDigit(b[i + 1]) {
                        i += 2
                    } else if (d == 43 || d == 45) && !hex && (b[i - 1] | 32) == 101 && i + 1 < n && isDigit(b[i + 1]) {
                        i += 1
                    } else {
                        break
                    }
                }
                out.add(s, i, .number)
                prev = 48
                continue
            }

            if identStart(c) {
                let s = i
                i += 1
                while i < n && identPart(b[i]) { i += 1 }
                var kind: SyntaxKind?
                if i - s <= g.maxWord && c < 128 && g.wordStart[Int(c)] {
                    let w = g.caseInsensitive ? word(b, s, i).lowercased() : word(b, s, i)
                    if g.keywords.contains(w) { kind = .keyword } else if g.types.contains(w) { kind = .type }
                }
                if kind == nil {
                    if g.capitalizedTypes && isUpper(c) && (g.capitalsAreTypes || i - s == 1 || (s..<i).contains { isLower(b[$0]) }) {
                        kind = .type
                    } else if g.functionCalls && i < n && b[i] == 40 {
                        kind = .function
                    } else if g.bangMacros && i + 1 < n && b[i] == 33 && (b[i + 1] == 40 || b[i + 1] == 91 || b[i + 1] == 123) {
                        i += 1
                        kind = .function
                    }
                }
                if let kind { out.add(s, i, kind) }
                prev = 97
                continue
            }

            if g.attributePrefixes.contains(c) {
                if i + 1 < n && identStart(b[i + 1]) {
                    let s = i
                    i += 2
                    while i < n && identPart(b[i]) { i += 1 }
                    out.add(s, i, .attribute)
                    if g.cInclude {
                        let j = skipSpaces(i)
                        if j < n && b[j] == 60, let e = (j..<n).first(where: { b[$0] == 62 }) {
                            out.add(j, e + 1, .string)
                            i = e + 1
                        }
                    }
                    prev = 97
                    continue
                }
                if g.bracketAttributes && c == 35 && i + 1 < n && (b[i + 1] == 91 || (b[i + 1] == 33 && i + 2 < n && b[i + 2] == 91)) {
                    let e = (i..<n).first { b[$0] == 93 }.map { $0 + 1 } ?? n
                    out.add(i, e, .attribute)
                    i = e
                    prev = 93
                    continue
                }
            }

            if g.variables && c == 36 && i + 1 < n {
                let d = b[i + 1]
                var e: Int?
                if isWord(d) {
                    var j = i + 2
                    while j < n && isWord(b[j]) { j += 1 }
                    e = j
                } else if d == 123 {
                    e = (i..<n).first { b[$0] == 125 }.map { $0 + 1 }
                } else if d == 40 && g.variableParens {
                    e = (i..<n).first { b[$0] == 41 }.map { $0 + 1 }
                } else if d == 64 || d == 42 || d == 35 || d == 63 || d == 60 || d == 94 {
                    e = i + 2
                }
                if let e {
                    out.add(i, e, .property)
                    i = e
                    prev = 97
                    continue
                }
            }

            if g.regex && c == 47 && (prev == 0 || Self.beforeRegex.contains(prev)), let e = regexEnd(b, i, n) {
                out.add(i, e, .string)
                i = e
                prev = 34
                continue
            }

            prev = c
            i += 1
        }
    }

    private static let beforeRegex = Set(units("(,=:[!&|?{};+-*%<>~^"))

    /// Advances past a block comment body, leaving `mode` set when it is still open at `n`.
    private func scanBlockComment(_ b: UnsafeBufferPointer<UInt16>, _ i: inout Int, _ n: Int) {
        let bc = g.blockComments[mode - 1]
        while i < n {
            if matches(b, bc.close, i, n) {
                i += bc.close.count
                depth -= 1
                if depth <= 0 {
                    mode = 0
                    depth = 0
                    return
                }
            } else if g.nestedComments && matches(b, bc.open, i, n) {
                i += bc.open.count
                depth += 1
            } else {
                i += 1
            }
        }
    }

    private func charLiteralEnd(_ b: UnsafeBufferPointer<UInt16>, _ r: StringRule, _ i: Int, _ n: Int) -> Int? {
        var j = i + r.open.count
        guard j < n else { return nil }
        if b[j] == 92 {
            var k = j + 2
            while k < n && k < j + 12 {
                if matches(b, r.close, k, n) { return k + r.close.count }
                k += 1
            }
            return nil
        }
        j += (b[j] >= 0xD800 && b[j] <= 0xDBFF) ? 2 : 1
        return matches(b, r.close, j, n) ? j + r.close.count : nil
    }

    private func regexEnd(_ b: UnsafeBufferPointer<UInt16>, _ i: Int, _ n: Int) -> Int? {
        var j = i + 1
        var inClass = false
        guard j < n, !isSpace(b[j]) else { return nil }
        while j < n {
            let c = b[j]
            if c == 92 { j += 2; continue }
            if c == 91 { inClass = true } else if c == 93 { inClass = false } else if c == 47 && !inClass {
                j += 1
                while j < n && isLower(b[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }
}

// MARK: HTML and XML

/// Tags, attributes, comments and entities. In HTML, `<script>` and `<style>` bodies are lexed as JavaScript and CSS.
final class MarkupLexer: SyntaxLexer {
    private enum State { case text, comment, tag, doubleQuoted, singleQuoted, cdata, script, style }

    private let html: Bool
    private var state = State.text
    /// What follows the tag being read: a script or style body, or ordinary text.
    private var pending = State.text
    private var afterEquals = false
    private lazy var script = CodeLexer(Languages.grammar("javascript")!)
    private lazy var style = CSSLexer()

    private static let commentOpen = units("<!--"), commentClose = units("-->")
    private static let cdataOpen = units("<![CDATA["), cdataClose = units("]]>")
    private static let scriptClose = units("</script"), styleClose = units("</style")

    init(html: Bool) { self.html = html }

    func lex(_ b: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, _ out: inout [SyntaxSpan]) {
        var i = range.lowerBound
        let n = range.upperBound
        func nameChar(_ c: UInt16) -> Bool { isWord(c) || c == 45 || c == 58 || c == 46 }

        while i < n {
            switch state {
            case .comment:
                let e = find(b, Self.commentClose, i, n).map { $0 + 3 }
                out.add(i, e ?? n, .comment)
                i = e ?? n
                if e != nil { state = .text }
            case .cdata:
                let e = find(b, Self.cdataClose, i, n).map { $0 + 3 }
                i = e ?? n
                if e != nil { state = .text }
            case .doubleQuoted, .singleQuoted:
                let q: UInt16 = state == .doubleQuoted ? 34 : 39
                let e = (i..<n).first { b[$0] == q }.map { $0 + 1 }
                out.add(i, e ?? n, .string)
                i = e ?? n
                if e != nil { state = .tag }
            case .script, .style:
                let e = find(b, state == .script ? Self.scriptClose : Self.styleClose, i, n, ignoreCase: true) ?? n
                if e > i {
                    if state == .script { script.lex(b, i..<e, &out) } else { style.lex(b, i..<e, &out) }
                }
                i = e
                if e < n {
                    script.reset()
                    style.reset()
                    state = .text
                }
            case .tag:
                let c = b[i]
                if isSpace(c) {
                    i += 1
                } else if c == 62 {
                    let selfClosing = i > range.lowerBound && b[i - 1] == 47
                    state = selfClosing ? .text : pending
                    pending = .text
                    i += 1
                } else if c == 34 || c == 39 {
                    let s = i
                    if let e = ((i + 1)..<n).first(where: { b[$0] == c }) {
                        i = e + 1
                    } else {
                        i = n
                        state = c == 34 ? .doubleQuoted : .singleQuoted
                    }
                    out.add(s, i, .string)
                    afterEquals = false
                } else if c == 61 {
                    afterEquals = true
                    i += 1
                } else if c == 47 || c == 63 {
                    i += 1
                } else {
                    let s = i
                    while i < n && !isSpace(b[i]) && b[i] != 62 && b[i] != 61 && b[i] != 34 && b[i] != 39
                            && !(b[i] == 47 && i + 1 < n && b[i + 1] == 62) {
                        i += 1
                    }
                    if i == s { i += 1 }
                    out.add(s, i, afterEquals ? .string : .attribute)
                    afterEquals = false
                }
            case .text:
                let c = b[i]
                if c == 60 {
                    if matches(b, Self.commentOpen, i, n) {
                        let e = find(b, Self.commentClose, i + 4, n).map { $0 + 3 }
                        out.add(i, e ?? n, .comment)
                        i = e ?? n
                        if e == nil { state = .comment }
                    } else if matches(b, Self.cdataOpen, i, n) {
                        state = .cdata
                        i += 9
                    } else {
                        var j = i + 1
                        let marker: UInt16 = j < n ? b[j] : 0
                        if marker == 47 || marker == 33 || marker == 63 { j += 1 }
                        let s = j
                        while j < n && nameChar(b[j]) { j += 1 }
                        if j > s {
                            out.add(marker == 33 || marker == 63 ? i + 1 : s, j, marker == 33 || marker == 63 ? .keyword : .tag)
                            if html && marker != 47 {
                                let name = word(b, s, j).lowercased()
                                pending = name == "script" ? .script : (name == "style" ? .style : .text)
                            }
                            state = .tag
                            afterEquals = false
                            i = j
                        } else {
                            i += 1
                        }
                    }
                } else if c == 38 {
                    var j = i + 1
                    while j < n && j - i < 12 && (isLetter(b[j]) || isDigit(b[j]) || b[j] == 35) { j += 1 }
                    if j < n && b[j] == 59 && j > i + 1 {
                        out.add(i, j + 1, .number)
                        i = j + 1
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
        }
    }
}

// MARK: CSS

/// CSS, SCSS and Less: selectors, properties, at-rules, numbers with units, colours and functions.
final class CSSLexer: SyntaxLexer {
    private var inComment = false
    private var depth = 0

    func reset() { inComment = false; depth = 0 }

    func lex(_ b: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, _ out: inout [SyntaxSpan]) {
        var i = range.lowerBound
        let n = range.upperBound
        var parens = 0
        func nameChar(_ c: UInt16) -> Bool { isWord(c) || c == 45 }
        /// True when what follows belongs to a selector: the next brace or semicolon ahead is `{`.
        func inSelector(_ from: Int) -> Bool {
            if parens > 0 { return false }
            if depth == 0 { return true }
            for j in from..<n {
                if b[j] == 123 { return true }
                if b[j] == 59 || b[j] == 125 { return false }
            }
            return false
        }

        while i < n {
            if inComment {
                let e = find(b, [42, 47], i, n).map { $0 + 2 }
                out.add(i, e ?? n, .comment)
                i = e ?? n
                if e != nil { inComment = false }
                continue
            }
            let c = b[i]
            let next: UInt16 = i + 1 < n ? b[i + 1] : 0
            if isSpace(c) {
                i += 1
            } else if c == 47 && next == 42 {
                inComment = true
            } else if c == 47 && next == 47 && (i == range.lowerBound || isSpace(b[i - 1])) {
                out.add(i, n, .comment)
                i = n
            } else if c == 34 || c == 39 {
                var j = i + 1
                while j < n && b[j] != c { j += b[j] == 92 ? 2 : 1 }
                let e = min(n, j + 1)
                out.add(i, e, .string)
                i = e
            } else if c == 123 {
                depth += 1
                i += 1
            } else if c == 125 {
                depth = max(0, depth - 1)
                i += 1
            } else if c == 40 {
                parens += 1
                i += 1
            } else if c == 41 {
                parens = max(0, parens - 1)
                i += 1
            } else if (c == 64 || c == 33) && (isLetter(next) || next == 45) {
                var j = i + 1
                while j < n && nameChar(b[j]) { j += 1 }
                out.add(i, j, .keyword)
                i = j
            } else if c == 35 && isWord(next) {
                var j = i + 1
                while j < n && nameChar(b[j]) { j += 1 }
                let hex = (j - i == 4 || j - i == 5 || j - i == 7 || j - i == 9) && ((i + 1)..<j).allSatisfy { isHex(b[$0]) }
                out.add(i, j, hex && !inSelector(i) ? .number : .tag)
                i = j
            } else if isDigit(c) || (c == 46 && isDigit(next)) || (c == 45 && (isDigit(next) || next == 46) && (i == range.lowerBound || !isWord(b[i - 1]))) {
                var j = i + 1
                while j < n && (isDigit(b[j]) || b[j] == 46 || isLetter(b[j]) || b[j] == 37) { j += 1 }
                out.add(i, j, .number)
                i = j
            } else if c == 46 && (isLetter(next) || next == 95 || next == 45) {
                var j = i + 1
                while j < n && nameChar(b[j]) { j += 1 }
                if inSelector(i) { out.add(i, j, .tag) }
                i = j
            } else if isLetter(c) || c == 95 || c == 45 || c == 36 || c >= 128 {
                var j = i + 1
                while j < n && nameChar(b[j]) { j += 1 }
                var k = j
                while k < n && isSpace(b[k]) { k += 1 }
                if j < n && b[j] == 40 {
                    out.add(i, j, .function)
                } else if c == 36 || (c == 45 && next == 45) {
                    out.add(i, j, .property)
                } else if k < n && b[k] == 58 && !inSelector(i) {
                    out.add(i, j, .property)
                } else if inSelector(i) {
                    out.add(i, j, .tag)
                }
                i = j
            } else {
                i += 1
            }
        }
    }
}

// MARK: YAML

/// Keys, quoted strings, numbers, booleans, anchors, comments and block scalars. Expects whole lines.
final class YAMLLexer: SyntaxLexer {
    /// Indentation of the key that opened a `|` or `>` block scalar, while its body is being read.
    private var blockIndent: Int?
    private static let constants: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]

    func lex(_ b: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, _ out: inout [SyntaxSpan]) {
        var i = range.lowerBound
        let n = range.upperBound
        while i < n && b[i] == 32 { i += 1 }
        let indent = i - range.lowerBound
        if let open = blockIndent {
            if i == n { return }
            if indent > open {
                out.add(i, n, .string)
                return
            }
            blockIndent = nil
        }
        guard i < n else { return }
        if n - i >= 3 && (b[i] == 45 || b[i] == 46) && b[i + 1] == b[i] && b[i + 2] == b[i] && (n - i == 3 || isSpace(b[i + 3])) {
            out.add(i, i + 3, .keyword)
            i += 3
        }
        // List markers: "- " may repeat, as in "- - a".
        while i + 1 < n && b[i] == 45 && b[i + 1] == 32 {
            i += 2
            while i < n && b[i] == 32 { i += 1 }
        }
        guard i < n else { return }
        if b[i] == 35 {
            out.add(i, n, .comment)
            return
        }

        // A key ends at the first ": " or at a colon that ends the line.
        var colon: Int?
        if b[i] == 34 || b[i] == 39 {
            if let e = ((i + 1)..<n).first(where: { b[$0] == b[i] }), e + 1 < n, b[e + 1] == 58 { colon = e + 1 }
        } else if b[i] != 123 && b[i] != 91 {
            var j = i
            while j < n {
                if b[j] == 58 && (j + 1 == n || isSpace(b[j + 1])) { colon = j; break }
                if b[j] == 35 && isSpace(b[j - (j > i ? 1 : 0)]) && j > i { break }
                j += 1
            }
        }
        if let colon {
            out.add(i, colon, .property)
            i = colon + 1
        }
        value(b, &i, n, indent, &out)
    }

    private func value(_ b: UnsafeBufferPointer<UInt16>, _ i: inout Int, _ n: Int, _ indent: Int, _ out: inout [SyntaxSpan]) {
        while i < n {
            let c = b[i]
            if isSpace(c) {
                i += 1
            } else if c == 35 && (i == 0 || isSpace(b[i - 1])) {
                out.add(i, n, .comment)
                i = n
            } else if c == 34 || c == 39 {
                var j = i + 1
                while j < n && b[j] != c { j += (c == 34 && b[j] == 92) ? 2 : 1 }
                let e = min(n, j + 1)
                out.add(i, e, .string)
                i = e
            } else if c == 38 || c == 42 || c == 33 {
                var j = i + 1
                while j < n && !isSpace(b[j]) && b[j] != 44 && b[j] != 93 && b[j] != 125 { j += 1 }
                if j > i + 1 { out.add(i, j, .attribute) }
                i = j
            } else if (c == 124 || c == 62) && Self.endsLine(b, i + 1, n) {
                out.add(i, i + 1, .keyword)
                blockIndent = indent
                i += 1
            } else if c == 44 || c == 91 || c == 93 || c == 123 || c == 125 || c == 58 {
                i += 1
            } else {
                // A plain scalar runs to a flow delimiter, a comment or the end of the line.
                var j = i
                while j < n && b[j] != 44 && b[j] != 93 && b[j] != 125 && !(b[j] == 35 && isSpace(b[j - 1]))
                        && !(b[j] == 58 && j + 1 < n && isSpace(b[j + 1])) {
                    j += 1
                }
                var e = j
                while e > i && isSpace(b[e - 1]) { e -= 1 }
                if j < n && b[j] == 58 {
                    out.add(i, e, .property)
                } else if e > i {
                    let text = word(b, i, e)
                    if Self.constants.contains(text.lowercased()) {
                        out.add(i, e, .keyword)
                    } else if Self.isNumber(b, i, e) {
                        out.add(i, e, .number)
                    }
                }
                i = max(j, i + 1)
            }
        }
    }

    /// True when only block scalar modifiers, spaces or a comment follow.
    private static func endsLine(_ b: UnsafeBufferPointer<UInt16>, _ from: Int, _ n: Int) -> Bool {
        var j = from
        while j < n && (b[j] == 43 || b[j] == 45 || isDigit(b[j])) { j += 1 }
        while j < n && isSpace(b[j]) { j += 1 }
        return j == n || b[j] == 35
    }

    private static func isNumber(_ b: UnsafeBufferPointer<UInt16>, _ s: Int, _ e: Int) -> Bool {
        var j = s
        if b[j] == 45 || b[j] == 43 { j += 1 }
        guard j < e, isDigit(b[j]) || (b[j] == 46 && j + 1 < e) else { return false }
        return (j..<e).allSatisfy { isHex(b[$0]) || b[$0] == 46 || b[$0] == 95 || b[$0] == 120 || b[$0] == 111 || b[$0] == 43 || b[$0] == 45 }
    }
}

// MARK: Markdown

/// Headings, code fences, inline code, links, list markers and quotes. Expects whole lines.
final class MarkdownLexer: SyntaxLexer {
    /// The fence character and length that opened the current code block.
    private var fence: (char: UInt16, count: Int)?

    func lex(_ b: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, _ out: inout [SyntaxSpan]) {
        var i = range.lowerBound
        let n = range.upperBound
        while i < n && isSpace(b[i]) { i += 1 }
        guard i < n else { return }
        let c = b[i]

        if c == 96 || c == 126 {
            var j = i
            while j < n && b[j] == c { j += 1 }
            if j - i >= 3 {
                if let open = fence {
                    if open.char == c && j - i >= open.count {
                        out.add(i, n, .comment)
                        fence = nil
                        return
                    }
                } else {
                    out.add(i, n, .comment)
                    fence = (c, j - i)
                    return
                }
            }
        }
        if fence != nil { return }

        if c == 35 {
            var j = i
            while j < n && b[j] == 35 { j += 1 }
            if j - i <= 6 && (j == n || isSpace(b[j])) {
                out.add(i, n, .keyword)
                return
            }
        }
        if c == 62 {
            out.add(i, n, .comment)
            return
        }
        if (c == 45 || c == 42 || c == 43) && i + 1 < n && isSpace(b[i + 1]) {
            out.add(i, i + 1, .number)
            i += 2
        } else if isDigit(c) {
            var j = i
            while j < n && isDigit(b[j]) { j += 1 }
            if j + 1 < n && (b[j] == 46 || b[j] == 41) && isSpace(b[j + 1]) {
                out.add(i, j + 1, .number)
                i = j + 2
            }
        }

        while i < n {
            let c = b[i]
            if c == 92 {
                i += 2
            } else if c == 96 {
                var j = i
                while j < n && b[j] == 96 { j += 1 }
                let ticks = Array(b[i..<j])
                if let e = find(b, ticks, j, n) {
                    out.add(i, e + ticks.count, .string)
                    i = e + ticks.count
                } else {
                    i = j
                }
            } else if c == 91, let close = ((i + 1)..<n).first(where: { b[$0] == 93 }), close + 1 < n, b[close + 1] == 40,
                      let end = ((close + 2)..<n).first(where: { b[$0] == 41 }) {
                out.add(i, close + 1, .property)
                out.add(close + 1, end + 1, .comment)
                i = end + 1
            } else if c == 60 && matches(b, [60, 33, 45, 45], i, n), let e = find(b, [45, 45, 62], i + 4, n) {
                out.add(i, e + 3, .comment)
                i = e + 3
            } else {
                i += 1
            }
        }
    }
}

// MARK: Languages

enum Languages {
    static let byExtension: [String: String] = {
        let table: [(String, String)] = [
            ("swift", "swift"), ("c", "c h"), ("cpp", "cpp cc cxx hpp hh hxx c++ h++ ino"), ("objc", "m mm"),
            ("java", "java"), ("kotlin", "kt kts"), ("csharp", "cs"), ("scala", "scala sc"), ("dart", "dart"),
            ("javascript", "js mjs cjs jsx"), ("typescript", "ts tsx mts cts"), ("python", "py pyw pyi"),
            ("ruby", "rb rake gemspec podspec"), ("go", "go"), ("rust", "rs"), ("php", "php phtml"),
            ("shell", "sh bash zsh fish ksh command"), ("sql", "sql"), ("lua", "lua"),
            ("html", "html htm xhtml vue svelte"), ("xml", "xml plist svg xib storyboard xsd xsl xslt rss atom entitlements xcscheme"),
            ("css", "css scss less"), ("json", "json jsonc json5 geojson webmanifest resolved"), ("yaml", "yaml yml"),
            ("toml", "toml"), ("ini", "ini cfg conf properties env editorconfig gitconfig"), ("markdown", "md markdown mdown"),
            ("makefile", "mk mak"),
        ]
        var result: [String: String] = [:]
        for (id, extensions) in table {
            for e in extensions.split(separator: " ") { result[String(e)] = id }
        }
        return result
    }()

    /// Whole file names, lowercased.
    static let byName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby", "brewfile": "ruby",
        ".zshrc": "shell", ".bashrc": "shell", ".bash_profile": "shell", ".profile": "shell", ".zprofile": "shell",
        ".gitconfig": "ini", ".editorconfig": "ini", ".npmrc": "ini", ".env": "ini",
        "package.resolved": "json", ".swiftlint.yml": "yaml", ".clang-format": "yaml",
    ]

    static let shebangs: [(String, String)] = [
        ("python", "python"), ("node", "javascript"), ("ruby", "ruby"), ("php", "php"), ("lua", "lua"),
        ("bash", "shell"), ("zsh", "shell"), ("fish", "shell"), ("/sh", "shell"), (" sh", "shell"),
    ]

    static let names: [String: String] = [
        "swift": "Swift", "c": "C", "cpp": "C++", "objc": "Objective-C", "java": "Java", "kotlin": "Kotlin",
        "csharp": "C#", "scala": "Scala", "dart": "Dart", "javascript": "JavaScript", "typescript": "TypeScript",
        "python": "Python", "ruby": "Ruby", "go": "Go", "rust": "Rust", "php": "PHP", "shell": "Shell", "sql": "SQL",
        "lua": "Lua", "html": "HTML", "xml": "XML", "css": "CSS", "json": "JSON", "yaml": "YAML", "toml": "TOML",
        "ini": "INI", "markdown": "Markdown", "makefile": "Makefile", "dockerfile": "Dockerfile",
    ]

    static func make(_ id: String) -> SyntaxLanguage? {
        guard let name = names[id] else { return nil }
        switch id {
        case "html": return SyntaxLanguage(name) { MarkupLexer(html: true) }
        case "xml": return SyntaxLanguage(name) { MarkupLexer(html: false) }
        case "css": return SyntaxLanguage(name) { CSSLexer() }
        case "yaml": return SyntaxLanguage(name) { YAMLLexer() }
        case "markdown": return SyntaxLanguage(name) { MarkdownLexer() }
        default:
            guard let g = grammar(id) else { return nil }
            return SyntaxLanguage(name) { CodeLexer(g) }
        }
    }

    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL _Bool _Atomic _Static_assert"
    private static let cTypes = "size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t wchar_t FILE va_list"
    private static let jsKeywords = "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield true false null undefined NaN Infinity"

    static func grammar(_ id: String) -> Grammar? {
        var g: Grammar
        switch id {
        case "swift":
            g = Grammar(keywords: "actor any as associatedtype async await borrowing break case catch class consuming continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet true false nil")
            g.strings = [StringRule("\"\"\"", multiline: true), .double]
            g.nestedComments = true
            g.attributePrefixes = [64, 35]
            g.capitalizedTypes = true
            g.capitalsAreTypes = true
        case "c":
            g = Grammar(keywords: cKeywords, types: cTypes)
            g.attributePrefixes = [35]
            g.cInclude = true
        case "cpp":
            g = Grammar(keywords: cKeywords + " alignas alignof and bitand bitor catch char8_t char16_t char32_t class co_await co_return co_yield compl concept const_cast consteval constexpr constinit decltype delete dynamic_cast explicit export final friend mutable namespace new noexcept not nullptr operator or override private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual xor", types: cTypes + " string vector map set unordered_map unordered_set shared_ptr unique_ptr optional variant array tuple pair")
            g.attributePrefixes = [35]
            g.cInclude = true
            g.capitalizedTypes = true
        case "objc":
            g = Grammar(keywords: cKeywords + " id self super nil Nil YES NO BOOL SEL IMP Class instancetype in out inout bycopy byref oneway nonatomic atomic strong weak copy assign readonly readwrite retain nullable nonnull", types: cTypes + " NSInteger NSUInteger CGFloat")
            g.attributePrefixes = [35, 64]
            g.cInclude = true
            g.capitalizedTypes = true
        case "java":
            g = Grammar(keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum exports extends final finally float for goto if implements import instanceof int interface long module native new non-sealed package permits private protected public record requires return sealed short static strictfp super switch synchronized this throw throws transient try var void volatile while yield true false null")
            g.strings = [StringRule("\"\"\"", multiline: true), .double, .single]
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
        case "kotlin":
            g = Grammar(keywords: "abstract actual annotation as break by catch class companion const constructor continue crossinline data do dynamic else enum expect external final finally for fun get if import in infix init inline inner interface internal is it lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val value var vararg when where while true false null")
            g.strings = [StringRule("\"\"\"", multiline: true), .double, .single]
            g.nestedComments = true
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
        case "csharp":
            g = Grammar(keywords: "abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach get goto if implicit in init int interface internal is lock long namespace new object operator out override params partial private protected public readonly record ref required return sbyte sealed set short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using var virtual void volatile when where while yield true false null")
            g.attributePrefixes = [35]
            g.capitalizedTypes = true
        case "scala":
            g = Grammar(keywords: "abstract case catch class def do else enum export extends extension final finally for forSome given if implicit import inline lazy match new object opaque override package private protected return sealed super then this throw trait try type using val var while with yield true false null")
            g.strings = [StringRule("\"\"\"", multiline: true), .double, .single]
            g.nestedComments = true
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
        case "dart":
            g = Grammar(keywords: "abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield true false null", types: "int double num bool")
            g.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), .double, .single]
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
        case "javascript", "typescript":
            let ts = id == "typescript" ? " abstract any as asserts boolean declare enum implements infer interface is keyof module namespace never number object override private protected public readonly satisfies string symbol type unique unknown" : ""
            g = Grammar(keywords: jsKeywords + ts)
            g.strings = [.double, .single, StringRule("`", multiline: true)]
            g.identStart = [36]
            g.identPart = [36]
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
            g.regex = true
        case "python":
            g = Grammar(keywords: "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield self cls True False None", types: "int float str bool bytes list dict set tuple object type", line: ["#"], block: [])
            g.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), .double, .single]
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
        case "ruby":
            g = Grammar(keywords: "alias and begin break case class def defined? do else elsif end ensure extend for if in include module next not or private protected public raise redo require require_relative rescue retry return self super then undef unless until when while yield attr_accessor attr_reader attr_writer true false nil", line: ["#"], block: [])
            g.strings = [.double, .single, StringRule("`")]
            g.identPart = [63, 33]
            g.attributePrefixes = [64]
            g.capitalizedTypes = true
            g.variables = true
        case "go":
            g = Grammar(keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota", types: "any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr")
            g.strings = [.double, .single, StringRule("`", escape: false, multiline: true)]
        case "rust":
            g = Grammar(keywords: "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while true false", types: "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize")
            g.strings = [StringRule("\"", multiline: true), StringRule("'", charLike: true)]
            g.nestedComments = true
            g.bracketAttributes = true
            g.attributePrefixes = [35]
            g.bangMacros = true
            g.capitalizedTypes = true
        case "php":
            g = Grammar(keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null self parent", types: "int float string bool mixed void iterable object never", line: ["//", "#"])
            g.capitalizedTypes = true
            g.variables = true
        case "shell":
            g = Grammar(keywords: "if then else elif fi for while until do done case esac in function select return exit break continue local export readonly declare typeset unset shift source alias set trap eval exec", line: ["#"], block: [])
            g.strings = [StringRule("\"", multiline: true), StringRule("'", escape: false, multiline: true), StringRule("`")]
            g.commentNeedsSpace = true
            g.functionCalls = false
            g.variables = true
        case "sql":
            g = Grammar(keywords: "add all alter and as asc begin between by cascade case check column commit constraint create cross database default delete desc distinct drop else end except exists foreign from full function group having if in index inner insert intersect into is join key left like limit not null offset on or order outer primary procedure references replace returning right rollback select set table then to transaction trigger truncate union unique update using values view when where with true false", types: "bigint binary bit blob boolean char date datetime decimal double float int integer json jsonb numeric real serial smallint text time timestamp tinyint uuid varchar", line: ["--"])
            g.strings = [StringRule("'", escape: false), .double, StringRule("`")]
            g.caseInsensitive = true
        case "lua":
            g = Grammar(keywords: "and break do else elseif end for function goto if in local not or repeat return then until while true false nil", line: ["--"], block: [("--[[", "]]")])
            g.strings = [.double, .single, StringRule("[[", "]]", escape: false, multiline: true)]
        case "json":
            g = Grammar(keywords: "true false null")
            g.strings = [.double]
            g.keyStrings = true
            g.functionCalls = false
        case "toml":
            g = Grammar(keywords: "true false inf nan", line: ["#"], block: [])
            g.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", escape: false, multiline: true), .double, StringRule("'", escape: false)]
            g.sectionHeaders = true
            g.lineKeys = [61]
            g.functionCalls = false
        case "ini":
            g = Grammar(keywords: "true false yes no on off", line: ["#", ";"], block: [])
            g.strings = [.double]
            g.commentNeedsSpace = true
            g.sectionHeaders = true
            g.lineKeys = [61, 58]
            g.functionCalls = false
        case "makefile":
            g = Grammar(keywords: "ifeq ifneq ifdef ifndef else endif include sinclude define endef export unexport override vpath", line: ["#"], block: [])
            g.lineKeys = [58, 61]
            g.functionCalls = false
            g.variables = true
            g.variableParens = true
        case "dockerfile":
            g = Grammar(keywords: "FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS", line: ["#"], block: [])
            g.commentNeedsSpace = true
            g.functionCalls = false
            g.variables = true
        default:
            return nil
        }
        return g.finished()
    }
}
