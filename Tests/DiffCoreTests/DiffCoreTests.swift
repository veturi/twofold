import Foundation
import XCTest
@testable import DiffCore

final class TextDocumentTests: XCTestCase {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visdiff-x-\(UUID().uuidString)")
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

final class FolderTests: XCTestCase {
    func testFolderComparison() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("visdiff-f-\(UUID().uuidString)")
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
