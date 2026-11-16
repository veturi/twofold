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
        didSet {
            guard oldValue != mode else { return }
            // The anchor is taken in the old mode's geometry, which `model` still describes.
            rebuild(anchor: captureAnchor(mode: oldValue))
            if oldValue == .unified || mode == .unified { searchAgain() }
        }
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
    /// Sides that cannot be changed: no typing there and no copying to them.
    var lockedSides: Set<Side> = [] {
        didSet { if oldValue != lockedSides { needsDisplay = true } }
    }
    /// Called with the side to copy the current change to.
    var onCopy: ((Side) -> Void)?
    /// In a three-way merge: what the result takes for each change. The ribbon then shows a pair of
    /// buttons on every change instead of the copy buttons, and unresolved conflicts get their own colour.
    var mergeMarks: [MergeMark]? {
        didSet { if oldValue != mergeMarks { needsDisplay = true } }
    }
    /// Called with a change and the side whose lines the result should take for it.
    var onTake: ((Int, Side) -> Void)?
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

    var selection: (side: Side, anchor: TextPos, head: TextPos)?

    /// Find: every match of `findQuery` in reading order, the matches of each line, and the current one.
    private(set) var findQuery = ""
    var findMatches: [FindMatch] = []
    var findLines: [[Int: Range<Int>]] = [[:], [:]]
    var findIndex: Int?
    /// True when the search stopped at `maxFindMatches`.
    var findOverflow = false
    /// Called when the matches or the current match change.
    var onFindChange: (() -> Void)?
    private var focusSide: Side = .left

    /// True from the start of a re-diff until its result is shown. Edits wait in `pendingOps` meanwhile.
    var busy = false {
        didSet { if !busy { drainOps() } }
    }
    private var pendingOps: [() -> Void] = []
    /// Installed by the next `setDiff`: where the caret belongs once an edit is on screen.
    private var pendingSelection: (side: Side, anchor: TextPos, head: TextPos)?
    /// Text an input method is still composing, as a range within one line.
    private var marked: (side: Side, line: Int, range: Range<Int>)?
    /// True while consecutive keystrokes should fold into one undo step.
    private var typingRun = false
    /// The column vertical movement tries to keep, in view coordinates.
    private var caretGoalX: CGFloat?
    private var caretOn = true
    private var caretTimer: Timer?
    /// Replaces a range of text on one side. Arguments: side, start, end, new text, and whether this
    /// continues the previous keystroke. Returns the position after the new text, or nil if refused.
    var onEdit: ((Side, TextPos, TextPos, String, Bool) -> TextPos?)?
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

    var ribbonWidth: CGFloat { mode == .fluid ? Self.fluidRibbonWidth : (mode == .blocks ? 1 : 0) }
    /// Width of one pane. In Unified mode the two sides share a single pane.
    var paneWidth: CGFloat {
        mode == .unified ? max(120, bounds.width - Self.stripWidth)
            : max(120, floor((bounds.width - Self.stripWidth - ribbonWidth) / 2))
    }
    func paneX(_ s: Side) -> CGFloat { s == .left || mode == .unified ? 0 : paneWidth + ribbonWidth }
    /// What the path bar lines up with. Above a single column it still shows A and B as two halves.
    private var headerGeometry: (CGFloat, CGFloat) {
        mode == .unified ? (floor((bounds.width - Self.stripWidth) / 2), 1) : (paneWidth, ribbonWidth)
    }

    private var digits: Int {
        max(3, String(max(diff?.left.lines.count ?? 0, diff?.right.lines.count ?? 0)).count)
    }
    private var numberWidth: CGFloat { ceil(CGFloat(digits) * metrics.smallCharWidth) }
    /// Unified mode has two columns of line numbers, A's then B's.
    var gutterWidth: CGFloat {
        ceil(CGFloat(digits) * metrics.smallCharWidth + metrics.charWidth + 26) + (mode == .unified ? numberWidth + 10 : 0)
    }
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
        if mode != .fluid { return scrollT }
        let half = bounds.height / 2 - Self.topInset
        let y = m.sideY(forT: scrollT + half, side) - half
        let maxS = max(0, m.totals[side.rawValue] + Self.topInset + Self.bottomInset - bounds.height)
        return min(max(y, 0), maxS)
    }

    // MARK: Content

    func setDiff(_ d: TextDiff?, columns: [[Int32]], syntax: [SyntaxMap?] = [nil, nil], edit: LineEdit? = nil, preserveScroll: Bool) {
        let anchor = preserveScroll ? captureAnchor() : nil
        if let edit, let old = diff, let d {
            // Folds are remembered by block index, which an edit shifts: keep every run expanded
            // that overlaps one the user had opened.
            let opened = expanded.filter { $0 < old.blocks.count }.map { i -> Range<Int> in
                let r = edit.side == .left ? old.blocks[i].left : old.blocks[i].right
                let end = r.upperBound >= edit.oldRange.upperBound ? r.upperBound + edit.newCount - edit.oldRange.count
                    : max(edit.map(r.upperBound), edit.oldRange.lowerBound + edit.newCount)
                return edit.map(r.lowerBound)..<max(end, edit.map(r.lowerBound))
            }
            expanded = Set(d.blocks.indices.filter { i in
                guard d.blocks[i].kind == .equal else { return false }
                let r = edit.side == .left ? d.blocks[i].left : d.blocks[i].right
                return opened.contains { $0.overlaps(r) }
            })
            if pendingSelection == nil, let s = selection, s.side == edit.side {
                func moved(_ p: TextPos) -> TextPos {
                    edit.oldRange.contains(p.line) ? TextPos(line: edit.map(p.line), offset: 0) : TextPos(line: edit.map(p.line), offset: p.offset)
                }
                selection = (s.side, moved(s.anchor), moved(s.head))
            }
        }
        if !preserveScroll {
            pendingSelection = nil
            marked = nil
            typingRun = false
        }
        let caretMoved = pendingSelection != nil
        if let p = pendingSelection {
            selection = p
            focusSide = p.side
            pendingSelection = nil
        }
        defer { if caretMoved { scrollCaretIntoView() } }
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
        searchAgain()
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
        onGeometryChange?(headerGeometry.0, headerGeometry.1)
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
                onGeometryChange?(headerGeometry.0, headerGeometry.1)
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

    private func captureAnchor(screenY: CGFloat? = nil, mode: LayoutMode? = nil) -> Anchor? {
        guard let m = model, bounds.height > 0 else { return nil }
        let sy = screenY ?? bounds.height / 2
        let mode = mode ?? self.mode
        // In Unified mode unchanged lines belong to the right side.
        for side in (mode == .unified ? [Side.right, .left] : [Side.left, .right]) where !m.lines(side).isEmpty {
            let scroll = mode == self.mode ? sideScroll(side)
                : (mode == .fluid ? m.sideY(forT: scrollT + bounds.height / 2 - Self.topInset, side) - bounds.height / 2 + Self.topInset : scrollT)
            let y = scroll + sy - Self.topInset
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

    func fill(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
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
        renderCaret(ctx)
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
                if mode != .unified || side == .right { renderFold(ctx, s, side, x0, sy) }
            case .equal:
                if mode != .unified {
                    renderLine(ctx, m, side, s.lines(side).lowerBound, x0, sy, kind: nil, current: false)
                } else if side == .right {
                    renderLine(ctx, m, side, s.rightLines.lowerBound, x0, sy, kind: nil, current: false, paired: s.leftLines.lowerBound)
                }
            case .change:
                renderChange(ctx, m, s, side, x0, sy, off, topY, botY, pulse)
            }
            i += 1
        }
    }

    /// The colours of a change: its kind's, or the conflict colours while a merge leaves it unresolved.
    private func colors(_ s: LayoutSection, _ diff: TextDiff) -> Palette.Change {
        if let marks = mergeMarks, s.change >= 0, s.change < marks.count, marks[s.change].conflict { return pal.conflict }
        return pal.colors(diff.blocks[s.block].kind)
    }

    private func renderChange(_ ctx: CGContext, _ m: DiffLayout, _ s: LayoutSection, _ side: Side,
                              _ x0: CGFloat, _ sy: CGFloat, _ off: CGFloat, _ topY: CGFloat, _ botY: CGFloat,
                              _ pulse: CGFloat?) {
        guard let diff else { return }
        // In one column the old lines are red and the new ones green, whatever kind the change is.
        let unified = mode == .unified
        let kind: DiffBlock.Kind = unified ? (side == .left ? .removed : .added) : diff.blocks[s.block].kind
        let colors = unified ? pal.colors(kind) : colors(s, diff)
        let current = s.change == currentChange
        let h = s.height(side)
        let sy = sy + (side == .right ? s.rightOffset : 0)
        if h > 0 {
            let body = CGRect(x: x0, y: sy, width: paneWidth, height: h)
            fill(ctx, body, current ? colors.bodyCurrent : colors.body)
            fill(ctx, CGRect(x: x0, y: sy, width: gutterWidth, height: h), current ? colors.gutterCurrent : colors.gutter)
            if current, let p = pulse { fill(ctx, body, colors.stroke.copy(alpha: p)!) }
            let lines = s.lines(side)
            var l = m.line(in: s, side, atY: topY) ?? lines.lowerBound
            let tops = m.lineTop[side.rawValue]
            while l < lines.upperBound && tops[l] <= botY {
                renderLine(ctx, m, side, l, x0, tops[l] - off + Self.topInset, kind: kind, current: current, colors: colors)
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
                            _ x0: CGFloat, _ sy: CGFloat, kind: DiffBlock.Kind?, current: Bool,
                            colors override: Palette.Change? = nil, paired: Int? = nil) {
        let colors = override ?? kind.map { pal.colors($0) }
        let rows = m.rowStarts(side, line)
        let text = m.lines(side)[line]
        let length = text.utf16.count
        let baselineOffset = (metrics.rowHeight - metrics.ascent - metrics.descent) / 2 + metrics.ascent
        let firstBaseline = sy + metrics.linePad + baselineOffset

        // Gutter: number and change marker.
        let num = numberLine(line + 1)
        let markerX = x0 + gutterWidth - metrics.charWidth - 8
        ctx.setFillColor(current ? pal.white : pal.lineNumber)
        // Unified mode: A's number in the first column, B's in the second; an unchanged line has both.
        let ownColumn = mode == .unified && side == .left ? markerX - 8 - numberWidth - 10 : markerX - 8
        ctx.textPosition = CGPoint(x: ownColumn - width(num), y: firstBaseline)
        CTLineDraw(num, ctx)
        if let paired {
            let other = numberLine(paired + 1)
            ctx.textPosition = CGPoint(x: markerX - 8 - numberWidth - 10 - width(other), y: firstBaseline)
            CTLineDraw(other, ctx)
        }
        if let kind {
            let marker = kind == .added ? "+" : (kind == .removed ? "−" : "~")
            ctx.setFillColor(current ? pal.white : (colors ?? pal.colors(kind)).marker)
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
        let found = findLines[side.rawValue][line]
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
            if let found {
                for k in found {
                    let f = findMatches[k].range
                    let a = max(f.lowerBound, rs), b = min(f.upperBound, re)
                    guard a < b else { continue }
                    let xa = CTLineGetOffsetForStringIndex(ctl, a - rs, nil)
                    let xb = CTLineGetOffsetForStringIndex(ctl, b - rs, nil)
                    let rect = CGRect(x: tx + xa - 1, y: rowTop, width: xb - xa + 2, height: metrics.rowHeight)
                    ctx.setFillColor(k == findIndex ? pal.findCurrent : pal.findMatch)
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
        if mode == .unified { return }
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
            let colors = colors(s, diff)
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

    /// The two ribbon buttons of a change, in the middle of its connector: copy to left and copy to
    /// right, or in a merge take left and take right. Only the current change's stay on screen when
    /// the change itself is partly scrolled away.
    private func buttonRects(_ c: Int) -> (left: CGRect, right: CGRect)? {
        guard mode == .fluid, let m = model, c >= 0, c < m.changeSections.count else { return nil }
        let s = m.sections[m.changeSections[c]]
        let lt = s.leftY - sideScroll(.left) + Self.topInset, rt = s.rightY - sideScroll(.right) + Self.topInset
        guard max(lt + s.leftHeight, rt + s.rightHeight) > 0, min(lt, rt) < bounds.height else { return nil }
        let size: CGFloat = mergeMarks == nil ? 20 : 18
        let mid = (lt + s.leftHeight / 2 + rt + s.rightHeight / 2) / 2
        let y = (c == currentChange ? min(max(mid, size / 2 + 4), bounds.height - size / 2 - 4) : mid) - size / 2
        let cx = paneWidth + ribbonWidth / 2
        return (CGRect(x: cx - size - 2, y: y, width: size, height: size), CGRect(x: cx + 2, y: y, width: size, height: size))
    }

    private func copyButtonRects() -> (left: CGRect, right: CGRect)? {
        guard mergeEnabled, mergeMarks == nil, let c = currentChange else { return nil }
        return buttonRects(c)
    }

    /// The changes whose take buttons are on screen, in a merge.
    private func visibleTakeButtons() -> [(change: Int, left: CGRect, right: CGRect)] {
        guard let marks = mergeMarks, mode == .fluid, let m = model, !m.sections.isEmpty else { return [] }
        let offL = sideScroll(.left), offR = sideScroll(.right)
        let lo = min(m.sectionIndex(.left, atY: offL - Self.topInset), m.sectionIndex(.right, atY: offR - Self.topInset))
        let hi = max(m.sectionIndex(.left, atY: offL + bounds.height), m.sectionIndex(.right, atY: offR + bounds.height))
        var out: [(Int, CGRect, CGRect)] = []
        for i in max(0, lo - 1)...min(m.sections.count - 1, hi + 1) where m.sections[i].kind == .change {
            let c = m.sections[i].change
            guard c < marks.count, let r = buttonRects(c) else { continue }
            out.append((c, r.left, r.right))
        }
        return out
    }

    private func renderCopyButtons(_ ctx: CGContext, _ m: DiffLayout) {
        guard let diff else { return }
        if let marks = mergeMarks {
            renderTakeButtons(ctx, m, diff, marks)
            return
        }
        guard let rects = copyButtonRects(), let c = currentChange else { return }
        let colors = pal.colors(diff.blocks[m.sections[m.changeSections[c]].block].kind)
        for (rect, direction) in [(rects.left, CGFloat(-1)), (rects.right, CGFloat(1))] {
            if lockedSides.contains(direction < 0 ? .left : .right) { continue }
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

    /// A filled, ticked circle on each side the result takes; an empty ring on a side it leaves out.
    private func renderTakeButtons(_ ctx: CGContext, _ m: DiffLayout, _ diff: TextDiff, _ marks: [MergeMark]) {
        for (c, left, right) in visibleTakeButtons() {
            let colors = colors(m.sections[m.changeSections[c]], diff)
            for (rect, taken) in [(left, marks[c].left), (right, marks[c].right)] {
                ctx.setFillColor(pal.ribbonBackground)
                ctx.fillEllipse(in: rect.insetBy(dx: -1.5, dy: -1.5))
                if taken {
                    ctx.setFillColor(colors.gutterCurrent)
                    ctx.fillEllipse(in: rect)
                    let tick = CGMutablePath()
                    tick.move(to: CGPoint(x: rect.midX - 3.8, y: rect.midY + 0.3))
                    tick.addLine(to: CGPoint(x: rect.midX - 1.1, y: rect.midY + 3))
                    tick.addLine(to: CGPoint(x: rect.midX + 3.9, y: rect.midY - 3))
                    ctx.addPath(tick)
                    ctx.setStrokeColor(pal.white)
                    ctx.setLineWidth(1.7)
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.strokePath()
                } else {
                    ctx.setStrokeColor(colors.stroke)
                    ctx.setLineWidth(1.5)
                    ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
                }
            }
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
            let colors = colors(s, diff)
            let y = 4 + (s.t + Self.topInset) * scale
            let r = CGRect(x: sx + 4, y: y, width: Self.stripWidth - 7, height: max(2, s.h * scale))
            ctx.setFillColor(c == currentChange ? colors.marker : colors.stroke)
            ctx.fill(r)
        }
        if !findMatches.isEmpty {
            ctx.setFillColor(pal.findTick)
            var last: CGFloat = -10
            for f in findMatches {
                guard let top = m.position(f.side, f.line) else { continue }
                let y = (4 + (m.t(forY: top, f.side) + Self.topInset) * scale).rounded()
                if abs(y - last) < 2 { continue }
                last = y
                ctx.fill(CGRect(x: sx + 1, y: y, width: 3, height: 2))
            }
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
        if mode == .unified {
            guard p.x < paneWidth, let m = model, !m.sections.isEmpty else { return nil }
            // A change shows its left lines first; everything else is the right side's.
            let y = p.y - Self.topInset + scrollT
            let s = m.sections[m.sectionIndex(.left, atY: y)]
            return s.kind == .change && (y < s.leftY + s.leftHeight || s.rightLines.isEmpty) && !s.leftLines.isEmpty ? .left : .right
        }
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
        if mode == .unified && side == .left && s.kind == .equal { return .none }
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
            if buttons.left.contains(p), !lockedSides.contains(.left) { onCopy?(.left); return }
            if buttons.right.contains(p), !lockedSides.contains(.right) { onCopy?(.right); return }
        }
        for (change, left, right) in visibleTakeButtons() {
            guard left.contains(p) || right.contains(p) else { continue }
            if change != currentChange {
                currentChange = change
                onStateChange?()
                needsDisplay = true
            }
            onTake?(change, left.contains(p) ? .left : .right)
            return
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
            typingRun = false
            marked = nil
            caretGoalX = nil
            caretOn = true
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
        guard mergeEnabled || mergeMarks != nil, let side = side(at: p),
              case .text(_, _, let change?) = hit(p, side: side) else { return nil }
        if change != currentChange {
            currentChange = change
            onStateChange?()
            needsDisplay = true
        }
        let menu = NSMenu()
        if mergeMarks != nil {
            menu.addItem(withTitle: "Use A", action: #selector(MergeWindowController.useLeft(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Use B", action: #selector(MergeWindowController.useRight(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Use Both", action: #selector(MergeWindowController.useBoth(_:)), keyEquivalent: "")
            return menu
        }
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
        // With a caret in an editable comparison the keyboard edits; otherwise it scrolls.
        if mergeEnabled, selection != nil {
            caretOn = true
            interpretKeyEvents([e])
            return
        }
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
        if item.action == #selector(cut(_:)) { return mergeEnabled && selectedText != nil }
        if item.action == #selector(paste(_:)) { return mergeEnabled && selection != nil && NSPasteboard.general.string(forType: .string) != nil }
        if item.action == #selector(selectAll(_:)) { return model != nil }
        return true
    }
}

/// Which lines of one side an edit replaced, so that state tied to line numbers can follow it.
struct LineEdit {
    var side: Side
    var oldRange: Range<Int>
    var newCount: Int

    /// Where a line index of the old document ends up; lines inside the replaced range collapse to its start.
    func map(_ line: Int) -> Int {
        if line < oldRange.lowerBound { return line }
        if line >= oldRange.upperBound { return line + newCount - oldRange.count }
        return oldRange.lowerBound
    }
}

// MARK: - Editing

/// Typing, deleting, caret movement, cut and paste.
///
/// Every operation goes through `perform`, which holds it back while a re-diff is in flight, so each
/// one runs against the document that is on screen and none is lost when keys arrive faster than diffs.
extension DiffCanvasView {
    var hasPendingOps: Bool { !pendingOps.isEmpty }

    func cancelPendingOps() {
        pendingOps.removeAll()
        pendingSelection = nil
        marked = nil
        typingRun = false
    }

    func perform(_ op: @escaping () -> Void) {
        if busy || !pendingOps.isEmpty { pendingOps.append(op) } else { op() }
    }

    func drainOps() {
        while !busy, !pendingOps.isEmpty { pendingOps.removeFirst()() }
    }

    /// Places the caret. Line and column are zero-based; used by snapshot runs.
    func setCaret(_ side: Side, line: Int, column: Int) {
        guard let m = model, line < m.lines(side).count else { return }
        let pos = TextPos(line: line, offset: min(column, lineLength(side, line)))
        selection = (side, pos, pos)
        focusSide = side
        typingRun = false
        scrollCaretIntoView()
    }

    /// Types text as the keyboard would, one character at a time. For snapshot runs, the arrows
    /// ← → ↑ ↓ move the caret and ⌫ deletes backward.
    func type(_ text: String) {
        for ch in text {
            switch ch {
            case "\n": insertNewline(nil)
            case "←": moveLeft(nil)
            case "→": moveRight(nil)
            case "↑": moveUp(nil)
            case "↓": moveDown(nil)
            case "⌫": deleteBackward(nil)
            default: insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    /// The selection the next diff should install, for edits made outside the canvas such as undo.
    func selectAfterNextDiff(_ side: Side, _ pos: TextPos) {
        pendingSelection = (side, pos, pos)
    }

    // MARK: Positions

    private func lineLength(_ side: Side, _ line: Int) -> Int {
        guard let m = model, line >= 0, line < m.lines(side).count else { return 0 }
        return m.lines(side)[line].utf16.count
    }

    private func isVisible(_ side: Side, _ line: Int) -> Bool {
        model?.isShown(side, line) ?? false
    }

    /// One character back. With `visibleOnly`, a line start steps over folded lines to the line shown above.
    private func before(_ side: Side, _ p: TextPos, visibleOnly: Bool) -> TextPos {
        guard let m = model, p.line < m.lines(side).count else { return p }
        if p.offset > 0 {
            let s = m.lines(side)[p.line] as NSString
            return TextPos(line: p.line, offset: s.rangeOfComposedCharacterSequence(at: min(p.offset, s.length) - 1).location)
        }
        var l = p.line - 1
        if visibleOnly { while l >= 0 && !isVisible(side, l) { l -= 1 } }
        return l >= 0 ? TextPos(line: l, offset: lineLength(side, l)) : p
    }

    private func after(_ side: Side, _ p: TextPos, visibleOnly: Bool) -> TextPos {
        guard let m = model, p.line < m.lines(side).count else { return p }
        let s = m.lines(side)[p.line] as NSString
        if p.offset < s.length {
            return TextPos(line: p.line, offset: NSMaxRange(s.rangeOfComposedCharacterSequence(at: p.offset)))
        }
        var l = p.line + 1
        let count = m.lines(side).count
        if visibleOnly { while l < count && !isVisible(side, l) { l += 1 } }
        return l < count ? TextPos(line: l, offset: 0) : p
    }

    private func wordBefore(_ side: Side, _ p: TextPos, visibleOnly: Bool) -> TextPos {
        guard let m = model, p.line < m.lines(side).count, p.offset > 0 else { return before(side, p, visibleOnly: visibleOnly) }
        let s = m.lines(side)[p.line] as NSString
        var i = min(p.offset, s.length)
        while i > 0 && !isWordChar(s.character(at: i - 1)) { i -= 1 }
        while i > 0 && isWordChar(s.character(at: i - 1)) { i -= 1 }
        return TextPos(line: p.line, offset: i)
    }

    private func wordAfter(_ side: Side, _ p: TextPos, visibleOnly: Bool) -> TextPos {
        guard let m = model, p.line < m.lines(side).count else { return p }
        let s = m.lines(side)[p.line] as NSString
        guard p.offset < s.length else { return after(side, p, visibleOnly: visibleOnly) }
        var i = p.offset
        while i < s.length && !isWordChar(s.character(at: i)) { i += 1 }
        while i < s.length && isWordChar(s.character(at: i)) { i += 1 }
        return TextPos(line: p.line, offset: i)
    }

    private func documentEnd(_ side: Side) -> TextPos {
        guard let m = model else { return TextPos(line: 0, offset: 0) }
        var l = m.lines(side).count - 1
        while l > 0 && !isVisible(side, l) { l -= 1 }
        return TextPos(line: max(l, 0), offset: lineLength(side, max(l, 0)))
    }

    private func documentStart(_ side: Side) -> TextPos {
        var l = 0
        let count = model?.lines(side).count ?? 0
        while l < count - 1 && !isVisible(side, l) { l += 1 }
        return TextPos(line: l, offset: 0)
    }

    /// Where the caret is drawn, in view coordinates, or nil when its line is folded away.
    func caretRect(_ side: Side, _ pos: TextPos) -> CGRect? {
        guard let m = model, pos.line >= 0, pos.line < m.lines(side).count else { return nil }
        let top = m.lineTop[side.rawValue][pos.line]
        guard top >= 0 else { return nil }
        let rows = m.rowStarts(side, pos.line)
        let length = lineLength(side, pos.line)
        let offset = min(max(pos.offset, 0), length)
        var r = rows.count - 1
        while r > 0 && rows[r] > offset { r -= 1 }
        let rs = rows[r], re = r + 1 < rows.count ? rows[r + 1] : length
        let x = CTLineGetOffsetForStringIndex(ctline(side, pos.line, r, rs, re), offset - rs, nil)
        let y = top - sideScroll(side) + Self.topInset + metrics.linePad + CGFloat(r) * metrics.rowHeight
        return CGRect(x: paneX(side) + textX - hOffset + x, y: y, width: 1.5, height: metrics.rowHeight)
    }

    /// The position one visual row above or below, keeping the column the movement started in.
    private func vertical(_ direction: CGFloat, _ side: Side, _ p: TextPos) -> TextPos {
        scrollCaretIntoView()
        guard let r = caretRect(side, p) else { return p }
        let x = caretGoalX ?? r.minX
        caretGoalX = x
        var y = r.midY
        // Step in half rows so nothing is skipped; folds and gaps between sections are stepped over.
        for _ in 0..<80 {
            y += direction * metrics.rowHeight / 2
            if case .text(_, let q, _) = hit(CGPoint(x: x, y: y), side: side),
               let qr = caretRect(side, q), abs(qr.minY - r.minY) > 0.5, (qr.minY - r.minY) * direction > 0 {
                return q
            }
        }
        return p
    }

    func scrollCaretIntoView() {
        guard let s = selection else { return }
        for _ in 0..<3 {
            guard let r = caretRect(s.side, s.head) else { break }
            if r.minY < 6 { scrollT -= 6 - r.minY } else if r.maxY > bounds.height - 6 { scrollT += r.maxY - bounds.height + 6 } else { break }
            clampScroll()
        }
        if !wrapLines, let r = caretRect(s.side, s.head) {
            let left = paneX(s.side) + textX, right = paneX(s.side) + paneWidth - 24
            if r.minX < left { hOffset -= left - r.minX } else if r.minX > right { hOffset += r.minX - right }
            clampScroll()
        }
        needsDisplay = true
    }

    // MARK: Caret drawing

    func renderCaret(_ ctx: CGContext) {
        guard mergeEnabled, window?.firstResponder === self, let s = selection else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: paneX(s.side) + gutterWidth, y: 0, width: paneWidth - gutterWidth, height: bounds.height))
        if let m = marked, m.side == s.side,
           let a = caretRect(m.side, TextPos(line: m.line, offset: m.range.lowerBound)),
           let b = caretRect(m.side, TextPos(line: m.line, offset: m.range.upperBound)), a.minY == b.minY {
            fill(ctx, CGRect(x: a.minX, y: a.maxY - 2, width: b.minX - a.minX, height: 1), pal.text)
        }
        if s.anchor == s.head, caretOn, let r = caretRect(s.side, s.head) { fill(ctx, r, pal.text) }
        ctx.restoreGState()
    }

    override func becomeFirstResponder() -> Bool {
        caretOn = true
        caretTimer?.invalidate()
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mergeEnabled, let s = self.selection, s.anchor == s.head else { return }
                self.caretOn.toggle()
                self.needsDisplay = true
            }
        }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        caretTimer?.invalidate()
        caretTimer = nil
        needsDisplay = true
        return true
    }

    // MARK: Changing text

    /// Replaces a range on one side through the owner, which answers with the position after the new text.
    @discardableResult
    private func edit(_ side: Side, _ a: TextPos, _ b: TextPos, _ text: String, coalesce: Bool) -> TextPos? {
        guard mergeEnabled, !lockedSides.contains(side), let end = onEdit?(side, a, b, text, coalesce && typingRun) else { return nil }
        pendingSelection = (side, end, end)
        typingRun = coalesce
        caretGoalX = nil
        caretOn = true
        return end
    }

    /// The range new text should replace: text being composed, a range the input system names within
    /// the caret's line, or the selection.
    private func editRange(_ replacement: NSRange) -> (Side, TextPos, TextPos)? {
        guard let s = selection else { return nil }
        if let m = marked, m.side == s.side {
            return (s.side, TextPos(line: m.line, offset: m.range.lowerBound), TextPos(line: m.line, offset: m.range.upperBound))
        }
        if replacement.location != NSNotFound {
            let length = lineLength(s.side, s.head.line)
            let a = min(replacement.location, length), b = min(NSMaxRange(replacement), length)
            return (s.side, TextPos(line: s.head.line, offset: a), TextPos(line: s.head.line, offset: b))
        }
        return (s.side, min(s.anchor, s.head), max(s.anchor, s.head))
    }

    private func replaceSelection(with text: String, coalesce: Bool = false) {
        perform { [self] in
            guard let (side, a, b) = editRange(NSRange(location: NSNotFound, length: 0)) else { return }
            marked = nil
            edit(side, a, b, text, coalesce: coalesce && a == b)
        }
    }

    private func delete(coalesce: Bool = false, to target: @escaping (Side, TextPos) -> TextPos) {
        perform { [self] in
            guard let s = selection else { return }
            marked = nil
            if s.anchor != s.head {
                edit(s.side, min(s.anchor, s.head), max(s.anchor, s.head), "", coalesce: false)
            } else {
                let t = target(s.side, s.head)
                if t != s.head { edit(s.side, min(t, s.head), max(t, s.head), "", coalesce: coalesce) }
            }
        }
    }

    private func moveCaret(extend: Bool, keepColumn: Bool = false, _ target: @escaping (Side, TextPos) -> TextPos) {
        perform { [self] in
            guard let s = selection else { return }
            if !keepColumn { caretGoalX = nil }
            let t = target(s.side, s.head)
            selection = (s.side, extend ? s.anchor : t, t)
            typingRun = false
            marked = nil
            caretOn = true
            scrollCaretIntoView()
        }
    }

    /// Left and right collapse a selection to its edge instead of moving past it.
    private func moveHorizontally(_ forward: Bool, extend: Bool) {
        moveCaret(extend: extend) { [self] side, p in
            if !extend, let s = selection, s.anchor != s.head { return forward ? max(s.anchor, s.head) : min(s.anchor, s.head) }
            return forward ? after(side, p, visibleOnly: true) : before(side, p, visibleOnly: true)
        }
    }

    override func moveLeft(_ sender: Any?) { moveHorizontally(false, extend: false) }
    override func moveRight(_ sender: Any?) { moveHorizontally(true, extend: false) }
    override func moveBackward(_ sender: Any?) { moveHorizontally(false, extend: false) }
    override func moveForward(_ sender: Any?) { moveHorizontally(true, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { moveHorizontally(false, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { moveHorizontally(true, extend: true) }
    override func moveUp(_ sender: Any?) { moveCaret(extend: false, keepColumn: true) { [self] in vertical(-1, $0, $1) } }
    override func moveDown(_ sender: Any?) { moveCaret(extend: false, keepColumn: true) { [self] in vertical(1, $0, $1) } }
    override func moveUpAndModifySelection(_ sender: Any?) { moveCaret(extend: true, keepColumn: true) { [self] in vertical(-1, $0, $1) } }
    override func moveDownAndModifySelection(_ sender: Any?) { moveCaret(extend: true, keepColumn: true) { [self] in vertical(1, $0, $1) } }
    override func moveWordLeft(_ sender: Any?) { moveCaret(extend: false) { [self] in wordBefore($0, $1, visibleOnly: true) } }
    override func moveWordRight(_ sender: Any?) { moveCaret(extend: false) { [self] in wordAfter($0, $1, visibleOnly: true) } }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { moveCaret(extend: true) { [self] in wordBefore($0, $1, visibleOnly: true) } }
    override func moveWordRightAndModifySelection(_ sender: Any?) { moveCaret(extend: true) { [self] in wordAfter($0, $1, visibleOnly: true) } }

    private func lineStart(_ extend: Bool) { moveCaret(extend: extend) { _, p in TextPos(line: p.line, offset: 0) } }
    private func lineEnd(_ extend: Bool) { moveCaret(extend: extend) { [self] side, p in TextPos(line: p.line, offset: lineLength(side, p.line)) } }
    override func moveToBeginningOfLine(_ sender: Any?) { lineStart(false) }
    override func moveToEndOfLine(_ sender: Any?) { lineEnd(false) }
    override func moveToLeftEndOfLine(_ sender: Any?) { lineStart(false) }
    override func moveToRightEndOfLine(_ sender: Any?) { lineEnd(false) }
    override func moveToBeginningOfParagraph(_ sender: Any?) { lineStart(false) }
    override func moveToEndOfParagraph(_ sender: Any?) { lineEnd(false) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { lineStart(true) }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) { lineEnd(true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { lineStart(true) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { lineEnd(true) }
    override func moveToBeginningOfDocument(_ sender: Any?) { moveCaret(extend: false) { [self] side, _ in documentStart(side) } }
    override func moveToEndOfDocument(_ sender: Any?) { moveCaret(extend: false) { [self] side, _ in documentEnd(side) } }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { moveCaret(extend: true) { [self] side, _ in documentStart(side) } }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { moveCaret(extend: true) { [self] side, _ in documentEnd(side) } }

    override func deleteBackward(_ sender: Any?) { delete(coalesce: true) { [self] in before($0, $1, visibleOnly: false) } }
    override func deleteForward(_ sender: Any?) { delete(coalesce: true) { [self] in after($0, $1, visibleOnly: false) } }
    override func deleteWordBackward(_ sender: Any?) { delete { [self] in wordBefore($0, $1, visibleOnly: false) } }
    override func deleteWordForward(_ sender: Any?) { delete { [self] in wordAfter($0, $1, visibleOnly: false) } }
    override func deleteToBeginningOfLine(_ sender: Any?) { delete { _, p in TextPos(line: p.line, offset: 0) } }
    override func deleteToEndOfLine(_ sender: Any?) { delete { [self] side, p in TextPos(line: p.line, offset: lineLength(side, p.line)) } }
    override func deleteToEndOfParagraph(_ sender: Any?) { deleteToEndOfLine(sender) }

    /// A new line starts with the indentation of the one it was broken from.
    override func insertNewline(_ sender: Any?) {
        perform { [self] in
            guard let (side, a, b) = editRange(NSRange(location: NSNotFound, length: 0)), let m = model, a.line < m.lines(side).count else { return }
            marked = nil
            let line = m.lines(side)[a.line] as NSString
            var indent = 0
            while indent < a.offset && indent < line.length && (line.character(at: indent) == 32 || line.character(at: indent) == 9) { indent += 1 }
            edit(side, a, b, "\n" + line.substring(to: indent), coalesce: false)
        }
    }

    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    override func insertTab(_ sender: Any?) { replaceSelection(with: "\t", coalesce: true) }
    override func insertBacktab(_ sender: Any?) {}
    override func cancelOperation(_ sender: Any?) {}

    override func pageUp(_ sender: Any?) { setScroll(scrollT - max(40, bounds.height - 60)) }
    override func pageDown(_ sender: Any?) { setScroll(scrollT + max(40, bounds.height - 60)) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { setScroll(0) }
    override func scrollToEndOfDocument(_ sender: Any?) { setScroll(.greatestFiniteMagnitude) }

    @objc func cut(_ sender: Any?) {
        guard mergeEnabled, selectedText != nil else { return }
        copy(sender)
        replaceSelection(with: "")
    }

    @objc func paste(_ sender: Any?) {
        guard mergeEnabled, let text = NSPasteboard.general.string(forType: .string) else { return }
        replaceSelection(with: text)
    }
}

// MARK: - Text input

/// Keyboard text and input methods. The input system sees one line at a time: every range it is given
/// or hands back is in UTF-16 offsets within the caret's line.
extension DiffCanvasView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        perform { [self] in
            guard let (side, a, b) = editRange(replacementRange) else { return }
            marked = nil
            edit(side, a, b, text, coalesce: text.count == 1 && a == b)
        }
    }

    /// Text still being composed is put into the document straight away and replaced as it changes.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        perform { [self] in
            guard let (side, a, b) = editRange(replacementRange), edit(side, a, b, text, coalesce: true) != nil else { return }
            let length = text.utf16.count
            marked = length == 0 ? nil : (side, a.line, a.offset..<(a.offset + length))
            let caret = TextPos(line: a.line, offset: a.offset + min(max(selectedRange.location, 0), length))
            pendingSelection = (side, caret, caret)
        }
    }

    func unmarkText() {
        perform { [self] in
            marked = nil
            needsDisplay = true
        }
    }

    func selectedRange() -> NSRange {
        guard let s = selection else { return NSRange(location: NSNotFound, length: 0) }
        let a = min(s.anchor, s.head), b = max(s.anchor, s.head)
        return a.line == b.line ? NSRange(location: a.offset, length: b.offset - a.offset) : NSRange(location: s.head.offset, length: 0)
    }

    func markedRange() -> NSRange {
        marked.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) } ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let s = selection, let m = model, s.head.line < m.lines(s.side).count else { return nil }
        let line = m.lines(s.side)[s.head.line] as NSString
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: line.length))
        actualRange?.pointee = clipped
        return NSAttributedString(string: line.substring(with: clipped))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let s = selection, let r = caretRect(s.side, TextPos(line: s.head.line, offset: range.location)), let window else { return .zero }
        return window.convertToScreen(convert(r, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) }
    }
}

// MARK: - Find

/// One occurrence of the search text: a UTF-16 range within a line of one side.
struct FindMatch: Equatable {
    var side: Side
    var line: Int
    var range: Range<Int>
}

extension DiffCanvasView {
    static let maxFindMatches = 20_000

    /// Sets the text to look for and moves to the first match at or after the current one,
    /// or after the top of the view. An empty string ends the search.
    func setFindQuery(_ query: String) {
        guard query != findQuery else { return }
        let previous = findIndex.map { findMatches[$0] }
        findQuery = query
        searchAgain()
        if !findMatches.isEmpty {
            let near = previous.flatMap { p in
                findMatches.firstIndex { $0.side == p.side && ($0.line, $0.range.lowerBound) >= (p.line, p.range.lowerBound) }
            }
            selectMatch(near ?? firstMatchInView())
        }
        onFindChange?()
        needsDisplay = true
    }

    /// Searches both sides again, in the order the text is read: block by block, and line by line
    /// where the sides are equal. Called when the query, the documents or the layout mode change.
    func searchAgain() {
        let previous = findIndex.map { findMatches[$0] }
        findMatches = []
        findLines = [[:], [:]]
        findIndex = nil
        findOverflow = false
        defer {
            onFindChange?()
            needsDisplay = true
        }
        guard !findQuery.isEmpty, let diff else { return }
        let query = findQuery
        let length = (query as NSString).length
        func search(_ side: Side, _ line: Int) {
            let string = side == .left ? diff.left.lines[line] : diff.right.lines[line]
            guard string.utf8.count >= length else { return }
            guard findMatches.count < Self.maxFindMatches else {
                findOverflow = true
                return
            }
            let text = string as NSString
            let start = findMatches.count
            var from = 0
            while from < text.length {
                let r = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: from, length: text.length - from))
                if r.location == NSNotFound || r.length == 0 { break }
                findMatches.append(FindMatch(side: side, line: line, range: r.location..<NSMaxRange(r)))
                from = NSMaxRange(r)
            }
            if findMatches.count > start { findLines[side.rawValue][line] = start..<findMatches.count }
        }
        for block in diff.blocks {
            if block.kind == .equal {
                for k in 0..<block.left.count {
                    // Unified mode shows an unchanged line once, as the right side's.
                    if mode != .unified { search(.left, block.left.lowerBound + k) }
                    search(.right, block.right.lowerBound + k)
                }
            } else {
                for l in block.left { search(.left, l) }
                for r in block.right { search(.right, r) }
            }
            if findOverflow { break }
        }
        if let previous { findIndex = findMatches.firstIndex(of: previous) }
    }

    private func firstMatchInView() -> Int {
        guard let m = model else { return 0 }
        for (i, f) in findMatches.enumerated() {
            // A match inside a fold counts as being where the fold is.
            if let y = m.position(f.side, f.line), y + metrics.rowHeight - sideScroll(f.side) + Self.topInset > 0 { return i }
        }
        return 0
    }

    /// Moves to the next or previous match, wrapping around at the ends.
    func findStep(forward: Bool) {
        let n = findMatches.count
        guard n > 0 else {
            NSSound.beep()
            return
        }
        if let i = findIndex {
            selectMatch((i + (forward ? 1 : n - 1)) % n)
        } else {
            let first = firstMatchInView()
            selectMatch(forward ? first : (first + n - 1) % n)
        }
    }

    /// Makes a match current: opens the fold that hides it, selects it and scrolls it into view.
    private func selectMatch(_ i: Int) {
        guard i >= 0, i < findMatches.count, let diff else { return }
        findIndex = i
        let f = findMatches[i]
        if let m = model, m.lineTop[f.side.rawValue][f.line] < 0,
           let block = diff.blocks.firstIndex(where: { $0.kind == .equal && (f.side == .left ? $0.left : $0.right).contains(f.line) }) {
            expanded.insert(block)
            rebuild(anchor: captureAnchor())
        }
        let start = TextPos(line: f.line, offset: f.range.lowerBound)
        selection = (f.side, start, TextPos(line: f.line, offset: f.range.upperBound))
        focusSide = f.side
        typingRun = false
        marked = nil
        caretGoalX = nil
        if let m = model, let r = caretRect(f.side, start) {
            if r.minY < 30 || r.maxY > bounds.height - 70 {
                let y = r.midY - Self.topInset + sideScroll(f.side)
                let target = min(max(m.t(forY: y, f.side) - (bounds.height / 2 - Self.topInset), 0), maxScrollT)
                if window?.isVisible == true {
                    scrollTarget = target
                    startTicking()
                } else {
                    scrollT = target
                }
            }
            if !wrapLines {
                let left = paneX(f.side) + textX, right = paneX(f.side) + paneWidth - 60
                if r.minX < left { hOffset -= left - r.minX + 40 } else if r.minX > right { hOffset += r.minX - right + 40 }
                clampScroll()
            }
        }
        onFindChange?()
        needsDisplay = true
    }
}

/// What a three-way merge's result takes for one change, and whether the change is still an open conflict.
struct MergeMark: Equatable {
    var left = false
    var right = false
    var conflict = false
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
    let findMatch = Theme.findMatch.cgColor
    let findCurrent = Theme.findCurrent.cgColor
    let findTick = Theme.findTick.cgColor
    let thumb = Theme.thumb.cgColor
    let thumbBorder = Theme.thumbBorder.cgColor
    let white = CGColor(gray: 1, alpha: 1)
    /// Indexed by `SyntaxKind.rawValue`.
    let syntax = SyntaxKind.allCases.map { Theme.syntax($0).cgColor }
    let added = Change(Theme.added)
    let removed = Change(Theme.removed)
    let modified = Change(Theme.modified)
    let conflict = Change(Theme.conflict)

    func colors(_ kind: DiffBlock.Kind) -> Change {
        switch kind {
        case .added: added
        case .removed: removed
        case .modified, .equal: modified
        }
    }
}
