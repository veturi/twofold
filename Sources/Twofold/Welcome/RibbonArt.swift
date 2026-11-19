import AppKit

/// The start window's background: soft glows under a fan of curves, drawn like the connectors in the
/// centre ribbon of a comparison. They leave the left edge in a tight bundle and spread out to the
/// right, and four of the gaps between them are filled in the change colours.
@MainActor
final class RibbonBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Self.draw(in: cg, size: bounds.size, art: Theme.ribbonArt(dark: dark))
    }

    /// Strand count; band positions below are strand indices.
    private static let strands = 26

    /// Where strand `t` (0...1) leaves the left edge and arrives at the right edge.
    private static func ends(_ t: CGFloat, _ h: CGFloat) -> (CGFloat, CGFloat) {
        (h * 0.30 + (t - 0.5) * h * 0.22, h * 0.62 + (t - 0.5) * h * 1.05)
    }

    static func draw(in cg: CGContext, size: CGSize, art: Theme.RibbonArt) {
        let w = size.width, h = size.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let base = CGGradient(colorsSpace: space, colors: art.base as CFArray, locations: [0, 0.55, 1]) {
            cg.drawLinearGradient(base, start: .zero, end: CGPoint(x: w, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for glow in art.glows {
            guard let clear = glow.color.copy(alpha: 0),
                  let g = CGGradient(colorsSpace: space, colors: [glow.color, clear] as CFArray, locations: [0, 1]) else { continue }
            cg.saveGState()
            // An ellipse that scales with the window, as an SVG gradient in bounding box units would.
            cg.translateBy(x: glow.x * w, y: glow.y * h)
            cg.scaleBy(x: w, y: h)
            cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: glow.radius, options: [])
            cg.restoreGState()
        }

        let x0: CGFloat = -40, x1 = w + 40
        let c1 = x0 + (x1 - x0) * 0.42, c2 = x0 + (x1 - x0) * 0.58
        func strand(_ k: Int) -> (CGFloat, CGFloat) { ends(CGFloat(k) / CGFloat(strands - 1), h) }

        cg.setLineCap(.round)
        for k in 0..<strands {
            let t = CGFloat(k) / CGFloat(strands - 1)
            let (yl, yr) = strand(k)
            let o = art.strandOpacity
            let alpha = o.lowerBound + (o.upperBound - o.lowerBound) * (0.5 + 0.5 * sin(t * 9))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: yl))
            path.addCurve(to: CGPoint(x: x1, y: yr), control1: CGPoint(x: c1, y: yl), control2: CGPoint(x: c2, y: yr))
            cg.addPath(path)
            cg.setStrokeColor(art.strand.withAlphaComponent(alpha).cgColor)
            cg.setLineWidth(0.8 + 1.2 * abs(sin(t * 5.3)))
            cg.strokePath()
        }

        for (color, (a, b)) in zip(art.bands, [(4, 6), (11, 12), (15, 17), (21, 22)]) {
            let (la, ra) = strand(a), (lb, rb) = strand(b)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: la))
            path.addCurve(to: CGPoint(x: x1, y: ra), control1: CGPoint(x: c1, y: la), control2: CGPoint(x: c2, y: ra))
            path.addLine(to: CGPoint(x: x1, y: rb))
            path.addCurve(to: CGPoint(x: x0, y: lb), control1: CGPoint(x: c2, y: rb), control2: CGPoint(x: c1, y: lb))
            path.closeSubpath()
            let peak = art.bandOpacity
            let colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(peak).cgColor,
                          color.withAlphaComponent(peak * 0.15).cgColor]
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.45, 1]) else { continue }
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            cg.drawLinearGradient(g, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
            cg.restoreGState()
        }
    }
}

/// The small ribbon between the A and B wells: a modified, an added and a removed band.
@MainActor
final class WellConnectorView: NSView {
    override var isFlipped: Bool { true }
    var muted = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 168) }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, s = bounds.height / 168
        if muted {
            cg.setFillColor(Theme.removed.stroke.withAlphaComponent(0.5).cgColor)
            cg.fill(CGRect(x: w / 2 - 14, y: bounds.midY - 0.75, width: 28, height: 1.5))
            return
        }
        // Left top, left bottom, right top, right bottom, in the 168 point tall design.
        let bands: [(NSColor, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (Theme.modified.stroke, 40, 60, 30, 66),
            (Theme.added.stroke, 92, 92, 86, 116),
            (Theme.removed.stroke, 120, 140, 132, 133),
        ]
        for (color, lt, lb, rt, rb) in bands {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: lt * s))
            path.addCurve(to: CGPoint(x: w, y: rt * s), control1: CGPoint(x: w / 2, y: lt * s), control2: CGPoint(x: w / 2, y: rt * s))
            path.addLine(to: CGPoint(x: w, y: rb * s))
            path.addCurve(to: CGPoint(x: 0, y: lb * s), control1: CGPoint(x: w / 2, y: rb * s), control2: CGPoint(x: w / 2, y: lb * s))
            path.closeSubpath()
            cg.addPath(path)
            cg.setFillColor(color.withAlphaComponent(0.42).cgColor)
            cg.fillPath()
        }
    }
}

/// The app icon with a soft glow of the accent colour around it.
@MainActor
final class GlowingIconView: NSView {
    private let size: CGFloat
    var tilt: CGFloat = 0 { didSet { needsDisplay = true } }

    init(size: CGFloat) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, let icon = NSApp.applicationIconImage else { return }
        cg.saveGState()
        if tilt != 0 {
            cg.translateBy(x: bounds.midX, y: bounds.midY)
            cg.rotate(by: tilt * .pi / 180)
            cg.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        cg.setShadow(offset: CGSize(width: 0, height: -size * 0.1), blur: size * 0.38, color: Theme.welcomeGlow.cgColor)
        icon.draw(in: bounds)
        cg.restoreGState()
    }
}
