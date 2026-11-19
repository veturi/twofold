import AppKit
import DiffCore

/// Recent repositories, and switches that make Twofold Git's diff tool and merge tool.
///
/// The switches always show what Git's global configuration says, read again whenever the page is
/// shown and after every change; nothing about that state is kept here between reads.
@MainActor
final class GitPage: NSView {
    private let repoGrid = NSStackView()
    private var rows: [GitIntegration.Tool: ToolRow] = [:]
    private let message = WelcomeText.wrapping("", size: 12, color: Theme.removed.marker, width: 640)
    private var integration: GitIntegration?
    private(set) var states: [GitIntegration.Tool: GitIntegration.State] = [:]
    var onOpenRepository: ((URL?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = WelcomeText.title("Git")
        let subtitle = WelcomeText.label("See a repository’s uncommitted changes live, and let Git open Twofold for you.", size: 12.5,
                                         color: Theme.welcomeSecondary)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4

        let open = WelcomeButton("Open Repository…", symbol: "plus", style: .primary, height: 28) { [weak self] in
            self?.onOpenRepository?(nil)
        }
        let repoHeader = NSStackView(views: [WelcomeText.section("Repositories"), NSView(), open])
        repoGrid.orientation = .vertical
        repoGrid.spacing = 12

        let diff = ToolRow(tool: .diff, title: "Diff tool", detail: "git difftool opens the changes here, and git difftool -d the whole tree.",
                           symbol: "rectangle.split.2x1", tint: Theme.modified.marker)
        let merge = ToolRow(tool: .merge, title: "Merge tool", detail: "git mergetool resolves conflicts in a three-way merge.",
                            symbol: "arrow.triangle.merge", tint: Theme.conflict.marker)
        rows = [.diff: diff, .merge: merge]
        for (tool, row) in rows {
            row.onToggle = { [weak self] on in Task { await self?.set(tool, on: on) } }
            row.onUpdate = { [weak self] in Task { await self?.set(tool, on: true) } }
        }
        let tools = WelcomePanel()
        let toolStack = NSStackView(views: [diff, WelcomeRule(), merge])
        toolStack.orientation = .vertical
        toolStack.spacing = 0
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        tools.addSubview(toolStack)
        for v in [diff, merge] { v.widthAnchor.constraint(equalTo: toolStack.widthAnchor).isActive = true }
        message.isHidden = true
        let footnote = WelcomeText.wrapping("Repositories that name their own tool keep it. Turning a switch off removes Twofold’s settings again.",
                                            size: 11.5, color: Theme.welcomeTertiary, width: 640)

        let stack = NSStackView(views: [heading, repoHeader, repoGrid, WelcomeText.section("Use Twofold from Git"), tools, message, footnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(24, after: heading)
        stack.setCustomSpacing(24, after: repoGrid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
            repoHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            repoGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tools.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolStack.topAnchor.constraint(equalTo: tools.topAnchor),
            toolStack.bottomAnchor.constraint(equalTo: tools.bottomAnchor),
            toolStack.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            toolStack.trailingAnchor.constraint(equalTo: tools.trailingAnchor),
        ])
        show(states: [:], ready: false)
        reloadRepositories()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Repositories

    func reloadRepositories() {
        repoGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let repos = Array(RecentComparisons.available.filter { $0.kind == .repository }.prefix(4))
        guard !repos.isEmpty else {
            let card = WelcomeControl()
            card.fill = Theme.welcomePanel
            card.stroke = Theme.welcomeCardStroke
            card.radius = 12
            card.action = { [weak self] in self?.onOpenRepository?(nil) }
            let text = WelcomeText.label("Open a folder inside a Git repository to watch its uncommitted changes as you work.",
                                         size: 12.5, color: Theme.welcomeSecondary)
            let row = NSStackView(views: [IconTile(symbol: "arrow.triangle.branch", tint: Theme.welcomeLink), text])
            row.spacing = 12
            card.embed(row, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
            repoGrid.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: repoGrid.widthAnchor).isActive = true
            return
        }
        for pair in stride(from: 0, to: repos.count, by: 2) {
            let line = NSStackView()
            line.spacing = 12
            line.distribution = .fillEqually
            for item in repos[pair..<min(pair + 2, repos.count)] {
                let card = RepositoryCard(item)
                card.action = { [weak self] in self?.onOpenRepository?(item.leftURL) }
                line.addArrangedSubview(card)
            }
            if repos.count - pair == 1 { line.addArrangedSubview(NSView()) }
            repoGrid.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: repoGrid.widthAnchor).isActive = true
        }
    }

    // MARK: Integration

    /// Reads Git's configuration and shows it. Called whenever the page is shown and after every change.
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
        if let failure { fail(failure) }
    }

    private func show(states: [GitIntegration.Tool: GitIntegration.State], ready: Bool) {
        self.states = states
        for (tool, row) in rows {
            row.isEnabled = ready
            guard ready else { row.set(on: false, status: nil, canUpdate: false); continue }
            switch states[tool] ?? .off(other: nil) {
            case .on:
                row.set(on: true, status: .good("✓ \(tool.key) = \(GitIntegration.name)"), canUpdate: false)
            case .off(let other?):
                row.set(on: false, status: .warning("\(tool.key) = \(other) · turning this on replaces it"), canUpdate: false)
            case .off(nil):
                row.set(on: false, status: .plain("\(tool.key) is not set"), canUpdate: false)
            case .custom(let command):
                row.set(on: true, status: .warning("Set up with a different command: \(command)"), canUpdate: true)
            }
        }
    }

    private func fail(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
    }
}

/// A recent repository: its name and folder, then its branch and how many files have changed.
@MainActor
private final class RepositoryCard: WelcomeControl {
    private let chips = NSStackView()

    init(_ item: RecentComparison) {
        super.init(frame: .zero)
        fill = Theme.welcomePanel
        hoverFill = Theme.welcomeCardHover
        stroke = Theme.welcomeCardStroke
        radius = 12
        let name = WelcomeText.label(item.title, size: 13, weight: .semibold)
        let path = WelcomeText.label((item.left as NSString).abbreviatingWithTildeInPath, size: 11, color: Theme.welcomeTertiary)
        let text = NSStackView(views: [name, path])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let top = NSStackView(views: [IconTile(symbol: "arrow.triangle.branch", tint: Theme.welcomeLink), text])
        top.spacing = 10
        chips.spacing = 8
        chips.addArrangedSubview(Chip("…"))
        let stack = NSStackView(views: [top, chips])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        embed(stack, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        toolTip = item.left
        setAccessibilityLabel("Open \(item.title)")
        Task { [weak self] in
            let status = await Self.status(item.leftURL)
            self?.show(status)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @concurrent
    private static func status(_ url: URL) async -> GitStatus? {
        try? WorkingCopy.locate(url)?.status()
    }

    private func show(_ status: GitStatus?) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let status else {
            chips.addArrangedSubview(Chip("Not available"))
            return
        }
        chips.addArrangedSubview(Chip(status.branch ?? "Detached", symbol: "smallcircle.filled.circle"))
        let n = status.changes.count
        chips.addArrangedSubview(n == 0
            ? Chip("Clean", color: Theme.welcomeStatusGood, background: Theme.added.stroke.withAlphaComponent(0.16))
            : Chip(n == 1 ? "1 change" : "\(n) changes", color: Theme.modified.marker, background: Theme.modified.stroke.withAlphaComponent(0.16)))
    }
}

/// One tool: its name, what turning it on does, what Git says now, and the switch.
@MainActor
private final class ToolRow: NSView {
    enum Status {
        case good(String), warning(String), plain(String)
    }

    private let toggle = NSSwitch()
    private let status = WelcomeText.label("", size: 11, color: Theme.welcomeTertiary)
    private let update = WelcomeButton("Use This Copy of Twofold", symbol: nil, style: .secondary, height: 24) {}
    var onToggle: ((Bool) -> Void)?
    var onUpdate: (() -> Void)?

    var isEnabled = true {
        didSet {
            toggle.isEnabled = isEnabled
            update.isEnabled = isEnabled
        }
    }

    init(tool: GitIntegration.Tool, title: String, detail: String, symbol: String, tint: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = WelcomeText.label(title, size: 13, weight: .semibold)
        let about = WelcomeText.label(detail, size: 11.5, color: Theme.welcomeSecondary)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.isSelectable = true
        update.action = { [weak self] in self?.onUpdate?() }
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(title)
        let text = NSStackView(views: [name, about, status, update])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(6, after: status)
        let row = NSStackView(views: [IconTile(symbol: symbol, tint: tint), text, NSView(), toggle])
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(on: Bool, status text: Status?, canUpdate: Bool) {
        toggle.state = on ? .on : .off
        switch text {
        case .good(let s)?: status.stringValue = s; status.textColor = Theme.welcomeStatusGood
        case .warning(let s)?: status.stringValue = s; status.textColor = Theme.welcomeStatusWarning
        case .plain(let s)?: status.stringValue = s; status.textColor = Theme.welcomeTertiary
        case nil: status.stringValue = ""
        }
        status.isHidden = text == nil
        update.isHidden = !canUpdate
    }

    @objc private func toggled() { onToggle?(toggle.state == .on) }
}
