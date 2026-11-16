import AppKit
import DiffCore

struct TextPos: Comparable, Hashable {
    var line: Int
    var offset: Int

    static func < (a: TextPos, b: TextPos) -> Bool {
        a.line != b.line ? a.line < b.line : a.offset < b.offset
    }
}

/// Draws both panes, the ribbon between them and the overview strip, and owns scrolling.
///
/// Only rows intersecting the view are drawn. Typeset rows are cached as `CTLine`s.
@MainActor
final class DiffCanvasView: NSView {
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 48
    static let stripWidth: CGFloat = 14
    static let fluidRibbonWidth: CGFloat = 64

    private(set) var diff: TextDiff?
    private var columns: [[Int32]] = [[], []]
    /// Token colours for each side, or nil where the language is unknown.
    private var syntax: [SyntaxMap?] = [nil, nil]
    private var maxColumns = 0
    private(set) var model: DiffLayout?
    private(set) var metrics = TextMetrics(size: Preferences.shared.fontSize)

    var mode: LayoutMode = .fluid {
        didSet { if oldValue != mode { rebuild(anchor: captureAnchor()) } }
    }
    var wrapLines = true {
        didSet { if oldValue != wrapLines { hOffset = 0; rebuild(anchor: captureAnchor()) } }
    }
    var showInvisibles = true {
        didSet { needsDisplay = true }
    }
    var showSyntax = true {
        didSet {
            guard oldValue != showSyntax else { return }
            lineCache.removeAll(keepingCapacity: true)
            needsDisplay = true
        }
    }
    var expandAll = false {
        didSet { if oldValue != expandAll { rebuild(anchor: captureAnchor()) } }
    }
    private var expanded = Set<Int>()

    private(set) var scrollT: CGFloat = 0
    private var hOffset: CGFloat = 0
    private(set) var currentChange: Int?

    /// Called when the current change or the change count changes.
    var onStateChange: (() -> Void)?
    /// Whether changes can be copied across; shows the copy buttons on the current change.
    var mergeEnabled = false {
        didSet { if oldValue != mergeEnabled { needsDisplay = true } }
    }
    /// Called with the side to copy the current change to.
    var onCopy: ((Side) -> Void)?
    /// Called with the pane and ribbon widths whenever they change.
    var onGeometryChange: ((CGFloat, CGFloat) -> Void)?

    private struct LineKey: Hashable {
        var side: UInt8
        var line: Int32
        var row: Int32
    }
    private var lineCache: [LineKey: CTLine] = [:]
    private var numberCache: [Int: CTLine] = [:]
    private struct LabelKey: Hashable {
        var text: String
        var small: Bool
        var bold: Bool
    }
    private var labelCache: [LabelKey: CTLine] = [:]

    private var selection: (side: Side, anchor: TextPos, head: TextPos)?
    private var focusSide: Side = .left
    private var draggingStrip = false
    private var link: CADisplayLink?
    private var scrollTarget: CGFloat?
    private var pulseStart: CFTimeInterval?
    private var lastTick: CFTimeInterval = 0
    private var lastWidth: CGFloat = -1
    private var palette: Palette?
    private var pal: Palette { palette ?? Palette() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Comparison")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Geometry

    var ribbonWidth: CGFloat { mode == .fluid ? Self.fluidRibbonWidth : 1 }
    var paneWidth: CGFloat { max(120, floor((bounds.width - Self.stripWidth - ribbonWidth) / 2)) }
    func paneX(_ s: Side) -> CGFloat { s == .left ? 0 : paneWidth + ribbonWidth }

    private var digits: Int {
        max(3, String(max(diff?.left.lines.count ?? 0, diff?.right.lines.count ?? 0)).count)
    }
    var gutterWidth: CGFloat { ceil(CGFloat(digits) * metrics.smallCharWidth + metrics.charWidth + 26) }
    var textX: CGFloat { gutterWidth + 10 }
    private var wrapColumns: Int? {
        wrapLines ? max(16, Int((paneWidth - textX - 18) / metrics.charWidth)) : nil
    }
    private var maxScrollT: CGFloat {
        max(0, (model?.totalT ?? 0) + Self.topInset + Self.bottomInset - bounds.height)
    }
    private var maxHOffset: CGFloat {
        wrapLines ? 0 : max(0, CGFloat(maxColumns) * metrics.charWidth - (paneWidth - textX) + 40)
    }

    /// Scroll offset of one side. In Fluid mode the line at the vertical centre is aligned across sides.
    func sideScroll(_ side: Side) -> CGFloat {
        guard let m = model else { return 0 }
        if mode == .blocks { return scrollT }
        let half = bounds.height / 2 - Self.topInset
        let y = m.sideY(forT: scrollT + half, side) - half
        let maxS = max(0, m.totals[side.rawValue] + Self.topInset + Self.bottomInset - bounds.height)
        return min(max(y, 0), maxS)
    }

    // MARK: Content

    func setDiff(_ d: TextDiff?, columns: [[Int32]], syntax: [SyntaxMap?] = [nil, nil], preserveScroll: Bool) {
        let anchor = preserveScroll ? captureAnchor() : nil
        diff = d
        self.columns = columns
        self.syntax = syntax
        maxColumns = Int(columns.flatMap { $0 }.max() ?? 0)
        if !preserveScroll {
            expanded = []
            scrollT = 0
            hOffset = 0
            selection = nil
            currentChange = (d?.changeBlocks.isEmpty == false) ? 0 : nil
        } else if let c = currentChange {
            let n = d?.changeBlocks.count ?? 0
            currentChange = n == 0 ? nil : min(c, n - 1)
        }
        if let s = selection, (s.side == .left ? d?.left.lines.count : d?.right.lines.count) ?? 0 <= max(s.anchor.line, s.head.line) {
            selection = nil
        }
        rebuild(anchor: anchor)
    }

    func setFontSize(_ size: CGFloat) {
        guard size != metrics.size else { return }
        let anchor = captureAnchor()
        metrics = TextMetrics(size: size)
        numberCache.removeAll()
        labelCache.removeAll()
        rebuild(anchor: anchor)
    }

    private func rebuild(anchor: Anchor?) {
        lineCache.removeAll(keepingCapacity: true)
        if let diff {
            model = DiffLayout(diff: diff, columns: columns, metrics: metrics, mode: mode,
                               wrapColumns: wrapColumns, expanded: expanded, expandAll: expandAll)
        } else {
            model = nil
        }
        if let anchor { restore(anchor) }
        clampScroll()
        onGeometryChange?(paneWidth, ribbonWidth)
        onStateChange?()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width != lastWidth {
            lastWidth = newSize.width
            if let m = model, m.wrapColumns != wrapColumns {
                rebuild(anchor: captureAnchor())
            } else {
                onGeometryChange?(paneWidth, ribbonWidth)
            }
            lineCache.removeAll(keepingCapacity: true)
        }
        clampScroll()
    }

    // MARK: Anchoring

    private struct Anchor {
        var side: Side
        var line: Int
        var fraction: CGFloat
        var screenY: CGFloat
    }

    private func captureAnchor(screenY: CGFloat? = nil) -> Anchor? {
        guard let m = model, bounds.height > 0 else { return nil }
        let sy = screenY ?? bounds.height / 2
        for side in [Side.left, .right] where !m.lines(side).isEmpty {
            let y = sideScroll(side) + sy - Self.topInset
            let s = m.sections[m.sectionIndex(side, atY: y)]
            if s.kind == .fold {
                return Anchor(side: side, line: s.lines(side).lowerBound, fraction: 0, screenY: sy)
            }
            if let l = m.line(in: s, side, atY: y) {
                let top = m.lineTop[side.rawValue][l]
                let h = m.lineHeight(side, l)
                return Anchor(side: side, line: l, fraction: min(1, max(0, (y - top) / h)), screenY: sy)
            }
        }
        return nil
    }

    private func restore(_ a: Anchor) {
        guard let m = model, a.line < m.lines(a.side).count else { return }
        var top = m.lineTop[a.side.rawValue][a.line]
        var h = m.lineHeight(a.side, a.line)
        if top < 0 {
            // The line is folded now: anchor to the fold that hides it.
            guard let s = m.sections.first(where: { $0.kind == .fold && $0.lines(a.side).contains(a.line) }) else { return }
            top = s.y(a.side)
            h = 0
        }
        // Keep the anchored line where it was on screen.
        let t = m.t(forY: top + a.fraction * h, a.side)
        scrollT = t - (a.screenY - Self.topInset)
    }

    private func clampScroll() {
        scrollT = min(max(scrollT, 0), maxScrollT)
        hOffset = min(max(hOffset, 0), maxHOffset)
    }

    func setScroll(_ t: CGFloat) {
        scrollT = t
        clampScroll()
        needsDisplay = true
    }

    // MARK: Navigation

    var changeCount: Int { diff?.changeBlocks.count ?? 0 }

    func goToChange(_ i: Int, animated: Bool = true) {
        guard let m = model, i >= 0, i < m.changeSections.count else { return }
        currentChange = i
        let s = m.sections[m.changeSections[i]]
        let visible = bounds.height - Self.topInset - Self.bottomInset
        let target: CGFloat
        if s.h < visible * 0.7 {
            target = s.t + s.h / 2 - (bounds.height / 2 - Self.topInset)
        } else {
            target = s.t - bounds.height * 0.15
        }
        let clamped = min(max(target, 0), maxScrollT)
        if animated && window?.isVisible == true {
            scrollTarget = clamped
            pulseStart = CACurrentMediaTime()
            startTicking()
        } else {
            scrollT = clamped
        }
        onStateChange?()
        needsDisplay = true
    }

    func nextChange() {
        guard changeCount > 0 else { return }
        goToChange(min(changeCount - 1, (currentChange ?? -1) + 1))
    }

    func previousChange() {
        guard changeCount > 0 else { return }
        goToChange(max(0, (currentChange ?? 1) - 1))
    }

    private func startTicking() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        if let target = scrollTarget {
            let k = 1 - exp(-dt * 13)
            scrollT += (target - scrollT) * k
            if abs(target - scrollT) < 0.5 {
                scrollT = target
                scrollTarget = nil
            }
        }
        if let p = pulseStart, now - p > 0.75 { pulseStart = nil }
        if scrollTarget == nil && pulseStart == nil {
            l.invalidate()
            link = nil
        }
        needsDisplay = true
    }

    private var pulseAlpha: CGFloat? {
        guard let p = pulseStart else { return nil }
        let x = (CACurrentMediaTime() - p) / 0.75
        guard x < 1 else { return nil }
        return CGFloat(sin(x * .pi)) * 0.35
    }

    // MARK: Typesetting

    private static let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
    private static let foreground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    private func ctline(_ side: Side, _ line: Int, _ row: Int, _ start: Int, _ end: Int) -> CTLine {
        let key = LineKey(side: UInt8(side.rawValue), line: Int32(line), row: Int32(row))
        if let l = lineCache[key] { return l }
        guard let m = model else { return CTLineCreateWithAttributedString(NSAttributedString()) }
        let str = m.lines(side)[line] as NSString
        let sub = (start == 0 && end == str.length) ? str as String : str.substring(with: NSRange(location: start, length: end - start))
        var attr = NSAttributedString(string: sub, attributes: [
            .font: metrics.font, Self.fromContext: true, .paragraphStyle: metrics.paragraphStyle,
        ])
        if showSyntax, let spans = syntax[side.rawValue]?[line], !spans.isEmpty {
            // Core Text leaves the last token's colour set in the context, so a line with tokens
            // gives its plain text an explicit colour too instead of taking it from the context.
            let colored = NSMutableAttributedString(string: sub, attributes: [
                .font: metrics.font, Self.foreground: pal.text, .paragraphStyle: metrics.paragraphStyle,
            ])
            var i = spans.startIndex
            if spans.count > 32 {
                // Long lines: skip straight to the first token that reaches this row.
                var lo = spans.startIndex, hi = spans.endIndex
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if spans[mid].range.upperBound <= start { lo = mid + 1 } else { hi = mid }
                }
                i = lo
            }
            while i < spans.endIndex, spans[i].range.lowerBound < end {
                let a = max(spans[i].range.lowerBound, start), b = min(spans[i].range.upperBound, end)
                if a < b {
                    colored.addAttribute(Self.foreground, value: pal.syntax[Int(spans[i].kind.rawValue)],
                                         range: NSRange(location: a - start, length: b - a))
                }
                i += 1
            }
            attr = colored
        }
        let l = CTLineCreateWithAttributedString(attr)
        if lineCache.count > 8000 { lineCache.removeAll(keepingCapacity: true) }
        lineCache[key] = l
        return l
    }

    private func numberLine(_ n: Int) -> CTLine {
        if let l = numberCache[n] { return l }
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: String(n), attributes: [
            .font: metrics.smallFont, Self.fromContext: true,
        ]))
        if numberCache.count > 4000 { numberCache.removeAll() }
        numberCache[n] = l
        return l
    }

    private func label(_ s: String, small: Bool = true, bold: Bool = false) -> CTLine {
        let key = LabelKey(text: s, small: small, bold: bold)
        if let l = labelCache[key] { return l }
        let font: NSFont = small
            ? NSFont.systemFont(ofSize: max(9, round(metrics.size * 0.92)), weight: bold ? .bold : .regular)
            : (bold ? NSFont.monospacedSystemFont(ofSize: metrics.size, weight: .bold) : metrics.font)
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            .font: font, Self.fromContext: true,
        ]))
        if labelCache.count > 500 { labelCache.removeAll() }
        labelCache[key] = l
        return l
    }

    private func width(_ l: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.render(ctx)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = nil
        // Typeset rows hold syntax colours resolved for the old appearance.
        lineCache.removeAll(keepingCapacity: true)
        labelCache.removeAll()
        needsDisplay = true
    }

    private func fill(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fill(r)
    }

    private func render(_ ctx: CGContext) {
        if palette == nil { palette = Palette() }
        fill(ctx, bounds, pal.paneBackground)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        guard let m = model else { return }
        let pulse = pulseAlpha
        for side in [Side.left, .right] {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: paneX(side), y: 0, width: paneWidth, height: bounds.height))
            renderPane(ctx, m, side, pulse)
            ctx.restoreGState()
        }
        renderRibbon(ctx, m)
        renderCopyButtons(ctx, m)
        renderStrip(ctx, m)
    }

    private func renderPane(_ ctx: CGContext, _ m: DiffLayout, _ side: Side, _ pulse: CGFloat?) {
        let off = sideScroll(side)
        let x0 = paneX(side)
        let topY = off - Self.topInset
        let botY = topY + bounds.height
        let sects = m.sections
        guard !sects.isEmpty else { return }
        var i = m.sectionIndex(side, atY: topY)
        while i > 0 && sects[i - 1].y(side) + sects[i - 1].span(side) >= topY - 2 && sects[i - 1].span(side) == 0 { i -= 1 }
        while i < sects.count {
            let s = sects[i]
            let y = s.y(side)
            if y > botY + 2 { break }
            let sy = y - off + Self.topInset
            switch s.kind {
            case .fold:
                renderFold(ctx, s, side, x0, sy)
            case .equal:
                renderLine(ctx, m, side, s.lines(side).lowerBound, x0, sy, kind: nil, current: false)
            case .change:
                renderChange(ctx, m, s, side, x0, sy, off, topY, botY, pulse)
            }
            i += 1
        }
    }

    private func renderChange(_ ctx: CGContext, _ m: DiffLayout, _ s: LayoutSection, _ side: Side,
                              _ x0: CGFloat, _ sy: CGFloat, _ off: CGFloat, _ topY: CGFloat, _ botY: CGFloat,
                              _ pulse: CGFloat?) {
        guard let diff else { return }
        let colors = pal.colors(diff.blocks[s.block].kind)
        let current = s.change == currentChange
        let h = s.height(side)
        if h > 0 {
            let body = CGRect(x: x0, y: sy, width: paneWidth, height: h)
            fill(ctx, body, current ? colors.bodyCurrent : colors.body)
            fill(ctx, CGRect(x: x0, y: sy, width: gutterWidth, height: h), current ? colors.gutterCurrent : colors.gutter)
            if current, let p = pulse { fill(ctx, body, colors.stroke.copy(alpha: p)!) }
            let lines = s.lines(side)
            var l = m.line(in: s, side, atY: topY) ?? lines.lowerBound
            let tops = m.lineTop[side.rawValue]
            while l < lines.upperBound && tops[l] <= botY {
                renderLine(ctx, m, side, l, x0, tops[l] - off + Self.topInset, kind: diff.blocks[s.block].kind, current: current)
                l += 1
            }
            if mode == .fluid {
                let ex = side == .left ? x0 + paneWidth - 1 : x0 + 1
                ctx.setStrokeColor(colors.stroke)
                ctx.setLineWidth(2)
                ctx.strokeLineSegments(between: [CGPoint(x: ex, y: sy), CGPoint(x: ex, y: sy + h)])
            }
        } else if mode == .fluid {
            ctx.setStrokeColor(colors.stroke)
            ctx.setLineWidth(current ? 2 : 1.5)
            ctx.strokeLineSegments(between: [CGPoint(x: x0, y: sy), CGPoint(x: x0 + paneWidth, y: sy)])
        }
    }

    private func renderLine(_ ctx: CGContext, _ m: DiffLayout, _ side: Side, _ line: Int,
                            _ x0: CGFloat, _ sy: CGFloat, kind: DiffBlock.Kind?, current: Bool) {
        let colors = kind.map { pal.colors($0) }
        let rows = m.rowStarts(side, line)
        let text = m.lines(side)[line]
        let length = text.utf16.count
        let baselineOffset = (metrics.rowHeight - metrics.ascent - metrics.descent) / 2 + metrics.ascent
        let firstBaseline = sy + metrics.linePad + baselineOffset

        // Gutter: number and change marker.
        let num = numberLine(line + 1)
        let markerX = x0 + gutterWidth - metrics.charWidth - 8
        ctx.setFillColor(current ? pal.white : pal.lineNumber)
        ctx.textPosition = CGPoint(x: markerX - 8 - width(num), y: firstBaseline)
        CTLineDraw(num, ctx)
        if let kind {
            let marker = kind == .added ? "+" : (kind == .removed ? "−" : "~")
            ctx.setFillColor(current ? pal.white : pal.colors(kind).marker)
            ctx.textPosition = CGPoint(x: markerX, y: firstBaseline)
            CTLineDraw(label(marker, small: false, bold: true), ctx)
        }

        let clips = !wrapLines
        if clips {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x0 + textX - 3, y: 0, width: paneWidth - textX + 3, height: bounds.height))
        }
        let tx = x0 + textX - hOffset
        let highlights = side == .left ? diff?.leftHighlights[line] : diff?.rightHighlights[line]
        let sel = selectionRange(side, line, length)
        for r in 0..<rows.count {
            let rowTop = sy + metrics.linePad + CGFloat(r) * metrics.rowHeight
            if rowTop > bounds.height { break }
            if rowTop + metrics.rowHeight < 0 { continue }
            let rs = rows[r]
            let re = r + 1 < rows.count ? rows[r + 1] : length
            let ctl = ctline(side, line, r, rs, re)
            if let highlights, let colors {
                ctx.setFillColor(current ? colors.inlineCurrent : colors.inline)
                for h in highlights {
                    let a = max(h.lowerBound, rs), b = min(h.upperBound, re)
                    guard a < b else { continue }
                    let xa = CTLineGetOffsetForStringIndex(ctl, a - rs, nil)
                    let xb = CTLineGetOffsetForStringIndex(ctl, b - rs, nil)
                    let rect = CGRect(x: tx + xa - 1, y: rowTop, width: xb - xa + 2, height: metrics.rowHeight)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                    ctx.fillPath()
                }
            }
            if let sel {
                let a = max(sel.lowerBound, rs), b = min(sel.upperBound, re)
                let extends = sel.upperBound > length && r == rows.count - 1
                if a < b || extends || (a == b && sel.upperBound > re && r < rows.count - 1) {
                    let xa = CTLineGetOffsetForStringIndex(ctl, max(0, a - rs), nil)
                    let xb = extends ? width(ctl) + metrics.charWidth : CTLineGetOffsetForStringIndex(ctl, b - rs, nil)
                    fill(ctx, CGRect(x: tx + xa, y: rowTop, width: max(0, xb - xa), height: metrics.rowHeight), pal.textSelection)
                }
            }
            ctx.setFillColor(pal.text)
            ctx.textPosition = CGPoint(x: tx, y: rowTop + baselineOffset)
            CTLineDraw(ctl, ctx)
            if r == rows.count - 1 && colors != nil && showInvisibles {
                ctx.setFillColor(pal.invisible)
                ctx.textPosition = CGPoint(x: tx + width(ctl) + 2, y: rowTop + baselineOffset)
                CTLineDraw(label("¬", small: false), ctx)
            }
        }
        if clips { ctx.restoreGState() }
    }

    /// The selected UTF-16 range of a line. An upper bound past the end means the line break is selected.
    private func selectionRange(_ side: Side, _ line: Int, _ length: Int) -> Range<Int>? {
        guard let s = selection, s.side == side else { return nil }
        let a = min(s.anchor, s.head), b = max(s.anchor, s.head)
        guard a != b, line >= a.line, line <= b.line else { return nil }
        let start = line == a.line ? a.offset : 0
        let end = line == b.line ? b.offset : length + 1
        return start..<max(start, end)
    }

    private func renderFold(_ ctx: CGContext, _ s: LayoutSection, _ side: Side, _ x0: CGFloat, _ sy: CGFloat) {
        let count = s.lines(side).count
        let h = metrics.foldHeight
        let bx0 = x0 + max(16, gutterWidth - 24), bx1 = x0 + paneWidth - 22
        let top = sy + 6, bottom = sy + h - 6, r: CGFloat = 5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bx0, y: top + r))
        path.addQuadCurve(to: CGPoint(x: bx0 + r, y: top), control: CGPoint(x: bx0, y: top))
        path.addLine(to: CGPoint(x: bx1 - r, y: top))
        path.addQuadCurve(to: CGPoint(x: bx1, y: top + r), control: CGPoint(x: bx1, y: top))
        path.move(to: CGPoint(x: bx0, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: bx0 + r, y: bottom), control: CGPoint(x: bx0, y: bottom))
        path.addLine(to: CGPoint(x: bx1 - r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: bx1, y: bottom - r), control: CGPoint(x: bx1, y: bottom))
        ctx.addPath(path)
        ctx.setStrokeColor(pal.foldLine)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let mid = sy + h / 2
        let pill = CGRect(x: bx0 + 14, y: mid - 6, width: 22, height: 12)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(pal.foldPill)
        ctx.fillPath()
        ctx.setFillColor(pal.foldText)
        for k in 0..<3 {
            ctx.fillEllipse(in: CGRect(x: pill.minX + 5 + CGFloat(k) * 5, y: mid - 1.25, width: 2.5, height: 2.5))
        }
        let text = label("\(count) Unchanged Line\(count == 1 ? "" : "s")")
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(text, &ascent, &descent, nil)
        ctx.textPosition = CGPoint(x: pill.maxX + 8, y: mid + (ascent - descent) / 2)
        CTLineDraw(text, ctx)
    }

    private func renderRibbon(_ ctx: CGContext, _ m: DiffLayout) {
        let rx0 = paneWidth
        let w = ribbonWidth
        if mode == .blocks {
            fill(ctx, CGRect(x: rx0, y: 0, width: 1, height: bounds.height), pal.separator)
            return
        }
        fill(ctx, CGRect(x: rx0, y: 0, width: w, height: bounds.height), pal.ribbonBackground)
        fill(ctx, CGRect(x: rx0, y: 0, width: 1, height: bounds.height), pal.separator)
        fill(ctx, CGRect(x: rx0 + w - 1, y: 0, width: 1, height: bounds.height), pal.separator)
        guard let diff, !m.sections.isEmpty else { return }
        let offL = sideScroll(.left), offR = sideScroll(.right)
        let lo = min(m.sectionIndex(.left, atY: offL - Self.topInset), m.sectionIndex(.right, atY: offR - Self.topInset))
        let hi = max(m.sectionIndex(.left, atY: offL + bounds.height), m.sectionIndex(.right, atY: offR + bounds.height))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rx0 + 1, y: 0, width: w - 2, height: bounds.height))
        for i in max(0, lo - 1)...min(m.sections.count - 1, hi + 1) where m.sections[i].kind == .change {
            let s = m.sections[i]
            let colors = pal.colors(diff.blocks[s.block].kind)
            let current = s.change == currentChange
            let lt = s.leftY - offL + Self.topInset, lb = lt + s.leftHeight
            let rt = s.rightY - offR + Self.topInset, rb = rt + s.rightHeight
            let x1 = rx0 + w, c1 = rx0 + w * 0.5, c2 = rx0 + w * 0.5

            let band = CGMutablePath()
            band.move(to: CGPoint(x: rx0, y: lt))
            band.addCurve(to: CGPoint(x: x1, y: rt), control1: CGPoint(x: c1, y: lt), control2: CGPoint(x: c2, y: rt))
            band.addLine(to: CGPoint(x: x1, y: rb))
            band.addCurve(to: CGPoint(x: rx0, y: lb), control1: CGPoint(x: c2, y: rb), control2: CGPoint(x: c1, y: lb))
            band.closeSubpath()
            ctx.addPath(band)
            ctx.setFillColor(current ? colors.body : colors.band)
            ctx.fillPath()

            let ml = (lt + lb) / 2, mr = (rt + rb) / 2
            let line = CGMutablePath()
            line.move(to: CGPoint(x: rx0, y: ml))
            line.addCurve(to: CGPoint(x: x1, y: mr), control1: CGPoint(x: c1, y: ml), control2: CGPoint(x: c2, y: mr))
            ctx.addPath(line)
            ctx.setStrokeColor(colors.stroke)
            ctx.setLineWidth(current ? 2.25 : 1.5)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The copy-to-left and copy-to-right buttons of the current change, in the middle of its connector.
    private func copyButtonRects() -> (left: CGRect, right: CGRect)? {
        guard mergeEnabled, mode == .fluid, let m = model, let c = currentChange, c < m.changeSections.count else { return nil }
        let s = m.sections[m.changeSections[c]]
        let lt = s.leftY - sideScroll(.left) + Self.topInset, rt = s.rightY - sideScroll(.right) + Self.topInset
        guard max(lt + s.leftHeight, rt + s.rightHeight) > 0, min(lt, rt) < bounds.height else { return nil }
        let size: CGFloat = 20
        let mid = (lt + s.leftHeight / 2 + rt + s.rightHeight / 2) / 2
        let y = min(max(mid, size / 2 + 4), bounds.height - size / 2 - 4) - size / 2
        let cx = paneWidth + ribbonWidth / 2
        return (CGRect(x: cx - size - 2, y: y, width: size, height: size), CGRect(x: cx + 2, y: y, width: size, height: size))
    }

    private func renderCopyButtons(_ ctx: CGContext, _ m: DiffLayout) {
        guard let rects = copyButtonRects(), let diff, let c = currentChange else { return }
        let colors = pal.colors(diff.blocks[m.sections[m.changeSections[c]].block].kind)
        for (rect, direction) in [(rects.left, CGFloat(-1)), (rects.right, CGFloat(1))] {
            ctx.setFillColor(pal.ribbonBackground)
            ctx.fillEllipse(in: rect.insetBy(dx: -2, dy: -2))
            ctx.setFillColor(colors.gutterCurrent)
            ctx.fillEllipse(in: rect)
            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: rect.midX - 4.5 * direction, y: rect.midY))
            arrow.addLine(to: CGPoint(x: rect.midX + 4.5 * direction, y: rect.midY))
            arrow.move(to: CGPoint(x: rect.midX + 1 * direction, y: rect.midY - 3.5))
            arrow.addLine(to: CGPoint(x: rect.midX + 4.5 * direction, y: rect.midY))
            arrow.addLine(to: CGPoint(x: rect.midX + 1 * direction, y: rect.midY + 3.5))
            ctx.addPath(arrow)
            ctx.setStrokeColor(pal.white)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    private var stripScale: CGFloat {
        let total = (model?.totalT ?? 0) + Self.topInset + Self.bottomInset
        return (bounds.height - 8) / max(total, bounds.height)
    }

    private func renderStrip(_ ctx: CGContext, _ m: DiffLayout) {
        guard let diff else { return }
        let sx = bounds.width - Self.stripWidth
        fill(ctx, CGRect(x: sx, y: 0, width: Self.stripWidth, height: bounds.height), pal.paneBackground)
        fill(ctx, CGRect(x: sx, y: 0, width: 1, height: bounds.height), pal.separator)
        let scale = stripScale
        for (c, si) in m.changeSections.enumerated() {
            let s = m.sections[si]
            let colors = pal.colors(diff.blocks[s.block].kind)
            let y = 4 + (s.t + Self.topInset) * scale
            let r = CGRect(x: sx + 4, y: y, width: Self.stripWidth - 7, height: max(2, s.h * scale))
            ctx.setFillColor(c == currentChange ? colors.marker : colors.stroke)
            ctx.fill(r)
        }
        if maxScrollT > 0 {
            let r = CGRect(x: sx + 2, y: 4 + scrollT * scale, width: Self.stripWidth - 3, height: max(12, bounds.height * scale))
            let p = CGPath(roundedRect: r, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(pal.thumb)
            ctx.fillPath()
            ctx.addPath(p)
            ctx.setStrokeColor(pal.thumbBorder)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
    }

    // MARK: Hit testing

    private func side(at p: CGPoint) -> Side? {
        if p.x < paneWidth { return .left }
        if p.x >= paneX(.right) && p.x < bounds.width - Self.stripWidth { return .right }
        return nil
    }

    private enum Hit {
        case fold(Int)
        case text(Side, TextPos, Int?)
        case none
    }

    private func hit(_ p: CGPoint, side: Side) -> Hit {
        guard let m = model, !m.sections.isEmpty else { return .none }
        let y = p.y - Self.topInset + sideScroll(side)
        let si = m.sectionIndex(side, atY: y)
        let s = m.sections[si]
        if s.kind == .fold {
            return y <= s.y(side) + s.span(side) ? .fold(s.block) : .none
        }
        guard let l = m.line(in: s, side, atY: y) else {
            return .none
        }
        let change = s.kind == .change ? s.change : nil
        let top = m.lineTop[side.rawValue][l]
        let rows = m.rowStarts(side, l)
        let length = m.lines(side)[l].utf16.count
        if y > top + m.lineHeight(side, l) {
            return .text(side, TextPos(line: l, offset: length), change)
        }
        let r = min(rows.count - 1, max(0, Int((y - top - metrics.linePad) / metrics.rowHeight)))
        let rs = rows[r], re = r + 1 < rows.count ? rows[r + 1] : length
        let ctl = ctline(side, l, r, rs, re)
        let x = p.x - paneX(side) - textX + hOffset
        var idx = x <= 0 ? 0 : CTLineGetStringIndexForPosition(ctl, CGPoint(x: x, y: 0))
        if idx == kCFNotFound { idx = 0 }
        return .text(side, TextPos(line: l, offset: min(re, rs + max(0, idx))), change)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        scrollTarget = nil
        if p.x >= bounds.width - Self.stripWidth {
            draggingStrip = true
            scrollFromStrip(p.y)
            return
        }
        if let buttons = copyButtonRects() {
            if buttons.left.contains(p) { onCopy?(.left); return }
            if buttons.right.contains(p) { onCopy?(.right); return }
        }
        guard let side = side(at: p) else { return }
        focusSide = side
        switch hit(p, side: side) {
        case .fold(let block):
            let anchor = captureAnchor(screenY: p.y)
            expanded.insert(block)
            rebuild(anchor: anchor)
        case .text(let s, let pos, let change):
            if e.clickCount == 2 {
                selection = (s, wordStart(s, pos), wordEnd(s, pos))
            } else if e.clickCount >= 3 {
                let len = model?.lines(s)[pos.line].utf16.count ?? 0
                selection = (s, TextPos(line: pos.line, offset: 0), TextPos(line: pos.line, offset: len))
            } else if e.modifierFlags.contains(.shift), let sel = selection, sel.side == s {
                selection = (s, sel.anchor, pos)
            } else {
                selection = (s, pos, pos)
            }
            if let change, change != currentChange {
                currentChange = change
                onStateChange?()
            }
            needsDisplay = true
        case .none:
            selection = nil
            needsDisplay = true
        }
    }

    /// Right-clicking a change makes it current and offers to copy it across.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard mergeEnabled, let side = side(at: p), case .text(_, _, let change?) = hit(p, side: side) else { return nil }
        if change != currentChange {
            currentChange = change
            onStateChange?()
            needsDisplay = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy to Right", action: #selector(ComparisonWindowController.copyToRight(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy to Left", action: #selector(ComparisonWindowController.copyToLeft(_:)), keyEquivalent: "")
        return menu
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if draggingStrip {
            scrollFromStrip(p.y)
            return
        }
        guard let sel = selection else { return }
        if p.y < 0 { setScroll(scrollT + p.y / 2) }
        if p.y > bounds.height { setScroll(scrollT + (p.y - bounds.height) / 2) }
        let q = CGPoint(x: min(max(p.x, paneX(sel.side) + 1), paneX(sel.side) + paneWidth - 1),
                        y: min(max(p.y, 0), bounds.height - 1))
        if case .text(let s, let pos, _) = hit(q, side: sel.side), s == sel.side {
            selection = (s, sel.anchor, pos)
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        draggingStrip = false
    }

    private func scrollFromStrip(_ y: CGFloat) {
        setScroll((y - 4) / stripScale - bounds.height / 2)
    }

    private func isWordChar(_ c: unichar) -> Bool {
        guard let sc = Unicode.Scalar(c) else { return true }
        return sc.properties.isAlphabetic || sc.properties.numericType != nil || sc == "_"
    }

    private func wordStart(_ side: Side, _ p: TextPos) -> TextPos {
        guard let m = model else { return p }
        let s = m.lines(side)[p.line] as NSString
        var i = min(p.offset, s.length)
        while i > 0 && isWordChar(s.character(at: i - 1)) { i -= 1 }
        return TextPos(line: p.line, offset: i)
    }

    private func wordEnd(_ side: Side, _ p: TextPos) -> TextPos {
        guard let m = model else { return p }
        let s = m.lines(side)[p.line] as NSString
        var i = p.offset
        while i < s.length && isWordChar(s.character(at: i)) { i += 1 }
        return TextPos(line: p.line, offset: i)
    }

    override func resetCursorRects() {
        for side in [Side.left, .right] {
            addCursorRect(CGRect(x: paneX(side) + textX - 4, y: 0, width: paneWidth - textX + 4, height: bounds.height), cursor: .iBeam)
        }
    }

    // MARK: Scrolling and keys

    override func scrollWheel(with e: NSEvent) {
        scrollTarget = nil
        var dy = e.scrollingDeltaY, dx = e.scrollingDeltaX
        if !e.hasPreciseScrollingDeltas {
            dy *= metrics.rowHeight * 3
            dx *= metrics.charWidth * 3
        }
        if e.modifierFlags.contains(.shift) && dx == 0 { dx = dy; dy = 0 }
        scrollT -= dy
        if !wrapLines { hOffset -= dx }
        clampScroll()
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        let page = max(40, bounds.height - 60)
        switch e.specialKey {
        case .upArrow?: setScroll(scrollT - metrics.rowHeight * 2)
        case .downArrow?: setScroll(scrollT + metrics.rowHeight * 2)
        case .pageUp?: setScroll(scrollT - page)
        case .pageDown?: setScroll(scrollT + page)
        case .home?: setScroll(0)
        case .end?: setScroll(.greatestFiniteMagnitude)
        case .leftArrow? where !wrapLines: hOffset -= metrics.charWidth * 4; clampScroll(); needsDisplay = true
        case .rightArrow? where !wrapLines: hOffset += metrics.charWidth * 4; clampScroll(); needsDisplay = true
        default:
            if e.charactersIgnoringModifiers == " " {
                setScroll(scrollT + (e.modifierFlags.contains(.shift) ? -page : page))
            } else {
                super.keyDown(with: e)
            }
        }
    }

    // MARK: Copy

    var selectedText: String? {
        guard let s = selection, let m = model, s.anchor != s.head else { return nil }
        let a = min(s.anchor, s.head), b = max(s.anchor, s.head)
        let lines = m.lines(s.side)
        var out: [String] = []
        for l in a.line...b.line {
            let ns = lines[l] as NSString
            let start = min(l == a.line ? a.offset : 0, ns.length)
            let end = min(l == b.line ? b.offset : ns.length, ns.length)
            out.append(ns.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
        return out.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let m = model else { return }
        let lines = m.lines(focusSide)
        guard let last = lines.last else { return }
        selection = (focusSide, TextPos(line: 0, offset: 0), TextPos(line: lines.count - 1, offset: last.utf16.count))
        needsDisplay = true
    }
}

extension DiffCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedText != nil }
        if item.action == #selector(selectAll(_:)) { return model != nil }
        return true
    }
}

/// Theme colours resolved to `CGColor` for one appearance, so drawing never resolves dynamic colours.
struct Palette {
    struct Change {
        let body, bodyCurrent, gutter, gutterCurrent, inline, inlineCurrent, stroke, marker, band: CGColor

        init(_ c: Theme.ChangeColors) {
            body = c.body.cgColor
            bodyCurrent = c.bodyCurrent.cgColor
            gutter = c.gutter.cgColor
            gutterCurrent = c.gutterCurrent.cgColor
            inline = c.inline.cgColor
            inlineCurrent = c.inlineCurrent.cgColor
            stroke = c.stroke.cgColor
            marker = c.marker.cgColor
            band = c.band.cgColor
        }
    }

    let paneBackground = Theme.paneBackground.cgColor
    let ribbonBackground = Theme.ribbonBackground.cgColor
    let separator = Theme.separator.cgColor
    let text = Theme.text.cgColor
    let lineNumber = Theme.lineNumber.cgColor
    let foldText = Theme.foldText.cgColor
    let foldLine = Theme.foldLine.cgColor
    let foldPill = Theme.foldPill.cgColor
    let invisible = Theme.invisible.cgColor
    let textSelection = Theme.textSelection.cgColor
    let thumb = Theme.thumb.cgColor
    let thumbBorder = Theme.thumbBorder.cgColor
    let white = CGColor(gray: 1, alpha: 1)
    /// Indexed by `SyntaxKind.rawValue`.
    let syntax = SyntaxKind.allCases.map { Theme.syntax($0).cgColor }
    let added = Change(Theme.added)
    let removed = Change(Theme.removed)
    let modified = Change(Theme.modified)

    func colors(_ kind: DiffBlock.Kind) -> Change {
        switch kind {
        case .added: added
        case .removed: removed
        case .modified, .equal: modified
        }
    }
}
