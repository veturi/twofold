import AppKit
import DiffCore

/// One window per three-way merge. It answers the same menu actions as a comparison window where
/// they apply, plus the ones that choose a side.
@MainActor
final class MergeWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let mergeVC: MergeViewController
    private var layoutGroup: NSToolbarItemGroup?
    var onClose: ((MergeWindowController) -> Void)?

    var isBusy: Bool { mergeVC.isLoading }

    init(base: URL?, local: URL, remote: URL, output: URL) {
        mergeVC = MergeViewController(base: base, local: local, remote: remote, output: output)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = Theme.chrome
        window.minSize = NSSize(width: 720, height: 520)
        window.isRestorable = false
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self

        mergeVC.onSummaryChange = { [weak self] in self?.updateTitle() }
        mergeVC.onEditStateChange = { [weak self] in
            self?.window?.isDocumentEdited = self?.mergeVC.hasUnsavedChanges ?? false
        }
        window.contentViewController = mergeVC
        window.setContentSize(NSSize(width: 1360, height: 860))

        let toolbar = NSToolbar(identifier: "MergeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        mergeVC.load()
    }

    private func updateTitle() {
        window?.title = "Merge: \(mergeVC.output.lastPathComponent)"
        window?.subtitle = mergeVC.summary
    }

    @objc private func preferencesChanged() {
        mergeVC.applyPreferences()
        layoutGroup?.selectedIndex = Preferences.shared.layout == .blocks ? 0 : 1
    }

    @objc private func layoutGroupChanged(_ sender: NSToolbarItemGroup) {
        Preferences.shared.layout = sender.selectedIndex == 0 ? .blocks : .fluid
    }

    // MARK: Actions

    @objc func nextChange(_ sender: Any?) { mergeVC.canvas.nextChange() }
    @objc func previousChange(_ sender: Any?) { mergeVC.canvas.previousChange() }
    @objc func nextConflict(_ sender: Any?) { mergeVC.goToConflict(forward: true) }
    @objc func previousConflict(_ sender: Any?) { mergeVC.goToConflict(forward: false) }
    @objc func useLeft(_ sender: Any?) { mergeVC.use(.local) }
    @objc func useRight(_ sender: Any?) { mergeVC.use(.remote) }
    @objc func useBoth(_ sender: Any?) { mergeVC.use(.both) }
    @objc func saveChanges(_ sender: Any?) { mergeVC.save() }
    @objc func undoEdit(_ sender: Any?) { mergeVC.undo.undo() }
    @objc func redoEdit(_ sender: Any?) { mergeVC.undo.redo() }

    @objc func toggleExpandAll(_ sender: Any?) {
        mergeVC.canvas.expandAll.toggle()
        mergeVC.applyPreferences()
    }

    // Find searches the result, which is the text being written. The text view brings its own find bar.
    private func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        window?.makeFirstResponder(mergeVC.result.textView)
        mergeVC.result.textView.performTextFinderAction(item)
    }

    @objc func showFind(_ sender: Any?) { find(.showFindInterface) }
    @objc func findNext(_ sender: Any?) { find(.nextMatch) }
    @objc func findPrevious(_ sender: Any?) { find(.previousMatch) }
    @objc func useSelectionForFind(_ sender: Any?) { find(.setSearchString) }

    @objc func reload(_ sender: Any?) {
        mergeVC.confirmUnsavedChanges { [self] in mergeVC.load() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let canvas = mergeVC.canvas
        switch item.action {
        case #selector(nextChange(_:)):
            return (canvas.currentChange ?? -1) < canvas.changeCount - 1
        case #selector(previousChange(_:)):
            return (canvas.currentChange ?? 0) > 0
        case #selector(nextConflict(_:)), #selector(previousConflict(_:)):
            return mergeVC.unresolvedCount > 0
        case #selector(useLeft(_:)), #selector(useRight(_:)), #selector(useBoth(_:)):
            return mergeVC.canUse
        case #selector(saveChanges(_:)):
            return mergeVC.hasUnsavedChanges
        case #selector(undoEdit(_:)):
            item.title = mergeVC.undo.undoMenuItemTitle
            return mergeVC.undo.canUndo
        case #selector(redoEdit(_:)):
            item.title = mergeVC.undo.redoMenuItemTitle
            return mergeVC.undo.canRedo
        case #selector(toggleExpandAll(_:)):
            item.state = canvas.expandAll ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mergeVC.hasUnsavedChanges else { return true }
        mergeVC.confirmUnsavedChanges { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { mergeVC.undo }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .layoutMode] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .layoutMode] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .layoutMode else { return nil }
        let group = NSToolbarItemGroup(
            itemIdentifier: id, images: [Icons.blocksLayout, Icons.fluidLayout], selectionMode: .selectOne,
            labels: ["Blocks", "Fluid"], target: self, action: #selector(layoutGroupChanged(_:)))
        group.label = "Layout"
        group.toolTip = "Layout"
        group.selectedIndex = Preferences.shared.layout == .blocks ? 0 : 1
        layoutGroup = group
        return group
    }
}
