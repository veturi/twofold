import AppKit

/// The editable result of a three-way merge: one text view whose text is divided into segments,
/// one per merge chunk, so that a chunk's lines can be found and replaced after any amount of typing.
///
/// Segment lengths are kept up to date from the text storage's own edit reports, which also cover
/// undo and redo. Nothing else is remembered about a segment: what a chunk currently holds is read
/// back from the text, so undo can never leave the two out of step.
@MainActor
final class MergeResultView: NSView, @preconcurrency NSTextStorageDelegate, NSTextViewDelegate {
    enum Style: Equatable { case plain, change, conflict }

    let scrollView = NSScrollView()
    let textView: ResultTextView
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    /// UTF-16 length of each segment, and where each starts.
    private(set) var lengths: [Int] = []
    private var starts: [Int] = []
    /// How many unresolved conflicts (opening marker lines) each segment holds.
    private var markerCounts: [Int] = []
    private(set) var totalMarkers = 0
    /// The segment a programmatic replacement is aimed at, while it runs.
    private var target: Int?
    private var loading = false
    private var touched = Set<Int>()

    var styles: [Style] = [] { didSet { if oldValue != styles { textView.needsDisplay = true } } }
    var current: Int? { didSet { if oldValue != current { textView.needsDisplay = true } } }
    /// Called after any change to the text with the segments it touched.
    var onChange: ((Set<Int>) -> Void)?
    /// Called when the user moves the caret into another segment.
    var onCaretSegment: ((Int) -> Void)?
    private var caretSegment: Int?

    var wrapLines = true { didSet { if oldValue != wrapLines { applyWrap() } } }

    override init(frame: NSRect) {
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = ResultTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)
        storage.delegate = self

        textView.owner = self
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.paneBackground
        textView.insertionPointColor = Theme.text
        textView.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Merge result")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.paneBackground
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setFontSize(Preferences.shared.fontSize)
        applyWrap()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Appearance

    private var attributes: [NSAttributedString.Key: Any] = [:]

    func setFontSize(_ size: CGFloat) {
        let metrics = TextMetrics(size: size)
        attributes = [.font: metrics.font, .foregroundColor: Theme.text, .paragraphStyle: metrics.paragraphStyle]
        textView.typingAttributes = attributes
        textView.font = metrics.font
        textView.defaultParagraphStyle = metrics.paragraphStyle
        if storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func applyWrap() {
        let huge = CGFloat.greatestFiniteMagnitude
        if wrapLines {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            scrollView.hasHorizontalScroller = false
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
            container.size = NSSize(width: scrollView.contentSize.width - 2 * textView.textContainerInset.width, height: huge)
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: huge, height: huge)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
        textView.needsDisplay = true
    }

    // MARK: Segments

    var text: String { storage.string }
    var segmentCount: Int { lengths.count }

    /// Replaces everything. Not undoable; used when a merge is loaded.
    func setSegments(_ texts: [String]) {
        loading = true
        lengths = texts.map { $0.utf16.count }
        storage.setAttributedString(NSAttributedString(string: texts.joined(), attributes: attributes))
        loading = false
        textView.undoManager?.removeAllActions(withTarget: textView)
        rebuildStarts()
        markerCounts = lengths.indices.map(countMarkers)
        totalMarkers = markerCounts.reduce(0, +)
        touched.removeAll()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.needsDisplay = true
    }

    private func rebuildStarts() {
        starts.removeAll(keepingCapacity: true)
        starts.reserveCapacity(lengths.count)
        var at = 0
        for n in lengths {
            starts.append(at)
            at += n
        }
    }

    func range(of segment: Int) -> NSRange {
        NSRange(location: starts[segment], length: lengths[segment])
    }

    func text(of segment: Int) -> String {
        storage.mutableString.substring(with: range(of: segment))
    }

    /// True when the segment's text is exactly `candidate`.
    func segment(_ segment: Int, equals candidate: String) -> Bool {
        lengths[segment] == candidate.utf16.count && (lengths[segment] == 0 || text(of: segment) == candidate)
    }

    func markerCount(_ segment: Int) -> Int { markerCounts[segment] }

    /// The segment a character position belongs to.
    func segment(at position: Int) -> Int? {
        guard !lengths.isEmpty else { return nil }
        return containing(min(max(position, 0), max(storage.length - 1, 0)))
    }

    /// The last segment that starts at or before `position`. For a position inside the text this is
    /// the segment that holds the character there, since empty segments sort before it.
    private func containing(_ position: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Replaces one segment's text as an undoable edit.
    func replace(segment: Int, with text: String, actionName: String) {
        let range = range(of: segment)
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        target = segment
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        target = nil
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !loading, editedMask.contains(.editedCharacters), !lengths.isEmpty else { return }
        let a = editedRange.location, newLength = editedRange.length, oldLength = editedRange.length - delta
        if let target {
            lengths[target] += delta
            touched.insert(target)
        } else if oldLength <= 0 {
            // An insertion at a point. An empty segment there takes it, as the place where a chunk's
            // lines would go; otherwise the segment whose text surrounds or follows the point.
            var first = containing(a)
            while first > 0 && starts[first - 1] == a && lengths[first - 1] == 0 { first -= 1 }
            if !(starts[first] == a && lengths[first] == 0) { first = containing(a) }
            if starts[first] + lengths[first] < a { first = lengths.count - 1 }
            lengths[first] += newLength
            touched.insert(first)
        } else {
            let end = a + oldLength
            let first = containing(a), last = containing(end - 1)
            let lastEnd = starts[last] + lengths[last]
            if first == last {
                lengths[first] += delta
            } else {
                lengths[first] = a - starts[first] + newLength
                for i in (first + 1)..<last { lengths[i] = 0 }
                lengths[last] = max(0, lastEnd - end)
            }
            touched.formUnion(first...last)
        }
        // Should the bookkeeping ever disagree with the text, put the difference in the last segment
        // rather than carry a wrong map forward.
        let total = lengths.reduce(0, +)
        if total != textStorage.length {
            lengths[lengths.count - 1] = max(0, lengths[lengths.count - 1] + textStorage.length - total)
            touched.formUnion(lengths.indices)
        }
        rebuildStarts()
    }

    func textDidChange(_ notification: Notification) {
        flush()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !loading, target == nil, window?.firstResponder === textView,
              let segment = segment(at: textView.selectedRange().location) else { return }
        if segment != caretSegment {
            caretSegment = segment
            onCaretSegment?(segment)
        }
    }

    /// Recounts what the edited segments hold and reports them.
    private func flush() {
        guard !touched.isEmpty else { return }
        let changed = touched
        touched.removeAll()
        for i in changed where i < lengths.count {
            let n = countMarkers(i)
            totalMarkers += n - markerCounts[i]
            markerCounts[i] = n
        }
        textView.needsDisplay = true
        onChange?(changed)
    }

    /// Lines in a segment that open a conflict: "<<<<<<<" at the start of a line, then a space or the end.
    private func countMarkers(_ segment: Int) -> Int {
        let string = storage.mutableString
        let range = range(of: segment)
        var count = 0
        var search = range
        while search.length >= 7 {
            let found = string.range(of: "<<<<<<<", options: [.literal], range: search)
            guard found.location != NSNotFound else { break }
            let atLineStart = found.location == 0 || string.character(at: found.location - 1) == 10
                || string.character(at: found.location - 1) == 13
            let after = NSMaxRange(found)
            let ends = after >= string.length || [32, 10, 13].contains(string.character(at: after))
            if atLineStart && ends { count += 1 }
            search = NSRange(location: after, length: NSMaxRange(range) - after)
        }
        return count
    }

    // MARK: Scrolling and drawing

    /// Brings a segment into view, a little below the top of the pane.
    func scroll(to segment: Int) {
        guard segment < lengths.count else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, starts[segment] + lengths[segment] + 1)))
        let y = top(of: segment) + textView.textContainerOrigin.y
        let clip = scrollView.contentView
        let visible = clip.bounds.height
        let maxY = max(0, textView.frame.height - visible)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, y - visible * 0.3), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The y of a segment's first line, in text container coordinates.
    private func top(of segment: Int) -> CGFloat {
        let at = starts[segment]
        if at < storage.length {
            return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: at), effectiveRange: nil).minY
        }
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0 { return extra.minY }
        return layoutManager.usedRect(for: container).maxY
    }

    /// Paints the changed segments' lines behind the text.
    fileprivate func drawSegments(in rect: NSRect) {
        guard !lengths.isEmpty, styles.count == lengths.count else { return }
        let origin = textView.textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: local, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var i = containing(visible.location)
        while i > 0 && starts[i - 1] == starts[i] { i -= 1 }
        let width = textView.bounds.width
        while i < lengths.count && starts[i] <= NSMaxRange(visible) {
            defer { i += 1 }
            guard styles[i] != .plain else { continue }
            let colors = styles[i] == .conflict ? Theme.conflict : Theme.modified
            if lengths[i] == 0 {
                // Nothing taken here: a line marks the spot.
                colors.stroke.setFill()
                NSRect(x: 0, y: top(of: i) + origin.y - 1, width: width, height: i == current ? 2 : 1.5).fill()
                continue
            }
            let shown = NSIntersectionRange(range(of: i), visible)
            guard shown.length > 0 else { continue }
            let box = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: shown, actualCharacterRange: nil), in: container)
            (i == current ? colors.bodyCurrent : colors.body).setFill()
            NSRect(x: 0, y: box.minY + origin.y, width: width, height: box.height).fill()
            (i == current ? colors.gutterCurrent : colors.stroke).setFill()
            NSRect(x: 0, y: box.minY + origin.y, width: 3, height: box.height).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        textView.needsDisplay = true
    }
}

/// The result pane's text view. It only adds the segment backgrounds.
@MainActor
final class ResultTextView: NSTextView {
    fileprivate weak var owner: MergeResultView?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        owner?.drawSegments(in: rect)
    }
}
