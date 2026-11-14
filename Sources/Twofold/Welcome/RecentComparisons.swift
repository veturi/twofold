import AppKit

/// One previously opened comparison.
struct RecentComparison: Equatable {
    var left: String
    var right: String
    var isFolder: Bool
    var date: Date

    var leftURL: URL { URL(fileURLWithPath: left) }
    var rightURL: URL { URL(fileURLWithPath: right) }

    var exists: Bool {
        FileManager.default.fileExists(atPath: left) && FileManager.default.fileExists(atPath: right)
    }
}

/// The last few comparisons, newest first, kept in user defaults as plain property lists.
@MainActor
enum RecentComparisons {
    static let key = "recentComparisons"
    static let limit = 5

    static var all: [RecentComparison] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let l = d["left"] as? String, let r = d["right"] as? String else { return nil }
            return RecentComparison(left: l, right: r, isFolder: d["folder"] as? Bool ?? false,
                                    date: d["date"] as? Date ?? .distantPast)
        }
    }

    /// Recent comparisons whose files or folders still exist.
    static var available: [RecentComparison] {
        all.filter(\.exists)
    }

    static func add(left: URL, right: URL, isFolder: Bool) {
        var list = all.filter { !($0.left == left.path && $0.right == right.path) }
        list.insert(RecentComparison(left: left.path, right: right.path, isFolder: isFolder, date: Date()), at: 0)
        save(Array(list.prefix(limit)))
    }

    static func clear() {
        save([])
    }

    private static func save(_ list: [RecentComparison]) {
        UserDefaults.standard.set(list.map {
            ["left": $0.left, "right": $0.right, "folder": $0.isFolder, "date": $0.date] as [String: Any]
        }, forKey: key)
    }
}

/// A clickable row in the start window's Recent list.
@MainActor
final class RecentRow: NSView {
    private let item: RecentComparison
    private let action: (RecentComparison) -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ item: RecentComparison, action: @escaping (RecentComparison) -> Void) {
        self.item = item
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        toolTip = "\(item.left)\n\(item.right)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Compare \(title)")
    }

    required init?(coder: NSCoder) { fatalError() }

    private var title: String {
        let a = item.leftURL.lastPathComponent, b = item.rightURL.lastPathComponent
        return a == b ? a : "\(a)  ↔  \(b)"
    }

    /// The folder each side lives in, reduced to the path components that differ between them.
    private var subtitle: String {
        let a = item.leftURL.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        let b = item.rightURL.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        var p = 0
        while p < min(a.count, b.count) && a[p] == b[p] { p += 1 }
        var s = 0
        while s < min(a.count, b.count) - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let da = a[p..<(a.count - s)].joined(separator: "/")
        let db = b[p..<(b.count - s)].joined(separator: "/")
        if da.isEmpty && db.isEmpty { return a.suffix(2).joined(separator: "/") }
        return "\(da.isEmpty ? "…" : da)  ↔  \(db.isEmpty ? "…" : db)"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(item) }
    }
    override func accessibilityPerformPress() -> Bool { action(item); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.accentSoft.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let icon = item.isFolder
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(forFile: item.left)
        icon.draw(in: CGRect(x: 10, y: bounds.midY - 14, width: 28, height: 28))

        let date = RelativeDateTimeFormatter().localizedString(for: item.date, relativeTo: Date())
        let dateAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText]
        let dateString = NSAttributedString(string: date, attributes: dateAttrs)
        let dateWidth = dateString.size().width
        dateString.draw(at: CGPoint(x: bounds.maxX - 12 - dateWidth, y: bounds.midY - 7))

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let textWidth = bounds.width - 50 - dateWidth - 28
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text, .paragraphStyle: para,
        ]).draw(in: CGRect(x: 48, y: bounds.midY, width: textWidth, height: 18))
        NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText, .paragraphStyle: para,
        ]).draw(in: CGRect(x: 48, y: bounds.midY - 16, width: textWidth, height: 15))
    }
}
