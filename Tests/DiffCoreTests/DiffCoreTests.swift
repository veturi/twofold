import Foundation
import XCTest
@testable import DiffCore

final class TextDocumentTests: XCTestCase {
    func testEncodedReproducesTheFile() {
        let cases: [[UInt8]] = [
            [], Array("a\nb\n".utf8), Array("a\nb".utf8), Array("\n".utf8), Array("\n\n".utf8), Array("a\r\nb\rc\n\r\n".utf8),
            Array("a\r".utf8), Array("caf\u{E9} 👍\r\nx".utf8),
            [0xEF, 0xBB, 0xBF] + Array("bom\nline".utf8), [0xEF, 0xBB, 0xBF],
            [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x80, 0x9F, 0xFF],                       // Latin-1, CRLF, C1 controls
            [0xFF, 0xFE, 0x68, 0x00, 0x0A, 0x00, 0x3D, 0xD8, 0x4D, 0xDC],                 // UTF-16 LE with an emoji
            [0xFE, 0xFF, 0x00, 0x68, 0x00, 0x0D, 0x00, 0x0A, 0x00, 0x69],                 // UTF-16 BE, CRLF
        ]
        for bytes in cases {
            let doc = TextDocument.decode(Data(bytes), url: nil)
            XCTAssertTrue(doc.isLossless)
            XCTAssertEqual(doc.encoded().map(Array.init), bytes, "\(bytes)")
            XCTAssertEqual(doc.terminators.count, doc.lines.count)
        }
    }

    func testRandomTextRoundTrips() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", " ", "\n", "\r\n", "\r", "é", "👍", "\t", "x y", ""]
        for _ in 0..<2000 {
            let text = (0..<Int.random(in: 0...12, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let data = Data(text.utf8)
            let doc = TextDocument.decode(data, url: nil)
            XCTAssertEqual(doc.encoded(), data, text.debugDescription)
            XCTAssertFalse(doc.terminators.dropLast().contains(.none), text.debugDescription)
        }
    }

    func testInvalidUTF16IsNotLossless() {
        // An unpaired high surrogate cannot be written back as it was.
        let doc = TextDocument.decode(Data([0xFF, 0xFE, 0x3D, 0xD8, 0x0A, 0x00]), url: nil)
        XCTAssertFalse(doc.isLossless)
    }

    func testLatin1CannotEncodeOtherCharacters() {
        let doc = TextDocument.decode(Data([0x63, 0xE9, 0x0A]), url: nil)
        XCTAssertEqual(doc.textEncoding, .latin1)
        XCTAssertNotNil(doc.replacingLines(0..<1, with: ["ç"]).encoded())
        XCTAssertNil(doc.replacingLines(0..<1, with: ["日本"]).encoded())
    }

    private func text(_ doc: TextDocument) -> String { String(decoding: doc.encoded()!, as: UTF8.self) }

    func testReplacingLinesKeepsTerminatorsOfUntouchedLines() {
        let doc = TextDocument(text: "a\r\nb\nc\r\nd\r\n")
        XCTAssertEqual(doc.lineEnding, .mixed)
        XCTAssertEqual(text(doc.replacingLines(1..<2, with: ["x", "y"])), "a\r\nx\r\ny\r\nc\r\nd\r\n")
        XCTAssertEqual(text(doc.replacingLines(1..<3, with: [])), "a\r\nd\r\n")
        XCTAssertEqual(text(doc.replacingLines(0..<0, with: ["z"])), "z\r\na\r\nb\nc\r\nd\r\n")
        XCTAssertEqual(TextDocument(text: "a\rb\r").replacingLines(1..<1, with: ["x"]).lineEnding, .cr)
    }

    func testReplacingLinesKeepsTheEndOfTheFile() {
        // No final line break stays that way, wherever the edit lands.
        let open = TextDocument(text: "a\nb")
        XCTAssertEqual(text(open.replacingLines(2..<2, with: ["c"])), "a\nb\nc")
        XCTAssertEqual(text(open.replacingLines(1..<2, with: ["x", "y"])), "a\nx\ny")
        XCTAssertEqual(text(open.replacingLines(1..<2, with: [])), "a")
        XCTAssertEqual(text(open.replacingLines(0..<1, with: ["z"])), "z\nb")
        XCTAssertEqual(text(open.replacingLines(0..<2, with: [])), "")
        // A final line break stays too.
        let closed = TextDocument(text: "a\nb\n")
        XCTAssertEqual(text(closed.replacingLines(2..<2, with: ["c"])), "a\nb\nc\n")
        XCTAssertEqual(text(closed.replacingLines(1..<2, with: [])), "a\n")
        // An empty document takes the hint.
        XCTAssertEqual(text(TextDocument.empty.replacingLines(0..<0, with: ["a", "b"])), "a\nb\n")
        XCTAssertEqual(text(TextDocument.empty.replacingLines(0..<0, with: ["a", "b"], endsWithTerminator: false)), "a\nb")
    }

    func testReplacingText() {
        let doc = TextDocument(text: "alpha\r\nbeta\r\ngamma")
        func edit(_ a: (Int, Int), _ b: (Int, Int), _ s: String) -> (String, Int, Int) {
            let r = doc.replacingText(from: a, to: b, with: s)
            return (text(r.document), r.end.line, r.end.offset)
        }
        XCTAssertTrue(edit((0, 2), (0, 2), "X") == ("alXpha\r\nbeta\r\ngamma", 0, 3))
        XCTAssertTrue(edit((0, 5), (0, 5), "\n") == ("alpha\r\n\r\nbeta\r\ngamma", 1, 0))          // new lines take the file's style
        XCTAssertTrue(edit((0, 3), (2, 2), "") == ("alpmma", 0, 3))                              // joins across lines
        XCTAssertTrue(edit((1, 0), (1, 4), "one\ntwo") == ("alpha\r\none\r\ntwo\r\ngamma", 2, 3))
        XCTAssertTrue(edit((2, 5), (2, 5), "\n") == ("alpha\r\nbeta\r\ngamma\r\n", 3, 0))           // a break at the very end
        XCTAssertTrue(edit((0, 5), (1, 0), "") == ("alphabeta\r\ngamma", 0, 5))                  // deleting a line break
        // An empty document can be typed into.
        let typed = TextDocument.empty.replacingText(from: (0, 0), to: (0, 0), with: "a\nb")
        XCTAssertEqual(text(typed.document), "a\nb")
        XCTAssertTrue(typed.end == (1, 1))
        XCTAssertEqual(TextDocument.pieces(of: "a\r\nb\rc\n"), ["a", "b", "c", ""])
    }

    /// Random edits on the line model give the same bytes as the same edits on a flat string.
    func testReplacingTextMatchesStringEditing() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", " ", "\n", "é", "👍", "x y", "\n\n"]
        for _ in 0..<1500 {
            var flat = (0..<Int.random(in: 0...10, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            var doc = TextDocument(text: flat)
            for _ in 0..<4 where !doc.lines.isEmpty {
                // Line starts as offsets into the flat text; every terminator here is one LF.
                var starts = [0]
                for line in doc.lines { starts.append(starts[starts.count - 1] + line.utf16.count + 1) }
                let l1 = Int.random(in: 0..<doc.lines.count, using: &rng), l2 = Int.random(in: l1..<doc.lines.count, using: &rng)
                func boundary(_ line: Int) -> Int {
                    // A random offset that does not split a surrogate pair.
                    let ns = doc.lines[line] as NSString
                    let o = Int.random(in: 0...ns.length, using: &rng)
                    return o < ns.length ? ns.rangeOfComposedCharacterSequence(at: o).location : o
                }
                var o1 = boundary(l1), o2 = boundary(l2)
                if l1 == l2 && o1 > o2 { swap(&o1, &o2) }
                let insert = (0..<Int.random(in: 0...3, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
                let ns = NSMutableString(string: flat)
                let endsOpen = !doc.endsWithTerminator
                ns.replaceCharacters(in: NSRange(location: starts[l1] + o1, length: starts[l2] + o2 - starts[l1] - o1), with: insert)
                flat = ns as String
                doc = doc.replacingText(from: (l1, o1), to: (l2, o2), with: insert).document
                XCTAssertEqual(text(doc), flat)
                XCTAssertEqual(doc.endsWithTerminator, !endsOpen)
                XCTAssertFalse(doc.terminators.dropLast().contains(.none))
            }
        }
    }

    func testCopyingAChangeMakesTheSidesEqual() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = ["a", "b", "c", "d", "e", ""]
        for _ in 0..<300 {
            let l = (0..<Int.random(in: 0...12, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            let r = (0..<Int.random(in: 0...12, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            var left = TextDocument(lines: l), right = TextDocument(lines: r)
            // Copying every change in turn, in either direction, ends with identical sides.
            for _ in 0..<40 {
                let d = TextDiff(left: left, right: right)
                guard let i = d.changeBlocks.randomElement(using: &rng) else { break }
                let b = d.blocks[i]
                if Bool.random(using: &rng) {
                    right = right.replacingLines(b.right, with: Array(left.lines[b.left]))
                } else {
                    left = left.replacingLines(b.left, with: Array(right.lines[b.right]))
                }
            }
            XCTAssertEqual(left.lines, right.lines)
        }
    }

    func testSplitsAllTerminators() {
        let doc = TextDocument(text: "a\nb\r\nc\rd")
        XCTAssertEqual(doc.lines, ["a", "b", "c", "d"])
        XCTAssertEqual(doc.lineEnding, .mixed)
    }

    func testTrailingNewlineDoesNotAddLine() {
        XCTAssertEqual(TextDocument(text: "a\nb\n").lines, ["a", "b"])
        XCTAssertEqual(TextDocument(text: "a\nb").lines, ["a", "b"])
        XCTAssertEqual(TextDocument(text: "").lines, [])
        XCTAssertEqual(TextDocument(text: "\n").lines, [""])
    }

    func testBinaryDetection() {
        let doc = TextDocument.decode(Data([0x41, 0x00, 0x42]), url: nil)
        XCTAssertTrue(doc.isBinary)
    }

    func testLatin1Fallback() {
        let doc = TextDocument.decode(Data([0x63, 0x61, 0x66, 0xE9, 0x0A]), url: nil)
        XCTAssertEqual(doc.lines, ["café"])
        XCTAssertEqual(doc.encoding, "Latin-1")
    }

    func testUTF16WithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("hi\nthere".data(using: .utf16LittleEndian)!)
        let doc = TextDocument.decode(data, url: nil)
        XCTAssertEqual(doc.lines, ["hi", "there"])
        XCTAssertEqual(doc.encoding, "UTF-16")
    }

    func testUTF8BOMIsStripped() {
        let doc = TextDocument.decode(Data([0xEF, 0xBB, 0xBF, 0x78]), url: nil)
        XCTAssertEqual(doc.lines, ["x"])
    }
    func testReplacingAllKeepsEncodingAndLineEndings() {
        let crlf = TextDocument.decode(Data("a\r\nb\r\n".utf8), url: nil)
        XCTAssertEqual(crlf.replacingAll(with: "x\ny\n").encoded(), Data("x\r\ny\r\n".utf8))
        XCTAssertEqual(crlf.replacingAll(with: "x\ny").encoded(), Data("x\r\ny".utf8))
        XCTAssertEqual(crlf.replacingAll(with: "").encoded(), Data())
        XCTAssertEqual(crlf.replacingAll(with: "\n").encoded(), Data("\r\n".utf8))
        let latin = TextDocument.decode(Data([0x63, 0xE9, 0x0A]), url: nil)
        XCTAssertEqual(latin.replacingAll(with: "é!\n").encoded(), Data([0xE9, 0x21, 0x0A]))
        XCTAssertNil(latin.replacingAll(with: "€\n").encoded())
        XCTAssertEqual(TextDocument.empty.replacingAll(with: "a\nb").lines, ["a", "b"])
    }
}


final class DiffTests: XCTestCase {
    func diff(_ a: String, _ b: String) -> TextDiff {
        TextDiff(left: TextDocument(text: a), right: TextDocument(text: b))
    }

    func testIdentical() {
        let d = diff("a\nb\nc\n", "a\nb\nc\n")
        XCTAssertTrue(d.isIdentical)
        XCTAssertEqual(d.blocks, [DiffBlock(kind: .equal, left: 0..<3, right: 0..<3)])
    }

    func testEmptyFiles() {
        XCTAssertTrue(diff("", "").isIdentical)
        XCTAssertEqual(diff("", "a\nb").blocks, [DiffBlock(kind: .added, left: 0..<0, right: 0..<2)])
        XCTAssertEqual(diff("a\nb", "").blocks, [DiffBlock(kind: .removed, left: 0..<2, right: 0..<0)])
    }

    func testLineEndingOnlyDifferenceIsNotAChange() {
        let d = diff("a\nb\n", "a\r\nb\r\n")
        XCTAssertTrue(d.isIdentical)
        XCTAssertTrue(d.lineEndingsDiffer)
    }

    func testMissingTrailingNewlineIsNotAChange() {
        XCTAssertTrue(diff("a\nb\n", "a\nb").isIdentical)
    }

    func testKinds() {
        let d = diff("a\nb\nc\nd\n", "a\nx\nc\nd\ne\n")
        XCTAssertEqual(d.blocks.map(\.kind), [.equal, .modified, .equal, .added])
        XCTAssertEqual(d.stats, DiffStats(additions: 1, deletions: 0, changes: 1))
        XCTAssertEqual(d.changeBlocks, [1, 3])
    }

    func testRemoved() {
        let d = diff("a\nb\nc\n", "a\nc\n")
        XCTAssertEqual(d.blocks, [
            DiffBlock(kind: .equal, left: 0..<1, right: 0..<1),
            DiffBlock(kind: .removed, left: 1..<2, right: 1..<1),
            DiffBlock(kind: .equal, left: 2..<3, right: 1..<2),
        ])
    }

    func testInlineHighlightsWords() {
        let d = diff("if (context.Args.hasArg(x)) {\n", "if (needsRuntime(context.Args)) {\n")
        XCTAssertNotNil(d.leftHighlights[0])
        XCTAssertNotNil(d.rightHighlights[0])
        let right = "if (needsRuntime(context.Args)) {" as NSString
        let first = d.rightHighlights[0]![0]
        XCTAssertEqual(right.substring(with: NSRange(first)), "needsRuntime(")
    }

    func testInlineRefinesToCharacters() {
        let d = diff("The Kaleidoscope Maker\n", "The Kaleidoscope Makers\n")
        XCTAssertNil(d.leftHighlights[0])
        XCTAssertEqual(d.rightHighlights[0], [22..<23])
    }

    func testIgnoringWhitespace() {
        let a = TextDocument(text: "if x {\n    return 1\n}\nlet y = 2\nend\n")
        let b = TextDocument(text: "if x {\n\treturn   1  \n}\nlet y = 3\nend\n")
        XCTAssertEqual(TextDiff(left: a, right: b).changeBlocks.count, 2)
        let d = TextDiff(left: a, right: b, ignoreWhitespace: true)
        XCTAssertTrue(d.ignoresWhitespace)
        XCTAssertEqual(d.blocks.map(\.kind), [DiffBlock.Kind.equal, .modified, .equal])
        XCTAssertEqual(d.blocks[1].left, 3..<4)
        // Whitespace where the other side has none is still a difference.
        XCTAssertFalse(TextDiff(left: TextDocument(text: "a b\n"), right: TextDocument(text: "ab\n"), ignoreWhitespace: true).isIdentical)
        XCTAssertTrue(TextDiff(left: TextDocument(text: "  a \t b\n\n"), right: TextDocument(text: "a b  \n   \n"), ignoreWhitespace: true).isIdentical)
        XCTAssertEqual(TextDiff.whitespaceKey(" \tfoo   bar\u{00A0} "), "foo bar")
    }

    func testIgnoringWhitespaceLeavesItOutOfInlineHighlights() {
        let d = TextDiff(left: TextDocument(text: "  call(a, b)\n"), right: TextDocument(text: "\tcall(a,  c)\n"), ignoreWhitespace: true)
        XCTAssertEqual(d.leftHighlights[0], [10..<11])
        XCTAssertEqual(d.rightHighlights[0], [10..<11])
    }

    func testEditNextToDeletionIsSplit() {
        let d = diff(
            "keep\nThe quick brown fox jumps\nApplications\nFile: San Diego.jpg\nkeep2\n",
            "keep\nThe quick brown fox jumps over\nkeep2\n")
        XCTAssertEqual(d.blocks.map(\.kind), [.equal, .modified, .removed, .equal])
        XCTAssertEqual(d.blocks[1].left, 1..<2)
        XCTAssertEqual(d.blocks[2].left, 2..<4)
        XCTAssertNil(d.leftHighlights[2], "removed lines carry no inline highlights")
    }

    func testDissimilarRegionStaysModified() {
        let d = diff("a\nalpha beta\ngamma\nz\n", "a\nzeta\nz\n")
        XCTAssertEqual(d.blocks.map(\.kind), [.equal, .modified, .equal])
    }

    // MARK: Property tests

    struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    func lcsLength(_ a: [Int32], _ b: [Int32]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[b.count]
    }

    func testMyersIsMinimalAndConsistent() {
        var rng = LCG(state: 42)
        for _ in 0..<3000 {
            let n = rng.int(30), m = rng.int(30), alphabet = 1 + rng.int(6)
            let a = (0..<n).map { _ in Int32(rng.int(alphabet)) }
            let b = (0..<m).map { _ in Int32(rng.int(alphabet)) }
            let (am, bm) = Myers.matches(a, b)
            let ma = zip(a, am).filter(\.1).map(\.0)
            let mb = zip(b, bm).filter(\.1).map(\.0)
            XCTAssertEqual(ma, mb, "matched elements must form a common subsequence")
            XCTAssertEqual(ma.count, lcsLength(a, b), "must be a longest common subsequence")
        }
    }

    func testBlocksReconstructRightSide() {
        var rng = LCG(state: 7)
        for _ in 0..<1000 {
            let left = (0..<rng.int(40)).map { _ in "line \(rng.int(8))" }
            let right = (0..<rng.int(40)).map { _ in "line \(rng.int(8))" }
            let d = TextDiff(left: TextDocument(lines: left), right: TextDocument(lines: right))
            var rebuilt: [String] = []
            var li = 0, ri = 0
            for block in d.blocks {
                XCTAssertEqual(block.left.lowerBound, li)
                XCTAssertEqual(block.right.lowerBound, ri)
                if block.kind == .equal {
                    XCTAssertEqual(Array(left[block.left]), Array(right[block.right]))
                    rebuilt += left[block.left]
                } else {
                    rebuilt += right[block.right]
                }
                li = block.left.upperBound
                ri = block.right.upperBound
            }
            XCTAssertEqual(li, left.count)
            XCTAssertEqual(rebuilt, right)
        }
    }

    /// Our total edit count must match `diff --minimal` on random files.
    func testMatchesSystemDiff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twofold-x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = LCG(state: 99)
        for round in 0..<40 {
            let base = (0..<200).map { _ in "token \(rng.int(30))" }
            var other = base
            for _ in 0..<rng.int(25) {
                let k = rng.int(3), at = rng.int(max(other.count, 1))
                if k == 0, !other.isEmpty { other.remove(at: at) }
                else if k == 1 { other.insert("new \(rng.int(50))", at: min(at, other.count)) }
                else if !other.isEmpty { other[at] = "changed \(rng.int(50))" }
            }
            let a = dir.appendingPathComponent("a\(round)"), b = dir.appendingPathComponent("b\(round)")
            try (base.joined(separator: "\n") + "\n").write(to: a, atomically: true, encoding: .utf8)
            try (other.joined(separator: "\n") + "\n").write(to: b, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            p.arguments = ["-d", a.path, b.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let expected = out.split(separator: "\n").filter { $0.hasPrefix("<") || $0.hasPrefix(">") }.count
            let d = TextDiff(left: try TextDocument.load(a), right: try TextDocument.load(b))
            let ours = d.blocks.filter { $0.kind != .equal }.reduce(0) { $0 + $1.left.count + $1.right.count }
            XCTAssertEqual(ours, expected, "round \(round)")
        }
    }
}

final class ThreeWayMergeTests: XCTestCase {
    private func doc(_ lines: [String]) -> TextDocument { TextDocument(lines: lines) }

    private func merge(_ base: [String]?, _ local: [String], _ remote: [String]) -> ThreeWayMerge {
        ThreeWayMerge(base: base.map(doc), local: doc(local), remote: doc(remote))
    }

    private func kinds(_ m: ThreeWayMerge) -> [MergeChunk.Kind] { m.chunks.map(\.kind) }

    func testChangesOnOneSideAreTaken() {
        let base = ["a", "b", "c", "d", "e"]
        let m = merge(base, ["a", "B", "c", "d", "e"], ["a", "b", "c", "d", "E", "f"])
        XCTAssertEqual(kinds(m), [.unchanged, .local, .unchanged, .remote])
        XCTAssertEqual(m.conflictCount, 0)
        XCTAssertEqual(m.mergedLines(), ["a", "B", "c", "d", "E", "f"])
        XCTAssertEqual(m.changeChunks, [1, 3])
        XCTAssertEqual(m.diff.changeBlocks.count, 2)
    }

    func testInsertionsAndDeletions() {
        let base = ["a", "b", "c", "d"]
        let m = merge(base, ["a", "c", "d"], ["a", "b", "c", "x", "d"])
        XCTAssertEqual(m.conflictCount, 0)
        XCTAssertEqual(m.mergedLines(), ["a", "c", "x", "d"])
        XCTAssertEqual(m.diff.blocks.filter { $0.kind != .equal }.map(\.kind), [.added, .added])
    }

    func testSameChangeOnBothSidesIsNotAConflict() {
        let m = merge(["a", "b", "c"], ["a", "X", "c"], ["a", "X", "c"])
        XCTAssertEqual(kinds(m), [.unchanged, .same, .unchanged])
        XCTAssertTrue(m.diff.isIdentical)
        XCTAssertEqual(m.mergedLines(), ["a", "X", "c"])
    }

    func testDifferentChangesToTheSameLinesConflict() {
        let m = merge(["a", "b", "c"], ["a", "L", "c"], ["a", "R", "c"])
        XCTAssertEqual(kinds(m), [.unchanged, .conflict, .unchanged])
        XCTAssertEqual(m.conflictCount, 1)
        XCTAssertNil(m.automaticChoice(1))
        XCTAssertEqual(m.lines(1, .local), ["L"])
        XCTAssertEqual(m.lines(1, .remote), ["R"])
        XCTAssertEqual(m.lines(1, .both), ["L", "R"])
        XCTAssertEqual(m.lines(1, .base), ["b"])
        XCTAssertEqual(m.mergedLines(localLabel: "ours", remoteLabel: "theirs"),
                       ["a", "<<<<<<< ours", "L", "=======", "R", ">>>>>>> theirs", "c"])
    }

    func testChangeAgainstDeletionConflicts() {
        let m = merge(["a", "b", "c"], ["a", "c"], ["a", "B", "c"])
        XCTAssertEqual(m.conflictCount, 1)
        XCTAssertEqual(m.lines(1, .local), [])
        XCTAssertEqual(m.diff.blocks[1].kind, .added)
    }

    func testAdjacentChangesConflict() {
        // As in git, edits to neighbouring lines are not merged silently.
        let m = merge(["a", "b", "c", "d"], ["a", "B", "c", "d"], ["a", "b", "C", "d"])
        XCTAssertEqual(m.conflictCount, 1)
    }

    func testSharedLinesAreTrimmedFromAConflict() {
        let m = merge(["a", "z"], ["a", "new", "L", "z"], ["a", "new", "R", "z"])
        XCTAssertEqual(kinds(m), [.unchanged, .same, .conflict, .unchanged])
        XCTAssertEqual(m.lines(2, .local), ["L"])
        XCTAssertEqual(m.mergedLines(), ["a", "new", "<<<<<<< local", "L", "=======", "R", ">>>>>>> remote", "z"])
    }

    func testWithoutBaseEveryDifferenceConflicts() {
        let m = merge(nil, ["a", "b", "c"], ["a", "c", "d"])
        XCTAssertEqual(kinds(m), [.unchanged, .conflict, .unchanged, .conflict])
        XCTAssertEqual(m.lines(1, .base), [])
        XCTAssertEqual(m.diff.changeBlocks.count, 2)
    }

    func testEmptyAndIdenticalInputs() {
        XCTAssertEqual(merge([], [], []).chunks, [])
        XCTAssertEqual(kinds(merge(["a"], ["a"], ["a"])), [.unchanged])
        let added = merge([], ["x"], [])
        XCTAssertEqual(kinds(added), [.local])
        XCTAssertEqual(added.mergedLines(), ["x"])
        XCTAssertEqual(merge([], ["x"], ["y"]).conflictCount, 1)
    }

    func testConflictStartDetection() {
        XCTAssertTrue(ThreeWayMerge.isConflictStart("<<<<<<< HEAD"))
        XCTAssertTrue(ThreeWayMerge.isConflictStart("<<<<<<<"))
        XCTAssertFalse(ThreeWayMerge.isConflictStart("<<<<<<<<"))
        XCTAssertFalse(ThreeWayMerge.isConflictStart(" <<<<<<< HEAD"))
    }

    /// The chunks must tile all three files, and the diff must describe local against remote.
    func testChunksCoverEverySide() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let base = (0..<Int.random(in: 0...30, using: &rng)).map { _ in String(Int.random(in: 0...6, using: &rng)) }
            func mutate(_ lines: [String]) -> [String] {
                var out = lines
                for _ in 0..<Int.random(in: 0...4, using: &rng) {
                    let i = Int.random(in: 0...out.count, using: &rng)
                    switch Int.random(in: 0...2, using: &rng) {
                    case 0: out.insert(String(Int.random(in: 0...9, using: &rng)), at: i)
                    case 1: if i < out.count { out.remove(at: i) }
                    default: if i < out.count { out[i] = String(Int.random(in: 0...9, using: &rng)) }
                    }
                }
                return out
            }
            let local = mutate(base), remote = mutate(base)
            for b in [base, nil] {
                let m = merge(b, local, remote)
                var bi = 0, li = 0, ri = 0
                for (i, c) in m.chunks.enumerated() {
                    if b != nil { XCTAssertEqual(c.base.lowerBound, bi) }
                    XCTAssertEqual(c.local.lowerBound, li)
                    XCTAssertEqual(c.remote.lowerBound, ri)
                    bi = c.base.upperBound; li = c.local.upperBound; ri = c.remote.upperBound
                    switch c.kind {
                    case .unchanged, .same: XCTAssertEqual(m.lines(i, .local), m.lines(i, .remote))
                    case .local: XCTAssertEqual(m.lines(i, .remote), m.lines(i, .base))
                    case .remote: XCTAssertEqual(m.lines(i, .local), m.lines(i, .base))
                    case .conflict: XCTAssertNotEqual(m.lines(i, .local), m.lines(i, .remote))
                    }
                    if c.kind != .unchanged && c.kind != .same { XCTAssertNotEqual(m.lines(i, .local), m.lines(i, .remote)) }
                }
                if let b { XCTAssertEqual(bi, b.count) }
                XCTAssertEqual(li, local.count)
                XCTAssertEqual(ri, remote.count)
                XCTAssertEqual(m.changeChunks.count, m.diff.changeBlocks.count)
                for (n, ci) in m.changeChunks.enumerated() {
                    let block = m.diff.blocks[m.diff.changeBlocks[n]]
                    XCTAssertEqual(block.left, m.chunks[ci].local)
                    XCTAssertEqual(block.right, m.chunks[ci].remote)
                }
                var l = 0, r = 0
                for block in m.diff.blocks {
                    XCTAssertEqual(block.left.lowerBound, l)
                    XCTAssertEqual(block.right.lowerBound, r)
                    l = block.left.upperBound; r = block.right.upperBound
                    if block.kind == .equal { XCTAssertEqual(Array(local[block.left]), Array(remote[block.right])) }
                }
                XCTAssertEqual(l, local.count)
                XCTAssertEqual(r, remote.count)
            }
        }
    }

    /// With unique lines and edits kept apart, git has only one possible answer; ours must be the same.
    func testMatchesGitMergeFile() throws {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not available") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twofold-m-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SystemRandomNumberGenerator()
        for round in 0..<25 {
            let base = (0..<200).map { "line \($0)" }
            // Each side edits its own set of spots, at least three lines from any other.
            func edited(_ offset: Int, _ tag: String) -> [String] {
                var out: [String] = []
                for (i, line) in base.enumerated() {
                    guard i % 12 == offset else { out.append(line); continue }
                    switch Int.random(in: 0...3, using: &rng) {
                    case 0: out.append("\(line) \(tag)")
                    case 1: break
                    case 2: out += [line, "\(tag) new \(i)", "\(tag) more \(i)"]
                    default: out.append(line)
                    }
                }
                return out
            }
            let local = edited(2, "L"), remote = edited(8, "R")
            let names = ["local", "base", "remote"].map { dir.appendingPathComponent("\($0)-\(round).txt") }
            for (url, lines) in zip(names, [local, base, remote]) {
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["merge-file", "-p"] + names.map(\.path)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git found conflicts in a case built to have none")
            let m = merge(base, local, remote)
            XCTAssertEqual(m.conflictCount, 0)
            XCTAssertEqual(m.mergedLines().joined(separator: "\n") + "\n", String(decoding: data, as: UTF8.self))
        }
    }
}

final class ImageDiffTests: XCTestCase {
    /// A solid image with some pixels replaced.
    private func image(_ w: Int, _ h: Int, fill: [UInt8] = [10, 20, 30, 255], _ edits: [(Int, Int, [UInt8])] = []) -> PixelBuffer {
        var px = [UInt8]()
        px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: fill) }
        for (x, y, c) in edits { px.replaceSubrange((y * w + x) * 4..<(y * w + x) * 4 + 4, with: c) }
        return PixelBuffer(width: w, height: h, rgba: px)
    }

    func testIdenticalImages() {
        let d = ImageDiff(left: image(40, 30), right: image(40, 30))
        XCTAssertTrue(d.isIdentical)
        XCTAssertEqual(d.regions, [])
        XCTAssertEqual(d.mask.count, 40 * 30)
        XCTAssertFalse(d.mask.contains { $0 != 0 })
    }

    func testCountsPixelsAndRecordsStrength() {
        let d = ImageDiff(left: image(40, 30), right: image(40, 30, [(5, 7, [10, 60, 30, 255]), (6, 7, [11, 20, 30, 255])]))
        XCTAssertEqual(d.differingPixels, 2)
        XCTAssertEqual(d.mask[7 * 40 + 5], 40)
        XCTAssertEqual(d.mask[7 * 40 + 6], 1)
        XCTAssertEqual(d.regions, [PixelRect(x: 5, y: 7, width: 2, height: 1)])
        XCTAssertEqual(d.fraction, 2.0 / 1200.0, accuracy: 1e-12)
    }

    func testDistantChangesAreSeparateRegions() {
        let edits: [(Int, Int, [UInt8])] = [(2, 2, [0, 0, 0, 255]), (3, 3, [0, 0, 0, 255]), (190, 90, [0, 0, 0, 255])]
        let d = ImageDiff(left: image(200, 100), right: image(200, 100, edits))
        XCTAssertEqual(d.regions, [PixelRect(x: 2, y: 2, width: 2, height: 2), PixelRect(x: 190, y: 90, width: 1, height: 1)])
    }

    func testNeighbouringCellsJoinIntoOneRegion() {
        // Either side of a cell boundary, and diagonally across one.
        let c = ImageDiff.cellSize
        let edits: [(Int, Int, [UInt8])] = [(c - 1, 4, [0, 0, 0, 255]), (c, 4, [0, 0, 0, 255]), (c + 3, c + 2, [0, 0, 0, 255])]
        let d = ImageDiff(left: image(64, 64), right: image(64, 64, edits))
        XCTAssertEqual(d.regions, [PixelRect(x: c - 1, y: 4, width: 5, height: c - 1)])
    }

    func testToleranceIgnoresSmallDifferences() {
        let l = image(8, 8), r = image(8, 8, [(1, 1, [12, 20, 30, 255]), (2, 2, [10, 20, 40, 255])])
        XCTAssertEqual(ImageDiff(left: l, right: r).differingPixels, 2)
        XCTAssertEqual(ImageDiff(left: l, right: r, tolerance: 2).differingPixels, 1)
        XCTAssertTrue(ImageDiff(left: l, right: r, tolerance: 10).isIdentical)
    }

    func testDifferentSizesCompareAgainstTransparent() {
        let d = ImageDiff(left: image(10, 10), right: image(14, 12))
        XCTAssertEqual(d.width, 14)
        XCTAssertEqual(d.height, 12)
        XCTAssertEqual(d.differingPixels, 14 * 12 - 10 * 10)
        XCTAssertEqual(d.mask[0], 0)
        XCTAssertEqual(d.mask[11 * 14 + 13], 255)
        XCTAssertEqual(d.regions, [PixelRect(x: 0, y: 0, width: 14, height: 12)])

        // Extra area that is fully transparent is not a difference.
        let clear = image(14, 12, fill: [0, 0, 0, 0], (0..<100).map { ($0 % 10, $0 / 10, [10, 20, 30, 255]) })
        XCTAssertTrue(ImageDiff(left: image(10, 10), right: clear).isIdentical)
    }

    func testMissingSide() {
        let d = ImageDiff(left: nil, right: image(6, 4))
        XCTAssertEqual(d.differingPixels, 24)
        XCTAssertEqual(ImageDiff(left: image(6, 4), right: nil).differingPixels, 24)
        let empty = ImageDiff(left: nil, right: nil)
        XCTAssertTrue(empty.isIdentical)
        XCTAssertEqual(empty.totalPixels, 0)
        XCTAssertEqual(empty.fraction, 0)
    }

    func testRespectsRowPadding() {
        // Rows padded to 20 bytes; the padding differs but must be ignored.
        func padded(_ pad: UInt8, _ last: UInt8) -> PixelBuffer {
            var bytes = [UInt8]()
            for y in 0..<3 {
                for x in 0..<4 { bytes.append(contentsOf: [1, 2, 3, (x == 3 && y == 2) ? last : 255]) }
                bytes.append(contentsOf: [pad, pad, pad, pad])
            }
            return PixelBuffer(width: 4, height: 3, bytesPerRow: 20, data: Data(bytes))
        }
        XCTAssertTrue(ImageDiff(left: padded(0, 255), right: padded(9, 255)).isIdentical)
        let d = ImageDiff(left: padded(0, 255), right: padded(9, 250))
        XCTAssertEqual(d.regions, [PixelRect(x: 3, y: 2, width: 1, height: 1)])
    }
}

final class SyntaxTests: XCTestCase {
    /// The highlighted pieces of each line as "kind:text".
    private func tokens(_ language: String, _ text: String) -> [[String]] {
        let lines = text.components(separatedBy: "\n")
        let map = SyntaxLanguage.named(language)!.highlight(lines)
        XCTAssertEqual(map.lineCount, lines.count)
        return lines.indices.map { i in
            let ns = lines[i] as NSString
            var last = 0
            return map[i].map { span in
                XCTAssertGreaterThanOrEqual(span.range.lowerBound, last, "spans overlap in \(lines[i])")
                XCTAssertLessThanOrEqual(span.range.upperBound, ns.length)
                last = span.range.upperBound
                return "\(span.kind):\(ns.substring(with: NSRange(span.range)))"
            }
        }
    }

    func testSwift() {
        let t = tokens("swift", #"""
        @MainActor final class Foo: Bar { // note
            let n = 0x1F + 2.5e-3
            func go(_ s: String) -> Int { print("a \" b"); return URL.max }
        }
        """#)
        XCTAssertEqual(t[0], ["attribute:@MainActor", "keyword:final", "keyword:class", "type:Foo", "type:Bar", "comment:// note"])
        XCTAssertEqual(t[1], ["keyword:let", "number:0x1F", "number:2.5e-3"])
        XCTAssertEqual(t[2], ["keyword:func", "function:go", "type:String", "type:Int", "function:print", #"string:"a \" b""#, "keyword:return", "type:URL"])
        // Outside Swift, all-capital names are constants and stay plain.
        XCTAssertEqual(tokens("java", "int n = MAX_SIZE + Limit.of(x);")[0], ["keyword:int", "type:Limit", "function:of"])
    }

    func testBlockCommentsAndStringsSpanLines() {
        let t = tokens("swift", "a /* one\n /* two */ still\n done */ let x = \"\"\"\n  text \"quoted\"\n  \"\"\" + y")
        XCTAssertEqual(t[0], ["comment:/* one"])
        XCTAssertEqual(t[1], ["comment: /* two */ still"])
        XCTAssertEqual(t[2], ["comment: done */", "keyword:let", "string:\"\"\""])
        XCTAssertEqual(t[3], ["string:  text \"quoted\""])
        XCTAssertEqual(t[4], ["string:  \"\"\""])
        // C comments do not nest, and an unterminated ordinary string ends with its line.
        let c = tokens("c", "/* a /* b */ int x; char *s = \"open\nint y;")
        XCTAssertEqual(c[0], ["comment:/* a /* b */", "keyword:int", "keyword:char", "string:\"open"])
        XCTAssertEqual(c[1], ["keyword:int"])
    }

    func testOffsetsAreUTF16() {
        let t = tokens("swift", "let s = \"👍🏽\" // é")
        XCTAssertEqual(t[0], ["keyword:let", "string:\"👍🏽\"", "comment:// é"])
    }

    func testCPreprocessorAndRust() {
        XCTAssertEqual(tokens("c", "#include <stdio.h>\nsize_t n = sizeof(x);")[0], ["attribute:#include", "string:<stdio.h>"])
        let r = tokens("rust", "#[derive(Debug)]\nfn f(x: &'a str) -> char { println!(\"hi\"); 'x' }")
        XCTAssertEqual(r[0], ["attribute:#[derive(Debug)]"])
        XCTAssertEqual(r[1], ["keyword:fn", "function:f", "type:str", "type:char", "function:println!", "string:\"hi\"", "string:'x'"])
    }

    func testJavaScriptRegexAndTemplates() {
        let t = tokens("javascript", "const re = /a\\/[/]b/gi, half = total / 2 / n;\nconst s = `line\n${x}`; // done")
        XCTAssertEqual(t[0], ["keyword:const", "string:/a\\/[/]b/gi", "number:2"])
        XCTAssertEqual(t[1], ["keyword:const", "string:`line"])
        XCTAssertEqual(t[2], ["string:${x}`", "comment:// done"])
    }

    func testPythonAndShell() {
        let p = tokens("python", "@cache\ndef f(x: int) -> str:  # why\n    return '''a\nb''' if x else None")
        XCTAssertEqual(p[0], ["attribute:@cache"])
        XCTAssertEqual(p[1], ["keyword:def", "function:f", "type:int", "type:str", "comment:# why"])
        XCTAssertEqual(p[2], ["keyword:return", "string:'''a"])
        XCTAssertEqual(p[3], ["string:b'''", "keyword:if", "keyword:else", "keyword:None"])
        let s = tokens("shell", "if [ $# -gt 0 ]; then echo \"${NAME}\" $1 # note")
        XCTAssertEqual(s[0], ["keyword:if", "property:$#", "number:0", "keyword:then", "string:\"${NAME}\"", "property:$1", "comment:# note"])
    }

    func testSQLIsCaseInsensitive() {
        XCTAssertEqual(tokens("sql", "Select id FROM t WHERE n = 'it''s' -- c")[0],
                       ["keyword:Select", "keyword:FROM", "keyword:WHERE", "string:'it'", "string:'s'", "comment:-- c"])
    }

    func testJSONAndTOML() {
        XCTAssertEqual(tokens("json", #"{ "name": "x", "n": [1.5, true] }"#)[0],
                       ["property:\"name\"", "string:\"x\"", "property:\"n\"", "number:1.5", "keyword:true"])
        let t = tokens("toml", "[package]\nname = \"twofold\" # c\ndebug = true")
        XCTAssertEqual(t, [["tag:[package]"], ["property:name", "string:\"twofold\"", "comment:# c"], ["property:debug", "keyword:true"]])
    }

    func testYAML() {
        let t = tokens("yaml", "# top\nname: \"a: b\"  # c\n- port: 8080\n  on: true\nrun: |\n  echo: hi\n\n  more\nnext: &a plain text")
        XCTAssertEqual(t[0], ["comment:# top"])
        XCTAssertEqual(t[1], ["property:name", "string:\"a: b\"", "comment:# c"])
        XCTAssertEqual(t[2], ["property:port", "number:8080"])
        XCTAssertEqual(t[3], ["property:on", "keyword:true"])
        XCTAssertEqual(t[4], ["property:run", "keyword:|"])
        XCTAssertEqual(t[5], ["string:echo: hi"])
        XCTAssertEqual(t[6], [])
        XCTAssertEqual(t[7], ["string:more"])
        XCTAssertEqual(t[8], ["property:next", "attribute:&a"])
    }

    func testHTMLWithEmbeddedScriptAndStyle() {
        let t = tokens("html", """
        <!DOCTYPE html>
        <div class="a" hidden>x &amp; y</div> <!-- c
        still --> <br/>
        <script type="module">
          const n = 1; // <b>
        </script>
        <style>p.note { color: #fff; }</style><p>
        """)
        XCTAssertEqual(t[0], ["keyword:!DOCTYPE", "attribute:html"])
        XCTAssertEqual(t[1], ["tag:div", "attribute:class", "string:\"a\"", "attribute:hidden", "number:&amp;", "tag:div", "comment:<!-- c"])
        XCTAssertEqual(t[2], ["comment:still -->", "tag:br"])
        XCTAssertEqual(t[3], ["tag:script", "attribute:type", "string:\"module\""])
        XCTAssertEqual(t[4], ["keyword:const", "number:1", "comment:// <b>"])
        XCTAssertEqual(t[5], ["tag:script"])
        XCTAssertEqual(t[6], ["tag:style", "tag:p", "tag:.note", "property:color", "number:#fff", "tag:style", "tag:p"])
    }

    func testCSS() {
        let t = tokens("css", "@media (min-width: 600px) {\n  a:hover, #main .x { margin: -0.5em auto; background: url(\"a.png\") #a1b2c3 !important; }\n  --gap: 4px; /* c */\n}")
        XCTAssertEqual(t[0], ["keyword:@media", "property:min-width", "number:600px"])
        XCTAssertEqual(t[1], ["tag:a", "tag:hover", "tag:#main", "tag:.x", "property:margin", "number:-0.5em", "property:background",
                              "function:url", "string:\"a.png\"", "number:#a1b2c3", "keyword:!important"])
        XCTAssertEqual(t[2], ["property:--gap", "number:4px", "comment:/* c */"])
    }

    func testMarkdown() {
        let t = tokens("markdown", "# Title\n- use `code` and [a link](http://x)\n```swift\nlet # not a heading\n```\n> quote")
        XCTAssertEqual(t, [["keyword:# Title"], ["number:-", "string:`code`", "property:[a link]", "comment:(http://x)"],
                           ["comment:```swift"], [], ["comment:```"], ["comment:> quote"]])
    }

    func testDetection() {
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "Main.SWIFT")?.name, "Swift")
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "Makefile")?.name, "Makefile")
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "Dockerfile.prod")?.name, "Dockerfile")
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "run", firstLine: "#!/usr/bin/env python3")?.name, "Python")
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "run", firstLine: "#!/bin/sh")?.name, "Shell")
        XCTAssertNil(SyntaxLanguage.detect(fileName: "notes.txt", firstLine: "hello"))
        // Every extension and file name points at a language that exists.
        for id in Set(Languages.byExtension.values).union(Languages.byName.values).union(Languages.shebangs.map(\.1)) {
            XCTAssertNotNil(SyntaxLanguage.named(id), id)
        }
    }

    /// Whatever the input, spans stay ordered and inside their line, and the lexer terminates.
    func testRandomInputKeepsSpansValid() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["\"", "'", "`", "/*", "*/", "//", "#", "<", ">", "</script", "<!--", "-->", "{", "}", ":", " ", "\\", "$", "@",
                      "a", "Foo", "12", "=", "[", "]", "(", ")", "|", "-", "\"\"\"", "é", "👍", "/", ";", "&amp;", "```", "<style>", "!"]
        for id in Languages.names.keys.sorted() {
            let lines = (0..<200).map { _ in (0..<Int.random(in: 0...14, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined() }
            let map = SyntaxLanguage.named(id)!.highlight(lines)
            for (i, line) in lines.enumerated() {
                var last = 0
                for span in map[i] {
                    XCTAssertTrue(span.range.lowerBound >= last && span.range.upperBound <= line.utf16.count && !span.range.isEmpty,
                                  "\(id): bad span \(span.range) in \(line.debugDescription)")
                    last = span.range.upperBound
                }
            }
        }
    }
}

final class FolderTests: XCTestCase {
    func testFolderComparison() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("twofold-f-\(UUID().uuidString)")
        let l = root.appendingPathComponent("L"), r = root.appendingPathComponent("R")
        defer { try? fm.removeItem(at: root) }
        func write(_ base: URL, _ path: String, _ text: String) throws {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(l, "same.txt", "hello"); try write(r, "same.txt", "hello")
        try write(l, "sub/samesize.txt", "abc"); try write(r, "sub/samesize.txt", "abd")
        try write(l, "sub/size.txt", "abc"); try write(r, "sub/size.txt", "abcdef")
        try write(l, "gone.txt", "x")
        try write(r, "deep/new/file.txt", "y")
        try write(l, ".git/config", "a"); try write(r, ".git/config", "b")

        let entries = await FolderCompare.list(left: l, right: r)
        XCTAssertEqual(entries.map(\.path), ["gone.txt", "same.txt", "deep/new/file.txt", "sub/samesize.txt", "sub/size.txt"])
        var resolved = entries
        let collector = Collector()
        await FolderCompare.resolve(entries: entries, left: l, right: r) { await collector.add($0) }
        for (i, s) in await collector.items { resolved[i].status = s }
        let status = Dictionary(uniqueKeysWithValues: resolved.map { ($0.path, $0.status) })
        XCTAssertEqual(status["same.txt"], .identical)
        XCTAssertEqual(status["sub/samesize.txt"], .different)
        XCTAssertEqual(status["sub/size.txt"], .different)
        XCTAssertEqual(status["gone.txt"], .onlyLeft)
        XCTAssertEqual(status["deep/new/file.txt"], .onlyRight)
    }

    actor Collector {
        var items: [(Int, FolderEntry.Status)] = []
        func add(_ batch: [(Int, FolderEntry.Status)]) { items += batch }
    }
}

final class BenchmarkTests: XCTestCase {
    func testSyntaxHighlightPerformance() {
        let unit = ["/// Doc comment for item", "public func item(_ index: Int, named name: String = \"x\") -> [String: Int]? {",
                    "    guard index > 0x10, let value = cache[name] else { return nil } // early out", "    return [\"count\": value * 2 + 1]", "}", ""]
        let lines = (0..<100_000).map { unit[$0 % unit.count] }
        let swift = SyntaxLanguage.named("swift")!
        let start = DispatchTime.now().uptimeNanoseconds
        let map = swift.highlight(lines)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "BENCH syntax 100k lines: %.1f ms", ms))
        XCTAssertEqual(map.lineCount, lines.count)
    }

    func testLargeDiffPerformance() {
        var rng = DiffTests.LCG(state: 1)
        let left = (0..<100_000).map { "let value\($0) = compute(\($0 % 977), \(rng.int(1000)))" }
        var right = left
        for _ in 0..<1000 { right[rng.int(right.count)] = "changed \(rng.int(1_000_000))" }
        let a = TextDocument(lines: left), b = TextDocument(lines: right)
        let start = Date()
        let d = TextDiff(left: a, right: b)
        let elapsed = Date().timeIntervalSince(start)
        print("BENCH diff 100k lines, 1% changed: \(Int(elapsed * 1000)) ms, \(d.changeBlocks.count) changes")
        XCTAssertGreaterThan(d.changeBlocks.count, 900)
        XCTAssertLessThan(elapsed, 5)
    }
}
