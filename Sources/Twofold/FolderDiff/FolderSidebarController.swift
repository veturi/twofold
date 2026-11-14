import AppKit
import DiffCore

/// The folder comparison sidebar: changed files grouped under directory headings.
@MainActor
final class FolderSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case heading(String)
        case file(Int)
    }

    enum Filter: CaseIterable {
        case modified, added, removed, identical

        var status: FolderEntry.Status {
            switch self {
            case .modified: .different
            case .added: .onlyRight
            case .removed: .onlyLeft
            case .identical: .identical
            }
        }

        var tip: String {
            switch self {
            case .modified: "Show Modified Files"
            case .added: "Show Added Files"
            case .removed: "Show Removed Files"
            case .identical: "Show Identical Files"
            }
        }
    }

    private(set) var entries: [FolderEntry] = []
    private var rows: [Row] = []
    private var filters: Set<Filter> = [.modified, .added, .removed]
    private var finished = false
    private(set) var selectedPath: String?
    private var suppressSelection = false

    private let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "Comparing…")
    private let countsLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private var filterButtons: [Filter: NSButton] = [:]

    var onSelect: ((FolderEntry?) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 600))
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = Theme.secondaryText
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text
        countsLabel.font = .systemFont(ofSize: 11)
        countsLabel.textColor = Theme.secondaryText
        let titleRow = NSStackView(views: [icon, titleLabel])
        titleRow.spacing = 6
        let header = NSStackView(views: [titleRow, countsLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.floatsGroupRows = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        searchField.placeholderString = "Filter File Name"
        searchField.delegate = self
        searchField.controlSize = .regular
        searchField.font = .systemFont(ofSize: 12)
        var buttons: [NSView] = []
        for f in Filter.allCases {
            let b = NSButton(image: Icons.statusTile(f.status, size: 16), target: self, action: #selector(toggleFilter(_:)))
            b.isBordered = false
            b.toolTip = f.tip
            b.tag = Filter.allCases.firstIndex(of: f)!
            filterButtons[f] = b
            buttons.append(b)
        }
        let toggles = NSStackView(views: buttons)
        toggles.spacing = 3
        let footer = NSStackView(views: [searchField, toggles])
        footer.spacing = 8

        for v in [header, scroll, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        updateFilterButtons()
    }

    // MARK: Data

    func reset(keeping path: String? = nil) {
        entries = []
        finished = false
        selectedPath = path
        rebuildRows()
        updateHeader()
    }

    func setEntries(_ e: [FolderEntry]) {
        entries = e
        rebuildRows()
        updateHeader()
    }

    func apply(_ updates: [(Int, FolderEntry.Status)]) {
        for (i, s) in updates where i < entries.count { entries[i].status = s }
        rebuildRows()
        updateHeader()
    }

    func finish() {
        finished = true
        updateHeader()
        if selectedPath == nil && !rows.contains(where: { if case .file = $0 { true } else { false } }) {
            onSelect?(nil)
        }
    }

    private func count(_ s: FolderEntry.Status) -> Int {
        entries.reduce(0) { $0 + ($1.status == s ? 1 : 0) }
    }

    private func updateHeader() {
        let modified = count(.different), added = count(.onlyRight), removed = count(.onlyLeft)
        let identical = count(.identical), pending = count(.pending)
        let changed = modified + added + removed
        titleLabel.stringValue = "\(changed) Changed File\(changed == 1 ? "" : "s")"
        var parts = ["✎ \(modified)", "+ \(added)", "− \(removed)", "= \(identical)"]
        if !finished || pending > 0 { parts.append("comparing…") }
        countsLabel.stringValue = parts.joined(separator: "   ")
    }

    private func rebuildRows() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = Set(filters.map(\.status))
        var out: [Row] = []
        var lastDir: String?
        for (i, e) in entries.enumerated() where shown.contains(e.status) {
            if !query.isEmpty && !e.path.lowercased().contains(query) { continue }
            let dir = e.directory
            if dir != lastDir {
                if !dir.isEmpty { out.append(.heading(dir)) }
                lastDir = dir
            }
            out.append(.file(i))
        }
        rows = out
        suppressSelection = true
        table.reloadData()
        if let path = selectedPath, let r = rowIndex(of: path) {
            table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        suppressSelection = false
        if selectedPath == nil, let first = rows.firstIndex(where: { if case .file = $0 { true } else { false } }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
    }

    private func rowIndex(of path: String) -> Int? {
        rows.firstIndex { if case .file(let i) = $0 { entries[i].path == path } else { false } }
    }

    // MARK: Actions

    @objc private func toggleFilter(_ sender: NSButton) {
        let f = Filter.allCases[sender.tag]
        if filters.contains(f) { filters.remove(f) } else { filters.insert(f) }
        updateFilterButtons()
        rebuildRows()
    }

    private func updateFilterButtons() {
        for (f, b) in filterButtons { b.alphaValue = filters.contains(f) ? 1 : 0.3 }
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildRows()
    }

    func selectNext(_ delta: Int) {
        let fileRows = rows.indices.filter { if case .file = rows[$0] { true } else { false } }
        guard !fileRows.isEmpty else { return }
        let current = fileRows.firstIndex(of: table.selectedRow) ?? (delta > 0 ? -1 : fileRows.count)
        let next = min(max(current + delta, 0), fileRows.count - 1)
        table.selectRowIndexes(IndexSet(integer: fileRows[next]), byExtendingSelection: false)
        table.scrollRowToVisible(fileRows[next])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = rows[row] { return 28 }
        return 30
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let dir):
            let id = NSUserInterfaceItemIdentifier("heading")
            let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let l = NSTextField(labelWithString: "")
                l.identifier = id
                l.font = .systemFont(ofSize: 11, weight: .medium)
                l.textColor = Theme.secondaryText
                l.lineBreakMode = .byTruncatingHead
                return l
            }()
            label.stringValue = "    " + dir.split(separator: "/").joined(separator: " ⟩ ")
            return label
        case .file(let i):
            let id = NSUserInterfaceItemIdentifier("file")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeFileCell(id)
            cell.imageView?.image = Icons.statusTile(entries[i].status)
            cell.textField?.stringValue = entries[i].name
            cell.toolTip = entries[i].path
            return cell
        }
    }

    private func makeFileCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingMiddle
        text.textColor = .labelColor
        for v in [image, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = table.selectedRow
        guard row >= 0, case .file(let i) = rows[row] else { return }
        guard entries[i].path != selectedPath else { return }
        selectedPath = entries[i].path
        onSelect?(entries[i])
    }
}

/// Row view with a rounded accent selection and no group-row background.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 10, dy: 2)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }
}
