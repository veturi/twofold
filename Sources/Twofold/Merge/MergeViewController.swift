import AppKit
import DiffCore

/// A three-way merge: the two sides in the diff canvas on top, the editable result below.
///
/// The canvas shows A (local) against B (remote) and is read-only. Every change in it is one chunk of
/// the merge, and the result pane holds one text segment per chunk. Choosing a side replaces that
/// segment; typing in the result edits it directly. What each chunk currently holds is always read
/// back from the result's text, so a conflict is unresolved exactly as long as its markers are there.
@MainActor
final class MergeViewController: NSViewController, NSSplitViewDelegate {
    enum LoadResult: Sendable {
        case ready(ThreeWayMerge, [[Int32]], [SyntaxMap?], template: TextDocument, onDisk: String?)
        case failure(String)
    }

    let pathBar = PathBarView()
    let canvas = DiffCanvasView()
    let resultBar = PathBarView()
    let result = MergeResultView()
    let bottomBar = BottomBarView()
    let placard = PlacardView()
    private let split = NSSplitView()
    let undo = UndoManager()

    let base: URL?
    let local: URL
    let remote: URL
    let output: URL

    private(set) var merge: ThreeWayMerge?
    private(set) var isLoading = false
    private(set) var summary = ""
    /// Encoding and line endings for the saved file: the output file's own if it exists, else A's.
    private var template = TextDocument.empty
    /// The result as it is on disk, or nil when the output file does not exist yet.
    private var savedText: String? { didSet { updateUnsaved() } }
    private var marks: [MergeMark] = []
    private var generation = 0
    private var shownChange: Int?
    private var placedDivider = false

    var onSummaryChange: (() -> Void)?
    var onEditStateChange: (() -> Void)?

    init(base: URL?, local: URL, remote: URL, output: URL) {
        self.base = base
        self.local = local
        self.remote = remote
        self.output = output
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = DropView()
        root.wantsLayer = true

        let top = NSView(), bottom = NSView()
        for (parent, bar, body) in [(top, pathBar, canvas as NSView), (bottom, resultBar, result as NSView)] {
            for v in [bar, body] {
                v.translatesAutoresizingMaskIntoConstraints = false
                parent.addSubview(v)
            }
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: parent.topAnchor),
                bar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: PathBarView.height),
                body.topAnchor.constraint(equalTo: bar.bottomAnchor),
                body.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
        }
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(top)
        split.addArrangedSubview(bottom)

        for v in [split, bottomBar, placard] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        placard.isHidden = true
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: BottomBarView.height),
            placard.topAnchor.constraint(equalTo: split.topAnchor),
            placard.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            placard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            placard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        pathBar.urls = (local, remote)
        pathBar.swapButton.isHidden = true
        resultBar.single = ("R", "Result", output)
        bottomBar.showsMergeControls = true
        canvas.mergeMarks = []
        canvas.onGeometryChange = { [weak self] pane, ribbon in
            self?.pathBar.paneWidth = pane
            self?.pathBar.ribbonWidth = ribbon
        }
        canvas.onStateChange = { [weak self] in self?.currentChangeMoved() }
        canvas.onTake = { [weak self] change, side in self?.use(side == .left ? .local : .remote, change: change) }
        result.onChange = { [weak self] segments in self?.resultChanged(segments) }
        result.onCaretSegment = { [weak self] segment in self?.caretMoved(to: segment) }
        view = root
        applyPreferences()
        updateLabels()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The first real layout decides where the divider starts: the result gets the lower third.
        if !placedDivider, split.bounds.height > 300 {
            placedDivider = true
            split.setPosition((split.bounds.height * 0.62).rounded(), ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat { 140 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        splitView.bounds.height - 110
    }

    func applyPreferences() {
        let p = Preferences.shared
        canvas.mode = p.layout
        canvas.wrapLines = p.wrapLines
        canvas.showInvisibles = p.showInvisibles
        canvas.showSyntax = p.syntaxHighlighting
        canvas.setFontSize(p.fontSize)
        result.wrapLines = p.wrapLines
        result.setFontSize(p.fontSize)
        bottomBar.setToggle(bottomBar.syntaxButton, on: p.syntaxHighlighting)
        bottomBar.setToggle(bottomBar.wrapButton, on: p.wrapLines)
        bottomBar.setToggle(bottomBar.invisiblesButton, on: p.showInvisibles)
        bottomBar.setToggle(bottomBar.expandButton, on: canvas.expandAll)
    }

    // MARK: Loading

    /// Reads the three inputs and starts the result afresh. Any work on the result is dropped; ask
    /// first with `confirmUnsavedChanges`.
    func load() {
        generation += 1
        let gen = generation
        isLoading = true
        let (base, local, remote, output) = (base, local, remote, output)
        Task { [weak self] in
            let loaded = await Self.compute(base, local, remote, output)
            guard let self, gen == self.generation else { return }
            self.isLoading = false
            self.apply(loaded)
        }
    }

    @concurrent
    static func compute(_ base: URL?, _ local: URL, _ remote: URL, _ output: URL) async -> LoadResult {
        do {
            let ld = try TextDocument.load(local), rd = try TextDocument.load(remote)
            // Git names a base file even when there is no common ancestor; it is then missing or empty.
            var bd: TextDocument?
            if let base, FileManager.default.fileExists(atPath: base.path) {
                let doc = try TextDocument.load(base)
                if doc.isBinary { return .failure("The base file is not text.") }
                if !doc.lines.isEmpty { bd = doc }
            }
            if ld.isBinary || rd.isBinary { return .failure("Only text files can be merged.") }
            var template = ld
            var onDisk: String?
            if FileManager.default.fileExists(atPath: output.path) {
                let od = try TextDocument.load(output)
                if !od.isBinary {
                    if !od.lines.isEmpty { template = od }
                    onDisk = zip(od.lines, od.terminators).map { $0 + ($1 == .none ? "" : "\n") }.joined()
                }
            }
            template.url = output
            async let leftSyntax = DiffViewController.syntax(ld, local)
            async let rightSyntax = DiffViewController.syntax(rd, remote)
            let merge = ThreeWayMerge(base: bd, local: ld, remote: rd)
            return .ready(merge, [Columns.compute(ld.lines), Columns.compute(rd.lines)], [await leftSyntax, await rightSyntax],
                          template: template, onDisk: onDisk)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func apply(_ loaded: LoadResult) {
        switch loaded {
        case .ready(let merge, let columns, let syntax, let template, let onDisk):
            self.merge = merge
            self.template = template
            savedText = onDisk
            placard.isHidden = true
            canvas.setDiff(merge.diff, columns: columns, syntax: syntax, preserveScroll: false)
            // One segment per chunk, and a last empty one so that there is always somewhere to type.
            result.setSegments(merge.chunks.indices.map { i in
                merge.automaticChoice(i).map { text(i, $0) } ?? markerText(i)
            } + [""])
            undo.removeAllActions()
            updateUnsaved()
            refreshMarks()
            shownChange = nil
            if let first = marks.firstIndex(where: \.conflict) {
                canvas.goToChange(first, animated: false)
            } else if !marks.isEmpty {
                canvas.goToChange(0, animated: false)
            }
        case .failure(let message):
            merge = nil
            hasUnsavedChanges = false
            canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
            result.setSegments([""])
            marks = []
            canvas.mergeMarks = []
            placard.show(symbol: "exclamationmark.triangle", title: "Could not merge", subtitle: message)
        }
        canvas.busy = false
        updateLabels()
        onEditStateChange?()
    }

    // MARK: Chunk text

    /// The text a chunk puts into the result for a choice: its lines, each ended by a line feed. The
    /// very last line of the result stays unterminated if it is unterminated in the file it comes from.
    private func text(_ chunk: Int, _ choice: MergeChoice) -> String {
        guard let merge else { return "" }
        let lines = merge.lines(chunk, choice)
        guard !lines.isEmpty else { return "" }
        var text = lines.joined(separator: "\n") + "\n"
        if chunk == merge.chunks.count - 1 {
            let c = merge.chunks[chunk]
            let open: Bool
            switch choice {
            case .local: open = c.local.upperBound == merge.local.lines.count && !merge.local.endsWithTerminator
            case .remote, .both:
                open = c.remote.isEmpty && choice == .both
                    ? c.local.upperBound == merge.local.lines.count && !merge.local.endsWithTerminator
                    : c.remote.upperBound == merge.remote.lines.count && !merge.remote.endsWithTerminator
            case .base: open = false
            }
            if open { text.removeLast() }
        }
        return text
    }

    private func markerText(_ chunk: Int) -> String {
        guard let merge else { return "" }
        return merge.markerLines(chunk, localLabel: local.lastPathComponent, remoteLabel: remote.lastPathComponent)
            .joined(separator: "\n") + "\n"
    }

    // MARK: State

    /// Reads what one change's segment holds: one side's lines, both, an open conflict, or other text.
    private func mark(_ change: Int) -> MergeMark {
        guard let merge else { return MergeMark() }
        let chunk = merge.changeChunks[change]
        if result.markerCount(chunk) > 0 { return MergeMark(conflict: true) }
        if result.segment(chunk, equals: text(chunk, .local)) { return MergeMark(left: true) }
        if result.segment(chunk, equals: text(chunk, .remote)) { return MergeMark(right: true) }
        if result.segment(chunk, equals: text(chunk, .both)) { return MergeMark(left: true, right: true) }
        return MergeMark()
    }

    private func refreshMarks(_ segments: Set<Int>? = nil) {
        guard let merge else { return }
        if let segments, marks.count == merge.changeChunks.count {
            for (change, chunk) in merge.changeChunks.enumerated() where segments.contains(chunk) { marks[change] = mark(change) }
        } else {
            marks = merge.changeChunks.indices.map(mark)
        }
        canvas.mergeMarks = marks
        var styles = [MergeResultView.Style](repeating: .plain, count: result.segmentCount)
        for (change, chunk) in merge.changeChunks.enumerated() { styles[chunk] = marks[change].conflict ? .conflict : .change }
        result.styles = styles
    }

    private func resultChanged(_ segments: Set<Int>) {
        updateUnsaved()
        refreshMarks(segments)
        updateLabels()
        onEditStateChange?()
    }

    /// Unresolved conflicts: opening conflict markers anywhere in the result.
    var unresolvedCount: Int { merge == nil ? 0 : result.totalMarkers }
    /// Whether the result differs from the output file. Kept as a flag because comparing two large
    /// texts on every query would be felt while typing.
    private(set) var hasUnsavedChanges = false

    private func updateUnsaved() {
        guard merge != nil, let savedText else {
            hasUnsavedChanges = merge != nil
            return
        }
        hasUnsavedChanges = !(result.text as NSString).isEqual(to: savedText)
    }
    var canUse: Bool { merge != nil && !isLoading && canvas.currentChange != nil }

    private func currentChangeMoved() {
        if let merge, let c = canvas.currentChange, c < merge.changeChunks.count {
            result.current = merge.changeChunks[c]
            // Follow the canvas only when it moved to another change, not on every repaint of the same one.
            if shownChange != c {
                shownChange = c
                result.scroll(to: merge.changeChunks[c])
            }
        } else {
            result.current = nil
        }
        updateLabels()
    }

    /// The caret entered another part of the result. If that part is a change, the canvas shows it.
    private func caretMoved(to segment: Int) {
        guard let merge, let change = merge.changeChunks.firstIndex(of: segment), change != canvas.currentChange else { return }
        shownChange = change
        canvas.goToChange(change)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
    }

    private func updateLabels() {
        let n = canvas.changeCount
        if merge == nil {
            bottomBar.changeLabel.stringValue = ""
        } else if n == 0 {
            bottomBar.changeLabel.stringValue = "No differences"
        } else if let c = canvas.currentChange {
            bottomBar.changeLabel.stringValue = "Change \(c + 1) of \(n)"
        } else {
            bottomBar.changeLabel.stringValue = "\(n) Changes"
        }
        bottomBar.previousButton.isEnabled = n > 0 && (canvas.currentChange ?? 0) > 0
        bottomBar.nextButton.isEnabled = n > 0 && (canvas.currentChange ?? -1) < n - 1
        for b in [bottomBar.useLeftButton, bottomBar.useRightButton, bottomBar.useBothButton] { b.isEnabled = canUse }
        bottomBar.nextConflictButton.isEnabled = marks.contains(where: \.conflict)
        bottomBar.setToggle(bottomBar.expandButton, on: canvas.expandAll)
        resultBar.edited = (hasUnsavedChanges, false)

        let open = unresolvedCount
        let conflicts = merge?.conflictCount ?? 0
        var status = ""
        if merge != nil {
            if open > 0 {
                status = "\(open) conflict\(open == 1 ? "" : "s") to resolve"
            } else if conflicts > 0 {
                status = "All conflicts resolved"
            } else {
                status = "No conflicts"
            }
            if merge?.base == nil { status += "   ·   No common base" }
        }
        bottomBar.statusLabel.stringValue = status
        bottomBar.statusLabel.textColor = open > 0 ? Theme.conflict.marker : Theme.secondaryText
        let newSummary = merge == nil ? "" : "\(n) change\(n == 1 ? "" : "s"), " + (open > 0 ? "\(open) conflict\(open == 1 ? "" : "s") to resolve" : "no conflicts left")
        if newSummary != summary {
            summary = newSummary
            onSummaryChange?()
        }
    }

    // MARK: Resolving

    /// Puts a side's lines (or both sides') into the result for a change; the current one by default.
    func use(_ choice: MergeChoice, change: Int? = nil) {
        guard let merge, !isLoading, let c = change ?? canvas.currentChange, c < merge.changeChunks.count else { return }
        if c != canvas.currentChange {
            shownChange = c
            canvas.goToChange(c)
        }
        let chunk = merge.changeChunks[c]
        let new = text(chunk, choice)
        if !result.segment(chunk, equals: new) {
            let name = choice == .local ? "Use A" : (choice == .remote ? "Use B" : "Use Both")
            result.replace(segment: chunk, with: new, actionName: name)
        }
        result.scroll(to: chunk)
    }

    /// Moves to the next change that is still an open conflict, wrapping around at the end.
    func goToConflict(forward: Bool) {
        let open = marks.indices.filter { marks[$0].conflict }
        guard !open.isEmpty else { return }
        let current = canvas.currentChange ?? (forward ? -1 : marks.count)
        let next = forward ? (open.first { $0 > current } ?? open[0]) : (open.last { $0 < current } ?? open[open.count - 1])
        canvas.goToChange(next)
    }

    // MARK: Saving

    /// Writes the result to the output file. Returns false if it was not saved.
    @discardableResult
    func save(confirmConflicts: Bool = true) -> Bool {
        guard merge != nil else { return false }
        let open = unresolvedCount
        if open > 0 && confirmConflicts {
            let alert = NSAlert()
            alert.messageText = open == 1 ? "One conflict is not resolved yet" : "\(open) conflicts are not resolved yet"
            alert.informativeText = "“\(output.lastPathComponent)” will be saved with conflict markers (<<<<<<<, =======, >>>>>>>) around them."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        let text = result.text
        var doc = template.replacingAll(with: text)
        var data = doc.encoded()
        if data == nil {
            let alert = NSAlert()
            alert.messageText = "“\(output.lastPathComponent)” can’t be saved as \(doc.encoding)"
            alert.informativeText = "The result contains characters that \(doc.encoding) cannot represent. You can save it as UTF-8 instead."
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            doc.textEncoding = .utf8
            template.textEncoding = .utf8
            data = doc.encoded()
        }
        do {
            try DiffViewController.write(data ?? Data(), to: output)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "“\(output.lastPathComponent)” could not be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
        savedText = text
        updateLabels()
        onEditStateChange?()
        return true
    }

    /// Runs `proceed` once the result is saved or given up; `cancel` if the user backs out.
    func confirmUnsavedChanges(cancel: (() -> Void)? = nil, _ proceed: @escaping () -> Void) {
        guard hasUnsavedChanges, let window = view.window else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the merge result to “\(output.lastPathComponent)”?"
        alert.informativeText = "The result will be lost if you don’t save it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save() { proceed() } else { cancel?() }
            case .alertThirdButtonReturn:
                self.savedText = self.result.text
                proceed()
            default:
                cancel?()
            }
        }
    }
}
