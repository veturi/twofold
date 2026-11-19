import AppKit

/// The highlights of the latest major release. The sidebar badges the page until it has been seen;
/// it never opens by itself.
@MainActor
enum WhatsNew {
    struct Feature {
        let symbol: String
        let tint: NSColor
        let title: String
        let detail: String
    }

    /// Change this, and the features, with each major release; the badge then appears again.
    static let version = "1.1"
    static let headline = "Merge, edit, and watch your working copy"
    static let summary = "The biggest update since 1.0. Still free, still open source."
    static let notes = URL(string: "https://github.com/veturi/twofold/releases")!

    static var features: [Feature] {
        [
            Feature(symbol: "arrow.triangle.merge", tint: Theme.conflict.marker, title: "Three-way merge",
                    detail: "Resolve conflicts from git mergetool, one click per side."),
            Feature(symbol: "pencil.line", tint: Theme.welcomeLink, title: "Edit in place",
                    detail: "Type in either pane, copy changes across, undo, save."),
            Feature(symbol: "waveform.path.ecg", tint: Theme.added.marker, title: "Live working copy",
                    detail: "Open a repository and watch changes as you work."),
            Feature(symbol: "rectangle.grid.1x2", tint: Theme.modified.marker, title: "Unified layout",
                    detail: "One column, plus find and ignore whitespace."),
            Feature(symbol: "photo", tint: Theme.removed.marker, title: "Image difference",
                    detail: "Pixels marked by how much they differ."),
            Feature(symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.modified.marker, title: "Syntax colours",
                    detail: "29 languages and formats, light and dark."),
        ]
    }

    private static let seenKey = "whatsNewSeen"

    static var isUnseen: Bool { UserDefaults.standard.string(forKey: seenKey) != version }

    static func markSeen() { UserDefaults.standard.set(version, forKey: seenKey) }
}

@MainActor
final class WhatsNewPage: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let hero = HeroView()

        var lines: [NSStackView] = []
        let features = WhatsNew.features
        for start in stride(from: 0, to: features.count, by: 3) {
            let line = NSStackView(views: features[start..<min(start + 3, features.count)].map(Self.tile))
            line.spacing = 10
            line.distribution = .fillEqually
            line.alignment = .top
            lines.append(line)
        }
        let grid = NSStackView(views: lines)
        grid.orientation = .vertical
        grid.spacing = 10
        for line in lines { line.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }

        let note = WelcomeText.label("Shown here after each major update. Never in the way.", size: 11.5, color: Theme.welcomeTertiary)
        let link = WelcomeLink("Full release notes ↗", size: 12) { NSWorkspace.shared.open(WhatsNew.notes) }
        let footer = NSStackView(views: [note, NSView(), link])

        let stack = NSStackView(views: [hero, grid, footer])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
            hero.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hero.heightAnchor.constraint(equalToConstant: 176),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func tile(_ f: WhatsNew.Feature) -> NSView {
        let panel = WelcomePanel()
        let title = WelcomeText.label(f.title, size: 13, weight: .semibold)
        let detail = WelcomeText.wrapping(f.detail, size: 11.5, width: 172)
        let stack = NSStackView(views: [IconTile(symbol: f.symbol, tint: f.tint, size: 30), title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
        ])
        return panel
    }
}

/// The release banner: the accent gradient, a few ribbon strands and the tilted app icon.
@MainActor
private final class HeroView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let chip = Chip("Twofold \(WhatsNew.version)", symbol: "sparkles", color: Theme.welcomeOnHero, background: Theme.welcomeOnHeroChip)
        let title = WelcomeText.wrapping(WhatsNew.headline, size: 23, color: Theme.welcomeOnHero, width: 400)
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let summary = WelcomeText.label(WhatsNew.summary, size: 12.5, color: Theme.welcomeOnHeroSecondary)
        let text = NSStackView(views: [chip, title, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 7
        text.translatesAutoresizingMaskIntoConstraints = false
        let icon = GlowingIconView(size: 150)
        icon.tilt = -8
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: Theme.welcomeHeroStart, ending: Theme.welcomeHeroEnd)?.draw(in: bounds, angle: 0)
        // Strands that leave a point left of the icon and fan out behind it, fading in from the left.
        let w = bounds.width, h = bounds.height
        let start = w * 0.45
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for k in 0..<9 {
            let yl = h * 0.40 + CGFloat(k) * 5, yr = -20 + CGFloat(k) * 26
            let p = CGMutablePath()
            p.move(to: CGPoint(x: start, y: yl))
            p.addCurve(to: CGPoint(x: w, y: yr), control1: CGPoint(x: start + w * 0.2, y: yl), control2: CGPoint(x: start + w * 0.26, y: yr))
            cg.saveGState()
            cg.addPath(p)
            cg.setLineWidth(1.4)
            cg.replacePathWithStrokedPath()
            cg.clip()
            let a = 0.08 + 0.03 * CGFloat(k % 3)
            let colors = [Theme.welcomeOnHero.withAlphaComponent(0).cgColor, Theme.welcomeOnHero.withAlphaComponent(a).cgColor]
            if let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.4]) {
                cg.drawLinearGradient(g, start: CGPoint(x: start, y: 0), end: CGPoint(x: w, y: 0), options: [.drawsAfterEndLocation])
            }
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.welcomeCardStroke.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16).stroke()
    }
}
