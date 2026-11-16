import AppKit
import DiffCore

/// Draws an image comparison in one of three modes and owns zooming and panning.
///
/// Both images share one view transform: the canvas is the union of their sizes, anchored top left.
@MainActor
final class ImageDiffView: NSView {
    private(set) var comparison: ImageComparison?
    var mode: ImageMode = .sideBySide {
        didSet {
            guard mode != oldValue else { return }
            clampCenter()
            needsDisplay = true
            onStateChange?()
        }
    }
    /// How much of B shows in Overlay mode: 0 is all A, 1 is all B.
    var overlayOpacity: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var onStateChange: (() -> Void)?

    /// Points per image pixel, or nil to fit the pane.
    private var zoom: CGFloat?
    /// The canvas point shown at the centre of a pane.
    private var center = CGPoint.zero

    private static let padding: CGFloat = 24
    private static let maxZoom: CGFloat = 32
    private static let zoomStep: CGFloat = 1.5
    private static let checkerSize: CGFloat = 8
    /// Above this many regions the outlines stop helping and are left out.
    private static let maxOutlinedRegions = 400

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setComparison(_ c: ImageComparison?, preserveView: Bool) {
        let sameCanvas = c?.diff.width == comparison?.diff.width && c?.diff.height == comparison?.diff.height
        comparison = c
        if !(preserveView && sameCanvas) {
            zoom = nil
            center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        }
        needsDisplay = true
        onStateChange?()
    }

    // MARK: Geometry

    private var canvasSize: CGSize {
        CGSize(width: comparison?.diff.width ?? 0, height: comparison?.diff.height ?? 0)
    }

    private var panes: [CGRect] {
        guard mode == .sideBySide else { return [bounds] }
        let half = floor((bounds.width - 1) / 2)
        return [CGRect(x: 0, y: 0, width: half, height: bounds.height),
                CGRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)]
    }

    /// The largest scale, up to actual size, at which the whole canvas fits a pane.
    private var fitScale: CGFloat {
        let pane = panes[0], size = canvasSize
        guard size.width > 0, size.height > 0 else { return 1 }
        let s = min((pane.width - 2 * Self.padding) / size.width, (pane.height - 2 * Self.padding) / size.height)
        return min(1, max(s, 0.001))
    }

    var scale: CGFloat { zoom ?? fitScale }
    var isFitted: Bool { zoom == nil }

    /// Where the canvas's top-left corner lands in a pane: centred when it fits, otherwise following `center`.
    private func origin(in pane: CGRect) -> CGPoint {
        let s = scale
        func axis(_ start: CGFloat, _ length: CGFloat, _ content: CGFloat, _ c: CGFloat) -> CGFloat {
            if content + 2 * Self.padding <= length { return (start + (length - content) / 2).rounded() }
            let o = start + length / 2 - c * s
            return min(start + Self.padding, max(start + length - Self.padding - content, o)).rounded()
        }
        return CGPoint(x: axis(pane.minX, pane.width, canvasSize.width * s, center.x),
                       y: axis(pane.minY, pane.height, canvasSize.height * s, center.y))
    }

    /// Pulls `center` back to what is actually shown, so panning never builds up hidden overshoot.
    private func clampCenter() {
        let pane = panes[0], o = origin(in: pane), s = scale
        center = CGPoint(x: (pane.midX - o.x) / s, y: (pane.midY - o.y) / s)
    }

    // MARK: Zoom and pan

    /// Sets the scale, keeping the image point under `anchor` (a point in this view) in place.
    func setZoom(_ z: CGFloat?, anchor: CGPoint? = nil) {
        guard comparison != nil else { return }
        let pane = anchor.flatMap { a in panes.first { $0.contains(a) } } ?? panes[0]
        let a = anchor.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: pane.midX, y: pane.midY)
        let o = origin(in: pane), old = scale
        let point = CGPoint(x: (a.x - o.x) / old, y: (a.y - o.y) / old)
        if let z, z > fitScale * 1.001 { zoom = min(z, Self.maxZoom) } else { zoom = nil }
        let s = scale
        center = CGPoint(x: point.x + (pane.midX - a.x) / s, y: point.y + (pane.midY - a.y) / s)
        clampCenter()
        needsDisplay = true
        onStateChange?()
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        guard comparison != nil else { return }
        center.x -= dx / scale
        center.y -= dy / scale
        clampCenter()
        needsDisplay = true
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(scale * Self.zoomStep) }
    @objc func zoomOut(_ sender: Any?) { setZoom(scale / Self.zoomStep) }
    @objc func zoomToFit(_ sender: Any?) { setZoom(nil) }
    @objc func zoomToActualSize(_ sender: Any?) { setZoom(1) }

    override func scrollWheel(with e: NSEvent) {
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        pan(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k)
    }

    override func magnify(with e: NSEvent) {
        setZoom(scale * (1 + e.magnification), anchor: convert(e.locationInWindow, from: nil))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard e.clickCount == 2 else { return }
        let p = convert(e.locationInWindow, from: nil)
        if isFitted { setZoom(fitScale < 1 ? 1 : 2, anchor: p) } else { setZoom(nil) }
    }

    override func mouseDragged(with e: NSEvent) {
        pan(dx: e.deltaX, dy: e.deltaY)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let z = zoom, z <= fitScale { zoom = nil }
        clampCenter()
        needsDisplay = true
        onStateChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.paneBackground.setFill()
        bounds.fill()
        guard let c = comparison else { return }
        let s = scale
        ctx.interpolationQuality = s >= 2 ? .none : .high

        switch mode {
        case .sideBySide:
            let p = panes
            drawSide(ctx, c.left, in: p[0])
            drawSide(ctx, c.right, in: p[1])
            Theme.separator.setFill()
            CGRect(x: p[0].maxX, y: 0, width: 1, height: bounds.height).fill()

        case .overlay:
            let o = origin(in: bounds)
            let canvas = CGRect(x: o.x, y: o.y, width: canvasSize.width * s, height: canvasSize.height * s)
            drawChecker(ctx, canvas)
            ctx.saveGState()
            ctx.clip(to: canvas)
            // Adding the two weighted images gives a true cross-fade, with no backdrop showing through.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setAlpha(1 - overlayOpacity)
            if let l = c.left { draw(ctx, l, at: o) }
            ctx.setBlendMode(.plusLighter)
            ctx.setAlpha(overlayOpacity)
            if let r = c.right { draw(ctx, r, at: o) }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            drawBorder(canvas)

        case .difference:
            let o = origin(in: bounds)
            let canvas = CGRect(x: o.x, y: o.y, width: canvasSize.width * s, height: canvasSize.height * s)
            if let base = c.right ?? c.left {
                ctx.saveGState()
                ctx.setAlpha(0.22)
                draw(ctx, base, at: o)
                ctx.restoreGState()
            }
            if let mask = c.mask {
                ctx.saveGState()
                ctx.translateBy(x: canvas.minX, y: canvas.maxY)
                ctx.scaleBy(x: 1, y: -1)
                let local = CGRect(origin: .zero, size: canvas.size)
                ctx.clip(to: local, mask: mask)
                ctx.setFillColor(Theme.imageDifference.cgColor)
                ctx.fill(local)
                ctx.restoreGState()
            }
            drawBorder(canvas)
            if c.diff.regions.count <= Self.maxOutlinedRegions {
                Theme.modified.stroke.setStroke()
                for r in c.diff.regions {
                    let box = CGRect(x: o.x + CGFloat(r.x) * s, y: o.y + CGFloat(r.y) * s,
                                     width: CGFloat(r.width) * s, height: CGFloat(r.height) * s).insetBy(dx: -4, dy: -4)
                    guard box.intersects(dirtyRect) else { continue }
                    let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }
    }

    private func drawSide(_ ctx: CGContext, _ image: CGImage?, in pane: CGRect) {
        ctx.saveGState()
        ctx.clip(to: pane)
        if let image {
            let o = origin(in: pane), s = scale
            let rect = CGRect(x: o.x, y: o.y, width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
            drawChecker(ctx, rect)
            draw(ctx, image, at: o)
            drawBorder(rect)
        } else {
            let text = NSAttributedString(string: "No file", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.secondaryText,
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: pane.midX - size.width / 2, y: pane.midY - size.height / 2))
        }
        ctx.restoreGState()
    }

    /// Draws an image with its top-left corner at `origin`, upright in this flipped view.
    private func draw(_ ctx: CGContext, _ image: CGImage, at origin: CGPoint) {
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y + h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// The backdrop that shows through transparent pixels.
    private func drawChecker(_ ctx: CGContext, _ rect: CGRect) {
        let visible = rect.intersection(bounds)
        guard !visible.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: visible)
        ctx.setFillColor(Theme.checkerLight.cgColor)
        ctx.fill(visible)
        let size = Self.checkerSize
        let i0 = Int(floor((visible.minX - rect.minX) / size)), i1 = Int(ceil((visible.maxX - rect.minX) / size))
        let j0 = Int(floor((visible.minY - rect.minY) / size)), j1 = Int(ceil((visible.maxY - rect.minY) / size))
        var tiles: [CGRect] = []
        tiles.reserveCapacity((i1 - i0) * (j1 - j0) / 2 + 1)
        for j in j0..<j1 {
            for i in i0..<i1 where (i + j) % 2 != 0 {
                tiles.append(CGRect(x: rect.minX + CGFloat(i) * size, y: rect.minY + CGFloat(j) * size, width: size, height: size))
            }
        }
        ctx.setFillColor(Theme.checkerDark.cgColor)
        ctx.fill(tiles)
        ctx.restoreGState()
    }

    private func drawBorder(_ rect: CGRect) {
        Theme.separator.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
