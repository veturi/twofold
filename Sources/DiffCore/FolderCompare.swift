import Foundation

/// One file path present in either or both compared folders.
public struct FolderEntry: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case pending, identical, different, onlyLeft, onlyRight
    }

    /// Path relative to the compared roots, using "/" separators.
    public var path: String
    public var status: Status

    public init(path: String, status: Status) {
        self.path = path
        self.status = status
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

public enum FolderCompare {
    public static let ignoredNames: Set<String> = [".git", ".hg", ".svn", ".DS_Store"]

    struct FileInfo: Sendable {
        var size: Int
        var symlinkTarget: String?
    }

    /// Lists every regular file and symbolic link below `root`, keyed by relative path.
    static func scan(_ root: URL) -> [String: FileInfo] {
        let root = root.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
        var result: [String: FileInfo] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return result
        }
        for case let url as URL in e {
            let name = url.lastPathComponent
            if ignoredNames.contains(name) {
                e.skipDescendants()
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let rel = String(path.dropFirst(rootPath.count))
            if v.isSymbolicLink == true {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                result[rel] = FileInfo(size: 0, symlinkTarget: target)
            } else if v.isDirectory == true {
                continue
            } else {
                result[rel] = FileInfo(size: v.fileSize ?? 0, symlinkTarget: nil)
            }
        }
        return result
    }

    @concurrent static func scanAsync(_ root: URL) async -> [String: FileInfo] {
        scan(root)
    }

    /// Scans both trees concurrently and pairs files by relative path.
    /// Pairs whose sizes match are left `.pending` for `resolve` to settle.
    public static func list(left: URL, right: URL) async -> [FolderEntry] {
        async let l = scanAsync(left)
        async let r = scanAsync(right)
        let (lf, rf) = await (l, r)
        var paths = Set(lf.keys)
        paths.formUnion(rf.keys)
        var entries: [FolderEntry] = []
        entries.reserveCapacity(paths.count)
        for p in paths {
            let status: FolderEntry.Status
            switch (lf[p], rf[p]) {
            case let (a?, b?):
                if a.symlinkTarget != nil || b.symlinkTarget != nil {
                    status = a.symlinkTarget == b.symlinkTarget ? .identical : .different
                } else {
                    status = a.size == b.size ? .pending : .different
                }
            case (_?, nil): status = .onlyLeft
            default: status = .onlyRight
            }
            entries.append(FolderEntry(path: p, status: status))
        }
        entries.sort(by: pathOrder)
        return entries
    }

    /// Orders files directory by directory, root first, case-insensitively.
    public static func pathOrder(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        let da = a.directory, db = b.directory
        if da != db {
            if da.isEmpty { return true }
            if db.isEmpty { return false }
            return da.localizedStandardCompare(db) == .orderedAscending
        }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Byte-for-byte comparison through memory maps.
    public static func contentsEqual(_ a: URL, _ b: URL) -> Bool {
        guard let da = try? Data(contentsOf: a, options: .alwaysMapped),
              let db = try? Data(contentsOf: b, options: .alwaysMapped) else { return false }
        return da == db
    }

    /// Compares the contents of every pending entry, reporting results in batches as they arrive.
    public static func resolve(
        entries: [FolderEntry], left: URL, right: URL,
        report: @escaping @Sendable ([(Int, FolderEntry.Status)]) async -> Void
    ) async {
        let pending = entries.indices.filter { entries[$0].status == .pending }
        if pending.isEmpty { return }
        let paths = pending.map { entries[$0].path }
        await withTaskGroup(of: (Int, FolderEntry.Status).self) { group in
            var next = 0
            func add() {
                guard next < pending.count else { return }
                let index = pending[next], path = paths[next]
                next += 1
                group.addTask {
                    let same = contentsEqual(left.appendingPathComponent(path), right.appendingPathComponent(path))
                    return (index, same ? .identical : .different)
                }
            }
            for _ in 0..<8 { add() }
            var buffer: [(Int, FolderEntry.Status)] = []
            var last = DispatchTime.now().uptimeNanoseconds
            for await result in group {
                if Task.isCancelled { group.cancelAll(); return }
                buffer.append(result)
                add()
                let now = DispatchTime.now().uptimeNanoseconds
                if buffer.count >= 512 || now - last > 50_000_000 {
                    await report(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    last = now
                }
            }
            if !buffer.isEmpty { await report(buffer) }
        }
    }
}
