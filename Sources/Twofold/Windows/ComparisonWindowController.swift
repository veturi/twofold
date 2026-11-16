import AppKit
import DiffCore

extension NSToolbarItem.Identifier {
    static let layoutMode = NSToolbarItem.Identifier("layoutMode")
}

/// One window per comparison: either two files, or two folders with a sidebar.
@MainActor
final class ComparisonWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    enum Kind { case files, folders }

    private(set) var left: URL
    private(set) var right: URL
    let kind: Kind
    let diffVC = DiffViewController()
    private(set) var sidebar: FolderSidebarController?
    private var folderTask: Task<Void, Never>?
    private var folderBusy = false
    private var layoutGroup: NSToolbarItemGroup?
    private var selectedEntry: FolderEntry?
    var initialSelection: String?

    var onClose: ((ComparisonWindowController) -> Void)?
    var onDrop: (([URL]) -> Void)?

    var isBusy: Bool { folderBusy || diffVC.isLoading }

    init(left: URL, right: URL, kind: Kind) {
        self.left = left
        self.right = right
        self.kind = kind
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = Theme.chrome
        window.minSize = NSSize(width: 720, height: 420)
        window.isRestorable = false
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self

        diffVC.onSummaryChange = { [weak self] in self?.updateTitle() }
        diffVC.onDrop = { [weak self] urls in self?.onDrop?(urls) }

        switch kind {
        case .files:
            window.contentViewController = diffVC
        case .folders:
            let sidebar = FolderSidebarController()
            sidebar.onSelect = { [weak self] entry in self?.select(entry) }
            self.sidebar = sidebar
            let split = NSSplitViewController()
            let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
            sideItem.minimumThickness = 220
            sideItem.maximumThickness = 460
            sideItem.canCollapse = true
            split.addSplitViewItem(sideItem)
            let detail = NSSplitViewItem(viewController: diffVC)
            detail.minimumThickness = 500
            split.addSplitViewItem(detail)
            window.contentViewController = split
        }
        window.setContentSize(NSSize(width: 1360, height: 860))

        let toolbar = NSToolbar(identifier: kind == .folders ? "FolderToolbar" : "FileToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        switch kind {
        case .files: diffVC.load(left: left, right: right)
        case .folders: scanFolders(keeping: initialSelection)
        }
    }

    // MARK: Folders

    private func scanFolders(keeping path: String? = nil) {
        folderTask?.cancel()
        folderBusy = true
        selectedEntry = nil
        sidebar?.reset(keeping: path)
        let l = left, r = right
        folderTask = Task { [weak self] in
            let entries = await FolderCompare.list(left: l, right: r)
            guard !Task.isCancelled, let self else { return }
            self.sidebar?.setEntries(entries)
            if let path, let entry = entries.first(where: { $0.path == path }) { self.select(entry) }
            await FolderCompare.resolve(entries: entries, left: l, right: r) { [weak self] updates in
                await MainActor.run { self?.sidebar?.apply(updates) }
            }
            guard !Task.isCancelled else { return }
            self.folderBusy = false
            self.sidebar?.finish()
            self.updateTitle()
        }
    }

    private func select(_ entry: FolderEntry?) {
        selectedEntry = entry
        guard let entry else {
            diffVC.clear(title: "No differences", subtitle: "Every file in both folders is identical.", symbol: "checkmark.circle")
            updateTitle()
            return
        }
        let l = entry.status == .onlyRight ? nil : left.appendingPathComponent(entry.path)
        let r = entry.status == .onlyLeft ? nil : right.appendingPathComponent(entry.path)
        diffVC.load(left: l, right: r)
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        window.title = "\(left.lastPathComponent) | \(right.lastPathComponent)"
        switch kind {
        case .files:
            window.subtitle = diffVC.summary
        case .folders:
            if let e = selectedEntry {
                window.subtitle = diffVC.summary.isEmpty ? e.name : "\(e.name) – \(diffVC.summary)"
            } else {
                window.subtitle = folderBusy ? "Comparing…" : ""
            }
        }
        // Blocks and Fluid are text layouts; images have their own modes in the bottom bar.
        layoutGroup?.isEnabled = !diffVC.showsImage
    }

    // MARK: Preferences

    @objc private func preferencesChanged() {
        diffVC.applyPreferences()
        layoutGroup?.selectedIndex = Preferences.shared.layout == .blocks ? 0 : 1
    }

    @objc private func layoutGroupChanged(_ sender: NSToolbarItemGroup) {
        Preferences.shared.layout = sender.selectedIndex == 0 ? .blocks : .fluid
    }

    // MARK: Actions

    @objc func nextChange(_ sender: Any?) { diffVC.canvas.nextChange() }
    @objc func previousChange(_ sender: Any?) { diffVC.canvas.previousChange() }
    @objc func nextFile(_ sender: Any?) { sidebar?.selectNext(1) }
    @objc func previousFile(_ sender: Any?) { sidebar?.selectNext(-1) }

    @objc func toggleExpandAll(_ sender: Any?) {
        diffVC.canvas.expandAll.toggle()
        diffVC.applyPreferences()
    }

    // Text size and image zoom share ⌘+, ⌘- and ⌘0. This controller sits before the app delegate
    // in the responder chain, so it takes the image case and passes the rest on to preferences.
    @objc func biggerText(_ sender: Any?) {
        if diffVC.showsImage { diffVC.imageView.zoomIn(sender) } else { Preferences.shared.fontSize += 1 }
    }

    @objc func smallerText(_ sender: Any?) {
        if diffVC.showsImage { diffVC.imageView.zoomOut(sender) } else { Preferences.shared.fontSize -= 1 }
    }

    @objc func actualSizeText(_ sender: Any?) {
        if diffVC.showsImage { diffVC.imageView.zoomToActualSize(sender) } else { Preferences.shared.fontSize = Preferences.defaultFontSize }
    }

    @objc func zoomImageToFit(_ sender: Any?) { diffVC.imageView.zoomToFit(sender) }

    @objc func reload(_ sender: Any?) {
        switch kind {
        case .files: diffVC.reload()
        case .folders:
            scanFolders(keeping: sidebar?.selectedPath)
        }
    }

    @objc func swapSides(_ sender: Any?) {
        swap(&left, &right)
        updateTitle()
        switch kind {
        case .files: diffVC.load(left: left, right: right)
        case .folders: scanFolders(keeping: sidebar?.selectedPath)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextChange(_:)):
            return (diffVC.canvas.currentChange ?? -1) < diffVC.canvas.changeCount - 1
        case #selector(previousChange(_:)):
            return (diffVC.canvas.currentChange ?? 0) > 0
        case #selector(zoomImageToFit(_:)):
            return diffVC.showsImage
        case #selector(nextFile(_:)), #selector(previousFile(_:)):
            return kind == .folders
        case #selector(toggleExpandAll(_:)):
            item.state = diffVC.canvas.expandAll ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        folderTask?.cancel()
        diffVC.stopWatching()
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        kind == .folders
            ? [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .layoutMode]
            : [.flexibleSpace, .layoutMode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .layoutMode else { return nil }
        let group = NSToolbarItemGroup(
            itemIdentifier: id, images: [Icons.blocksLayout, Icons.fluidLayout], selectionMode: .selectOne,
            labels: ["Blocks", "Fluid"], target: self, action: #selector(layoutGroupChanged(_:)))
        group.label = "Layout"
        group.toolTip = "Layout"
        group.selectedIndex = Preferences.shared.layout == .blocks ? 0 : 1
        group.autovalidates = false
        group.isEnabled = !diffVC.showsImage
        layoutGroup = group
        return group
    }
}
