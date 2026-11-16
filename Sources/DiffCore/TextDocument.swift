import Foundation

/// The line terminator style used by a document.
public enum LineEnding: String, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case mixed = "Mixed"
    case none = "None"
}

/// What ends one line. Only the last line of a document may have `.none`.
public enum LineTerminator: UInt8, Sendable {
    case none, lf, crlf, cr

    public var string: String {
        switch self {
        case .none: ""
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

/// How a document's text is stored on disk.
public enum TextEncoding: Sendable, Equatable {
    case utf8, utf8BOM, utf16LittleEndian, utf16BigEndian, latin1

    public var name: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 with BOM"
        case .utf16LittleEndian, .utf16BigEndian: "UTF-16"
        case .latin1: "Latin-1"
        }
    }
}

/// A text file split into lines. Line strings never contain their terminators.
///
/// `lines`, `terminators` and `textEncoding` together hold everything needed to write the file
/// back byte for byte, so that saving an edited document changes only the edited lines.
public struct TextDocument: Sendable {
    public var url: URL?
    public private(set) var lines: [String]
    /// The terminator of each line, parallel to `lines`.
    public private(set) var terminators: [LineTerminator]
    public var isBinary: Bool
    public private(set) var lineEnding: LineEnding
    public var textEncoding: TextEncoding
    public var byteCount: Int
    /// False when the file held something its encoding cannot express, so writing it back would alter it.
    public private(set) var isLossless = true

    /// The encoding's display name.
    public var encoding: String { textEncoding.name }

    /// - Parameter terminators: one per line; when omitted every line ends with a line feed.
    public init(
        lines: [String],
        terminators: [LineTerminator]? = nil,
        url: URL? = nil,
        isBinary: Bool = false,
        encoding: TextEncoding = .utf8,
        byteCount: Int = 0
    ) {
        precondition(terminators == nil || terminators!.count == lines.count)
        self.lines = lines
        self.terminators = terminators ?? [LineTerminator](repeating: .lf, count: lines.count)
        self.url = url
        self.isBinary = isBinary
        self.textEncoding = encoding
        self.byteCount = byteCount
        lineEnding = terminators == nil ? .none : Self.summary(self.terminators)
    }

    public static let empty = TextDocument(lines: [])

    public init(text: String, url: URL? = nil) {
        self = TextDocument.decode(Data(text.utf8), url: url)
    }

    /// Loads a file through a memory map.
    public static func load(_ url: URL) throws -> TextDocument {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return decode(data, url: url)
    }

    /// Detects encoding and binary content, then splits into lines.
    public static func decode(_ data: Data, url: URL?) -> TextDocument {
        let count = data.count
        if count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                let text = String(data: data, encoding: .utf16) ?? ""
                var doc = fromUTF8(Array(text.utf8), url: url, encoding: b0 == 0xFF ? .utf16LittleEndian : .utf16BigEndian)
                doc.byteCount = count
                // Unpaired surrogates and odd lengths do not survive decoding.
                doc.isLossless = doc.encoded() == data
                return doc
            }
        }
        return data.withUnsafeBytes { raw -> TextDocument in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = raw.baseAddress, !bytes.isEmpty else {
                return TextDocument(lines: [], url: url)
            }
            if memchr(base, 0, min(bytes.count, 8192)) != nil {
                return TextDocument(lines: [], url: url, isBinary: true, byteCount: count)
            }
            var body = UnsafeBufferPointer(rebasing: bytes[...])
            var encoding = TextEncoding.utf8
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                body = UnsafeBufferPointer(rebasing: bytes[3...])
                encoding = .utf8BOM
            }
            if String(validating: body, as: UTF8.self) == nil {
                // Latin-1 maps every byte, so this never fails and never loses data.
                let text = String(data: data, encoding: .isoLatin1) ?? ""
                var doc = fromUTF8(Array(text.utf8), url: url, encoding: .latin1)
                doc.byteCount = count
                return doc
            }
            var doc = split(body, url: url, encoding: encoding)
            doc.byteCount = count
            return doc
        }
    }

    private static func fromUTF8(_ bytes: [UInt8], url: URL?, encoding: TextEncoding) -> TextDocument {
        bytes.withUnsafeBufferPointer { split($0, url: url, encoding: encoding) }
    }

    /// Splits UTF-8 bytes on LF, CRLF and CR.
    static func split(_ bytes: UnsafeBufferPointer<UInt8>, url: URL?, encoding: TextEncoding) -> TextDocument {
        var lines: [String] = []
        var terminators: [LineTerminator] = []
        lines.reserveCapacity(bytes.count / 32 + 1)
        terminators.reserveCapacity(bytes.count / 32 + 1)
        var start = 0, i = 0
        let n = bytes.count
        @inline(__always) func line(_ a: Int, _ b: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[a..<b]), as: UTF8.self)
        }
        while i < n {
            let c = bytes[i]
            if c == 0x0A {
                lines.append(line(start, i)); terminators.append(.lf); i += 1; start = i
            } else if c == 0x0D {
                lines.append(line(start, i))
                if i + 1 < n && bytes[i + 1] == 0x0A { terminators.append(.crlf); i += 2 } else { terminators.append(.cr); i += 1 }
                start = i
            } else {
                i += 1
            }
        }
        if start < n {
            lines.append(line(start, n))
            terminators.append(.none)
        }
        return TextDocument(lines: lines, terminators: terminators, url: url, encoding: encoding)
    }

    /// The style shared by every terminated line, or `.mixed`.
    private static func summary(_ terminators: [LineTerminator]) -> LineEnding {
        var lf = false, crlf = false, cr = false
        for t in terminators {
            switch t {
            case .lf: lf = true
            case .crlf: crlf = true
            case .cr: cr = true
            case .none: break
            }
        }
        switch (lf, crlf, cr) {
        case (false, false, false): return .none
        case (true, false, false): return .lf
        case (false, true, false): return .crlf
        case (false, false, true): return .cr
        default: return .mixed
        }
    }

    // MARK: Writing and editing

    /// The bytes of the document in its own encoding, or nil when the text cannot be expressed in it
    /// (a character outside Latin-1 in a Latin-1 file).
    public func encoded() -> Data? {
        var text = ""
        text.reserveCapacity(byteCount + lines.count)
        for i in lines.indices {
            text += lines[i]
            text += terminators[i].string
        }
        switch textEncoding {
        case .utf8: return Data(text.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LittleEndian: return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BigEndian: return text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .latin1: return text.data(using: .isoLatin1)
        }
    }

    /// The terminator new lines get: the document's own style, or its most common one when mixed.
    public var preferredTerminator: LineTerminator {
        switch lineEnding {
        case .lf, .none: return .lf
        case .crlf: return .crlf
        case .cr: return .cr
        case .mixed:
            var counts = [0, 0, 0, 0]
            for t in terminators { counts[Int(t.rawValue)] += 1 }
            return counts[2] > counts[1] && counts[2] >= counts[3] ? .crlf : (counts[3] > counts[1] ? .cr : .lf)
        }
    }

    /// Replaces a range of lines. Untouched lines keep their terminators; new lines take this document's
    /// style. Whether the file ends with a line break stays as it was, or follows `endsWithTerminator`
    /// when the document was empty.
    public func replacingLines(_ range: Range<Int>, with newLines: [String], endsWithTerminator: Bool = true) -> TextDocument {
        precondition(range.lowerBound >= 0 && range.upperBound <= lines.count)
        let style = preferredTerminator
        let terminated = lines.isEmpty ? endsWithTerminator : terminators[terminators.count - 1] != .none
        var doc = self
        doc.lines.replaceSubrange(range, with: newLines)
        doc.terminators.replaceSubrange(range, with: [LineTerminator](repeating: style, count: newLines.count))
        // A line that used to be last, or the new last line, may now carry the wrong terminator.
        let count = doc.lines.count
        for i in [range.lowerBound - 1, range.lowerBound + newLines.count - 1, count - 2] where i >= 0 && i < count - 1 {
            if doc.terminators[i] == .none { doc.terminators[i] = style }
        }
        if count > 0 {
            let last = doc.terminators[count - 1]
            doc.terminators[count - 1] = terminated ? (last == .none ? style : last) : .none
        }
        doc.lineEnding = Self.summary(doc.terminators)
        return doc
    }

    /// The whole text replaced by `text`, in this document's encoding and line-ending style. Whether the
    /// file ends with a line break follows `text`.
    public func replacingAll(with text: String) -> TextDocument {
        var pieces = Self.pieces(of: text)
        let terminated = pieces.last == ""
        if terminated { pieces.removeLast() }
        let style = preferredTerminator
        var doc = self
        doc.lines = pieces
        doc.terminators = [LineTerminator](repeating: style, count: pieces.count)
        if !terminated, !pieces.isEmpty { doc.terminators[pieces.count - 1] = .none }
        doc.lineEnding = Self.summary(doc.terminators)
        return doc
    }

    /// True when the last line ends with a line break (or there are no lines to end).
    public var endsWithTerminator: Bool { terminators.last.map { $0 != .none } ?? true }
    /// Splits text on LF, CRLF and CR. Always returns at least one piece; a trailing break gives a final empty one.
    public static func pieces(of text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousWasCR {
                    out.append(String(current))
                    current = String.UnicodeScalarView()
                }
                previousWasCR = false
            } else if scalar == "\r" {
                out.append(String(current))
                current = String.UnicodeScalarView()
                previousWasCR = true
            } else {
                current.append(scalar)
                previousWasCR = false
            }
        }
        out.append(String(current))
        return out
    }

    /// Replaces the text between two positions (line index and UTF-16 offset) and returns where the
    /// inserted text ends. The line the range ends on keeps its terminator; lines created by line
    /// breaks in `text` take this document's style.
    public func replacingText(
        from start: (line: Int, offset: Int), to end: (line: Int, offset: Int), with text: String
    ) -> (document: TextDocument, end: (line: Int, offset: Int)) {
        var newLines = Self.pieces(of: text)
        guard !lines.isEmpty else {
            let doc = replacingLines(0..<0, with: newLines, endsWithTerminator: false)
            return (doc, (newLines.count - 1, newLines[newLines.count - 1].utf16.count))
        }
        let a = min(max(start.line, 0), lines.count - 1), b = min(max(end.line, a), lines.count - 1)
        let first = lines[a] as NSString, last = lines[b] as NSString
        let from = min(max(start.offset, 0), first.length)
        let to = min(max(end.offset, a == b ? from : 0), last.length)
        newLines[0] = first.substring(to: from) + newLines[0]
        let endOffset = newLines[newLines.count - 1].utf16.count
        newLines[newLines.count - 1] += last.substring(from: to)

        var doc = self
        var newTerminators = [LineTerminator](repeating: preferredTerminator, count: newLines.count)
        newTerminators[newLines.count - 1] = terminators[b]
        doc.lines.replaceSubrange(a...b, with: newLines)
        doc.terminators.replaceSubrange(a...b, with: newTerminators)
        doc.lineEnding = Self.summary(doc.terminators)
        return (doc, (a + newLines.count - 1, endOffset))
    }

}
