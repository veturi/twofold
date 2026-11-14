import AppKit

/// Shown when the app starts without paths: two drop wells and a Compare button.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let wellA = DropWell(letter: "A")
    private let wellB = DropWell(letter: "B")
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "")
    private let recentList = NSStackView()
    private let recentSection = NSStackView()
    var onCompare: ((URL, URL) -> Void)?

    init(prefill: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.chrome
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        super.init(window: window)

        let title = NSTextField(labelWithString: "Twofold")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = Theme.text
        let subtitle = NSTextField(labelWithString: "Drop two files or two folders to compare them.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Theme.secondaryText
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Theme.removed.marker

        compareButton.target = self
        compareButton.action = #selector(compare)
        compareButton.keyEquivalent = "\r"
        compareButton.controlSize = .large
        compareButton.bezelColor = Theme.accent

        let wells = NSStackView(views: [wellA, wellB])
        wells.spacing = 16
        wells.distribution = .fillEqually
        let footer = NSStackView(views: [hint, compareButton])
        footer.spacing = 12
        let recentLabel = NSTextField(labelWithString: "Recent")
        recentLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        recentLabel.textColor = Theme.secondaryText
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearRecents))
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 12)
        clear.contentTintColor = Theme.accent
        let recentHeader = NSStackView(views: [recentLabel, NSView(), clear])
        recentHeader.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        recentList.orientation = .vertical
        recentList.spacing = 2
        recentSection.orientation = .vertical
        recentSection.spacing = 6
        recentSection.addArrangedSubview(recentHeader)
        recentSection.addArrangedSubview(recentList)
        for v in [recentHeader, recentList] as [NSView] {
            v.widthAnchor.constraint(equalTo: recentSection.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [title, subtitle, wells, footer, recentSection])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(24, after: subtitle)
        stack.setCustomSpacing(20, after: wells)
        stack.setCustomSpacing(28, after: footer)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = DropView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 10),
            wells.widthAnchor.constraint(equalToConstant: 560),
            wells.heightAnchor.constraint(equalToConstant: 190),
            recentSection.widthAnchor.constraint(equalTo: wells.widthAnchor),
        ])
        root.onDrop = { [weak self] urls in self?.fill(urls) }
        window.contentView = root

        for well in [wellA, wellB] {
            well.onChange = { [weak self] in self?.update() }
            well.onMultiple = { [weak self] urls in self?.fill(urls) }
        }
        wellA.url = prefill
        update()
        reloadRecents()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func reloadRecents() {
        let items = RecentComparisons.available
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let row = RecentRow(item) { [weak self] r in self?.onCompare?(r.leftURL, r.rightURL) }
            recentList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentList.widthAnchor).isActive = true
        }
        recentSection.isHidden = items.isEmpty
        let height: CGFloat = items.isEmpty ? 400 : 440 + CGFloat(items.count) * 46
        guard let window else { return }
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 640, height: height))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    @objc private func clearRecents() {
        RecentComparisons.clear()
        reloadRecents()
    }

    private func fill(_ urls: [URL]) {
        if urls.count >= 2 {
            wellA.url = urls[0]
            wellB.url = urls[1]
        } else if let u = urls.first {
            if wellA.url == nil { wellA.url = u } else { wellB.url = u }
        }
        update()
    }

    private func isDirectory(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func update() {
        var message = ""
        var ok = false
        if let a = wellA.url, let b = wellB.url {
            if isDirectory(a) != isDirectory(b) {
                message = "Choose two files or two folders, not one of each."
            } else {
                ok = true
            }
        }
        hint.stringValue = message
        compareButton.isEnabled = ok
    }

    @objc private func compare() {
        guard let a = wellA.url, let b = wellB.url else { return }
        onCompare?(a, b)
    }
}

/// A rounded drop target that shows the chosen file or folder. Click to pick one.
@MainActor
final class DropWell: NSView {
    let letter: String
    var url: URL? { didSet { needsDisplay = true; onChange?() } }
    var onChange: (() -> Void)?
    var onMultiple: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    init(letter: String) {
        self.letter = letter
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        (highlighted ? Theme.accentSoft : Theme.paneBackground).setFill()
        path.fill()
        path.lineWidth = 1.5
        if url == nil { path.setLineDash([6, 4], count: 2, phase: 0) }
        (highlighted ? Theme.accent : Theme.separator).setStroke()
        path.stroke()

        Badge.draw(letter, in: CGRect(x: r.minX + 12, y: r.maxY - 28, width: 20, height: 18), filled: true)

        let icon: NSImage
        let name: String
        let detail: String
        if let url {
            icon = NSWorkspace.shared.icon(forFile: url.path)
            name = url.lastPathComponent
            detail = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        } else {
            icon = NSImage(systemSymbolName: "plus.square.dashed", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 34, weight: .ultraLight).applying(.init(paletteColors: [Theme.foldText])))!
            name = "Drop a file or folder"
            detail = "or click to choose"
        }
        let iconSize: CGFloat = 56
        icon.draw(in: CGRect(x: r.midX - iconSize / 2, y: r.midY - 4, width: iconSize, height: iconSize))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.text, .paragraphStyle: para,
        ]).draw(in: CGRect(x: r.minX + 12, y: r.midY - 30, width: r.width - 24, height: 18))
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText, .paragraphStyle: para,
        ]).draw(in: CGRect(x: r.minX + 12, y: r.midY - 48, width: r.width - 24, height: 16))
    }

    override func mouseDown(with event: NSEvent) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                if panel.urls.count >= 2 { self?.onMultiple?(panel.urls) } else { self?.url = panel.urls.first }
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !DropView.urls(sender).isEmpty
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = DropView.urls(sender)
        if urls.count >= 2 { onMultiple?(urls) } else { url = urls.first }
        return !urls.isEmpty
    }
}
