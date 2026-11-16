import Foundation

/// One stretch of a three-way merge: a run of lines on each of the three sides that belong together.
public struct MergeChunk: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// All three sides agree.
        case unchanged
        /// Only the local side differs from the base.
        case local
        /// Only the remote side differs from the base.
        case remote
        /// Both sides made the same change.
        case same
        /// Both sides changed the same lines differently.
        case conflict
    }

    public var kind: Kind
    public var base: Range<Int>
    public var local: Range<Int>
    public var remote: Range<Int>

    public init(kind: Kind, base: Range<Int>, local: Range<Int>, remote: Range<Int>) {
        self.kind = kind
        self.base = base
        self.local = local
        self.remote = remote
    }
}

/// Which lines a chunk contributes to the merged file.
public enum MergeChoice: Sendable, Hashable {
    case local, remote
    /// The local lines followed by the remote lines.
    case both
    /// Neither change: the lines of the common ancestor.
    case base
}

/// A diff3-style merge of two files that descend from a common base.
///
/// Lines of the base that survive on both sides divide the files into chunks. A chunk only one side
/// touched takes that side; a chunk both sides touched differently is a conflict. Without a base
/// every difference between the two sides is a conflict.
public struct ThreeWayMerge: Sendable {
    public let base: TextDocument?
    public let local: TextDocument
    public let remote: TextDocument
    public let chunks: [MergeChunk]
    /// Local against remote, with exactly one change block for every chunk where the two differ.
    public let diff: TextDiff
    /// For each change of `diff`, in order, the index of its chunk.
    public let changeChunks: [Int]

    public var conflictCount: Int { chunks.reduce(0) { $0 + ($1.kind == .conflict ? 1 : 0) } }

    public init(base: TextDocument?, local: TextDocument, remote: TextDocument, timeLimit: Double = 2.0) {
        self.base = base
        self.local = local
        self.remote = remote

        var table: [String: Int32] = [:]
        func intern(_ lines: [String]) -> [Int32] {
            lines.map { s in
                if let v = table[s] { return v }
                let v = Int32(table.count)
                table[s] = v
                return v
            }
        }
        let l = intern(local.lines), r = intern(remote.lines)
        var out: [MergeChunk] = []

        func push(_ kind: MergeChunk.Kind, _ b: Range<Int>, _ lr: Range<Int>, _ rr: Range<Int>) {
            if b.isEmpty && lr.isEmpty && rr.isEmpty { return }
            if kind == .unchanged, let last = out.last, last.kind == .unchanged {
                out[out.count - 1] = MergeChunk(kind: .unchanged, base: last.base.lowerBound..<b.upperBound,
                                                local: last.local.lowerBound..<lr.upperBound,
                                                remote: last.remote.lowerBound..<rr.upperBound)
            } else {
                out.append(MergeChunk(kind: kind, base: b, local: lr, remote: rr))
            }
        }

        /// Both sides differ from the base here. Lines they share at either end are not in dispute.
        func pushDisputed(_ b: Range<Int>, _ lr: Range<Int>, _ rr: Range<Int>, _ baseIDs: [Int32]?) {
            if l[lr] == r[rr] {
                push(.same, b, lr, rr)
                return
            }
            var p = 0
            while p < lr.count && p < rr.count && l[lr.lowerBound + p] == r[rr.lowerBound + p] { p += 1 }
            var s = 0
            while s < lr.count - p && s < rr.count - p && l[lr.upperBound - 1 - s] == r[rr.upperBound - 1 - s] { s += 1 }
            let lc = (lr.lowerBound + p)..<(lr.upperBound - s), rc = (rr.lowerBound + p)..<(rr.upperBound - s)
            push(.same, b.lowerBound..<b.lowerBound, lr.lowerBound..<lc.lowerBound, rr.lowerBound..<rc.lowerBound)
            // With the shared lines set aside, one side may turn out to equal the base after all.
            var kind = MergeChunk.Kind.conflict
            if let ids = baseIDs {
                if l[lc] == ids[b] { kind = .remote } else if r[rc] == ids[b] { kind = .local }
            }
            push(kind, b, lc, rc)
            push(.same, b.upperBound..<b.upperBound, lc.upperBound..<lr.upperBound, rc.upperBound..<rr.upperBound)
        }

        if let base {
            let b = intern(base.lines)
            let toLocal = Self.pairing(b, l, timeLimit), toRemote = Self.pairing(b, r, timeLimit)
            var bi = 0, li = 0, ri = 0
            func gap(_ be: Int, _ le: Int, _ re: Int) {
                let br = bi..<be, lr = li..<le, rr = ri..<re
                if br.isEmpty && lr.isEmpty && rr.isEmpty { return }
                let localChanged = l[lr] != b[br], remoteChanged = r[rr] != b[br]
                switch (localChanged, remoteChanged) {
                case (false, false): push(.unchanged, br, lr, rr)
                case (true, false): push(.local, br, lr, rr)
                case (false, true): push(.remote, br, lr, rr)
                case (true, true): pushDisputed(br, lr, rr, b)
                }
            }
            for i in b.indices where toLocal[i] >= 0 && toRemote[i] >= 0 {
                gap(i, toLocal[i], toRemote[i])
                push(.unchanged, i..<(i + 1), toLocal[i]..<(toLocal[i] + 1), toRemote[i]..<(toRemote[i] + 1))
                bi = i + 1
                li = toLocal[i] + 1
                ri = toRemote[i] + 1
            }
            gap(b.count, l.count, r.count)
        } else {
            let toRemote = Self.pairing(l, r, timeLimit)
            var li = 0, ri = 0
            for i in l.indices where toRemote[i] >= 0 {
                if li < i || ri < toRemote[i] { pushDisputed(0..<0, li..<i, ri..<toRemote[i], nil) }
                push(.unchanged, 0..<0, i..<(i + 1), toRemote[i]..<(toRemote[i] + 1))
                li = i + 1
                ri = toRemote[i] + 1
            }
            if li < l.count || ri < r.count { pushDisputed(0..<0, li..<l.count, ri..<r.count, nil) }
        }
        chunks = out

        var blocks: [DiffBlock] = []
        var changes: [Int] = []
        for (i, c) in out.enumerated() {
            if c.kind == .unchanged || c.kind == .same {
                if c.local.isEmpty { continue }
                if let last = blocks.last, last.kind == .equal {
                    blocks[blocks.count - 1] = DiffBlock(kind: .equal, left: last.left.lowerBound..<c.local.upperBound,
                                                         right: last.right.lowerBound..<c.remote.upperBound)
                } else {
                    blocks.append(DiffBlock(kind: .equal, left: c.local, right: c.remote))
                }
            } else {
                let kind: DiffBlock.Kind = c.local.isEmpty ? .added : (c.remote.isEmpty ? .removed : .modified)
                blocks.append(DiffBlock(kind: kind, left: c.local, right: c.remote))
                changes.append(i)
            }
        }
        diff = TextDiff(left: local, right: remote, blocks: blocks)
        changeChunks = changes
    }

    /// For each element of `a`, the index of the element of `b` it is matched with, or -1.
    private static func pairing(_ a: [Int32], _ b: [Int32], _ timeLimit: Double) -> [Int] {
        let (am, bm) = Myers.matches(a, b, timeLimit: timeLimit)
        var out = [Int](repeating: -1, count: a.count)
        var j = 0
        for i in a.indices where am[i] {
            while j < b.count && !bm[j] { j += 1 }
            if j >= b.count { break }
            out[i] = j
            j += 1
        }
        return out
    }

    // MARK: Result

    /// The choice the merge makes on its own, or nil for a conflict.
    public func automaticChoice(_ chunk: Int) -> MergeChoice? {
        switch chunks[chunk].kind {
        case .unchanged, .same, .local: .local
        case .remote: .remote
        case .conflict: nil
        }
    }

    public func lines(_ chunk: Int, _ choice: MergeChoice) -> [String] {
        let c = chunks[chunk]
        switch choice {
        case .local: return Array(local.lines[c.local])
        case .remote: return Array(remote.lines[c.remote])
        case .both: return Array(local.lines[c.local]) + Array(remote.lines[c.remote])
        case .base: return base.map { Array($0.lines[c.base]) } ?? []
        }
    }

    public static let localMarker = "<<<<<<<"
    public static let separatorMarker = "======="
    public static let remoteMarker = ">>>>>>>"

    /// Both versions of a chunk between conflict markers, as git writes an unresolved conflict.
    public func markerLines(_ chunk: Int, localLabel: String, remoteLabel: String) -> [String] {
        let c = chunks[chunk]
        return ["\(Self.localMarker) \(localLabel)"] + local.lines[c.local] + [Self.separatorMarker]
            + remote.lines[c.remote] + ["\(Self.remoteMarker) \(remoteLabel)"]
    }

    /// True when a line opens an unresolved conflict.
    public static func isConflictStart(_ line: some StringProtocol) -> Bool {
        line.hasPrefix(localMarker) && (line.count == localMarker.count || line.dropFirst(localMarker.count).first == " ")
    }

    /// The merged lines, with conflicts left between markers.
    public func mergedLines(localLabel: String = "local", remoteLabel: String = "remote") -> [String] {
        var out: [String] = []
        for i in chunks.indices {
            if let choice = automaticChoice(i) {
                out += lines(i, choice)
            } else {
                out += markerLines(i, localLabel: localLabel, remoteLabel: remoteLabel)
            }
        }
        return out
    }
}
