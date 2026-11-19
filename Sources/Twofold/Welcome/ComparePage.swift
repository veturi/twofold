import AppKit

/// The start window's first page: the logo, wells A and B, and the newest few comparisons.
///
/// There is no Compare button. As soon as both wells hold two files or two folders the comparison
/// opens; a file and a folder show an error in the well filled last instead.
@MainActor
final class ComparePage: NSView {
    let wellA = DropWell(letter: "A")
    let wellB = DropWell(letter: "B")
    private let connector = WellConnectorView()
    private let recentRow = NSStackView()
    private let recentSection = NSStackView()
    var onCompare: ((URL, URL) -> Void)?
    var onOpenRepository: (() -> Void)?
    var onOpenRecent: ((RecentComparison) -> Void)?
    var onShowRecents: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = GlowingIconView(size: 104)
        let title = WelcomeText.label("Twofold", size: 34, weight: .bold)
        let subtitle = WelcomeText.label("Drop two files or two folders anywhere in this window.", size: 14, color: Theme.welcomeSecondary)

        let wells = NSStackView(views: [wellA, connector, wellB])
        wells.spacing = 0
        for well in [wellA, wellB] {
            well.widthAnchor.constraint(equalToConstant: 264).isActive = true
            well.heightAnchor.constraint(equalToConstant: 168).isActive = true
            well.onChange = { [weak self, weak well] in self?.changed(well) }
            well.onChoose = { [weak self, weak well] in self?.choose(into: well) }
            well.onMultiple = { [weak self] urls in self?.take(urls) }
        }
        connector.widthAnchor.constraint(equalToConstant: 60).isActive = true
        connector.heightAnchor.constraint(equalToConstant: 168).isActive = true

        let choose = WelcomeButton("Choose Files…", symbol: "doc.on.doc", shortcut: "⌘O", style: .primary) { [weak self] in
            self?.chooseFiles()
        }
        let repository = WelcomeButton("Open Repository…", symbol: "arrow.triangle.branch", shortcut: "⇧⌘O", style: .secondary) { [weak self] in
            self?.onOpenRepository?()
        }
        let actions = NSStackView(views: [choose, repository])
        actions.spacing = 12

        let showAll = WelcomeLink("Show all") { [weak self] in self?.onShowRecents?() }
        let header = NSStackView(views: [WelcomeText.section("Jump back in"), NSView(), showAll])
        recentRow.spacing = 10
        recentRow.distribution = .fillEqually
        recentSection.orientation = .vertical
        recentSection.spacing = 10
        recentSection.addArrangedSubview(header)
        recentSection.addArrangedSubview(recentRow)
        for v in [header, recentRow] { v.widthAnchor.constraint(equalTo: recentSection.widthAnchor).isActive = true }

        let stack = NSStackView(views: [icon, title, subtitle, wells, actions, recentSection])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(30, after: subtitle)
        stack.setCustomSpacing(22, after: wells)
        stack.setCustomSpacing(34, after: actions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),
            recentSection.widthAnchor.constraint(equalTo: wells.widthAnchor),
        ])
        reloadRecents()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reloadRecents() {
        recentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = Array(RecentComparisons.available.prefix(3))
        for item in items {
            let card = RecentCard(item)
            card.action = { [weak self] in self?.onOpenRecent?(item) }
            recentRow.addArrangedSubview(card)
        }
        // Keep cards a third of the row wide, even when there are fewer than three.
        for _ in items.count..<3 where !items.isEmpty { recentRow.addArrangedSubview(NSView()) }
        recentSection.isHidden = items.isEmpty
    }

    // MARK: Filling the wells

    /// Takes dropped or chosen items: two or more start a comparison, one fills the next empty well.
    func take(_ urls: [URL]) {
        if urls.count >= 2 {
            // Fill both before looking at them, so A is never compared with what B held before.
            batching = true
            wellA.url = urls[0]
            wellB.url = urls[1]
            batching = false
            changed(wellB)
        } else if let u = urls.first {
            if wellA.url == nil { wellA.url = u } else if wellB.url == nil { wellB.url = u } else { wellB.url = u }
        }
    }

    private var batching = false

    private func changed(_ well: DropWell?) {
        guard !batching else { return }
        wellA.error = nil
        wellB.error = nil
        connector.muted = false
        guard let a = wellA.url, let b = wellB.url else { return }
        if isDirectory(a) != isDirectory(b) {
            (well ?? wellB).error = "A folder and a file can’t be compared"
            connector.muted = true
            return
        }
        onCompare?(a, b)
    }

    private func isDirectory(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// One open panel for both sides; picking one item fills the next empty well.
    func chooseFiles() {
        present(panel(multiple: true)) { [weak self] urls in self?.take(urls) }
    }

    private func choose(into well: DropWell?) {
        present(panel(multiple: true)) { [weak self, weak well] urls in
            if urls.count >= 2 { self?.take(urls) } else { well?.url = urls.first }
        }
    }

    private func panel(multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.message = "Choose two files or two folders, or one to fill the next side."
        panel.prompt = "Choose"
        return panel
    }

    private func present(_ panel: NSOpenPanel, then done: @escaping ([URL]) -> Void) {
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { done(panel.urls) }
        }
    }
}

/// A text button in the link colour.
@MainActor
final class WelcomeLink: WelcomeControl {
    init(_ title: String, size: CGFloat = 11.5, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.action = action
        let label = WelcomeText.label(title, size: size, weight: .medium, color: Theme.welcomeLink)
        embed(label, insets: NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2))
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hoverChanged() { alphaValue = hovering ? 0.75 : 1 }
}

/// A compact card for one recent comparison, for the Jump Back In row.
@MainActor
final class RecentCard: WelcomeControl {
    init(_ item: RecentComparison) {
        super.init(frame: .zero)
        fill = Theme.welcomeCard
        hoverFill = Theme.welcomeCardHover
        stroke = Theme.welcomeCardStroke
        radius = 11
        let title = WelcomeText.label(item.title, size: 12, weight: .semibold)
        let detail = WelcomeText.label(item.kind == .repository ? "Working copy · \(RecentComparisons.when(item.date))"
                                       : "\(item.locations) · \(RecentComparisons.when(item.date))",
                                       size: 10.5, color: Theme.welcomeTertiary)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [IconTile(symbol: item.symbol, tint: item.tint, size: 28), text])
        row.spacing = 10
        embed(row, insets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12))
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        toolTip = item.kind == .repository ? item.left : "\(item.left)\n\(item.right)"
        setAccessibilityLabel("Open \(item.title)")
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A rounded drop target that shows the chosen file or folder. Click to pick one.
@MainActor
final class DropWell: NSView {
    let letter: String
    var url: URL? { didSet { if url != oldValue { update(); onChange?() } } }
    /// Shown in red under the name, for a file and a folder that cannot be compared.
    var error: String? { didSet { update() } }
    var onChange: (() -> Void)?
    var onChoose: (() -> Void)?
    var onMultiple: (([URL]) -> Void)?
    private var dragging = false { didSet { update() } }
    private let icon = NSImageView()
    private let name = WelcomeText.label("", size: 13, weight: .semibold)
    private let detail = WelcomeText.label("", size: 11.5, color: Theme.welcomeTertiary)
    private lazy var clear = ClearButton { [weak self] in self?.url = nil }

    init(letter: String) {
        self.letter = letter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL])
        name.alignment = .center
        detail.alignment = .center
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let stack = NSStackView(views: [icon, name, detail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(8, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(clear)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -28),
            name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -28),
            detail.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -28),
            clear.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        clear.isHidden = url == nil || dragging
        // File icons fill the frame; symbols keep their point size.
        icon.imageScaling = url != nil && !dragging ? .scaleProportionallyUpOrDown : .scaleNone
        if dragging {
            icon.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 28, weight: .medium))
            icon.contentTintColor = Theme.welcomeText
            name.stringValue = "Release to compare"
            detail.stringValue = "Opens right away"
            detail.textColor = Theme.welcomeSecondary
        } else if let url {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 52, height: 52)
            icon.image = image
            icon.contentTintColor = nil
            name.stringValue = url.lastPathComponent
            detail.stringValue = error ?? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            detail.textColor = error == nil ? Theme.welcomeTertiary : Theme.removed.marker
        } else {
            icon.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
            icon.contentTintColor = Theme.welcomeTertiary
            name.stringValue = "Drop a file or folder"
            detail.stringValue = "or click to choose"
            detail.textColor = Theme.welcomeTertiary
        }
        setAccessibilityLabel("Side \(letter): \(url?.lastPathComponent ?? "empty")")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        if dragging {
            Theme.welcomeDropFill.setFill()
            path.fill()
            path.lineWidth = 2
            Theme.welcomeDropStroke.setStroke()
        } else if error != nil {
            Theme.welcomeErrorFill.setFill()
            path.fill()
            path.lineWidth = 1.5
            Theme.removed.stroke.setStroke()
        } else {
            (url == nil ? Theme.welcomeCard : Theme.welcomeCardHover).setFill()
            path.fill()
            path.lineWidth = url == nil ? 1.5 : 1
            if url == nil { path.setLineDash([6, 5], count: 2, phase: 0) }
            (url == nil ? Theme.welcomeWellStroke : Theme.welcomeCardStroke).setStroke()
        }
        path.stroke()

        // The A / B badge.
        let badge = CGRect(x: r.minX + 11, y: r.maxY - 31, width: 22, height: 20)
        (dragging ? NSColor.white : Theme.accent).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        let s = NSAttributedString(string: letter, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: dragging ? Theme.accent : NSColor.white,
        ])
        let size = s.size()
        s.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { onChoose?() }
    override func accessibilityPerformPress() -> Bool { onChoose?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !DropView.urls(sender).isEmpty
        dragging = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dragging = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragging = false
        let urls = DropView.urls(sender)
        if urls.count >= 2 { onMultiple?(urls) } else { url = urls.first }
        return !urls.isEmpty
    }

    /// The small × that empties the well.
    private final class ClearButton: WelcomeControl {
        init(_ action: @escaping () -> Void) {
            super.init(frame: .zero)
            self.action = action
            fill = Theme.welcomeChip
            hoverFill = Theme.welcomeSelection
            radius = 10
            let x = WelcomeText.symbol("xmark", size: 8.5, weight: .bold, color: Theme.welcomeSecondary)
            embed(x, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
            widthAnchor.constraint(equalToConstant: 20).isActive = true
            heightAnchor.constraint(equalToConstant: 20).isActive = true
            setAccessibilityLabel("Clear")
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}
