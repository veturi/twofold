import AppKit
import DiffCore

/// Path bar, diff canvas and bottom bar for one pair of files. Loads and diffs off the main thread.
@MainActor
final class DiffViewController: NSViewController {
    enum LoadResult: Sendable {
        case text(TextDiff, [[Int32]])
        case binary(identical: Bool, leftSize: Int, rightSize: Int)
        case failure(String)
    }

    let pathBar = PathBarView()
    let canvas = DiffCanvasView()
    let bottomBar = BottomBarView()
    let placard = PlacardView()

    private(set) var isLoading = false
    private(set) var urls: (URL?, URL?) = (nil, nil)
    private(set) var summary = ""
    private var generation = 0
    private var watcher: FileWatcher?

    var onSummaryChange: (() -> Void)?
    var onDrop: (([URL]) -> Void)? {
        didSet { (view as? DropView)?.onDrop = onDrop }
    }

    override func loadView() {
        let root = DropView()
        root.wantsLayer = true
        for v in [pathBar, canvas, bottomBar, placard] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        placard.isHidden = true
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
        ])
        canvas.onGeometryChange = { [weak self] pane, ribbon in
            self?.pathBar.paneWidth = pane
            self?.pathBar.ribbonWidth = ribbon
        }
        canvas.onStateChange = { [weak self] in self?.updateChangeLabel() }
        view = root
        applyPreferences()
        updateChangeLabel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
    }

    func applyPreferences() {
        let p = Preferences.shared
        canvas.mode = p.layout
        canvas.wrapLines = p.wrapLines
        canvas.showInvisibles = p.showInvisibles
        canvas.setFontSize(p.fontSize)
        bottomBar.setToggle(bottomBar.wrapButton, on: p.wrapLines)
        bottomBar.setToggle(bottomBar.invisiblesButton, on: p.showInvisibles)
        bottomBar.setToggle(bottomBar.expandButton, on: canvas.expandAll)
    }

    // MARK: Loading

    func load(left: URL?, right: URL?, keepScroll: Bool = false) {
        urls = (left, right)
        pathBar.urls = (left, right)
        generation += 1
        let gen = generation
        isLoading = true
        watcher?.invalidate()
        watcher = nil
        Task { [weak self] in
            let result = await Self.compute(left, right)
            guard let self, gen == self.generation else { return }
            self.isLoading = false
            self.apply(result, keepScroll: keepScroll)
            let watched = [left, right].compactMap { $0 }
            if !watched.isEmpty {
                self.watcher = FileWatcher(urls: watched) { [weak self] in self?.reload() }
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
        canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
        placard.show(symbol: symbol, title: title, subtitle: subtitle)
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
                var same = false
                if let l, let r { same = FolderCompare.contentsEqual(l, r) }
                return .binary(identical: same, leftSize: ld.byteCount, rightSize: rd.byteCount)
            }
            let diff = TextDiff(left: ld, right: rd)
            return .text(diff, [Columns.compute(ld.lines), Columns.compute(rd.lines)])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func apply(_ result: LoadResult, keepScroll: Bool) {
        switch result {
        case .text(let diff, let columns):
            placard.isHidden = true
            canvas.setDiff(diff, columns: columns, preserveScroll: keepScroll)
            summary = Self.summary(diff.stats)
            bottomBar.statusLabel.stringValue = Self.status(diff)
        case .binary(let identical, let ls, let rs):
            canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
            let f = ByteCountFormatter()
            placard.show(symbol: "doc.zipper",
                         title: identical ? "Binary files are identical" : "Binary files differ",
                         subtitle: "A: \(f.string(fromByteCount: Int64(ls)))    B: \(f.string(fromByteCount: Int64(rs)))")
            summary = identical ? "Binary, identical" : "Binary files differ"
            bottomBar.statusLabel.stringValue = ""
        case .failure(let message):
            canvas.setDiff(nil, columns: [[], []], preserveScroll: false)
            placard.show(symbol: "exclamationmark.triangle", title: "Could not open file", subtitle: message)
            summary = "Could not open file"
            bottomBar.statusLabel.stringValue = ""
        }
        updateChangeLabel()
        onSummaryChange?()
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

    private func updateChangeLabel() {
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
