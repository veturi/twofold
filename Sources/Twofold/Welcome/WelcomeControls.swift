import AppKit

/// Text in the start window's type scale.
@MainActor
enum WelcomeText {
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.welcomeText) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func wrapping(_ text: String, size: CGFloat, color: NSColor = Theme.welcomeSecondary, width: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = width
        l.isSelectable = false
        return l
    }

    /// A small capitalised section heading, such as JUMP BACK IN.
    static func section(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .kern: 0.6, .foregroundColor: Theme.welcomeTertiary,
        ])
        return l
    }

    static func title(_ text: String) -> NSTextField {
        label(text, size: 24, weight: .bold)
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
}

/// A rounded surface that can be clicked: cards, rows, buttons and sidebar items.
@MainActor
class WelcomeControl: NSView {
    var action: (() -> Void)?
    var fill: NSColor? { didSet { needsDisplay = true } }
    var hoverFill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 10 { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45; needsDisplay = true } }
    private(set) var hovering = false { didSet { if hovering != oldValue { needsDisplay = true; hoverChanged() } } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lets subclasses show or hide things while the pointer is over them.
    func hoverChanged() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside && isEnabled { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
    override func resetCursorRects() { if isEnabled && action != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func drawBackground(_ path: NSBezierPath) {
        if let f = (hovering && isEnabled ? hoverFill ?? fill : fill) {
            f.setFill()
            path.fill()
        }
        if pressed {
            Theme.welcomeHover.setFill()
            path.fill()
        }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius))
    }

    /// Pins `content` inside the control with the given insets.
    func embed(_ content: NSView, insets: NSEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
        ])
    }
}

/// A push button in the start window's style: the accent gradient, or a quiet translucent one.
@MainActor
final class WelcomeButton: WelcomeControl {
    enum Style { case primary, secondary }
    private let style: Style

    init(_ title: String, symbol: String?, shortcut: String? = nil, style: Style, height: CGFloat = 34, action: @escaping () -> Void) {
        self.style = style
        super.init(frame: .zero)
        self.action = action
        radius = height < 30 ? 7 : 9
        if style == .secondary {
            fill = Theme.welcomeCard
            hoverFill = Theme.welcomeCardHover
            stroke = Theme.welcomeCardStroke
        }
        let primary = style == .primary
        var views: [NSView] = []
        if let symbol {
            views.append(WelcomeText.symbol(symbol, size: 12.5, color: primary ? Theme.welcomeButtonText : Theme.welcomeSecondary))
        }
        views.append(WelcomeText.label(title, size: height < 30 ? 12 : 13, weight: primary ? .semibold : .medium,
                                       color: primary ? Theme.welcomeButtonText : Theme.welcomeText))
        if let shortcut {
            views.append(WelcomeText.label(shortcut, size: 11.5, color: primary ? Theme.welcomeOnHeroSecondary : Theme.welcomeTertiary))
        }
        let row = NSStackView(views: views)
        row.spacing = 7
        embed(row, insets: NSEdgeInsets(top: 0, left: primary ? 16 : 14, bottom: 0, right: primary ? 16 : 14))
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        guard style == .primary else { return super.draw(dirtyRect) }
        NSGradient(starting: Theme.welcomeButtonTop, ending: Theme.welcomeButtonBottom)?.draw(in: path, angle: -90)
        if hovering && isEnabled {
            NSColor(white: 1, alpha: 0.10).setFill()
            path.fill()
        }
        drawBackground(path)
    }
}

/// A rounded square holding a symbol, tinted with one of the change colours.
@MainActor
final class IconTile: NSView {
    private let tint: NSColor

    init(symbol: String, tint: NSColor, size: CGFloat = 32) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        let image = WelcomeText.symbol(symbol, size: size * 0.44, color: tint)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        image.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        image.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width * 0.25, yRadius: bounds.width * 0.25).fill()
    }
}

/// A small rounded label, such as a kind tag or a branch name.
@MainActor
final class Chip: NSView {
    private let background: NSColor

    init(_ text: String, symbol: String? = nil, color: NSColor = Theme.welcomeSecondary, background: NSColor = Theme.welcomeChip) {
        self.background = background
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = []
        if let symbol { views.append(WelcomeText.symbol(symbol, size: 9.5, color: color)) }
        views.append(WelcomeText.label(text, size: 10.5, weight: .medium, color: color))
        let row = NSStackView(views: views)
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A translucent rounded panel that groups rows or cards.
@MainActor
final class WelcomePanel: NSView {
    var fill = Theme.welcomePanel

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        fill.setFill()
        path.fill()
        Theme.welcomeCardStroke.setStroke()
        path.stroke()
    }
}

/// A one point line in the card stroke colour.
@MainActor
final class WelcomeRule: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.welcomeCardStroke.setFill()
        bounds.fill()
    }
}

/// A view that lays out its subviews from the top, for scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
