import AppKit

/// Path headers above the panes: an A or B badge, then the path as breadcrumbs.
@MainActor
final class PathBarView: NSView {
    static let height: CGFloat = 30

    var urls: (URL?, URL?) = (nil, nil) { didSet { needsDisplay = true } }
    /// Sides with unsaved changes are marked after the file name.
    var edited: (Bool, Bool) = (false, false) { didSet { needsDisplay = true } }
    var paneWidth: CGFloat = 300 { didSet { needsLayout = true; needsDisplay = true } }
    var ribbonWidth: CGFloat = 64 { didSet { needsLayout = true; needsDisplay = true } }
    let swapButton = NSButton()
    /// When set, the bar shows this one file across its whole width, under this badge letter and title.
    var single: (letter: String, title: String, url: URL)? { didSet { swapButton.isHidden = single != nil; needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill", accessibilityDescription: "Swap Sides")
        swapButton.isBordered = false
        swapButton.imageScaling = .scaleProportionallyUpOrDown
        swapButton.contentTintColor = Theme.secondaryText
        swapButton.toolTip = "Swap Sides"
        swapButton.action = #selector(ComparisonWindowController.swapSides(_:))
        addSubview(swapButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size: CGFloat = 18
        let x = hasRibbon ? paneWidth + ribbonWidth / 2 - size / 2 : paneWidth - size - 10
        swapButton.frame = CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
    }

    private var hasRibbon: Bool { ribbonWidth > 10 }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if let single {
            drawSide(single.letter, single.url, edited.0, CGRect(x: 0, y: 0, width: bounds.width - 12, height: bounds.height), title: single.title)
            return
        }
        let gap: CGFloat = hasRibbon ? 16 : 40
        drawSide("A", urls.0, edited.0, CGRect(x: 0, y: 0, width: paneWidth - gap, height: bounds.height))
        let rx = paneWidth + ribbonWidth
        drawSide("B", urls.1, edited.1, CGRect(x: rx, y: 0, width: bounds.width - rx - DiffCanvasView.stripWidth, height: bounds.height))
    }

    private func drawSide(_ letter: String, _ url: URL?, _ edited: Bool, _ rect: CGRect, title: String? = nil) {
        var x = rect.minX + 12
        let mid = rect.midY
        Badge.draw(letter, in: CGRect(x: x, y: mid - 8, width: 18, height: 16), filled: true)
        x += 26

        let font = NSFont.systemFont(ofSize: 12)
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.secondaryText]
        let main: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
        if let title {
            let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text])
            t.draw(at: CGPoint(x: x, y: mid - 8))
            x += t.size().width + 14
        }
        guard let url else {
            NSAttributedString(string: "No file", attributes: dim).draw(at: CGPoint(x: x, y: mid - 8))
            return
        }
        let dir = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        var comps = dir.split(separator: "/").map(String.init)
        var truncated = false
        // A bar with the whole width to itself would otherwise spell out a very long path.
        if title != nil, comps.count > 3 {
            comps = Array(comps.suffix(3))
            truncated = true
        }
        let name = NSMutableAttributedString(string: url.lastPathComponent, attributes: main)
        if edited { name.append(NSAttributedString(string: " — Edited", attributes: dim)) }
        let sep = NSAttributedString(string: "  ⟩  ", attributes: dim)
        let available = rect.maxX - x - 20 - name.size().width
        func crumbs() -> NSAttributedString {
            let s = NSMutableAttributedString()
            if truncated { s.append(NSAttributedString(string: "…", attributes: dim)); s.append(sep) }
            for c in comps {
                s.append(NSAttributedString(string: c, attributes: dim))
                s.append(sep)
            }
            return s
        }
        var path = crumbs()
        while path.size().width > available && !comps.isEmpty {
            comps.removeFirst()
            truncated = true
            path = crumbs()
        }
        if path.size().width <= available {
            path.draw(at: CGPoint(x: x, y: mid - 8))
            x += path.size().width
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.draw(in: CGRect(x: x, y: mid - 8, width: 16, height: 16))
        x += 20
        name.draw(with: CGRect(x: x, y: mid - 8, width: max(10, rect.maxX - x), height: 17),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The purple A / B badge.
enum Badge {
    static func draw(_ letter: String, in r: CGRect, filled: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        (filled ? Theme.accent : Theme.accentSoft).setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r.height * 0.7, weight: .bold),
            .foregroundColor: filled ? NSColor.white : Theme.accent,
        ]
        let s = NSAttributedString(string: letter, attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }
}

/// Bottom bar: view toggles on the left, status in the middle, change navigation on the right.
/// For an image comparison the toggles give way to the image mode and the navigation to zoom controls.
@MainActor
final class BottomBarView: NSView {
    static let height: CGFloat = 32

    let wrapButton = BottomBarView.iconButton("arrow.turn.down.left", "Wrap Lines", #selector(AppDelegate.toggleWrap(_:)))
    let invisiblesButton = BottomBarView.iconButton("paragraphsign", "Show Invisibles", #selector(AppDelegate.toggleInvisibles(_:)))
    let expandButton = BottomBarView.iconButton("arrow.up.and.down.text.horizontal", "Expand Unchanged Lines", #selector(ComparisonWindowController.toggleExpandAll(_:)))
    let syntaxButton = BottomBarView.iconButton("chevron.left.forwardslash.chevron.right", "Syntax Highlighting", #selector(AppDelegate.toggleSyntax(_:)))
    let copyLeftButton = BottomBarView.iconButton("arrow.left.to.line", "Copy Change to Left (⌥⌘←)", #selector(ComparisonWindowController.copyToLeft(_:)))
    let copyRightButton = BottomBarView.iconButton("arrow.right.to.line", "Copy Change to Right (⌥⌘→)", #selector(ComparisonWindowController.copyToRight(_:)))
    let useLeftButton = BottomBarView.iconButton("a.square", "Use A for This Change (⌥⌘1)", #selector(MergeWindowController.useLeft(_:)))
    let useRightButton = BottomBarView.iconButton("b.square", "Use B for This Change (⌥⌘2)", #selector(MergeWindowController.useRight(_:)))
    let useBothButton = BottomBarView.iconButton("plus.square.on.square", "Use Both, A Then B (⌥⌘3)", #selector(MergeWindowController.useBoth(_:)))
    let nextConflictButton = BottomBarView.iconButton("exclamationmark.triangle", "Next Unresolved Conflict (⌃⌘↓)", #selector(MergeWindowController.nextConflict(_:)))
    let statusLabel = NSTextField(labelWithString: "")
    let changeLabel = NSTextField(labelWithString: "")
    let previousButton = BottomBarView.iconButton("chevron.up", "Previous Change", #selector(ComparisonWindowController.previousChange(_:)))
    let nextButton = BottomBarView.iconButton("chevron.down", "Next Change", #selector(ComparisonWindowController.nextChange(_:)))

    let imageModeControl: NSSegmentedControl = {
        let c = NSSegmentedControl(labels: ImageMode.allCases.map(\.title), trackingMode: .selectOne,
                                   target: nil, action: #selector(AppDelegate.setImageMode(_:)))
        c.controlSize = .small
        c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return c
    }()
    /// Overlay mode's cross-fade from A to B.
    let opacitySlider: NSSlider = {
        let s = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.controlSize = .small
        s.toolTip = "Blend between A and B"
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return s
    }()
    private let opacityLabels = [NSTextField(labelWithString: "A"), NSTextField(labelWithString: "B")]
    let zoomLabel = NSTextField(labelWithString: "")
    let zoomOutButton = BottomBarView.iconButton("minus.magnifyingglass", "Zoom Out", #selector(ImageDiffView.zoomOut(_:)))
    let zoomInButton = BottomBarView.iconButton("plus.magnifyingglass", "Zoom In", #selector(ImageDiffView.zoomIn(_:)))
    let fitButton = BottomBarView.iconButton("arrow.up.left.and.arrow.down.right", "Zoom to Fit", #selector(ImageDiffView.zoomToFit(_:)))

    /// Switches between the text controls and the image controls.
    var showsImageControls = false { didSet { updateVisibility() } }
    var showsOpacity = false { didSet { updateVisibility() } }
    /// In a three-way merge the copy buttons give way to the ones that choose a side for the result.
    var showsMergeControls = false { didSet { updateVisibility() } }

    private func updateVisibility() {
        for v in [wrapButton, invisiblesButton, expandButton, syntaxButton, previousButton, nextButton] {
            v.isHidden = showsImageControls
        }
        for v in [copyLeftButton, copyRightButton] { v.isHidden = showsImageControls || showsMergeControls }
        for v in [useLeftButton, useRightButton, useBothButton, nextConflictButton] { v.isHidden = !showsMergeControls }
        for v in [imageModeControl, zoomLabel, zoomOutButton, zoomInButton, fitButton] as [NSView] { v.isHidden = !showsImageControls }
        for v in [opacitySlider] + opacityLabels as [NSView] { v.isHidden = !(showsImageControls && showsOpacity) }
    }

    static func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: tip)!
        let b = NSButton(image: image, target: nil, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        b.contentTintColor = Theme.secondaryText
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [statusLabel, changeLabel, zoomLabel] + opacityLabels {
            l.font = .systemFont(ofSize: 12)
            l.textColor = Theme.secondaryText
            l.lineBreakMode = .byTruncatingTail
        }
        zoomLabel.alignment = .right
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let left = NSStackView(views: [wrapButton, invisiblesButton, expandButton, syntaxButton,
                                       imageModeControl, opacityLabels[0], opacitySlider, opacityLabels[1]])
        left.spacing = 4
        left.setCustomSpacing(14, after: imageModeControl)
        let right = NSStackView(views: [nextConflictButton, useLeftButton, useRightButton, useBothButton,
                                        copyLeftButton, copyRightButton, changeLabel, previousButton, nextButton,
                                        zoomLabel, zoomOutButton, zoomInButton, fitButton])
        right.spacing = 6
        right.setCustomSpacing(14, after: nextConflictButton)
        right.setCustomSpacing(2, after: useLeftButton)
        right.setCustomSpacing(2, after: useRightButton)
        right.setCustomSpacing(14, after: useBothButton)
        right.setCustomSpacing(2, after: copyLeftButton)
        right.setCustomSpacing(14, after: copyRightButton)
        right.setCustomSpacing(12, after: changeLabel)
        right.setCustomSpacing(2, after: zoomOutButton)
        right.setCustomSpacing(2, after: zoomInButton)
        updateVisibility()
        for v in [left, right, statusLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setToggle(_ b: NSButton, on: Bool) {
        b.contentTintColor = on ? Theme.accent : Theme.secondaryText
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A centred message shown in place of the diff: binary files, errors, empty states.
@MainActor
final class PlacardView: NSView {
    private let image = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        image.contentTintColor = Theme.foldText
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.text
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Theme.secondaryText
        subtitle.alignment = .center
        let stack = NSStackView(views: [image, title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: image)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String, title: String, subtitle: String) {
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBackground.setFill()
        bounds.fill()
    }
}

/// A plain view that paints the chrome colour and accepts dropped files.
@MainActor
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var background: NSColor = Theme.chrome

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
    }

    static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && Self.urls(sender).count >= 2 ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.urls(sender)
        guard urls.count >= 2 else { return false }
        onDrop?(urls)
        return true
    }
}
