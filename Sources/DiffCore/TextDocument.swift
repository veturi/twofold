import Foundation

/// The line terminator style used by a document.
public enum LineEnding: String, Sendable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case mixed = "Mixed"
    case none = "None"
}

/// A text file split into lines. Line strings never contain their terminators.
public struct TextDocument: Sendable {
    public var url: URL?
    public var lines: [String]
    public var isBinary: Bool
    public var lineEnding: LineEnding
    public var encoding: String
    public var byteCount: Int

    public init(
        lines: [String],
        url: URL? = nil,
        isBinary: Bool = false,
        lineEnding: LineEnding = .none,
        encoding: String = "UTF-8",
        byteCount: Int = 0
    ) {
        self.lines = lines
        self.url = url
        self.isBinary = isBinary
        self.lineEnding = lineEnding
        self.encoding = encoding
        self.byteCount = byteCount
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
                var doc = fromUTF8(Array(text.utf8), url: url, encoding: "UTF-16")
                doc.byteCount = count
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
            var encoding = "UTF-8"
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                body = UnsafeBufferPointer(rebasing: bytes[3...])
                encoding = "UTF-8 with BOM"
            }
            if String(validating: body, as: UTF8.self) == nil {
                // Latin-1 maps every byte, so this never fails and never loses data.
                let text = String(data: data, encoding: .isoLatin1) ?? ""
                var doc = fromUTF8(Array(text.utf8), url: url, encoding: "Latin-1")
                doc.byteCount = count
                return doc
            }
            var doc = split(body, url: url, encoding: encoding)
            doc.byteCount = count
            return doc
        }
    }

    private static func fromUTF8(_ bytes: [UInt8], url: URL?, encoding: String) -> TextDocument {
        bytes.withUnsafeBufferPointer { split($0, url: url, encoding: encoding) }
    }

    /// Splits UTF-8 bytes on LF, CRLF and CR.
    static func split(_ bytes: UnsafeBufferPointer<UInt8>, url: URL?, encoding: String) -> TextDocument {
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 32 + 1)
        var lf = 0, crlf = 0, cr = 0
        var start = 0, i = 0
        let n = bytes.count
        @inline(__always) func line(_ a: Int, _ b: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[a..<b]), as: UTF8.self)
        }
        while i < n {
            let c = bytes[i]
            if c == 0x0A {
                lines.append(line(start, i)); lf += 1; i += 1; start = i
            } else if c == 0x0D {
                lines.append(line(start, i))
                if i + 1 < n && bytes[i + 1] == 0x0A { crlf += 1; i += 2 } else { cr += 1; i += 1 }
                start = i
            } else {
                i += 1
            }
        }
        if start < n { lines.append(line(start, n)) }
        let kinds = (lf > 0 ? 1 : 0) + (crlf > 0 ? 1 : 0) + (cr > 0 ? 1 : 0)
        let ending: LineEnding
        switch kinds {
        case 0: ending = .none
        case 1: ending = lf > 0 ? .lf : (crlf > 0 ? .crlf : .cr)
        default: ending = .mixed
        }
        return TextDocument(lines: lines, url: url, lineEnding: ending, encoding: encoding)
    }
}
