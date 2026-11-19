import AppKit

/// Everything compared, newest first, grouped into Today, Yesterday and Earlier.
@MainActor
final class RecentsPage: NSView, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let list = NSStackView()
    private let empty = WelcomeText.label("", size: 13, color: Theme.welcomeTertiary)
    private let scroll = NSScrollView()
    var onOpen: ((RecentComparison) -> Void)?
    /// Called after the list changed here, so other pages can show the same.
    var onChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = WelcomeText.title("Recents")
        let subtitle = WelcomeText.label("Everything you compared, newest first.", size: 12.5, color: Theme.welcomeSecondary)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4

        search.placeholderString = "Filter"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let clear = WelcomeLink("Clear…", size: 12.5) { [weak self] in self?.confirmClear() }
        let tools = NSStackView(views: [search, clear])
        tools.spacing = 12
        let header = NSStackView(views: [heading, NSView(), tools])
        header.alignment = .centerY

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let panel = WelcomePanel()
        panel.addSubview(scroll)
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(empty)

        let stack = NSStackView(views: [header, panel])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -1),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func focusFilter() { window?.makeFirstResponder(search) }

    func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let items = RecentComparisons.available.filter {
            query.isEmpty || $0.left.localizedCaseInsensitiveContains(query) || $0.right.localizedCaseInsensitiveContains(query)
        }
        let calendar = Calendar.current
        var group = ""
        for item in items {
            let name = calendar.isDateInToday(item.date) ? "Today" : calendar.isDateInYesterday(item.date) ? "Yesterday" : "Earlier"
            if name != group {
                group = name
                let label = WelcomeText.section(name)
                let holder = NSStackView(views: [label])
                holder.edgeInsets = NSEdgeInsets(top: list.arrangedSubviews.isEmpty ? 6 : 12, left: 12, bottom: 4, right: 12)
                list.addArrangedSubview(holder)
            }
            let row = RecentRow(item)
            row.action = { [weak self] in self?.onOpen?(item) }
            row.onRemove = { [weak self] in
                RecentComparisons.remove(item)
                self?.reload()
                self?.onChange?()
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
        }
        empty.stringValue = query.isEmpty ? "Comparisons you open show up here." : "Nothing matches “\(query)”."
        empty.isHidden = !items.isEmpty
    }

    private func confirmClear() {
        guard let window, !RecentComparisons.all.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the list of recent comparisons?"
        alert.informativeText = "The files and folders themselves are not touched."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                RecentComparisons.clear()
                self?.reload()
                self?.onChange?()
            }
        }
    }
}

/// One row of the Recents list. Hovering swaps the kind tag for Show in Finder and Remove.
@MainActor
final class RecentRow: WelcomeControl {
    private let item: RecentComparison
    private let kindTag: Chip
    private let buttons: NSStackView
    var onRemove: (() -> Void)?

    init(_ item: RecentComparison) {
        self.item = item
        kindTag = Chip(item.kindName)
        buttons = NSStackView()
        super.init(frame: .zero)
        hoverFill = Theme.welcomeCard
        radius = 9

        let names: NSView
        if item.kind == .repository {
            names = WelcomeText.label(item.title, size: 13, weight: .semibold)
        } else {
            let a = WelcomeText.label(item.leftURL.lastPathComponent, size: 13, weight: .semibold)
            let b = WelcomeText.label(item.rightURL.lastPathComponent, size: 13, weight: .semibold)
            names = NSStackView(views: [a, WelcomeText.symbol("arrow.left.arrow.right", size: 9.5, color: Theme.welcomeTertiary), b])
            (names as? NSStackView)?.spacing = 6
        }
        let paths = item.kind == .repository ? (item.left as NSString).abbreviatingWithTildeInPath
            : "\((item.leftURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) · \((item.rightURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)"
        let detail = WelcomeText.label(paths, size: 11, color: Theme.welcomeTertiary)
        let text = NSStackView(views: [names, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let reveal = RowButton(symbol: "folder", label: "Show in Finder") { [weak self] in self?.revealInFinder() }
        let remove = RowButton(symbol: "xmark", label: "Remove from Recents") { [weak self] in self?.onRemove?() }
        buttons.setViews([reveal, remove], in: .leading)
        buttons.spacing = 6
        buttons.isHidden = true

        let date = WelcomeText.label(RecentComparisons.when(item.date), size: 11.5, color: Theme.welcomeTertiary)
        date.alignment = .right
        date.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let row = NSStackView(views: [IconTile(symbol: item.symbol, tint: item.tint), text, NSView(), kindTag, buttons, date])
        row.spacing = 12
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        embed(row, insets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12))
        heightAnchor.constraint(equalToConstant: 52).isActive = true
        toolTip = item.kind == .repository ? item.left : "\(item.left)\n\(item.right)"
        setAccessibilityLabel("Open \(item.title)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hoverChanged() {
        kindTag.isHidden = hovering
        buttons.isHidden = !hovering
    }

    private func revealInFinder() {
        let urls = item.kind == .repository ? [item.leftURL] : [item.leftURL, item.rightURL]
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private final class RowButton: WelcomeControl {
        init(symbol: String, label: String, action: @escaping () -> Void) {
            super.init(frame: .zero)
            self.action = action
            fill = Theme.welcomeChip
            hoverFill = Theme.welcomeSelection
            radius = 7
            embed(WelcomeText.symbol(symbol, size: 11, color: Theme.welcomeSecondary), insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
            widthAnchor.constraint(equalToConstant: 26).isActive = true
            heightAnchor.constraint(equalToConstant: 26).isActive = true
            toolTip = label
            setAccessibilityLabel(label)
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}
