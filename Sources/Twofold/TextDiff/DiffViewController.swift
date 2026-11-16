import AppKit
import DiffCore

/// Path bar, diff canvas and bottom bar for one pair of files. Loads and diffs off the main thread.
@MainActor
final class DiffViewController: NSViewController {
    enum LoadResult: Sendable {
        case text(TextDiff, [[Int32]], [SyntaxMap?])
        case image(ImageComparison)
        case binary(identical: Bool, leftSize: Int, rightSize: Int)
        case failure(String)
    }

    let pathBar = PathBarView()
    let canvas = DiffCanvasView()
    let imageView = ImageDiffView()
    let bottomBar = BottomBarView()
    let placard = PlacardView()

    private(set) var isLoading = false
    private(set) var urls: (URL?, URL?) = (nil, nil)
    private(set) var summary = ""
    private var generation = 0
    private var watcher: FileWatcher?
    private var canvasGeometry: (pane: CGFloat, ribbon: CGFloat) = (300, 64)

    /// The two sides as they are being edited. They match the files until a change is copied across.
    private var docs: [TextDocument] = [.empty, .empty]
    /// Edits since each side was loaded or saved: up on every change and redo, down on undo.
    private var editCounts = [0, 0]
    /// What each file looked like on disk when it was last read or written here.
    private var stamps: [FileStamp?] = [nil, nil]
    let undo = UndoManager()
    /// The side whose latest undo step is a run of typing that further keystrokes may join.
    private var typingSide: Int?
    /// What the re-diff in flight changed, for the canvas to carry folds and the selection across.
    private var pendingEdit: LineEdit?
    /// Called when a side becomes edited or clean.
    var onEditStateChange: (() -> Void)?
    var onSave: (() -> Void)?

    /// True while an image comparison is on screen instead of the text canvas.
    var showsImage: Bool { !imageView.isHidden }

    var onSummaryChange: (() -> Void)?
    var onDrop: (([URL]) -> Void)? {
        didSet { (view as? DropView)?.onDrop = onDrop }
    }

    override func loadView() {
        let root = DropView()
        root.wantsLayer = true
        for v in [pathBar, canvas, imageView, bottomBar, placard] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        placard.isHidden = true
        imageView.isHidden = true
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: PathBarView.height),
            canvas.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: BottomBarView.height),
            placard.topAnchor.constraint(equalTo: canvas.topAnchor),
            placard.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            placard.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            placard.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: canvas.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
        canvas.onGeometryChange = { [weak self] pane, ribbon in
            self?.canvasGeometry = (pane, ribbon)
            self?.updatePathBarGeometry()
        }
        canvas.onStateChange = { [weak self] in self?.updateChangeLabel() }
        canvas.onCopy = { [weak self] side in self?.copyChange(to: side) }
        canvas.onEdit = { [weak self] side, a, b, text, coalesce in self?.replaceText(side, a, b, text, coalesce: coalesce) }
        imageView.onStateChange = { [weak self] in
            self?.updatePathBarGeometry()
            self?.updateChangeLabel()
        }
        for b in [bottomBar.zoomInButton, bottomBar.zoomOutButton, bottomBar.fitButton] { b.target = imageView }
        bottomBar.opacitySlider.target = self
        bottomBar.opacitySlider.action = #selector(opacityChanged(_:))
        view = root
        applyPreferences()
        updateChangeLabel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(showsImage ? imageView : canvas)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        imageView.overlayOpacity = CGFloat(sender.doubleValue)
    }

    /// The path bar lines its two halves up with the panes below it.
    private func updatePathBarGeometry() {
        if showsImage {
            // The image view has no ribbon or overview strip, so its panes meet at the true centre.
            pathBar.paneWidth = floor((imageView.bounds.width - 1) / 2)
            pathBar.ribbonWidth = 1
        } else {
            pathBar.paneWidth = canvasGeometry.pane
            pathBar.ribbonWidth = canvasGeometry.ribbon
        }
    }

    /// Swaps the text canvas for the image view, or back.
    private func showImage(_ comparison: ImageComparison?, keepView: Bool = false) {
        let wasShown = showsImage
        imageView.isHidden = comparison == nil
        imageView.setComparison(comparison, preserveView: keepView && wasShown)
        bottomBar.showsImageControls = comparison != nil
        updatePathBarGeometry()
        guard wasShown != showsImage, let window = view.window else { return }
        // Move keyboard focus along with the content, but leave it alone if it is in the sidebar.
        if window.firstResponder === (wasShown ? imageView : canvas) {
            window.makeFirstResponder(wasShown ? canvas : imageView)
        }
    }

    func applyPreferences() {
        let p = Preferences.shared
        canvas.mode = p.layout
        canvas.wrapLines = p.wrapLines
        canvas.showInvisibles = p.showInvisibles
        canvas.showSyntax = p.syntaxHighlighting
        bottomBar.setToggle(bottomBar.syntaxButton, on: p.syntaxHighlighting)
        canvas.setFontSize(p.fontSize)
        imageView.mode = p.imageMode
        bottomBar.imageModeControl.selectedSegment = ImageMode.allCases.firstIndex(of: p.imageMode) ?? 0
        bottomBar.showsOpacity = p.imageMode == .overlay
        bottomBar.setToggle(bottomBar.wrapButton, on: p.wrapLines)
        bottomBar.setToggle(bottomBar.invisiblesButton, on: p.showInvisibles)
        bottomBar.setToggle(bottomBar.expandButton, on: canvas.expandAll)
    }

    // MARK: Loading

    /// Reads both files from disk. Any unsaved edits are dropped; ask first with `confirmUnsavedChanges`.
    func load(left: URL?, right: URL?, keepScroll: Bool = false) {
        urls = (left, right)
        pathBar.urls = (left, right)
        stamps = [left.flatMap(FileStamp.init), right.flatMap(FileStamp.init)]
        resetEdits()
        generation += 1
        let gen = generation
        isLoading = true
        pendingEdit = nil
        canvas.cancelPendingOps()
        canvas.busy = true
        watcher?.invalidate()
        watcher = nil
        Task { [weak self] in
            let result = await Self.compute(left, right)
            guard let self, gen == self.generation else { return }
            self.isLoading = false
            self.apply(result, keepScroll: keepScroll)
            let watched = [left, right].compactMap { $0 }
            if !watched.isEmpty {
                self.watcher = FileWatcher(urls: watched) { [weak self] in self?.filesChanged() }
            }
        }
    }

    func reload() {
        load(left: urls.0, right: urls.1, keepScroll: true)
    }

    func clear(title: String, subtitle: String, symbol: String) {
        generation += 1
        isLoading = false
        watcher?.invalidate()
        watcher = nil
        urls = (nil, nil)
        pathBar.urls = (nil, nil)
        docs = [.empty, .empty]
        stamps = [nil, nil]
        resetEdits()
        pendingEdit = nil
        canvas.cancelPendingOps()
        canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
        showImage(nil)
        placard.show(symbol: symbol, title: title, subtitle: subtitle)
        canvas.busy = false
        summary = ""
        bottomBar.statusLabel.stringValue = ""
        updateChangeLabel()
        onSummaryChange?()
    }

    func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }

    @concurrent
    static func compute(_ l: URL?, _ r: URL?) async -> LoadResult {
        do {
            let ld = try l.map { try TextDocument.load($0) } ?? .empty
            let rd = try r.map { try TextDocument.load($0) } ?? .empty
            if ld.isBinary || rd.isBinary {
                if let image = ImageComparison.load(l, r) { return .image(image) }
                var same = false
                if let l, let r { same = FolderCompare.contentsEqual(l, r) }
                return .binary(identical: same, leftSize: ld.byteCount, rightSize: rd.byteCount)
            }
            return await diff(ld, rd, l, r)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Diffs two documents already in memory. Used for the first load and again after every edit.
    @concurrent
    static func diff(_ ld: TextDocument, _ rd: TextDocument, _ l: URL?, _ r: URL?) async -> LoadResult {
        // Tokenizing each side is independent of the diff, so all three run side by side.
        async let leftSyntax = syntax(ld, l)
        async let rightSyntax = syntax(rd, r)
        let diff = TextDiff(left: ld, right: rd)
        return .text(diff, [Columns.compute(ld.lines), Columns.compute(rd.lines)], [await leftSyntax, await rightSyntax])
    }

    /// Files above this size are shown without syntax colours.
    private nonisolated static let maxSyntaxBytes = 16_000_000

    /// Token colours for one side, when its language can be told from the file name or first line.
    @concurrent
    nonisolated static func syntax(_ doc: TextDocument, _ url: URL?) async -> SyntaxMap? {
        guard let url, doc.byteCount <= maxSyntaxBytes,
              let language = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: doc.lines.first) else { return nil }
        return language.highlight(doc.lines)
    }

    private func apply(_ result: LoadResult, keepScroll: Bool) {
        switch result {
        case .text(let diff, let columns, let syntax):
            placard.isHidden = true
            showImage(nil)
            docs = [diff.left, diff.right]
            canvas.setDiff(diff, columns: columns, syntax: syntax, edit: pendingEdit, preserveScroll: keepScroll)
            pendingEdit = nil
            summary = Self.summary(diff.stats)
            bottomBar.statusLabel.stringValue = Self.status(diff)
        case .image(let comparison):
            placard.isHidden = true
            canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
            showImage(comparison, keepView: keepScroll)
            summary = Self.summary(comparison.diff)
            bottomBar.statusLabel.stringValue = Self.status(comparison)
        case .binary(let identical, let ls, let rs):
            showImage(nil)
            canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
            let f = ByteCountFormatter()
            placard.show(symbol: "doc.zipper",
                         title: identical ? "Binary files are identical" : "Binary files differ",
                         subtitle: "A: \(f.string(fromByteCount: Int64(ls)))    B: \(f.string(fromByteCount: Int64(rs)))")
            summary = identical ? "Binary, identical" : "Binary files differ"
            bottomBar.statusLabel.stringValue = ""
        case .failure(let message):
            showImage(nil)
            canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
            placard.show(symbol: "exclamationmark.triangle", title: "Could not open file", subtitle: message)
            summary = "Could not open file"
            bottomBar.statusLabel.stringValue = ""
        }
        updateChangeLabel()
        onSummaryChange?()
        // Only now may queued keystrokes run: they must see the document that was just shown.
        canvas.busy = false
    }

    // MARK: Editing

    /// Whether a side differs from its file on disk.
    func isEdited(_ side: Side) -> Bool { editCounts[side.rawValue] != 0 }
    var hasUnsavedChanges: Bool { editCounts != [0, 0] }

    /// Editing needs a text diff of two existing files that can both be written back unchanged.
    var canEdit: Bool {
        canvas.diff != nil && urls.0 != nil && urls.1 != nil && docs[0].isLossless && docs[1].isLossless
    }
    /// True when an edit can be applied right now, which excludes the moment a re-diff is running.
    var canMerge: Bool { canEdit && !isLoading }
    var canCopyChange: Bool { canMerge && canvas.currentChange != nil }

    /// Replaces the current change on `target` with the lines of the other side.
    func copyChange(to target: Side) {
        guard canMerge, let diff = canvas.diff, let c = canvas.currentChange, c < diff.changeBlocks.count else { return }
        let block = diff.blocks[diff.changeBlocks[c]]
        let t = target.rawValue, s = 1 - t
        let from = s == 0 ? block.left : block.right, to = t == 0 ? block.left : block.right
        let edited = docs[t].replacingLines(to, with: Array(docs[s].lines[from]), endsWithTerminator: docs[s].endsWithTerminator)
        setDocument(edited, side: t, actionName: target == .right ? "Copy to Right" : "Copy to Left")
    }

    /// Typed or pasted text from the canvas. Returns where the caret belongs afterwards.
    private func replaceText(_ side: Side, _ a: TextPos, _ b: TextPos, _ text: String, coalesce: Bool) -> TextPos? {
        guard canMerge else { return nil }
        let result = docs[side.rawValue].replacingText(from: (a.line, a.offset), to: (b.line, b.offset), with: text)
        setDocument(result.document, side: side.rawValue, actionName: "Typing", coalesce: coalesce)
        return TextPos(line: result.end.line, offset: result.end.offset)
    }

    /// Installs a new working copy of one side, undoably, and diffs again.
    /// With `coalesce`, an edit that follows other typing on the same side joins its undo step.
    private func setDocument(_ doc: TextDocument, side: Int, actionName: String, coalesce: Bool = false) {
        let old = docs[side]
        let replaying = undo.isUndoing || undo.isRedoing
        if !(coalesce && typingSide == side && !replaying && undo.canUndo) {
            undo.registerUndo(withTarget: self) { $0.setDocument(old, side: side, actionName: actionName) }
            undo.setActionName(actionName)
            editCounts[side] += undo.isUndoing ? -1 : 1
        }
        typingSide = coalesce && !replaying ? side : nil
        docs[side] = doc
        let edit = Self.lineEdit(Side(rawValue: side) ?? .left, old.lines, doc.lines)
        if replaying {
            // Put the caret at the end of what undo or redo brought back.
            let line = min(max(edit.oldRange.lowerBound + edit.newCount - 1, 0), max(doc.lines.count - 1, 0))
            let offset = edit.newCount > 0 && line < doc.lines.count ? doc.lines[line].utf16.count : 0
            canvas.selectAfterNextDiff(edit.side, TextPos(line: line, offset: offset))
        }
        rediff(edit: edit)
        editStateChanged()
    }

    /// The smallest range of lines that differs between two versions of a side.
    private static func lineEdit(_ side: Side, _ old: [String], _ new: [String]) -> LineEdit {
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return LineEdit(side: side, oldRange: prefix..<(old.count - suffix), newCount: new.count - suffix - prefix)
    }

    /// Diffs the working copies again, keeping the scroll position and the current change.
    private func rediff(edit: LineEdit? = nil) {
        generation += 1
        let gen = generation
        isLoading = true
        canvas.busy = true
        pendingEdit = edit
        let l = docs[0], r = docs[1], urls = self.urls
        Task { [weak self] in
            let result = await Self.diff(l, r, urls.0, urls.1)
            guard let self, gen == self.generation else { return }
            self.isLoading = false
            self.apply(result, keepScroll: true)
        }
    }

    private func editStateChanged() {
        pathBar.edited = (isEdited(.left), isEdited(.right))
        updateChangeLabel()
        onEditStateChange?()
    }

    private func resetEdits() {
        typingSide = nil
        editCounts = [0, 0]
        undo.removeAllActions()
        editStateChanged()
    }

    // MARK: Saving

    /// Writes every edited side to its file. Returns false if something could not be saved,
    /// after telling the user why.
    @discardableResult
    func save() -> Bool {
        var normalized = false
        for side in 0..<2 where editCounts[side] != 0 {
            guard let url = side == 0 ? urls.0 : urls.1 else { continue }
            var data = docs[side].encoded()
            if data == nil {
                // Lines copied from the other side can hold characters this file's encoding lacks.
                let alert = NSAlert()
                alert.messageText = "“\(url.lastPathComponent)” can’t be saved as \(docs[side].encoding)"
                alert.informativeText = "It now contains characters that \(docs[side].encoding) cannot represent. You can save it as UTF-8 instead."
                alert.addButton(withTitle: "Save as UTF-8")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
                docs[side].textEncoding = .utf8
                data = docs[side].encoded()
            }
            do {
                try Self.write(data ?? Data(), to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "“\(url.lastPathComponent)” could not be saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return false
            }
            stamps[side] = FileStamp(url)
            editCounts[side] = 0
            // A last line that is empty and unterminated is written as nothing; read it as written.
            if let data {
                let written = TextDocument.decode(data, url: url)
                if written.lines.count != docs[side].lines.count {
                    docs[side] = written
                    normalized = true
                }
            }
        }
        typingSide = nil
        if normalized { rediff() }
        editStateChanged()
        onSave?()
        return true
    }

    /// Every write to a compared file goes through here. Replaces the file in one step and keeps its
    /// permissions; a symbolic link keeps pointing at the file that is rewritten.
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// Runs `proceed` once nothing is unsaved: straight away, or after the user saves or discards
    /// their changes. Runs `cancel` instead if they back out or the save fails.
    func confirmUnsavedChanges(cancel: (() -> Void)? = nil, _ proceed: @escaping () -> Void) {
        guard hasUnsavedChanges, let window = view.window else {
            proceed()
            return
        }
        let names = [Side.left, .right].filter(isEdited).compactMap { ($0 == .left ? urls.0 : urls.1)?.lastPathComponent }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(names.joined(separator: "” and “"))”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save() { proceed() } else { cancel?() }
            case .alertThirdButtonReturn:
                self.resetEdits()
                proceed()
            default:
                cancel?()
            }
        }
    }

    /// A compared file changed on disk. Our own saves are recognised by their timestamp and ignored.
    private func filesChanged() {
        let current = [urls.0.flatMap(FileStamp.init), urls.1.flatMap(FileStamp.init)]
        guard current != stamps else { return }
        guard hasUnsavedChanges else {
            reload()
            return
        }
        // Take in changes to sides that have no edits; ask about the ones that do.
        var conflicts: [String] = []
        var refreshed = false
        for side in 0..<2 where current[side] != stamps[side] {
            guard let url = side == 0 ? urls.0 : urls.1 else { continue }
            if editCounts[side] == 0, let doc = try? TextDocument.load(url), !doc.isBinary {
                docs[side] = doc
                refreshed = true
            } else {
                conflicts.append(url.lastPathComponent)
            }
            stamps[side] = current[side]
        }
        if refreshed {
            // Undoing past this point would bring back the old contents of the refreshed side.
            undo.removeAllActions()
            rediff()
        }
        guard !conflicts.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(conflicts.joined(separator: "” and “"))” changed on disk"
        alert.informativeText = "You have unsaved changes to it here. Keep them, or reload the file and lose them?"
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Reload")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.reload() }
        }
    }

    static func summary(_ s: DiffStats) -> String {
        func part(_ n: Int, _ word: String) -> String? {
            n == 0 ? nil : "\(n) \(word)\(n == 1 ? "" : "s")"
        }
        let parts = [part(s.additions, "Addition"), part(s.deletions, "Deletion"), part(s.changes, "Change")].compactMap { $0 }
        return parts.isEmpty ? "No differences" : parts.joined(separator: ", ")
    }

    static func status(_ d: TextDiff) -> String {
        var parts: [String] = []
        if d.lineEndingsDiffer {
            parts.append("Line endings differ: \(d.left.lineEnding.rawValue) → \(d.right.lineEnding.rawValue)")
        }
        if d.left.encoding != d.right.encoding {
            parts.append("Encoding: \(d.left.encoding) → \(d.right.encoding)")
        } else if d.left.encoding != "UTF-8" {
            parts.append(d.left.encoding)
        }
        if d.isIdentical && !(d.left.lines.isEmpty && d.right.lines.isEmpty) && parts.isEmpty {
            parts.append("Files are identical")
        }
        return parts.joined(separator: "   ·   ")
    }

    static func summary(_ d: ImageDiff) -> String {
        guard !d.isIdentical else { return "Images are identical" }
        let percent = d.fraction * 100
        let share = percent >= 10 ? String(format: "%.0f", percent)
            : percent >= 0.1 ? String(format: "%.1f", percent)
            : percent >= 0.01 ? String(format: "%.2f", percent) : "<0.01"
        return "\(d.differingPixels.formatted()) pixel\(d.differingPixels == 1 ? "" : "s") differ (\(share)%)"
    }

    static func status(_ c: ImageComparison) -> String {
        func text(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }
        var parts: [String] = []
        switch (c.leftSize, c.rightSize) {
        case let (l?, r?) where l != r: parts.append("Size: \(text(l)) → \(text(r))")
        case let (s?, _), let (nil, s?): parts.append(text(s))
        default: break
        }
        if c.reduced { parts.append("Compared at reduced size") }
        return parts.joined(separator: "   ·   ")
    }

    private func updateChangeLabel() {
        canvas.mergeEnabled = canEdit
        bottomBar.copyLeftButton.isEnabled = canCopyChange
        bottomBar.copyRightButton.isEnabled = canCopyChange
        if let c = imageView.comparison, showsImage {
            let n = c.diff.regions.count
            bottomBar.changeLabel.stringValue = n == 0 ? "No differences" : "\(n.formatted()) Region\(n == 1 ? "" : "s")"
            bottomBar.zoomLabel.stringValue = "\(Int((imageView.scale * 100).rounded()))%"
            return
        }
        let n = canvas.changeCount
        if n == 0 {
            bottomBar.changeLabel.stringValue = canvas.diff == nil ? "" : "No changes"
        } else if let c = canvas.currentChange {
            bottomBar.changeLabel.stringValue = "Change \(c + 1) of \(n)"
        } else {
            bottomBar.changeLabel.stringValue = "\(n) Changes"
        }
        bottomBar.previousButton.isEnabled = n > 0 && (canvas.currentChange ?? 0) > 0
        bottomBar.nextButton.isEnabled = n > 0 && (canvas.currentChange ?? -1) < n - 1
        bottomBar.setToggle(bottomBar.expandButton, on: canvas.expandAll)
    }
}

/// Enough about a file on disk to tell whether it has been written since we last looked.
struct FileStamp: Equatable {
    var modified: Date
    var size: Int

    init?(_ url: URL) {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = v.contentModificationDate else { return nil }
        self.modified = modified
        size = v.fileSize ?? 0
    }
}
