import Foundation

/// One file that differs between the last commit (HEAD) and the working copy.
public struct GitChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// In HEAD and in the working copy, with different contents.
        case modified
        /// In the working copy and known to git, but not in HEAD.
        case added
        /// In HEAD, gone from the working copy.
        case deleted
        /// In the working copy only; git does not track it.
        case untracked
        /// In HEAD under `originalPath`.
        case renamed
        /// Left unmerged by a merge, rebase or cherry-pick.
        case conflicted
    }

    /// How much of the change has been added to the index.
    public enum Staging: Sendable, Hashable {
        case none, partial, full
    }

    /// Path relative to the repository root, using "/" separators.
    public var path: String
    public var originalPath: String?
    public var kind: Kind
    public var staging: Staging
    /// Object name of the file's contents in HEAD, or nil when HEAD does not have the file.
    public var headID: String?

    public init(path: String, originalPath: String? = nil, kind: Kind, staging: Staging = .none, headID: String? = nil) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.staging = staging
        self.headID = headID
    }

    /// Whether the file exists in the working copy.
    public var isInWorkingCopy: Bool { kind != .deleted }
}

/// The state of a working copy, as `git status --porcelain=v2 --branch -z` reports it.
public struct GitStatus: Sendable, Equatable {
    /// The checked-out branch, or nil when HEAD is detached.
    public var branch: String?
    /// Changed files in path order. Changes inside submodules are left out.
    public var changes: [GitChange]

    public init(branch: String? = nil, changes: [GitChange] = []) {
        self.branch = branch
        self.changes = changes
    }

    /// Parses the output of `git status --porcelain=v2 --branch -z --untracked-files=all`.
    ///
    /// Records end in NUL. A renamed file's record is followed by its original path as a record of its own.
    public static func parse(_ output: Data) -> GitStatus {
        var status = GitStatus()
        var byPath: [String: GitChange] = [:]
        var untracked: Set<String> = []
        let records = output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var i = 0

        /// Splits off the first `count` space-separated fields; the rest is the path, which may contain spaces.
        func fields(_ record: String, _ count: Int) -> ([Substring], String)? {
            let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard parts.count == count + 1 else { return nil }
            return (Array(parts.prefix(count)), String(parts[count]))
        }
        func objectName(_ s: Substring) -> String? { s.allSatisfy { $0 == "0" } ? nil : String(s) }
        func staging(_ xy: Substring) -> GitChange.Staging {
            let x = xy.first ?? ".", y = xy.last ?? "."
            return x == "." ? .none : (y == "." ? .full : .partial)
        }

        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                status.branch = name == "(detached)" ? nil : name
            } else if record.hasPrefix("? ") {
                untracked.insert(String(record.dropFirst(2)))
            } else if record.hasPrefix("1 "), let (f, path) = fields(record, 8) {
                guard f[2].hasPrefix("N") else { continue }
                let x = f[1].first ?? ".", y = f[1].last ?? "."
                let head = objectName(f[6])
                let missing = y == "D" || (x == "D" && y == ".")
                if missing {
                    // Added to the index and deleted again: neither HEAD nor the working copy has it.
                    guard let head else { continue }
                    byPath[path] = GitChange(path: path, kind: .deleted, staging: staging(f[1]), headID: head)
                } else {
                    byPath[path] = GitChange(path: path, kind: head == nil ? .added : .modified, staging: staging(f[1]), headID: head)
                }
            } else if record.hasPrefix("2 "), let (f, path) = fields(record, 9) {
                let original = i < records.count ? records[i] : nil
                i += 1
                guard f[2].hasPrefix("N") else { continue }
                let head = objectName(f[6])
                if f[1].last == "D" {
                    if let original, let head {
                        byPath[original] = GitChange(path: original, kind: .deleted, staging: .partial, headID: head)
                    }
                } else {
                    // A copy keeps its source, so against HEAD it is simply a new file.
                    let renamed = f[8].hasPrefix("R")
                    byPath[path] = GitChange(path: path, originalPath: renamed ? original : nil, kind: renamed ? .renamed : .added,
                                             staging: staging(f[1]), headID: renamed ? head : nil)
                }
            } else if record.hasPrefix("u "), let (f, path) = fields(record, 10) {
                guard f[2].hasPrefix("N") else { continue }
                // Stage 2 is "ours", which is what HEAD holds.
                byPath[path] = GitChange(path: path, kind: .conflicted, headID: objectName(f[8]))
            }
        }
        for path in untracked {
            if var known = byPath[path], known.kind == .deleted {
                // Removed from the index but still on disk: HEAD and the working copy both have it.
                known.kind = .modified
                known.staging = .partial
                byPath[path] = known
            } else if byPath[path] == nil {
                byPath[path] = GitChange(path: path, kind: .untracked)
            }
        }
        status.changes = byPath.values.sorted {
            FolderCompare.pathOrder(FolderEntry(path: $0.path, status: .pending), FolderEntry(path: $1.path, status: .pending))
        }
        return status
    }
}
