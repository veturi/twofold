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
        showImage(nil)
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
                if let image = ImageComparison.load(l, r) { return .image(image) }
                var same = false
                if let l, let r { same = FolderCompare.contentsEqual(l, r) }
                return .binary(identical: same, leftSize: ld.byteCount, rightSize: rd.byteCount)
            }
            // Tokenizing each side is independent of the diff, so all three run side by side.
            async let leftSyntax = syntax(ld, l)
            async let rightSyntax = syntax(rd, r)
            let diff = TextDiff(left: ld, right: rd)
            return .text(diff, [Columns.compute(ld.lines), Columns.compute(rd.lines)], [await leftSyntax, await rightSyntax])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Files above this size are shown without syntax colours.
    private nonisolated static let maxSyntaxBytes = 16_000_000

    /// Token colours for one side, when its language can be told from the file name or first line.
    @concurrent
    private nonisolated static func syntax(_ doc: TextDocument, _ url: URL?) async -> SyntaxMap? {
        guard let url, doc.byteCount <= maxSyntaxBytes,
              let language = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: doc.lines.first) else { return nil }
        return language.highlight(doc.lines)
    }

    private func apply(_ result: LoadResult, keepScroll: Bool) {
        switch result {
        case .text(let diff, let columns, let syntax):
            placard.isHidden = true
            showImage(nil)
            canvas.setDiff(diff, columns: columns, syntax: syntax, preserveScroll: keepScroll)
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
