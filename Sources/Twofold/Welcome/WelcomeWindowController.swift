import AppKit

/// The start window: a sidebar of pages over the ribbon artwork. It always opens on Compare, ready for
/// files; Recents, Git and What's New are one click away.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    enum Page: String, CaseIterable {
        case compare, recents, git, whatsNew = "whats-new"

        var title: String {
            switch self {
            case .compare: "Compare"
            case .recents: "Recents"
            case .git: "Git"
            case .whatsNew: "What’s New"
            }
        }

        var symbol: String {
            switch self {
            case .compare: "rectangle.split.2x1"
            case .recents: "clock"
            case .git: "arrow.triangle.branch"
            case .whatsNew: "sparkles"
            }
        }
    }

    static let size = NSSize(width: 960, height: 620)
    static let sidebarWidth: CGFloat = 212

    let comparePage = ComparePage()
    let recentsPage = RecentsPage()
    let gitPage = GitPage()
    let whatsNewPage = WhatsNewPage()
    private var items: [Page: SidebarItem] = [:]
    private(set) var page: Page = .compare
    /// Off in snapshot runs, which must not change what the user has seen.
    private let remembersSeen: Bool

    var onCompare: ((URL, URL) -> Void)?
    var onOpenRepository: ((URL?) -> Void)?
    var onOpenRecent: ((RecentComparison) -> Void)?

    init(prefill: URL?, page: Page = .compare, remembersSeen: Bool = true) {
        self.remembersSeen = remembersSeen
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Twofold"
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        let root = WelcomeRootView()
        root.onDrop = { [weak self] urls in self?.dropped(urls) }
        let background = RibbonBackgroundView()
        let sidebar = buildSidebar()
        let container = NSView()
        for v in [background, sidebar, container] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        for p in [comparePage, recentsPage, gitPage, whatsNewPage] as [NSView] {
            p.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: container.topAnchor),
                p.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                p.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                p.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        window.contentView = root

        comparePage.onCompare = { [weak self] a, b in self?.onCompare?(a, b) }
        comparePage.onOpenRepository = { [weak self] in self?.onOpenRepository?(nil) }
        comparePage.onOpenRecent = { [weak self] item in self?.onOpenRecent?(item) }
        comparePage.onShowRecents = { [weak self] in self?.show(.recents) }
        recentsPage.onOpen = { [weak self] item in self?.onOpenRecent?(item) }
        recentsPage.onChange = { [weak self] in self?.reloadRecents() }
        gitPage.onOpenRepository = { [weak self] url in self?.onOpenRepository?(url) }

        comparePage.wellA.url = prefill
        show(page)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildSidebar() -> NSView {
        let sidebar = SidebarView()
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.spacing = 2
        for p in Page.allCases {
            if p == .whatsNew {
                let divider = NSStackView(views: [WelcomeRule()])
                divider.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
                nav.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
            }
            let item = SidebarItem(p, badge: p == .whatsNew ? WhatsNew.version : nil)
            item.action = { [weak self] in self?.show(p) }
            items[p] = item
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }
        items[.whatsNew]?.showsBadge = WhatsNew.isUnseen

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let name = WelcomeText.label(version.map { "Twofold \($0)" } ?? "Twofold", size: 11, weight: .semibold, color: Theme.welcomeSecondary)
        let tagline = WelcomeText.label("Free and open source", size: 11, color: Theme.welcomeTertiary)
        let footer = NSStackView(views: [name, tagline])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 3

        for v in [nav, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
        ])
        return sidebar
    }

    // MARK: Pages

    func show(_ page: Page) {
        self.page = page
        for (p, item) in items { item.isSelected = p == page }
        comparePage.isHidden = page != .compare
        recentsPage.isHidden = page != .recents
        gitPage.isHidden = page != .git
        whatsNewPage.isHidden = page != .whatsNew
        switch page {
        case .compare: comparePage.reloadRecents()
        case .recents: recentsPage.reload()
        case .git:
            gitPage.reloadRepositories()
            // Read again every time: the configuration may have been changed in a terminal meanwhile.
            Task { await gitPage.refresh() }
        case .whatsNew:
            items[.whatsNew]?.showsBadge = false
            if remembersSeen { WhatsNew.markSeen() }
        }
    }

    func reloadRecents() {
        comparePage.reloadRecents()
        recentsPage.reload()
        gitPage.reloadRepositories()
    }

    /// Asks for files on the Compare page.
    func chooseFiles() {
        show(.compare)
        comparePage.chooseFiles()
    }

    private func dropped(_ urls: [URL]) {
        show(.compare)
        comparePage.take(urls)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Something may have been compared, or a file removed, while another window was in front.
        if page != .git { reloadRecents() }
    }
}

/// The window's content: takes files dropped anywhere outside the wells.
@MainActor
private final class WelcomeRootView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropView.urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropView.urls(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// The translucent sidebar, with a hairline on its right edge.
@MainActor
private final class SidebarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.welcomeSidebar.setFill()
        bounds.fill()
        Theme.welcomeSidebarEdge.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// One page in the sidebar: its symbol, its name, and for What's New a version badge until it is seen.
@MainActor
private final class SidebarItem: WelcomeControl {
    private let icon: NSImageView
    private let label: NSTextField
    private let badge: Chip?

    var isSelected = false {
        didSet {
            fill = isSelected ? Theme.welcomeSelection : nil
            hoverFill = isSelected ? Theme.welcomeSelection : Theme.welcomeHover
            icon.contentTintColor = isSelected ? Theme.welcomeLink : Theme.welcomeSecondary
            label.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .medium)
            setAccessibilityValue(isSelected ? "selected" : nil)
        }
    }

    var showsBadge = false { didSet { badge?.isHidden = !showsBadge } }

    init(_ page: WelcomeWindowController.Page, badge text: String?) {
        icon = WelcomeText.symbol(page.symbol, size: 13.5, color: Theme.welcomeSecondary)
        label = WelcomeText.label(page.title, size: 13, weight: .medium)
        badge = text.map { Chip($0, color: Theme.welcomeButtonText, background: Theme.accent) }
        super.init(frame: .zero)
        hoverFill = Theme.welcomeHover
        radius = 8
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        var views: [NSView] = [icon, label, NSView()]
        if let badge {
            badge.isHidden = true
            views.append(badge)
        }
        let row = NSStackView(views: views)
        row.spacing = 9
        embed(row, insets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8))
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        setAccessibilityLabel(page.title)
    }

    required init?(coder: NSCoder) { fatalError() }
}
