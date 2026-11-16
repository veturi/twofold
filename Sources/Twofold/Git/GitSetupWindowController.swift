import AppKit

/// The Git Integration window: one switch each for using Twofold as Git's diff tool and merge tool.
///
/// The switches always show what Git's global configuration says, read again after every change.
@MainActor
final class GitSetupWindowController: NSWindowController, NSWindowDelegate {
    private var integration: GitIntegration?
    private var rows: [GitIntegration.Tool: Row] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private(set) var states: [GitIntegration.Tool: GitIntegration.State] = [:]
    var onClose: (() -> Void)?

    private static let width: CGFloat = 460

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Git Integration"
        window.backgroundColor = Theme.chrome
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        let heading = NSTextField(labelWithString: "Use Twofold from Git")
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.textColor = Theme.text
        let intro = Self.note("Turn on what you want. Twofold updates your global Git configuration for you, with no commands to type.")

        let diff = Row(title: "Diff tool", detail: "git difftool opens each changed file in Twofold, and git difftool -d opens the whole tree.")
        let merge = Row(title: "Merge tool", detail: "git mergetool opens each conflicted file in Twofold’s three-way merge.")
        rows = [.diff: diff, .merge: merge]
        for (tool, row) in rows {
            row.onToggle = { [weak self] on in self?.change(tool, on: on) }
            row.onUpdate = { [weak self] in self?.change(tool, on: true) }
        }

        let box = NSStackView(views: [diff, Self.rule(), merge])
        box.orientation = .vertical
        box.spacing = 0
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        for row in [diff, merge] { row.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }

        message.font = .systemFont(ofSize: 12)
        message.textColor = Theme.removed.marker
        message.isHidden = true
        let footer = Self.note("Repositories that name their own tool keep it. Turning a switch off removes Twofold’s settings again.")

        let stack = NSStackView(views: [heading, intro, box, message, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(12, after: box)
        stack.setCustomSpacing(10, after: message)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let inner = Self.width - 44
        for view in [intro, box, message, footer] as [NSView] { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }

        let root = BoxColours(box: box)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        show(states: [:], ready: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.secondaryText
        return label
    }

    private static func rule() -> NSView {
        let line = RuleView()
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: State

    /// Reads Git's configuration and shows it. Called when the window opens and after every change.
    func refresh() async {
        do {
            let (integration, states) = try await Self.read()
            self.integration = integration
            show(states: states, ready: true)
            fail(nil)
        } catch {
            integration = nil
            show(states: [:], ready: false)
            fail(error.message)
        }
        fit()
    }

    @concurrent
    private static func read() async throws(GitIntegration.Unavailable) -> (GitIntegration, [GitIntegration.Tool: GitIntegration.State]) {
        let integration = try GitIntegration.locate()
        return (integration, try integration.states())
    }

    @concurrent
    private static func write(_ integration: GitIntegration, _ tool: GitIntegration.Tool, on: Bool) async throws(GitIntegration.Unavailable) {
        if on { try integration.enable(tool) } else { try integration.disable(tool) }
    }

    private func change(_ tool: GitIntegration.Tool, on: Bool) {
        Task { await set(tool, on: on) }
    }

    func set(_ tool: GitIntegration.Tool, on: Bool) async {
        guard let integration else { return }
        rows.values.forEach { $0.isEnabled = false }
        var failure: String?
        do {
            try await Self.write(integration, tool, on: on)
        } catch {
            failure = error.message
        }
        await refresh()
        if let failure { fail(failure); fit() }
    }

    private func show(states: [GitIntegration.Tool: GitIntegration.State], ready: Bool) {
        self.states = states
        for (tool, row) in rows {
            row.isEnabled = ready
            switch states[tool] ?? .off(other: nil) {
            case .on:
                row.set(on: true, status: nil, canUpdate: false)
            case .off(let other):
                row.set(on: false, status: other.map { "Git now uses \($0). Turning this on replaces it." }, canUpdate: false)
            case .custom(let command):
                row.set(on: true, status: "Set up with a different command:\n\(command)", canUpdate: true)
            }
        }
    }

    private func fail(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
    }

    /// Resizes the window to its content, keeping the top edge where it is.
    private func fit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// One tool: its name, what turning it on does, a note about the current state, and the switch.
@MainActor
private final class Row: NSView {
    private let toggle = NSSwitch()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let update = NSButton(title: "Use This Copy of Twofold", target: nil, action: nil)
    var onToggle: ((Bool) -> Void)?
    var onUpdate: (() -> Void)?

    /// The window's inner width less the row's insets, the switch and the gap before it.
    private static let textWidth: CGFloat = 416 - 28 - 16 - 44

    var isEnabled = true {
        didSet {
            toggle.isEnabled = isEnabled
            update.isEnabled = isEnabled
        }
    }

    init(title: String, detail: String) {
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Theme.text
        let about = NSTextField(wrappingLabelWithString: detail)
        about.font = .systemFont(ofSize: 12)
        about.textColor = Theme.secondaryText
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.secondaryText
        status.isSelectable = true
        update.controlSize = .small
        update.target = self
        update.action = #selector(updated)
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setAccessibilityLabel(title)

        let text = NSStackView(views: [name, about, status, update])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(6, after: about)
        text.setCustomSpacing(6, after: status)
        // Wrapping labels need to know their width to report a height.
        for label in [about, status] { label.preferredMaxLayoutWidth = Self.textWidth }
        text.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        let row = NSStackView(views: [text, toggle])
        row.alignment = .top
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            // The text decides the height; the switch is shorter and sits at the top.
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        set(on: false, status: nil, canUpdate: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(on: Bool, status text: String?, canUpdate: Bool) {
        toggle.state = on ? .on : .off
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        update.isHidden = !canUpdate
    }

    @objc private func toggled() { onToggle?(toggle.state == .on) }
    @objc private func updated() { onUpdate?() }
}

/// A hairline in the separator colour.
@MainActor
private final class RuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        bounds.fill()
    }
}

/// The window's content view. Layer colours do not follow the appearance by themselves, so it sets them again on a change.
@MainActor
private final class BoxColours: NSView {
    private let box: NSView

    init(box: NSView) {
        self.box = box
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = Theme.paneBackground.cgColor
            box.layer?.borderColor = Theme.separator.cgColor
        }
    }
}
