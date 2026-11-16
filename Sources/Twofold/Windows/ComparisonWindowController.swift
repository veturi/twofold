import AppKit
import DiffCore

extension NSToolbarItem.Identifier {
    static let layoutMode = NSToolbarItem.Identifier("layoutMode")
    static let pauseUpdates = NSToolbarItem.Identifier("pauseUpdates")
}

/// One window per comparison: two files, two folders with a sidebar, or a Git working copy against
/// its last commit, which has the same sidebar and keeps itself up to date.
@MainActor
final class ComparisonWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    enum Kind { case files, folders, changes }

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

    // A working copy's changes (`kind == .changes`).
    let workingCopy: WorkingCopy?
    private var changes: [String: GitChange] = [:]
    /// The change the diff view was last loaded for, to tell when it needs loading again.
    private var shownChange: GitChange?
    private var branch: String?
    private var repoWatcher: FolderWatcher?
    /// Where committed versions of files are written for the left side.
    private var headFolder: URL?
    private var refreshing = false
    private var refreshWanted = false
    private var pendingShows = 0
    private var showGeneration = 0
    private var showsNoChanges = false
    private(set) var isPaused = false
    private var pauseItem: NSToolbarItem?

    var onClose: ((ComparisonWindowController) -> Void)?
    var onDrop: (([URL]) -> Void)?

    var isBusy: Bool { folderBusy || refreshing || pendingShows > 0 || diffVC.isLoading }

    init(left: URL, right: URL, kind: Kind, workingCopy: WorkingCopy? = nil) {
        self.left = left
        self.right = right
        self.kind = kind
        self.workingCopy = workingCopy
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
        diffVC.onDrop = { [weak self] urls in
            // A drop replaces this comparison, so settle unsaved changes first.
            self?.diffVC.confirmUnsavedChanges { self?.onDrop?(urls) }
        }
        diffVC.onEditStateChange = { [weak self] in
            self?.window?.isDocumentEdited = self?.diffVC.hasUnsavedChanges ?? false
        }
        diffVC.onSave = { [weak self] in self?.updateSavedStatus() }

        switch kind {
        case .files:
            window.contentViewController = diffVC
        case .folders, .changes:
            let sidebar = FolderSidebarController()
            if kind == .changes {
                sidebar.showsIdentical = false
                // The committed version is only shown; edits go to the working copy.
                diffVC.lockedSides = [.left]
                diffVC.pathBar.titles = ("HEAD", "Working Copy")
                diffVC.pathBar.swapButton.isHidden = true
            }
            diffVC.hasNeighbourFile = { [weak sidebar] delta in sidebar?.hasNeighbour(delta) ?? false }
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

        let toolbar = NSToolbar(identifier: kind == .folders ? "FolderToolbar" : (kind == .changes ? "ChangesToolbar" : "FileToolbar"))
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
        case .changes: startChanges()
        }
    }

    // MARK: Working copy

    private func startChanges() {
        guard let workingCopy else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Twofold-HEAD-\(UUID().uuidString)", isDirectory: true)
        headFolder = folder
        diffVC.pathBar.roots = (folder, workingCopy.root)
        repoWatcher = FolderWatcher(folder: workingCopy.root) { [weak self] in self?.workingCopyChanged() }
        folderBusy = true
        sidebar?.reset(keeping: initialSelection)
        refreshChanges()
    }

    /// Something below the repository changed: a file, the index, or what HEAD points at.
    private func workingCopyChanged() {
        if isPaused { refreshWanted = true } else { refreshChanges() }
    }

    private func refreshChanges() {
        guard let workingCopy else { return }
        // One status at a time; changes that arrive meanwhile are picked up by one more run afterwards.
        if refreshing {
            refreshWanted = true
            return
        }
        refreshing = true
        Task { [weak self] in
            let result = await Self.readStatus(workingCopy)
            guard let self, self.window != nil else { return }
            self.refreshing = false
            self.apply(result)
            if self.refreshWanted && !self.isPaused {
                self.refreshWanted = false
                self.refreshChanges()
            }
        }
    }

    @concurrent
    private static func readStatus(_ workingCopy: WorkingCopy) async -> Result<GitStatus, WorkingCopy.Failure> {
        do {
            return .success(try workingCopy.status())
        } catch {
            return .failure(error)
        }
    }

    @concurrent
    private static func headFile(_ workingCopy: WorkingCopy, _ change: GitChange, _ folder: URL) async -> URL? {
        workingCopy.headFile(for: change, in: folder)
    }

    private func apply(_ result: Result<GitStatus, WorkingCopy.Failure>) {
        folderBusy = false
        switch result {
        case .failure(let failure):
            if changes.isEmpty {
                selectedEntry = nil
                shownChange = nil
                showsNoChanges = false
                diffVC.clear(title: "Could not read the repository", subtitle: failure.message, symbol: "exclamationmark.triangle")
            }
        case .success(let status):
            branch = status.branch
            changes = Dictionary(status.changes.map { ($0.path, $0) }) { first, _ in first }
            var marks: [String: FolderSidebarController.Mark] = [:]
            let entries = status.changes.map { change -> FolderEntry in
                switch (change.kind, change.staging) {
                case (.untracked, _): marks[change.path] = .init(symbol: "questionmark.circle", tip: "Untracked")
                case (.conflicted, _): marks[change.path] = .init(symbol: "exclamationmark.triangle.fill", tip: "Unmerged")
                case (_, .full): marks[change.path] = .init(symbol: "checkmark.circle.fill", tip: "Staged")
                case (_, .partial): marks[change.path] = .init(symbol: "circle.lefthalf.filled", tip: "Partly staged")
                case (_, .none): break
                }
                let status: FolderEntry.Status
                switch change.kind {
                case .added, .untracked: status = .onlyRight
                case .deleted: status = .onlyLeft
                case .modified, .renamed, .conflicted: status = .different
                }
                return FolderEntry(path: change.path, status: status)
            }
            // A file being edited here stays open even if it has left the list.
            sidebar?.update(entries, marks: marks, keepSelection: diffVC.hasUnsavedChanges)
            sidebar?.finish()
            // A file named before the list arrived is selected in the sidebar without being reported.
            if selectedEntry == nil, let path = sidebar?.selectedPath, let entry = entries.first(where: { $0.path == path }) {
                show(entry)
            }
            // The selected file is still listed, but what it is compared against has changed: a commit,
            // a checkout, or the file itself appearing or disappearing.
            if let entry = selectedEntry, let now = changes[entry.path], let shown = shownChange, !diffVC.hasUnsavedChanges,
               (now.kind, now.headID, now.originalPath) != (shown.kind, shown.headID, shown.originalPath),
               let fresh = entries.first(where: { $0.path == entry.path }) {
                show(fresh, keepScroll: true)
            }
        }
        updateTitle()
    }

    private func showChange(_ entry: FolderEntry?, keepScroll: Bool) {
        guard let entry, let change = changes[entry.path], let workingCopy, let headFolder else {
            shownChange = nil
            showGeneration += 1
            guard !showsNoChanges else { return }
            showsNoChanges = true
            diffVC.clear(title: "No changes", subtitle: "The working copy matches the last commit.", symbol: "checkmark.circle")
            return
        }
        showsNoChanges = false
        shownChange = change
        showGeneration += 1
        let generation = showGeneration
        pendingShows += 1
        Task { [weak self] in
            let committed = await Self.headFile(workingCopy, change, headFolder)
            guard let self else { return }
            self.pendingShows -= 1
            guard generation == self.showGeneration, self.window != nil else { return }
            self.diffVC.load(left: committed, right: change.isInWorkingCopy ? workingCopy.root.appendingPathComponent(change.path) : nil,
                             keepScroll: keepScroll)
            self.updateTitle()
        }
    }

    /// Stops watching the repository and removes the committed versions written for the left side.
    /// Called when the window closes and when the app quits, which closes no windows.
    func cleanUp() {
        repoWatcher?.invalidate()
        repoWatcher = nil
        if let headFolder { try? FileManager.default.removeItem(at: headFolder) }
        headFolder = nil
    }

    @objc func togglePause(_ sender: Any?) {
        guard kind == .changes else { return }
        isPaused.toggle()
        diffVC.isPaused = isPaused
        pauseItem?.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        pauseItem?.label = isPaused ? "Resume Updates" : "Pause Updates"
        pauseItem?.toolTip = isPaused ? "Resume Updates" : "Pause Updates: keep showing this state while files change"
        if !isPaused && refreshWanted {
            refreshWanted = false
            refreshChanges()
        }
        updateTitle()
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
        // The sidebar has already moved; if the user backs out, move it back.
        let previous = selectedEntry?.path
        diffVC.confirmUnsavedChanges(cancel: { [weak self] in self?.sidebar?.restoreSelection(previous) }) { [weak self] in
            self?.show(entry)
        }
    }

    /// After a save in a folder comparison, the file may have become identical to its counterpart.
    private func updateSavedStatus() {
        guard kind == .folders, let entry = selectedEntry, entry.status == .different || entry.status == .identical else { return }
        let same = FolderCompare.contentsEqual(left.appendingPathComponent(entry.path), right.appendingPathComponent(entry.path))
        selectedEntry?.status = same ? .identical : .different
        sidebar?.setStatus(same ? .identical : .different, forPath: entry.path)
    }

    private func show(_ entry: FolderEntry?, keepScroll: Bool = false) {
        selectedEntry = entry
        if kind == .changes {
            showChange(entry, keepScroll: keepScroll)
            updateTitle()
            return
        }
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
        case .changes:
            window.title = "\(workingCopy?.name ?? left.lastPathComponent) — \(branch ?? "detached HEAD")"
            let paused = isPaused ? "Updates paused" : ""
            if let e = selectedEntry {
                window.subtitle = ([paused.isEmpty ? nil : paused, e.name, diffVC.summary.isEmpty ? nil : diffVC.summary] as [String?])
                    .compactMap { $0 }.joined(separator: " – ")
            } else {
                window.subtitle = folderBusy ? "Reading changes…" : (paused.isEmpty ? "Working copy changes" : paused)
            }
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
        layoutGroup?.selectedIndex = LayoutMode.allCases.firstIndex(of: Preferences.shared.layout) ?? 1
    }

    @objc private func layoutGroupChanged(_ sender: NSToolbarItemGroup) {
        guard LayoutMode.allCases.indices.contains(sender.selectedIndex) else { return }
        Preferences.shared.layout = LayoutMode.allCases[sender.selectedIndex]
    }

    // MARK: Actions

    // With a sidebar, stepping past the last change of a file moves on to the next file, and back likewise.
    @objc func nextChange(_ sender: Any?) {
        let canvas = diffVC.canvas
        if (canvas.currentChange ?? -1) < canvas.changeCount - 1 || sidebar?.hasNeighbour(1) != true {
            canvas.nextChange()
        } else {
            sidebar?.selectNext(1)
        }
    }

    @objc func previousChange(_ sender: Any?) {
        let canvas = diffVC.canvas
        if (canvas.currentChange ?? 0) > 0 || sidebar?.hasNeighbour(-1) != true {
            canvas.previousChange()
        } else {
            diffVC.startAtLastChange = true
            sidebar?.selectNext(-1)
        }
    }
    @objc func nextFile(_ sender: Any?) { sidebar?.selectNext(1) }
    @objc func previousFile(_ sender: Any?) { sidebar?.selectNext(-1) }

    @objc func showFind(_ sender: Any?) { diffVC.showFind() }
    @objc func findNext(_ sender: Any?) { diffVC.findStep(forward: true) }
    @objc func findPrevious(_ sender: Any?) { diffVC.findStep(forward: false) }
    @objc func useSelectionForFind(_ sender: Any?) { diffVC.useSelectionForFind() }

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
        diffVC.confirmUnsavedChanges { [self] in
            switch kind {
            case .files: diffVC.reload()
            case .folders: scanFolders(keeping: sidebar?.selectedPath)
            case .changes:
                refreshChanges()
                if selectedEntry != nil { diffVC.reload() }
            }
        }
    }

    @objc func swapSides(_ sender: Any?) {
        guard kind != .changes else { return }
        diffVC.confirmUnsavedChanges { [self] in
            swap(&left, &right)
            updateTitle()
            switch kind {
            case .files: diffVC.load(left: left, right: right)
            case .folders: scanFolders(keeping: sidebar?.selectedPath)
            case .changes: break
            }
        }
    }

    // MARK: Merging

    @objc func copyToRight(_ sender: Any?) { diffVC.copyChange(to: .right) }
    @objc func copyToLeft(_ sender: Any?) { diffVC.copyChange(to: .left) }
    @objc func saveChanges(_ sender: Any?) { diffVC.save() }
    @objc func undoEdit(_ sender: Any?) { diffVC.undo.undo() }
    @objc func redoEdit(_ sender: Any?) { diffVC.undo.redo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextChange(_:)):
            return (diffVC.canvas.currentChange ?? -1) < diffVC.canvas.changeCount - 1 || sidebar?.hasNeighbour(1) == true
        case #selector(previousChange(_:)):
            return (diffVC.canvas.currentChange ?? 0) > 0 || sidebar?.hasNeighbour(-1) == true
        case #selector(copyToRight(_:)):
            return diffVC.canCopyChange(to: .right)
        case #selector(copyToLeft(_:)):
            return diffVC.canCopyChange(to: .left)
        case #selector(swapSides(_:)):
            return kind != .changes
        case #selector(togglePause(_:)):
            item.title = isPaused ? "Resume Updates" : "Pause Updates"
            return kind == .changes
        case #selector(saveChanges(_:)):
            return diffVC.hasUnsavedChanges
        case #selector(undoEdit(_:)):
            item.title = diffVC.undo.undoMenuItemTitle
            return diffVC.undo.canUndo
        case #selector(redoEdit(_:)):
            item.title = diffVC.undo.redoMenuItemTitle
            return diffVC.undo.canRedo
        case #selector(zoomImageToFit(_:)):
            return diffVC.showsImage
        case #selector(showFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)):
            return diffVC.canFind
        case #selector(useSelectionForFind(_:)):
            return diffVC.canFind && diffVC.canvas.selectedText != nil
        case #selector(nextFile(_:)), #selector(previousFile(_:)):
            return sidebar != nil
        case #selector(toggleExpandAll(_:)):
            item.state = diffVC.canvas.expandAll ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard diffVC.hasUnsavedChanges else { return true }
        diffVC.confirmUnsavedChanges { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { diffVC.undo }

    func windowWillClose(_ notification: Notification) {
        folderTask?.cancel()
        cleanUp()
        diffVC.stopWatching()
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        switch kind {
        case .files: [.flexibleSpace, .layoutMode]
        case .folders: [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .layoutMode]
        case .changes: [.toggleSidebar, .sidebarTrackingSeparator, .pauseUpdates, .flexibleSpace, .layoutMode]
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .pauseUpdates {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            item.label = "Pause Updates"
            item.toolTip = "Pause Updates: keep showing this state while files change"
            item.isBordered = true
            item.target = self
            item.action = #selector(togglePause(_:))
            pauseItem = item
            return item
        }
        guard id == .layoutMode else { return nil }
        let group = NSToolbarItemGroup(
            itemIdentifier: id, images: [Icons.blocksLayout, Icons.fluidLayout, Icons.unifiedLayout], selectionMode: .selectOne,
            labels: ["Blocks", "Fluid", "Unified"], target: self, action: #selector(layoutGroupChanged(_:)))
        group.label = "Layout"
        group.toolTip = "Layout"
        group.selectedIndex = LayoutMode.allCases.firstIndex(of: Preferences.shared.layout) ?? 1
        group.autovalidates = false
        group.isEnabled = !diffVC.showsImage
        layoutGroup = group
        return group
    }
}
