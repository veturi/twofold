import AppKit
import UniformTypeIdentifiers

/// One previously opened comparison, or a repository whose working copy changes were opened.
struct RecentComparison: Equatable {
    enum Kind: String {
        case files, folders, repository
    }

    var left: String
    /// For a repository, the same as `left`.
    var right: String
    var kind: Kind
    var date: Date

    var leftURL: URL { URL(fileURLWithPath: left) }
    var rightURL: URL { URL(fileURLWithPath: right) }
    var isFolder: Bool { kind != .files }

    var exists: Bool {
        FileManager.default.fileExists(atPath: left) && FileManager.default.fileExists(atPath: right)
    }

    var isImage: Bool {
        kind == .files && (UTType(filenameExtension: leftURL.pathExtension)?.conforms(to: .image) ?? false)
    }

    /// The name shown for the comparison: one name when both sides share it.
    var title: String {
        let a = leftURL.lastPathComponent, b = rightURL.lastPathComponent
        return kind == .repository || a == b ? a : "\(a) ↔ \(b)"
    }

    /// The folder each side lives in, reduced to the path components that differ between them.
    var locations: String {
        if kind == .repository { return (left as NSString).abbreviatingWithTildeInPath }
        let a = leftURL.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        let b = rightURL.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        var p = 0
        while p < min(a.count, b.count) && a[p] == b[p] { p += 1 }
        var s = 0
        while s < min(a.count, b.count) - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let da = a[p..<(a.count - s)].joined(separator: "/")
        let db = b[p..<(b.count - s)].joined(separator: "/")
        if da.isEmpty && db.isEmpty { return a.suffix(2).joined(separator: "/") }
        return "\(da.isEmpty ? "…" : da) ↔ \(db.isEmpty ? "…" : db)"
    }

    /// The name of the kind, as the tag in the Recents list says it.
    var kindName: String {
        switch kind {
        case .repository: "Repository"
        case .folders: "Folders"
        case .files: isImage ? "Images" : "Files"
        }
    }

    var symbol: String {
        switch kind {
        case .repository: "arrow.triangle.branch"
        case .folders: "folder"
        case .files: isImage ? "photo" : "doc.text"
        }
    }

    @MainActor var tint: NSColor {
        switch kind {
        case .repository: Theme.welcomeLink
        case .folders: Theme.added.marker
        case .files: isImage ? Theme.removed.marker : Theme.modified.marker
        }
    }
}

/// Recent comparisons and repositories, newest first, kept in user defaults as plain property lists.
@MainActor
enum RecentComparisons {
    static let key = "recentComparisons"
    static let limit = 30

    static var all: [RecentComparison] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let l = d["left"] as? String, let r = d["right"] as? String else { return nil }
            // Entries written before kinds existed only say whether they were folders.
            let kind = (d["kind"] as? String).flatMap(RecentComparison.Kind.init)
                ?? ((d["folder"] as? Bool ?? false) ? .folders : .files)
            return RecentComparison(left: l, right: r, kind: kind, date: d["date"] as? Date ?? .distantPast)
        }
    }

    /// Recent entries whose files or folders still exist.
    static var available: [RecentComparison] {
        all.filter(\.exists)
    }

    static func add(left: URL, right: URL, kind: RecentComparison.Kind) {
        var list = all.filter { !($0.left == left.path && $0.right == right.path) }
        list.insert(RecentComparison(left: left.path, right: right.path, kind: kind, date: Date()), at: 0)
        save(Array(list.prefix(limit)))
    }

    static func remove(_ item: RecentComparison) {
        save(all.filter { !($0.left == item.left && $0.right == item.right) })
    }

    static func clear() {
        save([])
    }

    private static func save(_ list: [RecentComparison]) {
        UserDefaults.standard.set(list.map {
            ["left": $0.left, "right": $0.right, "kind": $0.kind.rawValue, "folder": $0.isFolder, "date": $0.date] as [String: Any]
        }, forKey: key)
    }

    /// "2 h ago" for today, "Yesterday", the weekday within a week, else the date.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return now.timeIntervalSince(date) < 60 ? "Just now" : f.localizedString(for: date, relativeTo: now)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            f.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return f.string(from: date)
    }
}
